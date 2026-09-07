---
title: 'omniReRank bootstrap: Base + Cohere provider + SQL rerank entry point'
type: 'feature'
created: '2026-09-07'
status: 'in-review'
baseline_commit: 'b968357babf30237b297d973e456a48108c9c768'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/module.xml'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** IRIS has no native abstraction for cross-encoder rerankers, so vector search results — often "correct set, wrong order" past top-K — cannot be reordered by relevance without ad-hoc per-provider glue. `dc.omniReRank` needs a working skeleton: a provider template and one real adapter, callable from SQL, so downstream work (more providers, resilience, fallbacks) has a stable base to extend.

**Approach:** Mirror `dc.omniEmbedding`'s Template-Method architecture in a new `dc.omniReRank` package: an abstract `Base` with a virtual (non-`[Final]`) `Execute`, a `Cohere` provider adapter (Cohere v2 `/rerank`), an `Engine` doing provider dispatch only, and a `%SqlProc` `Rerank(query, candidatesJson, configName)` classmethod that becomes the SQL entry point. Configuration lives inside the existing `%Embedding.Config` row's `Configuration` JSON under a `rerank` sub-block; the engine loads `%Embedding.Config` by name, parses the JSON, and reads `.rerank` (never `.dimensions` / provider-embedding fields). Credentials resolve through `Ens.Config.Credentials` by name via a copied-and-adapted `ResolveApiKey`.

**Decisions locked at approval (2026-09-07):**
- (Q1) Config storage: **reuse `%Embedding.Config`** — rerank fields live under a `rerank` sub-block inside its `Configuration` JSON. No new persistent class.
- (Q2) SQL return shape: **`%SqlProc` returning a result set** with columns `(originalIndex INT, candidate VARCHAR, score DOUBLE)`.
- (Q3) `module.xml`: **rename** `dc-sample` → `dc-omniReRank`; `Description` and package resource updated accordingly.
- (Q4) Token budget: keep the full spec despite the ~1950-token count; splitting further would leave non-shippable fragments.

## Boundaries & Constraints

**Always:**
- `dc.omniReRank.provider.Base:Execute` stays virtual — no `[Final]` — so future providers (e.g. Bedrock-style signed variants) can override the sequence.
- `apiKey` in config JSON is a credential **name**, never a raw secret; the resolved secret is only ever passed through `SetAuth` and never logged, thrown, or returned.
- SQL entry point returns candidates in the new order with the provider's raw `relevance_score`; the original 0-based index is preserved on each row.
- Provider adapters throw `%Status` on any malformed response or non-2xx HTTP; never return a silently truncated or empty result set.
- New code lives under `src/dc/omniReRank/`; the existing `src/dc/sample/` tree is not touched.

**Never:**
- No circuit breaker, no retry/backoff, no fallbacks in this spec — those become follow-up specs and must not be stubbed in Base to avoid dead code.
- No provider other than Cohere in this spec (Voyage, Jina, Ollama/BGE deferred).
- No silent score normalization or merging across providers, ever — Engine dispatches to exactly one provider per call.
- No changes to `%Embedding.Config` schema and no shared rows with embedding configs.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path | Valid `configName`; `query="…"`; `candidatesJson='["a","b","c"]'`; Cohere returns 3 scored results | Result set with 3 rows `(originalIndex, candidate, score)` sorted by score DESC | N/A |
| Empty candidates | `candidatesJson='[]'` | Empty result set, no HTTP call | N/A |
| Missing config | `configName` not present in `%Embedding.Config` OR its JSON lacks a `rerank` sub-block | Throw with actionable message naming the missing config (and the missing `rerank` block, when applicable) | Named exception |
| Missing credential | `apiKey` in config not found in `Ens.Config.Credentials` | Throw naming the credential name (never the value) | Named exception |
| Malformed candidates JSON | `candidatesJson='not-json'` | Throw parse error before any HTTP call | Named exception |
| Cohere 4xx (auth/model) | Bearer rejected or model unknown | Throw with HTTP status and body snippet; hint names the credential name and config field | Named exception (no retry — retries deferred) |
| Empty query | `query=""` | Throw before any HTTP call | Named exception |

</frozen-after-approval>

## Code Map

- `/Users/henryhamon/workstation/omni/src/dc/omniEmbedding/provider/Base.cls` — reuse source; copy the shape of `Execute`, `ResolveApiKey`, `StatusHint`, `TransportHint`, `IsFastFailStatus` into `dc.omniReRank.provider.Base`. Strip `RetryWithBackoff`/`ComputeBackoffDelay`/`RetryParam` and inline a single `request.Post(url)` with fast-fail-on-non-2xx (retry deferred). Strip `BuildVector` (rerank returns scores, not vectors).
- `/Users/henryhamon/workstation/omni/src/dc/omniEmbedding/provider/Cohere.cls` — reuse source; the auth pattern (`Bearer <resolved>`) and error-throwing style transfer directly. Rerank payload differs: `{query, documents:[…], model, top_n}` → response `results:[{index, relevance_score}, …]`.
- `/Users/henryhamon/workstation/omni/src/dc/omniEmbedding/Engine.cls` — reference only for `ResolveProvider` shape; copy only the `provider` explicit-key branch (no modelName inference, no circuit breaker, no fallback, no `ProviderKey`).
- `src/dc/sample/*` — do not touch.
- `src/dc/omniReRank/` — new package root; all new classes land here.
- `module.xml` — will need one edit per Open Question 3 outcome.
- `tests/` — new unit test class `dc.omniReRank.unittests.TestCohere` covering the I/O matrix; uses a process-private credential override (mirror `^||omniEmbeddingCredential(name)` hook from Base.cls:230) so tests do not touch `Ens.Config.Credentials`.

## Tasks & Acceptance

**Execution:**
- [x] `src/dc/omniReRank/provider/Base.cls` -- abstract class with virtual `Execute(query, candidates, rerankCfg)`, abstract `SetAuth`, `GetRerankUrl`, `BuildPayload`, `ParseResponse`, `ValidateConfig`; concrete `ResolveApiKey` (copied and renamed globals to `^||omniReRankCredential`), `StatusHint`, `TransportHint`, `IsFastFailStatus` -- reuse contract from `omniEmbedding.Base`. `rerankCfg` is the `rerank` sub-object (already extracted by Engine), so providers never see embedding fields.
- [x] `src/dc/omniReRank/provider/Cohere.cls` -- concrete adapter for Cohere v2 `/rerank`; `GetRerankUrl` → `https://api.cohere.com/v2/rerank`; `BuildPayload` → `{query, documents, model, top_n}`; `ParseResponse` iterates `results[]` yielding `(index, relevance_score)`; `ValidateConfig` requires `modelName` and `apiKey` -- one working provider proves the template.
- [x] `src/dc/omniReRank/Engine.cls` -- `Rerank(query, candidatesJson, configName)` classmethod: parse candidates JSON, `%OpenId` `%Embedding.Config` by `configName`, parse its `Configuration` JSON, extract the `.rerank` sub-object (throw naming both the config and the missing sub-block if absent), resolve provider class from `rerank.provider` (only `"cohere"` valid in this spec — throw with valid-list message otherwise), invoke `provider.Execute(query, candidatesArray, rerankCfg)`, sort results by score DESC, populate a `%SQL.StatementResult` with `(originalIndex, candidate, score)`. Marked `[ SqlProc ]` on the classmethod for SQL exposure.
- [x] `module.xml` -- rename module `dc-sample` → `dc-omniReRank`, update `Description` to reference the rerank gateway, and replace the `dc.sample.PKG` resource with `dc.omniReRank.PKG`.
- [ ] `tests/dc/omniReRank/unittests/TestCohere.cls` -- one test per I/O matrix row; mock Cohere via a subclassed provider that overrides `GetRerankUrl` to a local mock or by shimming `%Net.HttpRequest.Post` in a small test double. Uses the process-private credential override to inject a fake `apiKey`.

**Acceptance Criteria:**
- Given a valid `%Embedding.Config` row named `CohereRerankV3` whose `Configuration` JSON contains `"rerank": {"provider":"cohere","modelName":"rerank-v3.5","apiKey":"CohereCred"}` and an `Ens.Config.Credentials` entry `CohereCred` holding a real key, when a caller executes `CALL dc_omniReRank.Engine_Rerank('best iris tips', '["a","b","c"]', 'CohereRerankV3')`, then the result set has three rows in Cohere's returned order, each carrying the original 0-based index and Cohere's `relevance_score`.
- Given the config exists but its `rerank.apiKey` points at a missing credential, when the caller invokes `Rerank`, then an exception is thrown naming the credential name and no HTTP request is made.
- Given a candidate list of `[]`, when the caller invokes `Rerank`, then the result set is empty and no HTTP request is made.
- Given `configName` is not found in `%Embedding.Config`, when the caller invokes `Rerank`, then an exception is thrown naming the missing config and identifying `%Embedding.Config` as the store checked.
- Given the `%Embedding.Config` row exists but its `Configuration` JSON has no `rerank` sub-block, when the caller invokes `Rerank`, then an exception is thrown naming the config and stating that a `rerank` sub-block is required.

## Implementation Notes

<!-- append-only during implementation -->

**2026-09-07 — initial implementation**

Files added:
- `src/dc/omniReRank/provider/Base.cls` — abstract Template-Method base; `Execute` intentionally not `[Final]`; retry/backoff/circuit-breaker/vector helpers deliberately absent per spec.
- `src/dc/omniReRank/provider/Cohere.cls` — Cohere v2 `/rerank` adapter; `top_n` defaults to `candidates.%Size()` when not set in config, so the caller always gets a score per input.
- `src/dc/omniReRank/Engine.cls` — SQL entry point (`[ SqlProc ]`); parses candidates first (so bad JSON fails before any config lookup), returns empty result set on `[]` with no HTTP or config load, then loads `%Embedding.Config`, extracts `.rerank`, dispatches, sorts DESC via a `$Order`-friendly sparse array subscripted by `-score`.
- `src/dc/omniReRank/RerankResult.cls` — `%SQL.CustomResultSet` with `originalIndex INT`, `candidate VARCHAR(MAXLEN="")`, `score DOUBLE`.
- `tests/dc/omniReRank/unittests/TestCohere.cls` — 15 tests, one per matrix row (plus 2 `StatusHint` tests covering the Cohere-4xx "hint names credential" behavior without needing an HTTP mock) plus AC coverage.
- `tests/dc/omniReRank/unittests/MockProvider.cls` — mock subclass of Base, injected via a new `^||omniReRankProviderOverride(provider)` process-private hook on the Engine so the happy-path test dispatches without HTTP.

Extra surface beyond the Code Map: `^||omniReRankProviderOverride(provider)` on the Engine — added purely as a test hook, mirroring the sanctioned `^||omniReRankCredential` pattern on Base.

Not fully exercised by tests: the Base `Execute` non-2xx throw path itself (needs a live IRIS + a `%Net.HttpRequest` shim). Covered indirectly by the `StatusHint` unit tests which verify the credential-name-preserving hint content.

Verification not run in this session:
- `docker-compose up -d --build` — no IRIS container in this workstation session; user must run to confirm classes compile.
- `%UnitTest.Manager RunTest("dc.omniReRank.unittests")` — same reason.

Risks flagged for first compile:
1. `%SQL.CustomResultSet` `%OnNew + %Next` pattern documented for IRIS 2023+; if the target build wants `%OpenCursor` instead, `RerankResult.cls` needs a one-method swap.
2. `%Embedding.Config` may require additional non-null fields on some builds; `MakeConfig` in the test class sets `EmbeddingClass`/`VectorDataType` behind `Try/Catch`, but additional required fields could break the Engine tests that create configs.

## Design Notes

Deliberate divergences from `omniEmbedding`:
- `Execute` signature is `(query As %String, candidates As %DynamicArray, config As %DynamicObject)` — two textual inputs, not one — because reranking is a pairwise scoring task.
- `ParseResponse` returns a `%DynamicArray` of `{index, score}` objects, not a `%Vector`.
- No `EstimateTokenCount` — token estimation is a query-level concern and does not belong in the provider surface at this stage.

Minimal Base sketch:
```
ClassMethod Execute(query, candidates, config) As %DynamicArray {
    Do ..ValidateConfig(config)
    Set req = ##class(%Net.HttpRequest).%New()
    Set req.ContentType = "application/json"
    Do ..SetAuth(req, config)
    Set url = ..GetRerankUrl(config)
    Do req.EntityBody.Write(..BuildPayload(query, candidates, config).%ToJSON())
    $$$THROWONERROR(sc, req.Post(url))
    Set status = req.HttpResponse.StatusCode
    If (status < 200) || (status >= 300) { $$$ThrowStatus(...StatusHint...) }
    Return ..ParseResponse({}.%FromJSON(req.HttpResponse.Data))
}
```

## Verification

**Commands:**
- `docker-compose up -d --build` -- expected: IRIS container comes up healthy with the new package compiled (no `<COMPILE>` errors in `iris-main.log`).
- `docker-compose exec iris iris session iris -U IRISAPP -B "do ##class(%UnitTest.Manager).RunTest(\"dc.omniReRank.unittests\")"` -- expected: all `TestCohere` cases pass.

**Manual checks (if no CLI):**
- Inspect `src/dc/omniReRank/` — four `.cls` files present, no `Final` on `Base:Execute`, no reference to `RetryWithBackoff` / `CheckBreaker` / `TryFallback`.
