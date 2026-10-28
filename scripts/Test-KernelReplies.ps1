# Offline native reply-channel regressions. No GPU, live vault or kernel restart.
# -CompileOnly never runs model-modifiable native binaries.
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string[]]$ChangedPath = @(),
    [switch]$CompileOnly
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $RepoRoot 'godbrain_core\cpp_kernel'
$build = Join-Path ([IO.Path]::GetTempPath()) ('GodBrain-ReplyTests-' + [guid]::NewGuid().ToString('N'))
$unitDir = Join-Path $build 'parser'
$nativeDir = Join-Path $build 'godbrain_core\cpp_kernel'
$null = New-Item -ItemType Directory -Path $unitDir, $nativeDir
$previous = @{}
foreach ($name in 'GODBRAIN_REPLY_TEST_ROOT', 'GODBRAIN_REPLY_TEST_MISSING_PIN', 'GODBRAIN_COLIBRI_KEY', 'COLI_API_KEY') {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    $prefix = ''
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio x64 C++ tools are required.' }
        $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $vs) { throw 'Visual Studio x64 C++ tools were not found.' }
        $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
        $prefix = 'set "PATH=' + (Split-Path $vswhere -Parent) + ';%PATH%" && call "' + $vcvars + '" >nul && '
    }
    function Invoke-ReplyTestBuild(
        [string]$Directory, [string]$Name, [string[]]$Sources,
        [string]$Link = '', [switch]$ObjectOnly
    ) {
        $paths = @($Sources | ForEach-Object {
            $path = if ([IO.Path]::IsPathFullyQualified($_)) { $_ } else { Join-Path $source $_ }
            '"' + $path + '"'
        })
        $output = if ($ObjectOnly) { '/c /TP /Fo:' } else { '/Fe:' }
        $command = $prefix + 'cd /d "' + $Directory + '" && cl /nologo /std:c++17 /EHsc /W4 /I"' + $source + '" ' +
            $output + $Name + ' ' + ($paths -join ' ') + $Link
        & (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') /c $command
        if ($LASTEXITCODE -ne 0) { throw "Reply test build failed: $Name (exit $LASTEXITCODE)." }
    }
    $implementationSources = @(
        'kernel.cpp', 'surgery.cpp', 'telemetry.cpp', 'memory.cpp',
        'local_edit.cpp', 'local_tools.cpp', 'phone_desk.cpp'
    )
    $libraries = ' pdh.lib dxgi.lib winhttp.lib advapi32.lib user32.lib iphlpapi.lib'
    $productionLink = ' /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup' + $libraries
    if ($CompileOnly) {
        $compiled = @('main.cpp') + $implementationSources
        Invoke-ReplyTestBuild $nativeDir 'godbrain-kernel.exe' $compiled $productionLink
    } else {
        Invoke-ReplyTestBuild $unitDir 'coli-sse-test.exe' @('coli_sse_test.cpp')
        & (Join-Path $unitDir 'coli-sse-test.exe')
        if ($LASTEXITCODE -ne 0) { throw 'SSE parser regressions failed.' }

        Invoke-ReplyTestBuild $unitDir 'thinking-cmd-test.exe' @('thinking_cmd_test.cpp')
        & (Join-Path $unitDir 'thinking-cmd-test.exe')
        if ($LASTEXITCODE -ne 0) { throw 'Thinking preference and output-budget regressions failed.' }

        $nativeSources = @('reply_stream_test.cpp') + $implementationSources
        Invoke-ReplyTestBuild $nativeDir 'reply-stream-test.exe' $nativeSources (' /link' + $libraries)
        Invoke-ReplyTestBuild $unitDir 'kernel-main.obj' @('main.cpp') -ObjectOnly
        $productionObjects = @((Join-Path $unitDir 'kernel-main.obj')) + @(
            $implementationSources | ForEach-Object {
                Join-Path $nativeDir ([IO.Path]::ChangeExtension($_, '.obj'))
            }
        )
        Invoke-ReplyTestBuild $nativeDir 'godbrain-kernel.exe' $productionObjects $productionLink
        $compiled = @('main.cpp', 'coli_sse_test.cpp', 'thinking_cmd_test.cpp') + $nativeSources
    }
    $sourceRoot = [IO.Path]::GetFullPath($source).TrimEnd('\') + '\'
    $index = 0
    foreach ($changed in $ChangedPath) {
        $full = [IO.Path]::GetFullPath((Join-Path $RepoRoot $changed))
        if (-not $full.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetExtension($full) -notin @('.cpp', '.h', '.hpp') -or
            -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Changed path is not a kernel source file: $changed"
        }
        $relative = $full.Substring($sourceRoot.Length)
        if ($relative -in $compiled) { continue }
        Invoke-ReplyTestBuild $unitDir ("changed-$index.obj") @($relative) -ObjectOnly
        $compiled += $relative
        $index++
    }
    if ($CompileOnly) {
        Write-Host 'PASS: Kernel production compile/link (no native fixture execution)'
    } else {
        $env:GODBRAIN_REPLY_TEST_ROOT = $build
        $env:GODBRAIN_COLIBRI_KEY = $null
        $env:COLI_API_KEY = $null
        $env:GODBRAIN_REPLY_TEST_MISSING_PIN = $null
        & (Join-Path $nativeDir 'reply-stream-test.exe')
        if ($LASTEXITCODE -ne 0) { throw 'Native reply-channel regressions failed.' }

        $missingPinRoot = Join-Path $build 'missing-pin'
        $missingPinNative = Join-Path $missingPinRoot 'godbrain_core\cpp_kernel'
        $null = New-Item -ItemType Directory -Path $missingPinNative
        $telemetry = [IO.File]::ReadAllText((Join-Path $source 'telemetry.cpp'))
        $pinRead = 'const auto ubr = reg_dword(HKEY_LOCAL_MACHINE, key, L"UBR");'
        if (($telemetry.Split($pinRead, [StringSplitOptions]::None).Count - 1) -ne 1) {
            throw 'Missing-pin fixture no longer matches the production sensor read.'
        }
        $missingPinSource = Join-Path $missingPinNative 'telemetry.cpp'
        [IO.File]::WriteAllText($missingPinSource,
            $telemetry.Replace($pinRead, 'const std::optional<std::uint32_t> ubr;'),
            [Text.UTF8Encoding]::new($false))
        Invoke-ReplyTestBuild $missingPinNative 'telemetry.obj' @($missingPinSource) -ObjectOnly
        $missingPinObjects = @((Join-Path $missingPinNative 'telemetry.obj')) + @(
            $nativeSources | Where-Object { $_ -ne 'telemetry.cpp' } | ForEach-Object {
                Join-Path $nativeDir ([IO.Path]::ChangeExtension($_, '.obj'))
            }
        )
        Invoke-ReplyTestBuild $missingPinNative 'reply-stream-test.exe' $missingPinObjects (' /link' + $libraries)
        $env:GODBRAIN_REPLY_TEST_ROOT = $missingPinRoot
        $env:GODBRAIN_REPLY_TEST_MISSING_PIN = '1'
        & (Join-Path $missingPinNative 'reply-stream-test.exe')
        if ($LASTEXITCODE -ne 0) { throw 'Missing-pin chat isolation regressions failed.' }
        Write-Host 'PASS: Kernel reply channels (production link, mock HTTP, missing-pin isolation, no GPU/vault)'
    }
} finally {
    foreach ($name in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
    Remove-Item -LiteralPath $build -Recurse -Force
}
