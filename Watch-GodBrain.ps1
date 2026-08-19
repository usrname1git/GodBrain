# Same loop as Heal, on a timer. Discover → start missing → verify.
# Never stops or deletes anything. Not a graph, not a second agent.
# Safe to run every few minutes as the logged-in user (not LocalSystem).

[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"
# $PSScriptRoot in a param() default is empty when Task Scheduler launches -File.
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $RepoRoot = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "Watch-GodBrain: RepoRoot is empty."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$heal = Join-Path $RepoRoot "Heal-GodBrain.ps1"
if (-not (Test-Path -LiteralPath $heal)) {
    throw "Watch-GodBrain: missing $heal"
}

$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$watchLog = Join-Path $logDir "watch.log"
$utf8 = New-Object System.Text.UTF8Encoding $false
if ((Test-Path -LiteralPath $watchLog) -and ((Get-Item -LiteralPath $watchLog).Length -gt 256KB)) {
    $keep = Get-Content -LiteralPath $watchLog -Tail 200
    [System.IO.File]::WriteAllLines($watchLog, $keep, $utf8)
}
function Write-WatchLog([string]$Message) {
    $line = "{0:u} {1}" -f (Get-Date).ToUniversalTime(), $Message
    [System.IO.File]::AppendAllText($watchLog, $line + "`n", $utf8)
}

# Closed loop: detect → start missing allowlist → diagnose → maybe
# flushdns → verify → remember. Never kills the mouth or anything else.
# Watch-Cs2Pause disables this task while CS2.exe is running.
Write-WatchLog "start root=$RepoRoot"
try {
    & $heal -RepoRoot $RepoRoot
    Write-WatchLog ("heal exit={0}" -f $LASTEXITCODE)
} catch {
    Write-WatchLog ("heal throw: {0}" -f $_)
    throw
}
