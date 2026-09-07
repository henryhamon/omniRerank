Include %occStatus

/// Voyage provider — Voyage AI /v1/rerank API.
/// Payload:  {query, documents, model, top_k}
/// Response: {data:[{index, relevance_score}, ...], ...}
Class dc.omniReRank.provider.Voyage Extends dc.omniReRank.provider.Base
{

ClassMethod GetRerankUrl(config As %DynamicObject) As %String
{
    Return "https://api.voyageai.com/v1/rerank"
}

ClassMethod SetAuth(request As %Net.HttpRequest, config As %DynamicObject)
{
    Set key = ..ResolveApiKey(config)
    If key = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Voyage.SetAuth: 'apiKey' resolves to empty value"))
    }
    Set request.Authorization = "Bearer "_key
}

ClassMethod BuildPayload(query As %String, candidates As %DynamicArray, config As %DynamicObject) As %DynamicObject
{
    Set payload = {}
    Set payload.query = query
    Set payload.documents = candidates
    Set payload.model = config.%Get("modelName")

    // top_k defaults to the number of candidates when unset — always return
    // scores for the full input set.
    Set topK = config.%Get("topK")
    If topK = "" { Set topK = candidates.%Size() }
    Set payload."top_k" = +topK

    Return payload
}

/// Extracts body.data[] -> %DynamicArray of {"index","score"} objects,
/// preserving Voyage's own ordering. Throws with body content on any missing
/// field.
ClassMethod ParseResponse(body As %DynamicObject) As %DynamicArray
{
    Set data = body.%Get("data")
    If '$IsObject(data) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Voyage.ParseResponse: 'data' field missing. Body: "_body.%ToJSON()))
    }
    Set out = []
    Set iter = data.%GetIterator()
    While iter.%GetNext(.k, .row) {
        If '$IsObject(row) {
            $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Voyage.ParseResponse: 'data["_k_"]' is not an object. Body: "_body.%ToJSON()))
        }
        Set idx = row.%Get("index")
        Set score = row.%Get("relevance_score")
        If (idx = "") || (score = "") {
            $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Voyage.ParseResponse: 'data["_k_"]' missing 'index' or 'relevance_score'. Body: "_body.%ToJSON()))
        }
        Do out.%Push({"index": (+idx), "score": (+score)})
    }
    Return out
}

ClassMethod ValidateConfig(config As %DynamicObject)
{
    If config.%Get("modelName") = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Voyage.ValidateConfig: 'modelName' is required"))
    }
    If config.%Get("apiKey") = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Voyage.ValidateConfig: 'apiKey' is required"))
    }
}

}
