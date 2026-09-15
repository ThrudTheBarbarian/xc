---
title: UXPosting
description: "One entry in a term's posting list: a document id and how many times the term appears in it."
---

`UXPosting` is the atom of the inverted index: *this term appears in this
document, this many times*.

```c
#use <UXKit>            // or #import "UXSearchIndex.xc"
```

## Overview

```c
class UXPosting : Object {
    i32 docId;
    i32 count;
}
```

A [`UXTerm`](/compiler/api/uxkit/uxterm/) holds a list of these, one per
document containing the word. That list is the *posting list*, and the index is
a set of them.

## Why the count is stored

Recording only *which* documents contain a term would make the index smaller and
every result equally relevant. The count gives
[`search`](/compiler/api/uxkit/uxsearchindex/#search) something to rank by: a
document that says `dog` twice scores 2, one that says it once scores 1.

Frequency is the cheapest useful signal. It costs one integer per
(term, document) pair and needs no second pass over the corpus, which a scheme
like inverse document frequency would.

It does **not** record *where* a term appears. There are no positions, so the
index has no [phrase
search](/compiler/api/uxkit/uxsearchindex/#tokenizing-is-the-contract).
Positions would need a list per posting instead of a number, and the index is
sized for filenames and titles.

## Adding a document twice accumulates

Postings are **bumped**, never replaced. Indexing the same `docId` again adds to
the existing counts. [`addDocument`](/compiler/api/uxkit/uxsearchindex/#adddocument)
is therefore not an update: re-indexing a changed document double-counts every
term it kept.

The structure has no delete, because a posting list has no back-pointer to
remove by. Build a fresh index instead.

## It is also the distinct-id list

`UXSearchIndex` reuses this class for the list of document ids it has seen.
There, `docId` holds the id and `count` is unused.

When reading the index's internals: a `UXPosting` inside a term means
*(document, frequency)*, while one in the index's own `docIds` array means
*this id exists*.

## Fields

### docId

```c
i32 docId
```

The document this term was found in: the id passed to `addDocument`.

### count

```c
i32 count
```

Occurrences of the term in that document. At least 1 for a posting that exists,
since the first occurrence creates the posting.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXTerm`](/compiler/api/uxkit/uxterm/): the word these hang off
- [`UXSearchIndex`](/compiler/api/uxkit/uxsearchindex/): the index
- [`UXSearchResult`](/compiler/api/uxkit/uxsearchresult/): what a query sums
  these into
