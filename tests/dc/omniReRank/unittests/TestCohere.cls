Include (%occStatus, %outUnitTest)

/// Unit tests for the dc.omniReRank bootstrap.
/// Covers Cohere provider payload/parse/auth/validate, plus the Engine's SQL
/// entry point across the I/O matrix (empty candidates, missing config,
/// missing rerank sub-block, missing credential, malformed candidates JSON,
/// unknown provider, empty query, and a happy-path dispatch via a mock
/// provider injected through the process-private hook).
Class dc.omniReRank.unittests.TestCohere Extends %UnitTest.TestCase
{

Parameter TESTCONFIG = "dcOmniReRankTestCfg";

Parameter TESTCRED = "dcOmniReRankTestCred";

// =========================================================================

// Cohere provider — BuildPayload

// =========================================================================

Method TestBuildPayloadShape()
{
    Set candidates = ##class(%DynamicArray).%FromJSON("[""a"",""b"",""c""]")
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""rerank-v3.5"",""apiKey"":""k""}")
    Set payload = ##class(dc.omniReRank.provider.Cohere).BuildPayload("q", candidates, cfg)
    Do $$$AssertEquals(payload.model, "rerank-v3.5", "model")
    Do $$$AssertEquals(payload.query, "q", "query")
    Do $$$AssertEquals(payload."top_n", 3, "top_n defaults to candidate count")
    Do $$$AssertEquals(payload.documents.%Get(0), "a", "documents[0]")
    Do $$$AssertEquals(payload.documents.%Size(), 3, "documents length")
}

Method TestBuildPayloadExplicitTopN()
{
    Set candidates = ##class(%DynamicArray).%FromJSON("[""a"",""b"",""c""]")
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""rerank-v3.5"",""apiKey"":""k"",""topN"":2}")
    Set payload = ##class(dc.omniReRank.provider.Cohere).BuildPayload("q", candidates, cfg)
    Do $$$AssertEquals(payload."top_n", 2, "explicit topN wins")
}

// =========================================================================

// Cohere provider — ParseResponse

// =========================================================================

Method TestParseResponseValid()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""results"":[{""index"":2,""relevance_score"":0.9},{""index"":0,""relevance_score"":0.5}]}")
    Set out = ##class(dc.omniReRank.provider.Cohere).ParseResponse(body)
    Do $$$AssertEquals(out.%Size(), 2, "two rows returned")
    Do $$$AssertEquals(out.%Get(0).%Get("index"), 2, "row 0 index")
    Do $$$AssertEquals(out.%Get(1).%Get("index"), 0, "row 1 index")
}

Method TestParseResponseMissingResults()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""foo"":1}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Cohere).ParseResponse(body) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when 'results' is missing")
    Do $$$AssertTrue($Find(msg, "results") > 0, "error mentions 'results'")
    Do $$$AssertTrue($Find(msg, "Body:") > 0, "error includes body dump")
}

// =========================================================================

// Cohere provider — SetAuth (uses process-private credential hook)

// =========================================================================

Method TestSetAuthUsesBearer()
{
    Set ^||omniReRankCredential("cohere-test") = "ck-live"
    Set request = ##class(%Net.HttpRequest).%New()
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""m"",""apiKey"":""cohere-test""}")
    Do ##class(dc.omniReRank.provider.Cohere).SetAuth(request, cfg)
    Do $$$AssertEquals(request.Authorization, "Bearer ck-live", "Authorization: Bearer <resolved>")
    Kill ^||omniReRankCredential("cohere-test")
}

// =========================================================================

// Cohere provider — ValidateConfig

// =========================================================================

Method TestValidateMissingModelName()
{
    Set cfg = ##class(%DynamicObject).%FromJSON("{""apiKey"":""k""}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Cohere).ValidateConfig(cfg) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when modelName missing")
    Do $$$AssertTrue($Find(msg, "modelName") > 0, "error mentions modelName")
}

Method TestValidateMissingApiKey()
{
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""rerank-v3.5""}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Cohere).ValidateConfig(cfg) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when apiKey missing")
    Do $$$AssertTrue($Find(msg, "apiKey") > 0, "error mentions apiKey")
}

// =========================================================================

// Base — StatusHint (covers the Cohere-4xx matrix row: hint names the

// credential name; never leaks the resolved secret)

// =========================================================================

Method TestStatusHint401NamesCredential()
{
    Set cfg = ##class(%DynamicObject).%FromJSON("{""apiKey"":""CohereCred""}")
    Set hint = ##class(dc.omniReRank.provider.Cohere).StatusHint(401, cfg)
    Do $$$AssertTrue($Find(hint, "CohereCred") > 0, "401 hint names the credential")
    Do $$$AssertTrue($Find(hint, "authentication") > 0, "401 hint explains auth")
}

Method TestStatusHint404MentionsModel()
{
    Set cfg = ##class(%DynamicObject).%FromJSON("{""apiKey"":""CohereCred""}")
    Set hint = ##class(dc.omniReRank.provider.Cohere).StatusHint(404, cfg)
    Do $$$AssertTrue($Find(hint, "modelName") > 0, "404 hint points at modelName")
}

// =========================================================================

// Engine — I/O matrix

// =========================================================================

Method TestEngineEmptyCandidates()
{
    Set rs = ##class(dc.omniReRank.Engine).Rerank("q", "[]", ..#TESTCONFIG)
    Do $$$AssertEquals(rs.%Next(), 0, "empty result set for empty candidates (no config lookup, no HTTP)")
}

Method TestEngineMalformedCandidatesJson()
{
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("q", "not-json", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws on malformed candidatesJson")
    Do $$$AssertTrue($Find(msg, "candidatesJson") > 0, "error names the offending argument")
}

Method TestEngineMissingConfig()
{
    Do ..DeleteConfig(..#TESTCONFIG)
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("q", "[""a""]", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when config not found")
    Do $$$AssertTrue($Find(msg, ..#TESTCONFIG) > 0, "error names the missing config")
    Do $$$AssertTrue($Find(msg, "%Embedding.Config") > 0, "error identifies the store checked")
}

Method TestEngineMissingRerankBlock()
{
    Do ..DeleteConfig(..#TESTCONFIG)
    Do ..MakeConfig(..#TESTCONFIG, "{""dimensions"":1024}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("q", "[""a""]", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do ..DeleteConfig(..#TESTCONFIG)
    Do $$$AssertTrue(threw, "throws when 'rerank' sub-block absent")
    Do $$$AssertTrue($Find(msg, "rerank") > 0, "error mentions rerank sub-block")
    Do $$$AssertTrue($Find(msg, ..#TESTCONFIG) > 0, "error names the config")
}

Method TestEngineEmptyQuery()
{
    Do ..DeleteConfig(..#TESTCONFIG)
    Do ..MakeConfig(..#TESTCONFIG, "{""rerank"":{""provider"":""cohere"",""modelName"":""rerank-v3.5"",""apiKey"":"""_..#TESTCRED_"""}}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("", "[""a""]", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do ..DeleteConfig(..#TESTCONFIG)
    Do $$$AssertTrue(threw, "throws on empty query")
    Do $$$AssertTrue($Find(msg, "query") > 0, "error mentions query")
}

Method TestEngineUnknownProvider()
{
    Do ..DeleteConfig(..#TESTCONFIG)
    Do ..MakeConfig(..#TESTCONFIG, "{""rerank"":{""provider"":""voyage"",""modelName"":""x"",""apiKey"":""y""}}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("q", "[""a""]", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do ..DeleteConfig(..#TESTCONFIG)
    Do $$$AssertTrue(threw, "throws on unknown provider")
    Do $$$AssertTrue($Find(msg, "voyage") > 0, "error names the bad provider")
    Do $$$AssertTrue($Find(msg, "cohere") > 0, "error lists valid providers")
}

Method TestEngineMissingCredential()
{
    // Config points at a credential the store doesn't have. Since Ens.Config
    // .Credentials may or may not be present in the test namespace, we assert
    // simply that the call throws and mentions the credential name — never
    // its value (there is none to leak here anyway).
    Kill ^||omniReRankCredential(..#TESTCRED)
    Do ..DeleteConfig(..#TESTCONFIG)
    Do ..MakeConfig(..#TESTCONFIG, "{""rerank"":{""provider"":""cohere"",""modelName"":""rerank-v3.5"",""apiKey"":"""_..#TESTCRED_"""}}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("q", "[""a"",""b""]", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do ..DeleteConfig(..#TESTCONFIG)
    Do $$$AssertTrue(threw, "throws when credential cannot be resolved")
    Do $$$AssertTrue($Find(msg, ..#TESTCRED) > 0, "error names the credential")
}

Method TestEngineHappyPathSortsDesc()
{
    // Dispatch to a MockProvider that returns pre-scored rows out of order.
    // The Engine must merge candidate text back by index and sort DESC.
    Set ^||omniReRankProviderOverride("cohere") = "dc.omniReRank.unittests.MockProvider"
    Do ..DeleteConfig(..#TESTCONFIG)
    Do ..MakeConfig(..#TESTCONFIG, "{""rerank"":{""provider"":""cohere"",""modelName"":""rerank-v3.5"",""apiKey"":""k""}}")

    Try {
        Set rs = ##class(dc.omniReRank.Engine).Rerank("q", "[""alpha"",""beta"",""gamma""]", ..#TESTCONFIG)

        // Row 1: highest score
        Do $$$AssertEquals(rs.%Next(), 1, "first row present")
        Do $$$AssertEquals(rs.candidate, "gamma", "highest score is 'gamma' (index 2)")
        Do $$$AssertEquals(rs.originalIndex, 2, "originalIndex preserved for row 1")

        // Row 2
        Do $$$AssertEquals(rs.%Next(), 1, "second row present")
        Do $$$AssertEquals(rs.candidate, "alpha", "second highest is 'alpha' (index 0)")
        Do $$$AssertEquals(rs.originalIndex, 0, "originalIndex preserved for row 2")

        // Row 3
        Do $$$AssertEquals(rs.%Next(), 1, "third row present")
        Do $$$AssertEquals(rs.candidate, "beta", "third is 'beta' (index 1)")
        Do $$$AssertEquals(rs.originalIndex, 1, "originalIndex preserved for row 3")

        // End
        Do $$$AssertEquals(rs.%Next(), 0, "no more rows")
    }
    Catch happyEx {
        Do $$$AssertTrue(0, "happy path unexpectedly threw: "_happyEx.DisplayString())
    }

    Kill ^||omniReRankProviderOverride("cohere")
    Do ..DeleteConfig(..#TESTCONFIG)
}

// =========================================================================

// Helpers

// =========================================================================

/// Creates a %Embedding.Config row with the given Configuration JSON.
/// Uses reflection to stay resilient to schema variations across IRIS builds.
Method MakeConfig(name As %String, configJson As %String) [ Private ]
{
    Set cfg = ##class(%Embedding.Config).%New()
    Set cfg.Name = name
    Set cfg.Configuration = configJson
    // %Embedding.Config typically requires EmbeddingClass; use OpenAI as a
    // schema-satisfying placeholder — reranking never touches it.
    Try { Set cfg.EmbeddingClass = "%Embedding.OpenAI" } Catch {}
    Try { Set cfg.VectorDataType = "FLOAT" } Catch {}
    Try { Set cfg.VectorLength = 1536 } Catch {}
    // Some builds require an embedding-provider config JSON to satisfy validation;
    // if the caller passed a rerank-only JSON, add minimal embedding fields.
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
