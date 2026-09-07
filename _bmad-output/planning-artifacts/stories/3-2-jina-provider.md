# Story 3-2 — Jina provider

**Epic:** 3 — Provider Expansion
**Status:** pending
**Governed by:** AD-1, AD-4, AD-7
**Effort target:** ≤ 1 bmad-build session

## As a…

IRIS developer, I can set `rerank.provider = "jina"` and `rerank.modelName = "jina-reranker-v2-base-multilingual"` and reranking flows through Jina's v1 rerank endpoint with no other code change.

## Acceptance

1. `dc.omniReRank.provider.Jina` extends `Base` implementing the five hooks; `Execute` NOT overridden.
2. `GetRerankUrl` → `https://api.jina.ai/v1/rerank` — verify current at implementation time.
3. `BuildPayload` returns `{model, query, documents, top_n}`; `top_n` defaults to `candidates.%Size()` when `rerank.topN` unset.
4. `SetAuth` → `Bearer <ResolveApiKey(config)>` (AD-4).
5. `ParseResponse` iterates `results[]` yielding `{index, score}` (Jina's field is `relevance_score`). Missing `results` throws with `Body:` dump.
6. `ValidateConfig` throws when `modelName` or `apiKey` is missing.
7. `Engine.ResolveProvider` accepts `"jina"` (case-insensitive). "Unknown provider" message now lists `jina`.
8. `tests/dc/omniReRank/unittests/TestJina.cls` covers the same I/O matrix as `TestCohere`.
9. All prior tests still green.

## Out of scope

- Multilingual-specific behavior verification — that's a Jina concern, not the gateway's.
- Fallback between Jina and any other provider — Epic 4.

## Verification

- `iris-agentic-dev compile src/dc/omniReRank/... tests/dc/omniReRank/unittests/...` — zero errors.
- `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — all green.
