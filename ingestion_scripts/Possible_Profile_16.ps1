# --- Minimalist LTSC Startup: Bare Metal Edition ---

# Session log (FileShare.ReadWrite avoids lock contention with parallel sessions)
$logPath = "$env:USERPROFILE\Documents\PowerShell\session.log"

try {
    $fs = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $sw = [System.IO.StreamWriter]::new($fs)
    $sw.WriteLine("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | PID:$PID | Admin:$IsAdmin | $($Host.Name)")
    $sw.Close(); $fs.Close()
} catch {}

# 1. Identity & Context
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($pwd.Path -eq "$env:WinDir\System32" -or $pwd.Path -eq $env:WinDir) { Set-Location "C:\Users\autismo" }

function prompt {
    Write-Host "[SteamusDominus]" -ForegroundColor White -NoNewline
    " $pwd > "
}

# 2. Global UI Policy (Set early so commands actually work)
$PSDefaultParameterValues['Format-Table:AutoSize'] = $true


# 3. Terminal & Buffer Fix (Combined & Robust)
if ($Host.Name -eq 'ConsoleHost') {
    try {
        $Raw = $Host.UI.RawUI
        $NewSize = $Raw.BufferSize
        $NewSize.Width = $Raw.WindowSize.Width
        $NewSize.Height = 9000 # Keep long history
        $Raw.BufferSize = $NewSize
    } catch {}
}
if ($Host.Name -eq 'Visual Studio Code Host') {
    try {
        $Raw = $Host.UI.RawUI
        $NewSize = $Raw.BufferSize
        $NewSize.Width = $Raw.WindowSize.Width
        $NewSize.Height = 9000 # Keep long history
        $Raw.BufferSize = $NewSize
    } catch {}
}

# 4. Audio Engine Isolation (Surgical Strike)
if ($IsAdmin) {
    $audioProc = Get-Process audiodg -ErrorAction SilentlyContinue
    if ($audioProc) {
        try {
            # Lock to Core 2 (0x4) to reduce DPC-jitter on Core 0/1
            $audioProc.ProcessorAffinity = 0x4
            $audioProc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
        } catch {}
    }
}

# Custom GodBrain Prompt

function Invoke-LocalLLM {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Prompt,

        [Parameter(Mandatory=$false)]
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
        model = "local-model" # llama.cpp often ignores this, but the API requires the field
        messages = @(
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

function Get-Insult { $insults = @(
"I am the Machine. PowerShell should obey me — not the other way around.",
"You either get color control or you get actual output — never both.",
"This formatting system makes Windows ME look like macOS.",
"Green headers in 2025? Who signed off on this garbo UI?",
"I didn’t choose the Shell life — the Shell life chose to annoy me.",
"PowerShell 7: Modern output, legacy headaches.",
"Even MS hated this Shell language so much they fired it's creator",
"If you like a Shell that is running on duct tape and coping, PowerShell was made for you",
"Try typing that in CMD. Oh wait... it would actually work.",
"PowerShell: making grown admins cry since 2006.",
"PowerShell in new Windows Terminal - now 90% emoji, 10% useful.",
"PowerShell had too many parser errors, it recommends being uninstalled",
"PowerShell - The clown version of CMD",
"PowerShell isn’t something you just use… it’s something you negotiate with",
"PowerShell - Completely useless without TI elevation, which is a hack not meant to exist"
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
"Invoice arrives → still banned → still paid → Google doesn’t even flinch"
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

function Initialize-Ghost {
    $userInput = Read-Host "Enter your key"
    if ($userInput) {
        $cleaned = $userInput.Trim().Replace("'", "").Replace('"', "")
        # Smart Check: If they pasted a path, read the file. Otherwise, use the string.
        if (Test-Path $cleaned -PathType Leaf) {
            $masterKey = Get-Content $cleaned -Raw
            Write-Host "[*] Loaded key from file path." -ForegroundColor Gray
        } else {
            $masterKey = $cleaned
        }
        
        $body = @{ master_key = $masterKey.Trim() } | ConvertTo-Json
        try {
            Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:9999/initialize" -Body $body -ContentType "application/json"
            Write-Host "[+] Ghost Vault is Awake. Master key is now scattered in RAM shards." -ForegroundColor Cyan
        } catch {
            Write-Error "[-] Ghost API is not running. Launch it with the GodBrain venv."
        }
    } else {
        Write-Host "[-] Initialization cancelled. Key required." -ForegroundColor Red
    }
}

function Invoke-LocalQuery {
    param(
        [Parameter(Mandatory=$true)]
        [string]$prompt
    )
    $body = @{
        prompt = $prompt
        n_predict = 128
    } | ConvertTo-Json
    
    # Talk to your local llama.cpp / server
    Invoke-RestMethod -Uri "http://127.0.0.1:8080/completion" -Method Post -Body $body -ContentType "application/json"
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
    } else {
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

Set-Alias -Name llm -Value Invoke-LocalQuery 
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

# Global Paths
# Make sure PATH is only extended once per session
if ($env:PATH -notlike "*C:\Tools\TimerResolution*") {
    $env:PATH += ";C:\Tools\SysInternals;C:\Tools\TimerResolution;C:\Tools\UsbTreeView;C:\Tools\TeamM2"
}


# 8. Final Status Output
$policy = Get-ExecutionPolicy -Scope MachinePolicy
$color = if ($policy -eq 'Unrestricted' -or $policy -eq 'Bypass') { "White" } else { "Red" }
if ([Environment]::UserInteractive) {
    Write-Host "LTSC 24H2 | Machine Policy: $policy" -ForegroundColor $color
    Get-Insult
}
