# Register a current-user 5-minute keep-alive. Never LocalSystem.
# The watch script only starts missing listeners. It does not kill the mouth.

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
# Watch infers RepoRoot from -File; do not pass -RepoRoot.
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
$shell = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
$action = New-ScheduledTaskAction -Execute $hidden `
    -Argument "`"$shell`" -NoProfile -File `"$watch`"" `
    -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(20)) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Registered $taskName for $env:USERNAME every 5 minutes."
Write-Host "Starts missing rag/kernel/mouth only. Never kills a running process."
Write-Host "Remove with: .\Install-GodBrainWatch.ps1 -Unregister"
