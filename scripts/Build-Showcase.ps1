[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$out = Join-Path $RepoRoot 'build\showcase'
[void][IO.Directory]::CreateDirectory($out)
$source = Join-Path $RepoRoot 'godbrain_core\cpp_tools\showcase.cpp'
$exe = Join-Path $out 'showcase.exe'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio x64 C++ tools are required.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$installer = Split-Path $vswhere -Parent
& cmd.exe /d /c "set `"PATH=$installer;%PATH%`" && call `"$vcvars`" >nul && cl /nologo /std:c++17 /EHsc /W4 /WX /O2 /Fe:`"$exe`" /Fo:`"$out\showcase.obj`" `"$source`" /link bcrypt.lib"
if ($LASTEXITCODE) { throw 'Native showcase build failed.' }
& $exe --self-test
if ($LASTEXITCODE) { throw 'Native showcase self-test failed.' }
