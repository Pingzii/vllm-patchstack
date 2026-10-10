# Blue zone / transfer host: publish the patch stack.
#
#   powershell -ExecutionPolicy Bypass -File scripts\blue_publish.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\blue_publish.ps1 -Message "add mc2-dispatch-extscale"
#   powershell -ExecutionPolicy Bypass -File scripts\blue_publish.ps1 -DryRun
#
# Publishes THIS directory tree (changes only -- never a full framework tree) to
# the patch-stack repo. Clones the remote into a temp dir, overlays the local
# files, commits with sign-off, and pushes.
#
# NEVER run this from the green zone (it is read-only and must not push).
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 as ANSI
# when there is no BOM, so non-ASCII text here would be mangled.

[CmdletBinding()]
param(
    [string]$RepoUrl  = "https://github.com/Pingzii/vllm-patchstack.git",
    [string]$Branch   = "main",
    [string]$Message  = "chore(patchstack): sync tasks and probe",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Repo root = parent of this script's directory.
$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$work = Join-Path $env:TEMP ("patchstack-pub-" + (Get-Random))

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git not found on PATH"
}
$userName = (git config --get user.name) 2>$null
if (-not $userName) { throw "run: git config --global user.name ""Your Name"" (and user.email) first" }

Write-Host "[publish] source   : $here"
Write-Host "[publish] remote   : $RepoUrl ($Branch)"
Write-Host "[publish] work dir : $work"

if (Test-Path $work) { Remove-Item -Recurse -Force $work }

git clone --quiet $RepoUrl $work
if ($LASTEXITCODE -ne 0) { throw "git clone failed: $RepoUrl" }

# Overlay the local tree. Copy-Item will not delete remote-only files; stale
# files must be removed by hand if that ever matters.
Copy-Item (Join-Path $here '*') $work -Recurse -Force
Get-ChildItem -Path $work -Recurse -Force -Directory -Filter '__pycache__' |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Push-Location $work
try {
    git checkout -B $Branch | Out-Null

    $status = git status --porcelain
    if (-not $status) {
        Write-Host "[publish] nothing changed -- remote is already up to date."
        return
    }

    Write-Host "[publish] changes to commit:"
    $status | ForEach-Object { Write-Host "    $_" }

    if ($DryRun) {
        Write-Host "[publish] -DryRun: stopping before commit/push."
        return
    }

    # core.autocrlf=false keeps the shell scripts byte-identical for the green zone.
    git -c core.autocrlf=false add -A
    git -c core.autocrlf=false commit -q -s -m $Message
    if ($LASTEXITCODE -ne 0) { throw "git commit failed" }

    git push --quiet -u origin $Branch
    if ($LASTEXITCODE -ne 0) { throw "git push failed (check credentials / branch protection)" }

    Write-Host "[publish] OK"
    git log --oneline -1
    Write-Host ""
    Write-Host "[publish] green zone command:"
    Write-Host "  rm -rf /tmp/patchstack && git clone --quiet --depth 1 $RepoUrl /tmp/patchstack && rm -rf /tmp/patchstack/.git"
}
finally {
    Pop-Location
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
