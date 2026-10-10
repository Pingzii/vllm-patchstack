#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mc2-dispatch-extscale -- does MoeDistributeDispatchV2 accept an already
quantized fp8 activation plus an external e8m0 scale?

Why this probe exists
---------------------
The planned A2E quantization needs the FFN-side MoE dispatch to carry an
activation that the *Attention* side already quantized, together with the
matching per-token MX scale.  If the dispatch operator can do that, the
framework change is small and no operator work is needed.  If it cannot, the
interface has to be added on the CANN side.

This probe answers exactly that, and nothing else.

How it runs
-----------
Launch ONE process per NPU (see run.sh).  Every rank participates in every
variant, in the same order, separated by barriers, so results are attributable.

Variants (each one op call)
---------------------------
  A  x=bf16, quant_mode=0, scales=None          control: proves the harness works
  B  x=fp8,  quant_mode=0, scales=None          gate: is fp8 input accepted *here*?
  C  x=fp8,  quant_mode=0, scales=e8m0 [BS,H/32]     external scale, 2-D
  D  x=fp8,  quant_mode=0, scales=e8m0 [BS,H/64,2]   external scale, 3-D

Why there is no quant_mode=4 variant
------------------------------------
The CANN README states that 950DT supports quant_mode 0/1/2/3/4, so "does MX
self-quantization work" is already answered on paper.  Per the task's rule --
do not spend runtime on what the operator documentation already settles -- the
variant was dropped.  B is *not* in that category even though the README also
lists FLOAT8_E4M3FN for `x`: B is not asking whether fp8 is documented, it is
the gate that makes a C/D failure attributable (fp8 input vs external scale).

Decision rules (see README.md)
------------------------------
  A=0                      -> harness/environment problem, the run is void
  A=1 B=1 C=1 or D=1       -> external quantized passthrough is SUPPORTED
  A=1 B=1 C=0 D=0          -> fp8 goes in, but an external scale does not:
                              CANN must add the interface
  A=1 B=0                  -> fp8 input is rejected outright
                              (documented as supported -> this CANN build differs)

Compliance
----------
Read-only with respect to the checkout: this file only reads the environment,
calls operators, and writes under $OUT (default /tmp/...).  No git write, no
network write.  `--revert` is accepted and is a no-op because nothing is
patched, which keeps it compatible with the patch-stack runner contract.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import traceback
from datetime import timedelta
from pathlib import Path

OUT_DEFAULT = "/tmp/mc2_dispatch_extscale"

# ---------------------------------------------------------------- sizing ----
# Kept small on purpose: we are testing a dtype/shape contract, not throughput.
BS = 8            # tokens per rank          (950DT allows (0, 512])
H = 1024          # hidden size              (first legal value, multiple of 32)
K = 4             # top-k experts            (0 < K <= 16)
MOE_EXPERT_NUM = 32
SHARED_EXPERT_RANK_NUM = 0
EXPERT_TOKEN_NUMS_TYPE = 1   # 1 = count (per-expert token count)

# Only combinations the CANN README does *not* settle are worth a runtime.
# quant_mode=4 (MX self-quantization) is documented for 950DT and is therefore
# intentionally absent -- see the module docstring.
VARIANTS = (
    ("A", "bf16", 0, None),
    ("B", "fp8", 0, None),
    ("C", "fp8", 0, "scale2d"),
    ("D", "fp8", 0, "scale3d"),
)


def log(msg: str) -> None:
    print(f"[probe] {msg}", flush=True)


# ------------------------------------------------------------------ utils ----
def _e8m0_tensor(shape, torch, torch_npu):
    """Build an e8m0 tensor.

    The dtype attribute is not guaranteed to exist on every torch_npu build, and
    `view(dtype)` on device memory is unreliable, so: allocate uint8 on the CPU,
    view there, then move to the device.  If the dtype does not exist we fall
    back to uint8 and record that fact -- the operator may accept it.
    """
    u8 = torch.zeros(shape, dtype=torch.uint8)
    name = getattr(torch_npu, "float8_e8m0fnu", None) or getattr(torch, "float8_e8m0fnu", None)
    if name is None:
        return u8.npu(), "uint8_fallback"
    try:
        return u8.view(name).npu(), name.__name__ if hasattr(name, "__name__") else str(name)
    except Exception as exc:  # noqa: BLE001
        log(f"  e8m0 view failed ({exc.__class__.__name__}), falling back to uint8")
        return u8.npu(), "uint8_fallback"


def _fp8_tensor(shape, torch, fill=1.0):
    """float8_e4m3fn payload.  Cast on CPU first: on-device casts to fp8 are not
    reliably supported across torch_npu builds."""
    base = torch.full(shape, fill, dtype=torch.float32)
    return base.to(torch.float8_e4m3fn).npu()


def _bf16_tensor(shape, torch, fill=1.0):
    return torch.full(shape, fill, dtype=torch.bfloat16).npu()


def _first_line(exc: BaseException) -> str:
    text = str(exc).strip().replace("\r", "")
    for line in text.splitlines():
        line = line.strip()
        if line:
            return line[:300]
    return exc.__class__.__name__


# ------------------------------------------------------------------- rank ----
def run_rank(rank: int, world: int, out_dir: Path) -> dict:
    import torch
    import torch.distributed as dist

    try:
        import torch_npu  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        return {"rank": rank, "env_ok": 0, "fatal": f"import torch_npu failed: {_first_line(exc)}"}

    result: dict = {"rank": rank, "world": world, "variants": {}, "errors": {}}

    try:
        torch.npu.set_device(rank)
    except Exception as exc:  # noqa: BLE001
        return {**result, "env_ok": 0, "fatal": f"set_device({rank}) failed: {_first_line(exc)}"}

    # ------------------------------------------------- process groups --------
    # Use the default group itself.  Creating a subgroup that spans every rank is
    # both redundant and a known source of HCCL trouble, so it is only a fallback.
    try:
        dist.init_process_group(
            backend="hccl",
            rank=rank,
            world_size=world,
            timeout=timedelta(seconds=180),
        )
        pg = None
        pg_kind = "subgroup"
        try:
            from torch.distributed.distributed_c10d import _get_default_group

            pg = _get_default_group()
            pg_kind = "default"
        except Exception:  # noqa: BLE001
            pg = None
        if pg is None:
            pg = dist.new_group(ranks=list(range(world)), backend="hccl")
            pg_kind = "subgroup"
        backend = pg._get_backend(torch.device("npu"))
        local_rank = dist.get_rank(group=pg)
        group_name = backend.get_hccl_comm_name(local_rank)
        result["env_ok"] = 1
        result["group_name"] = group_name
        result["pg"] = pg_kind
    except Exception as exc:  # noqa: BLE001
        return {**result, "env_ok": 0, "fatal": f"process group setup failed: {_first_line(exc)}"}

    # ------------------------------------------------- payloads -------------
    try:
        expert_ids = torch.randint(
            low=0, high=MOE_EXPERT_NUM, size=(BS, K), dtype=torch.int32
        ).npu()
        expert_scales = torch.full((BS, K), 1.0 / K, dtype=torch.float32).npu()

        payload = {
            "bf16": lambda: _bf16_tensor((BS, H), torch),
            "fp8": lambda: _fp8_tensor((BS, H), torch),
        }
        scale_cache: dict = {}

        def get_scale(kind: str):
            if kind not in scale_cache:
                if kind == "scale2d":
                    scale_cache[kind] = _e8m0_tensor((BS, H // 32), torch, torch_npu)
                else:
                    scale_cache[kind] = _e8m0_tensor((BS, H // 64, 2), torch, torch_npu)
            return scale_cache[kind]
    except Exception as exc:  # noqa: BLE001
        return {**result, "env_ok": 0, "fatal": f"payload build failed: {_first_line(exc)}"}

    # ------------------------------------------------- variants -------------
    for tag, xkind, quant_mode, scale_kind in VARIANTS:
        dist.barrier()
        entry: dict = {"x": xkind, "quant_mode": quant_mode, "scale": scale_kind or "none"}
        try:
            x = payload[xkind]()
            kwargs = {
                "x": x,
                "expert_ids": expert_ids,
                "expert_shard_type": 0,
                "shared_expert_rank_num": SHARED_EXPERT_RANK_NUM,
                "moe_expert_num": MOE_EXPERT_NUM,
                "global_bs": 0,
                "expert_token_nums_type": EXPERT_TOKEN_NUMS_TYPE,
                "group_ep": group_name,
                "ep_world_size": world,
                "ep_rank_id": rank,
                "quant_mode": quant_mode,
                "group_tp": group_name,
                "tp_world_size": 1,
                "tp_rank_id": 0,
                "expert_scales": expert_scales,
            }
            if scale_kind is not None:
                scale_tensor, scale_dtype = get_scale(scale_kind)
                kwargs["scales"] = scale_tensor
                entry["scale_dtype"] = scale_dtype
            if xkind == "fp8":
                kwargs["y_dtype"] = torch.float8_e4m3fn

            # `y_dtype` is what vLLM-Ascend passes when the dispatch quantizes.
            # With quant_mode=0 the operator may derive the output dtype from `x`
            # instead and reject the extra kwarg, so retry once without it rather
            # than reporting a bogus failure.
            try:
                out = torch_npu.npu_moe_distribute_dispatch_v2(**kwargs)
            except TypeError as exc:
                if "y_dtype" in kwargs and "y_dtype" in str(exc):
                    entry["y_dtype_kwarg_rejected"] = 1
                    kwargs.pop("y_dtype")
                    out = torch_npu.npu_moe_distribute_dispatch_v2(**kwargs)
                else:
                    raise

            expand_x = out[0]
            dynamic_scale = out[1]
            entry["ok"] = 1
            entry["expand_x_dtype"] = str(expand_x.dtype)
            entry["expand_x_shape"] = list(expand_x.shape)
            entry["dynamic_scale_present"] = int(
                dynamic_scale is not None and getattr(dynamic_scale, "numel", lambda: 0)() > 0
            )
            entry["dynamic_scale_dtype"] = str(getattr(dynamic_scale, "dtype", None))
            entry["dynamic_scale_numel"] = int(getattr(dynamic_scale, "numel", lambda: 0)())
        except Exception as exc:  # noqa: BLE001
            entry["ok"] = 0
            entry["error"] = _first_line(exc)
            entry["traceback_tail"] = traceback.format_exc().strip().splitlines()[-1][:300]

        result["variants"][tag] = entry
        log(f"rank {rank} variant {tag}: ok={entry.get('ok')} {entry.get('error', '')}")

        # Barrier with a bounded wait: if one rank dies inside the collective the
        # others must not hang forever.
        try:
            dist.barrier()
        except Exception as exc:  # noqa: BLE001
            result["barrier_failure"] = f"after variant {tag}: {_first_line(exc)}"
            break

    try:
        dist.barrier()
        dist.destroy_process_group()
    except Exception:  # noqa: BLE001
        pass

    return result


# ------------------------------------------------------------------- main ----
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=os.environ.get("OUT", OUT_DEFAULT))
    ap.add_argument("--revert", action="store_true",
                    help="accepted for the patch-stack runner contract; this probe patches nothing")
    args = ap.parse_args()

    if args.revert:
        print("[probe] nothing to revert (probe patches nothing)")
        return 0

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    rank = int(os.environ.get("RANK", "0"))
    world = int(os.environ.get("WORLD_SIZE", "1"))
    log(f"rank={rank} world={world} out={out_dir}")

    if world < 2:
        payload = {
            "fatal": "the dispatch operator requires ep_world_size >= 2; launch one process per NPU",
            "rank": rank,
            "env_ok": 0,
        }
    else:
        payload = run_rank(rank, world, out_dir)

    (out_dir / f"rank_{rank}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return 0 if payload.get("env_ok") else 3


if __name__ == "__main__":
    sys.exit(main())
