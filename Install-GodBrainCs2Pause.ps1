# Register the Steam-Play backup gate. Prefer Start-CS2.ps1 / Start-CS2.cmd.
# This 1-minute task only matters if CS2 is launched from Steam itself.

[CmdletBinding()]
param(
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"
$taskName = "GodBrainCs2Pause"
$repo = $PSScriptRoot
$watch = Join-Path $repo "Watch-Cs2Pause.ps1"

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task $taskName"
    return
}

if (-not (Test-Path -LiteralPath $watch)) {
    throw "Missing $watch"
}

$hidden = Join-Path $repo "godbrain_core\cpp_tools\run_hidden.exe"
if (-not (Test-Path -LiteralPath $hidden)) {
    throw "Missing $hidden — run Install-GodBrainWatch.ps1 once to build it"
}
# run_hidden + pwsh -File. Never a .cmd: cmd.exe flashes Windows Terminal.
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
$shell = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
$action = New-ScheduledTaskAction -Execute $hidden `
    -Argument "`"$shell`" -NoProfile -WindowStyle Hidden -NonInteractive -File `"$watch`" -RepoRoot `"$repo`"" `
    -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(20)) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Registered $taskName for $env:USERNAME every 1 minute."
Write-Host "Pauses mouth (coli/llama) + Tailscale + Watch/Logon while CS2.exe is running."
Write-Host "Resumes 5 minutes after CS2.exe exits. Does not uninstall Tailscale."
Write-Host "Remove with: .\Install-GodBrainCs2Pause.ps1 -Unregister"
