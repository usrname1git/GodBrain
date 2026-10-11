function Get-GodBrainAirPlayExe { return 'C:\Tools\ShairportQt\ShairportQt.exe' }

function Get-GodBrainAirPlayProcess {
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $matches = @(Get-CimInstance Win32_Process -Filter "Name='ShairportQt.exe'" -OperationTimeoutSec 3 -ErrorAction Stop |
        Where-Object { $_.SessionId -eq $session })
    foreach ($process in $matches) {
        if (-not $process.ExecutablePath -or $process.ExecutablePath -ine (Get-GodBrainAirPlayExe)) {
            throw 'An unverified ShairportQt process is present in this session; AirPlay controls are closed.'
        }
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -OperationTimeoutSec 3 -ErrorAction Stop
        if ($owner.ReturnValue -ne 0 -or $owner.Sid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
            throw 'Could not verify AirPlay process ownership.'
        }
    }
    if ($matches.Count -gt 1) { throw 'Multiple ShairportQt instances are running; AirPlay controls are closed.' }
    if ($matches.Count) { return $matches[0] }
    return $null
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
        if ($ports.Count) { return "listening :$($ports -join ', :') (audio unverified)" }
        return 'running (no receiver listener)'
    } catch { return "unread: $($_.Exception.Message)" }
}

function Initialize-GodBrainAirPlayWindow {
    if ('GodBrain.AirPlayWindow' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace GodBrain {
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
        $handle = [Diagnostics.Process]::GetProcessById([int]$process.ProcessId)
        $null = $handle.Handle
        $created = $handle.StartTime.ToUniversalTime().Ticks
        $observed = $process.CreationDate.ToUniversalTime().Ticks
        if (($created - $created % 10) -ne ($observed - $observed % 10) -or
            $handle.MainModule.FileName -ine (Get-GodBrainAirPlayExe)) {
            throw 'AirPlay process identity changed before the operation.'
        }
        Initialize-GodBrainAirPlayWindow
        $window = [GodBrain.AirPlayWindow]::Find([uint32]$process.ProcessId)
        if ($Action -eq 'Stop') {
            if (-not [GodBrain.AirPlayWindow]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
                throw 'AirPlay did not accept its normal close request.'
            }
            if (-not $handle.WaitForExit(10000)) { throw 'AirPlay has not exited; no force kill was performed.' }
            return 'stopped (user app)'
        }
        $command = if ($Action -eq 'Open') { 9 } else { 6 }
        if (-not [GodBrain.AirPlayWindow]::ShowWindowAsync($window, $command)) {
            throw 'AirPlay window action was refused.'
        }
        if ($Action -eq 'Open') { $null = [GodBrain.AirPlayWindow]::SetForegroundWindow($window) }
        return Get-GodBrainAirPlayLine
    } finally {
        if ($handle) { $handle.Dispose() }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
