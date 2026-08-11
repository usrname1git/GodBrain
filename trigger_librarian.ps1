# trigger_librarian.ps1
# This script extracts the latest GitHub Copilot CLI session transcript and
# feeds it into the real native GodBrain Librarian (godbrain_core/cpp_tools/
# librarian.cpp, compiled to librarian.exe) for distillation and storage.
#
# The Librarian binary forwards the distilled "golden record" to the Go
# Memory Engine (godbrain_core/memory_engine), which writes it into Neo4j
# Aura. That write requires NEO4J_URI, NEO4J_USERNAME, and NEO4J_PASSWORD to
# already be present in the environment -- this script does NOT set or
# substitute them; it only warns if they look missing, since silently
# supplying/bypassing credentials would defeat the explicit-credential
# requirement documented in .github/copilot-instructions.md.

$ErrorActionPreference = "Stop"

function Fail {
    param([string]$Message)
    Write-Error "[LIBRARIAN HOOK] FAILED: $Message"
    exit 1
}

# 0. Portable paths: everything is resolved relative to this script's own
# location (the repository root), never a hardcoded per-user path.
$repoRoot = $PSScriptRoot
$librarianExe = Join-Path $repoRoot "godbrain_core\cpp_tools\librarian.exe"
if ($env:GODBRAIN_LIBRARIAN_PATH) {
    $librarianExe = $env:GODBRAIN_LIBRARIAN_PATH
}

if (-not (Test-Path $librarianExe -PathType Leaf)) {
    Fail "native Librarian executable not found at '$librarianExe'. Build it first (e.g. from godbrain_core/cpp_tools: cl /std:c++17 /EHsc librarian.cpp) or set GODBRAIN_LIBRARIAN_PATH."
}

foreach ($credVar in @("NEO4J_URI", "NEO4J_USERNAME", "NEO4J_PASSWORD")) {
    if (-not (Get-Item -Path "Env:$credVar" -ErrorAction SilentlyContinue)) {
        Write-Warning "[LIBRARIAN HOOK] $credVar is not set in the environment. The Memory Engine write to Neo4j Aura will fail without it."
    }
}

# 1. Locate the latest Copilot session directory
$copilotStatePath = Join-Path $env:USERPROFILE ".copilot\session-state"
if (-Not (Test-Path $copilotStatePath)) {
    Fail "Copilot session state directory not found at $copilotStatePath"
}

# Find the most recently modified session directory
$latestSessionDir = Get-ChildItem -Path $copilotStatePath -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-Not $latestSessionDir) {
    Fail "No session directories found in $copilotStatePath"
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
    $transcript = "RAW_SESSION_DUMP_PLACEHOLDER"
}

if ([string]::IsNullOrWhiteSpace($transcript)) {
    Write-Warning "[LIBRARIAN HOOK] Transcript is empty. Nothing to distill."
    exit 0
}

# 3. Save the transcript to a file so it can be handed to librarian.exe
# without hitting the Windows command-line length limit or quoting issues a
# full transcript would otherwise run into as a literal argv string.
$tempTranscriptPath = Join-Path $env:TEMP "godbrain_transcript_$sessionId.txt"
$transcript | Out-File -FilePath $tempTranscriptPath -Encoding utf8

# 4. Fire up the native C++ Librarian: `librarian.exe <session_id> --file <path>`
Write-Host "[LIBRARIAN HOOK] Waking up the native GodBrain Librarian ($librarianExe)..."
Write-Host "Executing: $librarianExe $sessionId --file $tempTranscriptPath"

& $librarianExe $sessionId "--file" $tempTranscriptPath
$librarianExitCode = $LASTEXITCODE

Remove-Item -Path $tempTranscriptPath -ErrorAction SilentlyContinue

if ($librarianExitCode -ne 0) {
    Fail "librarian.exe exited with status $librarianExitCode. Distillation did NOT complete; the golden record was not committed."
}

# Only reachable after the native tool itself reported success via exit code 0.
Write-Host "[LIBRARIAN HOOK] Distillation complete. Golden record secured."
Write-Host "Goodbye, Architect. See you next session."
exit 0
