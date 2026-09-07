# Story 3-3 — Ollama provider (authless / local)

**Epic:** 3 — Provider Expansion
**Status:** pending
**Governed by:** AD-1, AD-7. Deliberately NOT governed by AD-4 (Ollama is authless).
**Effort target:** ≤ 1 bmad-build session + a live Ollama endpoint check to freeze the response shape.
**Resolves:** PRD §8 Q2 (Ollama rerank surface — `/api/rerank` vs. prompt-template shim).

## As a…

Privacy-focused solutions architect, I can point `rerank.provider = "ollama"` at my internal BGE endpoint (`rerank.apiBase = "http://ollama.internal:11434"`) and rerank inside the datacenter with no `apiKey` configured — the same SQL entry point works.

## Acceptance

1. `dc.omniReRank.provider.Ollama` extends `Base` implementing the five hooks; `Execute` NOT overridden.
2. `GetRerankUrl` → `<config.apiBase>/api/rerank`. `ValidateConfig` throws when `apiBase` is missing.
3. `BuildPayload` returns `{model, query, documents, top_n}`; `top_n` defaults to `candidates.%Size()`.
4. `SetAuth` is a NO-OP (Ollama is authless). `ValidateConfig` MUST NOT require `apiKey` — this is the one deliberate deviation from other providers.
5. `ParseResponse` — the exact shape MUST be pinned by inspecting a live Ollama ≥ 0.6.0 `/api/rerank` response during implementation. If `/api/rerank` is unavailable in the target Ollama build, the story is REPLANNED to ship a prompt-template shim behind the same `Base` contract (PRD §8 Q2). Do NOT ship a guessed parser.
6. `ValidateConfig` throws when `modelName` or `apiBase` is missing; does NOT check `apiKey`.
7. `Engine.ResolveProvider` accepts `"ollama"` (case-insensitive). "Unknown provider" message now lists `ollama`.
8. `tests/dc/omniReRank/unittests/TestOllama.cls` covers: `BuildPayload` shape, `ParseResponse` valid, `ParseResponse` malformed with `Body:` dump, `ValidateConfig` missing `apiBase`, `ValidateConfig` missing `modelName`, `ValidateConfig` does NOT throw when `apiKey` is absent (regression guard for the authless invariant).
9. `iris-agentic-dev query "SELECT COUNT(*) FROM %Dictionary.CompiledClass WHERE Name %STARTSWITH 'dc.omniReRank.'"` returns ≥ 10 after this story lands.

## Open questions to resolve in the story spec

- **Ollama response shape** — inspect at implementation time; pin exactly. Reject anything else with the `Body:` dump pattern.
- **`/api/rerank` availability** — if unavailable, spec MUST document the prompt-template shim design (build a scoring prompt, POST to `/api/generate`, parse the model's response) before implementation starts. Do not silently paper over.

## Out of scope

- BGE-specific tuning (choice of model, temperature, prompt templates for the shim) — that's a caller decision, not the gateway's.
- Fallback to a SaaS provider when Ollama is down — Epic 4.

## Verification

- `iris-agentic-dev compile src/dc/omniReRank/... tests/dc/omniReRank/unittests/...` — zero errors.
- `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — all green.
- Manual smoke test against a real Ollama endpoint (documented in the story's Implementation Notes).
