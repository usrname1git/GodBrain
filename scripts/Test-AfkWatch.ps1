[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("GodBrain-Afk-test-" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path (Join-Path $fixture "scripts") -Force
function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike $Message) { throw }
        return
    }
    throw "Expected failure: $Message"
}
function Read-Ast([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors -join "`n") }
    return $ast
}
try {
    @'
function Test-GodBrainColiShouldSleep($RepoRoot) { return $global:AfkTest.held }
function Clear-GodBrainCs2Pause($RepoRoot) { $global:AfkTest.held = $false }
'@ | Set-Content -LiteralPath (Join-Path $fixture "GodBrain-Cs2.ps1")
    @'
param($RepoRoot,[switch]$Afk,[string]$Only,[int]$MongoWaitSeconds,[switch]$KeepPause)
$global:AfkTest.calls.Add("heal:$Afk")
if ($global:AfkTest.healFails) { exit 1 }
if ($global:AfkTest.stopDuringHeal) {
    "on" | Set-Content -LiteralPath (Join-Path $RepoRoot "logs\afk-pause.txt")
}
'@ | Set-Content -LiteralPath (Join-Path $fixture "Heal-GodBrain.ps1")
    @'
param($RepoRoot)
$global:AfkTest.calls.Add("gym")
'@ | Set-Content -LiteralPath (Join-Path $fixture "scripts\Invoke-FrontendGymMaintenance.ps1")
    $global:AfkTest = @{ held = $false; calls = [System.Collections.Generic.List[string]]::new() }
    $watch = Join-Path $repo "Watch-GodBrain.ps1"
    & $watch -RepoRoot $fixture
    Assert-Equal ($global:AfkTest.calls -join ",") "heal:True"
    $global:AfkTest.calls.Clear()
    & $watch -RepoRoot $fixture -WithGym
    Assert-Equal ($global:AfkTest.calls -join ",") "heal:True,gym"
    $global:AfkTest.calls.Clear()
    $global:AfkTest.stopDuringHeal = $true
    & $watch -RepoRoot $fixture -WithGym
    Assert-Equal ($global:AfkTest.calls -join ",") "heal:True"
    $global:AfkTest.stopDuringHeal = $false
    "off" | Set-Content -LiteralPath (Join-Path $fixture "logs\afk-pause.txt")
    $global:AfkTest.calls.Clear()
    "on" | Set-Content -LiteralPath (Join-Path $fixture "logs\afk-gym.txt")
    & $watch -RepoRoot $fixture
    Assert-Equal ($global:AfkTest.calls -join ",") "heal:True,gym"
    $global:AfkTest.calls.Clear()
    $global:AfkTest.held = $true
    & $watch -RepoRoot $fixture -WithGym
    Assert-Equal $global:AfkTest.calls.Count 0
    $global:AfkTest.held = $false
    "on" | Set-Content -LiteralPath (Join-Path $fixture "logs\afk-pause.txt")
    & $watch -RepoRoot $fixture -WithGym
    Assert-Equal $global:AfkTest.calls.Count 0
    & $watch -RepoRoot $fixture -Resume
    Assert-Equal ($global:AfkTest.calls -join ",") "heal:True,gym"
    $global:AfkTest.calls.Clear()
    $global:AfkTest.healFails = $true
    Assert-Throws { & $watch -RepoRoot $fixture -WithGym } "*Heal failed*"
    Assert-Equal ($global:AfkTest.calls -join ",") "heal:True"
    $global:AfkTest.healFails = $false
    @'
param($RepoRoot,[switch]$Afk)
$global:AfkTest.calls.Add("heal:$Afk")
if (-not $global:AfkTest.retried) { $global:AfkTest.retried=$true; exit 1 }
"on" | Set-Content -LiteralPath (Join-Path $RepoRoot "logs\afk-pause.txt")
'@ | Set-Content -LiteralPath (Join-Path $fixture "Heal-GodBrain.ps1")
    & {
        function Start-Sleep { param($Seconds) }
        $global:AfkTest.calls.Clear()
        & $watch -RepoRoot $fixture -Continuous -WithGym
        Assert-Equal ($global:AfkTest.calls -join ",") "heal:True,heal:True"
    }
    "off" | Set-Content -LiteralPath (Join-Path $fixture "logs\afk-pause.txt")

    $heal = Read-Ast (Join-Path $repo "Heal-GodBrain.ps1")
    $services = @($heal.EndBlock.Statements | Where-Object {
        $_.Extent.Text.StartsWith('if ($Afk -and -not $coliSleep)')
    })[0]
    & {
        $Afk = $true; $coliSleep = $false
        $ServiceAllowlist = [ordered]@{ mongo = "MongoDB"; dns = "Dnscache"; iphlp = "iphlpsvc"; nsi = "nsi" }
        $before = @{ tailscale_installed = $true; rustdesk_installed = $true
            tailscale_service = $false; rustdesk_service = $false }
        $needed = @()
        $script:holds = @()
        function Test-DeskPause($FileName) { return $FileName -in $script:holds }
        . ([scriptblock]::Create($services.Extent.Text))
        Assert-Equal ($needed -join ",") "tailscale_service,rustdesk_service"
        Assert-Equal $ServiceAllowlist.tailscale_service "Tailscale"
        Assert-Equal $ServiceAllowlist.rustdesk_service "RustDesk"
        $needed = @()
        $script:holds = @("tailscale-pause.txt", "rustdesk-pause.txt")
        . ([scriptblock]::Create($services.Extent.Text))
        Assert-Equal $needed.Count 0
        $script:holds = @()
        $coliSleep = $true
        . ([scriptblock]::Create($services.Extent.Text))
        Assert-Equal $needed.Count 0
        $coliSleep = $false
        $before.tailscale_installed = $false
        $before.rustdesk_installed = $false
        . ([scriptblock]::Create($services.Extent.Text))
        Assert-Equal $needed.Count 0
    }
    $listeners = $heal.EndBlock.Statements | Where-Object {
        $_.Extent.Text.StartsWith('if ($processNeeded.Count -gt 0)')
    }
    @'
param($RepoRoot,[string]$Only,[int]$MongoWaitSeconds,[switch]$KeepPause)
$global:AfkTest.calls.Add("start:$Only/keep:$KeepPause")
'@ | Set-Content -LiteralPath (Join-Path $fixture "Start-GodBrain.ps1")
    & {
        $Afk = $true; $RepoRoot = $fixture; $starter = Join-Path $fixture "Start-GodBrain.ps1"
        $processNeeded = @("rag", "kernel"); $acted = @()
        function Start-Sleep { param($Seconds) }
        $global:AfkTest.calls.Clear()
        . ([scriptblock]::Create($listeners.Extent.Text))
        Assert-Equal ($global:AfkTest.calls -join ",") "start:rag/keep:True,start:kernel/keep:True"
    }
    $layer = $heal.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-DiagnoseLayer"
    }, $true)
    & {
        . ([scriptblock]::Create($layer.Extent.Text))
        function Test-DeskPause($FileName) { return $false }
        $mouthOptional = $true; $coliSleep = $false; $ragPaused = $false; $kernelPaused = $false
        $probe = @{ icmp_loopback = $true; dns = $true; dns_self = $true; nic_tcpip = $true
            mongo = $true; rag = $true; rag_ready = $true; kernel = $true; coli = $false; mouth_ready = $false }
        Assert-Equal (Get-DiagnoseLayer $probe) "ok"
        $mouthOptional = $false
        Assert-Equal (Get-DiagnoseLayer $probe) "listeners"
        $mouthOptional = $true; $Afk = $true
        $probe.kernel_ready = $false
        Assert-Equal (Get-DiagnoseLayer $probe) "listeners"
        $probe.kernel_ready = $true
        Assert-Equal (Get-DiagnoseLayer $probe) "ok"
    }
    $glances = $heal.Find({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $node.Extent.Text.Contains('@{ Name = "brief"; Path = "/api/brief" }')
    }, $true)
    & {
        $script:routes = @()
        function Invoke-RestMethod { param($Uri, $TimeoutSec); $script:routes += $Uri }
        $Afk = $true
        . ([scriptblock]::Create($glances.Extent.Text))
        Assert-Equal $script:routes.Count 7
        if ($script:routes -match "/api/status|/api/brief") { throw "AFK status probe can kick a model." }
        $script:routes = @(); $Afk = $false
        . ([scriptblock]::Create($glances.Extent.Text))
        Assert-Equal $script:routes.Count 8
    }

    & {
        . (Join-Path $repo "scripts\GodBrain-HostServices.ps1")
        $script:rustExe = "C:\Program Files\RustDesk\rustdesk.exe"
        $script:rustProcesses = @(
            @{ ProcessId = 11; ExecutablePath = $script:rustExe },
            @{ ProcessId = 12; ExecutablePath = "C:\Temp\unrelated\rustdesk.exe" }
        )
        $script:rustActions = @()
        function Get-GodBrainRustDeskExe { return $script:rustExe }
        function Get-CimInstance { param($ClassName, $Filter, $OperationTimeoutSec, $ErrorAction); return $script:rustProcesses }
        function Start-Process {
            param($FilePath, $WindowStyle, [switch]$PassThru)
            $script:rustActions += "start:$FilePath"
            $script:rustProcesses = @(@{ ProcessId = 13; ExecutablePath = $FilePath })
            return @{ Id = 13 }
        }
        function Stop-Cs2OwnedProcess { param($Process); $script:rustActions += "stop:$($Process.ProcessId)" }
        Assert-Equal @(Get-GodBrainRustDeskProcesses).Count 1
        Start-GodBrainRustDeskApp
        Assert-Equal $script:rustActions.Count 0
        Stop-GodBrainRustDeskApp
        Assert-Equal ($script:rustActions -join ",") "stop:11"
        $script:rustActions = @(); $script:rustProcesses = @()
        Start-GodBrainRustDeskApp
        Assert-Equal ($script:rustActions -join ",") "start:$($script:rustExe)"
    }

    $deskCheck = Read-Ast (Join-Path $repo "Test-GodBrainDesk.ps1")
    $freshness = $deskCheck.Find({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$watchEnabled'
    }, $true)
    & {
        $RepoRoot = $fixture
        $briefFile = $doorsFile = $pendingFile = $vramFile = $lastHealFile =
            $lastSreFile = $lastOracleFile = $lastEditFile = $healFile = "receipt.json"
        $fails = [System.Collections.Generic.List[string]]::new()
        $script:receiptAge = 21
        function Test-Path { param($LiteralPath); return $true }
        function Get-Item { param($LiteralPath); return @{ LastWriteTime = (Get-Date).AddMinutes(-$script:receiptAge) } }
        $watchEnabled = $false
        . ([scriptblock]::Create($freshness.Extent.Text))
        Assert-Equal $fails.Count 0
        $watchEnabled = $true
        . ([scriptblock]::Create($freshness.Extent.Text))
        Assert-Equal $fails.Count 10
        $fails.Clear(); $script:receiptAge = 1
        . ([scriptblock]::Create($freshness.Extent.Text))
        Assert-Equal $fails.Count 0
    }

    $gym = Read-Ast (Join-Path $repo "scripts\Invoke-FrontendGymMaintenance.ps1")
    $tick = $gym.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Extent.Text.Contains('$state = Read-GymGlance')
    }
    $startGym = $gym.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Start-Gym"
    }, $true)
    & {
        . ([scriptblock]::Create($startGym.Extent.Text))
        $script:gymCrashLatched = $false; $script:gymCrashStreak = 9
        $script:gymLaunch = @{ Pid = 42; At = [datetime]::UtcNow.AddMinutes(-10) }
        $script:notices = 0
        function Test-GymProcessAlive { param($processId); return $false }
        function Get-GymCrashTail { return "" }
        function Save-GymCrashLatch {}
        function Write-WatchEvent { param($kind, $message) }
        function Send-GymCrashNotice { param($message); $script:notices++ }
        function Start-Process { throw "A latched gym must not restart." }
        Start-Gym
        Assert-Equal $script:gymCrashStreak 10
        Assert-Equal $script:gymCrashLatched $true
        Assert-Equal $script:notices 1
        Start-Gym
        Assert-Equal $script:notices 1
    }
    & {
        $RepoRoot = $fixture; $runtimeDir = $fixture; $heartbeat = "fixture-heartbeat"; $task = ""
        $script:cudaUnsafe = $false
        $script:gymCrashLatched = $false
        $script:tickCalls = @()
        $script:modelAllowed = $true
        $script:pauseDuringStart = $false
        $script:pause = @{ paused = $false; cs2_sleep = $false; stop_qwen = $false; manual_pause = $false }
        $script:state = @{ status = "idle"; lastError = "" }
        $lastHandledIma = ""; $lastPauseState = $false; $lastHostLine = ""; $quietBeats = 0
        function Read-GymGlance { return $script:state }
        function Get-FrontendPause { return $script:pause }
        function Start-Qwen {
            $script:tickCalls += "qwen"
            if ($script:pauseDuringStart) { $script:pause.paused = $true }
            return $script:modelAllowed
        }
        function Start-Gym { $script:tickCalls += "gym" }
        function Start-Dashboard { $script:tickCalls += "dashboard" }
        function Stop-Qwen { $script:tickCalls += "stop-qwen" }
        function Save-GymCrashLatch { $script:tickCalls += "cuda-latch" }
        function Write-WatchEvent { param($kind, $message) }
        function Get-QwenProcess { return $null }
        function Get-QwenListenerProcess { return $null }
        function Test-Port { param($Port); return $false }
        function Test-LoopbackPort { param($Port); return $false }
        function Set-Content { param($LiteralPath, $Value) }
        . ([scriptblock]::Create($tick.Extent.Text))
        Assert-Equal ($script:tickCalls -join ",") "qwen,gym"
        $script:tickCalls = @(); $script:pauseDuringStart = $true
        . ([scriptblock]::Create($tick.Extent.Text))
        Assert-Equal ($script:tickCalls -join ",") "qwen"
        $script:pauseDuringStart = $false; $script:pause.paused = $false
        $script:tickCalls = @(); $script:gymCrashLatched = $true
        . ([scriptblock]::Create($tick.Extent.Text))
        Assert-Equal $script:tickCalls.Count 0
        $script:gymCrashLatched = $false
        $script:tickCalls = @(); $script:modelAllowed = $false
        . ([scriptblock]::Create($tick.Extent.Text))
        Assert-Equal ($script:tickCalls -join ",") "qwen"
        $script:tickCalls = @(); $script:pause.paused = $true
        . ([scriptblock]::Create($tick.Extent.Text))
        Assert-Equal ($script:tickCalls -join ",") "dashboard"
        $script:tickCalls = @(); $script:pause.cs2_sleep = $true
        . ([scriptblock]::Create($tick.Extent.Text))
        Assert-Equal $script:tickCalls.Count 0
        $script:pause.cs2_sleep = $false
        $script:tickCalls = @(); $script:pause.stop_qwen = $true; $script:state.status = "generating"
        . ([scriptblock]::Create($tick.Extent.Text))
        Assert-Equal ($script:tickCalls -join ",") "dashboard"
        $script:tickCalls = @(); $script:pause.paused = $false
        $script:state.lastError = "CUDA illegal memory access"
        . ([scriptblock]::Create($tick.Extent.Text))
        Assert-Equal ($script:tickCalls -join ",") "cuda-latch"
        Assert-Equal $script:cudaUnsafe $true
        $script:tickCalls = @(); $script:state.lastError = ""
        . ([scriptblock]::Create($tick.Extent.Text))
        Assert-Equal $script:tickCalls.Count 0
    }
    "off" | Set-Content -LiteralPath (Join-Path $fixture "logs\afk-gym.txt")
    @'
param($RepoRoot,[switch]$Afk)
Add-Content -LiteralPath (Join-Path $RepoRoot "mutex-entered.txt") -Value "heal"
Start-Sleep -Seconds 3
'@ | Set-Content -LiteralPath (Join-Path $fixture "Heal-GodBrain.ps1")
    $child = Start-Process -FilePath "C:\pwsh\pwsh.exe" -ArgumentList @(
        "-NoProfile", "-File", "`"$watch`"", "-RepoRoot", "`"$fixture`""
    ) -WindowStyle Hidden -RedirectStandardError (Join-Path $fixture "child-error.txt") -PassThru
    try {
        $marker = Join-Path $fixture "mutex-entered.txt"
        $deadline = (Get-Date).AddSeconds(8)
        while (-not (Test-Path -LiteralPath $marker)) {
            if ($child.HasExited -or (Get-Date) -gt $deadline) { throw "Mutex fixture failed to enter Heal." }
            Start-Sleep -Milliseconds 50
        }
        $hash = [Security.Cryptography.SHA256]::Create()
        try {
            $key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($fixture.ToLowerInvariant()))).Replace("-", "")
        } finally { $hash.Dispose() }
        $name = "Global\GodBrainAfk-" + $key
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AfkMutexAccess {
    [StructLayout(LayoutKind.Sequential)] struct Sid { public IntPtr Value; public uint Attributes; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenMutex(uint access, bool inherit, string name);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool ConvertStringSidToSid(string text, out IntPtr sid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool CreateRestrictedToken(IntPtr token, uint flags, uint disableCount, ref Sid disable, uint deleteCount, IntPtr deleted, uint restrictCount, IntPtr restricted, out IntPtr result);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool SetTokenInformation(IntPtr token, int kind, ref Sid value, uint size);
    [DllImport("advapi32.dll")] static extern uint GetLengthSid(IntPtr sid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool ImpersonateLoggedOnUser(IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool RevertToSelf();
    [DllImport("ntdll.dll")] static extern int NtQueryObject(IntPtr handle, int kind, IntPtr buffer, uint size, out uint needed);
    public static void Verify(string name) {
        IntPtr original = IntPtr.Zero, restricted = IntPtr.Zero, admin = IntPtr.Zero, medium = IntPtr.Zero, mutex = IntPtr.Zero, buffer = IntPtr.Zero;
        bool impersonating = false;
        try {
            if (!OpenProcessToken(GetCurrentProcess(), 0x8A, out original) || !ConvertStringSidToSid("S-1-5-32-544", out admin)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Limited-token preparation failed");
            Sid disabled = new Sid { Value = admin };
            if (!CreateRestrictedToken(original, 1, 1, ref disabled, 0, IntPtr.Zero, 0, IntPtr.Zero, out restricted) ||
                !ConvertStringSidToSid("S-1-16-8192", out medium)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Restricted-token creation failed");
            Sid integrity = new Sid { Value = medium, Attributes = 0x20 };
            if (!SetTokenInformation(restricted, 25, ref integrity, (uint)Marshal.SizeOf<Sid>() + GetLengthSid(medium))) throw new Win32Exception(Marshal.GetLastWin32Error(), "Medium-integrity token setup failed");
            if (!ImpersonateLoggedOnUser(restricted)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Limited-token impersonation failed");
            impersonating = true;
            mutex = OpenMutex(0x00100001, false, name);
            if (mutex == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Limited token cannot open Global mutex");
            buffer = Marshal.AllocHGlobal(8192);
            uint needed;
            if (NtQueryObject(mutex, 1, buffer, 8192, out needed) < 0) throw new Exception("Mutex namespace query failed.");
            string resolved = Marshal.PtrToStringUni(Marshal.ReadIntPtr(buffer, IntPtr.Size == 8 ? 8 : 4), (ushort)Marshal.ReadInt16(buffer) / 2);
            if (!resolved.StartsWith(@"\BaseNamedObjects\GodBrainAfk-", StringComparison.Ordinal)) throw new Exception("Mutex is session-local: " + resolved);
        } finally {
            if (impersonating && !RevertToSelf()) throw new Win32Exception();
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            if (mutex != IntPtr.Zero) CloseHandle(mutex);
            if (restricted != IntPtr.Zero) CloseHandle(restricted);
            if (original != IntPtr.Zero) CloseHandle(original);
            if (admin != IntPtr.Zero) LocalFree(admin);
            if (medium != IntPtr.Zero) LocalFree(medium);
        }
    }
}
'@
        [AfkMutexAccess]::Verify($name)
        & $watch -RepoRoot ($fixture + "\")
        Assert-Equal @(Get-Content -LiteralPath $marker).Count 1
        if (-not $child.WaitForExit(8000) -or $child.ExitCode -ne 0) {
            throw "Mutex fixture did not finish successfully."
        }
    } finally {
        if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force }
        $child.Dispose()
    }
    Write-Output "PASS: AFK policy, global mutex contention and same-user medium-integrity admin-disabled token access without ACL changes."
} finally {
    Remove-Variable -Name AfkTest -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
