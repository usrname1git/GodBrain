# Phone control: iPhone and Android

The phone does not run the model. It can inspect and operate the Windows PC
through three existing doors: a private read-only web overview, SSH commands,
and RustDesk's interactive desktop. Tailscale gives the phone private
reachability without public SSH, router port-forwarding or an exit node.

## What you can do

| Capability | Phone workflow | Limits |
|---|---|---|
| Model identity/profile, busy state, global VRAM, RustDesk/Tailscale/SSH and core-service overview | Safari/Android browser: Phone Desk through Tailscale Serve | Read-only; Refresh never starts, repairs, restarts or generates. Mongo is service + TCP, not a database transaction test. |
| Start the remote-desktop backend | iOS Run Script Over SSH or an Android key-authenticated SSH client: `scripts\Start-RustDesk.ps1` | Administrative Windows token; installed RustDesk executable; CS2 must be stopped. A GUI window alone is not readiness. |
| Full PC GUI, files and desktop controls | Connect the mobile RustDesk client to the PC after backend success | Existing RustDesk authentication still applies. Opening the client does not connect or start the PC backend. |
| Start only kernel/RAG | SSH: `Start-GodBrain.ps1 -Only kernel` or `-Only rag` | Existing binaries/environment/Mongo and required permissions; these scoped starts leave the model untouched. |
| Diagnostics and local health | SSH: PowerShell service/process/log queries and loopback health URLs | Commands run as the authenticated Windows user, not a restricted web-dashboard role. |
| Ask the local Jarvis or ingest a text source | SSH: `scripts\Ask-GodBrain.ps1`, `scripts\Invoke-Librarian.ps1` | Requires the configured services/mouth; ingestion remains candidate, not verified. |
| Launch/stop a model or run gym work | SSH: existing installed launchers; or the desktop controls through RustDesk | Explicit actions, one GPU slot, required model kit/weights and pause/CS2 gates. Foreground launchers keep the SSH session occupied. |
| Save ideas, read pending/last/edit history, or judge a candidate | Native Shortcut/SSH client using the existing tailnet API | Configured bearer token; judging needs a reason. Not controls on Phone Desk. |
| AFK host recovery with optional gym/model maintenance | Existing desktop Watch controls, accessible through RustDesk | Operator-enabled; host-only default; Limited task service-start rights are not assumed or granted. |
| OCR images, transcribe audio or synthesize speech | Native HTTP Shortcut/client to the optional `:8001` helper | Separate API key for remote POSTs; local assets required. STT/TTS stay CPU; OCR can use an already-idle vision model. Not actions on Phone Desk. |

These are ways to operate the existing Windows runtime, not new permissions.
Administrative SSH is powerful: use keys, protect the phone and do not turn
model output or a web quote into an unattended command.

## One-time prerequisites

Install/sign in to Tailscale on the PC and phone, and authorize the phone in
the tailnet. ACLs must allow the desired services. No exit node is needed.

For SSH actions, configure Windows OpenSSH and key authentication. Examples
here use the configured host port **2222**; use your actual configured port.
Set the remote shell to PowerShell 7, or invoke the installed `pwsh.exe`
explicitly. Do not use Linux `sudo` commands against the Windows host.

Use the protected Windows administrator-key location,
`C:\ProgramData\ssh\administrators_authorized_keys`, for administrator
accounts: Administrators and SYSTEM only. Standard accounts retain their
per-user key file. Keep password authentication disabled and do not expose
TCP 2222 publicly just to make a phone button work.

On iPhone, use Shortcuts' **Run Script Over SSH**, with the PC's private
tailnet address/DNS name, configured port, Windows account and authorized
private key. Leave **Input empty** for the commands below. On Android, use
a key-authenticated SSH client; saved actions depend on that client. Android
does not need Apple's Shortcuts to invoke the same Windows commands.

Private keys stay on the phone. Public keys go in the approved Windows key
file. Do not commit keys, actual tailnet addresses, API tokens, service
receipts or exported secret-bearing shortcuts.

## Read-only Phone Desk

Build/reload the kernel with `GODBRAIN_API_TOKEN` configured. The separate
listener binds **127.0.0.1:8085** inside the existing C++ process. It serves
only the page and `GET/HEAD /api/phone/status`; bodies, body framing, query
parameters and control routes are rejected.

From the repository root, compile with `.\scripts\Build-Kernel.ps1`.
Reload only the kernel with its configured `GODBRAIN_API_TOKEN` using the
existing explicit Stop/Start controls or `Start-GodBrain.ps1 -Only kernel`
after the old kernel has stopped. A build does not restart the running kernel;
the HTML page is loaded at boot. RAG, Mongo and model setup are unchanged.

Before configuring Serve, inspect `serve status`. If no mapping exists,
configure once on the PC:

```powershell
& 'C:\Program Files\Tailscale\tailscale.exe' serve --bg --https=443 http://127.0.0.1:8085
& 'C:\Program Files\Tailscale\tailscale.exe' serve status
```

If HTTPS/Serve is not enabled, follow the owner consent URL printed by
Tailscale. Enable HTTPS and **leave Funnel off**, then rerun if necessary.
Certificate DNS names enter public certificate-transparency logs; the page
remains private. Do not replace unrelated Serve handlers or use `serve reset`.
Desk Status now shows **Serve** separately from the Tailscale service: private
background HTTPS to `:8085`, backend down, tailnet offline, missing mapping
or a query error. Explicit Tailscale Start verifies an existing private mapping;
only an entirely empty configuration is initialized. Conflicting mappings and
Funnel are reported rather than replaced. Status polling never configures Serve.
The CLI's valid JSON `null` also means unconfigured; empty, malformed or
non-object/non-null output is an error, never permission to configure.
`--bg` stores the mapping in the existing daemon, so it resumes when the
Tailscale service starts. No second watcher is needed. This does not change
the service startup type or override a manual Stop/CS2 hold.

Open the printed HTTPS URL with phone Tailscale connected:

1. **iPhone:** Safari, Share, Add to Home Screen.
2. **Android:** open in the browser and bookmark it or use Add to Home Screen.

The page refreshes every ten seconds while visible, uses a short server
cache and clearly marks invalid/failed/stale data. There are no Start,
Stop, Repair or Generate buttons. The exact untagged device-owner identity
from Serve is checked; shared users are denied. No bearer is embedded in
HTML, URLs or browser storage. The kernel authenticates the live TCP peer as
the installed SYSTEM-owned Tailscale service or its immediate SYSTEM worker
before trusting identity headers. Other direct loopback clients require the
bearer; copying the owner's header does not grant access. If the service,
worker identity or connection ownership cannot be verified, proxy access is
denied (no permissive fallback). If owner lookup fails at kernel boot, Serve
access remains closed until identity is available and the kernel is explicitly
reloaded.

`scripts\Test-PhoneDesk.ps1 -ServeTransport` checks direct-header rejection
and a real HTTPS proxy request using a temporary, random Serve path. It
removes only that test handler and verifies existing Serve configuration is
unchanged; it never restarts the running kernel or model.

**Never proxy the whole `:8083` listener through Serve.** It contains chat
and legacy status/brief routes that can start a paused model. The read-only
listener does not call them. Do not enable public Funnel.

## Remote OCR and CPU speech

The optional helper is `scripts\voice_door.py`, port **8001**. This is a
different API from the kernel and the private HTTPS dashboard. Its POST key is
`X-API-Key` (environment variable), falling back to `GODBRAIN_API_KEY`.
**`GODBRAIN_API_TOKEN` is the kernel token, not the speech key.**

### Local dependencies and weights

Use a local Python environment with `faster-whisper`, `piper-tts`, `easyocr`,
Pillow and NumPy. If not already installed, install them in that environment:

```powershell
python -m pip install faster-whisper piper-tts easyocr Pillow numpy
```

Activate that environment before opening Desk, or launch the helper explicitly
with its Python executable. Model assets must be provisioned locally in advance;
health checks never download or load them. EasyOCR downloads are disabled.

| Component | Required local assets | Directory |
|---|---|---|
| STT | faster-whisper-compatible `model.bin`, `config.json`, `tokenizer.json`, matching preprocessor assets | `GODBRAIN_WHISPER_DIR`; default `C:\nvme\faster-whisper-large-v3` |
| TTS | `en_US-lessac-medium.onnx` and `.onnx.json` | `GODBRAIN_PIPER_VOICES_DIR`; default `C:\nvme\piper-voices` |
| CPU OCR | `craft_mlt_25k.pth`, `latin_g2.pth` | EasyOCR's `model` folder under `EASYOCR_MODULE_PATH`, then `MODULE_PATH`, then `%USERPROFILE%\.EasyOCR` |

Optional directory overrides can be set in the helper's environment before
startup. Keep local paths and weights out of commits. CPU OCR uses Pillow,
including EXIF orientation, then contiguous BGR pixels for EasyOCR; it does
not depend on `skimage` filename plugins.
STT availability and initialization require the local tokenizer as well as
the model/config files. Incomplete assets fail before model initialization,
and the loader uses local-files-only mode rather than fetching missing weights.

### Configure authentication before starting

Keep an existing key when present; replacing it invalidates saved Shortcuts.
For a first setup only, generate a key locally and set it without printing it:

```powershell
$key = [Environment]::GetEnvironmentVariable('X-API-Key', 'User')
if (-not $key) {
    $key = [Environment]::GetEnvironmentVariable('GODBRAIN_API_KEY', 'User')
}
if (-not $key) {
    $key = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    [Environment]::SetEnvironmentVariable('X-API-Key', $key, 'User')
}
[Environment]::SetEnvironmentVariable('X-API-Key', $key, 'Process')
Set-Clipboard $key
Remove-Variable key
```

Paste the key only into the native Shortcut's **X-API-Key header value** through
a trusted channel. Clipboard contents are sensitive; clear them after transfer.
Do not export/publish the populated Shortcut, log the key, or put it in a URL.
For an already-running helper, its startup environment is authoritative:
changing the user environment requires restarting that helper before the new
value takes effect. Open a fresh Desk process after changing its environment.

Use Desk Status **STT/TTS Start**, or from the repository root:

```powershell
python .\scripts\voice_door.py --repo . --port 8001
```

The explicit CLI stays in the foreground; Desk uses its existing hidden child.
Without a key the helper binds loopback. With a key it binds **all IPv4
interfaces**, not only Tailscale. Remote POSTs require the key or equivalent
bearer; loopback calls are trusted locally. `/health` is unauthenticated.
The `bind: "tailnet"` health label does not prove interface-only exposure.
This helper uses plain HTTP; Tailscale encrypts transport when addressed through
the tailnet. Restrict inbound TCP 8001 to the intended Tailscale interface/peers
using your existing firewall and tailnet ACL policy. Do not expose it publicly,
forward it through your router or assume the key replaces firewall policy.
Neither Desk nor this helper installs firewall rules or changes Tailscale ACLs.

### iOS Shortcuts: exact request and result wiring

Replace `<PC_TAILNET_IP>` with your own PC's private address from Tailscale,
not an address copied from someone else's screenshot.

| Shortcut | Request actions | Result actions |
|---|---|---|
| Health | Get Contents of URL: `http://<PC_TAILNET_IP>:8001/health`, GET | Show Result / Quick Look on Contents of URL |
| Remote OCR | Receive one image from Share Sheet; Convert **Shortcut Input** to JPEG; URL `http://<PC_TAILNET_IP>:8001/ocr`; Get Contents of URL, POST, header `X-API-Key`, body **File**, value **Converted Image** | Get Dictionary Value `text` in Contents of URL; Show Result |
| STT | Record Audio; URL `http://<PC_TAILNET_IP>:8001/v1/audio/transcriptions?language=sv` (or `en`); POST, header `X-API-Key`, body **File**, value **Recorded Audio** | Get Dictionary Value `text`; Show Result |
| TTS | Text to speak; URL `http://<PC_TAILNET_IP>:8001/v1/audio/speech`; POST, header `X-API-Key`, body **JSON**, field `input` = text; optional `voice` = installed voice name | Play Sound / Quick Look on returned WAV |

OCR and STT accept raw-file uploads; multipart Form is optional, not required.
If using Form, the literal key must be `file` and its value the actual file.
JPEG conversion should receive an image, not the URL, a dictionary or an empty
Shortcut Input. Audio can be WAV or M4A; TTS expects JSON text, not audio.
TTS input is bounded to 4,000 characters. Android HTTP clients use the same
endpoints, headers and payloads; their UI wiring is client-specific.

### Status and troubleshooting

Phone Desk's **Speech / OCR** cards poll only local `/health.components`:
`available` means dependency/weight files exist, not verified inference;
`ready` means the last component request succeeded; `unready` shows missing
assets or a backend error. Invalid/legacy health is unknown, and a stopped helper
is stopped. Runtime request state resets when the helper restarts. A new
successful request clears that component's backend error. Invalid image input
gets HTTP 400 and does not label the CPU backend broken.
Public health reports only a generic backend failure and its exception class,
not raw stderr, local paths or request details. The authenticated failed POST
response retains the bounded diagnostic error; do not share it without redaction.

OCR's `engine` field reports `cpu` or `qwen`. The top-level health `ocr` field
is the saved preference, not proof the tower is running. Qwen OCR uses only an
already-running explicitly idle vision tower; an unavailable/busy tower falls
back to CPU with a note. The dashboard never generates or starts a model.

| Symptom | Check before changing the Shortcut |
|---|---|
| Health works, POST fails or times out | GET health requires no key. Confirm the POST header is the exact speech key from the helper's startup environment; it is not the kernel token. |
| HTTP 401 / log says `POST /ocr rejected` | Authentication failed before OCR. Replace only the header value; changing File to Form cannot fix a key mismatch. |
| HTTP 400 / zero-byte upload | Make sure File points to the conversion/recording output and the Shortcut was given input. |
| HTTP 503 / Not ready card | Read the component detail; verify local assets and dependencies. Missing weights never trigger an automatic download. |
| Request finishes, nothing appears | OCR/STT return JSON: extract `text` and display it. TTS returns WAV: play/preview it. |
| No `POST /ocr` log entry | Check listener, phone Tailscale connection, PC address, firewall and ACL reachability before blaming inference. |

Inspect `logs\voice-door.log` locally for path, upload size/type and rejection
markers. It does not log payloads or keys. Share only redacted diagnostics.
The known-good raw-file OCR flow has been exercised from an iPhone; STT/TTS
have CPU HTTP fixtures and host-side requests, not a claimed device-side result.
Network speed, model task quality and future mobile routes remain separate
from request/authorization correctness.

## RustDesk: one command, then open the client

Phone Desk observes SCM state and the installed service's live server child;
it does not run RustDesk's administrator-only option query. If the kernel cannot
inspect the server, the card keeps **running** and explains the unavailable
observation instead of hiding known service state or claiming **ready**.
An observed server is not an end-to-end remote connection test. Phone Desk's
Tailscale transport authentication still requires the strict process-owner check.

The remote command is the same on either phone platform:

```powershell
& "$env:USERPROFILE\Documents\GitHub\GodBrain\scripts\Start-RustDesk.ps1"
```

Adjust the repository path if installed elsewhere. The script explicitly
starts the backend and, when the already-installed RustDesk application's
SCM entry is missing, restores only that entry as LocalSystem/Manual.
Existing startup settings are preserved. It avoids the native installer's
logon shortcut and image-name process kills, reads/clears only `stop-service`
when necessary, and requires the running SYSTEM-owned `--server` child.
It does not configure an unattended-access password, download RustDesk,
change firewall/service ACLs, or start models/Watch/gym.

For an iOS Shortcut, after Run Script Over SSH:

1. If the result contains **`RustDesk remote-desktop service ready.`**, use
   Open App, RustDesk, then select the saved PC.
2. Otherwise use Show Result.

Keep Open App **inside the success branch**, not after End If. In an Android
SSH client, require successful command completion and that readiness receipt
before connecting the RustDesk app. A non-administrative session fails
explicitly; there is no remote UAC prompt or GUI-only success fallback.

## Other copyable SSH actions

These execute **on the PC** under the authenticated account:

```powershell
$repo = Join-Path $env:USERPROFILE 'Documents\GitHub\GodBrain'

# Read-only diagnostics; no model startup.
Get-Service -Name sshd,Tailscale,RustDesk,MongoDB
Get-Content -LiteralPath (Join-Path $repo 'logs\last-heal.txt') -Tail 20
Invoke-RestMethod 'http://127.0.0.1:8888/health' -TimeoutSec 3

# Explicit scoped listener recovery, without launching a model.
& (Join-Path $repo 'Start-GodBrain.ps1') -Only kernel
# Or: -Only rag. Add -KeepPause to skip a listener with an existing Stop hold.

# Explicit model work, not passive status:
& (Join-Path $repo 'scripts\Ask-GodBrain.ps1') 'Explain this error'
& (Join-Path $repo 'scripts\Invoke-Librarian.ps1') -Text 'A source to extract'
```

Use one action per saved button, not this entire block as an automatic
repair cocktail. Unavailable services/health endpoints are failures, not
proof a recovery succeeded. The starters leave their own logs/receipts;
verify the intended listener afterward.

Model launchers and continuous training can run in the foreground. Do not
assume closing a phone SSH client creates a durable Windows background job.
Use existing desktop/scheduled-task doors for persistent work, with their
actual permissions, rather than inventing a second watcher or elevated task.
Launching a Windows GUI from an SSH session also does not guarantee it
appears in the logged-in desktop; use RustDesk for the interactive panel.

After CS2, desktop Model, Gym, and Watch Start, and `Watch-GodBrain.ps1 -Resume`,
clear the hold and re-enable only an installed `GodBrainLogon` task. That enable
does not run Logon, start a model, or restore Watch or the gym tasks. Watch
Start then enables and runs only `GodBrainWatch`. It does not re-enable legacy
gym, model, or Creation Lab tasks. Merely clearing the CS2 hold starts nothing
and enables nothing. **Mouth Stop** targets only identity-rechecked legacy
`llama-server --port 8000`; other llama ports and the desk's `:8888` model remain.
CS2 shutdown repeats launcher and model censuses before declaring suspension,
so a late starter cannot survive merely because its maintenance parent exited.
Heal records `start:<service>` only after a requested start is observed Running;
permission failures, missing services and readiness timeouts are not successes.

## Native Shortcut API (separate from Phone Desk)

The authenticated tailnet listener remains on the PC's private address,
port `8083`. Every route there requires
`Authorization: Bearer <YOUR_PRIVATE_API_TOKEN>`, including GETs. Native
iOS Get Contents of URL actions or an Android HTTP client can use it;
Tailscale encrypts the tailnet transport. Do not put the token in a browser
URL or publish an exported shortcut.

Useful existing reads include `/api/last`, `/api/pending`, `/api/last-edit`,
`/api/events`, `/api/chain` and `/api/heal`. Prefer Phone Desk for passive
service polling; legacy `/api/status` and `/api/brief` can start llama.

An idea button can POST JSON `{"text":"My note","sector":"idea"}` to
`http://<PC_TAILNET_IP>:8083/api/remember`. It creates a **candidate**, never
an automatic verified fact. `/api/judge` requires the selected stable ID,
`verified`/`rejected` status and a reason. `/api/librarian` invokes the GPU
mouth and respects its availability/busy gates. Chat generation is not
exposed on this listener; call the loopback chat door via explicit SSH.

## Recovery limits and evidence

Phone Desk depends on the kernel and Tailscale. SSH can recover a dead
kernel when sshd and the network path still work; it cannot recover its own
dead SSH transport. Neither a domain name nor an exit node makes an offline
PC reachable. Independent outbound recovery and health-aware Ethernet/Wi-Fi
failover are separate work, not features claimed here.

CS2 explicitly disconnects Tailscale and holds automation for manual resume.
Starting it remotely can therefore end the phone's connection. Nothing
automatically resumes after the game.

Source-level/fixture tests and live Windows desktop checks cover the launchers,
read-only status, mobile viewports, stale/error states, owner/bearer gates and
unchanged service/model identities during refresh. Private Serve HTTPS has
been exercised on the running host without a browser token. These do not
claim a physical iPhone or Android end-to-end test, nor prove the Limited AFK
task has service-start rights.

Scoped checks: `scripts\Test-PhoneDesk.ps1` (`-Live` for passive host checks),
`scripts\Test-RustDeskShortcut.ps1`, `scripts\Test-DeskMenu.ps1`,
`scripts\Test-Cs2Controls.ps1`, `scripts\Test-AfkWatch.ps1`.
For speech/OCR, run `python -B -m unittest discover -s .\scripts -p test_voice_door.py`
and `python -B .\scripts\voice_door.py --self-test` in the configured Python
environment. Native Phone Desk checks require VS x64 C++ tools; browser
checks reuse the pinned Playwright dependency in `godbrain_core\skill_lab`
(`npm ci --prefix .\godbrain_core\skill_lab` if it is not installed) and an
installed Brave/Edge browser on Windows. These offline checks do not perform
model inference, change Serve or write to Mongo. `-Live` is opt-in and passive;
`-ServeTransport` is a separate explicit temporary-mapping integration check.
