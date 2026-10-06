# Persist mouth pause (logs/mouth-pause.txt). Same shape as logs/mtp.txt.
# Watch/Heal never kill. Operator Stop-LlamaServer.ps1 stops llama-server.

function Test-GodBrainMouthPaused {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $path = Join-Path $RepoRoot "logs\mouth-pause.txt"
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $raw = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) { return $false }
    $t = $raw.Trim().ToLowerInvariant()
    return @("on", "pause", "paused", "1", "true") -contains $t
}

function Set-GodBrainMouthPaused {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][bool]$On
    )
    $logDir = Join-Path $RepoRoot "logs"
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }
    $path = Join-Path $logDir "mouth-pause.txt"
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $text = $(if ($On) { "on`n" } else { "off`n" })
    [System.IO.File]::WriteAllText($path, $text, $utf8)
}
