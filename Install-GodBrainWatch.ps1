# Register a current-user 5-minute keep-alive. Never LocalSystem.
# The watch script only starts missing listeners. It does not kill Colibri.

[CmdletBinding()]
param(
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"
$taskName = "GodBrainWatch"
$repo = $PSScriptRoot
$watch = Join-Path $repo "Watch-GodBrain.ps1"

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task $taskName"
    return
}

if (-not (Test-Path -LiteralPath $watch)) {
    throw "Missing $watch"
}

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
$shell = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

$tr = "`"$shell`" -NoProfile -WindowStyle Hidden -File `"$watch`" -RepoRoot `"$repo`""
# schtasks repetition is reliable on this host. Never /RU SYSTEM.
& schtasks.exe /Create /TN $taskName /SC MINUTE /MO 5 /IT /F /RL LIMITED `
    /TR $tr | Out-Host
$registered = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$registered.Settings.MultipleInstances = "IgnoreNew"
$registered.Settings.AllowDemandStart = $true
$registered.Settings.StartWhenAvailable = $true
$registered.Settings.DisallowStartIfOnBatteries = $false
$registered.Settings.StopIfGoingOnBatteries = $false
Set-ScheduledTask -InputObject $registered | Out-Null

Write-Host "Registered $taskName for $env:USERNAME every 5 minutes."
Write-Host "Starts missing rag/kernel/coli only. Never kills a running process."
Write-Host "Remove with: .\Install-GodBrainWatch.ps1 -Unregister"
