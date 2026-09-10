/// Test-only mock provider injected via ^||omniReRankProviderOverride.
/// Returns fixed scored rows so the Engine's dispatch, sort, and result-set
/// wiring can be exercised without any network I/O.
Class dc.omniReRank.unittests.MockProvider Extends dc.omniReRank.provider.Base
{

ClassMethod Execute(query As %String, candidates As %DynamicArray, config As %DynamicObject) As %DynamicArray
{
    // Deliberately out of order and with a middle candidate scoring lowest,
    // so tests verify DESC-sort AND original-index preservation.
    // Assumes at least 3 candidates.
    Set out = []
    Do out.%Push({"index": 0, "score": 0.6})
    Do out.%Push({"index": 1, "score": 0.2})
    Do out.%Push({"index": 2, "score": 0.9})
    Return out
}

ClassMethod ValidateConfig(config As %DynamicObject)
{
}

ClassMethod SetAuth(request As %Net.HttpRequest, config As %DynamicObject)
{
}

ClassMethod GetRerankUrl(config As %DynamicObject) As %String
{
    Return ""
}

ClassMethod BuildPayload(query As %String, candidates As %DynamicArray, config As %DynamicObject) As %DynamicObject
{
    Return {}
}

ClassMethod ParseResponse(body As %DynamicObject, candidateCount As %Integer = 0) As %DynamicArray
{
    Return []
}

}
