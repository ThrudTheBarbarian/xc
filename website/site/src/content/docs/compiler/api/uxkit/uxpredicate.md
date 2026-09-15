---
title: UXPredicate
description: "A predicate tree (comparisons combined with AND, OR and NOT) evaluated against any object that answers valueForKey. The engine behind a rule editor."
---

`UXPredicate` is a tree of tests: **comparisons** (`keyPath OP value`) combined
by **AND / OR / NOT**. A rule editor is built from it ("kind is Source AND name
contains UX"), and it evaluates against any object that can answer one question.

```c
#use <UXKit>            // or #import "UXPredicate.xc"
```

## Overview

```c
UXPredicate* p = UXPredicate.and(UXPredicate.greaterThan((u8*)"age", (u8*)"30"),
                                 UXPredicate.contains_((u8*)"name", (u8*)"sm"));
p.evaluate((UXEvaluable*)person);     // true if age > 30 and "sm" is in the name
```

### One method makes an object filterable

```c
protocol UXEvaluable {
    u8* valueForKey(u8* key);
}
```

This is the whole contract. Your type answers a key path with a string, and any
predicate can filter it. The predicate does not need to know your type, and you
do not write a filter method per query.

Return `""` (or `0`) for a key you do not have. An absent key is **empty, not an
error**, so a rule mentioning a field this object lacks fails to match instead
of aborting a whole filter pass.

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

### Everything is a string, and the operator decides how to read it

Values come back as strings, and the **operator** determines interpretation:

| operators | how both sides are read |
| --- | --- |
| `<` `>` `<=` `>=` | parsed as **integers** |
| `=` `!=` | compared as **strings** |
| `CONTAINS` `BEGINSWITH` `ENDSWITH` | substring tests |
| `MATCHES` | an [`UXRegex`](/compiler/api/uxkit/uxregex/) **search** |

So `size > 9` picks 14 and 48. The numeric operators parse, so `"14" > "9"` is
true here; a plain string comparison would make it false.

A leading integer is enough: `"512 B"` reads as 512, and units are not modelled.

`MATCHES` **searches instead of anchoring**, so `(xc|png)` matches `main.xc` and
`logo.png` on a substring, without `.*` at either end.

## Topics

[equals](#equals) · [notEquals](#notequals) · [lessThan](#lessthan) · [greaterThan](#greaterthan) · [lessOrEqual](#lessorequal) · [greaterOrEqual](#greaterorequal) · [contains_](#contains_) · [beginsWith](#beginswith) · [endsWith](#endswith) · [matches](#matches) · [and](#and) · [or](#or) · [not](#not) · [compound](#compound) · [addSub](#addsub) · [evaluate](#evaluate) · [comparison](#comparison)

### equals

```c
static UXPredicate* equals(u8* k, u8* v)
```

String equality on key `k`.

### notEquals

```c
static UXPredicate* notEquals(u8* k, u8* v)
```

### lessThan

```c
static UXPredicate* lessThan(u8* k, u8* v)
```

Numeric: both sides parsed as integers.

### greaterThan

```c
static UXPredicate* greaterThan(u8* k, u8* v)
```

### lessOrEqual

```c
static UXPredicate* lessOrEqual(u8* k, u8* v)
```

### greaterOrEqual

```c
static UXPredicate* greaterOrEqual(u8* k, u8* v)
```

### contains_

```c
static UXPredicate* contains_(u8* k, u8* v)
```

Substring test.

:::note[The trailing underscore]
`contains` alone would collide with an existing name, so the constructor is
`contains_`. The **operator** is still `UXP_CONTAINS`; only the convenience
constructor carries the underscore.
:::

### beginsWith

```c
static UXPredicate* beginsWith(u8* k, u8* v)
```

### endsWith

```c
static UXPredicate* endsWith(u8* k, u8* v)
```

### matches

```c
static UXPredicate* matches(u8* k, u8* v)
```

A regular-expression **search**; see [above](#everything-is-a-string-and-the-operator-decides-how-to-read-it).

### and

```c
static UXPredicate* and(UXPredicate* a, UXPredicate* b)
```

### or

```c
static UXPredicate* or(UXPredicate* a, UXPredicate* b)
```

### not

```c
static UXPredicate* not(UXPredicate* a)
```

`NOT` is a compound with a single child, so `not(or(x, y))` is the complement of
that whole subtree, not of `x` alone.

### compound

```c
static UXPredicate* compound(i32 logic)      // UXP_AND / UXP_OR / UXP_NOT
```

An empty compound, for building a tree with more than two children.

### addSub

```c
void addSub(UXPredicate* s)
```

Adds a child to a compound. A rule editor with N rows combines this with
[`compound`](#compound) to build one predicate:

```c
UXPredicate* all = UXPredicate.compound(UXP_AND);
for (i32 i = 0; i < rows; i = i + 1) {
    if (rowIsActive(i)) { all.addSub(predicateForRow(i)); }
}
```

An inactive row is not added, so an editor where every value is blank matches
everything instead of nothing.

### comparison

```c
static UXPredicate* comparison(u8* key, i32 op, u8* rhs)
```

The general constructor, taking a `UXP_*` operator. A UI uses this when the
operator comes from a pop-up instead of the source text: the pop-up's tag
**is** the opcode.

### evaluate

```c
bool evaluate(UXEvaluable* obj)
```

Walks the tree against one object.

## Example

```c
Array<File>* files = new Array();
files.add(File.make((u8*)"README.md",   (u8*)"Markdown", (u8*)"2"));
files.add(File.make((u8*)"main.xc",     (u8*)"Source",   (u8*)"14"));
files.add(File.make((u8*)"UXWindow.xc", (u8*)"Source",   (u8*)"9"));
files.add(File.make((u8*)"logo.png",    (u8*)"Image",    (u8*)"48"));
```

| predicate | matches |
| --- | --- |
| `equals("kind", "Source")` | `main.xc` `UXWindow.xc` |
| `greaterThan("size", "9")` | `main.xc` `logo.png` |
| `contains_("name", "UX")` | `UXWindow.xc` |
| `and(equals("kind","Source"), contains_("name","UX"))` | `UXWindow.xc` |
| `or(equals("kind","Source"), equals("kind","Image"))` | `main.xc` `UXWindow.xc` `logo.png` |
| `not(equals("kind","Source"))` | `README.md` `logo.png` |
| `matches("name", "(xc\|png)")` | `main.xc` `UXWindow.xc` `logo.png` |

The full program is `website/site/examples/uxkit/predicate.xc`. The
`doc-examples` gate compiles it, and the table above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXRegex`](/compiler/api/uxkit/uxregex/): what `MATCHES` runs
- [`UXSortDescriptor`](/compiler/api/uxkit/uxsortdescriptor/): the ordering
  half of the same job
- [`UXTableView`](/compiler/api/uxkit/uxtableview/): the usual thing being
  filtered
