#!/usr/bin/env bash
# 绿区的唯一入口。内容随 git 更新，**命令本身永远不变**——所以绿区只需要记住一个词。
#
#   bash dsv4-mxfp-debug/run.sh              # 扫 A~E，结论在 /tmp/dsv4_mxfp_sweep/report.txt
#   bash dsv4-mxfp-debug/run.sh --revert     # 还原本地补丁
#   SERVE=/path/serve_8card.sh bash ...      # 需要时手动指定 serve 脚本
#
# 合规：本脚本不含任何 git 写 / 网络写操作（只读地改本地文件、起停本地进程、写 /tmp）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$HERE/.." && pwd)}"
OUT="${OUT:-/tmp/dsv4_mxfp_sweep}"
mkdir -p "$OUT"

# serve 脚本自动发现：省掉每次敲路径这个"变量"
if [[ -z "${SERVE:-}" ]]; then
  for c in \
    "$ROOT/../mix/serve_8card.sh" \
    /home/*/AFD/mix/serve_8card.sh \
    /home/*/*/serve_8card.sh \
    "$HOME/mix/serve_8card.sh" \
    "$ROOT/serve_8card.sh" ; do
    if [[ -f $c ]]; then SERVE="$c"; break; fi
  done
fi
if [[ -z "${SERVE:-}" || ! -f "${SERVE:-}" ]]; then
  echo "找不到 serve_8card.sh；请用：SERVE=/path/to/serve_8card.sh bash $0" >&2
  exit 2
fi

{
  echo "== dsv4 run =="
  echo "repo : $(basename "$ROOT")"
  echo "serve: $(basename "$SERVE")"
  echo "head : $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
} | tee "$OUT/run_header.txt"
echo

SERVE="$SERVE" ROOT="$ROOT" OUT="$OUT" bash "$HERE/run_matrix.sh" "$@"
