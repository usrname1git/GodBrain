# trigger_librarian.ps1
# This script extracts the latest GitHub Copilot CLI session transcript
# and feeds it into the GodBrain Librarian for distillation and storage.

$ErrorActionPreference = "Stop"

# 1. Locate the latest Copilot session directory
$copilotStatePath = Join-Path $env:USERPROFILE ".copilot\session-state"
if (-Not (Test-Path $copilotStatePath)) {
    Write-Error "Copilot session state directory not found at $copilotStatePath"
}

# Find the session directory containing the most recently modified events.jsonl
$latestSessionDir = Get-ChildItem -Path $copilotStatePath -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName "events.jsonl")
} | Sort-Object { (Get-Item (Join-Path $_.FullName "events.jsonl")).LastWriteTime } -Descending | Select-Object -First 1

if (-Not $latestSessionDir) {
    Write-Error "No session directories with events.jsonl found in $copilotStatePath"
}

$sessionFolder = $latestSessionDir.FullName
$sessionId = $latestSessionDir.Name

Write-Host "[LIBRARIAN HOOK] Found active session ID: $sessionId"
Write-Host "[LIBRARIAN HOOK] Extracting transcript from: $sessionFolder"

# 2. Extract the transcript from the session's events.jsonl using Python
$eventsFile = Join-Path $sessionFolder "events.jsonl"
if (-Not (Test-Path $eventsFile)) {
    Write-Error "events.jsonl not found in session folder"
}

$tempTranscriptPath = Join-Path $env:TEMP "godbrain_transcript_$sessionId.txt"

# Safe temp file cleanup via try/finally
try {
    Write-Host "[LIBRARIAN HOOK] Compiling full conversation..."
    
    $pythonScript = @"
import json
import sys

def extract_transcript(jsonl_path, out_path):
    transcript = []
    try:
        with open(jsonl_path, 'r', encoding='utf-8') as f:
            for line in f:
                if not line.strip(): continue
                evt = json.loads(line)
                if evt.get('type') == 'user.message':
                    content = evt.get('data', {}).get('content', '')
                    transcript.append(f'User:\n{content}\n')
                elif evt.get('type') == 'assistant.message':
                    content = evt.get('data', {}).get('content', '')
                    if content:
                        transcript.append(f'AI:\n{content}\n')
        
        with open(out_path, 'w', encoding='utf-8') as out:
            out.write('\n'.join(transcript))
    except Exception as e:
        sys.exit(f'Error extracting transcript: {e}')

extract_transcript(r'$eventsFile', r'$tempTranscriptPath')
"@

    # Execute Python
    $pythonRunSuccess = $false
    try {
        $pythonScript | py -
        if ($LASTEXITCODE -eq 0) { $pythonRunSuccess = $true }
    } catch {
        Write-Host "py launcher failed, trying python..."
    }

    if (-Not $pythonRunSuccess) {
        try {
            $pythonScript | python -
            if ($LASTEXITCODE -eq 0) { $pythonRunSuccess = $true }
        } catch {
            throw "Failed to extract transcript using both py and python: $($_.Exception.Message)"
        }
    }

    if (-Not $pythonRunSuccess) {
        throw "Failed to extract transcript using both py and python."
    }
    if (-Not (Test-Path -LiteralPath $tempTranscriptPath -PathType Leaf)) {
        throw "Transcript extraction completed without creating $tempTranscriptPath"
    }

    $transcriptLength = (Get-Item $tempTranscriptPath).Length
    if ($transcriptLength -eq 0) {
        Write-Warning "[LIBRARIAN HOOK] Transcript is empty. Nothing to distill."
        exit 0
    }
    
    Write-Host "[LIBRARIAN HOOK] Extracted $($transcriptLength) bytes of transcript."
    
    # 4. Fire up the C++ Librarian Pipeline
    Write-Host "[LIBRARIAN HOOK] Waking up the GodBrain Librarian (C++)..."
    
    $librarianExe = if ([string]::IsNullOrWhiteSpace($env:GODBRAIN_LIBRARIAN_PATH)) {
        Join-Path $PSScriptRoot "godbrain_core\cpp_tools\librarian.exe"
    } else {
        $env:GODBRAIN_LIBRARIAN_PATH
    }
    if (-Not (Test-Path -LiteralPath $librarianExe -PathType Leaf)) {
        throw "Librarian executable not found at '$librarianExe'. Run build_pipeline.ps1 or set GODBRAIN_LIBRARIAN_PATH."
    }
    
    # Execute the native pipeline
    Write-Host "Executing: & `"$librarianExe`" $sessionId `"$tempTranscriptPath`""
    & $librarianExe $sessionId $tempTranscriptPath
    $librarianExitCode = $LASTEXITCODE
    
    if ($librarianExitCode -ne 0) {
        Write-Host "[LIBRARIAN HOOK] Native pipeline failed with exit code $librarianExitCode" -ForegroundColor Red
        exit $librarianExitCode
    }
    
    Write-Host "[LIBRARIAN HOOK] Distillation complete. Golden record secured."
    Write-Host "Goodbye, Architect. See you next session."

} finally {
    # Clean up temp file
    if (Test-Path $tempTranscriptPath) {
        Remove-Item -Force $tempTranscriptPath
    }
}
