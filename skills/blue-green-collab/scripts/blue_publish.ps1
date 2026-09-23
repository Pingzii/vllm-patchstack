# 蓝区/中转机：把工作区里的补丁栈 + debug 包 + 本 skill 发布到补丁栈仓库。
#
#   pwsh -File scripts\blue_publish.ps1
#   pwsh -File scripts\blue_publish.ps1 -RepoUrl https://github.com/Pingzii/vllm-patchstack.git
#
# 严禁在绿区执行（绿区单向只读，任何外发都违规）。
param(
    [string]$RepoUrl     = "https://github.com/Pingzii/vllm-patchstack.git",
    [string]$Branch      = "main",
    [string]$Workspace   = "",
    [string]$Patchstack  = "",
    [string]$DebugPkg    = "",
    [string]$SkillDir    = ""
)
$ErrorActionPreference = "Stop"

$skillRoot = Split-Path -Parent $PSScriptRoot                 # ...\blue-green-collab
if (-not $Workspace)  { $Workspace  = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $skillRoot)) }
if (-not $Patchstack) { $Patchstack = Join-Path $Workspace 'vllm-patchstack' }
if (-not $DebugPkg)   { $DebugPkg   = Join-Path $Workspace 'dsv4-mxfp-debug' }
if (-not $SkillDir)   { $SkillDir   = $skillRoot }

if (-not (Test-Path (Join-Path $Patchstack 'manifest.tsv'))) { throw "找不到补丁栈工作区: $Patchstack" }
if (-not (git config --get user.name)) { throw "先设置 git config --global user.name" }

$work = Join-Path $env:TEMP ("patchstack-pub-" + (Get-Random))
$env:GIT_TERMINAL_PROMPT = '0'
Write-Host "[publish] repo=$RepoUrl"
Write-Host "[publish] patchstack=$Patchstack"
Write-Host "[publish] debug=$DebugPkg"
Write-Host "[publish] skill=$SkillDir"

git clone --quiet $RepoUrl $work
if ($LASTEXITCODE -ne 0) { throw "clone 失败: $RepoUrl" }

# 1) 补丁栈本体
Copy-Item (Join-Path $Patchstack '*') $work -Recurse -Force
# 2) debug 包（去掉本地缓存）
if (Test-Path $DebugPkg) {
    New-Item -ItemType Directory -Force (Join-Path $work 'debug') | Out-Null
    Copy-Item (Join-Path $DebugPkg '*') (Join-Path $work 'debug\') -Recurse -Force -Exclude '__pycache__'
}
Remove-Item -Recurse -Force (Join-Path $work 'debug\__pycache__') -ErrorAction SilentlyContinue
# 3) 本 skill
$dest = Join-Path $work 'skills\blue-green-collab'
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $SkillDir '*') $dest -Recurse -Force -Exclude '__pycache__'

Set-Location $work
git checkout -B $Branch
git -c core.autocrlf=false add -A
git commit -q -s -m "chore(skill): sync blue-green-collab + debug package"
git push --quiet -u origin $Branch
"PUSH_EXIT=$LASTEXITCODE"
git log --oneline -1
git ls-tree -r --name-only HEAD