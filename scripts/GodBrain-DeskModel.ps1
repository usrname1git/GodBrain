function Get-DeskModelDefaults([string]$Model) {
    switch ($Model) {
        "27b" { return @{ Context = 36864; CacheQuant = "4"; Mtp = $true; Budget = 13.5; CpuCache = 0; Vision = $false } }
        "uncensored" { return @{ Context = 10240; CacheQuant = "fp16"; Mtp = $false; Budget = 13.5; CpuCache = 0 } }
        "vl" { return @{ Context = 57344; CacheQuant = "fp16"; Mtp = $false; Budget = 14.5; CpuCache = 4 } }
        default { throw "No token context controls for $Model." }
    }
}

function Get-DeskModelLaunchOptions([string]$Model, $Profile) {
    if ($Model -notin @("27b", "uncensored", "vl")) { throw "Unsupported text model." }
    $context = 0
    if (-not [int]::TryParse([string]$Profile.Context, [ref]$context) -or
        $context -lt 256 -or $context -gt 262144 -or $context % 256) {
        throw "Context must be 256..262144 tokens in multiples of 256."
    }
    if ($Profile.CacheQuant -notin @("fp16", "4", "8", "8,4")) { throw "Invalid KV cache quant." }
    if ($Profile.Mtp -isnot [bool]) { throw "MTP must be true or false." }
    $budget = 0.0
    $parsed = [double]::TryParse([string]$Profile.Budget, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$budget)
    if (-not $parsed) {
        $parsed = [double]::TryParse([string]$Profile.Budget, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::CurrentCulture, [ref]$budget)
    }
    if (-not $parsed -or
        $budget -lt 1 -or $budget -gt 64 -or [double]::IsNaN($budget) -or
        [double]::IsInfinity($budget)) { throw "Invalid GPU budget." }
    if ($Model -eq "vl" -and $Profile.Mtp) { throw "This VL checkpoint has no supported MTP head." }
    $cpuCache = 0.0
    if ($Profile.ContainsKey("CpuCache")) {
        if (-not [double]::TryParse([string]$Profile.CpuCache, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$cpuCache) -or
            $cpuCache -lt 0 -or $cpuCache -gt 64 -or [double]::IsNaN($cpuCache) -or [double]::IsInfinity($cpuCache)) {
            throw "RAM prefix cache must be 0..64 GiB."
        }
    }
    $args = @("-CacheSize", [string]$context, "-CacheQuant", [string]$Profile.CacheQuant)
    $args += @("-CpuCacheSizeGB", $cpuCache.ToString([Globalization.CultureInfo]::InvariantCulture))
    if ($Model -ne "vl") {
        $args += @("-DraftMode", $(if ($Profile.Mtp) { "Mtp" } else { "None" }), "-GpuMemoryGB",
            $budget.ToString([Globalization.CultureInfo]::InvariantCulture))
        if ($Profile.Mtp) { $args += @("-NumDraftTokens", "4") }
    }
    if ($Model -eq "27b") {
        $vision = $false
        if ($Profile.ContainsKey("Vision")) {
            if ($Profile.Vision -isnot [bool]) { throw "Vision must be true or false." }
            $vision = $Profile.Vision
        }
        $args += @("-Vision", $(if ($vision) { "auto" } else { "off" }))
    }
    return ,$args
}

function Read-DeskModelProfiles([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($state.version -ne 1 -or $state.profiles -isnot [System.Collections.IDictionary]) {
        throw "Invalid saved model settings: $Path"
    }
    foreach ($model in $state.profiles.Keys) {
        [void](Get-DeskModelLaunchOptions $model $state.profiles[$model])
    }
    return $state.profiles
}

function Write-DeskModelProfiles([string]$Path, [hashtable]$Profiles) {
    foreach ($model in $Profiles.Keys) { [void](Get-DeskModelLaunchOptions $model $Profiles[$model]) }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temporary = $Path + "." + [guid]::NewGuid().ToString("N") + ".tmp"
    try {
        [IO.File]::WriteAllText($temporary, (@{ version = 1; profiles = $Profiles } | ConvertTo-Json -Depth 5))
        [IO.File]::Move($temporary, $Path, $true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Test-DeskModelLauncher([string]$File, [string[]]$Options) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Model launcher cannot be parsed: $File" }
    $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    for ($i = 0; $i -lt $Options.Count; $i += 2) {
        if ($Options[$i].TrimStart("-") -notin $names) {
            throw "Update the local Qwen launcher: it does not support $($Options[$i]). The running model was left untouched."
        }
    }
}

function Set-DeskReviewPlannerEncoding([Diagnostics.ProcessStartInfo]$Info) {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $Info.StandardInputEncoding = $utf8
    $Info.StandardOutputEncoding = $utf8
    $Info.StandardErrorEncoding = $utf8
}

function Invoke-DeskReviewPlanner($Request) {
    $python = Join-Path $Kit ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $python)) { throw "Local Qwen tokenizer environment is missing." }
    $info = [Diagnostics.ProcessStartInfo]::new($python)
    $info.ArgumentList.Add((Join-Path $PSScriptRoot "desk_review_plan.py"))
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
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write(($Request | ConvertTo-Json -Depth 8 -Compress))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "CPU-only review planning timed out."
        }
        if ($process.ExitCode) { throw "Review planning failed: $($stderr.GetAwaiter().GetResult())" }
        return ($stdout.GetAwaiter().GetResult() | ConvertFrom-Json)
    } finally { $process.Dispose() }
}

function Invoke-DeskReviewCompletion($Messages, [string]$Model, [int]$Output, [int]$Context = 0,
    [int]$PlannedPrompt = 0, [bool]$Thinking = $true) {
    $health = Invoke-RestMethod "http://127.0.0.1:8888/health" -TimeoutSec 3
    if ($health.backend -ne "exl3" -or $health.busy) { throw "EXL3 is unavailable or busy. Review was not queued." }
    if ($health.model -cne $Model -or ($Context -and $health.context_length -ne $Context)) {
        throw "The model/context changed during review. No complete verdict was recorded."
    }
    $body = @{ model = $Model; messages = @($Messages); max_tokens = $Output; stream = $false
        temperature = 0.1; chat_template_kwargs = @{ enable_thinking = $Thinking }; tool_choice = "none" }
    $response = Invoke-RestMethod "http://127.0.0.1:8888/v1/chat/completions" -Method Post `
        -Body ($body | ConvertTo-Json -Depth 10 -Compress) -ContentType "application/json; charset=utf-8" -TimeoutSec 600
    if ($response.error) { throw "Review failed: $($response.error | ConvertTo-Json -Compress)" }
    $choice = $response.choices[0]
    if ($choice.finish_reason -ne "stop") {
        throw "Review was incomplete (finish_reason='$($choice.finish_reason)', output limit $Output tokens including reasoning). Narrow the task or disable thinking explicitly; no complete verdict was recorded."
    }
    if ([string]::IsNullOrWhiteSpace($choice.message.content) -or $choice.message.tool_calls) {
        throw "Review returned no spoken report or attempted tools; no complete verdict was recorded."
    }
    if (-not $response.usage.prompt_tokens) { throw "Review returned no prompt-token receipt." }
    if ($PlannedPrompt -and ($response.usage.prompt_tokens -lt $PlannedPrompt -or
        $response.usage.prompt_tokens -gt $PlannedPrompt + 1024)) {
        throw "Actual prompt usage disagrees with the local tokenizer budget. No complete verdict was recorded."
    }
    return $response
}

function Get-DeskReviewMutexName {
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Repo.ToLowerInvariant()))
    return "Global\GodBrainDeskReview-" + [Convert]::ToHexString($hash).Substring(0, 16)
}

function Test-DeskReviewBusy {
    $mutex = [Threading.Mutex]::new($false, (Get-DeskReviewMutexName))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        return -not $owned
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-DeskCodeReview([string]$Path, [string]$Task) {
    $mutex = [Threading.Mutex]::new($false, (Get-DeskReviewMutexName))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw "Another complete-file review is running. Review was not queued." }
        return (Invoke-DeskCodeReviewCore $Path $Task)
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-DeskCodeReviewCore([string]$Path, [string]$Task) {
    if (-not $Path) { throw "Review complete file requires a granted file path." }
    $bytes = Read-DeskGrantedBytes $Path 1MB "Review"
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xfeff)
    $health = Invoke-RestMethod "http://127.0.0.1:8888/health" -TimeoutSec 3
    if ($health.backend -ne "exl3" -or $health.busy) { throw "Review requires an idle EXL3 model." }
    $models = Invoke-RestMethod "http://127.0.0.1:8888/v1/models" -TimeoutSec 3
    $model = [string]$models.data[0].id
    if ($model -cne $health.model) { throw "Model identity changed while planning review." }
    $tokenizer = switch -Regex ($model) {
        '^qwen3\.8-27b-uncensored' { Join-Path (Split-Path $Kit -Parent) "Qwen3.8-27B-Uncensored-exl3-3.07bpw\tokenizer.json"; break }
        '^qwen3\.8-27b-exl3-3\.5bpw$' { Join-Path $Kit "models\Qwen3.8-27B-EXL3-3.5bpw\tokenizer.json"; break }
        '^qwen3-vl-8b-exl3$' { Join-Path (Split-Path $Kit -Parent) "qwen3-vl-8b-exl3\tokenizer.json"; break }
        default { throw "No trusted local tokenizer mapping for the running model '$model'." }
    }
    $output = [Math]::Min(8192, [int]$health.context_length / 4)
    $thinkingPath = Join-Path $Repo "logs\thinking.txt"
    $thinking = if (Test-Path -LiteralPath $thinkingPath) {
        (Get-Content -LiteralPath $thinkingPath -Raw).Trim().ToLowerInvariant() -notin @("off", "false", "0")
    } else { $true }
    $request = @{ op = "plan"; tokenizer = $tokenizer; name = $Path; task = $Task; text = $text
        context = [int]$health.context_length; output = [int]$output; thinking = $thinking }
    $plan = Invoke-DeskReviewPlanner $request
    $receiptPath = Join-Path $Repo "logs\last-code-review.json"
    [void][IO.Directory]::CreateDirectory((Split-Path $receiptPath -Parent))
    $receipt = @{ version = 1; status = "running"; trust_tier = "candidate"; path = $Path
        source_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        model = $model; context = $plan.context; thinking_enabled = $thinking
        parts = @(); lines = $plan.lines; at = [datetime]::UtcNow.ToString("o") }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding utf8
    try {
        $reports = [Collections.Generic.List[string]]::new()
        # Keep the final synthesis bounded, including the worst-case size of each report.
        $partOutput = if (@($plan.chunks).Count -gt 1) {
            [Math]::Min($output, [int](($plan.context - 4096 - $output) / (@($plan.chunks).Count * 2)))
        } else { $output }
        if ($partOutput -lt 256) { throw "Context is too small for a reliable synthesis; increase context." }
        foreach ($chunk in $plan.chunks) {
            $response = Invoke-DeskReviewCompletion $chunk.messages $model $partOutput $plan.context $chunk.prompt_tokens $thinking
            $reports.Add("Lines $($chunk.start)-$($chunk.end):`n$($response.choices[0].message.content)")
            $receipt.parts += @{ start = $chunk.start; end = $chunk.end; split = $chunk.split
                prompt_tokens = $response.usage.prompt_tokens; completion_tokens = $response.usage.completion_tokens }
            $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding utf8
        }
        $answer = [string]$reports[0]
        if ($reports.Count -gt 1) {
            $request.op = "synthesis"
            $request.Remove("text")
            $request.reports = @($reports.ToArray())
            $request.shared = $plan.shared
            $synthesis = Invoke-DeskReviewPlanner $request
            $final = Invoke-DeskReviewCompletion $synthesis.messages $model $output $plan.context $synthesis.prompt_tokens $thinking
            $answer = [string]$final.choices[0].message.content
            $receipt.synthesis_prompt_tokens = $final.usage.prompt_tokens
        }
        $current = Read-DeskGrantedBytes $Path 1MB "Review"
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($current))) {
            throw "Source changed during review; the report does not cover the current file."
        }
        $receipt.status = "done"
        $receipt.task = $Task
        $receipt.report = $answer
        $receipt.part_reports = @($reports.ToArray())
        $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding utf8
        return "Candidate review; $($plan.lines) lines covered in $($reports.Count) part(s). No edits applied.`r`n`r`n$answer"
    } catch {
        $receipt.status = "failed"
        $receipt.error = $_.Exception.Message
        $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding utf8
        throw
    }
}
