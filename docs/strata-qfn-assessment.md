# Strata and Qwen3.8-Flash-Next

Research completed 2026-11-13 against
[`13eedf552417a6a791a7d13c6597e24300ee3a09`](https://github.com/Niko1221/Strata/tree/13eedf552417a6a791a7d13c6597e24300ee3a09).
The published release inspected was
[`v0.2.13`](https://github.com/Niko1221/Strata/releases/tag/v0.2.13), with
Windows CUDA engine/control 0.1.59. These source and binary versions are not
asserted to be identical.

**Conclusion:** the hybrid design is real and relevant to QFN, but this is
research, not a qualified GodBrain backend or a successful concurrent-video
benchmark. No Strata installer, engine or model weights were run or downloaded.

## What the implementation does

QFN has 48 layers, 512 routed experts per layer and 10 selected per token.
Strata keeps dense/shared work, KV and frequently selected experts on the GPU;
CPU workers compute uncached experts in RAM. The n-gram lookup table can remain
on SSD with sparse reads.

The CUDA
[`session.cpp` loop](https://github.com/Niko1221/Strata/blob/13eedf552417a6a791a7d13c6597e24300ee3a09/src/core/session.cpp#L728-L752)
queues GPU hits before CPU dispatch, copies CPU results, then combines them in
the current layer's router order.
[`expert_source.cpp`](https://github.com/Niko1221/Strata/blob/13eedf552417a6a791a7d13c6597e24300ee3a09/src/core/expert_source.cpp#L5210-L5340)
excludes GPU-owned rows from CPU jobs and supports native quantized verify
windows. This is not simply streaming every model weight through PCIe per token.
Effective overlap and throughput still depend on hardware, driver and workload.

CPU workers spin while waiting. Using the CPU is not the same as leaving the
desktop responsive.

## Format and CPU prerequisites

The QFN
[`own_path_problem` importer](https://github.com/Niko1221/Strata/blob/13eedf552417a6a791a7d13c6597e24300ee3a09/strata_control/models.py#L598-L618)
requires GGUF files. A read-only check rejected the existing EXL3 QFN set.
That does not mean its weights are invalid for ExLlama: Strata has separate
EXL3 support for DeepSeek in `dsv41`, not this QFN import path.
No supported EXL3-to-QFN-Strata conversion was established.

The qualification environment did not expose usable AVX/AVX2. Windows feature
queries, Strata's CPUID/XCR0 fallback, Torch's native CPU dispatcher and an
independent baseline-ISA C++ probe agreed; a separate WMI-launched process
returned the same result. This is an observation about the current exposed
instruction/state environment, not proof that the CPU SKU lacks AVX2 or that
a particular update caused it. Firmware/OS/masking causes remain unresolved;
no boot or firmware setting was changed.

Strata's
[`SOURCE_INSTALL.md`](https://github.com/Niko1221/Strata/blob/13eedf552417a6a791a7d13c6597e24300ee3a09/docs/SOURCE_INSTALL.md#L135-L140)
says ready-made x86 engines require AVX2. Experimental AVX/SSE4.2 source builds
exist with model-format caveats; none was built or qualified in this research.
Resolve that prerequisite, or separately qualify an experimental path, before
attempting a stock-engine cutover.

## Capacity is not a performance verdict

For a capacity profile of 48 GB RAM, 16 GB discrete display VRAM and eight
enabled physical cores, the full-expert Q2_0 is the first *candidate* to test,
not a measured model selection.

| ISTA-DAS variant | First shard | SSD n-gram shard | Total download |
| --- | ---: | ---: | ---: |
| Q2_0 | 37.6 GB | 28.8 GB | 66.4 GB |
| IQ2_XS | 39.2 GB | 28.8 GB | 68.0 GB |
| IQ3_XXS | 47.0 GB | 28.8 GB | 75.8 GB |
| IQ3_S | 54.8 GB | 28.8 GB | 83.6 GB |

These are decimal GB from the
[provider card](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF),
not GiB or measured runtime peaks. Strata estimates roughly 34 GB of experts
for Q2_0 and 35.5 GB for IQ2_XS. The card's quality/llama.cpp performance figures
are provider claims, not independent Strata qualification.

Full-arena mode duplicates GPU-cached experts in pinned RAM. Count that
duplication, dense buffers, prefill staging, KV, conversation/checkpoint caches,
MTP and OS/browser memory. Adding advertised RAM and VRAM is not a sufficient
fit check. Larger quants are not comfortable desktop-use defaults here.
Coder prunes half the experts; do not silently replace general/SRE use with it.

Low-RAM/resident-budget paths retain fewer experts in RAM and can read remaining
misses from files. SSD activity and latency depend on cache/routing; a fit label
does not establish that those reads disappear.

## The resource-headroom mode has limits

The actual
[`native-resources.mjs` policy](https://github.com/Niko1221/Strata/blob/13eedf552417a6a791a7d13c6597e24300ee3a09/apps/host/server/native-resources.mjs#L59-L119)
was executed for the capacity profile above, engine 0.1.59 and Q2_0-sized arena:

| Work policy output | Value |
| --- | --- |
| CPU expert workers | 7 |
| VRAM reserve | 1536 MiB |
| `STRATA_RAM_KEEP_GIB` | 8 |

Seven workers is also the normal default on this topology. The policy does
**not** reserve two CPU cores or enforce a hard 80% utilization throttle;
on 16 GB cards its VRAM default is also not a literal 20%.

The native engine implements `--pool-workers`, `--vram-reserve-mib` and
[`--ram-keep-gib`](https://github.com/Niko1221/Strata/blob/13eedf552417a6a791a7d13c6597e24300ee3a09/docs/DETAILS.md#L751-L767).
Its fallback safety headroom is 8 GiB on Windows. The app's Work policy is not
automatically applied by a bare Terminal/full-performance server.
Desktop usability therefore needs an explicit bounded profile and measurement,
not confidence in the label.

## Integration and checks

The engine is native C++; its stdin/stdout HTTP adapter is Python.
The Tauri/Node desktop UI is optional. A future GodBrain trial should reuse
the existing chat door, not install another desktop wrapper, agent framework
or MCP tool surface.

Source supports loopback OpenAI Chat Completions, SSE, typed tools, thinking
kwargs, cancellation and explicit context-overflow errors. Default port 8080
differs from the current 8888 mouth, so endpoint wiring is deliberate.
Keep GodBrain's C++ bearer/sovereignty and advertised-tool checks, one GPU slot,
CS2/manual/crash holds, exact-child cleanup and the matched ExLlama rollback.

Independently run against the pinned source:

| Check | Result | Limitation |
| --- | --- | --- |
| Tool parsing, call-ID ordering, HTTP context errors, two yield/deadlock cases | 22 Python tests passed | Mock/fake engines, not model inference |
| Resource-policy and user-argument preservation | 23 Node tests passed | No app install or real GPU allocation |
| Existing EXL3 QFN import | Explicit GGUF rejection | No conversion attempted |
| Native CPUID/state and separate WMI process | No usable AVX2 exposed | Cause unresolved |

The [historical speed table](https://github.com/Niko1221/Strata/blob/13eedf552417a6a791a7d13c6597e24300ee3a09/docs/DETAILS.md#L43-L84)
reports Q2_0 87.3-93.0 output tokens/s at 1K-4K on RTX 5070 12 GB, Ryzen 7600,
64 GB DDR5-5200, Windows, engine 0.1.26 and speculative decoding.
That specific older result is not a latest-engine or target-host prediction.
No verified concurrent-YouTube measurement was established.

## Acceptance before adoption

After the CPU prerequisite is resolved or an experimental build is explicitly
qualified, test separate Q2_0 GGUF weights with short bounded context, an explicit
worker cap below seven, RAM/VRAM reserves and no extra vision/MCP/model process.
Change one worker-count variable at a time with fixed prompts.

Record peak RAM/VRAM, first-token/decode latency, answer correctness,
tools/SSE/cancellation and simultaneous hardware-decoded video dropped frames
and audio continuity. A successful generate or a healthy HTTP port alone does
not qualify the request to keep watching video while QFN works.
