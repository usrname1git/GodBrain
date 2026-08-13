# Secure local document ingestion

This adapter extracts explicitly supplied local files, rejects likely credential
material, and sends one strict JSON document per file to the Go Memory Store. It
does not run inside the privileged kernel and never writes MongoDB directly.

Build the Memory Store first, set `MONGODB_URI`, then ingest UTF-8 text:

```powershell
Push-Location godbrain_core\memory_store
go build -o memory-store.exe .\cmd\memory-store
Pop-Location
python -m godbrain_core.local_ingestion --source-label research .\notes.md
```

Image OCR is optional and loaded only for image inputs. Install it in a dedicated
environment, then select CPU, CUDA GPU, or automatic detection:

```powershell
python -m pip install -r .\godbrain_core\local_ingestion\requirements-ocr.txt
python -m godbrain_core.local_ingestion --device cpu --ocr-model-dir .\ocr-models .\scan.png
python -m godbrain_core.local_ingestion --device auto --ocr-languages en,sv .\scan.jpg
```

The adapter passes `download_enabled=False` to EasyOCR. Required model files
must already exist in `--ocr-model-dir`, `EASYOCR_MODULE_PATH`, or EasyOCR's
standard local cache; ingestion never fetches them.

Use `--validate-only` to exercise extraction, secret scanning, hashing, and
payload bounds without contacting MongoDB. Run `--help` for all options.

## Boundaries

- Inputs must be explicit regular files. Directories, symlinks, Windows reparse
  points, empty files, files over 10 MiB, and extension/content mismatches fail.
- Text is strict UTF-8 (an optional UTF-8 BOM is accepted): `.txt`, `.md`, `.rst`,
  `.csv`, `.json`, `.yaml`, and `.yml`. Images are signature-checked PNG, JPEG,
  BMP, GIF, TIFF, or WebP files.
- Extracted text is capped at 3 MiB and split into at most 256 exact UTF-8 chunks
  of 32 KiB. The final Memory Store stdin document is capped below 15 MiB.
- `otpauth://`, `otpauth-migration://`, private-key blocks, and a bounded set of
  high-confidence token/credential formats are rejected before submission.
  Diagnostics name only the category and file, never the matched value. This is
  intentionally not presented as perfect generic-prose classification.
- Durable provenance contains only a user label and safe filename, never an
  absolute path. It records file and extracted-content SHA-256, extraction
  method/backend/version, languages, chunk ranges/count, and OCR confidence.
  Alexandria's required source identity remains legacy Keccak-256 of the exact
  normalized transcript, preserving Memory Store idempotency.
- All files are extracted and scanned before the first submission. A later
  Memory Store failure returns nonzero; files committed earlier in that submit
  phase remain committed and can be retried idempotently.
