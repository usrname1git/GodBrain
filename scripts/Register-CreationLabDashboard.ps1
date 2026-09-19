# Register a user scheduled task so Creation Lab :4177 is not a Grok Job Object child.
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent
if (Test-Path (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")) {
    . (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")
}
$exe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$arg = "-NoLogo -NoProfile -WindowStyle Hidden -File `"$PSScriptRoot\Invoke-FrontendGym.ps1`" -Command dashboard"
$action = New-ScheduledTaskAction -Execute $exe -Argument $arg -WorkingDirectory $RepoRoot
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName "GodBrainCreationLab" -Action $action -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Scheduled task GodBrainCreationLab registered hidden. Watch owns the console; open http://127.0.0.1:4177"
