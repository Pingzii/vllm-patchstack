#!/usr/bin/env bash
# Revert ONE task's manifest (reverse order).
#
#   bash revert_all.sh --root /path/to/vllm-ascend [--task <id>] [--only <repo>]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_DIR="$HERE/tasks"
ROOT=""; ONLY=""; TASK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --task) TASK="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$TASK" ]]; then
  found=()
  for d in "$TASKS_DIR"/*/; do [[ -d "$d" ]] && found+=("$(basename "$d")"); done
  if [[ ${#found[@]} -eq 1 ]]; then
    TASK="${found[0]}"
  else
    echo "multiple tasks present; pass --task <id>" >&2; exit 2
  fi
fi

TASK_DIR="$TASKS_DIR/$TASK"
MANIFEST="$TASK_DIR/manifest.tsv"
[[ -f "$MANIFEST" ]] || { echo "task '$TASK' has no manifest.tsv" >&2; exit 2; }
[[ -n "$ROOT" && -d "$ROOT" ]] || { echo "usage: $0 --root <repo-root> [--task <id>]" >&2; exit 2; }

echo "== revert task: $TASK"
mapfile -t LINES < "$MANIFEST"
for (( i=${#LINES[@]}-1; i>=0; i-- )); do
  IFS=$'\t' read -r repo kind path desc <<< "${LINES[$i]}"
  [[ -z "${repo//[[:space:]]/}" ]] && continue
  [[ "$repo" == \#* ]] && continue
  [[ -n "$ONLY" && "$repo" != "$ONLY" ]] && continue
  full="$TASK_DIR/$path"
  echo "== [revert][$repo] $kind $path"
  case "$kind" in
    patch)  git -C "$ROOT" apply -R "$full" || { echo "   !! reverse apply failed (already changed?)" >&2; } ;;
    script) python3 "$full" --root "$ROOT" --revert ;;
    *)      echo "   !! unknown kind: $kind" >&2 ;;
  esac
done
