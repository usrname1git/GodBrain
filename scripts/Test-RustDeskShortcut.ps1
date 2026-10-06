[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("GodBrain-RustDesk-test-" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path (Join-Path $fixture "logs") -Force
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
try {
    & {
        . (Join-Path $PSScriptRoot "GodBrain-HostServices.ps1")
        $script:exe = "C:\Program Files\RustDesk\rustdesk.exe"
        $script:serviceInfo = $null
        $script:processes = @()
        $script:systemOwned = $true
        $script:administrator = $true
        $script:registrations = 0
        $script:registrationFails = $false
        $script:registrationMissing = $false
        function Test-GodBrainRustDeskAdministrator { return $script:administrator }
        function Get-GodBrainRustDeskExe { return $script:exe }
        function New-Service {
            param($Name, $BinaryPathName, $DisplayName, $Description, $StartupType, $ErrorAction)
            $script:registrations++
            if ($script:registrationFails) { throw "Fixture registration failed." }
            Assert-Equal $Name "RustDesk"
            Assert-Equal $BinaryPathName ('"' + $script:exe + '" --service')
            Assert-Equal $StartupType "Manual"
            Assert-Equal $DisplayName "RustDesk Service"
            if (-not $script:registrationMissing) {
                $script:serviceInfo = @{ State = "Stopped"; ProcessId = 90; PathName = $BinaryPathName }
            }
            return $script:controller
        }
        function Get-CimInstance {
            param($ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
            if ($ClassName -eq "Win32_Service") { return $script:serviceInfo }
            return $script:processes
        }
        function Invoke-CimMethod {
            param($InputObject, $MethodName, $OperationTimeoutSec, $ErrorAction)
            return @{ ReturnValue = 0; Sid = $(if ($script:systemOwned) { "S-1-5-18" } else { "S-1-5-21-123" }) }
        }
        Assert-Equal (Test-GodBrainRustDeskBackend) $false
        Assert-Throws { Start-GodBrainRustDeskBackend } "*not installed*restore its registration*"
        Assert-Equal $script:registrations 0
        $script:administrator = $false
        Assert-Throws { Start-GodBrainRustDeskBackend -RegisterIfMissing } "*administrative SSH*"
        Assert-Equal $script:registrations 0
        $script:administrator = $true
        $script:exe = $null
        Assert-Throws { Start-GodBrainRustDeskBackend -RegisterIfMissing } "*not installed*Program Files*"
        Assert-Equal $script:registrations 0
        $script:exe = "C:\Program Files\RustDesk\rustdesk.exe"
        $script:serviceInfo = @{
            State = "Running"; ProcessId = 90; PathName = '"' + $script:exe + '" --service'
        }
        $script:processes = @(@{
            ProcessId = 91; ExecutablePath = $script:exe
            ParentProcessId = 90; CommandLine = '"' + $script:exe + '" --server'
        })
        Assert-Equal (Test-GodBrainRustDeskBackend) $true
        $script:processes[0].ParentProcessId = 999
        Assert-Equal (Test-GodBrainRustDeskBackend) $false
        $script:processes[0].ParentProcessId = 90
        $script:systemOwned = $false
        Assert-Equal (Test-GodBrainRustDeskBackend) $false
        $script:systemOwned = $true
        $script:serviceInfo.State = "Stopped"
        Assert-Equal (Test-GodBrainRustDeskBackend) $false
        $script:serviceInfo.State = "Running"
        $script:processes[0].CommandLine = '"' + $script:exe + '" --tray'
        Assert-Equal (Test-GodBrainRustDeskBackend) $false
        $script:processes[0].CommandLine = '"' + $script:exe + '" --server'
        $script:serviceInfo.PathName = '"C:\Temp\other.exe" --service'
        Assert-Throws { Test-GodBrainRustDeskBackend } "*unexpected executable*"
        $script:serviceInfo.PathName = '"' + $script:exe + '" --service'

        $script:controller = [pscustomobject]@{ Status = "Stopped" }
        $script:serviceStarts = 0
        $script:controller | Add-Member ScriptMethod Start {
            $script:serviceStarts++
            $this.Status = "Running"
            $script:serviceInfo.State = "Running"
        }
        $script:controller | Add-Member ScriptMethod WaitForStatus { param($Status, $Timeout) }
        $script:controller | Add-Member ScriptMethod Dispose {}
        function Get-Service { param($Name, $ErrorAction); return $script:controller }
        $script:stopOption = "Y"
        $script:clears = 0
        function Invoke-GodBrainRustDeskStopOption {
            param([switch]$Clear)
            if ($Clear) { $script:clears++; $script:stopOption = "" }
            return $script:stopOption
        }
        Start-GodBrainRustDeskBackend
        Assert-Equal $script:serviceStarts 1
        Assert-Equal $script:clears 1
        Start-GodBrainRustDeskBackend
        Assert-Equal $script:serviceStarts 1
        Assert-Equal $script:clears 1
        $script:serviceInfo = $null
        $script:controller.Status = "Stopped"
        $script:registrationFails = $true
        Assert-Throws { Start-GodBrainRustDeskBackend -RegisterIfMissing } "*Fixture registration failed*"
        Assert-Equal $script:serviceStarts 1
        $script:registrationFails = $false
        $script:registrationMissing = $true
        Assert-Throws { Start-GodBrainRustDeskBackend -RegisterIfMissing } "*registration did not create*"
        Assert-Equal $script:serviceStarts 1
        $script:registrationMissing = $false
        Start-GodBrainRustDeskBackend -RegisterIfMissing
        Assert-Equal $script:serviceStarts 2
        $registrations = $script:registrations
        Start-GodBrainRustDeskBackend -RegisterIfMissing
        Assert-Equal $script:registrations $registrations
        Assert-Equal $script:serviceStarts 2
        function Invoke-GodBrainRustDeskStopOption { param([switch]$Clear); return "Y" }
        Assert-Throws { Start-GodBrainRustDeskBackend } "*still configured to stop*"
    }
    & {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot "Start-RustDesk.ps1"), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors -join "`n") }
        foreach ($statement in $ast.EndBlock.Statements) {
            if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
                . ([scriptblock]::Create($statement.Extent.Text))
            }
        }
        $repo = $fixture
        $receiptPath = Join-Path $fixture "logs\last-rustdesk-start.json"
        $script:game = $false
        $script:ready = $true
        $script:stopped = ""
        $script:starts = 0
        $script:registrationRequested = $false
        $script:lateGame = $false
        function Get-Process { param($Name, $ErrorAction); if ($script:game) { return @{ Id = 99 } } }
        function Start-GodBrainRustDeskBackend {
            param([switch]$RegisterIfMissing)
            $script:registrationRequested = [bool]$RegisterIfMissing
            $script:starts++
            if ($script:lateGame) { $script:game = $true }
        }
        function Test-GodBrainRustDeskBackend { return $script:ready }
        function Invoke-GodBrainRustDeskStopOption { return $script:stopped }
        Assert-Equal (Invoke-RustDeskShortcutLaunch) "RustDesk remote-desktop service ready."
        Assert-Equal $script:registrationRequested $true
        $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
        Assert-Equal $receipt.status "ok"
        Assert-Equal $receipt.backend_ready $true
        Assert-Equal (Get-Content -LiteralPath (Join-Path $repo "logs\rustdesk-pause.txt")) "off"
        $script:game = $true
        $before = $script:starts
        Assert-Throws { Invoke-RustDeskShortcutLaunch } "*CS2 is running*"
        Assert-Equal $script:starts $before
        $script:game = $false
        $script:ready = $false
        Assert-Throws { Invoke-RustDeskShortcutLaunch } "*backend is not ready*"
        Assert-Equal (Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json).backend_ready $false
        $script:ready = $true
        $script:stopped = "Y"
        Assert-Throws { Invoke-RustDeskShortcutLaunch } "*backend is not ready*"
        $script:stopped = ""
        $script:lateGame = $true
        Set-Content -LiteralPath (Join-Path $repo "logs\rustdesk-pause.txt") -Value "on"
        Assert-Throws { Invoke-RustDeskShortcutLaunch } "*CS2 is running*"
        Assert-Equal (Get-Content -LiteralPath (Join-Path $repo "logs\rustdesk-pause.txt")) "on"
    }
    Write-Output "PASS: explicit missing-service registration, administrator gate, idempotent start, SYSTEM backend identity, CS2 and fail-closed receipts."
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
