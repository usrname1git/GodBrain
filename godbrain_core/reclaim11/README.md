# Reclaim11

**Recommended:** run it on a VM like VMware first, or at least run TEST
mode and see the result.

**MUST:** PREP MEDIA, then boot WinPE (ISO or USB) if you want Defender /
PPL / Sense gone. That offline pass is the kill. Without that boot the
GUI is **bloat only** (Xbox, telemetry, NIC, Start junk, BCD timer,
USB/ASPM, power registry). Killing blows and Grim Reaper stay locked
until a WinPE receipt. Exact flags are under Advanced.

## What to do

1. Get `Reclaim11-kit-v10.zip` from
   [GitHub Releases](https://github.com/usrname1git/GodBrain/releases/tag/reclaim11-v10)
   and unzip it. Check the `.sha256` next to the zip.
2. Double-click `Reclaim11.cmd`. You do not type `pwsh`. The `.cmd` hops
   to a hidden host so Windows Terminal does not stay as an empty black
   window. If you only have Windows PowerShell 5.1, the GUI offers the
   official PowerShell 7 MSI (adds PATH). WinPE stays 5.1.
3. Click **TEST FIRST** (noob door) or **TEST SELECTED** (expert).
   Nothing is deleted. Read the log.
4. Then pick a door:
   - **Noob:** Hide Xbox + telemetry. No Defender. No killing blows.
   - **Expert:** **PREP MEDIA** builds the WinPE ISO if missing, then
     writes a USB (formats the stick). Boot the ISO or the stick.
     VM recommended, not required. After Windows is up, SCAN.
     Killing blows / Grim Reaper unlock only after that boot.

Game Mode stays. The Xbox controller driver stays.

![Door chooser](ui/DoorChooser.jpg)

![Expert panel](ui/ExpertPanel.jpg)

## Advanced

Pack A is Defender / PPL / Sense / AppID. Hide Xbox also clears named
Start junk (Copilot, new Outlook, Clipchamp, WhatsApp, LinkedIn, …) and turns off Start
Recommended. Photos, Calculator, Store, Notepad stay. Game Mode stays.
The Xbox controller driver (`xboxgip`) stays.

### Rails

- Defender / PPL **require** a WinPE ISO you build and boot. No receipt = bloat only.
- `WdBoot.sys` is ELAM. **Refuse to park/stub it when Secure Boot is on.**
- Killing blows / Grim Reaper unlock only after a WinPE receipt.
- WinPE waits **12 seconds**: press **H** if Windows won't boot (skips Automatic Repair). Otherwise pack A runs as today. Help writes `reclaim11-winre-skip.log` and does **not** unlock killing blows.

### In-Windows without PE (exact flags)

These are the Expert/noob actions that do not need a WinPE receipt.
`restore.json` is written first.

- **BCD `{current}`:** `nx AlwaysOff` (DEP off), `tscsyncpolicy Enhanced`,
  `hypervisorlaunchtype Auto`, `vsmlaunchtype Off`, `sos No`,
  `useplatformclock No`, `useplatformtick No`, `disabledynamictick Yes`.
  `{bootmgr}` `bootmenupolicy Legacy`.
- **HKLM:** `GlobalTimerResolutionRequests=1`,
  `SystemResponsiveness=10` (0–9 clamp to 20),
  `Win32PrioritySeparation=38`.
- **Power (AC, active plan + High Performance if listed):** USB selective
  suspend Off, USB 3 link power Off, PCIe ASPM Off. GUI **asks** before
  `/setactive` High Performance. CLI needs `-SwitchHighPerformance`.
  Not min processor 100%. Not C-state kill. AGGRO (`61329e62`) and
  Ultimate (`e9a42b02`) refused.

### Two PE profiles

- **Operator PE:** `reg delete` pack-A service keys in the offline hive
  and **delete** catalog `.sys` (no sidecar `.bak` in `drivers\`).
  Never a usermode EXE over a driver.
- **GUI Safe cleanse:** move-only into `C:\reclaim11\backup\<stamp>\`
  plus `restore.json`. Restore with
  `Restore-Reclaim11Noob.ps1 -Manifest restore.json`. Does not delete.

### WinPE ISO (Defender)

ADK + WinPE addon **10.1.26100.2454**, not ADK 28000. PREP MEDIA
asks Yes/No if the pair is missing; Yes installs it and keeps going.
The kit zip ships `winpe\reclaim11-stub.exe` (MZ). PREP does not need Visual Studio.

```text
pwsh -NoProfile -File .\scripts\New-Reclaim11WinPeIso.ps1
```

Output: `C:\Reclaim11\Reclaim11-WinPE-v10.iso`.
v1/v2 copied EXE over `.sys` and bootloop; do not attach those.

### Boot the ISO in VMware

The VM CD/DVD picker browses the **host**, not the guest. Copy
`C:\Reclaim11\Reclaim11-WinPE-v10.iso` out of the VM (shared folder or
drag-drop), then VM Settings → CD/DVD → Use ISO image file → that host
path. EFI firmware. Boot the CD (firmware menu). USB EFI passthrough of
the PREP stick is the same WinPE; VMware USB is slow, not a kit hang.
Never boot this ISO or stick on the machine that built it.

Delete the ISO and click PREP MEDIA again after a kit update — an
existing ISO skips the rebuild, and both ISO and USB bake scripts into
`boot.wim`.

Snapshot, attach **v10**. PE **deletes** catalog
`drivers\WdBoot.sys` / `WdFilter.sys` / `WdNisDrv.sys` / `WdDevFlt.sys`
(exact names, never a `Wd*.sys` glob), stubs catalog usermode EXEs,
`reg delete` pack-A keys then Start=4 fallback, IFEO +
`DisableAntiSpyware` in the **offline hives**. Live Windows IFEO is
the wrong door (Tamper/PPL ACL). Disconnect ISO. `wpeutil reboot`.

Secure Boot on: refuse `WdBoot` delete and still boot. Secure Boot off
may drop ELAM.

After reboot, in-Windows `Apply-KillingBlows.ps1` is leftover `sc delete`,
Defender/ExploitGuard scheduled tasks (those two folders only), and delete
of `HKLM\SOFTWARE\Microsoft\Windows Defender` (resurrection lock). GPO
`DisableAntiSpyware=1` stays. Killing blows writes `restore.json` (task XML
under `tasks\`) before the deletes.

Optional remainder: `grim_reaper.ps1` (GUI: Send Grim Reaper).
**Deletes** named drivers, never stubs `.sys` / `.cip`. After 26H1 it
also locks WU resurrection (`wuauserv` / `UsoSvc` / `WaaSMedicSvc` and
named task folders) and hides Windows Update in Settings
(`hide:windowsupdate;…`, Game Mode stays) and
`SetDisableUXWUAccess=1` (System page Check for updates chrome).
`pwsh -File grim_reaper.ps1 -SelfTest`.
Old filename `NuclearDefenderWipe-V6_3.ps1` still launches this script.

Physical USB is a **separate** script (ISO builder stays `/ISO` only):

```text
pwsh -NoProfile -File .\scripts\New-Reclaim11WinPeUsb.ps1 -T
pwsh -NoProfile -File .\scripts\New-Reclaim11WinPeUsb.ps1 -DiskNumber N -Go
```

### Hide Xbox, telemetry, NIC

**Hide Xbox** (in-Windows): `restore.json` first, then Settings hide so
Gaming is Game Mode only. Does **not** write `AllowAutoGameMode`.
Does **not** delete `xboxgip`. Does **not** remove
`Microsoft.XboxGameCallableUI`. Admin (UAC). Restore:
`pwsh -File xbox_cleanse.ps1 -Restore restore.json`.

**Disable telemetry:** `AllowTelemetry=0`, `DiagTrack` + `dmwappushservice`
start=disabled. Restore:
`pwsh -File telemetry_cleanse.ps1 -Restore restore.json`.

**Tune NIC** (Ethernet only): EEE/interrupt moderation/flow/WoL off,
checksum/LSO/VLAN-priority off, RSS on, Rx/Tx **256–512**. Does not
force Speed/Duplex. Skips VMware host VMnet / Tailscale / Wi-Fi.
`pwsh -File nic_tune.ps1 -T`.

**Latency bake** (Expert, in-Windows): flags are under
**In-Windows without PE** above. WinPE MiniNT refused (that would be
the PE BCD). `pwsh -File latency_bake.ps1 -T`. Restore:
`pwsh -File latency_bake.ps1 -Restore restore.json`.

Killing blows / Grim Reaper self-elevate to TrustedInstaller via Task
Scheduler (Admin → SYSTEM → TI). No wsudo / MinSudo. WinPE is already
SYSTEM and skips that hop.

### From this repo

Run `Test-Reclaim11.ps1` on a VM. Not physical hardware.

```text
godbrain_core\reclaim11\Reclaim11.cmd
pwsh -NoProfile -File godbrain_core\reclaim11\ps1\Reclaim11.ps1 -T
pwsh -NoProfile -File .\scripts\New-Reclaim11KitZip.ps1
.\scripts\Test-Reclaim11.ps1
```

Headless inventory: `Reclaim11.ps1 -InventoryOnly`. GUI transcripts to
`%LOCALAPPDATA%\Reclaim11\logs`.

BitLocker in the VM is optional; if C: is encrypted, WinPE needs the
protector.

Brave bloat is a **policy overlay** in `brave-policy\`, not a forked browser.
