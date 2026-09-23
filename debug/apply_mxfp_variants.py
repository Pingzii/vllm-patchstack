#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Temporary A/B switch for the W4A8MXFP ALLTOALL routing call.

Context
-------
`TokenDispatcherWithAll2AllV._dispatch_postprocess` feeds an already quantized
fp8 activation plus an e8m0 per-token scale into `npu_moe_init_routing_v2` and
additionally passes `x_dtype=dst_type`.  On A5 that call fails with:

    aclnnMoeInitRoutingV3 ... The dtype or format of the actual input or output
    parameter of the operator is inconsistent with that defined in the operator
    prototype OpDef.
    Cannot find binary for op MoeInitRoutingV3.

Verified on the failing run (see README.md):
  * x        = torch.float8_e4m3fn, shape (N, 4096)
  * scale    = torch.float8_e8m0fnu, shape (N, 64, 2), dim 3   <- layout is fine
  * comm     = MoECommType.ALLTOALL (num_tokens=2048 > mc2_capacity=256)
  * crash    = immediately after that dispatch, in MoeInitRoutingV3

So the remaining suspects are the *arguments* of the call, not the scale layout.
This script swaps the call for an env-selected variant so each suspect can be
tested with one server start per variant.

Usage (on the machine that runs vLLM; run from the vllm-ascend checkout root)
----------------------------------------------------------------------------
    python3 apply_mxfp_variants.py --root /home/s00988495/AFD/vllm-ascend
    # ... run A~E, see README.md ...
    python3 apply_mxfp_variants.py --root /home/s00988495/AFD/vllm-ascend --revert

The edit is idempotent and keeps a `.bak` copy next to the file.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

REL_PATH = "vllm_ascend/ops/fused_moe/token_dispatcher.py"

ORIGINAL = '''                dynamic_scale_for_routing = dynamic_scale_after_all2all.view(torch.float8_e8m0fnu)
                global_input_tokens, reversed_global_input_permutation_mapping, _, routed_scale = (
                    torch_npu.npu_moe_init_routing_v2(
                        global_input_tokens,
                        experts_indices_2d_copy,
                        scale=dynamic_scale_for_routing,
                        active_num=experts_indices_2d_copy.shape[0],
                        expert_num=self.num_local_experts,
                        expert_tokens_num_type=1,
                        expert_tokens_num_flag=True,
                        active_expert_range=[0, self.num_local_experts],
                        x_dtype=dst_type,
                    )
                )
'''

PATCHED = '''                dynamic_scale_for_routing = dynamic_scale_after_all2all.view(torch.float8_e8m0fnu)
                import os as _os

                _variant = _os.environ.get("DSV4_MXFP_VARIANT", "A")
                _extra = {
                    # A: current code (scale + explicit x_dtype)
                    "A": {"scale": dynamic_scale_for_routing, "x_dtype": dst_type},
                    # B: drop x_dtype (elsewhere in the tree fp8 e4m3 is deliberately not passed)
                    "B": {"scale": dynamic_scale_for_routing},
                    # C: explicit "no quant, just route/permute"
                    "C": {"scale": dynamic_scale_for_routing, "x_dtype": dst_type, "quant_mode": -1},
                    # D: MXFP fused quant mode used by the AllGather branch
                    "D": {"scale": dynamic_scale_for_routing, "x_dtype": dst_type, "quant_mode": 3},
                    # E: candidate MXFP8 round-scale mode
                    "E": {"scale": dynamic_scale_for_routing, "quant_mode": 17},
                }[_variant]
                print(f"[DSV4-MXFP-PROBE] variant={_variant}", flush=True)
                global_input_tokens, reversed_global_input_permutation_mapping, _, routed_scale = (
                    torch_npu.npu_moe_init_routing_v2(
                        global_input_tokens,
                        experts_indices_2d_copy,
                        active_num=experts_indices_2d_copy.shape[0],
                        expert_num=self.num_local_experts,
                        expert_tokens_num_type=1,
                        expert_tokens_num_flag=True,
                        active_expert_range=[0, self.num_local_experts],
                        **_extra,
                    )
                )
'''

MARKER = "DSV4_MXFP_VARIANT"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="vllm-ascend checkout root")
    parser.add_argument("--revert", action="store_true", help="restore the .bak copy")
    args = parser.parse_args()

    path = Path(args.root) / REL_PATH
    if not path.is_file():
        print(f"not found: {path}", file=sys.stderr)
        return 2

    bak = path.with_suffix(path.suffix + ".bak")

    if args.revert:
        if not bak.is_file():
            print(f"no backup to restore: {bak}", file=sys.stderr)
            return 2
        shutil.copyfile(bak, path)
        print(f"reverted {path} from {bak}")
        return 0

    text = path.read_text()

    if MARKER in text:
        print(f"already patched (found {MARKER}); nothing to do")
        return 0

    if text.count(ORIGINAL) != 1:
        print(
            "anchor not found exactly once; the file differs from the expected "
            "revision. Apply the change manually (see README.md).",
            file=sys.stderr,
        )
        return 2

    if not bak.is_file():
        shutil.copyfile(path, bak)
        print(f"backup written: {bak}")

    path.write_text(text.replace(ORIGINAL, PATCHED))
    print(f"patched {path}")
    print("run one variant at a time, e.g.:  DSV4_MXFP_VARIANT=B bash serve_8card.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
