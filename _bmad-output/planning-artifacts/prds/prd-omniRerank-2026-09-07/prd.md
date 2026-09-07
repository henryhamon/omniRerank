---
title: dc.omniReRank
created: 2026-09-07
updated: 2026-09-07
status: final
---

# PRD: dc.omniReRank

*Universal reranking gateway for InterSystems IRIS 2026.*

## 0. Document Purpose

This PRD consolidates the vision for `dc.omniReRank` for the product owner, contributors, and the downstream architecture / epics-and-stories workflows. It is structured with a Glossary-anchored vocabulary, features grouped with globally-numbered FRs nested underneath, cross-cutting NFRs in their own section, and assumptions tagged inline (`[ASSUMPTION: ...]`) and indexed at the end. Two implementation slices are already merged and green — [spec-omnirerank-bootstrap-cohere.md](../../../implementation-artifacts/spec-omnirerank-bootstrap-cohere.md) (Phase 1: Base + Cohere + SQL entry) and [spec-omnirerank-resilience.md](../../../implementation-artifacts/spec-omnirerank-resilience.md) (Phase 2: retry + circuit breaker) — and this PRD treats those as the shipped MVP baseline it now extends toward v1.

## 1. Vision

`dc.omniReRank` is a single SQL entry point that takes a query and a list of candidate texts, sends them to a cross-encoder rerank model, and returns the candidates in relevance order. Behind that entry point lives a provider abstraction that speaks Cohere, Voyage, Jina, and a local Ollama / BGE deployment, with the operational plumbing — retries with exponential backoff, a per-provider circuit breaker, structured credential lookup — that a production IRIS deployment expects.

Vector search alone plateaus at "correct set, wrong order": cosine similarity finds the right documents but ranks them poorly for the user's intent. Cross-encoder rerankers are the industry-standard fix, but no native abstraction exists in the IRIS ecosystem — every team writes the same glue against a slightly different provider. `dc.omniReRank` closes that gap using the exact architectural pattern already proven in its sibling `dc.omniEmbedding`: a `[Abstract]` provider `Base` with a Template-Method `Execute`, a thin `Engine` for dispatch and resilience, and a `%SqlProc` classmethod as the SQL surface.

The library is deliberately narrow. It reranks. It does not embed, retrieve, chunk, or orchestrate — those are the jobs of `omniEmbedding` today and `omniRAG` tomorrow. Keeping the surface small keeps the library composable: reranking is one predictable primitive that any pipeline can call from SQL without inheriting a framework.

## 2. Target User

### 2.1 Jobs To Be Done

- **When an IRIS developer builds semantic search over a vector-indexed table,** they want to reorder the top-K candidates by relevance to the query with one SQL call, **so their users see the best answer first without them having to write a Cohere/Voyage/Jina HTTP client from scratch.**
- **When a data engineer's rerank provider throttles or degrades,** they want the library to retry transient failures and stop hammering a broken endpoint automatically, **so a provider incident does not turn into an IRIS outage.**
- **When an IRIS admin manages secrets,** they want API keys to live in `Ens.Config.Credentials` and be resolved by name, **so credentials never leak into `%Embedding.Config` JSON, logs, or error traces.**
- **When a team already runs `dc.omniEmbedding`,** they want the reranker to share configuration ergonomics and error-handling conventions, **so operating both feels like one library, not two.**
- **When a privacy-conscious deployment cannot send text to a SaaS provider,** they want to point the same SQL entry point at a local Ollama-hosted BGE reranker, **so the choice of provider is a config change, not a code rewrite.**

### 2.2 Non-Users (v1)

- Consumer applications talking to the reranker directly over HTTP — the surface is SQL / ObjectScript, not REST.
- IRIS deployments that need to rerank inside a stored-procedure trigger with sub-10-ms latency — rerankers are network calls; latency depends on the provider.
- Teams looking for a full RAG framework — `omniRAG` is the future composition project (see §5).

### 2.3 Key User Journeys

Lightweight — this is a developer library, so JTBD carries persona context and the journeys are single-sentence flows.

- **UJ-1. Marina, IRIS backend developer, reranks the top-20 vector hits inside her search stored procedure.** She adds a `rerank` sub-block to the existing `%Embedding.Config` row her search already uses, then joins her vector-search CTE against `CALL dc_omniReRank.Engine_Rerank(:query, :candidatesJson, 'ProductSearchV3')` to reorder the rows before returning them — one round trip, no client-side plumbing.
- **UJ-2. Bruno, platform engineer, ships a rerank-provider switch during an incident.** Cohere returns 429s for ten minutes; the breaker opens after five failures and fast-fails subsequent calls. Bruno updates the `rerank.provider` in `%Embedding.Config` from `cohere` to `voyage`, and traffic keeps flowing without a deploy.
- **UJ-3. Alice, privacy-focused solutions architect, stays inside the perimeter.** She points `rerank.provider` at `ollama` and `rerank.apiBase` at her internal BGE endpoint. No text leaves the datacenter; the SQL entry point is identical to what SaaS callers use.

## 3. Glossary

- **Rerank Gateway** — the `dc.omniReRank` library and everything it exposes to callers. One SQL entry point, one Engine, one provider abstraction.
- **Provider** — a concrete adapter class under `dc.omniReRank.provider.*` that speaks one external reranker's HTTP contract. Extends `Base`.
- **Base** — abstract `dc.omniReRank.provider.Base`. Owns the Template-Method `Execute`, `RetryWithBackoff`, `ResolveApiKey`, and hint helpers. `Execute` is virtual (no `[Final]`) so a Provider with unusual ordering constraints may override.
- **Engine** — `dc.omniReRank.Engine`. Owns the SQL entry point `Rerank(query, candidatesJson, configName)`, provider resolution, the Circuit Breaker, and result-set construction. Exactly one Provider is invoked per call.
- **%Embedding.Config Row** — a `%Embedding.Config` persistent row whose `Configuration` JSON contains a `rerank` sub-block. This is where per-namespace reranker configuration lives; there is no separate `dc.omniReRank.Config` persistent class.
- **Rerank Sub-Block** — the JSON object at `%Embedding.Config.Configuration.rerank`. Minimum keys: `provider`, `modelName`, `apiKey`. Optional keys documented per Provider (`topN`, `sslConfig`, `httpTimeout`, `apiBase`, `retry.*`).
- **API Key** — never the raw secret. Always the *name* of an `Ens.Config.Credentials` row; the real secret lives encrypted in `Ens.Config.Credentials.Password`.
- **Circuit Breaker** — the per-`provider|modelName` reliability state persisted at `^omniReRank.Breaker`. Opens after `FAILURETHRESHOLD` (5) consecutive failures for `COOLDOWNSECONDS` (60s), half-opens on the next call after cooldown, resets to `$LB(0,0)` on success.
- **Rerank Result Set** — `dc.omniReRank.RerankResult`, a `%SQL.CustomResultSet` yielding rows `(originalIndex INT, candidate VARCHAR, score DOUBLE)` sorted by `score DESC`. `originalIndex` is the caller's 0-based index into `candidatesJson`.
- **Fallback** — a secondary `%Embedding.Config` row's `rerank` sub-block invoked when the primary provider fails after retries. **Deferred to v2**; see §5 and §6.
- **Vector-Space Equivalence** — the invariant used by `dc.omniEmbedding` fallbacks to prevent mixing vector spaces. In reranking there is no vector space; the analog is *score-space isolation* — different providers return scores on incomparable scales, so results from two providers must never be merged silently. See NFR-Sec-3 and Non-Goals.

## 4. Features

### 4.1 SQL Rerank Entry Point

**Description:** A `%SqlProc` classmethod that takes the user's query, a JSON array of candidate strings, and the name of a configured `%Embedding.Config` row, and returns a sorted result set. This is the only surface consumer code should touch. Realizes UJ-1. Fails loudly and specifically on every misconfiguration so operators can act on the error message alone.

**Functional Requirements:**

#### FR-1: One-call reranking from SQL

An IRIS caller can execute `CALL dc_omniReRank.Engine_Rerank(:query, :candidatesJson, :configName)` from any SQL surface (embedded SQL, xDBC, JDBC, `%SQL.Statement`) and receive a result set. Realizes UJ-1.

**Consequences (testable):**
- The result set exposes columns `originalIndex INT`, `candidate VARCHAR`, `score DOUBLE`.
- Rows are ordered by `score DESC`; ties preserve the provider's returned order.
- `originalIndex` is the caller's 0-based index into `candidatesJson`; every returned row carries the exact `candidate` text the caller passed at that index.
- Passing an empty JSON array (`'[]'`) returns an empty result set and issues no HTTP call and no `%Embedding.Config` lookup.

#### FR-2: Configuration lives in `%Embedding.Config`

An operator can add a `rerank` sub-block to an existing `%Embedding.Config` row and use the same row name as `configName` — no separate persistent class, no duplicate secrets. Realizes UJ-1, UJ-2.

**Consequences (testable):**
- The Engine loads `%Embedding.Config` by `configName` via `%OpenId`.
- The Engine parses `%Embedding.Config.Configuration` as JSON and reads the `rerank` sub-object.
- If the row does not exist, the thrown error names both the missing name and identifies `%Embedding.Config` as the store checked.
- If the row exists but the `Configuration` JSON has no `rerank` sub-block, the thrown error names the row and states that a `rerank` object with `{provider, modelName, apiKey}` is required.

#### FR-3: Fail-fast argument validation

Every misuse produces an actionable exception before any HTTP or persistent-store call, so callers never wait for a network timeout to learn they passed bad input.

**Consequences (testable):**
- Malformed `candidatesJson` throws before any config lookup, naming the offending argument.
- Empty `query` (after config exists and candidates are non-empty) throws before any HTTP call, naming the `query` argument.
- Missing `configName` throws before any store lookup, naming the missing argument.
- Unknown `provider` value throws with the list of currently-valid providers.

### 4.2 Provider Abstraction

**Description:** Every reranker vendor is a subclass of `dc.omniReRank.provider.Base`. Adding a new Provider requires implementing five hooks (`ValidateConfig`, `SetAuth`, `GetRerankUrl`, `BuildPayload`, `ParseResponse`) — everything else (retries, backoff, credential resolution, error hints) is inherited. Realizes UJ-2, UJ-3.

**Functional Requirements:**

#### FR-4: Cohere provider — v1 shipped

`dc.omniReRank.provider.Cohere` implements the Cohere v2 `/rerank` API: `{query, documents, model, top_n}` payload, `Bearer <resolved-key>` auth, `results:[{index, relevance_score}, ...]` response.

**Consequences (testable):**
- `topN` defaults to `candidates.%Size()` when not set in config, so callers always get a score for every input.
- `ValidateConfig` throws when `modelName` or `apiKey` is missing, before any HTTP.
- `ParseResponse` throws with the raw body dumped when the `results` field is absent or malformed — never returns an empty array on a parse failure.

#### FR-5: Voyage, Jina, and Ollama providers — v1 targets

Additional Providers ship in v1 so the "swap provider in config" story is real: `Voyage` (Voyage AI `rerank-*` models), `Jina` (Jina Reranker v2), `Ollama` (local `bge-reranker-*` and any Ollama-hosted cross-encoder).

**Consequences (testable):**
- Each Provider passes an equivalent I/O matrix to Cohere: `ValidateConfig` catches missing required fields, `ParseResponse` throws on malformed body, happy-path returns scored rows.
- Ollama's `ValidateConfig` does *not* require `apiKey` — a local endpoint is authless — but requires `apiBase`.
- Every Provider inherits `RetryWithBackoff` and `ResolveApiKey` from `Base` without override.

#### FR-6: `Base.Execute` remains virtual

`Base.Execute` is not declared `[Final]`, so a future Provider with a legitimate ordering constraint (e.g. request signing that must run after the body is written) can override the whole template. Realizes an explicit compatibility principle inherited from `dc.omniEmbedding`.

**Consequences (testable):**
- Compiled `dc.omniReRank.provider.Base` shows `Execute` without the `[Final]` keyword.
- The bootstrap and resilience specs both encode this as an invariant in their "Always" clauses; regression is caught by inspection during code review.

### 4.3 Resilience — Retries and Circuit Breaker

**Description:** Transient upstream failures (429, 5xx, transport hiccups) are retried with exponential backoff and jitter, and repeated failures against the same `provider|modelName` open a persisted circuit breaker so a broken endpoint is not hammered. Both mechanisms already shipped in the resilience spec; this PRD codifies them as v1 contract. Realizes UJ-2.

**Functional Requirements:**

#### FR-7: Retry with exponential backoff on transient failures

`Base.RetryWithBackoff` retries on HTTP 429 and 5xx, fast-fails on other 4xx, and honors the `Retry-After` header when present and numeric.

**Consequences (testable):**
- Defaults: `maxAttempts=3`, `baseDelayMs=500`, `maxDelayMs=8000`, `honorRetryAfter=1`.
- Every default is overridable per-config via `rerank.retry.*`.
- Backoff formula: `min(baseDelayMs * 2^(attempt-1) + rand(baseDelayMs), maxDelayMs)`.
- A numeric `Retry-After` (when `honorRetryAfter=1`) supersedes the computed delay.
- Non-429 4xx statuses fast-fail with a status hint that names the credential name (never the value).

#### FR-8: Circuit breaker with cooldown

`Engine` tracks per-`provider|modelName` failure counts at `^omniReRank.Breaker`. After `FAILURETHRESHOLD` (5) consecutive failures the breaker opens for `COOLDOWNSECONDS` (60s); the next call after cooldown is allowed through as half-open; success resets, failure re-opens.

**Consequences (testable):**
- Open breaker throws with `"circuit breaker open"` in the message *before* dispatching to the provider — no HTTP is attempted.
- Success writes `$LB(0, 0)` explicitly (not merely deleting the global), so successive successes are cheap and observable.
- Breaker state is persisted (a namespace restart preserves it) and per-namespace (a compromise: not global, not per-process).

### 4.4 Credential Safety

**Description:** API keys are never stored in `%Embedding.Config` JSON, never logged, never included in exceptions. The library treats `rerank.apiKey` as a *name* and resolves the secret from `Ens.Config.Credentials`. Realizes UJ-2.

**Functional Requirements:**

#### FR-9: `ResolveApiKey` reads from `Ens.Config.Credentials`

`Base.ResolveApiKey(config)` looks up `config.apiKey` in `Ens.Config.Credentials` and returns `Password`. Callers must treat the return value as secret.

**Consequences (testable):**
- The returned secret never appears in any exception message thrown by `dc.omniReRank.*` — only the credential *name* does.
- Missing-credential errors name the credential and state which namespace's `Ens.Config.Credentials` store was checked.
- A process-private test hook `^||omniReRankCredential(name)` overrides the persistent store during unit tests — production paths never read this global.

## 5. Non-Goals (Explicit)

- **Not a RAG framework.** No embedding, no retrieval, no chunking, no LLM orchestration. `omniRAG` is a separate future composition project.
- **Never silently merges scores across Providers.** Providers score on incomparable scales; a fallback that returned a merged ranking would give the caller a lie. If v2 fallbacks ship, they will only fail over between compatible providers and never blend result sets.
- **No provider auto-detection from `modelName` alone.** Unlike `omniEmbedding`, the Rerank Engine requires an explicit `provider` value in the config. Name-prefix inference is quiet magic that surprises operators — always require the operator to state their intent.
- **No REST surface.** The library is SQL-first + ObjectScript-callable. A REST wrapper would be a separate service, not part of this library.
- **No client-side caching.** Response caching invites cache-key subtleties (query + candidates + model + provider version) that we prefer to leave to the caller.
- **No metrics/telemetry export in v1.** Observability lands as a v2 concern (see §6.2).

## 6. MVP Scope

### 6.1 In Scope

- **Already shipped (bootstrap + resilience specs, merged):** `Base` (virtual `Execute`, retry+backoff, `ResolveApiKey`, hints), `Engine` (SQL entry, config load, breaker), `Cohere` provider, `RerankResult`, mock provider + HTTP mock in tests. 29 unit tests green on live IRIS via `iris-agentic-dev`.
- **v1 completion targets** (this PRD adds on top of the shipped baseline):
  - `Voyage` provider (FR-5).
  - `Jina` provider (FR-5).
  - `Ollama` provider (FR-5) — proves the authless / local-endpoint path.
  - A short README section per provider naming the config keys, model examples, and one known gotcha.
  - A worked example: a stored procedure that vector-searches a demo table, joins against `Engine_Rerank`, and returns the reordered rows.

### 6.2 Out of Scope for MVP

- **Provider fallbacks** (`rerank.fallbacks` array, cross-provider fail-over) — deferred to v2. `[NOTE FOR PM]` this is the most-requested feature from the resilience spec review; revisit if MVP timeline allows a compatible-provider fallback (same score-space contract) without silent merging.
- **Metrics / telemetry export** (per-provider latency histograms, breaker-open counters) — deferred to v2.
- **Streaming or batched rerank across multiple queries in one HTTP call** — no provider we target exposes it cleanly; deferred until one does.
- **A REST wrapper service** — see §5.
- **Per-tenant rate limiting inside the library** — belongs at the IRIS SQL gateway or at the provider account.
- **Cohere v3 / new-shape APIs** — track when they GA; v1 pins to Cohere v2.

## 7. Success Metrics

**Primary**

- **SM-1**: **Providers shipped in v1 = 4** (Cohere, Voyage, Jina, Ollama). Validates FR-4, FR-5.
- **SM-2**: **Zero credential leaks in error paths.** Every thrown exception in `dc.omniReRank.*` is grep-checked in CI to contain no value read from `Ens.Config.Credentials.Password`; only credential names may appear. Validates FR-9.
- **SM-3**: **`bmad-build` cycle time per new Provider ≤ one working session.** With `Base` doing the heavy lifting, adding Voyage / Jina / Ollama should each be one spec + one implementation session + green tests. Validates FR-5, FR-6.

**Secondary**

- **SM-4**: **Retry-driven recovery ratio on synthetic-429 tests ≥ 95%.** With `maxAttempts=3` and honored `Retry-After`, at least 95% of injected transient failures resolve within the retry loop. Validates FR-7.
- **SM-5**: **Breaker-open share on a healthy provider = 0%** across a 24h synthetic soak. Validates FR-8.

**Counter-metrics (do not optimize)**

- **SM-C1**: **Number of retries per successful call.** Do NOT drive this to zero — a small retry rate is the sign that FR-7 is doing its job absorbing transient upstream noise. Counterbalances SM-4.
- **SM-C2**: **Provider count.** Do NOT keep adding Providers past the v1 four unless a real user of `omniReRank` is asking for one. Provider count is a maintenance liability, not a feature win. Counterbalances SM-1.

## 8. Open Questions

1. **v2 fallback contract** — when we ship provider fallbacks, what is the analog of `omniEmbedding`'s vector-space-equivalence check? Provisional answer: *only allow fallbacks whose `provider|modelName` is on an explicit compatibility list the operator maintains*, so no silent score-scale mixing. Confirm before v2.
2. **Ollama `rerank` API surface** — Ollama's rerank surface is still stabilizing (some builds expose `/api/rerank`, others require `/api/generate` with a prompt template). Which contract does the `Ollama` provider target? `[ASSUMPTION: /api/rerank in Ollama ≥ 0.6.0; if unavailable at implementation time, fall back to a prompt-template shim behind the same `Base` contract.]`
3. **`%Embedding.Config` schema tolerance** — `MakeConfig` in the resilience-spec test helper sets `EmbeddingClass`, `VectorDataType`, `VectorLength` behind `Try/Catch` to survive schema variance across IRIS builds. Is there a documented minimum IRIS 2026 build we should pin in `module.xml`? `[NOTE FOR PM]`
4. **Public naming** — the library is currently `dc.omniReRank` (mixed case). Open Exchange conventions favor lowercase (`dc.omniRerank` or `dc.omni_rerank`). Rename before v1 public release, or accept the mixed case?
5. **Score exposure** — the SQL result set exposes the raw provider `score`. Do we want an optional `normalizedScore DOUBLE` column (min-max within the current result set) so client code can threshold consistently across providers? Only introduce if a real caller asks — see SM-C2.

## 9. Assumptions Index

- Inline assumption from §8 Q2 — Ollama exposes `/api/rerank` at implementation time for the `Ollama` provider; prompt-template shim is the fallback strategy behind the same `Base` contract.
- Inline assumption from §8 Q3 — a documented minimum IRIS 2026 build exists that supplies `%Embedding.Config` with `EmbeddingClass`, `VectorDataType`, and `VectorLength` present but not required for reranker-only rows.
- Implicit assumption from FR-9 — every deployment that uses SaaS Providers has `Ens.Config.Credentials` available in the target namespace. Ollama-only deployments do not need it.
