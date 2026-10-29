[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "GodBrain-DeskModel.ps1")
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "Show-DeskMenu.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
foreach ($name in @("Get-DeskJailRoots", "ConvertTo-DeskAskPath", "Test-DeskGrantedPath",
    "Read-DeskGrantedBytes", "Test-DeskVisionImage", "Get-DeskAttachmentPaths", "Invoke-DeskAsk")) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Fails([scriptblock]$Action, [string]$Pattern = "*") {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure: $Pattern"
}
$fixture = Join-Path (Split-Path $PSScriptRoot -Parent) ("logs\desk-attachments-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($fixture)
$Repo = $fixture; $Kit = $fixture
try {
    & {
        Assert ((Get-Command Invoke-DeskCpuOcr).Parameters.ContainsKey("TimeoutMilliseconds")) "OCR has no injectable bounded input/output deadline."
        $script:ocrMode = "stdin"
        $ocrPidPath = Join-Path $fixture "fake-ocr.pid"
        $fakePython = (Get-Command python -ErrorAction Stop).Source
        function New-DeskCpuOcrStartInfo {
            $info = [Diagnostics.ProcessStartInfo]::new($fakePython)
            foreach ($value in @("-c", @'
import hashlib,json,os,sys,time
open(sys.argv[1], "w").write(str(os.getpid()))
mode = sys.argv[2]
if mode == "stdin":
    time.sleep(60)
if mode == "staged":
    time.sleep(1.2)
raw = sys.stdin.buffer.read()
if mode == "staged":
    time.sleep(1.2)
if mode == "output":
    print("pending", flush=True)
    time.sleep(60)
if mode == "failure":
    sys.exit(7)
if mode == "oversized":
    print("x" * (5 * 1024 * 1024), flush=True)
else:
    print(json.dumps(dict(version=1,engine="cpu",source_sha256=hashlib.sha256(raw).hexdigest(),text="fixture OCR")))
'@, $ocrPidPath, $script:ocrMode)) { $info.ArgumentList.Add($value) }
            $info.UseShellExecute = $false; $info.CreateNoWindow = $true
            $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
            Set-DeskReviewPlannerEncoding $info
            return $info
        }
        $largeBytes = [byte[]]::new(10MB)
        foreach ($mode in @("stdin", "output", "staged", "failure", "oversized")) {
            $script:ocrMode = $mode
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $pattern = if ($mode -in @("stdin", "output", "staged")) { "*CPU OCR timed out*" }
                elseif ($mode -eq "oversized") { "*CPU OCR output exceeded*" } else { "*CPU OCR failed*exit 7*" }
            Assert-Fails { Invoke-DeskCpuOcr $largeBytes -TimeoutMilliseconds 2000 } $pattern
            Assert ($clock.Elapsed.TotalSeconds -lt 6) "OCR exceeded its input/output deadline and cleanup grace."
            $childId = [int][IO.File]::ReadAllText($ocrPidPath)
            Assert (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) "OCR left its exact child running."
        }
        $script:ocrMode = "valid"
        $ocrText = Invoke-DeskCpuOcr ([byte[]]@(1,2,3)) -TimeoutMilliseconds 5000
        Assert ($ocrText -is [string] -and $ocrText -ceq "fixture OCR") "Valid OCR receipt changed."
    }
    $original = "state=enabled`r`nvalue=$([char]0xe5)`r`n"
    foreach ($encoding in @([Text.UTF8Encoding]::new($false), [Text.UTF8Encoding]::new($true),
        [Text.UnicodeEncoding]::new($false, $true), [Text.UnicodeEncoding]::new($true, $true))) {
        $bytes = [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($original))
        $decoded = ConvertFrom-DeskAttachmentBytes $bytes
        Assert ($decoded.Text -ceq $original) "Attachment decoding changed source text."
    }
    foreach ($bytes in @(
        [byte[]]@(), [byte[]]@(239,187,191), [byte[]]@(255,254,0,216),
        [byte[]]@(255,255), [byte[]]@(77,90,0), [byte[]]@(255,254,0,0,65,0,0,0))) {
        Assert-Fails { ConvertFrom-DeskAttachmentBytes $bytes }
    }
    $a = Join-Path $fixture "a.txt"; $b = Join-Path $fixture "b.ps1"
    [IO.File]::WriteAllText($a, "state=enabled`nvalue=42`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($b, "state=disabled`nvalue=42`n", [Text.UnicodeEncoding]::new($false, $true))
    $paths = Get-DeskAttachmentPaths @($a, $a.ToUpperInvariant(), $b)
    Assert ($paths.Count -eq 2) "Attachment deduplication changed."
    Assert-Fails { Get-DeskAttachmentPaths @($fixture) } "*not a readable file*"
    Assert-Fails { Get-DeskAttachmentPaths @("C:\Windows\win.ini") } "*outside the kernel file jail*"
    Assert-Fails { Get-DeskAttachmentPaths @((Join-Path $fixture "missing.txt")) } "*not a readable file*"
    Assert-Fails { Read-DeskGrantedBytes $a 1 "Attachment" } "*between*"
    $junction = Join-Path $fixture "outside-jail"
    [void](New-Item -ItemType Junction -Path $junction -Target $env:windir)
    try {
        $escaped = Join-Path $junction "System32\kernel32.dll"
        Assert ((Get-DeskAttachmentPaths @($escaped)).Count -eq 1) "Junction fixture is not lexically granted."
        Assert-Fails { Read-DeskGrantedBytes $escaped 1MB "Attachment" } "*resolves outside the kernel file jail*"
    } finally { [IO.Directory]::Delete($junction) }
    $many = @(1..9 | ForEach-Object {
        $path = Join-Path $fixture "$_.txt"; [IO.File]::WriteAllText($path, "fixture"); $path
    })
    Assert-Fails { Get-DeskAttachmentPaths $many } "*at most eight*"

    & {
        $script:posts = @(); $script:plans = @(); $script:finish = "stop"
        $script:changed = $false; $script:split = $false; $script:busy = $false; $script:tools = $null
        $script:finishSequence = @(); $script:context = 8192; $script:promptTokens = 120
        $script:busyAfterFirst = $false
        function Invoke-RestMethod {
            param($Uri, $Method, $Body, $ContentType, $TimeoutSec)
            $model = "qwen3.8-27b-exl3-3.5bpw"
            if ($Uri -like "*/health") {
                return @{ backend="exl3"; model=$model; context_length=$script:context
                    busy=($script:busy -or ($script:busyAfterFirst -and $script:posts.Count -gt 0)) }
            }
            if ($Uri -like "*/models") { return @{ data=@(@{id=$model; supported_reasoning_efforts=@("low","medium","xhigh")}) } }
            $script:posts += ($Body | ConvertFrom-Json)
            if ($script:changed) { [IO.File]::WriteAllText($a, "changed") }
            $finish = $script:finish
            if ($script:finishSequence.Count) {
                $finish = $script:finishSequence[0]
                $script:finishSequence = @($script:finishSequence | Select-Object -Skip 1)
            }
            $content = if ($finish -eq "length") { "PRIVATE_DRAFT" }
                elseif ($finish -eq "empty") { "" } else { "A:1 enabled; B:1 disabled" }
            return @{ choices=@(@{finish_reason=$(if($finish -eq "empty"){"stop"}else{$finish})
                    message=@{content=$content; reasoning_content="PRIVATE_REASONING"; tool_calls=$script:tools}})
                usage=@{prompt_tokens=$script:promptTokens; completion_tokens=12} }
        }
        function Invoke-DeskReviewPlanner {
            param($Request)
            $script:plans += ($Request | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
            $messages = @(@{role="system";content="Untrusted evidence; no tools"},@{role="user";content="A and B"})
            if ($Request.op -eq "completion") { return @{messages=$Request.messages;prompt_tokens=120} }
            if ($Request.op -eq "attachment-synthesis") { return @{messages=$messages;prompt_tokens=120} }
            $documents = @()
            $i = 0
            foreach ($source in $Request.sources) {
                $documents += @{id=[string][char](65+$i); name=$source.name; kind=$source.kind
                    sha256=$source.sha256; encoding=$source.encoding; lines=2}
                $i++
            }
            $chunks = @(@{coverage=@(@{id="A";start=1;end=2},@{id="B";start=1;end=2});messages=$messages;prompt_tokens=120})
            if ($script:split) {
                $chunks = @(1..2 | ForEach-Object {
                    @{coverage=@(@{id="A";start=$_;end=$_},@{id="B";start=$_;end=$_});messages=$messages;prompt_tokens=120}
                })
            }
            return @{documents=$documents;context=$script:context;chunks=$chunks}
        }
        $answer = Invoke-DeskAttachmentAnalysis @($a,$b) "Compare states"
        $receiptPath = Join-Path $Repo "logs\last-attachment-analysis.json"
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        Assert ($answer -like "*2 attachments*" -and $receipt.status -ceq "done") "Comparison failed."
        Assert ($receipt.trust_tier -ceq "candidate" -and $receipt.sources.Count -eq 2) "Comparison gained authority or lost a source."
        Assert ($script:plans[0].sources[1].text -ceq "state=disabled`nvalue=42`n") "UTF-16 did not reach planning."
        Assert ($script:posts[0].tool_choice -ceq "none" -and $receipt.sources[1].encoding -ceq "utf-16le") "Tool policy or encoding receipt lost."
        Assert ($script:posts[0].chat_template_kwargs.enable_thinking -eq $script:plans[0].thinking) "Planning/inference templates differ."
        & {
            function Get-GodBrainSharedContext { param($Query, $ThreadId); return @{ context = "SHARED_ATTACHMENT_FIXTURE"; index_id = "fixture-index" } }
            function Save-GodBrainWorkingTurn {
                param($Prompt, $Response, $ThreadId, $Sources)
                Assert ($Prompt -ceq "Research comparison" -and $Sources.Count -eq 2) "Attachment handoff lost original task or sources."
                return @{ record = @{ _id = "fixture-record" } }
            }
            $script:posts = @(); $script:plans = @()
            [void](Invoke-DeskAttachmentAnalysis @($a,$b) "Research comparison" "research")
            Assert ($script:plans[0].task -like "*SHARED_ATTACHMENT_FIXTURE*Operator request:*Research comparison") "Attachment context was added after planning."
            $sharedReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
            Assert ($sharedReceipt.shared_saved -and $sharedReceipt.task -ceq "Research comparison") "Attachment handoff was not confirmed."
        }
        $script:split = $true; $script:posts = @(); $script:plans = @()
        [void](Invoke-DeskAttachmentAnalysis @($a,$b) "Compare both parts")
        Assert ($script:posts.Count -eq 3 -and $script:plans[-1].op -ceq "attachment-synthesis") "Parts did not synthesize serially."
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        Assert ($receipt.parts.Count -eq 2 -and $receipt.part_reports.Count -eq 2) "Coverage or part reports lost."
        $script:split = $false; $script:context = 49152
        [IO.File]::WriteAllText((Join-Path $Repo "logs\thinking.txt"), "on")
        foreach ($failure in @("length","empty")) {
            $script:posts = @(); $script:plans = @(); $script:finishSequence = @($failure,"stop")
            $answer = Invoke-DeskAttachmentAnalysis @($a,$b) "Recover visibly"
            $raw = Get-Content -LiteralPath $receiptPath -Raw
            $receipt = $raw | ConvertFrom-Json
            Assert ($receipt.status -ceq "done" -and $receipt.answer_retry) "Failed completion did not recover."
            Assert ($receipt.completion_attempts.Count -eq 2 -and $script:posts.Count -eq 2) "Recovery was not bounded."
            Assert ($receipt.completion_attempts[0].status -ceq "failed" -and
                $receipt.completion_attempts[1].status -ceq "done") "Attempt diagnostics lost."
            Assert ($receipt.completion_attempts[0].reasoning_bytes -gt 0 -and $raw -notmatch "PRIVATE_") "Private output persisted."
            Assert ($script:posts[0].max_tokens -eq 16384 -and $script:posts[1].max_tokens -eq 4096) "Recovery output cap changed."
            Assert (-not $script:posts[1].chat_template_kwargs.enable_thinking -and
                -not $script:posts[1].reasoning_effort -and $script:posts[1].tool_choice -ceq "none") "Recovery widened authority or kept thinking."
            Assert ($script:plans[-1].op -ceq "completion" -and -not $script:plans[-1].thinking) "Recovery used a stale thinking token budget."
            Assert (($script:posts[1].messages | ConvertTo-Json -Depth 8) -notmatch "PRIVATE_" -and
                $script:posts[1].messages[1].content -ceq $script:posts[0].messages[1].content) "Recovery replayed a draft or lost evidence."
            Assert ($answer -like "*Answer recovery:*saved preference unchanged*") "Recovery was hidden."
            Assert ([IO.File]::ReadAllText((Join-Path $Repo "logs\thinking.txt")) -ceq "on") "Recovery changed saved settings."
        }
        $script:split = $true; $script:posts = @(); $script:plans = @(); $script:finishSequence = @("length","stop")
        [void](Invoke-DeskAttachmentAnalysis @($a,$b) "Recover and finish all parts")
        Assert ($script:posts.Count -eq 4) "Recovery repeated successful parts or skipped synthesis."
        foreach ($post in $script:posts | Select-Object -Skip 1) {
            Assert (-not $post.chat_template_kwargs.enable_thinking) "Remaining analysis restarted failed thinking mode."
        }
        $script:split = $false; $script:context = 8192; $script:posts = @(); $script:finish = "length"
        Assert-Fails { Invoke-DeskAttachmentAnalysis @($a,$b) "Truncated" } "*incomplete*"
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        Assert ($receipt.status -ceq "failed" -and -not $receipt.report) "Incomplete answer reused a successful receipt."
        Assert ($script:posts.Count -eq 2 -and $receipt.completion_attempts.Count -eq 2) "Recovery kept retrying."
        $script:finish = "stop"; $script:posts = @(); $script:promptTokens = 1
        Assert-Fails { Invoke-DeskAttachmentAnalysis @($a,$b) "Invalid token receipt" } "*tokenizer budget*"
        Assert ($script:posts.Count -eq 1) "Invalid token receipts triggered a retry."
        $script:promptTokens = 120; $script:posts = @(); $script:finishSequence = @("length")
        $script:busyAfterFirst = $true
        Assert-Fails { Invoke-DeskAttachmentAnalysis @($a,$b) "Busy recovery" } "*unavailable or busy*"
        Assert ($script:posts.Count -eq 1) "Recovery queued onto another generation."
        $script:busyAfterFirst = $false
        $script:finish = "stop"; $script:tools = @(@{function=@{name="run_pwsh"}})
        $script:posts = @()
        Assert-Fails { Invoke-DeskAttachmentAnalysis @($a,$b) "No execution" } "*attempted tools*"
        Assert ($script:posts.Count -eq 1) "Attempted tools triggered recovery."
        $script:tools = $null; $script:changed = $true
        Assert-Fails { Invoke-DeskAttachmentAnalysis @($a,$b) "Changed source" } "*changed during analysis*"
        Assert (-not (Test-DeskReviewBusy)) "Failed analysis retained its mutex."
        $script:changed = $false; $script:busy = $true
        $before = $script:posts.Count
        Assert-Fails { Invoke-DeskAttachmentAnalysis @($a,$b) "Busy" } "*idle EXL3*"
        Assert ($script:posts.Count -eq $before) "Busy model received a generation."
        $script:busy = $false
        Assert-Fails { Invoke-DeskAttachmentAnalysis @($a,(Join-Path $fixture "missing.txt")) "Missing" }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        Assert ($receipt.status -ceq "failed" -and -not $receipt.report) "Unreadable source produced success."
        function Invoke-DeskCpuOcr { param($Bytes); return "ME Disabled`nCode 632" }
        $image = Join-Path $fixture "screenshot.png"
        [IO.File]::WriteAllBytes($image, [byte[]]@(1,2,3,4))
        $script:plans = @()
        $answer = Invoke-DeskAttachmentAnalysis @($image,$b) "Compare screenshot and log"
        Assert ($script:plans[0].sources[0].kind -ceq "cpu-ocr") "Image was not labelled as derived OCR."
        Assert ($answer -like "*visual layout and OCR accuracy are not verified*") "OCR caveat missing."
    }
    & {
        $script:slotBusy = $false; $script:ports = @(); $script:routed = @()
        function Test-Port { param($Port); return $Port -in $script:ports }
        function Test-GenerateBusy { return $script:slotBusy }
        function Invoke-DeskAttachmentAnalysis { param($Paths,$Task); $script:routed=@($Paths); return "mixed analysis" }
        $request = [pscustomobject]@{Message="Compare"; Path=$a; Attachments=@($b); Mode="research"; ImageModel=$false}
        Assert ((Invoke-DeskAsk $request) -ceq "mixed analysis" -and $script:routed.Count -eq 2) "Primary file did not join attachments."
        $request.Path = $fixture
        Assert ((Invoke-DeskAsk $request) -ceq "mixed analysis" -and $script:routed.Count -eq 1) "Folder scope became an attachment."
        $request.Mode = "fix"
        Assert-Fails { Invoke-DeskAsk $request } "*read-only*"
        $request.Mode = "answer"; $request.Message = "/yolo 60"
        Assert-Fails { Invoke-DeskAsk $request } "*slash command*"
        $request.Message = "Compare"; $script:ports = @(8871)
        Assert-Fails { Invoke-DeskAsk $request } "*not Qwen-Image*"
        $script:ports = @(); $script:slotBusy = $true
        Assert-Fails { Invoke-DeskAsk $request } "*already running*"
        $script:slotBusy = $null
        Assert-Fails { Invoke-DeskAsk $request } "*cannot tell*"
        $request.Attachments = $b
        Assert-Fails { Invoke-DeskAsk $request } "*must be a list*"
    }
    Write-Output "PASS: mixed attachment routing, UTF-8/UTF-16, jail/limits, read-only completions, coverage, hashes and fail-closed receipts."
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
