[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DeskFixtureWindow {
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLong(IntPtr window, int index);
}
'@
$exe = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\desk_shell\desk-shell.exe'
. (Join-Path $PSScriptRoot 'GodBrain-DeskShell.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('Desk shell fixture ' + [guid]::NewGuid().ToString('N'))
function Native([string]$Mode, [string[]]$Options = @()) {
    Invoke-DeskShell -Operation $Mode -Options $Options -IdentityRoot $root
}
$event = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, "Local\GodBrain.Desk.Show.$PID")
$first = [Windows.Forms.Form]::new()
$second = [Windows.Forms.Form]::new()
$legacy = [Windows.Forms.Form]::new()
try {
    $first.Text = 'Isolated Desk shell fixture'
    $second.Text = 'Isolated second Desk fixture'
    $null = $first.Handle
    $null = $second.Handle
    $a = Native info
    $b = Invoke-DeskShell -Operation info -IdentityRoot $root.ToUpperInvariant()
    if ($a.app_id -cne $b.app_id) { throw 'Case-folded identity changed.' }
    if ((Native activate).status -ne 'absent') { throw 'Uncreated fixture was found.' }
    $null = Native attach @($first.Handle.ToInt64().ToString())
    $null = Native attach @($second.Handle.ToInt64().ToString(), '--secondary')
    $first.Show()
    [Windows.Forms.Application]::DoEvents()
    $first.Hide()
    $first.ShowInTaskbar = $false
    $null = Native attach @($first.Handle.ToInt64().ToString())
    foreach ($index in 1..3) {
        $reply = Native activate
        if ($reply.status -ne 'shown' -or $reply.pid -ne $PID -or -not $event.WaitOne(0)) {
            throw 'Existing-window activation did not signal the exact owner.'
        }
        $first.ShowInTaskbar = $true
        $first.Show()
        [Windows.Forms.Application]::DoEvents()
        $null = Native attach @($first.Handle.ToInt64().ToString())
    }
    if ((Native launch).status -ne 'shown') { throw 'Default launch created a fixture process instead of reusing.' }
    if (-not $event.WaitOne(0)) { throw 'Default launch did not use the show signal.' }
    $first.Dispose()
    $second.Dispose()
    $event.Dispose()
    $legacy.Text = 'Isolated eventless legacy fixture'
    $legacy.Show()
    $legacy.Hide()
    $legacy.ShowInTaskbar = $false
    $null = Native attach @($legacy.Handle.ToInt64().ToString())
    $owner = [DeskFixtureWindow]::GetWindowLong($legacy.Handle, -8)
    $reply = Native activate
    [Windows.Forms.Application]::DoEvents()
    if ($reply.signal -ne $false -or -not [DeskFixtureWindow]::IsWindowVisible($legacy.Handle) -or
        [DeskFixtureWindow]::GetWindowLong($legacy.Handle, -8) -ne $owner -or
        -not ([DeskFixtureWindow]::GetWindowLong($legacy.Handle, -20).ToInt64() -band 0x40000)) {
        throw 'Eventless legacy restoration did not retain the framework owner and restore its taskbar window.'
    }
    'PASS: native owner-bound identity, case stability, hidden/repeated activation, secondary/default reuse and eventless legacy parking-owner preservation. Isolated Windows forms only; no pin/service/model changes.'
} finally {
    $first.Dispose()
    $second.Dispose()
    $legacy.Dispose()
    $event.Dispose()
}
