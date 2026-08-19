# Call Librarian from any IDE or shell. Classifies text via the live :8000 mouth.
# Does not spawn Colibri. One GPU slot — do not run during a Galaxy generate.
#
#   .\Invoke-Librarian.ps1 -Text "claim text"
#   .\Invoke-Librarian.ps1 -File C:\path\transcript.txt
#   .\Invoke-Librarian.ps1 -Inbox
#   .\Invoke-Librarian.ps1 -SessionId my-vs-session -Text "..."
#
# -Inbox takes the oldest *.txt in repo inbox\ (not done\). One GPU slot —
# skip if :8000 is down or busy. Processed files move to inbox\done\.

[CmdletBinding()]
param(
    [string]$File = "",
    [string]$Text = "",
    [switch]$Inbox,
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
$inboxMove = $null
if ($Inbox) {
    try {
        $probe = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:8000/health"
        if ($probe.StatusCode -ne 200) { throw "mouth not healthy" }
    } catch {
        throw "mouth is down on :8000 — will not ingest. Start the mouth first."
    }
    try {
        $st = Invoke-RestMethod -TimeoutSec 2 -Uri "http://127.0.0.1:8083/api/status"
        $busy = [bool]($st.coli -and $st.coli.busy)
        if ($st.mouth -and $st.mouth.PSObject.Properties.Name -contains "busy") {
            $busy = $busy -or [bool]$st.mouth.busy
        }
        if ($busy) { throw "mouth is busy on :8000 — will not ingest during generate." }
    } catch {
        if ("$_" -match "will not ingest") { throw }
    }
    $inboxDir = Join-Path $RepoRoot "inbox"
    $doneDir = Join-Path $inboxDir "done"
    if (-not (Test-Path -LiteralPath $inboxDir)) {
        throw "missing $inboxDir — drop a .txt there"
    }
    $next = Get-ChildItem -LiteralPath $inboxDir -File -Filter "*.txt" |
        Sort-Object LastWriteTime |
        Select-Object -First 1
    if (-not $next) {
        Write-Host "inbox empty"
        exit 0
    }
    $inputPath = $next.FullName
    $inboxMove = Join-Path $doneDir $next.Name
    if (-not (Test-Path -LiteralPath $doneDir)) {
        New-Item -ItemType Directory -Path $doneDir | Out-Null
    }
} elseif ($File) {
    if (-not (Test-Path -LiteralPath $File)) { throw "missing file $File" }
    $inputPath = (Resolve-Path -LiteralPath $File).Path
} elseif (-not [string]::IsNullOrWhiteSpace($Text)) {
    $tmp = Join-Path $env:TEMP ("gb-lib-" + [guid]::NewGuid().ToString("n") + ".txt")
    [System.IO.File]::WriteAllText($tmp, $Text)
    $inputPath = $tmp
} else {
    throw "pass -Text, -File, or -Inbox"
}

if ([string]::IsNullOrWhiteSpace($SessionId)) {
    if ($inboxMove) {
        $SessionId = "inbox-" + [System.IO.Path]::GetFileNameWithoutExtension($inputPath)
    } else {
        $SessionId = "cli-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    }
}

try {
    Write-Host "Invoke-Librarian session=$SessionId mouth=:8000"
    & $exe $SessionId $inputPath
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($inboxMove) {
        Move-Item -LiteralPath $inputPath -Destination $inboxMove -Force
        Write-Host "inbox moved to $inboxMove"
    }
} finally {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) {
        Remove-Item -LiteralPath $tmp -Force
    }
}
