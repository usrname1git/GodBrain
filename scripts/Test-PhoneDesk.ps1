[CmdletBinding()]
param([switch]$Live, [switch]$ServeTransport, [string]$ImageHealthFixture = '')

$ErrorActionPreference = 'Stop'
function Get-ServiceIdentity {
    @(Get-CimInstance Win32_Service -Filter "Name='RustDesk' OR Name='Tailscale' OR Name='sshd' OR Name='MongoDB'" |
        ForEach-Object { "$($_.Name):$($_.State):$($_.ProcessId):$($_.StartMode)" }) +
    @(Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 8888,8871,8000,8084,27017,2222 |
        ForEach-Object {
            $process = Get-Process -Id $_.OwningProcess
            "$($_.LocalAddress):$($_.LocalPort):$($process.Id):$($process.StartTime.ToUniversalTime().Ticks)"
        })
}
if ($Live -and -not $env:GODBRAIN_API_TOKEN) { throw 'Live checks require GODBRAIN_API_TOKEN.' }
$repo = Split-Path $PSScriptRoot -Parent
$source = Join-Path $repo 'godbrain_core\cpp_kernel'
$build = Join-Path ([IO.Path]::GetTempPath()) ('GodBrain-PhoneDesk-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $build
try {
    $prefix = ''
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio x64 C++ tools are required.' }
        $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $vs) { throw 'Visual Studio x64 C++ tools were not found.' }
        $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
        $prefix = 'call "' + $vcvars + '" >nul && '
    }
    $sources = @('phone_desk_test.cpp', 'phone_desk.cpp', 'telemetry.cpp') |
        ForEach-Object { '"' + (Join-Path $source $_) + '"' }
    $command = $prefix + 'cd /d "' + $build + '" && cl /nologo /std:c++17 /EHsc /W4 /Fe:phone-desk-test.exe ' +
        ($sources -join ' ') + ' /link advapi32.lib pdh.lib dxgi.lib iphlpapi.lib'
    & (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') /c $command
    if ($LASTEXITCODE -ne 0) { throw 'Phone Desk C++ test build failed.' }
    & (Join-Path $build 'phone-desk-test.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Phone Desk C++ tests failed.' }
    if ($ImageHealthFixture) {
        & (Join-Path $build 'phone-desk-test.exe') --image-health-fixture $ImageHealthFixture
        if ($LASTEXITCODE -ne 0) { throw 'Actual image endpoint contract test failed.' }
    }
    if ($ServeTransport) {
        $transportIdentities = Get-ServiceIdentity
        $exe = 'C:\Program Files\Tailscale\tailscale.exe'
        $tail = & $exe status --json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Tailscale owner query failed.' }
        $owner = $tail.User.PSObject.Properties[$tail.Self.UserID.ToString()].Value.LoginName
        if (-not $owner) { throw 'Tailscale device owner is missing.' }
        $beforeConfig = & $exe serve status --json
        if ($LASTEXITCODE -ne 0) { throw 'Serve status query failed.' }
        $config = ($beforeConfig -join "`n") | ConvertFrom-Json
        if (-not $config.TCP.'443'.HTTPS -or -not $config.Web) { throw 'Existing private HTTPS Serve is required.' }
        $hostName = @($config.Web.PSObject.Properties.Name | Where-Object { $_.EndsWith(':443') })[0] -replace ':443$', ''
        if (-not $hostName) { throw 'Private HTTPS host is missing.' }
        $portReservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $portReservation.Start()
        $port = $portReservation.LocalEndpoint.Port
        $portReservation.Stop()
        $route = '/phone-test-' + [guid]::NewGuid().ToString('N')
        $child = Start-Process -FilePath (Join-Path $build 'phone-desk-test.exe') -ArgumentList @(
            '--proxy-fixture', $port, ('"' + $owner + '"')
        ) -WindowStyle Hidden -RedirectStandardError (Join-Path $build 'proxy-error.txt') -PassThru
        $installed = $false
        try {
            $url = "http://127.0.0.1:$port"
            $ready = $false
            for ($i = 0; $i -lt 40; $i++) {
                if ($child.HasExited) { throw 'Proxy fixture exited before readiness.' }
                try {
                    $result = Invoke-WebRequest "$url/" -Headers @{Authorization='Bearer fixture'} -TimeoutSec 1
                    $ready = [int]$result.StatusCode -eq 200
                } catch [Net.Http.HttpRequestException] { }
                if ($ready) { break }
                Start-Sleep -Milliseconds 100
            }
            if (-not $ready) { throw 'Proxy fixture was not ready.' }
            $spoof = Invoke-WebRequest "$url/" -Headers @{'Tailscale-User-Login'=$owner} -SkipHttpErrorCheck -TimeoutSec 5
            if ([int]$spoof.StatusCode -ne 403 -or ($spoof.Content | ConvertFrom-Json).authenticated_proxy) {
                throw 'Direct client impersonated the Serve transport.'
            }
            $installed = $true
            & $exe serve --bg --https=443 --set-path=$route --yes "http://127.0.0.1:$port" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Scoped Serve fixture registration failed.' }
            $proxied = Invoke-WebRequest ("https://" + $hostName + $route + '/') -TimeoutSec 12
            if ([int]$proxied.StatusCode -ne 200 -or -not ($proxied.Content | ConvertFrom-Json).authenticated_proxy) {
                throw 'Actual Tailscale-owned proxy transport was not authenticated.'
            }
            Write-Host 'PASS: direct owner-header spoof denied; actual private HTTPS Tailscale transport authenticated'
        } finally {
            if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force }
            $child.Dispose()
            if ($installed) {
                & $exe serve --bg --https=443 --set-path=$route off | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Scoped Serve fixture cleanup failed.' }
                $afterConfig = & $exe serve status --json
                if ($LASTEXITCODE -ne 0 -or ($beforeConfig -join "`n") -cne ($afterConfig -join "`n")) {
                    throw 'Serve configuration was not preserved after fixture cleanup.'
                }
            }
            if (@(Compare-Object $transportIdentities (Get-ServiceIdentity)).Count) {
                throw 'Service or model identities changed during proxy transport checks.'
            }
        }
    }

    $previous = $env:GODBRAIN_PHONE_LIVE_TEST
    if ($Live) { $before = Get-ServiceIdentity }
    try {
        $env:GODBRAIN_PHONE_LIVE_TEST = if ($Live) { '1' } else { '0' }
        & node --test (Join-Path $repo 'godbrain_core\frontend\phone.test.mjs')
        if ($LASTEXITCODE -ne 0) { throw 'Phone Desk browser checks failed.' }
    } finally { $env:GODBRAIN_PHONE_LIVE_TEST = $previous }

    if ($Live) {
        $headers = @{ Authorization = 'Bearer ' + $env:GODBRAIN_API_TOKEN }
        $url = 'http://127.0.0.1:8085'
        $tail = & 'C:\Program Files\Tailscale\tailscale.exe' status --json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Tailscale owner query failed.' }
        $owner = $tail.User.PSObject.Properties[$tail.Self.UserID.ToString()].Value.LoginName
        if (-not $owner) { throw 'Tailscale device owner is missing.' }
        foreach ($case in @(
            @{ Path='/api/phone/status'; Headers=@{}; Method='GET'; Expected=403 },
            @{ Path='/api/phone/status'; Headers=@{Authorization='Bearer fixture-invalid'}; Method='GET'; Expected=403 },
            @{ Path='/api/phone/status'; Headers=@{'Tailscale-User-Login'='other@example.invalid'}; Method='GET'; Expected=403 },
            @{ Path='/api/phone/status'; Headers=@{'Tailscale-User-Login'=$owner}; Method='GET'; Expected=403 },
            @{ Path='/api/chat'; Headers=$headers; Method='POST'; Expected=404 },
            @{ Path='/api/status'; Headers=$headers; Method='GET'; Expected=404 },
            @{ Path='/api/phone/status'; Headers=$headers; Method='POST'; Expected=404 },
            @{ Path='/api/phone/status?command_type=fixture'; Headers=$headers; Method='GET'; Expected=403 }
        )) {
            $result = Invoke-WebRequest ($url + $case.Path) -Headers $case.Headers -Method $case.Method -TimeoutSec 12 -SkipHttpErrorCheck
            if ([int]$result.StatusCode -ne $case.Expected) { throw "Unexpected status at $($case.Path)." }
        }
        $client = [Net.Http.HttpClient]::new()
        try {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$url/api/phone/status")
            $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $env:GODBRAIN_API_TOKEN)
            $request.Content = [Net.Http.StringContent]::new('{"command_type":"fixture"}')
            $result = $client.Send($request)
            try {
                if ([int]$result.StatusCode -ne 403) { throw 'Read-only endpoint accepted a GET body.' }
            } finally { $result.Dispose(); $request.Dispose() }
        } finally { $client.Dispose() }
        for ($i = 0; $i -lt 3; $i++) {
            $data = Invoke-RestMethod "$url/api/phone/status" -Headers $headers -TimeoutSec 12
            if ($data.schema_version -ne 1 -or $data.read_only -ne $true -or $data.services.Count -ne 3) {
                throw 'Invalid live Phone Desk response.'
            }
            Start-Sleep -Seconds 3
        }
        if (@(Compare-Object $before (Get-ServiceIdentity)).Count) { throw 'Service or model identities changed during read-only checks.' }
        if (@(Get-NetTCPConnection -State Listen -LocalPort 8085 | Where-Object LocalAddress -ne '127.0.0.1').Count) {
            throw 'Phone Desk is not exclusively loopback-bound.'
        }
        Write-Host 'PASS: Live loopback authentication, no control routes, read-only refreshes and unchanged service/model identities'
    }
} finally {
    Remove-Item -LiteralPath $build -Recurse -Force
}
