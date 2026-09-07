Include (%occStatus, %outUnitTest)

/// Unit tests for the dc.omniReRank Jina provider.
/// Mirrors the shape of TestCohere/TestVoyage; covers BuildPayload/
/// ParseResponse/SetAuth/ValidateConfig and Engine dispatch for `"jina"`.
Class dc.omniReRank.unittests.TestJina Extends %UnitTest.TestCase
{

Parameter TESTCONFIG = "dcOmniReRankJinaTestCfg";

Parameter TESTCRED = "dcOmniReRankJinaTestCred";

// =========================================================================

// Jina provider — BuildPayload

// =========================================================================

Method TestBuildPayloadShape()
{
    Set candidates = ##class(%DynamicArray).%FromJSON("[""a"",""b"",""c""]")
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""jina-reranker-v2-base-multilingual"",""apiKey"":""k""}")
    Set payload = ##class(dc.omniReRank.provider.Jina).BuildPayload("q", candidates, cfg)
    Do $$$AssertEquals(payload.model, "jina-reranker-v2-base-multilingual", "model")
    Do $$$AssertEquals(payload.query, "q", "query")
    Do $$$AssertEquals(payload."top_n", 3, "top_n defaults to candidate count")
    Do $$$AssertEquals(payload.documents.%Get(0), "a", "documents[0]")
    Do $$$AssertEquals(payload.documents.%Size(), 3, "documents length")
}

Method TestBuildPayloadExplicitTopN()
{
    Set candidates = ##class(%DynamicArray).%FromJSON("[""a"",""b"",""c""]")
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""jina-reranker-v2-base-multilingual"",""apiKey"":""k"",""topN"":2}")
    Set payload = ##class(dc.omniReRank.provider.Jina).BuildPayload("q", candidates, cfg)
    Do $$$AssertEquals(payload."top_n", 2, "explicit topN wins")
}

// =========================================================================

// Jina provider — ParseResponse

// =========================================================================

Method TestParseResponseValid()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""results"":[{""index"":2,""relevance_score"":0.9},{""index"":0,""relevance_score"":0.5}]}")
    Set out = ##class(dc.omniReRank.provider.Jina).ParseResponse(body)
    Do $$$AssertEquals(out.%Size(), 2, "two rows returned")
    Do $$$AssertEquals(out.%Get(0).%Get("index"), 2, "row 0 index")
    Do $$$AssertEquals(out.%Get(1).%Get("index"), 0, "row 1 index")
}

Method TestParseResponseMissingResults()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""foo"":1}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Jina).ParseResponse(body) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when 'results' is missing")
    Do $$$AssertTrue($Find(msg, "results") > 0, "error mentions 'results'")
    Do $$$AssertTrue($Find(msg, "Body:") > 0, "error includes body dump")
}

Method TestParseResponseMissingRelevanceScore()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""results"":[{""index"":0}]}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Jina).ParseResponse(body) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when 'relevance_score' missing")
    Do $$$AssertTrue($Find(msg, "relevance_score") > 0, "error mentions relevance_score")
    Do $$$AssertTrue($Find(msg, "Body:") > 0, "error includes body dump")
}

// =========================================================================

// Jina provider — SetAuth

// =========================================================================

Method TestSetAuthUsesBearer()
{
    Set ^||omniReRankCredential("JinaCred") = "jk-live"
    Set request = ##class(%Net.HttpRequest).%New()
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""m"",""apiKey"":""JinaCred""}")
    Do ##class(dc.omniReRank.provider.Jina).SetAuth(request, cfg)
    Do $$$AssertEquals(request.Authorization, "Bearer jk-live", "Authorization: Bearer <resolved>")
    Kill ^||omniReRankCredential("JinaCred")
}

// =========================================================================

// Jina provider — ValidateConfig

// =========================================================================

Method TestValidateMissingModelName()
{
    Set cfg = ##class(%DynamicObject).%FromJSON("{""apiKey"":""k""}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Jina).ValidateConfig(cfg) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when modelName missing")
    Do $$$AssertTrue($Find(msg, "modelName") > 0, "error mentions modelName")
}

Method TestValidateMissingApiKey()
{
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""jina-reranker-v2-base-multilingual""}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Jina).ValidateConfig(cfg) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when apiKey missing")
    Do $$$AssertTrue($Find(msg, "apiKey") > 0, "error mentions apiKey")
}

// =========================================================================

// Engine dispatch

// =========================================================================

Method TestEngineDispatchesToJina()
{
    // Override the "jina" branch with the mock provider so we exercise the
    // dispatch path without network I/O. Mock returns fixed scores; engine
    // must sort DESC and preserve originalIndex.
    Set ^||omniReRankProviderOverride("jina") = "dc.omniReRank.unittests.MockProvider"
    Do ..DeleteConfig(..#TESTCONFIG)
    Do ..MakeConfig(..#TESTCONFIG, "{""rerank"":{""provider"":""jina"",""modelName"":""jina-reranker-v2-base-multilingual"",""apiKey"":""k""}}")

    Try {
        Set rs = ##class(dc.omniReRank.Engine).Rerank("q", "[""alpha"",""beta"",""gamma""]", ..#TESTCONFIG)
        Do $$$AssertEquals(rs.%Next(), 1, "first row present")
        Do $$$AssertEquals(rs.originalIndex, 2, "highest scoring index is 2")
        Do $$$AssertEquals(rs.%Next(), 1, "second row present")
        Do $$$AssertEquals(rs.originalIndex, 0, "second highest is index 0")
        Do $$$AssertEquals(rs.%Next(), 1, "third row present")
        Do $$$AssertEquals(rs.originalIndex, 1, "third is index 1")
        Do $$$AssertEquals(rs.%Next(), 0, "no more rows")
    }
    Catch happyEx {
        Do $$$AssertTrue(0, "dispatch unexpectedly threw: "_happyEx.DisplayString())
    }

    Kill ^||omniReRankProviderOverride("jina")
    Do ..DeleteConfig(..#TESTCONFIG)
}

// =========================================================================

// Helpers

// =========================================================================

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
