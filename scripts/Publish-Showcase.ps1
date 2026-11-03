[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BatchDirectory,
    [Parameter(Mandatory)][string]$PublishingCheckout,
    [string]$ApprovedReview = '',
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'
$BatchDirectory = [IO.Path]::GetFullPath($BatchDirectory)
$PublishingCheckout = [IO.Path]::GetFullPath($PublishingCheckout)
$site = Join-Path $BatchDirectory 'site'
$reviewPath = Join-Path $BatchDirectory 'review.json'
$publishReview = Join-Path $BatchDirectory 'publishing-review.json'
foreach ($directory in @($BatchDirectory, $site, $PublishingCheckout)) {
    if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Publishing roots cannot be links or junctions.'
    }
}
function Invoke-ShowcaseGit([string[]]$Arguments) {
    $result = @(& git --no-pager -C $PublishingCheckout @Arguments)
    if ($LASTEXITCODE) { throw "Git failed: $($Arguments[0])" }
    return $result
}
function Get-ShowcaseDigest([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
function Save-ShowcaseReview($Value) {
    $temporary = $publishReview + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8))
        [IO.File]::Move($temporary, $publishReview, $true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Assert-ShowcaseFile([string]$Root, [string]$Relative, [string]$Hash) {
    if ($Relative -cnotmatch '^(?:index\.html|gallery\.(?:js|css)|catalog\.json|assets/[a-z][a-z0-9-]{0,47}/[A-Z][A-Z0-9_]{0,47}\.webp)$' -or
        $Hash -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid publishing manifest entry.' }
    $path = $Root
    foreach ($part in $Relative.Split('/')) {
        $path = Join-Path $path $part
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Linked showcase files/directories cannot be published.'
        }
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Hash) {
        throw "The reviewed file changed: $Relative"
    }
}
$review = Get-Content -LiteralPath $reviewPath -Raw | ConvertFrom-Json
if ($review.schema_version -ne 1 -or $review.ok -ne $true -or $review.operator_review_required -ne $true -or
    $review.files.Count -lt 4 -or $review.files.Count -gt 132) { throw 'Invalid showcase review manifest.' }
$binding = ''
$seen = @{}
foreach ($file in $review.files) {
    if ($seen.ContainsKey([string]$file.path)) { throw 'Duplicate publishing manifest path.' }
    $seen[[string]$file.path] = $true
    Assert-ShowcaseFile $site $file.path $file.sha256
    $binding += "$($file.path)`n$($file.sha256)`n"
}
if ((Get-ShowcaseDigest $binding) -cne $review.batch_sha256) { throw 'Showcase batch binding mismatch.' }
foreach ($required in @('index.html','gallery.js','gallery.css','catalog.json')) {
    if (-not $seen.ContainsKey($required)) { throw "Missing public showcase file: $required" }
}
$module = ([Uri](Join-Path (Split-Path $PSScriptRoot -Parent) 'godbrain_core\skill_lab\project-assets.mjs')).AbsoluteUri
& node -e 'import(process.argv[1]).then(async m=>{const c=await m.readProjectCatalogDirectory(process.argv[2]);if(!c)throw Error("Catalog missing")})' $module $site
if ($LASTEXITCODE) { throw 'The public catalog/images failed canonical asset validation.' }
function Assert-ShowcaseOrigin {
    foreach ($arguments in @(@('remote','get-url','--all','origin'), @('remote','get-url','--push','--all','origin'))) {
        $origins = @(Invoke-ShowcaseGit $arguments)
        if ($origins.Count -ne 1 -or
            $origins[0].Trim() -notmatch '^(?:https://github\.com/|git@github\.com:)autom8edIT/autom8edIT\.github\.io(?:\.git)?$') {
            throw 'Publishing is restricted to one fetch and one push URL for the dedicated autom8edIT/autom8edIT.github.io checkout.'
        }
    }
}
Assert-ShowcaseOrigin
$top = [IO.Path]::GetFullPath((Invoke-ShowcaseGit @('rev-parse','--show-toplevel') | Select-Object -First 1))
if ($top.TrimEnd('\') -ine $PublishingCheckout.TrimEnd('\')) {
    throw 'PublishingCheckout must be the dedicated Git repository root.'
}
if ((Invoke-ShowcaseGit @('branch','--show-current') | Select-Object -First 1) -cne 'main') {
    throw 'Use the dedicated main-branch publishing checkout; no branch switching or force-push is performed.'
}
$head = (Invoke-ShowcaseGit @('rev-parse','HEAD') | Select-Object -First 1).Trim()
$saved = if (Test-Path -LiteralPath $publishReview) { Get-Content -LiteralPath $publishReview -Raw | ConvertFrom-Json } else { $null }
if ($Publish) {
    if ($ApprovedReview -cnotmatch '^[a-f0-9]{64}$' -or $ApprovedReview -cne $saved.review_sha256 -or
        $saved.batch_sha256 -cne $review.batch_sha256 -or
        $saved.checkout -cne $PublishingCheckout) { throw 'Approve the exact current publishing-review hash after inspecting its sanitized preview.' }
    if ($saved.publication_commit -and $saved.publication_commit -cne $head) {
        throw 'The current commit is no longer the approved publication commit.'
    }
    $resuming = $saved.base_commit -cne $head
    if ($resuming) {
        $tree = (Invoke-ShowcaseGit @('rev-parse','HEAD^{tree}') | Select-Object -First 1).Trim()
        $parent = (Invoke-ShowcaseGit @('rev-parse','HEAD^') | Select-Object -First 1).Trim()
        if ($tree -cne $saved.approved_tree -or $parent -cne $saved.base_commit) {
            throw 'The current commit does not match the approved publication tree/base.'
        }
        if (@(Invoke-ShowcaseGit @('diff','--cached','--name-only','--')).Count) { throw 'Unreviewed staged changes block publication retry.' }
        $actual = @(Invoke-ShowcaseGit @('diff','--name-only',$saved.base_commit,$head,'--'))
    } else {
        $actual = @(Invoke-ShowcaseGit @('diff','--cached','--name-only','--'))
    }
    $expected = @($saved.files | ForEach-Object path)
    if ((($actual | Sort-Object) -join "`n") -cne (($expected | Sort-Object) -join "`n")) { throw 'The staged file set changed after review.' }
    if (@(Invoke-ShowcaseGit @('diff','--name-only','--')).Count -or
        @(Invoke-ShowcaseGit @('ls-files','--others','--exclude-standard')).Count) { throw 'Unreviewed working-tree changes block publication.' }
    $publishBinding = "$($saved.base_commit)`n$($review.batch_sha256)`n"
    foreach ($file in $saved.files) {
        $path = Join-Path $PublishingCheckout $file.path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) { throw "Reviewed publication changed: $($file.path)" }
        $revision = if ($resuming) { "${head}:$($file.path)" } else { ":$($file.path)" }
        $indexHash = (Invoke-ShowcaseGit @('rev-parse',$revision) | Select-Object -First 1).Trim()
        if ($indexHash -cne $file.git_blob) { throw 'Staged bytes changed after review.' }
        $publishBinding += "$($file.path)`n$($file.sha256)`n$indexHash`n"
    }
    if ((Get-ShowcaseDigest $publishBinding) -cne $ApprovedReview) { throw 'Publishing review binding mismatch.' }
    if (-not $resuming) {
        $tree = (Invoke-ShowcaseGit @('write-tree') | Select-Object -First 1).Trim()
        $saved | Add-Member -NotePropertyName approved_tree -NotePropertyValue $tree -Force
        Save-ShowcaseReview $saved
        Invoke-ShowcaseGit @('commit','-m',"Refresh curated project showcase`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>") | Write-Output
        $head = (Invoke-ShowcaseGit @('rev-parse','HEAD') | Select-Object -First 1).Trim()
        $committedTree = (Invoke-ShowcaseGit @('rev-parse','HEAD^{tree}') | Select-Object -First 1).Trim()
        $parent = (Invoke-ShowcaseGit @('rev-parse','HEAD^') | Select-Object -First 1).Trim()
        if ($tree -cne $committedTree -or $parent -cne $saved.base_commit) { throw 'The commit no longer matches the reviewed tree/base; nothing pushed.' }
    }
    $commit = $head
    $saved | Add-Member -NotePropertyName publication_commit -NotePropertyValue $commit -Force
    Save-ShowcaseReview $saved
    Assert-ShowcaseOrigin
    $confirmed = $false
    if ($resuming) {
        $remote = (Invoke-ShowcaseGit @('ls-remote','origin','refs/heads/main') | Select-Object -First 1) -split '\s+'
        $confirmed = $remote[0] -ceq $commit
    }
    if (-not $confirmed) {
        Assert-ShowcaseOrigin
        Invoke-ShowcaseGit @('push','origin',"${commit}:refs/heads/main") | Write-Output
    }
    $remote = (Invoke-ShowcaseGit @('ls-remote','origin','refs/heads/main') | Select-Object -First 1) -split '\s+'
    if ($remote[0] -cne $commit) { throw 'Push returned but the remote main commit could not be confirmed.' }
    $saved.published = $true
    $saved | Add-Member -NotePropertyName published_commit -NotePropertyValue $commit -Force
    Save-ShowcaseReview $saved
    return
}
if ($saved -and $saved.approved_tree -and $saved.published -ne $true) {
    throw 'Publication is pending. Retry -Publish with the original ApprovedReview hash; do not restage or create another commit.'
}
if (@(Invoke-ShowcaseGit @('status','--porcelain')).Count) { throw 'Staging requires a clean dedicated publishing checkout.' }
$target = Join-Path $PublishingCheckout 'projects'
if ((Test-Path -LiteralPath $target) -and
    ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Cannot publish through a linked projects directory.'
}
[void][IO.Directory]::CreateDirectory($target)
foreach ($file in $review.files) {
    $destination = Join-Path $target $file.path
    $directory = Split-Path $destination -Parent
    $parent = $directory
    while ($parent -ine $PublishingCheckout) {
        if ((Test-Path -LiteralPath $parent) -and
            ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Cannot publish through a linked target directory.'
        }
        $parent = Split-Path $parent -Parent
    }
    [void][IO.Directory]::CreateDirectory($directory)
    $existing = Test-Path -LiteralPath $destination
    if ($existing -and (Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cannot replace a linked publishing target.' }
    if (-not $existing -or (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) {
        Copy-Item -LiteralPath (Join-Path $site $file.path) -Destination $destination -Force
    }
}
$index = Join-Path $PublishingCheckout 'index.md'
$text = [IO.File]::ReadAllText($index)
if ($text -notmatch '<!-- godbrain-project-showcase -->') {
    [IO.File]::WriteAllText($index, $text.TrimEnd() + "`n`n<!-- godbrain-project-showcase -->`n[Explore the project showcase](./projects/) - Command Center, Reclaim11 and Remote Dashboard.`n", [Text.UTF8Encoding]::new($false))
}
$allowed = @('index.md') + @($review.files | ForEach-Object { 'projects/' + $_.path })
Invoke-ShowcaseGit (@('add','--') + $allowed) | Out-Null
$paths = @(Invoke-ShowcaseGit @('diff','--cached','--name-only','--'))
if (-not $paths.Count) {
    Write-Output 'Unchanged showcase: no commit or push needed.'
    return
}
$files = @()
$publishBinding = "$head`n$($review.batch_sha256)`n"
foreach ($path in $paths) {
    if ($allowed -cnotcontains $path) { throw 'Unexpected staged publishing path.' }
    $hash = (Get-FileHash -LiteralPath (Join-Path $PublishingCheckout $path) -Algorithm SHA256).Hash.ToLowerInvariant()
    $blob = (Invoke-ShowcaseGit @('rev-parse',":$path") | Select-Object -First 1).Trim()
    $files += [pscustomobject]@{ path=$path; sha256=$hash; git_blob=$blob }
    $publishBinding += "$path`n$hash`n$blob`n"
}
$approval = Get-ShowcaseDigest $publishBinding
[ordered]@{
    schema_version=1; checkout=$PublishingCheckout; base_commit=$head
    batch_sha256=$review.batch_sha256; review_sha256=$approval
    files=$files; operator_review_required=$true; published=$false
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $publishReview -Encoding utf8
$preview = Join-Path $BatchDirectory 'preview'
foreach ($file in $review.files) {
    $destination = Join-Path (Join-Path $preview 'projects') $file.path
    [void][IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
    Copy-Item -LiteralPath (Join-Path $site $file.path) -Destination $destination -Force
}
$themeDirectory = Join-Path $preview 'assets\js'
[void][IO.Directory]::CreateDirectory($themeDirectory)
Copy-Item -LiteralPath (Join-Path $PublishingCheckout 'assets\js\theme.js') -Destination (Join-Path $themeDirectory 'theme.js') -Force
Invoke-ShowcaseGit @('diff','--cached','--stat','--') | Write-Output
Write-Output "STAGED ONLY. Review the sanitized preview before publishing. Approval hash: $approval"
Write-Output "Preview only the public copy: python -m http.server 8766 --bind 127.0.0.1 --directory `"$preview`""
Write-Output 'Then open http://127.0.0.1:8766/projects/ . No Git metadata, encoder logs or local APIs are served.'
