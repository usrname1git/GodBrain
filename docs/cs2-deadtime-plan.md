# Reliable dead-time removal

## Goal and scope

First produce shorter, useful **copies** of the archive without losing the
fights the operator wanted. Cinematic editing, music, transitions and highlight
ranking are later. A two-minute recording may contain five useful seconds or
two useful minutes; a fixed keep quota is not a valid solution.

This plan does not establish that the existing model is qualified to sanitize
the archive. Code/schema checks and a successful inference are not visual accuracy.

## Working assumptions

1. Originals and historical diagnostic outputs remain unchanged. Output videos
   go to a separate destination; no in-place trimming or automatic source deletion.
2. Missing evidence is not dead time. KEEP wins a KEEP/DROP conflict, uncovered
   time is explicitly uncertain, and both are retained pending qualification.
3. Gold annotations are evaluation data, not answers for a blind detector.
   Optional hinted runs are diagnostic only.
4. Windows, existing FFmpeg and one local GPU slot remain the environment.
   No paid inference/search service, Node service or agent framework is needed.
5. Old dead-time debug scripts are historical experiments, not maintained
   production components. Do not edit that evidence or wire its silent parse
   failures and fixture-specific exceptions into Desk.
6. A decade of recordings may span CS:GO and different CS2 HUDs/resolutions.
   Inventory those families rather than assuming the six 2023 clips represent
   the whole archive.

## 1. Repair the connected scanner

Files: `scripts\Scan-Cs2Deadtime.ps1`, `scripts\Test-Cs2Deadtime.ps1`,
and the existing Clips action in `scripts\Show-DeskMenu.ps1`.

- Match decorated Gold headings correctly, but exclude per-file answers by
  default. Label hinted runs as ineligible for blind evaluation.
- Require a completed, correct-model response and a single strict JSON object.
  Validate identity, duration, numeric finite bounds and interval shape.
  Invalid/truncated/looping replies are failed attempts, not empty detections.
- Replace ambiguous keyframe-copy timing with accurately sought, independently
  encoded video-only analysis parts, starting at timestamp zero. Preserve the
  known original offset separately. This costs CPU work but makes mapping testable.
- Resolve conflicting KEEP/DROP conservatively, expose unknown coverage, and
  distinguish schema completion from model qualification.
- Bind new cache entries to exact source bytes, instructions, scanner and live
  inference process/configuration identity. A changed or unverifiable source/
  profile is not a cache hit. Runtime restart invalidates this conservative
  first cache; durable qualified model profiles are a later cut.
- Write new versioned receipts/indexes atomically; retain legacy results as
  evidence. Exclude concurrent scanners, preserve per-clip failures and continue
  other clips without reporting failed work as completed.
- Add a local-file input for bounded tests without iCloud downloads.
- Keep Desk bounded to three inputs while the detector is unqualified; do not
  turn migration away from the legacy cache into an unexpected full-archive run.

Acceptance: offline regression tests plus a long-GOP synthetic timing test and
a bounded real-source timing check. These tests qualify the harness, not Qwen.

### Implemented foundation

The connected scanner now implements this stage. Offline regressions cover
strict response failures, annotation isolation, conservative conflict/unknown
handling, source/profile cache changes, runtime replacement and changed rules
during inference, atomic array framing, corrupt-index preservation, exclusive
scanning and continued processing after a failed clip. The media suite checks
three long-GOP color segments and a bounded real recording: declared source
58s/59s must match analysis 0s/1s, with timestamp zero, expected duration and an
unchanged source hash. No model-quality pass is implied.

The reproduced old stream-copy splitter produced 2s/4s/6s files for planned
0s/2s/4s offsets in a six-second source. Independently encoded analysis parts
instead produce the intended 2s/2s/2s and the correct starting content.

New attempts live under `OutDir\runs\<id>` with raw responses and either
`result.json` or `failed.json`. `index-v2.json` is the mutable bound index;
legacy `index.json` and historical experiments are not reused or rewritten.
`complete` means structurally covered intervals, not a qualified detector.
`needs_review` means conflict or unclassified time remains; it is a machine
state for the next qualification/recovery loop, not a demand to inspect every
archive clip. All current results remain `model_qualified=false` and
`sanitized=false`.

With the existing VL model already running and idle:

```powershell
.\scripts\Scan-Cs2Deadtime.ps1 -NativeVideo -InputFile 'C:\Clips\sample.mp4'
```

Default evaluation is blind. `-UseGoldHints` is explicitly diagnostic and sets
`blind_evaluation_eligible=false`. `-Force` bypasses bound cache reuse without
deleting past attempts. The scanner has no finished-video export path yet.
Its JPEG and native-video modes still use sparse samples; the installed
server's sampling/labels, detector accuracy and audio are not qualified by
the extraction tests.

Offline checks, without a model, iCloud or original-video edits:

```powershell
.\scripts\Test-Cs2Deadtime.ps1
.\scripts\Test-Cs2Deadtime.ps1 -Media
.\scripts\Test-Cs2Deadtime.ps1 -Media -RealSource 'C:\Clips\sample.mp4'
```

The optional real source must contain the 58s-60s window. Tests create and
remove only their own temporary fixture directory.

## 2. Establish an honest quality gate

Prepare a source-hashed, playback-checked fixture manifest outside detector
prompts. Preserve the six operator-labelled clips as development fixtures,
correct their disputed boundaries explicitly, and reserve previously unseen
recordings as held-out fixtures. Include tiny/distant fights, instant deaths,
spectating, flashes, round transitions, freeze time, long idle gaps, action at
both clip ends, and recordings that should remain nearly intact.

Report separately:

- Whole-event recall and missed/truncated fights, not merely any-second overlap.
- Unwanted retained seconds and actual removable dead-time duration.
- Onset/ending error, full-white/death/freeze mistakes and uncertainty duration.
- Failed/invalid inference rate, processing speed and retained bytes per source.

The first release gate should have **no observed lost annotated event on the
held-out release set**, with explicit counts, dataset limits and no claim of
universal perfection. Set the dead-time-removal target from measured baseline
results rather than inventing a percentage now. Reject a keep-everything system
as useless even if it has perfect recall.

The loop performs routine checking and bounded retries. Do not make the operator
review every clip; escalate concrete unresolved cases and genuine preference
decisions, not a new annotation chore for the whole archive.

## 3. Qualify detection, then render previews

Compare the repaired baseline with CPU-nominated short windows and detailed
temporal evidence. The existing HUD scout is research worth reusing, not proof:
remove filename-specific exceptions and qualify each supported HUD family.
Use native C++ for new maintained detector/evaluator components where needed,
with FFmpeg as the existing media decoder. Keep orchestration small.

Candidate cues can include ammo changes, local awards, muzzle/action changes
and local audio evidence. They nominate windows; a killfeed or a single scope
image cannot independently certify an event. Preserve pre/post context and
join only genuinely connected action. Qualify the current Qwen before swapping
models; compare alternatives on the same held-out inputs if it fails.

Render preview copies only after defining continuous, half-open edit intervals
and padding. Preserve source audio and account for variable frame rates and
audio/video offsets. Decode-check every output, verify duration/streams and
retain source-to-output segment mappings. A successful encoder exit alone is
not enough.

Acceptance: source-bound detections, playback-checked previews, no zero-length
cuts, correct audio/time mapping, and the same release quality gate after render.

## 4. Run the backlog as a resumable job

Only a qualified profile earns the label `sanitized`. Keep one serial worker
with a durable per-source ledger: discovered, downloaded, analyzed, uncertain/
retryable, rendered, verified or failed. Reuse content hashes and qualified
profile versions; do not identify archive files by time-of-day stems alone.

Preflight remote inventory, disk space and output destination. Use bounded
downloads/scratch retention, CPU/GPU scheduling, pause/cancel and restart recovery.
Never compete with CS2 or another model. A failed clip cannot poison or block
the entire queue; bounded recovery is automatic, unresolved cases stay visible.

Start with a small mixed pilot, then one larger batch. Measure useful seconds
retained, time removed, bytes, throughput and failures before estimating how long
the decade will take. Expand only after both quality and resource limits pass.
Do not silently reprocess the whole archive because a prompt or model changed.

The deliverable is a separate, verified trimmed library plus an auditable
mapping back to originals. Automated editorial polish can follow, but it is
not required to make dead-time removal valuable.
