// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.
// SearchIndex.xc — a small full-text index: add documents, search words.
// ===========================================================================
//
//     SearchIndex* idx = new SearchIndex();
//     idx.addDocument(String.withCString("a"), String.withCString("The quick brown fox"));
//     idx.addDocument(String.withCString("b"), String.withCString("A quick quick dog"));
//     Array* hits = idx.search(String.withCString("quick fox"));
//     // a (2 terms), then b (1 term, said twice)
//
// Text is split into words: runs of letters and digits, with ASCII letters
// lowered, so "Fox," and "fox" are one word. Bytes of UTF-8 count as letters,
// so other scripts are indexed too, without case folding. An inverted index
// maps each word to the documents that hold it and how often.
//
// A query is split the same way. `search` finds the documents holding any of
// its words, `searchAll` those holding every one. A query word ending in '*'
// matches every word it begins, for find-as-you-type ("qui*"). Results come
// best first: more of the query's words matched, then more occurrences of
// them, then the order the documents were first added.
//
// Documents are named by a String id; adding one under an id already present
// replaces it.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every heap-capable target except xt6502.

#if ARCH_6502
#error "SearchIndex: not available on xt6502"
#endif

#import "Foundation.xc"

// One document a search found.
class SearchResult : Object
    {
    String* id;
    u32 matchedTerms; // how many of the query's words it holds
    u32 score;        // how many times it holds them, in all
    u32 _order;
    }

class SearchIndex
    {
    Map* _terms;   // word -> Map(document id -> Number count)
    Map* _docs;    // document id -> Array of its distinct words
    Map* _order;   // document id -> Number: when it was first added
    u32 _next;

    void init(void)
        {
        _terms = new Map();
        _docs = new Map();
        _order = new Map();
        _next = (u32)0;
        }

    // ── Words ────────────────────────────────────────────────────────────

    static bool _isWordByte(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z')
               || (c >= (u8)'0' && c <= (u8)'9') || c >= (u8)$80;
        }

    // The words of `text`, in order, repeats included.
    static Array* words(String* text)
        {
        Array* out = new Array();
        if (text == 0)
            return out;
        u8* p = text.cString();
        u32 n = text.byteLength();
        u32 i = (u32)0;
        while (i < n)
            {
            while (i < n && !SearchIndex._isWordByte(p[i]))
                i++;
            if (i >= n)
                break;
            String* w = String.withCString("");
            while (i < n && SearchIndex._isWordByte(p[i]))
                {
                u8 c = p[i];
                if (c >= (u8)'A' && c <= (u8)'Z')
                    c = c + (u8)32;
                w.appendByte(c);
                i++;
                }
            out.add(w);
            }
        return out;
        }

    // ── Documents ────────────────────────────────────────────────────────

    // Indexes `text` as the document `id`, replacing any document of that id.
    void addDocument(String* id, String* text)
        {
        if (id == 0)
            return;
        removeDocument(id);
        Map* counts = new Map();
        Array* ws = SearchIndex.words(text);
        for (u32 i = (u32)0; i < ws.count(); i++)
            {
            String* w = (String*)ws.get(i);
            Number* c = (Number* ?)counts.get(w);
            counts.set(w, Number.withU32(c == 0 ? (u32)1 : c.asU32() + (u32)1));
            }
        Array* distinct = new Array();
        for (u32 i = (u32)0; i < counts.count(); i++)
            {
            String* w = (String*)counts.enumAt(i);
            distinct.add(w);
            Map* postings = (Map* ?)_terms.get(w);
            if (postings == 0)
                {
                postings = new Map();
                _terms.set(w, postings);
                }
            postings.set(id, counts.get(w));
            }
        _docs.set(id, distinct);
        if (!_order.contains(id))
            {
            _order.set(id, Number.withU32(_next));
            _next = _next + (u32)1;
            }
        }

    void removeDocument(String* id)
        {
        if (id == 0)
            return;
        Array* distinct = (Array* ?)_docs.get(id);
        if (distinct == 0)
            return;
        for (u32 i = (u32)0; i < distinct.count(); i++)
            {
            String* w = (String*)distinct.get(i);
            Map* postings = (Map* ?)_terms.get(w);
            if (postings != 0)
                {
                postings.remove(id);
                if (postings.count() == (u32)0)
                    _terms.remove(w);
                }
            }
        _docs.remove(id);
        }

    bool containsDocument(String* id)
        {
        return id != 0 && _docs.contains(id);
        }

    u32 documentCount(void)
        {
        return _docs.count();
        }

    // The number of distinct words indexed.
    u32 termCount(void)
        {
        return _terms.count();
        }

    // ── Searching ────────────────────────────────────────────────────────

    // The documents holding any of the query's words, best first.
    Array* search(String* query)
        {
        return _search(query, false);
        }

    // The documents holding every one of the query's words, best first.
    Array* searchAll(String* query)
        {
        return _search(query, true);
        }

    Array* _search(String* query, bool all)
        {
        Map* found = new Map();  // id -> SearchResult
        Array* qs = new Array(); // the query's distinct words, '*' kept
        if (query != 0)
            {
            // Split by hand so a trailing '*' survives.
            u8* p = query.cString();
            u32 n = query.byteLength();
            u32 i = (u32)0;
            while (i < n)
                {
                while (i < n && !SearchIndex._isWordByte(p[i]))
                    i++;
                if (i >= n)
                    break;
                String* w = String.withCString("");
                while (i < n && SearchIndex._isWordByte(p[i]))
                    {
                    u8 c = p[i];
                    if (c >= (u8)'A' && c <= (u8)'Z')
                        c = c + (u8)32;
                    w.appendByte(c);
                    i++;
                    }
                if (i < n && p[i] == (u8)'*')
                    {
                    w.appendByte((u8)'*');
                    i++;
                    }
                if (!qs.containsEqual(w))
                    qs.add(w);
                }
            }
        for (u32 q = (u32)0; q < qs.count(); q++)
            {
            String* w = (String*)qs.get(q);
            u32 wl = w.byteLength();
            bool prefix = wl > (u32)0 && w.byteAt(wl - (u32)1) == (u8)'*';
            // Each document counts once per query word, however many indexed
            // words a prefix matches.
            Map* hit = new Map();  // id -> Number occurrences for this query word
            if (prefix)
                {
                String* stem = w.substringBytes((u32)0, wl - (u32)1);
                for (u32 t = (u32)0; t < _terms.count(); t++)
                    {
                    String* term = (String*)_terms.enumAt(t);
                    if (term.hasPrefix(stem))
                        SearchIndex._gather(hit, (Map*)_terms.get(term));
                    }
                }
            else
                {
                Map* postings = (Map* ?)_terms.get(w);
                if (postings != 0)
                    SearchIndex._gather(hit, postings);
                }
            for (u32 h = (u32)0; h < hit.count(); h++)
                {
                String* id = (String*)hit.enumAt(h);
                SearchResult* r = (SearchResult* ?)found.get(id);
                if (r == 0)
                    {
                    r = new SearchResult();
                    r.id = id;
                    r._order = ((Number*)_order.get(id)).asU32();
                    found.set(id, r);
                    }
                r.matchedTerms = r.matchedTerms + (u32)1;
                r.score = r.score + ((Number*)hit.get(id)).asU32();
                }
            }
        // Best first, by insertion into a sorted list (results are few).
        Array* out = new Array();
        for (u32 i = (u32)0; i < found.count(); i++)
            {
            SearchResult* r = (SearchResult*)found.get(found.enumAt(i));
            if (all && r.matchedTerms != qs.count())
                continue;
            u32 at = out.count();
            while (at > (u32)0 && SearchIndex._before(r, (SearchResult*)out.get(at - (u32)1)))
                at = at - (u32)1;
            out.insert(at, r);
            }
        return out;
        }

    static void _gather(Map* hit, Map* postings)
        {
        for (u32 i = (u32)0; i < postings.count(); i++)
            {
            String* id = (String*)postings.enumAt(i);
            u32 c = ((Number*)postings.get(id)).asU32();
            Number* have = (Number* ?)hit.get(id);
            hit.set(id, Number.withU32(have == 0 ? c : have.asU32() + c));
            }
        }

    static bool _before(SearchResult* a, SearchResult* b)
        {
        if (a.matchedTerms != b.matchedTerms)
            return a.matchedTerms > b.matchedTerms;
        if (a.score != b.score)
            return a.score > b.score;
        return a._order < b._order;
        }
    }
