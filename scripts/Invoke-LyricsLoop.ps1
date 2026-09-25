# CPU lyrics loop. Runs the checked-in scripts\lyrics_loop.py.
# Audio, stems, and state stay under C:\nvme\stt\lyrics. Whisper stays on CPU.
# Does not call C:\nvme\stt\Invoke-LyricsLoop.ps1.
#
# Start RECORDING first, THEN hit play in ncspot (~1s later).
# RecordSeconds is the song length: that 1s is preroll at the front.
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
$pyFile = Join-Path $PSScriptRoot "lyrics_loop.py"
if (-not (Test-Path -LiteralPath $pyFile)) { throw "missing $pyFile" }
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw "python is not on PATH (faster-whisper lives in that interpreter)" }
$pyArgs = @($pyFile, "--name", $Name, "--language", $Language, "--hint", $Hint, "--threads", "$Threads")
if ($Artist) { $pyArgs += @("--artist", $Artist) }
if ($Album) { $pyArgs += @("--album", $Album) }
if ($RecordSeconds) { $pyArgs += @("--record", "$RecordSeconds") }
if ($Path) { $pyArgs += @("--path", $Path) }
if ($Lock) { $pyArgs += @("--lock", $Lock) }
if ($Unlock) { $pyArgs += @("--unlock", $Unlock) }
if ($Rewrite) { $pyArgs += @("--rewrite", $Rewrite) }
if ($Drop) { $pyArgs += @("--drop", $Drop) }
if ($Insert) { $pyArgs += @("--insert", $Insert) }
if ($SnapFirst -gt 0) { $pyArgs += @("--snap-first", "$SnapFirst") }
if ($Song) { $pyArgs += @("--song", $Song) }
if ($Preroll -ge 0) { $pyArgs += @("--preroll", "$Preroll") }
if ($AcceptDraft) { $pyArgs += "--accept-draft" }
if ($Force) { $pyArgs += "--force" }
if ($RedoUnlocked) { $pyArgs += "--redo-unlocked" }
if ($Recheck) { $pyArgs += "--recheck" }
if ($SkipDemucs) { $pyArgs += "--skip-demucs" }
Write-Host "lyrics_loop $($pyArgs -join ' ')"
& $python @pyArgs
if ($LASTEXITCODE -ne 0) { throw "lyrics_loop failed $LASTEXITCODE" }
