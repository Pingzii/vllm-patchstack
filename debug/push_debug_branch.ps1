# Blue zone / transfer host: publish this debug package to a branch of the fork.
#
#   powershell -ExecutionPolicy Bypass -File push_debug_branch.ps1
#
# NEVER run this in the green zone (read-only zone; outbound writes are a violation).
# NOTE: keep this file ASCII-only; Windows PowerShell 5.1 reads .ps1 as ANSI without BOM.
param(
    [string]$RepoUrl = "https://github.com/Pingzii/vllm-ascend.git",
    [string]$Branch  = "debug/dsv4-mxfp-probe"
)
$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$pkg  = Split-Path -Leaf $here
$work = Join-Path $env:TEMP ("afd-debug-tree-" + (Get-Random))

$name  = (git config --get user.name)  2>$null
$email = (git config --get user.email) 2>$null
if (-not $name)  { throw "set git config --global user.name first" }
if (-not $email) { throw "set git config --global user.email first" }

Write-Host "[push] repo=$RepoUrl branch=$Branch work=$work"

git clone --quiet --depth 1 $RepoUrl $work
if ($LASTEXITCODE -ne 0) { throw "clone failed: $RepoUrl" }
$dest = Join-Path $work $pkg
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $here '*') $dest -Force -Recurse -Exclude '__pycache__'

Set-Location $work
git checkout -B $Branch
git -c core.autocrlf=false add $pkg
git commit -q -s -m "debug(dsv4): W4A8MXFP AllToAll routing variant switch + runbook"
git push --quiet -u origin $Branch
"PUSH_EXIT=$LASTEXITCODE"
git log --oneline -1
