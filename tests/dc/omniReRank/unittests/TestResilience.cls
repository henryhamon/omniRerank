Include (%occStatus, %outUnitTest)

/// Tests for retry+backoff on Base and the circuit breaker on Engine.
/// Exercises HTTP failure paths through the MockHttpProvider seam so no real
/// network I/O happens.
Class dc.omniReRank.unittests.TestResilience Extends %UnitTest.TestCase
{

Parameter TESTCONFIG = "dcOmniReRankResilienceCfg";

Parameter PROVIDERKEY = "cohere|rerank-v3.5";

/// rerank sub-block: sets retry timings to 1ms so exhaustion tests don't sleep.
Parameter RERANKJSON = "{""rerank"":{""provider"":""cohere"",""modelName"":""rerank-v3.5"",""apiKey"":""k"",""retry"":{""baseDelayMs"":1,""maxDelayMs"":1}}}";

Method OnBeforeAllTests() As %Status
{
    Set ^||omniReRankProviderOverride("cohere") = "dc.omniReRank.unittests.MockHttpProvider"
    Do ..Cleanup()
    Do ..MakeConfig(..#TESTCONFIG, ..#RERANKJSON)
    Return $$$OK
}

Method OnAfterAllTests() As %Status
{
    Do ..Cleanup()
    Do ..DeleteConfig(..#TESTCONFIG)
    Kill ^||omniReRankProviderOverride("cohere")
    Return $$$OK
}

Method OnBeforeOneTest(testname As %String) As %Status
{
    // Ensure the config still exists — some tests share the class, and if a
    // prior test suite ran an %OnAfterAllTests that dropped it, re-create it.
    If '##class(%Embedding.Config).%ExistsId(..#TESTCONFIG) {
        Do ..MakeConfig(..#TESTCONFIG, ..#RERANKJSON)
    }
    Do ..Cleanup()
    Return $$$OK
}

// =========================================================================

// I/O matrix

// =========================================================================

Method TestRetryOn5xxThen200()
{
    Set ^||omniReRankMockPostQueue(1) = $ListBuild(503, "", "")
    Set ^||omniReRankMockPostQueue(2) = $ListBuild(503, "", "")
    Set ^||omniReRankMockPostQueue(3) = $ListBuild(200, "", "{""results"":[{""index"":0,""relevance_score"":0.9}]}")
    Set rs = ##class(dc.omniReRank.Engine).Rerank("q", "[""x""]", ..#TESTCONFIG)
    Do $$$AssertEquals(rs.%Next(), 1, "one row present after 5xx-5xx-200")
    Do $$$AssertEquals(rs.originalIndex, 0, "originalIndex 0")
    Do $$$AssertEquals(rs.candidate, "x", "candidate 'x'")
    Do $$$AssertEquals(rs.score, 0.9, "score 0.9")
    Do $$$AssertEquals(rs.%Next(), 0, "no more rows")
    // Success resets the breaker
    Set data = $Get(^omniReRank.Breaker(..#PROVIDERKEY))
    Do $$$AssertEquals(data, $ListBuild(0, 0), "breaker reset to (0,0) after success")
}

Method TestRetryOn429WithRetryAfter()
{
    // Retry-After: 1 makes the delay ~1s regardless of the config timings.
    Set ^||omniReRankMockPostQueue(1) = $ListBuild(429, "Retry-After: 1", "")
    Set ^||omniReRankMockPostQueue(2) = $ListBuild(200, "", "{""results"":[]}")
    Set t0 = $ZH
    Set rs = ##class(dc.omniReRank.Engine).Rerank("q", "[""a""]", ..#TESTCONFIG)
    Set elapsed = $ZH - t0
    Do $$$AssertEquals(rs.%Next(), 0, "empty results parses OK")
    Do $$$AssertTrue(elapsed >= 0.9, "Retry-After honored (elapsed >= ~1s, got "_elapsed_")")
}

Method TestFastFailOn400()
{
    Set ^||omniReRankMockPostQueue(1) = $ListBuild(400, "", "bad-request")
    // Seed extra entries to prove they were NOT consumed.
    Set ^||omniReRankMockPostQueue(2) = $ListBuild(200, "", "{""results"":[]}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("q", "[""a""]", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ..ExMsg(ex) }
    Do $$$AssertTrue(threw, "fast-fails on 400")
    Do $$$AssertTrue($Find(msg, "400") > 0, "error names status 400")
    Do $$$AssertTrue($Find(msg, "bad-request") > 0, "error carries body snippet")
    // Second queue entry must remain — no retry on 400.
    Do $$$AssertTrue($Data(^||omniReRankMockPostQueue(2)) > 0, "queue entry 2 NOT consumed (no retry on 400)")
}

Method TestRetriesExhaustedOn500()
{
    Set ^||omniReRankMockPostQueue(1) = $ListBuild(500, "", "boom")
    Set ^||omniReRankMockPostQueue(2) = $ListBuild(500, "", "boom")
    Set ^||omniReRankMockPostQueue(3) = $ListBuild(500, "", "boom")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("q", "[""a""]", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ..ExMsg(ex) }
    Do $$$AssertTrue(threw, "throws when retries exhausted")
    Do $$$AssertTrue($Find(msg, "500") > 0, "error names status 500")
    Do $$$AssertTrue($Find(msg, "exhausted") > 0, "error says 'exhausted'")
    Do $$$AssertTrue($Find(msg, "3") > 0, "error names attempt count 3")
    // Breaker records a failure (one Engine.Rerank invocation = one RecordFailure).
    Set data = $Get(^omniReRank.Breaker(..#PROVIDERKEY))
    Do $$$AssertEquals($ListGet(data, 1), 1, "breaker failure counter incremented to 1")
}

Method TestTransportError()
{
    Set ^||omniReRankMockPostQueue(1) = $ListBuild("ERR", "", "socket closed")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("q", "[""a""]", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ..ExMsg(ex) }
    Do $$$AssertTrue(threw, "throws on transport error")
    Do $$$AssertTrue($Find(msg, "transport") > 0, "error mentions 'transport'")
    // No retry on transport error.
    Do $$$AssertEquals($Order(^||omniReRankMockPostQueue("")), "", "queue drained by exactly one PostOnce call (no retry on transport)")
}

Method TestBreakerOpensAfterNFailures()
{
    // Seed the breaker directly at threshold, opened just now.
    Set ^omniReRank.Breaker(..#PROVIDERKEY) = $ListBuild(5, ##class(dc.omniReRank.Engine).NowSeconds())
    // Also seed the queue — if the breaker leaks, PostOnce would consume it.
    Set ^||omniReRankMockPostQueue(1) = $ListBuild(200, "", "{""results"":[]}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("q", "[""a""]", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ..ExMsg(ex) }
    Do $$$AssertTrue(threw, "throws when breaker is open")
    Do $$$AssertTrue($Find(msg, "circuit breaker open") > 0, "error says 'circuit breaker open'")
    Do $$$AssertTrue($Data(^||omniReRankMockPostQueue(1)) > 0, "queue entry NOT consumed (no HTTP dispatch)")
}

Method TestBreakerHalfOpenAfterCooldown()
{
    // Opened 61s ago — cooldown elapsed, allow one attempt through.
    Set ^omniReRank.Breaker(..#PROVIDERKEY) = $ListBuild(5, ##class(dc.omniReRank.Engine).NowSeconds() - 61)
    Set ^||omniReRankMockPostQueue(1) = $ListBuild(200, "", "{""results"":[]}")
    Set rs = ##class(dc.omniReRank.Engine).Rerank("q", "[""a""]", ..#TESTCONFIG)
    Do $$$AssertEquals(rs.%Next(), 0, "call went through and returned an empty result set")
    Set data = $Get(^omniReRank.Breaker(..#PROVIDERKEY))
    Do $$$AssertEquals(data, $ListBuild(0, 0), "breaker reset to (0,0) after half-open success")
}

Method TestBreakerRecordsSuccessAsListBuild00()
{
    Do ##class(dc.omniReRank.Engine).RecordFailure(..#PROVIDERKEY)
    Do ##class(dc.omniReRank.Engine).RecordSuccess(..#PROVIDERKEY)
    Set data = $Get(^omniReRank.Breaker(..#PROVIDERKEY))
    Do $$$AssertEquals(data, $ListBuild(0, 0), "RecordSuccess explicitly sets $LB(0,0)")
}

Method TestBreakerSixthCallShortCircuits()
{
    // Five direct failures bring the breaker to threshold + opened.
    For i = 1:1:5 { Do ##class(dc.omniReRank.Engine).RecordFailure(..#PROVIDERKEY) }
    Set data = $Get(^omniReRank.Breaker(..#PROVIDERKEY))
    Do $$$AssertEquals($ListGet(data, 1), 5, "failure counter at 5")
    Do $$$AssertTrue($ListGet(data, 2) > 0, "breaker opened at a real timestamp")
    // Sixth call must short-circuit: seed a success and prove it's not consumed.
    Set ^||omniReRankMockPostQueue(1) = $ListBuild(200, "", "{""results"":[]}")
    Set threw = 0, msg = ""
    Try { Do ##class(dc.omniReRank.Engine).Rerank("q", "[""a""]", ..#TESTCONFIG) }
    Catch ex { Set threw = 1, msg = ..ExMsg(ex) }
    Do $$$AssertTrue(threw, "sixth call throws")
    Do $$$AssertTrue($Find(msg, "circuit breaker open") > 0, "sixth call names breaker")
    Do $$$AssertTrue($Data(^||omniReRankMockPostQueue(1)) > 0, "queue NOT consumed on sixth call")
}

Method TestProviderKeyShape()
{
    Set cfg = ##class(%DynamicObject).%FromJSON("{""provider"":""cohere"",""modelName"":""rerank-v3.5""}")
    Do $$$AssertEquals(##class(dc.omniReRank.Engine).ProviderKey(cfg), "cohere|rerank-v3.5", "provider|modelName only")
}

Method TestCheckBreakerBelowThreshold()
{
    Set ^omniReRank.Breaker(..#PROVIDERKEY) = $ListBuild(4, ##class(dc.omniReRank.Engine).NowSeconds())
    Do $$$AssertEquals(##class(dc.omniReRank.Engine).CheckBreaker(..#PROVIDERKEY), 0, "closed when failures < threshold")
}

Method TestRecordFailureOpensAtThreshold()
{
    For i = 1:1:4 { Do ##class(dc.omniReRank.Engine).RecordFailure(..#PROVIDERKEY) }
    Set data = $Get(^omniReRank.Breaker(..#PROVIDERKEY))
    Do $$$AssertEquals($ListGet(data, 1), 4, "counter at 4")
    Do $$$AssertEquals($ListGet(data, 2), 0, "not yet opened")
    Do ##class(dc.omniReRank.Engine).RecordFailure(..#PROVIDERKEY)
    Set data = $Get(^omniReRank.Breaker(..#PROVIDERKEY))
    Do $$$AssertEquals($ListGet(data, 1), 5, "counter at 5")
    Do $$$AssertTrue($ListGet(data, 2) > 0, "opened at threshold")
}

// =========================================================================

// Helpers

// =========================================================================

/// Extract the full error text from an exception. `%Exception.StatusException.
/// DisplayString()` truncates in some IRIS builds, so drop back to the
/// underlying %Status text which always carries the full message.
Method ExMsg(ex As %Exception.AbstractException) As %String [ Private ]
{
    If $IsObject(ex), ex.%IsA("%Exception.StatusException") {
        Return $System.Status.GetErrorText(ex.AsStatus())
    }
    Return ex.DisplayString()
}

Method Cleanup() [ Private ]
{
    Kill ^||omniReRankMockPostQueue
    Kill ^omniReRank.Breaker
}

Method MakeConfig(name As %String, configJson As %String) [ Private ]
{
    Do ..DeleteConfig(name)
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
