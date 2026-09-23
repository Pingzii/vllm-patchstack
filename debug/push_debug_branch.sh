#!/usr/bin/env bash
# ⚠️ 只能在「可上外网的中转机」上执行 —— 本脚本会 clone/commit/push 到 GitHub。
#    严禁在绿区（隔离区）执行：绿区是**单向只读**，任何从绿区向外的写入都是信息违规。
#
# 用法（中转机）：
#   I_AM_ON_TRANSFER_HOST=1 bash push_debug_branch.sh
#   I_AM_ON_TRANSFER_HOST=1 BRANCH=debug/dsv4-mxfp-probe bash push_debug_branch.sh
#
# 注意：这是**调试分支**，不要向 vllm-project/vllm-ascend 开 PR。
set -euo pipefail

# 合规护栏：必须显式确认自己在具备外发权限的中转机上
if [[ "${I_AM_ON_TRANSFER_HOST:-0}" != "1" ]]; then
  cat >&2 <<'EOF'
[拒绝执行] 本脚本会向 GitHub 写入（clone / commit / push）。
           绿区是单向只读区，执行它等于信息外发 —— 必须在中转机上跑。
           确认无误后请加环境变量：
               I_AM_ON_TRANSFER_HOST=1 bash push_debug_branch.sh
EOF
  exit 3
fi

REPO_URL="${REPO_URL:-https://github.com/Pingzii/vllm-ascend.git}"
BRANCH="${BRANCH:-debug/dsv4-mxfp-probe}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(basename "$HERE")"
WORK="${WORK:-$(mktemp -d)}"

git config --get user.name  >/dev/null || { echo "先设置：git config --global user.name  <你的名字>"  >&2; exit 2; }
git config --get user.email >/dev/null || { echo "先设置：git config --global user.email <你的邮箱>" >&2; exit 2; }

echo "[push] repo=$REPO_URL"
echo "[push] branch=$BRANCH"
echo "[push] work=$WORK"

git clone --depth 1 "$REPO_URL" "$WORK/repo"
mkdir -p "$WORK/repo/$PKG"

shopt -s nullglob
files=("$HERE"/*.py "$HERE"/*.sh "$HERE"/*.md)
((${#files[@]})) && cp -f "${files[@]}" "$WORK/repo/$PKG/"

cd "$WORK/repo"
git checkout -B "$BRANCH"
git add "$PKG"
git commit -s -m "debug(dsv4): W4A8MXFP AllToAll routing variant switch + runbook"
git push -u origin "$BRANCH"

cat <<EOF

[push] 已推送 $BRANCH
[push] 绿区执行：
    cd <vllm-ascend 检出目录>
    git fetch origin
    git checkout $BRANCH
    bash $PKG/run_matrix.sh                 # 结论落在 /tmp/dsv4_mxfp_sweep/report.txt
    bash $PKG/run_matrix.sh --revert        # 回退（或 git checkout main）
[push] 只把 report.txt（约 20 行）贴回来，不要回传代码或整段日志。
EOF
