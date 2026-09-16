# dashboard-shell-v1

Gym product: a small dark operations dashboard with live-looking status
cards (mouth, RAG, inbox) and a mobile layout. **Not Galaxy.** This is the
legacy build fixture, not evidence of complete browser behavior.

Autonomous practice now uses `scripts\Invoke-FrontendGym.ps1` and the protected
browser curriculum in the [parent gym](../../README.md). Routine exercises
do not require the operator to inspect code or approve each attempt.

## Brief

Responsive dark operations dashboard. Status cards. Works on a phone
width. No authentication in v1 (mocked data).

## Stack

Inferred from `godbrain_core/skill_lab/stack-policy.json`, not operator
choice: **Vite + React** (`frontend-spa-v1`, JavaScript sources). SPA
without an SSR requirement. GodBrain's own UI stays `galaxy.html`.

## Run

From this directory:

```text
npm ci --no-audit --no-fund
npm run build
```

Or from repo root:

```text
.\scripts\Verify-SkillLab.ps1
```

## Check

Harness profile `frontend-spa-v1` must pass `npm run build` **and** this
README must exist. Apply-only `/edit` cannot promote. `-Record` writes a legacy
global skill-run record; global promotion retains its verified-origin gate.
The autonomous gym's local lessons do not use this legacy recording workflow.
