# Blue zone / transfer host: publish the patch stack repository.
#
#   powershell -ExecutionPolicy Bypass -File tools\publish.ps1
#   powershell -ExecutionPolicy Bypass -File tools\publish.ps1 -RepoUrl https://github.com/Pingzii/vllm-patchstack.git
#
# Copies this directory plus ..\dsv4-mxfp-debug\* (as debug\) and commits + pushes.
# NEVER run this in the green zone (read-only zone).
# NOTE: keep this file ASCII-only; Windows PowerShell 5.1 reads .ps1 as ANSI without BOM.
param(
    [string]$RepoUrl = "https://github.com/Pingzii/vllm-patchstack.git",
    [string]$Branch  = "main"
)
$ErrorActionPreference = "Stop"

$here  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$debug = Join-Path (Split-Path -Parent $here) "dsv4-mxfp-debug"
$work  = Join-Path $env:TEMP ("patchstack-pub2-" + (Get-Random))

$name = (git config --get user.name) 2>$null
if (-not $name) { throw "set git config --global user.name first" }

Write-Host "[publish] repo=$RepoUrl work=$work"
git clone --quiet $RepoUrl $work
if ($LASTEXITCODE -ne 0) { throw "clone failed: $RepoUrl" }

Copy-Item (Join-Path $here '*') $work -Recurse -Force
New-Item -ItemType Directory -Force (Join-Path $work 'debug') | Out-Null
if (Test-Path $debug) {
    Copy-Item (Join-Path $debug '*') (Join-Path $work 'debug\') -Recurse -Force -Exclude '__pycache__'
} else {
    Write-Warning "debug package not found: $debug"
}
Remove-Item -Recurse -Force (Join-Path $work 'debug\__pycache__') -ErrorAction SilentlyContinue

Set-Location $work
git checkout -B $Branch
git -c core.autocrlf=false add -A
git commit -q -s -m "chore: sync patch stack + debug package"
git push --quiet -u origin $Branch
"PUSH_EXIT=$LASTEXITCODE"
git log --oneline -1
