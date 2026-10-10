#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mc2-dispatch-extscale / routing group -- can the local MoE routing operator
permute an already quantized fp8 activation together with its e8m0 block scale?

Why this is a separate group from probe.py
------------------------------------------
probe.py exercises `MoeDistributeDispatchV2`, which is the *cross-card* half of
the FFN-side dispatch.  This file exercises the *local reorder* half
(`MoeInitRouting*`), which is a single-card operator and therefore needs no
process group -- it runs on rank 0 only, after the distributed group is gone.

Why it is worth runtime even though the docs answer it
------------------------------------------------------
The CANN README for `MoeInitRoutingV3` states, for `quantMode = -1`:

    x            : ... FLOAT8_E4M3FN ...
    scaleOptional: when x is FLOAT4_E2M1 / FLOAT8_E4M3FN / FLOAT8_E5M2, must be
                   3-D, shape (NUM_ROWS, CeilDiv(H, 64), 2), dtype FLOAT8_E8M0
    expandedScaleOut: FLOAT8_E8M0, shape (NUM_ROWS*K, CeilDiv(H, 64), 2)

That is exactly the combination the A2E plan needs -- and it is exactly the
combination that a field record shows failing on A5 with

    aclnnMoeInitRoutingV3 ... dtype or format ... inconsistent with OpDef

So the documentation and the observed behaviour disagree.  This group does not
re-ask what the documentation settles; it asks **whether this CANN build matches
the documentation**, and which of the recorded call variants is the one that
works.

Variants (each is one operator call)
------------------------------------
  R1  x=bf16, scale=None                       control: the call shape is right
  R2  x=fp8,  scale=e8m0 (N,H/64,2), x_dtype=fp8      reproduces the field record
  R3  x=fp8,  scale=e8m0 (N,H/64,2), no x_dtype       is x_dtype the offender?
  R4  x=fp8,  scale=e8m0 (N,H/64,2), quant_mode=-1    is an explicit mode needed?

Compliance
----------
Read-only: no git write, no network write, no framework checkout is touched.
Writes only under $OUT.  `--revert` is a no-op, kept for the runner contract.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import traceback
from pathlib import Path

# ---------------------------------------------------------------- sizing ----
# Small on purpose: this is a dtype/shape contract check, not a throughput test.
NUM_ROWS = 16
H = 1024
K = 4
EXPERT_NUM = 32

ROUT_VARIANTS = (
    ("R1", "bf16", None, {}),
    ("R2", "fp8", "scale3d", {"x_dtype": "fp8"}),
    ("R3", "fp8", "scale3d", {}),
    ("R4", "fp8", "scale3d", {"quant_mode": -1}),
)


def log(msg: str) -> None:
    print(f"[routing] {msg}", flush=True)


def _first_line(exc: BaseException) -> str:
    text = str(exc).strip().replace("\r", "")
    for line in text.splitlines():
        line = line.strip()
        if line:
            return line[:300]
    return exc.__class__.__name__


# ------------------------------------------------------------------ utils ----
def _e8m0_tensor(shape, torch, torch_npu):
    """Build an e8m0 tensor.

    The dtype attribute is not guaranteed to exist on every torch_npu build, and
    `view(dtype)` on device memory is unreliable, so: allocate uint8 on the CPU,
    view there, then move to the device.  If the dtype does not exist, fall back
    to uint8 and say so -- the operator may still accept it.
    """
    u8 = torch.zeros(shape, dtype=torch.uint8)
    dt = getattr(torch_npu, "float8_e8m0fnu", None) or getattr(torch, "float8_e8m0fnu", None)
    if dt is None:
        return u8.npu(), "uint8_fallback"
    try:
        return u8.view(dt).npu(), str(dt)
    except Exception as exc:  # noqa: BLE001
        log(f"  e8m0 view failed ({exc.__class__.__name__}), falling back to uint8")
        return u8.npu(), "uint8_fallback"


def _fp8_tensor(shape, torch):
    """float8_e4m3fn payload.  Cast on the CPU first: on-device casts to fp8 are
    not reliably supported across torch_npu builds."""
    return torch.full(shape, 1.0, dtype=torch.float32).to(torch.float8_e4m3fn).npu()


def _bf16_tensor(shape, torch):
    return torch.full(shape, 1.0, dtype=torch.bfloat16).npu()


def _find_binding(torch_npu):
    """Return (name, callable) for the routing binding this build exposes.

    vLLM-Ascend calls `npu_moe_init_routing_v2`; other builds may only have a
    differently suffixed name, so the list is sorted by preference rather than
    hard-coded.
    """
    candidates = [n for n in dir(torch_npu) if "init_routing" in n.lower()]
    if not candidates:
        return None, None

    def rank(name: str) -> tuple:
        return (0 if name == "npu_moe_init_routing_v2" else 1, name)

    for name in sorted(candidates, key=rank):
        fn = getattr(torch_npu, name, None)
        if callable(fn):
            return name, fn
    return None, None


def _call_routing(fn, x, expert_idx, scale, extra):
    """Call the routing operator, dropping kwargs this build does not accept.

    Different CANN versions expose different keyword sets (`x_dtype`,
    `quant_mode`, `active_num` as an input vs an attribute).  Rather than
    guessing, start from the documented set and let TypeError tell us what to
    drop -- the dropped names are reported so a pass can be attributed.
    """
    kwargs = {
        "active_num": NUM_ROWS * K,
        "expert_num": EXPERT_NUM,
        "expert_tokens_num_type": 1,
        "expert_tokens_num_flag": True,
        "active_expert_range": [0, EXPERT_NUM],
    }
    if scale is not None:
        kwargs["scale"] = scale
    kwargs.update(extra)

    dropped: list = []
    while True:
        try:
            return fn(x, expert_idx, **kwargs), dropped
        except TypeError as exc:
            msg = str(exc)
            # CPython words this as "got an unexpected keyword argument 'name'".
            # Match the quoted form: a bare substring test would also catch
            # 'expert_num' inside 'expert_tokens_num_type' and drop a good kwarg.
            bad = [k for k in list(kwargs) if f"'{k}'" in msg]
            if not bad:
                raise
            for k in bad:
                kwargs.pop(k, None)
                dropped.append(k)


def run(out_dir: Path) -> dict:
    import torch

    try:
        import torch_npu  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        return {"env_ok": 0, "fatal": f"import torch_npu failed: {_first_line(exc)}"}

    result: dict = {"variants": {}, "errors": {}}

    name, fn = _find_binding(torch_npu)
    result["bindings"] = sorted(n for n in dir(torch_npu) if "init_routing" in n.lower())
    if fn is None:
        result["env_ok"] = 0
        result["fatal"] = "no *init_routing* binding found in torch_npu"
        return result
    result["binding"] = name

    try:
        torch.npu.set_device(0)
    except Exception as exc:  # noqa: BLE001
        result["env_ok"] = 0
        result["fatal"] = f"set_device(0) failed: {_first_line(exc)}"
        return result

    try:
        expert_idx = torch.randint(
            low=0, high=EXPERT_NUM, size=(NUM_ROWS, K), dtype=torch.int32
        ).npu()
        payload = {
            "bf16": lambda: _bf16_tensor((NUM_ROWS, H), torch),
            "fp8": lambda: _fp8_tensor((NUM_ROWS, H), torch),
        }
        scale_tensor, scale_dtype = _e8m0_tensor((NUM_ROWS, H // 64, 2), torch, torch_npu)
        result["env_ok"] = 1
    except Exception as exc:  # noqa: BLE001
        result["env_ok"] = 0
        result["fatal"] = f"payload build failed: {_first_line(exc)}"
        return result

    for tag, xkind, scale_kind, extra in ROUT_VARIANTS:
        entry: dict = {
            "x": xkind,
            "scale": scale_kind or "none",
            "extra": {k: str(v) for k, v in extra.items()},
        }
        try:
            x = payload[xkind]()
            call_extra = dict(extra)
            if call_extra.get("x_dtype") == "fp8":
                call_extra["x_dtype"] = torch.float8_e4m3fn
            scale = scale_tensor if scale_kind else None
            if scale is not None:
                entry["scale_dtype"] = scale_dtype
            out, dropped = _call_routing(fn, x, expert_idx, scale, call_extra)
            if dropped:
                entry["dropped_kwargs"] = dropped
            entry["ok"] = 1
            outs = out if isinstance(out, (tuple, list)) else [out]
            entry["n_outputs"] = len(outs)
            entry["out_dtypes"] = [str(getattr(t, "dtype", None)) for t in outs]
            entry["out_shapes"] = [list(getattr(t, "shape", [])) for t in outs]
            if len(outs) >= 4:
                s = outs[3]
                entry["expanded_scale_present"] = int(getattr(s, "numel", lambda: 0)() > 0)
                entry["expanded_scale_dtype"] = str(getattr(s, "dtype", None))
        except Exception as exc:  # noqa: BLE001
            entry["ok"] = 0
            entry["error"] = _first_line(exc)
            entry["traceback_tail"] = traceback.format_exc().strip().splitlines()[-1][:300]

        result["variants"][tag] = entry
        log(f"variant {tag} ({xkind}): ok={entry.get('ok')} {entry.get('error', '')}")

    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=os.environ.get("OUT", "/tmp/mc2_dispatch_extscale"))
    ap.add_argument("--revert", action="store_true",
                    help="accepted for the patch-stack runner contract; this probe patches nothing")
    args = ap.parse_args()

    if args.revert:
        print("[routing] nothing to revert (probe patches nothing)")
        return 0

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    payload = run(out_dir)
    (out_dir / "routing.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return 0 if payload.get("env_ok") else 3


if __name__ == "__main__":
    sys.exit(main())
