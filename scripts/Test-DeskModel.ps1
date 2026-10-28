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
foreach ($model in @("27b", "uncensored", "vl", "qfn")) {
    $profile = Get-DeskModelDefaults $model
    $args = Get-DeskModelLaunchOptions $model $profile
    Assert ($args[1] -eq [string]$profile.Context) "Wrong context argument."
    Assert ($args[3] -eq $profile.CacheQuant) "Wrong cache argument."
    Assert (($args -contains "-NumDraftTokens") -eq $profile.Mtp) "Wrong MTP window argument."
    Assert (($args -contains "-Vision") -eq ($model -eq "27b")) "Vision belongs only on the 27B launcher."
}
$qfn = Get-DeskModelDefaults "qfn"
Assert ($qfn.CacheQuant -ceq "fp16" -and $qfn.Context -eq 16384 -and $qfn.CpuExperts -eq 432 -and $qfn.CpuCache -eq 0) "QFN quality/fit defaults changed."
foreach ($change in @(
    @{Context=71680}, @{CpuExperts=999}, @{CpuExperts="bad"}, @{CpuCache=1}, @{Budget=15}, @{Vision="false"}, @{Vision=$true}
)) {
    $profile = Get-DeskModelDefaults "qfn"
    foreach ($key in $change.Keys) { $profile[$key] = $change[$key] }
    Assert-Fails { Get-DeskModelLaunchOptions "qfn" $profile }
}
$qfn.Mtp = $true
$qfnArgs = Get-DeskModelLaunchOptions "qfn" $qfn
Assert ($qfnArgs[$qfnArgs.IndexOf("-NumDraftTokens") + 1] -ceq "3") "QFN draft window is not three tokens."
Assert ($qfnArgs[$qfnArgs.IndexOf("-CpuExperts") + 1] -ceq "432") "QFN expert split did not reach its launcher."
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
    $thinkingPath = Join-Path $fixture "thinking.txt"
    $defaultThinking = Read-DeskReasoningPreference $thinkingPath
    Assert ($defaultThinking.Enabled -and -not $defaultThinking.Effort -and $defaultThinking.Value -eq "on") "Missing preference changed default."
    foreach ($value in @("on", "off", "low", "medium", "xhigh")) {
        Write-DeskReasoningPreference $thinkingPath $value
        $preference = Read-DeskReasoningPreference $thinkingPath
        Assert ($preference.Value -ceq $value) "Reasoning preference did not round-trip."
        Assert ($preference.Enabled -eq ($value -ne "off")) "Reasoning enable state changed."
        Assert ([IO.File]::ReadAllBytes($thinkingPath)[0] -ne 239) "Reasoning file has a BOM."
    }
    foreach ($value in @("true", "1", "false", "0", " MEDIUM `r`n")) {
        [IO.File]::WriteAllText($thinkingPath, $value)
        $preference = Read-DeskReasoningPreference $thinkingPath
        Assert ($preference.Enabled -eq ($value -notin @("false", "0"))) "Legacy thinking preference changed."
    }
    foreach ($value in @("", "high", "max", "low`non", ("x" * 65))) {
        [IO.File]::WriteAllText($thinkingPath, $value)
        Assert-Fails { Read-DeskReasoningPreference $thinkingPath }
    }
    $before = [IO.File]::ReadAllText($thinkingPath)
    Assert-Fails { Write-DeskReasoningPreference $thinkingPath "invalid" }
    Assert ([IO.File]::ReadAllText($thinkingPath) -ceq $before) "Invalid save overwrote the preference."
    $path = Join-Path $fixture "profiles.json"
    Write-DeskModelProfiles $path @{ "27b" = (Get-DeskModelDefaults "27b"); "qfn" = (Get-DeskModelDefaults "qfn") }
    $state = Read-DeskModelProfiles $path
    Assert ($state["27b"].Context -eq 36864 -and $state["27b"].Mtp) "Saved settings did not round-trip."
    Assert ($state["qfn"].CpuExperts -eq 432 -and $state["qfn"].CacheQuant -ceq "fp16") "QFN profile did not round-trip."
    & {
        . (Join-Path $PSScriptRoot "Start-QwenFlashNext.ps1")
        $Repo = $fixture
        $statusSpec = [pscustomobject]@{RepoRoot=$fixture}
        $script:qfnFixtureLaunchers = @([pscustomobject]@{ProcessId=$PID})
        function Get-DeskQfnLaunchers { return $script:qfnFixtureLaunchers }
        function Stop-Cs2OwnedProcess {
            param($Process)
            Assert ($Process.ProcessId -eq $PID) "Stop targeted an unrecognized launcher."
            $script:qfnFixtureLaunchers = @()
        }
        Write-QfnLaunchStatus $statusSpec "checking" "fixture checks"
        Assert ((Read-DeskQfnLaunchStatus).state -ceq "checking") "An owned checking launcher lost its state."
        $script:qfnFixtureLaunchers = @()
        Assert ((Read-DeskQfnLaunchStatus).state -ceq "stopped") "An exited launcher was still reported as loading."
        Write-QfnLaunchStatus $statusSpec "failed" "fixture failure"
        Assert ((Read-DeskQfnLaunchStatus).message -ceq "fixture failure") "Desk hid its persisted failure."
        $script:qfnFixtureLaunchers = @([pscustomobject]@{ProcessId=$PID})
        Assert (Stop-DeskQfnLauncher) "Owned QFN launcher was not stopped."
        Assert ((Read-DeskQfnLaunchStatus).state -ceq "stopped") "Explicit Stop was reported as a launch failure."
        Assert (-not (Stop-DeskQfnLauncher)) "A missing QFN launcher was reported as stopped."
    }
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
    $launchers = @(
        (Join-Path $PSScriptRoot "Start-QwenVL.ps1"),
        (Join-Path $PSScriptRoot "Start-QwenFlashNext.ps1")
    )
    if ($InstalledLaunchers) {
        $launchers += @(
            "C:\nvme\Qwen3.8-27B-16gb\paper-godbrain\Start-Qwen.ps1",
            "C:\nvme\Qwen3.8-27B-16gb\paper-godbrain\Start-UncensoredQwen.ps1"
        )
    }
    foreach ($file in $launchers) {
        $model = if ($file -like "*FlashNext*") { "qfn" } elseif ($file -like "*VL*") { "vl" } elseif ($file -like "*Uncensored*") { "uncensored" } else { "27b" }
        Test-DeskModelLauncher $file (Get-DeskModelLaunchOptions $model (Get-DeskModelDefaults $model))
    }
    $reports = [Collections.Generic.List[string]]::new()
    $script:requests = @()
    function Invoke-RestMethod {
        param($Uri, $Method, $Body, $ContentType, $TimeoutSec)
        if ($Uri -like "*/health") { return @{ backend = "exl3"; busy = $script:busy; model = "fixture-model" } }
        if ($Uri -like "*/models") { return @{data=@(@{id="fixture-model";supported_reasoning_efforts=$script:efforts})} }
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
    $script:efforts = @("low", "medium", "xhigh")
    foreach ($effort in $script:efforts) {
        [void](Invoke-DeskReviewCompletion $messages "fixture-model" 512 0 123 $true $effort)
        Assert ($script:requests[-1].reasoning_effort -ceq $effort) "Review effort was not forwarded."
        Assert ($script:requests[-1].max_tokens -eq 512) "Effort changed the output limit."
    }
    $script:efforts = @()
    $count = $script:requests.Count
    Assert-Fails { Invoke-DeskReviewCompletion $messages "fixture-model" 512 0 123 $true "xhigh" }
    Assert ($script:requests.Count -eq $count) "Unsupported effort generated anyway."
    $script:efforts = "xhigh"
    Assert-Fails { Invoke-DeskReviewCompletion $messages "fixture-model" 512 0 123 $true "xhigh" }
    Assert ($script:requests.Count -eq $count) "Malformed capability list generated anyway."
    Assert-Fails { Assert-DeskReasoningCapability @{ data = @{ id = "fixture-model"; supported_reasoning_efforts = @("xhigh") } } "fixture-model" "xhigh" }
    [void](Invoke-DeskReviewCompletion $messages "fixture-model" 512 0 123 $false "xhigh")
    Assert (-not $script:requests[-1].reasoning_effort -and -not $script:requests[-1].chat_template_kwargs.enable_thinking) "Thinking-off request retained effort."

    $Repo = $fixture
    $Kit = $fixture
    $script:sourceReads = 0
    $script:sourceChanges = $false
    $script:plannerRequests = @()
    $script:reviewRequests = @()
    $script:failPart = 0
    $script:reviewModel = "qwen3.8-27b-exl3-3.5bpw"
    function Read-DeskGrantedBytes {
        param($Path, $Maximum, $Purpose)
        $script:sourceReads++
        $value = if ($script:sourceChanges -and $script:sourceReads -gt 1) { "changed" } else { "fixture source" }
        return ,[Text.Encoding]::UTF8.GetBytes($value)
    }
    function Invoke-RestMethod {
        param($Uri, $Method, $Body, $ContentType, $TimeoutSec)
        $model = $script:reviewModel
        if ($Uri -like "*/health") { return @{ backend = "exl3"; busy = $false; model = $model; context_length = 8192 } }
        if ($Uri -like "*/models") { return @{ data = @(@{ id = $model; supported_reasoning_efforts = @("low", "medium", "xhigh") }) } }
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
    & {
        function Get-GodBrainSharedContext { param($Query, $ThreadId); return @{ context = "SHARED_REVIEW_FIXTURE"; index_id = "fixture-index" } }
        function Save-GodBrainWorkingTurn {
            param($Prompt, $Response, $ThreadId, $Sources)
            Assert ($Prompt -ceq "Research review" -and $ThreadId -ceq "desk") "Review handoff changed the original request."
            Assert ($Sources[0] -like "*sha256=*") "Review handoff lost source binding."
            return @{ record = @{ _id = "fixture-record" } }
        }
        $script:plannerRequests = @(); $script:reviewRequests = @()
        [void](Invoke-DeskCodeReview "fixture.cpp" "Research review" "research")
        Assert ($script:plannerRequests[0].task -like "*SHARED_REVIEW_FIXTURE*Operator request:*Research review") "Review memory was not supplied before token planning."
        $sharedReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        Assert ($sharedReceipt.shared_saved -and $sharedReceipt.task -ceq "Research review") "Review handoff was not confirmed."
    }
    $script:reviewModel = "qwen3.8-flash-next-exl3-3.05bpw"
    [void](Invoke-DeskCodeReview "fixture.cpp" "QFN review")
    Assert ($script:plannerRequests[-1].tokenizer -like "*Qwen3.8-Flash-Next-EXL3-3.05bpw\tokenizer.json") "QFN used another checkpoint's tokenizer."
    $script:reviewModel = "qwen3.8-27b-exl3-3.5bpw"

    Write-DeskReasoningPreference (Join-Path $fixture "logs\thinking.txt") "xhigh"
    $script:sourceReads = 0; $script:plannerRequests = @(); $script:reviewRequests = @()
    [void](Invoke-DeskCodeReview "fixture.cpp" "check high effort")
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    Assert ($receipt.reasoning_effort -ceq "xhigh") "Receipt lost effort."
    foreach ($request in $script:plannerRequests) {
        Assert ($request.reasoning_effort -ceq "xhigh" -and $request.thinking) "CPU planner lost effort."
    }
    foreach ($request in $script:reviewRequests) {
        Assert ($request.reasoning_effort -ceq "xhigh" -and $request.chat_template_kwargs.enable_thinking) "Part or synthesis lost effort."
    }

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
