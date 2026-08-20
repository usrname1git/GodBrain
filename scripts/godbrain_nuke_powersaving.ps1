
<#
.SYNOPSIS
    GodBrain SRE Power Plan Obliterator & Kernel Scheduler Optimizer
.DESCRIPTION
    Ruthlessly disables all power-saving mechanisms and forces the kernel into 100% RAM.
#>

Write-Host "[*] Initiating GodBrain Power Optimization Sequence..." -ForegroundColor Cyan

# 1. Duplicate and activate the hidden 'Ultimate Performance' plan
Write-Host "[*] Unlocking Ultimate Performance Plan..." -ForegroundColor Yellow
$up_guid = (powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61) -match '([A-Fa-f0-9\-]{36})'
if ($matches) {
    $plan_guid = $matches[1]
    powercfg -setactive $plan_guid
    powercfg -changename $plan_guid "GodBrain Sovereign Performance" "Ruthless power limits. All efficiency modes disabled."
    Write-Host "[+] Activated GodBrain Sovereign Performance Plan ($plan_guid)" -ForegroundColor Green
} else {
    Write-Host "[-] Failed to unlock Ultimate Performance." -ForegroundColor Red
    exit 1
}

# 2. Disable USB Selective Suspend (prevents USB hub sleep latency)
Write-Host "[*] Disabling USB Selective Suspend..." -ForegroundColor Yellow
powercfg -setacvalueindex $plan_guid 2a737441-1930-4402-8d77-b2bea0c8a392 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg -setdcvalueindex $plan_guid 2a737441-1930-4402-8d77-b2bea0c8a392 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0

# 3. Disable PCIe Active State Power Management (ASPM) to prevent GPU/NVMe micro-stutters
Write-Host "[*] Disabling PCIe ASPM (Link State Power Management)..." -ForegroundColor Yellow
powercfg -setacvalueindex $plan_guid 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d2d4-4591-ba4f-ce64811c62fa 0
powercfg -setdcvalueindex $plan_guid 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d2d4-4591-ba4f-ce64811c62fa 0

# 4. Processor Power Management - Pin Min/Max to 100% (No C-State Downclocking)
Write-Host "[*] Forcing CPU Minimum State to 100%..." -ForegroundColor Yellow
powercfg -setacvalueindex $plan_guid 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100
powercfg -setdcvalueindex $plan_guid 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100

# 5. Disable Processor Idle Demotion/Promotion (forces CPU to stay awake)
Write-Host "[*] Unhiding and Disabling CPU Idle States..." -ForegroundColor Yellow
$power_reg = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00"
Set-ItemProperty -Path "$power_reg\68f262a7-f621-4069-b9a5-4874169be23c" -Name "Attributes" -Value 2 -ErrorAction SilentlyContinue
powercfg -setacvalueindex $plan_guid 54533251-82be-4824-96c1-47b60b740d00 68f262a7-f621-4069-b9a5-4874169be23c 0

# 6. Turn off Display/Disk sleep timers
Write-Host "[*] Nuking Display and Disk Sleep Timers..." -ForegroundColor Yellow
powercfg -change -monitor-timeout-ac 0
powercfg -change -disk-timeout-ac 0
powercfg -change -standby-timeout-ac 0
powercfg -change -hibernate-timeout-ac 0

# 7. KERNEL & SCHEDULER OVERRIDES
Write-Host "[*] Optimizing Kernel Scheduler & Memory Management..." -ForegroundColor Yellow
$sess_mgr = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
$prio_ctrl = "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"

# Force kernel into RAM (eliminates paging I/O latency)
Set-ItemProperty -Path $sess_mgr -Name "DisablePagingExecutive" -Value 1 -Type DWord

# Set Win32PrioritySeparation to 1 (Foreground apps get strict fastest CPU timeslicing)
Set-ItemProperty -Path $prio_ctrl -Name "Win32PrioritySeparation" -Value 1 -Type DWord

Write-Host "[+] Power Plan & Kernel Obliteration Complete! System is locked into MAX PERFORMANCE." -ForegroundColor Green
