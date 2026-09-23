# vllm-patchstack

针对 vLLM / vllm-ascend / afd-plugin 等框架侧改动的**统一补丁栈**：一处存放、可校验、可回退、可评审。

## 为什么单独一个仓

原来的做法是 fork 既当"上游镜像"、又当"我的改动"、又当"给绿区的传输通道"，三个角色混在一起：
fork 一落后，就分不清"落后"到底影响什么。拆开之后：

| 关注点 | 现在的归属 |
|---|---|
| 上游代码 | 绿区自己那份检出（它是什么版本，就测什么版本） |
| 我们的改动 | **本仓**（补丁/脚本，按 base commit 记录） |
| 传输通道 | 本仓（体积小，绿区匿名 `git clone` 即可） |
| 提 PR | 需要时从本仓的补丁另开干净分支，rebase 到上游最新 |

## 目录

```
.
├── README.md
├── manifest.tsv          # 补丁清单：repo / kind / path / 说明（TSV，bash 免依赖解析）
├── apply_all.sh          # 应用（patch 走 git apply --check 校验；script 走自身 --root）
├── revert_all.sh         # 逆序回退
├── patches/
│   ├── vllm-ascend/      # 0001-xxx.patch ...
│   ├── vllm/
│   └── afd-plugin/
├── debug/                # 诊断包（run.sh / run_matrix.sh / apply_mxfp_variants.py ...）
└── tools/publish.ps1     # 在 Windows 中转机上发布本仓内容
```

## base 版本（对照用，务必随绿区现状更新）

| 仓库 | base commit | 备注 |
|---|---|---|
| vllm-ascend | `<待填>` | 绿区 `git -C <repo> rev-parse --short HEAD` |
| vLLM | `<待填>` | |
| afd-plugin | `<待填>` | |

> 上游一动，`apply_all.sh` 的 `git apply --check` 会失败并**明确报错**（不静默改错），
> 提示该补丁需要 rebase。

## 绿区用法（一次性 alias + 每次两个词）

```bash
# 一次性（走已批准通道输入）
alias dsv4sync='rm -rf /tmp/patchstack && git clone --quiet --depth 1 https://github.com/Pingzii/vllm-patchstack.git /tmp/patchstack && rm -rf /tmp/patchstack/.git'
alias dsv4apply='cd /home/s00988495/AFD/vllm-ascend && bash /tmp/patchstack/apply_all.sh --root .'
alias dsv4back='cd /home/s00988495/AFD/vllm-ascend && bash /tmp/patchstack/revert_all.sh --root .'

# 每次
dsv4sync && dsv4apply && bash /tmp/patchstack/debug/run.sh
dsv4back
```

`/tmp/patchstack/.git` 会被删掉——绿区不留 git 状态，也不做任何对外写入。

## 加新改动的规范

1. 能做成 diff 的，放 `patches/<repo>/NNNN-短描述.patch`，并写清 base commit；
2. 一次性/诊断性的，放 `debug/`，保持"幂等 + 锚点校验 + `--revert`"三件套；
3. 每加一项，在 `manifest.tsv` 里加一行；
4. 补丁只装"改动"，**不要装整棵树**——这是这个仓存在的意义。
