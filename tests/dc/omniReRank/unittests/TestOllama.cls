Include (%occStatus, %outUnitTest)

/// Unit tests for the dc.omniReRank Ollama provider (LLM-as-judge shim).
/// Covers BuildPayload / GetRerankUrl / SetAuth / ValidateConfig /
/// ParseResponse and Engine dispatch for `"ollama"`. 17 tests mirroring the
/// I/O matrix in the frozen spec.
Class dc.omniReRank.unittests.TestOllama Extends %UnitTest.TestCase
{

Parameter TESTCONFIG = "dcOmniReRankOllamaTestCfg";

// =========================================================================
// BuildPayload
// =========================================================================

Method TestBuildPayloadDefault()
{
    Set candidates = ##class(%DynamicArray).%FromJSON("[""a"",""b"",""c""]")
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""llama3.1:8b-instruct"",""apiBase"":""http://ollama:11434""}")
    Set payload = ##class(dc.omniReRank.provider.Ollama).BuildPayload("q", candidates, cfg)
    Do $$$AssertEquals(payload.model, "llama3.1:8b-instruct", "model")
    Do $$$AssertEquals(+payload.stream, 0, "stream is false")
    Do $$$AssertEquals(payload.format, "json", "format json")
    Do $$$AssertEquals(payload.options.temperature, 0, "default temperature=0")
    Do $$$AssertEquals(payload.messages.%Size(), 2, "system + user")
    Do $$$AssertEquals(payload.messages.%Get(0).role, "system", "role[0]=system")
    Do $$$AssertEquals(payload.messages.%Get(1).role, "user", "role[1]=user")
    Set user = payload.messages.%Get(1).content
    Do $$$AssertTrue($Find(user, "Query: q") > 0, "user contains Query:")
    Do $$$AssertTrue($Find(user, "0: a") > 0, "user has candidate 0")
    Do $$$AssertTrue($Find(user, "1: b") > 0, "user has candidate 1")
    Do $$$AssertTrue($Find(user, "2: c") > 0, "user has candidate 2")
}

Method TestBuildPayloadCustomPromptTemplate()
{
    Set candidates = ##class(%DynamicArray).%FromJSON("[""a""]")
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""m"",""apiBase"":""http://x"",""promptTemplate"":""CUSTOM SYSTEM""}")
    Set payload = ##class(dc.omniReRank.provider.Ollama).BuildPayload("q", candidates, cfg)
    Do $$$AssertEquals(payload.messages.%Get(0).content, "CUSTOM SYSTEM", "custom system prompt used")
}

Method TestBuildPayloadCustomChatOptionsMergeAndOverride()
{
    Set candidates = ##class(%DynamicArray).%FromJSON("[""a""]")
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""m"",""apiBase"":""http://x"",""chatOptions"":{""temperature"":0.3,""num_ctx"":8192}}")
    Set payload = ##class(dc.omniReRank.provider.Ollama).BuildPayload("q", candidates, cfg)
    Do $$$AssertEquals(+payload.options.temperature, 0.3, "caller temperature overrides default")
    Do $$$AssertEquals(+payload.options."num_ctx", 8192, "num_ctx merged")
}

// =========================================================================
// GetRerankUrl
// =========================================================================

Method TestGetRerankUrlBasic()
{
    Set cfg = ##class(%DynamicObject).%FromJSON("{""apiBase"":""http://ollama:11434""}")
    Do $$$AssertEquals(##class(dc.omniReRank.provider.Ollama).GetRerankUrl(cfg), "http://ollama:11434/api/chat", "url composed")
}

Method TestGetRerankUrlTrailingSlash()
{
    Set cfg = ##class(%DynamicObject).%FromJSON("{""apiBase"":""http://ollama:11434/""}")
    Do $$$AssertEquals(##class(dc.omniReRank.provider.Ollama).GetRerankUrl(cfg), "http://ollama:11434/api/chat", "trailing slash collapsed")
}

// =========================================================================
// SetAuth — no-op
// =========================================================================

Method TestSetAuthNoOp()
{
    // No ^||omniReRankCredential seeded — SetAuth must not throw and must
    // leave Authorization empty (no ResolveApiKey call).
    Set request = ##class(%Net.HttpRequest).%New()
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""m"",""apiBase"":""http://x""}")
    Set threw = 0
    Try { Do ##class(dc.omniReRank.provider.Ollama).SetAuth(request, cfg) }
    Catch ex { Set threw = 1 }
    Do $$$AssertEquals(threw, 0, "SetAuth does not throw without credential")
    Do $$$AssertEquals(request.Authorization, "", "Authorization stays empty")
}

// =========================================================================
// ValidateConfig
// =========================================================================

Method TestValidateApiKeyNotRequired()
{
    // Regression guard for spec D5 — apiKey deliberately absent.
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""m"",""apiBase"":""http://x""}")
    Set threw = 0
    Try { Do ##class(dc.omniReRank.provider.Ollama).ValidateConfig(cfg) }
    Catch ex { Set threw = 1 }
    Do $$$AssertEquals(threw, 0, "ValidateConfig does not require apiKey")
}

Method TestValidateMissingModelName()
{
    Set cfg = ##class(%DynamicObject).%FromJSON("{""apiBase"":""http://x""}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Ollama).ValidateConfig(cfg) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when modelName missing")
    Do $$$AssertTrue($Find(msg, "modelName") > 0, "error mentions modelName")
}

Method TestValidateMissingApiBase()
{
    Set cfg = ##class(%DynamicObject).%FromJSON("{""modelName"":""m""}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Ollama).ValidateConfig(cfg) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when apiBase missing")
    Do $$$AssertTrue($Find(msg, "apiBase") > 0, "error mentions apiBase")
}

// =========================================================================
// ParseResponse
// =========================================================================

Method TestParseResponseValid()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""message"":{""role"":""assistant"",""content"":""{\""rankings\"":[{\""index\"":2,\""score\"":0.9},{\""index\"":0,\""score\"":0.5},{\""index\"":1,\""score\"":0.1}]}""}}")
    Set out = ##class(dc.omniReRank.provider.Ollama).ParseResponse(body, 3)
    Do $$$AssertEquals(out.%Size(), 3, "three rows returned")
    Do $$$AssertEquals(+out.%Get(0).%Get("index"), 2, "row 0 index 2")
    Do $$$AssertEquals(+out.%Get(1).%Get("index"), 0, "row 1 index 0")
    Do $$$AssertEquals(+out.%Get(2).%Get("index"), 1, "row 2 index 1")
}

Method TestParseResponseMalformedInnerJson()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""message"":{""role"":""assistant"",""content"":""not-json""}}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Ollama).ParseResponse(body, 2) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws on malformed inner JSON")
    Do $$$AssertTrue($Find(msg, "JSON") > 0, "error mentions JSON")
    Do $$$AssertTrue($Find(msg, "Body:") > 0, "error includes Body dump")
}

Method TestParseResponseMissingMessage()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""foo"":1}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Ollama).ParseResponse(body, 1) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when 'message' missing")
    Do $$$AssertTrue($Find(msg, "message") > 0, "error mentions message")
    Do $$$AssertTrue($Find(msg, "Body:") > 0, "error includes Body dump")
}

Method TestParseResponseMissingRankings()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""message"":{""role"":""assistant"",""content"":""{\""foo\"":1}""}}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Ollama).ParseResponse(body, 1) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when 'rankings' missing")
    Do $$$AssertTrue($Find(msg, "rankings") > 0, "error mentions rankings")
    Do $$$AssertTrue($Find(msg, "Body:") > 0, "error includes Body dump")
}

Method TestParseResponseWrongCount()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""message"":{""role"":""assistant"",""content"":""{\""rankings\"":[{\""index\"":0,\""score\"":0.5}]}""}}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Ollama).ParseResponse(body, 3) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws on count mismatch")
    Do $$$AssertTrue($Find(msg, "expected 3") > 0, "error says expected 3")
    Do $$$AssertTrue($Find(msg, "got 1") > 0, "error says got 1")
    Do $$$AssertTrue($Find(msg, "Body:") > 0, "error includes Body dump")
}

Method TestParseResponseDuplicateIndex()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""message"":{""role"":""assistant"",""content"":""{\""rankings\"":[{\""index\"":0,\""score\"":0.5},{\""index\"":0,\""score\"":0.4},{\""index\"":2,\""score\"":0.1}]}""}}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Ollama).ParseResponse(body, 3) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws on duplicate index")
    Do $$$AssertTrue($Find(msg, "duplicate") > 0, "error mentions duplicate")
    Do $$$AssertTrue($Find(msg, "Body:") > 0, "error includes Body dump")
}

Method TestParseResponseIndexOutOfRange()
{
    Set body = ##class(%DynamicObject).%FromJSON("{""message"":{""role"":""assistant"",""content"":""{\""rankings\"":[{\""index\"":5,\""score\"":0.5},{\""index\"":0,\""score\"":0.3},{\""index\"":1,\""score\"":0.2}]}""}}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.provider.Ollama).ParseResponse(body, 3) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do $$$AssertTrue(threw, "throws when index out of range")
    Do $$$AssertTrue($Find(msg, "out of") > 0, "error mentions out of range")
    Do $$$AssertTrue($Find(msg, "Body:") > 0, "error includes Body dump")
}

// =========================================================================
// Engine dispatch
// =========================================================================

Method TestEngineDispatchesToOllama()
{
    Set ^||omniReRankProviderOverride("ollama") = "dc.omniReRank.unittests.MockProvider"
    Do ..DeleteConfig(..#TESTCONFIG)
    Do ..MakeConfig(..#TESTCONFIG, "{""rerank"":{""provider"":""ollama"",""modelName"":""llama3.1:8b-instruct"",""apiBase"":""http://ollama:11434""}}")

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

    Kill ^||omniReRankProviderOverride("ollama")
    Do ..DeleteConfig(..#TESTCONFIG)
}

Method TestEngineUnknownProviderListsOllama()
{
    Do ..DeleteConfig(..#TESTCONFIG)
    Do ..MakeConfig(..#TESTCONFIG, "{""rerank"":{""provider"":""rerankly"",""modelName"":""x"",""apiKey"":""y""}}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("q", "[""a""]", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ex.DisplayString() }
    Do ..DeleteConfig(..#TESTCONFIG)
    Do $$$AssertTrue(threw, "throws on unknown provider")
    Do $$$AssertTrue($Find(msg, "ollama") > 0, "error lists ollama in valid providers")
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
    If $$$ISERR(sc) { Do $System.Status.DisplayError(sc) }
}

Method DeleteConfig(name As %String) [ Private ]
{
    Try { Do ##class(%Embedding.Config).%DeleteId(name) } Catch {}
}

}
