---
title: SearchIndex
description: "A small full-text index: add documents under string ids, search for any or every word, with prefix queries for find-as-you-type."
---

`SearchIndex` is a small full-text index: documents go in under a `String` id,
and searches for words come back ranked best first. It is what a
find-as-you-type box or a local search needs. **From 0.72.**

```c
#import "SearchIndex.xc"   // not in the Foundation umbrella: import it by name
```

## Overview

```c
SearchIndex* idx = new SearchIndex();
idx.addDocument(String.withCString("a"), String.withCString("The quick brown fox"));
idx.addDocument(String.withCString("b"), String.withCString("A quick quick dog"));
Array* hits = idx.search(String.withCString("quick fox"));
// a (both words), then b (one word, twice)
SearchResult* best = (SearchResult*)hits.get(0);   // best.id is "a"
```

**Words.** Text is split into runs of letters and digits, with ASCII letters
lowered, so `Fox,` and `fox` are one word. The bytes of UTF-8 count as letters,
so other scripts are indexed too, without case folding. An inverted index maps
each word to the documents that hold it and how often.

**Queries** are split the same way. [`search`](#search) finds documents holding
any of the query's words, [`searchAll`](#searchall) those holding every one. A
query word ending in `*` matches every word it begins (`qui*` finds `quick`
and `quietly`).

**Ranking**: more of the query's words matched first, then more occurrences of
them, then the order the documents were first added.

:::note[Availability]
Every heap-capable target except xt6502.
:::

## Topics

**Documents** · [addDocument](#adddocument) · [removeDocument](#removedocument) · [containsDocument](#containsdocument) · [documentCount](#documentcount) · [termCount](#termcount)

**Searching** · [search](#search) · [searchAll](#searchall) · [SearchResult](#searchresult) · [words](#words)

---

## Documents

### addDocument
```c
void addDocument(String* id, String* text)
```
Indexes `text` as the document `id`, replacing any document of that id (which
keeps its place in the tie-breaking order).

### removeDocument
```c
void removeDocument(String* id)
```

### containsDocument
```c
bool containsDocument(String* id)
```

### documentCount
```c
u32 documentCount(void)
```

### termCount
```c
u32 termCount(void)
```
The number of distinct words indexed.

[↑ Topics](#topics)

## Searching

### search
```c
Array* search(String* query)
```
The documents holding any of the query's words, as
[`SearchResult`](#searchresult)s, best first. An empty query finds nothing.

### searchAll
```c
Array* searchAll(String* query)
```
The documents holding every one of the query's words, best first.

### SearchResult
```c
class SearchResult : Object
    {
    String* id;
    u32 matchedTerms;   // how many of the query's words it holds
    u32 score;          // how many times it holds them, in all
    }
```

### words
```c
static Array* words(String* text)
```
The words `text` splits into, in order, repeats included: what the index
stores.

[↑ Topics](#topics)
