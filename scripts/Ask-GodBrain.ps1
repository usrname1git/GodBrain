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
$destination = $null
if (-not [Uri]::TryCreate($Base, [UriKind]::Absolute, [ref]$destination) -or
    $destination.Scheme -cne "http" -or $destination.Port -ne 8083 -or
    $destination.Host -notin @("127.0.0.1", "localhost") -or $destination.UserInfo -or
    $destination.AbsolutePath -cne "/" -or $destination.Query -or $destination.Fragment) {
    throw "Ask-GodBrain -Base must be the canonical loopback kernel: http://127.0.0.1:8083 (localhost alias allowed)."
}
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
if ((Test-GodBrainWriteSlash $message) -and [string]::IsNullOrWhiteSpace($env:GODBRAIN_API_TOKEN)) {
    throw "This kernel command requires GODBRAIN_API_TOKEN in this process."
}
$invoke = @{
    Uri = "http://127.0.0.1:8083/api/chat"
    Method = "POST"
    ContentType = "application/json"
    Body = $body
    TimeoutSec = $timeout
    MaximumRedirection = 0
}
if (-not [string]::IsNullOrWhiteSpace($env:GODBRAIN_API_TOKEN)) {
    $invoke.Headers = @{ Authorization = "Bearer " + $env:GODBRAIN_API_TOKEN }
}
try {
    $r = Invoke-RestMethod @invoke
} catch {
    # Remote bodies/exception text can echo credentials; do not include them.
    throw "Ask-GodBrain failed: the canonical loopback request did not complete (redirects are disabled)."
}
if ($r.response) {
    Write-Output $r.response
} elseif ($r.error) {
    Write-Output $r.error
    exit 1
} else {
    Write-Output ($r | ConvertTo-Json -Compress)
}
