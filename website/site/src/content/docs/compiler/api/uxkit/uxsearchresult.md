---
title: UXSearchResult
description: "One ranked hit: the document id you supplied, and the score that placed it."
---

`UXSearchResult` is one entry in the array
[`UXSearchIndex.search`](/compiler/api/uxkit/uxsearchindex/#search) returns.

```c
#use <UXKit>            // or #import "UXSearchIndex.xc"
```

## Overview

```c
class UXSearchResult : Object {
    i32 docId;    // the id you passed to addDocument
    i32 score;    // summed term frequency
}
```

```c
Array<UXSearchResult>* hits = ix.search((u8*)"quick dog");
for (u16 i = 0; i < hits.count(); i = i + 1) {
    UXSearchResult* r = (UXSearchResult* ?)hits.get(i);
    showRow(r.docId);            // best first
}
```

The array is already ordered **best first**, so nothing needs sorting afterwards.

## The id is yours

```c
i32 docId
```

The value you passed to
[`addDocument`](/compiler/api/uxkit/uxsearchindex/#adddocument): a row index, a
file id, a key into your own array. The index stores only ids, never documents,
so this is the only link from a hit back to what was found.

The index therefore cannot tell you that an id is stale. If rows can be deleted,
check the id is still live before showing it.

## The score is comparable within one search only

```c
i32 score
```

The sum, over the query's terms, of how many times each appears in that
document. Bigger is better.

It is **not** a percentage, not normalised, and not comparable between searches.
A one-word query produces small numbers and a five-word query large ones, for
the same documents. Showing it to a user as a relevance figure would mislead.

Use it *within* one result set: for the ordering, a relative bar, or a cut-off
such as "ignore anything scoring below half the top hit".

:::note[No length normalisation]
A long document that mentions a term five times outranks a short one that
mentions it twice, even if the short one is more about it. Classic ranking
schemes divide by document length to correct for this; this index does not.

For titles and filenames, which the index is sized for, lengths are similar
enough that it does not show. Over mixed-length prose it favours the verbose.
:::

## Fields

### docId

```c
i32 docId
```

### score

```c
i32 score
```

## Example

```
search 'dog': doc2=2 doc1=1
search 'quick dog': doc2=4 doc1=2
```

Doc 2 says `dog` twice and `quick` twice. Both scores grew when the query did:
the same documents give different numbers, so the value only means something
relative to its neighbours.

The program is `website/site/examples/uxkit/records.xc`. The `doc-examples`
gate compiles it, and the block above is its output.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXSearchIndex`](/compiler/api/uxkit/uxsearchindex/): what produces these
- [`UXPosting`](/compiler/api/uxkit/uxposting/): the per-term counts the score
  is summed from
