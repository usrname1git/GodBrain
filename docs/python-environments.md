# Python workload boundaries

Upgrade to the newest compatible release, not the newest version number at the
expense of another application. Package metadata is not runtime proof: verify
imports, interpreter origins and the affected application's actual operation.
Do not upgrade the working text/QFN Torch/CUDA environment to repair shared Python.

## Active environments

| Environment | Purpose | Dependency boundary |
| --- | --- | --- |
| Text kit `.venv` | 27B, VL and Flash Next | Existing isolated ExLlamaV3 / Torch 2.11.0 / CUDA 12.8 stack; unchanged by this repair |
| Image model `.venv-isolated` | Qwen-Image-2.1 | Isolated Torch 2.6.0 / torchvision 0.21.0 / CUDA 12.4; current compatible image libraries |
| Tool root `mcp-modern` | MarkItDown, PDF and FastMCP | MCP 2; Pillow 12 |
| Tool root `mcp-v1` | Fetch and Time servers | MCP 1; current application releases still require this SDK major |
| Tool root `media` | MoviePy | Pillow 11; cannot share current PDF/image requirements |
| Shared Python | Existing CPU/OCR and general workloads | Normal user-site visibility remains supported; not an isolated application environment |

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

The shared file records this repair's compatible target set, including protected
Torch/NumPy pins. It is not a blanket installer for another host. Local packages,
installed consumers and their constraints must be inventoried before applying it.
Some existing shared dependencies live in the user site; disabling user-site
visibility is not equivalent to running this shared environment. Use a workload
venv when isolation is required.

## Deliberate compatibility limits

- Diffusers 0.41.0 requires Hub `<2`; use Hub 1.33.0 rather than Hub 2.2.0
  in the shared and image environments.
- MoviePy 2.2.1 requires Pillow `<12`; Pillow 11.3.0 is its current compatible
  release. Current PDF tools require Pillow `>=12.2`.
- Fetch/Time 2026.10.10 require MCP `<2`. MarkItDown MCP 0.0.1a7 and
  FastMCP 4.1.0 use MCP 2. Keep the SDK majors separated.
- Existing shared MSAL requires Cryptography `<49`; use 48.0.1.
  Existing Streamlit requires Starlette `<1.4`; use 1.3.1, paired with
  FastAPI 0.143.2.
- Shared CPU/OCR Torch 2.6.0/CUDA 12.4 and NumPy 2.4.3 are preserved.
  The isolated image environment can use NumPy 2.5.4 without changing OCR.

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
& $ImagePython -m pip install --index-url https://download.pytorch.org/whl/cu124 `
    'torch==2.6.0+cu124' 'torchvision==0.21.0+cu124'
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

`Start-QwenImage.ps1` selects `.venv-isolated`. It keeps CPU offload, the one-GPU
slot gate, 1024 default size and disposable worker lifecycle. Model weights are
not part of a dependency repair.

## Commands and Python scripts

The host migration preserves `fastmcp`, `markitdown`, `markitdown-mcp`,
`pdfplumber`, `mcp-server-fetch` and `mcp-server-time` command names. Their native
Windows launchers are generated with pip's bundled distlib and point to the
appropriate isolated interpreter, not shared Python. No PATH change is needed.
These compatibility launchers are not shared installations of those packages.

Point MCP clients directly at the isolated server's `.exe`. Copilot's existing
MarkItDown entry uses the `mcp-modern` executable; reconnect/restart the client
after changing the command. No new server registration is needed.

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
