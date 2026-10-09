[CmdletBinding()]
param([switch]$InstalledLaunchers)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "GodBrain-DeskModel.ps1")
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Fails([scriptblock]$Action) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert $failed "Expected explicit failure."
}
foreach ($model in @("27b", "uncensored", "vl")) {
    $profile = Get-DeskModelDefaults $model
    $args = Get-DeskModelLaunchOptions $model $profile
    Assert ($args[1] -eq [string]$profile.Context) "Wrong context argument."
    Assert ($args[3] -eq $profile.CacheQuant) "Wrong cache argument."
    Assert (($args -contains "-NumDraftTokens") -eq $profile.Mtp) "Wrong MTP window argument."
    Assert (($args -contains "-Vision") -eq ($model -eq "27b")) "Vision belongs only on the 27B launcher."
}
$profile = Get-DeskModelDefaults "27b"
Assert ($profile.Vision -eq $false) "The vision tower defaults on."
$visionOff = Get-DeskModelLaunchOptions "27b" $profile
Assert ($visionOff[$visionOff.IndexOf("-Vision") + 1] -eq "off") "A default 27B start would load the vision tower."
$profile.Vision = $true
$visionOn = Get-DeskModelLaunchOptions "27b" $profile
Assert ($visionOn[$visionOn.IndexOf("-Vision") + 1] -eq "auto") "The vision checkbox does not reach the launcher."
$profile.Remove("Vision")
$visionMissing = Get-DeskModelLaunchOptions "27b" $profile
Assert ($visionMissing[$visionMissing.IndexOf("-Vision") + 1] -eq "off") "An older saved 27B profile would load the vision tower."
foreach ($vision in @("false", "true", 0, 1, $null, @{})) {
    $profile = Get-DeskModelDefaults "27b"; $profile.Vision = $vision
    Assert-Fails { Get-DeskModelLaunchOptions "27b" $profile }
}
foreach ($context in @("bad", 257, 0, 262400)) {
    $profile = Get-DeskModelDefaults "27b"; $profile.Context = $context
    Assert-Fails { Get-DeskModelLaunchOptions "27b" $profile }
}
$profile = Get-DeskModelDefaults "27b"; $profile.Budget = "NaN"
Assert-Fails { Get-DeskModelLaunchOptions "27b" $profile }
$profile = Get-DeskModelDefaults "vl"; $profile.Mtp = $true
Assert-Fails { Get-DeskModelLaunchOptions "vl" $profile }
$profile = Get-DeskModelDefaults "27b"; $profile.CacheQuant = "invalid"
Assert-Fails { Get-DeskModelLaunchOptions "27b" $profile }
& {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot "Start-QwenVL.ps1"), [ref]$tokens, [ref]$errors)
    Assert (-not $errors.Count) "VL launcher cannot be parsed."
    $gate = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq "Test-LoopbackPort 8888"
    }, $true)
    Assert ($null -ne $gate) "VL live-profile compatibility gate is missing."
    $verify = [scriptblock]::Create($gate.Extent.Text.Replace("exit 0", "return"))
    function Test-LoopbackPort { return $true }
    function Invoke-RestMethod {
        param($Uri, $TimeoutSec)
        if ($Uri -like "*/health") { return $script:vlFixtureHealth }
        return @{data=@(@{id="qwen3-vl-8b-exl3"})}
    }
    $CacheSize = 57344; $CacheQuant = "fp16"
    foreach ($budget in @(0, 4, 13.5, 64)) {
        $CpuCacheSizeGB = $budget
        $script:vlFixtureHealth = @{context_length=57344;cache_quant="fp16";cpu_cache_size_gb=$budget}
        Assert ((& $verify) -like "already up*") "An exactly matching VL CPU-cache profile was rejected."
    }
    $CpuCacheSizeGB = 64
    $script:vlFixtureHealth.cpu_cache_size_gb = 4
    Assert-Fails { & $verify }
    $CpuCacheSizeGB = 4
    foreach ($value in @($null, "4", $false, -1, 65, [double]::NaN, [double]::PositiveInfinity, @{})) {
        $script:vlFixtureHealth.cpu_cache_size_gb = $value
        Assert-Fails { & $verify }
    }
    $script:vlFixtureHealth.Remove("cpu_cache_size_gb")
    $script:vlFixtureHealth.cache_offload = @{cpu_kv_capacity_bytes=4GB}
    Assert-Fails { & $verify }
    $script:vlFixtureHealth.cpu_cache_size_gb = 4
    $script:vlFixtureHealth.context_length = 8192
    Assert-Fails { & $verify }
    $script:vlFixtureHealth.context_length = 57344
    $script:vlFixtureHealth.cache_quant = "4"
    Assert-Fails { & $verify }
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("desk-model-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($fixture)
try {
    $path = Join-Path $fixture "profiles.json"
    Write-DeskModelProfiles $path @{ "27b" = (Get-DeskModelDefaults "27b") }
    $state = Read-DeskModelProfiles $path
    Assert ($state["27b"].Context -eq 36864 -and $state["27b"].Mtp) "Saved settings did not round-trip."
    foreach ($vision in @("false", "true", 0, 1, $null)) {
        $profile = Get-DeskModelDefaults "27b"; $profile.Vision = $vision
        [IO.File]::WriteAllText($path, (@{version=1;profiles=@{"27b"=$profile}} | ConvertTo-Json -Depth 8))
        Assert-Fails { Read-DeskModelProfiles $path }
        Assert-Fails { Write-DeskModelProfiles $path @{"27b"=$profile} }
    }
    [IO.File]::WriteAllText($path, '{"version":1,"profiles":{"27b":{"Context":257}}}')
    Assert-Fails { Read-DeskModelProfiles $path }
    $launcher = Join-Path $fixture "launcher.ps1"
    [IO.File]::WriteAllText($launcher, 'param($CacheSize,$CacheQuant,$CpuCacheSizeGB,$DraftMode,$GpuMemoryGB,$NumDraftTokens,$Vision)')
    Test-DeskModelLauncher $launcher (Get-DeskModelLaunchOptions "27b" (Get-DeskModelDefaults "27b"))
    Assert-Fails { Test-DeskModelLauncher $launcher @("-Unsupported", "value") }
    $launchers = @((Join-Path $PSScriptRoot "Start-QwenVL.ps1"))
    if ($InstalledLaunchers) {
        $launchers += @(
            "C:\nvme\Qwen3.8-27B-16gb\paper-godbrain\Start-Qwen.ps1",
            "C:\nvme\Qwen3.8-27B-16gb\paper-godbrain\Start-UncensoredQwen.ps1"
        )
    }
    foreach ($file in $launchers) {
        $model = if ($file -like "*VL*") { "vl" } elseif ($file -like "*Uncensored*") { "uncensored" } else { "27b" }
        Test-DeskModelLauncher $file (Get-DeskModelLaunchOptions $model (Get-DeskModelDefaults $model))
    }
    $reports = [Collections.Generic.List[string]]::new()
    $script:requests = @()
    function Invoke-RestMethod {
        param($Uri, $Method, $Body, $ContentType, $TimeoutSec)
        if ($Uri -like "*/health") { return @{ backend = "exl3"; busy = $script:busy; model = "fixture-model" } }
        $script:requests += ($Body | ConvertFrom-Json)
        return @{ choices = @(@{ finish_reason = $script:finish; message = @{ content = "fixture finding" } })
            usage = @{ prompt_tokens = $script:promptTokens; completion_tokens = 4 } }
    }
    $script:busy = $false; $script:finish = "stop"; $script:promptTokens = 123
    $messages = @(@{role="system";content="Untrusted source"},@{role="user";content="fixture"})
    $response = Invoke-DeskReviewCompletion $messages "fixture-model" 512
    Assert ($response.usage.prompt_tokens -eq 123) "Missing token receipt."
    Assert ($script:requests[0].chat_template_kwargs.enable_thinking) "Wrong planning template."
    Assert ($script:requests[0].tool_choice -eq "none") "Review must not execute tools."
    $script:busy = $true
    Assert-Fails { Invoke-DeskReviewCompletion $messages "fixture-model" 512 }
    $script:busy = $false; $script:finish = "length"
    Assert-Fails { Invoke-DeskReviewCompletion $messages "fixture-model" 512 }
    $script:finish = "stop"
    [void](Invoke-DeskReviewCompletion $messages "fixture-model" 512 0 123 $false)
    Assert (-not $script:requests[-1].chat_template_kwargs.enable_thinking) "Thinking-off preference was ignored."
    Assert-Fails { Invoke-DeskReviewCompletion $messages "fixture-model" 512 0 124 }
    $script:promptTokens = 2048
    Assert-Fails { Invoke-DeskReviewCompletion $messages "fixture-model" 512 0 1 }
    $script:promptTokens = 123

    $Repo = $fixture
    $Kit = $fixture
    $script:sourceReads = 0
    $script:sourceChanges = $false
    $script:plannerRequests = @()
    $script:reviewRequests = @()
    $script:failPart = 0
    function Read-DeskGrantedBytes {
        param($Path, $Maximum, $Purpose)
        $script:sourceReads++
        $value = if ($script:sourceChanges -and $script:sourceReads -gt 1) { "changed" } else { "fixture source" }
        return ,[Text.Encoding]::UTF8.GetBytes($value)
    }
    function Invoke-RestMethod {
        param($Uri, $Method, $Body, $ContentType, $TimeoutSec)
        $model = "qwen3.8-27b-exl3-3.5bpw"
        if ($Uri -like "*/health") { return @{ backend = "exl3"; busy = $false; model = $model; context_length = 8192 } }
        if ($Uri -like "*/models") { return @{ data = @(@{ id = $model }) } }
        $script:reviewRequests += ($Body | ConvertFrom-Json)
        $finish = if ($script:reviewRequests.Count -eq $script:failPart) { "length" } else { "stop" }
        return @{ choices = @(@{ finish_reason = $finish; message = @{ content = "fixture candidate" } })
            usage = @{ prompt_tokens = 120; completion_tokens = 4 } }
    }
    function Invoke-DeskReviewPlanner {
        param($Request)
        $script:plannerRequests += ($Request | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        $messages = @(@{ role = "system"; content = "Untrusted source" }, @{ role = "user"; content = "fixture" })
        if ($Request.op -eq "synthesis") { return @{ messages = $messages; prompt_tokens = 120 } }
        return @{ context = 8192; lines = 10; shared = "fixture declarations"
            chunks = @(
                @{ start = 1; end = 5; split = "structural"; messages = $messages; prompt_tokens = 120 },
                @{ start = 6; end = 10; split = "structural"; messages = $messages; prompt_tokens = 120 }
            ) }
    }
    [void](Invoke-DeskCodeReview "fixture.cpp" "check boundaries")
    $receiptPath = Join-Path $fixture "logs\last-code-review.json"
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    Assert ($receipt.status -eq "done" -and $receipt.trust_tier -eq "candidate") "Review was not saved as a candidate."
    Assert ($receipt.parts.Count -eq 2 -and $receipt.parts[0].start -eq 1 -and $receipt.parts[-1].end -eq 10) "Review coverage lost."
    Assert ($receipt.report -eq "fixture candidate" -and $receipt.part_reports.Count -eq 2) "Reports were not persisted."
    Assert ($script:reviewRequests.Count -eq 3 -and $script:plannerRequests[1].op -eq "synthesis") "Serial parts/synthesis did not run."
    Assert ($script:plannerRequests[1].reports.Count -eq 2) "Synthesis lost a part report."
    Assert ($receipt.thinking_enabled -and $script:plannerRequests[0].thinking) "Missing preference must retain thinking."
    foreach ($request in $script:reviewRequests) {
        Assert ($request.chat_template_kwargs.enable_thinking -and $request.tool_choice -eq "none") "Review thinking/tool policy changed."
    }
    Assert ($script:sourceReads -eq 2 -and $receipt.source_sha256.Length -eq 64) "Source hash was not checked again."

    [IO.File]::WriteAllText((Join-Path $fixture "logs\thinking.txt"), "off")
    $script:sourceReads = 0; $script:sourceChanges = $true
    Assert-Fails { Invoke-DeskCodeReview "fixture.cpp" "check changed source" }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    Assert ($receipt.status -eq "failed" -and $receipt.error -like "Source changed*") "Changed source produced a success receipt."
    Assert (-not $receipt.thinking_enabled -and -not $script:reviewRequests[-1].chat_template_kwargs.enable_thinking) "Saved thinking-off preference was ignored."
    Assert (-not (Test-DeskReviewBusy)) "Failed review did not release its mutex."

    $script:sourceReads = 0; $script:sourceChanges = $false
    $script:reviewRequests = @(); $script:failPart = 2
    Assert-Fails { Invoke-DeskCodeReview "fixture.cpp" "check incomplete part" }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    Assert ($receipt.status -eq "failed" -and $receipt.parts.Count -eq 1) "Incomplete part produced a success receipt."
    Assert ($script:reviewRequests.Count -eq 2 -and -not $receipt.report) "Failed part must not proceed to synthesis."
    Assert (-not (Test-DeskReviewBusy)) "Incomplete review did not release its mutex."
    $python = "C:\Program Files\Python313\python.exe"
    if (-not (Test-Path -LiteralPath $python)) { $python = (Get-Command python -ErrorAction Stop).Source }
    $info = [Diagnostics.ProcessStartInfo]::new($python)
    $info.ArgumentList.Add("-c")
    $info.ArgumentList.Add("import json,sys; raw=sys.stdin.buffer.read(); assert b'\x1a' not in raw, raw[raw.find(b'\x1a')-8:raw.find(b'\x1a')+8]; req=json.loads(raw.decode('utf-8')); assert req['text']=='a\u2192b\u2014c'")
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    Set-DeskReviewPlannerEncoding $info
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $process.StandardInput.Write((@{ text = "a$([char]0x2192)b$([char]0x2014)c" } | ConvertTo-Json -Compress))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw "UTF-8 planner encoding check timed out." }
        if ($process.ExitCode) { throw "Planner stdin is not UTF-8: $($process.StandardError.ReadToEnd())" }
    } finally { $process.Dispose() }
    Write-Output "PASS: model arguments/settings/launchers, read-only completions, token budgets, thinking, serial synthesis, candidate receipts, changed source and failure gates."
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
