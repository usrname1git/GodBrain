# Native Desk control panel

Run `.\scripts\Show-DeskMenu.ps1` from PowerShell. It returns the caller's
shell and opens a separate hidden STA WinForms host. X hides the panel;
the power glyph quits. Status and Ask use serialized asynchronous workers
instead of blocking the UI. Image status checks port 8871 and identifies
Qwen-Image-2.1 independently of the text/vision service on port 8888.

Status's **Llama :8000** row is the legacy llama-server startup hold, not a
separate Qwen service. **Info** explains the distinction and starts nothing.
**Hold** persists the legacy pause and stops only an identified llama-server
on port 8000; Qwen on 8888 and Qwen-Image on 8871 are unaffected. Its
`hold on` / `hold off` readout describes the startup hold, not listener health.
For text answers, select a text Qwen profile on the Model page, then use
**Status > Model > Start**. Qwen-Image generates images, not text answers.

For a Windows desktop or Start-menu shortcut, target PowerShell 7 explicitly
instead of relying on the `.ps1` file association:

```text
C:\pwsh\pwsh.exe -NoProfile -STA -WindowStyle Hidden -File "<repo>\scripts\Show-DeskMenu.ps1" -ControlPanelHost
```

Replace `<repo>` with the checkout path and set **Start in** to that directory.
Adjust the PowerShell executable path for other installations. Run as the
normal user, not administrator; no execution-policy bypass is needed.
This launches the existing WinForms host directly without occupying another
terminal. It is not a native executable or a Linux/macOS port.

The panel can be resized or maximized; its original size is the minimum.
Status values expand with the window, and Open/Start/Stop plus Galaxy stay
aligned to the right edge. Button captions retain their usable size rather
than becoming stretched bars. At the minimum size, unusually long statuses
still use ellipsis; hover shows the complete status. The Share page's status
summary expands horizontally too.
Ask has no Grok folder/launcher controls. Its reply area extends to a 20-pixel
bottom margin, including when maximized, and preserves response line breaks,
so longer answers can be captured in a screenshot without the old unused footer.
Replies that exceed the available screen space still scroll.
Drag the horizontal divider below the complete-file review checkbox to resize
the prompt and answer panes. The prompt grows with that divider; both panes
retain a usable minimum size when resizing or maximizing the window.

## Model profiles

The Model page groups **Qwen3.8-27B**, **Qwen3-VL-8B**,
**Qwen3.8-27B-Uncensored** and **Qwen3.8-Flash-Next** under **EXL3**,
with equal-sized buttons. **Qwen-Image-2.1** is separate: its diffusion
backend is not EXL3. The 27B name has no text/vision suffix; its existing
Vision tower checkbox controls that optional component.

The Model page saves context tokens, KV-cache precision, MTP, GPU budget,
RAM prefix cache and the optional 27B vision tower to
`logs\desk-model-settings.json`. Save is passive: only the next explicit
Status Start applies a profile. Invalid settings or an incompatible launcher
are reported before stopping the running model.

The installed Qwen kit's launchers must support the options advertised by
`scripts\GodBrain-DeskModel.ps1`. The kit and its weights are external,
not installed or vendored by this panel. The local text kit's
`paper-godbrain\requirements.txt` pins ExLlamaV3 1.6.1 to its matching
PyTorch 2.11.0/CUDA 12.8 Windows wheel and Hub 1.x. Updating this isolated
inference environment does not repair or upgrade the shared Python packages.
The image launcher uses its separate `.venv-isolated`, never shared-site
inheritance. Its Torch/CUDA ABI stays independent of the text kit; see
[Python workload boundaries](python-environments.md) for requirements,
compatible-version limits and rollback.
`Start-QwenVL.ps1` supports the
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

### Flash Next: quality-first hardware-fit profile

Select **Qwen3.8-Flash-Next**, save its controls, then use **Status > Model >
Start**. Selection/Save never starts a model. Flash Next is not the Watch
default. Its launcher, `scripts\Start-QwenFlashNext.ps1`, also works as a
separate manual trial. It reuses the
existing Qwen kit without changing its runner, packages or 27B launcher.
The snapshot is pinned to
`turboderp/Qwen3.8-Flash-Next-exl3` commit
`69e33439ae950f17bcbe95c98f117d80f759ab6d`. Download it with `hf download`
and verify it with `hf cache verify` at that exact revision; the launcher
requires `logs\qfn-model-verification.json` from the completed preparation.
That receipt binds the verified file inventory, sizes and modification times,
plus the config hash. Changed/incomplete snapshots require checksum verification
again; startup does not rehash 85 GB of weights.

```powershell
.\scripts\Start-QwenFlashNext.ps1 -VerifySnapshot
.\scripts\Start-QwenFlashNext.ps1 -CheckOnly
.\scripts\Start-QwenFlashNext.ps1
```

`-VerifySnapshot` runs the pinned Hub checksum verification and atomically
refreshes the receipt without loading a model. The initial download is
`hf download turboderp/Qwen3.8-Flash-Next-exl3 --revision 69e33439ae950f17bcbe95c98f117d80f759ab6d --local-dir C:\nvme\Qwen3.8-Flash-Next-EXL3-3.05bpw --max-workers 2`.
Do not combine verification and `-CheckOnly`.

Defaults are text-only, 16,384 context tokens, **FP16 KV**, MTP off, 432 CPU /
80 GPU experts, eight CPU workers, a 13.5 GiB GPU allocation budget and no
CPU prefix-cache tier. Both PLE and token-embedding rows stream from NVMe;
dynamic hot/cold expert placement keeps the GPU portion useful. These move
or stream the existing weights; they do not remove experts or further quantize
the downloaded 3.05 checkpoint. The trial needs at least
**43 GiB available RAM** and **14.5 GiB free dedicated VRAM** before launch;
these conservative starting gates are not a proof of inference fit. Closing
Brave/other applications can reclaim RAM; the launcher never closes them.
The 4 GiB host-memory reserve stays enabled. Child-only environment settings
cannot change the next normal 27B launch. CS2/manual holds, existing model
processes (including loading) and listeners on 8000/8871/8888 block startup;
the trial never stops another model or clears a hold.

For Flash Next, the RAM-prefix-cache field becomes **CPU experts** with
allowed values 400/416/432/448/464. More CPU experts use more RAM and less
VRAM; the minimum available-RAM gate follows the selected split.
**Quality preset** restores 16K/FP16/432/MTP off without changing the running
model. Explicit KV choices (`fp16`, `8`, `8,4`, `4`) are preserved: no automatic
precision downgrade, context shrink or smaller-checkpoint fallback. MTP is
a speed option, not a quality upgrade. A larger context is capacity, not a
quality score. The existing global reasoning preference remains unchanged.

Desk validates the pinned snapshot, runtime and RAM before stopping an
existing model; the child rechecks all resources after the slot is released.
Desk starts the QFN supervisor hidden. Its bounded launch/failure receipt is
`logs\qfn-last-launch.json`; failures appear in Status and the Model page,
with full details on the live-settings tooltip. Loading is not readiness:
the model must answer its actual `/health` endpoint. A Windows kill-on-close
Job owns the server and CPU workers, including workers surviving server exit.
Desk Stop/model switches and CS2 release that scope; CS2 never resumes it.
QFN holds host-wide, cross-session launch admission from preflight through
Job/child cleanup; a competing launch fails without replacing the owner's
launch status.

The console remains attached for a manual launch; Ctrl+C closes that same
owned scope. Once `/health` is ready, run
`.\scripts\Test-QwenFlashNext.ps1 -Live` in another terminal for one bounded,
thinking-off arithmetic request. It checks the live model identity before sending
anything and never starts/stops a model. A successful preflight is only permission
to attempt the load, not a successful generation. Measure RAM/VRAM peaks, paging, prompt latency
and decode before using `-DraftMode Mtp` (three-token window) or increasing
`-CacheSize` toward 65,536. `-CpuExperts` changes the RAM/VRAM tradeoff and the
minimum RAM gate; no automatic OOM retry or smaller-model fallback is performed.
Without `-Live`, `scripts\Test-QwenFlashNext.ps1` is offline and does not load
CUDA or model weights.

### Text reasoning

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

Kernel text replies keep the server's `reasoning_content` separate from
final-answer `content`. Desk/Galaxy streams show answer tokens and progress
pings while thinking runs, not the reasoning scratchpad. Only answer text
enters continuation history or saved replies; private reasoning still passes
through the existing loop guards. If a completion produces reasoning without
a final answer at the output limit, EXL3 gets **one** fresh thinking-off
answer attempt, capped at 4,096 tokens, with no tools or private reasoning
replayed. Other empty completions and failed recovery return explicit errors.
The receipt reports recovery; the saved preference is unchanged.
Recovery text is buffered until a complete `stop` response is accepted.
A truncated retry fails explicitly and never starts another continuation.
Thinking-enabled EXL3 chat requests allow up to **16,384 output tokens**
for reasoning plus the answer. The installed server then clamps each request
against the **actual fully formatted input**, leaving at least 1,024 tokens
for runtime/speculative overhead. This clamp belongs to the separately
installed, updated EXL3 kit; its backend changes are not bundled in this
repository. Insufficient headroom fails explicitly.
`/health.last_generation` records prompt tokens, requested/effective output,
reserve and context. Missing, invalid or ambiguous model context fails before
reasoning generation. Thinking-off, tool and `/edit` turns keep their existing
ceilings. Ask allows up to ten minutes for the bounded request.
The preallocated cache is unchanged. Text that the server labels as final `content` is not
semantically reclassified or trimmed as supposed reasoning.

### Ask text modes

The visible selector defaults to **Research (read-only)**. **Answer** disables
model tools even with a Path; an explicit leading `No tools` also wins over
the selector. **Research** advertises only reads and enforces read-only
arguments after alias normalization, even when YOLO is active. It cannot
apply `/edit`, write files/registry/ACLs, elevate or change services.
**Fix** retains existing scoped tools, jail, bearer and sovereignty checks;
it does not grant YOLO or elevation. Explicit authenticated operator
`/yolo`, `/verify` and `/reject` commands retain their separate gates.
Images and complete-source review retain their dedicated read-only/generated-image routes.

Research can query service configuration (`run_host`, `exe=sc`, `args=qc SERVICE`)
and inspect a registry key or granted file/folder using `read_local_acl`.
Host reads use the same executable-prefix normalization as the native executor.
Registry reads accept either `args=query "KEY" ...` or `path=KEY` (quoted by
the kernel). Explicit arguments take precedence; a path never converts a
mutating verb into a read. The model schema includes native `reg query`
search examples, and denied read invocations include the accepted syntax.
The native reader returns owner, complete SDDL and ordered DACL entries from
the opened object. It requests only `READ_CONTROL`, checks the resolved target,
rejects remote/SAM/SECURITY targets, and never reads values/content or changes
permissions. Missing/denied objects fail explicitly. ACL metadata is not an
effective-token access check or proof of a writer. Research allows up to seven
tool rounds plus one final-answer round; independent reads can share a round.
A Path used for research is not replaced with a repository-map conclusion.
Desk sends the current Ask text and optional Path, not Copilot's conversation:
private client history is not automatically imported. After an explicit
`index`, authenticated ordinary requests retrieve relevant shared working
research and the target-host snapshot automatically. Published working
context is not verified knowledge.
Research retains up to 32 KiB of complete, distinct observations, including
on Continue. It does not evict earlier facts to fit later reads. Repeated
identical results are deduplicated; a round with no new evidence ends tool
collection. Capacity exhaustion preserves earlier observations and explicitly
marks omitted new evidence before the final answer. Service observations
include the exact invocation so a failed query is not attributed to another service.
`read_local_file` decodes BOM-marked UTF-16LE/BE and UTF-8 before line slicing.
The source-read and decoded-text bounds remain 256 KiB; clipped text is marked,
malformed UTF-16 fails explicitly, and binary files remain rejected.
Research can also
search Microsoft Learn and read an exact documentation URL supplied by the
operator or that request's search. Search terms must come from the operator
question or a fixed public Windows access-control vocabulary, not private
tool output; unsupported terms are omitted with a count and the actual query
in the source receipt. First-party fetches reuse the bounded
HTTPS/allowlisted-host/HTTP-200/no-redirect transport. Text remains an
**untrusted reference**, never an automatically verified claim or proof of
the actual writer on this host. Documentation tools require no paid API.
Large/earlier research results are explicitly omitted rather than cut through
a reference. Ask shows the effective mode, actual model tool attempts and any
answer retry; failed attempts are explicitly marked as incomplete evidence.
Empty, truncated or repetitive native Research drafts get one fresh, tools-off
answer attempt, never a replay of the discarded draft. Failed recovery is an
explicit error rather than an apparently finished partial table.
The same bounded recovery applies when the final streamed reasoning/answer
loops or returns no visible answer. Research emits answer text only after a complete answer is accepted;
progress pings continue while generating, and discarded drafts never stream
into the displayed answer. The saved thinking preference is unchanged.
Failed model requests finalize an existing task as failed rather than leaving it
running. Saved task diagnostics include HTTP status, finish reason and
visible/reasoning byte counts, never private reasoning text.
Receipts are execution metadata, not task verification.
The API field is `tool_mode: "answer"|"research"|"fix"`; omitted mode preserves
legacy clients. A running read-only chain retains its restrictions on Continue.

## Shared working memory and index

Send exactly `index` (or `/index`) after infrastructure changes. It refreshes
the native target-host hardware/capability snapshot without starting a model.
This is not a full-vault RAG rebuild, continuous broadcast, permission grant
or verification. The configured `GODBRAIN_API_TOKEN` is required; ordinary
Desk and Ask-GodBrain requests send it when configured.
Ask-GodBrain accepts only `http://127.0.0.1:8083` (or its `localhost`
alias), always targets that canonical loopback kernel and never follows redirects.

Verified technical RAG remains the manual. Separate Mongo discussion and
research shelves hold untrusted continuity and provisional findings; personal
scope is separate from technical retrieval. The authenticated kernel exposes
`/api/context`, `/api/shelf`, `/api/shelf/schema` and `/api/index`. Discovery is
persisted outside chat, so a fresh integrated client can recall published
research without repeating the history. Unpublished Copilot history is not
magically available.
PowerShell shared-context reads and discussion saves use the same `desk` thread
by default; the shared-memory helper functions still accept an explicit `-ThreadId`.

Prompt excerpts share a bounded budget. Long references cannot crowd out every
later research finding; omitted excerpts/references are labeled, with complete
records still available through the shelf API. A tight discussion budget keeps
the newest turn rather than an older one. Recall is not factual verification:
model interpretations remain untrusted, including after being remembered.

Research-mode file reviews, attachments and vision requests include shared
context before any token planning, then save a bounded untrusted discussion
handoff with source hashes/references. Original attachments are not archived
by that handoff. Oversized prompt/report excerpts are labeled and retain
complete-text SHA-256 references. Failed persistence is explicit, never a
claim that the work was saved or verified. Answer and leading `No tools`
remain memory-free; image diffusion retains its separate path.

`scripts\Invoke-LocalLLM.ps1` provides the same context/continuity to a fresh
PowerShell invocation while keeping the existing custom system prompt,
thinking-off plain-text completion and `tool_choice=none`. It requires an
already-running idle EXL3 model and never starts one. `-NoSharedMemory` keeps
the original stateless behavior; `-Scope personal` uses only the personal
working shelf, not technical RAG. `Invoke-LocalLLM index` needs no model.
This foundation is not an autonomous long-task runner or model-to-model loop.

From the repository root:

```powershell
.\scripts\Invoke-LocalLLM.ps1 index
.\scripts\Invoke-LocalLLM.ps1 'Explain: Get-Process | Where-Object { $_.CPU -gt 10 }'
.\scripts\Invoke-LocalLLM.ps1 'Explain this command' -NoSharedMemory
```

Single-quoted prompts preserve literal `$` variables rather than expanding
them in the calling shell. If an existing profile already defines the
`Invoke-LocalLLM` helper, its short alias is
`Set-Alias -Name aai -Value Invoke-LocalLLM`; reload that profile with
`. $PROFILE` in an existing terminal. These scripts do not install or modify
profiles. Neither the helper nor the alias executes the returned commands.
Shared memory improves continuity, not model accuracy: a stored response is
still untrusted, and a running model is not a qualification result.

Ordinary kernel chat also saves bounded prompt/answer excerpts rather than
overrunning the shelf's 32 KiB limit. Clipped excerpts carry the complete
UTF-8 byte count and Keccak-256 hash; they are not full transcript archives.

## Complete-file review and images

For comparisons, **Add files...** in Ask selects multiple attachments. Files can
also be dropped onto the attachment list; **Paste image** (or Ctrl+V in the list)
adds a clipboard screenshot. Remove detaches selected entries without deleting
the files. Clipboard originals remain under ignored `logs\desk-attachments`.
The optional Path field stays separate: a file there joins the attachments;
a folder is not used or read during attachment analysis.

Attachments use the running text model, with no tools or edits, in Answer or
Research mode. Fix, slash commands and Qwen-Image generation reject attachments
explicitly. Text is read directly as strict UTF-8 or BOM-marked UTF-16.
Screenshots are transcribed by the existing CPU EasyOCR implementation in a
bounded one-shot Python child, without starting the speech listener, using
the vision tower or changing the saved model settings. No downloads occur.
The 180-second OCR deadline includes stdin delivery and output draining;
oversized output fails explicitly and only that child is terminated on failure.
OCR is derived text, not verified visual evidence; non-text pictures still
need the separate vision path described below.

Up to eight files are accepted (1 MiB per text file/extracted text, 10 MiB per
image). Sources receive stable IDs, byte hashes and original/extracted line
numbers. Two bounded text inputs also get a deterministic unified diff. Derived
diffs above one million line pairs or 262144 combined UTF-8 bytes are explicitly
omitted in source metadata; original source coverage is never dropped. The local
tokenizer budgets all sources together; larger inputs use serial source
windows (at most 16 parts) and an explicitly unverified synthesis, not silent truncation.
Every supplied line is covered across parts, which is not a guarantee of
exhaustive semantic comparison. Missing/binary inputs, incomplete generations,
changed sources/model/context and context limits fail explicitly.
`logs\last-attachment-analysis.json` records coverage and a **candidate** report;
attachments and answers are not automatically ingested as Golden Records.
Research-mode bounded handoffs go only to the separate untrusted working shelf.
An output-limit or empty-answer failure gets one fresh, concise thinking-off
recovery; discarded drafts and private reasoning are never replayed. Recovery
and any remaining parts/synthesis use freshly counted thinking-off prompts,
at most 4096 output tokens each, without changing the saved preference.
The answer labels recovery explicitly. The receipt retains attempt finish
reasons, token usage and visible/reasoning byte counts, never private reasoning.
A failed recovery, attempted tools, bad token receipts or changed sources still
fail closed; no truncated report is presented as complete.

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

The Speech/OCR row starts/stops the optional `scripts\voice_door.py` helper
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

Tailscale Start enables unattended mode with `tailscale set --unattended`,
then reconnects with bare `tailscale up`, preserving existing node preferences
including exit-node LAN access. The shared Desk/AFK helper bounds each CLI
process to ten seconds without passing flags to `up`. Its errors
are labeled Tailscale, not CS2; no Steam or game process is required.

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
Completed operation receipts are consumed before any modal error dialog, so a
timer tick cannot repeatedly show the same failure. ClipShare uses the same
consume-before-notify rule.

Process verification reads the executable and creation time through a pinned
query-limited native handle, then checks the current session and user ownership.
It does not depend on WMI exposing `ExecutablePath` or on reading process modules:
those can be hidden when a normal-user Desk inspects an elevated receiver.
This does not grant elevated window-control rights. If Windows refuses an
operation across UAC, Desk reports the failure once; close the receiver from its
own window and start it normally rather than elevating the whole panel.
No global terminal-host or PowerShell elevation settings are changed.

ShairportQt is not a Windows SCM service. No service wrapper, autostart task,
firewall rule, registry change or receiver-setting rewrite is installed.
Closing Desk leaves AirPlay running; it ends at logout unless separately
configured by the operator. Existing tray and receiver/password settings remain
unchanged. Status distinguishes stopped, running without a listener, and the
receiver-reported **ready**, **connected**, **playing** or **paused** state.
The read-only C++ helper `desk-airplay.exe` reads ShairportQt's accessible
connection label and Play/Pause button name. These describe receiver state,
not speaker output: **Pause** means ShairportQt reports playing; **Play** means
it reports paused. A connected receiver without an enabled playback control
shows **connected; playback state unavailable**. Unsupported/localized labels,
inaccessible controls, identity changes and timeouts explicitly show
**receiver state unavailable**, retaining the listener result rather than
guessing. The probe never clicks controls, reads password fields or collects
sender/track metadata. Each inspection is a bounded child process in the
existing asynchronous status worker; a timeout terminates only that probe.
When Qt hides its window to the tray, the helper uses the receiver's PID-owned
IPv4/IPv6 listener and accepted TCP connections instead of its absent UIA tree.
Without a connection it shows **listening; tray**, not a guessed ready/playing
state or a cached Windows media session. With an accepted connection, the unique
`Airplay.Shairport.1.0` Windows media session can report **playing/paused**,
explicitly labelled **Windows media session**. No matching media session shows
**connected; playback state unavailable**; ambiguous sessions fail explicitly.
Status never restores the window or changes playback to obtain a reading.
Build it once with `scripts\Build-DeskAirPlay.ps1` (Visual Studio x64 C++ tools).

End-to-end audio verification still requires a real AirPlay sender streaming known
audio to this receiver and confirmation of playback on the intended Windows
output. An audio session or nonzero meter is useful diagnostic evidence, not
proof of audible delivery. The current row does not persist an audio-verification
receipt or turn a successful listener probe into an audio pass.
`scripts\Test-AirPlay.ps1` runs offline process-identity/status/probe fixtures;
`-ReadOnlyLive` passively inspects an already-running receiver without changing
its window or playback. `-Live` explicitly exercises the installed receiver's
Start/Open/Stop lifecycle and refuses when a receiver is already running.

## ClipShare media links

The Status **ClipShare** row provides Start/Stop. The **Share** rail page adds
**Inbox**, **Library**, **Copy link**, and **Copy login**. These call the sibling
`ClipShare\build\Release\clipshare.exe` (override with
`GODBRAIN_CLIPSHARE_ROOT`); no Python service logic lives in Desk.
Operations use a serialized asynchronous worker. Status checks the native
controller/server identity, listener ownership, fresh heartbeat and authenticated
HTTP readiness, not just a listening port.
When `local\ingress\native-settings.json` exists, Start waits for the media
backend before starting `clipshare-ingress.exe`; Stop closes ingress before
stopping the backend. Status includes the native ingress line. Missing ingress
configuration retains the original media-only behavior. These buttons preserve
the saved DNS-only/public-proxy preference; they never create firewall rules.

ClipShare is a current-user background app supervising pinned Copyparty and
serial CPU FFmpeg imports. Start returns without parking PowerShell. Closing
Desk leaves it running; Stop signals only its verified instances and their owned
child Jobs. Desk does not install a Windows service, logon task, firewall/router
rule, Tailscale Serve change or GPU worker.
Copyparty runtime salts/sessions and SFX extraction use that instance's private
`local\copyparty` and `local\copyparty-cache`, avoiding administrator-created
shared AppData/cache files on normal-user startup. No global directory ACLs or
environment settings are changed. A native-ingress credential failure is still
reported separately and is not disguised as successful public readiness.

Drop local video/audio files into Inbox. Originals remain untouched. Published
H.264/AAC MP4 or MP3 files get seven-day read-only share links; the source library
requires login as `owner` (Copy login copies the generated password).
Copy link selects the latest completed, unexpired share. Links are bearer
access and forwardable. Expiration revokes access, not storage.
Fresh installations default to `http://127.0.0.1:3923` links on this PC only.
Public HTTPS requires separately approved ingress setup, restricted proxy routes
and outside-network verification; Desk preserves that saved configuration.
The native status deliberately reports local readiness only: its external
verification flag is not updated by a previous one-time public test. Desk removes
the repetitive "external URL unverified" boilerplate. If
`local\ingress\public-verification.json` contains a successful external check for
the current public URL, it shows **last verified at YYYY-MM-DD HH:MM UTC**.
Changed template/configuration/Caddy/media-controller hashes add
**(setup changed)**; missing history shows no dated claim, and malformed history
is reported without hiding local readiness. The same presentation is used on
Status, Share and applicable Start/Copy receipts. No external request is made,
no native verification flag is changed, and historical evidence is not rewritten.
A historical pass is not continuous reachability. Verify public HTTPS from outside this
network with disposable synthetic shares, including actual media GET/HEAD,
byte-range seeking and denial after revocation; never send owner credentials
or private media to a public probe. A local TLS pass or expected bare-host 404
does not verify a working external share.
Do not proxy GodBrain's privileged listener for this purpose.
See the sibling project's README for retention, failures and deployment.

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
.\scripts\Build-DeskAirPlay.ps1
.\scripts\Test-AirPlay.ps1
.\scripts\Test-ClipShare.ps1
.\scripts\Test-QwenFlashNext.ps1
.\scripts\Test-KernelReplies.ps1
python -m unittest discover -s .\scripts -p test_desk_review_plan.py
python -m unittest discover -s .\scripts -p test_voice_door.py
python .\scripts\voice_door.py --self-test
.\scripts\Test-PhoneDesk.ps1
```

These checks use synthetic monitor, model, speech and HTTP fixtures, not
model inference or real monitor writes. `Test-DeskModel.ps1 -InstalledLaunchers`
also checks this host's external kit parameter contract without running it.
`Test-KernelReplies.ps1` compiles the SSE parser and actual native generation
loop in a temporary fixture root and drives an isolated loopback mock server.
It is included in the offline Jarvis gate; it does not call a running model
or write the live vault. AirPlay state fixtures need the native helper build
above; `-ReadOnlyLive` is an explicit passive read of an existing receiver.
`Test-DeskMonitor.ps1 -LiveMonitor` is a separate explicit hardware write-and-
restore action. Do not use it for routine PR or RAG-ingestion validation.
`Test-DisplayProfiles.ps1 -Live` explicitly switches and restores real display
layouts. `Test-AirPlay.ps1 -Live` and `Test-DeskMenu.ps1 -UiSmoke -AirPlayLive`
exercise the receiver lifecycle and require it initially stopped; they do not
test discovery or audio playback.
Phone Desk's browser checks use the existing Playwright dependency from
`godbrain_core\skill_lab`; see the phone guide for scoped setup and optional
passive live checks.
