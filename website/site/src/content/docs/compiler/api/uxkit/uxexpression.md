---
title: UXExpression
description: "Parse and evaluate an integer expression with variables, for a computed column, a rule value, or the arithmetic half of a light scripting layer."
---

`UXExpression` parses an arithmetic expression once and evaluates it against a
set of variable bindings as often as you like.

```c
#use <UXKit>            // or #import "UXExpression.xc"
```

## Overview

```c
UXExpression* e = UXExpression.parse((u8*)"qty * price + tax");

UXBindings* b = new UXBindings();
b.set((u8*)"qty", 3);
b.set((u8*)"price", 200);
b.set((u8*)"tax", 50);

e.evaluate(b);        // 650
```

It has the shape of `NSExpression`. A recursive-descent parser builds a small
AST, which evaluation walks. Arithmetic is integer-only, so results are exact on
every backend.

Use it for a computed column, a rule value (`"price * qty"`), or the arithmetic
half of a light UI scripting layer.

## Parse once, evaluate many

```c
UXExpression* e = UXExpression.parse((u8*)"qty * price");
e.evaluate(b);                 // 600
b.set((u8*)"qty", 10);
e.evaluate(b);                 // 2000
```

The expression holds structure only, no values. A computed column parses its
formula when the column is defined and re-evaluates it per row.

`evaluate` does not mutate the expression, so one parsed expression can be
evaluated against different bindings.

## Operators and precedence

Loosest first:

| | |
| --- | --- |
| comparison | `==` `!=` `<` `>` `<=` `>=` |
| additive | `+` `-` |
| multiplicative | `*` `/` `%` |
| unary | `-` |
| primary | number, variable, `( … )` |

Comparisons yield **1 or 0**, so an expression can also serve as a predicate:

```c
UXExpression.parse((u8*)"qty * price > 500").evaluate(b);   // 1
```

A rule such as "flag rows where the total exceeds the limit" is then one
expression, with no separate comparison written in code.

## Nothing traps

Three cases that would abort in a stricter language return a value instead:

```c
UXExpression.parse((u8*)"qty / 0").evaluate(b);         // 0
UXExpression.parse((u8*)"qty % 0").evaluate(b);         // 0
UXExpression.parse((u8*)"qty + missing").evaluate(b);   // 3 — missing is 0
```

Division and modulo by zero give `0`, and an **unbound variable reads as 0**.

This suits a formula a user typed into a cell: a typo in a name produces a wrong
number, not a crashed application. It does not suit code that needs to know the
name was wrong. [`UXBindings`](/compiler/api/uxkit/uxbindings/) has no "is this
bound" query, so check the names you intend to allow before evaluating.

:::caution[Overflow is not detected]
Arithmetic is `i32` and wraps silently. `"price * qty"` with large values gives
a wrong answer with no indication.

Nothing here guards against it, so bound the inputs where the result could be
large. [`UXNumberFormatter`](/compiler/api/uxkit/uxnumberformatter/#formatfixed)
needs the same care for scaled values.
:::

## Failure is a flag, not a null

```c
UXExpression* e = UXExpression.parse((u8*)"qty * ");
e.isValid();      // false
e.evaluate(b);    // 0 — do not use it
```

`parse` **always returns an object**. Check [`isValid`](#isvalid) before
evaluating. An invalid expression evaluates to `0` instead of refusing, which
cannot be told apart from a valid formula whose result is zero.

[`UXJSON.parse`](/compiler/api/uxkit/uxjson/#parse), by contrast, returns null
on malformed input. Here the object exists because it also records the failure:
trailing operators, unbalanced parentheses and unexpected characters all set the
flag.

## Topics

[parse](#parse) · [isValid](#isvalid) · [evaluate](#evaluate)

### parse

```c
static UXExpression* parse(u8* s)
```

Parses a whole string. Trailing text that is not part of the expression, such as
the `)` in `"1 + 2)"`, makes it invalid instead of being ignored.

Whitespace and tabs are skipped. Variable names are letters, digits and
underscore, not starting with a digit.

### isValid

```c
bool isValid(void)
```

Whether the parse succeeded. Always check it.

### evaluate

```c
i32 evaluate(UXBindings* b)
```

Walks the tree against the bindings. A null `b` is allowed; every variable then
reads as `0`, which is useful for a constant expression.

## Example

```
  qty * price + tax = 650
  (qty + 1) * price = 800
  -qty * 10 = -30
  7 / 2 = 3
  7 % 2 = 1
  qty * price > 500 = 1
  qty == 3 = 1
  qty / 0 = 0
  qty % 0 = 0
  qty + missing = 3
  before: 600
  after qty=10: 2000
  qty *  = INVALID
  1 + 2) = INVALID
```

`7 / 2 = 3` is integer division truncating toward zero, not rounding. The
program is `website/site/examples/uxkit/rules.xc`; the `doc-examples` gate
compiles it, and the output above is what it prints.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXBindings`](/compiler/api/uxkit/uxbindings/): the variable values
- [`UXPredicate`](/compiler/api/uxkit/uxpredicate/): filtering objects, where
  this class computes numbers
- [`UXNumberFormatter`](/compiler/api/uxkit/uxnumberformatter/): presenting the
  result
