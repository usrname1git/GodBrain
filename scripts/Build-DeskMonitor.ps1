[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = "Stop"
$source = Join-Path $RepoRoot "godbrain_core\cpp_tools\desk_monitor.cpp"
$exe = Join-Path $RepoRoot "godbrain_core\cpp_tools\desk-monitor.exe"
$objects = Join-Path $RepoRoot "build\desk_monitor"
if (-not (Test-Path -LiteralPath $source)) { throw "Missing monitor source: $source" }
New-Item -ItemType Directory -Path $objects -Force | Out-Null
$vcvars = $null
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) { throw "Visual Studio C++ tools are required." }
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ([string]::IsNullOrWhiteSpace($vsPath)) { throw "Visual Studio x64 C++ tools were not found." }
    $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path -LiteralPath $vcvars)) { throw "Missing compiler environment: $vcvars" }
}
$compile = "cl /nologo /std:c++17 /EHsc /W4 /WX /O2 /Fe:`"$exe`" /Fo:`"$objects\desk_monitor.obj`" `"$source`" /link dxva2.lib user32.lib"
if ($vcvars) {
    $installer = Split-Path $vswhere -Parent
    & cmd.exe /d /c "set `"PATH=$installer;%PATH%`" && call `"$vcvars`" >nul && $compile"
}
else { & cmd.exe /d /c $compile }
if ($LASTEXITCODE -ne 0) { throw "Desk monitor build failed: exit $LASTEXITCODE" }
& $exe --self-test
if ($LASTEXITCODE -ne 0) { throw "Desk monitor offline tests failed." }
Write-Host "Built $exe"
