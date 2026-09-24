# Door to C:\nvme\stt\Invoke-LyricsLoop.ps1 (CPU Whisper lyrics, 4080 untouched).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Artist,
    [string]$Album,
    [string]$Path,
    [string]$RecordSeconds = "",
    [string]$Language = "en",
    [string]$Hint = "",
    [int]$Threads = 20,
    [string]$Lock,
    [string]$Unlock,
    [string]$Rewrite,
    [string]$Drop,
    [string]$Insert,
    [double]$SnapFirst = 0,
    [string]$Song,
    [double]$Preroll = -1,
    [switch]$AcceptDraft,
    [switch]$Force,
    [switch]$RedoUnlocked,
    [switch]$Recheck,
    [switch]$SkipDemucs
)
$ErrorActionPreference = "Stop"
$here = Join-Path "C:\nvme\stt" "Invoke-LyricsLoop.ps1"
$splat = @{
    Name           = $Name
    Language       = $Language
    Hint           = $Hint
    Threads        = $Threads
    RedoUnlocked   = $RedoUnlocked
    Recheck        = $Recheck
    SkipDemucs     = $SkipDemucs
    AcceptDraft    = $AcceptDraft
    Force          = $Force
}
if ($Artist) { $splat.Artist = $Artist }
if ($Album) { $splat.Album = $Album }
if ($Path) { $splat.Path = $Path }
if ($RecordSeconds) { $splat.RecordSeconds = $RecordSeconds }
if ($Lock) { $splat.Lock = $Lock }
if ($Unlock) { $splat.Unlock = $Unlock }
if ($Rewrite) { $splat.Rewrite = $Rewrite }
if ($Drop) { $splat.Drop = $Drop }
if ($Insert) { $splat.Insert = $Insert }
if ($SnapFirst -gt 0) { $splat.SnapFirst = $SnapFirst }
if ($Song) { $splat.Song = $Song }
if ($Preroll -ge 0) { $splat.Preroll = $Preroll }
& $here @splat
