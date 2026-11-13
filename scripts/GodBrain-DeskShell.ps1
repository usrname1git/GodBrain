function Invoke-DeskShell {
    param([string]$Operation, [string[]]$Options = @(), [string]$IdentityRoot)
    $repository = Split-Path $PSScriptRoot -Parent
    $root = if ($IdentityRoot) { $IdentityRoot } else { $repository }
    $exe = Join-Path $repository 'build\desk_shell\desk-shell.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw 'Native Desk launcher is missing. Run scripts\Build-DeskShell.ps1.'
    }
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($value in @($Operation, $root) + $Options) { $start.ArgumentList.Add($value) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorText = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Native Desk $Operation timed out."
        }
        $text = $output.GetAwaiter().GetResult()
        $failure = $errorText.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Native Desk $Operation failed: $failure" }
        if ([string]::IsNullOrWhiteSpace($text)) { throw "Native Desk $Operation returned no receipt." }
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } finally { $process.Dispose() }
}

function Register-DeskWindow {
    if ($CaptureView -or $script:DeskUiSmoke) { return }
    $options = @($f.Handle.ToInt64().ToString([Globalization.CultureInfo]::InvariantCulture))
    if ($NewInstance) { $options += '--secondary' }
    $null = Invoke-DeskShell attach $options
}
