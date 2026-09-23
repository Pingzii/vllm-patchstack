# Blue zone / transfer host: publish the patch stack + debug package + this skill.
#
#   powershell -ExecutionPolicy Bypass -File scripts\blue_publish.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\blue_publish.ps1 -RepoUrl https://github.com/Pingzii/vllm-patchstack.git
#
# NEVER run this in the green zone: the green zone is read-only and any outbound
# write (push/upload) is a compliance violation.
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 as ANSI
# unless a BOM is present, so non-ASCII comments break parsing on CN systems.
param(
    [string]$RepoUrl    = "https://github.com/Pingzii/vllm-patchstack.git",
    [string]$Branch     = "main",
    [string]$Workspace  = "",
    [string]$Patchstack = "",
    [string]$DebugPkg   = "",
    [string]$SkillDir   = ""
)
$ErrorActionPreference = "Stop"

$skillRoot = Split-Path -Parent $PSScriptRoot
if (-not $Workspace)  { $Workspace  = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $skillRoot)) }
if (-not $Patchstack) { $Patchstack = Join-Path $Workspace 'vllm-patchstack' }
if (-not $DebugPkg)   { $DebugPkg   = Join-Path $Workspace 'dsv4-mxfp-debug' }
if (-not $SkillDir)   { $SkillDir   = $skillRoot }

if (-not (Test-Path (Join-Path $Patchstack 'manifest.tsv'))) { throw "patch stack working copy not found: $Patchstack" }
if (-not (git config --get user.name)) { throw "set git config --global user.name first" }

$work = Join-Path $env:TEMP ("patchstack-pub-" + (Get-Random))
$env:GIT_TERMINAL_PROMPT = '0'
Write-Host "[publish] repo=$RepoUrl"
Write-Host "[publish] patchstack=$Patchstack"
Write-Host "[publish] debug=$DebugPkg"
Write-Host "[publish] skill=$SkillDir"

git clone --quiet $RepoUrl $work
if ($LASTEXITCODE -ne 0) { throw "clone failed: $RepoUrl" }

# 1) patch stack itself
Copy-Item (Join-Path $Patchstack '*') $work -Recurse -Force
# 2) debug package (drop local caches)
if (Test-Path $DebugPkg) {
    New-Item -ItemType Directory -Force (Join-Path $work 'debug') | Out-Null
    Copy-Item (Join-Path $DebugPkg '*') (Join-Path $work 'debug\') -Recurse -Force -Exclude '__pycache__'
}
Remove-Item -Recurse -Force (Join-Path $work 'debug\__pycache__') -ErrorAction SilentlyContinue
# 3) this skill
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
