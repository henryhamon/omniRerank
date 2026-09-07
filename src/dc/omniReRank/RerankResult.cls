/// Custom result set backing the SQL CALL dc_omniReRank.Engine_Rerank(...).
/// Iterates a %DynamicArray of {index, candidate, score} rows already sorted
/// by score DESC, exposing them as SQL columns (originalIndex, candidate,
/// score).
Class dc.omniReRank.RerankResult Extends %SQL.CustomResultSet
{

/// The rows to serve, already sorted by score DESC.
/// Each entry is an object with keys: index, candidate, score.
Property Rows As %DynamicArray [ Private ];

Property Pos As %Integer [ InitialExpression = 0, Private ];

Property originalIndex As %Integer;

Property candidate As %String(MAXLEN = "");

Property score As %Double;

/// Init after %New — %SQL.CustomResultSet marks %OnNew Final, so rows are
/// injected via this method instead of the constructor.
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
    Set ..originalIndex = +row.%Get("index")
    Set ..candidate = row.%Get("candidate")
    Set ..score = +row.%Get("score")
    Set i%%ROWCOUNT = ..Pos
    Set i%%ROWID = ..Pos
    Return 1
}

}
