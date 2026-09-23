#!/usr/bin/env bash
# 逆序回退 manifest.tsv 里的所有改动。
#   bash revert_all.sh --root /path/to/vllm-ascend
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=""; ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$ROOT" && -d "$ROOT" ]] || { echo "用法: $0 --root <repo-root> [--only <repo>]" >&2; exit 2; }

MANIFEST="$HERE/manifest.tsv"
[[ -f "$MANIFEST" ]] || { echo "缺 manifest.tsv" >&2; exit 2; }

mapfile -t LINES < "$MANIFEST"
for (( i=${#LINES[@]}-1; i>=0; i-- )); do
  IFS=$'\t' read -r repo kind path desc <<< "${LINES[$i]}"
  [[ -z "${repo//[[:space:]]/}" ]] && continue
  [[ "$repo" == \#* ]] && continue
  [[ -n "$ONLY" && "$repo" != "$ONLY" ]] && continue
  full="$HERE/$path"
  echo "== [revert][$repo] $kind $path"
  case "$kind" in
    patch)  git -C "$ROOT" apply -R "$full" || { echo "   !! 反打失败（可能已被改过）" >&2; } ;;
    script) python3 "$full" --root "$ROOT" --revert ;;
    *)      echo "   !! 未知 kind: $kind" >&2 ;;
  esac
done
