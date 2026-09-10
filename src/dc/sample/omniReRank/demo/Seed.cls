Include %occStatus

/// One-shot seeder for the demo Catalog. Operator runs this once after
/// creating the two %Embedding.Config rows (see README §Demo).
/// Uses IRIS 2026 native %Embedding.Interface — no sibling embedding
/// library, no fixture vectors. Fails loudly if CatalogEmbeddingV1 is missing.
Class dc.sample.omniReRank.demo.Seed
{

Parameter EMBCONFIG = "CatalogEmbeddingV1";

/// Wipes the Catalog and re-seeds it with 20 hand-curated rows across four
/// topics (5 rows each): IRIS tutorials, ObjectScript idioms,
/// deployment/DevOps, SQL/vector search. Idempotent — safe to run twice.
ClassMethod Run() As %Status
{
    // Fail before touching Catalog if the embedding config is missing.
    If '##class(%Embedding.Config).%ExistsId(..#EMBCONFIG) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.sample.omniReRank.demo.Seed.Run: %Embedding.Config '"_..#EMBCONFIG_"' not found — create it before seeding (see README §Demo)."))
    }
    Set cfg = ##class(%Embedding.Config).%OpenId(..#EMBCONFIG, , .openSc)
    If '$IsObject(cfg) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.sample.omniReRank.demo.Seed.Run: could not open %Embedding.Config '"_..#EMBCONFIG_"'."))
    }
    Set embCfgJson = cfg.Configuration

    // Wipe and re-seed.
    Do ##class(dc.sample.omniReRank.demo.Catalog).%KillExtent()

    Set rows = ..Corpus()
    Set iter = rows.%GetIterator()
    While iter.%GetNext(.k, .row) {
        Set doc = ##class(dc.sample.omniReRank.demo.Catalog).%New()
        Set doc.Id = +row.%Get("id")
        Set doc.Title = row.%Get("title")
        Set doc.Description = row.%Get("description")
        Set doc.Topic = row.%Get("topic")
        Set doc.Embedding = ##class(%Embedding.Interface).Embedding(doc.Description, embCfgJson)
        Set sc = doc.%Save()
        If $$$ISERR(sc) {
            $$$ThrowStatus(sc)
        }
    }
    Write !, "Seeded 20 rows across 4 topics."
    Return $$$OK
}

ClassMethod Corpus() As %DynamicArray
{
    Set c = []

    // --- Topic 1: IRIS tutorials -----------------------------------------
    Do c.%Push({"id":1,"topic":"iris-tutorials","title":"Getting Started With InterSystems IRIS",
        "description":"A guided walkthrough for developers new to InterSystems IRIS covering namespace creation, launching an IRIS instance in docker, connecting via terminal, and running the first ObjectScript command in an interactive session."})
    Do c.%Push({"id":2,"topic":"iris-tutorials","title":"Namespaces, Databases, and Globals Explained",
        "description":"An introduction to how InterSystems IRIS organizes storage: databases hold globals, namespaces map logical routines and classes to physical databases, and understanding this split is key to working with multi-tenant IRIS installations."})
    Do c.%Push({"id":3,"topic":"iris-tutorials","title":"Your First Persistent Class in IRIS",
        "description":"A step-by-step tutorial that creates a %Persistent class with a few properties, saves an instance, queries it via SQL, and inspects the auto-generated storage definition to build intuition for how IRIS maps objects to globals."})
    Do c.%Push({"id":4,"topic":"iris-tutorials","title":"Embedded Python Inside InterSystems IRIS",
        "description":"How to call Python code from ObjectScript and ObjectScript code from Python inside a single IRIS process, including passing globals and dynamic objects across the language boundary without serialization overhead."})
    Do c.%Push({"id":5,"topic":"iris-tutorials","title":"Introduction to the IRIS Package Manager",
        "description":"Package Manager (IPM/ZPM) tutorial: installing modules from the community registry, loading a local module.xml, and publishing your own package so other IRIS developers can install it with a single zpm install command."})

    // --- Topic 2: ObjectScript idioms ------------------------------------
    Do c.%Push({"id":6,"topic":"objectscript","title":"How Do I Compile Classes in ObjectScript",
        "description":"Compiling ObjectScript classes: using the do $system.OBJ.Compile command, understanding the qualifiers like /display and /recursive, the difference between class compilation and routine compilation, and how the compiler produces the .obj artifacts IRIS actually executes."})
    Do c.%Push({"id":7,"topic":"objectscript","title":"Dynamic Objects and JSON in ObjectScript",
        "description":"Working with %DynamicObject and %DynamicArray to build and parse JSON documents in ObjectScript: %FromJSON, %ToJSON, iterators, and the trade-offs versus the older %ZEN.proxyObject or %Library.DynamicObject patterns."})
    Do c.%Push({"id":8,"topic":"objectscript","title":"Error Handling With Try Catch and $$$ThrowStatus",
        "description":"Idiomatic error handling in ObjectScript: raising %Status values with $$$ERROR macros, throwing them via $$$ThrowStatus, catching in Try/Catch blocks, and unpacking DisplayString from the caught exception object."})
    Do c.%Push({"id":9,"topic":"objectscript","title":"Working With Globals and $Order",
        "description":"How to traverse sparse multi-dimensional globals using $Order and $Query, the difference between the two, and idiomatic loops for scanning large trees without loading everything into process memory."})
    Do c.%Push({"id":10,"topic":"objectscript","title":"Class Method vs Instance Method in ObjectScript",
        "description":"The distinction between ClassMethod and Method in ObjectScript, when to use each, how the calling syntax differs, and how ObjectScript resolves polymorphic dispatch on instance methods across an inheritance chain."})

    // --- Topic 3: Deployment / DevOps ------------------------------------
    Do c.%Push({"id":11,"topic":"devops","title":"Deploying IRIS Applications With Docker Compose",
        "description":"A practical guide to shipping an IRIS application as a docker-compose stack: base image selection, volume mounts for durable storage, mapping license keys and CPF files, and exposing the SuperServer and web ports to the host."})
    Do c.%Push({"id":12,"topic":"devops","title":"Continuous Integration for ObjectScript Projects",
        "description":"Setting up GitHub Actions to build the docker image, load the module, run unit tests via %UnitTest.Manager inside the container, and publish artifacts — the standard CI recipe for community IRIS projects."})
    Do c.%Push({"id":13,"topic":"devops","title":"Managing Secrets and API Keys in IRIS",
        "description":"Patterns for handling API keys and other secrets in IRIS deployments: using Ens.Config.Credentials, environment variables, and avoiding hard-coding sensitive values into class definitions or configuration files that end up in source control."})
    Do c.%Push({"id":14,"topic":"devops","title":"Kubernetes Operator for InterSystems IRIS",
        "description":"An overview of the InterSystems Kubernetes Operator (IKO) for running mirrored IRIS clusters in Kubernetes, including how it manages ECP configuration, mirror failover, and persistent volumes across pod restarts."})
    Do c.%Push({"id":15,"topic":"devops","title":"Zero-Downtime Upgrades of an IRIS Instance",
        "description":"Techniques for upgrading an IRIS application without taking it offline: mirroring with failover, side-by-side deploys behind a load balancer, running the module upgrade with zpm, and rolling back if the upgrade regresses."})

    // --- Topic 4: SQL / vector search ------------------------------------
    Do c.%Push({"id":16,"topic":"sql-vector","title":"Introduction to Vector Search in InterSystems IRIS",
        "description":"An overview of the IRIS 2024+ vector search stack: the %Vector datatype, VECTOR_COSINE and VECTOR_DOT_PRODUCT SQL functions, HNSW indexing, and how to plug an embedding model in so text queries produce vectors comparable to stored rows."})
    Do c.%Push({"id":17,"topic":"sql-vector","title":"Using VECTOR_COSINE in IRIS SQL Queries",
        "description":"Practical query patterns for VECTOR_COSINE: ordering by cosine distance, filtering with a threshold, combining with predicates on other columns, and the trade-offs between exact scans and HNSW index-accelerated top-K searches."})
    Do c.%Push({"id":18,"topic":"sql-vector","title":"HNSW Vector Indexes and Their Trade-Offs",
        "description":"How the HNSW vector index in IRIS works at a conceptual level, the M and efConstruction parameters, why HNSW is approximate rather than exact, and when to reach for a plain vector column instead of the index."})
    Do c.%Push({"id":19,"topic":"sql-vector","title":"Two-Stage Retrieval With Rerank Models",
        "description":"Why production retrieval-augmented generation systems combine a fast vector top-K with a slower cross-encoder rerank pass, how the rerank model rescores the candidates end-to-end against the query, and how to wire the two stages together in IRIS SQL."})
    Do c.%Push({"id":20,"topic":"sql-vector","title":"Embedding Text With the IRIS %Embedding Interface",
        "description":"How to call %Embedding.Interface.Embedding to turn arbitrary text into a %Vector using any registered %Embedding.Config row, including how to point one config at OpenAI, another at a local Ollama model, and switch between them per query."})

    Return c
}

}
