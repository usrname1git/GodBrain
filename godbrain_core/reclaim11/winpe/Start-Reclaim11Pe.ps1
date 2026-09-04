# WinPE door. Default is pack-A wipe after a 12s banner.
# Press H: skip Automatic Repair only. Failed help does not wipe.
# PowerShell 5.1 (WinPE) and 7 (Test-Reclaim11).
[CmdletBinding()]
param(
    [ValidateSet("Auto", "Help", "Wipe")]
    [string]$Door = "Auto",
    [int]$BannerSec = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($here)) { $here = $PWD.Path }
. (Join-Path $here "offline.ps1")

function Read-Reclaim11PeDoor {
    param(
        [int]$Seconds = 12,
        [string]$SrtHint = ""
    )
    Write-Host ""
    Write-Host "========================================"
    Write-Host "  Press H  Windows won't boot - help!"
    Write-Host ("  Pack A wipe starts in {0} seconds." -f $Seconds)
    if (-not [string]::IsNullOrWhiteSpace($SrtHint)) {
        Write-Host ("  {0}" -f $SrtHint)
    }
    Write-Host "========================================"
    $choice = Join-Path $env:SystemRoot "System32\choice.exe"
    if (-not (Test-Path -LiteralPath $choice)) {
        Start-Sleep -Seconds $Seconds
        return "Wipe"
    }
    cmd.exe /c "`"$choice`" /C HW /N /T $Seconds /D W"
    if ($LASTEXITCODE -eq 1) { return "Help" }
    "Wipe"
}

$srtHint = ""
try {
    foreach ($v in @(Find-Reclaim11WindowsVolumes)) {
        $srt = Join-Path $v.WindowsRoot "System32\LogFiles\Srt\SrtTrail.txt"
        if (Test-Path -LiteralPath $srt) {
            $srtHint = "Automatic Repair log found."
            break
        }
    }
} catch { }

$picked = $Door
if ($Door -eq "Auto") {
    $picked = Read-Reclaim11PeDoor -Seconds $BannerSec -SrtHint $srtHint
}

$skip = Join-Path $here "Skip-Reclaim11WinRe.ps1"
$apply = Join-Path $here "Apply-Reclaim11Offline.ps1"
if ($picked -eq "Help") {
    Write-Host "Windows won't boot - skip Automatic Repair. Pack A does not run."
    if (-not (Test-Path -LiteralPath $skip)) { throw "Start-Reclaim11Pe: missing Skip-Reclaim11WinRe.ps1" }
    & $skip
} else {
    Write-Host "Pack A wipe (default)."
    if (-not (Test-Path -LiteralPath $apply)) { throw "Start-Reclaim11Pe: missing Apply-Reclaim11Offline.ps1" }
    & $apply
}
