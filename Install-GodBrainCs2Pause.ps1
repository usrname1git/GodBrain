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

$tools = Join-Path $repo "godbrain_core\cpp_tools"
$hidden = Join-Path $tools "run_hidden.exe"
if (-not (Test-Path -LiteralPath $hidden)) {
    throw "Missing $hidden — run Install-GodBrainWatch.ps1 once to build it"
}
$gate = Join-Path $tools "cs2_gate.exe"
$gateSrc = Join-Path $tools "cs2_gate.cpp"
if (-not (Test-Path -LiteralPath $gate)) {
    if (-not (Test-Path -LiteralPath $gateSrc)) { throw "Missing $gateSrc" }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
    cmd /c "call `"$vcvars`" >nul && cd /d `"$tools`" && cl /nologo /O2 /Fe:cs2_gate.exe cs2_gate.cpp /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $gate)) {
        throw "failed to build $gate"
    }
}
# WINDOWS-subsystem gate. No pwsh unless CS2 is up or pause-state is set.
$action = New-ScheduledTaskAction -Execute $gate -WorkingDirectory $repo
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
Write-Host "Resumes 10 minutes after CS2.exe exits. Does not uninstall Tailscale."
Write-Host "Remove with: .\Install-GodBrainCs2Pause.ps1 -Unregister"
