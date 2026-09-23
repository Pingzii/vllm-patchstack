#!/usr/bin/env bash
# One-key green-zone entry point. Two equivalent usages:
#
#   A) piped  : curl -fsSL https://raw.githubusercontent.com/Pingzii/vllm-patchstack/main/scripts/onekey.sh | bash -s -- --task <id>
#   B) cloned : bash /tmp/patchstack/scripts/onekey.sh --task <id>
#
# It fetches the patch stack when it is not available locally, then delegates the
# whole loop (sync -> apply -> run -> report -> revert) to green_run.sh.
# All arguments are forwarded, e.g. --list, --dry-run, --keep, --revert.
set -euo pipefail

PATCHSTACK_URL="${PATCHSTACK_URL:-https://github.com/Pingzii/vllm-patchstack.git}"
PATCHSTACK="${PATCHSTACK:-/tmp/patchstack}"
SELF="${BASH_SOURCE[0]:-}"
HERE=""
if [[ -n "$SELF" && -f "$SELF" ]]; then
  HERE="$(cd "$(dirname "$SELF")" && pwd)"
fi

if [[ -n "$HERE" && -f "$HERE/green_run.sh" ]]; then
  exec bash "$HERE/green_run.sh" "$@"
fi

echo "[onekey] local runner not found; fetching patch stack"
rm -rf "$PATCHSTACK"
git clone --quiet --depth 1 "$PATCHSTACK_URL" "$PATCHSTACK"
rm -rf "$PATCHSTACK/.git"
exec bash "$PATCHSTACK/scripts/green_run.sh" "$@"
