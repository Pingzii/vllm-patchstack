# 在「能上 GitHub 的 Windows 中转机」上执行：发布补丁栈仓库。
#   pwsh -File tools\publish.ps1
#   pwsh -File tools\publish.ps1 -RepoUrl https://github.com/Pingzii/vllm-patchstack.git
#
# 会把本目录内容 + ..\dsv4-mxfp-debug\*（作为 debug\）一起提交推送。
# 严禁在绿区执行（绿区单向只读）。
param(
    [string]$RepoUrl = "https://github.com/Pingzii/vllm-patchstack.git",
    [string]$Branch  = "main"
)
$ErrorActionPreference = "Stop"

$here  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)   # 仓库根
$debug = Join-Path (Split-Path -Parent $here) "dsv4-mxfp-debug"
$work  = Join-Path $env:TEMP ("patchstack-" + (Get-Random))

$name = (git config --get user.name) 2>$null
if (-not $name) { throw "先设置 git config --global user.name" }

Write-Host "[publish] repo=$RepoUrl work=$work"
git clone --quiet $RepoUrl $work          # 空仓也能 clone
if ($LASTEXITCODE -ne 0) { throw "clone 失败：$RepoUrl（仓库是否已创建？）" }

# 内容：本目录所有文件 + debug 包
Copy-Item (Join-Path $here '*') $work -Recurse -Force
New-Item -ItemType Directory -Force (Join-Path $work 'debug') | Out-Null
if (Test-Path $debug) {
    Copy-Item (Join-Path $debug '*') (Join-Path $work 'debug\') -Recurse -Force
} else {
    Write-Warning "找不到 $debug，debug\ 将为空"
}

Set-Location $work
git checkout -B $Branch
git -c core.autocrlf=false add -A
git commit -q -s -m "feat: vllm/vllm-ascend patch stack + DSv4 MXFP debug package"
git push -u origin $Branch
"PUSH_EXIT=$LASTEXITCODE"
git log --oneline -1