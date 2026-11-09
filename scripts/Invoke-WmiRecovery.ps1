#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Restart,
    [ValidateRange(1, 60)][int]$TimeoutSec = 10,
    [ValidateRange(1, 15)][int]$ProbeTimeoutSec = 3,
    [string]$ReceiptPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\last-wmi-recovery.json')
)

$ErrorActionPreference = 'Stop'

function Test-WmiRecoveryAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
}

function Write-WmiRecoveryReceipt([hashtable]$Receipt, [string]$Path) {
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Receipt | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-WmiRunningDependents($Controller) {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ordered = [Collections.Generic.List[object]]::new()
    $opened = [Collections.Generic.List[object]]::new()
    $complete = $false
    function Visit-WmiDependent($Service) {
        foreach ($child in $Service.DependentServices) {
            if (-not $seen.Add($child.ServiceName)) { continue }
            $opened.Add($child)
            if ($opened.Count -gt 32) { throw 'More than 32 WMI dependents; no service changes performed.' }
            $child.Refresh()
            if ($child.Status -notin @('Running', 'Stopped')) {
                throw "Dependent $($child.ServiceName) is $($child.Status); retry after its transition."
            }
            Visit-WmiDependent $child
            if ($child.Status -eq 'Running') { $ordered.Add($child) }
        }
    }
    try {
        Visit-WmiDependent $Controller
        $complete = $true
        return $ordered.ToArray()
    } finally {
        foreach ($child in $opened) {
            if (-not $complete -or $child -notin $ordered) { $child.Dispose() }
        }
    }
}

function Test-WmiServiceQuery([int]$Timeout) {
    $probe = Get-CimInstance Win32_Service -Filter "Name='winmgmt'" -OperationTimeoutSec $Timeout -ErrorAction Stop
    if (@($probe).Count -ne 1 -or $probe.Name -ne 'winmgmt' -or $probe.State -ne 'Running') {
        throw 'The WMI service-query probe did not return the running winmgmt service.'
    }
}

function Restore-WmiRunningService($Controller, [int]$TimeoutSec) {
    $Controller.Refresh()
    if ($Controller.Status -eq 'StopPending') {
        $Controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds($TimeoutSec))
        $Controller.Refresh()
    }
    if ($Controller.Status -eq 'Stopped') { $Controller.Start() }
    $Controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds($TimeoutSec))
}

function Invoke-WmiRecovery {
    param([switch]$Restart, [int]$TimeoutSec = 10, [int]$ProbeTimeoutSec = 3, [string]$ReceiptPath)
    if (-not (Test-WmiRecoveryAdministrator)) {
        throw 'WMI recovery requires an administrative SSH session; no remote UAC prompt is attempted.'
    }
    $provider = $null
    $drive = $null
    $ReceiptPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $ReceiptPath, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw 'The recovery receipt must use a filesystem path.' }
    $receipt = @{
        at = [DateTimeOffset]::UtcNow.ToString('o')
        status = 'running'; action = 'check'; service_running = $null; query_verified = $false
        running_dependents = @(); restored_dependents = @(); errors = @()
    }
    $controller = $null
    $dependents = @()
    $mutex = [Threading.Mutex]::new($false, 'Global\GodBrain.WmiRecovery.v1')
    $locked = $false
    $problems = [Collections.Generic.List[string]]::new()
    $failure = $null
    try {
        try { $locked = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another WMI recovery has not finished within 30 seconds.' }
        $controller = Get-Service -Name winmgmt -ErrorAction Stop
        $controller.Refresh()
        if ($controller.Status -notin @('Running', 'Stopped')) {
            throw "WMI is $($controller.Status); no competing service transition was started."
        }
        if ($Restart -and $controller.Status -eq 'Running') {
            $receipt.action = 'restart'
            $dependents = @(Get-WmiRunningDependents $controller)
            $receipt.running_dependents = @($dependents | ForEach-Object ServiceName)
            try {
                foreach ($service in $dependents) {
                    $service.Stop()
                    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds($TimeoutSec))
                }
                $controller.Stop()
                $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds($TimeoutSec))
                $controller.Start()
                $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds($TimeoutSec))
            } catch { $problems.Add("Restart failed: $($_.Exception.Message)") }
            finally {
                try {
                    Restore-WmiRunningService $controller $TimeoutSec
                } catch { $problems.Add("WMI restoration failed: $($_.Exception.Message)") }
                for ($index = $dependents.Count - 1; $index -ge 0; $index--) {
                    $service = $dependents[$index]
                    try {
                        Restore-WmiRunningService $service $TimeoutSec
                        $receipt.restored_dependents += $service.ServiceName
                    } catch { $problems.Add("Restore $($service.ServiceName) failed: $($_.Exception.Message)") }
                }
            }
            if ($problems.Count) { throw ($problems -join '; ') }
        } elseif ($controller.Status -eq 'Stopped') {
            $receipt.action = 'start'
            $controller.Start()
            $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds($TimeoutSec))
        }
        $controller.Refresh()
        if ($controller.Status -ne 'Running') { throw 'SCM did not confirm WMI running.' }
        $receipt.service_running = $true
        Test-WmiServiceQuery $ProbeTimeoutSec
        $receipt.query_verified = $true
        $receipt.status = 'ready'
        return $receipt
    } catch {
        $failure = $_.Exception
        $receipt.status = 'failed'
        $receipt.errors = @($_.Exception.Message)
        if ($controller) {
            try {
                $controller.Refresh()
                $receipt.service_running = $controller.Status -eq 'Running'
            } catch {
                $receipt.service_running = $null
                $receipt.errors += "Final SCM read failed: $($_.Exception.Message)"
            }
        }
        throw
    } finally {
        $receipt.at = [DateTimeOffset]::UtcNow.ToString('o')
        try { Write-WmiRecoveryReceipt $receipt $ReceiptPath }
        catch {
            if ($failure) {
                throw [AggregateException]::new('Recovery and receipt persistence failed.',
                    [Exception[]]@($failure, $_.Exception))
            }
            throw
        }
        finally {
            foreach ($service in $dependents) { $service.Dispose() }
            if ($controller) { $controller.Dispose() }
            if ($locked) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-WmiRecovery -Restart:$Restart -TimeoutSec $TimeoutSec -ProbeTimeoutSec $ProbeTimeoutSec -ReceiptPath $ReceiptPath
    "WMI ready: service Running; service-query probe passed; action=$($result.action)."
}
