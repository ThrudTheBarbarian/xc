// records.xc — UXSortDescriptor and UXSearchIndex: ordering rows and finding
// them.
//
// Both are pure logic over your own objects. The sort works on anything that
// answers UXEvaluable — the same protocol UXPredicate filters on — so filter
// then sort is the pair a table view uses.
#import <Stdio.xc>
#import "UXSortDescriptor.xc"
#import "UXSearchIndex.xc"

class Row : Object <UXEvaluable> {
    u8* name; u8* size;
    void init(void) { name=(u8*)""; size=(u8*)"0"; }
    static Row* make(u8* n, u8* s) { Row* r = new Row(); r.name=n; r.size=s; return r; }
    u8* valueForKey(u8* key) {
        if (UXPredicate.streq(key, (u8*)"name")) { return name; }
        if (UXPredicate.streq(key, (u8*)"size")) { return size; }
        return (u8*)"";
    }
}

void show(u8* label, Array<UXEvaluable>* rows) {
    Stdio.printf("%s", label);
    for (u16 i = (u16)0; i < rows.count(); i = i + (u16)1) {
        Row* r = (Row* ?)rows.get(i);
        Stdio.printf(" %s(%s)", r.name, r.size);
    }
    Stdio.printf("\n");
}

Array<UXEvaluable>* freshRows(void) {
    Array<UXEvaluable>* a = new Array();
    a.add((UXEvaluable*)Row.make((u8*)"delta",   (u8*)"9"));
    a.add((UXEvaluable*)Row.make((u8*)"Alpha",   (u8*)"100"));
    a.add((UXEvaluable*)Row.make((u8*)"charlie", (u8*)"20"));
    a.add((UXEvaluable*)Row.make((u8*)"bravo",   (u8*)"3"));
    return a;
}

void main(void) {
    // ---- sorting ----------------------------------------------------------
    Array<UXEvaluable>* rows = freshRows();
    show((u8*)"unsorted:     ", rows);

    UXSortDescriptor.make((u8*)"name", true).sort(rows);
    show((u8*)"by name asc:  ", rows);

    rows = freshRows();
    UXSortDescriptor.make((u8*)"name", false).sort(rows);
    show((u8*)"by name desc: ", rows);

    // A STRING sort of numbers orders them lexically: "100" before "20".
    rows = freshRows();
    UXSortDescriptor.make((u8*)"size", true).sort(rows);
    show((u8*)"size as text: ", rows);

    // numericKey reads the value as an integer instead.
    rows = freshRows();
    UXSortDescriptor.numericKey((u8*)"size", true).sort(rows);
    show((u8*)"size numeric: ", rows);

    // Comparison is by BYTE, so uppercase sorts before lowercase.
    rows = freshRows();
    UXSortDescriptor.make((u8*)"name", true).sort(rows);
    Stdio.printf("first by name: %s  (uppercase sorts first)\n",
                 ((Row* ?)rows.get((u16)0)).name);

    // An unknown key reads as "" for every row, so the order is unchanged.
    rows = freshRows();
    UXSortDescriptor.make((u8*)"nope", true).sort(rows);
    show((u8*)"unknown key:  ", rows);

    // Comparing two rows directly, without sorting.
    UXSortDescriptor* byName = UXSortDescriptor.make((u8*)"name", true);
    Stdio.printf("compare bravo vs delta: %d\n",
                 byName.compare((UXEvaluable*)Row.make((u8*)"bravo", (u8*)"0"),
                                (UXEvaluable*)Row.make((u8*)"delta", (u8*)"0")));

    // ---- searching --------------------------------------------------------
    UXSearchIndex* ix = new UXSearchIndex();
    ix.addDocument((i32)1, (u8*)"The quick brown fox jumps over the lazy dog");
    ix.addDocument((i32)2, (u8*)"A quick brown dog, and another quick dog");
    ix.addDocument((i32)3, (u8*)"Lazy afternoons and slow rivers");

    Stdio.printf("\nindex: docs=%d terms=%d\n",
                 ix.documentCount(), ix.termCount());

    // Ranked by summed term frequency, best first.
    Array<UXSearchResult>* r1 = ix.search((u8*)"dog");
    Stdio.printf("search 'dog':");
    for (u16 i = (u16)0; i < r1.count(); i = i + (u16)1) {
        UXSearchResult* r = (UXSearchResult* ?)r1.get(i);
        Stdio.printf(" doc%d=%d", r.docId, r.score);
    }
    Stdio.printf("\n");

    // Several terms is an OR: any document with any term matches, and the
    // scores add, so the document with most of them ranks highest.
    Array<UXSearchResult>* r2 = ix.search((u8*)"quick dog");
    Stdio.printf("search 'quick dog':");
    for (u16 i = (u16)0; i < r2.count(); i = i + (u16)1) {
        UXSearchResult* r = (UXSearchResult* ?)r2.get(i);
        Stdio.printf(" doc%d=%d", r.docId, r.score);
    }
    Stdio.printf("\n");

    // Queries are case-folded and punctuation-split the same way documents are.
    Stdio.printf("'LAZY' finds %d   'lazy,' finds %d   'Dog!' finds %d\n",
                 (i32)ix.search((u8*)"LAZY").count(),
                 (i32)ix.search((u8*)"lazy,").count(),
                 (i32)ix.search((u8*)"Dog!").count());

    // No match is an empty result, not null.
    Stdio.printf("'unicorn' finds %d\n", (i32)ix.search((u8*)"unicorn").count());

    // There is no stemming: "jumps" is indexed, "jump" is not the same term.
    Stdio.printf("'jumps'=%d  'jump'=%d\n",
                 (i32)ix.search((u8*)"jumps").count(),
                 (i32)ix.search((u8*)"jump").count());
}
