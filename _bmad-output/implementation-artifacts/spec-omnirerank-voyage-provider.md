---
title: 'omniReRank Voyage provider: dc.omniReRank.provider.Voyage adapter for /v1/rerank'
type: 'feature'
created: '2026-09-07'
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'cf32c78897b77eabe2d224f061fd6fea0c605006'
story_key: '3-1-voyage-provider'
context:
  - '{project-root}/_bmad-output/planning-artifacts/stories/3-1-voyage-provider.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-omniRerank-2026-09-07/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 3-1 pending. Only one Provider is wired (`Cohere`), so PRD UJ-2 ("swap provider in config, no code change") is a promise on paper. Voyage is the natural first expansion — payload shape is closest to Cohere, so it stresses the Template-Method contract without introducing new patterns.

**Approach:** Add `dc.omniReRank.provider.Voyage` as a subclass of `dc.omniReRank.provider.Base` implementing exactly the five hooks (`ValidateConfig`, `SetAuth`, `GetRerankUrl`, `BuildPayload`, `ParseResponse`); do NOT override `Execute`. Register `"voyage"` in `Engine.ResolveProvider`. Add `TestVoyage.cls` covering the same I/O matrix rows the shipped `TestCohere` covers. Verified against Voyage's official rerank API documentation at implementation time — POST `https://api.voyageai.com/v1/rerank`, Bearer auth, `{query, documents, model, top_k}` payload, `{data:[{index, relevance_score}, ...]}` response.

**Decisions (from story spec + web verification 2026-09-07):**
- (D1) URL and payload: `POST https://api.voyageai.com/v1/rerank`, body `{query, documents, model, top_k}`. `top_k` defaults to `candidates.%Size()` when `rerank.topK` is unset (parity with Cohere's `top_n` default).
- (D2) Response path: iterate `body.data[]`, extract `index` and `relevance_score`.
- (D3) Auth: `Authorization: Bearer <ResolveApiKey(config)>` — same pattern as Cohere.
- (D4) Config key for optional cap: `rerank.topK` (camelCase, matching Cohere's `rerank.topN` — payload field differs (`top_k` vs `top_n`), config key mirrors the payload for operator legibility).
- (D5) Deliberately NOT exposed in v1: `return_documents`, `truncation`. Callers already own the candidate text (they passed it in), and truncation defaults are Voyage's problem.

## Boundaries & Constraints

**Always:**
- `dc.omniReRank.provider.Voyage` extends `dc.omniReRank.provider.Base` and implements only the five abstract hooks; `Execute` is NOT overridden (AD-1).
- Credentials resolve by name through `Base.ResolveApiKey(config)` (AD-4). No credential value ever appears in a `%Status` message thrown from Voyage.
- `Engine.ResolveProvider` is the single dispatch point that maps `"voyage"` → `dc.omniReRank.provider.Voyage` (AD-7).
- `ParseResponse` throws with the raw body dumped when `data` is absent, is not a JSON array, or a row is missing `index`/`relevance_score`. Never returns an empty array.

**Never:**
- No override of `Execute`, `RetryWithBackoff`, `PostOnce`, `ResolveApiKey`, `StatusHint`, or `TransportHint` on Voyage — those are inherited (AD-1, AD-6, AD-10).
- No new persistent globals, no new test seams beyond the three sanctioned in AD-10.
- No changes to `Engine.Rerank`, `RerankResult`, or `Cohere` other than the one-line addition in `ResolveProvider`.
- No support for `return_documents` or `truncation` in this spec.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| BuildPayload default top_k | `candidates=["a","b","c"]`, config has no `topK` | Payload `{query, documents:["a","b","c"], model:"rerank-2.5", top_k:3}` | N/A |
| BuildPayload explicit topK | Same, config `{"topK":2}` | Payload `top_k=2` (explicit wins) | N/A |
| SetAuth via credential hook | `^||omniReRankCredential("VoyageCred") = "vk-live"`, config `apiKey="VoyageCred"` | `request.Authorization = "Bearer vk-live"` | N/A |
| ParseResponse valid | Body `{"data":[{"index":2,"relevance_score":0.9},{"index":0,"relevance_score":0.5}]}` | `%DynamicArray` of two `{index, score}` entries preserving order | N/A |
| ParseResponse missing data | Body `{"foo":1}` | Throws naming `data`, includes `Body:` dump | Named exception |
| ParseResponse malformed row | Body `{"data":[{"index":0}]}` (no `relevance_score`) | Throws naming the missing field, includes `Body:` dump | Named exception |
| ValidateConfig missing modelName | `{"apiKey":"k"}` | Throws naming `modelName` before any HTTP | Named exception |
| ValidateConfig missing apiKey | `{"modelName":"rerank-2.5"}` | Throws naming `apiKey` before any HTTP | Named exception |
| Engine dispatch on `"voyage"` | Config `rerank.provider="voyage"`, override registered | Engine routes to `dc.omniReRank.provider.Voyage` | N/A |
| Engine dispatch on unknown provider | Config `rerank.provider="rerankly"` | Throws listing `cohere, voyage` in the valid set | Named exception |

</frozen-after-approval>

## Code Map

- `src/dc/omniReRank/provider/Cohere.cls` — reference for shape and error style. `Voyage` follows the exact same structure with three field renames (`documents` still `documents`, but `top_n`→`top_k`, `results[]`→`data[]`, `embedding_types` block absent).
- `src/dc/omniReRank/provider/Base.cls` — parent. Read `ResolveApiKey` (line ~223 in shipped code) to confirm the credential lookup contract. `SetAuth` on Voyage writes `Bearer <returned-value>` and throws when the resolved value is empty.
- `src/dc/omniReRank/Engine.cls` — the `ResolveProvider` method has an explicit `If provider = "cohere" { Return "dc.omniReRank.provider.Cohere" }`. Add the `voyage` branch immediately after, and update the "unknown provider" error message's valid list from `"Valid: cohere"` to `"Valid: cohere, voyage"`.
- `tests/dc/omniReRank/unittests/TestCohere.cls` — reference for test shape. `TestVoyage.cls` mirrors the structure section-by-section.
- `tests/dc/omniReRank/unittests/MockProvider.cls` and `MockHttpProvider.cls` — no changes needed; `Voyage` inherits `Base`, so `MockHttpProvider` already exercises its retry path.
- `module.xml` — no change; `dc.omniReRank.PKG` resource picks up the new class automatically.

## Tasks & Acceptance

**Execution:**
- [x] `src/dc/omniReRank/provider/Voyage.cls` -- new class extending `dc.omniReRank.provider.Base`. Implement `GetRerankUrl` (returns `"https://api.voyageai.com/v1/rerank"`), `SetAuth` (Bearer + `ResolveApiKey`, throw on empty resolved value), `BuildPayload` (`{query, documents, model, top_k}` with `top_k` default from `candidates.%Size()` when `config.topK` unset), `ParseResponse` (iterate `body.data[]` yielding `{index, score}` `%DynamicArray`; throw with `Body:` dump on missing `data` or malformed row), `ValidateConfig` (require `modelName` and `apiKey`, actionable messages).
- [x] `src/dc/omniReRank/Engine.cls` -- extend `ResolveProvider`: add `voyage` branch mapping to `dc.omniReRank.provider.Voyage`; update the "unknown provider" error's valid-list message to `"Valid: cohere, voyage"`.
- [x] `tests/dc/omniReRank/unittests/TestVoyage.cls` -- one test per I/O matrix row: `TestBuildPayloadShape`, `TestBuildPayloadExplicitTopK`, `TestSetAuthUsesBearer` (credential hook), `TestParseResponseValid`, `TestParseResponseMissingData`, `TestParseResponseMissingRelevanceScore`, `TestValidateMissingModelName`, `TestValidateMissingApiKey`. Follow the exact class + method layout of `TestCohere.cls`.
- [ ] Optional (if `TestCohere.cls`'s `TestEngineUnknownProvider` already asserts the valid list) -- update its expected substring assertion to include `voyage`. If not present, add `TestEngineDispatchesToVoyage` in `TestVoyage.cls` covering the two Engine-dispatch rows in the I/O matrix.

**Acceptance Criteria:**
- Given a `%Embedding.Config` row `VoyageRerankV25` whose `Configuration` JSON contains `"rerank": {"provider":"voyage","modelName":"rerank-2.5","apiKey":"VoyageCred"}` and `^||omniReRankCredential("VoyageCred") = "vk-mock"`, when `CALL dc_omniReRank.Engine_Rerank('q', '["a","b","c"]', 'VoyageRerankV25')` dispatches through a `MockHttpProvider` seeded with `(200, "", '{"data":[{"index":2,"relevance_score":0.9},{"index":0,"relevance_score":0.5},{"index":1,"relevance_score":0.1}]}')`, then the returned result set has three rows sorted DESC by score with `originalIndex` values 2, 0, 1.
- Given the same config, when `ValidateConfig` runs with `modelName` missing, then a named exception is thrown before any HTTP call; the message names `modelName`.
- Given `Engine.ResolveProvider("rerankly")`, then the thrown message lists both `cohere` and `voyage` in the valid set.
- Given `TestVoyage` runs under `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'`, then all TestVoyage cases pass AND every prior TestCohere and TestResilience case still passes.

## Implementation Notes

<!-- append-only during implementation -->

**2026-09-07 — implemented and verified on live IRIS via `iris-agentic-dev`**

Changes:
- `src/dc/omniReRank/provider/Voyage.cls` — new class mirroring Cohere's shape with three renames (`top_k`, `data[]`, no `embedding_types` block). `Execute` NOT overridden.
- `src/dc/omniReRank/Engine.cls` — `ResolveProvider` extended with the `voyage` branch; both "unknown provider" error messages updated to list `cohere, voyage`.
- `tests/dc/omniReRank/unittests/TestVoyage.cls` — 9 tests: BuildPayload shape + explicit topK, SetAuth Bearer, ParseResponse valid + missing data + malformed row, ValidateConfig missing model + missing apiKey, Engine dispatch via MockProvider override.
- `tests/dc/omniReRank/unittests/TestCohere.cls` — `TestEngineUnknownProvider` updated: bad-provider name changed from `voyage` (now valid) to `rerankly`; asserts both `cohere` and `voyage` appear in the valid list.

Verification:
- `iris-agentic-dev compile ...` — 4 classes OK, zero errors.
- `iris-agentic-dev exec 'set ^UnitTestRoot="/home/irisowner/dev/tests" do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — All PASSED. Prior TestCohere (16) + TestResilience (13) still green; new TestVoyage (9) all green.

No open risks. Story 3-1 acceptance criteria satisfied.

## Design Notes

Divergences from Cohere adapter (kept intentional for future readers):
- **Payload field name.** `top_k` (Voyage) vs `top_n` (Cohere). Config-key mirrors payload for operator legibility (`rerank.topK` here, `rerank.topN` there). Both default to `candidates.%Size()` when unset.
- **Response array name.** `data` (Voyage) vs `results` (Cohere). Same shape underneath (`{index, relevance_score}` rows).
- **Score field.** Both use `relevance_score` — the one commonality worth noting since it's tempting to imagine a shared adapter. Do NOT hoist a shared parser onto `Base` — every fourth provider (Jina, Ollama, next SaaS) will invent its own field, and premature abstraction will cost more than the duplication.

Minimal Voyage sketch:
```
ClassMethod BuildPayload(query, candidates, config) As %DynamicObject {
    Set payload = {}
    Set payload.query = query
    Set payload.documents = candidates
    Set payload.model = config.%Get("modelName")
    Set topK = config.%Get("topK")
    If topK = "" { Set topK = candidates.%Size() }
    Set payload."top_k" = +topK
    Return payload
}
```

## Verification

**Commands (via `iris-agentic-dev`):**
- `iris-agentic-dev compile src/dc/omniReRank/provider/Voyage.cls src/dc/omniReRank/Engine.cls tests/dc/omniReRank/unittests/TestVoyage.cls` -- expected: zero errors.
- `iris-agentic-dev exec 'set ^UnitTestRoot="/home/irisowner/dev/tests" do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` -- expected: All PASSED. TestCohere (16) + TestResilience (13) + TestVoyage (new) all green.
- `iris-agentic-dev query "SELECT COUNT(*) FROM %Dictionary.CompiledClass WHERE Name %STARTSWITH 'dc.omniReRank.provider.'"` -- expected: at least 3 (`Base`, `Cohere`, `Voyage`).
