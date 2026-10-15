#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$VerifySnapshot,
    [ValidateSet(400, 416, 432, 448, 464)][int]$CpuExperts = 432,
    [ValidateRange(256, 65536)][int]$CacheSize = 16384,
    [ValidateSet("fp16", "4", "8", "8,4")][string]$CacheQuant = "fp16",
    [ValidateRange(1, 14.7)][double]$GpuMemoryGB = 13.5,
    [ValidateRange(0, 0)][double]$CpuCacheSizeGB = 0,
    [ValidateSet("None", "Mtp")][string]$DraftMode = "None",
    [ValidateRange(1, 12)][int]$NumDraftTokens = 3,
    [switch]$DeskLaunch,
    [string]$KitRoot = "C:\nvme\Qwen3.8-27B-16gb",
    [string]$ModelRoot = "C:\nvme\Qwen3.8-Flash-Next-EXL3-3.05bpw"
)
$ErrorActionPreference = "Stop"

function New-QfnLaunchSpec {
    param(
        [string]$KitRoot, [string]$ModelRoot, [string]$RepoRoot,
        [ValidateSet(400, 416, 432, 448, 464)][int]$CpuExperts = 432,
        [ValidateRange(256, 65536)][int]$CacheSize = 16384,
        [ValidateSet("None", "Mtp")][string]$DraftMode = "None",
        [ValidateSet("fp16", "4", "8", "8,4")][string]$CacheQuant = "fp16",
        [ValidateRange(1, 14.7)][double]$GpuMemoryGB = 13.5,
        [ValidateRange(1, 12)][int]$NumDraftTokens = 3
    )
    if ($CacheSize % 256) { throw "CacheSize must be a multiple of 256." }
    if (-not [double]::IsFinite($GpuMemoryGB)) { throw "GPU budget must be finite." }
    $kit = [IO.Path]::GetFullPath($KitRoot)
    $model = [IO.Path]::GetFullPath($ModelRoot)
    $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $kit ".venv\Scripts\python.exe"))
    $info.WorkingDirectory = $kit
    $info.UseShellExecute = $false
    foreach ($argument in @(
        "-u", (Join-Path $kit "tools\serve_openai.py"),
        "--model", $model, "--model_id", "qwen3.8-flash-next-exl3-3.05bpw",
        "--host", "127.0.0.1", "--port", "8888",
        "--cache_size", [string]$CacheSize,
        "--grid_size", $GpuMemoryGB.ToString([Globalization.CultureInfo]::InvariantCulture), "--cpu_cache_size", "0",
        "--draft_model", $DraftMode.ToLowerInvariant(), "--vision", "off", "--ui", "off"
    )) { $info.ArgumentList.Add($argument) }
    if ($CacheQuant -ne "fp16") {
        $info.ArgumentList.Add("--cache_quant")
        $info.ArgumentList.Add($CacheQuant)
    }
    if ($DraftMode -eq "Mtp") {
        $info.ArgumentList.Add("--num_draft_tokens")
        $info.ArgumentList.Add([string]$NumDraftTokens)
    }
    [void]$info.Environment.Remove("CUDA_HOME")
    foreach ($name in @($info.Environment.Keys)) {
        if ($name -like "EXL3_MOE_*" -or $name -like "EXL3_NGRAM_*" -or
            $name -in @("EXL3_HOST_MEM_RESERVE_MB", "EXL3_EMBED_STREAM")) {
            [void]$info.Environment.Remove($name)
        }
    }
    foreach ($entry in @{
        EXL3_MOE_CPU_SPLIT = [string]$CpuExperts
        EXL3_MOE_CPU_THREADS = "8"
        EXL3_MOE_CPU_PIN = "1"
        EXL3_MOE_CPU_SWAP = "1"
        EXL3_MOE_HOST_CORES = "1"
        EXL3_MOE_PINNED_ARENA = "0"
        EXL3_NGRAM_STREAM = "1"
        EXL3_EMBED_STREAM = "1"
        EXL3_HOST_MEM_RESERVE_MB = "4096"
        PYTHONIOENCODING = "utf-8"
        PYTHONUTF8 = "1"
        TRITON_CACHE_DIR = (Join-Path $kit "triton-cache")
        TRITON_PTXAS_PATH = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.3\bin\ptxas.exe"
    }.GetEnumerator()) { $info.Environment[$entry.Key] = $entry.Value }
    # Packed expert bytes from every shard header; allow arena rounding, 4 GiB reserve and 3 GiB runtime.
    $packedGiB = ($CpuExperts * 48L * 1862412L) / 1GB
    return [pscustomobject]@{
        Info = $info
        ModelRoot = $model
        RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
        ReceiptPath = Join-Path $RepoRoot "logs\qfn-model-verification.json"
        CpuExperts = $CpuExperts
        CacheSize = $CacheSize
        DraftMode = $DraftMode
        CacheQuant = $CacheQuant
        RequiredRamGiB = [math]::Ceiling($packedGiB) + 7
        RequiredVramGiB = [math]::Max(14.5, $GpuMemoryGB + 0.8)
    }
}

function Initialize-QfnProcessScope {
    if ("GodBrain.QfnProcessScope" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace GodBrain {
    public sealed class QfnProcessScope : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct Basic {
            public long ProcessTime, JobTime; public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveProcessLimit; public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] struct Io {
            public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
        }
        [StructLayout(LayoutKind.Sequential)] struct Extended {
            public Basic Basic; public Io Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool SetInformationJobObject(IntPtr job, int kind, IntPtr info, uint size);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        IntPtr job;
        readonly Queue<string> tail = new Queue<string>();
        public QfnProcessScope() {
            job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            var info = new Extended(); info.Basic.Flags = 0x2000;
            int size = Marshal.SizeOf(typeof(Extended));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(job, 9, buffer, (uint)size))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            } catch { Dispose(); throw; }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        public void Attach(Process process) {
            if (!AssignProcessToJobObject(job, process.Handle))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        void Record(string line) {
            if (line == null) return;
            lock (tail) {
                if (tail.Count == 128) tail.Dequeue();
                tail.Enqueue(line.Length > 4096 ? line.Substring(line.Length - 4096) : line);
            }
        }
        public void Capture(Process process) {
            process.OutputDataReceived += (sender, e) => Record(e.Data);
            process.ErrorDataReceived += (sender, e) => Record(e.Data);
            process.BeginOutputReadLine(); process.BeginErrorReadLine();
        }
        public string Diagnostics { get { lock (tail) { return string.Join("\n", tail); } } }
        public void Dispose() {
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
        }
    }
}
'@
}

function Write-QfnLaunchStatus {
    param($Spec, [ValidateSet("checking", "loading", "stopped", "failed")][string]$State, [string]$Message)
    $path = Join-Path $Spec.RepoRoot "logs\qfn-last-launch.json"
    [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
    if ($Message.Length -gt 8192) { $Message = $Message.Substring($Message.Length - 8192) }
    $record = @{ version = 1; state = $State; message = $Message; launcher_pid = $PID
        at_utc = [DateTime]::UtcNow.ToString("o") }
    $temp = $path + "." + [guid]::NewGuid().ToString("N") + ".tmp"
    try {
        [IO.File]::WriteAllText($temp, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $path, $true)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Test-QfnModelSnapshot {
    param($Spec)
    if (-not (Test-Path -LiteralPath $Spec.ReceiptPath -PathType Leaf)) {
        throw "Pinned QFN checksum receipt missing: $($Spec.ReceiptPath). Finish download and hf cache verify first."
    }
    $proof = Get-Content -LiteralPath $Spec.ReceiptPath -Raw | ConvertFrom-Json
    if ($proof.version -ne 1 -or $proof.verified -isnot [bool] -or -not $proof.verified -or
        $proof.method -cne "hf-cache-verify" -or
        $proof.repo -cne "turboderp/Qwen3.8-Flash-Next-exl3" -or
        $proof.revision -cne "69e33439ae950f17bcbe95c98f117d80f759ab6d" -or
        $proof.model_root -ine $Spec.ModelRoot -or $proof.config_sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "QFN verification receipt does not identify the pinned 3.05 snapshot."
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (@($proof.files).Count -lt 17 -or @($proof.files).Count -gt 64) { throw "Invalid QFN file inventory." }
    foreach ($entry in $proof.files) {
        if ($entry.path -notmatch '^[A-Za-z0-9_.-]+$' -or $entry.path -in @(".", "..") -or
            -not $seen.Add($entry.path) -or
            ($entry.size -isnot [int] -and $entry.size -isnot [long]) -or $entry.size -le 0) {
            throw "Invalid or duplicate QFN inventory entry."
        }
        $file = Get-Item -LiteralPath (Join-Path $Spec.ModelRoot $entry.path) -ErrorAction Stop
        if ($file.PSIsContainer -or $file.Length -ne $entry.size -or
            [string]$file.LastWriteTimeUtc.Ticks -cne $entry.last_write_utc_ticks) {
            throw "QFN snapshot changed or is incomplete: $($entry.path). Repeat checksum verification."
        }
    }
    $required = @("config.json", "chat_template.jinja", "tokenizer.json", "tokenizer_config.json",
        "model.safetensors.index.json", "quantization_config.json", "ngram_embedding.safetensors",
        "mtp_hyper_connection_mixer_patch.safetensors", "generation_config.json", "merges.txt", "vocab.json")
    $required += 1..7 | ForEach-Object { "model-{0:D5}-of-00007.safetensors" -f $_ }
    foreach ($name in $required) {
        if (-not $seen.Contains($name)) { throw "QFN verified inventory is missing $name." }
    }
    $configPath = Join-Path $Spec.ModelRoot "config.json"
    if ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ine $proof.config_sha256) {
        throw "QFN config hash differs from the checksum-verified snapshot."
    }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($config.architectures -cnotcontains "Qwen4ExpForConditionalGeneration" -or
        $config.text_config.num_experts -ne 512 -or $config.text_config.num_experts_per_tok -ne 10 -or
        $config.quantization_config.quant_method -cne "exl3" -or $config.quantization_config.bits -ne 3.05) {
        throw "QFN configuration is not the expected 512-expert EXL3 3.05 checkpoint."
    }
}

function Invoke-QfnHub {
    param([string[]]$HubArguments)
    $cli = Get-Command hf -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $info = [Diagnostics.ProcessStartInfo]::new($cli.Source)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.Environment["PYTHONUTF8"] = "1"
    $info.Environment["PYTHONIOENCODING"] = "utf-8"
    $info.Environment["HF_DEBUG"] = "0"
    foreach ($argument in $HubArguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw "QFN Hub command did not start." }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(250)) { }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $details = ($output + "`n" + $errorText).Trim()
            if ($details.Length -gt 8192) { $details = $details.Substring(0, 8192) + "`n[diagnostics truncated]" }
            throw "QFN Hub $($HubArguments[0]) failed (exit $($process.ExitCode)); receipt unchanged.`n$details"
        }
        if ($errorText.Trim()) { Write-Warning $errorText.Trim() }
        return $output
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

function Save-QfnSnapshotVerification {
    param($Spec)
    $repo = "turboderp/Qwen3.8-Flash-Next-exl3"
    $revision = "69e33439ae950f17bcbe95c98f117d80f759ab6d"
    $manifest = Invoke-QfnHub -HubArguments @("models", "list", $repo, "--revision", $revision, "--recursive", "--format", "json") |
        ConvertFrom-Json
    $files = @(
        foreach ($entry in $manifest) {
            if ($entry.path -notmatch '^[A-Za-z0-9_.-]+$' -or $entry.path -in @(".", "..")) {
                throw "Unexpected path in pinned QFN manifest."
            }
            $file = Get-Item -LiteralPath (Join-Path $Spec.ModelRoot $entry.path) -ErrorAction Stop
            if ($file.PSIsContainer -or $file.Length -ne $entry.size) { throw "Incomplete QFN download: $($entry.path)." }
            @{ path = $entry.path; size = $file.Length; last_write_utc_ticks = [string]$file.LastWriteTimeUtc.Ticks }
        }
    )
    Invoke-QfnHub -HubArguments @("cache", "verify", $repo, "--revision", $revision, "--local-dir", $Spec.ModelRoot,
        "--fail-on-missing-files", "--format", "human") | Out-Host
    $proof = @{
        version = 1; verified = $true; method = "hf-cache-verify"; repo = $repo; revision = $revision
        model_root = $Spec.ModelRoot; verified_at_utc = [DateTime]::UtcNow.ToString("o")
        config_sha256 = (Get-FileHash -LiteralPath (Join-Path $Spec.ModelRoot "config.json") -Algorithm SHA256).Hash
        files = $files
    }
    [void][IO.Directory]::CreateDirectory((Split-Path $Spec.ReceiptPath -Parent))
    $temp = $Spec.ReceiptPath + "." + [guid]::NewGuid().ToString("N") + ".tmp"
    try {
        [IO.File]::WriteAllText($temp, ($proof | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Test-QfnModelSnapshot ([pscustomobject]@{ ModelRoot = $Spec.ModelRoot; ReceiptPath = $temp })
        [IO.File]::Move($temp, $Spec.ReceiptPath, $true)
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force }
    }
    Write-Output "Verified pinned QFN snapshot; receipt saved to $($Spec.ReceiptPath). No model loaded."
}

function Get-QfnRuntimeInfo {
    param([string]$Python, [string]$Server)
    $probe = @'
import ast, importlib.metadata as m, json, pathlib, sys
d = m.distribution("exllamav3")
cfg = pathlib.Path(d.locate_file("exllamav3/model/config.py")).read_text(encoding="utf-8")
tree = ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
flags = {a.value for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "add_argument" for a in n.args if isinstance(a, ast.Constant) and isinstance(a.value, str)}
print(json.dumps({"engine": d.version, "split": "EXL3_MOE_CPU_SPLIT" in cfg, "stream": "EXL3_NGRAM_STREAM" in cfg, "embed": "EXL3_EMBED_STREAM" in cfg, "flags": sorted(flags)}))
'@
    $output = & $Python -c $probe $Server
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect the installed QFN runtime without loading a model." }
    return $output | ConvertFrom-Json
}

function Get-QfnHardware {
    param([string]$RepoRoot, [string]$Server)
    . (Join-Path $RepoRoot "GodBrain-Cs2.ps1")
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $gpu = @(& nvidia-smi --query-gpu=memory.total,memory.free --format=csv,noheader,nounits)
    if ($LASTEXITCODE -ne 0 -or $gpu.Count -ne 1 -or $gpu[0] -notmatch '^\s*(\d+),\s*(\d+)\s*$') {
        throw "Cannot establish free dedicated memory on the single GPU."
    }
    $totalMiB = [int]$Matches[1]; $freeMiB = [int]$Matches[2]
    if ($totalMiB -le 0 -or $freeMiB -lt 0 -or $freeMiB -gt $totalMiB) { throw "Invalid GPU memory probe." }
    $ports = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalPort -in @(8000, 8871, 8888) })
    $loading = @(Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object { (Test-Cs2ModelProcess $_ $RepoRoot) -or ($Server -and (Test-Cs2ScriptProcess $_ $Server)) })
    return [pscustomobject]@{
        AvailableRamGiB = $os.FreePhysicalMemory / 1MB
        AvailableVramGiB = $freeMiB / 1024.0
        BusyPorts = @($ports | Select-Object -ExpandProperty LocalPort -Unique)
        LoadingPids = @($loading | Select-Object -ExpandProperty ProcessId)
        Cs2Held = ((Read-Cs2PauseState $RepoRoot).paused -or (Test-Cs2Running))
    }
}

function Test-QfnPrerequisites {
    param($Spec)
    foreach ($path in @($Spec.Info.FileName, $Spec.Info.ArgumentList[1],
        $Spec.Info.Environment["TRITON_PTXAS_PATH"])) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "QFN dependency missing: $path" }
    }
    Test-QfnModelSnapshot $Spec
    $runtime = Get-QfnRuntimeInfo $Spec.Info.FileName $Spec.Info.ArgumentList[1]
    if ([version]($runtime.engine -split '\+')[0] -lt [version]"1.6.1" -or
        -not $runtime.split -or -not $runtime.stream -or -not $runtime.embed) { throw "Installed ExLlamaV3 lacks the reviewed QFN support." }
    foreach ($flag in @("--model", "--model_id", "--host", "--port", "--cache_size", "--cache_quant",
        "--grid_size", "--cpu_cache_size", "--draft_model", "--num_draft_tokens", "--vision", "--ui")) {
        if ($flag -cnotin $runtime.flags) { throw "Installed server does not accept $flag." }
    }
    return $runtime
}

function Get-QfnPreflight {
    param($Spec)
    $runtime = Test-QfnPrerequisites $Spec
    $hardware = Get-QfnHardware $Spec.RepoRoot $Spec.Info.ArgumentList[1]
    $issues = [Collections.Generic.List[string]]::new()
    if ($hardware.Cs2Held) { $issues.Add("CS2/manual model hold is active; resume through the existing Desk controls first.") }
    if (@($hardware.BusyPorts).Count) { $issues.Add("Model port(s) already listening: $($hardware.BusyPorts -join ', '). Stop the existing model normally.") }
    if (@($hardware.LoadingPids).Count) { $issues.Add("An existing model process is running/loading: PID $($hardware.LoadingPids -join ', ').") }
    foreach ($field in @("AvailableRamGiB", "AvailableVramGiB")) {
        $value = $hardware.$field
        if ($value -isnot [double] -or -not [double]::IsFinite($value) -or $value -lt 0) {
            throw "Invalid $field probe; QFN was not started."
        }
    }
    if ($hardware.AvailableRamGiB -lt $Spec.RequiredRamGiB) {
        $issues.Add(("Available RAM {0:F2} GiB; this split requires at least {1} GiB. Close other applications, then recheck." -f
            $hardware.AvailableRamGiB, $Spec.RequiredRamGiB))
    }
    if ($hardware.AvailableVramGiB -lt $Spec.RequiredVramGiB) {
        $issues.Add(("Free dedicated VRAM {0:F2} GiB; require {1} GiB." -f $hardware.AvailableVramGiB, $Spec.RequiredVramGiB))
    }
    return [pscustomobject]@{
        ready_to_attempt = ($issues.Count -eq 0)
        inference_fit_proven = $false
        engine = $runtime.engine
        cpu_experts = $Spec.CpuExperts
        gpu_experts = 512 - $Spec.CpuExperts
        context_tokens = $Spec.CacheSize
        cache_quant = $Spec.CacheQuant
        draft_mode = $Spec.DraftMode.ToLowerInvariant()
        available_ram_gib = [math]::Round($hardware.AvailableRamGiB, 2)
        required_available_ram_gib = $Spec.RequiredRamGiB
        available_vram_gib = [math]::Round($hardware.AvailableVramGiB, 2)
        blockers = $issues.ToArray()
    }
}

if ($MyInvocation.InvocationName -eq ".") { return }
$spec = New-QfnLaunchSpec -KitRoot $KitRoot -ModelRoot $ModelRoot -RepoRoot (Split-Path $PSScriptRoot -Parent) `
    -CpuExperts $CpuExperts -CacheSize $CacheSize -DraftMode $DraftMode -CacheQuant $CacheQuant `
    -GpuMemoryGB $GpuMemoryGB -NumDraftTokens $NumDraftTokens
if (($CheckOnly -and $VerifySnapshot) -or ($DeskLaunch -and ($CheckOnly -or $VerifySnapshot))) {
    throw "Choose only one of CheckOnly, VerifySnapshot or DeskLaunch."
}
if ($VerifySnapshot) {
    Save-QfnSnapshotVerification $spec
    return
}
$process = [Diagnostics.Process]::new()
$process.StartInfo = $spec.Info
$started = $false
$attached = $false
$scope = $null
try {
    if ($DeskLaunch) { Write-QfnLaunchStatus $spec "checking" "Checking QFN snapshot, runtime and memory." }
    $preflight = Get-QfnPreflight $spec
    $preflight | ConvertTo-Json -Depth 4
    if (-not $preflight.ready_to_attempt) { throw "QFN preflight blocked: $($preflight.blockers -join ' ')" }
    if ($CheckOnly) { return }
    Initialize-QfnProcessScope
    $scope = [GodBrain.QfnProcessScope]::new()
    if ($DeskLaunch) {
        $spec.Info.CreateNoWindow = $true
        $spec.Info.RedirectStandardOutput = $true
        $spec.Info.RedirectStandardError = $true
        $spec.Info.StandardOutputEncoding = [Text.Encoding]::UTF8
        $spec.Info.StandardErrorEncoding = [Text.Encoding]::UTF8
    }
    Write-Host "Starting QFN on 127.0.0.1:8888. This launcher owns the server and its CPU workers."
    $started = $process.Start()
    if (-not $started) { throw "QFN child process did not start." }
    $scope.Attach($process)
    $attached = $true
    if ($DeskLaunch) {
        $scope.Capture($process)
        Write-QfnLaunchStatus $spec "loading" "Loading QFN; readiness requires live /health."
    }
    while (-not $process.WaitForExit(250)) { }
    $scope.Dispose()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "QFN exited with code $($process.ExitCode). No automatic retry or quality downgrade.`n$($scope.Diagnostics)"
    }
    if ($DeskLaunch) { Write-QfnLaunchStatus $spec "stopped" "QFN server exited." }
} catch {
    if ($DeskLaunch) { Write-QfnLaunchStatus $spec "failed" $_.Exception.Message }
    throw
} finally {
    if ($scope) { $scope.Dispose() }
    if ($started -and $attached) { $process.WaitForExit() }
    elseif ($started -and -not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
    $process.Dispose()
}
