# Story 5-2 — Per-provider README pages

**Epic:** 5 — Demo, README & Release Prep
**Status:** pending
**Depends on:** Epic 3 (a page per Provider means Providers must exist).

## As a…

IRIS developer choosing a Provider, I want one page per shipped Provider with its config keys, one working full `%Embedding.Config` JSON example, model examples, and one known gotcha, so I don't have to read source to onboard a new backend.

## Acceptance

1. `docs/providers/cohere.md`, `docs/providers/voyage.md`, `docs/providers/jina.md`, `docs/providers/ollama.md` — one file per Provider actually shipped. If Epic 3 lands only a subset, ship only those pages.
2. Each page follows a fixed structure:
   - Provider name + one-sentence purpose.
   - Full sample `%Embedding.Config.Configuration` JSON in a fenced ```json``` block (with `rerank` sub-block, required keys populated, optional keys commented as "// optional" via a note above the block since JSON has no comments).
   - Required config keys with their types (table).
   - Optional config keys with types + defaults (table).
   - At least two `modelName` examples the vendor currently supports (verified at implementation time).
   - One "Gotcha" section — a real thing that trips first-time users (Cohere `input_type` doesn't apply to rerank; Ollama needs `apiBase`; Jina multilingual model has larger max token count; etc.).
3. `tests/dc/omniReRank/unittests/TestReadmeExamples.cls` — reads each `docs/providers/*.md`, extracts every fenced ```json``` block, parses it, and calls the matching Provider's `ValidateConfig` on the `rerank` sub-block. Any parse failure or validation throw fails the test naming the offending doc file and JSON block.
4. `README.md` links to every `docs/providers/*.md` from the Providers table.

## Out of scope

- Marketing copy or comparative benchmarks between providers.
- Provider price / quota comparisons — vendor pricing changes independently of this library.

## Verification

- `iris-agentic-dev compile tests/dc/omniReRank/unittests/TestReadmeExamples.cls` — zero errors.
- `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` — `TestReadmeExamples` green (proves every JSON sample in the docs actually validates).
