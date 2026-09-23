#!/usr/bin/env bash
# 按 manifest.tsv 把补丁栈应用到某个仓库树。
#   bash apply_all.sh --root /path/to/vllm-ascend
#   bash apply_all.sh --root /path/to/vllm-ascend --only vllm-ascend
# 说明：patch 走 git apply --check（对不上就报错跳过），script 走自身的锚点校验。
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

fail=0
while IFS=$'\t' read -r repo kind path desc; do
  [[ -z "${repo//[[:space:]]/}" ]] && continue
  [[ "$repo" == \#* ]] && continue
  [[ -n "$ONLY" && "$repo" != "$ONLY" ]] && continue
  full="$HERE/$path"
  echo "== [$repo] $kind $path -- ${desc:-}"
  case "$kind" in
    patch)
      if git -C "$ROOT" apply --check "$full" 2>/dev/null; then
        git -C "$ROOT" apply "$full"; echo "   applied"
      else
        echo "   !! 锚点不匹配（base 版本可能已变，需要 rebase）" >&2; fail=1
      fi ;;
    script)
      python3 "$full" --root "$ROOT" ;;
    *)
      echo "   !! 未知 kind: $kind" >&2; fail=1 ;;
  esac
done < "$MANIFEST"

exit $fail
