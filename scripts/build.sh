#!/usr/bin/env bash
# NOTE4C build helper. State is derived from facts: release "<tag>-note4c",
# patches/BASE, and the upstream latest release. Callable locally:
#   TAG=v1.8.17 NO_GH=1 NO_CLAUDE=1 ./scripts/build.sh prepare
#   TAG=v1.8.17 NO_GH=1 NO_CLAUDE=1 ./scripts/build.sh apply
# Subcommands: resolve prepare apply applied patches build amend scan assets
#              publish issue
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OURS=${OURS:-$(dirname "$HERE")}
FW=${FW:-$OURS/.work/test-fw}
DIST=${DIST:-$OURS/.work/test-dist}
UPSTREAM_REPO=${UPSTREAM_REPO:-usetrmnl/trmnl-firmware}
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/$UPSTREAM_REPO.git}
PIO_ENV=${PIO_ENV:-zectrix_note4c}
MARKERS='^(<<<<<<<|=======$|>>>>>>>)'
BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

die() {
  echo "error: $*" >&2
  exit 1
}

export_kv() {
  local k=$1 v=$2
  echo "$k=$v"
  [[ -n ${GITHUB_OUTPUT:-} ]] && echo "$k=$v" >>"$GITHUB_OUTPUT"
  return 0
}

export_env() {
  [[ -n ${GITHUB_ENV:-} ]] && echo "$1=$2" >>"$GITHUB_ENV"
  return 0
}

# Hooks off: files that Claude edits must not run anything during git operations.
fwgit() {
  git -C "$FW" -c core.hooksPath=/dev/null "$@"
}

valid_ref() {
  [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe ref: $1"
}

base_ref() {
  local b=${BASE:-}
  [[ -z $b ]] && b=$(tr -d '[:space:]' <"$OURS/patches/BASE")
  valid_ref "$b"
  echo "$b"
}

release_exists() {
  [[ -n ${NO_GH:-} ]] && return 1
  gh release view "$1" -R "${REPO:?REPO is not set}" >/dev/null 2>&1
}

# True when the last commit that touched patches/BASE says Claude resolved this TAG.
resolved_before() {
  [[ -d $OURS/.git ]] || return 1
  [[ $(base_ref) == "$TAG" ]] || return 1
  git -C "$OURS" log -1 --format=%B -- patches/BASE 2>/dev/null |
    grep -q '^Resolved-by: claude$'
}

am_running() {
  [[ -d $FW/.git/rebase-apply ]]
}

# Added lines that look like conflict markers, in the working tree vs HEAD
# (untracked files included). Prints file names only.
marker_files() {
  local idx
  idx=$(mktemp)
  cp "$FW/.git/index" "$idx"
  GIT_INDEX_FILE=$idx fwgit add -A
  GIT_INDEX_FILE=$idx fwgit diff --cached -U0 HEAD |
    awk -v re="${MARKERS#^}" '
      /^\+\+\+ b\// { file = substr($0, 7); next }
      /^\+/ && substr($0, 2) ~ "^" re { print file }' |
    sort -u
  rm -f "$idx"
}

cmd_resolve() {
  TAG=${TAG:-}
  if [[ -z $TAG ]]; then
    TAG=$(gh release view -R "$UPSTREAM_REPO" --json tagName --jq .tagName)
  fi
  valid_ref "$TAG"
  local skip=false
  if release_exists "${TAG}-note4c" && [[ ${FORCE:-false} != true ]]; then
    skip=true
    echo "release ${TAG}-note4c exists, nothing to do"
  fi
  export_kv tag "$TAG"
  export_kv skip "$skip"
  export_env TAG "$TAG"
  export_env SKIP "$skip"
}

cmd_prepare() {
  valid_ref "$TAG"
  local base
  base=$(base_ref)
  if [[ -e $FW ]]; then
    [[ -f $FW/.git/ci-managed ]] || die "refusing to delete $FW: not created by this script"
    rm -rf "$FW"
  fi
  git clone --quiet --no-checkout "$UPSTREAM_URL" "$FW"
  touch "$FW/.git/ci-managed"
  fwgit fetch --quiet --tags origin
  fwgit rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
    fwgit fetch --quiet origin "$base"
  fwgit rev-parse --verify --quiet "$TAG^{commit}" >/dev/null || die "tag $TAG not found upstream"
  fwgit checkout --quiet --detach "$TAG"
  fwgit config user.name "$BOT_NAME"
  fwgit config user.email "$BOT_EMAIL"
  mkdir -p "$FW/.ci"
  printf '.ci/\n.claude/\n' >>"$FW/.git/info/exclude"
  sha256sum_file "$FW/.git/config" >"$FW/.git/ci-config.sha"
  echo "prepared $FW at $TAG (patch base $base)"
}

sha256sum_file() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

check_git_untouched() {
  [[ $(sha256sum_file "$FW/.git/config") == "$(cat "$FW/.git/ci-config.sha")" ]] ||
    die ".git/config changed during the Claude step"
  local f
  for f in "$FW"/.git/hooks/*; do
    [[ -e $f && $f != *.sample ]] && die "unexpected git hook: ${f##*/}"
  done
  return 0
}

# One round of the apply loop. Starts "git am" the first time, continues it
# afterwards. Stops at the first conflict and reports it.
cmd_apply() {
  local rc=0 out
  if am_running; then
    check_git_untouched
    local bad
    bad=$(marker_files)
    if [[ -n $bad ]]; then
      echo "conflict markers remain in:" >&2
      echo "$bad" >&2
      exit 1
    fi
    fwgit add -A
    out=$(GIT_EDITOR=true fwgit am --continue 2>&1) || rc=$?
    touch "$FW/.ci/resolved"
  else
    shopt -s nullglob
    local patches=("$OURS"/patches/*.patch)
    [[ ${#patches[@]} -gt 0 ]] || die "no patches in $OURS/patches"
    out=$(fwgit am -3 "${patches[@]}" 2>&1) || rc=$?
  fi
  echo "$out"
  if [[ $rc -eq 0 ]]; then
    export_kv conflict false
    return 0
  fi
  local files
  files=$(fwgit diff --name-only --diff-filter=U)
  if [[ -z $files ]]; then
    echo "git am failed without conflicts; see output above" >&2
    exit 1
  fi
  printf '%s\n' "$files" >"$FW/.ci/conflicts.txt"
  local n name
  n=$(<"$FW/.git/rebase-apply/next")
  name=$(find "$OURS/patches" -name '*.patch' | sort | sed -n "${n}p")
  printf '%s\n' "${name##*/}" >"$FW/.ci/patch-name"
  echo "CONFLICT in patch ${name##*/}, files:" >&2
  sed 's/^/  /' "$FW/.ci/conflicts.txt" >&2
  export_kv conflict true
  if [[ -n ${NO_CLAUDE:-} ]]; then
    echo "NO_CLAUDE set: stopping at the conflict" >&2
    exit 1
  fi
}

cmd_applied() {
  ! am_running || die "git am still has conflicts after the maximum number of Claude rounds"
  echo "all patches applied; resolved=$([[ -f $FW/.ci/resolved ]] && echo true || echo false)"
}

# Regenerate the patch series into $DIST/patches when the repo must change.
cmd_patches() {
  local base resolved=false
  base=$(base_ref)
  [[ -f $FW/.ci/resolved ]] && resolved=true
  local update=false
  [[ $resolved == true || $base != "$TAG" ]] && update=true
  resolved_before && resolved=true
  rm -rf "$DIST/patches"
  mkdir -p "$DIST"
  if [[ $update == true ]]; then
    mkdir -p "$DIST/patches"
    fwgit format-patch --quiet --zero-commit --no-signature -o "$DIST/patches" "$TAG..HEAD"
    printf '%s\n' "$TAG" >"$DIST/patches/BASE"
    export_kv update_patches true
  else
    export_kv update_patches false
  fi
  printf 'RESOLVED=%s\n' "$resolved" >"$DIST/meta.env"
  export_kv resolved "$resolved"
}

cmd_build() {
  local final=${1:-first}
  check_git_untouched
  local rc=0
  set +e
  (cd "$FW" && env -u GITHUB_ENV -u GITHUB_OUTPUT -u GITHUB_PATH -u GITHUB_STATE -u GITHUB_STEP_SUMMARY pio run -e "$PIO_ENV") 2>&1 | tee "$FW/.ci/build.log"
  rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -eq 0 && -f $FW/.pio/build/$PIO_ENV/merged_firmware.bin ]]; then
    echo "build ok"
    [[ -n ${GITHUB_OUTPUT:-} ]] && echo "ok=true" >>"$GITHUB_OUTPUT"
    return 0
  fi
  tail -n 200 "$FW/.ci/build.log" >"$FW/.ci/build-tail.log"
  [[ -n ${GITHUB_OUTPUT:-} ]] && echo "ok=false" >>"$GITHUB_OUTPUT"
  echo "build failed" >&2
  if [[ $final == first && -f $FW/.ci/resolved ]]; then
    echo "conflicts were resolved by Claude: one fix round follows" >&2
    return 0
  fi
  return 1
}

cmd_amend() {
  check_git_untouched
  local bad
  bad=$(marker_files)
  [[ -z $bad ]] || die "conflict markers in: $bad"
  fwgit add -A
  fwgit commit --quiet --amend --no-edit
  echo "amended HEAD with the build fix"
}

# Scan everything that could reach the repo: working tree vs TAG (untracked
# included) and the commit messages. Needs CLAUDE_CODE_OAUTH_TOKEN in the env.
cmd_scan() {
  local idx
  idx=$(mktemp)
  cp "$FW/.git/index" "$idx"
  GIT_INDEX_FILE=$idx fwgit add -A
  local rc=0
  {
    GIT_INDEX_FILE=$idx fwgit diff --cached --binary "$TAG"
    fwgit log --format=%B "$TAG..HEAD" 2>/dev/null || true
  } | python3 -I "$HERE/secret_scan.py" || rc=$?
  rm -f "$idx"
  # Raw bytes of every file, ignored and excluded ones included (.ci/, .git/).
  python3 -I "$HERE/secret_scan.py" "$FW" || rc=1
  return "$rc"
}

meta_resolved() {
  [[ $(sed -n 's/^RESOLVED=//p' "$DIST/meta.env") == true ]] && echo true || echo false
}

write_notes() {
  local sha=$1 resolved=$2
  local app=zectrix-note4c-$TAG-firmware.bin merged=zectrix-note4c-$TAG-merged-firmware.bin
  local status="Patches applied cleanly. Not tested on hardware."
  [[ $resolved == true ]] && status="Conflicts with upstream resolved automatically by Claude. Not tested on hardware."
  cat >"$DIST/notes.md" <<NOTES
Unofficial community build of the TRMNL firmware for the Zectrix NOTE4C. Not affiliated with TRMNL or Zectrix.

$status

Built from upstream tag \`$TAG\` (https://github.com/$UPSTREAM_REPO/releases/tag/$TAG) plus the patches in this repository at commit \`$sha\`. That commit is the corresponding source. License: GPL-3.0.

Assets:
- \`$merged\`: complete flash image (bootloader, partition table, app). Write it at 0x0. Back up the full 16 MB flash first.
- \`$app\`: app image only. It sits at 0x20000 in the merged image. Do not write it at 0x0.
- \`SHA256SUMS\`: checksums of both files.

See the README for the flashing steps.
NOTES
}

cmd_assets() {
  local b=$FW/.pio/build/$PIO_ENV
  [[ -f $b/firmware.bin && -f $b/merged_firmware.bin ]] || die "build outputs missing in $b"
  mkdir -p "$DIST"
  local app=zectrix-note4c-$TAG-firmware.bin merged=zectrix-note4c-$TAG-merged-firmware.bin
  cp "$b/firmware.bin" "$DIST/$app"
  cp "$b/merged_firmware.bin" "$DIST/$merged"
  (cd "$DIST" && if command -v sha256sum >/dev/null; then sha256sum "$app" "$merged"; else shasum -a 256 "$app" "$merged"; fi >SHA256SUMS)
  echo "assets in $DIST"
}

# Publish job: commit the new series (if any) and create the release.
cmd_publish() {
  valid_ref "$TAG"
  local RESOLVED
  RESOLVED=$(meta_resolved)
  if [[ -d $DIST/patches ]]; then
    rm -f "$OURS"/patches/*.patch
    cp "$DIST"/patches/*.patch "$OURS/patches/"
    cp "$DIST/patches/BASE" "$OURS/patches/BASE"
    git -C "$OURS" add patches
    if ! git -C "$OURS" diff --cached --quiet; then
      local trailer=()
      [[ $RESOLVED == true ]] && trailer=(-m "Resolved-by: claude")
      git -C "$OURS" -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
        commit --quiet -m "Rebase NOTE4C patches on $TAG" ${trailer[@]+"${trailer[@]}"}
      local auth
      auth=$(printf 'x-access-token:%s' "${GH_TOKEN:?GH_TOKEN is not set}" | base64 | tr -d '\n')
      git -C "$OURS" -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" \
        push origin HEAD:main
    fi
  fi
  local sha
  sha=$(git -C "$OURS" rev-parse HEAD)
  write_notes "$sha" "$RESOLVED"
  local flags=()
  [[ $RESOLVED == true ]] && flags=(--prerelease)
  if release_exists "${TAG}-note4c"; then
    gh release delete "${TAG}-note4c" -R "$REPO" --cleanup-tag --yes
  fi
  gh release create "${TAG}-note4c" -R "$REPO" --target "$sha" \
    --title "NOTE4C $TAG" --notes-file "$DIST/notes.md" ${flags[@]+"${flags[@]}"} \
    "$DIST"/zectrix-note4c-"$TAG"-*.bin "$DIST/SHA256SUMS"
}

cmd_issue() {
  local t=${TAG:-unknown}
  local title="Build failed for $t"
  local url="${GITHUB_SERVER_URL:-https://github.com}/${REPO:?}/actions/runs/${RUN_ID:?}"
  local n
  n=$(gh issue list -R "$REPO" --state open --limit 200 --json number,title \
    --jq ".[] | select(.title == \"$title\") | .number" | head -n1)
  if [[ -n $n ]]; then
    gh issue comment "$n" -R "$REPO" --body "Failed again: $url"
  else
    gh issue create -R "$REPO" --title "$title" --body "Run: $url"
  fi
}

sub=${1:-}
shift || true
case "$sub" in
resolve | prepare | apply | applied | patches | build | amend | scan | assets | publish | issue)
  [[ $sub == resolve || $sub == issue ]] || { TAG=${TAG:?TAG is not set}; }
  "cmd_$sub" "$@"
  ;;
*) die "usage: build.sh resolve|prepare|apply|applied|patches|build|amend|scan|assets|publish|issue" ;;
esac
