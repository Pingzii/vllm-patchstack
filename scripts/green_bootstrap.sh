#!/usr/bin/env bash
# 绿区一次性引导：打印（或安装）两个 alias。补丁栈每次由 dsv4sync 重新拉，所以 runner 自更新。
#
#   bash green_bootstrap.sh            # 只打印，自己贴
#   bash green_bootstrap.sh --install  # 追加到 ~/.bashrc（带标记，可重复执行）
set -euo pipefail

PATCHSTACK_URL="${PATCHSTACK_URL:-https://github.com/Pingzii/vllm-patchstack.git}"
PATCHSTACK="${PATCHSTACK:-/tmp/patchstack}"
MARK="# >>> blue-green-collab >>>"

BLOCK="$(cat <<EOF
$MARK
alias dsv4sync='rm -rf $PATCHSTACK && git clone --quiet --depth 1 $PATCHSTACK_URL $PATCHSTACK && rm -rf $PATCHSTACK/.git'
alias dsv4run='bash $PATCHSTACK/scripts/green_run.sh'
alias dsv4back='bash $PATCHSTACK/scripts/green_run.sh --revert'
# <<< blue-green-collab <<<
EOF
)"

if [[ "${1:-}" == "--install" ]]; then
  RC="$HOME/.bashrc"
  touch "$RC"
  if grep -qF "$MARK" "$RC"; then
    echo "已在 $RC 中存在标记，跳过（如需更新请先手工删除那段）"
  else
    printf '\n%s\n' "$BLOCK" >> "$RC"
    echo "已写入 $RC"
  fi
  echo "执行： source ~/.bashrc"
else
  echo "$BLOCK"
  echo
  echo "# 之后每次实验：  dsv4sync && dsv4run        （回退：dsv4back）"
fi
