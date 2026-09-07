---
title: 'omniReRank Jina provider: dc.omniReRank.provider.Jina adapter for /v1/rerank'
type: 'feature'
created: '2026-09-07'
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '80e1cba20fa3cd168733fc52272415c05d66976e'
story_key: '3-2-jina-provider'
context:
  - '{project-root}/_bmad-output/planning-artifacts/stories/3-2-jina-provider.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-omniRerank-2026-09-07/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 3-2 pending. Cohere and Voyage are wired; adding Jina rounds out the SaaS Provider set called out in PRD FR-5 and stresses the Template-Method contract one more time before we hit the deliberately-different Ollama shape (Story 3-3).

**Approach:** Add `dc.omniReRank.provider.Jina` as a subclass of `dc.omniReRank.provider.Base` implementing only the five hooks; do NOT override `Execute`. Register `"jina"` in `Engine.ResolveProvider`. Add `TestJina.cls` covering the same I/O matrix rows that `TestCohere` and `TestVoyage` cover. Verified against Jina's OpenAPI schema at implementation time — POST `https://api.jina.ai/v1/rerank`, Bearer auth, `{model, query, documents, top_n}` payload, `{results:[{index, relevance_score}, ...]}` response.

**Decisions (from story spec + web verification 2026-09-07):**
- (D1) URL and payload: `POST https://api.jina.ai/v1/rerank`, body `{model, query, documents, top_n}`. `top_n` defaults to `candidates.%Size()` when `rerank.topN` is unset (matches Cohere naming — Jina and Cohere share the `top_n` field name; Voyage's `top_k` is the outlier).
- (D2) Response path: iterate `body.results[]`, extract `index` and `relevance_score` (confirmed against Jina's OpenAPI schema — the score field is `relevance_score`, not `score`).
- (D3) Auth: `Authorization: Bearer <ResolveApiKey(config)>` — same pattern as Cohere and Voyage.
- (D4) Config key for optional cap: `rerank.topN` (camelCase, mirroring Cohere).
- (D5) Deliberately NOT exposed in v1: `return_documents`. Callers already own the candidate text.

## Boundaries & Constraints

**Always:**
- `dc.omniReRank.provider.Jina` extends `dc.omniReRank.provider.Base` and implements only the five abstract hooks; `Execute` is NOT overridden (AD-1).
- Credentials resolve by name through `Base.ResolveApiKey(config)` (AD-4). No credential value ever appears in a `%Status` message thrown from Jina.
- `Engine.ResolveProvider` maps `"jina"` → `dc.omniReRank.provider.Jina` (AD-7); the unknown-provider error message lists `cohere, voyage, jina`.
- `ParseResponse` throws with the raw body dumped when `results` is absent, is not a JSON array, or a row is missing `index`/`relevance_score`. Never returns an empty array.

**Never:**
- No override of `Execute`, `RetryWithBackoff`, `PostOnce`, `ResolveApiKey`, `StatusHint`, or `TransportHint` on Jina.
- No new persistent globals; no new test seams beyond the three sanctioned in AD-10.
- No changes to `Engine.Rerank`, `RerankResult`, `Cohere`, or `Voyage` other than the one-line addition in `ResolveProvider` and the corresponding valid-list message update.
- No support for `return_documents` in this spec.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| BuildPayload default top_n | `candidates=["a","b","c"]`, config has no `topN` | Payload `{model:"jina-reranker-v2-base-multilingual", query, documents:["a","b","c"], top_n:3}` | N/A |
| BuildPayload explicit topN | Same, config `{"topN":2}` | Payload `top_n=2` (explicit wins) | N/A |
| SetAuth via credential hook | `^||omniReRankCredential("JinaCred") = "jk-live"`, config `apiKey="JinaCred"` | `request.Authorization = "Bearer jk-live"` | N/A |
| ParseResponse valid | Body `{"results":[{"index":2,"relevance_score":0.9},{"index":0,"relevance_score":0.5}]}` | `%DynamicArray` of two `{index, score}` entries preserving order | N/A |
| ParseResponse missing results | Body `{"foo":1}` | Throws naming `results`, includes `Body:` dump | Named exception |
| ParseResponse malformed row | Body `{"results":[{"index":0}]}` (no `relevance_score`) | Throws naming the missing field, includes `Body:` dump | Named exception |
| ValidateConfig missing modelName | `{"apiKey":"k"}` | Throws naming `modelName` before any HTTP | Named exception |
| ValidateConfig missing apiKey | `{"modelName":"jina-reranker-v2-base-multilingual"}` | Throws naming `apiKey` before any HTTP | Named exception |
| Engine dispatch on `"jina"` | Config `rerank.provider="jina"`, MockProvider override registered | Engine routes to `dc.omniReRank.provider.Jina` | N/A |
| Engine dispatch on unknown provider | Config `rerank.provider="rerankly"` | Throws listing `cohere, voyage, jina` in the valid set | Named exception |

</frozen-after-approval>

## Code Map

- `src/dc/omniReRank/provider/Cohere.cls` — closest reference (same `top_n` payload field, same `results[]` response array, same `relevance_score` field). Jina's adapter is nearly line-for-line the same with the URL swapped.
- `src/dc/omniReRank/provider/Voyage.cls` — recent-precedent for the "add-a-provider" pattern with rename discipline; use its test file layout as a template.
- `src/dc/omniReRank/provider/Base.cls` — parent. `ResolveApiKey` semantics unchanged.
- `src/dc/omniReRank/Engine.cls` — extend `ResolveProvider` with the `jina` branch. Update both "unknown provider" error messages to include `jina` in the valid list.
- `tests/dc/omniReRank/unittests/TestVoyage.cls` — most recent precedent; `TestJina.cls` mirrors its structure section-by-section.
- `tests/dc/omniReRank/unittests/TestCohere.cls` — `TestEngineUnknownProvider` asserts the valid list; update to also assert `jina` appears.
- `module.xml` — no change; `dc.omniReRank.PKG` resource picks up the new class.

## Tasks & Acceptance

**Execution:**
- [x] `src/dc/omniReRank/provider/Jina.cls` -- new class extending `dc.omniReRank.provider.Base`. Implement `GetRerankUrl` (returns `"https://api.jina.ai/v1/rerank"`), `SetAuth` (Bearer + `ResolveApiKey`, throw on empty resolved value), `BuildPayload` (`{model, query, documents, top_n}` with `top_n` default from `candidates.%Size()` when `config.topN` unset), `ParseResponse` (iterate `body.results[]` yielding `{index, score}` `%DynamicArray`; throw with `Body:` dump on missing `results` or malformed row), `ValidateConfig` (require `modelName` and `apiKey`, actionable messages).
- [x] `src/dc/omniReRank/Engine.cls` -- extend `ResolveProvider`: add `jina` branch mapping to `dc.omniReRank.provider.Jina`; update BOTH "unknown provider" error messages to `"Valid: cohere, voyage, jina"`.
- [x] `tests/dc/omniReRank/unittests/TestJina.cls` -- one test per I/O matrix row: `TestBuildPayloadShape`, `TestBuildPayloadExplicitTopN`, `TestSetAuthUsesBearer`, `TestParseResponseValid`, `TestParseResponseMissingResults`, `TestParseResponseMissingRelevanceScore`, `TestValidateMissingModelName`, `TestValidateMissingApiKey`, `TestEngineDispatchesToJina` (uses MockProvider override to exercise Engine routing without HTTP).
- [x] `tests/dc/omniReRank/unittests/TestCohere.cls` -- update `TestEngineUnknownProvider`: assert `jina` also appears in the valid-list substring.

**Acceptance Criteria:**
- Given a `%Embedding.Config` row `JinaRerankV2` whose `Configuration` JSON contains `"rerank": {"provider":"jina","modelName":"jina-reranker-v2-base-multilingual","apiKey":"JinaCred"}` and `^||omniReRankCredential("JinaCred") = "jk-mock"`, when `CALL dc_omniReRank.Engine_Rerank('q', '["a","b","c"]', 'JinaRerankV2')` dispatches through a `MockHttpProvider` seeded with `(200, "", '{"results":[{"index":2,"relevance_score":0.9},{"index":0,"relevance_score":0.5},{"index":1,"relevance_score":0.1}]}')`, then the returned result set has three rows sorted DESC by score with `originalIndex` values 2, 0, 1.
- Given `Engine.ResolveProvider("rerankly")`, then the thrown message lists all three of `cohere`, `voyage`, and `jina` in the valid set.
- Given `TestJina` runs under `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'`, then all TestJina cases pass AND every prior TestCohere, TestResilience, and TestVoyage case still passes.

## Implementation Notes

<!-- append-only during implementation -->

**2026-09-07 — implemented and verified on live IRIS via `iris-agentic-dev`**

Changes:
- `src/dc/omniReRank/provider/Jina.cls` — new class extending Base with the five hooks. Same response-parse shape as Cohere (`results[].relevance_score`); URL `https://api.jina.ai/v1/rerank`; `top_n` payload default from `candidates.%Size()`. `Execute` NOT overridden.
- `src/dc/omniReRank/Engine.cls` — `ResolveProvider` extended with `jina` branch; both unknown-provider error messages updated to list `cohere, voyage, jina`.
- `tests/dc/omniReRank/unittests/TestJina.cls` — 9 tests mirroring TestVoyage's structure, one per I/O matrix row.
- `tests/dc/omniReRank/unittests/TestCohere.cls` — `TestEngineUnknownProvider` also asserts `jina` in the valid-list message.

Verification:
- `iris-agentic-dev compile ...` — 4 classes OK, zero errors.
- `iris-agentic-dev exec 'set ^UnitTestRoot=... RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — All PASSED. TestCohere (16) + TestResilience (13) + TestVoyage (9) + TestJina (9) all green.

No open risks. Story 3-2 acceptance criteria satisfied.

## Design Notes

Payload shape identity with Cohere:
- Both use `top_n` (not Voyage's `top_k`), so the `rerank.topN` config key from Cohere carries over unchanged.
- Both use `results[]` with `{index, relevance_score}`, so `ParseResponse` is structurally identical to Cohere's.

Do NOT hoist a shared parser onto `Base` even though Cohere and Jina now share the exact response shape. Ollama (Story 3-3) will diverge, and every fourth SaaS after that will invent its own. Premature abstraction costs more than the ~15-line duplication.

Minimal Jina sketch:
```
ClassMethod GetRerankUrl(config) As %String { Return "https://api.jina.ai/v1/rerank" }

ClassMethod BuildPayload(query, candidates, config) As %DynamicObject {
    Set payload = {}
    Set payload.model = config.%Get("modelName")
    Set payload.query = query
    Set payload.documents = candidates
    Set topN = config.%Get("topN")
    If topN = "" { Set topN = candidates.%Size() }
    Set payload."top_n" = +topN
    Return payload
}
```

## Verification

**Commands (via `iris-agentic-dev`):**
- `iris-agentic-dev compile src/dc/omniReRank/provider/Jina.cls src/dc/omniReRank/Engine.cls tests/dc/omniReRank/unittests/TestJina.cls tests/dc/omniReRank/unittests/TestCohere.cls` -- expected: zero errors.
- `iris-agentic-dev exec 'set ^UnitTestRoot="/home/irisowner/dev/tests" do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` -- expected: All PASSED. TestCohere + TestResilience + TestVoyage + TestJina all green.
- `iris-agentic-dev query "SELECT COUNT(*) FROM %Dictionary.CompiledClass WHERE Name %STARTSWITH 'dc.omniReRank.provider.'"` -- expected: at least 4 (`Base`, `Cohere`, `Voyage`, `Jina`).
