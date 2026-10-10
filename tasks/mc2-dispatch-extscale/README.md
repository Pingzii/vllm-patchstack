# 任务卡：mc2-dispatch-extscale

## 一句话

验证 A5 上 FFN 侧 dispatch 的**两半**，能否接受**外部已量化的 fp8 激活 + 外部 e8m0 scale**：

- **MC2 组（跨卡）**：`MoeDistributeDispatchV2` 的 EP AllToAllV 能不能把外部 scale 一起搬
- **ROUT 组（单卡）**：`MoeInitRouting` 的重排能不能把 scale 用同一个置换排好

**两半都通** → 框架侧小改即可，算子零改动。
**任一半不通** → 需要推动 CANN 加接口。

---

## 背景

AFD 同步 connector 的 A2E 只传 BF16。想换成 MXFP8（通信量 14336 → 7392 B/token）：

```
Attention 侧量化 → a2e 传 fp8 + e8m0 scale → FFN 侧直接喂 GMM
```

FFN 侧那一段会经过 MoE 的 token 分发，它必须同时做到两件事：

1. **不重复量化**（数据在 Attention 侧已经量化过了）
2. **把 scale 和 payload 用同一个置换搬过去**（分发会按专家重排 token，scale 不跟就会静默算错）

分发在不同场景走不同算子，所以两组都要验。

---

## 为什么只有这 8 个变体（文档已经答过的一律不测）

原则：**能从算子文档读出来的结论，不花运行时。**

以下候选测试都被文档直接判定了，因此**不测**：

| 候选测试 | 文档结论 | 出处 |
|---|---|---|
| MC2 dispatch 的 `x` 支持 fp8 吗 | 950DT 支持 `FLOAT8_E4M3FN` | `MoeDistributeDispatchV2` README |
| MC2 dispatch 的 `scalesOptional` 支持 e8m0 吗 | 支持 `FLOAT8_E8M0` | 同上 |
| MC2 dispatch 支持 `quant_mode=4`（MX 自量化）吗 | 950DT 支持 0/1/2/3/4 | 同上 |
| `MoeDistributeDispatchV3` 能用来传 MXFP8 吗 | **不能** —— `x` 只有 FP16/BF16、`scales` 只有 FLOAT32、`quantMode` 只有 0/2 | `...V3` README |
| `AttentionToFFN`（官方 A2E）能用吗 | **不能** —— 不支持 950 | `AttentionToFFN` README |

> **原变体 `E`（bf16 + `quant_mode=4`）已按此原则删除。**
> 它问的是「MX 自量化支不支持」，而 README 对 950DT 已经写明了。

**剩下必须实测的，只有文档没有明确的两类问题：**

### 缺口 1：语义缺口（→ MC2 组的 C/D）

`MoeDistributeDispatchV2` 的 `quant_mode=0` 情形，公式只写了：

```
allToAllXOut = AllToAllV(X)
expand_x_out = AllToAllV(X)
```

**完全没提 `scalesOptional` 的去向。** 而 `dynamicScalesOut` 的描述是「量化场景下，表示本卡输出 Token 的量化系数」——`quant_mode=0` 不算量化场景。

**所以「外部 scale 会不会跟着搬」文档没说 → 必须测。**

### 缺口 2：文档与实现不一致（→ ROUT 组）

`MoeInitRoutingV3` 的 README 对 `quantMode=-1` 明确写了：

```
x            : ... FLOAT8_E4M3FN ...
scaleOptional: 当 x 为 FLOAT4_E2M1 / FLOAT8_E4M3FN / FLOAT8_E5M2 时，
               要求 3D，shape (NUM_ROWS, CeilDiv(H, 64), 2)，dtype FLOAT8_E8M0
expandedScaleOut: FLOAT8_E8M0，shape (NUM_ROWS*K, CeilDiv(H, 64), 2)
```

**而现场记录显示 A5 上这个组合报 `aclnnMoeInitRoutingV3 ... dtype or format ... inconsistent with OpDef`。**

**文档说支持、实测失败 → 这正是最该测的一类。**

### 关于控制组

`A` 和 `R1` 不是重复提问，它们是**归因锚点**：

- `A=0` → MC2 那组的结果全部作废（环境问题，不是算子问题）
- `B` 不是问「fp8 文档上支不支持」（文档已答），而是**在你们的 CANN 版本上支不支持** ——
  没有 B，C/D 挂了就无法区分是「fp8 输入不行」还是「外部 scale 不行」

---

## 环境画像

| 项 | 值 |
|---|---|
| 硬件 | Ascend A5（950DT 系列） |
| 卡数 | 单机 8 卡（脚本自适应，`NPUS=` 可覆盖，MC2 组需要 ≥2） |
| 框架 | 不依赖 vllm-ascend / vLLM / afd-plugin，**纯算子级直调** |
| 依赖 | `torch`、`torch_npu`、可用的 NPU 驱动 + CANN |

## 为什么是「纯算子级直调」

- 不碰任何框架检出 → 没有补丁、没有 revert 风险、不可能污染绿区工作树
- 排除掉框架侧的一切变量（配置、路由、量化方案），只测算子契约
- MC2 组 4 个变体 + ROUT 组 4 个变体，每个变体一次算子调用，失败互不影响

---

## 变体设计

### MC2 组 —— 跨卡，需要 HCCL

| 代号 | `x` | `quant_mode` | `scales` | 目的 |
|---|---|---|---|---|
| **A** | bf16 | 0 | 无 | **控制组**：证明 harness 与调用方式正确 |
| **B** | fp8 | 0 | 无 | **归因锚点**：fp8 输入在**这套 CANN 版本**上通不通 |
| **C** | fp8 | 0 | e8m0 `[BS, H/32]` | 外部 scale（2 维） |
| **D** | fp8 | 0 | e8m0 `[BS, H/64, 2]` | 外部 scale（3 维，README 对 routing 用的就是它） |

尺寸：`BS=8, H=1024, K=4, moe_expert_num=32, shared_expert_rank_num=0`
→ `local_expert_num = 32/8 = 4`，满足 `moe_expert_num % (ep_world_size - shared_expert_rank_num) == 0`。

### ROUT 组 —— 单卡，无需 process group

| 代号 | `x` | `scale` | 额外 kwarg | 目的 |
|---|---|---|---|---|
| **R1** | bf16 | 无 | — | **控制组**：证明单卡 harness 正确 |
| **R2** | fp8 | e8m0 `(N,H/64,2)` | `x_dtype=fp8` | **复现现场记录**的调用形态 |
| **R3** | fp8 | e8m0 `(N,H/64,2)` | 去掉 `x_dtype` | `x_dtype` 是不是肇事者 |
| **R4** | fp8 | e8m0 `(N,H/64,2)` | `quant_mode=-1` | 需要显式的「不量化」模式吗 |

尺寸：`NUM_ROWS=16, H=1024, K=4, EXPERT_NUM=32`

> ROUT 组会**自动探测** `torch_npu` 里可用的 `*init_routing*` 绑定（优先 `npu_moe_init_routing_v2`），
> 并自动丢弃这套版本不接受的 kwarg；被丢弃的名字记录在 `routing.json` 的 `dropped_kwargs` 里。

---

## 判读规则

### MC2 组

| 观测 | 结论 | 下一步 |
|---|---|---|
| `A=0` | 环境/调用有问题，**MC2 那组作废** | 看 `rank_*.log` |
| `A=1 B=0` | fp8 输入直接被拒 | **文档说支持 → 这套 CANN 与文档不符**，作为升版依据 |
| `A=1 B=1 C=1 或 D=1` | **外部量化直通成立** 🎉 | 框架侧小改即可，算子零改动 |
| `A=1 B=1 C=0 D=0` | fp8 能进，但**外部 scale 没有入口** | 推动 CANN 加接口 |

### ROUT 组

| 观测 | 结论 | 下一步 |
|---|---|---|
| `R1=0` | 单卡 harness 有问题，**ROUT 那组作废** | 看 `routing.log` |
| `R1=1 R3=1 或 R4=1` | **routing 能把 fp8 + e8m0 排好** 🎉 | AllToAll 路径可用 |
| `R1=1 R2..R4 全 0` | **文档说支持但运行时拒绝** | 需要 CANN 修，或换 `MoeInitRoutingV4` |
| `R1=1 R2=1 其余 0` | 只有原样调用能过 | 看 `dropped_kwargs` 判断原因 |

> **注意区分**：本任务只证明「接口能不能用」。**「接口能用」≠「端到端有收益」**。
> A2E 是否在关键路径上、MXFP8 计算侧是否划算，是另外两次测量的事。
>
> **也不看数值正确性** —— 只看「有没有返回非空的 scale」，不看值对不对。数值一致性需要另做一次验证。

---

## 状态

- [ ] 绿区跑出 `FINGERPRINT`
- [ ] 判读结论
- [ ] （若 MC2 为 PARTIAL）整理给 CANN 的接口需求
- [ ] （若任一为 SUPPORTED）转成框架侧实施任务

## 结论

（待填）

---

## 绿区怎么跑

```bash
rm -rf /tmp/patchstack && \
git clone --quiet --depth 1 https://github.com/Pingzii/vllm-patchstack.git /tmp/patchstack && \
rm -rf /tmp/patchstack/.git && \
bash /tmp/patchstack/tasks/mc2-dispatch-extscale/debug/run.sh
```

先看不改任何东西的计划：

```bash
bash /tmp/patchstack/tasks/mc2-dispatch-extscale/debug/run.sh --dry-run
```

产物在 `/tmp/mc2_dispatch_extscale/`：
`report.txt`、`rank_*.json`、`rank_*.log`、`routing.json`、`routing.log`。

**回传只要一行**（脚本最后会打印 `SEND THIS ONE LINE >>>`）：

```
mc2-dispatch-extscale A1 B1 C0 D0 R1_1 R2_0 R3_0 R4_0
```

如果全挂，再多带一行 `first error >>> ...`。

`--revert` 是空操作 —— 本任务不改绿区的任何文件，保留它是为了和其他任务统一契约。

## 已知风险

| 风险 | 缓解 |
|---|---|
| 某个 rank 在集合通信里失败，其他 rank 挂死 | `init_process_group(timeout=180s)` + 每个变体后带超时的 barrier + 每进程 `timeout 900` |
| `torch_npu.float8_e8m0fnu` 不存在 | 先按 uint8 分配，**在 CPU 上 view**，再搬卡；失败则回退 uint8 并在报告里标注 |
| 卡上做 `view(dtype)` 不可靠 | 同上，一律在 CPU 上 view |
| 8 卡不可用 | `NPUS=4 bash run.sh` 覆盖；`ep_world_size` 会跟着变，`moe_expert_num=32` 仍能整除 |
| 端口冲突 | `MASTER_PORT` / `HCCL_IF_BASE_PORT` 每次随机 |
| ROUT 组的 kwarg 名与这套 CANN 不符 | 自动探测绑定名 + 自动丢弃不接受的 kwarg，并把丢弃的名字记进 `routing.json` |
| ROUT 组和 MC2 组互相影响 | ROUT 在 MC2 所有 rank 退出后、以**独立单卡进程**运行，任一组失败不影响另一组 |
