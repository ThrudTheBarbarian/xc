// test_searchindex.xc — UXSearchIndex: tokenizing, inverted index, ranked query.
#import <Stdio.xc>
#import "UXSearchIndex.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }
i32 topDoc(Array<UXSearchResult>* r)
    {
    return r.count() > (u16)0 ? ((UXSearchResult * ?) r.get((u16)0)).docId : (i32)-1;
    }
i32 topScore(Array<UXSearchResult>* r)
    {
    return r.count() > (u16)0 ? ((UXSearchResult * ?) r.get((u16)0)).score : (i32)0;
    }

void main(void)
    {
    gFails = (i32)0;
    UXSearchIndex* ix = new UXSearchIndex();
    ix.addDocument((i32)1, (u8*)"The quick brown fox");
    ix.addDocument((i32)2, (u8*)"The lazy dog sleeps");
    ix.addDocument((i32)3, (u8*)"A quick quick quick cat and a dog"); // 'quick' x3, 'dog' x1
    check("three documents", ix.documentCount(), (i32)3);

    // single term
    Array* r1 = ix.search((u8*)"fox");
    check("'fox' matches one doc", (i32)r1.count(), (i32)1);
    check("'fox' -> doc 1", topDoc(r1), (i32)1);

    // case-insensitive
    Array* rC = ix.search((u8*)"QUICK");
    check("'QUICK' case-insensitive matches two docs", (i32)rC.count(), (i32)2);
    // doc 3 has 'quick' x3 -> ranks above doc 1 (x1)
    check("ranked: doc 3 first", topDoc(rC), (i32)3);
    check("doc 3 score is 3", topScore(rC), (i32)3);

    // term in two docs
    Array* rDog = ix.search((u8*)"dog");
    check("'dog' matches two docs", (i32)rDog.count(), (i32)2);

    // multi-term OR with summed scores: 'quick dog' -> doc3 (3+1=4) beats doc1 (1) and doc2 (1)
    Array* rM = ix.search((u8*)"quick dog");
    check("'quick dog' matches three docs", (i32)rM.count(), (i32)3);
    check("doc 3 tops multi-term", topDoc(rM), (i32)3);
    check("doc 3 summed score 4", topScore(rM), (i32)4);

    // punctuation is a separator, not part of a term
    ix.addDocument((i32)4, (u8*)"e-mail, e-mail; EMAIL!"); // 'e','mail' x2 each, 'email' x1
    Array* rMail = ix.search((u8*)"mail");
    check("'mail' found via tokenization", (i32)rMail.count(), (i32)1);
    check("'mail' doc 4 count 2", topScore(rMail), (i32)2);

    // a term that isn't indexed
    check("unknown term -> no results", (i32)ix.search((u8*)"xyzzy").count(), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXSearchIndex — tokenizing, inverted index, case-folding, TF ranking, multi-term.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
