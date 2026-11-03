[CmdletBinding()]
param([string]$BatchDirectory = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$parent = Join-Path $repo 'godbrain_core\skill_lab\work\tests'
[void][IO.Directory]::CreateDirectory($parent)
$fixture = Join-Path $parent ('publish-' + [guid]::NewGuid().ToString('N'))
$checkout = Join-Path $fixture 'checkout'
$fixtureRemote = Join-Path $fixture 'remote.git'
$batch = Join-Path $fixture 'batch'
$nativeGit = (Get-Command git.exe).Source
$pushes = [Collections.Generic.List[string]]::new()
$faults = [pscustomobject]@{ Push = $false; Readback = $false; ReadbackAfterPush = $false; AfterCommit = $false }
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
            $forward[$position + 1] = $fixtureRemote
            if ($operation -eq 'push') { $pushes.Add('local bare fixture only') }
            if (($operation -eq 'push' -and $faults.Push) -or
                ($operation -eq 'ls-remote' -and $faults.Readback)) {
                $global:LASTEXITCODE = 1
                return
            }
        }
    }
    & $nativeGit @forward
    $global:LASTEXITCODE = $LASTEXITCODE
    if ($faults.ReadbackAfterPush -and $forward -contains 'push' -and -not $LASTEXITCODE) {
        $faults.Readback = $true
    }
    if ($faults.AfterCommit -and $forward -contains 'commit' -and -not $LASTEXITCODE) {
        $global:LASTEXITCODE = 1
    }
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
    if ($BatchDirectory) {
        Copy-Item -LiteralPath $BatchDirectory -Destination $batch -Recurse
    } else {
        $site = Join-Path $batch 'site'
        $imageDirectory = Join-Path $site 'assets\fixture'
        [void][IO.Directory]::CreateDirectory($imageDirectory)
        $image = [Convert]::FromBase64String('UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA')
        [IO.File]::WriteAllBytes((Join-Path $imageDirectory 'COVER.webp'), $image)
        foreach ($name in @('index.html', 'gallery.js', 'gallery.css')) {
            Copy-Item -LiteralPath (Join-Path $repo "godbrain_core\showcase\$name") -Destination (Join-Path $site $name)
        }
        @{
            schema_version=1; projects=@(@{
                id='fixture'; title='Synthetic project'; description='Synthetic local publication fixture.'
                url='https://example.org/'; source_url='https://github.com/example/project'; cover='COVER'
                images=@(@{
                    id='COVER'; path='assets/fixture/COVER.webp'; width=1; height=1
                    sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($image)).ToLowerInvariant()
                    description='Synthetic pixel'; capture_kind='synthetic-test'
                })
            })
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $site 'catalog.json') -Encoding utf8
        $entries = @(); $binding = ''
        foreach ($name in @('index.html','gallery.js','gallery.css','catalog.json','assets/fixture/COVER.webp')) {
            $hash = (Get-FileHash -LiteralPath (Join-Path $site $name) -Algorithm SHA256).Hash.ToLowerInvariant()
            $entries += @{path=$name; sha256=$hash}
            $binding += "$name`n$hash`n"
        }
        @{
            schema_version=1; ok=$true; operator_review_required=$true; files=$entries
            batch_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($binding))).ToLowerInvariant()
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $batch 'review.json') -Encoding utf8
    }
    $builder = Join-Path $fixture 'builder'
    [void][IO.Directory]::CreateDirectory($builder)
    Copy-Item -LiteralPath (Join-Path $batch 'site') -Destination (Join-Path $builder 'showcase') -Recurse
    $originalCatalog = (Get-FileHash -LiteralPath (Join-Path $builder 'showcase\catalog.json') -Algorithm SHA256).Hash
    $captures = Join-Path $fixture 'empty-captures'
    [void][IO.Directory]::CreateDirectory($captures)
    $refresh = Join-Path $PSScriptRoot 'Refresh-Showcase.ps1'
    Expect-Rejection {
        & $refresh -BuilderWorkDir $builder -CaptureDirectory $captures -BatchDirectory (Join-Path $fixture 'missing-capture') `
            -Ffmpeg (Join-Path $env:SystemRoot 'System32\where.exe') -SkipCapture
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
    Invoke-TestGit @('init','--bare',$fixtureRemote)
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
    foreach ($kind in @('url', 'pushurl')) {
        foreach ($extra in @('https://github.com/autom8edIT/autom8edIT.github.io.git', 'https://example.invalid/unapproved.git')) {
            if ($kind -eq 'pushurl') {
                Invoke-TestGit @('-C',$checkout,'config','--add','remote.origin.pushurl','https://github.com/autom8edIT/autom8edIT.github.io.git')
            }
            Invoke-TestGit @('-C',$checkout,'config','--add',"remote.origin.$kind",$extra)
            try {
                Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout } "multiple $kind destinations" '*dedicated*'
                if (@(& $nativeGit -C $checkout status --porcelain).Count -or $pushes.Count) {
                    throw 'An invalid destination modified the checkout or attempted a push.'
                }
            } finally {
                Invoke-TestGit @('-C',$checkout,'config','--unset-all',"remote.origin.$kind")
                if ($kind -eq 'url') {
                    Invoke-TestGit @('-C',$checkout,'config','--add','remote.origin.url','https://github.com/autom8edIT/autom8edIT.github.io.git')
                }
            }
        }
    }
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
    Invoke-TestGit @('-C',$checkout,'config','--add','remote.origin.pushurl','https://github.com/autom8edIT/autom8edIT.github.io.git')
    Invoke-TestGit @('-C',$checkout,'config','--add','remote.origin.pushurl','https://example.invalid/unapproved.git')
    try {
        Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 } 'destination changed after staging' '*dedicated*'
        if ((& $nativeGit -C $checkout rev-parse HEAD).Trim() -cne $review.base_commit -or $pushes.Count) {
            throw 'An invalid publication destination committed or attempted a push.'
        }
    } finally { Invoke-TestGit @('-C',$checkout,'config','--unset-all','remote.origin.pushurl') }
    $faults.AfterCommit = $true
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 } 'interrupted commit receipt' 'Git failed: commit'
    $faults.AfterCommit = $false
    $approvedCommit = (& $nativeGit -C $checkout rev-parse HEAD).Trim()
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout } 'pending publication must not become a staging no-op' '*pending*'
    $faults.Push = $true
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 } 'push failure' 'Git failed: push'
    $faults.Push = $false
    $pending = Get-Content -LiteralPath (Join-Path $batch 'publishing-review.json') -Raw | ConvertFrom-Json
    if ($pending.publication_commit -cne $approvedCommit -or $pending.published -ne $false -or $pushes.Count -ne 1) {
        throw 'Failed push did not preserve the exact approved pending commit.'
    }
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview ('0' * 64) } 'retry still requires approval'
    [IO.File]::AppendAllText($css, "`nbody{color:red}")
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 } 'retry working-tree mutation'
    [IO.File]::WriteAllBytes($css, $original)
    [IO.File]::AppendAllText($css, "`nbody{color:red}")
    Invoke-TestGit @('-C',$checkout,'add','--','projects/gallery.css')
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 } 'retry staged mutation'
    [IO.File]::WriteAllBytes($css, $original)
    Invoke-TestGit @('-C',$checkout,'add','--','projects/gallery.css')
    $faults.ReadbackAfterPush = $true
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 } 'readback failure' 'Git failed: ls-remote'
    $faults.ReadbackAfterPush = $false
    $faults.Readback = $false
    if ((& $nativeGit --git-dir $fixtureRemote rev-parse refs/heads/main).Trim() -cne $approvedCommit) {
        throw 'Readback failure was not exercised after the approved commit reached the remote.'
    }
    & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 | Out-Null
    if ((& $nativeGit -C $checkout rev-parse HEAD).Trim() -cne $approvedCommit -or $pushes.Count -ne 2) {
        throw 'Retry changed the approved commit or did not publish exactly that commit.'
    }
    $published = Get-Content -LiteralPath (Join-Path $batch 'publishing-review.json') -Raw | ConvertFrom-Json
    if ($published.published -ne $true -or $published.published_commit -cne $approvedCommit) {
        throw 'Remote confirmation did not persist the published commit.'
    }
    $message = & $nativeGit -C $checkout log -1 --format=%B
    if (($message -join "`n") -notmatch 'Co-authored-by: Copilot') { throw 'Commit trailer missing.' }
    $again = & $publisher -BatchDirectory $batch -PublishingCheckout $checkout
    if (($again -join "`n") -notmatch 'Unchanged showcase' -or $pushes.Count -ne 2) { throw 'Unchanged refresh did not stay a no-op.' }
    & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 | Out-Null
    if ($pushes.Count -ne 2) { throw 'Confirmed publication was pushed again.' }
    [IO.File]::AppendAllText((Join-Path $checkout 'index.md'), "`nUnrelated subsequent change`n")
    Invoke-TestGit @('-C',$checkout,'add','--','index.md')
    Invoke-TestGit @('-C',$checkout,'commit','-m',"Subsequent local fixture change`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>")
    Expect-Rejection { & $publisher -BatchDirectory $batch -PublishingCheckout $checkout -Publish -ApprovedReview $review.review_sha256 } 'stale HEAD approval'
    Write-Output 'PASS: failed capture/encoder preserve the catalog; every destination, exact approval/tree/base, tampering, interrupted commit, failed push/readback recovery, exact-commit confirmation, trailer and unchanged no-op. Local bare Git only; no GitHub publication.'
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
