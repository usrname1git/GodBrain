#requires -Version 7.0
[CmdletBinding()]
param([switch]$Live)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Start-QwenFlashNext.ps1")
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert ($null -ne $caught) "Expected explicit failure: $Pattern"
    Assert ($caught.Exception.Message -match $Pattern) "Unexpected failure: $caught"
}
$repo = Split-Path $PSScriptRoot -Parent
$envBefore = $env:EXL3_MOE_CPU_SPLIT
$spec = New-QfnLaunchSpec "C:\fixture kit" "C:\fixture model" $repo
Assert ($spec.RequiredRamGiB -eq 43) "Default RAM budget lost reserve/runtime headroom."
Assert ($spec.Info.ArgumentList -contains "127.0.0.1") "Trial is not loopback-only."
Assert ($spec.Info.ArgumentList -contains "16384") "Wrong initial context."
Assert ($spec.Info.Environment["EXL3_MOE_CPU_SPLIT"] -eq "432") "CPU split not forwarded."
Assert ($spec.Info.Environment["EXL3_MOE_CPU_THREADS"] -eq "8") "Wrong CPU worker count."
Assert ($spec.Info.Environment["EXL3_NGRAM_STREAM"] -eq "1") "PLE table would load into RAM."
Assert ($spec.Info.Environment["EXL3_EMBED_STREAM"] -eq "1") "Token embeddings would remain resident in RAM."
Assert ($spec.Info.Environment["EXL3_MOE_CPU_SWAP"] -eq "1") "Dynamic hot/cold expert placement was disabled."
Assert ($spec.Info.Environment["EXL3_HOST_MEM_RESERVE_MB"] -eq "4096") "Host reserve disabled."
Assert (-not $spec.Info.Environment.ContainsKey("CUDA_HOME")) "CUDA_HOME reached the trial."
Assert ($env:EXL3_MOE_CPU_SPLIT -ceq $envBefore) "Parent environment changed."
Assert (-not $spec.Info.UseShellExecute) "Arguments would be shell-expanded."
Assert ($spec.Info.ArgumentList[1] -ceq "C:\fixture kit\tools\serve_openai.py") "Spaced path was not preserved."
$argsList = @($spec.Info.ArgumentList)
Assert ($spec.CacheQuant -ceq "fp16" -and "--cache_quant" -cnotin $argsList) "Quality-first default is not FP16."
foreach ($quant in @("4", "8", "8,4")) {
    $quantSpec = New-QfnLaunchSpec "C:\kit" "C:\model" $repo -CacheQuant $quant
    $quantArgs = @($quantSpec.Info.ArgumentList)
    Assert ($quantArgs[[array]::IndexOf($quantArgs, "--cache_quant") + 1] -ceq $quant) "Explicit KV choice was silently changed."
}
foreach ($pair in @(@("--draft_model", "none"), @("--vision", "off"),
    @("--cpu_cache_size", "0"), @("--grid_size", "13.5"), @("--ui", "off"))) {
    Assert ($argsList[[array]::IndexOf($argsList, $pair[0]) + 1] -ceq $pair[1]) "Wrong argument $($pair[0])."
}
$mtp = New-QfnLaunchSpec "C:\kit" "C:\model" $repo -DraftMode Mtp
$mtpArgs = @($mtp.Info.ArgumentList)
Assert ($mtpArgs[[array]::IndexOf($mtpArgs, "--num_draft_tokens") + 1] -eq "3") "MTP window not bounded."
Assert-Fails { New-QfnLaunchSpec "C:\kit" "C:\model" $repo -CacheSize 257 } "multiple of 256"
Assert-Fails { New-QfnLaunchSpec "C:\kit" "C:\model" $repo -CpuExperts 999 } "ValidateSet|does not belong"
Assert-Fails { New-QfnLaunchSpec "C:\kit" "C:\model" $repo -CacheSize 131072 } "ValidateRange|greater than"
Assert-Fails { New-QfnLaunchSpec "C:\kit" "C:\model" $repo -GpuMemoryGB ([double]::NaN) } "finite|ValidateRange|range"
foreach ($split in @(400,416,432,448,464)) {
    $candidate = New-QfnLaunchSpec "C:\kit" "C:\model" $repo -CpuExperts $split
    Assert ($candidate.RequiredRamGiB -eq ([math]::Ceiling(($split * 48L * 1862412L) / 1GB) + 7)) "Wrong split-dependent memory gate."
}
$oldOffload = $env:EXL3_MOE_CPU_OFFLOAD
$oldStream = $env:EXL3_NGRAM_STREAM
try {
    Initialize-QfnProcessScope
    $job = [GodBrain.QfnProcessScope]::new()
    $parent = [Diagnostics.Process]::new()
    $worker = $null
    try {
        $parent.StartInfo = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $parent.StartInfo.UseShellExecute = $false
        $parent.StartInfo.RedirectStandardOutput = $true
        $parent.StartInfo.RedirectStandardError = $true
        $workerScript = '$i=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$i.UseShellExecute=$false;foreach($a in @("-NoProfile","-Command","Start-Sleep -Seconds 60")){$i.ArgumentList.Add($a)};$p=[Diagnostics.Process]::Start($i);[Console]::Out.WriteLine("worker="+$p.Id);Start-Sleep -Milliseconds 500;exit 7'
        foreach ($argument in @("-NoLogo", "-NoProfile", "-Command", $workerScript)) { $parent.StartInfo.ArgumentList.Add($argument) }
        Assert ($parent.Start()) "Job fixture parent did not start."
        $job.Attach($parent)
        $job.Capture($parent)
        Assert ($parent.WaitForExit(10000)) "Job fixture parent did not exit."
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ($job.Diagnostics -notmatch 'worker=(\d+)' -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        Assert ($job.Diagnostics -match 'worker=(\d+)') "Job fixture lost its bounded output."
        $worker = Get-Process -Id ([int]$Matches[1]) -ErrorAction Stop
        Assert (-not $worker.HasExited) "Worker fixture did not survive its parent's exit."
        $job.Dispose()
        Assert ($worker.WaitForExit(5000)) "Job close did not release the orphaned CPU-worker fixture."
        $parent.WaitForExit()
        Assert ($parent.ExitCode -eq 7) "Child failure exit code was lost."
    } finally {
        $job.Dispose()
        if ($worker) { if (-not $worker.HasExited) { $worker.Kill() }; $worker.Dispose() }
        if ($parent.Id -and -not $parent.HasExited) { $parent.Kill($true); $parent.WaitForExit() }
        $parent.Dispose()
    }
    $env:EXL3_MOE_CPU_OFFLOAD = "999"; $env:EXL3_NGRAM_STREAM = "0"
    $isolated = New-QfnLaunchSpec "C:\kit" "C:\model" $repo
    Assert (-not $isolated.Info.Environment.ContainsKey("EXL3_MOE_CPU_OFFLOAD")) "Inherited layer offload conflicts with expert split."
    Assert ($isolated.Info.Environment["EXL3_NGRAM_STREAM"] -eq "1") "Inherited RAM PLE setting leaked into child."
    Assert ($env:EXL3_MOE_CPU_OFFLOAD -eq "999" -and $env:EXL3_NGRAM_STREAM -eq "0") "Parent environment was rewritten."
} finally {
    $env:EXL3_MOE_CPU_OFFLOAD = $oldOffload; $env:EXL3_NGRAM_STREAM = $oldStream
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("qfn-offline-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($fixture)
try {
    & {
        function Get-CimInstance {
            param($ClassName, $ErrorAction)
            if ($ClassName -eq "Win32_OperatingSystem") {
                return [pscustomobject]@{ FreePhysicalMemory = [uint64]45088768 }
            }
            return @()
        }
        function Get-NetTCPConnection { return @() }
        function Get-Process { return @() }
        function nvidia-smi { $global:LASTEXITCODE = 0; "16384, 15360" }
        $script:integralHardware = Get-QfnHardware $repo "C:\fixture\serve_openai.py"
        Assert ($script:integralHardware.AvailableRamGiB -is [double] -and
            $script:integralHardware.AvailableRamGiB -eq 43.0) "An exact GiB hardware reading was not a Double."
    }
    $supervisorFixture = Join-Path $fixture "supervisor.ps1"
    $workerFixture = Join-Path $fixture "worker.ps1"
    [IO.File]::WriteAllText($workerFixture, @'
param($Root, $Role)
[IO.File]::WriteAllText((Join-Path $Root ("worker-" + $Role)), [string]$PID)
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath (Join-Path $Root "release"))) {
    if ([DateTime]::UtcNow -ge $deadline) { exit 17 }
    Start-Sleep -Milliseconds 20
}
'@)
    [IO.File]::WriteAllText($supervisorFixture, @'
param($Launcher, $Root, $AdmissionName, $Role)
$ErrorActionPreference = "Stop"
. $Launcher
$originalAdmission = ${function:Enter-QfnAdmission}
function Enter-QfnAdmission { & $originalAdmission -Name $AdmissionName }
function Get-QfnPreflight {
    [IO.File]::WriteAllText((Join-Path $Root ("preflight-" + $Role)), "called")
    return @{ready_to_attempt=$true;blockers=@()}
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$tokens, [ref]$errors)
$main = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
$spec = New-QfnLaunchSpec $Root $Root $Root
$spec.Info.FileName = (Get-Process -Id $PID).Path
$spec.Info.ArgumentList.Clear()
foreach ($arg in @("-NoLogo", "-NoProfile", "-File", (Join-Path $Root "worker.ps1"), $Root, $Role)) {
    $spec.Info.ArgumentList.Add($arg)
}
$process = [Diagnostics.Process]::new()
$process.StartInfo = $spec.Info
$DeskLaunch = $true; $CheckOnly = $false
$started = $false; $attached = $false; $scope = $null; $admission = $null
try { & ([scriptblock]::Create($main.Extent.Text)) }
catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
'@)
    $admissionName = "Global\GodBrain.QfnFixture." + [guid]::NewGuid().ToString("N")
    $supervisors = [Collections.Generic.List[Diagnostics.Process]]::new()
    function Start-FixtureSupervisor([string]$Role) {
        $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        foreach ($arg in @("-NoLogo", "-NoProfile", "-File", $supervisorFixture,
            (Join-Path $PSScriptRoot "Start-QwenFlashNext.ps1"), $fixture, $admissionName, $Role)) {
            $info.ArgumentList.Add($arg)
        }
        $child = [Diagnostics.Process]::Start($info)
        $supervisors.Add($child)
        return @{ Process = $child; Out = $child.StandardOutput.ReadToEndAsync(); Err = $child.StandardError.ReadToEndAsync() }
    }
    try {
        $owner = Start-FixtureSupervisor "owner"
        $statusPath = Join-Path $fixture "logs\qfn-last-launch.json"
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath (Join-Path $fixture "worker-owner"))) {
            Assert (-not $owner.Process.HasExited) "Owner supervisor failed before starting its fixture worker."
            Assert ([DateTime]::UtcNow -lt $deadline) "Owner supervisor did not start its fixture worker."
            Start-Sleep -Milliseconds 20
        }
        $beforeStatus = [IO.File]::ReadAllText($statusPath)
        Assert (($beforeStatus | ConvertFrom-Json).state -eq "loading") "Owner did not publish loading status."
        $loser = Start-FixtureSupervisor "competitor"
        Assert ($loser.Process.WaitForExit(10000)) "Competing QFN launch did not fail promptly."
        Assert ($loser.Process.ExitCode -eq 1 -and
            $loser.Err.GetAwaiter().GetResult() -match "Another QFN launch owns admission") "Concurrent launch was not rejected by admission."
        Assert (-not (Test-Path -LiteralPath (Join-Path $fixture "preflight-competitor")) -and
            -not (Test-Path -LiteralPath (Join-Path $fixture "worker-competitor"))) "Competing launch reached preflight or started a model."
        Assert ([IO.File]::ReadAllText($statusPath) -ceq $beforeStatus) "Competing launch overwrote the owner's status."
        Assert (-not $owner.Process.HasExited) "Rejected competitor terminated the owner."
        [IO.File]::WriteAllText((Join-Path $fixture "release"), "release")
        Assert ($owner.Process.WaitForExit(10000) -and $owner.Process.ExitCode -eq 0) "Owner did not finish cleanly."
        $released = Enter-QfnAdmission -Name $admissionName
        $released.ReleaseMutex()
        $released.Dispose()
    } finally {
        foreach ($supervisor in $supervisors) {
            if (-not $supervisor.HasExited) { $supervisor.Kill($true); $supervisor.WaitForExit() }
            $supervisor.Dispose()
        }
    }
    $childSpec = New-QfnLaunchSpec $fixture $fixture $repo
    $childInfo = $childSpec.Info
    $childInfo.FileName = (Get-Process -Id $PID).Path
    $childInfo.ArgumentList.Clear()
    foreach ($value in @("-NoLogo", "-NoProfile", "-Command",
        '@{split=$env:EXL3_MOE_CPU_SPLIT;stream=$env:EXL3_NGRAM_STREAM;reserve=$env:EXL3_HOST_MEM_RESERVE_MB;cwd=(Get-Location).Path}|ConvertTo-Json -Compress')) {
        $childInfo.ArgumentList.Add($value)
    }
    $childInfo.RedirectStandardOutput = $true
    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $childInfo
    $childStarted = $false
    try {
        $childStarted = $child.Start()
        Assert $childStarted "Synthetic child did not start."
        $stdout = $child.StandardOutput.ReadToEndAsync()
        Assert ($child.WaitForExit(10000)) "Synthetic environment probe timed out."
        Assert ($child.ExitCode -eq 0) "Synthetic child failed."
        $childResult = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json
        Assert ($childResult.split -eq "432" -and $childResult.stream -eq "1" -and $childResult.reserve -eq "4096") "Real child did not receive the isolated settings."
        Assert ($childResult.cwd -eq $fixture) "Real child has the wrong working directory."
        Assert ($env:EXL3_MOE_CPU_SPLIT -ceq $envBefore) "Real child polluted parent environment."
    } finally {
        if ($childStarted -and -not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
        $child.Dispose()
    }
    & {
        function Get-Command {
            param($Name, $CommandType, $ErrorAction)
            Assert ($Name -ceq "hf" -and $CommandType -ceq "Application") "Hub executable lookup was not constrained."
            @(
                [pscustomobject]@{ Source = (Get-Process -Id $PID).Path }
                [pscustomobject]@{ Source = (Join-Path $fixture "nonexistent-hf.exe") }
            )
        }
        $beforeUtf8 = $env:PYTHONUTF8
        $beforeEncoding = $env:PYTHONIOENCODING
        $result = Invoke-QfnHub -HubArguments @("-NoLogo", "-NoProfile", "-Command",
            '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);@{utf8=$env:PYTHONUTF8;encoding=$env:PYTHONIOENCODING;unicode=[string][char]0x2713}|ConvertTo-Json -Compress') |
            ConvertFrom-Json
        Assert ($result.utf8 -ceq "1" -and $result.encoding -ceq "utf-8") "Hub child is not configured for UTF-8."
        Assert ($result.unicode -ceq [string][char]0x2713) "Hub child output was not decoded as UTF-8."
        Assert ($env:PYTHONUTF8 -ceq $beforeUtf8 -and $env:PYTHONIOENCODING -ceq $beforeEncoding) "Hub child changed the parent encoding."
        Assert-Fails {
            Invoke-QfnHub -HubArguments @("-NoLogo", "-NoProfile", "-Command",
                '[Console]::Out.WriteLine("fixture checksum mismatch");[Console]::Error.WriteLine("fixture stderr");exit 7')
        } '(?s)failed \(exit 7\).*fixture checksum mismatch.*fixture stderr'
        try {
            Invoke-QfnHub -HubArguments @("-NoLogo", "-NoProfile", "-Command",
                '[Console]::Out.Write("x"*10000);exit 9') | Out-Null
            throw "Expected bounded Hub failure."
        } catch {
            Assert ($_.Exception.Message.Length -lt 8500 -and $_.Exception.Message -match '\[diagnostics truncated\]') "Hub failure diagnostics are not bounded."
        }
    }
    $receiptPath = Join-Path $fixture "verification.json"
    $modelSpec = [pscustomobject]@{ ModelRoot = $fixture; ReceiptPath = $receiptPath; RepoRoot = $fixture }
    Write-QfnLaunchStatus $modelSpec "failed" ("fixture " + ("x" * 10000))
    $launchStatus = Get-Content -LiteralPath (Join-Path $fixture "logs\qfn-last-launch.json") -Raw | ConvertFrom-Json
    Assert ($launchStatus.state -ceq "failed" -and $launchStatus.message.Length -eq 8192) "Desk failure receipt is missing or unbounded."
    & {
        $tokens = $null; $parseErrors = $null
        $launcherAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot "Start-QwenFlashNext.ps1"), [ref]$tokens, [ref]$parseErrors)
        Assert (-not $parseErrors.Count) "QFN launcher cannot be parsed."
        $main = @($launcherAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
        function Get-QfnPreflight { return @{ready_to_attempt=$false;blockers=@("fixture insufficient RAM")} }
        $DeskLaunch = $true; $CheckOnly = $false
        $spec = $modelSpec
        $process = [Diagnostics.Process]::new()
        $started = $false; $attached = $false; $scope = $null
        $admission = $null
        $originalAdmission = ${function:Enter-QfnAdmission}
        function Enter-QfnAdmission { & $originalAdmission -Name $admissionName }
        Assert-Fails { & ([scriptblock]::Create($main.Extent.Text)) } "fixture insufficient RAM"
        $failure = Get-Content -LiteralPath (Join-Path $fixture "logs\qfn-last-launch.json") -Raw | ConvertFrom-Json
        Assert ($failure.state -ceq "failed" -and $failure.message -like "*fixture insufficient RAM*") "Real launcher failure path did not publish the Desk error."
    }
    Assert-Fails { Test-QfnModelSnapshot $modelSpec } "receipt missing"
    $config = '{"architectures":["Qwen4ExpForConditionalGeneration"],"text_config":{"num_experts":512,"num_experts_per_tok":10},"quantization_config":{"quant_method":"exl3","bits":3.05}}'
    $names = @("config.json", "chat_template.jinja", "tokenizer.json", "tokenizer_config.json",
        "model.safetensors.index.json", "quantization_config.json", "ngram_embedding.safetensors",
        "mtp_hyper_connection_mixer_patch.safetensors", "generation_config.json", "merges.txt", "vocab.json")
    $names += 1..7 | ForEach-Object { "model-{0:D5}-of-00007.safetensors" -f $_ }
    foreach ($name in $names) {
        [IO.File]::WriteAllText((Join-Path $fixture $name), $(if ($name -eq "config.json") { $config } else { "fixture" }))
    }
    $proof = @{
        version = 1; verified = $true; method = "hf-cache-verify"
        repo = "turboderp/Qwen3.8-Flash-Next-exl3"; revision = "69e33439ae950f17bcbe95c98f117d80f759ab6d"
        model_root = $fixture; config_sha256 = (Get-FileHash (Join-Path $fixture "config.json")).Hash
        files = @($names | ForEach-Object {
            $item = Get-Item -LiteralPath (Join-Path $fixture $_)
            @{ path = $_; size = $item.Length; last_write_utc_ticks = [string]$item.LastWriteTimeUtc.Ticks }
        })
    }
    function Save-FixtureProof { $proof | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath }
    Save-FixtureProof
    Test-QfnModelSnapshot $modelSpec
    $proof.revision = "main"; Save-FixtureProof
    Assert-Fails { Test-QfnModelSnapshot $modelSpec } "pinned 3.05"
    $proof.revision = "69e33439ae950f17bcbe95c98f117d80f759ab6d"
    $proof.model_root = "C:\wrong-model"; Save-FixtureProof
    Assert-Fails { Test-QfnModelSnapshot $modelSpec } "pinned 3.05"
    $proof.model_root = $fixture
    $proof.verified = "true"; Save-FixtureProof
    Assert-Fails { Test-QfnModelSnapshot $modelSpec } "pinned 3.05"
    $proof.verified = $true
    $proof.files[0].path = "..\escape"; Save-FixtureProof
    Assert-Fails { Test-QfnModelSnapshot $modelSpec } "inventory entry"
    $proof.files[0].path = "config.json"
    $proof.files[0].size++; Save-FixtureProof
    Assert-Fails { Test-QfnModelSnapshot $modelSpec } "changed or is incomplete"
    $proof.files[0].size--
    $proof.files[0].last_write_utc_ticks = "invalid"; Save-FixtureProof
    Assert-Fails { Test-QfnModelSnapshot $modelSpec } "changed or is incomplete"
    $proof.files[0].last_write_utc_ticks = [string](Get-Item (Join-Path $fixture "config.json")).LastWriteTimeUtc.Ticks
    $proof.config_sha256 = "0" * 64; Save-FixtureProof
    Assert-Fails { Test-QfnModelSnapshot $modelSpec } "config hash"

    & {
        function Invoke-QfnHub {
            param([string[]]$HubArguments)
            if ($HubArguments[0] -eq "models") {
                return $proof.files | Select-Object path,size | ConvertTo-Json
            }
            if ($script:verifyFails) { throw "fixture checksum failure" }
            Assert ($HubArguments -contains "--fail-on-missing-files") "Verification did not require all pinned files."
            Assert ($HubArguments[-1] -ceq "human") "Checksum failures would hide per-file diagnostics."
        }
        $script:verifyFails = $false
        Save-QfnSnapshotVerification $modelSpec | Out-Null
        Test-QfnModelSnapshot $modelSpec
        $before = [IO.File]::ReadAllText($receiptPath)
        $script:verifyFails = $true
        Assert-Fails { Save-QfnSnapshotVerification $modelSpec } "fixture checksum failure"
        Assert ([IO.File]::ReadAllText($receiptPath) -ceq $before) "Failed verification replaced a previous receipt."
        $script:verifyFails = $false
        [IO.File]::AppendAllText((Join-Path $fixture "ngram_embedding.safetensors"), "changed")
        Assert-Fails { Save-QfnSnapshotVerification $modelSpec } "Incomplete QFN download"
        Assert ([IO.File]::ReadAllText($receiptPath) -ceq $before) "Partial download replaced a verified receipt."
    }

    & {
        function Test-Path { return $true }
        function Test-QfnModelSnapshot {}
        function Get-QfnRuntimeInfo { return $script:runtime }
        function Get-QfnHardware { return $script:hardware }
        $script:runtime = @{engine="1.6.1+cu128.torch2.11.0";split=$true;stream=$true;embed=$true;flags=@(
            "--model","--model_id","--host","--port","--cache_size","--cache_quant",
            "--grid_size","--cpu_cache_size","--draft_model","--num_draft_tokens","--vision","--ui")}
        $script:hardware = @{AvailableRamGiB=44.0;AvailableVramGiB=15.0;BusyPorts=@();LoadingPids=@();Cs2Held=$false}
        $ready = Get-QfnPreflight $spec
        Assert ($ready.ready_to_attempt -and -not $ready.inference_fit_proven) "Preflight pretended to prove inference."
        $script:hardware = $script:integralHardware
        Assert ((Get-QfnPreflight $spec).ready_to_attempt) "Exact GiB hardware reading failed typed preflight."
        foreach ($port in @(8000,8871,8888)) {
            $script:hardware.BusyPorts = @($port)
            Assert (-not (Get-QfnPreflight $spec).ready_to_attempt) "Busy port $port accepted."
        }
        $script:hardware.BusyPorts = @()
        foreach ($ram in @(38.0,42.99)) {
            $script:hardware.AvailableRamGiB = $ram
            Assert (-not (Get-QfnPreflight $spec).ready_to_attempt) "Insufficient RAM accepted."
        }
        $script:hardware.AvailableRamGiB = 43.0
        Assert ((Get-QfnPreflight $spec).ready_to_attempt) "Exact minimum RAM rejected."
        $script:hardware.AvailableVramGiB = 14.49
        Assert (-not (Get-QfnPreflight $spec).ready_to_attempt) "Insufficient dedicated VRAM accepted."
        $script:hardware.AvailableVramGiB = 15.0
        $script:hardware.Cs2Held = $true
        Assert (-not (Get-QfnPreflight $spec).ready_to_attempt) "CS2 hold ignored."
        $script:hardware.Cs2Held = $false; $script:hardware.LoadingPids = @(123)
        Assert (-not (Get-QfnPreflight $spec).ready_to_attempt) "Loading process ignored."
        $script:hardware.LoadingPids = @(); $script:hardware.AvailableRamGiB = [double]::NaN
        Assert-Fails { Get-QfnPreflight $spec } "Invalid AvailableRamGiB"
        $script:hardware.AvailableRamGiB = 44.0; $script:runtime.split = $false
        Assert-Fails { Get-QfnPreflight $spec } "lacks the reviewed"
        $script:runtime.split = $true; $script:runtime.engine = "1.5.0"
        Assert-Fails { Get-QfnPreflight $spec } "lacks the reviewed"
        $script:runtime.engine = "1.6.1"; $script:runtime.flags = @()
        Assert-Fails { Get-QfnPreflight $spec } "does not accept"
    }
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
& {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot "Test-QwenFlashNext.ps1"), [ref]$tokens, [ref]$errors)
    Assert (-not $errors.Count) "Live smoke test cannot be parsed."
    $gate = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq '$Live'
    }, $true)
    Assert ($null -ne $gate) "Explicit live opt-in is missing."
    $bodyText = $gate.Clauses[0].Item2.Extent.Text
    $exercise = [scriptblock]::Create($bodyText.Substring(1, $bodyText.Length - 2))
    function Invoke-RestMethod {
        param($Uri, $Method, $ContentType, $Body, $TimeoutSec)
        if ($Uri -like "*/health") { return $script:liveHealth }
        $script:livePosts++
        $request = $Body | ConvertFrom-Json
        Assert ($request.model -ceq "qwen3.8-flash-next-exl3-3.05bpw") "Smoke test sent the wrong model ID."
        Assert ($request.max_tokens -eq 32 -and -not $request.chat_template_kwargs.enable_thinking) "Smoke test is unbounded or thinking-on."
        return $script:liveResponse
    }
    $script:liveHealth = @{backend="exl3";model="qwen3.8-flash-next-exl3-3.05bpw";busy=$false;context_length=16384}
    $script:liveResponse = @{choices=@(@{finish_reason="stop";message=@{content="4"}});usage=@{prompt_tokens=12;completion_tokens=1}}
    $script:livePosts = 0
    $pass = (& $exercise) | ConvertFrom-Json
    Assert ($pass.status -ceq "pass" -and $script:livePosts -eq 1) "Synthetic live result did not pass."
    $script:liveHealth.model = "another-model"
    Assert-Fails { & $exercise } "actual QFN model"
    Assert ($script:livePosts -eq 1) "Wrong-model health check still generated."
    $script:liveHealth.model = "qwen3.8-flash-next-exl3-3.05bpw"; $script:liveHealth.busy = $true
    Assert-Fails { & $exercise } "busy"
    Assert ($script:livePosts -eq 1) "Busy health check still generated."
    $script:liveHealth.busy = $false; $script:liveResponse.choices[0].message.content = "5"
    Assert-Fails { & $exercise } "wrong answer"
    $script:liveResponse.choices[0].message.content = "4"; $script:liveResponse.choices[0].finish_reason = "length"
    Assert-Fails { & $exercise } "complete normally"
    $script:liveResponse.choices[0].finish_reason = "stop"; $script:liveResponse.usage.completion_tokens = 0
    Assert-Fails { & $exercise } "token receipt"
}
Write-Output "PASS: QFN arguments, isolated environment, pinned inventory and no-GPU preflight gates."
if ($Live) {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:8888/health" -TimeoutSec 5
    Assert ($health.backend -ceq "exl3" -and $health.model -ceq "qwen3.8-flash-next-exl3-3.05bpw") "Live smoke test requires the actual QFN model, not another mouth."
    Assert ($health.busy -is [bool] -and -not $health.busy) "QFN is busy or did not report idle readiness."
    $body = @{
        model = "qwen3.8-flash-next-exl3-3.05bpw"
        messages = @(@{role="user";content="What is 2+2? Reply with the digit only."})
        max_tokens = 32; temperature = 0
        chat_template_kwargs = @{enable_thinking=$false}
    } | ConvertTo-Json -Depth 4
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:8888/v1/chat/completions" `
        -Method Post -ContentType "application/json" -Body $body -TimeoutSec 180
    Assert ($response.choices.Count -eq 1 -and $response.choices[0].finish_reason -ceq "stop") "QFN smoke test did not complete normally."
    Assert ($response.choices[0].message.content -match '^\s*4\s*$') "QFN smoke test returned the wrong answer."
    Assert ($response.usage.prompt_tokens -gt 0 -and $response.usage.completion_tokens -gt 0) "QFN smoke test has no token receipt."
    @{
        status = "pass"; model = $health.model; context_tokens = $health.context_length
        answer = "4"; usage = $response.usage; metrics = $response.exllamav3
    } | ConvertTo-Json -Depth 8
}
