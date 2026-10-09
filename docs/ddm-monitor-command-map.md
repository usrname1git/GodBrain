# Dell DDM monitor command map

## Scope and evidence

This is an original factual reference for DDM **2.0.0.134** and the native
GodBrain replacement on a **Dell S2522HG**. It is suitable as a source for
later Librarian/RAG ingestion, not a blanket verified record. Ingested
claims must retain their individual evidence and normal candidate/judge gates.
No ingestion, promotion, monitor write, or model call is performed by this file.

Three kinds of evidence are deliberately separate:

| Evidence | What it establishes | Limits |
|---|---|---|
| Local inspection of DDM 2.0.0.134 types and command handlers | Constants, lookup tables, legacy cycle action and F4 selection/query path | Not proof that another monitor advertises or implements those commands |
| GodBrain native source, offline tests and live DDC/CI readback | Exact command encoding, capability gates, bounded process ownership and readable settings | API acceptance alone cannot verify a Dark Stabilizer level |
| Operator observation on the connected S2522HG | Four visible cycle positions and working Desk button/F9 with DDM exited | Current numeric level is still unavailable; no packet trace was obtained |

Implementation references: `godbrain_core\cpp_tools\desk_monitor.cpp`,
`scripts\GodBrain-DeskMonitor.ps1`, `scripts\Test-DeskMonitor.ps1`,
`scripts\Show-DeskMenu.ps1`, and `scripts\Test-DeskMenu.ps1`.
Vendor assemblies, decompiled implementation text and private settings exports
are intentionally not included.

## Dark Stabilizer: the working cycle command

**On this S2522HG, advance one position by writing VCP `E3` = `10`
(hexadecimal): code 227, value 16 in decimal.**

DDM names code E3 `BlackEnhancementControl`; its legacy hotkey action uses
the `10` cycle value. GodBrain narrows this to an exact Dell PnP target,
capability model `S2522HG`, and advertised E3. It rejects missing or ambiguous
targets and does not probe the unrelated Samsung monitor.

The operator observed the sequence **0 disabled -> 1 -> 2 -> 3 -> 0**.
Both the Desk button and global F9 were physically confirmed to work without
DDM running. This is a cycle action, not an absolute-level setter.

The native action writes **once**, with no automatic write retry or software
level counter. Its receipt means:

```text
action.control = dark_stabilizer_cycle
action.command_accepted = true
action.state_verified = false
action.current = null
action.vcp_code = 227
action.value = 16
action.write_count = 1
```

If an acknowledgement or deadline fails after a possible write, the monitor
may already have advanced. Observe the picture before trying again. Retrying
automatically could advance another position.

**An E3 read of zero does not mean Dark Stabilizer is disabled.** Locally
compared exports made at visually observed minimum and maximum had identical
31-entry VCP snapshots, including E3 zero, and neither contained F4. Native E3
readback likewise does not establish the current cycle level.

The UI text **Disabled / Enabled level 1-3** is a static legend, not a status.
F9 remains registered while Desk is hidden; quitting Desk releases it. An
existing F9 owner produces an explicit collision notice and a Claim F9 button.
Busy monitor operations reject a press rather than queue another cycle.

## Dark Stabilizer: the different absolute F4 interface

DDM names VCP `F4` (244 decimal) `GamingWidgetsControls`.
`GamingStructure.DarkStabilizerName` maps:

| Dark level | F4 value, hex | F4 value, decimal |
|---|---|---|
| Disabled / Level0 | `30` | 48 |
| Level1 | `31` | 49 |
| Level2 | `32` | 50 |
| Level3 | `33` | 51 |
| Dark group query selector | `3F` | 63 |

On a supported device, the query path selects F4=`3F` and reads F4; it is
not a query of E3. The native helper requires advertised F4 values `30` through
`33` before using the absolute interface.

**This S2522HG does not advertise that interface.** GodBrain therefore reports
absolute Dark Stabilizer unsupported and presents cycling only. A table in
DDM's source is not permission to send undocumented commands to this host.
Do not send `30`-`33` to E3, confuse decimal 16 with hex `16`, or infer an
absolute level from a hotkey binding or cached value.

## Readable brightness and contrast

| Control | VCP code, hex | VCP code, decimal | Native accepted range |
|---|---|---|---|
| Brightness | `10` | 16 | 0-100, with hardware maximum 100 |
| Contrast | `12` | 18 | 0-100, with hardware maximum 100 |

These are ordinary readable controls, unlike the E3 cycle. GodBrain verifies
their actual readback after one write. A failed verification is not reported
as a verified change.

## Color presets: setter and E2 readback are different

The following is the native S2522HG encoding table. **Every code and value
in this table is hexadecimal.** A preset is offered only when the monitor
advertises both its setter value and E2 readback value.

| Preset | Native ID | Setter code=value | Expected E2 readback |
|---|---|---|---|
| Standard | `standard` | `DC=00` | `00` |
| Game 1 | `game1` | `DC=05` | `04` |
| ComfortView | `comfortview` | `F0=0C` | `1D` |
| Game 2 | `game2` | `F0=0D` | `1E` |
| Game 3 | `game3` | `F0=0E` | `1F` |
| FPS | `fps` | `F0=0F` | `20` |
| RTS | `rts` | `F0=10` | `21` |
| RPG | `rpg` | `F0=11` | `22` |
| Sports | `sports` | `F0=13` | `2F` |
| Warm | `warm` | `14=0B` | `0E` |
| Cool | `cool` | `14=08` | `12` |
| Custom Color | `custom` | `14=0C` | `14` |

For example, selecting Game 1 writes DC=`05`, but verification expects
E2=`04`, not `05`. Standard/FPS/Warm live write-and-restore checks exercised
the three setter families DC/F0/14. The encoding table is covered offline;
this does not claim separate visual confirmation of all twelve presets.

## Other DDM F4 tables: reference only

These keys are source-confirmed mappings in DDM 2.0.0.134, **not implemented
or probed controls on this host**. Values below are hexadecimal.

| F4 category | Value-to-name mapping |
|---|---|
| Game enhancement | `10` Off; `11` FrameRate; `12` DisplayAlignment; `13` Timer30min; `14` Timer40min; `15` Timer50min; `16` Timer60min; `17` Timer90min |
| Response time | `20` Extreme; `21` SuperFast; `22` Fast; `23` Normal |
| Smart HDR | `40` Off; `41` Desktop; `42` MovieHDR; `43` GameHDR; `44` DisplayHDR600; `45` CustomColorHDR; `46` HDRPeak1000 |

The same number has different meaning on a different VCP code: E3=`10`
is the working Dark cycle, while F4=`10` belongs to game enhancement.

## Identifiers that are not Dark strengths or VCP commands

`GamingStructure.GameEyeMode` uses decimal enum IDs: Off=0,
NightVision=1, ClearVision=2, BinoVision=3, ChromaVision=4, Steady=5,
Crosshair=6. **NightVision/ClearVision/BinoVision are distinct vision modes,
not Dark Stabilizer levels 1/2/3.**

`HotkeyFun.DarkStablizer=4` is a saved binding function identifier.
`HotKeyTypes.ToggleDarkStabilizer=45170` is an internal hotkey identifier.
Neither is a VCP code, level, or write value.

## DDM queue/cache limits

In the inspected version, `GamingPage.initGeneral` partitions advertised F4
keys by the `1F`/`2F`/`3F`/`4F` groups. `initDarkStabilizer` populates its
dropdown; populating it is not itself a hardware command.

Selection starts a thread, queues `Publish_SetVcp(F4, selectedValue)`,
waits one second and requests refresh. The publisher resolves to
`DDM2._0_UX.ClassMessageBroker` in `DDM.dll`. **That sleep is not a hardware
acknowledgement.** `invalidateVCPF4` requests `3F` when the Dark grid is
visible. Cache grouping masks with `F0`; the `3F` selector addresses the
`30` bucket, and query-selector low nibble `F` is not saved as a level.
A cached value is not necessarily fresh physical readback.

The full queue-consumer chain was not packet-traced. Source transport retry
and locking observations did not prove the cause of host-wide mouse stalls.
The useful confirmed replacement is the gated native command above, not a
claim that all Dell models or every DDM code path was audited.

## Using the native helper

Build from the repository root:

```powershell
.\scripts\Build-DeskMonitor.ps1
.\godbrain_core\cpp_tools\desk-monitor.exe --read
```

An explicit `--cycle-dark` advances once. `--set brightness 75`,
`--set contrast 75`, or `--set preset game1` are writes, not diagnostics.
`--set dark_stabilizer 0` is conditional on absolute F4 support and is
rejected on this host. CLI level arguments are decimal 0-3; the helper
performs the F4 encoding.

Offline checks are `scripts\Test-DeskMonitor.ps1` and
`scripts\Test-DeskMenu.ps1 -UiSmoke` in an STA PowerShell. The opt-in
`-LiveMonitor` suite changes and restores readable settings; do not run it
as a routine documentation/ingestion check.
