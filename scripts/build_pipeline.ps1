# scripts/build_pipeline.ps1
# Builds the C++ Librarian and Go Alexandria services to their expected locations

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")

Write-Host "Building Alexandria Pipeline..."

# 1. Build Memory Store and canonical retrieval tools
Write-Host "Building Memory Store and RAG tools (Go)..."
Push-Location "$RepoRoot\godbrain_core\memory_store"
try {
    go build -o memory-store.exe ./cmd/memory-store
    if ($LASTEXITCODE -ne 0) { throw "Go build failed" }
    go build -ldflags "-H windowsgui" -o rag-service.exe ./cmd/rag-service
    if ($LASTEXITCODE -ne 0) { throw "RAG service build failed" }
    go build -o rag-rebuild.exe ./cmd/rag-rebuild
    if ($LASTEXITCODE -ne 0) { throw "RAG rebuild build failed" }
    go build -o rag-eval.exe ./cmd/rag-eval
    if ($LASTEXITCODE -ne 0) { throw "RAG evaluation build failed" }
    Write-Host "Memory Store and RAG tools built successfully."
} finally {
    Pop-Location
}

# 2. Build Librarian
Write-Host "Building Librarian (C++)..."
Push-Location "$RepoRoot\godbrain_core\cpp_tools"
try {
    # Check if cl is already in PATH
    $clOutput = (Get-Command cl -ErrorAction SilentlyContinue)
    if ($clOutput) {
        cmd.exe /c "cl /std:c++17 /EHsc /Fe:librarian.exe librarian.cpp /link ws2_32.lib"
    } else {
        # Find vcvars64.bat
        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (-Not (Test-Path $vswhere)) {
            throw "Could not find vswhere.exe and cl.exe is not in PATH."
        }
        $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        $vcvars = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"
        if (-Not (Test-Path $vcvars)) {
            throw "Could not find vcvars64.bat at $vcvars"
        }

        cmd.exe /c "call `"$vcvars`" >nul && cl /std:c++17 /EHsc /Fe:librarian.exe librarian.cpp /link ws2_32.lib"
    }
    if ($LASTEXITCODE -ne 0) { throw "C++ build failed" }
    Write-Host "Librarian built successfully."
} finally {
    Pop-Location
}

Write-Host "Pipeline build complete!"
