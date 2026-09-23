#!/usr/bin/env bash
# DSv4-Flash W4A8MXFP —— AllToAll routing 入参变体扫描（一次性 runbook）
#
# 合规说明：本脚本**不做任何 git / 网络操作**（只读地 apply 本地补丁、本地起服务、
#           本地写 /tmp 日志），可以在绿区执行。回传内容只保留结论行，并做基础脱敏。
#
# 用法：
#   SERVE=/path/serve_8card.sh bash run_matrix.sh   # 扫 A~E，生成脱敏后的 report.txt
#   bash run_matrix.sh --revert                     # 只还原代码（用 .bak）
#   VARIANTS="A B" OUT=/tmp/sweep bash run_matrix.sh
#
# 依赖：与 serve 脚本同机的 python3（执行 apply_mxfp_variants.py）
set -euo pipefail

ROOT="${ROOT:-/home/s00988495/AFD/vllm-ascend}"
SERVE="${SERVE:-$(pwd)/serve_8card.sh}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-/tmp/dsv4_mxfp_sweep}"
VARIANTS="${VARIANTS:-A B C D E}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-900}"   # 单变体最多等多久（秒）
SETTLE="${SETTLE:-20}"                     # 两次之间留给 NPU 回收的时间（秒）

APPLIER="$HERE/apply_mxfp_variants.py"

[[ -f "$SERVE"  ]] || { echo "serve 脚本不存在：$SERVE（用 SERVE=... 指定）" >&2; exit 2; }
[[ -f "$APPLIER" ]] || { echo "找不到 $APPLIER" >&2; exit 2; }

if [[ "${1:-}" == "--revert" ]]; then
  python3 "$APPLIER" --root "$ROOT" --revert
  exit 0
fi

mkdir -p "$OUT"
echo "[sweep] ROOT=$ROOT"
echo "[sweep] SERVE=$SERVE"
echo "[sweep] OUT=$OUT"

python3 "$APPLIER" --root "$ROOT"

for V in $VARIANTS; do
  log="$OUT/8card_$V.log"
  echo "===== variant $V -> $log"

  # 后台起服务：出现"启动成功"或"目标报错"就提前结束，不等满超时
  DSV4_MXFP_VARIANT="$V" bash "$SERVE" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 "$STARTUP_TIMEOUT"); do
    if grep -qE "Application startup complete|MoeInitRoutingV3|EngineCore failed to start|Worker failed with error" "$log"; then
      break
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  grep -m2 -E "variant=$V|Application startup complete|MoeInitRoutingV3" "$log" || true
  sleep "$SETTLE"   # 等 NPU 侧资源回收；若发现残留进程，可在两次之间加 pkill -f "vllm serve"
done

report="$OUT/report.txt"

# 基础脱敏：绝对用户路径与 IP 不外传（回传前请再按贵方规定复核一遍）
sanitize() {
  sed -E 's#/home/[^/ ]+#/home/<user>#g;
          s#/mnt/[^/ ]+#/mnt/<path>#g;
          s#/data/[^/ ]+#/data/<path>#g;
          s#([0-9]{1,3}\.){3}[0-9]{1,3}#<ip>#g'
}

{
  echo "### DSv4 MXFP A2A routing sweep  ($(date -Is))"
  echo "repo=$(basename "$ROOT")  serve=$(basename "$SERVE")"
  for V in $VARIANTS; do
    log="$OUT/8card_$V.log"
    printf '\n--- variant %s ---\n' "$V"
    if [[ ! -f "$log" ]]; then echo "RESULT: no-log"; continue; fi
    if grep -q "Application startup complete" "$log"; then
      echo "RESULT: startup-ok"
    elif grep -q "MoeInitRoutingV3" "$log"; then
      echo "RESULT: MoeInitRoutingV3-fail"
      grep -m1 -E "Reason: .*OpDef|Cannot find binary" "$log" || true
    else
      echo "RESULT: other-failure"
      grep -m3 -E "ERROR|Traceback" "$log" || tail -5 "$log"
    fi
    grep -m1 "variant=$V" "$log" || true
  done

  # 极简指纹：外发只需这一行（信息量最小）
  printf 'FINGERPRINT:'
  for V in $VARIANTS; do
    log="$OUT/8card_$V.log"
    if   [[ -f "$log" ]] && grep -q "Application startup complete" "$log"; then printf ' %s=ok' "$V"
    elif [[ -f "$log" ]] && grep -q "MoeInitRoutingV3" "$log";           then printf ' %s=route_fail' "$V"
    else printf ' %s=other' "$V"; fi
  done
  printf '\n'
} | sanitize | tee "$report"

echo
echo "[sweep] 把 $report 整个贴回来即可（一条命令的输出，够我定位）"
echo "[sweep] 回退代码： bash $0 --revert"
