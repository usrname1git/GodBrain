# Call Librarian from any IDE or shell. Classifies text via the live :8000 mouth.
# Does not spawn Colibri. One GPU slot — do not run during a Galaxy generate.
#
#   .\Invoke-Librarian.ps1 -Text "claim text"
#   .\Invoke-Librarian.ps1 -File C:\path\transcript.txt
#   .\Invoke-Librarian.ps1 -SessionId my-vs-session -Text "..."

[CmdletBinding()]
param(
    [string]$File = "",
    [string]$Text = "",
    [string]$SessionId = "",
    [string]$RepoRoot = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot) && $MyInvocation.MyCommand.Path) {
    $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$exe = if ($env:GODBRAIN_LIBRARIAN_PATH) {
    $env:GODBRAIN_LIBRARIAN_PATH
} else {
    Join-Path $RepoRoot "godbrain_core\cpp_tools\librarian.exe"
}
if (-not (Test-Path -LiteralPath $exe)) {
    throw "missing $exe — build with build_pipeline.ps1"
}

$tmp = $null
if ($File) {
    if (-not (Test-Path -LiteralPath $File)) { throw "missing file $File" }
    $inputPath = (Resolve-Path -LiteralPath $File).Path
} elseif (-not [string]::IsNullOrWhiteSpace($Text)) {
    $tmp = Join-Path $env:TEMP ("gb-lib-" + [guid]::NewGuid().ToString("n") + ".txt")
    [System.IO.File]::WriteAllText($tmp, $Text)
    $inputPath = $tmp
} else {
    throw "pass -Text or -File"
}

if ([string]::IsNullOrWhiteSpace($SessionId)) {
    $SessionId = "cli-" + (Get-Date -Format "yyyyMMdd-HHmmss")
}

try {
    Write-Host "Invoke-Librarian session=$SessionId mouth=:8000"
    & $exe $SessionId $inputPath
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) {
        Remove-Item -LiteralPath $tmp -Force
    }
}
