# 任务卡：dsv4-mxfp-a2a

DSv4-Flash（W4A8MXFP）在 **EP8 混布**启动时失败：`aclnnMoeInitRoutingV3` 报
`dtype or format ... inconsistent with OpDef` / `Cannot find binary`。

## 目标

找出 ALLTOALL 分支上 `npu_moe_init_routing_v2` **可被 A5 接受的入参组合**，
据此产出正式修复补丁 + 回归用例；若老版本已不可修，则作为升版依据。

## 环境画像

| 项 | 值 |
|---|---|
| 模型 / 量化 | DeepSeek-V4-Flash / W4A8MXFP（`n_routed_experts=256`，`num_experts_per_tok=4`） |
| 硬件 | Ascend A5，单机 8 卡 |
| 部署 | 混布 `DP8 × TP1 × EP8`（对照基线：4 卡 `EP4` 正常） |
| base | vllm-ascend `<待填>`，vLLM `<待填>`，afd-plugin `<待填>` |

## 已确认的事实（证据链）

1. 失败发生在 `profile_run`，失败算子 `aclnnMoeInitRoutingV3`；
2. `num_tokens=256 ≤ mc2_capacity=256` 走 MC2 正常；`num_tokens=2048` 走 **ALLTOALL** 随即崩；
3. 该调用点入参：`x=fp8_e4m3fn`、`x_dtype=fp8_e4m3fn`、`scale=e8m0 (N,64,2) dim=3`、`local_experts=32`；
4. 4 卡正常（`world_size(4) ≤ top_k(4)` ⇒ 走 ALLGATHER），⇒ 问题只在这条 ALLTOALL 分支；
5. 上游 main 已重写该函数（`scale_type` 分支被删、MC2 侧新增 A5 MXFP `quant_mode=4`/`y_dtype`），
   但 `x_dtype=dst_type` 仍在传 —— 需要确认上游是否已改走别的路径。

## 待验证（A~E 变体）

| 变体 | 入参 | 假设 |
|---|---|---|
| A | `scale + x_dtype=fp8` | 现状，必须复现同一报错 |
| B | `scale`（去掉 `x_dtype`） | fp8 不该显式传 dtype ⇒ 一行删除即修复 |
| C | `scale + x_dtype + quant_mode=-1` | 需要显式"不量化、只排序" |
| D | `scale + x_dtype + quant_mode=3` | 需要 AllGather 那套 MXFP 融合量化模式 |
| E | `scale + quant_mode=17` | MXFP8 round-scale |

## 状态

- [ ] 绿区跑出 `FINGERPRINT`
- [ ] 定位正确入参组合
- [ ] 正式补丁 + 回归用例（`patches/vllm-ascend/0001-*.patch`）+ 数值一致性验证
- [ ] （可选）确认上游是否已修，决定 issue 还是升版

## 结论

（待填：哪个变体通过、证据、最终修复、验证方式）
