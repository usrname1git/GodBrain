[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$BuilderWorkDir = '',
    [string]$CaptureDirectory = '',
    [string]$BatchDirectory = '',
    [ValidateSet('CMDSTATUS','CMDMODELS','RECLAIM11_DOOR','RECLAIM11_PRO','RECLAIM11_BEGINNER','PHONEDASHBOARD','WORKSPACEMAP','WORKSPACEENV','WORKSPACEEVAL','MONITORCONTROLS','AIRPLAYCONTROLS','IOSWORKFLOW','CLIPSHAREFLOW')]
    [string[]]$Images = @('CMDSTATUS','CMDMODELS','RECLAIM11_DOOR','RECLAIM11_PRO','RECLAIM11_BEGINNER','PHONEDASHBOARD','WORKSPACEMAP','WORKSPACEENV','WORKSPACEEVAL','MONITORCONTROLS','AIRPLAYCONTROLS','IOSWORKFLOW','CLIPSHAREFLOW'),
    [string]$Ffmpeg = 'C:\Tools\ffmpeg\ffmpeg.exe',
    [switch]$SkipCapture
)
$ErrorActionPreference = 'Stop'
if (-not $BuilderWorkDir) { $BuilderWorkDir = Join-Path $RepoRoot 'godbrain_core\skill_lab\work\gym' }
$BuilderWorkDir = [IO.Path]::GetFullPath($BuilderWorkDir)
if (-not $CaptureDirectory) { $CaptureDirectory = Join-Path $BuilderWorkDir 'showcase-captures' }
if (-not $BatchDirectory) {
    $BatchDirectory = Join-Path $BuilderWorkDir ('showcase-batches\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
}
$exe = Join-Path $RepoRoot 'build\showcase\showcase.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Run scripts\Build-Showcase.ps1 first.' }
if (-not (Test-Path -LiteralPath $Ffmpeg -PathType Leaf)) { throw 'The existing CPU ffmpeg executable is required.' }
$protected = @{}
$logs = Join-Path $RepoRoot 'logs'
if (Test-Path -LiteralPath $logs) {
    foreach ($file in Get-ChildItem -LiteralPath $logs -File) {
        if ($file.Name -match 'pause|hold|thinking|mtp|cuda|desk-model-settings|afk-gym') {
            $protected[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    }
}
try {
    if (-not $SkipCapture) {
        $previousCaptures = $CaptureDirectory
        $CaptureDirectory = Join-Path $CaptureDirectory ('capture-' + [guid]::NewGuid().ToString('N'))
    }
    [void][IO.Directory]::CreateDirectory($CaptureDirectory)
    if (-not $SkipCapture) {
        $descriptor = Get-Content -LiteralPath (Join-Path $RepoRoot 'godbrain_core\showcase\projects.json') -Raw | ConvertFrom-Json
        foreach ($id in $descriptor.projects.images.id | Where-Object { $_ -notin $Images }) {
            foreach ($name in @("$id.png", "$id.png.receipt.json")) {
                $source = Join-Path $previousCaptures $name
                if (Test-Path -LiteralPath $source -PathType Leaf) {
                    Copy-Item -LiteralPath $source -Destination (Join-Path $CaptureDirectory $name)
                }
            }
        }
        foreach ($id in $Images) {
            $output = Join-Path $CaptureDirectory ($id + '.png')
            switch ($id) {
                'CMDSTATUS' { & 'C:\pwsh\pwsh.exe' -NoProfile -Sta -File (Join-Path $RepoRoot 'scripts\Show-DeskMenu.ps1') -CaptureView Status -CapturePng $output }
                'CMDMODELS' { & 'C:\pwsh\pwsh.exe' -NoProfile -Sta -File (Join-Path $RepoRoot 'scripts\Show-DeskMenu.ps1') -CaptureView Model -CapturePng $output }
                'PHONEDASHBOARD' { & node (Join-Path $RepoRoot 'godbrain_core\frontend\capture-phone.mjs') --output $output }
                'MONITORCONTROLS' { & 'C:\pwsh\pwsh.exe' -NoProfile -Sta -File (Join-Path $RepoRoot 'scripts\Show-DeskMenu.ps1') -CaptureView Monitor -CapturePng $output }
                'AIRPLAYCONTROLS' { & 'C:\pwsh\pwsh.exe' -NoProfile -Sta -File (Join-Path $RepoRoot 'scripts\Show-DeskMenu.ps1') -CaptureView AirPlay -CapturePng $output }
                { $_ -in @('WORKSPACEMAP','WORKSPACEENV','WORKSPACEEVAL','IOSWORKFLOW','CLIPSHAREFLOW') } {
                    & node (Join-Path $RepoRoot 'godbrain_core\frontend\capture-workspace.mjs') --image $id --output $output
                }
                default {
                    $door = @{ RECLAIM11_DOOR='door'; RECLAIM11_PRO='expert'; RECLAIM11_BEGINNER='noob' }[$id]
                    & 'C:\pwsh\pwsh.exe' -NoProfile -Sta -File (Join-Path $RepoRoot 'scripts\Capture-Reclaim11Gui.ps1') -Door $door -OutPng $output -PublicPreview
                }
            }
            if ($LASTEXITCODE) { throw "Named capture failed: $id. The last installed catalog is unchanged." }
        }
    }
    & $exe $CaptureDirectory (Join-Path $RepoRoot 'godbrain_core\showcase') $BatchDirectory $Ffmpeg (Join-Path $RepoRoot 'godbrain_core\showcase\projects.json')
    if ($LASTEXITCODE) { throw 'Showcase conversion failed. The last installed catalog is unchanged.' }
    $module = ([Uri](Join-Path $RepoRoot 'godbrain_core\skill_lab\project-assets.mjs')).AbsoluteUri
    $site = Join-Path $BatchDirectory 'site'
    & node -e 'import(process.argv[1]).then(async m=>{const c=await m.readProjectCatalogDirectory(process.argv[2]);if(!c)throw Error("Catalog missing");console.log(JSON.stringify({validated:true,projects:c.projects.length,images:c.assets.size}))})' $module $site
    if ($LASTEXITCODE) { throw 'Bounded catalog/image validation failed. Nothing installed or published.' }
    $next = Join-Path $BuilderWorkDir ('showcase.next-' + [guid]::NewGuid().ToString('N'))
    $current = Join-Path $BuilderWorkDir 'showcase'
    $previous = Join-Path $BuilderWorkDir ('showcase.previous-' + [guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $site -Destination $next -Recurse
    & node -e 'import(process.argv[1]).then(async m=>{if(!await m.readProjectCatalogDirectory(process.argv[2]))throw Error("Copied catalog missing")})' $module $next
    if ($LASTEXITCODE) { throw 'Copied builder assets failed validation. The current catalog is unchanged.' }
    $moved = $false
    try {
        if (Test-Path -LiteralPath $current) {
            Move-Item -LiteralPath $current -Destination $previous
            $moved = $true
        }
        Move-Item -LiteralPath $next -Destination $current
    } catch {
        if ($moved -and -not (Test-Path -LiteralPath $current)) { Move-Item -LiteralPath $previous -Destination $current }
        throw
    }
    if ($moved) { Remove-Item -LiteralPath $previous -Recurse -Force }
    [pscustomobject]@{
        batch = [IO.Path]::GetFullPath($BatchDirectory)
        capture_directory = [IO.Path]::GetFullPath($CaptureDirectory)
        review = Join-Path ([IO.Path]::GetFullPath($BatchDirectory)) 'review.json'
        builder_catalog = $current
        publication = 'Not published. Review the sanitized batch, then approve its exact publishing hash.'
    }
} finally {
    foreach ($entry in $protected.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Key) -or
            (Get-FileHash -LiteralPath $entry.Key -Algorithm SHA256).Hash -ne $entry.Value) {
            throw "Protected host/model state changed during refresh: $([IO.Path]::GetFileName($entry.Key))"
        }
    }
}
