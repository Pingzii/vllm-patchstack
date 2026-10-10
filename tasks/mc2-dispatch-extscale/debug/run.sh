#!/usr/bin/env bash
# mc2-dispatch-extscale -- green-zone entry point.
#
#   bash run.sh                 # MC2 group (4 variants) + routing group (4 variants)
#   bash run.sh --dry-run       # show the plan, change nothing
#   bash run.sh --revert        # no-op (this probe patches nothing), kept for contract
#   NPUS=4 bash run.sh          # force a smaller EP world size
#   OUT=/tmp/foo bash run.sh    # custom output directory
#
# Compliance: read-only.  Touches no framework checkout, does no git write and no
# network write.  Everything it produces lives under $OUT (default /tmp/...).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_ID="mc2-dispatch-extscale"
OUT="${OUT:-/tmp/mc2_dispatch_extscale}"
PROBE="$HERE/probe.py"
WAIT_SECS="${WAIT_SECS:-900}"

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --revert)  echo "[$TASK_ID] nothing to revert (probe patches nothing)"; exit 0 ;;
    --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------------ probe ----
if ! command -v python3 >/dev/null 2>&1; then
  echo "[$TASK_ID] FATAL: python3 not found" >&2; exit 2
fi

if ! python3 -c 'import torch, torch_npu' >/dev/null 2>&1; then
  echo "[$TASK_ID] FATAL: torch_npu is not importable in this python3" >&2
  exit 2
fi

NPUS="${NPUS:-}"
if [[ -z "$NPUS" ]]; then
  if [[ -n "${ASCEND_RT_VISIBLE_DEVICES:-}" ]]; then
    IFS=',' read -r -a _v <<< "$ASCEND_RT_VISIBLE_DEVICES"; NPUS=${#_v[@]}
  else
    NPUS="$(ls -d /dev/davinci[0-9]* 2>/dev/null | wc -l | tr -d ' ')"
  fi
fi
case "$NPUS" in
  ''|*[!0-9]*) NPUS=8 ;;
esac
if [[ "$NPUS" -lt 2 ]]; then NPUS=8; fi

PORT="${PORT:-$(( 20000 + (RANDOM % 20000) ))}"

echo "== $TASK_ID =="
echo "probe   : $PROBE"
echo "out     : $OUT"
echo "npus    : $NPUS   (EP world size)"
echo "master  : 127.0.0.1:$PORT"
echo "python  : $(python3 -c 'import sys;print(sys.version.split()[0])' 2>/dev/null || echo '?')"
echo "torch   : $(python3 -c 'import torch;print(torch.__version__)' 2>/dev/null || echo '?')"
echo "torch_npu: $(python3 -c 'import torch_npu;print(torch_npu.__version__)' 2>/dev/null || echo '?')"
echo

if [[ "$DRY" == "1" ]]; then
  echo "dry-run: would launch $NPUS processes of probe.py, then probe_routing.py as a"
  echo "          separate single-card process on device 0."
  echo
  echo "group MC2 (cross-card, needs HCCL) -- does the EP dispatch carry an"
  echo "          already quantized fp8 activation plus an external e8m0 scale?"
  echo "  A  x=bf16 quant_mode=0 scales=None             (control)"
  echo "  B  x=fp8  quant_mode=0 scales=None             (gate: fp8 input in THIS build)"
  echo "  C  x=fp8  quant_mode=0 scales=e8m0 [BS,H/32]"
  echo "  D  x=fp8  quant_mode=0 scales=e8m0 [BS,H/64,2]"
  echo "  (no quant_mode=4 variant: the CANN README settles it, so it costs no runtime)"
  echo
  echo "group ROUT (single card) -- docs say MoeInitRoutingV3 accepts"
  echo "          fp8 + e8m0 for quantMode=-1, but A5 field logs show it failing:"
  echo "  R1 x=bf16 scale=None                           (control)"
  echo "  R2 x=fp8  scale=e8m0 (N,H/64,2) x_dtype=fp8    (reproduces the field record)"
  echo "  R3 x=fp8  scale=e8m0 (N,H/64,2) no x_dtype"
  echo "  R4 x=fp8  scale=e8m0 (N,H/64,2) quant_mode=-1"
  exit 0
fi

rm -rf "$OUT"; mkdir -p "$OUT"

export MASTER_ADDR=127.0.0.1
export MASTER_PORT="$PORT"
export WORLD_SIZE="$NPUS"
export OUT
# HCCL_BUFFSIZE is deliberately NOT overridden: the requirement for this tiny
# payload (BS=8, H=1024, EP=8) is about 1.4 MB, well under the 200 MB default,
# and overriding it could clash with the cluster's own configuration.
export HCCL_IF_BASE_PORT="${HCCL_IF_BASE_PORT:-$(( 30000 + (RANDOM % 20000) ))}"

pids=()
for ((r=0; r<NPUS; r++)); do
  RANK="$r" LOCAL_RANK="$r" \
    python3 "$PROBE" --out "$OUT" > "$OUT/rank_$r.log" 2>&1 &
  pids+=("$!")
done

# Bound every child so a rank stuck inside a collective cannot hang the run.
( sleep "$WAIT_SECS"
  for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && kill -TERM "$p" 2>/dev/null; done
) &
WATCHDOG=$!

rc_all=0
for ((r=0; r<NPUS; r++)); do
  wait "${pids[$r]}"
  rc=$?
  if [[ "$rc" -ne 0 && "$rc_all" -eq 0 ]]; then rc_all=$rc; fi
done
kill "$WATCHDOG" 2>/dev/null || true
wait "$WATCHDOG" 2>/dev/null || true

# ----------------------------------------------------------- routing group ---
# MoeInitRouting is a single-card reorder operator: it needs no process group,
# so it runs here, after every rank has exited.  It is independent of the MC2
# group -- if the HCCL harness failed above, this group still says something.
rout_rc=0
python3 "$HERE/probe_routing.py" --out "$OUT" > "$OUT/routing.log" 2>&1 || rout_rc=$?
echo "[$TASK_ID] routing group rc=$rout_rc  (log: $OUT/routing.log)"

# --------------------------------------------------------------- aggregate ---
agg_rc=0
python3 - "$OUT" "$TASK_ID" "$NPUS" <<'PY' || agg_rc=$?
import json, sys, glob, os
from pathlib import Path

out_dir, task_id, world = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
MC2 = ["A", "B", "C", "D"]
ROUT = ["R1", "R2", "R3", "R4"]
VARIANTS = MC2  # the cross-card group keeps the existing per-rank logic

files = sorted(glob.glob(str(out_dir / "rank_*.json")))
ranks = {}
for f in files:
    try:
        d = json.loads(Path(f).read_text(encoding="utf-8"))
        ranks[int(d.get("rank", -1))] = d
    except Exception:
        pass

env_ok = int(bool(ranks) and all(d.get("env_ok") for d in ranks.values()) and len(ranks) == world)

# A variant passes only if every rank that reported it succeeded.
flags = {}
for v in VARIANTS:
    seen = [d.get("variants", {}).get(v) for d in ranks.values()]
    seen = [s for s in seen if s is not None]
    flags[v] = int(len(seen) == world and len(seen) > 0 and all(s.get("ok") for s in seen))

# Which variant, if any, returned a non-empty dynamic_scale?
scale_from = [v for v in VARIANTS
              if flags[v] and any((ranks[r].get("variants", {}).get(v, {}) or {}).get("dynamic_scale_present")
                                  for r in ranks)]

# First error per failing variant, for the human-readable report (never for egress).
errors = {}
for v in VARIANTS:
    if flags[v]:
        continue
    for r in sorted(ranks):
        e = (ranks[r].get("variants", {}).get(v) or {}).get("error")
        if e:
            errors[v] = f"rank {r}: {e}"
            break
    else:
        fatal = next((d.get("fatal") or d.get("barrier_failure") for d in ranks.values()
                      if d.get("fatal") or d.get("barrier_failure")), None)
        if fatal:
            errors[v] = fatal

# ---- routing group: one process, one json, independent of the ranks --------
rout = {}
try:
    rout = json.loads((out_dir / "routing.json").read_text(encoding="utf-8"))
except Exception:
    rout = {}
rout_env = int(bool(rout.get("env_ok")))
for v in ROUT:
    entry = (rout.get("variants") or {}).get(v)
    flags[v] = int(rout_env and bool(entry) and bool(entry.get("ok")))
    if rout_env and entry and not entry.get("ok"):
        errors[v] = entry.get("error", "failed")
rscale_from = [v for v in ROUT
               if flags[v] and (rout["variants"][v] or {}).get("expanded_scale_present")]

lines = []
lines.append(f"task            : {task_id}")
lines.append(f"ranks reported  : {len(ranks)}/{world}")
lines.append(f"env_ok (mc2)    : {env_ok}")
for v in MC2:
    lines.append(f"  variant {v}   : {'PASS' if flags[v] else 'FAIL'}"
                 + (f"   ({errors[v]})" if v in errors else ""))
lines.append(f"  dynamic_scale from: {scale_from or 'none'}")
lines.append(f"env_ok (routing): {rout_env}   binding={rout.get('binding', 'n/a')}")
if rout.get("bindings"):
    lines.append(f"  bindings found: {', '.join(rout['bindings'])}")
for v in ROUT:
    lines.append(f"  variant {v}   : {'PASS' if flags[v] else 'FAIL'}"
                 + (f"   ({errors[v]})" if v in errors else ""))
lines.append(f"  expanded_scale from: {rscale_from or 'none'}")

if env_ok and (flags["C"] or flags["D"]):
    mc2_verdict = ("SUPPORTED -- the EP dispatch accepts an already quantized fp8 "
                   "activation plus an external e8m0 scale")
elif env_ok and flags["B"] and not (flags["C"] or flags["D"]):
    mc2_verdict = ("PARTIAL -- fp8 input is accepted, but an external scale is not "
                   "carried; the CANN interface has to be extended")
elif env_ok and not flags["B"]:
    mc2_verdict = ("NOT SUPPORTED -- fp8 activation input is rejected outright, which "
                   "contradicts the CANN README for this build")
elif not env_ok:
    mc2_verdict = "VOID -- the harness did not come up; the run answers nothing"
else:
    mc2_verdict = "INCONCLUSIVE -- see the per-variant errors"
lines.append(f"mc2 verdict     : {mc2_verdict}")

if not rout_env:
    rout_verdict = "VOID -- no routing binding found, or the single-card harness failed"
elif flags["R1"] and (flags["R3"] or flags["R4"]):
    rout_verdict = ("SUPPORTED -- routing permutes fp8 + e8m0 and returns the "
                    "reordered scale, matching the README")
elif flags["R1"] and not (flags["R2"] or flags["R3"] or flags["R4"]):
    rout_verdict = ("NOT SUPPORTED on this build -- the README documents this "
                    "combination, but the runtime rejects it")
elif flags["R1"] and flags["R2"] and not (flags["R3"] or flags["R4"]):
    rout_verdict = ("PARTIAL -- only the verbatim field call works; check the dropped "
                    "kwargs in routing.json")
else:
    rout_verdict = "INCONCLUSIVE -- see the per-variant errors"
lines.append(f"routing verdict : {rout_verdict}")

report = "\n".join(lines)
(out_dir / "report.txt").write_text(report + "\n", encoding="utf-8")

print()
print("=" * 72)
print(report)
print("=" * 72)

fp = " ".join([f"{v}{flags[v]}" for v in MC2] + [f"{v}_{flags[v]}" for v in ROUT])
print()
print(f"FINGERPRINT {task_id}: {fp}")
if scale_from:
    print(f"(non-empty dynamic_scale came back from: {','.join(scale_from)})")
if rscale_from:
    print(f"(non-empty expanded_scale came back from: {','.join(rscale_from)})")
print()
print("SEND THIS ONE LINE >>> " + f"{task_id} {fp}")
first = next((f"variant {v}: {errors[v]}" for v in MC2 + ROUT if v in errors), "")
if first:
    print("first error >>> " + first)
elif not env_ok and not rout_env:
    fatal = next((d.get("fatal") for d in ranks.values() if d.get("fatal")), None) \
        or rout.get("fatal", "no rank reported")
    print("first error >>> " + str(fatal)[:300])
PY

echo
echo "artifacts: $OUT/report.txt , $OUT/rank_*.json , $OUT/rank_*.log"

# Exit 0 whenever the aggregation produced a report: this task applies NO patch,
# so a non-zero exit must not be read as "the patch failed to apply".  A non-zero
# from a probe rank is reflected in the FINGERPRINT line, not in the exit code.
if [[ "$agg_rc" -eq 0 && -f "$OUT/report.txt" ]]; then
  exit 0
fi
echo "[$TASK_ID] aggregation failed (rc=$agg_rc)" >&2
exit 1
