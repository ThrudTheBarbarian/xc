---
title: UXEvaluable
description: "One method makes any type filterable: answer a key path with a string, and every predicate anyone builds works on you."
---

`UXEvaluable` is the one-method protocol that makes a type filterable by
[`UXPredicate`](/compiler/api/uxkit/uxpredicate/).

```c
#use <UXKit>            // or #import "UXPredicate.xc"
```

## Overview

```c
protocol UXEvaluable {
    u8* valueForKey(u8* key);
}
```

Implement this method and **any predicate works on your type**. The predicate
does not need to know what your type is, and you do not write a filter method
per query.

```c
class File : Object <UXEvaluable> {
    u8* name; u8* kind; u8* size;

    u8* valueForKey(u8* key) {
        if (UXPredicate.streq(key, (u8*)"name")) { return name; }
        if (UXPredicate.streq(key, (u8*)"kind")) { return kind; }
        if (UXPredicate.streq(key, (u8*)"size")) { return size; }
        return (u8*)"";
    }
}
```

```c
UXPredicate* p = UXPredicate.and(UXPredicate.equals((u8*)"kind", (u8*)"Source"),
                                 UXPredicate.contains_((u8*)"name", (u8*)"UX"));
p.evaluate((UXEvaluable*)file);
```

## Topics

[valueForKey](#valueforkey)

### valueForKey

```c
u8* valueForKey(u8* key)
```

The value for a key path, as a string.

**Return `""` (or `0`) for a key you do not have.** An absent key counts as
empty, not as an error. A rule naming a field this object lacks fails to match
instead of aborting a whole filter pass, so one rule editor can run over a
heterogeneous list.

**Everything is a string, and the operator decides how to read it.** Numeric
comparisons (`<` `>` `<=` `>=`) parse both sides as integers; `=` and `!=`
compare as strings. Under `>`, a `size` of `"14"` is greater than `"9"`, where a
string comparison would say otherwise. `"512 B"` reads as 512, because the parse
takes the leading integer and units are not modelled.

You can keep values in whatever textual form your model already has, but unit
suffixes are ignored, not interpreted.

## Keeping it cheap

`valueForKey` is called once per key per object per evaluation, so a filter over
a large list calls it many times. Returning a stored field is ideal. If a key
needs computing, consider holding the value in the model instead of computing it
here.

## See also

- [`UXPredicate`](/compiler/api/uxkit/uxpredicate/): the tree that calls this,
  with the full operator table and a worked example
- [`UXSortDescriptor`](/compiler/api/uxkit/uxsortdescriptor/): the ordering
  half of the same job
- [`UXTableDataSource`](/compiler/api/uxkit/uxtabledatasource/): the usual
  source of the list being filtered
