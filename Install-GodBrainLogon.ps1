# Register or remove a current-user logon task. Does not use LocalSystem.

[CmdletBinding()]
param(
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"
$taskName = "GodBrainLogon"
$repo = $PSScriptRoot
$starter = Join-Path $repo "Start-GodBrain.ps1"

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task $taskName"
    return
}

if (-not (Test-Path -LiteralPath $starter)) {
    throw "Missing $starter"
}

$hidden = Join-Path $repo "godbrain_core\cpp_tools\run_hidden.exe"
if (-not (Test-Path -LiteralPath $hidden)) {
    throw "Missing $hidden — run Install-GodBrainWatch.ps1 once to build it"
}
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
$shell = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

$action = New-ScheduledTaskAction -Execute $hidden `
    -Argument "`"$shell`" -NoProfile -WindowStyle Hidden -NonInteractive -File `"$starter`"" `
    -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Registered $taskName for $env:USERNAME at logon."
Write-Host "Starts (if binaries exist): rag-service :8084, mouth :8000 (llama or coli), kernel :8083"
Write-Host "Mongo is not started here; keep its own Windows service."
Write-Host "Remove with: .\Install-GodBrainLogon.ps1 -Unregister"