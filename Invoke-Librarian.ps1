# Call Librarian from any IDE or shell. Classifies text via the live :8000 mouth.
# Does not spawn Colibri. One GPU slot — do not run during a Galaxy generate.
#
#   .\Invoke-Librarian.ps1 -Text "claim text"
#   .\Invoke-Librarian.ps1 -File C:\path\transcript.txt
#   .\Invoke-Librarian.ps1 -Inbox
#   .\Invoke-Librarian.ps1 -SessionId my-vs-session -Text "..."
#
# -Inbox takes the oldest *.txt in repo inbox\ (not done\ or failed\).
# One GPU slot — skip if :8000 is down or busy. Success moves to inbox\done\.
# A failed extract moves to inbox\failed\ so Watch does not burn the GPU
# retrying a poison file. -SelfTest checks that move without the mouth.

[CmdletBinding()]
param(
    [string]$File = "",
    [string]$Text = "",
    [switch]$Inbox,
    [switch]$SelfTest,
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

function Move-InboxQuarantine {
    param(
        [string]$SourcePath,
        [string]$FailDir,
        [string]$Why
    )
    if (-not (Test-Path -LiteralPath $FailDir)) {
        New-Item -ItemType Directory -Path $FailDir | Out-Null
    }
    $name = [System.IO.Path]::GetFileName($SourcePath)
    $dest = Join-Path $FailDir $name
    if (Test-Path -LiteralPath $dest) {
        $stamp = Get-Date -Format "yyyyMMddHHmmss"
        $dest = Join-Path $FailDir (
            [System.IO.Path]::GetFileNameWithoutExtension($name) +
            "-" + $stamp + [System.IO.Path]::GetExtension($name))
    }
    Move-Item -LiteralPath $SourcePath -Destination $dest -Force
    $reason = Join-Path $FailDir (
        [System.IO.Path]::GetFileName($dest) + ".reason")
    [System.IO.File]::WriteAllText($reason, $Why)
    Write-Host "inbox quarantined to $dest"
    return $dest
}

if ($SelfTest) {
    $inboxDir = Join-Path $RepoRoot "inbox"
    $failDir = Join-Path $inboxDir "failed"
    if (-not (Test-Path -LiteralPath $inboxDir)) {
        throw "missing $inboxDir"
    }
    $probe = Join-Path $inboxDir ("selftest-" + [guid]::NewGuid().ToString("n") + ".txt")
    [System.IO.File]::WriteAllText($probe, "self-test quarantine")
    $dest = Move-InboxQuarantine -SourcePath $probe -FailDir $failDir -Why "self-test"
    if (-not (Test-Path -LiteralPath $dest)) { throw "SelfTest: quarantine dest missing" }
    if (Test-Path -LiteralPath $probe) { throw "SelfTest: source still in inbox" }
    Remove-Item -LiteralPath $dest -Force
    $reason = $dest + ".reason"
    if (Test-Path -LiteralPath $reason) { Remove-Item -LiteralPath $reason -Force }
    Write-Host "SelfTest ok quarantine"
    exit 0
}

$tmp = $null
$inboxMove = $null
$inboxDir = $null
$failDir = $null
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
    $failDir = Join-Path $inboxDir "failed"
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
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        if ($inboxMove -and $failDir -and (Test-Path -LiteralPath $inputPath)) {
            Move-InboxQuarantine -SourcePath $inputPath -FailDir $failDir -Why ("librarian-exit-" + $code)
        }
        exit $code
    }
    if ($inboxMove) {
        Move-Item -LiteralPath $inputPath -Destination $inboxMove -Force
        Write-Host "inbox moved to $inboxMove"
    }
} finally {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) {
        Remove-Item -LiteralPath $tmp -Force
    }
}
