. (Join-Path $PSScriptRoot "GodBrain-SharedMemory.ps1")

function Read-DeskReasoningPreference([string]$Path) {
    $value = if (Test-Path -LiteralPath $Path) {
        if ((Get-Item -LiteralPath $Path).Length -gt 64) { throw "Reasoning preference exceeds 64 bytes: $Path" }
        [IO.File]::ReadAllText($Path).Trim().ToLowerInvariant()
    } else { "on" }
    switch ($value) {
        { $_ -in @("on", "true", "1") } { return @{ Enabled = $true; Effort = ""; Value = "on" } }
        { $_ -in @("off", "false", "0") } { return @{ Enabled = $false; Effort = ""; Value = "off" } }
        { $_ -in @("low", "medium", "xhigh") } { return @{ Enabled = $true; Effort = $value; Value = $value } }
        default { throw "Invalid reasoning preference: $Path. Select Default, Off, Low, Medium or High." }
    }
}

function Write-DeskReasoningPreference([string]$Path, [string]$Value) {
    if ($Value -notin @("on", "off", "low", "medium", "xhigh")) { throw "Unsupported reasoning preference." }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temporary = $Path + "." + [guid]::NewGuid().ToString("N") + ".tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Value + "`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Assert-DeskReasoningCapability($Models, [string]$Model, [string]$Effort) {
    if (-not $Effort) { return }
    $match = @($Models.data | Where-Object { $_.id -ceq $Model })
    if ($Models.data -isnot [array] -or $match.Count -ne 1 -or
        $match[0].supported_reasoning_efforts -isnot [array] -or
        $Effort -cnotin $match[0].supported_reasoning_efforts) {
        throw "The running model does not advertise reasoning effort $Effort. Select Default or Off; no generation was sent."
    }
}

function Get-DeskModelDefaults([string]$Model) {
    switch ($Model) {
        "27b" { return @{ Context = 36864; CacheQuant = "4"; Mtp = $true; Budget = 13.5; CpuCache = 0; Vision = $false } }
        "uncensored" { return @{ Context = 10240; CacheQuant = "fp16"; Mtp = $false; Budget = 13.5; CpuCache = 0 } }
        "vl" { return @{ Context = 57344; CacheQuant = "fp16"; Mtp = $false; Budget = 14.5; CpuCache = 4 } }
        "qfn" { return @{ Context = 16384; CacheQuant = "fp16"; Mtp = $false; Budget = 13.5; CpuCache = 0; CpuExperts = 432 } }
        default { throw "No token context controls for $Model." }
    }
}

function Get-DeskModelLaunchOptions([string]$Model, $Profile) {
    if ($Model -notin @("27b", "uncensored", "vl", "qfn")) { throw "Unsupported text model." }
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
        $experts = 0
        if ($Model -eq "qfn") {
            if ($context -gt 65536) { throw "Flash Next context is limited to 65536 until larger contexts are measured." }
            if ($budget -gt 14.7 -or $cpuCache -ne 0) { throw "Flash Next requires GPU budget <=14.7 GiB and RAM prefix cache 0." }
            if (-not [int]::TryParse([string]$Profile.CpuExperts, [ref]$experts) -or
                $experts -notin @(400, 416, 432, 448, 464)) {
                throw "Flash Next CPU experts must be 400, 416, 432, 448 or 464."
            }
            if ($Profile.ContainsKey("Vision") -and ($Profile.Vision -isnot [bool] -or $Profile.Vision)) {
                throw "Flash Next's hardware-fit profile is text-only."
            }
        }
    }
    $args = @("-CacheSize", [string]$context, "-CacheQuant", [string]$Profile.CacheQuant)
    $args += @("-CpuCacheSizeGB", $cpuCache.ToString([Globalization.CultureInfo]::InvariantCulture))
    if ($Model -ne "vl") {
        $args += @("-DraftMode", $(if ($Profile.Mtp) { "Mtp" } else { "None" }), "-GpuMemoryGB",
            $budget.ToString([Globalization.CultureInfo]::InvariantCulture))
        if ($Profile.Mtp) { $args += @("-NumDraftTokens", $(if ($Model -eq "qfn") { "3" } else { "4" })) }
    }
    if ($Model -eq "27b") {
        $vision = $false
        if ($Profile.ContainsKey("Vision")) {
            if ($Profile.Vision -isnot [bool]) { throw "Vision must be true or false." }
            $vision = $Profile.Vision
        }
        $args += @("-Vision", $(if ($vision) { "auto" } else { "off" }))
    }
    if ($Model -eq "qfn") { $args += @("-CpuExperts", [string]$experts) }
    return ,$args
}

function Test-DeskQfnPrerequisites($Profile) {
    $options = Get-DeskModelLaunchOptions "qfn" $Profile
    . (Join-Path $PSScriptRoot "Start-QwenFlashNext.ps1")
    $spec = New-QfnLaunchSpec -KitRoot $Kit -ModelRoot (Join-Path (Split-Path $Kit -Parent) "Qwen3.8-Flash-Next-EXL3-3.05bpw") `
        -RepoRoot $Repo -CpuExperts $Profile.CpuExperts -CacheSize $Profile.Context -CacheQuant $Profile.CacheQuant `
        -GpuMemoryGB ([double]$options[$options.IndexOf("-GpuMemoryGB") + 1]) -DraftMode $(if ($Profile.Mtp) { "Mtp" } else { "None" })
    [void](Test-QfnPrerequisites $spec)
    $hardware = Get-QfnHardware $Repo $spec.Info.ArgumentList[1]
    if ($hardware.AvailableRamGiB -isnot [double] -or -not [double]::IsFinite($hardware.AvailableRamGiB)) {
        throw "Available RAM probe is invalid; the current model was not stopped."
    }
    if ($hardware.AvailableRamGiB -lt $spec.RequiredRamGiB) {
        throw ("Flash Next needs {0} GiB available RAM for this split; currently {1:F2} GiB. Close other applications and retry. No model was stopped." -f
            $spec.RequiredRamGiB, $hardware.AvailableRamGiB)
    }
}

function Get-DeskQfnLaunchers {
    $path = Join-Path $Repo "scripts\Start-QwenFlashNext.ps1"
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction Stop |
        Where-Object { Test-Cs2ScriptProcess $_ $path -PowerShell })
}

function Stop-DeskQfnLauncher {
    $launchers = @(Get-DeskQfnLaunchers)
    foreach ($launcher in $launchers) { Stop-Cs2OwnedProcess $launcher }
    if ($launchers.Count) {
        . (Join-Path $PSScriptRoot "Start-QwenFlashNext.ps1")
        Write-QfnLaunchStatus ([pscustomobject]@{ RepoRoot = $Repo }) "stopped" "QFN stopped by Desk; its Job releases server and CPU workers."
        return $true
    }
    return $false
}

function Read-DeskQfnLaunchStatus {
    $path = Join-Path $Repo "logs\qfn-last-launch.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $path).Length -gt 65536) { throw "QFN launch receipt exceeds its size limit." }
    $status = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($status.version -ne 1 -or $status.state -notin @("checking", "loading", "failed", "stopped") -or
        $status.message -isnot [string] -or $status.message.Length -gt 8192) { throw "Invalid QFN launch receipt." }
    if ($status.state -in @("checking", "loading") -and
        -not (@(Get-DeskQfnLaunchers) | Where-Object ProcessId -eq $status.launcher_pid)) {
        $status.state = "stopped"
        $status.message = "QFN launcher exited; no live readiness is claimed."
    }
    return $status
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
    [int]$PlannedPrompt = 0, [bool]$Thinking = $true, [string]$Effort = "", [hashtable]$Diagnostics = $null) {
    $health = Invoke-RestMethod "http://127.0.0.1:8888/health" -TimeoutSec 3
    if ($health.backend -ne "exl3" -or $health.busy) { throw "EXL3 is unavailable or busy. Review was not queued." }
    if ($health.model -cne $Model -or ($Context -and $health.context_length -ne $Context)) {
        throw "The model/context changed during review. No complete verdict was recorded."
    }
    $body = @{ model = $Model; messages = @($Messages); max_tokens = $Output; stream = $false
        temperature = 0.1; chat_template_kwargs = @{ enable_thinking = $Thinking }; tool_choice = "none" }
    if ($Thinking -and $Effort) {
        $models = Invoke-RestMethod "http://127.0.0.1:8888/v1/models" -TimeoutSec 3
        Assert-DeskReasoningCapability $models $Model $Effort
        $body.reasoning_effort = $Effort
    }
    $response = Invoke-RestMethod "http://127.0.0.1:8888/v1/chat/completions" -Method Post `
        -Body ($body | ConvertTo-Json -Depth 10 -Compress) -ContentType "application/json; charset=utf-8" -TimeoutSec 600
    if ($response.error) { throw "Review failed: $($response.error | ConvertTo-Json -Compress)" }
    $choice = $response.choices[0]
    if ($null -ne $Diagnostics) {
        $Diagnostics.finish_reason = $choice.finish_reason
        $Diagnostics.prompt_tokens = $response.usage.prompt_tokens
        $Diagnostics.completion_tokens = $response.usage.completion_tokens
        $Diagnostics.visible_bytes = [Text.Encoding]::UTF8.GetByteCount([string]$choice.message.content)
        $Diagnostics.reasoning_bytes = [Text.Encoding]::UTF8.GetByteCount([string]$choice.message.reasoning_content)
    }
    if (-not $response.usage.prompt_tokens) { throw "Review returned no prompt-token receipt." }
    if ($PlannedPrompt -and ($response.usage.prompt_tokens -lt $PlannedPrompt -or
        $response.usage.prompt_tokens -gt $PlannedPrompt + 1024)) {
        throw "Actual prompt usage disagrees with the local tokenizer budget. No complete verdict was recorded."
    }
    if ($choice.finish_reason -ne "stop") {
        $failure = [InvalidOperationException]::new(
            "Review was incomplete (finish_reason='$($choice.finish_reason)', output limit $Output tokens including reasoning). No complete verdict was recorded.")
        if ($choice.finish_reason -ceq "length" -and -not $choice.message.tool_calls) {
            $failure.Data["DeskAnswerRecovery"] = "output_limit"
        }
        throw $failure
    }
    if ([string]::IsNullOrWhiteSpace($choice.message.content) -or $choice.message.tool_calls) {
        $failure = [InvalidOperationException]::new("Review returned no spoken report or attempted tools; no complete verdict was recorded.")
        if (-not $choice.message.tool_calls) { $failure.Data["DeskAnswerRecovery"] = "empty_completion" }
        throw $failure
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

function Invoke-DeskCodeReview([string]$Path, [string]$Task, [string]$Mode = "answer") {
    $mutex = [Threading.Mutex]::new($false, (Get-DeskReviewMutexName))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw "Another complete-file review is running. Review was not queued." }
        return (Invoke-DeskCodeReviewCore $Path $Task $Mode)
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-DeskReviewRuntime {
    $health = Invoke-RestMethod "http://127.0.0.1:8888/health" -TimeoutSec 3
    if ($health.backend -ne "exl3" -or $health.busy) { throw "Review requires an idle EXL3 model." }
    $models = Invoke-RestMethod "http://127.0.0.1:8888/v1/models" -TimeoutSec 3
    $model = [string]$models.data[0].id
    if ($model -cne $health.model) { throw "Model identity changed while planning review." }
    $tokenizer = switch -Regex ($model) {
        '^qwen3\.8-27b-uncensored' { Join-Path (Split-Path $Kit -Parent) "Qwen3.8-27B-Uncensored-exl3-3.07bpw\tokenizer.json"; break }
        '^qwen3\.8-27b-exl3-3\.5bpw$' { Join-Path $Kit "models\Qwen3.8-27B-EXL3-3.5bpw\tokenizer.json"; break }
        '^qwen3-vl-8b-exl3$' { Join-Path (Split-Path $Kit -Parent) "qwen3-vl-8b-exl3\tokenizer.json"; break }
        '^qwen3\.8-flash-next-exl3-3\.05bpw$' { Join-Path (Split-Path $Kit -Parent) "Qwen3.8-Flash-Next-EXL3-3.05bpw\tokenizer.json"; break }
        default { throw "No trusted local tokenizer mapping for the running model '$model'." }
    }
    $output = [Math]::Min(16384, ([int]$health.context_length - 4096) / 2)
    $preference = Read-DeskReasoningPreference (Join-Path $Repo "logs\thinking.txt")
    $thinking = [bool]$preference.Enabled
    $effort = [string]$preference.Effort
    Assert-DeskReasoningCapability $models $model $effort
    return @{ Model = $model; Tokenizer = $tokenizer; Context = [int]$health.context_length
        Output = [int]$output; Thinking = $thinking; Effort = $effort }
}

function Invoke-DeskCodeReviewCore([string]$Path, [string]$Task,
    [ValidateSet("answer", "research", "fix")][string]$Mode = "answer") {
    if (-not $Path) { throw "Review complete file requires a granted file path." }
    $bytes = Read-DeskGrantedBytes $Path 1MB "Review"
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xfeff)
    $operatorTask = $Task
    $memory = $null
    if ($Mode -ne "answer" -and $Task -notmatch '^\s*(?i)no tools\b') {
        $memory = Get-GodBrainSharedContext -Query $Task -ThreadId "desk"
        $Task = Add-GodBrainSharedContext $Task $memory
    }
    $runtime = Get-DeskReviewRuntime
    $model = $runtime.Model; $tokenizer = $runtime.Tokenizer; $output = $runtime.Output
    $thinking = $runtime.Thinking; $effort = $runtime.Effort
    $request = @{ op = "plan"; tokenizer = $tokenizer; name = $Path; task = $Task; text = $text
        context = $runtime.Context; output = [int]$output; thinking = $thinking; reasoning_effort = $effort }
    $plan = Invoke-DeskReviewPlanner $request
    $receiptPath = Join-Path $Repo "logs\last-code-review.json"
    [void][IO.Directory]::CreateDirectory((Split-Path $receiptPath -Parent))
    $receipt = @{ version = 1; status = "running"; trust_tier = "candidate"; path = $Path
        source_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        model = $model; context = $plan.context; thinking_enabled = $thinking; reasoning_effort = $effort
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
            $response = Invoke-DeskReviewCompletion $chunk.messages $model $partOutput $plan.context $chunk.prompt_tokens $thinking $effort
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
            $final = Invoke-DeskReviewCompletion $synthesis.messages $model $output $plan.context $synthesis.prompt_tokens $thinking $effort
            $answer = [string]$final.choices[0].message.content
            $receipt.synthesis_prompt_tokens = $final.usage.prompt_tokens
        }
        $current = Read-DeskGrantedBytes $Path 1MB "Review"
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($current))) {
            throw "Source changed during review; the report does not cover the current file."
        }
        $receipt.status = "done"
        $receipt.task = $operatorTask
        $receipt.report = $answer
        $receipt.part_reports = @($reports.ToArray())
        if ($null -ne $memory) {
            $receipt.shared_saved = $false
            $saved = Save-GodBrainWorkingTurn -Prompt $operatorTask -Response $answer -ThreadId "desk" `
                -Sources @("$Path [sha256=$($receipt.source_sha256)]")
            $receipt.shared_saved = $true
            $receipt.shared_record_id = $saved.record._id
            $receipt.context_index_id = $memory.index_id
        }
        $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding utf8
        return "Candidate review; $($plan.lines) lines covered in $($reports.Count) part(s). No edits applied.`r`n`r`n$answer"
    } catch {
        $receipt.status = "failed"
        $receipt.error = $_.Exception.Message
        $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding utf8
        throw
    }
}

function ConvertFrom-DeskAttachmentBytes([byte[]]$Bytes) {
    $offset = 0
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $name = "utf-8"
    if ($Bytes.Length -ge 4 -and (
        ($Bytes[0] -eq 255 -and $Bytes[1] -eq 254 -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) -or
        ($Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 254 -and $Bytes[3] -eq 255))) {
        throw "UTF-32 attachments are not supported. Save the text as UTF-8 or UTF-16."
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true); $offset = 2; $name = "utf-16le"
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true); $offset = 2; $name = "utf-16be"
    } elseif ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        $offset = 3
    }
    $text = $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset)
    if ([string]::IsNullOrWhiteSpace($text) -or $text -match '[\x00-\x08\x0b\x0c\x0e-\x1f]') {
        throw "Attachment is empty, binary or has an unsupported encoding. Use UTF-8 or UTF-16 with a BOM."
    }
    return @{ Text = $text; Encoding = $name }
}

function Invoke-DeskCpuOcr([byte[]]$Bytes) {
    $python = (Get-Command python, python.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $python) { throw "CPU OCR requires the existing Python/EasyOCR environment." }
    $info = [Diagnostics.ProcessStartInfo]::new($python)
    $info.ArgumentList.Add("-X")
    $info.ArgumentList.Add("faulthandler")
    $info.ArgumentList.Add((Join-Path $PSScriptRoot "voice_door.py"))
    $info.ArgumentList.Add("--ocr-stdin")
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    Set-DeskReviewPlannerEncoding $info
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.BaseStream.Write($Bytes, 0, $Bytes.Length)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(180000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "CPU OCR timed out; no model was started."
        }
        if ($process.ExitCode) { throw "CPU OCR failed (exit $($process.ExitCode)): $($stderr.GetAwaiter().GetResult())" }
        $result = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
        if ($result.version -ne 1 -or $result.engine -cne "cpu" -or
            $result.source_sha256 -cne $hash -or [string]::IsNullOrWhiteSpace($result.text)) {
            throw "CPU OCR returned an invalid or empty source receipt."
        }
        return [string]$result.text
    } finally {
        try {
            if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        } finally { $process.Dispose() }
    }
}

function Write-DeskAttachmentReceipt($Receipt) {
    $path = Join-Path $Repo "logs\last-attachment-analysis.json"
    [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
    $temporary = $path + "." + [guid]::NewGuid().ToString("N") + ".tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Receipt | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $path, $true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Invoke-DeskAttachmentCompletion($Messages, $Runtime, [int]$Output, [int]$PlannedPrompt,
    [hashtable]$Receipt, [string]$Stage = "part") {
    for ($index = 0; $index -lt 2; $index++) {
        $thinking = $Runtime.Thinking
        $effort = $Runtime.Effort
        $messagesToSend = @($Messages)
        $outputToSend = $Output
        if ($Receipt.answer_retry) {
            $thinking = $false; $effort = ""
            $outputToSend = [Math]::Min($Output, 4096)
            $messagesToSend += @{ role = "user"; content =
                "An earlier attempt in this analysis was discarded. Give a concise final answer from the supplied evidence. " +
                "Distinguish observations from hypotheses and missing evidence. If a requested mapping or method is not established, say so. " +
                "Do not call tools, repeat reads or claim verification." }
            $plan = Invoke-DeskReviewPlanner @{ op = "completion"; messages = $messagesToSend
                tokenizer = $Runtime.Tokenizer; context = $Runtime.Context; output = $outputToSend; thinking = $false }
            $PlannedPrompt = $plan.prompt_tokens
        }
        $attempt = @{ stage = $Stage; status = "running"; thinking_enabled = $thinking
            reasoning_effort = $effort; answer_retry = [bool]$Receipt.answer_retry
            requested_max_tokens = $outputToSend; planned_prompt_tokens = $PlannedPrompt }
        $Receipt.completion_attempts += $attempt
        Write-DeskAttachmentReceipt $Receipt
        try {
            $response = Invoke-DeskReviewCompletion $messagesToSend $Runtime.Model $outputToSend `
                $Runtime.Context $PlannedPrompt $thinking $effort $attempt
            $attempt.status = "done"
            return $response
        } catch {
            $attempt.status = "failed"; $attempt.error = $_.Exception.GetBaseException().Message
            $reason = $_.Exception.GetBaseException().Data["DeskAnswerRecovery"]
            if (-not $reason -or $Receipt.answer_retry) { throw }
            $Receipt.answer_retry = $true
            $Receipt.answer_retry_reason = [string]$reason
        } finally { Write-DeskAttachmentReceipt $Receipt }
    }
    throw "Attachment answer recovery did not produce a complete answer."
}

function Invoke-DeskAttachmentAnalysis([string[]]$Paths, [string]$Task,
    [ValidateSet("answer", "research")][string]$Mode = "answer") {
    $mutex = [Threading.Mutex]::new($false, (Get-DeskReviewMutexName))
    $owned = $false
    $receipt = @{ version = 1; status = "running"; trust_tier = "candidate"; task = $Task
        at = [datetime]::UtcNow.ToString("o"); sources = @(); parts = @(); paths = @($Paths)
        answer_retry = $false; completion_attempts = @() }
    try {
        try { $owned = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw "Another file analysis/review is running. Nothing was queued." }
        Write-DeskAttachmentReceipt $receipt
        try {
            $memory = $null
            if ($Mode -ne "answer" -and $Task -notmatch '^\s*(?i)no tools\b') {
                $memory = Get-GodBrainSharedContext -Query $Task -ThreadId "desk"
                $Task = Add-GodBrainSharedContext $Task $memory
            }
            $runtime = Get-DeskReviewRuntime
            $sources = @()
            foreach ($path in $Paths) {
                $image = Test-DeskVisionImage $path
                $maximum = if ($image) { 10MB } else { 1MB }
                $bytes = Read-DeskGrantedBytes $path $maximum "Attachment"
                $decoded = if ($image) { @{ Text = (Invoke-DeskCpuOcr $bytes); Encoding = "cpu-ocr" } }
                    else { ConvertFrom-DeskAttachmentBytes $bytes }
                if ([Text.Encoding]::UTF8.GetByteCount($decoded.Text) -gt 1MB) { throw "Extracted attachment text exceeds 1 MiB." }
                $sources += @{ name = $path; text = $decoded.Text; encoding = $decoded.Encoding
                    kind = $(if ($image) { "cpu-ocr" } else { "text" })
                    sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
            }
            $request = @{ op = "attachments"; sources = $sources; task = $Task; tokenizer = $runtime.Tokenizer
                context = $runtime.Context; output = $runtime.Output; thinking = $runtime.Thinking
                reasoning_effort = $runtime.Effort }
            $plan = Invoke-DeskReviewPlanner $request
            $receipt.sources = @($plan.documents)
            $receipt.model = $runtime.Model; $receipt.context = $runtime.Context
            $receipt.thinking_enabled = $runtime.Thinking; $receipt.reasoning_effort = $runtime.Effort
            Write-DeskAttachmentReceipt $receipt
            $reports = [Collections.Generic.List[string]]::new()
            $partOutput = if (@($plan.chunks).Count -gt 1) {
                [Math]::Min($runtime.Output, [int](($runtime.Context - 4096 - $runtime.Output) / (@($plan.chunks).Count * 2)))
            } else { $runtime.Output }
            if ($partOutput -lt 256) { throw "Context is too small for attachment synthesis; increase context or narrow the inputs." }
            foreach ($chunk in $plan.chunks) {
                $response = Invoke-DeskAttachmentCompletion $chunk.messages $runtime $partOutput `
                    $chunk.prompt_tokens $receipt
                $coverage = ($chunk.coverage | ForEach-Object { "$($_.id):$($_.start)-$($_.end)" }) -join ", "
                $reports.Add("Supplied ranges: $coverage`n$($response.choices[0].message.content)")
                $receipt.parts += @{ coverage = @($chunk.coverage); prompt_tokens = $response.usage.prompt_tokens
                    completion_tokens = $response.usage.completion_tokens }
                Write-DeskAttachmentReceipt $receipt
            }
            $answer = [string]$reports[0]
            if ($reports.Count -gt 1) {
                $request.op = "attachment-synthesis"
                $request.Remove("sources")
                $request.documents = @($plan.documents)
                $request.reports = @($reports.ToArray())
                if ($receipt.answer_retry) {
                    $request.thinking = $false; $request.reasoning_effort = ""
                    $request.output = [Math]::Min($runtime.Output, 4096)
                }
                $synthesis = Invoke-DeskReviewPlanner $request
                $final = Invoke-DeskAttachmentCompletion $synthesis.messages $runtime $runtime.Output `
                    $synthesis.prompt_tokens $receipt "synthesis"
                $answer = [string]$final.choices[0].message.content
                $receipt.synthesis_prompt_tokens = $final.usage.prompt_tokens
            }
            foreach ($source in $sources) {
                $maximum = if ($source.kind -eq "cpu-ocr") { 10MB } else { 1MB }
                $current = Read-DeskGrantedBytes $source.name $maximum "Attachment"
                if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($current)).ToLowerInvariant() -cne $source.sha256) {
                    throw "Attachment changed during analysis: $($source.name). No complete answer was recorded."
                }
            }
            $receipt.status = "done"; $receipt.report = $answer; $receipt.part_reports = @($reports.ToArray())
            if ($null -ne $memory) {
                $receipt.shared_saved = $false
                $references = @($sources | ForEach-Object { "$($_.name) [sha256=$($_.sha256)]" })
                $saved = Save-GodBrainWorkingTurn -Prompt $receipt.task -Response $answer -ThreadId "desk" -Sources $references
                $receipt.shared_saved = $true
                $receipt.shared_record_id = $saved.record._id
                $receipt.context_index_id = $memory.index_id
            }
            Write-DeskAttachmentReceipt $receipt
            $labels = @($plan.documents | Where-Object kind -ne "derived-diff" | ForEach-Object {
                "$($_.id): $($_.name) [$($_.encoding); $($_.lines) lines]"
            }) -join "`r`n"
            $note = if (@($sources | Where-Object kind -eq "cpu-ocr").Count) {
                "`r`nScreenshots supplied as CPU OCR text only; visual layout and OCR accuracy are not verified."
            } else { "" }
            if ($receipt.answer_retry) {
                $note += "`r`nAnswer recovery: thinking off for recovery and remaining parts; saved preference unchanged."
            }
            return "Candidate analysis; $($sources.Count) attachments supplied completely across $($reports.Count) part(s). No tools or edits.`r`n$labels$note`r`n`r`n$answer"
        } catch {
            $receipt.status = "failed"; $receipt.error = $_.Exception.Message
            Write-DeskAttachmentReceipt $receipt
            throw
        }
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
