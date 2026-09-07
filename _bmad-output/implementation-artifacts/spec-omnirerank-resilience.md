---
title: 'omniReRank resilience: retry+backoff on Base, circuit breaker on Engine, transport mock'
type: 'feature'
created: '2026-09-07'
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'b968357babf30237b297d973e456a48108c9c768'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/spec-omnirerank-bootstrap-cohere.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The bootstrap spec left `dc.omniReRank.provider.Base.Execute` fast-failing on every non-2xx: a single upstream 429 or transient 5xx surfaces as a hard error, and repeated failures against a broken provider still hammer the endpoint request-by-request. Two proven resilience patterns already exist in `dc.omniEmbedding` — `RetryWithBackoff` on the provider Base, and a persisted circuit breaker on the Engine — and must be ported so `omniReRank` matches the family's contract.

**Approach:** Port the omniEmbedding resilience patterns 1:1, renaming globals and error prefixes to `omniReRank`. Retry+backoff on `Base` (retries on 429 and 5xx, fast-fails on other 4xx, honors `Retry-After`, exponential+jitter to a max delay). Circuit breaker on `Engine` (5 consecutive failures open the breaker for 60s per `provider|modelName` key, persisted at `^omniReRank.Breaker`, half-open on first request after cooldown). To exercise Base's HTTP failure paths without real network calls, introduce a `PostOnce(request, url)` seam on Base so tests can subclass and inject synthetic HTTP responses; the production path calls `request.Post(url)` unchanged.

**Decisions locked at approval (2026-09-07):**
- (Q1) Breaker scope: **`provider|modelName`** — no `apiBase` component, since only Cohere is wired and no provider currently reads `apiBase`. Follow-up specs that add an OpenAI-compatible base URL may extend the key.
- (Q2) Retry defaults: **`maxAttempts=3`, `baseDelayMs=500`, `maxDelayMs=8000`, `honorRetryAfter=1`** — same defaults as `dc.omniEmbedding`. All overridable per-config via `config.retry.*`.
- (Q3) HTTP mock strategy: **`PostOnce` seam on Base** overridable in a test subclass — no full DI refactor, no shim on `%Net.HttpRequest`.
- (Q4) Fallbacks between providers: **explicitly out of scope** — deferred to a follow-up spec. The circuit-breaker's cooldown-open branch throws (does not silently degrade).

## Boundaries & Constraints

**Always:**
- The retry loop lives in `Base.RetryWithBackoff` and is called from the (still-virtual) `Base.Execute`; providers that inherit the default `Execute` inherit retries automatically.
- The circuit breaker lives in `Engine`: `Engine.Rerank` checks the breaker before dispatch, records success on OK, records failure on any thrown exception from the provider.
- Breaker state is persisted at `^omniReRank.Breaker(providerKey) = $LB(failures, openedAtSeconds)`.
- Backoff is `min(baseDelayMs * 2^(attempt-1) + rand(baseDelayMs), maxDelayMs)`; when `Retry-After` is present, numeric, and `honorRetryAfter=1`, that value in seconds wins.
- The Base `PostOnce(request, url)` seam wraps exactly `request.Post(url)`; tests override it, production does not.

**Never:**
- No provider-fallback logic in this spec (`config.fallbacks` is ignored — deferred).
- No `apiBase` in the breaker key (deferred to when a provider actually reads it).
- No changes to the SQL entry-point signature or `RerankResult` shape.
- No new dependencies; no changes to `module.xml` beyond compiling the new files under the existing package resource.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Retry on 5xx then 200 | Test provider returns 503, 503, 200 with a valid parseable body | Third attempt succeeds; result set returned; breaker records success (counter reset) | N/A |
| Retry on 429 with Retry-After | Provider returns 429 with `Retry-After: 1`, then 200 | Second attempt succeeds after ~1s delay; result set returned | N/A |
| Fast-fail on 400 | Provider returns 400 | Throws immediately after 1 attempt; error names status and body snippet | Named exception, no retry |
| Retries exhausted on persistent 500 | Provider returns 500 on every attempt with `maxAttempts=3` | Throws after 3 attempts; error names status, URL, attempts count | Named exception |
| Transport error | `request.Post` returns error `%Status` | Throws with `TransportHint`; error mentions `HTTPS`/`sslConfig` for https URLs | Named exception, no retry |
| Breaker opens after N failures | 5 consecutive provider throws for the same `provider\|modelName` key | Sixth call throws with `"circuit breaker open"` message before dispatching; no HTTP attempt | Named exception |
| Breaker half-open after cooldown | Breaker was opened; time elapsed ≥ 60s | Next call is allowed through; success resets counter; failure re-opens breaker | Depends on outcome |
| Breaker records success | After any successful call | `^omniReRank.Breaker(key) = $LB(0,0)` (explicit reset, not merely a missing global) | N/A |

</frozen-after-approval>

## Code Map

- `/Users/henryhamon/workstation/omni/src/dc/omniEmbedding/provider/Base.cls` lines 80-133 (`RetryWithBackoff`), 185-203 (`ComputeBackoffDelay`), 205-212 (`RetryParam`) — copy verbatim into `dc.omniReRank.provider.Base`, renaming error prefixes to `dc.omniReRank`.
- `/Users/henryhamon/workstation/omni/src/dc/omniEmbedding/Engine.cls` lines 96-145 (`ProviderKey`, `FAILURETHRESHOLD`, `COOLDOWNSECONDS`, `CheckBreaker`, `RecordSuccess`, `RecordFailure`, `NowSeconds`) — copy into `dc.omniReRank.Engine`; swap `^omniEmbedding.Breaker` → `^omniReRank.Breaker`; drop `apiBase` from `ProviderKey`.
- `src/dc/omniReRank/provider/Base.cls` — modify `Execute` to call `..RetryWithBackoff(request, url, config)` instead of inline `request.Post(url)`; add `RetryWithBackoff`, `ComputeBackoffDelay`, `RetryParam`, `PostOnce` methods.
- `src/dc/omniReRank/Engine.cls` — inject breaker check before dispatch; on provider throw, `RecordFailure(providerKey)` then re-throw; on success, `RecordSuccess(providerKey)`.
- `tests/dc/omniReRank/unittests/MockHttpProvider.cls` — NEW: subclass of `dc.omniReRank.provider.Base` that overrides `PostOnce` to return synthetic `(status, headers, body)` from a process-private queue (`^||omniReRankMockPostQueue`); also has trivial `SetAuth`/`GetRerankUrl`/`BuildPayload`/`ParseResponse`/`ValidateConfig` implementations. Registered via `^||omniReRankProviderOverride("cohere")` in tests, mirroring the existing `MockProvider` pattern.
- `tests/dc/omniReRank/unittests/TestResilience.cls` — NEW: one test per matrix row above, plus one test per breaker method (records failure count, opens at threshold, cooldown gate, resets on success).

## Tasks & Acceptance

**Execution:**
- [x] `src/dc/omniReRank/provider/Base.cls` -- add `RetryWithBackoff(request, url, config)` (retries on 429/5xx, fast-fails other 4xx, honors Retry-After); add `ComputeBackoffDelay(attempt, retryAfter, config)`; add `RetryParam(retry, name, default)` (private); add `PostOnce(request, url) As %Status` returning `request.Post(url)` — the injection seam; change `Execute` to build the request, then delegate to `RetryWithBackoff` and parse only on success; keep `Execute` virtual (no `[Final]`).
- [x] `src/dc/omniReRank/Engine.cls` -- add `ProviderKey(rerankCfg) As %String` returning `provider|modelName`; add `Parameter FAILURETHRESHOLD = 5` and `Parameter COOLDOWNSECONDS = 60`; add `CheckBreaker(providerKey)`, `RecordSuccess(providerKey)`, `RecordFailure(providerKey)`, `NowSeconds()` — all `[Internal]`; wrap the `$ClassMethod(providerClass, "Execute", ...)` call: if `CheckBreaker` returns 1 throw with the breaker-open message; on success `RecordSuccess`; on exception `RecordFailure` then re-throw.
- [x] `tests/dc/omniReRank/unittests/MockHttpProvider.cls` -- new mock provider overriding `PostOnce`; reads `(status, headers-as-JSON, body)` triples from `^||omniReRankMockPostQueue(1..N)` popping FIFO; if queue empty throws so tests notice starvation; `ParseResponse` accepts the same `{results:[{index,relevance_score},...]}` shape as Cohere to keep the happy-path test payload realistic.
- [x] `tests/dc/omniReRank/unittests/TestResilience.cls` -- one test per I/O matrix row; each test seeds `^||omniReRankMockPostQueue` and asserts either the sorted result set or the thrown message; each test kills the queue and `^omniReRank.Breaker` in a `%OnBeforeAllTests`/`OnAfterAllTests`-style cleanup so cross-test state cannot leak.

**Acceptance Criteria:**
- Given `maxAttempts=3` and a queue of `(503, "", "")`, `(503, "", "")`, `(200, "", '{"results":[{"index":0,"relevance_score":0.9}]}')`, when `Engine.Rerank("q", "[\"x\"]", cfg)` runs, then the third HTTP attempt succeeds and one row `(originalIndex=0, candidate="x", score=0.9)` is returned.
- Given a queue seeded with `(429, "Retry-After: 1", "")` then `(200, "", '{"results":[]}')`, when `Engine.Rerank` runs, then the retry honors the header and the second attempt succeeds; total wall time is at least 1 second.
- Given a queue seeded with `(400, "", "bad-request")`, when `Engine.Rerank` runs, then it throws after exactly 1 attempt with a message naming status 400 and the body snippet.
- Given `^omniReRank.Breaker("cohere|rerank-v3.5")` seeded with `$LB(5, NowSeconds())`, when `Engine.Rerank` runs, then it throws with `"circuit breaker open"` in the message and no HTTP attempt is made.
- Given the breaker key is `$LB(5, NowSeconds()-61)` (cooldown elapsed), when `Engine.Rerank` runs with a `(200, "", '{"results":[]}')` queue, then the call succeeds and the breaker global is reset to `$LB(0,0)`.
- Given five consecutive `Engine.Rerank` calls each throw a provider error, when a sixth call is made, then it throws the breaker-open message without dispatching to the provider (queue not consumed).

## Implementation Notes

<!-- append-only during implementation -->

**2026-09-07 — implemented and verified on live IRIS via `iris-agentic-dev`**

Changes:
- `src/dc/omniReRank/provider/Base.cls` — added `RetryWithBackoff`, `ComputeBackoffDelay`, private `RetryParam`, and the `PostOnce(request, url) As %Status` injection seam; `Execute` delegates to `RetryWithBackoff`. `Execute` remains non-`[Final]`.
- `src/dc/omniReRank/Engine.cls` — added `ProviderKey` (`provider|modelName`, no `apiBase`), `Parameter FAILURETHRESHOLD=5`/`COOLDOWNSECONDS=60`, and `[Internal]` `CheckBreaker`/`RecordSuccess`/`RecordFailure`/`NowSeconds`; dispatch is now `check → try → record`. Breaker persists at `^omniReRank.Breaker(providerKey) = $LB(failures, openedAtSeconds)`.
- `tests/dc/omniReRank/unittests/MockHttpProvider.cls` — pops `(status, headers, body)` triples FIFO from `^||omniReRankMockPostQueue`; empty queue throws; sentinel `status = "ERR"` returns a `%Status` error to exercise the transport-error path.
- `tests/dc/omniReRank/unittests/TestResilience.cls` — 13 tests, one per matrix row plus one per breaker method. Each test overrides `config.retry.baseDelayMs = 1` except the real `Retry-After: 1` test (asserts ≥0.9s elapsed).

Two incidental fixes on the bootstrap-era code (both were latent bugs matching risks flagged in the prior spec's Implementation Notes):
- `src/dc/omniReRank/RerankResult.cls` — the bootstrap-era `%OnNew(rows)` collided with `%SQL.CustomResultSet`'s Final `%OnNew` on this IRIS build; replaced with an explicit `SetRows(rows)` method, and `Engine.Rerank` now does `%New()` + `SetRows(...)`.
- `tests/dc/omniReRank/unittests/TestCohere.cls` — `MakeConfig` helper now also sets `VectorLength` and required embedding fields so `%Embedding.Config.%Save()` no longer silently failed with `#10202: VectorLength not set` on this IRIS build.

Verification:
- `iris-agentic-dev compile src/dc/omniReRank/... tests/dc/omniReRank/unittests/...` — all 8 classes OK, zero errors.
- `iris-agentic-dev exec 'set ^UnitTestRoot="/home/irisowner/dev/tests" do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — All PASSED: TestCohere (16) + TestResilience (13) = 29 tests green.

Deferred (out of scope, per spec locks): provider fallbacks (`TryFallback` + `AssertVectorSpaceCompatible` + `LoadFallbackConfig` — a follow-up spec).

## Design Notes

Deliberately not copied from omniEmbedding:
- **Fallback loop** (`TryFallback`, `LoadFallbackConfig`, `AssertVectorSpaceCompatible`) — deferred; provider selection stays 1-to-1 in this spec.
- **`apiBase` in the breaker key** — no provider in `omniReRank` currently reads it, so its inclusion would just make the key noisier without adding discrimination.

Mock queue shape (test-only):
```
^||omniReRankMockPostQueue(1) = $LB(503, "", "")
^||omniReRankMockPostQueue(2) = $LB(429, "Retry-After: 1", "")
^||omniReRankMockPostQueue(3) = $LB(200, "", '{"results":[{"index":0,"relevance_score":0.9}]}')
```
`MockHttpProvider.PostOnce` pops the lowest-numbered entry, sets `request.HttpResponse.StatusCode`/`Data`/`GetHeader` accordingly (via a small helper), and returns `$$$OK`. On empty queue it throws — test starvation is a test bug, not a silent zero.

## Verification

**Commands (via `iris-agentic-dev`, which is already reachable on this workstation):**
- `iris-agentic-dev compile src/dc/omniReRank` -- expected: zero compile errors across `Base.cls`, `Engine.cls`, and the two test classes.
- `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc.omniReRank.unittests")'` -- expected: every test in `TestCohere` (from the bootstrap spec) AND `TestResilience` passes; PASSED count matches the sum of methods in both classes.
- `iris-agentic-dev query "SELECT COUNT(*) FROM %Dictionary.CompiledClass WHERE Name %STARTSWITH 'dc.omniReRank.'"` -- expected: >= 6 (Base, Cohere, Engine, RerankResult, MockProvider, MockHttpProvider) and TestCohere/TestResilience.
