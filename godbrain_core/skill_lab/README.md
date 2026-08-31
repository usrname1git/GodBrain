# Skill lab (gym, not Galaxy)

Practice canvas for **product-shaped** procedures: brief → inferred stack →
fixture → build → evidence. It does not replace `galaxy.html`, Heal, or the
kernel. It is not a Linux-kernel factory.

Frontend is the first gym because a small UI is a cheap inner loop (build
either works or it does not). A passing dashboard here does not make GodBrain
a web-dev shop, and it does not imply Nest, Next, or Rust-in-the-kernel.

Stack pick is **compiled** in `stack-policy.json`. Do not ask the operator
Vite vs Next vs Node. Do not Exa Wikipedia for that table.

| Job | Lab default |
|---|---|
| Simple browser app / dashboard | Vite + React (`frontend-spa-v1`) |
| SSR / public site (only if the brief says so) | Next.js (`frontend-nextjs-v1`) — not scaffolded in v1 |
| GodBrain operator UI | **Out of lab.** `godbrain_core/frontend/galaxy.html` |
| Separate API, OS kernel, BIOS | **Not this gym.** |

Harness: `scripts\Verify-SkillLab.ps1`. It runs allowlisted `npm` commands
off the GPU, then **fails if the fixture has no real README** (Brief, Stack,
Run, Check, Not Galaxy). A green build without docs is not a product.
Optional `-Record` writes `skill_verification_runs` with `suite_id`.
Apply-only `/edit` cannot promote. Broad profiles (`frontend-spa-v1`,
`galaxy-html-v1`, `frontend-nextjs-v1`) need passing runs on **two**
distinct fixtures before promote. `desk-v1` may stay one host fixture.
Origin node still needs `/verify`. Not a popularity rank and not an
automatic contradiction resolver.
