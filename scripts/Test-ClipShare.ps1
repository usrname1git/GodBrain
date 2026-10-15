[CmdletBinding()]
param([switch]$Live, [switch]$Ui)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GodBrain-ClipShare.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
foreach ($name in 'GodBrain-ClipShare.ps1','Show-DeskMenu.ps1','Test-ClipShare.ps1') {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
    Assert (-not $errors.Count) "Parse failure in $name"
}
& {
    function Get-GodBrainClipSharePublicVerification { return $null }
    function Invoke-GodBrainClipShareCommand { param($Command); return @{line="fixture:$Command"} }
    function Test-Path { param($LiteralPath,$PathType); return $false }
    foreach ($action in 'Start','Stop','Inbox','Library','Copy','Login') {
        Assert ((Invoke-GodBrainClipShare $action) -eq "fixture:$($action.ToLowerInvariant())") 'Action mapping changed.'
    }
    Assert ((Get-GodBrainClipShareLine) -eq 'not installed') 'Missing installation was not reported.'
}
& {
    function Get-GodBrainClipSharePublicVerification { return $null }
    function Test-Path { param($LiteralPath,$PathType); return $true }
    $calls = [Collections.Generic.List[string]]::new()
    function Invoke-GodBrainClipShareCommand {
        param($Command, [switch]$Ingress)
        $component = if ($Ingress) { 'ingress' } else { 'media' }
        $calls.Add("${component}:$Command")
        return @{line="${component}:$Command"}
    }
    Assert ((Invoke-GodBrainClipShare 'Start') -eq 'media:start; ingress: ingress:start') 'Configured start receipt lost ingress state.'
    Assert (($calls -join ',') -eq 'media:start,ingress:start') 'Ingress started before the backend was ready.'
    $calls.Clear()
    $null = Invoke-GodBrainClipShare 'Stop'
    Assert (($calls -join ',') -eq 'ingress:stop,media:stop') 'Backend stopped before ingress.'
    Assert ((Get-GodBrainClipShareLine) -eq 'media:status; ingress: ingress:status') 'Configured ingress status was hidden.'
    $calls.Clear()
    function Invoke-GodBrainClipShareCommand {
        param($Command, [switch]$Ingress)
        $calls.Add("$(if ($Ingress) {'ingress'} else {'media'}):$Command")
        throw 'fixture component failure'
    }
    $failed = $false
    try { $null = Invoke-GodBrainClipShare 'Stop' }
    catch { $failed = $_.Exception.Message -eq 'fixture component failure' }
    Assert ($failed -and ($calls -join ',') -eq 'ingress:stop') 'Ingress stop failure did not prevent backend shutdown.'
    $calls.Clear()
    $failed = $false
    try { $null = Invoke-GodBrainClipShare 'Start' }
    catch { $failed = $_.Exception.Message -eq 'fixture component failure' }
    Assert ($failed -and ($calls -join ',') -eq 'media:start') 'Failed backend start still launched ingress.'
}
& {
    function Test-Path { param($LiteralPath,$PathType); return $true }
    function Invoke-GodBrainClipShareCommand { param($Command); throw 'fixture identity mismatch' }
    Assert ((Get-GodBrainClipShareLine) -like 'unread:*identity mismatch*') 'Identity/readiness errors were hidden.'
}
& {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('GodBrain-ClipShareHistory-' + [guid]::NewGuid().ToString('N'))
    $files = [ordered]@{
        template_sha256 = 'Caddyfile.example'
        config_sha256 = 'local\ingress\Caddyfile'
        caddy_sha256 = 'tools\caddy\caddy.exe'
        controller_sha256 = 'build\Release\clipshare.exe'
    }
    function Get-GodBrainClipShareRoot { return $fixture }
    $proofPath = Join-Path $fixture 'local\ingress\public-verification.json'
    try {
        foreach ($file in $files.GetEnumerator()) {
            $path = Join-Path $fixture $file.Value
            $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
            [IO.File]::WriteAllText($path, "synthetic $($file.Key)")
        }
        $base = 'https://share.example.test'
        @{ public_base = $base } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $fixture 'local\settings.json') -Encoding utf8
        $raw = 'ready :3923 (external URL unverified); ingress: Local TLS ready; external reachability still unverified'
        Assert ((Format-GodBrainClipShareLine $raw -PublicHistory) -eq 'ready :3923; ingress: Local TLS ready') 'Missing history did not remove boilerplate cleanly.'
        $proof = [ordered]@{
            schema_version = 1; at = '2026-01-02T03:04:05.1234567Z'
            status = 'pass'; public_reachability_verified = $true; public_base = $base
        }
        foreach ($file in $files.GetEnumerator()) {
            $proof[$file.Key] = (Get-FileHash -LiteralPath (Join-Path $fixture $file.Value) -Algorithm SHA256).Hash
        }
        $proof | ConvertTo-Json | Set-Content -LiteralPath $proofPath -Encoding utf8
        $expected = 'ready :3923; ingress: Local TLS ready; last verified at 2026-01-02 03:04 UTC'
        Assert ((Format-GodBrainClipShareLine $raw -PublicHistory) -eq $expected) 'Successful historical check was not dated or uppercase hashes were rejected.'
        $history = Get-GodBrainClipSharePublicVerification
        Assert ($history.MatchesCurrentSetup -is [bool] -and $history.MatchesCurrentSetup -eq $true) 'Identical setup did not return a true Boolean match.'
        Assert ((Format-GodBrainClipShareLine 'Link copied; external reachability not verified' -PublicHistory) -eq 'Link copied; last verified at 2026-01-02 03:04 UTC') 'Copy receipt kept obsolete verification wording.'
        Assert ((Format-GodBrainClipShareLine 'Ingress failed: receiver certificate unverified') -eq 'Ingress failed: receiver certificate unverified') 'A genuine component error was filtered.'
        $native = [pscustomobject]@{ line = $raw; public_reachability_verified = $false }
        $null = Format-GodBrainClipShareLine $native.line -PublicHistory
        Assert ($native.public_reachability_verified -eq $false) 'Historical display changed the native verification flag.'
        $controller = Join-Path $fixture $files.controller_sha256
        [IO.File]::WriteAllText($controller, 'new synthetic build')
        Assert ((Format-GodBrainClipShareLine $raw -PublicHistory) -eq "$expected (setup changed)") 'A changed executable inherited the old check without qualification.'
        $history = Get-GodBrainClipSharePublicVerification
        Assert ($history.MatchesCurrentSetup -is [bool] -and $history.MatchesCurrentSetup -eq $false) 'Changed setup did not return a false Boolean match.'
        foreach ($key in @('status', 'public_reachability_verified', 'at', 'controller_sha256')) {
            $original = $proof[$key]
            $proof[$key] = switch ($key) {
                'status' { 'fail' }
                'public_reachability_verified' { 'true' }
                'at' { [datetime]::UtcNow.AddDays(1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
                'controller_sha256' { 'invalid hash' }
            }
            $proof | ConvertTo-Json | Set-Content -LiteralPath $proofPath -Encoding utf8
            $line = Format-GodBrainClipShareLine $raw -PublicHistory
            Assert ($line -like 'ready :3923; ingress: Local TLS ready; verification history unreadable:*' -and $line -notlike '*last verified at*') "Invalid $key became a verified timestamp or hid local readiness."
            $proof[$key] = $original
        }
        $proof.public_base = 'https://different.example.test'
        $proof | ConvertTo-Json | Set-Content -LiteralPath $proofPath -Encoding utf8
        Assert ((Format-GodBrainClipShareLine $raw -PublicHistory) -eq 'ready :3923; ingress: Local TLS ready') 'A different URL inherited historical verification.'
        [IO.File]::WriteAllText($proofPath, 'invalid JSON')
        Assert ((Format-GodBrainClipShareLine $raw -PublicHistory) -like '*verification history unreadable:*') 'Corrupt history was hidden.'
    } finally {
        foreach ($file in @($files.Values) + @('local\settings.json', 'local\ingress\public-verification.json')) {
            $path = Join-Path $fixture $file
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path }
        }
        foreach ($directory in @('local\ingress', 'tools\caddy', 'build\Release', 'local', 'tools', 'build', '')) {
            $path = if ($directory) { Join-Path $fixture $directory } else { $fixture }
            if (Test-Path -LiteralPath $path -PathType Container) { Remove-Item -LiteralPath $path }
        }
    }
    Write-Host 'PASS: dated public-check history, hash/URL binding, changed setup, missing/corrupt evidence and preserved native readiness'
}
if ($Live) {
    $status = Invoke-GodBrainClipShareCommand 'status'
    Assert $status.ready 'Installed ClipShare is not ready.'
    $again = Invoke-GodBrainClipShareCommand 'start'
    Assert ($again.pid -eq $status.pid) 'Desk Start did not reuse the verified instance.'
    if (Test-Path -LiteralPath (Join-Path (Get-GodBrainClipShareRoot) 'local\ingress\native-settings.json') -PathType Leaf) {
        $ingress = Invoke-GodBrainClipShareCommand 'status' -Ingress
        $null = Invoke-GodBrainClipShare 'Start'
        $same = Invoke-GodBrainClipShareCommand 'status' -Ingress
        Assert ($ingress.alive -and $same.pid -eq $ingress.pid -and $same.created -eq $ingress.created) 'Configured Desk Start replaced the active ingress.'
    }
}
if ($Ui) {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run the UI fixture with pwsh -Sta.' }
    $path = Join-Path $PSScriptRoot 'Show-DeskMenu.ps1'
    $script:clipFixtureScripts = $PSScriptRoot
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    $source=[Collections.Generic.List[string]]::new()
    foreach($statement in $ast.EndBlock.Statements) {
        if($statement.Extent.Text -eq '$f.Show()') { break }
        if($statement.Extent.Text -in 'Update-Status','$timer.Start()') { continue }
        $source.Add($statement.Extent.Text)
    }
    $ControlPanelHost=$true
    $Status=$false; $StatusSnapshot=$false; $AirPlayRequest=$null; $ClipShareRequest=$null
    $AskRequest=$null; $MonitorRequest=$null; $DisplayRequest=$null
    try {
        . ([scriptblock]::Create(($source -join "`n").Replace('$PSScriptRoot','$script:clipFixtureScripts').Replace('$PSCommandPath',"'$path'")))
        Show-Page 'Share'
        $script:clipShareStatus.Text = Get-GodBrainClipShareLine
        $f.Show()
        [Windows.Forms.Application]::DoEvents()
        Assert $pageShare.Visible 'Share route is not visible.'
        foreach($text in 'Start','Stop','Inbox','Library','Copy link','Copy login') {
            Assert (@($pageShare.Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq $text }).Count -eq 1) "Missing Share control: $text"
        }
        foreach($control in $pageShare.Controls) {
            Assert ($control.Bottom -le $pageShare.ClientSize.Height -and $control.Right -le $pageShare.ClientSize.Width) 'Share control is clipped at minimum size.'
        }
        Show-Page 'Status'
        Assert ($afkGym.Bottom -le $pageStatus.ClientSize.Height) 'AFK checkbox was clipped by the new status row.'
        Assert ($rowClipShare.Text -ne $null) 'ClipShare status row is missing.'
        Show-Page 'Share'
        $bitmap=[Drawing.Bitmap]::new($f.Width,$f.Height)
        try {
            $f.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$f.Width,$f.Height))
            $out=Join-Path (Get-GodBrainClipShareRoot) 'build\desk-share-fixture.png'
            $bitmap.Save($out)
            Write-Host "PASS: native Desk Share route and minimum-size layout; screenshot $out"
        } finally { $bitmap.Dispose() }
    } finally {
        if($timer) { $timer.Stop(); $timer.Dispose() }
        foreach($worker in @($script:statusWorker,$script:askWorker,$script:airPlayWorker,$script:clipShareWorker,$script:monitorWorker,$script:displayWorker)) {
            if($worker) { $worker.Stop(); $worker.Dispose() }
        }
        if($script:monitorHotkey) { $script:monitorHotkey.Dispose() }
        Clear-DisplayHotkeys
        if($script:ni) { $script:ni.Visible=$false; $script:ni.Dispose() }
        if($f) { $f.Dispose() }
    }
}
Write-Host 'PASS: ClipShare Desk syntax, operations, missing-installation and explicit-error fixtures'
