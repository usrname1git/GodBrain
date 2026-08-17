# Play CS2 with the 4080 free and Tailscale off. Pause GodBrain first,
# launch via Steam, wait until CS2.exe exits, wait 5 more minutes, then
# wake the mouth and bring Tailscale back. Never uninstall or --reset.
# Prefer this over clicking Play in Steam. Watch-Cs2Pause is the backup.

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [int]$ResumeDelayMinutes = 5,
    [int]$AppearTimeoutMinutes = 10,
    [string]$SteamExe = "C:\Program Files (x86)\Steam\steam.exe",
    [int]$AppId = 730
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $MyInvocation.MyCommand.Path) {
    $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    throw "Start-CS2: RepoRoot is empty."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

$helper = Join-Path $RepoRoot "GodBrain-Cs2.ps1"
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Start-CS2: missing $helper"
}
. $helper

if (-not (Test-Path -LiteralPath $SteamExe)) {
    throw "Start-CS2: Steam not at $SteamExe"
}

function Set-StartCs2ConsoleVisible([bool]$Show) {
    # Add-Type compiles C# and dies if LIB points at a missing WDK path
    # (common on this box). Never let hide/show abort the CS2 waiter.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $savedLib = $env:LIB
    $savedInc = $env:INCLUDE
    try {
        $env:LIB = $null
        $env:INCLUDE = $null
        if (-not ("GodBrain.Cs2Native" -as [type])) {
            Add-Type -Namespace GodBrain -Name Cs2Native -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
"@
        }
        $hwnd = [GodBrain.Cs2Native]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            $cmd = 0
            if ($Show) { $cmd = 1 }
            [void][GodBrain.Cs2Native]::ShowWindow($hwnd, $cmd)
        }
    } catch {
        Write-Host "Start-CS2: console hide/show skipped ($($_.Exception.Message))"
    } finally {
        $env:LIB = $savedLib
        $env:INCLUDE = $savedInc
        $ErrorActionPreference = $oldEap
    }
}

Write-Host "Start-CS2: pausing GodBrain before launch"
Suspend-GodBrainForCs2 $RepoRoot
# This script owns the wait. Do not let the 1-min backup task spawn a window.
Set-GodBrainTaskEnabled "GodBrainCs2Pause" $false

Write-Host ("Start-CS2: launching Steam app {0}" -f $AppId)
Start-Process -FilePath $SteamExe -ArgumentList @("-applaunch", "$AppId")

$appearDeadline = (Get-Date).AddMinutes($AppearTimeoutMinutes)
Write-Host ("Start-CS2: waiting up to {0} min for CS2.exe" -f $AppearTimeoutMinutes)
while (-not (Test-Cs2Running)) {
    if ((Get-Date) -gt $appearDeadline) {
        Write-Host "Start-CS2: CS2.exe never appeared. Not starting GLM. Run Start-GodBrain.ps1 when you want it."
        Set-GodBrainTaskEnabled "GodBrainCs2Pause" $true
        exit 2
    }
    Start-Sleep -Seconds 3
}

Write-Host "Start-CS2: CS2.exe is up. GPU is yours. Hiding this window so CS2 stays exclusive."
$state = Read-Cs2PauseState $RepoRoot
$state.last_seen = (Get-Date).ToUniversalTime().ToString("o")
$state.paused = $true
$state.last_action = "pause"
Write-Cs2PauseState $RepoRoot $state
Set-StartCs2ConsoleVisible $false
while (Test-Cs2Running) {
    Start-Sleep -Seconds 30
}

Set-StartCs2ConsoleVisible $true
Write-Host ("Start-CS2: CS2 exited. Waiting {0} min before waking GodBrain." -f $ResumeDelayMinutes)
$state = Read-Cs2PauseState $RepoRoot
$state.last_seen = (Get-Date).ToUniversalTime().ToString("o")
$state.paused = $true
$state.last_action = "pause"
Write-Cs2PauseState $RepoRoot $state
Start-Sleep -Seconds ($ResumeDelayMinutes * 60)

if (Test-Cs2Running) {
    Write-Host "Start-CS2: CS2 came back. Staying paused."
    exit 0
}

Set-GodBrainTaskEnabled "GodBrainCs2Pause" $true
Resume-GodBrainAfterCs2 $RepoRoot
Write-Host "Start-CS2: done"
exit 0
