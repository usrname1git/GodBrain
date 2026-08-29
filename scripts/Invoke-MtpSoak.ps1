# Soak the live :8000 mouth for MTP IMA (CUDA abort or garbled generate).
# Direct llama-server, no Galaxy/Oracle persist. Skip if CS2 holds the GPU.
# Writes logs/last-mtp-soak.json. Exit 1 on fail. Playbook verify step.

[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [string]$BaseUrl = "http://127.0.0.1:8000",
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-GodBrainRoot.ps1")
$cs2Helper = Join-Path $RepoRoot "GodBrain-Cs2.ps1"
if (Test-Path -LiteralPath $cs2Helper) {
    . $cs2Helper
    if (Test-GodBrainColiShouldSleep $RepoRoot) {
        throw "Invoke-MtpSoak: CS2 holds the GPU (running or sleep window)"
    }
} elseif (Get-Process -Name CS2 -ErrorAction SilentlyContinue) {
    throw "Invoke-MtpSoak: CS2.exe is running"
}

$logDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$errLog = Join-Path $logDir "llama-server.err.log"
$outJson = Join-Path $logDir "last-mtp-soak.json"
$outTxt = Join-Path $logDir "last-mtp-soak.txt"
$mouth = ""
$mouthPath = Join-Path $logDir "mouth.txt"
if (Test-Path -LiteralPath $mouthPath) {
    $mouth = (Get-Content -LiteralPath $mouthPath -Raw).Trim()
}

function Test-MouthUp {
    try {
        $h = Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/health" -TimeoutSec 3
        return $h.StatusCode -eq 200
    } catch { return $false }
}

if (-not (Get-Process -Name llama-server -ErrorAction SilentlyContinue)) {
    throw "Invoke-MtpSoak: llama-server is not running"
}
if (-not (Test-MouthUp)) {
    throw "Invoke-MtpSoak: $BaseUrl/health failed"
}
if ($mouth -notmatch '(?i)\bmtp\b') {
    throw "Invoke-MtpSoak: logs/mouth.txt is not an MTP mouth ('$mouth')"
}

function Test-Garbage([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $n = $Text.Length
    $repl = ([regex]::Matches($Text, [char]0xFFFD)).Count
    if ($repl -ge 8) { return "replacement_chars=$repl" }
    $ctrl = ([regex]::Matches($Text, '[\x00-\x08\x0B\x0C\x0E-\x1F]')).Count
    if ($ctrl -ge 8) { return "control_chars=$ctrl" }
    if ($n -ge 800) {
        $words = @($Text.ToLowerInvariant() -split '\W+' | Where-Object { $_.Length -ge 3 })
        if ($words.Count -ge 80) {
            $uniq = ($words | Select-Object -Unique).Count
            $ratio = $uniq / [double]$words.Count
            if ($ratio -lt 0.08) { return ("uniq_ratio={0:n3} words={1}" -f $ratio, $words.Count) }
        }
        $chunk = $Text.Substring([Math]::Max(0, $n - 400), [Math]::Min(24, $n))
        if ($chunk.Trim().Length -ge 12) {
            $esc = [regex]::Escape($chunk.Trim())
            $hits = ([regex]::Matches($Text, $esc)).Count
            if ($hits -ge 15) { return "repeat_tail_hits=$hits" }
        }
    }
    return $null
}

function Get-ErrHits {
    if (-not (Test-Path -LiteralPath $errLog)) { return @() }
    return @(Select-String -Path $errLog -Pattern 'CUDA error|illegal memory access|GGML_ASSERT|GGML_ABORT|fattn abort' -CaseSensitive:$false |
        ForEach-Object { $_.Line.Trim() })
}

$runs = New-Object System.Collections.Generic.List[object]
$fails = New-Object System.Collections.Generic.List[string]
$started = Get-Date

function Invoke-Complete([string]$Name, [object[]]$Messages, [int]$MaxTokens, [double]$Temp) {
    $bodyObj = @{
        model = "Gemma4-12B-IT"
        messages = $Messages
        max_tokens = $MaxTokens
        temperature = $Temp
        stream = $false
        chat_template_kwargs = @{ enable_thinking = $false }
    }
    $body = $bodyObj | ConvertTo-Json -Depth 8 -Compress
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $row = [ordered]@{
        name = $Name
        ok = $false
        elapsed_ms = 0
        completion_tokens = 0
        prompt_tokens = 0
        content_chars = 0
        predicted_per_second = $null
        draft_n = $null
        draft_n_accepted = $null
        accept = $null
        garbage = $null
        error = $null
    }
    try {
        $j = Invoke-RestMethod -Uri "$BaseUrl/v1/chat/completions" -Method POST -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec $TimeoutSec
        $sw.Stop()
        $row.elapsed_ms = $sw.ElapsedMilliseconds
        $text = [string]$j.choices[0].message.content
        $row.content_chars = $text.Length
        if ($j.usage) {
            $row.completion_tokens = [int]$j.usage.completion_tokens
            $row.prompt_tokens = [int]$j.usage.prompt_tokens
        }
        if ($j.timings) {
            $row.predicted_per_second = $j.timings.predicted_per_second
            $row.draft_n = $j.timings.draft_n
            $row.draft_n_accepted = $j.timings.draft_n_accepted
            if ($j.timings.draft_n -gt 0) {
                $row.accept = [math]::Round($j.timings.draft_n_accepted / [double]$j.timings.draft_n, 4)
            }
        }
        $g = Test-Garbage $text
        if ($g) {
            $row.garbage = $g
            $fails.Add("$Name garbage: $g") | Out-Null
        }
        if ($row.completion_tokens -ge 200 -and $text.Length -lt 80) {
            $row.garbage = "empty_spoken"
            $fails.Add("$Name empty spoken content") | Out-Null
        }
        if ($null -ne $row.draft_n -and $row.draft_n -gt 50 -and ($null -eq $row.accept -or $row.accept -lt 0.15)) {
            $fails.Add(("{0} draft accept {1} (draft_n={2})" -f $Name, $row.accept, $row.draft_n)) | Out-Null
        }
        $row.ok = ($fails | Where-Object { $_ -like "$Name *" }).Count -eq 0
        $script:lastText = $text
        return $text
    } catch {
        $sw.Stop()
        $row.elapsed_ms = $sw.ElapsedMilliseconds
        $row.error = $_.Exception.Message
        $fails.Add("$Name error: $($_.Exception.Message)") | Out-Null
        $script:lastText = ""
        return ""
    } finally {
        if (-not (Get-Process -Name llama-server -ErrorAction SilentlyContinue)) {
            $fails.Add("$Name llama-server died") | Out-Null
            $row.ok = $false
        }
        if (-not (Test-MouthUp)) {
            $fails.Add("$Name health down") | Out-Null
            $row.ok = $false
        }
        $runs.Add([pscustomobject]$row) | Out-Null
        Write-Host ("{0} ok={1} tok={2} t/s={3} accept={4} chars={5} {6}" -f `
            $Name, $row.ok, $row.completion_tokens, $row.predicted_per_second, $row.accept, $row.content_chars, $row.garbage)
    }
}

$script:lastText = ""
$null = Invoke-Complete "spoken-2048-a" @(
    @{ role = "user"; content = "Tell the entire story of Forrest Gump scene by scene in exhaustive detail. Number every paragraph. After the movie ends, start again from the beginning. Do not stop." }
) 2048 0.7

$null = Invoke-Complete "spoken-2048-b" @(
    @{ role = "user"; content = "Write a continuous technical log of a Windows SRE diagnose loop: ping, nslookup, tracert, then NIC-to-Tcpip binding. Keep adding numbered steps forever. No summary." }
) 2048 0.4

$null = Invoke-Complete "spoken-4096" @(
    @{ role = "user"; content = "Narrate a year on this desk as a continuous day-by-day journal. One paragraph per day. Never stop. Never repeat the same sentence." }
) 4096 0.8

$padSrc = ""
$agents = Join-Path $RepoRoot "AGENTS.md"
if (Test-Path -LiteralPath $agents) {
    $padSrc = (Get-Content -LiteralPath $agents -Raw)
    if ($padSrc.Length -gt 7000) { $padSrc = $padSrc.Substring(0, 7000) }
}
$libUser = @"
Transcript (raw, immutable). First character must be '{'.

$padSrc

Extract at most 6 specific claims from the transcript. Output one JSON object only. schema_version 1.0, extractor Librarian-CPP, trust_tier raw_candidate, claims[{claim_id, type, content, confidence, evidence_spans}]. Close every brace. No markdown. No thinking.
"@
$libText = Invoke-Complete "librarian-2048" @(
    @{ role = "user"; content = $libUser }
) 2048 0
if ($libText -and $libText.TrimStart().StartsWith("{") -eq $false) {
    $fails.Add("librarian-2048 did not start with '{'") | Out-Null
}

$hist = New-Object System.Collections.Generic.List[object]
$hist.Add(@{ role = "user"; content = "Continue a numbered list of Windows host facts, one fact per line. Start at 1. Do not stop." }) | Out-Null
for ($i = 1; $i -le 3; $i++) {
    $turn = Invoke-Complete "grow-$i" @($hist.ToArray()) 1024 0.5
    $hist.Add(@{ role = "assistant"; content = $turn }) | Out-Null
    $hist.Add(@{ role = "user"; content = "Continue the numbered list. Do not restart at 1. Do not stop." }) | Out-Null
}

$errHits = Get-ErrHits
$cudaHits = @($errHits | Where-Object { $_ -match '(?i)CUDA error|illegal memory access|GGML_ASSERT|GGML_ABORT' })
if ($cudaHits.Count -gt 0) {
    foreach ($h in $cudaHits) { $fails.Add("errlog: $h") | Out-Null }
}

$alive = [bool](Get-Process -Name llama-server -ErrorAction SilentlyContinue)
$health = Test-MouthUp
$ok = ($fails.Count -eq 0) -and $alive -and $health
$elapsedS = [int]((Get-Date) - $started).TotalSeconds
$runDtos = @($runs | ForEach-Object {
    [pscustomobject]@{
        name = [string]$_.name
        ok = [bool]$_.ok
        elapsed_ms = [int]$_.elapsed_ms
        completion_tokens = [int]$_.completion_tokens
        prompt_tokens = [int]$_.prompt_tokens
        content_chars = [int]$_.content_chars
        predicted_per_second = $(if ($null -eq $_.predicted_per_second) { 0.0 } else { [double]$_.predicted_per_second })
        draft_n = $(if ($null -eq $_.draft_n) { 0 } else { [int]$_.draft_n })
        draft_n_accepted = $(if ($null -eq $_.draft_n_accepted) { 0 } else { [int]$_.draft_n_accepted })
        accept = $(if ($null -eq $_.accept) { 0.0 } else { [double]$_.accept })
        garbage = $(if ($null -eq $_.garbage) { "" } else { [string]$_.garbage })
        error = $(if ($null -eq $_.error) { "" } else { [string]$_.error })
    }
})
$failArr = @($fails | ForEach-Object { [string]$_ })
$errArr = @($errHits | Select-Object -Last 12 | ForEach-Object { [string]$_ })
$dto = [pscustomobject]@{
    at = (Get-Date).ToUniversalTime().ToString("o")
    ok = [bool]$ok
    mouth = [string]$mouth
    base_url = [string]$BaseUrl
    elapsed_s = $elapsedS
    llama_alive = [bool]$alive
    health = [bool]$health
    fail_count = [int]$fails.Count
    fails = $failArr
    err_hits = $errArr
    runs = $runDtos
}
$json = ConvertTo-Json -InputObject $dto -Depth 8
Set-Content -LiteralPath $outJson -Value $json -Encoding utf8
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add(("mtp-soak ok={0} mouth={1} elapsed_s={2} fails={3}" -f $ok, $mouth, $elapsedS, $fails.Count)) | Out-Null
foreach ($r in $runDtos) {
    $lines.Add(("  {0} ok={1} tok={2} t/s={3:n1} accept={4:n3} chars={5}" -f $r.name, $r.ok, $r.completion_tokens, $r.predicted_per_second, $r.accept, $r.content_chars)) | Out-Null
}
foreach ($f in $failArr) { $lines.Add("FAIL $f") | Out-Null }
$textOut = $lines -join "`n"
Set-Content -LiteralPath $outTxt -Value $textOut -Encoding utf8
Write-Host $textOut
if (-not $ok) { exit 1 }
exit 0
