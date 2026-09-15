---
title: UXTerm
description: "One indexed word and the list of documents containing it: the row of the inverted index that makes a query a lookup rather than a scan."
---

`UXTerm` is one word in a [`UXSearchIndex`](/compiler/api/uxkit/uxsearchindex/),
together with every document it occurs in.

```c
#use <UXKit>            // or #import "UXSearchIndex.xc"
```

## Overview

```c
class UXTerm : Object {
    u8*               word;        // lowercased, alphanumeric only
    Array<UXPosting>* postings;    // one per document containing it
}
```

A term is a row of the inverted index. A query tokenizes into words, looks each
one up here, and reads off the documents. Searching is therefore a **lookup**
rather than a scan of every document.

## The word is already normalised

```c
u8* word
```

Before a term is created, the tokenizer lowercases the word and strips
everything that is not a letter or a digit. `"Dog!"`, `"dog,"` and `"DOG"` in
three documents are **one** `UXTerm`.

Queries go through the same tokenizer, so indexing and querying apply the same
normalisation from one place.

The string is a **copy** made by the index, so it outlives the text that was
indexed.

## The postings are the payoff

```c
Array<UXPosting>* postings
```

One [`UXPosting`](/compiler/api/uxkit/uxposting/) per document containing the
word, each carrying a count. Scoring a query walks these lists and adds up the
counts.

Postings are held strongly and never removed. The index has no delete, so a
term's list only grows. This is why
[re-indexing means a rebuild](/compiler/api/uxkit/uxsearchindex/#adddocument).

A term always has at least one posting: its first occurrence creates it, and
nothing prunes.

## Lookup is a linear scan

The index finds a term by walking its term array and comparing strings, so
`termCount()` is also the cost of every lookup.

For the hundreds to low thousands of distinct words that a project's filenames
and titles produce, this is faster than a hash and simpler. Over large amounts
of prose it would be the first part to replace, and it can be replaced here
without changing postings, scoring or the query path.

## Fields

### word

```c
u8* word
```

### postings

```c
Array<UXPosting>* postings
```

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXPosting`](/compiler/api/uxkit/uxposting/): a document and a count
- [`UXSearchIndex`](/compiler/api/uxkit/uxsearchindex/): the index these make
  up
- [`UXStrItem`](/compiler/api/uxkit/uxstritem/): a plain boxed string, when you
  want no index at all
