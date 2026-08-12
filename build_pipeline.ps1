# build_pipeline.ps1
# Builds the C++ Librarian and Go Memory Store to their expected locations

$ErrorActionPreference = "Stop"

Write-Host "Building Alexandria Pipeline..."

# 1. Build Memory Store
Write-Host "Building Memory Store (Go)..."
Push-Location "$PSScriptRoot\godbrain_core\memory_store"
try {
    go build -o memory-store.exe ./cmd/memory-store
    if ($LASTEXITCODE -ne 0) { throw "Go build failed" }
    Write-Host "Memory Store built successfully."
} finally {
    Pop-Location
}

# 2. Build Librarian
Write-Host "Building Librarian (C++)..."
Push-Location "$PSScriptRoot\godbrain_core\cpp_tools"
try {
    # Check if cl is already in PATH
    $clOutput = (Get-Command cl -ErrorAction SilentlyContinue)
    if ($clOutput) {
        cmd.exe /c "cl /EHsc /Fe:librarian.exe librarian.cpp"
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

        cmd.exe /c "call `"$vcvars`" >nul && cl /EHsc /Fe:librarian.exe librarian.cpp"
    }
    
    if ($LASTEXITCODE -ne 0) { throw "C++ build failed" }
    Write-Host "Librarian built successfully."
} finally {
    Pop-Location
}

Write-Host "Pipeline build complete!"
