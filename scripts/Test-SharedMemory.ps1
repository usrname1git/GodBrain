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
            if ($payload.action -ceq "read") {
                $rows = @($script:shelfRecords | Where-Object {
                    $_.shelf -ceq $payload.shelf -and $_.scope -ceq $payload.scope
                } | Select-Object -Last $payload.limit | ForEach-Object { $_.Clone() })
                if ($script:badReadScope -and $rows.Count) { $rows[0].scope = "personal" }
                return @{ status = "ok"; schema_version = "working-shelf-v1"; shelf = $payload.shelf
                    trust = $(if ($script:badReadTrust) { "verified" } else { "untrusted" })
                    promoted = $false; records = $rows; count = $rows.Count; more = $false }
            }
            $row = @{ _id = ("{0:x64}" -f ($script:shelfRecords.Count + 1)); text = $payload.text
                title = $payload.title; scope = $payload.scope; sources = @($payload.sources)
                schema_version = "working-shelf-v1"; trust = "untrusted"; source_hash = ("b" * 64)
                shelf = $payload.shelf; thread_id = $payload.thread_id; request_id = $payload.request_id
                host_id = "private-fixture-host" }
            $script:shelfRecords += $row
            $reply = $row.Clone()
            if ($script:badResearchReceipt) { $reply.text = "Not the requested handoff." }
            return @{ status = "stored"; schema_version = "working-shelf-v1"; shelf = $payload.shelf
                trust = "untrusted"; promoted = $false; record = $reply }
        }
        "http://127.0.0.1:8888/health" {
            return @{ backend = "exl3"; busy = $script:busy; model = "fixture-model" }
        }
        "http://127.0.0.1:8083/api/aai" {
            if ($script:busy) { throw "EXL3 must already be running and idle." }
            if ($script:contextFails) { throw "Fixture context unavailable." }
            if ($script:saveFails) { throw "Generated answer was not confirmed saved. Answer: Fixture answer." }
            return @{
                response = "Fixture answer."; shared_saved = (-not $script:badAaiReceipt)
                shared_record_id = ("a" * 64)
                scope = $(if ($script:badAaiScope) { "personal" } else { $payload.scope })
                thread_id = $payload.thread_id
                request_receipt = @{ tool_attempts = @($script:toolAttempts) }
            }
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
$testFolder = Join-Path ([IO.Path]::GetTempPath()) ("godbrain-shared-handoff-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($testFolder)
try {
    $env:GODBRAIN_API_TOKEN = "fixture-token"
    $script:calls = @(); $script:contextFails = $false; $script:saveFails = $false
    $script:shelfRecords = @()
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
    $script:shelfRecords = @(); $script:badReadScope = $false; $script:badReadTrust = $false
    $script:badResearchReceipt = $false
    $script:badAaiReceipt = $false; $script:badAaiScope = $false; $script:toolAttempts = @()
    $client = Join-Path $PSScriptRoot "Invoke-LocalLLM.ps1"
    Assert ((. $client "index") -ceq "Indexed fixture.") "Index did not return its receipt."
    Assert ($script:calls.Count -eq 1 -and $script:calls[0].uri -like "*/api/index") "Index touched the model."
    $script:calls = @()
    Assert ((. $client "A fresh question" -SystemPrompt "Custom system.") -ceq "Fixture answer.") "Fresh client failed."
    Assert ($script:calls.Count -eq 1 -and $script:calls[0].uri -like "*/api/aai") "Shared mode bypassed the native tool loop or duplicated persistence."
    $completion = $script:calls[0].payload
    Assert ($completion.thread_id -ceq "desk") "Fresh client did not share the Desk thread."
    Assert ($completion.system_prompt -ceq "Custom system.") "Custom response preference changed."
    Assert ($completion.message -ceq "A fresh question" -and
        $completion.message -notmatch "SHARED_FIXTURE") "Client injected memory into the operator message."
    $script:calls = @()
    [void](. $client "Another session" -ThreadId "fresh-cli-session")
    Assert ($script:calls[0].payload.thread_id -ceq "fresh-cli-session") "Thread identity did not reach the kernel."
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
    Assert ($script:calls.Count -eq 1) "Failed kernel persistence was silently retried."
    $script:saveFails = $false; $script:badAaiReceipt = $true
    Assert-Fails { . $client "Bad receipt" } "*confirmed shared-memory persistence*"
    $script:badAaiReceipt = $false; $script:badAaiScope = $true
    Assert-Fails { . $client "Cross-scope receipt" } "*confirmed shared-memory persistence*"
    $script:badAaiScope = $false; $script:toolAttempts = @(@{ executor_ok = $false })
    Assert-Fails { . $client "Failed tool" } "*failed or invalid tool receipt*"
    $script:toolAttempts = @()
    $script:saveFails = $false; $script:finish = "length"; $script:calls = @()
    Assert-Fails { . $client "Truncated" -NoSharedMemory } "*did not finish*"
    Assert (@($script:calls | Where-Object uri -like "*/api/shelf").Count -eq 0) "Incomplete answer was saved."
    $script:finish = "stop"; $script:tools = @(@{ function = @{ name = "fixture" } })
    Assert-Fails { . $client "Unexpected tools" -NoSharedMemory } "*no plain-text answer*"
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
    $script:calls = @()
    $researchText = "Observed result " + [char]::ConvertFromUtf32(0x1f642) + "`nChecks passed; applicability unknown."
    $receipt = Save-GodBrainResearchHandoff -Title "Fixture research" -Text $researchText `
        -ThreadId "research-fixture" -Sources @("fixture.txt SHA256 evidence") -RequestId "fixture-research-1"
    Assert ($receipt.trust -ceq "untrusted" -and $receipt.promoted -eq $false -and
        $receipt.record.text -ceq $researchText) "Research helper did not preserve the untrusted handoff."
    Assert ($script:calls[0].payload.shelf -ceq "research" -and
        $script:calls[0].payload.sources[0] -ceq "fixture.txt SHA256 evidence") "Research provenance changed."
    $destination = Join-Path $testFolder "handoff.json"
    $script:calls = @()
    $export = Export-GodBrainSharedHandoff -Query "fixture" -Path $destination -ThreadId "new-reader"
    $exportText = [IO.File]::ReadAllText($destination, [Text.UTF8Encoding]::new($false, $true))
    $packet = $exportText | ConvertFrom-Json
    Assert ($export.state -ceq "exported" -and $export.bytes -le 32768 -and
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $export.sha256) "Export receipt/hash was invalid."
    Assert ($packet.context -ceq "SHARED_FIXTURE" -and $packet.research[0].text -ceq $researchText -and
        $packet.research[0].sources[0] -ceq "fixture.txt SHA256 evidence") "Export lost context, Unicode or complete research."
    Assert ($packet.scope -ceq "technical" -and $packet.trust -ceq "untrusted_reference" -and
        -not $packet.promoted -and $packet.request_tools.Count -eq 0) "Export granted authority or changed scope."
    Assert ($exportText -notmatch "fixture-token|private-fixture-host" -and
        @($script:calls | Where-Object uri -notlike "http://127.0.0.1:8083/*").Count -eq 0) "Export exposed caller metadata or touched a model."
    $beforeCalls = $script:calls.Count
    Assert-Fails { Export-GodBrainSharedHandoff -Query "fixture" -Path $destination } "*already exists*"
    Assert ($script:calls.Count -eq $beforeCalls -and [IO.File]::ReadAllText($destination) -ceq $exportText) "Export overwrite changed the file or made requests."
    [void](Save-GodBrainResearchHandoff -Title "Personal fixture" -Text "Personal-only fixture." -Scope personal)
    $personal = Export-GodBrainSharedHandoff -Query "fixture" -Scope personal -Path (Join-Path $testFolder "personal.json")
    $personalPacket = Get-Content -LiteralPath $personal.path -Raw | ConvertFrom-Json
    Assert ($personalPacket.scope -ceq "personal" -and $personalPacket.research.Count -eq 1 -and
        $personalPacket.research[0].text -ceq "Personal-only fixture.") "Personal export included technical research."
    $invalidPath = Join-Path $testFolder "invalid.json"
    $script:badReadScope = $true
    Assert-Fails { Export-GodBrainSharedHandoff -Query "fixture" -Path $invalidPath } "*cross-scope*"
    Assert (-not (Test-Path -LiteralPath $invalidPath)) "Cross-scope data was written."
    $script:badReadScope = $false; $script:badReadTrust = $true
    Assert-Fails { Export-GodBrainSharedHandoff -Query "fixture" -Path $invalidPath } "*invalid research shelf*"
    $script:badReadTrust = $false; $script:badResearchReceipt = $true
    Assert-Fails { Save-GodBrainResearchHandoff -Title "Fixture mismatch" -Text "Actual text." } "*did not confirm*"
    $script:badResearchReceipt = $false
    [void](Save-GodBrainResearchHandoff -Title "Large fixture" -Text ("x" * 32000))
    $bounded = Export-GodBrainSharedHandoff -Query "fixture" -Path (Join-Path $testFolder "bounded.json")
    $boundedPacket = Get-Content -LiteralPath $bounded.path -Raw | ConvertFrom-Json
    Assert ($bounded.bytes -le 32768 -and $bounded.omitted_research -eq 1 -and
        $boundedPacket.omitted_research[0].reason -like "*complete record*" -and
        @($boundedPacket.research | Where-Object title -eq "Large fixture").Count -eq 0) "Oversized research was silently truncated or unbounded."
    $env:GODBRAIN_API_TOKEN = $null; $script:calls = @()
    Assert-Fails { Export-GodBrainSharedHandoff -Query "fixture" -Path $invalidPath } "*requires GODBRAIN_API_TOKEN*"
    Assert ($script:calls.Count -eq 0 -and -not (Test-Path -LiteralPath $invalidPath)) "Unauthorized export wrote data or made a request."
    Write-Host "PASS: Shared-memory clients (authorization, modes, scopes, threads, research handoffs, bounded exports, UTF-8)"
} finally {
    $env:GODBRAIN_API_TOKEN = $previous
    foreach ($file in [IO.Directory]::GetFiles($testFolder)) { [IO.File]::Delete($file) }
    [IO.Directory]::Delete($testFolder)
}
