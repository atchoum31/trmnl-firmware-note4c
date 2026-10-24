#!/usr/bin/env bash
# The only script that sees CLAUDE_CODE_OAUTH_TOKEN.
# Usage: claude.sh resolve|fix
# Runs Claude in $FW, then scans the whole diff against $TAG for the token.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FW=${FW:?FW is not set}
MODE=${1:?usage: claude.sh resolve|fix}
MODEL=${CLAUDE_MODEL:-claude-opus-5-5}

: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN is not set}"
unset ANTHROPIC_API_KEY

case "$MODE" in
resolve)
  template=$(<"$HERE/prompt-resolve.md")
  patch=$(<"$FW/.ci/patch-name")
  files=$(sed 's/^/- /' "$FW/.ci/conflicts.txt")
  prompt=${template//\{\{PATCH\}\}/$patch}
  prompt=${prompt//\{\{FILES\}\}/$files}
  ;;
fix)
  template=$(<"$HERE/prompt-fix.md")
  prompt=${template//\{\{LOG\}\}/.ci/build-tail.log}
  ;;
*)
  echo "unknown mode: $MODE" >&2
  exit 2
  ;;
esac

scan() {
  "$HERE/build.sh" scan
}

# Claude runs in a throwaway container that sees only the checkout (/work) and
# the hardware docs (/docs, read-only), so it cannot leave files elsewhere on
# the runner. Its output stays in the container: the job log is public and
# GitHub masks the token only in clear text.
OURS=${OURS:-$(cd "$HERE/.." && pwd)}
CLAUDE_VERSION=${CLAUDE_VERSION:-2.1.309}
rc=0
PROMPT=$prompt docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e CLAUDE_CODE_OAUTH_TOKEN -e PROMPT -e MODEL="$MODEL" -e HOME=/tmp/home \
  -v "$FW:/work" -v "$OURS/docs/hardware:/docs:ro" -w /work \
  node:22-bookworm bash -c '
    git config --global --add safe.directory /work
    npm install --silent --prefix /tmp/npm "@anthropic-ai/claude-code@'"$CLAUDE_VERSION"'" >/dev/null 2>&1 || exit 3
    /tmp/npm/node_modules/.bin/claude -p "$PROMPT" \
      --model "$MODEL" \
      --max-turns 40 \
      --permission-mode dontAsk \
      --allowedTools "Read,Edit,Write,Glob,Grep,Bash(git diff *),Bash(git status *),Bash(git log *),Bash(git show *)" \
      --disallowedTools "WebFetch,WebSearch,mcp__*,Bash(git push *),Bash(git remote *),Bash(git config *),Bash(curl *),Bash(wget *)"
  ' >/dev/null 2>&1 || rc=$?
echo "claude exited with code $rc"

scan || exit 1
exit "$rc"
