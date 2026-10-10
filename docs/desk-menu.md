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

The Status page also has a separate **Serve** row. Tailscale Start preserves
an existing private HTTPS mapping to Phone Desk on `127.0.0.1:8085`; with no
Serve configuration it installs that mapping using `serve --bg --https=443`.
An unrelated mapping or Funnel configuration is left unchanged and reported.
Background Serve belongs to the existing Tailscale daemon and resumes with its
service; it is not a second launcher/watchdog. Read-only status polling does not
configure Serve, start Tailscale, or recover the phone backend.

With no configured API key it binds loopback. Setting `X-API-Key` or
`GODBRAIN_API_KEY` makes this helper bind **all IPv4 interfaces**; non-loopback
POSTs then require that key (header or bearer). It is plain HTTP, not a
tailnet-only binding or TLS endpoint. The panel does not create firewall
rules or configure remote exposure. This is separate from the C++ kernel's
`GODBRAIN_API_TOKEN` boundary.

## Dell monitor controls and F9

Build the native helper once with `.\scripts\Build-DeskMonitor.ps1`.
The Monitor page uses User32/Dxva2 directly for the Dell S2522HG: brightness,
contrast and advertised color presets have hardware readback verification.
No DDM installation, SDK or background monitor poller is required.

Dark Stabilizer is a **Cycle (F9)** action beside the static
**Disabled / Enabled level 1-3** legend. The legend is not current status:
this monitor does not expose usable absolute-level readback. Each button/key
press sends one E3=`10` command; no automatic retry, fake counter or queued
busy press. F9 works while Desk is hidden, including before opening Monitor.
An existing owner is reported; exit it and use Claim F9. Quitting unregisters
the hotkey. There are no mouse hooks or additional hotkey services.

See [DDM monitor command map](ddm-monitor-command-map.md) for the exact
encodings, evidence, unsupported F4 absolute interface and source-only tables.

## Offline validation

From the repository root on Windows with PowerShell 7 and VS x64 C++ tools:

```powershell
.\scripts\Build-DeskMonitor.ps1
.\scripts\Test-DeskMonitor.ps1
pwsh -NoProfile -Sta -File .\scripts\Test-DeskMenu.ps1 -UiSmoke
.\scripts\Test-DeskModel.ps1
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
Phone Desk's browser checks use the existing Playwright dependency from
`godbrain_core\skill_lab`; see the phone guide for scoped setup and optional
passive live checks.
