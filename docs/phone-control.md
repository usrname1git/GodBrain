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

Configure once on the PC:

```powershell
& 'C:\Program Files\Tailscale\tailscale.exe' serve --bg --yes http://127.0.0.1:8085
& 'C:\Program Files\Tailscale\tailscale.exe' serve status
```

If HTTPS/Serve is not enabled, follow the owner consent URL printed by
Tailscale. Enable HTTPS and **leave Funnel off**, then rerun if necessary.
Certificate DNS names enter public certificate-transparency logs; the page
remains private. Do not replace unrelated Serve handlers or use `serve reset`.

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

After CS2, explicitly selecting desktop **Watch Start** re-enables installed
`GodBrainLogon` and `GodBrainWatch`, then runs the host Watch tick. It does not
re-enable legacy gym, model or Creation Lab tasks. Merely clearing the CS2 hold
starts nothing. **Mouth Stop** targets only identity-rechecked legacy
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
