#!/usr/bin/env bash
# 绿区一键：同步补丁栈 → 应用 → 运行实验 → 打印可外发结论 → （默认）还原工作区。
#
#   bash green_run.sh                 # 自动发现 vllm-ascend 检出
#   ROOT=/path/to/vllm-ascend bash green_run.sh
#   bash green_run.sh --keep          # 跑完保留补丁（手工继续调试）
#   bash green_run.sh --no-run        # 只同步 + 应用，不跑实验
#   bash green_run.sh --revert        # 只还原
#
# 合规：仅 git clone（只读流入）+ 本地文件改动 + 本地进程 + /tmp 写入。
set -euo pipefail

PATCHSTACK_URL="${PATCHSTACK_URL:-https://github.com/Pingzii/vllm-patchstack.git}"
PATCHSTACK="${PATCHSTACK:-/tmp/patchstack}"
OUT="${OUT:-/tmp/dsv4_mxfp_sweep}"
KEEP=0; NO_RUN=0; ONLY_REVERT=0; PS_SHA="?"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)   KEEP=1; shift ;;
    --no-run) NO_RUN=1; shift ;;
    --revert) ONLY_REVERT=1; shift ;;
    --root)   ROOT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

# --- 解析仓库根 ---
if [[ -z "${ROOT:-}" ]]; then
  if ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$ROOT" && -d "$ROOT/vllm_ascend" ]]; then
    :
  else
    for c in "$PWD" "$HOME/vllm-ascend" /home/*/AFD/vllm-ascend /home/*/vllm-ascend; do
      if [[ -d "$c/vllm_ascend" ]]; then ROOT="$c"; break; fi
    done
  fi
fi
[[ -n "${ROOT:-}" && -d "$ROOT/vllm_ascend" ]] || { echo "找不到 vllm-ascend 检出；用 ROOT=<路径> 指定" >&2; exit 2; }

sync_patchstack() {
  rm -rf "$PATCHSTACK"
  git clone --quiet --depth 1 "$PATCHSTACK_URL" "$PATCHSTACK"
  PS_SHA="$(git -C "$PATCHSTACK" rev-parse --short HEAD 2>/dev/null || echo '?')"
  rm -rf "$PATCHSTACK/.git"          # 绿区不留 git 状态
}

echo "== repo       : $(basename "$ROOT")"
echo "== repo HEAD  : $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"

if [[ $ONLY_REVERT -eq 1 ]]; then
  [[ -d "$PATCHSTACK" ]] || sync_patchstack
  bash "$PATCHSTACK/revert_all.sh" --root "$ROOT"
  rm -f "$ROOT/vllm_ascend/ops/fused_moe/token_dispatcher.py.bak"
  exit 0
fi

sync_patchstack
echo "== patchstack : $PS_SHA"

bash "$PATCHSTACK/apply_all.sh" --root "$ROOT"

mkdir -p "$OUT"
if [[ $NO_RUN -eq 0 && -f "$PATCHSTACK/debug/run.sh" ]]; then
  bash "$PATCHSTACK/debug/run.sh" || echo "[green_run] 实验脚本返回非零，见 $OUT" >&2
fi

REPORT="$OUT/report.txt"
echo
echo "==================== 可外发结论 ===================="
if [[ -f "$REPORT" ]]; then
  if ! grep -m1 '^FINGERPRINT:' "$REPORT"; then
    echo "(report 无 FINGERPRINT，给最后 5 行)"
    tail -5 "$REPORT"
  fi
else
  echo "(没有 $REPORT；检查 debug/run.sh 是否生成报告)"
fi
echo "==================================================="
echo "日志目录（勿外发）：$OUT"

if [[ $KEEP -eq 0 ]]; then
  bash "$PATCHSTACK/revert_all.sh" --root "$ROOT" >/dev/null
  rm -f "$ROOT/vllm_ascend/ops/fused_moe/token_dispatcher.py.bak"
  echo "[green_run] 工作区已还原（--keep 可保留补丁）"
else
  echo "[green_run] 已保留补丁；还原： bash $0 --revert"
fi
