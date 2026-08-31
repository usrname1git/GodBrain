# Noninteractive kernel compile. Does not start the kernel, Mongo, or the mouth.
# From repo root: .\scripts\Build-Kernel.ps1
# Backups go outside git (C:\nvme\godbrain-kernel-bak or %LOCALAPPDATA%\GodBrain\kernel-bak).

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [switch]$SkipBackup
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")

$kernelDir = Join-Path $RepoRoot "godbrain_core\cpp_kernel"
$exe = Join-Path $kernelDir "godbrain-kernel.exe"
if (-not (Test-Path -LiteralPath (Join-Path $kernelDir "main.cpp"))) {
    throw "Build-Kernel: missing $kernelDir\main.cpp"
}

function Find-Vcvars64 {
    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($cl) { return $null }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "Build-Kernel: cl.exe is not on PATH and vswhere.exe is missing"
    }
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ([string]::IsNullOrWhiteSpace($vsPath)) {
        throw "Build-Kernel: no Visual Studio C++ x64 tools installed"
    }
    $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path -LiteralPath $vcvars)) {
        throw "Build-Kernel: missing $vcvars"
    }
    return $vcvars
}

if (-not $SkipBackup -and (Test-Path -LiteralPath $exe)) {
    $bakRoot = if (Test-Path -LiteralPath "C:\nvme") {
        "C:\nvme\godbrain-kernel-bak"
    } else {
        Join-Path $env:LOCALAPPDATA "GodBrain\kernel-bak"
    }
    if (-not (Test-Path -LiteralPath $bakRoot)) {
        New-Item -ItemType Directory -Path $bakRoot | Out-Null
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item -LiteralPath $exe -Destination (Join-Path $bakRoot "godbrain-kernel.exe.bak_$stamp") -Force
}

$vcvars = Find-Vcvars64
$sources = "main.cpp kernel.cpp surgery.cpp telemetry.cpp memory.cpp local_edit.cpp local_tools.cpp"
$clLine = "cl /nologo /std:c++17 /EHsc /W4 /Fe:godbrain-kernel.exe $sources /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup pdh.lib dxgi.lib winhttp.lib advapi32.lib user32.lib"
Push-Location $kernelDir
try {
    if ($vcvars) {
        cmd.exe /c "call `"$vcvars`" >nul && $clLine"
    } else {
        cmd.exe /c $clLine
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Build-Kernel: cl failed with exit $LASTEXITCODE (stop godbrain-kernel.exe on :8083 if LNK1104)"
    }
    Get-ChildItem -LiteralPath $kernelDir -Filter "*.obj" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
} finally {
    Pop-Location
}

$info = Get-Item -LiteralPath $exe
Write-Host ("Build-Kernel ok {0} bytes={1} at={2:u}" -f $info.Name, $info.Length, $info.LastWriteTimeUtc)
