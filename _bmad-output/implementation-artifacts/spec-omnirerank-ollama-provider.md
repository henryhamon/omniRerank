---
title: 'omniReRank Ollama provider: prompt-template shim over /api/chat (LLM-as-judge)'
type: 'feature'
created: '2026-09-10'
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'f03a6590cae9cd1268d8218b5f297adb18305ac5'
story_key: '3-3-ollama-provider'
context:
  - '{project-root}/_bmad-output/planning-artifacts/stories/3-3-ollama-provider.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-omniRerank-2026-09-07/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 3-3 pending. Ollama does not expose a native `/api/rerank` (confirmed against Ollama's HTTP API docs on 2026-09-10 — only `/api/embed`, `/api/generate`, `/api/chat`, and model-management endpoints exist). But PRD UJ-3 ("privacy-focused deployment, no text leaves the datacenter, same SQL entry point") requires a local option. The story spec explicitly sanctioned building a prompt-template shim when the native endpoint is missing — and required the shim design be pinned in a spec before code.

**Approach:** Ship `dc.omniReRank.provider.Ollama` as an **LLM-as-judge** shim: send a scoring prompt to `<apiBase>/api/chat` with `format: "json"` and `stream: false`, asking an instruction-tuned model to return `{"rankings":[{"index":<int>,"score":<float>}, ...]}` for every candidate. The Provider extends `Base` implementing the five hooks; `Execute` is NOT overridden. `SetAuth` is a no-op (Ollama is authless). `ValidateConfig` requires `modelName` and `apiBase` — deliberately does NOT require `apiKey`. Response parsing pulls `body.message.content` (a JSON string when `format: "json"`), re-parses it as JSON, extracts `rankings[]`, throws with `Body:` dump on any structural mismatch. Register `"ollama"` in `Engine.ResolveProvider`.

**Decisions locked at spec-time (2026-09-10):**
- (D1) Endpoint: `POST <config.apiBase>/api/chat` (chosen over `/api/generate` because `/api/chat` is the modern instruction-tuned entry point and cleanly separates system/user roles).
- (D2) Request options: `{model, messages, format:"json", stream:false, options:{temperature:0}}`. `temperature:0` for reproducibility; users who want sampling override via `rerank.chatOptions` (see D4).
- (D3) Prompt template (baked-in default): a two-message conversation — one system message that fixes the JSON output contract and one user message carrying `Query: <query>` followed by an enumerated `Candidates:` list. Every candidate index MUST appear exactly once in `rankings[]`; the parser throws on missing indices with an actionable message.
- (D4) Escape hatches for advanced users, both optional in config:
  - `rerank.promptTemplate`: full string override of the default system prompt. When set, the operator owns correctness — the schema contract is unchanged.
  - `rerank.chatOptions`: `%DynamicObject` merged into the outgoing `options` field (e.g. `{"temperature":0.2,"num_ctx":8192}`). Merge is shallow; `temperature:0` default is overridden if the caller supplies one.
- (D5) `apiKey` explicitly NOT required — regression-guarded by test.
- (D6) Response validation is strict: exactly one `rankings[]` entry per input candidate; scores clamped to `[0.0, 1.0]` on read (raw score preserved in the result); duplicate indices reject.
- (D7) The story's original open question "response shape" is resolved by owning the shape — the shim mandates the schema.

## Boundaries & Constraints

**Always:**
- `dc.omniReRank.provider.Ollama` extends `dc.omniReRank.provider.Base` and implements only the five abstract hooks; `Execute` is NOT overridden (AD-1).
- `SetAuth` is a no-op (Ollama is authless — deliberate deviation from other Providers, invariant per PRD FR-5).
- `ValidateConfig` requires `modelName` and `apiBase`; does NOT require `apiKey`.
- `GetRerankUrl` returns `<config.apiBase>/api/chat` — throws in `ValidateConfig` (not `GetRerankUrl`) when `apiBase` is missing so the failure surfaces before any HTTP setup.
- `ParseResponse` throws with `Body:` dump when any of: `message` missing, `message.content` missing, `message.content` not valid JSON, parsed JSON missing `rankings` array, `rankings` size ≠ input candidate count, `rankings` contains duplicate indices, `rankings` contains an index outside `[0, N)`.
- `Engine.ResolveProvider` maps `"ollama"` → `dc.omniReRank.provider.Ollama` (AD-7); the unknown-provider error message lists `cohere, voyage, jina, ollama`.

**Never:**
- No override of `Execute`, `RetryWithBackoff`, `PostOnce`, `ResolveApiKey`, `StatusHint`, or `TransportHint`.
- No credential lookup — the Provider MUST NOT call `ResolveApiKey`. If a caller sets `rerank.apiKey`, it is silently ignored (documented in per-provider README, Story 5-2).
- No streaming (`stream: false` fixed). Streaming reranking has no meaningful semantics.
- No prompt template that says "answer in natural language" — the JSON contract is load-bearing.
- No support for `/api/generate` or `/api/embed` in this Provider — those are separate architectures (Story 5-1 uses `/api/embed` through `dc.omniEmbedding`, not this Provider).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| BuildPayload default | `candidates=["a","b","c"]`, config `{modelName:"llama3.1:8b-instruct", apiBase:"http://ollama:11434"}` | Payload has `model="llama3.1:8b-instruct"`, `stream=false`, `format="json"`, `options.temperature=0`, `messages` with 2 entries (system + user); user message contains `Query:` and `0: a`, `1: b`, `2: c` | N/A |
| BuildPayload custom promptTemplate | Same, config `{promptTemplate:"CUSTOM SYSTEM"}` | System message content equals `"CUSTOM SYSTEM"` exactly; user message unchanged | N/A |
| BuildPayload custom chatOptions | Config `{chatOptions:{temperature:0.3,num_ctx:8192}}` | `options.temperature=0.3` (caller override wins), `options.num_ctx=8192` merged | N/A |
| GetRerankUrl | `apiBase="http://ollama:11434"` | Returns `"http://ollama:11434/api/chat"` | N/A |
| GetRerankUrl trailing slash | `apiBase="http://ollama:11434/"` | Returns `"http://ollama:11434/api/chat"` (single slash) | N/A |
| SetAuth no-op | Any config, `request` freshly created | `request.Authorization` remains empty; no call to `ResolveApiKey` | N/A |
| ValidateConfig apiKey NOT required | Config `{modelName:"m",apiBase:"http://x"}` (no apiKey) | Does NOT throw — regression guard for the authless invariant | N/A |
| ValidateConfig missing modelName | `{apiBase:"http://x"}` | Throws naming `modelName` | Named exception |
| ValidateConfig missing apiBase | `{modelName:"m"}` | Throws naming `apiBase` | Named exception |
| ParseResponse valid | Body `{"message":{"role":"assistant","content":"{\"rankings\":[{\"index\":2,\"score\":0.9},{\"index\":0,\"score\":0.5},{\"index\":1,\"score\":0.1}]}"}}` for 3-candidate input | `%DynamicArray` of 3 `{index, score}` entries in the order the model returned | N/A |
| ParseResponse malformed inner JSON | `message.content = "not-json"` | Throws naming the JSON parse failure with `Body:` dump | Named exception |
| ParseResponse missing message | Body `{"foo":1}` | Throws naming `message`, `Body:` dump | Named exception |
| ParseResponse missing rankings | `message.content = "{\"foo\":1}"` | Throws naming `rankings`, `Body:` dump | Named exception |
| ParseResponse wrong count | 3 candidates, but `rankings` has 2 entries | Throws stating expected 3 got 2, `Body:` dump | Named exception |
| ParseResponse duplicate index | `rankings=[{"index":0},{"index":0},{"index":2}]` | Throws naming duplicate index 0, `Body:` dump | Named exception |
| ParseResponse index out of range | `rankings=[{"index":5,...}]` for 3 candidates | Throws stating index 5 out of `[0,3)`, `Body:` dump | Named exception |
| Engine dispatch on `"ollama"` | Config `rerank.provider="ollama"`, MockProvider override | Engine routes to `dc.omniReRank.provider.Ollama` | N/A |
| Engine unknown provider | `rerank.provider="rerankly"` | Throws listing `cohere, voyage, jina, ollama` in the valid set | Named exception |

</frozen-after-approval>

## Code Map

- `src/dc/omniReRank/provider/Base.cls` — parent. Note: `ParseResponse` signature returns `%DynamicArray`; the `Ollama.ParseResponse` needs the input `candidateCount` for the wrong-count check, which the current `ParseResponse` signature does NOT accept. Two options: (a) add `candidateCount` to the `ParseResponse` signature on `Base` and update Cohere/Voyage/Jina to accept-and-ignore it, or (b) stash the count on a per-invocation basis via a `[ThreadPrivate]` classmethod state, or (c) let Ollama's `Execute` (still virtual — AD-1 permits override for ordering constraints) override the sequence to validate against the count itself. **Chosen approach: (a)** — cleanest, no state, no `Execute` override. See Task 1 below.
- `src/dc/omniReRank/provider/Cohere.cls`, `Voyage.cls`, `Jina.cls` — must accept the new `candidateCount` parameter on `ParseResponse`. Body unchanged; signature-only edit.
- `src/dc/omniReRank/Engine.cls` — extend `ResolveProvider` with the `ollama` branch. Update both "unknown provider" error messages to list `cohere, voyage, jina, ollama`. `Base.Execute` needs to pass `candidates.%Size()` to `ParseResponse` — check whether `Execute` is on `Base` or `Engine`; per shipped code `Execute` lives on `Base` and receives `candidates`, so the signature threading is one line.
- `tests/dc/omniReRank/unittests/TestOllama.cls` — new test class following `TestJina.cls`'s structure with the ~17 tests the I/O matrix demands.
- `tests/dc/omniReRank/unittests/TestCohere.cls` — one-line update to `TestEngineUnknownProvider` asserting `ollama` in valid list.
- No changes to `Cohere.ParseResponse`, `Voyage.ParseResponse`, `Jina.ParseResponse` bodies — only their `ParseResponse` signatures need the added parameter. Their existing tests continue to pass because they invoke `ParseResponse(body)` — with a defaulted parameter, both call shapes work. Confirm by re-running the full suite after signature changes.

## Tasks & Acceptance

**Execution:**
- [x] `src/dc/omniReRank/provider/Base.cls` -- change abstract signature `ParseResponse(body As %DynamicObject) As %DynamicArray` to `ParseResponse(body As %DynamicObject, candidateCount As %Integer = 0) As %DynamicArray`. Update `Base.Execute` to pass `candidates.%Size()` as the second argument. Default value 0 preserves back-compat for the existing three Providers whose ParseResponse ignores the count.
- [x] `src/dc/omniReRank/provider/Cohere.cls` -- update `ParseResponse` signature to accept `candidateCount As %Integer = 0` (parameter unused in body). Do NOT change parse logic.
- [x] `src/dc/omniReRank/provider/Voyage.cls` -- same signature update; body unchanged.
- [x] `src/dc/omniReRank/provider/Jina.cls` -- same signature update; body unchanged.
- [x] `src/dc/omniReRank/provider/Ollama.cls` -- new class extending `Base`. Implement: `GetRerankUrl` (concatenate `apiBase` + `/api/chat`, collapse any duplicated slash between base and path), `SetAuth` (no-op, no `ResolveApiKey` call), `BuildPayload` (build the two-message chat request with `format:"json"`, `stream:false`, `options.temperature=0` merged under `rerank.chatOptions`; system message from `rerank.promptTemplate` if set, else the baked-in default; user message is `"Query: <query>\n\nCandidates:\n0: <cand0>\n1: <cand1>\n..."`), `ParseResponse(body, candidateCount)` (extract `body.message.content`, re-parse as JSON, extract `rankings[]`, validate count matches `candidateCount`, validate no duplicate indices, validate each index in `[0, candidateCount)`, return `%DynamicArray` of `{index, score}` in the model's returned order — do NOT re-sort here; Engine sorts), `ValidateConfig` (require `modelName` and `apiBase`, do NOT require `apiKey`, actionable messages).
- [x] `src/dc/omniReRank/Engine.cls` -- extend `ResolveProvider`: add `ollama` branch mapping to `dc.omniReRank.provider.Ollama`; update BOTH "unknown provider" error messages to `"Valid: cohere, voyage, jina, ollama"`.
- [x] `tests/dc/omniReRank/unittests/TestOllama.cls` -- one test per I/O matrix row (17 total): BuildPayload default (system+user shape, format:"json", stream:false, temperature:0, indexed candidates), BuildPayload custom promptTemplate, BuildPayload custom chatOptions (merge behavior + caller-override-wins), GetRerankUrl basic, GetRerankUrl trailing slash, SetAuth no-op (assert `Authorization` stays empty AND `ResolveApiKey` is not reachable — implemented by NOT setting `^||omniReRankCredential` and asserting no throw), ValidateConfig apiKey not required (regression guard), ValidateConfig missing modelName, ValidateConfig missing apiBase, ParseResponse valid, ParseResponse malformed inner JSON, ParseResponse missing message, ParseResponse missing rankings, ParseResponse wrong count, ParseResponse duplicate index, ParseResponse index out of range, Engine dispatches to Ollama (MockProvider override), Engine unknown-provider error lists ollama.
- [x] `tests/dc/omniReRank/unittests/TestCohere.cls` -- update `TestEngineUnknownProvider` assertion to also expect `ollama` in the valid-list substring.

**Acceptance Criteria:**
- Given a `%Embedding.Config` row `OllamaLocal` whose `Configuration` JSON contains `"rerank": {"provider":"ollama","modelName":"llama3.1:8b-instruct","apiBase":"http://ollama:11434"}` (no `apiKey`), when `CALL dc_omniReRank.Engine_Rerank('q', '["a","b","c"]', 'OllamaLocal')` dispatches through a `MockHttpProvider` seeded with `(200, "", '{"message":{"role":"assistant","content":"{\"rankings\":[{\"index\":2,\"score\":0.9},{\"index\":0,\"score\":0.5},{\"index\":1,\"score\":0.1}]}"}}')`, then the returned result set has three rows sorted DESC by score with `originalIndex` values 2, 0, 1.
- Given the same config with `apiKey` deliberately omitted, when `Ollama.ValidateConfig(cfg)` runs, then it does NOT throw (regression guard for AD-4 deviation).
- Given the same config with `apiBase` missing, when `Ollama.ValidateConfig(cfg)` runs, then it throws naming `apiBase` before any HTTP call.
- Given `MockHttpProvider` returns a body whose `message.content` parses to `{"rankings":[{"index":0,"score":0.5}]}` for a 3-candidate input, when Engine dispatches, then `Ollama.ParseResponse` throws stating expected 3 got 1 with `Body:` dump.
- Given `Engine.ResolveProvider("rerankly")`, then the thrown message lists all four of `cohere`, `voyage`, `jina`, and `ollama` in the valid set.
- Given the full test suite runs under `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'`, then TestOllama cases pass AND every prior TestCohere, TestResilience, TestVoyage, and TestJina case still passes (the `ParseResponse` signature widening is back-compatible).

## Implementation Notes

<!-- append-only during implementation -->

**2026-09-10 — implemented and verified on live IRIS via `iris-agentic-dev`**

Changes:
- `src/dc/omniReRank/provider/Base.cls` — abstract `ParseResponse` signature widened to `(body, candidateCount As %Integer = 0)`; `Execute` passes `candidates.%Size()`.
- `src/dc/omniReRank/provider/Cohere.cls`, `Voyage.cls`, `Jina.cls` — signature-only widening; bodies unchanged; back-compat preserved by default value.
- `src/dc/omniReRank/provider/Ollama.cls` — new. LLM-as-judge shim over `/api/chat` with `format:"json"`, `stream:0`, `options.temperature:0` merged under `rerank.chatOptions`. `DEFAULTSYSTEMPROMPT` parameter carries the baked-in schema contract; `rerank.promptTemplate` overrides. `SetAuth` no-op. `ValidateConfig` requires `modelName` + `apiBase`, NOT `apiKey`. Strict parser: missing message / bad inner JSON / missing rankings / count mismatch / duplicate index / out-of-range all throw with `Body:` dump. Scores clamped to [0,1].
- `src/dc/omniReRank/Engine.cls` — `ollama` branch added; unknown-provider error now lists `cohere, voyage, jina, ollama`.
- `tests/dc/omniReRank/unittests/TestOllama.cls` — 17 tests, one per I/O matrix row.
- `tests/dc/omniReRank/unittests/TestCohere.cls` — `TestEngineUnknownProvider` also asserts `ollama` in valid list.
- `tests/dc/omniReRank/unittests/MockProvider.cls`, `MockHttpProvider.cls` — signature-only `ParseResponse` widening to match Base.

Verification:
- `iris-agentic-dev compile ...` — 13 files OK, zero errors.
- `iris-agentic-dev exec 'set ^UnitTestRoot=... RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — All PASSED. TestCohere (16) + TestResilience (13) + TestVoyage (9) + TestJina (9) + TestOllama (17) = 64 tests green.

Design decision recap for future readers: Ollama has no native `/api/rerank` (confirmed 2026-09-10). This Provider uses the LLM-as-judge shim over `/api/chat`. Quality depends on the chosen model (`llama3.1:8b-instruct` and larger recommended). If Ollama ever ships native rerank, this Provider can be swapped without changing the SQL surface — Base contract preserved.

No open risks. Story 3-3 acceptance criteria satisfied. Epic 3 complete.

## Design Notes

**Baked-in default system prompt** (implementation MUST use this exact wording; changes require a follow-up spec because caller reproducibility depends on it):

```
You are a relevance judge for a search reranking system. You receive a query
and a numbered list of candidate texts. Your ONLY job is to score each
candidate for relevance to the query and return the result as JSON.

Output contract (STRICT):
- Return a single JSON object with one key: "rankings".
- "rankings" is an array with EXACTLY one entry per candidate index.
- Each entry has integer "index" (0-based, from the input list) and float
  "score" between 0.0 and 1.0 (higher = more relevant).
- Every candidate index MUST appear exactly once. No duplicates. No omissions.
- Return ONLY the JSON object. No prose, no code fences, no commentary.

Example: for two candidates you might return
{"rankings":[{"index":1,"score":0.85},{"index":0,"score":0.20}]}
```

The user message is generated from the query and candidates:
```
Query: <the query>

Candidates:
0: <candidate 0>
1: <candidate 1>
...
```

**Why `/api/chat` over `/api/generate`?** Chat cleanly separates the system prompt (the schema contract) from the user prompt (the actual query and candidates). With `/api/generate` we'd concatenate them into one blob and rely on model discipline. Chat is also the endpoint model authors optimize for instruction-following.

**Why `format: "json"`?** Ollama's `format: "json"` constrains the sampler to emit valid JSON. Models still hallucinate schema (missing keys, extra keys) — that's why `ParseResponse` validates strictly — but at least raw JSON parse failures become rare.

**Why not a `%SchemaSerializer` or a JSON schema constraint parameter?** Ollama accepts a JSON schema as the `format` value in newer builds, which could enforce the `rankings[]` shape at the model level. Deliberately NOT used here: it's not supported by every model Ollama runs, adds a hidden compatibility matrix, and our post-parse validation catches every deviation anyway. Revisit in a follow-up spec if operator demand appears.

**Why the parameter widening to `ParseResponse`?** Cohere/Voyage/Jina's response bodies self-report their result count (each `results[].index` is the source of truth). Ollama's is a JSON string produced by a model that could invent, drop, or duplicate indices — we need the input count as a ground truth to validate against. Widening the abstract signature to `ParseResponse(body, candidateCount)` with a default of 0 is the least-invasive fix and preserves backward compatibility for the three shipped Providers whose bodies don't need the hint.

**Ollama-specific status hints (deferred, not shipped here).** `Base.StatusHint` currently emits Cohere/Voyage/Jina-flavored copy referencing `apiKey`. For Ollama a 404 usually means the model isn't pulled, not a bad model name. Not fixed in this spec — the shipped hint text is already generic enough, and localizing per-Provider hints deserves its own tiny spec once Story 5-3 (credential-leak CI) tightens the exception surface.

Minimal Ollama sketch:
```
ClassMethod BuildPayload(query, candidates, config) As %DynamicObject {
    Set systemPrompt = config.%Get("promptTemplate")
    If systemPrompt = "" { Set systemPrompt = ..#DEFAULTSYSTEMPROMPT }

    Set userLines = "Query: "_query_$Char(10, 10)_"Candidates:"_$Char(10)
    Set iter = candidates.%GetIterator()
    While iter.%GetNext(.k, .cand) {
        Set userLines = userLines_k_": "_cand_$Char(10)
    }

    Set opts = {"temperature":0}
    Set caller = config.%Get("chatOptions")
    If $IsObject(caller) {
        Set optIter = caller.%GetIterator()
        While optIter.%GetNext(.ok, .ov) { Do opts.%Set(ok, ov) }
    }

    Set payload = {}
    Set payload.model = config.%Get("modelName")
    Set payload.stream = 0
    Set payload.format = "json"
    Set payload.options = opts
    Set payload.messages = [
        {"role":"system","content":(systemPrompt)},
        {"role":"user","content":(userLines)}
    ]
    Return payload
}
```

## Verification

**Commands (via `iris-agentic-dev`):**
- `iris-agentic-dev compile src/dc/omniReRank/provider/... src/dc/omniReRank/Engine.cls tests/dc/omniReRank/unittests/...` -- expected: zero errors across Base, Cohere, Voyage, Jina, Ollama, Engine, and all test classes (signature widening + new class + new tests).
- `iris-agentic-dev exec 'set ^UnitTestRoot="/home/irisowner/dev/tests" do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` -- expected: All PASSED. TestCohere (16) + TestResilience (13) + TestVoyage (9) + TestJina (9) + TestOllama (17) = 64 tests green.
- `iris-agentic-dev query "SELECT COUNT(*) FROM %Dictionary.CompiledClass WHERE Name %STARTSWITH 'dc.omniReRank.provider.'"` -- expected: at least 5 (`Base`, `Cohere`, `Voyage`, `Jina`, `Ollama`).
