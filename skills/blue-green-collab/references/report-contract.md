# 回传契约与红线

## 1. 只回一行：`FINGERPRINT`

绿区实验脚本必须在报告末尾输出**一行**机器可读结论，形如：

```
FINGERPRINT: A=route_fail B=ok C=route_fail D=route_fail E=other
```

取值约定：

| 值 | 含义 |
|---|---|
| `ok` | 该变体启动成功（出现 `Application startup complete`） |
| `route_fail` | 复现目标故障（如 `MoeInitRoutingV3` 报错） |
| `other` | 其它失败（需附首个错误行） |
| `skip` / `n/a` | 未执行 |

回传内容：

1. **必需**：`FINGERPRINT:` 那一行；
2. **可选**：首个错误的**前 3~5 行**（只在这行不足以下判断时）；
3. **禁止**：整段多进程日志、代码、权重路径、内网拓扑、IP。

## 2. 绿区红线（合规）

* 绿区是**单向只读区**：只允许 `git clone/fetch`、本地改文件、跑本地进程、写 `/tmp`；
* **禁止**在绿区执行 `git push`、上传、把日志发到外部服务；
* 不要在绿区保留 git 状态（补丁栈 clone 到 `/tmp` 后删掉 `.git`）；
* 不要在绿区 `git checkout` 整个调试分支——那会把工作区降级到旧快照；只取目录：

```bash
git fetch <url> <branch>
git archive FETCH_HEAD <dir> | tar -x
```

## 3. 一次实验的最小清单

1. 蓝区：改 `patches/` 或 `debug/` → 更新 `manifest.tsv` → 本地 `bash -n` / `py_compile` 校验；
2. 蓝区：`pwsh -File scripts\blue_publish.ps1`；
3. 绿区：`dsv4sync && dsv4run`（= 同步 → 应用 → 跑 → 还原）；
4. 回传 `FINGERPRINT` 一行；
5. 蓝区：据此写正式修复（带回归测试）→ 重复 2~4；
6. 验证通过后：另开干净分支提上游（脱敏、带 `Signed-off-by`），`debug/` 永不进上游 PR。

## 4. 常见坑

| 坑 | 症状 | 处理 |
|---|---|---|
| CRLF 进了 shell 脚本 | 绿区 `bash: $'\r': command not found` | 发布时 `-c core.autocrlf=false`；已入仓的用 `sed -i 's/\r$//'` |
| 补丁锚点随上游漂移 | `git apply --check` 失败 | **不要**手改目标文件；在蓝区 rebase 补丁，更新 `manifest.tsv` 的 base 记录 |
| 实验把工作区改脏 | 下次实验基线不明 | `green_run.sh` 默认跑完即还原；用 `--keep` 才保留 |
| 把 fork 当传输通道 | fork 落后 → 整树被降级 | 只用补丁栈仓；只取目录，不切分支 |
| AI 声称"我做不到" | 白白手工搬运 | 先确认是策略限制还是沙箱/环境故障，**换模式重试一次**再下结论 |
