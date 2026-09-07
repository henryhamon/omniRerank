# Story 5-4 — Open Exchange release cut

**Epic:** 5 — Demo, README & Release Prep
**Status:** pending
**Depends on:** Epics 1, 2, 3, and Stories 5-1, 5-2, 5-3. Epic 4 (fallbacks) is NOT a v1 release blocker.
**Resolves:** PRD §8 Q4 (final naming casing).

## As a…

Maintainer, I can publish `dc.omniReRank` v1.0.0 to InterSystems Open Exchange, so the library is discoverable and installable via IPM by any IRIS developer.

## Acceptance

1. `module.xml` version bumped to `1.0.0`. `Description` reflects the actual v1 provider set (list the ones that landed in Epic 3).
2. PRD §8 Q4 resolved: final package name casing pinned everywhere — `module.xml`, `README.md`, `docs/**`, class names. Recommendation: **keep `dc.omniReRank` (mixed case)** — matches every file that has already shipped; a rename would churn every path in this backlog. Document the decision at the top of `README.md`.
3. Full CI green on a clean clone: `docker-compose up -d --build`, IPM install, `iris-agentic-dev exec 'do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'` → every test in every `unittests` class passes.
4. `CHANGELOG.md` created (Keep-a-Changelog format) with entries for the two shipped specs and every Story from Epics 3 and 5 that landed. Format: one section per version, most recent first; each entry links to the shipped spec or story file.
5. `README.md` at the top: badges (License, Open Exchange, CI status), one-paragraph elevator pitch (from PRD §1 Vision), a "What it isn't" list (from PRD §5), a Providers table linking to `docs/providers/*.md`, and a "Demo" section (from Story 5-1).
6. Open Exchange listing draft ready in `docs/release/open-exchange-listing.md`: screenshots of demo output (Story 5-1), feature list matching PRD §4, "not for" list matching PRD §5, links back to repo README and CHANGELOG.
7. A git tag `v1.0.0` is created on the merge commit that satisfies acceptance criteria 1–6.

## Out of scope

- Actually publishing to Open Exchange (a human decision — this story ships the *draft*, not the submission).
- Marketing / conference-talk material.

## Verification

- `iris-agentic-dev compile src/... tests/...` on a fresh docker container — zero errors.
- Full test suite green — same command as shipped specs.
- `git tag --list v1.0.0` returns the tag.
- All Story 5-2 JSON examples validate (test `TestReadmeExamples` still green).
- All Story 5-3 credential-safety checks pass in CI.
