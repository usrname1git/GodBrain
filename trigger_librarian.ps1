# trigger_librarian.ps1
# This script extracts the latest GitHub Copilot CLI session transcript
# and feeds it into the GodBrain Librarian for distillation and storage.

$ErrorActionPreference = "Stop"

# 1. Locate the latest Copilot session directory
$copilotStatePath = Join-Path $env:USERPROFILE ".copilot\session-state"
if (-Not (Test-Path $copilotStatePath)) {
    Write-Error "Copilot session state directory not found at $copilotStatePath"
}

# Find the most recently modified session directory
$latestSessionDir = Get-ChildItem -Path $copilotStatePath -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-Not $latestSessionDir) {
    Write-Error "No session directories found in $copilotStatePath"
}

$sessionFolder = $latestSessionDir.FullName
$sessionId = $latestSessionDir.Name

Write-Host "[LIBRARIAN HOOK] Found active session ID: $sessionId"
Write-Host "[LIBRARIAN HOOK] Extracting transcript from: $sessionFolder"

# 2. Extract the transcript from the session's SQLite/JSON data
# Note: The CLI stores turn data either in turns.json or via local SQLite databases.
# For this PoC, we are doing a quick aggregate of checkpoint/markdown files if they exist,
# or alerting if we need to parse the DB directly.

$transcript = ""
$checkpointsDir = Join-Path $sessionFolder "checkpoints"

if (Test-Path $checkpointsDir) {
    Write-Host "[LIBRARIAN HOOK] Compiling checkpoints for distillation..."
    $checkpointFiles = Get-ChildItem -Path $checkpointsDir -Filter "*.md" | Sort-Object Name
    foreach ($file in $checkpointFiles) {
        $transcript += "`n--- $($file.Name) ---`n"
        $transcript += Get-Content $file.FullName -Raw
    }
} else {
    Write-Host "[WARN] No checkpoints found. Librarian will need to parse the raw session DB."
    $transcript = "No checkpoints available. Raw session DB requires extraction."
}

if ([string]::IsNullOrWhiteSpace($transcript)) {
    Write-Warning "[LIBRARIAN HOOK] Transcript is empty. Nothing to distill."
    exit 0
}

# 3. Save transcript to a temp file so the Python script can read it safely
$tempTranscriptPath = Join-Path $env:TEMP "godbrain_transcript_$sessionId.txt"
$transcript | Out-File -FilePath $tempTranscriptPath -Encoding utf8

# 4. Fire up the C++ Librarian Pipeline
Write-Host "[LIBRARIAN HOOK] Waking up the GodBrain Librarian (C++)..."

$librarianExe = Join-Path $PSScriptRoot "godbrain_core\cpp_tools\librarian.exe"

# Execute the native pipeline
Write-Host "Executing: & $librarianExe $sessionId $tempTranscriptPath"
& $librarianExe $sessionId $tempTranscriptPath
$librarianExitCode = $LASTEXITCODE

# Clean up temp file
if (Test-Path $tempTranscriptPath) {
    Remove-Item -Force $tempTranscriptPath
}

if ($librarianExitCode -ne 0) {
    Write-Host "[LIBRARIAN HOOK] Native pipeline failed with exit code $librarianExitCode" -ForegroundColor Red
    exit $librarianExitCode
}

Write-Host "[LIBRARIAN HOOK] Distillation complete. Golden record secured."
Write-Host "Goodbye, Architect. See you next session."
