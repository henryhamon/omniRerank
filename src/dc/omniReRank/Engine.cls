Include %occStatus

/// Central dispatch engine for dc.omniReRank.
/// Responsibility in this spec: provider resolution only. No circuit breaker,
/// no retry, no fallback — those become follow-up specs.
Class dc.omniReRank.Engine
{

/// SQL entry point.
/// 
///   CALL dc_omniReRank.Engine_Rerank('<query>', '<candidatesJson>', '<configName>')
/// 
/// Loads the named %Embedding.Config row, parses its Configuration JSON,
/// extracts the `rerank` sub-block, dispatches to the resolved provider, and
/// returns a result set with (originalIndex INT, candidate VARCHAR, score
/// DOUBLE) rows sorted by score DESC. Preserves the caller's original 0-based
/// index on every row so callers can map back to their input array.
ClassMethod Rerank(query As %String, candidatesJson As %String, configName As %String) As dc.omniReRank.RerankResult [ SqlProc ]
{
    // Parse candidates first — fail before touching config / HTTP on bad JSON.
    If '$Data(candidatesJson) { Set candidatesJson = "[]" }
    Set candidates = ""
    Try {
        Set candidates = [].%FromJSON(candidatesJson)
    } Catch parseEx {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.Engine.Rerank: 'candidatesJson' is not valid JSON. Cause: "_parseEx.DisplayString()))
    }
    If '$IsObject(candidates) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.Engine.Rerank: 'candidatesJson' must parse to a JSON array"))
    }

    // Empty candidates: no HTTP, empty result set.
    If candidates.%Size() = 0 {
        Set emptyRs = ##class(dc.omniReRank.RerankResult).%New()
        Do emptyRs.SetRows([])
        Return emptyRs
    }

    // Empty query: fail before any HTTP call.
    If $Get(query) = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.Engine.Rerank: 'query' must be a non-empty string"))
    }

    // Load %Embedding.Config by name.
    If $Get(configName) = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.Engine.Rerank: 'configName' is required"))
    }
    Set embCfg = ##class(%Embedding.Config).%OpenId(configName, , .openSc)
    If '$IsObject(embCfg) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.Engine.Rerank: %Embedding.Config '"_configName_"' not found (store checked: %Embedding.Config)"))
    }

    // Parse Configuration JSON and pull out the rerank sub-block.
    Set fullCfg = ""
    Try {
        Set fullCfg = {}.%FromJSON(embCfg.Configuration)
    } Catch cfgEx {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.Engine.Rerank: %Embedding.Config '"_configName_"' has invalid Configuration JSON. Cause: "_cfgEx.DisplayString()))
    }
    Set rerankCfg = fullCfg.%Get("rerank")
    If '$IsObject(rerankCfg) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.Engine.Rerank: %Embedding.Config '"_configName_"' has no 'rerank' sub-block in its Configuration JSON — a 'rerank' object with at least {provider, modelName, apiKey} is required"))
    }

    // Resolve provider (only Cohere in this spec).
    Set providerClass = ..ResolveProvider(rerankCfg)

    // Circuit breaker: block dispatch if the breaker is open for this key.
    Set providerKey = ..ProviderKey(rerankCfg)
    If ..CheckBreaker(providerKey) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.Engine.Rerank: circuit breaker open for '"_providerKey_"' — cooldown in effect after repeated provider failures; no HTTP attempt made"))
    }

    // Delegate to the provider — returns %DynamicArray of {index, score}.
    // Record success/failure for the breaker; re-throw on provider exceptions.
    Set scored = ""
    Try {
        Set scored = $ClassMethod(providerClass, "Execute", query, candidates, rerankCfg)
        Do ..RecordSuccess(providerKey)
    } Catch provEx {
        Do ..RecordFailure(providerKey)
        Throw provEx
    }

    // Merge back the original candidate text keyed by index, then sort DESC by score.
    // Build a plain array [pos] = $LB(score, index, candidate) to sort in-process.
    Set rowsIdx = "", n = 0
    Set iter = scored.%GetIterator()
    While iter.%GetNext(.k, .row) {
        Set idx = +row.%Get("index")
        Set score = +row.%Get("score")
        Set cand = candidates.%Get(idx)
        Set n = n + 1
        Set rowsIdx(n) = $ListBuild(score, idx, cand)
    }

    // Sort by score DESC using an $Order-friendly subscript layout.
    // Key = negative-score-string + sequence for stable tie-break.
    Kill sorted
    For i = 1:1:n {
        Set entry = rowsIdx(i)
        Set score = $ListGet(entry, 1)
        Set sorted(-score, i) = entry
    }

    Set outRows = []
    Set k1 = ""
    For {
        Set k1 = $Order(sorted(k1))
        Quit:k1=""
        Set k2 = ""
        For {
            Set k2 = $Order(sorted(k1, k2))
            Quit:k2=""
            Set entry = sorted(k1, k2)
            Do outRows.%Push({
                "index": ($ListGet(entry, 2)),
                "candidate": ($ListGet(entry, 3)),
                "score": ($ListGet(entry, 1))
            })
        }
    }

    Set rs = ##class(dc.omniReRank.RerankResult).%New()
    Do rs.SetRows(outRows)
    Return rs
}

/// Resolves the ObjectScript class name for the provider.
/// Only `provider = "cohere"` is valid in this spec. Any other value throws
/// with the list of currently-valid providers.
ClassMethod ResolveProvider(rerankCfg As %DynamicObject) As %String
{
    Set provider = $ZConvert(rerankCfg.%Get("provider"), "L")
    If provider = "" {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.Engine.ResolveProvider: 'provider' is required in the rerank sub-block. Valid: cohere"))
    }
    // Test hook: process-private override wins over the built-in map.
    // Mirrors ^||omniReRankCredential — used by unit tests to inject a mock
    // provider class without going over the network.
    Set testClass = $Get(^||omniReRankProviderOverride(provider))
    If testClass '= "" { Return testClass }
    If provider = "cohere" { Return "dc.omniReRank.provider.Cohere" }
    $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.omniReRank.Engine.ResolveProvider: unknown provider '"_rerankCfg.%Get("provider")_"'. Valid: cohere"))
}

/// Generates the circuit breaker key: "provider|modelName".
/// apiBase is intentionally omitted — no provider in dc.omniReRank currently
/// reads it. Follow-up specs that add an OpenAI-compatible base URL may extend.
ClassMethod ProviderKey(rerankCfg As %DynamicObject) As %String
{
    Return rerankCfg.%Get("provider") _ "|" _ rerankCfg.%Get("modelName")
}

Parameter FAILURETHRESHOLD = 5;

Parameter COOLDOWNSECONDS = 60;

/// Checks if the circuit breaker is open for the given provider key.
/// Returns 1 if open (block), 0 if closed OR half-open (allow one attempt).
ClassMethod CheckBreaker(providerKey As %String) As %Boolean [ Internal ]
{
    Set data = $Get(^omniReRank.Breaker(providerKey))
    If data = "" { Return 0 }
    Set failures = $ListGet(data, 1, 0)
    Set openedAt = $ListGet(data, 2, 0)
    If (failures < ..#FAILURETHRESHOLD) || (openedAt = 0) { Return 0 }
    Set nowSec = ..NowSeconds()
    If (nowSec - openedAt) >= ..#COOLDOWNSECONDS { Return 0 }
    Return 1
}

/// Records a successful provider call: resets circuit breaker to (0, 0).
/// Global explicitly becomes $LISTBUILD(0, 0) after success — not merely killed.
ClassMethod RecordSuccess(providerKey As %String) [ Internal ]
{
    Set ^omniReRank.Breaker(providerKey) = $ListBuild(0, 0)
}

/// Records a failed provider call: increments failure counter, opens circuit
/// once the failure threshold is reached.
ClassMethod RecordFailure(providerKey As %String) [ Internal ]
{
    Set data = $Get(^omniReRank.Breaker(providerKey))
    Set failures = $ListGet(data, 1, 0) + 1
    Set openedAt = $ListGet(data, 2, 0)
    If (failures >= ..#FAILURETHRESHOLD) && (openedAt = 0) {
        Set openedAt = ..NowSeconds()
    }
    Set ^omniReRank.Breaker(providerKey) = $ListBuild(failures, openedAt)
}

/// Wall-clock seconds since epoch (from $Horolog). Extracted so tests can
/// verify the cooldown math without waiting 60 real seconds.
ClassMethod NowSeconds() As %Integer [ Internal ]
{
    Return ($Piece($Horolog, ",", 1) * 86400) + $Piece($Horolog, ",", 2)
}

}
