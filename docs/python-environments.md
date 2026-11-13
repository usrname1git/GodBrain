# Python workload boundaries

Upgrade to the newest compatible release, not the newest version number at the
expense of another application. Package metadata is not runtime proof: verify
imports, interpreter origins and the affected application's actual operation.
Do not upgrade the working text/QFN Torch/CUDA environment to repair shared Python.

## Active environments

| Environment | Purpose | Dependency boundary |
| --- | --- | --- |
| Text kit `.venv` | Local text serving | ExLlamaV3 1.6.6 / Torch 2.13.0 / CUDA 13.2; standard 27B qualified, VL/Flash Next not requalified; do not apply the shared Torch upgrade here |
| Image model `.venv-isolated` | Qwen-Image-2.1 | Isolated Torch 2.15.0 / torchvision 0.29.2 / CUDA 13.4; Diffusers 0.43.0 and Transformers 5.22.2 |
| Secure MCP replacement | MarkItDown, PDF and FastMCP | MCP 2; FastMCP 4.1.8 and Pillow 13; configured client prefix |
| Tool root `mcp-v1` | Fetch and Time servers | MCP 1; current application releases still require this SDK major |
| Tool root `media` | MoviePy | Pillow 11; cannot share current PDF/image requirements |
| Shared Python | Existing CPU/OCR, audio and general workloads | Torch 2.15.0 / torchvision 0.29.2 / torchaudio 2.11.1 / CUDA 13.4; normal user-site visibility remains supported |

Every application venv has `include-system-site-packages = false`. The image
launcher rejects a missing, enabled or ambiguous system-site setting and never
falls back to the original inherited `.venv`. The original image environment
is retained for rollback, not used by Desk.

The scoped requirements files are under `scripts`:

- `requirements-qwen-image.txt`
- `requirements-python-mcp-modern.txt`
- `requirements-python-mcp-v1.txt`
- `requirements-python-media.txt`
- `requirements-python-shared.txt`

The MCP 2 file freezes the complete 119-package Windows CPython 3.13 set
used for the secure replacement, including conversion extras and transitive
dependencies. It is separate from shared Python's older Starlette/NumPy limits.
Its historical clean audit is not a guarantee against newly published advisories.

The shared file records this repair's compatible target set, including protected
Torch/NumPy pins. It is not a blanket installer for another host. Local packages,
installed consumers and their constraints must be inventoried before applying it.
Some existing shared dependencies live in the user site; disabling user-site
visibility is not equivalent to running this shared environment. Use a workload
venv when isolation is required.

## Deliberate compatibility limits

- Shared Diffusers remains 0.41.0; the image environment uses 0.43.0.
  Both qualified sets retain Hub 1.33.0; the separate text environment's
  Hub major is not a reason to upgrade the shared/image Hub.
- MoviePy 2.2.1 requires Pillow `<12`; Pillow 11.3.0 is its current compatible
  release. Current PDF tools require Pillow `>=12.2`.
- Fetch/Time 2026.10.10 require MCP `<2`. MarkItDown MCP 0.0.1a7,
  MarkItDown 0.1.9 and FastMCP 4.1.8 use the separate MCP 2 set.
  Keep the SDK majors separated.
- Shared MSAL 1.39.0 permits Cryptography `<51`; the qualified target is 50.0.2.
  Existing Streamlit requires Starlette `<1.4`; use 1.3.1, paired with
  FastAPI 0.143.2.
- Shared Torch 2.15.0/CUDA 13.4 is qualified with NumPy 2.4.3.
  The isolated image environment can use NumPy 2.5.4 without changing OCR.
- Torch 2.15.0 requires newer SymPy; both environments use 1.14.0.
  TorchAudio 2.11.1 requires TorchCodec for its WAV load/save path.
  Shared Python uses TorchCodec 0.17.0 with checksum-verified FFmpeg 9.0.2
  full-shared DLLs beside the TorchCodec libraries. A static `ffmpeg.exe`
  is not this runtime dependency. Existing FFmpeg tools and PATH are unchanged.
- Image Filelock 4.2.10 replaces the vulnerable 3.32.3 copy; the complete image
  environment is audited separately rather than assuming shared-package fixes
  reach an isolated venv.

Do not replace these limits with `--no-deps`, force a resolver result, or remove
metadata merely to make `pip check` green. An intentional compatibility-limit
change needs new application evidence.

## Rebuilding without global inheritance

Use the existing Python installation and a new, empty environment directory.
Set these example variables to local paths; no weights are downloaded here:

```powershell
$Python = '<base-python>\python.exe'
$ImageRoot = '<image-model>'
$ToolsRoot = '<python-tools>'

& $Python -I -m venv (Join-Path $ImageRoot '.venv-isolated')
$ImagePython = Join-Path $ImageRoot '.venv-isolated\Scripts\python.exe'
& $ImagePython -m pip install --index-url https://download.pytorch.org/whl/cu134 `
    'torch==2.15.0+cu134' 'torchvision==0.29.2+cu134'
& $ImagePython -m pip install -r .\scripts\requirements-qwen-image.txt

& $Python -I -m venv (Join-Path $ToolsRoot 'mcp-modern')
& (Join-Path $ToolsRoot 'mcp-modern\Scripts\python.exe') -m pip install `
    -r .\scripts\requirements-python-mcp-modern.txt
& $Python -I -m venv (Join-Path $ToolsRoot 'mcp-v1')
& (Join-Path $ToolsRoot 'mcp-v1\Scripts\python.exe') -m pip install `
    -r .\scripts\requirements-python-mcp-v1.txt
& $Python -I -m venv (Join-Path $ToolsRoot 'media')
& (Join-Path $ToolsRoot 'media\Scripts\python.exe') -m pip install `
    -r .\scripts\requirements-python-media.txt
```

Check each exit code before continuing. Do not move a built venv into a different
directory: Windows entry points embed the interpreter path. Stage at its final
path, verify it, and only then change a launcher or client configuration.
Protect private runtime and rollback directories with explicit current-account,
Administrators and SYSTEM access. Inherited authenticated-user write access is
not suitable for executable dependencies or rollback evidence. Normal-user
read/write checks must still pass; do not change a shared parent directory's ACL.

`Start-QwenImage.ps1` selects `.venv-isolated`. It keeps CPU offload, the one-GPU
slot gate, 1024 default size and disposable worker lifecycle. Model weights are
not part of a dependency repair. The worker keeps the directly owned base-Python
process, using `-S` and the image server's explicit import paths so Python cannot
append global/user site-packages and mix a second Torch ABI into the worker.

## Commands and Python scripts

The host migration preserves `fastmcp`, `markitdown`, `markitdown-mcp`,
`pdfplumber`, `mcp-server-fetch` and `mcp-server-time` command names. Their native
Windows launchers are generated with pip's bundled distlib and point to the
appropriate isolated interpreter, not shared Python. No PATH change is needed.
These compatibility launchers are not shared installations of those packages.

Point MCP clients directly at the qualified isolated server's `.exe`. Copilot's
MarkItDown entry uses the secure replacement, not the retained old `mcp-modern`
environment. Reconnect the client after changing the command. No new server
registration is needed.

For Python code importing an isolated package, select that environment explicitly:

```powershell
& (Join-Path $ToolsRoot 'media\Scripts\python.exe') .\my_moviepy_job.py
& (Join-Path $ToolsRoot 'mcp-modern\Scripts\python.exe') .\my_pdf_job.py
```

Do not add a venv's site-packages directory to `PYTHONPATH` or reintroduce
`--system-site-packages` to make ambient imports work.

Fetch keeps its default private-address protections. The regression fixture's
explicit `--allow-private-ips` is only for its disposable loopback server; it
is not added to installed launchers or client configuration. Fetch can use its
upstream Python article extractor when Node/npm are unavailable; this migration
does not install another Node runtime.

## Verification and rollback

Run `python -m pip check` with each intended interpreter. Verify imported package
files are under the venv prefix and `site.ENABLE_USER_SITE` is false. For images,
run the existing CPU-only service fixtures:

```powershell
& $ImagePython -m unittest discover -s .\scripts -p test_qwen_image_server.py
.\scripts\Test-DeskMenu.ps1
```

Exercise MCP initialization and actual tool calls, PDF extraction/rendering,
MoviePy video encode/decode, and shared CPU/OCR/API behavior. An image `/health`
probe and pipeline import do not prove that weights fit or that generation works;
that is a separate explicit one-GPU test.

The shared/image Torch migration was qualified as a real non-elevated user:
CPU OCR with existing offline weights, NumPy/native NMS, CUDA matrix operations,
audio resampling and WAV save/load, plus the API/model imports. Image verification
includes the isolated-worker regression and real 256-by-256 generation through
the HTTP/disposable-worker path at four and forty steps, with completed-step
correlation and nonblank PNG output. This is not a 1024/2048 memory or image-quality
benchmark. One-step baseline output was black; it is not successful image evidence.
No weights were downloaded or deleted.

Before shared replacement, retain a timestamped, access-restricted backup of
system/user site-packages, their Scripts directories, client configuration and
the image launcher. Verify duplicate distributions against their wheel RECORD
hashes before quarantining stale metadata. Preserve an intact current Pillow
installation if a running application has its native modules loaded.

Keep the old image venv and complete backup after cutover. To roll back, stop the
affected consumers deliberately, move the changed package/Scripts directories
aside, restore the corresponding intact backups and original client/launcher
files, then verify again. Do not merge old and new distribution metadata, delete
model weights, stop unrelated services or use process-image-wide termination.
Keep the private runtime/backup ACL boundary during rollback; captured original
ACLs are evidence, not permission to reinstate broad authenticated-user writes.
