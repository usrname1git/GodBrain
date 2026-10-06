# Operator-controlled AFK loop. Host recovery is Heal; gym/Qwen is opt-in.
# The scheduled tick and manual continuous door share one mutex.

[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [switch]$WithGym,
    [switch]$Continuous,
    [switch]$Resume
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
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
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

. (Join-Path $RepoRoot "GodBrain-Cs2.ps1")
$pauseFile = Join-Path $logDir "afk-pause.txt"
if ($Resume) {
    Clear-GodBrainCs2Pause $RepoRoot
    [System.IO.File]::WriteAllText($pauseFile, "off`n", $utf8)
}
$hash = [System.Security.Cryptography.SHA256]::Create()
$key = [BitConverter]::ToString($hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($RepoRoot.ToLowerInvariant()))).Replace("-", "")
$hash.Dispose()
$mutex = New-Object System.Threading.Mutex($false, ("Global\GodBrainAfk-" + $key))
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) {
        Write-Host "watch: another AFK loop owns this repository; skipped"
        return
    }
    do {
        if ((Test-Path -LiteralPath $pauseFile) -and
            (Get-Content -LiteralPath $pauseFile -Raw -ErrorAction Stop).Trim() -eq "on") {
            Write-WatchLog "manual stop"
            break
        }
        if (Test-GodBrainColiShouldSleep $RepoRoot) {
            Write-WatchLog "skip: CS2 running or manual hold"
        } else {
            Write-WatchLog "afk tick gym=$([bool]$WithGym)"
            try {
                $global:LASTEXITCODE = 0
                & $heal -RepoRoot $RepoRoot -Afk
                if ($LASTEXITCODE -ne 0) { throw "AFK Heal failed (exit $LASTEXITCODE); gym recovery skipped." }
                if ((Test-Path -LiteralPath $pauseFile) -and
                    (Get-Content -LiteralPath $pauseFile -Raw -ErrorAction Stop).Trim() -eq "on") {
                    Write-WatchLog "manual stop after Heal; skipped gym"
                    break
                }
                $gymPolicy = Join-Path $logDir "afk-gym.txt"
                $gymEnabled = $WithGym -or ((Test-Path -LiteralPath $gymPolicy) -and
                    (Get-Content -LiteralPath $gymPolicy -Raw -ErrorAction Stop).Trim() -eq "on")
                if ($gymEnabled) {
                    $global:LASTEXITCODE = 0
                    & (Join-Path $RepoRoot "scripts\Invoke-FrontendGymMaintenance.ps1") -RepoRoot $RepoRoot
                    if ($LASTEXITCODE -ne 0) { throw "AFK gym maintenance failed (exit $LASTEXITCODE)." }
                }
                Write-WatchLog "afk tick finished"
            } catch {
                Write-WatchLog ("afk failure: {0}" -f $_)
                if (-not $Continuous) { throw }
                Write-Warning ("AFK tick failed; retry in 15 seconds: {0}" -f $_)
            }
        }
        if ($Continuous) { Start-Sleep -Seconds 15 }
    } while ($Continuous)
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
