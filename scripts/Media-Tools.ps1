$script:GodBrainMediaRoot = Split-Path $PSScriptRoot -Parent

function Get-GodBrainMediaExecutable([string]$Name) {
    $installed = if ($Name -in @('ffmpeg', 'ffprobe')) { "C:\Tools\ffmpeg\$Name.exe" } else { '' }
    if ($installed -and (Test-Path -LiteralPath $installed -PathType Leaf)) { return $installed }
    $command = Get-Command "$Name.exe" -CommandType Application -ErrorAction Stop
    return $command.Source
}

function Save-WebVideo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Url,
        [string]$Directory = (Join-Path $HOME 'Downloads\Media')
    )
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('https', 'http') -or $uri.UserInfo) {
        throw 'Supply one quoted HTTP(S) video URL without credentials.'
    }
    $tool = Get-GodBrainMediaExecutable 'yt-dlp'
    $ffmpeg = Get-GodBrainMediaExecutable 'ffmpeg'
    $node = Get-GodBrainMediaExecutable 'node'
    $Directory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Directory)
    [void][IO.Directory]::CreateDirectory($Directory)
    $arguments = @('--ignore-config', '--no-playlist', '--no-overwrites', '--windows-filenames',
        '--ffmpeg-location', (Split-Path $ffmpeg -Parent), '--js-runtimes', "node:$node",
        '--format', 'bv*+ba/b', '--merge-output-format', 'mkv', '--paths', $Directory,
        '--output', '%(title).150B [%(id)s].%(ext)s', '--', $Url)
    & $tool @arguments
    if ($LASTEXITCODE) { throw "yt-dlp failed with exit code $LASTEXITCODE; no browser cookies were requested." }
}

function Remove-MediaSilence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$InputFile,
        [string]$OutputFile,
        [ValidateRange(-90, -10)][double]$NoiseDb = -40,
        [ValidateRange(0.05, 30)][double]$MinimumGap = 0.5,
        [ValidateRange(0, 1)][double]$Padding = 0.1,
        [switch]$Plan
    )
    $tool = Join-Path $script:GodBrainMediaRoot 'build\media_cut\media-cut.exe'
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw 'Run scripts\Build-MediaCut.ps1 first.' }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $arguments = @('--input', $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputFile),
        '--ffmpeg', (Get-GodBrainMediaExecutable 'ffmpeg'), '--ffprobe', (Get-GodBrainMediaExecutable 'ffprobe'),
        '--noise-db', $NoiseDb.ToString($culture), '--min-gap', $MinimumGap.ToString($culture),
        '--padding', $Padding.ToString($culture))
    if ($OutputFile) { $arguments += @('--output', $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)) }
    if ($Plan) { $arguments += '--plan' }
    $text = & $tool @arguments
    if ($LASTEXITCODE) { throw "Media cutter failed with exit code $LASTEXITCODE; see its explicit error above." }
    if (-not $text) { throw 'Media cutter returned no receipt.' }
    return ($text | ConvertFrom-Json -ErrorAction Stop)
}

Set-Alias -Name ytdl -Value Save-WebVideo
Set-Alias -Name ffcut -Value Remove-MediaSilence
