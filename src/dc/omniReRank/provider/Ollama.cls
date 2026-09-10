Include %occStatus

/// Ollama provider — LLM-as-judge shim over Ollama /api/chat.
/// Ollama does not expose a native /api/rerank endpoint. This provider sends
/// a scoring prompt to an instruction-tuned model requesting a strict
/// {"rankings":[{"index","score"}]} JSON object it then validates.
///
/// Endpoint:  POST <config.apiBase>/api/chat
/// Payload:   {model, messages, format:"json", stream:false, options:{...}}
/// Response:  {message:{role,content:"<json string>"}, ...}
Class dc.omniReRank.provider.Ollama Extends dc.omniReRank.provider.Base
{

/// Default system prompt — locked at spec-time. Changes require a follow-up spec.
Parameter DEFAULTSYSTEMPROMPT = "You are a relevance judge for a search reranking system. You receive a query and a numbered list of candidate texts. Your ONLY job is to score each candidate for relevance to the query and return the result as JSON.

Output contract (STRICT):
- Return a single JSON object with one key: ""rankings"".
- ""rankings"" is an array with EXACTLY one entry per candidate index.
- Each entry has integer ""index"" (0-based, from the input list) and float ""score"" between 0.0 and 1.0 (higher = more relevant).
- Every candidate index MUST appear exactly once. No duplicates. No omissions.
- Return ONLY the JSON object. No prose, no code fences, no commentary.

Example: for two candidates you might return
{""rankings"":[{""index"":1,""score"":0.85},{""index"":0,""score"":0.20}]}";

ClassMethod GetRerankUrl(config As %DynamicObject) As %String
{
    Set base = config.%Get("apiBase")
    // Collapse a trailing slash so we don't emit "//api/chat".
    If $Extract(base, *) = "/" { Set base = $Extract(base, 1, *-1) }
    Return base_"/api/chat"
}

/// SetAuth is intentionally a no-op — Ollama is authless. Deliberate deviation
/// from other Providers per the frozen spec (D5). MUST NOT call ResolveApiKey.
ClassMethod SetAuth(request As %Net.HttpRequest, config As %DynamicObject)
{
    // no-op
}

ClassMethod BuildPayload(query As %String, candidates As %DynamicArray, config As %DynamicObject) As %DynamicObject
{
    Set systemPrompt = config.%Get("promptTemplate")
    If systemPrompt = "" { Set systemPrompt = ..#DEFAULTSYSTEMPROMPT }

    Set userLines = "Query: "_query_$Char(10, 10)_"Candidates:"_$Char(10)
    Set iter = candidates.%GetIterator()
    While iter.%GetNext(.k, .cand) {
        Set userLines = userLines_k_": "_cand_$Char(10)
    }

    Set opts = {"temperature":0}
    Set caller = config.%Get("chatOptions")
    If $IsObject(caller) {
        Set optIter = caller.%GetIterator()
        While optIter.%GetNext(.ok, .ov) { Do opts.%Set(ok, ov) }
    }

    Set payload = {}
    Set payload.model = config.%Get("modelName")
    Set payload.stream = 0
    Set payload.format = "json"
    Set payload.options = opts
    Set payload.messages = [
        {"role":"system","content":(systemPrompt)},
        {"role":"user","content":(userLines)}
    ]
    Return payload
}

/// Parses Ollama's /api/chat response. body.message.content is a JSON string
/// (because format:"json"); we re-parse it and validate strictly against the
/// candidate count.
ClassMethod ParseResponse(body As %DynamicObject, candidateCount As %Integer = 0) As %DynamicArray
{
    Set msg = body.%Get("message")
    If '$IsObject(msg) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Ollama.ParseResponse: 'message' field missing. Body: "_body.%ToJSON()))
    }
    Set content = msg.%Get("content")
    If content = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Ollama.ParseResponse: 'message.content' missing or empty. Body: "_body.%ToJSON()))
    }

    Set inner = ""
    Try {
        Set inner = {}.%FromJSON(content)
    } Catch parseEx {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Ollama.ParseResponse: 'message.content' is not valid JSON. Cause: "_parseEx.DisplayString()_". Body: "_body.%ToJSON()))
    }

    Set rankings = inner.%Get("rankings")
    If '$IsObject(rankings) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Ollama.ParseResponse: parsed content missing 'rankings' array. Body: "_body.%ToJSON()))
    }

    Set got = rankings.%Size()
    If got '= candidateCount {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Ollama.ParseResponse: 'rankings' size mismatch — expected "_candidateCount_" got "_got_". Body: "_body.%ToJSON()))
    }

    Kill seen
    Set out = []
    Set iter = rankings.%GetIterator()
    While iter.%GetNext(.k, .row) {
        If '$IsObject(row) {
            $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Ollama.ParseResponse: 'rankings["_k_"]' is not an object. Body: "_body.%ToJSON()))
        }
        Set idx = row.%Get("index")
        Set score = row.%Get("score")
        If (idx = "") || (score = "") {
            $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Ollama.ParseResponse: 'rankings["_k_"]' missing 'index' or 'score'. Body: "_body.%ToJSON()))
        }
        Set idx = +idx
        If (idx < 0) || (idx >= candidateCount) {
            $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Ollama.ParseResponse: index "_idx_" out of [0,"_candidateCount_"). Body: "_body.%ToJSON()))
        }
        If $Data(seen(idx)) {
            $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Ollama.ParseResponse: duplicate index "_idx_" in 'rankings'. Body: "_body.%ToJSON()))
        }
        Set seen(idx) = 1
        Set score = +score
        If score < 0 { Set score = 0 }
        If score > 1 { Set score = 1 }
        Do out.%Push({"index": (idx), "score": (score)})
    }
    Return out
}

ClassMethod ValidateConfig(config As %DynamicObject)
{
    If config.%Get("modelName") = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Ollama.ValidateConfig: 'modelName' is required"))
    }
    If config.%Get("apiBase") = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Ollama.ValidateConfig: 'apiBase' is required (e.g. http://ollama:11434)"))
    }
    // apiKey deliberately NOT required — Ollama is authless (spec D5).
}

}
