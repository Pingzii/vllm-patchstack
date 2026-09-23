#!/usr/bin/env bash
# Apply ONE task's manifest onto a framework checkout.
#
#   bash apply_all.sh --root /path/to/vllm-ascend [--task <id>] [--only <repo>]
#   bash apply_all.sh --list
#
# Tasks live in tasks/<id>/ (own manifest.tsv, patches/, debug/). With exactly one
# task present, --task may be omitted; with several, it is required.
# patch entries are validated with `git apply --check`; script entries self-check anchors.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_DIR="$HERE/tasks"
ROOT=""; ONLY=""; TASK=""

list_tasks() {
  local d
  for d in "$TASKS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    printf '  %s\n' "$(basename "$d")"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)  ROOT="${2:-}"; shift 2 ;;
    --only)  ONLY="${2:-}"; shift 2 ;;
    --task)  TASK="${2:-}"; shift 2 ;;
    --list)  echo "available tasks:"; list_tasks; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$TASK" ]]; then
  found=()
  for d in "$TASKS_DIR"/*/; do [[ -d "$d" ]] && found+=("$(basename "$d")"); done
  if [[ ${#found[@]} -eq 1 ]]; then
    TASK="${found[0]}"
  else
    echo "multiple tasks present; pass --task <id>:" >&2; list_tasks >&2; exit 2
  fi
fi

TASK_DIR="$TASKS_DIR/$TASK"
MANIFEST="$TASK_DIR/manifest.tsv"
[[ -f "$MANIFEST" ]] || { echo "task '$TASK' has no manifest.tsv ($MANIFEST)" >&2; exit 2; }
[[ -n "$ROOT" && -d "$ROOT" ]] || { echo "usage: $0 --root <repo-root> [--task <id>] [--only <repo>]" >&2; exit 2; }

echo "== task: $TASK"
fail=0
while IFS=$'\t' read -r repo kind path desc; do
  [[ -z "${repo//[[:space:]]/}" ]] && continue
  [[ "$repo" == \#* ]] && continue
  [[ -n "$ONLY" && "$repo" != "$ONLY" ]] && continue
  full="$TASK_DIR/$path"
  echo "== [$repo] $kind $path -- ${desc:-}"
  case "$kind" in
    patch)
      if git -C "$ROOT" apply --check "$full" 2>/dev/null; then
        git -C "$ROOT" apply "$full"; echo "   applied"
      else
        echo "   !! anchor mismatch (rebase the patch on the blue side)" >&2; fail=1
      fi ;;
    script)
      python3 "$full" --root "$ROOT" ;;
    *)
      echo "   !! unknown kind: $kind" >&2; fail=1 ;;
  esac
done < "$MANIFEST"

exit $fail
