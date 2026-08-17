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
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
$shell = if ($pwsh) { $pwsh.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
# CREATE_NO_WINDOW child. Hidden pwsh and wscript still flash Windows Terminal.
$tr = "`"$hidden`" `"$shell`" -NoProfile -WindowStyle Hidden -File `"$watch`" -RepoRoot `"$repo`""
# schtasks only. Get-ScheduledTask CIM throws 0x8007054f on this host.
# Never /RU SYSTEM. /IT = only while this user is logged on.
& schtasks.exe /Create /TN $taskName /SC MINUTE /MO 5 /IT /F /RL LIMITED `
    /TR $tr | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "schtasks /Create failed with exit $LASTEXITCODE"
}

Write-Host "Registered $taskName for $env:USERNAME every 5 minutes."
Write-Host "Starts missing rag/kernel/coli only. Never kills a running process."
Write-Host "Remove with: .\Install-GodBrainWatch.ps1 -Unregister"
