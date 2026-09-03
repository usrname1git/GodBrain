# Reclaim11

**MUST:** build a WinPE ISO and boot it if you want Defender / PPL / Sense
gone. That offline pass is the kill. Without that boot, this GUI is
**bloat only** (Xbox, telemetry, NIC). Killing blows and Grim Reaper
stay locked until a WinPE receipt.

One WPF window around the pack-A playbook: Defender / PPL / Sense / AppID.

Inventory plus a **WinPE ISO**. Two cleanse profiles:

- **Operator PE:** `reg delete` pack-A service keys in the offline hive
  and **delete** catalog `.sys` (no sidecar `.bak` in `drivers\`).
  Never a usermode EXE over a driver.
- **GUI Safe cleanse:** move-only into `C:\reclaim11\backup\<stamp>\`
  plus `restore.json` (`original` / `backup` / `relative` / `sha256` /
  `length`). Restore with `Restore-Reclaim11Noob.ps1 -Manifest restore.json`.
  Does not delete.

Killing blows (IFEO + `sc delete` pack A) and Safe cleanse run only after
a WinPE receipt, and **refuse this desk** (`IoTEnterpriseS`). Never BFE /
`mpssvc` / `FltMgr`.

## Rails

- Pack A only. WU GPO is pack B, later. Start junk (named Appx + Recommended off) is Hide Xbox.
- Defender / PPL **require** a WinPE ISO you build and boot. No receipt = bloat only.
- `WdBoot.sys` is ELAM. **Refuse to park/stub it when Secure Boot is on.**
- Killing blows unlock only after a WinPE receipt. Desk SKU is refused.

## Run

Double-click `Reclaim11.cmd` (UAC + GUI). Workers live in `ps1\`. You do not
need to type `pwsh`.

Download (Reclaim11 only, not the GodBrain tree): GitHub Release tag
`reclaim11-v9`, asset `Reclaim11-kit-v9.zip` plus the `.sha256` next to it.
Unzip and double-click `Reclaim11.cmd`. That zip is **bloat + ISO builder**.
**MUST** still build and boot the WinPE ISO to take Defender. `irm | iex` is
not this zip.

Pack the zip from this repo:

```text
pwsh -NoProfile -File .\scripts\New-Reclaim11KitZip.ps1
```

```text
godbrain_core\reclaim11\Reclaim11.cmd
```

Test-only (DeviceCleanupCmd `-t`: privs, paths, what would happen, no mutate):

```text
pwsh -NoProfile -File godbrain_core\reclaim11\ps1\Reclaim11.ps1 -T
pwsh -NoProfile -File godbrain_core\reclaim11\ps1\xbox_cleanse.ps1 -T
```

GUI **TEST SELECTED** is the same. Desk SKU is a report line, not a crash.

Headless inventory (JSON):

```text
pwsh -NoProfile -File godbrain_core\reclaim11\ps1\Reclaim11.ps1 -InventoryOnly
```

GUI opens on a **door chooser**: noob (three jobs + TEST) vs expert
(BIOS ticks). The expert door is that tick wall on purpose — a noob
hitting it closes the app. SWITCH DOOR goes back.

GUI (not `-InventoryOnly`) self-elevates UAC, requires FullLanguage, and
transcripts to `%LOCALAPPDATA%\Reclaim11\logs`. ConstrainedLanguage
refuse, `-Verb RunAs`, XAML try/catch, run lock, DragMove, screen clamp,
Esc/Ctrl+Q. `-InventoryOnly` still skips UAC. Not `irm | iex`.

Check:

```text
.\scripts\Test-Reclaim11.ps1
```

## VMware first (this host has Workstation 17.6.4)

Do **not** nuke the desk. Snapshot a VM, then:

1. New Win11 VM, EFI. One snapshot **Secure Boot on**, one **off**.
2. Inventory in the VM (this GUI). Confirm SKU / SB / BitLocker / PPL.
3. Build the ISO (ADK + WinPE addon **10.1.26100.2454**, not ADK 28000):

   ```text
   pwsh -NoProfile -File .\scripts\New-Reclaim11WinPeIso.ps1
   ```

   Output: `C:\nvme\reclaim11\Reclaim11-WinPE-v7.iso` (outside git).
   v1/v2 copied EXE over `.sys` and bootloop; do not attach those.
4. Snapshot, attach **v7**. PE is the kill: **deletes** catalog
   `drivers\WdBoot.sys` / `WdFilter.sys` / `WdNisDrv.sys` / `WdDevFlt.sys`
   (exact names, never a `Wd*.sys` glob), stubs catalog usermode EXEs,
   `reg delete` pack-A keys then Start=4 fallback, IFEO +
   `DisableAntiSpyware` in the **offline hives**. Live Windows IFEO is
   the wrong door (Tamper/PPL ACL). Disconnect ISO. `wpeutil reboot`.
5. SB-on VM must refuse `WdBoot` delete and still boot. SB-off may drop ELAM.
6. After reboot, BFE/`mpssvc` must be RUNNING. In-Windows
   `Apply-KillingBlows.ps1` is leftover `sc delete`, Defender/ExploitGuard
   scheduled tasks (those two folders only), and delete of
   `HKLM\SOFTWARE\Microsoft\Windows Defender` (resurrection lock). GPO
   `DisableAntiSpyware=1` stays. Not a host-wide task glob.
   Optional remainder: `grim_reaper.ps1` (GUI: Send Grim Reaper; boot-safe).
   Compat name: `NuclearDefenderWipe-V6_3.ps1`.
   v6.2 stubbed kernel `.sys` and `CIPolicies` and WinRE'd; v6.3
   **deletes** named drivers, never stubs `.sys` / `.cip`, never DENY
   SYSTEM under `System32`. After 26H1 it also Grim-Reapers WU resurrection:
   `sc delete` `wuauserv` / `UsoSvc` / `WaaSMedicSvc`, IFEO
   `UsoCoreWorker.exe` / `MoUsoCoreWorker.exe` / `WaaSMedicAgent.exe`,
   named task folders WindowsUpdate / WaaSMedic / UpdateOrchestrator.
   Never stub `usosvc.dll` / `wuaueng.dll` / `WaaSMedicSvc.dll`. Never
   bits / DoSvc / TrustedInstaller. Not killing-blows pack A (so 26H1
   via Windows Update still works *before* Nuclear). Check:
   `pwsh -File grim_reaper.ps1 -SelfTest`. Not this desk.

7. Physical USB is a **separate** script (ISO builder stays `/ISO` only):

   ```text
   pwsh -NoProfile -File .\scripts\New-Reclaim11WinPeUsb.ps1 -T
   pwsh -NoProfile -File .\scripts\New-Reclaim11WinPeUsb.ps1 -DiskNumber N -Go
   ```

   Legal stick: USB, 2–32 GiB, not disk 0, not `C:`, not a USB HDD
   (`D:\` W11_STORAGE is refused by size). Refreshes `boot.wim` payload
   then `MakeWinPEMedia /UFD /F`. Kit also lands on `\reclaim11\` for
   in-Windows Nuclear after PE reboot. **Do not boot the stick on
   M1ABRAMS.** VM USB passthrough or another box. Destination of
   Nuclear is IoT LTSC parity (stub + DACL unused); WU lock is already
   in v6.3. Full Pro-inbox list after 26H1 inventory vs this host.

Killing blows also writes `restore.json` (task XML under `tasks\`) before
the deletes. COM CLSID wipe is not pack A (7-Zip / PowerRename stay).

**Tune NIC** (in-Windows, Ethernet only): keyword map (`*EEE`, `*InterruptModeration`,
`*FlowControl`, WoL, GreenEthernet) → 0; `*RSS` → 1; Rx/Tx buffers → **256–512**
(CS2/latency; keep if already in band, else 512). Not 2048. Skips
VMware host VMnet / Tailscale / Wi-Fi / Bluetooth. Does not
touch BFE/`ms_tcpip` bindings or Speed & Duplex. `restore.json` first.
Desk refused. `pwsh -File nic_tune.ps1 -T`.

**Disable telemetry** (in-Windows, not PE): `restore.json` first, then
`AllowTelemetry=0`, `DiagTrack` + `dmwappushservice` start=disabled (same
pair the old autom8ed nuke lists used). Not `sc delete`. Not a scheduled-task
glob. Desk SKU refused. Restore:
`pwsh -File telemetry_cleanse.ps1 -Restore restore.json`.

**Hide Xbox** (in-Windows, not PE): writes `C:\reclaim11\backup\<stamp>\restore.json`
first, then HKLM+HKCU `SettingsPageVisibility`
`hide:gaming-gamebar;gaming-gamedvr;gaming-trueplay;gaming-broadcasting;gaming-captures`
(GPO is one `hide:` then semicolon ids — not `hide:` per page, or only the
first page hides). Settings → Gaming is Game Mode only (Captures =
`gaming-gamedvr`; OBS / ShadowPlay / AMD).
HKCU GameBar: `EnableGameBar=0`, startup/broadcast panels off. Does **not** write
`AllowAutoGameMode` / `AutoGameModeEnabled` (Game Mode stays). `sc delete` Xbox
usermode (`XblAuthManager`, `XblGameSave`, `XboxNetApiSvc`, `XboxGipSvc`,
`GamingServices`, `BcastDVRUserService*`). Removes the Appx bloat list
(Game Bar, Bing News, Get Help, Solitaire, Zune, Feedback Hub, Your Phone,
…). Restore: `pwsh -File xbox_cleanse.ps1 -Restore restore.json`. Does
**not** delete `xboxgip` (controller). Does **not** remove
`Microsoft.XboxGameCallableUI`. Desk SKU refused. Hide Xbox is admin
(UAC); killing blows / Nuclear self-elevate to TrustedInstaller via Task
Scheduler (Admin → SYSTEM → TI). No wsudo / MinSudo. WinPE is already
SYSTEM and skips that hop.

GUI (Safe / Kill / Reaper locked until a WinPE receipt). **MUST** boot the
ISO for Defender; screenshots are a 26H2 VM *after* that boot:

![Door chooser](ui/DoorChooser.jpg)

![Expert panel](ui/ExpertPanel.jpg)

BitLocker in the VM is optional for v1; if C: is encrypted, WinPE needs
the protector and inventory must show it.

Brave bloat is a **policy overlay**, not a forked browser:
`godbrain_core\reclaim11\brave-policy\`. Friend-safe default; download
danger block is an explicit power-user tick with a warning.

## Not in v1

Twitter release, winget store, `sfc` / DISM repair tab, `netsh` reset,
Galaxy, Heal, auto-crown.
