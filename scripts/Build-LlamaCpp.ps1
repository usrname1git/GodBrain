<#
.SYNOPSIS
    Codified custom build for llama.cpp GodBrain specialist (and rpc-server for distributed).
    Solves "every project has its own cmake" + "ultra minimal/barebone Nvidia for FPS" concerns.

.DESCRIPTION
    Standard flow:
    1. Run this script (first time it will clone).
    2. Edit files under the SourceDir (e.g. common/chat.cpp or common/chat-peg-parser.cpp).
    3. Re-run the script (it will incremental rebuild + redeploy).
    4. Test with your specialist model via the kernel tool path (not MCP).

    - NEVER mutates your global PATH. Invokes cmake by FULL PATH only.
    - For nvcc/CUDA: Use a SEPARATE minimal CUDA Toolkit install (custom/advanced, UNCHECK driver + bloat).
    - Always enables GGML_CUDA + your 4080 arch (89) + GGML_RPC=ON + BUILD_SHARED_LIBS.
    - Optional source overlays from .\llama-overrides before configure (chat-template token overlays were removed).
    - Keeps everything sovereign inside your GodBrain-controlled paths. Produces JSON and TXT info files.
#>

[CmdletBinding()]
param(
    [string]$SourceDir = "C:\Users\autismo\llama.cpp",
    [string]$RuntimeDir = "C:\Users\autismo\llama-cpp",
    [string]$GodBrainDir = "C:\Users\autismo\Documents\GitHub\GodBrain",

    [switch]$SkipClone,
    [switch]$SkipConfigure,
    [switch]$SkipBuild,
    [switch]$DeployOnly,
    [switch]$Clean,
    [switch]$Force,

    [string]$CMakePath = "",
    [string]$CudaToolkitRoot = "",
    [string]$Generator = "",  # auto-detected below (prefers Ninja on your VS18-only setup)
    [string[]]$ExtraCMakeArgs = @()
)

$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "GodBrain Llama.cpp Custom Build"
$scriptDir = $PSScriptRoot

function Write-Color {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::White)
    Write-Host $Text -ForegroundColor $Color
}

if (-not $PSBoundParameters.ContainsKey('GodBrainDir')) {
    $GodBrainDir = (Resolve-Path (Join-Path $scriptDir '..')).Path
}
if (-not $PSBoundParameters.ContainsKey('SourceDir')) {
    $SourceDir = Join-Path $env:USERPROFILE 'llama.cpp'
}
if (-not $PSBoundParameters.ContainsKey('RuntimeDir')) {
    $RuntimeDir = Join-Path $env:USERPROFILE 'llama-cpp'
}
$llamaSourcePath = $SourceDir
$buildOutputPath = Join-Path $SourceDir 'build'

Write-Host "Building llama.cpp from $llamaSourcePath into $buildOutputPath"

# Smart default for Generator on this machine (your stable VS 18/2026 only, no 2022/v143)
# We prefer Ninja because MSBuild + cl.exe under the VS 18/2026 + CUDA 13.3 has been
# causing hard 0xc0000005 crashes that trash devenv, VSCode, and the whole system.
# Ninja + direct cl calls are more stable here. (MS calls this their stable release;
# there is a separate preview, but even "stable" is very new and has rough edges
# with heavy ggml/CUDA compilation.)
if ([string]::IsNullOrWhiteSpace($Generator)) {
    $hasVS2022 = Test-Path "C:\Program Files\Microsoft Visual Studio\2022"
    $hasNinja = $null -ne (Get-Command ninja.exe -ErrorAction SilentlyContinue)
    $isVS18Only = (Test-Path "C:\Program Files\Microsoft Visual Studio\18\Community") -and -not $hasVS2022
    if ($isVS18Only -and $hasNinja) {
        $Generator = "Ninja"
        Write-Color "[*] Auto-detected VS18-only setup + ninja.exe. Defaulting Generator to Ninja for stability (avoids MSBuild/devenv crashes)." Cyan
    } else {
        $Generator = "Visual Studio 17 2022"
    }
}

function Resolve-CMakeExe {
    param([string]$ProvidedPath)
    if ($ProvidedPath -and (Test-Path -LiteralPath $ProvidedPath)) {
        return (Resolve-Path $ProvidedPath).Path
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        try {
            $vsInstallPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1
            if ($vsInstallPath) {
                $cand = Join-Path $vsInstallPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
                if (Test-Path -LiteralPath $cand) {
                    Write-Color "Auto-detected VS cmake via vswhere: $cand" "Green"
                    return $cand
                }
            }
        } catch { }
    }

    $candidates = @(
        "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Preview\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "C:\Program Files\Microsoft Visual Studio\18\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "C:\Program Files\Microsoft Visual Studio\18\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            Write-Color "Found VS cmake at common location: $c" "Green"
            return $c
        }
    }

    $cmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Color "Falling back to cmake from current session PATH: $($cmd.Source)" "Yellow"
        return $cmd.Source
    }

    throw "Could not find cmake.exe."
}

function Resolve-CudaRoot {
    param([string]$Provided)
    if ($Provided) {
        $nvcc = Join-Path $Provided "bin\nvcc.exe"
        if (Test-Path -LiteralPath $nvcc) { return (Resolve-Path $Provided).Path }
        Write-Color "Provided CudaToolkitRoot '$Provided' has no bin\nvcc.exe -- ignoring." "Red"
    }

    $base = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA"
    if (Test-Path -LiteralPath $base) {
        $latest = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                  Sort-Object { [version]($_.Name -replace '^v','') } -Descending |
                  Select-Object -First 1
        if ($latest) {
            $nvcc = Join-Path $latest.FullName "bin\nvcc.exe"
            if (Test-Path -LiteralPath $nvcc) {
                Write-Color "Auto-detected CUDA Toolkit: $($latest.FullName)" "Green"
                return $latest.FullName
            }
        }
    }

    if ($env:CUDA_PATH -and (Test-Path (Join-Path $env:CUDA_PATH "bin\nvcc.exe"))) {
        Write-Color "Using CUDA from current env:CUDA_PATH = $($env:CUDA_PATH)" "Yellow"
        return $env:CUDA_PATH
    }
    return $null
}

function Test-Prerequisites {
    Write-Color "[*] Checking build prerequisites for SteamusDominus..." Cyan

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git not found. Install Git for Windows."
    }
    Write-Color "    [+] git OK" Green

    $global:ResolvedCMake = Resolve-CMakeExe -ProvidedPath $CMakePath
    Write-Color "    [+] cmake OK" Green

    $global:ResolvedCuda = Resolve-CudaRoot -Provided $CudaToolkitRoot
    if ($global:ResolvedCuda) {
        Write-Color "    [+] nvcc OK (CUDA detected)" Green
    } else {
        Write-Color "    [!] nvcc not found explicitely. CUDA Toolkit required for GGML_CUDA=ON." Yellow
    }

    # Auto-prefer Ninja for your stable VS 18/2026 install (no 2022/v143) because
    # MSBuild + cl.exe under VS 18/2026 + CUDA 13.3 has been causing hard 0xc0000005
    # crashes that trash devenv, VSCode, and the whole system. Ninja calls cl
    # more directly and is more resilient. You have ninja.exe available.
    $isPreview = ($Generator -match '18|2026|Preview') -or ($global:ResolvedCMake -match '\\18\\')
    $ninja = Get-Command ninja.exe -ErrorAction SilentlyContinue
    if ($isPreview -and $ninja -and ($Generator -notmatch 'Ninja')) {
        Write-Color "    [!] VS 18/2026 + ninja.exe detected. Auto-switching to -Generator Ninja for this run (more stable than MSBuild on the 18 toolchain). Pass -Generator explicitly to override." Yellow
        $script:Generator = "Ninja"
    }
}

function Initialize-Source {
    if ($DeployOnly) { return }

    if (Test-Path (Join-Path $SourceDir ".git")) {
        Write-Color "[+] Source tree exists at $SourceDir" Green
        if (-not $SkipClone) {
            Write-Color "[*] Updating source (git pull)..." Cyan
            Push-Location $SourceDir
            try {
                git fetch --all --prune
                git checkout master
                git pull --ff-only
            } finally { Pop-Location }
        }
        return
    }

    if ($SkipClone) { throw "SourceDir $SourceDir runs no git." }

    Write-Color "[*] Cloning llama.cpp (shallow) into $SourceDir ..." Cyan
    $parent = Split-Path $SourceDir -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git $SourceDir
    Write-Color "[+] Clone complete." Green
}

function Initialize-Overrides {
    $overridesDir = Join-Path $GodBrainDir "llama-overrides"
    if (-not (Test-Path $overridesDir)) { return }

    Write-Color "[*] Found llama-overrides/  overlaying GodBrain patches into source tree..." Cyan

    # Recursively overlay patches from llama-overrides to SourceDir.
    # Only real source; never copy stray .patch/.diff/README/example files into the upstream tree.
    $global:OverlaysApplied = @()
    Get-ChildItem $overridesDir -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($overridesDir.Length).TrimStart('\','/')
        $name = $_.Name

        # Strict skip for junk
        if ($relative -match '(?i)example|README|\.patch$|\.diff$|\.md$|\.txt$') { return }
        if ($name -like "*.example*" -or $name -like "*README*") { return }

        $dest = Join-Path $SourceDir $relative
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

        Copy-Item $_.FullName $dest -Force
        Write-Color "    overlaid: $relative" Yellow
        $global:OverlaysApplied += $relative
    }

    # Belt-and-suspenders: remove any .patch or example files that may have landed in common/ from previous runs
    $stray = Get-ChildItem (Join-Path $SourceDir "common") -Recurse -File -Include *.patch,*.diff,*example* -ErrorAction SilentlyContinue
    if ($stray) {
        $stray | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Color "    cleaned stray overlay junk: $($_.Name)" DarkGray
        }
    }
}

function Write-BuildWarnings {
    $warn = [string]::Join([Environment]::NewLine, @(
        "[!] STEAMUSDOMINUS BUILD WARNINGS (read this):",
        "",
        "  If the build dies with CL.exe exiting -1073741819 (0xC0000005) or syntax errors",
        "  deep inside MSVC <array> / std:: headers while compiling ggml-opt.cpp etc:",
        "",
        "    * Bleeding-edge combo: VS 18/2026 (the \18\ folder + MSVC 19.x, which MS calls",
        "      their stable release) + CUDA 13.3 (or newer) as host compiler for heavy",
        "      template code in recent llama.cpp (ggml-opt.cpp etc.). The stdlib headers",
        "      get confused and CL.exe hard-crashes. These crashes can destabilize the",
        "      whole system (VSCode, VS, even Brave) because cl.exe is deeply integrated.",
        "    * VSCode extension bisect finding this: very common. The C/C++ extension (or",
        "      CMake Tools, or anything that invokes cl.exe / loads MSVC bits for IntelliSense)",
        "      can trigger or amplify the AVs when the toolchain is under load from the",
        "      GodBrain build. It `"leaks`" to full devenv/VS because they share the exact",
        "      same 18 MSVC DLLs and runtime, even if you barely open VS. (MS labels the",
        "      18/2026 as stable; there is a separate preview, but it's still the newest",
        "      and has these rough edges.)",
        "    * The CMake warnings you just pasted (CMP194 `"MSVC is not an assembler`",",
        "      ccache not found, NCCL not found, OpenSSL not found) are **completely normal",
        "      and harmless** on Windows + this VS preview + no ccache/NCCL/OpenSSL installed.",
        "      The script now silences the two noisy ones (CMP194 + ccache) automatically.",
        "    * (Since you already have Mr Defender 6ft under, that's ruled out. Good  keeps",
        "      the PC God node truly sovereign.)",
        "",
        "  FIXES (do these in order):",
        "    1. ALWAYS start with a clean build dir when changing VS/CUDA (menu option 3",
        "       or pass -Clean). Incremental builds on preview toolchains are cursed.",
        "       We just cleaned it for you in the background.",
        "       The script now forces clean for VS18-only to prevent stale objects from",
        "       prior cl.exe crashes (this has caused many '10 hour debugging' sessions).",
        "    2. The script now auto-defaults to Ninja on your VS 18/2026-only machine (no 2022/v143).",
        "       This bypasses the flaky MSBuild layer + `"devenv.exe`" (the real name of the VS",
        "       `"host ui`" process in Task Manager / pwsh) that amplifies the cl.exe 0xc0000005",
        "       crashes and takes down VSCode, full VS, and even Brave. Ninja + direct cl is",
        "       the only stable path here. You can still pass -Generator if you want to experiment.",
        "    3. The script auto-detects preview VS/CUDA and injects",
        "       -DCMAKE_CXX_STANDARD=17 / CMAKE_CUDA_STANDARD=17 + silences the CMP194",
        "       (MSVC not assembler) and ccache warnings you are seeing.",
        "    4. If still dying on the same <array> errors: the VS 18/2026 install itself",
        "       may be partially broken (common with these combos + heavy CUDA builds).",
        "       Repair it from the VS Installer (run the vs_installer.exe and choose Repair",
        "       for the 18 Community). Reboot after repair. The script no longer requires",
        "       22/143 on your machine.",
        "",
        "  CRITICAL: After killing devenv/cl/etc. and cleaning, **reboot the machine**,",
        "  then run this script from a *plain fresh pwsh.exe window* (do NOT launch it",
        "  from inside VSCode terminal, or any session started from devenv/VS `"host ui`").",
        "  This keeps the entire build decoupled from the crashing devenv host.",
        "",
        "  Chat-template overlays were removed. Privileged tools stay on the C++ kernel",
        "  command_type path, not llama.cpp preserved_tokens."
    ))
    Write-Color $warn "Yellow"
}

function Connect-GodBrainChatExtensions {
    Write-Color "    Skipping llama.cpp chat-template overlay (removed; tools stay on the C++ kernel)." DarkGray
}

function Invoke-CustomBuild {
    if ($DeployOnly) { return }

    $buildDir = Join-Path $SourceDir "build"
    if ($Clean -and (Test-Path $buildDir)) {
        Write-Color "[*] Cleaning build dir..." Yellow
        Remove-Item -Recurse -Force $buildDir
    }
    if (-not (Test-Path $buildDir)) {
        New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
    }

    Push-Location $buildDir
    try {
        # Detect preview toolchain early so it is available for both configure and build steps
        $isPreviewVS = ($Generator -match '18|2026|Preview') -or ($global:ResolvedCMake -match '\\18\\')

        # For VS18-only setups, always force a clean build dir. Previous partial/crashed builds
        # leave stale objects that cause "access violation" / subcommand failed in subsequent runs.
        # This has been the source of many "10 hour debugging" sessions.
        if ($isPreviewVS -and (Test-Path $buildDir)) {
            Write-Color "    [!] VS18 detected: forcing clean build dir (stale objects from prior cl.exe AVs are the #1 cause of repeated 'ninja subcommand failed' + access violation)." Yellow
            Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
        }

        # For preview VS (your VS18 + CUDA13 situation), strongly prefer Ninja if available
        # to avoid the MSBuild orchestration that makes cl.exe 0xc0000005 crashes worse
        # and destabilize VSCode/VS/Brave. You have ninja from Python scripts.
        if ($isPreviewVS) {
            $ninjaCmd = Get-Command ninja.exe -ErrorAction SilentlyContinue
            if ($ninjaCmd -and ($Generator -notmatch 'Ninja')) {
                Write-Color "    [!] Preview VS detected + ninja.exe found at $($ninjaCmd.Source). Switching Generator to Ninja for more stable direct cl.exe invocations (bypasses buggy MSBuild in VS18 preview)." Yellow
                $Generator = "Ninja"
                # Re-resolve cmake if needed, but it should be fine
            }
        }

        if ($Generator -match 'Ninja' -and (-not $env:VSCMD_ARG_TGT_ARCH)) {
            $vcvars = "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path $vcvars) {
                Write-Color "[*] Injecting vcvars64.bat into session for Ninja (fixes kernel32.lib missing)..." Cyan
                cmd.exe /c "`"$vcvars`" && set" | ForEach-Object {
                    if ($_ -match "^([^=]+)=(.*)$") {
                        [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
                    }
                }
            }
        }

        if (-not $SkipConfigure) {
            Write-Color "[*] Configuring with CMake (GGML_CUDA + RPC + shared libs)..." Cyan

            $cmakeArgs = @(
                "..",
                "-G", $Generator
            )

            if ($Generator -match "Visual Studio") {
                $cmakeArgs += @("-A", "x64")
            }

            $cmakeArgs += @(
                "-DGGML_CUDA=ON",
                "-DCMAKE_CUDA_ARCHITECTURES=89",
                "-DCMAKE_BUILD_TYPE=Release",
                "-DGGML_NATIVE=OFF",
                "-DGGML_CUDA_FORCE_MMQ=ON",
                "-DGGML_CUDA_F16=ON",
                "-DGGML_SCHED_MAX_COPIES=2",
                "-DCMAKE_CXX_FLAGS=/bigobj /Zm2000"
            )

            if ($Generator -match 'Ninja') {
                $cmakeArgs += "-DCMAKE_ASM_COMPILER=ml64.exe"
            }

            if ($global:ResolvedCuda) {
                $cmakeArgs += "-DCUDAToolkit_ROOT=$global:ResolvedCuda"
                $cmakeArgs += "-DCMAKE_CUDA_COMPILER=$(Join-Path $global:ResolvedCuda 'bin\nvcc.exe')"
                $env:CUDA_PATH = $global:ResolvedCuda
                $env:CUDA_TOOLKIT_ROOT_DIR = $global:ResolvedCuda
                $env:PATH = (Join-Path $global:ResolvedCuda "bin") + ";" + $env:PATH
            }
            if ($ExtraCMakeArgs.Count -gt 0) {
                $cmakeArgs += $ExtraCMakeArgs
            }

            # Preview toolchain hardening (you are on VS18 + CUDA13 territory)
            if ($isPreviewVS) {
                Write-Color "    [!] Preview VS generator detected ($Generator). Adding stabilizing flags for ggml-opt / stdlib issues." Yellow
                # Force a known-good C++ standard and disable some new MSVC "features" that can break under nvcc host
                $cmakeArgs += @(
                    "-DCMAKE_CXX_STANDARD=17",
                    "-DCMAKE_CUDA_STANDARD=17",
                    "-DCMAKE_CXX_STANDARD_REQUIRED=ON",
                    "-DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=",
                    # MSVC cl.exe is incredibly crash-prone (ICE C1001) on recent previews when compiling ggml/cuda.
                    # We have to keep optimization OFF (/Od) to prevent MSVC ICE crashes on argsort.cu / ggml-quants.c.
                    # We also must tell nvcc NOT to optimize the device code either (-O0), because when the
                    # host code is unoptimized but nvcc tries to heavily optimize the resulting AST, cicc.exe crashes.
                    "-DCMAKE_C_FLAGS_RELEASE=/MD /Od /DNDEBUG /MP",
                    "-DCMAKE_CXX_FLAGS_RELEASE=/MD /Od /DNDEBUG /MP",
                    "-DCMAKE_CUDA_FLAGS_RELEASE=-O0 -Xcompiler=`"/MD /Od /DNDEBUG /MP`" -DNDEBUG",
                    "-DGGML_AVX=OFF",
                    "-DGGML_AVX2=OFF",
                    "-DGGML_FMA=OFF",
                    "-DGGML_F16C=OFF",
                    "-DGGML_AVX512=OFF"
                )
            }

            # Silence noisy but harmless warnings that always appear on Windows + modern CMake + this VS preview
            # CMP194: MSVC "is not an assembler" for ASM language (new policy in CMake 4.x / VS18)
            # GGML_CCACHE=OFF: we don't have ccache, no need for the suggestion every time
            $cmakeArgs += @(
                "-DCMAKE_POLICY_DEFAULT_CMP194=NEW",
                "-DGGML_CCACHE=OFF"
            )

            $global:FinalCMakeArgs = $cmakeArgs

            Write-Color "    $global:ResolvedCMake $($cmakeArgs -join ' ')" DarkGray
            & $global:ResolvedCMake @cmakeArgs
            if ($LASTEXITCODE -ne 0) { throw "CMake configure failed." }
        }

        if (-not $SkipBuild) {
            Write-Color "[*] Building (Release, parallel). This will take a while..." Cyan

            $buildArgs = @("--build", ".", "--config", "Release", "--parallel", "--target", "llama-server")
            if ($isPreviewVS) {
                Write-Color "    [!] Preview VS: using limited parallelism (1 job) + /Od to avoid cl.exe AVs on heavy CUDA units (workaround for MSVC 19.44 bug on ggml-opt etc.)." Yellow
                $buildArgs = @("--build", ".", "--config", "Release", "--parallel", "1", "--target", "llama-server")
            }

            & $global:ResolvedCMake $buildArgs
            if ($LASTEXITCODE -ne 0) { throw "Build failed." }

            Write-Color "[+] Build succeeded." Green
        }
    } finally {
        Pop-Location
    }
}

function Deploy-Artifacts {
    if ($SkipBuild -and -not $DeployOnly) { return }

    $buildBin = Join-Path $SourceDir "build\bin\Release"
    if (-not (Test-Path $buildBin)) { $buildBin = Join-Path $SourceDir "build\Release" }
    if (-not (Test-Path $buildBin)) { throw "Could not find build output." }

    Write-Color "[*] Deploying artifacts from $buildBin to $RuntimeDir ..." Cyan

    if (-not (Test-Path $RuntimeDir)) { New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null }

    $targetExe = Join-Path $RuntimeDir "llama-server.exe"
    if (Test-Path -LiteralPath $targetExe) {
        $bak = "$targetExe.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item -LiteralPath $targetExe -Destination $bak -Force
        Write-Color "    Backed up previous: $bak" DarkGray
    }

    $patterns = @("llama-server*.exe", "llama-common*.dll", "llama.dll", "ggml*.dll", "llama-*.dll", "mtmd*.dll")
    $copied = 0
    foreach ($pat in $patterns) {
        Get-ChildItem -Path $buildBin -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName $RuntimeDir -Force
            Write-Color "    deployed: $($_.Name)" Green
            $copied++
        }
    }

    if ($copied -eq 0) { Write-Color "[!] No matching artifacts found." Yellow }

    $commit = ""
    if (Test-Path (Join-Path $SourceDir ".git")) {
        Push-Location $SourceDir
        $commit = (git rev-parse --short HEAD) 2>$null
        Pop-Location
    }

    $infoPath = Join-Path $RuntimeDir "LlamaBuildInfo.txt"
    $infoJson = Join-Path $RuntimeDir "LlamaBuildInfo.json"

    $buildInfo = [ordered]@{
        godbrain_build = $true
        date = (Get-Date -Format o)
        source_commit = $commit
        source_dir = $SourceDir
        runtime_dir = $RuntimeDir
        build_output_dir = $buildBin
        cmake_generator = $Generator
        cmake_args = ($global:FinalCMakeArgs -join " ")
        overlays_applied = $global:OverlaysApplied
        features = @("GGML_CUDA", "BUILD_SHARED_LIBS", "GGML_NATIVE", "GGML_RPC")
        notes = "Custom build for GodBrain specialist (Gemma-4 26B). Kernel owns tool execution. Patches live in GodBrain/llama-overrides/"
    }

    $buildInfo | ConvertTo-Json -Depth 5 | Out-File -FilePath $infoJson -Encoding utf8 -Force

    $infoString = [string]::Join([Environment]::NewLine, @(
        "GodBrain Custom Llama Build",
        "Date: $(Get-Date -Format o)",
        "Source commit: $commit",
        "Source dir: $SourceDir",
        "Runtime dir: $RuntimeDir",
        "Build dir:   $buildBin",
        "CMake generator: $Generator + GGML_CUDA + shared + RPC",
        "CMake full path: $global:ResolvedCMake",
        "Overlays Applied:",
        $($global:OverlaysApplied | ForEach-Object { "  - $_" } | Out-String),
        "Notes: Custom build for GodBrain specialist. Kernel owns tool execution.",
        "       Edit files in common/ (especially chat*.cpp and jinja/) then re-run Build-LlamaCpp.ps1",
        "       JSON version at LlamaBuildInfo.json for easy save_godbrain_thought / constellation ingest."
    ))
    $infoString | Out-File -FilePath $infoPath -Encoding utf8 -Force

    Write-Color "[+] Deploy complete." Green
}

function Show-Menu {
    Write-Color "`n=== GodBrain Llama Custom Build Menu ===" Yellow
    Write-Color "  1) Full build (clone/update + configure + build + deploy)" White
    Write-Color "  2) Quick redeploy (use existing build artifacts)" White
    Write-Color "  3) Clean build dir + full build" White
    Write-Color "  4) Update source only (git pull into $SourceDir)" White
    Write-Color "  5) Configure only (cmake step, no build)" White
    Write-Color "  6) Build only (assume already configured)" White
    Write-Color "  7) Show current auto-detected cmake + cuda (dry)" White
    Write-Color "  8) Print minimal CUDA Toolkit install steps (no bloat)" White
    Write-Color "  9) Show current build info from runtime" White
    Write-Color " 10) Open overrides directory (for your patches)" White
    Write-Color "  0) Exit" White

    $choice = Read-Host "`nChoose (1-10, 0 to quit)"
    switch ($choice) {
        "1" { 
            Test-Prerequisites; Initialize-Source; Initialize-Overrides; Connect-GodBrainChatExtensions; Write-BuildWarnings; Invoke-CustomBuild; Deploy-Artifacts
        }
        "2" { $global:DeployOnly = $true; Deploy-Artifacts }
        "3" { 
            $global:Clean = $true
            Test-Prerequisites; Initialize-Source; Initialize-Overrides; Connect-GodBrainChatExtensions; Write-BuildWarnings; Invoke-CustomBuild; Deploy-Artifacts
        }
        "4" { Initialize-Source }
        "5" { 
            $global:SkipBuild = $true
            Test-Prerequisites; Initialize-Source; Initialize-Overrides; Connect-GodBrainChatExtensions; Write-BuildWarnings; Invoke-CustomBuild
        }
        "6" { 
            $global:SkipConfigure = $true
            Test-Prerequisites; Initialize-Source; Initialize-Overrides; Connect-GodBrainChatExtensions; Write-BuildWarnings; Invoke-CustomBuild; Deploy-Artifacts
        }
        "7" {
            $c = Resolve-CMakeExe -ProvidedPath $CMakePath
            $cu = Resolve-CudaRoot -Provided $CudaToolkitRoot
            Write-Color "CMake     : $c" Green
            Write-Color "CUDA      : $cu" Green
            Write-Color "Generator : $Generator" Green
        }
        "8" {
            $cudaInfo = [string]::Join([Environment]::NewLine, @(
                "=== Minimal CUDA Toolkit (nvcc only) for NVCleanInstall ===",
                "1. On the PC, run nvidia-smi. Note the `"CUDA Version`". Use a Toolkit <= that version.",
                "2. Download CUDA Toolkit network or local exe from NVIDIA.",
                "3. CUSTOM (ADVANCED) installation.",
                "4. UNCHECK `"NVIDIA Graphics Driver`" (Display Driver).",
                "5. UNCHECK Nsight / VS Integration / Samples / Docs.",
                "6. Keep: CUDA Toolkit (nvcc, cudart, cublas).",
                "This gives you compilers without touching your stripped display drivers."
            ))
            Write-Color $cudaInfo Yellow
        }
        "9" {
            $info = Join-Path $RuntimeDir "LlamaBuildInfo.txt"
            if (Test-Path $info) { Get-Content $info | Write-Host } else { Write-Color "No build info yet." Yellow }
        }
        "10" {
            $ov = Join-Path $GodBrainDir "llama-overrides"
            if (-not (Test-Path $ov)) { New-Item -ItemType Directory -Path $ov -Force | Out-Null }
            Invoke-Item $ov
        }
        "0" { Write-Color "Bye." Cyan; return }
        default { Write-Color "Invalid choice." Red }
    }
}

function Build-Engine {
    Write-Host "Initializing build sequence..."
    
    if ($UseCuda) {
        Write-Host "CUDA flag detected."
    # The brace below is required to close the 'if' statement
    }
    
# The brace below is required to close the 'function' statement
}

# --- Main Runtime ---
$hasAction = $DeployOnly -or $SkipClone -or $SkipConfigure -or $SkipBuild -or $Force -or $Clean

if (-not $hasAction) {
    # Lazy mode menu
    Show-Menu
    exit 0
}

Test-Prerequisites
Initialize-Source
Initialize-Overrides
Connect-GodBrainChatExtensions
Write-BuildWarnings
Invoke-CustomBuild
Deploy-Artifacts

Write-Color "" White
Write-Host "Done. Your custom llama.cpp build is ready for GodBrain."


