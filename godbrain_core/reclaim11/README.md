# Reclaim11 (not Heal, not Galaxy)

One WPF window around the pack-A playbook: Defender / PPL / Sense / AppID.
Not `irm | iex`. Not DISM. Never BFE / `mpssvc` /
`FltMgr` / EventLog.

Inventory plus a **WinPE ISO** that stubs pack-A PPL files on an offline
Windows volume. Killing blows stay gated and **do not mutate** in this
build. No live wipe.

## Rails

- Pack A only. Ads/cloud/WU GPO is pack B, later.
- `WdBoot.sys` is ELAM. **Refuse to stub it when Secure Boot is on.**
- Killing blows unlock only after a WinPE log exists.
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

   Output: `C:\nvme\reclaim11\Reclaim11-WinPE.iso` (outside git).
4. Snapshot, attach the ISO in VMware, boot it. Payload writes
   `Windows\reclaim11-winpe.log` on the guest volume. `wpeutil reboot`.
5. SB-on VM must refuse `WdBoot` stub and still boot. Other pack-A PPL
   files may still be stubbed. SB-off may stub ELAM too.
6. After reboot, inventory sees the receipt and unlocks the killing-blows
   *button* (still non-mutating). `mpssvc` / BFE must still be RUNNING.
7. Physical USB only after the ISO path is green.

BitLocker in the VM is optional for v1; if C: is encrypted, WinPE needs
the protector and inventory must show it.

Brave bloat is a **policy overlay**, not a forked browser:
`godbrain_core\reclaim11\brave-policy\`. Friend-safe default; download
danger block is an explicit power-user tick with a warning.

## Not in v1

Twitter release, winget store, `sfc` / DISM repair tab, `netsh` reset,
Galaxy, Heal, auto-crown.
