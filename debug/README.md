# DSv4-Flash W4A8MXFP：8 卡混布启动失败——诊断包

面向 `vllm-ascend` W4A8MXFP + EP8 的一个**临时诊断补丁**，以及后续修复/提交/推送的操作步骤。

## 0. 工作流：文件化 + 绿区 **单向只读**

> **合规红线（务必遵守）**：绿区只能 `git pull` / 本地 apply / 本地运行。
> **禁止**在绿区执行任何 `git push`、上传、外发日志的动作——那是信息违规。
> `run_matrix.sh` 不含任何 git/网络操作；`push_debug_branch.sh` 只能在中转机执行（脚本自带护栏）。

| 角色 | 动作 |
|---|---|
| 我 | 只往工作区写文件：`dsv4-mxfp-debug/`（开关脚本 + runbook + 本说明） |
| 中转机（可上外网） | `I_AM_ON_TRANSFER_HOST=1 bash dsv4-mxfp-debug/push_debug_branch.sh` → 发布到 fork 的调试分支 |
| 绿区（只读） | `git fetch && git checkout debug/... && SERVE=... bash dsv4-mxfp-debug/run_matrix.sh` |
| 回传 | 走**已批准的文本通道**，只回 `/tmp/dsv4_mxfp_sweep/report.txt`（已做基础脱敏：`/home/<user>`、`<ip>`），**不回传代码、不回传整段日志、不回传权重路径/拓扑全貌** |

约定：

* 一个实验 = **一个分支**（`debug/dsv4-<主题>`）+ **一个目录** + **一条命令**；
* 回退 = `run_matrix.sh --revert`，或直接 `git checkout main`——**不需要逐个文件 `git restore`**；
* 调试分支不要向上游开 PR；
* 框架侧（`vllm` / `afd-plugin`）的临时改动也走同一个调试分支，需要时按
  `patches/<repo>/NNNN-*.patch` 分目录堆叠，由 apply 脚本按各自的 repo root 应用与回退；
* 代码一律走文件（可自检：`git apply --check` + 脚本锚点校验），**对话只用来传结论**。

> 说明：本会话的 shell 被沙箱拒绝（`pwsh` 调用直接失败），且这个工作区不是 git 检出，
> 更新（实测）：把沙箱提到 `danger-full-access` 后，**我可以直接 push**（用的是本机 Git Credential
> Manager 的缓存凭据，作者是你自己的 git 身份）。所以发布这一步现在由我做，你只需在审批弹窗点同意。

---

## 0.5 绿区只记三个词（把"命令"也变成一次性的）

气隙环境里"零人工输入"不可能，但可以做到 **一次设置、之后每次一个词**：
变化的东西（变体、超时、日志解析、回退、serve 路径自动发现）**全部随 git 进来**，
所以绿区敲的命令永远不变。

**一次性**（走已批准通道输入，只需输一次）：

```bash
# 关键：只把 debug 目录取出来，绝不要 checkout 整个分支！
# （fork 的 main 可能落后上游很多，checkout 会把整个工作区降级到那个旧快照）
alias dsv4sync='cd /home/s00988495/AFD/vllm-ascend && git fetch https://github.com/Pingzii/vllm-ascend.git debug/dsv4-mxfp-probe && git archive FETCH_HEAD dsv4-mxfp-debug | tar -x'
alias dsv4run='cd /home/s00988495/AFD/vllm-ascend && bash dsv4-mxfp-debug/run.sh'
alias dsv4back='cd /home/s00988495/AFD/vllm-ascend && bash dsv4-mxfp-debug/run.sh --revert && rm -rf dsv4-mxfp-debug vllm_ascend/ops/fused_moe/token_dispatcher.py.bak'
```

（不想用 alias 就把这三行贴进 `~/.bashrc`，或写成 `~/dsv4run.sh`。）

**之后每次实验**：

```bash
dsv4sync     # 只取 debug 目录（不动 HEAD、不动其它文件）
dsv4run      # 跑 A~E，结论在 /tmp/dsv4_mxfp_sweep/report.txt
dsv4back     # 还原 token_dispatcher.py + 清掉调试目录
```

**外发只有一行**：`report.txt` 末尾的 `FINGERPRINT: A=... B=...`。

要点：`run.sh` 会**自动发现** `serve_8card.sh`（`$ROOT/../mix/`、`/home/*/AFD/mix/` 等），
所以"路径"这个变量也不用人敲。

## 1. 目前确认的事实（证据链）

| # | 事实 | 来源 |
|---|---|---|
| 1 | 失败发生在 `profile_run`（建 KV cache 前的 dummy run），失败算子 = `aclnnMoeInitRoutingV3` | 日志 `current working operator name is aclnnMoeInitRoutingV3` |
| 2 | 小 batch（`num_tokens=256 ≤ mc2_capacity=256`）走 `MC2`，正常 | `MoE comm method selected: ... method=MoECommType.MC2` |
| 3 | 大 batch（`num_tokens=2048`）走 `ALLTOALL`，紧接着就崩 | 同上，`method=MoECommType.ALLTOALL`，下一行即 probe，再下一行即 `ERR00100` |
| 4 | 该调用点的入参：`x=fp8_e4m3fn (N,4096)`、`x_dtype=fp8_e4m3fn`、`scale=e8m0 (N,64,2) dim=3`、`local_experts=32` | 探针输出 |
| 5 | i.e. **scale 的 dtype 和维度都是对的**（64×2 = 128 组 = 4096/32，group_size=32） | 同上 |
| 6 | 4 卡混布正常（同环境/同量化/同代码，只差卡数）；EP4 时 `world_size(4) ≤ top_k(4)` ⇒ 走 ALLGATHER | 你的对比 + `ascend_forward_context.py:337` |

⇒ 结论方向：**不是算子缺失、不是量化不支持、不是 scale 布局错**，而是
`ALLTOALL` 那条 MXFP 分支**传给 `npu_moe_init_routing_v2` 的参数组合**与 A5 的 OpDef 不符。
可疑点只有两个：

* 显式传了 `x_dtype=dst_type`（fp8）。同仓库别处是**刻意只放行** `float4_e2m1fn_x2 / hifloat8`
  的（`vllm_ascend/device/device_op.py` 的 `npu_moe_init_routing`），`vllm_ascend/device/mxfp_compat.py`
  的注释还专门写了 *"while float8_e4m3fn does not [need to be specified]"*——**约定不一致**。
* 没传 `quant_mode`（AllGather 那条传了 `quant_mode=3`）。

---

## 1.5 版本漂移警告（重要）

与上游 `vllm-project/vllm-ascend@main` 的 `vllm_ascend/ops/fused_moe/token_dispatcher.py` 对比，
**这个函数已经被重写过**：

| | 你手上的版本 | 上游 main |
|---|---|---|
| `_dispatch_postprocess` 的 MXFP 分支 | 有 `if scale_type == torch.float8_e8m0fnu:`，做 `.view(torch.float8_e8m0fnu)` 并传 `active_num` | **该分支已删除**；`scale` 直接传入，签名里去掉了 `scale_type` |
| `expert_num=` | `self.num_local_experts` | `self.num_experts` |
| MC2 + A5 MXFP | 只有老的 `quant_mode` 2/0 路径 | 新增 `hardware_profile`/`HardwareCapability`、A5 MXFP `quant_mode=4`、`y_dtype` 等 |
| `x_dtype=dst_type` | 传 | **仍然传**（所以若 `x_dtype` 真是元凶，上游也会中） |

含义：

1. 本目录的 A~E 补丁是按**你当前树的锚点**写的，只对你的版本有效（锚点不匹配会直接报错，不会改错）；
2. 你遇到的这个问题**可能在上游已经不存在**（那条分支已被重写）——所以"修老代码"未必是正确投入；
3. 若要向上游提 PR，必须基于上游最新代码重新分析，不能拿这里的补丁直接提。

查落后多少（绿区只读，无对外写入）：

```bash
git remote add upstream https://github.com/vllm-project/vllm-ascend.git 2>/dev/null || true
git fetch upstream
git rev-list --left-right --count main...upstream/main   # 左=本地领先，右=落后
git log --oneline -1 upstream/main
```

---

## 2. 怎么跑（一次一个变量）

中转机（可上外网，一条命令，发布调试分支）：

**Windows（PowerShell）**——只需 `git`，不需要 bash：

```powershell
pwsh -File dsv4-mxfp-debug\push_debug_branch.ps1
```

**Linux 中转机**：

```bash
I_AM_ON_TRANSFER_HOST=1 bash dsv4-mxfp-debug/push_debug_branch.sh
```

> Windows 手敲等价命令（6 行）：
> ```powershell
> git clone https://github.com/Pingzii/vllm-ascend.git $env:TEMP\afd-debug-tree
> New-Item -ItemType Directory -Force $env:TEMP\afd-debug-tree\dsv4-mxfp-debug | Out-Null
> Copy-Item D:\Application\vllm_projects\AFD-dpsv4\dsv4-mxfp-debug\* $env:TEMP\afd-debug-tree\dsv4-mxfp-debug\ -Recurse -Force
> cd $env:TEMP\afd-debug-tree
> git checkout -b debug/dsv4-mxfp-probe ; git add dsv4-mxfp-debug
> git commit -s -m "debug(dsv4): W4A8MXFP AllToAll routing variant switch + runbook" ; git push -u origin debug/dsv4-mxfp-probe
> ```

绿区（**只读**；只取 debug 目录，**不切分支、不动其它文件**）：

```bash
cd /home/s00988495/AFD/vllm-ascend
git fetch https://github.com/Pingzii/vllm-ascend.git debug/dsv4-mxfp-probe
git archive FETCH_HEAD dsv4-mxfp-debug | tar -x     # ← 关键：不要 git checkout 整个分支
bash dsv4-mxfp-debug/run.sh
# 结论：/tmp/dsv4_mxfp_sweep/report.txt
# 回退：bash dsv4-mxfp-debug/run.sh --revert && rm -rf dsv4-mxfp-debug
```

> **为什么必须是 `git archive` 而不是 `git checkout`**：本 fork 的 `main` 可能落后上游很多，
> `git checkout <debug分支>` 会把**整个工作区**降级到 fork-main 那个旧快照，而不是只加几个调试文件。
> `git archive FETCH_HEAD dsv4-mxfp-debug | tar -x` 只解出这一个目录，HEAD 与其它文件完全不动，
> 所以 fork 落后多少都不影响你。

`run_matrix.sh` 内部做完了这些（不用你手敲）：打补丁 → A~E 逐个起服务（出现启动成功或目标报错就提前退出）→ 日志落盘 → 生成 report.txt → 打印回退命令。

如果只想手工控制，等价操作是：

```bash
python3 dsv4-mxfp-debug/apply_mxfp_variants.py --root .
for V in A B C D E; do DSV4_MXFP_VARIANT=$V bash /path/to/serve_8card.sh 2>&1 | tee /tmp/8card_$V.log; done
python3 dsv4-mxfp-debug/apply_mxfp_variants.py --root . --revert
```

变体含义：

| 变体 | kwargs | 假设 |
|---|---|---|
| A | `scale + x_dtype=fp8` | 现状，**必须复现同一个错**，否则对照组不成立 |
| B | `scale`（去掉 `x_dtype`） | fp8 不该显式传 dtype ⇒ 一行删除即修复 |
| C | `scale + x_dtype + quant_mode=-1` | 需要显式"不量化、只排序" |
| D | `scale + x_dtype + quant_mode=3` | 需要 AllGather 那套 MXFP 融合量化模式 |
| E | `scale + quant_mode=17` | MXFP8 round-scale（若你从支持侧拿到过这个取值） |

判读：

* **B 过、A 挂** → 最可能，且能对上 `mxfp_compat.py` 的注释；修复 = 删掉 `x_dtype=dst_type`。
* **C 过** → 修复 = 补 `quant_mode=-1`。
* **D/E 过** → 说明这条分支想要"未量化输入 + 指定量化模式"，而 x 已经量化，属设计冲突，
  不要急着改，要先对齐语义。
* **全挂** → 才回到"环境/版本"，用 A~E 这 5 行 + 版本三元组去问支持。

**别省的一步**：任何"能让服务起来"的组合，都要做数值验证——同一批 greedy prompt，
8 卡新路径 vs 已知正常的 4 卡 ALLGATHER 路径，输出逐 token 一致。
scale 排列错不会报错，只会静默算错。

---

## 3. 提交与推送（这部分必须你来做）

确定正确入参后，**先把它做成正式修复**，再提交：

```bash
cd /home/s00988495/AFD/vllm-ascend
git status
git remote -v
# 若 origin 还不是你的 fork：
git remote set-url origin https://github.com/Pingzii/vllm-ascend.git

git checkout -b fix/mxfp-a2a-routing-args
# 1) 把 token_dispatcher.py 改回正式写法（不要留 DSV4_MXFP_VARIANT 调试开关、不要留 print）
# 2) 补一个单测（见下）
git diff
git add vllm_ascend/ops/fused_moe/token_dispatcher.py tests/ut/ops/a2/test_token_dispatcher.py
git commit -s -m "fix(moe): align A5 MXFP routing args in the AllToAll dispatcher" \
  -m "The AllToAll MXFP postprocess passes an already quantized fp8 activation plus an
e8m0 per-token scale into npu_moe_init_routing_v2 and additionally sets x_dtype.
On A5 that descriptor is rejected by the MoeInitRoutingV3 OpDef with
\"dtype or format ... inconsistent with OpDef\" / \"Cannot find binary\",
so EP8 colocated startup fails during profile_run. EP<=top_k keeps using the
AllGather path, which is why 4 cards worked." \
  -m "Tested: <填你实际跑的命令与结果>"
git push -u origin fix/mxfp-a2a-routing-args
```

提交前请对照仓库自己的规矩（`vllm-ascend/AGENTS.md`）：

* **必须有测试**：bug fix 要带回归用例；dispatcher 的 UT 目录是
  `tests/ut/ops/a2/test_token_dispatcher.py`（已有该文件，扩展现有用例优先）。
* 提交信息用 Conventional Commits 且**必须 `-s` 签名**（`git commit -s`）。
* PR 描述按 `.github/PULL_REQUEST_TEMPLATE.md`，并保留自动追加的
  `- vLLM version:` / `- vLLM main:` 两行。
* 人类提交者必须逐行 review 并实际跑过测试——**别把未经你验证的改动推上去**。

PR 正文可直接用这段（把 <> 补全）：

```markdown
### What this PR does / why we need it?
EP8 + W4A8MXFP colocated startup fails in profile_run with
`aclnnMoeInitRoutingV3 ... dtype or format ... inconsistent with OpDef`.
The AllToAll MXFP postprocess calls `npu_moe_init_routing_v2` with
`scale=<e8m0 (N,64,2)>` and `x_dtype=<fp8>`. EP<=top_k (e.g. 4 cards) uses the
AllGather path instead, which is why it was not hit before.
Fix: <一行改动说明>。

### Does this PR introduce _any_ user-facing change?
Yes: EP > top_k deployments with W4A8MXFP can start (previously crashed).

### How was this patch tested?
- UT: <tests/ut/ops/a2/test_token_dispatcher.py::...>
- E2E: DeepSeek-V4-Flash W4A8MXFP, 8xNPU, EP8: `vllm serve ... ` starts, profile_run passes.
- Accuracy: same greedy prompts vs 4-card EP4 (AllGather path), token-identical outputs.
```

---

## 4. 顺带：那个独立复现脚本为什么挂了

`torch.ones(...).npu().view(torch_npu.float8_e8m0fnu)` 报
`shape '[293]' is invalid for input of size 524288`——是**在卡上做 view(dtype) 不可靠**，
和你查的问题无关。改法：先在 CPU 上 view 再搬卡。

```python
sc_u8 = torch.ones(N, H // G // 2, 2, dtype=torch.uint8)
sc = sc_u8.view(torch_npu.float8_e8m0fnu).npu()   # CPU view → npu
```

不过更推荐直接用本文第 2 节的**在真实调用点做 A/B**：那里有一个货真价实的
e8m0 scale，不用自己造。
