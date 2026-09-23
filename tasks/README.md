# 任务登记表（多任务隔离）

**一个任务 = 一个目录**（`tasks/<task-id>/`），目录内自带 `manifest.tsv`、`patches/`、`debug/`。
脚本按 `--task <id>` 选择任务；只有一个任务时可省略该参数。

## 任务清单

| task-id | 标题 | 状态 | base（对照） | 最近结论 |
|---|---|---|---|---|
| `dsv4-mxfp-a2a` | DSv4-Flash W4A8MXFP：EP8 混布 ALLTOALL routing 入参 | 进行中（等绿区 A~E 结果） | vllm-ascend `<待填>` | — |

> 新增任务：`cp -r tasks/dsv4-mxfp-a2a tasks/<new-id>` 后清空内容，或直接建目录 + `manifest.tsv`，
> 然后在本表登记一行。

## 命名与隔离规则

1. **task-id 用 kebab-case 且语义化**：`dsv4-mxfp-a2a`、`afd-4a2f-bench`、`upgrade-0.26`；
2. **一次实验只跑一个任务**：绝不把两个任务的补丁混在一次 `apply` 里，否则无法归因；
3. **两个任务改同一个文件**时：分两次实验跑，或在一个任务里显式写明应用顺序；
4. **产物隔离**：绿区报告按任务分目录 `/tmp/.../<task-id>/report.txt`，互不覆盖；
5. **回传隔离**：`FINGERPRINT` 行前带 task-id（`FINGERPRINT <task-id>: ...`），避免张冠李戴；
6. **任务完成/放弃**：在 `tasks/<id>/README.md` 里写结论，状态改为 `done`/`dropped`，
   `debug/` 保留（它记录了当时怎么验的），补丁若已进上游就标注 PR 链接。

## 目录

```
tasks/
├── README.md                 # 本文件（登记表 + 规则）
└── <task-id>/
    ├── README.md             # 任务卡：目标 / 环境画像 / base commit / 状态 / 结论
    ├── manifest.tsv          # 该任务的改动清单
    ├── patches/<repo>/       # 该任务的补丁（含 base 说明）
    └── debug/                # 该任务的一次性诊断脚本（幂等 + 锚点校验 + --revert）
```

任务之间**不共享** `manifest.tsv`；根目录的 `apply_all.sh` / `revert_all.sh` 是公共工具。
