[CmdletBinding()]
param([switch]$Media, [string]$RealSource)
$ErrorActionPreference = "Stop"
if ($RealSource -and -not $Media) { throw "-RealSource requires -Media." }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("godbrain-deadtime-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($fixture)
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Fails([scriptblock]$Action, [string]$Pattern = "*") {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure: $Pattern"
}
function New-Completion([string]$Json, [string]$Finish = "stop") {
    @{ model = $Model; choices = @(@{ finish_reason = $Finish; message = @{ content = $Json } }) }
}
try {
    $tokens = $null; $parseErrors = $null
    $deskAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot "Show-DeskMenu.ps1"), [ref]$tokens, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) "Desk syntax failed."
    $clipAction = $deskAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Start-ClipScan"
    }, $true)
    $launch = $clipAction.Find({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq "Start-Process"
    }, $true)
    $Repo = Split-Path $PSScriptRoot -Parent
    $Pwsh = "C:\pwsh\pwsh.exe"
    $scan = Join-Path $PSScriptRoot "Scan-Cs2Deadtime.ps1"
    function Start-Process {
        param($FilePath, [string[]]$ArgumentList, $WorkingDirectory, $WindowStyle)
        $script:deskLaunch = $ArgumentList
    }
    & ([scriptblock]::Create($launch.Extent.Text))
    Remove-Item -LiteralPath "Function:\Start-Process"
    $limitAt = [array]::IndexOf($script:deskLaunch, "-Limit")
    Assert ($limitAt -ge 0 -and $script:deskLaunch[$limitAt + 1] -ceq "3" -and
        $script:deskLaunch -contains $scan -and $script:deskLaunch -contains "-NativeVideo") "Desk launch did not request the bounded scanner pilot."

    . (Join-Path $PSScriptRoot "Scan-Cs2Deadtime.ps1") -OutDir $fixture -NativeVideo
    Assert (-not (Test-Path -LiteralPath $scratch)) "Import started scanner filesystem work."
    $valid = '{"file":"fixture.mp4","duration_s":10,"keep":[{"in":2,"out":4,"why":"shots"}],"drop":[]}'
    $parsed = ConvertFrom-VlCompletion (New-Completion $valid) "fixture.mp4" 10
    Assert ($parsed.keep.Count -eq 1 -and $parsed.keep[0].in -eq 2) "Valid inference was not accepted."
    $validEmpty = ConvertFrom-VlCompletion (New-Completion '{"file":"fixture.mp4","duration_s":10,"keep":[],"drop":[]}') "fixture.mp4" 10
    Assert ($validEmpty.keep.Count -eq 0 -and $validEmpty.drop.Count -eq 0) "Valid empty arrays were rejected."
    foreach ($bad in @(
        $valid.Replace('"in":2', '"in":"2"'),
        $valid.Replace('"in":2', '"in":-1'),
        $valid.Replace('"out":4', '"out":2'),
        $valid.Replace('"out":4', '"out":11'),
        $valid.Replace('"file":"fixture.mp4"', '"file":"another.mp4"'),
        $valid.Replace('"duration_s":10', '"duration_s":20'),
        $valid.Replace('"keep":[', '"extra":true,"keep":['),
        $valid.Replace('"in":2', '"in":2,"in":3'),
        ("explanation " + $valid), ($valid + "{}"),
        '{"file":"fixture.mp4","duration_s":10,"keep":null,"drop":[]}',
        '{"file":"fixture.mp4","duration_s":10,"keep":[{"in":NaN,"out":4,"why":"bad"}],"drop":[]}',
        '{"file":"fixture.mp4","duration_s":10,"keep":[]'
    )) {
        Assert-Fails { ConvertFrom-VlCompletion (New-Completion $bad) "fixture.mp4" 10 }
    }
    Assert-Fails { ConvertFrom-VlCompletion (New-Completion $valid "length") "fixture.mp4" 10 } "*completion failed*"
    Assert-Fails { ConvertFrom-VlCompletion (New-Completion $valid) "fixture.mp4" 10 5 8 } "*outside supplied evidence*"
    $changedModel = New-Completion $valid
    $changedModel.model = "not-the-requested-model"
    Assert-Fails { ConvertFrom-VlCompletion $changedModel "fixture.mp4" 10 } "*changed model*"
    $toolReply = New-Completion $valid
    $toolReply.choices[0].message.tool_calls = @(@{ id = "unrequested" })
    Assert-Fails { ConvertFrom-VlCompletion $toolReply "fixture.mp4" 10 } "*completion failed*"

    [IO.File]::WriteAllText($instructionsPath, @'
# General rules
Keep visible action.
## Gold
### fixture.mp4 (~120s)
UNIQUE_GOLD_58_62
### other.mp4 (~120s)
OTHER_FILE_LABEL
'@)
    Assert ((Get-InstructionBlock "fixture.mp4" -IncludeGold) -match "UNIQUE_GOLD_58_62") "Decorated Gold heading did not match."
    Assert ((Get-InstructionBlock "fixture.mp4") -notmatch "UNIQUE_GOLD|OTHER_FILE") "Blind prompt leaked Gold."
    Assert ((Get-InstructionBlock "unknown.mp4" -IncludeGold) -notmatch "UNIQUE_GOLD|OTHER_FILE") "Another file's Gold leaked."
    $firstProfile = Get-ScanProfile @{ pid = 7 }
    [IO.File]::AppendAllText($instructionsPath, "`nExtra Gold detail.")
    Assert ((Get-ScanProfile @{ pid = 7 }).hash -ceq $firstProfile.hash) "Unused Gold invalidated a blind profile."
    Assert ((Get-ScanProfile @{ pid = 8 }).hash -cne $firstProfile.hash) "Runtime identity did not invalidate cache."
    [IO.File]::WriteAllText($instructionsPath, ([IO.File]::ReadAllText($instructionsPath).Replace("Keep visible action.", "Keep visible action and preserve uncertainty.")))
    Assert ((Get-ScanProfile @{ pid = 7 }).hash -cne $firstProfile.hash) "Changed rules did not invalidate cache."

    $resolved = Resolve-ClipRanges $parsed.keep @(
        [pscustomobject]@{ in = 0; out = 3; why = "idle" },
        [pscustomobject]@{ in = 6; out = 8; why = "idle" }) 10
    Assert ($resolved.state -ceq "needs_review" -and $resolved.conflicts.Count -eq 1 -and
        $resolved.drop[0].out -eq 2 -and $resolved.uncertain.Count -eq 2 -and
        $resolved.retain[0].in -eq 2 -and $resolved.retain[0].out -eq 6) "Conflict/unknown handling discarded action or uncertainty."
    foreach ($keep in $resolved.keep) {
        foreach ($drop in $resolved.drop) {
            Assert ([math]::Max($keep.in, $drop.in) -ge [math]::Min($keep.out, $drop.out)) "KEEP/DROP overlap survived resolution."
        }
    }
    $empty = Resolve-ClipRanges @() @() 10
    Assert ($empty.state -ceq "needs_review" -and $empty.retain[0].out -eq 10) "Empty detection silently discarded a clip."
    $separated = @(Coalesce-Ranges @(
        [pscustomobject]@{ in = 0; out = 1; why = "idle" },
        [pscustomobject]@{ in = 2; out = 3; why = "idle" }))
    Assert ($separated.Count -eq 2) "Unseen time was fabricated as DROP."

    $cachePath = Join-Path $fixture "cache.json"
    Write-ScanJson @{ schema_version = "cs2-deadtime-v2"; file = "fixture.mp4"; state = "complete"
        source_sha256 = "source"; profile_sha256 = "profile"; sanitized = $false } $cachePath
    $cache = [pscustomobject]@{ schema_version = "cs2-deadtime-v2"; file = "fixture.mp4"; state = "complete"
        source_sha256 = "source"; profile_sha256 = "profile"; json = $cachePath
        result_sha256 = (Get-FileHash -LiteralPath $cachePath).Hash }
    Assert (Test-ScanCache $cache "source" "profile") "Identical bound receipt did not cache."
    Assert (-not (Test-ScanCache $cache "changed-source" "profile")) "Changed source reused cache."
    Assert (-not (Test-ScanCache $cache "source" "changed-profile")) "Changed profile reused cache."
    Assert (-not (Test-ScanCache ([pscustomobject]@{ file = "fixture.mp4" }) "source" "profile")) "Legacy filename-only result reused cache."
    [IO.File]::AppendAllText($cachePath, " ")
    Assert-Fails { Test-ScanCache $cache "source" "profile" } "*content changed*"

    $originalFunctions = @{}
    foreach ($name in @("Read-Duration", "Wait-Vl", "Get-ScanRuntime", "New-ContactSheet")) {
        $originalFunctions[$name] = (Get-Item "Function:\$name").ScriptBlock
    }
    $script:runtimeReads = 0; $script:runtimePid = 7; $script:runtimeChangeOnRead = 0
    $script:changeDuringInference = $false; $script:changeRulesDuringInference = $false; $script:vanishPath = ""
    function Wait-Vl {
        if ($script:vanishPath) { Remove-Item -LiteralPath $script:vanishPath }
        return @{ id = $Model }
    }
    function Get-ScanRuntime {
        $script:runtimeReads++
        if ($script:runtimeChangeOnRead -and $script:runtimeReads -ge $script:runtimeChangeOnRead) {
            $script:runtimePid = 8
        }
        return @{ pid = $script:runtimePid }
    }
    function Read-Duration { param($Mp4); return 10.0 }
    function New-ContactSheet { param($Mp4, $Sheet); [IO.File]::WriteAllText($Sheet, "fixture sheet") }
    $script:modelCalls = 0
    function Invoke-RestMethod {
        param($Method, $Uri, $ContentType, $Body, $TimeoutSec)
        Assert ($Method -ceq "Post" -and $Uri -ceq $Endpoint) "Offline test tried an unexpected HTTP call."
        $request = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        $name = [regex]::Match($request.messages[0].content[0].text, '(?m)^File: (.+)\r?$').Groups[1].Value.Trim()
        $script:modelCalls++
        if ($script:changeDuringInference) { $script:runtimePid = 8 }
        if ($script:changeRulesDuringInference) {
            $rules = [IO.File]::ReadAllText($instructionsPath)
            [IO.File]::WriteAllText($instructionsPath, $rules.Replace("Keep visible action and preserve uncertainty.", "Keep all useful action."))
        }
        if ($name -ceq "bad.mp4") { return New-Completion '{"broken":' "length" }
        return New-Completion (@{ file = $name; duration_s = 10
            keep = @(); drop = @(@{ in = 0; out = 10; why = "fixture idle" }) } | ConvertTo-Json -Depth 5)
    }
    $badPath = Join-Path $fixture "bad.mp4"; $goodPath = Join-Path $fixture "good.mp4"
    [IO.File]::WriteAllText($badPath, "bad fixture source")
    [IO.File]::WriteAllText($goodPath, "good fixture source")
    $badHash = (Get-FileHash -LiteralPath $badPath).Hash
    $goodHash = (Get-FileHash -LiteralPath $goodPath).Hash
    $InputFile = @($badPath, $goodPath); $Limit = 0
    $legacy = Join-Path $fixture "index.json"
    [IO.File]::WriteAllText($legacy, '[{"file":"legacy.mp4","keep":[]}]')
    $legacyBytes = [IO.File]::ReadAllText($legacy)
    Assert-Fails { Invoke-Cs2DeadtimeScan } "*1 clip(s) failed*"
    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
    Assert ($index.Count -eq 2 -and $index[0].state -ceq "failed" -and
        $index[1].state -ceq "complete" -and $script:modelCalls -eq 2) "Failed clip blocked another clip or was counted as complete."
    $failedReceipt = Get-Content -LiteralPath $index[0].json -Raw | ConvertFrom-Json
    $goodReceipt = Get-Content -LiteralPath $index[1].json -Raw | ConvertFrom-Json
    Assert ($failedReceipt.PSObject.Properties.Name -notcontains "keep") "Failed inference became an empty successful selection."
    Assert (-not $goodReceipt.sanitized -and -not $goodReceipt.model_qualified) "Schema-valid detection was labelled sanitized."
    Assert ((Get-FileHash -LiteralPath $badPath).Hash -ceq $badHash -and
        (Get-FileHash -LiteralPath $goodPath).Hash -ceq $goodHash -and
        [IO.File]::ReadAllText($legacy) -ceq $legacyBytes) "Originals or historical index changed."
    $InputFile = @($goodPath)
    Invoke-Cs2DeadtimeScan | Out-Null
    Assert ($script:modelCalls -eq 2) "Bound cache hit repeated inference."
    [IO.File]::AppendAllText($goodPath, " changed")
    Invoke-Cs2DeadtimeScan | Out-Null
    Assert ($script:modelCalls -eq 3) "Changed source did not reanalyze."
    $InputFile = @($goodPath)
    foreach ($number in 1..3) {
        $pilot = Join-Path $fixture "pilot$number.mp4"
        [IO.File]::WriteAllText($pilot, "pilot fixture $number")
        $InputFile += $pilot
    }
    $Limit = 3
    Invoke-Cs2DeadtimeScan | Out-Null
    $pilotIndex = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
    Assert ($script:modelCalls -eq 5 -and -not ($pilotIndex | Where-Object file -CEQ "pilot3.mp4")) "Bounded pilot exceeded its input limit."
    $InputFile = @($goodPath); $Limit = 0
    $script:runtimeReads = 0; $script:runtimeChangeOnRead = 2
    Assert-Fails { Invoke-Cs2DeadtimeScan } "*1 clip(s) failed*"
    Assert ($script:modelCalls -eq 5) "Changed runtime reused a cache or performed inference."
    $script:runtimePid = 7; $script:runtimeChangeOnRead = 0; $script:changeDuringInference = $true
    Assert-Fails { Invoke-Cs2DeadtimeScan } "*1 clip(s) failed*"
    $runtimeFailure = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json |
        Where-Object file -CEQ "good.mp4"
    Assert ($runtimeFailure.state -ceq "failed") "Runtime replacement during inference was accepted."
    $script:changeDuringInference = $false; $script:runtimePid = 7
    $script:changeRulesDuringInference = $true
    Assert-Fails { Invoke-Cs2DeadtimeScan } "*1 clip(s) failed*"
    $rulesEntry = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json |
        Where-Object file -CEQ "good.mp4"
    $rulesFailure = Get-Content -LiteralPath $rulesEntry.json -Raw | ConvertFrom-Json
    Assert ($rulesFailure.error -like "*scan instructions changed*") "Changed prompt rules were bound to the old profile."
    $script:changeRulesDuringInference = $false
    $script:vanishPath = Join-Path $fixture "vanished.mp4"
    [IO.File]::WriteAllText($script:vanishPath, "temporary local fixture")
    $InputFile = @($script:vanishPath)
    function rclone { throw "Offline regression attempted a remote operation." }
    Assert-Fails { Invoke-Cs2DeadtimeScan } "*1 clip(s) failed*"
    $vanishEntry = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json |
        Where-Object file -CEQ "vanished.mp4"
    $vanishReceipt = Get-Content -LiteralPath $vanishEntry.json -Raw | ConvertFrom-Json
    Assert ($vanishReceipt.error -like "*Explicit local input disappeared*") "Missing local input was substituted remotely."
    $script:vanishPath = ""
    $singleIndexPath = Join-Path $fixture "single-index.json"
    Write-ScanJson @($cache) $singleIndexPath
    Assert (([IO.File]::ReadAllText($singleIndexPath)).TrimStart().StartsWith("[")) "Single-entry index lost its array framing."
    $lock = [IO.File]::Open((Join-Path $fixture "scan-v2.lock"), "Open", "ReadWrite", "None")
    try { Assert-Fails { Invoke-Cs2DeadtimeScan } }
    finally { $lock.Dispose() }
    [IO.File]::WriteAllText($indexPath, "[broken")
    Assert-Fails { Invoke-Cs2DeadtimeScan }
    Assert ([IO.File]::ReadAllText($indexPath) -ceq "[broken") "Corrupt index was silently reset."
    foreach ($name in $originalFunctions.Keys) {
        Set-Item -Path "Function:\$name" -Value $originalFunctions[$name]
    }
    Write-Host "PASS: dead-time response validation, Gold isolation, conservative intervals, cache binding, failure receipts and batch continuation."

    if ($Media) {
        $source = Join-Path $fixture "long-gop.mp4"
        & $Ffmpeg -hide_banner -loglevel error -n -f lavfi -i "color=c=red:s=64x64:r=10:d=2" `
            -f lavfi -i "color=c=green:s=64x64:r=10:d=2" -f lavfi -i "color=c=blue:s=64x64:r=10:d=2" `
            -filter_complex "[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]" -map "[v]" `
            -c:v libx264 -g 60 -keyint_min 60 -sc_threshold 0 -bf 0 -pix_fmt yuv420p $source
        if ($LASTEXITCODE) { throw "Synthetic long-GOP source generation failed." }
        $hash = (Get-FileHash -LiteralPath $source).Hash
        $mediaParts = @(Split-ExactParts $source (Join-Path $fixture "exact") 3 6)
        $expected = @(@(253, 0, 0), @(0, 127, 0), @(0, 0, 254))
        foreach ($part in $mediaParts) {
            $rgbPath = Join-Path $fixture ("pixel-" + $part.index + ".rgb")
            & $Ffmpeg -hide_banner -loglevel error -n -i $part.path -frames:v 1 -vf "scale=1:1" `
                -pix_fmt rgb24 -f rawvideo $rgbPath
            if ($LASTEXITCODE) { throw "Analysis-part first-pixel extraction failed." }
            $rgb = [IO.File]::ReadAllBytes($rgbPath)
            Assert ($part.offset_s -eq (($part.index - 1) * 2) -and
                [math]::Abs($part.duration_s - 2) -lt 0.05) "Long-GOP part offset/duration is wrong."
            for ($channel = 0; $channel -lt 3; $channel++) {
                Assert ([math]::Abs([int]$rgb[$channel] - $expected[$part.index - 1][$channel]) -le 12) "Long-GOP part begins on the wrong source content."
            }
        }
        Assert ((Get-FileHash -LiteralPath $source).Hash -ceq $hash) "Synthetic original changed."
        if ($RealSource) {
            $realHash = (Get-FileHash -LiteralPath $RealSource).Hash
            $realPart = Join-Path $fixture "real-part.mp4"
            New-ExactVideoPart $RealSource $realPart 58 2
            Assert ([math]::Abs((Read-Duration $realPart) - 2) -lt 0.1 -and
                (Get-FileHash -LiteralPath $RealSource).Hash -ceq $realHash) "Real-source part duration/source preservation failed."
            foreach ($sample in @(0.0, 1.0)) {
                $referencePath = Join-Path $fixture ("reference-$sample.rgb")
                $analysisPath = Join-Path $fixture ("analysis-$sample.rgb")
                $sourceTime = (58 + $sample).ToString("0.######", [Globalization.CultureInfo]::InvariantCulture)
                $partTime = $sample.ToString("0.######", [Globalization.CultureInfo]::InvariantCulture)
                & $Ffmpeg -hide_banner -loglevel error -n -ss $sourceTime -i $RealSource -frames:v 1 `
                    -vf "scale=64:48" -pix_fmt rgb24 -f rawvideo $referencePath
                if ($LASTEXITCODE) { throw "Real-source reference decode failed." }
                & $Ffmpeg -hide_banner -loglevel error -n -ss $partTime -i $realPart -frames:v 1 `
                    -vf "scale=64:48" -pix_fmt rgb24 -f rawvideo $analysisPath
                if ($LASTEXITCODE) { throw "Real-source analysis decode failed." }
                $reference = [IO.File]::ReadAllBytes($referencePath)
                $analysis = [IO.File]::ReadAllBytes($analysisPath)
                Assert ($reference.Length -gt 0 -and $reference.Length -eq $analysis.Length) "Real-source frame dimensions differ."
                $difference = 0.0
                for ($i = 0; $i -lt $reference.Length; $i++) {
                    $difference += [math]::Abs([int]$reference[$i] - [int]$analysis[$i])
                }
                Assert (($difference / $reference.Length) -lt 5) "Real-source analysis frame is not aligned with the declared source time."
            }
            Write-Host "PASS: real recording at 58s/59s matches analysis at 0s/1s, zero timestamp, duration and unchanged source."
        }
        Write-Host "PASS: long-GOP three-color timing (0/2/4s source offsets, 2s parts, correct first-frame content)."
    }
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
