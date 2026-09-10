/// Custom result set backing the demo SQL CALL dc_sample_omniReRank_demo.Search_Search(...).
/// Exposes (Id, Title, CosineDistance, RerankScore) — reranked rows already
/// sorted by RerankScore DESC. Initialization mirrors dc.omniReRank.RerankResult:
/// %New() then SetRows(rows) — %OnNew is deliberately NOT overridden because
/// %SQL.CustomResultSet marks its own %OnNew Final.
Class dc.sample.omniReRank.demo.SearchResult Extends %SQL.CustomResultSet
{

/// Rows to serve, already sorted by RerankScore DESC.
/// Each entry is an object with keys: Id, Title, CosineDistance, RerankScore.
Property Rows As %DynamicArray [ Private ];

Property Pos As %Integer [ InitialExpression = 0, Private ];

Property Id As %Integer;

Property Title As %String(MAXLEN = "");

Property CosineDistance As %Double;

Property RerankScore As %Double;

Method SetRows(rows As %DynamicArray)
{
    Set ..Rows = rows
    Set ..Pos = 0
}

Method %Next(ByRef sc As %Status = {$$$OK}) As %Integer
{
    Set sc = $$$OK
    If '$IsObject(..Rows) { Return 0 }
    If ..Pos >= ..Rows.%Size() { Return 0 }
    Set row = ..Rows.%Get(..Pos)
    Set ..Pos = ..Pos + 1
    If '$IsObject(row) { Return 0 }
    Set ..Id = +row.%Get("Id")
    Set ..Title = row.%Get("Title")
    Set ..CosineDistance = +row.%Get("CosineDistance")
    Set ..RerankScore = +row.%Get("RerankScore")
    Set i%%ROWCOUNT = ..Pos
    Set i%%ROWID = ..Pos
    Return 1
}

}
