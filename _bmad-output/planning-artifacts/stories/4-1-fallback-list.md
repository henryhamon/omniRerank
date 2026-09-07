# Story 4-1 — Fallback list in config + one-provider-at-a-time execution

**Epic:** 4 — Fallback Chain (v2)
**Status:** pending
**Governed by:** AD-5, AD-9. Extends AD-2.
**Depends on:** Epic 3 complete (fallback with one Provider registered is meaningless).

## As a…

Platform engineer, I can list secondary configs at `rerank.fallbacks: ["ConfigB", "ConfigC"]` in my primary `%Embedding.Config`, and when the primary throws after retries (or its breaker is open) the Engine tries each fallback in order until one succeeds or all exhaust — without ever mixing scores across providers.

## Acceptance

1. `Engine.Rerank` reads `rerank.fallbacks` from the primary config's `rerank` sub-block. Absent or empty array → no fallback attempted, primary error propagates as today.
2. On primary throw (after retries) OR primary `CheckBreaker` returning open, the Engine loads each named fallback via `%Embedding.Config.%OpenId(name).Configuration.rerank`, dispatches through the normal path. Each fallback gets ITS OWN breaker key and its OWN retry budget.
3. Every fallback goes through `AssertProviderCompatible(primaryCfg, fallbackCfg, fallbackName)` BEFORE any HTTP call (see Story 4-2). Incompatibility is fatal — never quiet fall-through, never HTTP.
4. Exactly ONE Provider produces the returned `RerankResult` — the first fallback that succeeds. AD-9 invariant enforced: no code path concatenates or blends `results[]` across providers. A code-review checklist item is added to CONTRIBUTING.md enforcing this.
5. When every fallback throws, the Engine throws with a message listing the primary reason AND every attempted fallback name — no fallback name is omitted.
6. Fallback loading errors (config not found, JSON invalid, no `rerank` sub-block) throw with the same actionable messages as the primary-load path; the fallback name is always in the message.
7. `tests/dc/omniReRank/unittests/TestFallback.cls` covers: primary success (no fallback consulted, no `%OpenId` on fallback names); primary throw + first fallback success; primary throw + all fallbacks throw (message lists every attempt); primary breaker open + first fallback success.
8. All prior tests still green.

## Open questions to resolve in the story spec

- **Does the breaker also gate fallback attempts?** Recommendation: yes — each fallback carries its own key, its own state. A fallback whose own breaker is open is skipped (as if it had thrown) and the loop moves on.
- **Retry budget per fallback:** independent (default recommendation) or a shared cap across the chain? Story spec should pin one and cite the reason.

## Out of scope

- Score normalization across providers — forbidden by AD-9.
- Automatic reordering of the fallback list based on recent success rate — v3 feature at best.

## Verification

- `iris-agentic-dev compile src/dc/omniReRank/... tests/dc/omniReRank/unittests/...` — zero errors.
- `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — all green.
