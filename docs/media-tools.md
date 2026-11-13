# Local media commands

Dot-source `scripts\Media-Tools.ps1` from the PowerShell profile. Build the native
gap cutter with `scripts\Build-MediaCut.ps1`.

```powershell
ytdl 'https://example.org/video'
ffcut '.\recording.mp4'
ffcut '.\recording.mp4' -Plan
ffcut '.\recording.mp4' -MinimumGap 0.3 -NoiseDb -45 -Padding 0.08
```

`ytdl` downloads one video at the best available quality, merges separate streams
with the existing FFmpeg, and saves under `Downloads\Media`. `-Directory` changes
the destination. URLs are arguments, never evaluated commands. Filenames are
Windows-safe; existing downloads are not overwritten. There is no automatic
browser-cookie export; these defaults ignore unrelated yt-dlp config files.
Only download media you are authorized to retrieve.

The existing Python user installation uses `yt-dlp[default]`, including EJS, and
the installed Node executable for supported JavaScript challenges. Updating it is
an explicit `py -3.13 -m pip install --user --upgrade --pre "yt-dlp[default]"`;
profile startup never installs or updates anything. The upstream nightly
recommendation does not guarantee that every site will work.

`ffcut` finds sustained silence across the audio channels and removes the same
time intervals from audio and video. Defaults: -40 dB, gaps at least 0.5 seconds,
and 0.1 seconds of padding beside speech. It writes a new `.no-silence.mp4` or
`.no-silence.wav` plus a `.cut.json` receipt. `-OutputFile` names a new destination;
existing outputs/receipts and the original are never overwritten. `-Plan` only
detects and reports intervals. No qualifying gap creates no derivative; entirely
silent input fails explicitly rather than manufacturing an empty recording.

Video is CPU-encoded H.264 (CRF 18) with AAC audio; audio-only output is 24-bit PCM.
This is a lossy video derivative, not an archival replacement. Video boundaries
are frame-limited; audio is trimmed at sample boundaries. VFR and source A/V
offsets are preserved in the shared timeline rather than independently resetting
each stream. Verify the receipt's actual duration and listen to the result before
using it. HDR, subtitle/data streams and multiple audio/video tracks require an
explicit encoding/timeline choice and are rejected rather than silently dropped.

Native child processes have bounded output, timeouts, a 2 GiB job-memory ceiling,
restricted handle inheritance and exact-job termination. More than 512 silent gaps fails explicitly; increase
`-MinimumGap` for very fragmented recordings. FFmpeg itself remains available
unchanged for commands outside this helper's deliberately narrow scope.
