[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "GodBrain-SharedMemory.ps1")
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Fails([scriptblock]$Action, [string]$Pattern = "*") {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure: $Pattern"
}
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction)
    $payload = if ($null -ne $Body) {
        $json = if ($Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Body) } else { $Body }
        $json | ConvertFrom-Json
    }
    $script:calls += @{ uri = $Uri; payload = $payload; headers = $Headers }
    switch ($Uri) {
        "http://127.0.0.1:8083/api/index" {
            return @{ state = "indexed"; persisted = $true; promoted = $false; response = "Indexed fixture." }
        }
        "http://127.0.0.1:8083/api/context" {
            if ($script:contextFails) { throw "Fixture context unavailable." }
            return @{ schema_version = "shared-context-v1"; state = "ready"; scope = $payload.scope
                trust = "untrusted_reference"; context = "SHARED_FIXTURE"; request_tools = @() }
        }
        "http://127.0.0.1:8083/api/shelf" {
            if ($script:saveFails) { throw "Fixture store unavailable." }
            return @{ schema_version = "working-shelf-v1"; shelf = "discussion"; trust = "untrusted"
                promoted = $false; record = @{ _id = ("a" * 64); text = $payload.text; scope = $payload.scope
                    thread_id = $payload.thread_id; request_id = $payload.request_id } }
        }
        "http://127.0.0.1:8888/health" {
            return @{ backend = "exl3"; busy = $script:busy; model = "fixture-model" }
        }
        "http://127.0.0.1:8888/v1/models" { return @{ data = @(@{ id = "fixture-model" }) } }
        "http://127.0.0.1:8888/v1/chat/completions" {
            return @{ choices = @(@{ finish_reason = $script:finish
                message = @{ content = "Fixture answer."; tool_calls = $script:tools } }) }
        }
        default { throw "Unexpected HTTP endpoint: $Uri" }
    }
}
$previous = $env:GODBRAIN_API_TOKEN
try {
    $env:GODBRAIN_API_TOKEN = "fixture-token"
    $script:calls = @(); $script:contextFails = $false; $script:saveFails = $false
    $script:busy = $false; $script:finish = "stop"; $script:tools = @()
    $client = Join-Path $PSScriptRoot "Invoke-LocalLLM.ps1"
    Assert ((. $client "index") -ceq "Indexed fixture.") "Index did not return its receipt."
    Assert ($script:calls.Count -eq 1 -and $script:calls[0].uri -like "*/api/index") "Index touched the model."
    $script:calls = @()
    Assert ((. $client "A fresh question" -SystemPrompt "Custom system.") -ceq "Fixture answer.") "Fresh client failed."
    Assert ($script:calls[0].uri -like "*/api/context" -and $script:calls[-1].uri -like "*/api/shelf") "Context/save ordering changed."
    $completion = @($script:calls | Where-Object uri -like "*/chat/completions")[0].payload
    Assert ($completion.messages[0].content -ceq "Custom system.") "Custom system prompt changed."
    Assert ($completion.messages[1].content -like "*SHARED_FIXTURE*Operator request:*A fresh question") "Shared context not supplied."
    Assert ($completion.tool_choice -ceq "none" -and -not $completion.chat_template_kwargs.enable_thinking) "Direct-client permissions changed."
    Assert ($script:calls[-1].payload.text -notmatch "SHARED_FIXTURE") "Saved recursively injected context instead of the original request."
    foreach ($call in $script:calls | Where-Object uri -like "*:8083/*") {
        Assert ($call.headers.Authorization -ceq "Bearer fixture-token") "Memory request lost authorization."
    }
    $script:calls = @()
    [void](. $client "Personal fixture" -Scope personal)
    Assert ($script:calls[0].payload.scope -ceq "personal" -and
        $script:calls[-1].payload.scope -ceq "personal") "Personal and technical shelves mixed."
    $env:GODBRAIN_API_TOKEN = $null
    foreach ($parameters in @(@{ Prompt = "No tools. Advisory" }, @{ Prompt = "Legacy"; NoSharedMemory = $true })) {
        $script:calls = @()
        [void](. $client @parameters)
        Assert (@($script:calls | Where-Object uri -like "*:8083/*").Count -eq 0) "Memory-free mode used shared storage."
    }
    $script:calls = @()
    Assert-Fails { . $client "Needs shared context" } "*requires GODBRAIN_API_TOKEN*"
    Assert ($script:calls.Count -eq 0) "Missing authorization made an HTTP request."
    $env:GODBRAIN_API_TOKEN = "fixture-token"
    $script:contextFails = $true; $script:calls = @()
    Assert-Fails { . $client "Needs shared context" } "*context unavailable*"
    Assert ($script:calls.Count -eq 1) "Failed context silently proceeded to generation."
    $script:contextFails = $false; $script:saveFails = $true; $script:calls = @()
    Assert-Fails { . $client "Save failure" } "*not confirmed saved*Answer:*Fixture answer.*"
    Assert (@($script:calls | Where-Object uri -like "*/api/shelf").Count -eq 1) "Save was silently retried."
    $script:saveFails = $false; $script:finish = "length"; $script:calls = @()
    Assert-Fails { . $client "Truncated" } "*did not finish*"
    Assert (@($script:calls | Where-Object uri -like "*/api/shelf").Count -eq 0) "Incomplete answer was saved."
    $script:finish = "stop"; $script:tools = @(@{ function = @{ name = "fixture" } })
    Assert-Fails { . $client "Unexpected tools" } "*no plain-text answer*"
    $script:tools = @(); $script:busy = $true; $script:calls = @()
    Assert-Fails { . $client "Busy" } "*must already be running and idle*"
    Assert (@($script:calls | Where-Object uri -like "*/chat/completions").Count -eq 0) "Busy model generated."
    $script:busy = $false; $script:calls = @()
    $unicode = [char]::ConvertFromUtf32(0x1f642) * 10000
    $null = Save-GodBrainWorkingTurn -Prompt $unicode -Response $unicode
    $saved = $script:calls[-1].payload.text
    Assert ([Text.Encoding]::UTF8.GetByteCount($saved) -le 32768 -and $saved -match "excerpt truncated.*complete_sha256=") "Working excerpt is unbounded or unlabeled."
    [void][Text.UTF8Encoding]::new($false, $true).GetBytes($saved)
    Assert-Fails { Get-GodBrainSharedContext -Query "fixture" -ThreadId "bad thread" }
    Write-Host "PASS: Shared-memory clients (mock HTTP, authorization, modes, scopes, index, persistence, UTF-8)"
} finally {
    $env:GODBRAIN_API_TOKEN = $previous
}
