Include %occStatus

/// Test-only provider that overrides Base.PostOnce to inject synthetic HTTP
/// responses from a process-private FIFO queue at
/// ^||omniReRankMockPostQueue(1..N) = $LB(status, headersString, body).
/// 
/// `headersString` is a raw HTTP header block (lines separated by CRLF or LF),
/// e.g. "Retry-After: 1". Empty string means no extra headers.
/// 
/// If the queue is empty on a PostOnce call, throws — test starvation is a
/// test bug, not a silent zero.
Class dc.omniReRank.unittests.MockHttpProvider Extends dc.omniReRank.provider.Base
{

ClassMethod PostOnce(request As %Net.HttpRequest, url As %String) As %Status
{
    // Pop the lowest-numbered entry from the queue.
    Set idx = $Order(^||omniReRankMockPostQueue(""))
    If idx = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.unittests.MockHttpProvider: mock queue empty on PostOnce — test seeded fewer responses than the code path consumed"))
    }
    Set entry = ^||omniReRankMockPostQueue(idx)
    Kill ^||omniReRankMockPostQueue(idx)

    Set status = $ListGet(entry, 1)
    Set headers = $ListGet(entry, 2)
    Set body = $ListGet(entry, 3)

    // Sentinel: status = "ERR" means return an error %Status (transport failure).
    // The body carries the error text.
    If status = "ERR" {
        Return $$$ERROR($$$GeneralError, body)
    }

    // Build a synthetic HttpResponse.
    Set resp = ##class(%Net.HttpResponse).%New()
    Set resp.StatusCode = status
    Set data = ##class(%GlobalCharacterStream).%New()
    If body '= "" { Do data.Write(body) }
    Do data.Rewind()
    Set resp.Data = data

    // Parse headers block, one "Name: value" per line.
    If headers '= "" {
        Set normalized = $Replace(headers, $Char(13, 10), $Char(10))
        For lineIdx = 1:1:$Length(normalized, $Char(10)) {
            Set line = $Piece(normalized, $Char(10), lineIdx)
            If line = "" { Continue }
            Set hname = $ZStrip($Piece(line, ":", 1), "<>W")
            Set hval  = $ZStrip($Piece(line, ":", 2, *), "<>W")
            If hname '= "" { Do resp.SetHeader(hname, hval) }
        }
    }

    Set request.HttpResponse = resp
    Return $$$OK
}

ClassMethod ValidateConfig(config As %DynamicObject)
{
}

ClassMethod SetAuth(request As %Net.HttpRequest, config As %DynamicObject)
{
}

ClassMethod GetRerankUrl(config As %DynamicObject) As %String
{
    Return "https://mock.local/v2/rerank"
}

ClassMethod BuildPayload(query As %String, candidates As %DynamicArray, config As %DynamicObject) As %DynamicObject
{
    Return {"query": (query), "documents": (candidates)}
}

/// Matches Cohere's {results:[{index,relevance_score},...]} shape.
ClassMethod ParseResponse(body As %DynamicObject, candidateCount As %Integer = 0) As %DynamicArray
{
    Set results = body.%Get("results")
    If '$IsObject(results) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "MockHttpProvider.ParseResponse: response missing 'results'. Body: "_body.%ToJSON()))
    }
    Set out = []
    Set iter = results.%GetIterator()
    While iter.%GetNext(.k, .row) {
        Do out.%Push({"index": (+row.%Get("index")), "score": (+row.%Get("relevance_score"))})
    }
    Return out
}

}
