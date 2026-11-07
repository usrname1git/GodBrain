# CS2 DVR dead-time scan. Contact sheet is an operator receipt only (tiny tiles).
# JPEG evidence is extracted at 1440x1080; the running server's pixel cap may downscale it.
# JPEG mode uses uniformly spaced samples, not scene-change detection.
# Originals and legacy outputs are never modified. New receipts are unqualified detections.
[CmdletBinding()]
param(
    [ValidateRange(0, 1000000)][int]$Limit = 3,
    [string]$Match = "",
    [switch]$Force,
    [switch]$NativeVideo,
    [switch]$UseGoldHints,
    [string[]]$InputFile = @(),
    [ValidateRange(1, 32)][int]$Parts = 4,
    [string]$Remote = "iCloud:CS2 ",
    [string]$OutDir = "C:\nvme\cs-clips\out\deadtime",
    [string]$Endpoint = "http://127.0.0.1:8888/v1/chat/completions",
    [string]$Model = "qwen3-vl-8b-exl3",
    [string]$Ffmpeg = "C:\Tools\ffmpeg\ffmpeg.exe"
)

$ErrorActionPreference = "Stop"
$scannerSourcePath = $PSCommandPath
$scratch = Join-Path $OutDir "scratch-v2"
$instructionsPath = Join-Path $OutDir "instructions.md"
$indexPath = Join-Path $OutDir "index-v2.json"
$responseDir = ""

function Get-ModelsUrl {
    $uri = [Uri]$Endpoint
    if (-not $uri.IsLoopback -or $uri.Scheme -cne "http" -or $uri.UserInfo -or
        $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne "/v1/chat/completions") {
        throw "Clip inference requires a plain HTTP loopback /v1/chat/completions endpoint."
    }
    return $uri.GetLeftPart([UriPartial]::Authority) + "/v1/models"
}

function Wait-Vl {
    $modelsUrl = Get-ModelsUrl
    $deadline = (Get-Date).AddMinutes(8)
    $detail = "No matching model advertised."
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-RestMethod -UseBasicParsing -TimeoutSec 3 $modelsUrl
            $hit = @($r.data) | Where-Object { [string]$_.id -eq $Model } | Select-Object -First 1
            if ($hit) {
                $mods = @($hit.architecture.input_modalities)
                if ($mods -contains $(if ($NativeVideo) { "video" } else { "image" })) { return $hit }
            }
        } catch { $detail = $_.Exception.Message }
        Start-Sleep -Seconds 3
    }
    throw "Model $Model with the requested input is not ready at ${modelsUrl}: $detail"
}

function Get-ClipNames {
    $errFile = Join-Path $scratch "rclone-lsf.err"
    $names = @(rclone lsf $Remote --files-only 2>$errFile)
    if ($LASTEXITCODE -ne 0) {
        $detail = ""
        if (Test-Path -LiteralPath $errFile) { $detail = (Get-Content -LiteralPath $errFile -Raw) }
        throw "rclone lsf failed ($LASTEXITCODE) for ${Remote}: $detail"
    }
    @($names | Where-Object { $_ -like "*.mp4" })
}

function Get-ArtifactKey([string]$Name) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Name))
    } finally {
        $sha.Dispose()
    }
    ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant().Substring(0, 16)
}

function Get-TextHash([string]$Text) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Write-ScanJson($Value, [string]$Path) {
    $tmp = $Path + "." + [guid]::NewGuid().ToString("N") + ".tmp"
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(
        (ConvertTo-Json -InputObject $Value -Depth 16))
    $file = [IO.File]::Open($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) }
    finally { $file.Dispose() }
    [IO.File]::Move($tmp, $Path, $true)
}

function Get-ScanRuntime {
    $null = Get-ModelsUrl
    $uri = [Uri]$Endpoint
    $health = Invoke-RestMethod -Uri ($uri.GetLeftPart([UriPartial]::Authority) + "/health") -TimeoutSec 3
    if ($health.model -cne $Model -or $health.vision -ne $true -or $health.busy -ne $false) {
        throw "The requested vision model must already be running and idle; no model was started."
    }
    $owners = @(Get-NetTCPConnection -LocalPort $uri.Port -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalAddress -in @("127.0.0.1", "::1") } |
        Select-Object -ExpandProperty OwningProcess -Unique)
    if ($owners.Count -ne 1) { throw "Cannot bind the vision endpoint to one local process." }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($owners[0])" -ErrorAction Stop
    if (-not $process.CreationDate -or [string]::IsNullOrWhiteSpace($process.CommandLine)) {
        throw "Vision process identity/configuration could not be read; cache reuse is unsafe."
    }
    [ordered]@{
        pid = $owners[0]; created = $process.CreationDate.ToUniversalTime().ToString("o")
        command_sha256 = Get-TextHash $process.CommandLine
        context_length = $health.context_length; cache_quant = $health.cache_quant
        video_max_frames = $health.video_max_frames; video_max_pixels = $health.video_max_pixels
        video_zoom = $health.video_zoom
    }
}

function Get-ScanProfile($Runtime) {
    $rules = if ($UseGoldHints -and (Test-Path -LiteralPath $instructionsPath)) {
        Get-Content -LiteralPath $instructionsPath -Raw
    } else { Get-InstructionBlock "__no_gold__" }
    $profile = [ordered]@{
        schema_version = "cs2-deadtime-v2"; scanner_sha256 = (Get-FileHash -LiteralPath $scannerSourcePath).Hash
        rules_sha256 = Get-TextHash $rules; model = $Model; endpoint = $Endpoint
        native_video = [bool]$NativeVideo; parts = $Parts; gold_hints = [bool]$UseGoldHints; runtime = $Runtime
    }
    [pscustomobject]@{ hash = Get-TextHash ($profile | ConvertTo-Json -Depth 8 -Compress); profile = $profile }
}

function Test-ScanCache($Entry, [string]$SourceHash, [string]$ProfileHash) {
    if (-not $Entry -or $Entry.schema_version -cne "cs2-deadtime-v2" -or
        $Entry.source_sha256 -cne $SourceHash -or $Entry.profile_sha256 -cne $ProfileHash -or
        $Entry.state -notin @("complete", "needs_review")) { return $false }
    $path = [IO.Path]::GetFullPath([string]$Entry.json)
    $root = [IO.Path]::GetFullPath($OutDir).TrimEnd('\') + "\"
    if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Cached receipt path is invalid or missing." }
    if ((Get-FileHash -LiteralPath $path).Hash -cne $Entry.result_sha256) {
        throw "Cached receipt content changed; preserve it and rerun with -Force."
    }
    $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($receipt.schema_version -cne "cs2-deadtime-v2" -or $receipt.file -cne $Entry.file -or
        $receipt.state -cne $Entry.state -or $receipt.source_sha256 -cne $SourceHash -or
        $receipt.profile_sha256 -cne $ProfileHash -or $receipt.sanitized -ne $false) {
        throw "Cached receipt identity or state is invalid."
    }
    return $true
}

function New-ContactSheet([string]$Mp4, [string]$Sheet) {
    $vf = "fps=1,scale=160:-1:flags=fast_bilinear,drawtext=fontfile=C\\:/Windows/Fonts/consola.ttf:text='%{eif\:n\:d}s':x=4:y=4:fontsize=14:fontcolor=white:box=1:boxcolor=black@0.7,tile=10x12,scale=1280:-1"
    & $Ffmpeg -hide_banner -loglevel error -y -i $Mp4 -vf $vf -frames:v 1 $Sheet
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Sheet)) {
        throw "ffmpeg contact sheet failed for $Mp4"
    }
}

function New-PovFrames([string]$Mp4, [string]$Prefix, [double]$Duration) {
    $n = 24
    $frames = @()
    for ($i = 0; $i -lt $n; $i++) {
        $t = [math]::Round($i * [math]::Max(0, $Duration - 0.05) / [math]::Max(1, $n - 1), 3)
        $label = $t.ToString("0.###", [Globalization.CultureInfo]::InvariantCulture)
        $out = "{0}.p{1:000}.jpg" -f $Prefix, $i
        $draw = "scale=1440:1080:force_original_aspect_ratio=decrease,pad=1440:1080:(ow-iw)/2:(oh-ih)/2,drawtext=fontfile=C\\:/Windows/Fonts/consola.ttf:text='${label}s':x=24:y=24:fontsize=48:fontcolor=white:box=1:boxcolor=black@0.75"
        & $Ffmpeg -hide_banner -loglevel error -n -ss $label -i $Mp4 -frames:v 1 -vf $draw -q:v 3 $out
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw "ffmpeg POV frame failed at ${t}s" }
        $frames += [pscustomobject]@{ FullName = $out; second = $t }
    }
    if ($frames.Count -lt 1) { throw "no POV frames for $Mp4" }
    $frames
}

function Coalesce-Ranges($items, [double]$Gap = 0) {
    $sorted = @($items | Where-Object { $_ } | Sort-Object { [double]$_.in })
    if ($sorted.Count -eq 0) { return @() }
    $out = @()
    $cur = [pscustomobject]@{ in = [double]$sorted[0].in; out = [double]$sorted[0].out; why = $sorted[0].why }
    foreach ($item in $sorted | Select-Object -Skip 1) {
        $inn = [double]$item.in
        $outt = [double]$item.out
        if ($inn -le $cur.out + $Gap) {
            if ($outt -gt $cur.out) { $cur.out = $outt }
            if ($item.why -and -not ([string]$cur.why).Contains([string]$item.why)) {
                $cur.why = "$($cur.why); $($item.why)"
            }
        } else {
            $out += $cur
            $cur = [pscustomobject]@{ in = $inn; out = $outt; why = $item.why }
        }
    }
    $out += $cur
    $out | ForEach-Object {
        [pscustomobject]@{
            in = $_.in
            out = $_.out
            why = $_.why
        }
    }
}

function Shift-Ranges($items, [double]$Offset) {
    @($items | ForEach-Object {
        if (-not $_) { return }
        [pscustomobject]@{
            in = ([double]$_.in) + $Offset
            out = ([double]$_.out) + $Offset
            why = $_.why
        }
    })
}

function New-ExactVideoPart([string]$Src, [string]$Out, [double]$Start, [double]$Length) {
    $ss = $Start.ToString("0.######", [Globalization.CultureInfo]::InvariantCulture)
    $span = $Length.ToString("0.######", [Globalization.CultureInfo]::InvariantCulture)
    & $Ffmpeg -hide_banner -loglevel error -n -ss $ss -i $Src -t $span -map 0:v:0 -an `
        -vf "setpts=PTS-STARTPTS" -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p -fps_mode passthrough $Out
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Out)) {
        throw "ffmpeg exact analysis-part extraction failed at ${ss}s."
    }
    if ([math]::Abs((Read-StartSeconds $Out)) -gt 0.05) { throw "Analysis part does not start at timestamp zero." }
}

function Split-ExactParts([string]$Src, [string]$Prefix, [int]$PartCount, [double]$Duration) {
    if ($Duration -le 0 -or $PartCount -lt 1) { throw "Invalid analysis split bounds." }
    $seg = $Duration / $PartCount
    $parts = @()
    for ($i = 1; $i -le $PartCount; $i++) {
        $out = "{0}_part{1}.mp4" -f $Prefix, $i
        $ss = ($i - 1) * $seg
        New-ExactVideoPart $Src $out $ss $seg
        $dur = Read-Duration $out
        if ([math]::Abs($dur - $seg) -gt 0.1) { throw "Analysis part duration differs from the requested span." }
        $parts += [pscustomobject]@{
            index = $i
            path = $out
            offset_s = $ss
            duration_s = [math]::Min($dur, $seg)
        }
    }
    $parts
}

function Read-Duration([string]$Mp4) {
    $ffprobe = Join-Path (Split-Path $Ffmpeg) "ffprobe.exe"
    $raw = & $ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $Mp4
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$raw)) {
        throw "ffprobe duration failed for $Mp4"
    }
    $dur = [double]::Parse(([string]$raw).Trim(), [Globalization.CultureInfo]::InvariantCulture)
    if ([double]::IsNaN($dur) -or [double]::IsInfinity($dur) -or $dur -le 0) { throw "ffprobe duration is invalid for $Mp4" }
    $dur
}

function Read-StartSeconds([string]$Mp4) {
    $ffprobe = Join-Path (Split-Path $Ffmpeg) "ffprobe.exe"
    $raw = & $ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -read_intervals "%+#1" -of csv=p=0 $Mp4
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$raw)) {
        throw "ffprobe start time failed for $Mp4"
    }
    $line = ([string]$raw).Trim().Split([char]10)[0].Trim()
    [double]::Parse($line, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-InstructionBlock([string]$Name, [switch]$IncludeGold) {
    if (-not (Test-Path -LiteralPath $instructionsPath)) { return "" }
    $text = Get-Content -LiteralPath $instructionsPath -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $rules = $text
    $goldAt = $text.IndexOf('## Gold')
    if ($goldAt -ge 0) {
        $rules = $text.Substring(0, $goldAt).Trim()
        $gold = $text.Substring($goldAt)
        $block = ""
        foreach ($part in ($gold -split '(?m)^### ')) {
            if (-not $part) { continue }
            $heading = (($part -split "`r?`n", 2)[0]).Trim()
            $heading = $heading -replace '\s+\(~?\d+(?:\.\d+)?s\)$', ''
            if ($IncludeGold -and [string]::Equals($heading, $Name, [StringComparison]::OrdinalIgnoreCase)) {
                $block = '### ' + $part.Trim()
                break
            }
        }
        if ($block) { $rules = $rules + "`n`nGOLD FOR THIS FILE ONLY:`n" + $block }
    }
    if (-not $IncludeGold) { $rules = (($rules -split '\r?\n') | Where-Object { $_ -notmatch '\bgold\b' }) -join "`n" }
    return "OPERATOR LAW:`n$rules"
}

function Assert-JsonKeys($Element, [string[]]$Expected) {
    if ($Element.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw "VL JSON must contain objects." }
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $Element.EnumerateObject()) {
        if (-not $keys.Add($property.Name) -or $property.Name -cnotin $Expected) {
            throw "VL JSON has a duplicate or unexpected field: $($property.Name)"
        }
    }
    if ($keys.Count -ne $Expected.Count) { throw "VL JSON is missing required fields." }
}

function Read-JsonNumber($Element) {
    if ($Element.ValueKind -ne [Text.Json.JsonValueKind]::Number) { throw "VL times must be JSON numbers." }
    $value = $Element.GetDouble()
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw "VL times must be finite." }
    return $value
}

function ConvertFrom-VlCompletion($Response, [string]$Name, [double]$Duration,
    [double]$WindowStart = 0, [double]$WindowEnd = -1) {
    if ($WindowEnd -lt 0) { $WindowEnd = $Duration }
    if ($Response.error -or $Response.model -cne $Model -or @($Response.choices).Count -ne 1 -or
        $Response.choices[0].finish_reason -cne "stop" -or $Response.choices[0].message.tool_calls -or
        $Response.choices[0].message.content -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Response.choices[0].message.content)) {
        throw "VL completion failed, was truncated, changed model, or returned no plain-text answer."
    }
    $document = [Text.Json.JsonDocument]::Parse([string]$Response.choices[0].message.content)
    try {
        $root = $document.RootElement
        Assert-JsonKeys $root @("file", "duration_s", "keep", "drop")
        if ($root.GetProperty("file").ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $root.GetProperty("file").GetString() -cne $Name -or
            [math]::Abs((Read-JsonNumber $root.GetProperty("duration_s")) - $Duration) -gt 0.05) {
            throw "VL result identity or duration does not match the evidence."
        }
        $result = [ordered]@{ file = $Name; duration_s = $Duration; keep = @(); drop = @() }
        foreach ($kind in @("keep", "drop")) {
            $ranges = $root.GetProperty($kind)
            if ($ranges.ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw "VL keep/drop must be arrays." }
            foreach ($range in $ranges.EnumerateArray()) {
                Assert-JsonKeys $range @("in", "out", "why")
                $a = Read-JsonNumber $range.GetProperty("in")
                $b = Read-JsonNumber $range.GetProperty("out")
                if ($a -lt $WindowStart -or $b -gt $WindowEnd -or $a -ge $b -or
                    $range.GetProperty("why").ValueKind -ne [Text.Json.JsonValueKind]::String -or
                    [string]::IsNullOrWhiteSpace($range.GetProperty("why").GetString()) -or
                    $range.GetProperty("why").GetString().Length -gt 512) {
                    throw "VL interval is invalid, outside supplied evidence, or has an invalid reason."
                }
                $result[$kind] += [pscustomobject]@{ in = $a; out = $b; why = $range.GetProperty("why").GetString() }
            }
        }
        return [pscustomobject]$result
    } finally { $document.Dispose() }
}

function Resolve-ClipRanges($Keep, $Drop, [double]$Duration) {
    $kept = @(Coalesce-Ranges $Keep)
    $dropped = @(); $conflicts = @()
    foreach ($range in @(Coalesce-Ranges $Drop)) {
        $cursor = [double]$range.in
        foreach ($fight in $kept) {
            $a = [math]::Max($cursor, [double]$fight.in)
            $b = [math]::Min([double]$range.out, [double]$fight.out)
            if ($a -ge $b) { continue }
            if ($cursor -lt $a) { $dropped += [pscustomobject]@{ in = $cursor; out = $a; why = $range.why } }
            $conflicts += [pscustomobject]@{ in = $a; out = $b; why = "KEEP/DROP conflict; retained" }
            $cursor = $b
        }
        if ($cursor -lt $range.out) {
            $dropped += [pscustomobject]@{ in = $cursor; out = [double]$range.out; why = $range.why }
        }
    }
    $unknown = @(); $cursor = 0.0
    foreach ($range in @(Coalesce-Ranges @($kept + $dropped))) {
        if ($cursor -lt $range.in) {
            $unknown += [pscustomobject]@{ in = $cursor; out = [double]$range.in; why = "Unclassified; retained" }
        }
        $cursor = [math]::Max($cursor, [double]$range.out)
    }
    if ($cursor -lt $Duration) { $unknown += [pscustomobject]@{ in = $cursor; out = $Duration; why = "Unclassified; retained" } }
    [pscustomobject]@{
        keep = $kept; drop = $dropped; uncertain = $unknown; conflicts = $conflicts
        retain = @(Coalesce-Ranges @($kept + $unknown))
        state = $(if ($unknown.Count -or $conflicts.Count) { "needs_review" } else { "complete" })
    }
}

function Save-VlResponse($Response) {
    if ($responseDir) {
        Write-ScanJson $Response (Join-Path $responseDir ("response-" + [guid]::NewGuid().ToString("N") + ".json"))
    }
}

function Invoke-Vl([object[]]$Frames, [string]$Name, [double]$Duration, [double]$Offset = 0) {
    $notes = Get-InstructionBlock $Name -IncludeGold:$UseGoldHints
    $windowStart = [double]$Frames[0].second
    $windowEnd = [math]::Min($Duration, [double]$Frames[-1].second + [math]::Max(0.05, $Duration / 23))
    $durationText = $Duration.ToString("0.######", [Globalization.CultureInfo]::InvariantCulture)
    $prompt = @"
Mark KEEP vs DROP on this Counter-Strike 2 Shadowplay DVR.

File: $Name
Duration: ${durationText}s. Local zero is original time $Offset.
Only report intervals within local $windowStart..$windowEnd, the supplied sample window.
Any hinted original-file times must have $Offset subtracted; ignore hints outside this window.

You get $($Frames.Count) POV frames at 1440x1080 (same as the DVR). Each frame is labeled with seconds. The tiny contact sheet is NOT your evidence.

Do not reuse times from another file.

Rules:
- Kill feed is not evidence. Only gunfire, blood, or a body you can SEE in the local POV.
- After local death the POV is black ~3s. Drop that.
- Full-white flash POV is drop until the world is visible again.
- Freeze time (buy, orange bar, black map, killed-you panel) is drop.
- Preserve the full visible engagement. Do not shorten useful action to meet a fixed KEEP duration or quota.
- Opening spray while spectating still counts if it is on screen.
- Falling body with no shot on screen: keep or drop both OK.
- Metronome keeps are a fail.

$notes

Return ONLY JSON. keep is an array of {in,out,why} in seconds. If there is no visible fight, keep is []. Never copy example numbers — there are none. Shape:
Use continuous intervals with out > in, never single-second points. Keep each why brief.
{"file":"$Name","duration_s":$durationText,"keep":[],"drop":[]}
"@
    $content = New-Object System.Collections.Generic.List[object]
    [void]$content.Add(@{ type = "text"; text = $prompt })
    foreach ($frame in $Frames) {
        $bytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($frame.FullName))
        [void]$content.Add(@{ type = "image_url"; image_url = @{ url = "data:image/jpeg;base64,$bytes" } })
    }
    $body = @{
        model = $Model
        temperature = 0.2
        max_tokens = 800
        chat_template_kwargs = @{ enable_thinking = $false }
        messages = @(
            @{ role = "user"; content = $content }
        )
    } | ConvertTo-Json -Depth 8 -Compress
    $resp = Invoke-RestMethod -Method Post -Uri $Endpoint -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 240
    Save-VlResponse $resp
    ConvertFrom-VlCompletion $resp $Name $Duration $windowStart $windowEnd
}

function Invoke-VlVideo([string]$LocalMp4, [string]$Name, [double]$Duration, [double]$Offset = 0, [int]$PartIndex = 0, [int]$PartCount = 1) {
    $notes = Get-InstructionBlock $Name -IncludeGold:$UseGoldHints
    $durationText = $Duration.ToString("0.######", [Globalization.CultureInfo]::InvariantCulture)
    $uri = "file:///" + ($LocalMp4 -replace '\\', '/')
    $origEnd = [math]::Round($Offset + $Duration, 1)
    $chunkNote = if ($PartCount -gt 1 -and $PartIndex -gt 0) {
        @"
You are watching PART $PartIndex of $PartCount of the SAME original DVR (accurately sought, timestamp-zeroed analysis part).
Original file: $Name
This part duration: ${Duration}s. Local t=0 is original t=$Offset. Local t=$Duration is original t=$origEnd.
A duel may start at the end of this part and continue in the next part — mark only what is VISIBLE here. Do not invent the rest of the round. Do not reuse keep times from other parts.
Report in/out in LOCAL seconds (0..$Duration). If gold is in original-file seconds, subtract $Offset. Ignore gold outside $Offset..$origEnd.
CRITICAL: Freeze or buy-menu at the START of this part does not make the whole part DROP. Watch every labeled frame through local t=$Duration.
"@
    } else { "This is the full clip." }
    $prompt = @"
Mark KEEP vs DROP on this Counter-Strike 2 Shadowplay DVR.

File: $Name
Duration: ${durationText}s
$chunkNote

The server decodes this local mp4 into timestamp-labelled image samples at its configured fps and pixel cap; it is not continuous video/audio evidence. If zoom>1 the frames are center-cropped (outer HUD may be absent). Do not infer the contents of unseen time from one sampled frame.

Do not reuse times from another file.

Rules:
- Kill feed names are not evidence. HUD money IS: +$ / neutralizing / ammo dropping / muzzle flash / silhouette in a scoped AWP circle = KEEP even if the enemy is a speck or already gone.
- After local death the POV is black ~3s. Drop that.
- Full-white flash POV is drop until the world is visible again.
- Freeze time (buy, orange bar, black map, killed-you panel, ROUND WON) is drop.
- Preserve the full visible engagement. Do not shorten useful action to meet a fixed KEEP duration or quota.
- Opening spray while spectating still counts if it is on screen.
- Falling body with no shot on screen: keep or drop both OK.
- Metronome keeps are a fail.
- Unscoped AWP + empty street + +$ already on HUD = the frag was the previous second. Do not keep the walk. Do not skip the earlier scoped frame.

$notes

Return ONLY JSON. keep is an array of {in,out,why} in seconds. If there is no visible fight, keep is []. Never invent times from a template. Shape:
Use continuous intervals with out > in. Keep each why brief. Uncertain time may remain unclassified.
{"file":"$Name","duration_s":$durationText,"keep":[],"drop":[]}
"@
    $body = @{
        model = $Model
        temperature = 0.2
        max_tokens = 800
        chat_template_kwargs = @{ enable_thinking = $false }
        messages = @(
            @{
                role = "user"
                content = @(
                    @{ type = "text"; text = $prompt }
                    @{ type = "video_url"; video_url = @{ url = $uri } }
                )
            }
        )
    } | ConvertTo-Json -Depth 8 -Compress
    $resp = Invoke-RestMethod -Method Post -Uri $Endpoint -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 300
    Save-VlResponse $resp
    ConvertFrom-VlCompletion $resp $Name $Duration
}

function Invoke-VlWindowed([object[]]$Frames, [string]$Name, [double]$Duration, [double]$Offset = 0) {
    $keeps = @(); $drops = @()
    for ($i = 0; $i -lt $Frames.Count; $i += 3) {
        $chunk = @($Frames | Select-Object -Skip $i -First 3)
        Write-Host ("  VL chunk {0}-{1}" -f $i, ($i + $chunk.Count - 1))
        $part = Invoke-Vl $chunk $Name $Duration $Offset
        $keeps += @($part.keep)
        $drops += @($part.drop)
    }
    [pscustomobject]@{
        file = $Name
        duration_s = $Duration
        keep = @($keeps)
        drop = @($drops)
    }
}

function Invoke-Cs2DeadtimeScan {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    $lock = [IO.File]::Open((Join-Path $OutDir "scan-v2.lock"),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $index = @()
        if (Test-Path -LiteralPath $indexPath) {
            $raw = Get-Content -LiteralPath $indexPath -Raw
            $doc = [Text.Json.JsonDocument]::Parse([string]$raw)
            try {
                if ($doc.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Array) {
                    throw "Scan index must be an array; it was not reset or overwritten."
                }
            } finally { $doc.Dispose() }
            $index = @($raw | ConvertFrom-Json)
            foreach ($entry in $index) {
                if ($entry.schema_version -cne "cs2-deadtime-v2" -or $entry.file -isnot [string]) {
                    throw "Scan index contains invalid entries; it was not reset or overwritten."
                }
            }
        }
        $all = if ($InputFile.Count) {
            @($InputFile | ForEach-Object {
                $item = Get-Item -LiteralPath $_ -ErrorAction Stop
                if ($item.PSIsContainer -or $item.Extension -ine ".mp4") { throw "Local input must be an MP4 file." }
                [pscustomobject]@{ name = $item.Name; local = $item.FullName }
            })
        } else {
            @(Get-ClipNames | ForEach-Object {
                if ($_ -ne [IO.Path]::GetFileName($_)) { throw "Remote listing contains a non-leaf filename." }
                [pscustomobject]@{ name = $_; local = "" }
            })
        }
        if ($Match) { $all = @($all | Where-Object { $_.name -like "*$Match*" }) }
        if ($Limit -gt 0) { $all = @($all | Select-Object -First $Limit) }
        if (-not $all.Count) { Write-Output "No matching MP4 inputs."; return }
        $null = Wait-Vl
        $runtime = Get-ScanRuntime
        $runtimeHash = Get-TextHash ($runtime | ConvertTo-Json -Depth 8 -Compress)
        $profile = Get-ScanProfile $runtime
        $failed = 0
        Write-Output "clips=$($all.Count); detections are unqualified, not sanitized videos."
        foreach ($source in $all) {
            $name = $source.name
            $runId = [guid]::NewGuid().ToString("N")
            $runDir = Join-Path $OutDir ("runs\" + $runId)
            $local = ""; $copied = $false; $sourceHash = ""; $partPaths = @(); $stage = "source"
            try {
                $existing = if ($source.local) { $source.local } else { Join-Path $OutDir $name }
                if (Test-Path -LiteralPath $existing -PathType Leaf) { $local = $existing }
                else {
                    if ($source.local) { throw "Explicit local input disappeared; no remote substitute was downloaded." }
                    $local = Join-Path $scratch ($runId + ".mp4")
                    if (Test-Path -LiteralPath $local) { throw "Owned download destination already exists." }
                    $copied = $true
                    & rclone copyto ($Remote + "/" + $name) $local
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $local -PathType Leaf)) {
                        throw "rclone copyto failed for $name."
                    }
                }
                $sourceHash = (Get-FileHash -LiteralPath $local).Hash
                $stage = "cache"
                if ((Get-TextHash ((Get-ScanRuntime) | ConvertTo-Json -Depth 8 -Compress)) -cne $runtimeHash -or
                    (Get-ScanProfile $runtime).hash -cne $profile.hash) {
                    throw "Vision runtime or scan instructions changed during this batch; restart the scan."
                }
                $previous = @($index | Where-Object file -CEQ $name)
                if ($previous.Count -gt 1) { throw "Duplicate source entries in the scan index." }
                if (-not $Force -and (Test-ScanCache ($previous | Select-Object -First 1) $sourceHash $profile.hash)) {
                    Write-Output "cached $name state=$($previous[0].state); not a sanitation verdict"
                    continue
                }
                $stage = "analysis"
                New-Item -ItemType Directory -Path $runDir -ErrorAction Stop | Out-Null
                $responseDir = $runDir
                $prefix = Join-Path $runDir (Get-ArtifactKey $name)
                $sheet = $prefix + ".sheet.jpg"
                $duration = Read-Duration $local
                New-ContactSheet $local $sheet
                $nParts = if ($duration -lt 80) { 1 } else { $Parts }
                $keepAll = @(); $dropAll = @(); $partMeta = @()
                $split = if ($nParts -gt 1) {
                    $partPaths = @(1..$nParts | ForEach-Object { "${prefix}_part$_.mp4" })
                    @(Split-ExactParts $local $prefix $nParts $duration)
                } else {
                    @([pscustomobject]@{ index = 1; path = $local; offset_s = 0.0; duration_s = $duration })
                }
                foreach ($part in $split) {
                    $prediction = if ($NativeVideo) {
                        Invoke-VlVideo $part.path $name $part.duration_s $part.offset_s $part.index $nParts
                    } else {
                        $frames = @(New-PovFrames $part.path ("${prefix}_part" + $part.index) $part.duration_s)
                        Invoke-VlWindowed $frames $name $part.duration_s $part.offset_s
                    }
                    $partPath = "$prefix.part$($part.index).json"
                    Write-ScanJson $prediction $partPath
                    $keepAll += Shift-Ranges $prediction.keep $part.offset_s
                    $dropAll += Shift-Ranges $prediction.drop $part.offset_s
                    $partMeta += [pscustomobject]@{
                        part = $part.index; offset_s = $part.offset_s; duration_s = $part.duration_s; json = $partPath
                    }
                }
                if ((Get-FileHash -LiteralPath $local).Hash -cne $sourceHash -or
                    (Get-TextHash ((Get-ScanRuntime) | ConvertTo-Json -Depth 8 -Compress)) -cne $runtimeHash -or
                    (Get-ScanProfile $runtime).hash -cne $profile.hash) {
                    throw "Source bytes, vision runtime or scan instructions changed during analysis."
                }
                $resolved = Resolve-ClipRanges $keepAll $dropAll $duration
                $result = [ordered]@{
                    schema_version = "cs2-deadtime-v2"; file = $name; source_sha256 = $sourceHash
                    profile_sha256 = $profile.hash; profile = $profile.profile; duration_s = $duration
                    state = $resolved.state; model_qualified = $false; sanitized = $false
                    blind_evaluation_eligible = -not [bool]$UseGoldHints
                    parts = $partMeta; sheet = $sheet
                    keep = $resolved.keep; drop = $resolved.drop; uncertain = $resolved.uncertain
                    conflicts = $resolved.conflicts; retain = $resolved.retain
                }
                $jsonPath = Join-Path $runDir "result.json"
                Write-ScanJson $result $jsonPath
                $entry = [pscustomobject]@{
                    schema_version = "cs2-deadtime-v2"; file = $name; source_sha256 = $sourceHash
                    profile_sha256 = $profile.hash; state = $resolved.state; json = $jsonPath
                    result_sha256 = (Get-FileHash -LiteralPath $jsonPath).Hash
                    at = [DateTime]::UtcNow.ToString("o")
                }
                Write-Output "$($resolved.state) $name keep=$($resolved.keep.Count) uncertain=$($resolved.uncertain.Count) conflicts=$($resolved.conflicts.Count)"
            } catch {
                $failed++
                if (-not (Test-Path -LiteralPath $runDir)) { New-Item -ItemType Directory -Path $runDir | Out-Null }
                $jsonPath = Join-Path $runDir "failed.json"
                $failure = [ordered]@{
                    schema_version = "cs2-deadtime-v2"; file = $name; state = "failed"; stage = $stage
                    source_sha256 = $sourceHash; profile_sha256 = $profile.hash
                    sanitized = $false; error = $_.Exception.Message
                }
                Write-ScanJson $failure $jsonPath
                $entry = [pscustomobject]@{
                    schema_version = "cs2-deadtime-v2"; file = $name; state = "failed"
                    source_sha256 = $sourceHash; profile_sha256 = $profile.hash; json = $jsonPath
                    result_sha256 = (Get-FileHash -LiteralPath $jsonPath).Hash; at = [DateTime]::UtcNow.ToString("o")
                }
                Write-Warning "FAILED $name at ${stage}: $($failure.error)"
            } finally {
                foreach ($path in $partPaths) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
                if ($copied -and (Test-Path -LiteralPath $local)) { Remove-Item -LiteralPath $local -Force }
            }
            $index = @($index | Where-Object file -CNE $name) + @($entry)
            Write-ScanJson @($index) $indexPath
        }
        if ($failed) { throw "$failed clip(s) failed. Failures are retained in $indexPath; no failed clip is sanitized." }
        Write-Output "DONE: $indexPath contains unqualified detections, not finished edits."
    } finally { $lock.Dispose() }
}

if ($MyInvocation.InvocationName -ne ".") { Invoke-Cs2DeadtimeScan }
