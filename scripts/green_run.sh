#!/usr/bin/env bash
# Green zone: one key. sync patch stack -> apply one task -> run -> print the
# reportable line -> (default) revert. Nothing else to type.
#
#   bash green_run.sh                      # auto-detect repo root and task
#   bash green_run.sh --task <id>          # pick a task (required when several exist)
#   bash green_run.sh --list               # list tasks
#   bash green_run.sh --dry-run            # show the plan, change nothing
#   bash green_run.sh --keep               # keep the patch applied afterwards
#   bash green_run.sh --no-run             # sync + apply only
#   bash green_run.sh --revert             # revert only
#   ROOT=/path/to/vllm-ascend bash green_run.sh
#
# Compliance: clone/fetch (read-only inflow) + local file edits + local processes + /tmp only.
set -euo pipefail

PATCHSTACK_URL="${PATCHSTACK_URL:-https://github.com/Pingzii/vllm-patchstack.git}"
PATCHSTACK="${PATCHSTACK:-/tmp/patchstack}"
OUT_BASE="${OUT:-/tmp/dsv4_mxfp_sweep}"
KEEP=0; NO_RUN=0; ONLY_REVERT=0; DRY_RUN=0; PS_SHA="?"; TASK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)    KEEP=1; shift ;;
    --no-run)  NO_RUN=1; shift ;;
    --revert)  ONLY_REVERT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --task)    TASK="${2:-}"; shift 2 ;;
    --root)    ROOT="${2:-}"; shift 2 ;;
    --list)    LIST_ONLY=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
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

list_tasks() {
  local d
  for d in "$PATCHSTACK"/tasks/*/; do
    [[ -d "$d" ]] && printf '  %s\n' "$(basename "$d")"
  done
}

resolve_task() {
  [[ -n "$TASK" ]] && return 0
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

preflight() {
  command -v python3 >/dev/null 2>&1 || echo "[warn] python3 not found; script-kind entries will fail" >&2
  if command -v pgrep >/dev/null 2>&1 && pgrep -f "vllm serve" >/dev/null 2>&1; then
    echo "[warn] a 'vllm serve' process is running; it may hold the NPUs" >&2
  fi
}

echo "== repo       : $(basename "$ROOT")"
echo "== repo HEAD  : $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"

if [[ $ONLY_REVERT -eq 1 ]]; then
  [[ -d "$PATCHSTACK/tasks" ]] || sync_patchstack
  resolve_task
  bash "$PATCHSTACK/revert_all.sh" --root "$ROOT" --task "$TASK"
  rm -f "$ROOT/vllm_ascend/ops/fused_moe/token_dispatcher.py.bak"
  echo "[green_run] reverted task $TASK"
  exit 0
fi

sync_patchstack
if [[ "${LIST_ONLY:-0}" == "1" ]]; then
  echo "== patchstack : $PS_SHA"
  echo "available tasks:"; list_tasks
  exit 0
fi
resolve_task
OUT="$OUT_BASE/$TASK"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "== patchstack : $PS_SHA"
  echo "== task       : $TASK"
  echo "[dry-run] nothing will be changed. Plan:"
  echo "  1. apply  : tasks/$TASK/manifest.tsv"
  while IFS=$'\t' read -r repo kind path desc; do
    [[ -z "${repo//[[:space:]]/}" || "$repo" == \#* ]] && continue
    echo "       - [$repo] $kind $path"
  done < "$PATCHSTACK/tasks/$TASK/manifest.tsv"
  echo "  2. run    : tasks/$TASK/debug/run.sh $([[ $NO_RUN -eq 1 ]] && echo '(skipped: --no-run)')"
  echo "  3. report : $OUT/report.txt  -> one 'FINGERPRINT $TASK: ...' line"
  echo "  4. revert : $([[ $KEEP -eq 1 ]] && echo 'no (--keep)' || echo 'yes')"
  exit 0
fi

preflight
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
    # digits-only, label-preserving code: impossible to distort when retyped
    #   ok=1  route_fail=0  other=2  skip/n-a=9
    code="$(printf '%s' "${line#FINGERPRINT:}" \
      | sed -E 's/[[:space:]]*=[[:space:]]*/=/g; s/=ok/=1/g; s/=route_fail/=0/g; s/=other/=2/g; s/=skip/=9/g; s#=n/a#=9#g' \
      | tr -d '=')"
    echo
    echo "SEND THIS ONE LINE >>> $TASK $code"
  else
    echo "(no FINGERPRINT in report; last 5 lines)"
    tail -5 "$REPORT"
    echo
    echo "SEND THIS ONE LINE >>> $TASK noreport"
  fi
else
  echo "(no $REPORT; check tasks/$TASK/debug/run.sh)"
  echo
  echo "SEND THIS ONE LINE >>> $TASK noreport"
fi
echo "=========================================================="
echo "logs (do not export): $OUT"

if [[ $KEEP -eq 0 ]]; then
  bash "$PATCHSTACK/revert_all.sh" --root "$ROOT" --task "$TASK" >/dev/null
  rm -f "$ROOT/vllm_ascend/ops/fused_moe/token_dispatcher.py.bak"
  echo "[green_run] worktree restored (use --keep to keep the patch)"
else
  echo "[green_run] patch kept; revert with: bash $0 --revert --task $TASK"
fi
