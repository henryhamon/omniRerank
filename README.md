[![Open Exchange](https://img.shields.io/badge/Available%20on-Intersystems%20Open%20Exchange-00b2a9.svg)](https://openexchange.intersystems.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat&logo=AdGuard)](LICENSE)
[![InterSystems IRIS](https://img.shields.io/badge/InterSystems-IRIS%202026%2B-blue.svg)](https://www.intersystems.com/)
[![ObjectScript](https://img.shields.io/badge/ObjectScript-native-informational.svg)](https://docs.intersystems.com/)

# 🎯 dc.omniReRank

**The Universal Reranking Gateway for InterSystems IRIS**

> *One `Rerank()` call. Any provider. Explicit control — no silent score merging.*

---

## 🌌 Motivation

Vector search over IRIS 2026's native `%Vector` retrieves the right documents but often ranks them poorly — the top-K by cosine similarity is *the correct set, in the wrong order*. Cross-encoder rerankers are the industry-standard fix, but every reranker has its own quirks:

- **Cohere** returns scores nested under `results[].relevance_score`, expects `top_n` and `documents`
- **Voyage AI** returns scores under `data[].relevance_score` and expects `top_k` (not `top_n`)
- **Jina AI** shares Cohere's `results[]`/`top_n` shape but with a different auth scope and multilingual model family
- **Ollama** has **no native `/api/rerank`** — the same local endpoint that hosts embeddings needs a prompt-template shim over `/api/chat` with `format: "json"` and a strict schema-validating parser
- Different providers score on **incomparable scales** — mixing them in a fallback silently corrupts your top-K, and the failure mode only surfaces months later when your users notice the "best answer" isn't

Swapping rerankers usually means rewriting glue code, and blending them naively is a data-quality disaster.

**`dc.omniReRank` changes that.**

Plug it in once as a SQL-callable `%SqlProc`, keep the rerank config in the same `%Embedding.Config` row your search already uses, and every `CALL dc_omniReRank.Engine_Rerank('query', candidatesJson, 'ConfigName')` — from SQL, from ObjectScript, from Interoperability — routes to the right provider, retries transient errors, opens a circuit breaker on failing providers, and **refuses to mix score spaces** across providers.

- ✅ **Four providers, one interface:** Cohere · Voyage AI · Jina AI · Ollama (LLM-as-judge shim)
- ✅ **Native HTTP:** `%Net.HttpRequest` — no Python required on the hot path
- ✅ **Resilient:** exponential backoff, `Retry-After` honored, circuit breaker per provider
- ✅ **Score-space isolation:** results in one call come from **exactly one** provider — no silent merging
- ✅ **Secure by default:** `apiKey` is a **credential name**, never the raw secret
- ✅ **Independent of `dc.omniEmbedding`:** zero code coupling; the two libraries coexist by sharing the IRIS-native `%Embedding.Config` store, nothing more
- ✅ **CI-friendly:** every branch is covered by mocked HTTP — no cloud key needed to run the suite

---

## 🛠️ How It Works

`dc.omniReRank` sits between your SQL layer and any of the four supported reranker backends, applying three architectural pillars ([full spine](_bmad-output/planning-artifacts/architecture/architecture-omniRerank-2026-09-07/ARCHITECTURE-SPINE.md)):

1. **HTTP native first** — the entire happy path uses `%Net.HttpRequest`; no Embedded Python, no external SDKs.
2. **Polymorphism by class hierarchy** — a Template Method in `provider.Base` fixes the sequence `ValidateConfig → SetAuth → GetRerankUrl → BuildPayload → RetryWithBackoff → ParseResponse`; each provider overrides only what differs. `Execute` is intentionally **not `[Final]`** so future providers with unusual ordering constraints (e.g. request signing) can override the whole template.
3. **Score-space isolation as a hard invariant** — exactly one Provider produces any `RerankResult`. A future v2 fallback loop tries providers one at a time; no code path is allowed to concatenate or blend `results[]` across providers.

### **Core Components**

| Class | Role |
|---|---|
| `dc.omniReRank.Engine` | SQL entry point (`Rerank` `[SqlProc]`), config load, provider resolution, circuit breaker |
| `dc.omniReRank.RerankResult` | `%SQL.CustomResultSet` with fixed columns `(originalIndex INT, candidate VARCHAR, score DOUBLE)` sorted `score DESC` |
| `dc.omniReRank.provider.Base` | Abstract Template Method; retry/backoff; `PostOnce` HTTP seam; `ResolveApiKey` |
| `dc.omniReRank.provider.Cohere` | Cohere v2 `/rerank`, Bearer auth, `results[].relevance_score` parse |
| `dc.omniReRank.provider.Voyage` | Voyage AI `/v1/rerank`, Bearer auth, `data[].relevance_score` parse, `top_k` payload |
| `dc.omniReRank.provider.Jina` | Jina `/v1/rerank`, Bearer auth, `results[].relevance_score` parse, multilingual model family |
| `dc.omniReRank.provider.Ollama` | Authless local shim over `/api/chat` with `format:"json"` + a strict schema-validating parser (Ollama has no native `/rerank` yet) |

### **Architecture Overview**

```

┌─────────────────────────────────────────────────────────────┐
│               Any caller — SQL, ObjectScript,               │
│                 Interoperability, %SQL.Statement            │
│   CALL dc_omniReRank.Engine_Rerank(query, candJson, cfg)    │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                 dc.omniReRank.Engine                        │
│   parse candidatesJson · load %Embedding.Config by name     │
│   extract .rerank sub-block · ResolveProvider (explicit)    │
│   CheckBreaker → dispatch → RecordSuccess/Failure           │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│      provider.Base.Execute() — Template Method              │
│  ValidateConfig → SetAuth → GetRerankUrl →                  │
│  BuildPayload → RetryWithBackoff(PostOnce) → ParseResponse  │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  %Net.HttpRequest → { Cohere | Voyage | Jina |              │
│                       Ollama (chat + format:json shim) }    │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│           dc.omniReRank.RerankResult                        │
│  (originalIndex INT, candidate VARCHAR, score DOUBLE)       │
│  sorted DESC by score — returned to the SQL caller          │
└─────────────────────────────────────────────────────────────┘

```

### **Resilience Model**

- **Retry:** 429 and 5xx are retried with `MIN(baseDelayMs * 2^(attempt-1) + jitter, maxDelayMs)` — `Retry-After` is honored verbatim when present. 4xx (except 429) fast-fail.
- **Circuit breaker:** per `provider|modelName` key stored in `^omniReRank.Breaker`. Opens after **5** consecutive failures; **60 s** cooldown; half-open lets one probe through; success writes `$LB(0, 0)` explicitly.
- **Score-space isolation:** exactly one Provider produces any `RerankResult`. Fallback across providers (v2) is a follow-up spec — v1 dispatches one provider and either returns its result or throws.

---

## 📋 Prerequisites

- **InterSystems IRIS 2026.2+** (native `%Embedding.Config`, `%Vector`, `%SQL.CustomResultSet` are required)
- **Docker** and **Docker Compose** (if you use the bundled dev container)
- **A rerank provider account** — Cohere / Voyage / Jina — *or* a local **Ollama** instance running an instruction-tuned model (Llama 3.1, Qwen 2.5, Mistral) for the authless local path

---

## 🛠️ Installation

### 1. **Clone the Repository**

```sh
git clone https://github.com/henryhamon/omniRerank.git
cd dc.omniReRank
```

### 2. **Build and Run the Dev Container**

```sh
docker-compose up -d --build
```

The IPM module `dc-omniReRank` is loaded automatically into the `IRISAPP` namespace.

### 3. **Or Install as an IPM Package**

```objectscript
zpm "install dc-omniReRank"
```

### 4. **Wire it into `%Embedding.Config`**

Rerank configuration lives as a `rerank` sub-block inside the `Configuration` JSON of an existing `%Embedding.Config` row. Any embedding config can be extended in place:

```sql
INSERT INTO %Embedding.Config (Name, Configuration, EmbeddingClass, VectorLength, VectorDataType, Description)
VALUES (
    'ProductSearchV3',
    '{"apiKey":"openai-prod","modelName":"text-embedding-3-small","rerank":{"provider":"cohere","modelName":"rerank-v3.5","apiKey":"cohere-prod"}}',
    '%Embedding.OpenAI',
    1536,
    'FLOAT',
    'Product search: OpenAI embeddings + Cohere rerank'
)
```

### 5. **Use It**

From SQL:

```sql
CALL dc_omniReRank.Engine_Rerank(
    'best iris tutorials',
    '["Getting started with IRIS SQL","Deploying IRIS with Docker","Advanced ObjectScript tips"]',
    'ProductSearchV3'
)
```

From ObjectScript:

```objectscript
Set rs = ##class(dc.omniReRank.Engine).Rerank(
    "best iris tutorials",
    "[""Getting started with IRIS SQL"",""Deploying IRIS with Docker"",""Advanced ObjectScript tips""]",
    "ProductSearchV3"
)
While rs.%Next() {
    Write !, rs.originalIndex, " → ", rs.candidate, " (", rs.score, ")"
}
```

---

## 💡 Configuration Reference

Every field lives under the `rerank` sub-object of `%Embedding.Config.Configuration`.

### **Common fields (all providers)**

| Field | Required | Description |
|---|---|---|
| `provider` | yes | one of: `cohere`, `voyage`, `jina`, `ollama`. **No inference from `modelName`** — always explicit (deliberate divergence from `dc.omniEmbedding` for operator predictability) |
| `modelName` | yes | Model identifier for the target provider |
| `apiKey` | required for SaaS providers; ignored for `ollama` | **Credential name** (not the value) — resolved via `Ens.Config.Credentials` |
| `apiBase` | required for `ollama`; not used by SaaS providers | Base URL of a local Ollama instance, e.g. `http://ollama:11434` |
| `topN` / `topK` | no (defaults to candidate count) | Max results to return. Field name mirrors the provider's payload — Cohere/Jina/Ollama use `topN`; Voyage uses `topK` |
| `sslConfig` | no | Name of a `%SSL.Config` for TLS |
| `httpTimeout` | no (default `30`s) | HTTP timeout in seconds |
| `retry.maxAttempts` | no (default `3`) | Max attempts including the first |
| `retry.baseDelayMs` | no (default `500`) | Base backoff delay |
| `retry.maxDelayMs` | no (default `8000`) | Backoff cap |
| `retry.honorRetryAfter` | no (default `true`) | Use the `Retry-After` header when present |

### **Provider-specific extras**

- **Cohere:** none beyond the common set. Endpoint `https://api.cohere.com/v2/rerank`. Model examples: `rerank-v3.5`, `rerank-multilingual-v3.0`.
- **Voyage AI:** none beyond the common set (uses `topK`, not `topN`). Endpoint `https://api.voyageai.com/v1/rerank`. Model examples: `rerank-2.5`, `rerank-2.5-lite`.
- **Jina AI:** none beyond the common set. Endpoint `https://api.jina.ai/v1/rerank`. Model examples: `jina-reranker-v2-base-multilingual`, `jina-reranker-v3`.
- **Ollama** (LLM-as-judge shim): `promptTemplate` (optional — override the baked-in system prompt; when set, the operator owns correctness), `chatOptions` (optional `%DynamicObject` merged into `/api/chat`'s `options` field, e.g. `{"temperature":0.2,"num_ctx":8192}`). Endpoint is `<apiBase>/api/chat`. Model examples: `llama3.1:8b-instruct`, `qwen2.5:7b-instruct`, `mistral:7b-instruct`.

### **Example — Cohere primary, Voyage fallback (v2 preview)**

*Fallbacks are v2-only — this config is a preview of the shape v2 will accept; v1 ignores `fallbacks`.*

```json
{
    "provider": "cohere",
    "modelName": "rerank-v3.5",
    "apiKey": "cohere-prod",
    "fallbacks": ["ProductSearchV3-VoyageBackup"]
}
```

A fallback with a different `provider|modelName` will be **rejected before any HTTP call** (score-space mismatch). Only exact `provider|modelName` matches — e.g. same Cohere model behind a different `apiBase` for multi-region — will be considered safe in the v2 default policy.

### **Example — Ollama LLM-as-judge with a specific instruction-tuned model**

```json
{
    "provider": "ollama",
    "modelName": "qwen2.5:7b-instruct",
    "apiBase": "http://ollama:11434",
    "chatOptions": {"num_ctx": 8192}
}
```

`apiKey` is intentionally absent — Ollama is authless. `temperature` defaults to `0` for reproducibility; override via `chatOptions.temperature` if you want sampling.

---

## 🔐 Credentials

`config.rerank.apiKey` is always a **credential name**, never the raw secret. The gateway resolves the name via `Ens.Config.Credentials.%OpenId(name).Password`. Register one from the IRIS terminal:

```objectscript
Set cred = ##class(Ens.Config.Credentials).%New()
Set cred.SystemName = "cohere-prod"
Set cred.Username = "apikey"
Set cred.Password = "co-...your-real-key..."
Do cred.%Save()
```

Then reference it as `"apiKey": "cohere-prod"` in your `rerank` sub-block. Exceptions raised for a missing credential carry only the *name* — never the value. `Ollama` deliberately does not call `ResolveApiKey`.

---

## 🎬 Demo

An end-to-end walkthrough — table → vector top-K → rerank → reordered rows — lives under `src/dc/sample/omniReRank/demo/` (kept out of the IPM install: `dc.sample.*` classes exist in the repo for reference but never ship into `dc.omniReRank.PKG`). It uses IRIS 2026's native `%Embedding.Interface` (no `dc.omniEmbedding` dependency, no fixture vectors).

1. **Prerequisites.** `docker-compose up -d` is running; IPM has loaded `dc-omniReRank` into `IRISAPP`.

2. **Create two `%Embedding.Config` rows** — one for embeddings, one for rerank. Any shipped IRIS embedding provider works for the first; any `dc.omniReRank` provider works for the second:

   ```objectscript
   Set emb = ##class(%Embedding.Config).%New()
   Set emb.Name = "CatalogEmbeddingV1", emb.EmbeddingClass = "%Embedding.OpenAI"
   Set emb.VectorLength = 1536, emb.VectorDataType = "FLOAT"
   Set emb.Configuration = "{""apiKey"":""openai-prod"",""modelName"":""text-embedding-3-small""}"
   Do emb.%Save()

   Set rr = ##class(%Embedding.Config).%New()
   Set rr.Name = "CatalogRerankV1", rr.EmbeddingClass = "%Embedding.OpenAI"
   Set rr.VectorLength = 1536, rr.VectorDataType = "FLOAT"
   Set rr.Configuration = "{""apiKey"":""unused"",""modelName"":""placeholder"",""rerank"":{""provider"":""cohere"",""modelName"":""rerank-v3.5"",""apiKey"":""cohere-prod""}}"
   Do rr.%Save()
   ```

3. **Seed the corpus** (20 rows across 4 topics):

   ```sh
   docker-compose exec iris iris session iris -U IRISAPP -B "do ##class(dc.sample.omniReRank.demo.Seed).Run()"
   ```

4. **Search**:

   ```sql
   CALL dc_sample_omniReRank_demo.Search_Search('how do I compile classes in ObjectScript?', 5)
   ```

   The five returned rows are sorted by `RerankScore DESC`; ObjectScript-topic rows outrank the others.

---

## 🗂️ Project Structure

```
dc.omniReRank/
├── src/dc/omniReRank/
│   ├── Engine.cls                 # SQL entry · config load · breaker · dispatch
│   ├── RerankResult.cls           # %SQL.CustomResultSet — fixed column contract
│   └── provider/
│       ├── Base.cls               # Template Method · retry · PostOnce · ResolveApiKey
│       ├── Cohere.cls             # v2 /rerank · Bearer · results[].relevance_score
│       ├── Voyage.cls             # /v1/rerank · Bearer · data[].relevance_score · top_k
│       ├── Jina.cls               # /v1/rerank · Bearer · results[].relevance_score
│       └── Ollama.cls             # authless · /api/chat + format:"json" shim · strict schema parser
├── src/dc/sample/omniReRank/demo/ # repo-only walkthrough (not in dc.omniReRank.PKG)
│   ├── Catalog.cls                # 20-row seeded corpus · HNSW cosine index
│   ├── Seed.cls                   # %Embedding.Interface embedding at seed time
│   ├── Search.cls                 # vector top-K → rerank → reordered rows [SqlProc]
│   └── SearchResult.cls           # (Id, Title, CosineDistance, RerankScore) result set
├── tests/dc/omniReRank/unittests/
│   ├── TestCohere.cls             # payload / parse / auth / validate + Engine matrix
│   ├── TestResilience.cls         # retry loop · circuit breaker · transport error
│   ├── TestVoyage.cls             # per-provider I/O matrix
│   ├── TestJina.cls               # per-provider I/O matrix
│   ├── TestOllama.cls             # shim-specific: strict parser, apiKey NOT required
│   ├── TestDemo.cls               # persistence · seed guard · id mapping
│   ├── MockProvider.cls           # dispatch test double
│   └── MockHttpProvider.cls       # PostOnce override — HTTP failure paths
├── module.xml                     # IPM manifest — Resource dc.omniReRank.PKG only
├── docker-compose.yml
└── README.md
```

---

## 🧪 Testing

The suite has **69 tests** covering every provider's I/O matrix, the retry loop, the circuit breaker, the transport-error path, and the demo id-mapping — all against mocked HTTP, no cloud keys required.

Run every suite from the IRIS terminal:

```objectscript
Set ^UnitTestRoot = "/home/irisowner/dev/tests"
Do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests", "/nodelete/noload")
```

Or via IPM:

```objectscript
zpm "test dc-omniReRank"
```

Or via [`iris-agentic-dev`](https://github.com/intersystems-community/iris-agentic-dev) on your workstation:

```sh
iris-agentic-dev compile src/dc/omniReRank/... tests/dc/omniReRank/unittests/...
iris-agentic-dev exec 'set ^UnitTestRoot="/home/irisowner/dev/tests" do ##class(%UnitTest.Manager).RunTest("dc/omniReRank/unittests","/nodelete/noload")'
```

---

## 📊 Roadmap

### ✅ **v1.0 — Complete**

* [x] SQL-callable `Engine.Rerank` `[SqlProc]` + fixed `%SQL.CustomResultSet` column contract
* [x] Configuration under `%Embedding.Config.Configuration.rerank` — no separate persistent class
* [x] Fail-fast argument validation before any HTTP or store lookup
* [x] Four providers: Cohere, Voyage AI, Jina AI, Ollama (LLM-as-judge shim over `/api/chat`)
* [x] Retry with exponential backoff + `Retry-After` honoring
* [x] Circuit breaker (5 failures / 60 s cooldown / half-open probe) per `provider|modelName`
* [x] Credentials via `Ens.Config.Credentials` (secret never leaks; Ollama authless)
* [x] `Base.Execute` deliberately non-`[Final]` for future signing-provider overrides
* [x] Full unit-test coverage against mocked HTTP — no cloud keys needed
* [x] End-to-end demo under `dc.sample.omniReRank.demo` (not shipped in IPM install)

### 🔮 **Future**

* [ ] Provider fallback chain with strict `provider|modelName` compatibility (v2 — no silent score-space mixing)
* [ ] Per-provider README pages under `docs/providers/*.md` with validated JSON examples
* [ ] CI grep for credential-leak sentinel across every throw path
* [ ] Metrics / telemetry export (per-provider latency, breaker-open counters)
* [ ] Optional `normalizedScore` column on `RerankResult`

---

## 🎖️ Credits

`dc.omniReRank` is designed and developed with 💜 by:

- [**Henry Pereira**](https://community.intersystems.com/user/henry-pereira) — architecture, implementation, testing

Companion library: [**`dc.omniEmbedding`**](https://github.com/henryhamon/dc.omniEmbedding) — the universal embedding gateway that pairs naturally with this reranker in a full retrieval pipeline (the two are architecturally independent — sharing only the IRIS-native `%Embedding.Config` store).

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
