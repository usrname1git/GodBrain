# --- Minimalist LTSC Startup: Bare Metal Edition ---

# 1. Identity & Context
[void]([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($pwd.Path -eq "$env:WinDir\System32") { Set-Location "C:\Users\autismo" }

# 2. Global UI Policy (Sätts tidigt så alla kommandon lyder direkt)
$PSDefaultParameterValues['Format-Table:AutoSize'] = $true

# 3. Terminal & Buffer Fix (Kombinerad & Robust)
if ($Host.Name -eq 'ConsoleHost' -or $Host.Name -eq 'Visual Studio Code Host') {
    try {
        $Raw = $Host.UI.RawUI
        # Mappa bufferten direkt till fönstrets bredd för att döda radbrytningar
        $NewSize = $Raw.BufferSize
        $NewSize.Width = $Raw.WindowSize.Width
        $NewSize.Height = 3000 # Behåll lång historik
        $Raw.BufferSize = $NewSize
    } catch {}
}
function Get-Insult { $insults = @(
"I am the Machine. PowerShell should obey me — not the other way around.",
"Fire the whole fucking PS and Windows Terminal team!",
"You either get color control or you get actual output — never both.",
"This formatting system makes Windows ME look like macOS.",
"Green headers in 2025? Who signed off on this garbo UI?",
"I didn’t choose the Shell life — the Shell life chose to annoy me.",
"PowerShell 7: Modern output, legacy headaches.",
"Not only the most retarded Shell, also the most retarded script language ever created",
"Even MS hated this Shell language so much they fired it's creator",
"If you like a Shell that is running on duct tape and coping, PowerShell is perfect",
"Try typing that in CMD. Oh wait... it would actually work.",
"PowerShell: making grown admins cry since 2006.",
"PowerShell in new Windows Terminal - now 90% emoji, 10% useful.",
"PowerShell had too many parser errors, it recommends being uninstalled",
"PowerShell - The clown version of CMD",
"PowerShell isn’t something you just use… it’s something you negotiate with"
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

$Host.UI.RawUI.WindowTitle = ($insults | Get-Random)
Write-Host "🗑️ " -NoNewline; Write-Host "$($insults | Get-Random)" -ForegroundColor Red

}

# 5. Expert Functions (The Toolbelt)

# TI-Escalation
function ti { 
    $t = if ($pwd.Path -like "*System32*") { "C:\Users\autismo" } else { $pwd.Path }
    wsudo.exe --ti pwsh -NoExit -Command "Set-Location '$t'" 
}


# 6. Aliases
Set-Alias insult Get-Insult
Set-Alias -Name MinSudo -Value MinSudo.exe
Set-Alias -Name wsudo -Value wsudo.exe
Set-Alias -Name handle -Value handle64.exe

# 7. Final Status Output
$policy = Get-ExecutionPolicy -Scope MachinePolicy
$color = if ($policy -eq 'Unrestricted' -or $policy -eq 'Bypass') { "White" } else { "Red" }
Write-Host "LTSC 24H2 | Machine Policy: $policy" -ForegroundColor $color

# Custom Prompt
function prompt {
    "$([char]27)[36m[SteamusDominus]$([char]27)[0m $pwd > "
}
