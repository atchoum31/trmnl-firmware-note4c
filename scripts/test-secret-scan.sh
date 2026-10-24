#!/usr/bin/env bash
# Regression test for secret_scan.py: every planted encoding of a fake token
# must be caught, a clean input must pass, and a missing token must refuse.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCAN=$HERE/secret_scan.py
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-TESTtestTEST0123456789abcdefghij
tok=$CLAUDE_CODE_OAUTH_TOKEN
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

expect() {
  local want=$1 name=$2 rc=0
  shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq $want ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $rc, want $want"
    fail=1
  fi
}

diff_of() { printf '+++ b/x\n+%s\n' "$1"; }
# shellcheck disable=SC2317,SC2329 # called through expect
stdin_scan() { python3 -I "$SCAN" <<<"$1"; }

b64=$(printf '%s' "$tok" | base64 | tr -d '\n')
b64_offset=$(printf 'xy%s' "$tok" | base64 | tr -d '\n')
hex=$(printf '%s' "$tok" | od -An -tx1 | tr -d ' \n')
wrapped=$(printf '%s' "$tok" | base64 | tr -d '\n' | fold -w 20)

expect 0 "clean diff" stdin_scan "$(diff_of 'int x = 1;')"
expect 1 "diff, clear" stdin_scan "$(diff_of "$tok")"
expect 1 "diff, base64" stdin_scan "$(diff_of "$b64")"
expect 1 "diff, base64 at an offset" stdin_scan "$(diff_of "$b64_offset")"
expect 1 "diff, hex" stdin_scan "$(diff_of "$hex")"
expect 1 "diff, wrapped base64" stdin_scan "$wrapped"

mkdir -p "$tmp/tree/.ci" "$tmp/tree/src"
echo 'int x;' >"$tmp/tree/src/a.c"
expect 0 "clean tree" python3 -I "$SCAN" "$tmp/tree"
printf '%s' "$b64" >"$tmp/tree/.ci/hidden"
expect 1 "tree, base64 in an ignored file" python3 -I "$SCAN" "$tmp/tree"
rm "$tmp/tree/.ci/hidden"
printf '%s' "$hex" >"$tmp/tree/src/b.c"
expect 1 "tree, hex" python3 -I "$SCAN" "$tmp/tree"

expect 2 "empty token refuses" env CLAUDE_CODE_OAUTH_TOKEN= python3 -I "$SCAN" "$tmp/tree"

exit "$fail"
