# 回传契约与红线

## 1. 只回一行：数字码

绿区脚本跑完会打印一行 **`SEND THIS ONE LINE >>> <task-id> A0 B1 C0 D0 E2`**。
**只把这行原样抄回来**即可——全数字、无标点、无引号，抄写不可能走形。

编码表（脚本自动转换，不需要你记）：

| 结果词 | 数字 |
|---|---|
| `ok` | `1` |
| `route_fail` / 目标故障复现 | `0` |
| `other` | `2` |
| `skip` / `n/a` | `9` |
| 无报告 | `noreport` |

同时保留人类可读的 `FINGERPRINT <task-id>: A=route_fail B=ok ...` 行供核对；
**外发只用数字码那一行**。任务 id 前缀用于多任务隔离，别漏掉。

如果一定要贴日志，限**首个错误的 3~5 行**；禁止整段多进程日志、代码、权重路径、IP。

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
