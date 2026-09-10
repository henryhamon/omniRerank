/// Demo persistent class for the omniReRank end-to-end walkthrough.
/// Holds a small corpus of documents (title + description + topic tag) whose
/// Description text is embedded once at seed time using IRIS 2026's native
/// %Embedding.Interface and then vector-searched at query time.
/// Not referenced by any production omniReRank class — lives under the demo
/// sub-package so newcomers can inspect it beside the library it demonstrates.
Class dc.sample.omniReRank.demo.Catalog Extends %Persistent
{

Property Id As %Integer(MINVAL = 1) [ Required ];

Property Title As %String(MAXLEN = "");

Property Description As %String(MAXLEN = "");

Property Topic As %String(MAXLEN = 32);

/// Fixed at 1536 dims so the HNSW functional index below can build.
/// Assumes an embedding model that produces 1536-length float vectors
/// (OpenAI text-embedding-3-small, Cohere embed-v3, etc). If the operator
/// wires up a different-length model, drop the EmbeddingIdx index and
/// widen this length.
Property Embedding As %Vector(DATATYPE = "FLOAT", LEN = 1536);

Index IdIdx On Id [ IdKey ];

Index EmbeddingIdx On (Embedding) As %SQL.Index.HNSW(Distance = "Cosine", M = 16, efConstruction = 64);

Storage Default
{
<Data name="CatalogDefaultData">
<Value name="1">
<Value>%%CLASSNAME</Value>
</Value>
<Value name="2">
<Value>Title</Value>
</Value>
<Value name="3">
<Value>Description</Value>
</Value>
<Value name="4">
<Value>Topic</Value>
</Value>
<Value name="5">
<Value>Embedding</Value>
</Value>
</Data>
<DataLocation>^dc.sample.omniReRa4736.CatalogD</DataLocation>
<DefaultData>CatalogDefaultData</DefaultData>
<IdLocation>^dc.sample.omniReRa4736.CatalogD</IdLocation>
<IndexLocation>^dc.sample.omniReRa4736.CatalogI</IndexLocation>
<StreamLocation>^dc.sample.omniReRa4736.CatalogS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
