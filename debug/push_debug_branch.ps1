# 在「能上 GitHub 的 Windows 机器」上执行：把 dsv4-mxfp-debug 发布到 fork 的调试分支，
# 供绿区（Linux，只读）git pull。
#
#   pwsh -File push_debug_branch.ps1
#   pwsh -File push_debug_branch.ps1 -Branch debug/dsv4-mxfp-probe
#
# ⚠️ 严禁在绿区执行：绿区是单向只读区，向 GitHub 写入属信息外发违规。
param(
    [string]$RepoUrl = "https://github.com/Pingzii/vllm-ascend.git",
    [string]$Branch  = "debug/dsv4-mxfp-probe"
)

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg  = Split-Path -Leaf $here
$work = Join-Path $env:TEMP ("afd-debug-tree-" + (Get-Random))

$name  = (git config --get user.name)  2>$null
$email = (git config --get user.email) 2>$null
if (-not $name)  { throw "先设置：git config --global user.name  <你的名字>" }
if (-not $email) { throw "先设置：git config --global user.email <你的邮箱>" }

# Windows 上保持行尾不被改写（bash 脚本吃了 CRLF 会在绿区报 $'\r'）
$git = { git -c core.autocrlf=false @args }

Write-Host "[push] repo=$RepoUrl"
Write-Host "[push] branch=$Branch"
Write-Host "[push] work=$work"

& $git clone --depth 1 $RepoUrl $work
$dest = Join-Path $work $pkg
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $here "*") $dest -Force -Recurse

Push-Location $work
try {
    & $git checkout -B $Branch
    & $git add $pkg
    & $git commit -s -m "debug(dsv4): W4A8MXFP AllToAll routing variant switch + runbook"
    & $git push -u origin $Branch
}
finally {
    Pop-Location
}

Write-Host @"

[push] 已推送 $Branch
[push] 绿区（Linux，只读）执行：
    cd /home/s00988495/AFD/vllm-ascend
    git fetch $RepoUrl $Branch
    git checkout -B $Branch FETCH_HEAD
    bash dsv4-mxfp-debug/run.sh            # 结论：/tmp/dsv4_mxfp_sweep/report.txt
    bash dsv4-mxfp-debug/run.sh --revert   # 回退（或 git checkout -）
[push] 外发只回 report.txt 末尾那一行 FINGERPRINT。
"@
