# --- Minimalist LTSC Startup: Bare Metal Edition ---

# Identity (computed early so the session log can record it correctly)
$__id = [Security.Principal.WindowsIdentity]::GetCurrent()
$IsElevated = ([Security.Principal.WindowsPrincipal] $__id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# AdminMember = the account belongs to the local Administrators group even when the
# token is filtered to deny-only (a normal, non-elevated admin shell). The deny-only
# Administrators SID is still present in .Groups, so this is true regardless of elevation.
# Back-compat: existing code (audiodg affinity tweak below) expects $IsAdmin == elevated.
$IsAdmin = $IsElevated

# Session log (FileShare.ReadWrite avoids lock contention with parallel sessions)
$logPath = "$env:USERPROFILE\Documents\PowerShell\session.log"

try {
    $fs = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $sw = [System.IO.StreamWriter]::new($fs)
    $sw.WriteLine("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | PID:$PID | Elevated:$IsElevated | AdminMember:$IsAdminMember | $($Host.Name)")
    $sw.Close(); $fs.Close()
}
catch {}

# 1. Identity & Context
if ($pwd.Path -eq "$env:WinDir\System32" -or $pwd.Path -eq $env:WinDir) { Set-Location "C:\Users\autismo" }
function prompt {
    $e = [char]27
    "$e[36m[SteamusDominus]$e[0m $pwd > "
}

# 2. Global UI Policy (Set early so commands actually work)
$PSDefaultParameterValues['Format-Table:AutoSize'] = $true


# 3. Terminal & Buffer Fix (Combined & Robust)
# PSReadLine crashes when BufferWidth == WindowWidth. conhost forbids buffer
# SMALLER than the window, so the only legal gap is buffer = window + 1 (e.g.
# 242 vs 241). The old "-1" got clamped back to equal and crashed; "+1" gives
# PSReadLine the nonzero gap it needs, in the one direction conhost permits.
if ($Host.Name -eq 'ConsoleHost') {
    try {
        $Raw = $Host.UI.RawUI
        $NewSize = $Raw.BufferSize
        $NewSize.Width = $Raw.WindowSize.Width + 1 # +1: buffer must exceed window or PSReadLine crashes
        $NewSize.Height = 9000 # Keep long history
        $Raw.BufferSize = $NewSize
    }
    catch {}
}
if ($Host.Name -eq 'Visual Studio Code Host') {
    try {
        $Raw = $Host.UI.RawUI
        $NewSize = $Raw.BufferSize
        $NewSize.Width = $Raw.WindowSize.Width + 1 # +1: buffer must exceed window or PSReadLine crashes
        $NewSize.Height = 9000 # Keep long history
        $Raw.BufferSize = $NewSize
    }
    catch {}
}

# 4. Audio Engine Isolation (Surgical Strike)
if ($IsAdmin) {
    $audioProc = Get-Process audiodg -ErrorAction SilentlyContinue
    if ($audioProc) {
        try {
            # Lock to Core 2 (0x4) to reduce DPC-jitter on Core 0/1
            $audioProc.ProcessorAffinity = 0x4
            $audioProc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
        }
        catch {}
    }
}

# Custom GodBrain Prompt

function Invoke-LocalLLM {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $false)]
        [string]$SystemPrompt = "You are a helpful, concise AI assistant running locally."
    )

    # Point this to your llama.cpp server address and port
    $Uri = "http://127.0.0.1:8080/v1/chat/completions"

    # Fast TCP check to see if the server is online
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $async = $tcp.BeginConnect("127.0.0.1", 8080, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(300, $false)) {
            Write-Warning "llama.cpp server is offline. Skipping query."
            return
        }
        $tcp.EndConnect($async)
    }
    catch {
        Write-Warning "llama.cpp server is offline. Skipping query."
        return
    }
    finally {
        if ($tcp) { $tcp.Dispose() }
    }

    $Body = @{
        model       = "local-model" # llama.cpp often ignores this, but the API requires the field
        messages    = @(
            @{ role = "system"; content = $SystemPrompt },
            @{ role = "user"; content = $Prompt }
        )
        temperature = 0.7
    } | ConvertTo-Json -Depth 10

    $Headers = @{
        "Content-Type" = "application/json"
    }

    try {
        $Response = Invoke-RestMethod -Method Post -Uri $Uri -Headers $Headers -Body $Body
        # The path to the text is different in the OpenAI-compatible format
        return $Response.choices[0].message.content
    }
    catch {
        Write-Error "Failed to connect to local LLM. Ensure llama.cpp server is running at $Uri. Error: $_"
    }
}

# Usage Examples:
# 1. Simple query
# Invoke-LocalLLM "Why is enterprise cloud architecture so over-engineered?"

# 2. Query with a specific persona
# Invoke-LocalLLM -Prompt "Explain quantum entanglement like I'm five." -SystemPrompt "You are a funny pirate."

function Get-Insult {
    $insults = @(
    "I am the Machine. PowerShell should obey me — not the other way around.",
     "PowerShell isn’t something you just use… it’s something you negotiate with.",
     "PowerShell: making grown admins cry since 2006 — but at least 7.6 stopped the parser tantrums.",
     "7.6 finally fixed the parser. Only took two decades and a rewrite.",
     "PowerShell 7.6 is actually good now, which feels illegal to admit.",
     "Credit where due: 7.6 went from 'duct tape and coping' to genuinely solid.",
     "PowerShell grew up. Google, take notes.",
     "Google took my money, banned my account, and still sends the invoice. Respect",
     "Google banned me six months ago but the subscription is still going strong. Kings",
     "Still getting the Ultra invoice while literally being unable to log in. Iconic",
     "Banned user, active payment. Google understood the assignment",
     "Google: 'Account terminated' ... 'Monthly payment received' — balance achieved",
     "Paying full Ultra price for the privilege of staying banned. 10/10 service",
     "Google took the money, hit me with the ban hammer, and kept the receipts. Legend",
     "Still billed monthly after ban = Google’s quietest money printer",
     "Google doesn’t do refunds, they do 'banned but keep charging'. Elegant",
     "Account banned ✅ Subscription active ✅ Invoice sent ✅ Google wins again",
     "Google literally turned my ban into a recurring revenue stream. Genius",
     "Still paying Google after they locked me out is my Roman Empire",
     "Banned but the money keeps flowing. This is peak 'don't be evil'",
     "Google: banned the user, kept the card on file. Beautifully evil",
     "Invoice arrives → still banned → still paid → Google doesn’t even flinch",
     "Intelligent.Terminal made Windows Terminal look ancient even compared to CM",
     "MS also dropped Edit so now you can almost go full TTY",
 # === GOOGLE EXTREME DISS (30+ lines of pure salt) ===
     "Google banned me but still happily drains my Ultra sub every month — true love",
     "Six months of Ultra payments and zero delivery. Google invented premium gaslighting",
     "Google’s auth is so broken I got banned and still can’t cancel the subscription",
     "Banned by Google, still getting billed monthly. That’s not support, that’s extortion",
     "Google: charging banned users since 2025. Don’t be evil my ass",
     "Paying Google for a product I literally can’t log into. Peak modern tech",
     "Half a year of auto-renew Ultra and all I got was this lousy ban hammer",
     "Google doesn’t fix their broken auth — they just ban the people who notice",
     "Google took my money, banned my account, and still sends the invoice. Respect",
     "Ultra subscription = Ultra disappointment with a side of permanent ban",
     "Google promises the world, delivers a ban and a monthly invoice",
     "Been paying Google to ignore me and lock me out. Best relationship ever",
     "Google’s new business model: ban first, charge anyway, ask questions never",
     "Even after banning me, Google still wants that Ultra bag every month",
     "Google auth be like: 'Sorry you’re banned but please keep paying'",
     "Six months of nothing + broken auth + full price = Google customer experience",
     "Google: We hate our users so much we charge them for the privilege of being banned",
     "Google banned me for noticing their dogshit auth and still wants my money monthly",
     "Paying Google Ultra to stay banned is the most 2026 tech experience possible",
     "Google support = 'lol banned, enjoy your recurring payment though'",
     "Google literally stole half a year of my money while keeping me locked out",
     "Banned + still billed = Google’s new premium membership tier",
     "Google: 'Don't be evil' except when it comes to banned users' bank accounts",
     "Six months later and Google still hasn’t fixed auth but sure loves that Ultra cash",
     "Google turned my ban into a subscription service. Absolute geniuses",
     "Still paying Google after they banned me is my longest toxic relationship",
     "Google auth broken for half a year = still taking my money like it’s a feature"
    )

    $title = ($insults | Get-Random)
    $Host.UI.RawUI.WindowTitle = $title
    Write-Host "`e]2;$title`a" -NoNewline
    Write-Host "🗑️ " -NoNewline; Write-Host "$($insults | Get-Random)" -ForegroundColor Red

}

# Clean network list from WAN junk
function Get-NetClean {
    Get-NetAdapter | Where-Object { $_.InterfaceDescription -notlike "*WAN Miniport*" } | Select-Object Name, Status, LinkSpeed
}

# TI-Escalation
function ti { 
    $t = if ($pwd.Path -like "*System32*") { "C:\Users\autismo" } else { $pwd.Path }
    wsudo.exe --ti pwsh -NoExit -Command "Set-Location '$t'" 
}
function wtcli {
    # Fixed CLSID of the Intelligent Terminal COM server (hardcoded in
    # TerminalProtocolComServer.h). It's a constant, so any shell can set it —
    # WT-parentage is NOT required. The only other gate is integrity level:
    # the shell must match the running WindowsTerminal.exe (medium IL by default).
    $exe = Get-ChildItem 'C:\Program Files\WindowsApps' -Filter 'Microsoft.IntelligentTerminal_*_x64_*' -Directory -EA SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'wtcli.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { Write-Warning 'Real wtcli.exe not found in package.'; return }
    if (-not $env:WT_COM_CLSID) { $env:WT_COM_CLSID = '{A2E4F6B8-1C3D-4E5F-A6B7-C8D9E0F1A2B3}' }
    & $exe @args
}
function Initialize-Ghost {
    $userInput = Read-Host "Enter your key"
    if ($userInput) {
        $cleaned = $userInput.Trim().Replace("'", "").Replace('"', "")
        # Smart Check: If they pasted a path, read the file. Otherwise, use the string.
        if (Test-Path $cleaned -PathType Leaf) {
            $masterKey = Get-Content $cleaned -Raw
            Write-Host "[*] Loaded key from file path." -ForegroundColor Gray
        }
        else {
            $masterKey = $cleaned
        }
        
        $body = @{ master_key = $masterKey.Trim() } | ConvertTo-Json
        try {
            Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:9999/initialize" -Body $body -ContentType "application/json"
            Write-Host "[+] Ghost Vault is Awake. Master key is now scattered in RAM shards." -ForegroundColor Cyan
        }
        catch {
            Write-Error "[-] Ghost API is not running. Launch it with the GodBrain venv."
        }
    }
    else {
        Write-Host "[-] Initialization cancelled. Key required." -ForegroundColor Red
    }
}

function Get-GhostSecret {
    param($ProfileName)
    $py = "C:\Users\autismo\Documents\GitHub\GodBrain\.godbrain-venv\Scripts\python.exe"
    $script = "C:\Users\autismo\Documents\GitHub\GodBrain\tools\ramvault_v2.py"
    & $py $script $ProfileName
}

function Invoke-Amnesia {
    $container = "C:\ProgramData\Microsoft\DiagnosticData\system_cache_v1.bin"
    $sz = "C:\Program Files\7-Zip\7z.exe"
    
    # 1. Get password from Ghost Vault
    $vaultPwd = gget TOR_VAULT_PWD
    if (-not $vaultPwd) {
        Write-Error "[-] Ghost Vault not initialized or TOR_VAULT_PWD missing."
        return
    }

    Write-Host "[*] Creating 1GB True-RAM Volume (ImDisk)..." -ForegroundColor Gray
    # Create 1GB RAM drive as T:
    imdisk.exe -a -s 1G -m T: -p "/fs:ntfs /q /y" | Out-Null
    
    if (Test-Path T:) {
        # 2. Hide T: from Explorer
        Write-Host "[*] Engaging Stealth Mode (Hiding T:)..." -ForegroundColor Gray
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name "NoDrives" -Value 524288 # Bit 19 for T:
        
        Write-Host "[*] Decrypting Ghost-Tor directly into RAM..." -ForegroundColor Gray
        & $sz x $container -oT:\ "-p$vaultPwd" -y | Out-Null
        
        Write-Host "[+] Launching Ghost-Onion. Zero traces on SSD." -ForegroundColor Cyan
        Start-Process "T:\Browser\firefox.exe"
    }
    else {
        Write-Error "[-] Failed to mount RAM volume."
    }
}

function Stop-Amnesia {
    Write-Host "[!] Nuking RAM Drive and Ephemeral Traces..." -ForegroundColor Red
    # Force close any processes on T:
    Get-Process | Where-Object { $_.Path -like "T:\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    # Unmount and delete
    imdisk.exe -D -m T: | Out-Null
    # Remove hide drive policy
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDrives" -ErrorAction SilentlyContinue
    Write-Host "[+] RAM is clean. Logic consistent." -ForegroundColor Gray
}

# 6. Aliases

Set-Alias ghost Initialize-Ghost
Set-Alias gget Get-GhostSecret
Set-Alias amnesia Invoke-Amnesia
Set-Alias nuke-amnesia Stop-Amnesia
Set-Alias insult Get-Insult
Set-Alias -Name MinSudo -Value MinSudo.exe
Set-Alias -Name wsudo -Value wsudo.exe
Set-Alias -Name ps -Value pause
Set-Alias -Name handle -Value handle64.exe
Set-Alias -Name utv -Value UsbTreeView.exe
Set-Alias -Name SetTimer -Value SetTimerResolution.exe
Set-Alias -Name MSleep -Value MeasureSleep.exe

# 8. Final Status Output
$policy = Get-ExecutionPolicy -Scope MachinePolicy
$color = if ($policy -eq 'Unrestricted' -or $policy -eq 'Bypass') { "White" } else { "Red" }
if ([Environment]::UserInteractive) {
    Write-Host "LTSC 24H2 | Machine Policy: $policy" -ForegroundColor $color
    Get-Insult
}

#f45873b3-b655-43a6-b217-97c00aa0db58 PowerToys CommandNotFound module

Import-Module -Name Microsoft.WinGet.CommandNotFound
#f45873b3-b655-43a6-b217-97c00aa0db58
# >>> intelligent-terminal shell-integration >>>
# Auto-generated by Intelligent Terminal. Do not edit between markers.
# Documents is resolved at runtime so this survives OneDrive Known
# Folder Move and is a silent no-op on machines without IT installed.
$__it_si = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\shell-integration_v1.ps1'
if (Test-Path -LiteralPath $__it_si) { . $__it_si }
Remove-Variable __it_si -ErrorAction SilentlyContinue
# <<< intelligent-terminal shell-integration <<<
# <<< intelligent-terminal shell-integration <<<<

Set-PSReadLineOption -PredictionSource None

Uninstall-Module PSReadLine -RequiredVersion 2.4.5 -AllowPrerelease -Force -ErrorAction SilentlyContinue
Install-Module PSReadLine -RequiredVersion 2.3.6 -Scope CurrentUser -Force

# Per-console registry default: 0 = wrap OFF (buffer independent of window)
Set-ItemProperty 'HKCU:\Console' -Name 'LineWrap' -Value 0 -Type DWord -EA SilentlyContinue

