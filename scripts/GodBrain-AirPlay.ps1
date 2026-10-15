function Get-GodBrainAirPlayExe { return 'C:\Tools\ShairportQt\ShairportQt.exe' }

function Open-GodBrainAirPlayHandle([uint32]$ProcessId) {
    Initialize-GodBrainAirPlayWindow
    return [GodBrain.AirPlayProcessHandle]::Open($ProcessId)
}

function Assert-GodBrainAirPlayProcess($Process, $Handle) {
    $expected = Get-GodBrainAirPlayExe
    if (($Process.ExecutablePath -and $Process.ExecutablePath -ine $expected) -or
        $Handle.ExecutablePath -ine $expected) {
        throw 'An unverified ShairportQt process is present in this session; AirPlay controls are closed.'
    }
    if ($Process.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId -or
        $Process.CreationDate -isnot [datetime]) {
        throw 'AirPlay process session or creation time could not be verified.'
    }
    $created = $Handle.CreationTimeUtc.Ticks
    $observed = $Process.CreationDate.ToUniversalTime().Ticks
    if (($created - $created % 10) -ne ($observed - $observed % 10)) {
        throw 'AirPlay process identity changed before the operation.'
    }
    $owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwnerSid -OperationTimeoutSec 3 -ErrorAction Stop
    if ($owner.ReturnValue -ne 0 -or $owner.Sid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        throw 'Could not verify AirPlay process ownership.'
    }
}

function Get-GodBrainAirPlayProcess {
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $matches = @(Get-CimInstance Win32_Process -Filter "Name='ShairportQt.exe'" -OperationTimeoutSec 3 -ErrorAction Stop |
        Where-Object { $_.SessionId -eq $session })
    foreach ($process in $matches) {
        $handle = Open-GodBrainAirPlayHandle $process.ProcessId
        try { Assert-GodBrainAirPlayProcess $process $handle }
        finally { $handle.Dispose() }
    }
    if ($matches.Count -gt 1) { throw 'Multiple ShairportQt instances are running; AirPlay controls are closed.' }
    if ($matches.Count) { return $matches[0] }
    return $null
}

function Invoke-GodBrainAirPlayProbe {
    param([Diagnostics.ProcessStartInfo]$StartInfo, [ValidateRange(1, 4000)][int]$TimeoutMilliseconds = 3000)
    $probe = [Diagnostics.Process]::new()
    $probe.StartInfo = $StartInfo
    $probe.StartInfo.UseShellExecute = $false
    $probe.StartInfo.CreateNoWindow = $true
    $probe.StartInfo.RedirectStandardOutput = $true
    $probe.StartInfo.RedirectStandardError = $true
    try {
        if (-not $probe.Start()) { throw 'Could not start the AirPlay state probe.' }
        $stdout = $probe.StandardOutput.ReadToEndAsync()
        $stderr = $probe.StandardError.ReadToEndAsync()
        if (-not $probe.WaitForExit($TimeoutMilliseconds)) {
            $probe.Kill()
            if (-not $probe.WaitForExit(1000)) { throw 'AirPlay state probe timed out and did not exit.' }
            throw 'AirPlay state probe timed out.'
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 1000)) {
            throw 'AirPlay state probe output timed out.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($output.Length -gt 16384 -or $errorText.Length -gt 16384 -or $errorText.Trim()) {
            throw 'Invalid AirPlay state probe output.'
        }
        $result = $output | ConvertFrom-Json -NoEnumerate -Depth 8 -ErrorAction Stop
        if ($result -is [array] -or $result -isnot [pscustomobject] -or
            $result.schema_version -ne 1 -or $result.ok -isnot [bool]) {
            throw 'Invalid AirPlay state probe receipt.'
        }
        if (-not $result.ok) {
            if ($result.error -isnot [string] -or [string]::IsNullOrWhiteSpace($result.error) -or
                $result.error.Length -gt 300 -or $result.error -match '[\r\n]') {
                throw 'Invalid AirPlay state probe error.'
            }
            throw "AirPlay state probe failed: $($result.error)"
        }
        if ($probe.ExitCode -ne 0) { throw 'AirPlay state probe exited unsuccessfully.' }
        return $result
    } finally { $probe.Dispose() }
}

function Get-GodBrainAirPlayReceiverState($Process) {
    $exe = Join-Path (Split-Path $PSScriptRoot -Parent) 'godbrain_core\cpp_tools\desk-airplay.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw 'AirPlay state helper is missing; run scripts\Build-DeskAirPlay.ps1 once.'
    }
    $handle = Open-GodBrainAirPlayHandle $Process.ProcessId
    try {
        Assert-GodBrainAirPlayProcess $Process $handle
        $created = $handle.CreationTimeUtc.ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $exe
        foreach ($argument in @('--pid', [string]$Process.ProcessId, '--created', $created)) {
            $info.ArgumentList.Add($argument)
        }
        $result = Invoke-GodBrainAirPlayProbe $info
        if (($result.pid -isnot [long] -and $result.pid -isnot [int]) -or
            $result.pid -ne $Process.ProcessId -or $result.created -isnot [string] -or
            $result.created -cne $created -or $result.source -cne 'shairportqt-uia' -or
            $result.state -cnotin @('ready', 'connected', 'playing', 'paused') -or
            $result.audio_output_verified -isnot [bool] -or $result.audio_output_verified) {
            throw 'Invalid AirPlay receiver state or process identity.'
        }
        if ($handle.WaitForExit(0)) { throw 'AirPlay receiver exited during inspection.' }
        return $result.state
    } finally { $handle.Dispose() }
}

function Get-GodBrainAirPlayLine {
    try {
        $process = Get-GodBrainAirPlayProcess
        if (-not $process) {
            if (Test-Path -LiteralPath (Get-GodBrainAirPlayExe) -PathType Leaf) { return 'stopped (user app)' }
            return 'not installed'
        }
        $ports = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Where-Object OwningProcess -eq $process.ProcessId |
            Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
        if ($ports.Count) {
            try {
                $state = Get-GodBrainAirPlayReceiverState $process
                $detail = if ($state -eq 'connected') { '; playback state unavailable' } else { '' }
                return "$state :$($ports -join ', :') (ShairportQt$detail)"
            } catch { return "listening :$($ports -join ', :') (receiver state unavailable: $($_.Exception.Message))" }
        }
        return 'running (no receiver listener)'
    } catch { return "unread: $($_.Exception.Message)" }
}

function Initialize-GodBrainAirPlayWindow {
    if ('GodBrain.AirPlayWindow' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace GodBrain {
    public sealed class AirPlayProcessHandle : IDisposable {
        private readonly SafeProcessHandle handle;
        public string ExecutablePath { get; private set; }
        public DateTime CreationTimeUtc { get; private set; }
        [DllImport("kernel32.dll", SetLastError=true)] private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool QueryFullProcessImageName(SafeProcessHandle process, uint flags, StringBuilder path, ref uint size);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetProcessTimes(SafeProcessHandle process, out long created, out long exited, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);
        private AirPlayProcessHandle(SafeProcessHandle value, string path, DateTime created) {
            handle = value;
            ExecutablePath = path;
            CreationTimeUtc = created;
        }
        public static AirPlayProcessHandle Open(uint pid) {
            // Query-limited + synchronize, not VM-read or all-access across UAC.
            var process = OpenProcess(0x101000, false, pid);
            if (process.IsInvalid) {
                int error = Marshal.GetLastWin32Error();
                process.Dispose();
                throw new Win32Exception(error, "Could not inspect the AirPlay process.");
            }
            try {
                uint size = 32768;
                var path = new StringBuilder((int)size);
                if (!QueryFullProcessImageName(process, 0, path, ref size)) throw new Win32Exception();
                long created, exited, kernel, user;
                if (!GetProcessTimes(process, out created, out exited, out kernel, out user)) throw new Win32Exception();
                return new AirPlayProcessHandle(process, path.ToString(), DateTime.FromFileTimeUtc(created));
            } catch {
                process.Dispose();
                throw;
            }
        }
        public bool WaitForExit(int milliseconds) {
            if (milliseconds < 0) throw new ArgumentOutOfRangeException("milliseconds");
            uint result = WaitForSingleObject(handle, (uint)milliseconds);
            if (result == 0) return true;
            if (result == 258) return false;
            throw new Win32Exception();
        }
        public void Dispose() { handle.Dispose(); }
    }
    public static class AirPlayWindow {
        private delegate bool EnumProc(IntPtr window, IntPtr data);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int count);
        [DllImport("user32.dll", EntryPoint="GetWindowLongW")] private static extern int GetWindowLong(IntPtr window, int index);
        [DllImport("user32.dll", SetLastError=true)] public static extern bool ShowWindowAsync(IntPtr window, int command);
        [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
        public static IntPtr Find(uint pid) {
            var matches = new List<IntPtr>();
            if (!EnumWindows((window, data) => {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                var name = new StringBuilder(256);
                GetClassName(window, name, name.Capacity);
                if (owner == pid && GetWindow(window, 4) == IntPtr.Zero &&
                    name.ToString().StartsWith("Qt", StringComparison.Ordinal) &&
                    (name.ToString().EndsWith("QWindowIcon", StringComparison.Ordinal) ||
                     name.ToString().EndsWith("QWindowOwnDCIcon", StringComparison.Ordinal)) &&
                    (GetWindowLong(window, -16) & 0x00C00000) == 0x00C00000) matches.Add(window);
                return true;
            }, IntPtr.Zero)) throw new InvalidOperationException("AirPlay window query failed.");
            if (matches.Count != 1) throw new InvalidOperationException("AirPlay main window is missing or ambiguous.");
            return matches[0];
        }
    }
}
'@
}

function Invoke-GodBrainAirPlay {
    param([ValidateSet('Start', 'Stop', 'Open')][string]$Action)
    $mutex = [Threading.Mutex]::new($false, 'Local\GodBrainShairportQt')
    $locked = $false
    $handle = $null
    try {
        try { $locked = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another AirPlay operation is in progress.' }
        $process = Get-GodBrainAirPlayProcess
        if (-not $process -and $Action -eq 'Stop') { return 'stopped (user app)' }
        if (-not $process) {
            $exe = Get-GodBrainAirPlayExe
            if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "AirPlay is not installed at $exe." }
            $launched = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Minimized -PassThru
            try {
                $deadline = [datetime]::UtcNow.AddSeconds(5)
                do {
                    $process = Get-GodBrainAirPlayProcess
                    if ($process) { break }
                    Start-Sleep -Milliseconds 100
                } while ([datetime]::UtcNow -lt $deadline)
                if (-not $process -or $process.ProcessId -ne $launched.Id) {
                    throw 'AirPlay launch did not produce the expected single user-session process.'
                }
                if (-not $launched.WaitForInputIdle(5000)) { throw 'AirPlay GUI did not become responsive.' }
            } finally { $launched.Dispose() }
        }
        $handle = Open-GodBrainAirPlayHandle $process.ProcessId
        Assert-GodBrainAirPlayProcess $process $handle
        Initialize-GodBrainAirPlayWindow
        $window = [GodBrain.AirPlayWindow]::Find([uint32]$process.ProcessId)
        if ($Action -eq 'Stop') {
            if (-not [GodBrain.AirPlayWindow]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
                $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "AirPlay did not accept its normal close request (Windows error $code). If the receiver is elevated, close it from its own window and start it normally."
            }
            if (-not $handle.WaitForExit(10000)) { throw 'AirPlay has not exited; no force kill was performed.' }
            return 'stopped (user app)'
        }
        $command = if ($Action -eq 'Open') { 9 } else { 6 }
        if (-not [GodBrain.AirPlayWindow]::ShowWindowAsync($window, $command)) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "AirPlay window action was refused (Windows error $code). If the receiver is elevated, close it from its own window and start it normally."
        }
        if ($Action -eq 'Open') { $null = [GodBrain.AirPlayWindow]::SetForegroundWindow($window) }
        return Get-GodBrainAirPlayLine
    } finally {
        if ($handle) { $handle.Dispose() }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
