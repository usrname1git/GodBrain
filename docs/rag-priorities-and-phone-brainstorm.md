# RAG priority and parked phone brainstorm

Recorded 2026-10-15. This is a direction and idea note, not a verified
implementation report or permission to deploy new services.

## Active priority: better evidence, less routine crowning

Improve the quality and freshness of data available to inference. The goal is
for the operator to judge meaningful exceptions, not manually crown an
ever-growing queue of routine cards.

Prefer evidence-backed maintenance:

- Reuse and strengthen machine-checkable host facts and scoped,
  source-backed documentation checks. Automate only the conclusions those
  checks actually establish; a matching quote is not universal proof that a
  procedure works.
- Recheck source versions and applicability. Changed or invalid evidence
  must not leave obsolete claims silently eligible for inference.
- Extend existing Golden Records instead of generating near-duplicates.
  Preserve immutable sources, provenance and explicit contradictions.
- Keep unproven interpretations, conflicting claims and playbooks that need
  judgment out of verified inference. Surface a bounded, useful exception
  queue rather than transferring the entire ingestion workload to the operator.
- Measure supported, current retrieval and operator burden, not card volume,
  model confidence or how often a claim is repeated.

This prioritizes canonical RAG data maintenance over new phone features and
autonomous self-editing. The evidence/retention and current-skill foundations
are useful groundwork, not proof that general RAG refresh is already solved.
Existing authorization, verification, provenance and C++/Go compatibility
gates remain unchanged. This note does not authorize bulk auto-verification
of Librarian output.

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
