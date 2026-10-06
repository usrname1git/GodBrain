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
    "Get-DeskJailRoots", "ConvertTo-DeskAskPath", "Test-DeskGrantedPath", "Test-DeskPathToken", "Get-DeskImagePayload", "Wait-DeskImageResult", "Invoke-DeskAsk")) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text.Replace('$PSScriptRoot', '$script:fixtureRoot')))
}

function Test-Port([int]$Port) { return $Port -in $script:ports }
function Invoke-RestMethod {
    param([string]$Uri, [int]$TimeoutSec, [string]$Method, [string]$Body, [string]$ContentType)
    if ($script:httpFails) { throw "Fixture HTTP failure" }
    $script:lastUri = $Uri
    $script:lastBody = $Body
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
    $Repo = "fixture"; $script:controlCalls = @(); $script:logonInstalled = $true; $script:taskFails = ""
    function Update-Status {}
    function Confirm-Stop { param($Message, $Title); return $true }
    function Set-DeskPause { param($Name); $script:controlCalls += "hold:on" }
    function Set-GodBrainMouthPaused { param($RepoRoot, $On); $script:controlCalls += "hold:on" }
    function Enable-DeskAfterCs2 { return $true }
    function Test-GodBrainTaskExists { param($TaskName); return $script:logonInstalled }
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
        return @{ ExitCode = $(if ($script:taskFails -and $ArgumentList -contains $script:taskFails) { 5 } else { 0 }) }
    }
    Stop-MouthHold
    Assert-Equal ($script:controlCalls -join ",") "hold:on,stop:10,stop:13"
    $script:controlCalls = @()
    Set-WatchTask "ENABLE"
    Assert-Equal ($script:controlCalls -join ",") "/Change /TN GodBrainLogon /ENABLE,/Change /TN GodBrainWatch /ENABLE,hold:off,/Run /TN GodBrainWatch"
    $script:controlCalls = @(); $script:logonInstalled = $false
    Set-WatchTask "ENABLE"
    Assert-Equal ($script:controlCalls -join ",") "/Change /TN GodBrainWatch /ENABLE,hold:off,/Run /TN GodBrainWatch"
    $script:controlCalls = @(); $script:logonInstalled = $true; $script:taskFails = "GodBrainLogon"
    Set-WatchTask "ENABLE" | Out-Null
    Assert-Equal ($script:controlCalls -join ",") "/Change /TN GodBrainLogon /ENABLE"
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

$script:processFails = $false
$script:processes = @()
Assert-Equal (Get-WhisperLine) "CPU lyrics idle (no port)"
$worker = Join-Path $PSScriptRoot "lyrics_loop.py"
$script:processes = @(@{ CommandLine = 'python.exe "' + $worker + '" --name fixture' })
Assert-Equal (Get-WhisperLine) "CPU lyrics running (no port)"
$script:processes = @(@{ CommandLine = "python.exe $worker --name fixture" })
Assert-Equal (Get-WhisperLine) "CPU lyrics running (no port)"
$script:processes = @(@{ CommandLine = "python.exe $worker.backup" })
Assert-Equal (Get-WhisperLine) "CPU lyrics idle (no port)"
$script:processFails = $true
Assert-Equal (Get-WhisperLine) "CPU lyrics process unread"

function Start-ImageDoor { $script:imageStarted = $true }
function Stop-ImageDoor { $script:imageStopped = $true }
function Enable-DeskAfterCs2 { return $script:canResume }
function Stop-Door { $script:slotStopped = $true; return $true }
function Start-Door([string]$File) { $script:startedFile = $File }
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
    $ControlPanelHost = $true; $Status = $false; $StatusSnapshot = $false; $AskRequest = $null
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
        Show-Page "Status"
        Write-Output "PASS: native STA desk construction/render and AFK option bounds; no actions or status probes started."
    } finally {
        if ($timer) { $timer.Stop(); $timer.Dispose() }
        if ($script:statusWorker) { $script:statusWorker.Dispose() }
        if ($script:askWorker) { $script:askWorker.Dispose() }
        if ($script:ni) { $script:ni.Visible = $false; $script:ni.Dispose() }
        if ($f) { $f.Dispose() }
    }
}
