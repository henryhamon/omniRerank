# Story 5-3 — CI grep for credential leaks (SM-2 evidence)

**Epic:** 5 — Demo, README & Release Prep
**Status:** pending
**Governed by:** AD-4 (credentials by name; secrets never in errors).
**Depends on:** Epic 3 (coverage grows as Providers land; the test iterates the compiled Provider list).

## As a…

Platform maintainer, I want CI to fail if any exception string emitted anywhere under `dc.omniReRank.*` could plausibly contain a resolved credential value, so the SM-2 promise ("zero credential leaks in error paths") has real teeth — not just a doc-level assertion.

## Acceptance

1. `tests/dc/omniReRank/unittests/TestCredentialSafety.cls`:
   - Sets `^||omniReRankCredential("SentinelCred") = "OMNIRERANK_LEAK_SENTINEL_XYZ"`.
   - Iterates every compiled Provider class under `dc.omniReRank.provider.*` except `Base`, discovered via `%Dictionary.CompiledClass`.
   - For each Provider, triggers every throw path with a config referring to `apiKey = "SentinelCred"`:
     - `ValidateConfig` on missing `modelName` (crafted to reach the throw AFTER the sentinel was resolvable, so a leak into a compound error message is caught).
     - `SetAuth` producing an `Authorization` header (verifies header is set to `Bearer OMNIRERANK_LEAK_SENTINEL_XYZ` — that's expected — but then triggers a downstream throw and asserts the sentinel is NOT in the thrown `%Status`).
     - `Base.RetryWithBackoff` fast-fail on 401, 403, 404, 422, 429 (via `MockHttpProvider` seeded queue).
     - `Base.RetryWithBackoff` exhaustion on persistent 500 (via `MockHttpProvider`).
     - `Base.PostOnce` transport error (via `MockHttpProvider` `"ERR"` sentinel).
   - Captures every `%Status` message via `$System.Status.GetErrorText`.
   - Asserts `$Find(msg, "OMNIRERANK_LEAK_SENTINEL_XYZ") = 0` for every captured message.
   - On failure, prints the offending Provider class and the exact leaked message.
2. Also covers the Engine path: `Engine.Rerank` with a config pointing at `SentinelCred`, primary throws → captured Engine error string checked for the sentinel.
3. `.github/workflows/ci.yml` (or existing workflow) adds a step that runs this test after every push. Workflow fails on any sentinel match.
4. Documentation: `docs/security/credential-safety.md` explains the sentinel-based check, the test hook, and how to add coverage when introducing a new Provider (recommendation: none needed — the test discovers Providers via `%Dictionary.CompiledClass`).

## Out of scope

- Static analysis of source code for `%s` / `_` credential concatenation — the runtime test above is strictly stronger.
- Log-line inspection (this library does not log by design; if that changes, extend this test).

## Verification

- `iris-agentic-dev compile tests/dc/omniReRank/unittests/TestCredentialSafety.cls` — zero errors.
- `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — green.
- Deliberate regression test: temporarily inject `_ key` into one Provider's `SetAuth` error message → CI fails naming that Provider; revert.
