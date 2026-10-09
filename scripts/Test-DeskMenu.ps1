[CmdletBinding()]
param([switch]$UiSmoke)

$ErrorActionPreference = "Stop"
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "Show-DeskMenu.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
$script:fixtureRoot = $PSScriptRoot
foreach ($name in @("Get-ModelLine", "Get-TokLine", "Get-ImageRateLine", "Get-WhisperLine", "Get-ModelPickFile", "Start-SelectedModel", "Stop-ActiveModel",
    "Get-DeskJailRoots", "ConvertTo-DeskAskPath", "Test-DeskGrantedPath", "Test-DeskPathToken", "Read-DeskGrantedBytes", "Get-DeskImagePayload", "Wait-DeskImageResult", "Test-DeskWriteSlash", "Test-DeskVisionImage", "Test-DeskNeedsCompleteReview", "Invoke-DeskVisionAsk", "Invoke-DeskAsk")) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text.Replace('$PSScriptRoot', '$script:fixtureRoot')))
}

function Test-Port([int]$Port) { return $Port -in $script:ports }
function Invoke-RestMethod {
    param([string]$Uri, [int]$TimeoutSec, [string]$Method, [string]$Body, [string]$ContentType, [hashtable]$Headers)
    if ($script:httpFails) { throw "Fixture HTTP failure" }
    $script:lastUri = $Uri
    $script:lastBody = $Body
    $script:lastAuthorization = $null
    if ($Headers -and $Headers.Contains("Authorization")) {
        $script:lastAuthorization = [string]$Headers["Authorization"]
    }
    if ($Method -eq "Post") { $script:lastPostBody = $Body }
    if ($script:asyncFixture -and $Uri -eq "http://127.0.0.1:8871/v1/images/generations") {
        $script:imagePostCount++
        $script:fixtureRequestId = ($Body | ConvertFrom-Json).request_id
        return @{ request_id = $script:fixtureRequestId; status = "running" }
    }
    if ($script:asyncFixture -and $Uri -like "http://127.0.0.1:8871/v1/images/jobs/*") {
        return @{ request_id = $script:fixtureRequestId; status = $script:fixtureJobStatus
            result = [pscustomobject]@{ path = "async-fixture.png"; width = 1024; height = 1024; steps = 40; seed = 0 }
            error = "fixture generation failure" }
    }
    if ($script:askResponses -and $script:askResponses.ContainsKey($Uri)) { return $script:askResponses[$Uri] }
    return $script:response
}
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, [string]$ErrorAction)
    if ($script:processFails) { throw "Fixture process failure" }
    return $script:processes
}
function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}
function Assert-Throws([scriptblock]$Action, [string]$Expected) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike $Expected) { throw }
        return
    }
    throw "Expected failure: $Expected"
}

& {
    foreach ($name in @("Stop-MouthHold", "Set-WatchTask")) {
        $definition = $ast.Find({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text.Replace('[System.Windows.Forms.MessageBox]::Show', 'Write-Output')))
    }
    $Repo = "fixture"; $script:controlCalls = @()
    function Update-Status {}
    function Confirm-Stop { param($Message, $Title); return $true }
    function Set-DeskPause { param($Name); $script:controlCalls += "hold:on" }
    function Set-GodBrainMouthPaused { param($RepoRoot, $On); $script:controlCalls += "hold:on" }
    function Enable-DeskAfterCs2 { return $true }
    function Set-Content { param($LiteralPath, $Value); $script:controlCalls += "hold:$Value" }
    function Stop-Process { throw "Image-name-wide termination must not run." }
    function Stop-Cs2OwnedProcess { param($Process); $script:controlCalls += "stop:$($Process.ProcessId)" }
    function Get-CimInstance { param($ClassName, $Filter, $ErrorAction)
        return @(
            @{ Name = "llama-server.exe"; ProcessId = 10; CommandLine = "llama-server.exe --port 8000" },
            @{ Name = "llama-server.exe"; ProcessId = 11; CommandLine = "llama-server.exe --port 8001" },
            @{ Name = "llama-server.exe"; ProcessId = 12; CommandLine = "llama-server.exe --port 80001" },
            @{ Name = "llama-server.exe"; ProcessId = 13; CommandLine = "llama-server.exe --port=8000" },
            @{ Name = "python.exe"; ProcessId = 14; CommandLine = "python.exe --port 8888" }
        )
    }
    function Start-Process { param($FilePath, $ArgumentList, $WindowStyle, [switch]$Wait, [switch]$PassThru)
        $script:controlCalls += ($ArgumentList -join " ")
        return @{ ExitCode = 0 }
    }
    Stop-MouthHold
    Assert-Equal ($script:controlCalls -join ",") "hold:on,stop:10,stop:13"
    $script:controlCalls = @()
    Set-WatchTask "ENABLE"
    Assert-Equal ($script:controlCalls -join ",") "/Change /TN GodBrainWatch /ENABLE,hold:off,/Run /TN GodBrainWatch"
    $script:controlCalls = @()
    Set-WatchTask "DISABLE"
    Assert-Equal ($script:controlCalls -join ",") "/Change /TN GodBrainWatch /DISABLE,hold:on"
}

& {
    $definition = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Enable-DeskAfterCs2"
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text.Replace('[System.Windows.Forms.MessageBox]::Show', 'Write-Output')))
    $Repo = "fixture"
    $script:resumeCalls = @()
    function Clear-GodBrainCs2Pause { param($RepoRoot); $script:resumeCalls += "clear" }
    function Enable-InstalledGodBrainLogon { $script:resumeCalls += "logon" }
    if (-not (Enable-DeskAfterCs2)) { throw "Explicit resume should clear the hold and re-enable Logon." }
    Assert-Equal ($script:resumeCalls -join ",") "clear,logon"
    $script:resumeCalls = @()
    function Clear-GodBrainCs2Pause { param($RepoRoot); throw "CS2 is running. Close the game before starting models or Watch." }
    $running = @(Enable-DeskAfterCs2)
    Assert-Equal $running[-1] $false
    Assert-Equal ($script:resumeCalls -join ",") ""
    $script:resumeCalls = @()
    function Clear-GodBrainCs2Pause { param($RepoRoot); $script:resumeCalls += "clear" }
    function Enable-InstalledGodBrainLogon { throw "fixture logon denied" }
    $denied = @(Enable-DeskAfterCs2)
    Assert-Equal $denied[-1] $false
    Assert-Equal ($script:resumeCalls -join ",") "clear"
}

$script:ports = @()
$script:httpFails = $false
Assert-Equal (Get-ModelLine) "No model: :8888 / :8871 down"

$script:ports = @(8871)
$script:response = @{ ok = $true; ready = $true; weights = "C:\nvme\Qwen-Image-2.1" }
Assert-Equal (Get-ModelLine) "Qwen-Image-2.1  :8871"
Assert-Equal $script:lastUri "http://127.0.0.1:8871/health"
$script:ports = @(8871, 8888)
Assert-Equal (Get-ModelLine) "Qwen-Image-2.1  :8871"
$script:httpFails = $true
Assert-Equal (Get-ModelLine) "8871 up, health unread"

$script:ports = @(8888)
Assert-Equal (Get-ModelLine) "8888 up, models unread"
$script:httpFails = $false
$script:response = @{ data = @(@{ id = "qwen-text-fixture"; max_model_len = 8192 }) }
Assert-Equal (Get-ModelLine) "qwen-text-fixture  ctx=8192"
Assert-Equal $script:lastUri "http://127.0.0.1:8888/v1/models"

$script:ports = @(8871)
$script:response = @{ ready = $true; busy = $true }
$script:tokSample = @{ At = [datetime]::UtcNow; Total = 123; Text = "stale text rate" }
Assert-Equal (Get-TokLine) "image busy (progress unavailable)"
Assert-Equal $script:tokSample $null
$script:response.busy = $false
Assert-Equal (Get-TokLine) "image idle"
$script:response.ready = $false
Assert-Equal (Get-TokLine) "image loading"
$script:response.ready = $true
$script:response.progress = @{
    phase = "denoising"; completed_steps = 12; total_steps = 40; elapsed_seconds = 240
    steps_per_second = 0.05; seconds_per_step = 20
}
Assert-Equal (Get-TokLine) ("12/40 steps, 240s, {0:0.0} s/step" -f 20)
$script:response.progress.steps_per_second = 2
Assert-Equal (Get-TokLine) ("12/40 steps, 240s, {0:0.00} steps/s" -f 2)
$script:response.progress.steps_per_second = $null
$script:response.progress.seconds_per_step = $null
$script:response.progress.completed_steps = 1
Assert-Equal (Get-TokLine) "1/40 steps, 240s"
foreach ($phase in @("loading", "preparing", "decoding", "saving", "unloading", "done")) {
    $script:response.progress.phase = $phase
    Assert-Equal (Get-TokLine) "$phase, 240s"
}
$script:response.progress.phase = "failed"
Assert-Equal (Get-TokLine) "image failed, 240s"
$script:response.progress.phase = "idle"
Assert-Equal (Get-TokLine) "image idle"
$script:response.progress.phase = "invalid"
Assert-Equal (Get-TokLine) "image progress unread"
$script:httpFails = $true
Assert-Equal (Get-TokLine) "image status unread"
$script:httpFails = $false
$script:ports = @(8888)
$script:response = @{ prompt_tokens_total = 125; completion_tokens_total = 75; busy = $false }
$script:tokSample = @{ At = [datetime]::UtcNow.AddSeconds(-2); Total = 160; Text = "idle" }
if ((Get-TokLine) -notmatch '^\d+ T/s$') { throw "Text throughput lost its token units." }
$script:ports = @()
Assert-Equal (Get-TokLine) "idle"
Assert-Equal $script:tokSample $null
if ($ast.Extent.Text -notmatch '\$rowTok = Add-Row \$pageStatus "Rate"') {
    throw "Image diffusion speed still has a misleading Tok/s label."
}
if ($ast.Extent.Text -notmatch 'Add-Pair \$pageStatus "STT/TTS"') {
    throw "STT/TTS is missing its Start and Stop buttons."
}

$script:ports = @()
$script:httpFails = $false
Assert-Equal (Get-WhisperLine) "down"
$script:ports = @(8001)
$script:response = @{ service = "voice"; device = "cpu"; ocr = "cpu" }
Assert-Equal (Get-WhisperLine) "CPU up :8001"
$script:response.ocr = "qwen"
Assert-Equal (Get-WhisperLine) "CPU up :8001 OCR=tower"
$script:response = @{ service = "other"; device = "cpu"; ocr = "cpu" }
Assert-Equal (Get-WhisperLine) "down (other)"
$script:httpFails = $true
Assert-Equal (Get-WhisperLine) "health unread"
$script:httpFails = $false
$script:ports = @()

function Start-ImageDoor { $script:imageStarted = $true }
function Stop-ImageDoor { $script:imageStopped = $true }
function Enable-DeskAfterCs2 { return $script:canResume }
function Stop-Door { $script:slotStopped = $true; return $true }
function Start-Door([string]$File, [string[]]$Options) { $script:startedFile = $File; $script:startedOptions = $Options }
function Save-DeskModelControls {
    $script:modelProfiles[$script:modelPick] = Get-DeskModelDefaults $script:modelPick
}
function Test-DeskModelLauncher {}
. (Join-Path $PSScriptRoot "GodBrain-DeskModel.ps1")
function Test-DeskModelLauncher {}
$script:modelProfiles = @{}
function Update-Status {}
$Start27 = "text-fixture.ps1"
$StartVl = "vision-fixture.ps1"
$StartImage = "image-fixture.ps1"
$StartUncensored = "uncensored-fixture.ps1"
$script:canResume = $true
foreach ($pick in @("27b", "vl", "image", "uncensored")) {
    $script:modelPick = $pick
    $script:imageStarted = $false
    $script:slotStopped = $false
    Start-SelectedModel
    if ($pick -eq "image") {
        Assert-Equal $script:imageStarted $true
        Assert-Equal $script:slotStopped $false
    } else {
        Assert-Equal $script:slotStopped $true
        Assert-Equal $script:startedFile (Get-ModelPickFile)
        Assert-Equal ($script:startedOptions -join ",") ((Get-DeskModelLaunchOptions $pick (Get-DeskModelDefaults $pick)) -join ",")
    }
}
$script:canResume = $false
foreach ($pick in @("27b", "vl", "image", "uncensored")) {
    $script:modelPick = $pick
    $script:imageStarted = $false
    $script:slotStopped = $false
    Start-SelectedModel
    Assert-Equal $script:imageStarted $false
    Assert-Equal $script:slotStopped $false
}
$script:canResume = $true
$script:ports = @(8871)
$script:imageStopped = $false
Stop-ActiveModel
Assert-Equal $script:imageStopped $true
if ($ast.Extent.Text -match '\$rowImage|Stop-TextModel|Add-ModelPick "image" "Image"') {
    throw "The separate Image controls or old model label remain."
}
if ($ast.Extent.Text -notmatch 'Add-ModelPick "image" "Qwen-Image-2\.1"') {
    throw "The named image model selection is missing."
}

$starter = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "Start-QwenImage.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
$guard = $starter.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Assert-ImageGpuSlot"
}, $true)
if (-not $guard) { throw "Missing image GPU-slot guard." }
. ([scriptblock]::Create($guard.Extent.Text))
function Test-LoopbackPort([int]$Port) { return $Port -in $script:ports }
function Get-NetTCPConnection {
    param([int]$LocalPort, [string]$State, [string]$ErrorAction)
    return $script:listeners
}
$script:processFails = $false
$script:ports = @()
Assert-ImageGpuSlot
$script:ports = @(8000)
$script:listeners = @(@{ OwningProcess = 42 })
$script:processes = @{ Name = "python.exe"; CommandLine = '"C:\Program Files\Python\python.exe" -m http.server 8000 --bind 127.0.0.1' }
Assert-ImageGpuSlot
$script:processes = @{ Name = "llama-server.exe"; CommandLine = "llama-server.exe --port 8000" }
Assert-Throws { Assert-ImageGpuSlot } "*:8000 is held by a model or unknown process*"
$script:processes = @{ Name = "python.exe"; CommandLine = "python.exe serve_openai.py --port 8000" }
Assert-Throws { Assert-ImageGpuSlot } "*:8000 is held by a model or unknown process*"
$script:processes = $null
Assert-Throws { Assert-ImageGpuSlot } "*:8000 is held by a model or unknown process*"
$script:listeners = @()
Assert-Throws { Assert-ImageGpuSlot } "*Could not identify the :8000 listener*"
$script:ports = @(8888)
Assert-Throws { Assert-ImageGpuSlot } "*:8888 is still listening*"

$Repo = Split-Path $PSScriptRoot -Parent
$script:httpFails = $false
$script:ports = @(8871)
$script:askResponses = @{
    "http://127.0.0.1:8871/health" = @{ ready = $true; busy = $false }
    "http://127.0.0.1:8871/v1/images/generations" = @{ path = "fixture.png"; width = 256; height = 256; steps = 1; seed = 0 }
    "http://127.0.0.1:8083/api/chat" = @{ response = "text fixture" }
}
$request = @{ Message = "Make this profile picture half cyborg"; Path = ""; ImageModel = $true }
$answer = Invoke-DeskAsk $request
if ($answer -notlike "*fixture.png*") { throw "Image Ask did not return its saved path." }
Assert-Equal $script:lastUri "http://127.0.0.1:8871/v1/images/generations"
Assert-Equal ($script:lastBody | ConvertFrom-Json).prompt $request.Message
$script:asyncFixture = $true
$script:imagePostCount = 0
$script:fixtureJobStatus = "done"
$answer = Invoke-DeskAsk $request
if ($answer -notlike "*async-fixture.png*") { throw "Async image receipt was lost." }
Assert-Equal $script:imagePostCount 1
Assert-Equal ($script:lastPostBody | ConvertFrom-Json).async $true
if ($script:fixtureRequestId -notmatch '^[a-f0-9]{32}$') { throw "Missing correlated image request ID." }
$script:fixtureJobStatus = "failed"
Assert-Throws { Invoke-DeskAsk $request } "*fixture generation failure*"
$script:fixtureJobStatus = "invalid"
Assert-Throws { Invoke-DeskAsk $request } "*invalid request state*"
$script:fixtureJobStatus = "done"
$script:fixtureRequestId = "a" * 32
Assert-Throws { Wait-DeskImageResult ("b" * 32) } "*different request ID*"
$script:asyncFixture = $false
$request.ImageModel = $false
Invoke-DeskAsk $request | Out-Null
Assert-Equal $script:lastUri "http://127.0.0.1:8871/v1/images/generations"
$fixtureFile = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllBytes($fixtureFile, [byte[]]@(1, 2, 3, 4))
    $request.Path = $fixtureFile
    Invoke-DeskAsk $request | Out-Null
    Assert-Equal ($script:lastBody | ConvertFrom-Json).image_base64 "AQIDBA=="
} finally { [IO.File]::Delete($fixtureFile) }
$request.Path = "C:\Windows\fixture.png"
Assert-Throws { Invoke-DeskAsk $request } "*outside the kernel file jail*"
$request.Path = ""
$request.ImageModel = $true
$script:ports = @()
Assert-Throws { Invoke-DeskAsk $request } "*Qwen-Image-2.1 is down*"
$script:ports = @(8871, 8888)
Assert-Throws { Invoke-DeskAsk $request } "*Both image and text models*"
$script:ports = @(8871)
$script:askResponses["http://127.0.0.1:8871/health"].busy = $true
Assert-Throws { Invoke-DeskAsk $request } "*already generating*"
$script:askResponses["http://127.0.0.1:8871/health"].busy = $false
$script:askResponses["http://127.0.0.1:8871/health"].ready = $false
Assert-Throws { Invoke-DeskAsk $request } "*not ready*"
function Test-GenerateBusy { return $script:fixtureBusy }
$script:fixtureBusy = $false
$script:ports = @(8888)
$request.ImageModel = $false
Assert-Equal (Invoke-DeskAsk $request) "text fixture"
Assert-Equal $script:lastUri "http://127.0.0.1:8083/api/chat"
if (($script:lastBody | ConvertFrom-Json).message -notlike "No tools.*") { throw "Text Ask lost its no-tools routing." }
if ($script:lastAuthorization) { throw "Ordinary Ask sent a bearer." }
Assert-Equal (Test-DeskWriteSlash "/yolo") $false
Assert-Equal (Test-DeskWriteSlash "/yolo status") $false
Assert-Equal (Test-DeskWriteSlash "/yolo ?") $false
Assert-Equal (Test-DeskWriteSlash "/YOLO off") $true
Assert-Equal (Test-DeskWriteSlash "/verify last because") $true
$savedAsk = $request.Message
$savedPath = $request.Path
$savedToken = $env:GODBRAIN_API_TOKEN
try {
    $env:GODBRAIN_API_TOKEN = "fixture-desk-token"
    $request.Message = "/verify last the probe matched"
    Assert-Equal (Invoke-DeskAsk $request) "text fixture"
    Assert-Equal (($script:lastBody | ConvertFrom-Json).message) "/verify last the probe matched"
    Assert-Equal $script:lastAuthorization "Bearer fixture-desk-token"
    $request.Message = "/yolo"
    Invoke-DeskAsk $request | Out-Null
    if (($script:lastBody | ConvertFrom-Json).message -like "No tools.*") { throw "Read /yolo was rewritten." }
    if ($script:lastAuthorization) { throw "Status /yolo sent a bearer." }
    $request.Path = "C:\Temp\GitHub"
    $request.ReviewFile = $true
    $request.Message = "/verify last the probe matched"
    Invoke-DeskAsk $request | Out-Null
    Assert-Equal (($script:lastBody | ConvertFrom-Json).message) "/verify last the probe matched"
    Assert-Equal $script:lastAuthorization ("Bearer " + $env:GODBRAIN_API_TOKEN)
    $request.Path = "C:\Temp\GitHub\fixture.jpg"
    $request.Message = "/yolo off`r`n"
    Invoke-DeskAsk $request | Out-Null
    Assert-Equal (($script:lastBody | ConvertFrom-Json).message) "/yolo off"
    Assert-Equal $script:lastAuthorization ("Bearer " + $env:GODBRAIN_API_TOKEN)
    $request.ReviewFile = $false
    $request.Path = "C:\Temp\GitHub"
    $request.Message = "what is in here"
    Invoke-DeskAsk $request | Out-Null
    if (($script:lastBody | ConvertFrom-Json).message -notmatch '(?s)^Path: .+what is in here$') {
        throw "Ordinary Ask with a path lost its path prefix."
    }
    if ($script:lastAuthorization) { throw "Ordinary path Ask sent a bearer." }
    $request.Path = ""
    $script:fixtureBusy = $true
    $request.Message = "/yolo off"
    Assert-Equal (Invoke-DeskAsk $request) "text fixture"
    Assert-Equal (($script:lastBody | ConvertFrom-Json).message) "/yolo off"
    Assert-Equal $script:lastAuthorization ("Bearer " + $env:GODBRAIN_API_TOKEN)
    $request.Message = "what is in here"
    Assert-Throws { Invoke-DeskAsk $request } "*already running*"
    $script:fixtureBusy = $null
    $request.Message = "/yolo off"
    Assert-Equal (Invoke-DeskAsk $request) "text fixture"
    $script:fixtureBusy = $false
    $request.Message = "/yolo 15"
    Invoke-DeskAsk $request | Out-Null
    Assert-Equal (($script:lastBody | ConvertFrom-Json).message) "/yolo 15"
    Assert-Equal $script:lastAuthorization "Bearer fixture-desk-token"
    Remove-Item Env:GODBRAIN_API_TOKEN
    Invoke-DeskAsk $request | Out-Null
    if ($script:lastAuthorization) { throw "Unset token still sent a bearer." }
} finally {
    if ([string]::IsNullOrEmpty($savedToken)) { Remove-Item Env:GODBRAIN_API_TOKEN -ErrorAction SilentlyContinue }
    else { $env:GODBRAIN_API_TOKEN = $savedToken }
    $request.Message = $savedAsk
    $request.Path = $savedPath
}
$askAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "Ask-GodBrain.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
$askWrite = $askAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Test-GodBrainWriteSlash"
}, $true)
if (-not $askWrite) { throw "Ask-GodBrain is missing Test-GodBrainWriteSlash." }
. ([scriptblock]::Create($askWrite.Extent.Text))
Assert-Equal (Test-GodBrainWriteSlash "/reject last junk") $true
Assert-Equal (Test-GodBrainWriteSlash "/yolo status extra") $false
Assert-Equal (Test-GodBrainWriteSlash "/brief") $false
$large = Join-Path $env:TEMP ("desk-review-" + [guid]::NewGuid().ToString("N") + ".cpp")
$picture = $null
try {
    [IO.File]::WriteAllText($large, ("int x;`n" * 20000))
    if ((Get-Item -LiteralPath $large).Length -le 128KB) { throw "Large-file fixture is under 128 KiB." }
    function Invoke-DeskCodeReview { param($Path, $Task) $script:completeReview = $Path; return "chunked review" }
    $savedMessage = $request.Message
    $request.Path = $large
    $request.Message = "I want this analyzed for bugs"
    $request.ReviewFile = $false
    Assert-Equal (Invoke-DeskAsk $request) "chunked review"
    Assert-Equal $script:completeReview $large
    $request.Message = "fix the crash in this file"
    Assert-Equal (Invoke-DeskAsk $request) "text fixture"
    Assert-Equal $script:lastUri "http://127.0.0.1:8083/api/chat"
    $request.Path = ""
    $request.Message = $savedMessage
    $request.ReviewFile = $false
    $picture = Join-Path $env:TEMP ("desk-vision-" + [guid]::NewGuid().ToString("N") + ".jpg")
    $pixels = [byte[]]::new(140KB)
    $pixels[0] = 0xFF; $pixels[1] = 0xD8; $pixels[2] = 0xFF; $pixels[3] = 0xD9
    [IO.File]::WriteAllBytes($picture, $pixels)
    $request.Path = $picture
    $request.Message = "OCR"
    $script:completeReview = ""
    $script:ports = @()
    Assert-Throws { Invoke-DeskAsk $request } "*vision tower is down*"
    Assert-Equal $script:completeReview ""
    $script:ports = @(8888)
    $script:askResponses["http://127.0.0.1:8888/health"] = @{ vision = $false; busy = $false }
    Assert-Throws { Invoke-DeskAsk $request } "*text-only*"
    $script:askResponses["http://127.0.0.1:8888/health"] = @{ vision = $true; busy = $false }
    $script:askResponses["http://127.0.0.1:8888/v1/models"] = @{ data = @(@{ id = "qwen-vision-fixture" }) }
    $script:askResponses["http://127.0.0.1:8888/v1/chat/completions"] = @{
        choices = @(@{ message = @{ content = "tank fixture" } })
    }
    Assert-Equal (Invoke-DeskAsk $request) "tank fixture"
    Assert-Equal $script:completeReview ""
    if ($script:lastBody -notmatch '"messages":\[') { throw "Vision Ask unwrapped the messages array." }
    $posted = $script:lastBody | ConvertFrom-Json
    Assert-Equal $posted.model "qwen-vision-fixture"
    Assert-Equal ([bool]$posted.chat_template_kwargs.enable_thinking) $false
    Assert-Equal $posted.messages[0].content[0].text "OCR"
    if ($posted.messages[0].content[1].image_url.url -notlike "data:image/jpeg;base64,*") {
        throw "Vision Ask did not send the picture."
    }
    $request.Path = ""
    $request.Message = $savedMessage
    $script:askResponses.Remove("http://127.0.0.1:8888/health")
    $script:askResponses.Remove("http://127.0.0.1:8888/v1/models")
    $script:askResponses.Remove("http://127.0.0.1:8888/v1/chat/completions")
} finally { Remove-Item -LiteralPath $large, $picture -Force -ErrorAction SilentlyContinue }
$script:fixtureBusy = $true
Assert-Throws { Invoke-DeskAsk $request } "*already running*"
$script:fixtureBusy = $null
Assert-Throws { Invoke-DeskAsk $request } "*Kernel status is down*"

$update = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Update-Status"
}, $true)
if (-not $update) { throw "Missing asynchronous status updater." }
. ([scriptblock]::Create($update.Extent.Text.Replace('$PSCommandPath', '$script:fixtureCommand')))
function Update-MicMark {}
$script:statusRows = [ordered]@{}
foreach ($key in @("Model", "Tok", "Kernel", "Rag", "Mongo", "Gym", "Cs2", "Mouth", "Gpu", "Rust", "Ssh", "Tail", "Watch", "Web", "Whisper")) {
    $script:statusRows[$key] = [pscustomobject]@{ Text = "waiting" }
}
$rowModel = $script:statusRows.Model
$script:statusTip = [pscustomobject]@{ LastText = "" }
$script:statusTip | Add-Member -MemberType ScriptMethod -Name SetToolTip -Value {
    param($Control, $Text)
    $this.LastText = $Text
}
$state = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$state.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new("Get-FixtureSnapshot", @'
param([switch]$StatusSnapshot, [object]$TokenSample)
Start-Sleep -Milliseconds 1500
$rows = @{}
foreach ($key in "Model", "Tok", "Kernel", "Rag", "Mongo", "Gym", "Cs2", "Mouth", "Gpu", "Rust", "Ssh", "Tail", "Watch", "Web", "Whisper") {
    $rows[$key] = "fixture $key"
}
[pscustomobject]@{ Rows = [pscustomobject]$rows; TokenSample = @{ Total = (1 + $TokenSample.Total) } }
'@))
$state.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new(
    "Get-FailingSnapshot", 'param([switch]$StatusSnapshot, [object]$TokenSample) throw "fixture refresh failure"'))
$script:statusWorker = [PowerShell]::Create($state)
$script:statusJob = $null
$script:statusNextRefresh = [datetime]::MinValue
$script:statusRefreshRequested = $false
$script:tokSample = @{ Total = 0 }
$script:fixtureCommand = "Get-FixtureSnapshot"
try {
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    Update-Status
    $elapsed.Stop()
    if ($elapsed.ElapsedMilliseconds -gt 250) { throw "Starting a status probe blocked the UI." }
    $firstJob = $script:statusJob
    $elapsed.Restart()
    foreach ($i in 1..20) { Update-Status -Poll }
    $elapsed.Stop()
    if ($elapsed.ElapsedMilliseconds -gt 250) { throw "Polling an unfinished status probe blocked the UI." }
    Assert-Equal $script:statusJob $firstJob
    Update-Status
    Assert-Equal $script:statusJob $firstJob
    Assert-Equal $rowModel.Text "waiting"
    if (-not $firstJob.AsyncWaitHandle.WaitOne(5000)) { throw "Fixture status probe timed out." }
    Update-Status -Poll
    Assert-Equal $rowModel.Text "fixture Model"
    Assert-Equal $script:tokSample.Total 1
    if ($script:statusJob -eq $firstJob -or -not $script:statusJob) {
        throw "A refresh requested during an active probe was not queued correctly."
    }
    if (-not $script:statusJob.AsyncWaitHandle.WaitOne(5000)) { throw "Queued status probe timed out." }
    Update-Status -Poll
    Assert-Equal $script:tokSample.Total 2
    Assert-Equal $script:statusJob $null
    foreach ($entry in $script:statusRows.GetEnumerator()) {
        Assert-Equal $entry.Value.Text ("fixture " + $entry.Key)
    }
    $script:fixtureCommand = "Get-FailingSnapshot"
    Update-Status
    if (-not $script:statusJob.AsyncWaitHandle.WaitOne(5000)) { throw "Failure fixture timed out." }
    Update-Status -Poll
    Assert-Equal $rowModel.Text "Status refresh failed"
    if ($script:statusTip.LastText -notlike "*fixture refresh failure*") {
        throw "The status probe failure was not surfaced."
    }
} finally {
    $script:statusWorker.Stop()
    $script:statusWorker.Dispose()
}

Write-Output "Desk model routing, GPU-slot, and non-blocking status checks passed."

& {
    foreach ($name in @("Get-RustDeskLine", "Set-HostService")) {
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $script:appActions = @()
    $script:appRunning = $false
    function Get-ServiceWord { return "missing" }
    function Get-Service { param($Name, $ErrorAction); return $null }
    function Get-GodBrainRustDeskExe { return "C:\Program Files\RustDesk\rustdesk.exe" }
    function Get-GodBrainRustDeskProcesses { if ($script:appRunning) { return @{ ProcessId = 7 } }; return @() }
    function Start-GodBrainRustDeskApp { throw "Desk Start must not launch only the GUI." }
    function Test-Path { param($LiteralPath); return $true }
    function Start-Process {
        param($FilePath, $ArgumentList, $WindowStyle, [switch]$Wait, [switch]$PassThru)
        Assert-Equal $FilePath "C:\Tools\TeamM2\wsudo.exe"
        Assert-Equal $ArgumentList[0] "-A"
        Assert-Equal $ArgumentList[2] "C:\pwsh\pwsh.exe"
        Assert-Equal $ArgumentList[6] "-File"
        Assert-Equal $ArgumentList[7] ('"' + (Join-Path $Repo "scripts\Start-RustDesk.ps1") + '"')
        $script:appActions += "backend-start"
        return @{ ExitCode = 0 }
    }
    function Stop-GodBrainRustDeskApp { $script:appActions += "stop" }
    function Set-DeskPause { param($Name); $script:appActions += "hold:$Name" }
    function Set-Content { param($LiteralPath, $Value); $script:appActions += "resume:$Value" }
    function Update-Status {}
    $Repo = Split-Path $PSScriptRoot -Parent
    Assert-Equal (Get-RustDeskLine) "service missing"
    $script:appRunning = $true
    Assert-Equal (Get-RustDeskLine) "GUI only (no service)"
    Set-HostService "RustDesk" "stop"
    Set-HostService "RustDesk" "start"
    Assert-Equal ($script:appActions -join ",") "hold:rustdesk,stop,backend-start,resume:off"
}

if ($UiSmoke) {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne "STA") { throw "UI smoke requires pwsh -Sta." }
    $script:uiScriptsRoot = $PSScriptRoot
    $source = [System.Collections.Generic.List[string]]::new()
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement.Extent.Text -eq '$f.Show()') { break }
        if ($statement.Extent.Text -in @('Update-Status', '$timer.Start()')) { continue }
        $source.Add($statement.Extent.Text)
    }
    $ControlPanelHost = $true; $Status = $false; $StatusSnapshot = $false; $AskRequest = $null; $MonitorRequest = $null
    $panelPath = "'" + (Join-Path $PSScriptRoot "Show-DeskMenu.ps1").Replace("'", "''") + "'"
    try {
        . ([scriptblock]::Create(($source -join "`n").Replace('$PSScriptRoot', '$script:uiScriptsRoot').Replace('$PSCommandPath', $panelPath)))
        if ($afkGym.Parent -ne $pageStatus -or $afkGym.Bounds.Bottom -gt $pageStatus.ClientSize.Height) {
            throw "AFK option is outside the Status page."
        }
        if ([System.Windows.Forms.TextRenderer]::MeasureText($afkGym.Text, $afkGym.Font).Width + 24 -gt $afkGym.Width) {
            throw "AFK option label is clipped."
        }
        $bitmap = New-Object System.Drawing.Bitmap($f.Width, $f.Height)
        try { $f.DrawToBitmap($bitmap, $f.ClientRectangle) } finally { $bitmap.Dispose() }
        Show-Page "Model"
        foreach ($control in @($script:modelContext, $script:modelCache, $script:modelMtp, $script:modelBudget, $script:modelCpuCache, $script:modelSettingsHint, $script:modelLive)) {
            if ($control.Parent -ne $pageModel -or $control.Bounds.Bottom -gt $pageModel.ClientSize.Height) {
                throw "Model settings are outside the Model page."
            }
        }
        Set-ModelPick "image"
        Assert-Equal $script:modelContext.Enabled $false
        Assert-Equal $script:modelMtp.Enabled $false
        Set-ModelPick "vl"
        Assert-Equal $script:modelContext.Enabled $true
        Assert-Equal $script:modelMtp.Enabled $false
        Set-ModelPick "27b"
        Assert-Equal $script:modelMtp.Enabled $true
        $hintSize = [Windows.Forms.TextRenderer]::MeasureText($script:modelSettingsHint.Text,
            $script:modelSettingsHint.Font, $script:modelSettingsHint.Size, [Windows.Forms.TextFormatFlags]::WordBreak)
        if ($hintSize.Height -gt $script:modelSettingsHint.Height) {
            throw "Model settings explanation is clipped: measured=$($hintSize.Height), available=$($script:modelSettingsHint.Height)."
        }
        if ([Windows.Forms.TextRenderer]::MeasureText($reviewFile.Text, $reviewFile.Font).Width + 24 -gt $reviewFile.Width) {
            throw "Complete-file review label is clipped."
        }
        $monitorRail = @($script:railMarks | Where-Object Name -eq "Monitor")
        Assert-Equal $monitorRail.Count 1
        Assert-Equal $monitorRail[0].Button.Top 296
        if ($monitorRail[0].Button.Bottom -ge $script:micRail.Top) {
            throw "Monitor icon is not above the microphone."
        }
        $script:monitorWorker.Dispose()
        $script:monitorWorker = [PowerShell]::Create()
        $monitorFixture = '{"schema_version":1,"ok":true,"model":"Dell S2522HG","display":"fixture","brightness":{"supported":true,"current":75,"maximum":100},"contrast":{"supported":true,"current":75,"maximum":100},"dark_stabilizer":{"supported":true,"current":0,"maximum":3},"dark_stabilizer_cycle":{"supported":true,"readback_available":false,"current":null},"preset":{"supported":true,"current":30,"maximum":255,"id":"game2"},"presets":[{"id":"standard","name":"Standard"},{"id":"game2","name":"Game 2"}]}'
        [void]$script:monitorWorker.AddScript("Start-Sleep -Milliseconds 900; '$monitorFixture' | ConvertFrom-Json")
        $script:monitorJob = $script:monitorWorker.BeginInvoke()
        Set-MonitorEnabled
        Show-Page "Monitor"
        Assert-Equal $script:monitorApply.brightness.Enabled $false
        $script:monitorUiTicks = 0
        $probeTimer = [Windows.Forms.Timer]::new()
        $probeTimer.Interval = 40
        $probeTimer.Add_Tick({ $script:monitorUiTicks++ })
        $probeTimer.Start()
        $deadline = [datetime]::UtcNow.AddSeconds(5)
        try {
            while (-not $script:monitorJob.IsCompleted) {
                [Windows.Forms.Application]::DoEvents()
                Show-Page "Status"
                Show-Page "Monitor"
                if ([datetime]::UtcNow -gt $deadline) { throw "Monitor fixture did not finish." }
                Start-Sleep -Milliseconds 10
            }
        } finally { $probeTimer.Stop(); $probeTimer.Dispose() }
        if ($script:monitorUiTicks -lt 8) { throw "UI timer froze during slow monitor I/O." }
        Update-Monitor
        Assert-Equal $script:monitorControls.brightness.Value 75
        Assert-Equal $script:monitorControls.preset.SelectedIndex 1
        Assert-Equal $script:monitorApply.brightness.Enabled $true
        Assert-Equal $script:monitorNames.dark_stabilizer "Dark Stabilizer"
        Assert-Equal $script:monitorControls.ContainsKey("dark_stabilizer") $false
        Assert-Equal $script:monitorApply.ContainsKey("dark_stabilizer") $false
        Assert-Equal ($script:monitorDarkLevels -is [Windows.Forms.Label]) $true
        Assert-Equal $script:monitorDarkLevels.Text "Disabled / Enabled level 1-3"
        $darkLabels = @($pageMonitor.Controls | Where-Object { $_.Text -eq "Dark Stabilizer" })
        Assert-Equal $darkLabels.Count 1
        Assert-Equal $script:monitorCycle.Enabled $true
        Assert-Equal $script:monitorCycle.Text "Cycle (F9)"
        Assert-Equal $script:monitorCycle.Left $script:monitorApply.brightness.Left
        Assert-Equal $script:monitorCycle.Size $script:monitorApply.brightness.Size
        Assert-Equal $script:monitorCycle.Top ($script:monitorDarkLevels.Top - 2)
        if ([Windows.Forms.TextRenderer]::MeasureText($script:monitorCycle.Text, $script:monitorCycle.Font).Width + 12 -gt $script:monitorCycle.Width) {
            throw "Dark Stabilizer cycle button text is clipped."
        }
        foreach ($control in @($script:monitorControls.Values) + @($script:monitorApply.Values) +
                @($script:monitorRefresh, $script:monitorMessage, $script:monitorCycle,
                    $script:monitorHotkeyHint, $script:monitorClaimHotkey, $script:monitorDarkLevels)) {
            if ($control.Parent -ne $pageMonitor -or $control.Bounds.Bottom -gt $pageMonitor.ClientSize.Height) {
                throw "Monitor controls are outside their page."
            }
        }
        $bitmap = [Drawing.Bitmap]::new($f.Width, $f.Height)
        try { $f.DrawToBitmap($bitmap, $f.ClientRectangle) } finally { $bitmap.Dispose() }
        $script:monitorWorker.Commands.Clear()
        $unsupportedFixture = $monitorFixture | ConvertFrom-Json
        $unsupportedFixture.dark_stabilizer = [pscustomobject]@{ supported = $false; error = "fixture levels unavailable" }
        $unsupportedJson = $unsupportedFixture | ConvertTo-Json -Depth 8 -Compress
        [void]$script:monitorWorker.AddScript("'$unsupportedJson' | ConvertFrom-Json")
        $script:monitorJob = $script:monitorWorker.BeginInvoke()
        while (-not $script:monitorJob.IsCompleted) { Start-Sleep -Milliseconds 10 }
        Update-Monitor
        Assert-Equal $script:monitorDarkLevels.Text "Disabled / Enabled level 1-3"
        Assert-Equal $script:monitorDarkLevels.Enabled $true
        Assert-Equal $script:monitorCycle.Enabled $true
        Assert-Equal $script:monitorApply.brightness.Enabled $true
        if ($script:monitorMessage.Text -notlike "*fixture levels unavailable*") { throw "Unsupported control was hidden." }
        $script:monitorWorker.Commands.Clear()
        $script:monitorWorker.Streams.Error.Clear()
        [void]$script:monitorWorker.AddScript('throw "fixture monitor disconnected"')
        $script:monitorJob = $script:monitorWorker.BeginInvoke()
        while (-not $script:monitorJob.IsCompleted) { Start-Sleep -Milliseconds 10 }
        Update-Monitor
        Assert-Equal $script:monitorApply.brightness.Enabled $false
        Assert-Equal $script:monitorRefresh.Enabled $true
        if ($script:monitorMessage.Text -notlike "*fixture monitor disconnected*") {
            throw "Monitor failure was not reported."
        }
        Assert-Equal $script:monitorCycle.Enabled $false
        Assert-Equal $script:monitorDarkLevels.Text "Disabled / Enabled level 1-3"
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class DeskMonitorTestInput {
    [StructLayout(LayoutKind.Sequential)]
    struct Keyboard { public ushort Key, Scan; public uint Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct Mouse { public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Explicit)]
    struct Data { [FieldOffset(0)] public Keyboard Keyboard; [FieldOffset(0)] public Mouse Mouse; }
    [StructLayout(LayoutKind.Sequential)]
    struct Input { public uint Type; public Data Data; }
    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint count, Input[] inputs, int size);
    public static void Key(ushort key, bool up) {
        var input = new Input { Type = 1,
            Data = new Data { Keyboard = new Keyboard { Key = key, Flags = up ? 2u : 0u } } };
        if (SendInput(1, new[] { input }, Marshal.SizeOf<Input>()) != 1)
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
        $script:monitorHotkey.Dispose()
        $script:monitorHotkey = [DeskMonitorHotkey]::new(0x87) # F24 fixture never claims the live F9.
        $script:monitorHotkeyDeliveries = 0
        $script:monitorHotkey.Add_Pressed({
            $script:monitorHotkeyDeliveries++
            Start-MonitorOperation "dark_stabilizer_cycle"
        })
        $blocker = [DeskMonitorHotkey]::new(0x87)
        try {
            if (-not $blocker.Register()) { throw "F24 fixture unavailable: $($blocker.RegistrationError)" }
            Register-MonitorHotkey
            Assert-Equal $script:monitorHotkey.Registered $false
            Assert-Equal $script:monitorClaimHotkey.Enabled $true
            if ($script:monitorHotkeyHint.Text -notlike "*F9 unavailable*Exit DDM*") { throw "Hotkey collision was not reported." }
        } finally { $blocker.Dispose() }
        Register-MonitorHotkey
        Assert-Equal $script:monitorHotkey.Registered $true
        Assert-Equal $script:monitorClaimHotkey.Enabled $false
        if ($script:monitorMessage.Text -like "F9 unavailable*") { throw "Reclaimed hotkey still reports a collision." }

        $cycleFixture = $unsupportedFixture
        $cycleFixture | Add-Member action ([pscustomobject]@{
            control = "dark_stabilizer_cycle"; command_accepted = $true; state_verified = $false
            current = $null; vcp_code = 227; value = 16; write_count = 1
        })
        $cycleJson = $cycleFixture | ConvertTo-Json -Depth 8 -Compress
        $script:monitorWorker.Dispose()
        $cycleState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $cycleState.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new("Get-FixtureMonitorCycle",
            "param(`$MonitorRequest) `$global:cycleRequests.Add(`$MonitorRequest.Control); Start-Sleep -Milliseconds 900; if (`$global:cycleFail) { throw 'fixture cycle timed out; may have reached the monitor; current level is unavailable. No automatic retry was made.' }; '$cycleJson' | ConvertFrom-Json"))
        $cycleRunspace = [RunspaceFactory]::CreateRunspace($cycleState)
        $cycleRunspace.Open()
        $cycleRequests = [Collections.Generic.List[string]]::new()
        $cycleRunspace.SessionStateProxy.SetVariable("cycleRequests", $cycleRequests)
        $script:monitorWorker = [PowerShell]::Create()
        $script:monitorWorker.Runspace = $cycleRunspace
        $startMonitor = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Start-MonitorOperation"
        }, $true)
        $script:monitorFixtureCommand = "Get-FixtureMonitorCycle"
        . ([scriptblock]::Create($startMonitor.Extent.Text.Replace('$PSCommandPath', '$script:monitorFixtureCommand')))
        $script:monitorSnapshot = $null
        $f.Hide()
        try {
            [DeskMonitorTestInput]::Key(0x87, $false)
            $deadline = [datetime]::UtcNow.AddSeconds(3)
            while (-not $script:monitorJob) {
                [Windows.Forms.Application]::DoEvents()
                if ([datetime]::UtcNow -gt $deadline) { throw "Hidden-window hotkey did not start the fixture." }
                Start-Sleep -Milliseconds 5
            }
            $firstJob = $script:monitorJob
            [DeskMonitorTestInput]::Key(0x87, $false)
            [Windows.Forms.Application]::DoEvents()
            Assert-Equal $script:monitorHotkeyDeliveries 1
        } finally { [DeskMonitorTestInput]::Key(0x87, $true) }
        [DeskMonitorTestInput]::Key(0x87, $false)
        [DeskMonitorTestInput]::Key(0x87, $true)
        $deadline = [datetime]::UtcNow.AddSeconds(3)
        while ($script:monitorHotkeyDeliveries -lt 2) {
            [Windows.Forms.Application]::DoEvents()
            if ([datetime]::UtcNow -gt $deadline) { throw "Second hotkey press was not dispatched." }
            Start-Sleep -Milliseconds 5
        }
        Assert-Equal $script:monitorJob $firstJob
        if ($script:monitorMessage.Text -notlike "*busy*not sent or queued*") { throw "Busy cycle was silently dropped or queued." }
        if (-not $firstJob.AsyncWaitHandle.WaitOne(5000)) { throw "Cycle fixture did not finish." }
        Update-Monitor
        Assert-Equal $cycleRequests.Count 1
        Assert-Equal $cycleRequests[0] "dark_stabilizer_cycle"
        Assert-Equal $script:monitorDarkLevels.Text "Disabled / Enabled level 1-3"
        if ($script:monitorMessage.Text -notlike "*command accepted*Current level unavailable*") { throw "Cycle claimed an unverified level." }
        if ($script:monitorMessage.Text -like "*Hardware readback confirmed*") { throw "Cycle falsely claimed hardware verification." }
        foreach ($control in @($script:monitorHotkeyHint, $script:monitorMessage, $monitorNote, $monitorHint,
                $script:monitorDarkLevels, $darkLabels[0])) {
            $measured = [Windows.Forms.TextRenderer]::MeasureText($control.Text, $control.Font,
                $control.Size, [Windows.Forms.TextFormatFlags]::WordBreak)
            if ($measured.Height -gt $control.Height) { throw "Monitor label is clipped: $($control.Text)" }
        }
        $cycleRunspace.SessionStateProxy.SetVariable("cycleFail", $true)
        $f.Show()
        Show-Page "Monitor"
        $script:monitorCycle.PerformClick()
        if (-not $script:monitorJob -or -not $script:monitorJob.AsyncWaitHandle.WaitOne(5000)) {
            throw "Cycle button did not start its asynchronous fixture."
        }
        Update-Monitor
        Assert-Equal $cycleRequests.Count 2
        Assert-Equal $script:monitorCycle.Enabled $false
        Assert-Equal $script:monitorRefresh.Enabled $true
        if ($script:monitorMessage.Text -notlike "*cycle timed out*may have reached*current level is unavailable*No automatic retry*") {
            throw "Uncertain cycle failure was not surfaced."
        }
        Start-Sleep -Milliseconds 100
        Update-Monitor
        Assert-Equal $cycleRequests.Count 2
        $script:monitorSnapshot = $cycleFixture
        $script:monitorSnapshot.dark_stabilizer_cycle = [pscustomobject]@{ supported = $false; error = "fixture no E3" }
        Set-MonitorEnabled
        Assert-Equal $script:monitorCycle.Enabled $false
        Start-MonitorOperation "dark_stabilizer_cycle"
        Assert-Equal $script:monitorJob $null
        if ($script:monitorMessage.Text -notlike "*not advertised*no command sent*") { throw "Unsupported cycle was not reported." }
        $script:monitorHotkey.Dispose()
        $released = [DeskMonitorHotkey]::new(0x87)
        try {
            if (-not $released.Register()) { throw "Hotkey was not released on disposal." }
        } finally { $released.Dispose() }
        Write-Output "PASS: ordinary hidden-window hotkey delivery before first monitor read, MOD_NOREPEAT, collision/reclaim/release, one async cycle, busy/no-queue and unknown-level UI; F24 fixture only, no real monitor writes."
        Show-Page "Status"
        Write-Output "PASS: Monitor icon/page bounds, slow-I/O UI timer responsiveness, readback display and disconnected fail-closed controls; no real monitor probes or writes."
        Write-Output "PASS: native STA desk construction/render and AFK option bounds; no actions or status probes started."
    } finally {
        if ($timer) { $timer.Stop(); $timer.Dispose() }
        if ($script:statusWorker) { $script:statusWorker.Dispose() }
        if ($script:askWorker) { $script:askWorker.Dispose() }
        if ($script:monitorWorker) { $script:monitorWorker.Stop(); $script:monitorWorker.Dispose() }
        if ($cycleRunspace) { $cycleRunspace.Dispose() }
        if ($script:monitorHotkey) { $script:monitorHotkey.Dispose() }
        if ($script:ni) { $script:ni.Visible = $false; $script:ni.Dispose() }
        if ($f) { $f.Dispose() }
    }
}
