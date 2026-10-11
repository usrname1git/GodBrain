function Assert-DisplayProfileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 64 -or $Name -cne $Name.Trim() -or
            $Name -match '[\x00-\x1f\x7f<>:"/\\|?*]') {
        throw "Profile names must contain 1-64 characters without outer spaces, control or path characters."
    }
}

function Assert-DisplayProfileSummary {
    param($Profile)
    if ($Profile.name -isnot [string]) { throw "Invalid display-profile name type." }
    Assert-DisplayProfileName $Profile.name
    if (($Profile.hotkey -isnot [int] -and $Profile.hotkey -isnot [long]) -or $Profile.hotkey -lt 0 -or $Profile.hotkey -gt 12 -or
            $Profile.displays -isnot [array] -or $Profile.displays.Count -lt 1 -or $Profile.displays.Count -gt 16) {
        throw "Invalid display-profile summary."
    }
    $primary = $false
    foreach ($display in $Profile.displays) {
        if ($display.label -isnot [string] -or [string]::IsNullOrWhiteSpace($display.label) -or $display.label.Length -gt 256 -or $display.primary -isnot [bool]) {
            throw "Invalid display-profile monitor identity."
        }
        foreach ($field in @("width", "height", "x", "y", "rotation")) {
            if ($display.$field -isnot [int] -and $display.$field -isnot [long]) { throw "Invalid display-profile field: $field" }
        }
        if ($display.width -lt 1 -or $display.width -gt 32768 -or $display.height -lt 1 -or $display.height -gt 32768 -or
                [Math]::Abs([long]$display.x) -gt 131072 -or [Math]::Abs([long]$display.y) -gt 131072 -or
                $display.rotation -lt 1 -or $display.rotation -gt 4 -or
                ($display.refresh_hz -isnot [double] -and $display.refresh_hz -isnot [int] -and $display.refresh_hz -isnot [long]) -or
                -not [double]::IsFinite([double]$display.refresh_hz) -or $display.refresh_hz -le 0 -or
                $display.primary -ne ($display.x -eq 0 -and $display.y -eq 0)) {
            throw "Invalid display-profile dimensions, origin or refresh rate."
        }
        $primary = $primary -or $display.primary
    }
    if (-not $primary) { throw "Display profile has no primary monitor." }
}

function Assert-DisplayProfileResult {
    param($Result, [string]$Operation, [string]$Name)
    if ($Result.schema_version -ne 1 -or $Result.ok -isnot [bool] -or -not $Result.ok -or $Result.operation -cne $Operation) {
        $kind = if ($null -eq $Result) { "null" } else { $Result.GetType().Name }
        throw "Invalid display-profile helper response (expected $Operation, received $($Result.operation), schema $($Result.schema_version), ok $($Result.ok), type $kind)."
    }
    if ($Operation -eq "list") {
        if ($Result.profiles -isnot [array] -or $Result.profiles.Count -gt 32 -or $Result.recovery_pending -isnot [bool]) {
            throw "Invalid display-profile list."
        }
        $names = @{}; $hotkeys = @{}
        foreach ($profile in $Result.profiles) {
            Assert-DisplayProfileSummary $profile
            if ($names.ContainsKey($profile.name) -or ($profile.hotkey -gt 0 -and $hotkeys.ContainsKey([int]$profile.hotkey))) {
                throw "Duplicate display-profile name or hotkey."
            }
            $names[$profile.name] = $true
            if ($profile.hotkey -gt 0) { $hotkeys[[int]$profile.hotkey] = $true }
        }
    } elseif ($Operation -eq "recover") {
        if ($Result.verified -isnot [bool] -or -not $Result.verified -or $Result.outcome -cne "restored") {
            throw "Display-profile recovery was not verified."
        }
    } elseif ($Operation -eq "delete") {
        if ($Result.deleted -cne $Name) { throw "Display-profile deletion receipt mismatch." }
    } else {
        Assert-DisplayProfileSummary $Result.profile
        if ($Operation -ne "current" -and $Result.profile.name -ine $Name) { throw "Display-profile receipt name mismatch." }
        if ($Operation -eq "preview" -and ($Result.validated -isnot [bool] -or -not $Result.validated)) {
            throw "Display-profile preview was not validated."
        }
        if ($Operation -eq "apply" -and ($Result.verified -isnot [bool] -or -not $Result.verified -or
                $Result.outcome -cnotin @("kept", "reverted") -or
                $Result.confirmation -cnotin @("keep", "saved_profile", "revert", "closed", "timeout", "owner_exit") -or
                ($Result.outcome -ceq "kept") -ne ($Result.confirmation -cin @("keep", "saved_profile")))) {
            throw "Display-profile switch was not verified."
        }
    }
    return $Result
}

function Invoke-DisplayProfiles {
    [CmdletBinding()]
    param(
        [ValidateSet("list", "current", "save", "preview", "apply", "hotkey", "delete", "recover")]
        [string]$Operation = "list",
        [string]$Name,
        [ValidateRange(0, 12)][int]$Hotkey = 0,
        [switch]$Overwrite,
        [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
    )
    if ($Operation -in @("save", "preview", "apply", "hotkey", "delete")) { Assert-DisplayProfileName $Name }
    if ($Overwrite -and $Operation -ne "save") { throw "Overwrite applies only to Save current layout." }
    $exe = Join-Path $RepoRoot "godbrain_core\cpp_tools\display-profiles.exe"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Display-profile helper is missing. Run scripts\Build-DisplayProfiles.ps1 first." }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $exe
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.ArgumentList.Add("--$Operation")
    if ($Operation -in @("save", "preview", "apply", "hotkey", "delete")) { $info.ArgumentList.Add($Name) }
    if ($Overwrite) { $info.ArgumentList.Add("--overwrite") }
    if ($Operation -eq "hotkey") { $info.ArgumentList.Add([string]$Hotkey) }
    if ($Operation -eq "apply") {
        $info.ArgumentList.Add("--owner")
        $info.ArgumentList.Add([string][Environment]::ProcessId)
        $info.ArgumentList.Add("--no-confirm")
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw "Display-profile helper did not start." }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $timeout = if ($Operation -in @("apply", "recover")) { 90 } else { 30 }
        while (-not $process.WaitForExit(100)) {
            if ($watch.Elapsed.TotalSeconds -ge $timeout) {
                throw "Display-profile helper PID $($process.Id) timed out. If a switch was interrupted, use Recover previous layout; restoration is not proven."
            }
        }
        if (-not $stdout.Wait(2000) -or -not $stderr.Wait(2000) -or $stdout.Result.Length -gt 1048576) {
            throw "Display-profile output did not close or exceeds its bound."
        }
        $result = $stdout.Result | ConvertFrom-Json -ErrorAction Stop
        if ($process.ExitCode -ne 0 -or $result.ok -ne $true) {
            if (-not $result.error) { throw "Display-profile helper failed without an error receipt." }
            throw [string]$result.error
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr.Result)) { throw "Display-profile helper reported: $($stderr.Result.Trim())" }
        return Assert-DisplayProfileResult $result $Operation $Name
    } finally {
        try {
            if ($started -and -not $process.HasExited) {
                # Allow the owned helper to finish persistence or restoration when the UI worker is stopped.
                if (-not $process.WaitForExit(30000)) {
                    $process.Kill()
                    if (-not $process.WaitForExit(10000)) { throw "Owned display-profile helper did not exit after termination." }
                    throw "Display-profile helper was terminated. Restoration is unverified; use Recover previous layout."
                }
            }
        } finally { $process.Dispose() }
    }
}
