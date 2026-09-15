---
title: UXBindings
description: "Named integer values for a UXExpression to read: the row a formula is evaluated against."
---

`UXBindings` is a set of name/value pairs that a
[`UXExpression`](/compiler/api/uxkit/uxexpression/) reads its variables from.

```c
#use <UXKit>            // or #import "UXExpression.xc"
```

## Overview

```c
UXBindings* b = new UXBindings();
b.set((u8*)"qty",   3);
b.set((u8*)"price", 200);

UXExpression.parse((u8*)"qty * price").evaluate(b);    // 600
```

It is two parallel arrays, names and values, looked up by content. It is small
on purpose: it holds one row of a computed column and is not a symbol table.

## The bindings are the row

Separating the expression from the bindings makes a computed column one parse
and N evaluations:

```c
UXExpression* total = UXExpression.parse((u8*)"qty * price");

for (each row) {
    b.set((u8*)"qty",   row.qty);
    b.set((u8*)"price", row.price);
    cell = total.evaluate(b);
}
```

[`set`](#set) **updates in place** when the name already exists, so reusing one
bindings object across rows does not grow it. The intended pattern is one
object, re-set per row.

## An unbound name is zero

```c
b.get((u8*)"missing");      // 0
```

There is no "is this bound" query and no error. A formula that refers to a name
that does not exist evaluates with `0` in its place.

For a formula a user typed, a typo then gives a wrong number instead of a crash.
To reject unknown names, check them before evaluating: you know which names you
meant to offer, and the expression does not.

:::note[Zero is also a legitimate value]
`get` returning `0` cannot distinguish "bound to zero" from "not bound at all".
If that distinction matters, keep your own set of the names you bound.
[`UXStr.toInt`](/compiler/api/uxkit/uxstr/#toint) has the same limitation and
the same remedy.
:::

## Names are compared by content, and kept by pointer

```c
b.set((u8*)"qty", 3);
```

Lookup compares bytes, so a name built at run time matches a literal.

`set` **keeps the name pointer** and does not copy it. If the name comes from a
scratch buffer, the bindings compare against whatever that buffer later holds.
Copy borrowed strings with [`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup).

Values are `i32` and are copied, so only the names need care.

## Lookup is linear

Every `get` scans the names. For the handful of variables a formula uses, this
is faster than a hash and much simpler.

An expression evaluated per row over a large table does one scan per variable
reference, so keep the bindings small. A row's bindings usually are.

## Topics

[set](#set) · [get](#get)

### set

```c
void set(u8* name, i32 v)
```

Bind, or rebind. Updating an existing name is in place.

### get

```c
i32 get(u8* name)
```

The value, or `0` if the name is not bound.

## Example

```
  qty * price + tax = 650
  qty + missing = 3
  before: 600
  after qty=10: 2000
```

`missing` contributes nothing, and the rebind changes the answer without
re-parsing. The program is `website/site/examples/uxkit/rules.xc`. The
`doc-examples` gate compiles it, and the listing above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXExpression`](/compiler/api/uxkit/uxexpression/): reads these
- [`UXKeyValueStore`](/compiler/api/uxkit/uxkeyvaluestore/): named values that
  persist, where these are per-evaluation
