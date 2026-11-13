[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$out = Join-Path $RepoRoot 'build\desk_shell'
[void][IO.Directory]::CreateDirectory($out)
$source = Join-Path $RepoRoot 'godbrain_core\cpp_tools\desk_shell.cpp'
$exe = Join-Path $out 'desk-shell.exe'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs -or $LASTEXITCODE) { throw 'Visual Studio x64 C++ tools are required.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$installer = Split-Path $vswhere -Parent
$compile = "cl /nologo /std:c++17 /EHsc /W4 /WX /O2 /Fe:`"$exe`" /Fo:`"$out\desk_shell.obj`" `"$source`" /link /SUBSYSTEM:WINDOWS /ENTRY:wmainCRTStartup shell32.lib ole32.lib propsys.lib advapi32.lib user32.lib bcrypt.lib"
& cmd.exe /d /c "set `"PATH=$installer;%PATH%`" && call `"$vcvars`" >nul && $compile"
if ($LASTEXITCODE) { throw 'Desk shell build failed.' }
. (Join-Path $PSScriptRoot 'GodBrain-DeskShell.ps1')
$test = Invoke-DeskShell '--self-test'
if ($test.status -ne 'pass') { throw 'Desk shell quoting tests failed.' }
$test | ConvertTo-Json -Compress
