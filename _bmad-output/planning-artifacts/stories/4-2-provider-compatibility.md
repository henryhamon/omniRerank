# Story 4-2 — Provider-compatibility contract for fallbacks

**Epic:** 4 — Fallback Chain (v2)
**Status:** pending
**Governed by:** AD-9 (score-space isolation), AD-7 (explicit provider).
**Ships together with:** Story 4-1 in one bmad-build session (splitting produces a non-shippable Epic 4).
**Resolves:** PRD §8 Q1 — pins the strictest safe fallback-compatibility default.

## As a…

Platform engineer, I want the Engine to reject a fallback whose score-space is incompatible with the primary BEFORE any HTTP call, so I never receive a merged or blended ranking that lies about relative relevance across providers.

## Acceptance

1. `Engine.AssertProviderCompatible(primaryCfg, fallbackCfg, fallbackName) [ Internal ]` throws before any HTTP when the compatibility rule fails.
2. Compatibility rule v2 (default; **the one that ships in this story**): **exact `provider|modelName` match** with the primary. Rationale documented in the class comment: two different `modelName` values on the same provider produce different score scales; same-model swap across `apiBase` (multi-region, private routes) is the only always-safe fallback shape. This is deliberately strict — this AC pins the safe default for v2. Loosening this contract requires a future spec.
3. When rejection fires, the thrown message states `"score-space mismatch"`, names the fallback, and shows both `(provider, modelName)` pairs — never leaks any credential value.
4. `TestFallback.cls` (from Story 4-1) adds cases:
   - Fallback with different `modelName` on the same provider → throws with `"score-space mismatch"` naming both configs; no HTTP.
   - Fallback with different `provider` value → throws with `"score-space mismatch"`; no HTTP.
   - Fallback with matching `provider|modelName` but different `apiBase` → passes the check and is attempted normally.
5. All prior tests still green.

## Design Notes (documented in the class comment; NOT implemented in this story)

**Alternative future contract — operator-maintained compatibility list:**
```
^omniReRank.Compat("primaryProvider|primaryModel") = $LB("okProvider1|okModel1", "okProvider2|okModel2", ...)
```
An operator would explicitly declare which cross-provider swaps they trust as score-space-comparable (e.g. after benchmarking Cohere `rerank-v3.5` vs. Voyage `rerank-2` on their own corpus). `AssertProviderCompatible` would check the primary's `providerKey` against the list. This is v3+ material — do NOT ship in Story 4-2.

## Out of scope

- The operator-maintained compatibility list described in Design Notes.
- Score normalization / rescaling — forbidden by AD-9.

## Verification

- `iris-agentic-dev compile src/dc/omniReRank/... tests/dc/omniReRank/unittests/...` — zero errors.
- `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — all green.
