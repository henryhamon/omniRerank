Include %occStatus

/// Cohere provider — Cohere v2 /rerank API.
/// Payload:  {query, documents, model, top_n}
/// Response: {results:[{index, relevance_score}, ...], ...}
Class dc.omniReRank.provider.Cohere Extends dc.omniReRank.provider.Base
{

ClassMethod GetRerankUrl(config As %DynamicObject) As %String
{
    Return "https://api.cohere.com/v2/rerank"
}

ClassMethod SetAuth(request As %Net.HttpRequest, config As %DynamicObject)
{
    Set key = ..ResolveApiKey(config)
    If key = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Cohere.SetAuth: 'apiKey' resolves to empty value"))
    }
    Set request.Authorization = "Bearer "_key
}

ClassMethod BuildPayload(query As %String, candidates As %DynamicArray, config As %DynamicObject) As %DynamicObject
{
    Set payload = {}
    Set payload.model = config.%Get("modelName")
    Set payload.query = query
    Set payload.documents = candidates

    // top_n defaults to the number of candidates when unset — always return
    // scores for the full input set.
    Set topN = config.%Get("topN")
    If topN = "" { Set topN = candidates.%Size() }
    Set payload."top_n" = +topN

    Return payload
}

/// Extracts body.results[] -> %DynamicArray of {"index","score"} objects,
/// preserving Cohere's own ordering. Throws with body content on any missing
/// field.
ClassMethod ParseResponse(body As %DynamicObject, candidateCount As %Integer = 0) As %DynamicArray
{
    Set results = body.%Get("results")
    If '$IsObject(results) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Cohere.ParseResponse: 'results' field missing. Body: "_body.%ToJSON()))
    }
    Set out = []
    Set iter = results.%GetIterator()
    While iter.%GetNext(.k, .row) {
        If '$IsObject(row) {
            $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Cohere.ParseResponse: 'results["_k_"]' is not an object. Body: "_body.%ToJSON()))
        }
        Set idx = row.%Get("index")
        Set score = row.%Get("relevance_score")
        If (idx = "") || (score = "") {
            $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Cohere.ParseResponse: 'results["_k_"]' missing 'index' or 'relevance_score'. Body: "_body.%ToJSON()))
        }
        Do out.%Push({"index": (+idx), "score": (+score)})
    }
    Return out
}

ClassMethod ValidateConfig(config As %DynamicObject)
{
    If config.%Get("modelName") = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Cohere.ValidateConfig: 'modelName' is required"))
    }
    If config.%Get("apiKey") = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Cohere.ValidateConfig: 'apiKey' is required"))
    }
}

}
