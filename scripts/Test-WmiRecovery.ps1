[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-WmiRecovery.ps1')
$script:admin = $true
$script:probeFails = $false
$script:probeCalls = 0
$script:operations = [Collections.Generic.List[string]]::new()
$script:lastReceipt = $null
$script:receiptFails = $false
function Test-WmiRecoveryAdministrator { $script:admin }
function Write-WmiRecoveryReceipt($Receipt, $Path) {
    if ($script:receiptFails) { throw 'Fixture receipt persistence failure.' }
    $script:lastReceipt = $Receipt.Clone()
}
function Get-Service { param($Name, $ErrorAction); $script:root }
function Get-CimInstance {
    param($ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
    $script:probeCalls++
    if ($ClassName -ne 'Win32_Service' -or $Filter -ne "Name='winmgmt'") { throw 'Unexpected probe.' }
    if ($script:probeFails) { throw 'Fixture CIM timeout.' }
    @{ Name = 'winmgmt'; State = 'Running' }
}
function New-Controller($Name, $State, $Children = @()) {
    $value = [pscustomobject]@{
        ServiceName = $Name; Status = $State; DependentServices = $Children; FailStart = $false; FailStop = $false
    }
    $value | Add-Member ScriptMethod Refresh {}
    $value | Add-Member ScriptMethod Dispose {}
    $value | Add-Member ScriptMethod Start {
        $script:operations.Add("start:$($this.ServiceName)")
        if ($this.FailStart) { throw "Fixture start $($this.ServiceName)" }
        $this.Status = 'Running'
    }
    $value | Add-Member ScriptMethod Stop {
        $script:operations.Add("stop:$($this.ServiceName)")
        if ($this.FailStop) { throw "Fixture stop $($this.ServiceName)" }
        $this.Status = 'Stopped'
    }
    $value | Add-Member ScriptMethod WaitForStatus {
        param($Expected, $Timeout)
        if ($this.Status -ne $Expected.ToString()) { throw "Fixture wait $($this.ServiceName)" }
    }
    $value
}
function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure: $Pattern"
}
function Run-Recovery([switch]$Restart) {
    Invoke-WmiRecovery -Restart:$Restart -ReceiptPath 'fixture'
}
$script:root = New-Controller winmgmt Running
Assert-Equal (Run-Recovery).action check
Assert-Equal $script:operations.Count 0
$script:root.Status = 'Stopped'
Assert-Equal (Run-Recovery).action start
Assert-Equal ($script:operations -join ',') 'start:winmgmt'
$script:operations.Clear()
$leaf = New-Controller child Running
$parent = New-Controller parent Running @($leaf)
$sibling = New-Controller sibling Running
$stopped = New-Controller untouched Stopped
$script:root = New-Controller winmgmt Running @($parent, $sibling, $stopped)
$receipt = Run-Recovery -Restart
Assert-Equal $receipt.query_verified $true
Assert-Equal ($script:operations -join ',') 'stop:child,stop:parent,stop:sibling,stop:winmgmt,start:winmgmt,start:sibling,start:parent,start:child'
Assert-Equal $stopped.Status Stopped
$script:operations.Clear()
$parent.FailStart = $true
Assert-Throws { Run-Recovery -Restart } '*Restore parent failed*'
Assert-Equal $script:lastReceipt.status failed
Assert-Equal $script:lastReceipt.service_running $true
Assert-Equal ($script:operations -contains 'start:child') $true
Assert-Equal ($script:operations -contains 'start:sibling') $true
$parent.FailStart = $false
$parent.Status = 'Running'
$script:operations.Clear()
$leaf.FailStop = $true
Assert-Throws { Run-Recovery -Restart } '*Restart failed*'
Assert-Equal $script:root.Status Running
Assert-Equal ($script:operations -contains 'stop:winmgmt') $false
$leaf.FailStop = $false
$script:probeFails = $true
Assert-Throws { Run-Recovery } '*Fixture CIM timeout*'
Assert-Equal $script:lastReceipt.query_verified $false
$script:receiptFails = $true
Assert-Throws { Run-Recovery } '*Fixture CIM timeout*Fixture receipt persistence failure*'
$script:receiptFails = $false
$script:probeFails = $false
$script:root.Status = 'StartPending'
$script:operations.Clear()
$bounded = New-Controller winmgmt Running @(1..33 | ForEach-Object { New-Controller "bounded$_" Stopped })
$script:root = $bounded
Assert-Throws { Run-Recovery -Restart } '*More than 32 WMI dependents*'
Assert-Equal $script:operations.Count 0
$script:root.Status = 'StartPending'
Assert-Throws { Run-Recovery } '*no competing service transition*'
$script:admin = $false
Assert-Throws { Run-Recovery } '*administrative SSH*'
'PASS: SCM start/no-op, opt-in restart, transitive stop/restore order, all restoration attempts, stopped-dependent preservation, failure receipts, probe/transition/elevation failures. No host services changed.'
