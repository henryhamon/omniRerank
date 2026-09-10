# Story 5-1 — Worked example: vector search + rerank stored procedure

**Epic:** 5 — Demo, README & Release Prep
**Status:** pending
**Governed by:** AD-2, AD-3, AD-8.
**Depends on:** Epic 1 only. Can ship before Epic 3 completes.

## As a…

IRIS developer evaluating the library, I want a small demo — a table with embeddings, some seeded rows, and one stored procedure that vector-searches then reranks — so I can see the end-to-end flow without reading source.

## Acceptance

1. `src/dc/sample/omniReRank/demo/Catalog.cls` — `%Persistent` with properties `Id As %Integer [ IdKey ]`, `Title As %String(MAXLEN="")`, `Description As %String(MAXLEN="")`, `Embedding As %Vector(...)` matching whatever the seeded embeddings use. Sensible default: `Embedding` as a 1024-dim `%Vector(DATATYPE="FLOAT")` if `dc.omniEmbedding` with a matching config is available, else a lower-dim fixture-friendly size.
2. `src/dc/sample/omniReRank/demo/Seed.cls:Run()` classmethod seeds ~20 rows across a couple of topics (e.g. IRIS tutorials, ObjectScript idioms, deployment tips). Embeddings computed via `dc.omniEmbedding` when reachable, otherwise pre-shipped fixture vectors bundled inline in the seed class.
3. `src/dc/sample/omniReRank/demo/Search.cls:Search(query As %String, k As %Integer = 10) As %SQL.StatementResult [ SqlProc ]` — does a `VECTOR_COSINE(:queryEmbedding, Embedding)`-ordered top-K SELECT on `Catalog`, builds `candidatesJson` from the `Title` (or `Description`, spec picks one and pins it), invokes `CALL dc_omniReRank.Engine_Rerank(:query, :candidatesJson, 'CatalogSearchV1')`, and joins the result back on `originalIndex` to return `(Id, Title, cosineScore DOUBLE, rerankScore DOUBLE)` sorted by `rerankScore DESC`.
4. `iris-agentic-dev exec 'do ##class(dc.sample.omniReRank.demo.Seed).Run() do ##class(dc.sample.omniReRank.demo.Search).Search("best iris tutorials", 5).%Display()'` returns 5 rows with monotonically decreasing `rerankScore`.
5. `README.md` gains a `## Demo` section walking through the four steps a fresh clone needs: `docker-compose up -d --build`, load the module, `do ##class(dc.sample.omniReRank.demo.Seed).Run()`, call `Search()`.
6. Requires a `CatalogSearchV1` `%Embedding.Config` row with a `rerank` sub-block pointing at Cohere; the seed script also inserts this row (with a placeholder credential name — README tells the operator to create the actual `Ens.Config.Credentials` entry).

## Out of scope

- Multi-language corpus.
- A UI in front of the demo — this is a CLI / SQL demo, not a webapp.
- Benchmarking rerank quality against a baseline — SM measurement, not demo scope.

## Verification

- `iris-agentic-dev compile src/dc/sample/omniReRank/demo/...` — zero errors.
- Manual: run the four README steps against a docker-compose IRIS with a real Cohere credential; visually confirm ordered results.
