[CmdletBinding()]
param([switch]$Live)

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
        ($sources -join ' ') + ' /link advapi32.lib pdh.lib dxgi.lib'
    & (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') /c $command
    if ($LASTEXITCODE -ne 0) { throw 'Phone Desk C++ test build failed.' }
    & (Join-Path $build 'phone-desk-test.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Phone Desk C++ tests failed.' }

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
        $ownerResult = Invoke-WebRequest "$url/" -Headers @{'Tailscale-User-Login'=$owner} -TimeoutSec 12
        if ([int]$ownerResult.StatusCode -ne 200) { throw 'Device-owner proxy identity rejected.' }
        foreach ($case in @(
            @{ Path='/api/phone/status'; Headers=@{}; Method='GET'; Expected=403 },
            @{ Path='/api/phone/status'; Headers=@{Authorization='Bearer fixture-invalid'}; Method='GET'; Expected=403 },
            @{ Path='/api/phone/status'; Headers=@{'Tailscale-User-Login'='other@example.invalid'}; Method='GET'; Expected=403 },
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
