# Register a current-user 5-minute keep-alive. Never LocalSystem.
# Host-only recovery by default; optional gym maintenance respects explicit release.

[CmdletBinding()]
param(
    [switch]$Unregister,
    [switch]$Enable,
    [switch]$WithGym
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

$hidden = Join-Path $repo "godbrain_core\cpp_tools\run_hidden.exe"
$hiddenSrc = Join-Path $repo "godbrain_core\cpp_tools\run_hidden.cpp"
if (-not (Test-Path -LiteralPath $hidden)) {
    if (-not (Test-Path -LiteralPath $hiddenSrc)) { throw "Missing $hiddenSrc" }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
    $dir = Split-Path $hiddenSrc -Parent
    cmd /c "call `"$vcvars`" >nul && cd /d `"$dir`" && cl /nologo /O2 /Fe:run_hidden.exe run_hidden.cpp /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $hidden)) {
        throw "failed to build $hidden"
    }
}
# run_hidden + pwsh -File. Never a .cmd: cmd.exe flashes Windows Terminal.
# Register-ScheduledTask (not schtasks /TR) so the line can be long.
# Pass RepoRoot explicitly and retain -File inference for manual callers.
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
$shell = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
$action = New-ScheduledTaskAction -Execute $hidden `
    -Argument "`"$shell`" -NoProfile -WindowStyle Hidden -NonInteractive -File `"$watch`" -RepoRoot `"$repo`"" `
    -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(20)) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew
$settings.Enabled = [bool]$Enable
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
if ($PSBoundParameters.ContainsKey("WithGym")) {
    $logs = Join-Path $repo "logs"
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $logs "afk-gym.txt") -Value $(if ($WithGym) { "on" } else { "off" })
}

Write-Host "Registered $taskName for $env:USERNAME every 5 minutes; enabled=$([bool]$Enable)."
Write-Host "AFK Heal attempts core/service recovery; Windows service starts require current-user SCM permissions."
Write-Host "The task remains Limited; it does not elevate model/gym processes or grant service permissions."
Write-Host "Default is disabled. Enable Watch from the desk when AFK, or install with -Enable."
Write-Host "Host recovery only by default; -WithGym opts into Qwen/gym recovery."
Write-Host "Remove with: .\Install-GodBrainWatch.ps1 -Unregister"
