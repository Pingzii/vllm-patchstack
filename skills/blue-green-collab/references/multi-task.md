# 多任务隔离

同一个补丁栈仓里可以并存多个任务；**一个任务 = 一个目录** `tasks/<task-id>/`，
自带 `manifest.tsv` / `patches/` / `debug/`，互不影响。

## 选择任务

```bash
bash /tmp/patchstack/scripts/green_run.sh --list              # 列出任务
bash /tmp/patchstack/scripts/green_run.sh --task afd-4a2f-bench
bash /tmp/patchstack/apply_all.sh  --root <repo> --task <id>
bash /tmp/patchstack/revert_all.sh --root <repo> --task <id>
```

只有一个任务时 `--task` 可省略；**有多个任务又没给 `--task` 会直接报错退出**（不猜）。

## 隔离规则（agent 必须遵守）

1. **一次实验只跑一个任务**：绝不把两个任务的补丁混在一次 apply 里——否则结论无法归因；
2. **两个任务改同一文件**：分两次实验跑；若必须叠加，在该任务 README 里写明顺序与理由；
3. **报告按任务分目录**：`/tmp/.../<task-id>/report.txt`；
4. **回传行带 task-id**：`FINGERPRINT <task-id>: A=ok B=...`；
5. **一个任务一份任务卡**：`tasks/<id>/README.md` 记录目标 / 环境画像 / base commit / 状态 / 结论；
6. **任务结束要收口**：状态改 `done`/`dropped`，写明结论与（若已上游化的）PR 链接；
7. **绝不跨任务复用 `debug/` 脚本**：那是当时那套假设的产物，拷过去会带错前提。

## 新增任务的最小步骤

```bash
mkdir -p tasks/<new-id>/{patches,debug}
# 写 tasks/<new-id>/manifest.tsv（至少表头注释 + 条目）
# 写 tasks/<new-id>/README.md（任务卡）
# 在 tasks/README.md 的登记表里加一行
```

然后：蓝区 `blue_publish.ps1` → 绿区 `dsv4sync && dsv4run --task <new-id>`。

## 与分支策略的关系

默认所有任务都在 `main` 上、靠目录隔离（绿区匿名 clone 最简单）。
需要冻结/评审某个任务时，才在补丁栈仓给它开 `task/<id>` 分支：

```bash
git checkout -b task/<id> && git push -u origin task/<id>
# 绿区： PATCHSTACK_URL 不变，改 clone 分支即可（仍只取目录，不 checkout 框架仓）
```

注意：**框架仓库（vllm-ascend 等）永远不切分支**——补丁只 apply 到工作区，跑完即还原。
