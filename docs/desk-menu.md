# Native Desk control panel

Run `.\scripts\Show-DeskMenu.ps1` from PowerShell. It returns the caller's
shell and opens a separate hidden STA WinForms host. X hides the panel;
the power glyph quits. Status and Ask use serialized asynchronous workers
instead of blocking the UI. Image status checks port 8871 and identifies
Qwen-Image-2.1 independently of the text/vision service on port 8888.

The panel can be resized or maximized; its original size is the minimum.
Ask expands the reply area with the window and preserves response line breaks,
so longer answers can be captured in a screenshot. Replies that exceed the
available screen space still scroll.

## Model profiles

The Model page saves context tokens, KV-cache precision, MTP, GPU budget,
RAM prefix cache and the optional 27B vision tower to
`logs\desk-model-settings.json`. Save is passive: only the next explicit
Status Start applies a profile. Invalid settings or an incompatible launcher
are reported before stopping the running model.

The installed Qwen kit's launchers must support the options advertised by
`scripts\GodBrain-DeskModel.ps1`. The kit and its weights are external,
not installed or vendored by this panel. `Start-QwenVL.ps1` supports the
VL context/cache controls and rejects a mismatched already-running profile.
Already-running VL reuse also requires a numeric configured RAM-cache budget
in `health.cpu_cache_size_gb` matching the request. The installed kit currently
reports only cache capacity, which is not proof of its configured budget:
the launcher fails explicitly and requires a stop/start instead of claiming
the requested profile is already applied. The external kit is not modified.

KV precision is not weight precision. RAM prefix caching reuses prefixes;
it does not extend live context or spill dense model weights to disk.
Large text and Max context presets are plans, not guarantees of fitting
every GPU. Explicit high-context/vision starts retain confirmation and the
one-GPU-slot gates. Context thresholds use numeric values, including six-digit
contexts. A saved Vision preference must be a JSON boolean; strings such as
`"false"` are rejected before stopping a model. A missing preference stays off.

The **Text reasoning effort** selector offers Default, Off, Low, Medium and
High (`xhigh` for Qwen3.8). **Apply reasoning** atomically saves
`logs\thinking.txt` for the next text/chat or complete-file review request,
without starting, stopping or reloading a model. This is a global request
preference, separate from the selected launch profile. Default preserves the
model's own behavior (Qwen3.8 defaults to `xhigh`). Existing on/off files and
Galaxy `enable_thinking: true|false` commands remain compatible; the latter
reset the preference to Default/Off. Explicit levels require the running
model's matching `/v1/models` entry to advertise `supported_reasoning_efforts`;
missing/unsupported capabilities fail explicitly rather than silently ignoring
the selection. The installed EXL3 server already supports this contract.

Effort is template guidance, not a hard thinking-token budget. Higher effort
may consume more output/context tokens and time, but does not change weight
precision or automatically enlarge the preallocated cache. Increasing context
capacity can require more VRAM. Kernel tool rounds, `/edit` apply and Desk
picture questions remain thinking-off. Complete-file review planning, every
part and the final synthesis use the same captured preference; receipts record
the effort and remain candidates.

## Complete-file review and images

Ask accepts granted file/folder paths, source files and images. Image bytes
and review bytes are bounded and checked against their final handle target,
not just the visible path. Picture questions use an already-running vision
tower; Qwen-Image uses its existing generation/edit path and request receipts.
Desk picture questions use greedy decoding (`temperature=0`), thinking off,
and a 2,048-token generation ceiling. This is separate from the server's image
pixel limit and the loaded model's context size.

Review complete file is read-only and is also selected automatically for
non-image files above 128 KiB when the request is advisory, not an edit/fix.
The CPU planner uses the installed local tokenizer to budget every source
line into structural or explicitly oversized-unit parts. Parts and their
synthesis run serially, with no tools or edits. Truncation, changed model or
context, token-budget disagreement and changed source fail explicitly.
`logs\last-code-review.json` stores coverage and a **candidate** report,
not a verified repair or an automatically ingested Golden Record.

Existing `/yolo`, `/verify` and `/reject` messages remain kernel commands,
not file-review or vision prompts. Mutation/judgment requests retain their
bearer authorization; read-only slash commands do not start a generation.

## CPU speech helper

The STT/TTS row starts/stops the optional `scripts\voice_door.py` helper
on port 8001. It uses the existing local faster-whisper weights and Piper
voices on CPU; EasyOCR is the CPU image-text fallback. These dependencies
and weights must already be installed. Starting the panel does not download
them or start speech/model services.
Set `GODBRAIN_WHISPER_DIR` and `GODBRAIN_PIPER_VOICES_DIR` before launching
the panel/helper to use other local weight directories. Existing defaults stay
unchanged. The [phone setup guide](phone-control.md#remote-ocr-and-cpu-speech)
lists dependencies, local assets, exact iOS upload/response actions and
authentication troubleshooting without embedding a device address or key.

Speech launches use typed child arguments so repository paths with spaces stay
intact. Multipart audio/image uploads preserve the exact field bytes. Invalid
saved Vision settings produce an explicit unavailable/error response rather
than enabling the tower or silently claiming CPU readiness.

OCR may use the already-running Qwen vision tower when the saved 27B
profile enables it and health explicitly reports idle vision. Busy or
unverifiable tower readiness uses CPU fallback with an explicit note.
EasyOCR downloads are disabled; missing local weights fail explicitly.
CPU OCR decodes with Pillow (including image orientation) and passes contiguous
BGR pixels to EasyOCR; it does not depend on `skimage` image-file plugins.
Speech stays CPU.
The helper exposes `/health`, `/v1/audio/transcriptions`,
`/v1/audio/speech`, `/ocr` and `/ingest/image`.
`/health.components` reports STT, TTS and CPU OCR separately. `available`
means local dependencies/weights exist, not that inference was verified.
A successful request reports `ready`; a backend failure reports `unready`
with its error until a later successful request. Health polling itself never
loads weights or generates. Phone Desk shows these passive states and errors.
Public backend errors are sanitized; detailed errors stay in the authenticated
POST response. STT checks the local tokenizer/model/config before initialization
and does not fetch missing assets.

The Status page also has a separate **Serve** row. Tailscale Start preserves
an existing private HTTPS mapping to Phone Desk on `127.0.0.1:8085`; with no
Serve configuration it installs that mapping using `serve --bg --https=443`.
An unrelated mapping or Funnel configuration is left unchanged and reported.
The CLI's unconfigured JSON `null` is accepted; blank, malformed or other
non-object output fails closed without configuring anything.
Background Serve belongs to the existing Tailscale daemon and resumes with its
service; it is not a second launcher/watchdog. Read-only status polling does not
configure Serve, start Tailscale, or recover the phone backend.

With no configured API key it binds loopback. Setting `X-API-Key` or
`GODBRAIN_API_KEY` makes this helper bind **all IPv4 interfaces**; non-loopback
POSTs then require that key (header or bearer). It is plain HTTP, not a
tailnet-only binding or TLS endpoint. The panel does not create firewall
rules or configure remote exposure. This is separate from the C++ kernel's
`GODBRAIN_API_TOKEN` boundary.

## Phone Desk authorization

Phone Desk runs unelevated. Owner-only requests must arrive over the actual
private Serve TCP connection, owned by the running LocalSystem Tailscale service
or its immediate session-0 worker. The kernel checks the configured service
executable and native process names, ancestry and creation times, then rechecks
those identities and socket ownership; forwarded headers or a matching process
name alone are not authorization. This avoids requesting SYSTEM process handles
that Windows denies to a normal user. A missing owner profile at boot stays
fail-closed and retries at most once per 30 seconds on a trusted Serve request.
Once resolved, the owner is pinned until kernel restart. Local bearer
authentication remains available, and a configured `GODBRAIN_API_TOKEN` is
required for either access path.
`scripts\Test-PhoneDesk.ps1 -Live -Serve` additionally exercises the mobile page
and status over existing private HTTPS without a bearer; it does not configure
Serve or start services.

## AirPlay receiver

The Status page's **AirPlay** row controls the existing
`C:\Tools\ShairportQt\ShairportQt.exe` desktop receiver. **Start** launches it
minimized in the current user's session, **Open** restores its window, and
**Stop** requests its normal close and waits for a clean exit. An existing
instance is reused; unknown paths/owners or multiple instances fail explicitly.
Controls run asynchronously so receiver startup/shutdown does not freeze Desk.

ShairportQt is not a Windows SCM service. No service wrapper, autostart task,
firewall rule, registry change or receiver-setting rewrite is installed.
Closing Desk leaves AirPlay running; it ends at logout unless separately
configured by the operator. Existing tray and receiver/password settings remain
unchanged. Status distinguishes stopped, running without a listener, and
listening; a listening socket is not proof of discovery or successful audio.
`scripts\Test-AirPlay.ps1` runs offline process-identity/status fixtures;
`-Live` explicitly exercises the installed receiver's Start/Open/Stop lifecycle.

## Dell monitor controls and F9

Build the native helper once with `.\scripts\Build-DeskMonitor.ps1`.
The Monitor page uses User32/Dxva2 directly for the Dell S2522HG: brightness,
contrast and advertised color presets have hardware readback verification.
No DDM installation, SDK or background monitor poller is required.
Discovery checks all active monitor identities, ignoring stale records left
by display-profile switches. Contrast writes are limited to **25-100** in the
UI and both helper layers; brightness remains 0-100. If another program sets
contrast lower, Refresh shows that actual readback and offers 25 for the next
Apply without changing the monitor automatically.

Dark Stabilizer is a **Cycle (F9)** action beside the static
**Disabled / Enabled level 1-3** legend. The legend is not current status:
this monitor does not expose usable absolute-level readback. Each button/key
press sends one E3=`10` command; no automatic retry, fake counter or queued
busy press. F9 works while Desk is hidden, including before opening Monitor.
An existing owner is reported; exit it and use Claim F9. Quitting unregisters
the hotkey. There are no mouse hooks or additional hotkey services.

See [DDM monitor command map](ddm-monitor-command-map.md) for the exact
encodings, evidence, unsupported F4 absolute interface and source-only tables.

## Windows display-layout profiles

The **Layouts** button on Monitor opens named Windows layout profiles; **Dell
controls** returns to the picture controls. Build the independent native helper
with `.\scripts\Build-DisplayProfiles.ps1`. It uses documented User32
`QueryDisplayConfig`, `DisplayConfigGetDeviceInfo` and `SetDisplayConfig` APIs,
not Monitor Profile Switcher code, binaries, XML profiles or a vendor SDK.
No additional service, tray process, task or startup layout change is installed.

Configure a layout in Windows, enter a new name and **Capture** it. Capture
records active displays, extend/clone source geometry, primary origin, positions,
resolution, orientation and rational refresh/timing data without changing the
layout. **Overwrite** recaptures a selected GodBrain profile after confirmation;
**Delete** removes only that selected GodBrain record. Saved profiles and an
unfinished-switch recovery journal live in `%LOCALAPPDATA%\GodBrain`, outside
Git. Existing Monitor Profile Switcher profiles/installations remain untouched:
recapture desired configurations instead of importing its private XML format.

**Preview** resolves monitor device/adapter identities against current Windows
paths and validates without applying. Missing, ambiguous or incompatible targets
fail explicitly; saved display numbers and adapter LUIDs are not replayed.
Profiles support 1-16 active displays and always require a primary display.
There is no custom layout editor, HDR, DPI scaling, ICC/colour-profile switching,
DDC/CI write or driver installation. Profile portability across adapters/driver
identity changes is not promised: recapture rather than guess.

**Apply** validates, writes a flushed recovery snapshot, applies temporarily and
checks the actual layout, then persists the saved profile and checks both the
live and saved Windows configurations. Desk's Apply button and profile hotkeys
switch directly: **no Keep popup and no 15-second revert on a successful switch**.
This applies only to an explicitly selected saved profile; Capture stays read-only.
Verification checks clone-source membership as well as monitor geometry and
refresh; overlapping extended displays cannot masquerade as a cloned layout.
Direct-switch receipts say `confirmation=saved_profile`, not that a Keep button
was clicked. The native CLI's default interactive mode still offers a 15-second
Keep / Revert window; revert, close, timeout or detected owner exit restores and
verifies the previous layout. An owner exit before persistence also aborts a
direct switch. Validation does not guarantee that a working layout is comfortable
to use; choose another saved profile to undo a successful direct switch.
A normal failure attempts restoration and reports its result. Driver
hangs, process termination or unplugged monitors can prevent restoration; no
receipt then claims success. An uncleared journal blocks later changes and
**Recover previous layout** explicitly resolves/restores it. Listing never
automatically applies a recovery. A recovery error retains the journal.
Before either direct switching or Keep writes Windows' saved layout, the journal is flushed again with a
separate pre-switch database snapshot. If persistence could have begun, recovery
restores and checks that saved layout first, then restores and checks the previous
live layout temporarily; the two can differ. Recovery before persistence never writes the
database. Older journal versions lack a separate database snapshot and
conservatively use their captured live layout if persistence may have begun.
Windows' documented identity-scaling normalization at matching source/target
dimensions is treated as equivalent, not mistaken for a failed restoration.
Database snapshots also retain the zero `totalSize` that
[QueryDisplayConfig](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-querydisplayconfig)
documents for database queries; ordinary captured profiles still require full
target timing. The scaling normalization follows
[SetDisplayConfig](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdisplayconfig),
not a guessed driver fallback.

Assign **Ctrl+Alt+F1-F12** to a profile using **Set hotkey**, or select None.
The existing Desk host owns these hotkeys while hidden; quit releases them.
Collisions are reported; release the other owner and Refresh to retry. F9 keeps
its separate Dell cycle meaning. Profile and Dell operations are serialized:
busy presses are rejected, never queued. Hotkey switches use the same direct,
verified persistence as Apply. No remote kernel command or model tool was added.

Read-only/native CLI equivalents are `display-profiles.exe --list`, `--current`,
`--save "Name"`, `--preview "Name"`; `--apply "Name"` shows the native
confirmation. `--save "Name" --overwrite`, `--hotkey "Name" 0..12`, `--delete
"Name"` and `--recover` are explicit local actions.
`--apply "Name" --no-confirm` switches directly like Desk; the wrapper supplies
`--apply "Name" --owner PID --no-confirm` so owner-exit protection stays active.

## Offline validation

From the repository root on Windows with PowerShell 7 and VS x64 C++ tools:

```powershell
.\scripts\Build-DeskMonitor.ps1
.\scripts\Test-DeskMonitor.ps1
.\scripts\Build-DisplayProfiles.ps1
.\scripts\Test-DisplayProfiles.ps1
pwsh -NoProfile -Sta -File .\scripts\Test-DeskMenu.ps1 -UiSmoke
.\scripts\Test-DeskModel.ps1
.\scripts\Test-AirPlay.ps1
python -m unittest discover -s .\scripts -p test_desk_review_plan.py
python -m unittest discover -s .\scripts -p test_voice_door.py
python .\scripts\voice_door.py --self-test
.\scripts\Test-PhoneDesk.ps1
```

These checks use synthetic monitor, model, speech and HTTP fixtures, not
model inference or real monitor writes. `Test-DeskModel.ps1 -InstalledLaunchers`
also checks this host's external kit parameter contract without running it.
`Test-DeskMonitor.ps1 -LiveMonitor` is a separate explicit hardware write-and-
restore action. Do not use it for routine PR or RAG-ingestion validation.
`Test-DisplayProfiles.ps1 -Live` explicitly switches and restores real display
layouts. `Test-AirPlay.ps1 -Live` and `Test-DeskMenu.ps1 -UiSmoke -AirPlayLive`
exercise the receiver lifecycle and require it initially stopped; they do not
test discovery or audio playback.
Phone Desk's browser checks use the existing Playwright dependency from
`godbrain_core\skill_lab`; see the phone guide for scoped setup and optional
passive live checks.
