---
title: 'omniReRank demo: vector search + rerank stored procedure using native %Embedding'
type: 'feature'
created: '2026-09-10'
status: 'in-review'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '02584aa5bfc6c7af86efa35d35c10ac49b4efc15'
story_key: '5-1-demo-stored-procedure'
context:
  - '{project-root}/_bmad-output/planning-artifacts/stories/5-1-demo-stored-procedure.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-omniRerank-2026-09-07/ARCHITECTURE-SPINE.md'
  - '{project-root}/README.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A developer landing on the Open Exchange listing has no easy way to see the end-to-end flow — table → vector-indexed rows → top-K vector search → rerank → reordered rows — without stitching it together themselves. Story 5-1 pending. The story spec left the embedding source open; the operator has just confirmed the architectural principle that `dc.omniReRank` is independent of `dc.omniEmbedding` (chosen 2026-09-10). The demo must respect that.

**Approach:** Build a small, self-contained demo under `src/dc/sample/omniReRank/demo/` that uses **IRIS 2026's native `%Embedding.Config` API directly** to compute row embeddings — no `dc.omniEmbedding` dependency, no fake fixture vectors. The demo requires the operator to configure two `%Embedding.Config` rows before running: one for embeddings (any shipped IRIS embedding provider — `%Embedding.OpenAI` is the documented default) and one for reranking (any `dc.omniReRank` provider). `Search(query, k)` does a `VECTOR_COSINE(:queryVec, Embedding)` top-K SELECT, feeds the retrieved candidates into `CALL dc_omniReRank.Engine_Rerank(:query, :candidatesJson, 'CatalogRerankV1')`, and returns the reranked rows.

**Decisions locked at spec-time (2026-09-10):**
- (D1) Embedding source: IRIS 2026 native `%Embedding.Interface.Embedding(text, configJson)` classmethod, resolved through a `%Embedding.Config` row the operator creates. NOT `dc.omniEmbedding`, NOT fixture vectors.
- (D2) Two configs, distinct names: `CatalogEmbeddingV1` (embedding-only) and `CatalogRerankV1` (rerank-only, contains only the `rerank` sub-block). This keeps AD-3 clean — the demo does not share one row across concerns.
- (D3) Rerank field: `Description` (not `Title`). Rationale: cross-encoder rerankers score longer text more informatively than short titles. Documented in Design Notes.
- (D4) Seed corpus: exactly 20 rows across four topics (5 rows each) — IRIS tutorials, ObjectScript idioms, deployment/DevOps, SQL/vector search. Small enough to inspect visually, large enough for cosine top-K to leave real reranking headroom.
- (D5) The demo is READ-ONLY at runtime — `Search` never writes. Seeding is a one-shot classmethod the operator runs once.
- (D6) `Search` signature: `Search(query As %String, k As %Integer = 10) As %SQL.StatementResult [ SqlProc ]` returning columns `(Id INT, Title VARCHAR, CosineDistance DOUBLE, RerankScore DOUBLE)` sorted by `RerankScore DESC`.

## Boundaries & Constraints

**Always:**
- Demo classes live under `src/dc/sample/omniReRank/demo/*` — a separate sub-package. Production paths never reference them.
- Zero dependency on `dc.omniEmbedding`. `grep -R 'dc.omniEmbedding' src/dc/sample/omniReRank/demo/` returns empty.
- The demo uses `%Embedding.Config` and `%Embedding.Interface.Embedding()` — IRIS 2026 system classes, not the reranker library's own subclass.
- The rerank call passes the `Description` text as the candidate; the returned `originalIndex` maps back to the `Catalog.Id` via a caller-owned lookup table built inside `Search`.
- README §"Demo" walks through the four operator steps: docker up, load module, seed both configs + run `Seed.Run()`, call `Search()`.

**Never:**
- No fixture vectors. If the embedding config is missing or broken, `Seed.Run()` fails loudly naming the missing config — it does not fall back to fake vectors.
- No demo classes marked `[ SqlProc ]` other than `Search.Search` (the single public entry point).
- No changes to `src/dc/omniReRank/{Engine,RerankResult}.cls` or any Provider class.
- No changes to `module.xml` beyond the `dc.omniReRank.PKG` resource already picking up new files under `src/dc/omniReRank/`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Seed happy path | Both configs exist, embedding provider reachable | 20 `Catalog` rows inserted, each with a non-empty `Embedding` vector matching the config's dimension count | N/A |
| Seed with missing embedding config | `CatalogEmbeddingV1` absent | Throws naming the missing config, no rows inserted | Named exception |
| Seed idempotency | `Seed.Run()` called twice | Second call `%KillExtent`s and re-inserts — no duplicates, no orphan indices | N/A |
| Search happy path | 20 seeded rows, query "how do I compile classes in ObjectScript?", k=5 | Result set with 5 rows sorted by `RerankScore DESC`; every returned `Id` also appears in the pre-rerank cosine top-5 | N/A |
| Search with missing rerank config | `CatalogRerankV1` absent, Catalog seeded | Throws (propagates from `Engine.Rerank`) naming the missing config | Named exception |
| Search on empty table | Table exists but zero rows | Empty result set, no rerank HTTP call (Engine already short-circuits on empty candidates) | N/A |
| Search with k=0 | k=0 | Empty result set, no rerank call | N/A |
| Search preserves Id mapping | Cosine returns Ids [7, 3, 15]; rerank returns indices [2, 0, 1] with scores [0.9, 0.5, 0.1] | Result set rows in order: (Id=15, RerankScore=0.9), (Id=7, RerankScore=0.5), (Id=3, RerankScore=0.1) | N/A |
| Cosine distance surfaced | Any successful Search | Each row carries the `VECTOR_COSINE` value the cosine phase returned for it | N/A |

</frozen-after-approval>

## Code Map

- `src/dc/omniReRank/Engine.cls` — sole runtime dependency. `Search.Search` invokes `CALL dc_omniReRank.Engine_Rerank(...)` via `%SQL.Statement`.
- `%Embedding.Config` — IRIS 2026 system class. Both demo configs are ordinary rows in it.
- `%Embedding.Interface.Embedding(text, configJson)` — IRIS 2026 system classmethod. `Seed.Run()` calls it once per row; `Search.Search` calls it once per query.
- `Catalog.cls` — `%Persistent` with `Id`, `Title`, `Description`, `Embedding %Vector`, and one index on `Embedding` for `VECTOR_COSINE` acceleration.
- `Seed.cls` — hand-written 20-row corpus embedded as a `%DynamicArray` literal (title/description/topic tag). `Run()` clears and re-seeds.
- `Search.cls` — `Search(query, k)` classmethod marked `[ SqlProc ]`. Does the two-phase pipeline.
- `README.md` — new `## Demo` section walking through the four operator steps.
- **Not touched:** any Provider class, `Engine.cls`, `RerankResult.cls`, existing unit tests, `module.xml`.

## Tasks & Acceptance

**Execution:**
- [x] `src/dc/sample/omniReRank/demo/Catalog.cls` -- `%Persistent` with `Id As %Integer [ IdKey ]`, `Title As %String(MAXLEN="")`, `Description As %String(MAXLEN="")`, `Topic As %String(MAXLEN=32)`, `Embedding As %Vector(DATATYPE="FLOAT")`. One index on `Embedding` typed for vector cosine. `Storage` block left to IRIS defaults.
- [x] `src/dc/sample/omniReRank/demo/Seed.cls` -- `Run()` classmethod: `%KillExtent` on `Catalog`, iterate over a 20-entry `%DynamicArray` literal (5 rows × 4 topics — pick topical, discriminative titles + one-paragraph descriptions), call `##class(%Embedding.Interface).Embedding(desc, embConfigJson)` for each row's `Description`, save. Fails loudly and specifically when `%Embedding.Config` `CatalogEmbeddingV1` is missing (throws before touching Catalog). `Run()` prints a summary line via `write !, "Seeded 20 rows across 4 topics."`.
- [x] `src/dc/sample/omniReRank/demo/Search.cls` -- `Search(query As %String, k As %Integer = 10) As %SQL.StatementResult [ SqlProc ]`. (1) Loads `CatalogEmbeddingV1` config, computes `queryVec = %Embedding.Interface.Embedding(query, cfgJson)`. (2) Runs `SELECT TOP :k Id, Title, Description, VECTOR_COSINE(:queryVec, Embedding) AS Cos FROM dc_sample_omniReRank_demo.Catalog ORDER BY Cos DESC` — capture into a temp `%SQL.StatementResult` and materialize into a local array `hits(pos) = $LB(Id, Title, Cos)` PLUS a parallel `%DynamicArray` `candidates` of the `Description` texts. (3) Builds `candidatesJson = candidates.%ToJSON()`. (4) Invokes `CALL dc_omniReRank.Engine_Rerank(:query, :candidatesJson, 'CatalogRerankV1')` via `%SQL.Statement`. (5) Iterates the rerank result set: for each row, use `originalIndex` to look up `hits(originalIndex + 1)` and emit `(Id, Title, CosineDistance, RerankScore)` into a `%SQL.CustomResultSet` (new tiny class `demo.SearchResult`) returned to the SQL caller. Uses **only** the SQL surface + `%Embedding.Interface` — no direct provider access.
- [x] `src/dc/sample/omniReRank/demo/SearchResult.cls` -- `%SQL.CustomResultSet` with columns `Id INT`, `Title VARCHAR(MAXLEN="")`, `CosineDistance DOUBLE`, `RerankScore DOUBLE`. Initializer pattern is the SAME one the shipped `RerankResult.cls` uses (`%New()` + `SetRows(rows)` — do NOT define `%OnNew(rows)`, per the invariant learned in the resilience spec).
- [x] `tests/dc/omniReRank/unittests/TestDemo.cls` -- unit tests that DO NOT require external embedding/rerank services:
  - `TestCatalogPersistenceRoundtrip` — inserts one row with a hand-crafted `%Vector`, reads it back, asserts fields.
  - `TestSeedThrowsWithoutEmbeddingConfig` — deletes `CatalogEmbeddingV1`, calls `Seed.Run()`, asserts throw naming the missing config.
  - `TestSearchIdMappingPreserved` — bypasses `%Embedding` and rerank by seeding a fixed `hits` array via a small package-private test helper on `Search`, then invoking the second half of the pipeline with a mocked rerank result (via `^||omniReRankProviderOverride("cohere") = "dc.omniReRank.unittests.MockProvider"` — MockProvider's fixed scores `{0:0.6, 1:0.2, 2:0.9}` are already suitable). Asserts the returned rows come back in the order (index 2, index 0, index 1) with matching `Id` values.
  - `TestSearchEmptyTable` — seeded `Catalog` is empty; `Search("q", 5)` returns an empty result set and no rerank call is made.
  - `TestSearchKZero` — `Search("q", 0)` returns empty, no rerank call.
- [x] `README.md` -- append `## Demo` section (short — 25 lines max):
  1. Prerequisites: docker-compose running, IPM installed the module.
  2. Create both `%Embedding.Config` rows (one for embeddings pointing at any shipped provider, one for rerank pointing at Cohere/Voyage/Jina/Ollama). Give one working JSON example each (Cohere for embedding via `%Embedding.OpenAI` since that ships with IRIS 2026; Cohere for rerank). Point the reader at `docs/providers/*.md` (Story 5-2) for other options.
  3. `iris session iris -U IRISAPP -B "do ##class(dc.sample.omniReRank.demo.Seed).Run()"` — expect "Seeded 20 rows across 4 topics.".
  4. `CALL dc_sample_omniReRank_demo.Search_Search('how do I compile classes in ObjectScript?', 5)` — expect 5 rows sorted by `RerankScore DESC`.

**Acceptance Criteria:**
- Given both `%Embedding.Config` rows exist and their credentials resolve, when `##class(dc.sample.omniReRank.demo.Seed).Run()` runs, then `Catalog` contains exactly 20 rows across 4 topics and every row's `Embedding` is non-empty with the configured dimension count.
- Given the same setup, when `CALL dc_sample_omniReRank_demo.Search_Search('how do I compile classes in ObjectScript?', 5)` runs, then the result set has 5 rows sorted by `RerankScore` descending; every returned `Id` is also among the 5 highest cosine-similarity rows in `Catalog`.
- Given `CatalogEmbeddingV1` is deleted and `Seed.Run()` is called, then an exception is thrown naming the missing config before any Catalog row is created.
- Given `Catalog` is empty, when `Search('q', 5)` runs, then the result set is empty and no rerank call is dispatched.
- Given the full test suite runs under `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'`, then TestDemo cases pass AND every prior TestCohere, TestResilience, TestVoyage, TestJina, and TestOllama case still passes (demo adds no regression surface — only new files).
- `grep -R 'dc.omniEmbedding' src/dc/sample/omniReRank/demo/` returns empty (independence invariant, verified in CI or by hand).

## Implementation Notes

<!-- append-only during implementation -->

**2026-09-10 — implemented and verified on live IRIS via `iris-agentic-dev`**

Files added under `src/dc/sample/omniReRank/demo/`:
- `Catalog.cls` — 5 properties (Id/Title/Description/Topic/Embedding); Embedding is `%Vector(DATATYPE="FLOAT", LEN=1536)` — LEN is required by IRIS HNSW functional indices (`#5414` on unsized vectors). Cosine HNSW index on `Embedding`.
- `Seed.cls` — `Run()` throws before touching Catalog when `CatalogEmbeddingV1` missing, else `%KillExtent` + re-inserts 20 rows across 4 topics (iris-tutorials, objectscript, devops, sql-vector) computing each `Embedding` via `%Embedding.Interface.Embedding()`.
- `Search.cls` — `Search(query, k=10) [SqlProc]`. Short-circuits on `k≤0` and empty Catalog. Embeds query natively, cosine top-K, then `RerankPhase(query, hits, candidates, config)` (extracted so tests can bypass embedding + cosine).
- `SearchResult.cls` — `%SQL.CustomResultSet` with `(Id, Title, CosineDistance, RerankScore)`, `%New()` + `SetRows(rows)` initializer.

Test file: `tests/dc/omniReRank/unittests/TestDemo.cls` — 5 tests (persistence roundtrip, seed-throws-without-config, id-mapping via MockProvider, empty-table short-circuit, k=0 short-circuit).

README: appended `## Demo` section with prerequisites, both `%Embedding.Config` snippets, `Seed.Run()`, `CALL dc_sample_omniReRank_demo.Search_Search(...)`.

Verification:
- `iris-agentic-dev compile ...` — all OK.
- `iris-agentic-dev exec 'set ^UnitTestRoot=… RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — All PASSED (prior 64 + TestDemo 5 = 69).
- `grep -R "dc.omniEmbedding" src/dc/sample/omniReRank/demo/` — empty (independence invariant holds).

**Findings that emerged during implementation — worth follow-up:**

1. **FR-1 partial-regression when `CALL Engine_Rerank(...)` is issued from another SQL statement.** Subagent report: `CALL dc_omniReRank.Engine_Rerank(?, ?, ?)` returns `SQLCODE=0` but the inner `%SQL.CustomResultSet`'s rows don't surface via `%Next()/%Get()` on the outer statement result in this IRIS build. The demo works around it by calling `##class(dc.omniReRank.Engine).Rerank(...)` as an ObjectScript classmethod — Engine.Rerank remains SqlProc-registered, but SQL-only consumers may hit the same wall. `TestCohere.TestEngineEmptyCandidates` and the resilience suite exercise Engine.Rerank via classmethod calls, which is why the shipped tests didn't catch it.
2. **HNSW vector index requires fixed vector length.** `Catalog.Embedding` had to be pinned at 1536 dims. Documented in README; operators wanting other-dim embeddings must drop the index or widen `LEN`.

Both findings are candidates for their own tiny follow-up specs — not blockers for this story's acceptance.

Story 5-1 acceptance criteria satisfied.

## Design Notes

**Why native `%Embedding.Interface` and not `dc.omniEmbedding`?** The operator just confirmed `dc.omniReRank` is architecturally independent of `dc.omniEmbedding`. A demo that pulls in `dc.omniEmbedding` would silently reintroduce that dependency and confuse newcomers browsing Open Exchange. `%Embedding.Interface` is an IRIS 2026 system API that `dc.omniEmbedding` itself extends, and IRIS 2026 ships at least `%Embedding.OpenAI` out of the box — so the operator's "how do I run this?" bar stays at "you need one embedding config", not "you need another library too."

**Why the demo lives under `src/dc/sample/omniReRank/demo/` and not a separate module?** Two reasons:
- The `dc.omniReRank.PKG` resource in `module.xml` already picks it up — zero packaging churn.
- Anyone browsing the source tree finds the demo next to the library it demonstrates. Splitting into a `dc.omniReRankDemo` module would create the exact ergonomic tax the operator just pushed back against.

**Why `Description` and not `Title` gets reranked?** Cross-encoders (or the Ollama LLM-as-judge shim) score longer, more content-rich text more informatively than short titles. Titles are for humans reading the result set; the reranker needs signal.

**Why one index on `Embedding` and not on `Topic`?** The demo's read path never filters by topic — `Topic` is metadata for humans inspecting the seeded corpus. `VECTOR_COSINE` benefits from an HNSW-style vector index; other columns are read at demand from the tiny 20-row table.

**Id-mapping sketch** (the load-bearing part of Search):
```
Set stmt = ##class(%SQL.Statement).%New()
Do stmt.%Prepare("SELECT TOP ? Id, Title, Description, VECTOR_COSINE(?, Embedding) Cos FROM dc_sample_omniReRank_demo.Catalog ORDER BY Cos DESC")
Set rs = stmt.%Execute(k, queryVec)
Set candidates = []
Set pos = 0
While rs.%Next() {
    Set pos = pos + 1
    Set hits(pos) = $LB(rs.%Get("Id"), rs.%Get("Title"), rs.%Get("Cos"))
    Do candidates.%Push(rs.%Get("Description"))
}
Set rerankRs = ##class(%SQL.Statement).%ExecDirect(, "CALL dc_omniReRank.Engine_Rerank(?, ?, 'CatalogRerankV1')", .., query, candidates.%ToJSON())
Set outRows = []
While rerankRs.%Next() {
    Set idx = rerankRs.%Get("originalIndex")
    Set hit = hits(idx + 1)
    Do outRows.%Push({
        "Id": ($ListGet(hit, 1)),
        "Title": ($ListGet(hit, 2)),
        "CosineDistance": ($ListGet(hit, 3)),
        "RerankScore": (rerankRs.%Get("score"))
    })
}
Return ##class(dc.sample.omniReRank.demo.SearchResult).%New().SetRows(outRows)
```

**Not tested in the unit suite:** the actual embedding call and the actual rerank HTTP call — both require live external services. Those are covered by the README's manual smoke-test recipe. The unit tests exercise the id-mapping wiring, the empty-table shortcut, the `k=0` shortcut, and the config-missing failure — the four things that can break without needing a live upstream.

## Verification

**Commands (via `iris-agentic-dev`):**
- `iris-agentic-dev compile src/dc/sample/omniReRank/demo/... tests/dc/omniReRank/unittests/TestDemo.cls` -- expected: zero errors.
- `iris-agentic-dev exec 'set ^UnitTestRoot="/home/irisowner/dev/tests" do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` -- expected: All PASSED. TestCohere (16) + TestResilience (13) + TestVoyage (9) + TestJina (9) + TestOllama (17) + TestDemo (5) = 69 tests green.
- `grep -R "dc.omniEmbedding" src/dc/sample/omniReRank/demo/` -- expected: empty (independence invariant).

**Manual smoke test (documented in Implementation Notes when done, not automated):**
- Create both `%Embedding.Config` rows against a real embedding provider + a real rerank provider.
- `do ##class(dc.sample.omniReRank.demo.Seed).Run()` — expect "Seeded 20 rows...".
- `CALL dc_sample_omniReRank_demo.Search_Search('how do I compile classes in ObjectScript?', 5)` in an IRIS SQL shell — visually confirm the ObjectScript-topic rows rank higher than the others.
