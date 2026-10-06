function Get-GodBrainRustDeskExe {
    $path = Join-Path $env:ProgramFiles "RustDesk\rustdesk.exe"
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-GodBrainRustDeskProcesses {
    $exe = Get-GodBrainRustDeskExe
    if (-not $exe) { return @() }
    return @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -OperationTimeoutSec 3 -ErrorAction Stop |
        Where-Object { $_.ExecutablePath -eq $exe })
}

function Start-GodBrainRustDeskApp {
    if (@(Get-GodBrainRustDeskProcesses).Count -gt 0) { return }
    $exe = Get-GodBrainRustDeskExe
    if (-not $exe) { throw "RustDesk is not installed at the known Program Files location." }
    $process = Start-Process -FilePath $exe -WindowStyle Minimized -PassThru
    $deadline = (Get-Date).AddSeconds(3)
    do {
        if (@(Get-GodBrainRustDeskProcesses).Count -gt 0) { return }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw "RustDesk launch did not produce a running installed app (launcher pid=$($process.Id))."
}

function Invoke-GodBrainRustDeskStopOption {
    param([switch]$Clear)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Get-GodBrainRustDeskExe
    if (-not $info.FileName) { throw "RustDesk is not installed." }
    $info.Arguments = if ($Clear) { '--option stop-service ""' } else { "--option stop-service" }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "Could not start the RustDesk service-option command." }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
            $null = $process.WaitForExit(3000)
            throw "RustDesk service-option command timed out."
        }
        $output = $stdout.GetAwaiter().GetResult().Trim()
        $errorText = $stderr.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0 -or $errorText -or $output -notin @("", "Y", "N")) {
            throw "RustDesk rejected its service-option command; an administrative SSH account and enabled CLI settings are required."
        }
        return $output
    } finally {
        $process.Dispose()
    }
}

function Test-GodBrainRustDeskBackend {
    $service = Get-CimInstance Win32_Service -Filter "Name='RustDesk'" -OperationTimeoutSec 3 -ErrorAction Stop
    if (-not $service -or $service.State -ne "Running" -or $service.ProcessId -le 0) { return $false }
    $expected = '"' + (Get-GodBrainRustDeskExe) + '" --service'
    if ($service.PathName.Trim() -ine $expected) { throw "RustDesk service uses an unexpected executable or arguments." }
    foreach ($process in @(Get-GodBrainRustDeskProcesses)) {
        if ($process.ParentProcessId -ne $service.ProcessId -or
            $process.CommandLine -notmatch "(?:^|\s)--server(?:\s|$)") { continue }
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -OperationTimeoutSec 3 -ErrorAction Stop
        if ($owner.ReturnValue -ne 0) { throw "Could not verify RustDesk backend ownership." }
        if ($owner.Sid -eq "S-1-5-18") { return $true }
    }
    return $false
}

function Test-GodBrainRustDeskAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally {
        $identity.Dispose()
    }
}

function Start-GodBrainRustDeskBackend {
    param([switch]$RegisterIfMissing)
    if (-not (Test-GodBrainRustDeskAdministrator)) {
        throw "RustDesk Start requires an administrative SSH session or PowerShell run as administrator."
    }
    $exe = Get-GodBrainRustDeskExe
    if (-not $exe) { throw "RustDesk is not installed at the known Program Files location." }
    $expected = '"' + $exe + '" --service'
    $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='RustDesk'" -OperationTimeoutSec 3 -ErrorAction Stop
    if (-not $serviceInfo) {
        if (-not $RegisterIfMissing) {
            throw "RustDesk Windows service is not installed. Explicit scripts\Start-RustDesk.ps1 can restore its registration."
        }
        # RustDesk's installer also adds logon startup and image-name-wide process kills.
        $created = New-Service -Name RustDesk -BinaryPathName $expected -DisplayName "RustDesk Service" `
            -Description "RustDesk remote-desktop service" -StartupType Manual -ErrorAction Stop
        if ($created) { $created.Dispose() }
        $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='RustDesk'" -OperationTimeoutSec 3 -ErrorAction Stop
        if (-not $serviceInfo) { throw "RustDesk service registration did not create the expected Windows service." }
        Write-Host "Registered RustDesk Windows service (Manual startup)."
    }
    if ($serviceInfo.PathName.Trim() -ine $expected) { throw "RustDesk service uses an unexpected executable or arguments." }
    $service = Get-Service -Name RustDesk -ErrorAction Stop
    try {
        if ($service.Status -eq [ServiceProcess.ServiceControllerStatus]::StopPending) {
            $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(10))
        }
        if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Running) {
            if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::StartPending) { $service.Start() }
            $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(10))
        }
    } finally {
        $service.Dispose()
    }
    if ((Invoke-GodBrainRustDeskStopOption) -eq "Y") {
        $null = Invoke-GodBrainRustDeskStopOption -Clear
    }
    if ((Invoke-GodBrainRustDeskStopOption) -eq "Y") { throw "RustDesk is still configured to stop its service." }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    do {
        if (Test-GodBrainRustDeskBackend) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "RustDesk Windows service started, but its remote-desktop backend did not become ready."
}

function Stop-GodBrainRustDeskApp {
    foreach ($process in @(Get-GodBrainRustDeskProcesses)) {
        Stop-Cs2OwnedProcess $process
    }
}
