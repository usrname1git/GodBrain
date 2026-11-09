[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Media-Tools.ps1')
$work = Join-Path $script:GodBrainMediaRoot ('build\media_cut\fixtures-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $work) { throw 'Fixture directory already exists.' }
[void][IO.Directory]::CreateDirectory($work)
$ffmpeg = Get-GodBrainMediaExecutable ffmpeg
$ffprobe = Get-GodBrainMediaExecutable ffprobe
function Run-MediaFixture([string[]]$Arguments) {
    $data = & $ffmpeg -hide_banner -nostdin -v error @Arguments
    if ($LASTEXITCODE) { throw 'Synthetic fixture FFmpeg failed.' }
    return $data
}
function Must-Fail([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected explicit failure.' }
}
try {
    $tone = "if(lt(t,1)+gte(t,2),0.2*sin(2*PI*440*t),0)"
    $interior = Join-Path $work ('voice [test] ' + [char]0x00e5 + '.wav')
    Run-MediaFixture @('-f','lavfi','-i',"aevalsrc='$tone':s=48000:d=3",'-c:a','pcm_s16le',$interior) | Out-Null
    $sourceHash = (Get-FileHash -LiteralPath $interior).Hash
    $preview = ffcut $interior -Plan
    if ($preview.status -ne 'planned' -or $preview.keep.Count -ne 2) { throw 'Interior plan failed.' }
    $cut = ffcut $interior
    if ($cut.status -ne 'created' -or [Math]::Abs($cut.output_seconds - 2.2) -gt 0.002) { throw 'Sample-bound interior cut failed.' }
    if ((Get-FileHash -LiteralPath $interior).Hash -ne $sourceHash -or
        $cut.source_sha256 -cne $sourceHash.ToLowerInvariant()) { throw 'Source/hash changed.' }
    $stored = Get-Content -LiteralPath ($cut.output + '.cut.json') -Raw | ConvertFrom-Json
    if ($stored.output -cne $cut.output) { throw 'Committed receipt mismatch.' }
    $outputHash = (Get-FileHash -LiteralPath $cut.output).Hash
    if ((ffcut $interior -Plan).status -ne 'planned') { throw 'Read-only planning was blocked by an existing derivative.' }
    Must-Fail { ffcut $interior }
    Must-Fail { ffcut $interior -OutputFile $interior }
    if ((Get-FileHash -LiteralPath $cut.output).Hash -ne $outputHash) { throw 'Existing output was overwritten.' }

    $edges = Join-Path $work 'edges.wav'
    Run-MediaFixture @('-f','lavfi','-i',"aevalsrc='if(between(t,0.5,2.5),0.2*sin(2*PI*440*t),0)':s=48000:d=3",'-c:a','pcm_s16le',$edges) | Out-Null
    if ([Math]::Abs((ffcut $edges).output_seconds - 2.2) -gt 0.002) { throw 'Leading/trailing silence failed.' }
    $stereo = Join-Path $work 'stereo.wav'
    Run-MediaFixture @('-f','lavfi','-i',"aevalsrc='0|$tone':s=48000:d=3",'-c:a','pcm_s16le',$stereo) | Out-Null
    if ([Math]::Abs((ffcut $stereo).output_seconds - 2.2) -gt 0.002) { throw 'Stereo detection treated a silent channel as global silence.' }
    if ((ffcut $stereo -OutputFile (Join-Path $work 'uppercase.WAV')).status -ne 'created') { throw 'Windows-case output extension failed.' }
    $continuous = Join-Path $work 'continuous.wav'
    Run-MediaFixture @('-f','lavfi','-i','sine=frequency=440:duration=3', $continuous) | Out-Null
    if ((ffcut $continuous).status -ne 'unchanged' -or
        (Test-Path -LiteralPath (Join-Path $work 'continuous.no-silence.wav'))) { throw 'No-silence input created an unnecessary derivative.' }
    $silent = Join-Path $work 'silent.wav'
    Run-MediaFixture @('-f','lavfi','-i','anullsrc=r=48000:cl=mono','-t','3',$silent) | Out-Null
    Must-Fail { ffcut $silent }
    if (Test-Path -LiteralPath (Join-Path $work 'silent.no-silence.wav')) { throw 'All-silent input created an empty artifact.' }
    Must-Fail { ffcut (Join-Path $work 'missing.wav') }

    $video = Join-Path $work 'offset-vfr.mp4'
    Run-MediaFixture @('-f','lavfi','-i','color=c=black:s=96x64:r=30:d=3.25',
        '-itsoffset','0.25','-f','lavfi','-i',"aevalsrc='$tone':s=48000:d=3",
        '-vf',"drawbox=color=white:t=fill:enable='gte(t,2.25)',select='if(lt(t,1.5),1,not(mod(n,2)))'",
        '-fps_mode','vfr','-c:v','libx264','-threads','2','-c:a','aac',$video) | Out-Null
    $videoHash = (Get-FileHash -LiteralPath $video).Hash
    $videoCut = ffcut $video
    $frames = & $ffprobe -v error -select_streams v -show_entries frame=best_effort_timestamp_time -of json $videoCut.output | ConvertFrom-Json
    if ($LASTEXITCODE) { throw 'VFR output frame probe failed.' }
    $times = @($frames.frames | ForEach-Object { [double]$_.best_effort_timestamp_time })
    $deltas = @(for ($i=1; $i -lt $times.Count; $i++) { [Math]::Round($times[$i]-$times[$i-1],3) })
    if (($deltas | Select-Object -Unique).Count -lt 2) { throw 'VFR was flattened.' }
    $videoMetadata = Run-MediaFixture @('-i',$videoCut.output,'-vf','signalstats,metadata=mode=print:key=lavfi.signalstats.YAVG:file=-','-an','-f','null','NUL')
    $time = 0; $firstWhite = $null
    foreach ($line in $videoMetadata) {
        if ($line -match 'pts_time:([0-9.]+)') { $time = [double]$Matches[1] }
        if ($line -match '^lavfi.signalstats.YAVG=([0-9.]+)' -and [double]$Matches[1] -gt 200 -and $null -eq $firstWhite) { $firstWhite = $time }
    }
    $audioMetadata = Run-MediaFixture @('-i',$videoCut.output,'-map','0:a:0','-af',
        'silencedetect=noise=-40dB:duration=0.1,ametadata=mode=print:key=lavfi.silence_end:file=-','-f','null','NUL')
    $ends = @($audioMetadata | Where-Object { $_ -match '^lavfi.silence_end=' } | ForEach-Object { [double]($_.Split('=')[1]) } | Sort-Object)
    if ($null -eq $firstWhite -or $ends.Count -lt 2 -or [Math]::Abs($firstWhite - $ends[-1]) -gt 0.07) {
        throw "A/V event alignment failed: video=$firstWhite audio=$($ends -join ',')"
    }
    if ((Get-FileHash -LiteralPath $video).Hash -ne $videoHash) { throw 'Original video changed.' }
    $noAudio = Join-Path $work 'no-audio.mp4'
    Run-MediaFixture @('-f','lavfi','-i','color=c=black:s=96x64:r=30:d=1','-c:v','libx264',$noAudio) | Out-Null
    Must-Fail { ffcut $noAudio }
    $script:downloadFixture = Join-Path $work 'download.ps1'
    [IO.File]::WriteAllText($script:downloadFixture, '$global:CapturedDownloadArguments = $args; $global:LASTEXITCODE = 0')
    function Get-GodBrainMediaExecutable([string]$Name) {
        if ($Name -eq 'yt-dlp') { return $script:downloadFixture }
        if ($Name -eq 'node') { return 'C:\Program Files\nodejs\node.exe' }
        return "C:\Tools\ffmpeg\$Name.exe"
    }
    $literal = 'https://example.invalid/video?id=one&literal=$(throw "must not evaluate")'
    Save-WebVideo $literal -Directory (Join-Path $work 'downloads')
    if ($global:CapturedDownloadArguments[-1] -cne $literal -or
        $global:CapturedDownloadArguments[-2] -cne '--' -or
        $global:CapturedDownloadArguments -notcontains '--ignore-config' -or
        $global:CapturedDownloadArguments -contains '--cookies-from-browser') { throw 'Download URL was interpreted or cookie access introduced.' }
    Must-Fail { Save-WebVideo 'file:///C:/private.txt' }
    'PASS: padded/sample-bound cuts, edges, stereo, no/all-silence, Unicode/literal paths, source/receipt/no-overwrite, VFR and delayed A/V event alignment, unsupported/no-audio failures, and literal download arguments. CPU synthetic fixtures only.'
} finally {
    if ((Split-Path $work -Leaf) -notmatch '^fixtures-[a-f0-9]{32}$') { throw 'Refusing unknown cleanup scope.' }
    Remove-Item -LiteralPath $work -Recurse -Force
}
