[CmdletBinding()]
param([Parameter(Mandatory)][string]$BatchDirectory)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$parent = Join-Path $repo 'godbrain_core\skill_lab\work\tests'
[void][IO.Directory]::CreateDirectory($parent)
$fixture = Join-Path $parent ('publish-' + [guid]::NewGuid().ToString('N'))
$checkout = Join-Path $fixture 'checkout'
$remote = Join-Path $fixture 'remote.git'
$batch = Join-Path $fixture 'batch'
$nativeGit = (Get-Command git.exe).Source
$pushes = [Collections.Generic.List[string]]::new()
function Invoke-TestGit([string[]]$Arguments) {
    & $nativeGit @Arguments | Out-Null
    if ($LASTEXITCODE) { throw "Fixture git failed: $($Arguments[0])" }
}
function git {
    $forward = @($args)
    foreach ($operation in @('push','ls-remote')) {
        $position = [Array]::IndexOf($forward, $operation)
        if ($position -ge 0) {
            if ($forward[$position + 1] -cne 'origin' -or $forward[2] -cne $checkout) {
                throw 'Fixture attempted an unexpected remote operation.'
            }
            $forward[$position + 1] = $remote
            if ($operation -eq 'push') { $pushes.Add('local bare fixture only') }
        }
    }
    & $nativeGit @forward
    $global:LASTEXITCODE = $LASTEXITCODE
}
function Expect-Rejection([scriptblock]$Action, [string]$Label, [string]$ExpectedMessage = '') {
    $rejected = $false
    try { & $Action | Out-Null } catch {
        if ($ExpectedMessage -and $_.Exception.Message -notlike $ExpectedMessage) { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw "Expected publication rejection: $Label" }
}
try {
    [void][IO.Directory]::CreateDirectory($checkout)
    Copy-Item -LiteralPath $BatchDirectory -Destination $batch -Recurse
    $builder = Join-Path $fixture 'builder'
    [void][IO.Directory]::CreateDirectory($builder)
    Copy-Item -LiteralPath (Join-Path $batch 'site') -Destination (Join-Path $builder 'showcase') -Recurse
    $originalCatalog = (Get-FileHash -LiteralPath (Join-Path $builder 'showcase\catalog.json') -Algorithm SHA256).Hash
    $captures = Join-Path $fixture 'empty-captures'
    [void][IO.Directory]::CreateDirectory($captures)
    $refresh = Join-Path $PSScriptRoot 'Refresh-Showcase.ps1'
    Expect-Rejection {
        & $refresh -BuilderWorkDir $builder -CaptureDirectory $captures -BatchDirectory (Join-Path $fixture 'missing-capture') -SkipCapture
    } 'missing capture' 'Showcase conversion failed.*'
    $header = [byte[]](0x89,0x50,0x4e,0x47,13,10,26,10,0,0,0,13,0x49,0x48,0x44,0x52,0,0,0,2,0,0,0,2)
    [IO.File]::WriteAllBytes((Join-Path $captures 'CMDSTATUS.png'), $header)
    Expect-Rejection {
        & $refresh -BuilderWorkDir $builder -CaptureDirectory $captures -BatchDirectory (Join-Path $fixture 'encoder-failure') `
            -Ffmpeg (Join-Path $env:SystemRoot 'System32\where.exe') -SkipCapture
    } 'encoder failure' 'Showcase conversion failed.*'
    if ((Get-FileHash -LiteralPath (Join-Path $builder 'showcase\catalog.json') -Algorithm SHA256).Hash -cne $originalCatalog) {
        throw 'A failed capture/encode replaced the last good builder catalog.'
    }
    Invoke-TestGit @('init','--bare',$remote)
    Invoke-TestGit @('init','--initial-branch=main',$checkout)
    Invoke-TestGit @('-C',$checkout,'config','user.name','Showcase fixture')
    Invoke-TestGit @('-C',$checkout,'config','user.email','fixture@example.invalid')
    Invoke-TestGit @('-C',$checkout,'config','core.autocrlf','false')
    Invoke-TestGit @('-C',$checkout,'remote','add','origin','https://github.com/autom8edIT/autom8edIT.github.io.git')
    [IO.File]::WriteAllText((Join-Path $checkout 'index.md'), "# Test portfolio`n")
    [void][IO.Directory]::CreateDirectory((Join-Path $checkout 'assets\js'))
    [IO.File]::WriteAllText((Join-Path $checkout 'assets\js\theme.js'), '// Local fixture theme')
    Invoke-TestGit @('-C',$checkout,'add','--','index.md','assets/js/theme.js')
    Invoke-TestGit @('-C',$checkout,'commit','-m',"Create local publication fixture`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>")
    $publisher = Join-Path $PSScriptRoot 'Publish-Showcase.ps1'
    & $publisher -BatchDirectory $batch -PublishingCheckout $checkout | Out-Null
    $review = Get-Content -LiteralPath (Join-Path $batch 'publishing-review.json') -Raw | ConvertFrom-Json
    if (-not $review.files.Count -or $pushes.Count) { throw 'Staging pushed or produced no review.' }
    if (-not (Test-Path -LiteralPath (Join-Path $batch 'preview\assets\js\theme.js')) -or
        (Get-FileHash -LiteralPath (Join-Path $batch 'preview\projects\catalog.json') -Algorithm SHA256).Hash -cne $originalCatalog) {
        throw 'Public-only preview did not preserve the approved catalog/theme.'
    }
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish } 'missing approval'
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview ('0' * 64) } 'wrong approval'
    $css = Join-Path $checkout 'projects\gallery.css'
    $original = [IO.File]::ReadAllBytes($css)
    [IO.File]::AppendAllText($css, "`nbody{color:red}")
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 } 'unstaged mutation'
    Invoke-TestGit @('-C',$checkout,'add','--','projects/gallery.css')
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 } 'staged mutation'
    [IO.File]::WriteAllBytes($css, $original)
    Invoke-TestGit @('-C',$checkout,'add','--','projects/gallery.css')
    if ($pushes.Count) { throw 'A rejected approval attempted a push.' }
    & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 | Out-Null
    if ($pushes.Count -ne 1) { throw 'Approved fixture did not push exactly once to the local bare fixture.' }
    $message = & $nativeGit -C $checkout log -1 --format=%B
    if (($message -join "`n") -notmatch 'Co-authored-by: Copilot') { throw 'Commit trailer missing.' }
    $again = & $publisher -BatchDirectory $batch -PublishingCheckout $checkout
    if (($again -join "`n") -notmatch 'Unchanged showcase' -or $pushes.Count -ne 1) { throw 'Unchanged refresh did not stay a no-op.' }
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 } 'stale HEAD approval'
    Write-Output 'PASS: failed capture/encoder preserve the last good catalog; hash-bound staging, missing/wrong/stale approval, working-tree/index tampering, exact scoped commit, local-bare-only push/readback, trailer and unchanged no-op. No GitHub publication.'
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
