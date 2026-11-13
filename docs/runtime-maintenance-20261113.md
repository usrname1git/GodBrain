# Qualified runtime maintenance, 2026-11-13

This is a scoped maintenance/audit record, not a whole-host clean bill of health
or permission to replay repairs. Private installer/ACL/hash inventories,
credentials, model paths, transcripts, binaries and rollback copies remain
outside Git.

## Included changes and qualification

| Component | Completed change | Evidence and limits |
| --- | --- | --- |
| Python | Patch to 3.13.17 at the existing installation | Verified installer and full backup; package inventories/non-bytecode hashes preserved; affected HTTP service restored |
| Shared Python | Compatible security updates; Torch 2.15.0/cu134, Vision 0.29.2, Audio 2.11.1, TorchCodec 0.17.0, SymPy 1.14.0 | Native CPU/CUDA/OCR/audio checks; NumPy 2.4.3 retained; not the text environment |
| Image environment | Matched Torch/Vision/cu134; Diffusers 0.43.0, Transformers 5.22.2, Filelock 4.2.10, Pillow 13 | Isolated environment checked; actual nonblank 256px four/forty-step outputs; not a 1024/2048 or quality benchmark |
| Disposable image worker | Base interpreter now uses `-S` with explicit image import paths | Added real isolated-worker regression preventing ambient global/user Torch ABI mixing; owned-child lifecycle unchanged |
| MCP 2 conversion environment | Qualified 119-package secure replacement, MarkItDown 0.1.9, FastMCP 4.1.8, Pillow 13 | Complete pinned set in `scripts/requirements-python-mcp-modern.txt`; zero flagged/skipped packages at audit time; MCP 1/media environments remain separate |
| Audit tooling / certificate roots | pip 26.3, pip-audit 2.10.1, Certifi 2026.10.23, Setuptools 84.2.1 | Explicit physical/effective audit scopes and import/consumer checks; no future-advisory guarantee |
| Private Python cache/runtime ACLs | 174 blocked cache shards repaired with account access; private executable/rollback boundaries retained | Genuine normal-user access plus content/owner/untargeted-ACL preservation; not a generic parent ACL reset |
| Rust | 1.99.1 under the existing installation model | Compile/link/run and fresh default resolution checked; old SDK retained |
| Node/npm | Node 26.13.1 and effective npm 12.2.2 | Native/runtime and normal-user checks; original installation model preserved |
| Private Chrome MCP | Existing entry advanced to 1.13.0 | Package/client qualification; no new MCP registration |
| Frontend dependency sets | Playwright 1.65, React/DOM 19.3.1, Vite 8.3.8/plugin-react 6.3 | Paired manifests/locks, builds and real 390x844 Brave route checks; existing evaluator failures are not called passing |
| External text-serving kit | ExLlamaV3 1.6.6 with Torch 2.13.0/cu132 and Triton-Windows 3.7.1.post27 | 25 serving tests, real native CUDA/Triton and None/MTP/ngram arithmetic/SSE/tool checks on standard 27B; VL/QFN variants not requalified |

The text environment is deliberately **not** upgraded to the shared/image
Torch set. Defaults remain 10,240 context, fp16 KV, 13.5 GiB budget, no vision
and None drafting. No Qwen weights were downloaded or deleted.

## Separately managed text-kit patch

[`exllama-1.6.6-serving-kit.patch`](exllama-1.6.6-serving-kit.patch) contains
the six session changes in the separately managed
[MiaAI-Lab serving kit](https://github.com/MiaAI-Lab/Qwen3.8-27B-16gb-NVIDIA-GPUs-one-click-install).
Its upstream checkout was `622c7965ed5e02a13b188c9ef21bb9857fd2ba28`, **plus**
existing local integrations. The untracked `paper-godbrain` integration and
prior engine changes are preconditions; this incremental patch does not
bootstrap a raw upstream checkout. No upstream PR is claimed.

The patch was applied to private copies of the exact preimages; all six final
files matched the deployed source byte-for-byte. Both launchers parsed without
execution. Patch SHA-256:
`5f1147770d72ab3d83958d8c9759e6828ed01cbb00da28b3c09d45d527c36a18`.

| Preimage file | Exact SHA-256 |
| --- | --- |
| `tools\wheels.py` | `50d1148b943943f0569ad5edc23efad9e0c2c7fbc639bf9ff69175cb2b1efeed` |
| `tools\test_serve_drafting.py` | `85707b90f4b6ceecf94f70348205b58bc57b41571471d2b44ef776ccb0e877c6` |
| `paper-godbrain\requirements.txt` | `b3dd578ad70ec7cea8dfdcc2414a7201c3ed74cd03a851c5a763759e27992abc` |
| `paper-godbrain\Install-Qwen.ps1` | `4667713ef0dcb46ba7d80673e8c26400258fd533954e2bd9ae18be53569572fe` |
| `paper-godbrain\Start-Qwen.ps1` | `bd50b3537c132356eb1d998727fa000062073315eb270bab28a388dbc2877b04` |
| `paper-godbrain\README.md` | `39f46d4c8b5d7fd7057ef8723d1547e892e52125309951ead13e6179917ce7bf` |

Check all preimage hashes before a separately authorized apply, then use
`git -c core.autocrlf=false apply --check --unidiff-zero` from the kit root.
Use `--unidiff-zero` and the same `core.autocrlf=false` setting when applying.
The scoped Git attribute preserves the patch's source line-ending bytes.
This is static source evidence, not a vendored server, automatic installer,
package update or instruction to restart a model.

The included upstream patch portions retain this original license notice:

```text
MIT License

Copyright (c) 2026 Mia'a AI Lab

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Audit scope and operational findings

Launching an auditor with Python `-I` does not itself restrict a subprocess
package inventory to global site-packages. Explicit `--path` scopes exposed
an older physical Certifi copy hidden by a newer user-site copy. Audit the
effective application environment *and* relevant physical sites; a corrected
global audit is not proof that every isolated environment was repaired.

Native TorchAudio WAV operations require TorchCodec and compatible FFmpeg
shared DLLs. The qualified shared runtime uses checksum-verified FFmpeg 9.0.2
DLLs beside TorchCodec. The separate static FFmpeg executable and PATH were
not replaced.

The Node install's nested old-product MSI uninstall did not inherit the
top-level Restart Manager disable property and interrupted existing
npx/Chrome MCP children. That interruption was observed, not concealed as a
successful no-restart update. Later package/client qualification does not
establish every current interactive MCP connection was reloaded.

BackgroundDownload.exe was identified as Microsoft's Visual Studio downloader,
not Copilot. The reported access violations were not shown to share a cause.
The approximately 1.86 GB Copilot history was preserved and streamed/validated;
two bounded copied-history runs did not reproduce the hashbrown panic.
No panic fix or compact continuation pack is claimed.

## Already reviewed, fixed and merged

These are documented here, not duplicated in this PR:

| PR | Result |
| --- | --- |
| [GodBrain #163](https://github.com/usrname1git/GodBrain/pull/163) | Desk Unicode/identity/reuse, media inherited-handle/deadline and WMI receipt/restoration fixes reviewed and merged |
| [GodBrain #164](https://github.com/usrname1git/GodBrain/pull/164) | Final normalized query byte limit, bounded Windows normalization retries and explicit failure handling fixed in C++/Go and merged |
| [usrname1git/CS2-Analyzer#1](https://github.com/usrname1git/CS2-Analyzer/pull/1) | Eight native/auth/concurrency/pipeline/frontend findings fixed and merged |

Combined GodBrain main passed hosted Windows validation. Scoped local binaries
were deployed with hash-backed rollback; live normalized-query and authorization
boundaries and unchanged corpus counts were checked. Existing Desk relaunch
metadata was refreshed without replacing its live window.
CS2's local native/JS build and tests passed; its production service was not
enabled, and production TLS/credentials/real-demo containment were not rerun.
No model was started to perform deployment or research.

## Clean publication checks

The clean current-main PR worktree reported **169/169** gym tests passing,
with zero failures or skips, using a separate headless Brave instance and
a native disposable Mongo listener on a non-production loopback port.
Real shared-source invalidation/persistence coverage ran; the owned helper was
stopped afterward. The wrapper hit a console-encoding error while printing the
already-completed runner log; full log readback confirmed the test counts.
An earlier incorrectly suffixed database name was rejected by the expected
database guard before tests and was corrected in the test environment only.

The isolated image interpreter passed all **22** image-server tests, including
the real worker-import isolation regression without a skip. The dashboard
fixture's clean lock installed and its Vite build passed; real 390x844 Brave
rendered all three cards without JavaScript exceptions. Those cards are
synthetic fixture values, not live-host readiness. The full MCP manifest
matched all **119** qualified installed package versions; resolver dry-run
requested no additional packages and `pip check` found no conflicts.
The six-file external patch passed both apply-check and exact postimage hashing.
No evaluator or host-policy code was changed to obtain these results.

## Remaining work, not completed fixes

| Item | State |
| --- | --- |
| DiskCache 5.6.3 unsafe-pickle advisory | Saved ASAP task; optional callers assessed, no live removal/backport |
| npm bundled Glob/Minimatch advisories | Saved ASAP task; package-chain/export compatibility assessed, no live backport or out-of-range override |
| Historical dirty-checkout gym browser/evaluator failures | Initial 142-test baseline: 133 passed, nine failed before/after dependency migration. This is a different source tree from the clean publication's 169/169 result; no evaluator fix is claimed |
| Copilot giant-log resume | Original retained; compact continuation/panic fix not implemented |
| Strata/QFN desktop-use replacement | [Research completed](strata-qfn-assessment.md); format/CPU prerequisites and real model/video qualification remain |

This record separates actual source/runtime changes, historical checks,
provider claims and unresolved limits. It does not promote research to a
Golden Record or claim a historical recovery proves current readiness.
