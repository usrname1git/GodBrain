# Frontend University (browser-qualified)

This is not your home basement gym with some random drills. It is a **mastery
ladder**: prerequisites unlock the next exam, not a Swedish calendar. Cycle 1
is the product-site path (capstone once). Cycle 2 is application craft
(settings, lists, catalog, registration, keyboard dialogs). Cycle 3 is the
**God exam**: client routing, loading/error/empty/ready data, error-boundary
recovery, a large keyed list, then one workbench that must pass all four.
Cycle 4 is the **visual God exam**: a seeded visualSystem (the painted canvas)
must show up in computed styles; Inter/system-ui/Tailwind purple and a
three-equal-card row fail. Marketing-site reskins do not pass God. A C/C++
Carmack track is a later gym with its own verifiers. GPT and Grok staffed the path; Qwen
(`qwen3.8-27b-exl3-3.5bpw` on `:8888`) is the learner. A failed attempt is
normal coursework, not an approval prompt.
**The operator does not review web code or `/verify` individual attempts.**

The loop is still one node: read docs, generate against a fixture, compile,
exercise it in a clean browser, feed failures back, repair, retain working
examples. The university is the curriculum and the scoreboard. The gym is
the runner.

House frontend default is the React family: **Next.js for public sites**
(server-rendered pages), **Vite SPA for apps in the browser**. That is the
current curriculum, not a claim that every website on earth is React.
Later tracks (SRE diagnose loops, other C++-adjacent practice) can share this
harness; they are not this folder's job until a named GO. Do not add Svelte/Vue
as a second gym just because they are not crap.

This gym qualifies narrowly scoped frontend examples from machine evidence.
Registry edits, AppX internals, networking repairs, sovereignty decisions and
other host claims remain outside it. It does not change the privileged kernel,
Alexandria's ingestion protocol, or its global skill-promotion authorization.

## Run

Node 22.13+ with the built-in SQLite module is required. Install the pinned
dependencies once from the repository root:

```powershell
npm ci --prefix .\godbrain_core\skill_lab --ignore-scripts --no-audit --no-fund
.\scripts\Invoke-FrontendGym.ps1 -Command tasks
.\scripts\Invoke-FrontendGym.ps1 -Continuous
```

The loop uses an already-running local OpenAI endpoint, preferring `:8888`,
then `:8000`. It never downloads weights, starts a competing model, or touches a
cloud inference service. `-WithMouth` is the desk llama only: resume
`Start-LlamaServer.ps1`, run, then `Stop-LlamaServer.ps1` so Watch does not
leave Gemma parked. The gym mouth on `:8888` is `qwen3.8-27b-exl3-3.5bpw` via `Start-PaperQwen.ps1` (historical filename). Set `-Endpoint` and `-Model` to select a local runner.
Literal loopback addresses only; optional authentication is supplied through
`GODBRAIN_GYM_TOKEN`, never a command-line token. Browser discovery uses a
separate headless Chromium/Brave/Edge instance, not the operator's profile.
Use `-Browser` for an explicit executable.

```powershell
# Two exercise rounds. Each round allows up to four attempts before rotating.
.\scripts\Invoke-FrontendGym.ps1 -Rounds 2
.\scripts\Invoke-FrontendGym.ps1 -Rounds 2 -WithMouth
# Gemma: unpause :8000 for the run, pause after. Not Qwen.

# These controls do not use the GPU.
.\scripts\Invoke-FrontendGym.ps1 -Command status -Json
.\scripts\Invoke-FrontendGym.ps1 -Command lessons
.\scripts\Invoke-FrontendGym.ps1 -Command objectives
.\scripts\Invoke-FrontendGym.ps1 -Command stop

# The same invocation resumes an interrupted exercise and its feedback.
.\scripts\Invoke-FrontendGym.ps1 -Continuous
```

Overnight keep-alive (Qwen `:8888` + gym worker, one GPU slot, honors CS2/pause):

```powershell
.\scripts\Watch-FrontendGymOvernight.ps1
```

The command runs in the foreground. Leave that terminal/session running for
continuous practice; this does not install a scheduled task or startup service.
Completion requests use bounded OpenAI event streams so stopping can disconnect
an active generation, including runners whose non-streaming route cannot cancel.
An unavailable model is reported and retried in continuous mode. A finite run
fails explicitly instead. Transient browser infrastructure failures retry the
same source without spending another model attempt or awarding a false pass.
CS2's existing pause/resume gate is consulted before
each attempt; the desk mouth's explicit pause is also honored when using `:8000`.
The practice loop itself never kills or restarts the model server.

## Live dashboard and Creation Gallery

Qwen (the learner) is `http://127.0.0.1:8888/v1`. That is generate.
Continuous runs also serve a read-only dashboard on
`http://127.0.0.1:4177`. That is the scoreboard, not a second mouth. It shows the current phase, current-session counters,
recent trusted-curriculum mastery, current-session verifier failures,
tutor hypotheses, generated-source reuse, infrastructure errors, active
objectives, and recent events. Internal objective IDs and completed queue
entries stay out of the mastery panel; their durable results remain available
through campaigns and the gallery.
The Creation Gallery shows the latest passing high-quality creation for each
named curriculum skill plus successful standalone custom work. Basic drill
repetitions, failed generations, internal objective IDs, and concepts already
shown in the campaign alternatives section stay out of the gallery without
deleting their audit evidence. Previews open inside a sandboxed, script-only
iframe, or **OPEN IN NEW TAB** (`/preview/<runId>`) for a full-page look.
Learner code cannot access the dashboard origin, host files, model
endpoint, or arbitrary network resources.

The dashboard is part of the existing gym worker, not a second backend or
agent. It binds only to literal loopback. `-DashboardPort` changes the port;
`-NoDashboard` disables it for test or batch runs.

### Custom training objectives

The dashboard can queue two kinds of requests:

- **Explore:** a free-form frontend such as an AppGraph-inspired architecture
  workspace. It receives generic browser safety, rendering, responsive
  screenshot and transfer-fixture checks. A pass appears in the gallery but
  does not become a reusable qualified lesson.
- **Qualify:** a style/product request layered onto one of the existing trusted
  functional contracts. The model may change the presentation, but the
  protected browser evaluator still supplies the requirements and verdict.
  Passing both input variants may retain a scoped lesson.

The model never writes its own acceptance test. Reference URLs are prompt
inspiration only; repositories are not cloned, installed, imported, or
executed by this path. Custom requests persist in `objectives.json` and resume
after worker or model restarts.

### Mastery-aware curriculum

Continuous mode does not round-robin mastered drills forever. The scheduler
uses each contract's latest 40 verdicts and distinct passing source hashes:

- fewer than 20 recent verdicts is `learning`;
- a weaker rolling window is `improving`;
- at least 95% passes across 20+ recent verdicts with two distinct passing
  implementations is `mastered`.

The active Frontend University course receives priority until it is mastered.
Outside the university, new and improving marketing-site contracts outrank
legacy drills. Mastered work moves to sparse regression sampling, while a weak
legacy contract is bounded to targeted maintenance rather than monopolizing the
GPU. The broad curriculum covers product-site architecture, responsive
navigation, lifecycle and feature exploration, pricing/demo conversion, and an
integrated event-platform showcase.

### Self-expanding frontend university

The React-first university is a durable prerequisite graph above the original
quality contracts. It begins with typed component composition and responsive
CSS, then opens accessibility, derived state, form UX, design systems, and
information architecture. Level 3 is **split on purpose**: compose typed
navigation with a conversion form (`responsive-site-navigation-v1` plus
`form`/`aria-invalid`), then compose lifecycle exploration with a form
(`feature-lifecycle-explorer-v1` plus form). The four-suite event-platform
showcase is the **capstone**, not a meat grinder taped onto L3. Responsive
product-system CSS and the typed capstone close the degree. Each course
extends an existing protected browser contract and is validated through
`verifier-dsl.mjs`; generated course data cannot contain or execute JavaScript
assertions.

Courses may use `App.tsx` as well as `App.jsx`. TypeScript courses require an
explicit props type and reject `any`/`unknown` escapes before compilation. The
same browser contract still runs against independent practice and transfer
fixtures. A course is mastered only after the rolling evidence threshold is
met, at which point its prerequisites unlock the next course.

After the fixed degree path is mastered, the factory continuously creates new
versioned capstone studios across rotating product contexts and visual
directions. Old mastered capstone metadata is compacted into an archive count so
the university can continue without unbounded ledger growth. Use
`.\scripts\Invoke-FrontendGym.ps1 -Command university` or the dashboard's
**Frontend University** panel to inspect the current frontier.

The protected browser evaluator checks more than rendering: semantic landmarks,
heading and CTA hierarchy, substantial non-placeholder content, unsupported
business claims, typography scale, spacing, tonal depth, mobile composition,
navigation behavior, seeded feature exploration, plan comparison and form
validation. Qwen cannot edit those checks.

### Frontend Coach campaigns

The dashboard's **Frontend Coach** accepts a client brief: project name, site
type, pages, features, brand direction and an optional style reference. The
coach deterministically maps that brief onto available trusted verifier
contracts and queues one Qualify objective per required capability. It does not
ask the model which tests should count.

After every capability either passes or reaches its bounded attempt limit, the
coach builds the site in resumable stages. A bounded, compact shell establishes
the complete navigation and requested sections; a second integration/polish
stage starts from that browser-qualified source instead of regenerating from
scratch. Repeated shell failure triggers one larger recovery attempt rather than
blindly repeating the same strategy. If optional polish exhausts its attempts,
the qualified shell remains available as `delivered_limited`.

The dashboard persists capability outcomes as they arrive and distinguishes
qualified, limited, running and queued work. Campaign creation is deliberately
pointer-only: Enter and Ctrl+Enter never submit the coach form, and duplicate
active project names are rejected. The integrated build receives generic
browser, isolation, responsive screenshot and rendering evidence; it is not
misrepresented as fully production-qualified until dedicated end-to-end
contracts exist for that site class.

Campaigns persist in `campaigns.json`. Worker, model, or watchdog restarts resume
the objective queue and advance the campaign without losing completed evidence.
Terminal campaigns remain durable but are collapsed under **Completed / archived
campaigns** rather than occupying the active campaign workspace. Completed
alternative sets keep their rerun control in that section.

**Pause & save** writes `training-pause.json` and lets the in-flight generate
finish, then sleeps the loop. Qwen stays warm. **Pause, save & stop Qwen**
arms the same pause and the watchdog stops `:8888` only after gym is idle
(not mid-CUDA). **AUTOPLAY OFF** is YouTube-style: after evaluate (or a
parse-fail with no evaluate), the worker waits instead of starting the next
generate. Resume continues the persisted attempt. CS2 sleep still stops Qwen
when the gym is idle.

Blocked client campaigns can be promoted into a four-direction alternative set.
Each alternative keeps the trusted, browser-proven event-platform interaction
scaffold and asks the learner for a bounded CSS visual system under the complete
showcase contract. This spends the local model's limited output budget on
composition and design instead of repeatedly regenerating interaction
boilerplate. The coach records source and computed visual fingerprints, retries
one duplicate or failed direction, and exposes passing concepts together under
**Alternative concepts**. Current Trippus directions are Nordic editorial,
product-led interactive, enterprise trust, and event-experience storytelling.
Completed or limited sets can be rerun from the campaign card. A rerun creates a
new versioned set of four objectives while retaining the preceding set as
bounded campaign history.

## What counts as learning

The protected curriculum contains product-shaped exercises with varying input
data. The learner can replace only `App.jsx` and `styles.css`. It cannot edit
the evaluator, tests, dependencies, package scripts, or host files.

The evaluator bundles with trusted esbuild configuration and runs browser
interactions, state transitions, narrow-screen/layout and accessibility-related
checks. It captures screenshots and structured failures. A source artifact must
pass both a practice input and a separate transfer input before it becomes a
reusable gym lesson. A build alone or a model saying "passed" is insufficient.

The second input checks transfer within an exercise, not universal frontend
mastery. Screenshots are evidence for inspection, not an automatic certificate
of visual taste. This is not a comprehensive accessibility or security audit,
an SSR course, or a guarantee of production readiness.

Lessons retain exact source, SHA-256, model identity, seeds, and browser receipts.
The receipt is also bound to the evaluator/curriculum sources and dependency
lockfile. Changing that evaluator fingerprint prevents old lessons being used
as current evidence. A subsequent failure of the same source marks its lesson
stale. The gym automatically retrieves matching tested examples on later
attempts, including when a different model takes the learner role.

This is external memory and practice, **not weight training**. It does not
fine-tune Qwen or label arbitrary model-written explanations as verified facts.
Gym lessons stay in the local library, automatically usable by this loop; they
are not silently promoted into Alexandria's globally verified host manual.

## Models teaching models

After two failed attempts, the default learner acts as its own tutor in a
separate, bounded request. The tutor sees the failed code and browser feedback,
then suggests repairs. Its advice is explicitly a hypothesis; only the browser
evaluator can qualify the resulting code.

```powershell
.\scripts\Invoke-FrontendGym.ps1 -Continuous `
    -Endpoint http://127.0.0.1:8888/v1 -Model student `
    -TeacherEndpoint http://127.0.0.1:8888/v1 -TeacherModel teacher
```

Different model IDs require a local backend that actually serves them.
Alternatively, use a different local teacher endpoint when hardware permits.
Requests are serialized; the gym does not load two models into one GPU or manage
model swaps. `-TutorEvery 0` disables critique. Shared, tested examples remain
available regardless of which model generated them.

## Persistence, bounds, and isolation

State is under ignored `godbrain_core\skill_lab\work\gym` by default:

| Artifact | Purpose |
|---|---|
| `state.json` | Atomic checkpoint, current exercise, counters, lesson index |
| `runs\<id>\source.json` | Exact learner files |
| `runs\<id>\receipt.json` | Immutable verdict, seeds, hashes and scope |
| `runs\<id>\practice`, `transfer` | Browser evidence and screenshots |
| `events.jsonl`, `events.previous.jsonl` | Bounded operational history |
| `objectives.json` | Bounded Explore/Qualify request queue and outcomes |
| `campaigns.json` | Client briefs, capability plans, assembly and delivery state |
| `docs` | Hash-receipted official reference cache |
| `stop.json` | Cooperative stop request |

The default retains the latest 24 completed runs plus every currently indexed
lesson. Cleanup only removes completed, gym-owned run directories, never
fixtures or repository files. A SQLite transaction in `work` prevents competing
gym workers and releases automatically after a crash. Context, response sizes,
per-exercise attempts, model waits, browser execution and logs are bounded.
Continuous mode rotates after success or the attempt limit; it does not keep
one failed generation spinning forever.

Generated JavaScript is compiled, not executed by Node. It runs in a clean
browser context with restrictive CSP and network controls, no host credentials,
no external network, no Node APIs, and no arbitrary package/config execution.
Keep the browser updated; this is application isolation, not a VM security
boundary against browser-engine vulnerabilities.

Official React/MDN/Node documentation is read as reference data, not tool
instructions or automatically verified claims. Cached pages have content hashes
and fetch dates. `-OfflineDocs` uses the cache and explicitly records unavailable
references. No private source is sent to documentation sites.

## Development and legacy fixture

```powershell
npm test --prefix .\godbrain_core\skill_lab
```

The suite includes passing reference apps, broken-app rejection and the loop's
repair, transfer, persistence, teacher, stop and evidence rules. References are
test fixtures; the live learner is never silently supplied a reference answer.

The original Vite/React dashboard under `fixtures\dashboard-shell-v1` and
`scripts\Verify-SkillLab.ps1` remain a **legacy build/README check**. They are
not the autonomous browser gym. The new exercises use React with a fixed,
trusted bundler instead of executing learner-authored Vite or npm configuration.
`stack-policy.json` still describes project-stack choices, not host authority.

Existing global `record_skill_run` / `promote_skill` retain their original
verified-origin and multiple-fixture gates. Passing this local gym does not
bypass them. A separate, explicitly scoped integration would be required to
publish gym evidence into that protocol.
