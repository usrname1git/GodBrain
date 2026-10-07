# Ask the local mouth without opening Galaxy. Loopback only. One GPU slot.
# Ideas are candidate Golden Records in sector=idea. Never auto-verified.
#
#   .\scripts\Ask-GodBrain.ps1 what is this PC named
#   .\scripts\Ask-GodBrain.ps1 -Idea "store this thought"
#   .\scripts\Ask-GodBrain.ps1 -Ideas
#   .\scripts\Ask-GodBrain.ps1 /brief

[CmdletBinding()]
param(
    [switch]$Idea,
    [switch]$Ideas,
    [string]$Base = "http://127.0.0.1:8083",
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Text
)

$ErrorActionPreference = "Stop"
$message = (($Text | ForEach-Object { $_ }) -join " ").Trim()
if ($Ideas) { $message = "/ideas" }
elseif ($Idea) {
    if ([string]::IsNullOrWhiteSpace($message)) {
        throw "Ask-GodBrain -Idea needs the idea text after the switch."
    }
    if (-not $message.StartsWith("/idea")) { $message = "/idea " + $message }
}
if ([string]::IsNullOrWhiteSpace($message)) {
    throw "Ask-GodBrain needs a question, /slash, or -Idea text."
}

$timeout = 180
if ($message.StartsWith("/")) { $timeout = 20 }

function Test-GodBrainWriteSlash([string]$Text) {
    $trimmed = $Text.Trim()
    if ($trimmed -match '^(?i)/(?:verify|reject)\b') { return $true }
    if ($trimmed -match '^(?i)/yolo\s+(\S+)') {
        return $Matches[1] -notmatch '^(?i)(?:status|\?)$'
    }
    return $false
}

$body = @{ message = $message } | ConvertTo-Json -Compress
$invoke = @{
    Uri = ($Base + "/api/chat")
    Method = "POST"
    ContentType = "application/json"
    Body = $body
    TimeoutSec = $timeout
}
if ((Test-GodBrainWriteSlash $message) -and -not [string]::IsNullOrWhiteSpace($env:GODBRAIN_API_TOKEN)) {
    $invoke.Headers = @{ Authorization = "Bearer " + $env:GODBRAIN_API_TOKEN }
}
try {
    $r = Invoke-RestMethod @invoke
} catch {
    throw "Ask-GodBrain failed: $_"
}
if ($r.response) {
    Write-Output $r.response
} elseif ($r.error) {
    Write-Output $r.error
    exit 1
} else {
    Write-Output ($r | ConvertTo-Json -Compress)
}
