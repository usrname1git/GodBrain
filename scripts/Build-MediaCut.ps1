[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$out = Join-Path $RepoRoot 'build\media_cut'
[void][IO.Directory]::CreateDirectory($out)
$source = Join-Path $RepoRoot 'godbrain_core\cpp_tools\media_cut.cpp'
$exe = Join-Path $out 'media-cut.exe'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs -or $LASTEXITCODE) { throw 'Visual Studio x64 C++ tools are required.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$installer = Split-Path $vswhere -Parent
$compile = "cl /nologo /std:c++17 /EHsc /W4 /WX /O2 /Fe:`"$exe`" /Fo:`"$out\media_cut.obj`" `"$source`" /link bcrypt.lib"
& cmd.exe /d /c "set `"PATH=$installer;%PATH%`" && call `"$vcvars`" >nul && $compile"
if ($LASTEXITCODE) { throw 'Native media cutter build failed.' }
& $exe --self-test
if ($LASTEXITCODE) { throw 'Media interval self-tests failed.' }
