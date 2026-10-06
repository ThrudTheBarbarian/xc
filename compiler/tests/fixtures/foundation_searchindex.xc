//xtc-na: xt6502 — SearchIndex is not available on xt6502
// foundation_searchindex.xc — SearchIndex: word splitting, any-word and
// every-word search, ranking, prefix queries, replacing and removing
// documents.
#import "Foundation.xc"
#import "SearchIndex.xc"

String* S(u8* c)
    {
    return String.withCString(c);
    }
void show(u8* label, Array* hits)
    {
    Stdio.printf("%s:", label);
    for (u32 i = (u32)0; i < hits.count(); i++)
        {
        SearchResult* r = (SearchResult*)hits.get(i);
        Stdio.printf(" %s(%u/%u)", r.id.cString(), r.matchedTerms, r.score);
        }
    Stdio.printf("\n");
    }

i32 main(void)
    {
    Array* ws = SearchIndex.words(S("The quick, brown FOX -- jumped 2x!"));
    Stdio.printf("words:");
    for (u32 i = (u32)0; i < ws.count(); i++)
        Stdio.printf(" [%s]", ((String*)ws.get(i)).cString());
    Stdio.printf("\n");

    SearchIndex* idx = new SearchIndex();
    idx.addDocument(S("a"), S("The quick brown fox"));
    idx.addDocument(S("b"), S("A quick quick dog"));
    idx.addDocument(S("c"), S("Foxes and dogs, quietly"));
    idx.addDocument(S("d"), S("nothing here"));
    Stdio.printf("documents %u, terms %u\n", idx.documentCount(), idx.termCount());

    show("quick fox", idx.search(S("quick fox")));
    show("all quick fox", idx.searchAll(S("quick fox")));
    show("QUICK", idx.search(S("QUICK")));
    show("qui*", idx.search(S("qui*")));
    show("fox*", idx.search(S("fox*")));
    show("dog* quick", idx.search(S("dog* quick")));
    show("missing", idx.search(S("missing")));
    show("empty", idx.search(S("  ")));

    idx.addDocument(S("b"), S("a slow cat"));
    show("quick after b replaced", idx.search(S("quick")));
    idx.removeDocument(S("a"));
    show("quick after a removed", idx.search(S("quick")));
    Stdio.printf("documents %u, has a %d, terms %u\n", idx.documentCount(),
                 (i32)(idx.containsDocument(S("a")) ? 1 : 0), idx.termCount());
    return (i32)0;
    }
