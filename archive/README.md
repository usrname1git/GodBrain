# Archive

Not runtime. Do not modernize `neo4j/`.

`godbrain-llama-chat-extensions.extract.cpp` is a salvage of the custom
llama.cpp GodBrain patch after a Gemini delete script wiped that tree.
It is **not** compiled. Live hands are `godbrain_core/cpp_kernel/local_tools.cpp`.

| Extract (MCP / llama PEG) | Live GodBrain |
|---|---|
| `read_local_file` `write_local_file` `list_local_dir` `ensure_local_dir` | kernel chat tools (same names; `ensure_local_dir` → `create_local_dir`) |
| `save_godbrain_thought` `query_recent_thoughts` `execute_godbrain_script` `get_system_telemetry` `propose_sovereign_architect_change` | kernel `command_type` (bearer + reasoning; not YOLO chat) |
| `query_constellation` | alias of `query_recent_thoughts` (verified RAG). The Node paid graph is gone. Golden Records are the manual (RTFM), not aggregated web hits. `/recall` + `where-we-are.md` inherit crowned facts. |
| `ocr_image` | CPU STT/OCR helpers, not a kernel chat tool |
| `ask_local_llm` | **no** — second generate on the one GPU slot |
| `get_cognitive_protocol` | **no** — not a second agent graph |
| Python MCP writes, CORS/storage-access theater | kernel CreateProcess; loopback CORS list; not browser FS |
| `preserved_tokens` / 80 architect slogans in Gemma 4 PEG | OpenAI `tools` + `--jinja`; kernel executes. Do not stuff doctrine into stop-sequences. |
| Mac Mini UMA cluster / Distributed Cognitive OS | one Windows loop, one GPU slot |

Keep: anti-token-chase, function over shine, native privileged path.
Do not revive MCP or a 26B specialist chat.cpp overlay unless ggml sunsets
and we fork llama on purpose.