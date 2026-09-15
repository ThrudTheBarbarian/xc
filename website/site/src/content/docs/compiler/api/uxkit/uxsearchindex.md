---
title: UXSearchIndex
description: "A small full-text index: documents in, ranked matches out. An inverted index over lowercased alphanumeric terms, scored by term frequency."
---

`UXSearchIndex` holds documents as `(id, text)` and answers queries with
**ranked** results.

```c
#use <UXKit>            // or #import "UXSearchIndex.xc"
```

## Overview

```c
UXSearchIndex* ix = new UXSearchIndex();
ix.addDocument(1, (u8*)"The quick brown fox jumps over the lazy dog");
ix.addDocument(2, (u8*)"A quick brown dog, and another quick dog");

Array<UXSearchResult>* hits = ix.search((u8*)"quick dog");
// doc2 score 4, doc1 score 2 — best first
```

The shape follows SearchKit. It is a base for a find-as-you-type box or a desktop
search. It is built from pure data structures, so it is testable.

## An inverted index, not a scan

The text is **tokenized** into terms, and each term records which documents
contain it and how often. A query looks up its terms and collects the documents
they point at.

This differs from [`UXText.contains`](/compiler/api/uxkit/uxtext/#contains):
scanning costs *documents × length* per query, while a lookup costs the terms in
the query. You pay once, at `addDocument`, and every later search is cheap.

Use **`UXText.contains` for one string, and this for a corpus you query
repeatedly.**

## Tokenizing is the contract

Documents and queries are split the same way: **runs of letters and digits,
lowercased**. Everything else is a separator.

```c
ix.search((u8*)"LAZY");     // same as "lazy"
ix.search((u8*)"lazy,");    // same as "lazy"
ix.search((u8*)"Dog!");     // same as "dog"
```

Case-folding and punctuation-stripping happen on both sides, so a user does not
have to type what the document said character for character. Two consequences
often defy expectations:

:::caution[No stemming, and no phrase search]
```c
ix.search((u8*)"jumps");    // 1 hit
ix.search((u8*)"jump");     // 0 hits — a different term
```

`jump` and `jumps` are unrelated strings. There is no stemmer, no plural
handling and no synonym table.

There is also **no phrase search**: `"brown fox"` is two independent terms, not
an adjacency requirement. Only frequency is recorded, not position.

Neither matters much for find-as-you-type over titles and filenames, which is
what the index is for. For prose search they do, and this is the wrong tool.
:::

Folding is ASCII-only, so accented characters are indexed as themselves. `Café`
and `café` are the same term (the `C` folds); `café` and `cafe` are not.

## Scoring is summed term frequency

Every document containing **any** query term matches (queries are an **OR**, not
an AND), and each term contributes the number of times it appears.

```
search 'dog':        doc2=2 doc1=1
search 'quick dog':  doc2=4 doc1=2
```

Doc 2 says `dog` twice and `quick` twice, so it scores 4 and ranks first. Doc 1
says each once.

Because queries are an OR, a two-word query never returns **fewer** results than
a one-word one. It widens the net and re-ranks. That suits a search box, where
the user is refining rather than constraining. It does not give "documents
containing both". For an AND, search each term and intersect the id sets
yourself.

There is no length normalisation, so a long document beats a short one for the
same relevance. For titles and filenames that is fine; over mixed lengths it
favours the verbose.

## Topics

[addDocument](#adddocument) · [search](#search) · [documentCount](#documentcount) · [termCount](#termcount)

### addDocument

```c
void addDocument(i32 docId, u8* text)
```

Index a document under an id you choose: a row index, a file id, anything you
can map back. The index stores **ids, not documents**, so it keeps nothing alive
and cannot dangle. It can describe text that has since changed.

:::note[There is no remove or update]
Adding the same id twice **adds to** its postings rather than replacing them, so
re-indexing a changed document double-counts its terms.

To re-index, build a fresh `UXSearchIndex`. At the sizes this is meant for,
rebuilding is cheap even for a document set that changes often. Keep the old
index until the new one is built to avoid a period with no search.
:::

The text is tokenized immediately and the terms are copied, so the string need
not outlive the call.

### search

```c
Array<UXSearchResult>* search(u8* query)
```

Ranked matches, best first. Returns an **empty array** for no match, never null,
so a result loop needs no guard.

A query with no alphanumeric characters tokenizes to nothing and matches nothing,
which is the right result for an empty search box.

### documentCount

```c
i32 documentCount(void)
```

Distinct ids seen.

### termCount

```c
i32 termCount(void)
```

Distinct terms. Useful as a sanity check on the tokenizer, and as a rough size
measure: the index is one entry per distinct term plus one posting per
(term, document) pair.

## Cost

Both `termFor` and the scoring accumulator are **linear scans**. Indexing a
document costs *terms × distinct terms so far*, and a query costs *query terms ×
index size*.

That is fine for hundreds of documents and thousands of terms, which is what a
find-as-you-type box over a project's files has. Beyond that the cost grows
roughly quadratically, and a real corpus needs a hash.

## Example

```
index: docs=3 terms=14
search 'dog': doc2=2 doc1=1
search 'quick dog': doc2=4 doc1=2
'LAZY' finds 2   'lazy,' finds 2   'Dog!' finds 2
'unicorn' finds 0
'jumps'=1  'jump'=0
```

The program is `website/site/examples/uxkit/records.xc`. The `doc-examples`
gate compiles it, and the block above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXSearchResult`](/compiler/api/uxkit/uxsearchresult/): one ranked hit
- [`UXTerm`](/compiler/api/uxkit/uxterm/): one word and where it occurs
- [`UXPosting`](/compiler/api/uxkit/uxposting/): one (document, count) pair
- [`UXText.contains`](/compiler/api/uxkit/uxtext/#contains): the right tool for
  a single string
