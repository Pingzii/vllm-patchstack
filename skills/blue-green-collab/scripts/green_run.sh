#!/usr/bin/env bash
# Green zone: sync patch stack -> apply one task -> run -> print the reportable line -> revert.
#
#   bash green_run.sh                      # auto-detect repo root and task (if only one)
#   bash green_run.sh --task <id>          # pick a specific task
#   ROOT=/path/to/vllm-ascend bash green_run.sh
#   bash green_run.sh --keep               # keep the patch applied afterwards
#   bash green_run.sh --no-run             # sync + apply only
#   bash green_run.sh --revert             # revert only
#   bash green_run.sh --list               # list tasks in the patch stack
#
# Compliance: clone/fetch (read-only inflow) + local file edits + local processes + /tmp only.
set -euo pipefail

PATCHSTACK_URL="${PATCHSTACK_URL:-https://github.com/Pingzii/vllm-patchstack.git}"
PATCHSTACK="${PATCHSTACK:-/tmp/patchstack}"
OUT_BASE="${OUT:-/tmp/dsv4_mxfp_sweep}"
KEEP=0; NO_RUN=0; ONLY_REVERT=0; PS_SHA="?"; TASK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)   KEEP=1; shift ;;
    --no-run) NO_RUN=1; shift ;;
    --revert) ONLY_REVERT=1; shift ;;
    --task)   TASK="${2:-}"; shift 2 ;;
    --root)   ROOT="${2:-}"; shift 2 ;;
    --list)
      [[ -d "$PATCHSTACK/tasks" ]] || { mkdir -p "$PATCHSTACK"; rm -rf "$PATCHSTACK"; git clone --quiet --depth 1 "$PATCHSTACK_URL" "$PATCHSTACK"; rm -rf "$PATCHSTACK/.git"; }
      echo "available tasks:"; for d in "$PATCHSTACK"/tasks/*/; do [[ -d "$d" ]] && printf '  %s\n' "$(basename "$d")"; done
      exit 0 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- framework repo root ---
if [[ -z "${ROOT:-}" ]]; then
  if ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$ROOT" && -d "$ROOT/vllm_ascend" ]]; then
    :
  else
    for c in "$PWD" "$HOME/vllm-ascend" /home/*/AFD/vllm-ascend /home/*/vllm-ascend; do
      if [[ -d "$c/vllm_ascend" ]]; then ROOT="$c"; break; fi
    done
  fi
fi
[[ -n "${ROOT:-}" && -d "$ROOT/vllm_ascend" ]] || { echo "vllm-ascend checkout not found; pass ROOT=<path>" >&2; exit 2; }

sync_patchstack() {
  rm -rf "$PATCHSTACK"
  git clone --quiet --depth 1 "$PATCHSTACK_URL" "$PATCHSTACK"
  PS_SHA="$(git -C "$PATCHSTACK" rev-parse --short HEAD 2>/dev/null || echo '?')"
  rm -rf "$PATCHSTACK/.git"          # leave no git state in the green zone
}

resolve_task() {
  if [[ -n "$TASK" ]]; then return 0; fi
  local found=() d
  for d in "$PATCHSTACK"/tasks/*/; do [[ -d "$d" ]] && found+=("$(basename "$d")"); done
  if [[ ${#found[@]} -eq 1 ]]; then
    TASK="${found[0]}"
  else
    echo "multiple tasks; pass --task <id>:" >&2
    for d in "${found[@]}"; do printf '  %s\n' "$d" >&2; done
    exit 2
  fi
}

echo "== repo       : $(basename "$ROOT")"
echo "== repo HEAD  : $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"

if [[ $ONLY_REVERT -eq 1 ]]; then
  [[ -d "$PATCHSTACK/tasks" ]] || sync_patchstack
  resolve_task
  bash "$PATCHSTACK/revert_all.sh" --root "$ROOT" --task "$TASK"
  rm -f "$ROOT/vllm_ascend/ops/fused_moe/token_dispatcher.py.bak"
  exit 0
fi

sync_patchstack
resolve_task
OUT="$OUT_BASE/$TASK"
echo "== patchstack : $PS_SHA"
echo "== task       : $TASK"

bash "$PATCHSTACK/apply_all.sh" --root "$ROOT" --task "$TASK"

mkdir -p "$OUT"
if [[ $NO_RUN -eq 0 && -f "$PATCHSTACK/tasks/$TASK/debug/run.sh" ]]; then
  bash "$PATCHSTACK/tasks/$TASK/debug/run.sh" || echo "[green_run] experiment returned non-zero, see $OUT" >&2
fi

REPORT="$OUT/report.txt"
echo
echo "==================== reportable result ===================="
if [[ -f "$REPORT" ]]; then
  line="$(grep -m1 '^FINGERPRINT:' "$REPORT" || true)"
  if [[ -n "$line" ]]; then
    echo "${line/FINGERPRINT:/FINGERPRINT $TASK:}"
  else
    echo "(no FINGERPRINT in report; last 5 lines)"
    tail -5 "$REPORT"
  fi
else
  echo "(no $REPORT; check tasks/$TASK/debug/run.sh)"
fi
echo "=========================================================="
echo "logs (do not export): $OUT"

if [[ $KEEP -eq 0 ]]; then
  bash "$PATCHSTACK/revert_all.sh" --root "$ROOT" --task "$TASK" >/dev/null
  rm -f "$ROOT/vllm_ascend/ops/fused_moe/token_dispatcher.py.bak"
  echo "[green_run] worktree restored (use --keep to keep the patch)"
else
  echo "[green_run] patch kept; revert with: bash $0 --revert"
fi
