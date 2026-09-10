---
title: dc.omniReRank — Epics & Stories
created: 2026-09-07
updated: 2026-09-07
stepsCompleted: [1, 2, 3, 4]
sources:
  - _bmad-output/planning-artifacts/prds/prd-omniRerank-2026-09-07/prd.md
  - _bmad-output/planning-artifacts/architecture/architecture-omniRerank-2026-09-07/ARCHITECTURE-SPINE.md
  - _bmad-output/implementation-artifacts/spec-omnirerank-bootstrap-cohere.md
  - _bmad-output/implementation-artifacts/spec-omnirerank-resilience.md
---

# dc.omniReRank — Backlog

## Requirements Inventory

**Functional (from PRD §4):**

| FR | Capability | Governed by |
|----|-----------|-------------|
| FR-1 | One-call reranking from SQL | AD-2, AD-8 |
| FR-2 | Config in `%Embedding.Config` | AD-3 |
| FR-3 | Fail-fast argument validation | AD-2, AD-7 |
| FR-4 | Cohere provider | AD-1 |
| FR-5 | Voyage, Jina, Ollama providers | AD-1, AD-4, AD-7 |
| FR-6 | `Base.Execute` remains virtual | AD-1 |
| FR-7 | Retry with exponential backoff | AD-6 |
| FR-8 | Circuit breaker with cooldown | AD-5, AD-9 |
| FR-9 | Credential safety | AD-4 |

**Non-Functional / Cross-cutting (from PRD §5, §6.2, §7 counter-metrics):**
- No score merging across providers (Non-Goal + AD-9)
- No REST surface, no client caching, no telemetry export in v1
- SM-2: zero credential leaks in error paths (grep-checked in CI)
- SM-3: adding a new Provider ≤ one working session
- SM-4: retry-driven recovery ratio ≥ 95% on synthetic-429 tests
- SM-C1: retry count is a health signal, not something to minimize

## Epics List

| Epic | Title | Status | Covers |
|------|-------|--------|--------|
| **Epic 1** | Foundation, SQL Surface & Cohere Provider | ✅ **DONE** (Phase 1) | FR-1, FR-2, FR-3, FR-4, FR-6, FR-9 |
| **Epic 2** | Resilience — Retries & Circuit Breaker | ✅ **DONE** (Phase 3) | FR-7, FR-8 |
| **Epic 3** | Provider Expansion — Voyage, Jina, Ollama | 🔲 pending | FR-5 |
| **Epic 4** | Fallback Chain (v2) | 🔲 pending | v2 Deferred from Spine |
| **Epic 5** | Demo, README & Release Prep | 🔲 pending | PRD §6.1 (worked example + per-provider README), SM-3 evidence |

**Dependency graph:**
```
Epic 1 ──▶ Epic 2 ──▶ Epic 3 ──▶ Epic 5
                       │
                       └───────▶ Epic 4 (needs ≥ 2 providers to be meaningful)
```

**FR coverage sanity check:** every FR from the inventory above is claimed by exactly one epic (FR-1..4,6,9 → Epic 1; FR-7,8 → Epic 2; FR-5 → Epic 3). Cross-cutting Non-Goals live in every epic's Boundaries automatically (they are AD-level invariants).

---

## Epic 1 — Foundation, SQL Surface & Cohere Provider ✅ DONE

**Goal:** Ship a working `dc.omniReRank` package end-to-end — abstract Base, one real provider (Cohere), SQL entry point, credential resolution — so the surface any later story extends is already alive.

**Status:** Shipped in [spec-omnirerank-bootstrap-cohere.md](../implementation-artifacts/spec-omnirerank-bootstrap-cohere.md). 16 unit tests green on live IRIS.

### Story 1-1 — Base + Cohere + SQL entry point ✅ DONE

- **As** an IRIS developer, **I can** call `CALL dc_omniReRank.Engine_Rerank(:query, :candidatesJson, :configName)` from SQL and receive a `(originalIndex, candidate, score)` result set sorted by score DESC, **so I don't write a Cohere HTTP client by hand.**
- **Acceptance** (from shipped spec's Acceptance Criteria, all green):
  - Valid `%Embedding.Config` row with `rerank` sub-block + `Ens.Config.Credentials` entry → 3 rows returned in Cohere's order with 0-based original indices.
  - Missing credential → named exception, no HTTP.
  - Empty candidates `[]` → empty result set, no HTTP, no config lookup.
  - Missing `configName` → exception naming the missing config and identifying `%Embedding.Config` as the store checked.
  - Missing `rerank` sub-block → exception naming the config and stating the sub-block is required.
- **Covers:** FR-1, FR-2, FR-3, FR-4, FR-6, FR-9.
- **Evidence:** [spec-omnirerank-bootstrap-cohere.md](../implementation-artifacts/spec-omnirerank-bootstrap-cohere.md).

---

## Epic 2 — Resilience: Retries & Circuit Breaker ✅ DONE

**Goal:** Turn transient upstream failures into recovered requests, and stop hammering broken endpoints — without changing the SQL surface.

**Status:** Shipped in [spec-omnirerank-resilience.md](../implementation-artifacts/spec-omnirerank-resilience.md). 13 unit tests green on live IRIS.

### Story 2-1 — Retry with exponential backoff on Base ✅ DONE

- **As** an IRIS developer, **I want** the reranker to retry 429 and 5xx responses with exponential backoff (honoring `Retry-After`), **so a transient upstream hiccup does not surface as a hard error to my caller.**
- **Acceptance** (all shipped-spec ACs green):
  - `(503, 503, 200)` sequence → third attempt succeeds.
  - `(429 with Retry-After: 1, 200)` → second attempt succeeds after ≥1s wait.
  - `400` → throws after 1 attempt (fast-fail).
  - Persistent `500` with `maxAttempts=3` → throws after 3 attempts naming status, URL, attempts count.
  - Transport error → throws with `TransportHint` mentioning HTTPS/`sslConfig` on https URLs.
- **Covers:** FR-7.

### Story 2-2 — Circuit breaker on Engine ✅ DONE

- **As** a platform engineer, **I want** the gateway to open a circuit breaker after 5 consecutive failures per `provider|modelName`, **so a broken provider does not consume request budget for 60 seconds.**
- **Acceptance** (all shipped-spec ACs green):
  - Breaker key `$LB(5, now)` → next call throws `"circuit breaker open"` pre-dispatch (queue not consumed).
  - Breaker key `$LB(5, now-61)` → next call allowed through (half-open); success resets to `$LB(0, 0)`.
  - Five consecutive throws + sixth call → sixth short-circuits without HTTP.
- **Covers:** FR-8.

### Story 2-3 — Transport mock (`PostOnce` seam + `MockHttpProvider`) ✅ DONE

- **As** a test author, **I want** to exercise every branch of `Base.Execute` (retry loop, fast-fail, transport error) without hitting a real network, **so the resilience contract has real coverage in CI.**
- **Acceptance** (shipped): `MockHttpProvider` overrides `PostOnce`, pops FIFO `$LB(status, headers, body)` from `^||omniReRankMockPostQueue`, throws on starvation, supports the sentinel `"ERR"` for the transport-error path.
- **Covers:** AD-10 test-seam invariant; enables ACs of Story 2-1 and 2-2.

---

## Epic 3 — Provider Expansion 🔲 pending

**Goal:** Prove the "swap provider in config" story from PRD UJ-2 and UJ-3 by shipping three additional Providers under the exact `Base` contract. This epic validates SM-3 (adding a Provider ≤ one working session).

**Sequence:** stories are independent — pick any order. Voyage first is a reasonable warm-up (closest API shape to Cohere); Ollama last covers the authless / local path.

### Story 3-1 — Voyage provider

**File:** [stories/3-1-voyage-provider.md](stories/3-1-voyage-provider.md)

- **As** an IRIS developer, **I can** set `rerank.provider = "voyage"` and `rerank.modelName = "rerank-2"` in my `%Embedding.Config`, **and my existing `CALL dc_omniReRank.Engine_Rerank(...)` starts calling Voyage AI instead of Cohere with no other code change.**
- **Acceptance:**
  1. `dc.omniReRank.provider.Voyage` extends `Base` with the five hooks; `Execute` NOT overridden.
  2. `GetRerankUrl` → `https://api.voyageai.com/v1/rerank` (verify current at implementation time).
  3. `BuildPayload` → `{query, documents, model, top_k}`; `top_k` defaults to `candidates.%Size()` when unset.
  4. `SetAuth` → `Bearer <ResolveApiKey(config)>` — same pattern as Cohere.
  5. `ParseResponse` → iterates `data[]` yielding `{index, relevance_score}` as `%DynamicArray` of `{index, score}`.
  6. `ValidateConfig` throws when `modelName` or `apiKey` missing.
  7. `Engine.ResolveProvider` accepts `"voyage"` and maps to `dc.omniReRank.provider.Voyage`; the "unknown provider" error message lists `voyage` alongside `cohere`.
  8. `tests/dc/omniReRank/unittests/TestVoyage.cls` covers the same I/O matrix rows as `TestCohere`: `BuildPayload` shape, `BuildPayload` explicit `topK`, `ParseResponse` valid, `ParseResponse` missing `data`, `SetAuth` Bearer via credential hook, `ValidateConfig` missing model, `ValidateConfig` missing apiKey.
  9. `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` → `TestVoyage` all green, prior `TestCohere` + `TestResilience` still green.
- **Governed by:** AD-1 (Template Method), AD-4 (credentials by name), AD-7 (explicit provider registration).
- **Effort:** ≤ 1 bmad-build session.

### Story 3-2 — Jina provider

**File:** [stories/3-2-jina-provider.md](stories/3-2-jina-provider.md)

- **As** an IRIS developer, **I can** set `rerank.provider = "jina"` and `rerank.modelName = "jina-reranker-v2-base-multilingual"`, **and reranking flows through Jina's v1 rerank endpoint.**
- **Acceptance:**
  1. `dc.omniReRank.provider.Jina` extends `Base` with the five hooks; `Execute` NOT overridden.
  2. `GetRerankUrl` → `https://api.jina.ai/v1/rerank` (verify at implementation time).
  3. `BuildPayload` → `{model, query, documents, top_n}`; `top_n` defaults to `candidates.%Size()`.
  4. `SetAuth` → `Bearer <ResolveApiKey(config)>`.
  5. `ParseResponse` → iterates `results[]` yielding `{index, relevance_score}`.
  6. `ValidateConfig` throws when `modelName` or `apiKey` missing.
  7. `Engine.ResolveProvider` accepts `"jina"`; the "unknown provider" error message lists `jina`.
  8. `tests/dc/omniReRank/unittests/TestJina.cls` covers the same I/O matrix rows as `TestCohere`.
  9. All prior tests still green.
- **Governed by:** AD-1, AD-4, AD-7.
- **Effort:** ≤ 1 bmad-build session.

### Story 3-3 — Ollama provider (authless / local)

**File:** [stories/3-3-ollama-provider.md](stories/3-3-ollama-provider.md)

- **As** a privacy-focused solutions architect, **I can** point `rerank.provider = "ollama"` at my internal BGE endpoint (`rerank.apiBase = "http://ollama.internal:11434"`), **and rerank inside the datacenter with no `apiKey` required.**
- **Acceptance:**
  1. `dc.omniReRank.provider.Ollama` extends `Base` with the five hooks; `Execute` NOT overridden.
  2. `GetRerankUrl` → `<config.apiBase>/api/rerank` (target Ollama ≥ 0.6.0 — PRD §8 Q2); throws in `ValidateConfig` when `apiBase` missing.
  3. `BuildPayload` → `{model, query, documents, top_n}`; `top_n` defaults to `candidates.%Size()`.
  4. `SetAuth` → NO-OP (Ollama is authless); `ValidateConfig` MUST NOT require `apiKey` (deliberate deviation from other providers).
  5. `ParseResponse` → shape TBD at implementation time — the story spec must pin the exact Ollama response shape and reject anything else with `Body:` dump.
  6. `ValidateConfig` throws when `modelName` or `apiBase` missing; does NOT check `apiKey`.
  7. `Engine.ResolveProvider` accepts `"ollama"`; error message lists `ollama`.
  8. `tests/dc/omniReRank/unittests/TestOllama.cls` covers: `BuildPayload`, `ParseResponse` valid/malformed, `ValidateConfig` missing `apiBase`, `ValidateConfig` missing `modelName`, `ValidateConfig` does NOT require `apiKey`.
  9. `iris-agentic-dev query "SELECT COUNT(*) FROM %Dictionary.CompiledClass WHERE Name %STARTSWITH 'dc.omniReRank.'"` returns ≥ 10 (Base, Cohere, Voyage, Jina, Ollama, Engine, RerankResult, 3 test classes + mocks).
- **Governed by:** AD-1, AD-7. Deliberately not governed by AD-4 (no credential).
- **Effort:** ≤ 1 bmad-build session **plus** a live Ollama endpoint check to freeze the response shape.
- **Open question resolution:** Story spec must pin the Ollama rerank contract as it exists at implementation time; if `/api/rerank` is unavailable, spec must document the prompt-template shim fallback (PRD §8 Q2).

---

## Epic 4 — Fallback Chain (v2) 🔲 pending

**Goal:** When the primary provider fails after retries (or the breaker is open), try a compatible secondary provider before surfacing the error to the caller — without ever mixing scores across providers (AD-9).

**Depends on:** Epic 3 (fallback with only one provider registered is meaningless).

### Story 4-1 — Fallback list in config + one-provider-at-a-time execution

**File:** [stories/4-1-fallback-list.md](stories/4-1-fallback-list.md)

- **As** a platform engineer, **I can** list secondary configs at `rerank.fallbacks: ["ConfigB", "ConfigC"]`, **and when the primary throws after retries the Engine tries each in order until one succeeds or all exhaust.**
- **Acceptance:**
  1. `Engine.Rerank` reads `rerank.fallbacks` from the primary config; absent or empty array → no fallback, primary error propagates as today.
  2. On primary throw (after retries) OR primary breaker open, the Engine loads each named fallback via `%Embedding.Config.%OpenId(name).Configuration.rerank`, dispatches through the normal path (each fallback gets its own breaker key, its own retry budget).
  3. Every fallback is passed through `AssertProviderCompatible(primary, fallback, name)` **BEFORE** any HTTP call. Incompatibility is fatal — never quiet fall-through. See Story 4-2 for the compatibility rule.
  4. Only ONE Provider produces the returned `RerankResult` — the first that succeeds. AD-9 invariant: no code path concatenates or blends `results[]` across providers. A code-review checklist item enforces this.
  5. When every fallback throws, the Engine throws with a message listing the primary reason and every attempted fallback name — no fallback name is omitted.
  6. `tests/dc/omniReRank/unittests/TestFallback.cls` covers: primary success (no fallback consulted); primary throw + first fallback success; primary throw + all fallbacks throw (message lists every attempt); primary breaker open + first fallback success.
- **Governed by:** AD-5, AD-9. Extends AD-2 (Engine still mediates every call).
- **Open questions to resolve in the story spec:**
  - Does the breaker also gate fallback attempts? (Recommendation: yes — each fallback has its own key, its own state.)
  - Retry budget per fallback: independent (default) or shared cap across the chain?

### Story 4-2 — Provider-compatibility contract for fallbacks

**File:** [stories/4-2-provider-compatibility.md](stories/4-2-provider-compatibility.md)

- **As** a platform engineer, **I want** the Engine to reject a fallback whose score-space is incompatible with the primary BEFORE any HTTP call, **so I never receive a merged / blended ranking that lies about relative relevance.**
- **Acceptance:**
  1. `Engine.AssertProviderCompatible(primaryCfg, fallbackCfg, fallbackName) [ Internal ]` throws before any HTTP when the compatibility rule fails.
  2. Compatibility rule v2 (proposed default; confirm before implementation): **exact `provider|modelName` match with the primary.** Rationale: two different `modelName` values on the same provider still produce different score scales; a same-model swap across `apiBase` (multi-region, private routes) is the only always-safe fallback shape. This is deliberately strict — the PRD's §8 Q1 flagged this as the v2 open question; this AC pins the strictest safe default.
  3. Alternative future contract (documented in Design Notes, not implemented in this story): an **operator-maintained compatibility list** — `^omniReRank.Compat("primaryProvider|primaryModel") = $LB("okProvider1|okModel1", ...)`. Story 4-2 does NOT ship this; only the strict rule ships.
  4. `TestFallback.cls` adds cases: fallback with different `modelName` on the same provider → throws with "score-space mismatch" naming both configs; fallback with different `provider` → throws.
- **Governed by:** AD-9 (score-space isolation), AD-7 (explicit provider).
- **Effort:** ships together with Story 4-1 in one bmad-build session; splitting would produce a non-shippable Epic 4.

---

## Epic 5 — Demo, README & Release Prep 🔲 pending

**Goal:** Turn the library into something an outside developer can adopt in an afternoon — a runnable demo, per-provider docs, and enough README to justify the Open Exchange listing.

### Story 5-1 — Worked example: vector search + rerank stored procedure

**File:** [stories/5-1-demo-stored-procedure.md](stories/5-1-demo-stored-procedure.md)

- **As** an IRIS developer evaluating the library, **I want** a small demo — a table, some seeded rows, and a stored procedure that vector-searches then reranks — **so I can see the end-to-end flow without reading the source.**
- **Acceptance:**
  1. `src/dc/sample/omniReRank/demo/Catalog.cls` — `%Persistent` with `Id`, `Title`, `Description`, `Embedding %Vector(...)`.
  2. `src/dc/sample/omniReRank/demo/Seed.cls` — classmethod that seeds ~20 rows across a couple of topics; embeddings computed via `dc.omniEmbedding` if reachable, otherwise pre-shipped fixture vectors.
  3. `src/dc/sample/omniReRank/demo/Search.cls:Search(query, k)` — `%SqlProc` that: (a) does a `VECTOR_COSINE`-ordered top-K search on `Catalog`, (b) joins the top-K against `CALL dc_omniReRank.Engine_Rerank(:query, :candidatesJson, 'CatalogSearchV1')`, (c) returns `(Id, Title, cosineScore, rerankScore)` in rerank order.
  4. `iris-agentic-dev exec 'do ##class(dc.sample.omniReRank.demo.Seed).Run() zw ##class(dc.sample.omniReRank.demo.Search).Search("best iris tutorials", 5)'` → returns 5 rows with monotonically decreasing `rerankScore`.
  5. `README.md` §"Demo" walks through the four steps a fresh clone needs (docker up, load module, seed, call).
- **Governed by:** AD-2, AD-3, AD-8.
- **Depends on:** Epic 1 only. Can ship before Epic 3 completes.

### Story 5-2 — Per-provider README pages

**File:** [stories/5-2-provider-readmes.md](stories/5-2-provider-readmes.md)

- **As** an IRIS developer choosing a provider, **I want** one page per Provider with its config keys, one working `%Embedding.Config` JSON example, model examples, and one known gotcha, **so I don't have to read the source to onboard a new backend.**
- **Acceptance:**
  1. `docs/providers/cohere.md`, `docs/providers/voyage.md`, `docs/providers/jina.md`, `docs/providers/ollama.md` — one per Provider actually shipped.
  2. Each page contains: full sample `%Embedding.Config.Configuration` JSON (with `rerank` sub-block), the required + optional config keys with types, at least two `modelName` examples, and one "gotcha" section (e.g. Cohere `input_type` doesn't apply to rerank; Ollama needs `apiBase`).
  3. Every JSON sample validates against the Provider's `ValidateConfig` when loaded (test: `TestReadmeExamples.cls` reads each `docs/providers/*.md`, parses the fenced ```json``` blocks, and calls `ValidateConfig`).
  4. `README.md` links to every `docs/providers/*.md`.
- **Depends on:** Epic 3 (a page per Provider means Providers must exist).

### Story 5-3 — CI grep for credential leaks (SM-2 evidence)

**File:** [stories/5-3-ci-credential-leak-check.md](stories/5-3-ci-credential-leak-check.md)

- **As** a platform maintainer, **I want** CI to fail if any exception string in `dc.omniReRank.*` could plausibly emit a resolved credential value, **so the SM-2 promise ("zero credential leaks in error paths") has teeth.**
- **Acceptance:**
  1. `tests/dc/omniReRank/unittests/TestCredentialSafety.cls` — instruments a test hook that returns a sentinel-string password (`"OMNIRERANK_LEAK_SENTINEL_XYZ"`), triggers every code path in `Base`, `Cohere`, `Voyage`, `Jina`, `Ollama`, and `Engine` that throws (invalid config, 401, 403, 404, 500, transport error), captures every `%Status` message, asserts the sentinel appears in NONE of them.
  2. GitHub Actions workflow adds a step running this test after every push.
  3. If the sentinel ever appears in an error message, the offending frame is named in the test failure output.
- **Governed by:** AD-4.
- **Depends on:** Epic 3 (need every Provider in scope). Coverage grows story-by-story as Providers land — the test iterates the compiled Provider list, so newly added Providers get checked automatically.

### Story 5-4 — Open Exchange release cut

**File:** [stories/5-4-release-cut.md](stories/5-4-release-cut.md)

- **As** the maintainer, **I can** publish `dc.omniReRank` v1.0.0 to InterSystems Open Exchange, **so the library is discoverable and installable via IPM by any IRIS developer.**
- **Acceptance:**
  1. `module.xml` version bumped to `1.0.0`; `Description` reflects the v1 provider set.
  2. PRD §8 Q4 resolved: final package name casing pinned in `module.xml` and README (recommendation: keep `dc.omniReRank` — matches every shipped file).
  3. Full CI green on a clean clone: docker build, IPM install, `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` → all tests pass.
  4. `CHANGELOG.md` created with entries for the two shipped specs and every Epic 3–5 story that landed.
  5. Open Exchange listing draft ready for review (screenshots of demo output, feature list matching PRD §4, "not for" list matching PRD §5).
- **Depends on:** Epics 1, 2, 3, 5 (Story 5-1, 5-2, 5-3). Epic 4 is v2 — not a v1 release blocker.

---

## Coverage Check

Every FR in the inventory maps to at least one story:

| FR | Stories | Status |
|----|---------|--------|
| FR-1 | 1-1 | ✅ |
| FR-2 | 1-1 | ✅ |
| FR-3 | 1-1 | ✅ |
| FR-4 | 1-1 | ✅ |
| FR-5 | 3-1, 3-2, 3-3 | 🔲 |
| FR-6 | 1-1 (invariant preserved), 3-1, 3-2, 3-3 (re-asserted per Provider) | ✅ shipped; re-checked per story |
| FR-7 | 2-1 | ✅ |
| FR-8 | 2-2 | ✅ |
| FR-9 | 1-1 (mechanism), 5-3 (CI enforcement) | ✅ mechanism / 🔲 CI |

Cross-cutting AD-9 (no score merging) covered by Story 4-2's compatibility contract + a code-review checklist item enforced in Story 4-1.

## Deferred (v2+ — do NOT create stories yet)

- **Metrics / telemetry export** — PRD §6.2. Wait for a user asking.
- **Response caching** — PRD Non-Goal. Wait for a user asking.
- **REST wrapper service** — PRD Non-Goal.
- **Score normalization column on `RerankResult`** — PRD §8 Q5. Wait for a user asking.
- **`apiBase` in the breaker key** — Spine deferred. Reintroduce when a Provider actually reads `apiBase` for dispatch (Ollama does not — same key across regions is fine).
