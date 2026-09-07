Include %occStatus

/// Abstract base class for all dc.omniReRank providers.
/// Implements a Template-Method Execute() — NOT [Final]. Providers with a
/// legitimate ordering constraint (e.g. request-signing schemes such as SigV4
/// that must run AFTER the payload is written) may override the whole
/// sequence; all others MUST use this template unchanged.
/// 
/// Subclasses override: SetAuth, GetRerankUrl, BuildPayload, ParseResponse,
/// ValidateConfig. ValidateConfig subclasses MUST call ##super() first if they
/// add more checks.
/// 
/// Compared to dc.omniEmbedding.provider.Base this Base is deliberately
/// smaller: no retry/backoff, no circuit-breaker, no vector helpers. Those are
/// deferred to follow-up specs and MUST NOT be stubbed here to avoid dead code.
Class dc.omniReRank.provider.Base [ Abstract ]
{

/// Template Method — NOT declared Final.
/// Sequence: ValidateConfig -> SetAuth -> GetRerankUrl -> BuildPayload
///           -> POST (fast-fail on non-2xx) -> ParseResponse
/// 
/// `config` is the `rerank` sub-object of a %Embedding.Config Configuration
/// JSON, already extracted by the Engine; providers never see embedding
/// fields.
ClassMethod Execute(query As %String, candidates As %DynamicArray, config As %DynamicObject) As %DynamicArray
{
    Do ..ValidateConfig(config)

    Set request = ##class(%Net.HttpRequest).%New()
    Set request.ContentType = "application/json"
    Set timeout = config.%Get("httpTimeout")
    Set request.Timeout = $Select(+timeout > 0: +timeout, 1: 30)
    Set sslConfig = config.%Get("sslConfig")
    If sslConfig '= "" {
        Set request.SSLConfiguration = sslConfig
    }

    Do ..SetAuth(request, config)

    Set url = ..GetRerankUrl(config)
    Set payload = ..BuildPayload(query, candidates, config)
    Do request.EntityBody.Write(payload.%ToJSON())

    Set response = ..RetryWithBackoff(request, url, config)

    Set body = {}.%FromJSON(response.Data)
    Return ..ParseResponse(body)
}

/// Executes the HTTP POST with retry / exponential backoff.
/// Retries on 429 and 5xx. Fast-fails on other 4xx. Honors Retry-After when
/// config.retry.honorRetryAfter is true (default) and the header is present.
/// Retry parameters (all under config.retry, with defaults):
///   maxAttempts (3), baseDelayMs (500), maxDelayMs (8000), honorRetryAfter (1)
/// Throws with the last HTTP status and URL after attempts are exhausted.
ClassMethod RetryWithBackoff(request As %Net.HttpRequest, url As %String, config As %DynamicObject) As %Net.HttpResponse [ Internal ]
{
    Set retry = config.%Get("retry")
    Set maxAttempts = ..RetryParam(retry, "maxAttempts", 3)
    Set honorRetryAfter = ..RetryParam(retry, "honorRetryAfter", 1)

    Set attempt = 0, lastStatus = 0, lastBody = ""
    While attempt < maxAttempts {
        Set attempt = attempt + 1

        Set sc = ..PostOnce(request, url)
        If $$$ISERR(sc) {
            Set transportErr = $System.Status.GetErrorText(sc)
            Set hint = ..TransportHint(url, transportErr)
            $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank: HTTP transport error on POST '"_url_"'. Cause: "_transportErr_hint))
        }

        Set lastStatus = request.HttpResponse.StatusCode

        // Success: 2xx
        If (lastStatus >= 200) && (lastStatus < 300) {
            Return request.HttpResponse
        }

        Set lastBody = ""
        Try { Set lastBody = request.HttpResponse.Data.Read(300) } Catch {}

        // Fast-fail on 4xx that are NOT 429
        If ..IsFastFailStatus(lastStatus) {
            Set hint = ..StatusHint(lastStatus, config)
            $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank: HTTP "_lastStatus_" from '"_url_"' (fast-fail, no retry). "_hint_" Body: "_lastBody))
        }

        // Last attempt: don't sleep, fall through to throw
        If attempt >= maxAttempts { Quit }

        // 429 or 5xx: compute delay and sleep before next attempt
        Set retryAfter = ""
        If honorRetryAfter {
            Set retryAfter = request.HttpResponse.GetHeader("Retry-After")
        }
        Set delayMs = ..ComputeBackoffDelay(attempt, retryAfter, config)
        If delayMs > 0 { Hang delayMs / 1000 }
    }

    Set hint = ..StatusHint(lastStatus, config)
    $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank: HTTP "_lastStatus_" from '"_url_"' (exhausted "_maxAttempts_" attempts). "_hint_" Body: "_lastBody))
}

/// Computes the backoff delay in milliseconds for a given attempt.
/// When retryAfter is non-empty and numeric, returns retryAfter * 1000.
/// Otherwise returns MIN(baseDelayMs * 2^(attempt-1) + rand(baseDelayMs), maxDelayMs).
ClassMethod ComputeBackoffDelay(attempt As %Integer, retryAfter As %String, config As %DynamicObject) As %Integer
{
    Set retry = config.%Get("retry")
    Set baseDelayMs = ..RetryParam(retry, "baseDelayMs", 500)
    Set maxDelayMs = ..RetryParam(retry, "maxDelayMs", 8000)

    If (retryAfter '= "") && ($Match(retryAfter, "^[0-9]+$")) {
        Return +retryAfter * 1000
    }

    Set exp = baseDelayMs * ($ZPower(2, attempt - 1))
    Set jitter = $Random(baseDelayMs)
    Set delay = exp + jitter
    If delay > maxDelayMs { Set delay = maxDelayMs }
    Return delay
}

/// Reads a numeric retry parameter from config.retry with a default fallback.
ClassMethod RetryParam(retry As %DynamicObject, name As %String, default As %Integer) As %Integer [ Private ]
{
    If '$IsObject(retry) { Return default }
    Set v = retry.%Get(name)
    If (v = "") { Return default }
    Return +v
}

/// Injection seam wrapping exactly `request.Post(url)`. Production path is
/// unchanged; test subclasses override to inject synthetic HTTP responses
/// without touching the network.
ClassMethod PostOnce(request As %Net.HttpRequest, url As %String) As %Status
{
    Return request.Post(url)
}

/// Validates provider-specific configuration fields.
/// Subclasses MUST implement (and MAY call ##super() first when Base grows checks).
ClassMethod ValidateConfig(config As %DynamicObject) [ Abstract ]
{
}

/// Sets authentication headers on the HTTP request.
ClassMethod SetAuth(request As %Net.HttpRequest, config As %DynamicObject) [ Abstract ]
{
}

/// Returns the full URL for the rerank endpoint.
ClassMethod GetRerankUrl(config As %DynamicObject) As %String [ Abstract ]
{
}

/// Builds the JSON request body as a %DynamicObject.
ClassMethod BuildPayload(query As %String, candidates As %DynamicArray, config As %DynamicObject) As %DynamicObject [ Abstract ]
{
}

/// Parses the HTTP response body and returns a %DynamicArray of
/// `{"index": <origIndex>, "score": <relevanceScore>}` objects.
/// MUST throw — never return an empty array on failure.
ClassMethod ParseResponse(body As %DynamicObject) As %DynamicArray [ Abstract ]
{
}

/// Returns an actionable hint for common HTTP failure codes.
/// Never leaks the resolved credential value — only the credential NAME
/// (which is public metadata already visible in %Embedding.Config).
ClassMethod StatusHint(status As %Integer, config As %DynamicObject) As %String [ Internal ]
{
    Set credName = config.%Get("apiKey")
    If status = 401 {
        Return "Hint: authentication failed — check that Ens.Config.Credentials '"_credName_"' holds a valid, non-expired key for the provider; regenerate the key in the provider portal if unsure."
    }
    If status = 403 {
        Return "Hint: forbidden — the credential '"_credName_"' resolves, but lacks permission for this endpoint/model/region."
    }
    If status = 404 {
        Return "Hint: not found — verify config.modelName matches something that actually exists at the URL above."
    }
    If status = 413 {
        Return "Hint: payload too large — reduce query length or the number/size of candidates before calling Rerank()."
    }
    If status = 422 {
        Return "Hint: invalid request — check that provider-specific fields (top_n, modelName, etc.) match the model's supported values."
    }
    If status = 429 {
        Return "Hint: rate limited — retry/backoff is not implemented in this spec; back off caller concurrency or ask the provider for a higher quota."
    }
    If (status >= 500) && (status < 600) {
        Return "Hint: upstream provider error — usually transient; retry from the caller."
    }
    Return ""
}

/// Returns an actionable hint for transport-level failures (raised BEFORE any
/// HTTP response arrived — DNS failure, TCP refused, TLS handshake, etc.).
ClassMethod TransportHint(url As %String, errText As %String) As %String [ Internal ]
{
    If $Extract(url, 1, 8) = "https://" {
        Return " Hint: HTTPS calls require an SSL configuration — set 'sslConfig' in the rerank sub-block of your %Embedding.Config JSON to the name of a Security.SSLConfigs entry."
    }
    Return " Hint: verify network reachability (DNS, firewall, proxy) between IRIS and the URL above."
}

/// Returns 1 for statuses that must NOT be retried: any 4xx other than 429.
/// Kept for parity with the omniEmbedding contract even though this spec
/// fast-fails on every non-2xx (retries are deferred to a follow-up spec).
ClassMethod IsFastFailStatus(status As %Integer) As %Boolean
{
    Return ((status >= 400) && (status < 500) && (status '= 429))
}

/// Resolves the API key.
/// config.apiKey is a CREDENTIAL NAME (SystemName), never the value itself.
/// Looks it up in the namespace's Ens.Config.Credentials store and returns
/// the Password (the resolved secret).
/// 
/// SECURITY: exceptions and traces NEVER include the resolved value — only
/// the credential name. Callers MUST treat the return value as secret and
/// never log it.
/// 
/// Returns "" when config.apiKey is absent — providers that require a key
/// enforce non-empty via ValidateConfig / SetAuth.
ClassMethod ResolveApiKey(config As %DynamicObject) As %String
{
    Set name = config.%Get("apiKey")
    If name = "" { Return "" }

    // Test hook: process-private override wins over persistent store.
    // Used by unit tests to inject credentials without touching Ens.Config.Credentials.
    Set testValue = $Get(^||omniReRankCredential(name))
    If testValue '= "" { Return testValue }

    If '$$$comClassDefined("Ens.Config.Credentials") {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Base.ResolveApiKey: credential store 'Ens.Config.Credentials' not available in this namespace; cannot resolve credential '"_name_"'"))
    }

    Set cred = ##class(Ens.Config.Credentials).%OpenId(name, , .sc)
    If '$IsObject(cred) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.provider.Base.ResolveApiKey: credential '"_name_"' not found"))
    }
    Return cred.Password
}

}
