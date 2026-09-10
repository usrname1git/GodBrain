# Pin mongo-c-driver 1.x into C:\Tools (out of git). Not npm. Not Heal.
# Source/build live under C:\Tools\src so MSBuild is not in %TEMP% (MSB8029).
[CmdletBinding()]
param(
    [string]$Version = "1.30.9",
    [string]$Prefix = "C:\Tools\mongo-c-driver"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$config = Join-Path $Prefix "lib\cmake\mongoc-1.0\mongoc-1.0-config.cmake"
if (Test-Path -LiteralPath $config) {
    Write-Host "mongo-c-driver already at $Prefix"
    return
}

New-Item -ItemType Directory -Path $Prefix -Force | Out-Null

# Reuse a previous RelWithDebInfo tree if cmake-build is still around.
$legacyBuilds = @(
    (Join-Path $env:TEMP ("mongo-c-driver-" + $Version + "\cmake-build")),
    (Join-Path "C:\Tools\src" ("mongo-c-driver-" + $Version + "\cmake-build"))
)
foreach ($legacy in $legacyBuilds) {
    if (Test-Path -LiteralPath $legacy) {
        Write-Host "Installing existing build $legacy -> $Prefix"
        cmake --install $legacy --config RelWithDebInfo --prefix "$Prefix"
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $config)) {
            Write-Host "mongo-c-driver $Version installed at $Prefix"
            return
        }
    }
}

$srcRoot = Join-Path "C:\Tools\src" ("mongo-c-driver-" + $Version)
$tarball = Join-Path "C:\Tools\src" ("mongo-c-driver-" + $Version + ".tar.gz")
$url = "https://github.com/mongodb/mongo-c-driver/releases/download/$Version/mongo-c-driver-$Version.tar.gz"
New-Item -ItemType Directory -Path (Split-Path -Parent $tarball) -Force | Out-Null

if (-not (Test-Path -LiteralPath $tarball)) {
    $tempTar = Join-Path $env:TEMP ("mongo-c-driver-" + $Version + ".tar.gz")
    if (Test-Path -LiteralPath $tempTar) {
        Copy-Item -LiteralPath $tempTar -Destination $tarball -Force
    } else {
        Write-Host "Downloading $url"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing
    }
}

if (Test-Path -LiteralPath $srcRoot) { Remove-Item -LiteralPath $srcRoot -Recurse -Force }
New-Item -ItemType Directory -Path $srcRoot | Out-Null
tar -xf $tarball -C $srcRoot
$inner = Get-ChildItem -LiteralPath $srcRoot -Directory | Select-Object -First 1
if (-not $inner) { throw "Fetch-MongoCDriver: tarball had no directory" }

$build = Join-Path $srcRoot "cmake-build"
New-Item -ItemType Directory -Path $build | Out-Null
$src = $inner.FullName
cmake -S $src -B $build `
    -DENABLE_AUTOMATIC_INIT_AND_CLEANUP=OFF `
    -DENABLE_TESTS=OFF `
    -DENABLE_EXAMPLES=OFF `
    -DENABLE_HTML_DOCS=OFF `
    -DENABLE_MAN_PAGES=OFF `
    -DENABLE_UNINSTALL=OFF `
    -DENABLE_SSL=WINDOWS `
    "-DCMAKE_INSTALL_PREFIX=$Prefix"
if ($LASTEXITCODE -ne 0) { throw "Fetch-MongoCDriver: cmake configure failed" }
cmake --build $build --config RelWithDebInfo --target install
if ($LASTEXITCODE -ne 0) { throw "Fetch-MongoCDriver: cmake build/install failed" }
if (-not (Test-Path -LiteralPath $config)) {
    throw "Fetch-MongoCDriver: install missing $config"
}
Write-Host "mongo-c-driver $Version installed at $Prefix"
