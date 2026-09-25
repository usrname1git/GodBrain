# CS2 DVR dead-time scan. Contact sheet is an operator receipt only (tiny tiles).
# VL sees POV JPEGs at 1440x1080 (native DVR). Server image cap is 1.55 MP so they are not downscaled.
# Scene-change picks the frames; even spacing fills if the clip is quiet.
# Does not keep the mp4 on C:.
[CmdletBinding()]
param(
    [int]$Limit = 3,
    [string]$Match = "",
    [switch]$Force,
    [switch]$NativeVideo,
    [int]$Parts = 4,
    [string]$Remote = "iCloud:CS2 ",
    [string]$OutDir = "C:\nvme\cs-clips\out\deadtime",
    [string]$Endpoint = "http://127.0.0.1:8888/v1/chat/completions",
    [string]$Model = "qwen3-vl-8b-exl3",
    [string]$Ffmpeg = "C:\Tools\ffmpeg\ffmpeg.exe"
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$scratch = Join-Path $OutDir "scratch"
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$instructionsPath = Join-Path $OutDir "instructions.md"
$indexPath = Join-Path $OutDir "index.json"

function Wait-Vl {
    $deadline = (Get-Date).AddMinutes(8)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-RestMethod -UseBasicParsing -TimeoutSec 3 "http://127.0.0.1:8888/v1/models"
            if ($r.data) { return }
        } catch {}
        Start-Sleep -Seconds 3
    }
    throw "Qwen-VL on :8888 did not become ready."
}

function Get-ClipNames {
    $names = @(rclone lsf $Remote --files-only)
    $names | Where-Object { $_ -like "*.mp4" }
}

function New-ContactSheet([string]$Mp4, [string]$Sheet) {
    $vf = "fps=1,scale=160:-1:flags=fast_bilinear,drawtext=fontfile=C\\:/Windows/Fonts/consola.ttf:text='%{eif\:n\:d}s':x=4:y=4:fontsize=14:fontcolor=white:box=1:boxcolor=black@0.7,tile=10x12,scale=1280:-1"
    & $Ffmpeg -hide_banner -loglevel error -y -i $Mp4 -vf $vf -frames:v 1 $Sheet
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Sheet)) {
        throw "ffmpeg contact sheet failed for $Mp4"
    }
}

function New-PovFrames([string]$Mp4, [string]$Prefix, [double]$Duration) {
    $dir = Split-Path $Prefix
    $leaf = Split-Path $Prefix -Leaf
    Get-ChildItem -LiteralPath $dir -Filter "$leaf.p*.jpg" -ErrorAction SilentlyContinue | Remove-Item -Force
    $n = 24
    for ($i = 0; $i -lt $n; $i++) {
        $t = [math]::Round($i * ($Duration - 0.25) / [math]::Max(1, $n - 1), 1)
        $out = "{0}.p{1:000}.jpg" -f $Prefix, $i
        $draw = "scale=1440:1080:force_original_aspect_ratio=decrease,pad=1440:1080:(ow-iw)/2:(oh-ih)/2,drawtext=fontfile=C\\:/Windows/Fonts/consola.ttf:text='${t}s':x=24:y=24:fontsize=48:fontcolor=white:box=1:boxcolor=black@0.75"
        & $Ffmpeg -hide_banner -loglevel error -y -ss $t -i $Mp4 -frames:v 1 -vf $draw -q:v 3 $out
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg POV frame failed at ${t}s" }
    }
    $frames = @(Get-ChildItem -LiteralPath $dir -Filter "$leaf.p*.jpg" | Sort-Object Name)
    if ($frames.Count -lt 1) { throw "no POV frames for $Mp4" }
    $frames
}

function Coalesce-Ranges($items, [double]$Gap = 2) {
    $sorted = @($items | Where-Object { $_ } | Sort-Object { [double]$_.in })
    if ($sorted.Count -eq 0) { return @() }
    $out = @()
    $cur = [pscustomobject]@{ in = [double]$sorted[0].in; out = [double]$sorted[0].out; why = $sorted[0].why }
    foreach ($item in $sorted | Select-Object -Skip 1) {
        $inn = [double]$item.in
        $outt = [double]$item.out
        if ($inn -le $cur.out + $Gap) {
            if ($outt -gt $cur.out) { $cur.out = $outt }
            if ($item.why -and $cur.why -notlike "*$($item.why)*") {
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
            in = [math]::Round($_.in, 2)
            out = [math]::Round($_.out, 2)
            why = $_.why
        }
    }
}

function Shift-Ranges($items, [double]$Offset) {
    @($items | ForEach-Object {
        if (-not $_) { return }
        [pscustomobject]@{
            in = [math]::Round(([double]$_.in) + $Offset, 2)
            out = [math]::Round(([double]$_.out) + $Offset, 2)
            why = $_.why
        }
    })
}

function Split-CopyParts([string]$Src, [string]$Prefix, [int]$PartCount, [double]$Duration) {
    $seg = [math]::Max(1, [math]::Floor($Duration / $PartCount))
    $parts = @()
    $offset = 0.0
    for ($i = 1; $i -le $PartCount; $i++) {
        $out = "{0}_part{1}.mp4" -f $Prefix, $i
        $ss = ($i - 1) * $seg
        if ($i -eq $PartCount) {
            & $Ffmpeg -hide_banner -loglevel error -y -ss $ss -i $Src -c copy $out
        } else {
            & $Ffmpeg -hide_banner -loglevel error -y -ss $ss -t $seg -i $Src -c copy $out
        }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) {
            throw "ffmpeg -c copy split failed for part $i"
        }
        $dur = Read-Duration $out
        $parts += [pscustomobject]@{
            index = $i
            path = $out
            offset_s = [math]::Round($offset, 2)
            duration_s = $dur
        }
        $offset += $dur
    }
    $parts
}

function Read-Duration([string]$Mp4) {
    $ffprobe = Join-Path (Split-Path $Ffmpeg) "ffprobe.exe"
    $raw = & $ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $Mp4
    [math]::Round([double]$raw, 1)
}

function Get-InstructionBlock([string]$Name) {
    if (-not (Test-Path -LiteralPath $instructionsPath)) { return "" }
    $text = Get-Content -LiteralPath $instructionsPath -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $rules = $text
    $goldAt = $text.IndexOf('## Gold')
    if ($goldAt -ge 0) {
        $rules = $text.Substring(0, $goldAt).Trim()
        $gold = $text.Substring($goldAt)
        $stem = [IO.Path]::GetFileNameWithoutExtension($Name)
        $block = ""
        foreach ($part in ($gold -split '(?m)^### ')) {
            if ($part -and $part.Contains($stem)) { $block = '### ' + $part.Trim(); break }
        }
        if ($block) { $rules = $rules + "`n`nGOLD FOR THIS FILE ONLY:`n" + $block }
    }
    return "OPERATOR LAW:`n$rules"
}

function Invoke-Vl([object[]]$Frames, [string]$Name, [double]$Duration) {
    $notes = Get-InstructionBlock $Name
    $prompt = @"
Mark KEEP vs DROP on this Counter-Strike 2 Shadowplay DVR.

File: $Name
Duration: ${Duration}s (usually ~120s / 2:00).

You get $($Frames.Count) POV frames at 1440x1080 (same as the DVR). Each frame is labeled with seconds. The tiny contact sheet is NOT your evidence.

Do not reuse times from another file. Gold below applies only if the filename matches.

Rules:
- Kill feed is not evidence. Only gunfire, blood, or a body you can SEE in the local POV.
- After local death the POV is black ~3s. Drop that.
- Full-white flash POV is drop until the world is visible again.
- Freeze time (buy, orange bar, black map, killed-you panel) is drop.
- KEEP is 1-5 seconds per visible fight. Many fights => many keeps.
- Opening spray while spectating still counts if it is on screen.
- Falling body with no shot on screen: keep or drop both OK.
- Metronome keeps are a fail.

$notes

Return ONLY JSON. keep is an array of {in,out,why} in seconds. If there is no visible fight, keep is []. Never copy example numbers — there are none. Shape:
{"file":"$Name","duration_s":$Duration,"keep":[],"drop":[]}
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
        messages = @(
            @{ role = "user"; content = $content }
        )
    } | ConvertTo-Json -Depth 8 -Compress
    $resp = Invoke-RestMethod -Method Post -Uri $Endpoint -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 240
    $text = [string]$resp.choices[0].message.content
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { throw "VL did not return JSON: $text" }
    $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
}

function Invoke-VlVideo([string]$LocalMp4, [string]$Name, [double]$Duration, [double]$Offset = 0, [int]$PartIndex = 0, [int]$PartCount = 1) {
    $notes = Get-InstructionBlock $Name
    $uri = "file:///" + ($LocalMp4 -replace '\\', '/')
    $origEnd = [math]::Round($Offset + $Duration, 1)
    $chunkNote = if ($PartCount -gt 1 -and $PartIndex -gt 0) {
        @"
You are watching PART $PartIndex of $PartCount of the SAME original DVR (stream-copy split at ~$([int]$Duration)s, keyframe-aligned).
Original file: $Name
This part duration: ${Duration}s. Local t=0 is original t=$Offset. Local t=$Duration is original t=$origEnd.
A duel may start at the end of this part and continue in the next part — mark only what is VISIBLE here. Do not invent the rest of the round. Do not reuse keep times from other parts.
Report in/out in LOCAL seconds (0..$Duration). If gold is in original-file seconds, subtract $Offset. Ignore gold outside $Offset..$origEnd.
CRITICAL: Freeze or buy-menu at the START of this part does not make the whole part DROP. Watch every labeled frame through local t=$Duration. keep=[] is only allowed if none of the frames show a fight. If gold has a KEEP in $Offset..$origEnd, you MUST output it (local = original - $Offset).
"@
    } else { "This is the full clip." }
    $prompt = @"
Mark KEEP vs DROP on this Counter-Strike 2 Shadowplay DVR.

File: $Name
Duration: ${Duration}s
$chunkNote

The server sampled this local mp4 (file://) at its configured fps, capped at 60 frames, each ~0.3 MP, seconds painted on the frame. This is native video ingest, not a contact sheet. If zoom>1 the frames are a VLC-style CENTER CROP scaled back to the same 0.3 MP (minimap / outer HUD may be out of frame). Scoreboard filling the shot is still freeze = DROP. A teammate's back filling the frame is not a fight unless you also see shots or a body drop.

Do not reuse times from another file. Gold below applies only if the filename matches.

Rules:
- Kill feed names are not evidence. HUD money IS: +$ / neutralizing / ammo dropping / muzzle flash / silhouette in a scoped AWP circle = KEEP even if the enemy is a speck or already gone.
- After local death the POV is black ~3s. Drop that.
- Full-white flash POV is drop until the world is visible again.
- Freeze time (buy, orange bar, black map, killed-you panel, ROUND WON) is drop.
- KEEP is 1-5 seconds per visible fight. Many fights => many keeps.
- Opening spray while spectating still counts if it is on screen.
- Falling body with no shot on screen: keep or drop both OK.
- Metronome keeps are a fail.
- Unscoped AWP + empty street + +$ already on HUD = the frag was the previous second. Do not keep the walk. Do not skip the earlier scoped frame.

$notes

Return ONLY JSON. keep is an array of {in,out,why} in seconds. If there is no visible fight, keep is []. Never invent times from a template. Shape:
{"file":"$Name","duration_s":$Duration,"keep":[],"drop":[]}
"@
    $body = @{
        model = $Model
        temperature = 0.2
        max_tokens = 800
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
    $text = [string]$resp.choices[0].message.content
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { throw "VL did not return JSON: $text" }
    $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
}

function Invoke-VlWindowed([object[]]$Frames, [string]$Name, [double]$Duration) {
    $keeps = @(); $drops = @()
    for ($i = 0; $i -lt $Frames.Count; $i += 3) {
        $chunk = @($Frames | Select-Object -Skip $i -First 3)
        Write-Host ("  VL chunk {0}-{1}" -f $i, ($i + $chunk.Count - 1))
        $part = Invoke-Vl $chunk $Name $Duration
        $keeps += @($part.keep)
        $drops += @($part.drop)
    }
    [pscustomobject]@{
        file = $Name
        duration_s = $Duration
        keep = @($keeps | Where-Object { $_ -and ([double]$_.out - [double]$_.in -gt 0 -or [double]$_.in -gt 0) })
        drop = @($drops | Where-Object { $_ -and ([double]$_.out -gt [double]$_.in) })
    }
}

Wait-Vl
$all = @(Get-ClipNames)
if ($Match) { $all = @($all | Where-Object { $_ -like "*$Match*" }) }
$index = @()
if (Test-Path -LiteralPath $indexPath) {
    try { $index = @(Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json) } catch { $index = @() }
}
if ($Force -and $Match) {
    $index = @($index | Where-Object { $_.file -notlike "*$Match*" })
}
$done = [System.Collections.Generic.HashSet[string]]::new([string[]]@($index | ForEach-Object { $_.file }))
if (-not $Force) { $all = @($all | Where-Object { -not $done.Contains($_) }) }
if ($Limit -gt 0) { $all = $all | Select-Object -First $Limit }

Write-Output "VL ready. clips=$($all.Count). POV frames ~1152x864. sheet is receipt only."

foreach ($name in $all) {
    if (-not $Force -and $done.Contains($name)) { Write-Output "skip $name"; continue }
    $safe = ($name -replace '[^a-zA-Z0-9._-]', '_')
    $local = Join-Path $scratch $safe
    $sheet = Join-Path $OutDir "$safe.sheet.jpg"
    $prefix = Join-Path $OutDir $safe
    $jsonPath = Join-Path $OutDir "$safe.json"
    $existing = Join-Path $OutDir $name
    $copied = $false
    if (Test-Path -LiteralPath $existing) {
        $local = $existing
        Write-Output "local $local"
    } else {
        Write-Output "copy $name"
        rclone copyto ($Remote + "/" + $name) $local --ignore-checksum
        if (-not (Test-Path -LiteralPath $local)) { throw "rclone copyto missed $name" }
        $copied = $true
    }
    try {
        $duration = Read-Duration $local
        New-ContactSheet $local $sheet
        $nParts = $Parts
        if ($duration -lt 80) { $nParts = 1 }
        $keepAll = @()
        $dropAll = @()
        $partMeta = @()
        $partFiles = @()
        if ($nParts -gt 1) {
            $split = @(Split-CopyParts $local $prefix $nParts $duration)
            foreach ($p in $split) {
                Write-Output ("part {0} offset={1}s dur={2}s" -f $p.index, $p.offset_s, $p.duration_s)
                if ($NativeVideo) {
                    $partResult = Invoke-VlVideo $p.path $name $p.duration_s $p.offset_s $p.index $nParts
                } else {
                    $partPrefix = "{0}_part{1}" -f $prefix, $p.index
                    $partFrames = @(New-PovFrames $p.path $partPrefix $p.duration_s)
                    $partResult = Invoke-VlWindowed $partFrames $name $p.duration_s
                }
                $partJson = [pscustomobject]@{
                    file = $name
                    part = $p.index
                    offset_s = $p.offset_s
                    duration_s = $p.duration_s
                    keep = @($partResult.keep)
                    drop = @($partResult.drop)
                }
                $partPath = "{0}.part{1}.json" -f $prefix, $p.index
                $partJson | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $partPath -Encoding utf8
                $partFiles += $partPath
                $keepAll += Shift-Ranges $partResult.keep $p.offset_s
                $dropAll += Shift-Ranges $partResult.drop $p.offset_s
                $partMeta += [pscustomobject]@{
                    part = $p.index
                    offset_s = $p.offset_s
                    duration_s = $p.duration_s
                    json = $partPath
                }
                Remove-Item -LiteralPath $p.path -Force -ErrorAction SilentlyContinue
            }
            $result = [pscustomobject]@{
                file = $name
                duration_s = $duration
                parts = $partMeta
                keep = @(Coalesce-Ranges $keepAll 2)
                drop = @(Coalesce-Ranges $dropAll 2)
            }
        } elseif ($NativeVideo) {
            Write-Output "native video_url file:// ($local)"
            $result = Invoke-VlVideo $local $name $duration
        } else {
            $frames = @(New-PovFrames $local $prefix $duration)
            Write-Output ("pov frames={0}" -f $frames.Count)
            $result = Invoke-VlWindowed $frames $name $duration
        }
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding utf8
        $index = @($index | Where-Object { $_.file -ne $name })
        $index += [pscustomobject]@{
            file = $name
            duration_s = $duration
            json = $jsonPath
            parts = $partFiles
            sheet = $sheet
            drop = @($result.drop)
            keep = @($result.keep)
            at = (Get-Date).ToUniversalTime().ToString("o")
        }
        $index | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $indexPath -Encoding utf8
        Write-Output ("ok {0} parts={1} drop={2} keep={3}" -f $name, $nParts, @($result.drop).Count, @($result.keep).Count)
    } finally {
        if ($copied) {
            Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Output "DONE review $OutDir\index.json and the .sheet.jpg files"
Write-Output "Write misses into $instructionsPath then rerun (already-done names are skipped)"
