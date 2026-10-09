function Assert-DeskMonitorResult {
    param($Result, [string]$Control = "read", [string]$Value)
    if ($Result.schema_version -ne 1 -or $Result.ok -isnot [bool] -or -not $Result.ok) {
        throw "Invalid monitor helper response."
    }
    if ($Result.model -ne "Dell S2522HG" -or -not $Result.display) { throw "Unverified monitor identity." }
    foreach ($name in @("brightness", "contrast", "preset", "dark_stabilizer")) {
        $state = $Result.$name
        if (-not $state -or $state.supported -isnot [bool]) { throw "Missing monitor control state: $name" }
        if (-not $state.supported -and -not $state.error) { throw "Missing unsupported-control explanation: $name" }
        if ($state.supported) {
            $limit = if ($name -eq "dark_stabilizer") { 3 } elseif ($name -eq "preset") { 255 } else { 100 }
            if ($state.current -isnot [long] -and $state.current -isnot [int]) { throw "Invalid monitor value: $name" }
            if ($state.maximum -isnot [long] -and $state.maximum -isnot [int]) { throw "Invalid monitor maximum: $name" }
            if ($state.current -lt 0 -or $state.current -gt $limit -or $state.maximum -ne $limit) {
                throw "Invalid monitor range: $name"
            }
        }
    }
    $cycle = $Result.dark_stabilizer_cycle
    if (-not $cycle -or $cycle.supported -isnot [bool] -or
            $cycle.readback_available -isnot [bool] -or $cycle.readback_available -ne $false -or
            -not $cycle.PSObject.Properties["current"] -or $null -ne $cycle.current) {
        throw "Invalid Dark Stabilizer cycle capability/state."
    }
    if (-not $cycle.supported -and -not $cycle.error) { throw "Missing unsupported-cycle explanation." }
    $allowedPresets = @("standard", "game1", "comfortview", "game2", "game3", "fps", "rts", "rpg", "sports", "warm", "cool", "custom")
    if ($Result.presets -isnot [array] -or $Result.presets.Count -gt $allowedPresets.Count) {
        throw "Invalid monitor preset list."
    }
    $seen = @{}
    foreach ($preset in $Result.presets) {
        if ($preset.id -notin $allowedPresets -or $seen.ContainsKey([string]$preset.id) -or
                [string]::IsNullOrWhiteSpace($preset.name) -or $preset.name.Length -gt 48) {
            throw "Invalid monitor preset entry."
        }
        $seen[[string]$preset.id] = $true
    }
    if ($Control -eq "dark_stabilizer_cycle") {
        $action = $Result.action
        if (-not $cycle.supported -or $Result.changed -or $action.control -cne $Control -or
                $action.command_accepted -isnot [bool] -or $action.command_accepted -ne $true -or
                $action.state_verified -isnot [bool] -or $action.state_verified -ne $false -or
                -not $action.PSObject.Properties["current"] -or $null -ne $action.current) {
            throw "Invalid Dark Stabilizer cycle acceptance receipt."
        }
        foreach ($field in @("vcp_code", "value", "write_count")) {
            if ($action.$field -isnot [long] -and $action.$field -isnot [int]) {
                throw "Invalid Dark Stabilizer cycle command field: $field"
            }
        }
        if ($action.vcp_code -ne 0xE3 -or $action.value -ne 0x10 -or $action.write_count -ne 1) {
            throw "Invalid Dark Stabilizer cycle command."
        }
        return $Result
    }
    if ($Result.action -or ($Control -eq "read" -and $Result.changed)) { throw "Unexpected monitor action receipt." }
    if ($Control -ne "read" -and ($Result.changed.verified -isnot [bool] -or
            $Result.changed.verified -ne $true -or
            $Result.changed.control -cne $Control -or $Result.changed.requested -cne $Value)) {
        throw "Monitor helper did not verify the requested change."
    }
    if ($Control -eq "preset" -and $Result.preset.id -cne $Value) { throw "Monitor preset readback does not match the request." }
    if ($Control -notin @("read", "preset") -and
            (-not $Result.$Control.supported -or $Result.$Control.current -ne [long]$Value)) {
        throw "Monitor control readback does not match the request."
    }
    return $Result
}

function Invoke-DeskMonitor {
    [CmdletBinding()]
    param(
        [ValidateSet("read", "brightness", "contrast", "preset", "dark_stabilizer", "dark_stabilizer_cycle")]
        [string]$Control = "read",
        [string]$Value,
        [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 15
    )
    if ($Control -eq "dark_stabilizer_cycle" -and -not [string]::IsNullOrEmpty($Value)) {
        throw "Dark Stabilizer cycling takes no level or value."
    }
    $exe = Join-Path $RepoRoot "godbrain_core\cpp_tools\desk-monitor.exe"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Monitor helper is missing. Run scripts\Build-DeskMonitor.ps1 once."
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $exe
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($Control -eq "read") { $info.ArgumentList.Add("--read") }
    elseif ($Control -eq "dark_stabilizer_cycle") { $info.ArgumentList.Add("--cycle-dark") }
    else {
        $info.ArgumentList.Add("--set")
        $info.ArgumentList.Add($Control)
        $info.ArgumentList.Add($Value)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    $mayHaveCycled = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw "Monitor helper did not start." }
        $mayHaveCycled = $Control -eq "dark_stabilizer_cycle"
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(100)) {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $detail = if ($Control -eq "read") { "No settings change was requested." }
                    elseif ($Control -eq "dark_stabilizer_cycle") { "No automatic retry will be made." }
                    else { "A requested change may have reached the monitor; refresh before retrying." }
                throw "Monitor operation (PID $($process.Id)) timed out. $detail"
            }
        }
        if (-not $stdout.Wait(2000) -or -not $stderr.Wait(2000)) { throw "Monitor helper output did not close." }
        if ($stdout.Result.Length -gt 32768) { throw "Monitor helper response is too large." }
        $result = $stdout.Result | ConvertFrom-Json -ErrorAction Stop
        if ($result.schema_version -ne 1 -or $result.ok -isnot [bool]) { throw "Invalid monitor helper response." }
        if ($process.ExitCode -ne 0 -or -not $result.ok) {
            $message = if ($result.error) { [string]$result.error } else { "Monitor helper failed: exit $($process.ExitCode)" }
            if ($result.may_have_changed -is [bool] -and -not $result.may_have_changed) { $mayHaveCycled = $false }
            if ($result.may_have_changed -and $Control -ne "dark_stabilizer_cycle") {
                $message += ". Settings may have changed; refresh before retrying."
            }
            throw $message
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr.Result)) { throw "Monitor helper reported: $($stderr.Result.Trim())" }
        return Assert-DeskMonitorResult -Result $result -Control $Control -Value $Value
    } catch {
        if ($mayHaveCycled) {
            throw "$($_.Exception.Message) The cycle may have reached the monitor; current level is unavailable. Observe the picture before pressing again. No automatic retry was made."
        }
        throw
    } finally {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill()
                # A pending display-driver call can delay completion of TerminateProcess.
                if (-not $process.WaitForExit(10000)) {
                    throw "Owned monitor helper PID $($process.Id) was terminated but has not exited; display-driver I/O is still pending."
                }
            }
        } finally {
            $process.Dispose()
        }
    }
}
