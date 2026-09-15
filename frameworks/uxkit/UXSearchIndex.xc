// UXSearchIndex.xc — a small full-text search index (SearchKit in shape).
//
// Documents are added as (id, text); the text is tokenized (lowercased runs of letters/digits) into
// TERMS, and an inverted index maps each term to the documents that contain it and how often.  A query
// is tokenized the same way; every document containing any query term scores by summed term frequency,
// and the matches come back ranked best-first.  Pure data structures — fully testable — and the base
// for a find-as-you-type box or a desktop search.
#import "Array.xc"

class UXPosting : Object
    {
    i32 docId;
    i32 count;
    void init(void)
        {
        docId = (i32)0;
        count = (i32)0;
        }
    } class UXTerm : Object
    {
    u8* word;
    Array<UXPosting>* postings; // of UXPosting, one per document containing the term
    void init(void)
        {
        word = (u8*)"";
        postings = new Array();
        }
    } class UXSearchResult : Object
    {
    i32 docId;
    i32 score;
    void init(void)
        {
        docId = (i32)0;
        score = (i32)0;
        }
    }

    class UXSearchIndex
    {
    Array<UXTerm>* terms;     // of UXTerm (the inverted index)
    Array<UXPosting>* docIds; // distinct doc ids seen
    void init(void)
        {
        terms = new Array();
        docIds = new Array();
        }

    static bool streq(u8* a, u8* b)
        {
        i32 i = (i32)0;
        while (a[i] != (u8)0 && b[i] != (u8)0)
            {
            if (a[i] != b[i])
                {
                return false;
                }
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }
    static bool isAlnum(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9');
        }
    static u8 lower(u8 c)
        {
        return (c >= (u8)'A' && c <= (u8)'Z') ? (u8)(c + (u8)32) : c;
        }
    static u8* dup(u8* s, i32 start, i32 len)
        {
        u8* o = new u8[(u32)(len + (i32)1)];
        for (i32 i = (i32)0; i < len; i = i + (i32)1)
            {
            o[i] = UXSearchIndex.lower(s[start + i]);
            }
        o[len] = (u8)0;
        return o;
        }

    UXTerm* termFor(u8* word, bool create)
        {
        for (u16 i = (u16)0; i < terms.count(); i = i + (u16)1)
            {
            UXTerm* t = (UXTerm* ?)terms.get(i);
            if (UXSearchIndex.streq(t.word, word))
                {
                return t;
                }
            }
        if (!create)
            {
            return (UXTerm*)0;
            }
        UXTerm* t = new UXTerm();
        t.word = word;
        terms.add(t);
        return t;
        }
    void bumpPosting(UXTerm* t, i32 docId)
        {
        for (u16 i = (u16)0; i < t.postings.count(); i = i + (u16)1)
            {
            UXPosting* p = (UXPosting* ?)t.postings.get(i);
            if (p.docId == docId)
                {
                p.count = p.count + (i32)1;
                return;
                }
            }
        UXPosting* p = new UXPosting();
        p.docId = docId;
        p.count = (i32)1;
        t.postings.add(p);
        }

    void addDocument(i32 docId, u8* text)
        {
        bool known = false;
        for (u16 i = (u16)0; i < docIds.count(); i = i + (u16)1)
            {
            if (((UXPosting* ?)docIds.get(i)).docId == docId)
                {
                known = true;
                }
            }
        if (!known)
            {
            UXPosting* d = new UXPosting();
            d.docId = docId;
            docIds.add(d);
            }
        // tokenize
        i32 n = (i32)0;
        while (text[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        i32 i = (i32)0;
        while (i < n)
            {
            if (UXSearchIndex.isAlnum(text[i]))
                {
                i32 start = i;
                while (i < n && UXSearchIndex.isAlnum(text[i]))
                    {
                    i = i + (i32)1;
                    }
                u8* word = UXSearchIndex.dup(text, start, i - start);
                self.bumpPosting(self.termFor(word, true), docId);
                }
            else
                {
                i = i + (i32)1;
                }
            }
        }
    i32 documentCount(void)
        {
        return (i32)docIds.count();
        }
    i32 termCount(void)
        {
        return (i32)terms.count();
        }

    // Ranked search: every doc containing any query term scores by summed term frequency, best first.
    Array<UXSearchResult>* search(u8* query)
        {
        Array<UXSearchResult>* results = new Array(); // accumulated then sorted
        i32 n = (i32)0;
        while (query[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        i32 i = (i32)0;
        while (i < n)
            {
            if (UXSearchIndex.isAlnum(query[i]))
                {
                i32 start = i;
                while (i < n && UXSearchIndex.isAlnum(query[i]))
                    {
                    i = i + (i32)1;
                    }
                u8* word = UXSearchIndex.dup(query, start, i - start);
                UXTerm* t = self.termFor(word, false);
                if (t != (UXTerm*)0)
                    {
                    for (u16 k = (u16)0; k < t.postings.count(); k = k + (u16)1)
                        {
                        UXPosting* p = (UXPosting* ?)t.postings.get(k);
                        self.addScore(results, p.docId, p.count);
                        }
                    }
                }
            else
                {
                i = i + (i32)1;
                }
            }
        self.sortByScore(results);
        return results;
        }
    void addScore(Array<UXSearchResult>* results, i32 docId, i32 add)
        {
        for (u16 i = (u16)0; i < results.count(); i = i + (u16)1)
            {
            UXSearchResult* r = (UXSearchResult* ?)results.get(i);
            if (r.docId == docId)
                {
                r.score = r.score + add;
                return;
                }
            }
        UXSearchResult* r = new UXSearchResult();
        r.docId = docId;
        r.score = add;
        results.add(r);
        }
    // selection sort, descending by score (result sets are small)
    void sortByScore(Array<UXSearchResult>* results)
        {
        i32 m = (i32)results.count();
        for (i32 i = (i32)0; i < m - (i32)1; i = i + (i32)1)
            {
            i32 best = i;
            for (i32 j = i + (i32)1; j < m; j = j + (i32)1)
                {
                if (((UXSearchResult* ?)results.get((u16)j)).score > ((UXSearchResult* ?)results.get((u16)best)).score)
                    {
                    best = j;
                    }
                }
            if (best != i)
                {
                UXSearchResult* a = results.get((u16)i);
                UXSearchResult* b = results.get((u16)best);
                results.set((u16)i, b);
                results.set((u16)best, a);
                }
            }
        }
    }
