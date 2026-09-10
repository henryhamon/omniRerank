Include %occStatus

/// Demo entry point: end-to-end vector-search-then-rerank against the
/// dc.sample.omniReRank.demo.Catalog table. Uses only the SQL surface of the library
/// (CALL dc_omniReRank.Engine_Rerank) plus IRIS 2026 native %Embedding.Interface
/// for the query embedding — no direct provider access, no dependency on
/// the sibling embedding library.
Class dc.sample.omniReRank.demo.Search
{

Parameter EMBCONFIG = "CatalogEmbeddingV1";

Parameter RERANKCONFIG = "CatalogRerankV1";

/// SQL entry point.
/// 
///   CALL dc_sample_omniReRank_demo.Search_Search('<query>', <k>)
/// 
/// Runs a two-phase retrieval:
///   1. Embeds `query` via %Embedding.Interface using CatalogEmbeddingV1.
///   2. Selects the top-k rows from Catalog ordered by VECTOR_COSINE DESC.
///   3. Sends the retrieved Description texts as candidates to
///      Engine.Rerank with CatalogRerankV1 and returns the reranked rows.
/// Short-circuits with an empty result set on k<=0 or an empty Catalog —
/// neither triggers the embedding or rerank call.
ClassMethod Search(query As %String, k As %Integer = 10) As dc.sample.omniReRank.demo.SearchResult [ SqlProc ]
{
    // k=0 short-circuit — no embedding, no cosine, no rerank.
    If (+$Get(k)) <= 0 {
        Set emptyOut = ##class(dc.sample.omniReRank.demo.SearchResult).%New()
        Do emptyOut.SetRows([])
        Return emptyOut
    }

    // Empty-table short-circuit — cheaper than embedding a query only to
    // then match nothing, and lets the empty-table unit test pass without
    // a live embedding provider.
    Set catalogCount = 0
    &sql(SELECT COUNT(*) INTO :catalogCount FROM dc_sample_omniReRank_demo.Catalog)
    If catalogCount = 0 {
        Set emptyOut = ##class(dc.sample.omniReRank.demo.SearchResult).%New()
        Do emptyOut.SetRows([])
        Return emptyOut
    }

    // Embed the query using CatalogEmbeddingV1.
    If '##class(%Embedding.Config).%ExistsId(..#EMBCONFIG) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.sample.omniReRank.demo.Search.Search: %Embedding.Config '"_..#EMBCONFIG_"' not found — create it before searching (see README section Demo)."))
    }
    Set embCfg = ##class(%Embedding.Config).%OpenId(..#EMBCONFIG, , .openSc)
    If '$IsObject(embCfg) {
        $$$ThrowStatus($$$ERROR($$$GeneralError, "dc.sample.omniReRank.demo.Search.Search: could not open %Embedding.Config '"_..#EMBCONFIG_"'."))
    }
    Set queryVec = ##class(%Embedding.Interface).Embedding(query, embCfg.Configuration)

    // Cosine top-K query — materialize hits + candidate descriptions.
    Set stmt = ##class(%SQL.Statement).%New()
    Set sc = stmt.%Prepare("SELECT TOP ? Id, Title, Description, VECTOR_COSINE(?, Embedding) AS Cos FROM dc_sample_omniReRank_demo.Catalog ORDER BY Cos DESC")
    If $$$ISERR(sc) { $$$ThrowStatus(sc) }
    Set rs = stmt.%Execute(k, queryVec)
    Set hits = []
    Set candidates = []
    While rs.%Next() {
        Set hit = []
        Do hit.%Push(rs.%Get("Id"))
        Do hit.%Push(rs.%Get("Title"))
        Do hit.%Push(rs.%Get("Cos"))
        Do hits.%Push(hit)
        Do candidates.%Push(rs.%Get("Description"))
    }

    Return ..RerankPhase(query, hits, candidates, ..#RERANKCONFIG)
}

/// Second-phase pipeline: takes pre-collected cosine hits + candidate
/// descriptions and dispatches through the SQL rerank stored procedure.
/// Extracted from Search so the id-mapping wiring can be exercised in tests
/// without a live embedding or rerank service — tests pass fabricated hits
/// alongside a MockProvider registered via ^||omniReRankProviderOverride.
/// 
/// `hits` is a %DynamicArray of 3-element arrays: [Id, Title, CosineDistance].
/// `candidates` is a parallel %DynamicArray of Description strings.
ClassMethod RerankPhase(query As %String, hits As %DynamicArray, candidates As %DynamicArray, rerankConfig As %String = {..#RERANKCONFIG}) As dc.sample.omniReRank.demo.SearchResult [ Internal ]
{
    Set out = ##class(dc.sample.omniReRank.demo.SearchResult).%New()
    If '$IsObject(candidates) || (candidates.%Size() = 0) || '$IsObject(hits) || (hits.%Size() = 0) {
        Do out.SetRows([])
        Return out
    }

    // Engine.Rerank is the SQL surface — same method registered as
    // dc_omniReRank.Engine_Rerank via SqlProc. We call it as an ObjectScript
    // classmethod so we can iterate its %SQL.CustomResultSet directly; CALL
    // via %SQL.Statement wraps the returned result set in a way that does
    // not surface the custom row properties (originalIndex/score) to a
    // downstream %Next()/%Get() caller.
    Set rerankRs = ##class(dc.omniReRank.Engine).Rerank(query, candidates.%ToJSON(), rerankConfig)

    Set outRows = []
    While rerankRs.%Next() {
        Set idx = +rerankRs.originalIndex
        Set hit = hits.%Get(idx)
        If '$IsObject(hit) { Continue }
        Do outRows.%Push({
            "Id": (+hit.%Get(0)),
            "Title": (hit.%Get(1)),
            "CosineDistance": (+hit.%Get(2)),
            "RerankScore": (+rerankRs.score)
        })
    }

    Do out.SetRows(outRows)
    Return out
}

}
