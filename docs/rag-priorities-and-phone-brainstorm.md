# RAG priority and parked phone brainstorm

Recorded 2026-10-15. This is a direction and idea note, not a verified
implementation report or permission to deploy new services.

## Active priority: better evidence, less routine crowning

Improve the quality and freshness of data available to inference autonomously.
The operator should correct concrete failures the system could not resolve,
not manage another abstraction or an ever-growing queue of routine cards.
Routine provenance onboarding, rechecks, retries and bounded recovery are the
system's work. This is the goal, not a report that the runtime already does it.

Prefer evidence-backed maintenance:

- Reuse and strengthen machine-checkable host facts and scoped,
  source-backed documentation checks. Automate only the conclusions those
  checks actually establish; a matching quote is not universal proof that a
  procedure works.
- Recheck source versions and applicability. Changed or invalid evidence
  must not leave obsolete claims silently eligible for inference.
- Extend existing Golden Records instead of generating near-duplicates.
  Preserve immutable sources, provenance and explicit contradictions.
- Onboard legacy provenance automatically wherever a supported source/checker
  can be established. An unmanaged category must not become a permanent manual
  lane, and onboarding must not silently discard the existing manual.
- Keep unproven interpretations, conflicting claims and playbooks that need
  judgment out of verified inference. Pursue bounded automatic evidence
  gathering and recovery first. A deduplicated queue is internal loop state,
  not per-card homework: surface an actionable incident only after safe
  automatic resolution is exhausted or a genuine authority decision is needed.
- Measure supported, current retrieval and operator burden, not card volume,
  model confidence or how often a claim is repeated.

Autonomy does not let a model certify its own interpretation. Unknown or
unsupported results stay explicitly unproven. Existing deployment and protected
host-operation authorization remains separate from routine maintenance.

This prioritizes canonical RAG data maintenance over new phone features and
autonomous self-editing. The evidence/retention and current-skill foundations
are useful groundwork, not proof that general RAG refresh is already solved.
Existing authorization, verification, provenance and C++/Go compatibility
gates remain unchanged. This note does not authorize bulk auto-verification
of Librarian output.

### Implemented foundation, not yet deployed

The isolated evidence foundation rechecks current skill origins and exact
OS-pin applicability across the complete matching corpus. Host observation now
reconciles even with a missing or unchanged disk checkpoint, rejects unavailable
Windows build reads instead of fabricating a pin, and reports reconciliation
or checkpoint failures explicitly. Repeating the same inventory remains
idempotent; it does not bypass applicability/projection repair.

RAG-derived process session references now recheck current canonical status,
identity/version, complete-content hash and applicable live OS pins before
prompt/recall use. Failed or retired origins are withheld explicitly and remain
retryable; ordinary untrusted conversation/operator continuity is separate.
Personal notes do not enter technical prompts. A local cached status cannot
invent verified authority. This closes that cache bypass without adding
automatic verification authority or changing the C++/Go wire contract.
The prompt path also uses a shared, frame-safe 4 KiB evidence budget for
all runners, rather than silently cutting non-llama context at 160 bytes.
Ordinary follow-ups keep current evidence alongside prior chat history.
The optional file pointer cannot displace evidence; clipping is explicit.

The source-only verifier increment closes `/api/truth` assertion authority:
caller interpretations remain candidates; matching checks verify only a
separate canonical observation bound to complete source/probe evidence and a
checker version. Complete document read failures and unacknowledged
ingestion/judgment fail explicitly. Offline counterexamples cover unrelated
prose, incomplete evidence, exact probes, retry identities and the unchanged
C++/Go ingestion contract. This increment is not deployed.

General source/document freshness is still unsolved. Before expanding automatic
verification further, define expiry/renewal, retrieval and cache eligibility,
source/semantic-drift handling and a deduplicated exception path. Do not
automatically crown legacy cards or claim that checked snapshots supply those
broader guarantees.
A failed observation is not proof that the existing corpus is current.
Canonical origin rechecks also cannot detect unsupported interpretations or
semantic drift that has not yet reached the verified record.

## Parked: private phone streaming and interpreter

Status: brainstorm / possible future feature. No implementation or model
download is requested by saving it.

The phone supplies microphone, speaker/headphones and optional visual input;
the Windows PC supplies inference over a private authenticated connection.
A persistent full-duplex session could carry audio in both directions,
text/control events and separately bounded photos or camera frames.
Tailscale could supply private connectivity; it is not itself the media
protocol. PersonaPlex already uses WebSocket; WebRTC is another option.

Possible modes:

- Conversation: start a session, pocket the phone and talk through headphones,
  with interruption support and visual context when requested.
- Two-way interpreter: put the phone on speaker between people using different
  languages. A first phrase-based version could use CPU Whisper, GPU Qwen
  translation and CPU Piper with appropriate target-language voices.

Open constraints include GPU fit and one-slot scheduling, mobile-network
latency/reconnection, iOS background audio, echo cancellation and language
direction. PersonaPlex documents English-to-English speech, not multilingual
translation or OCR. Native iOS audio handling may suit the eventual
background experience better than relying on a browser tab.

Continuous transport need not mean permanent recording. Interpreter mode
would translate, not answer or execute the conversation. Audio, images and
transcripts remain untrusted data; no voice path grants host authority.
The existing read-only Phone Desk remains read-only.

References, not verification of this design:

- [PersonaPlex](https://github.com/NVIDIA/personaplex)
- [PersonaPlex model card](https://huggingface.co/nvidia/personaplex-7b-v1)
- [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)
- [Apple audio guidelines](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioGuidelinesByAppType/AudioGuidelinesByAppType.html)
