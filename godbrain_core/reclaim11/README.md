# Reclaim11 (not Heal, not Galaxy)

One WPF window around the pack-A playbook: Defender / PPL / Sense / AppID.
Not `irm | iex`. Not DISM. Never BFE / `mpssvc` /
`FltMgr` / EventLog.

Inventory plus a **WinPE ISO** that parks pack-A `.sys` on an offline
Windows volume (never a usermode EXE over a driver) and copies
`C:\reclaim11\` for the online remainder. Killing blows (IFEO + `sc delete`
pack A) run only after a WinPE receipt, and **refuse this desk**
(`IoTEnterpriseS`). Never BFE / `mpssvc` / `FltMgr`.

## Rails

- Pack A only. Ads/cloud/WU GPO is pack B, later.
- `WdBoot.sys` is ELAM. **Refuse to park/stub it when Secure Boot is on.**
- Killing blows unlock only after a WinPE receipt. Desk SKU is refused.
- Heal never launches this. Kernel YOLO never `--ti` for this.

## Run

```text
pwsh -STA -NoProfile -ExecutionPolicy Bypass -File godbrain_core\reclaim11\Reclaim11.ps1
```

Headless inventory (JSON):

```text
pwsh -NoProfile -File godbrain_core\reclaim11\Reclaim11.ps1 -InventoryOnly
```

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

   Output: `C:\nvme\reclaim11\Reclaim11-WinPE-v3.iso` (outside git).
   v1/v2 copied EXE over `.sys` and bootloop; do not attach those.
4. Snapshot, attach **v3**, boot CD. Payload parks `drivers\Wd*.sys`
   (exact names), stubs usermode EXEs, writes `Windows\reclaim11-winpe.log`
   and `C:\reclaim11\`. Disconnect ISO. `wpeutil reboot`.
5. SB-on VM must refuse `WdBoot` park and still boot. SB-off may park ELAM.
6. After reboot, BFE/`mpssvc` must be RUNNING. Then:

   ```text
   pwsh -NoProfile -ExecutionPolicy Bypass -File C:\reclaim11\Apply-KillingBlows.ps1
   ```

7. Physical USB only after the ISO path is green.

BitLocker in the VM is optional for v1; if C: is encrypted, WinPE needs
the protector and inventory must show it.

Brave bloat is a **policy overlay**, not a forked browser:
`godbrain_core\reclaim11\brave-policy\`. Friend-safe default; download
danger block is an explicit power-user tick with a warning.

## Not in v1

Twitter release, winget store, `sfc` / DISM repair tab, `netsh` reset,
Galaxy, Heal, auto-crown.
