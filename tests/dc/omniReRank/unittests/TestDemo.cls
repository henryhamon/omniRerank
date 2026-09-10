Include (%occStatus, %outUnitTest)

/// Unit tests for the dc.sample.omniReRank.demo end-to-end walkthrough.
/// Covers persistence roundtrip on Catalog, Seed's fail-loud behavior when
/// the embedding config is missing, Search's id-mapping wiring via the
/// MockProvider hook, and the two short-circuit paths (empty table, k=0).
/// Deliberately does NOT exercise the real %Embedding call or the real
/// rerank HTTP call — those need live upstreams and are covered by the
/// README manual smoke-test recipe.
Class dc.omniReRank.unittests.TestDemo Extends %UnitTest.TestCase
{

Parameter EMBCONFIG = "CatalogEmbeddingV1";

Parameter RERANKCONFIG = "CatalogRerankV1";

Method OnBeforeAllTests() As %Status
{
    // Start clean; individual tests set up their own state.
    Do ##class(dc.sample.omniReRank.demo.Catalog).%KillExtent()
    Do ..DeleteConfig(..#EMBCONFIG)
    Do ..DeleteConfig(..#RERANKCONFIG)
    Return $$$OK
}

Method OnAfterAllTests() As %Status
{
    Do ##class(dc.sample.omniReRank.demo.Catalog).%KillExtent()
    Do ..DeleteConfig(..#EMBCONFIG)
    Do ..DeleteConfig(..#RERANKCONFIG)
    Kill ^||omniReRankProviderOverride("cohere")
    Return $$$OK
}

Method TestCatalogPersistenceRoundtrip()
{
    Do ##class(dc.sample.omniReRank.demo.Catalog).%KillExtent()
    // Build a 1536-length vector string (column is fixed-length so the HNSW
    // functional index can build). Values are irrelevant to this test — we
    // only assert the row roundtrips through storage.
    Set vec = "0.001"
    For i = 2:1:1536 { Set vec = vec_",0.001" }
    Set stmt = ##class(%SQL.Statement).%New()
    Set sc = stmt.%Prepare("INSERT INTO dc_sample_omniReRank_demo.Catalog (Id, Title, Description, Topic, Embedding) VALUES (?, ?, ?, ?, TO_VECTOR(?, FLOAT, 1536))")
    Do $$$AssertStatusOK(sc, "prepare INSERT")
    Set rs = stmt.%Execute(101, "Roundtrip Row", "A hand-crafted description.", "test", vec)
    Do $$$AssertEquals(rs.%SQLCODE, 0, "insert SQLCODE=0 (msg="_rs.%Message_")")
    Set row = ##class(dc.sample.omniReRank.demo.Catalog).%OpenId(101)
    Do $$$AssertTrue($IsObject(row), "row 101 loads")
    If $IsObject(row) {
        Do $$$AssertEquals(row.Title, "Roundtrip Row", "Title roundtrip")
        Do $$$AssertEquals(row.Description, "A hand-crafted description.", "Description roundtrip")
        Do $$$AssertEquals(row.Topic, "test", "Topic roundtrip")
        Do $$$AssertTrue(row.Embedding '= "", "Embedding non-empty")
    }
    Do ##class(dc.sample.omniReRank.demo.Catalog).%DeleteId(101)
}

Method TestSeedThrowsWithoutEmbeddingConfig()
{
    Do ..DeleteConfig(..#EMBCONFIG)
    Set threw = 0, msg = ""
    Try { Do ##class(dc.sample.omniReRank.demo.Seed).Run() }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "Seed.Run throws when CatalogEmbeddingV1 is missing")
    Do $$$AssertTrue($Find(msg, ..#EMBCONFIG) > 0, "error names the missing config")
    // Verify no rows were inserted.
    Set cnt = 0
    &sql(SELECT COUNT(*) INTO :cnt FROM dc_sample_omniReRank_demo.Catalog)
    Do $$$AssertEquals(cnt, 0, "no Catalog rows created on the failure path")
}

Method TestSearchIdMappingPreserved()
{
    // Register the mock provider + create a rerank config that resolves to it.
    Set ^||omniReRankProviderOverride("cohere") = "dc.omniReRank.unittests.MockProvider"
    Do ..DeleteConfig(..#RERANKCONFIG)
    Do ..MakeConfig(..#RERANKCONFIG, "{""rerank"":{""provider"":""cohere"",""modelName"":""rerank-v3.5"",""apiKey"":""k""}}")

    // Fabricate hits + candidates as Search's cosine phase would build them.
    // hits[i] = [Id, Title, CosineDistance]. Ids chosen distinctly so the
    // returned order proves the id-mapping worked.
    Set hits = []
    Do hits.%Push([7, "Alpha row", 0.31])
    Do hits.%Push([3, "Beta row", 0.28])
    Do hits.%Push([15, "Gamma row", 0.22])
    Set candidates = []
    Do candidates.%Push("alpha description text")
    Do candidates.%Push("beta description text")
    Do candidates.%Push("gamma description text")

    // MockProvider scores: idx0=0.6, idx1=0.2, idx2=0.9 → sort DESC gives
    // idx=2 (Id 15), idx=0 (Id 7), idx=1 (Id 3).
    Try {
        Set result = ##class(dc.sample.omniReRank.demo.Search).RerankPhase("q", hits, candidates, ..#RERANKCONFIG)

        Do $$$AssertEquals(result.%Next(), 1, "row 1 present")
        Do $$$AssertEquals(result.Id, 15, "row 1 Id = 15 (originalIndex 2)")
        Do $$$AssertEquals(result.Title, "Gamma row", "row 1 Title")
        Do $$$AssertEquals(result.RerankScore, 0.9, "row 1 RerankScore = 0.9")
        Do $$$AssertEquals(result.CosineDistance, 0.22, "row 1 CosineDistance from hits[2]")

        Do $$$AssertEquals(result.%Next(), 1, "row 2 present")
        Do $$$AssertEquals(result.Id, 7, "row 2 Id = 7 (originalIndex 0)")
        Do $$$AssertEquals(result.RerankScore, 0.6, "row 2 RerankScore = 0.6")

        Do $$$AssertEquals(result.%Next(), 1, "row 3 present")
        Do $$$AssertEquals(result.Id, 3, "row 3 Id = 3 (originalIndex 1)")
        Do $$$AssertEquals(result.RerankScore, 0.2, "row 3 RerankScore = 0.2")

        Do $$$AssertEquals(result.%Next(), 0, "no more rows")
    }
    Catch ex {
        Do $$$AssertTrue(0, "unexpected throw: "_ex.DisplayString())
    }

    Kill ^||omniReRankProviderOverride("cohere")
    Do ..DeleteConfig(..#RERANKCONFIG)
}

Method TestSearchEmptyTable()
{
    // Empty catalog → Search short-circuits before embedding or rerank.
    Do ##class(dc.sample.omniReRank.demo.Catalog).%KillExtent()
    Do ..DeleteConfig(..#EMBCONFIG)
    Do ..DeleteConfig(..#RERANKCONFIG)
    Try {
        Set result = ##class(dc.sample.omniReRank.demo.Search).Search("anything", 5)
        Do $$$AssertTrue($IsObject(result), "returns a result set")
        Do $$$AssertEquals(result.%Next(), 0, "empty result set — no embedding, no rerank dispatched")
    }
    Catch ex {
        Do $$$AssertTrue(0, "empty-table path must not throw (no embedding config lookup): "_ex.DisplayString())
    }
}

Method TestSearchKZero()
{
    // k=0 → Search short-circuits before touching Catalog, embedding, or rerank.
    Do ..DeleteConfig(..#EMBCONFIG)
    Do ..DeleteConfig(..#RERANKCONFIG)
    Try {
        Set result = ##class(dc.sample.omniReRank.demo.Search).Search("anything", 0)
        Do $$$AssertTrue($IsObject(result), "returns a result set")
        Do $$$AssertEquals(result.%Next(), 0, "empty result set for k=0")
    }
    Catch ex {
        Do $$$AssertTrue(0, "k=0 path must not throw: "_ex.DisplayString())
    }
}

/// Creates a %Embedding.Config row with the given Configuration JSON.
/// Same defensive schema handling as TestCohere.MakeConfig.
Method MakeConfig(name As %String, configJson As %String) [ Private ]
{
    Set cfg = ##class(%Embedding.Config).%New()
    Set cfg.Name = name
    Set cfg.Configuration = configJson
    Try { Set cfg.EmbeddingClass = "%Embedding.OpenAI" } Catch {}
    Try { Set cfg.VectorDataType = "FLOAT" } Catch {}
    Try { Set cfg.VectorLength = 1536 } Catch {}
    Try {
        Set probe = {}.%FromJSON(configJson)
        If (probe.%Get("apiKey") = "") || (probe.%Get("modelName") = "") {
            Do probe.%Set("apiKey", "unused-for-rerank")
            Do probe.%Set("modelName", "text-embedding-3-small")
            Set cfg.Configuration = probe.%ToJSON()
        }
    } Catch {}
    Set sc = cfg.%Save()
    If $$$ISERR(sc) {
        Do $System.Status.DisplayError(sc)
    }
}

Method DeleteConfig(name As %String) [ Private ]
{
    Try { Do ##class(%Embedding.Config).%DeleteId(name) } Catch {}
}

}
