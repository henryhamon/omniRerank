# Story 3-1 — Voyage provider

**Epic:** 3 — Provider Expansion
**Status:** pending
**Governed by:** AD-1, AD-4, AD-7 (see [ARCHITECTURE-SPINE.md](../architecture/architecture-omniRerank-2026-09-07/ARCHITECTURE-SPINE.md))
**Effort target:** ≤ 1 bmad-build session

## As a…

IRIS developer, I can set `rerank.provider = "voyage"` and `rerank.modelName = "rerank-2"` in my `%Embedding.Config`, and my existing `CALL dc_omniReRank.Engine_Rerank(...)` starts calling Voyage AI instead of Cohere with no other code change.

## Acceptance

1. `dc.omniReRank.provider.Voyage` extends `dc.omniReRank.provider.Base` implementing the five hooks; `Execute` NOT overridden (AD-1).
2. `GetRerankUrl` → `https://api.voyageai.com/v1/rerank` — **verify the current URL at implementation time via web check.**
3. `BuildPayload` returns `{query, documents, model, top_k}`; `top_k` defaults to `candidates.%Size()` when `rerank.topK` is unset.
4. `SetAuth` → `Bearer <ResolveApiKey(config)>` (AD-4). Same credential-name pattern as Cohere; secret never appears in exceptions.
5. `ParseResponse` iterates `data[]` yielding `{index, score}` `%DynamicArray` (Voyage's field is `relevance_score`). Missing `data` or malformed row throws with `Body:` dump — never returns empty.
6. `ValidateConfig` throws with named-field message when `modelName` or `apiKey` is missing.
7. `Engine.ResolveProvider` accepts `"voyage"` (case-insensitive) and maps to `dc.omniReRank.provider.Voyage`. The "unknown provider" error now lists `voyage` alongside `cohere`.
8. `tests/dc/omniReRank/unittests/TestVoyage.cls` mirrors `TestCohere`'s I/O matrix: `BuildPayload` shape, `BuildPayload` explicit `topK`, `ParseResponse` valid, `ParseResponse` missing `data`, `SetAuth` Bearer via `^||omniReRankCredential` hook, `ValidateConfig` missing model, `ValidateConfig` missing apiKey.
9. `iris-agentic-dev compile src/dc/omniReRank/... tests/dc/omniReRank/unittests/...` → zero errors. `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` → `TestVoyage` all green, prior `TestCohere` (16) + `TestResilience` (13) still green.

## Out of scope

- Any HTTP mock beyond what `MockHttpProvider` already offers (`PostOnce` seam from AD-10 covers the retry path). If Voyage's specific status codes need happy-path integration coverage, extend `MockHttpProvider` rather than adding a Voyage-specific mock.
- Fallback behavior between Cohere and Voyage — that's Epic 4.

## Verification (via `iris-agentic-dev`)

- `iris-agentic-dev compile src/dc/omniReRank/... tests/dc/omniReRank/unittests/...` — zero errors.
- `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — all tests pass (Cohere 16 + Resilience 13 + Voyage new).
