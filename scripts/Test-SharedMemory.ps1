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
    param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, $MaximumRedirection)
    $payload = if ($null -ne $Body) {
        $json = if ($Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Body) } else { $Body }
        $json | ConvertFrom-Json
    }
    $script:calls += @{ uri = $Uri; payload = $payload; headers = $Headers; redirects = $MaximumRedirection }
    switch ($Uri) {
        "http://127.0.0.1:8083/api/chat" {
            if ($script:redirect) {
                if ($MaximumRedirection -ne 0) { throw "Redirect protection missing." }
                throw "Fixture redirect rejected: $($Headers.Authorization)"
            }
            return @{ response = "Fixture kernel answer." }
        }
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
    foreach ($thread in @("desk", "explicit-thread")) {
        $script:calls = @()
        $options = if ($thread -ceq "desk") { @{} } else { @{ ThreadId = $thread } }
        $null = Get-GodBrainSharedContext -Query "fixture" @options
        $null = Save-GodBrainWorkingTurn -Prompt "fixture" -Response "answer" @options
        Assert ($script:calls[0].payload.thread_id -ceq $thread -and
            $script:calls[1].payload.thread_id -ceq $thread) "Shared default/explicit threads diverged."
    }
    $ask = Join-Path $PSScriptRoot "Ask-GodBrain.ps1"
    foreach ($base in @("http://127.0.0.1:8083", "http://localhost:8083/")) {
        foreach ($question in @("A question", "/brief", "/verify last fixture")) {
            $script:calls = @()
            Assert ((. $ask -Base $base -Text $question) -ceq "Fixture kernel answer.") "Kernel ask failed."
            Assert ($script:calls.Count -eq 1 -and $script:calls[0].uri -ceq
                "http://127.0.0.1:8083/api/chat") "Ask did not use the canonical kernel."
            Assert ($script:calls[0].headers.Authorization -ceq ("Bearer " + $env:GODBRAIN_API_TOKEN) -and
                $script:calls[0].redirects -eq 0) "Ask lost authorization or allowed redirects."
        }
    }
    foreach ($base in @("http://example.invalid:8083", "https://example.invalid",
        "http://127.0.0.1:8084", "https://127.0.0.1:8083", "http://127.0.0.1:8083/path", "http://127.0.0.1:8083/?q=1",
        "http://user:password@127.0.0.1:8083", "http://127.0.0.1:8083/#fragment", "not a URI")) {
        $script:calls = @()
        Assert-Fails { . $ask -Base $base -Text "No forwarding" } "*canonical loopback kernel*"
        Assert ($script:calls.Count -eq 0) "Rejected destination received a request."
    }
    $script:redirect = $true; $script:calls = @()
    try { . $ask -Text "Redirect fixture" | Out-Null; throw "Expected redirect failure." } catch {
        Assert ($_.Exception.Message -like "Ask-GodBrain failed:*" -and
            -not $_.Exception.Message.Contains($env:GODBRAIN_API_TOKEN)) "Redirect error leaked credentials or was not explicit."
    }
    Assert ($script:calls.Count -eq 1) "Ask followed or retried a redirect."
    $script:redirect = $false
    $env:GODBRAIN_API_TOKEN = $null; $script:calls = @()
    Assert ((. $ask -Text "/brief") -ceq "Fixture kernel answer.") "Anonymous glance failed."
    Assert (-not $script:calls[0].headers) "Anonymous request sent credentials."
    Assert-Fails { . $ask -Text "/verify last fixture" } "*requires GODBRAIN_API_TOKEN*"
    $env:GODBRAIN_API_TOKEN = "fixture-token"; $script:calls = @()
    $script:busy = $false; $script:finish = "stop"; $script:tools = @()
    $client = Join-Path $PSScriptRoot "Invoke-LocalLLM.ps1"
    Assert ((. $client "index") -ceq "Indexed fixture.") "Index did not return its receipt."
    Assert ($script:calls.Count -eq 1 -and $script:calls[0].uri -like "*/api/index") "Index touched the model."
    $script:calls = @()
    Assert ((. $client "A fresh question" -SystemPrompt "Custom system.") -ceq "Fixture answer.") "Fresh client failed."
    Assert ($script:calls[0].uri -like "*/api/context" -and $script:calls[-1].uri -like "*/api/shelf") "Context/save ordering changed."
    Assert ($script:calls[0].payload.thread_id -ceq "desk" -and
        $script:calls[-1].payload.thread_id -ceq "desk") "Fresh client did not share the Desk thread."
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
