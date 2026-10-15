function Get-GodBrainClipShareRoot {
    if ($env:GODBRAIN_CLIPSHARE_ROOT) { return [IO.Path]::GetFullPath($env:GODBRAIN_CLIPSHARE_ROOT) }
    return Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'ClipShare'
}

function Invoke-GodBrainClipShareCommand {
    param([ValidateSet('status', 'start', 'stop', 'inbox', 'library', 'copy', 'login')][string]$Command,
        [switch]$Ingress)
    $root = Get-GodBrainClipShareRoot
    $name = if ($Ingress) { 'clipshare-ingress.exe' } else { 'clipshare.exe' }
    $exe = Join-Path $root "build\Release\$name"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "ClipShare $name is not installed at $root." }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $exe
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Command, '--root', $root) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'ClipShare command did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timeout = if ($Command -eq 'start') { 35000 } elseif ($Command -eq 'stop') { 16000 } else { 10000 }
        if (-not $process.WaitForExit($timeout)) {
            $process.Kill()
            $process.WaitForExit()
            throw "ClipShare $Command timed out. Check its own status/logs before retrying."
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = $errorText.Trim()
            if ($detail.StartsWith('{')) { $detail = ($detail | ConvertFrom-Json -ErrorAction Stop).error }
            throw "ClipShare $Command failed: $detail"
        }
        $result = $output | ConvertFrom-Json -ErrorAction Stop
        if (-not $result.line) { throw 'ClipShare returned an invalid receipt.' }
        return $result
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function Get-GodBrainClipSharePublicVerification {
    param([string]$Root = (Get-GodBrainClipShareRoot))
    $path = Join-Path $Root 'local\ingress\public-verification.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $path -ErrorAction Stop).Length -gt 256KB) {
        throw 'Public verification receipt exceeds 256 KiB.'
    }
    $proof = Get-Content -LiteralPath $path -Raw -ErrorAction Stop |
        ConvertFrom-Json -DateKind String -NoEnumerate -Depth 16 -ErrorAction Stop
    if ($proof -is [array] -or $proof -isnot [pscustomobject] -or
        $proof.schema_version -ne 1 -or $proof.status -cne 'pass' -or
        $proof.public_reachability_verified -isnot [bool] -or -not $proof.public_reachability_verified) {
        throw 'Public verification receipt is not a successful supported check.'
    }
    $at = [datetimeoffset]::MinValue
    $formats = [string[]]@("yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'")
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if ($proof.at -isnot [string] -or
        -not [datetimeoffset]::TryParseExact($proof.at, $formats, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$at) -or
        $at -gt [datetimeoffset]::UtcNow.AddMinutes(2)) {
        throw 'Public verification receipt has an invalid timestamp.'
    }
    $settings = Get-Content -LiteralPath (Join-Path $Root 'local\settings.json') -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if ($proof.public_base -isnot [string] -or [string]::IsNullOrWhiteSpace($proof.public_base) -or
        $settings.public_base -isnot [string]) {
        throw 'Public verification URL binding is missing.'
    }
    if ($proof.public_base -cne $settings.public_base) { return $null }
    $files = [ordered]@{
        template_sha256 = 'Caddyfile.example'
        config_sha256 = 'local\ingress\Caddyfile'
        caddy_sha256 = 'tools\caddy\caddy.exe'
        controller_sha256 = 'build\Release\clipshare.exe'
    }
    $matchesCurrentSetup = $true
    foreach ($file in $files.GetEnumerator()) {
        if ($proof.($file.Key) -isnot [string] -or $proof.($file.Key) -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Public verification receipt has an invalid file binding.'
        }
        $current = Join-Path $Root $file.Value
        if (-not (Test-Path -LiteralPath $current -PathType Leaf)) { $matchesCurrentSetup = $false; continue }
        if ((Get-FileHash -LiteralPath $current -Algorithm SHA256 -ErrorAction Stop).Hash -ine $proof.($file.Key)) {
            $matchesCurrentSetup = $false
        }
    }
    return [pscustomobject]@{
        At = $at.UtcDateTime.ToString("yyyy-MM-dd HH:mm 'UTC'", [Globalization.CultureInfo]::InvariantCulture)
        MatchesCurrentSetup = $matchesCurrentSetup
    }
}

function Format-GodBrainClipShareLine {
    param([string]$Line, [switch]$PublicHistory)
    $text = $Line -creplace ' \(external URL unverified\)', '' `
        -creplace '; external reachability still unverified(?=;|$)', '' `
        -creplace '; external reachability not verified(?=;|$)', ''
    if ($PublicHistory) {
        try {
            $history = Get-GodBrainClipSharePublicVerification
            if ($history) {
                $changed = if ($history.MatchesCurrentSetup) { '' } else { ' (setup changed)' }
                $text += "; last verified at $($history.At)$changed"
            }
        } catch { $text += "; verification history unreadable: $($_.Exception.Message)" }
    }
    return $text
}

function Get-GodBrainClipShareLine {
    $exe = Join-Path (Get-GodBrainClipShareRoot) 'build\Release\clipshare.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return 'not installed' }
    try {
        $line = [string](Invoke-GodBrainClipShareCommand 'status').line
        if (Test-Path -LiteralPath (Join-Path (Get-GodBrainClipShareRoot) 'local\ingress\native-settings.json') -PathType Leaf) {
            $line += '; ingress: ' + [string](Invoke-GodBrainClipShareCommand 'status' -Ingress).line
        }
        return Format-GodBrainClipShareLine $line -PublicHistory
    }
    catch { return "unread: $($_.Exception.Message)" }
}

function Invoke-GodBrainClipShare {
    param([ValidateSet('Start', 'Stop', 'Inbox', 'Library', 'Copy', 'Login')][string]$Action)
    $configured = Test-Path -LiteralPath (Join-Path (Get-GodBrainClipShareRoot) 'local\ingress\native-settings.json') -PathType Leaf
    if ($configured -and $Action -eq 'Stop') { $null = Invoke-GodBrainClipShareCommand 'stop' -Ingress }
    $result = Invoke-GodBrainClipShareCommand $Action.ToLowerInvariant()
    if ($configured -and $Action -eq 'Start') {
        $line = [string]$result.line + '; ingress: ' + [string](Invoke-GodBrainClipShareCommand 'start' -Ingress).line
        return Format-GodBrainClipShareLine $line -PublicHistory
    }
    return Format-GodBrainClipShareLine ([string]$result.line) -PublicHistory:($Action -in @('Start', 'Copy'))
}
