---
title: Expression
description: "Parse an arithmetic expression once and evaluate it many times against variables: exact integers, doubles, comparisons, logic and min/max/abs."
---

`Expression` parses an arithmetic expression once and evaluates it as often as
needed against a set of variables (`NSExpression` in shape): a computed column,
a rule such as `price * qty`, or the arithmetic of a small scripting layer.
**From 0.72.**

```c
#import "Expression.xc"    // not in the Foundation umbrella: import it by name
```

## Overview

```c
try
    {
    Expression* e = Expression.parse(String.withCString("qty * price + tax"));
    Map* vars = new Map();
    vars.set(String.withCString("qty"), Number.withI64((i64)3));
    vars.set(String.withCString("price"), Number.withI64((i64)200));
    vars.set(String.withCString("tax"), Number.withDouble(12.5d));
    Stdio.printf("%@\n", e.evaluate(vars));       // 612.500000
    }
catch (ExpressionError x)
    {
    Stdio.printf("%s\n", x.message().cString());
    }
```

**The language**, from the loosest binding to the tightest:

| | |
|---|---|
| `a \|\| b` | either is non-zero (a bool) |
| `a && b` | both are non-zero (a bool) |
| `==` `!=` `<` `>` `<=` `>=` | compare (a bool) |
| `+` `-` | add, subtract |
| `*` `/` `%` | multiply, divide, remainder |
| `-` `!` `+` | negate, not, plus (prefix) |
| `42` `0x2A` `2.5` `1e3` `true` `false` `name` `f(a, b)` `( … )` | values |

Names are letters, digits and `_` after a letter or `_`. The functions are
`min` and `max` (one or more arguments) and `abs` (one). `&&` and `||` evaluate
their right side only when they need it, so `0 && missing` is `false` even
with no value for `missing`.

**Numbers.** Values are [`Number`](/compiler/api/number/)s. An operation on two
integers stays an exact 64-bit integer (wrapping on overflow, as `i64` does):
`/` truncates toward zero and `%` takes the sign of the left side, so `-7 / 2`
is `-3` and `-7 % 3` is `-1`. If either side is a double, the operation is done
in double. A comparison or a logical operator gives
[`Number.withBool`](/compiler/api/number/#withbool). A literal with a `.` or
an exponent is a double, read exactly as [`JSON`](/compiler/api/json/) reads
one.

:::note[Availability]
Every target except xt6502.
:::

## Topics

**Parsing** · [parse](#parse) · [variables](#variables)

**Evaluating** · [evaluate](#evaluate)

**Errors** · [ExpressionError](#expressionerror)

---

## Parsing

### parse
```c
static Expression* parse(String* text) throws
```
The expression `text` holds, ready to evaluate. Throws an
[`ExpressionError`](#expressionerror) for text that is not one expression.

### variables
```c
Array* variables(void)
```
The names of the variables it uses (`String`s), each once, in the order they
first appear: `a * b + a - c` gives `a`, `b`, `c`.

[↑ Topics](#topics)

## Evaluating

### evaluate
```c
Number* evaluate(void) throws
Number* evaluate(Map* vars) throws
```
The value, with each variable taken from `vars`, a [`Map`](/compiler/api/map/)
from its name (a `String`) to a `Number`. Throws an
[`ExpressionError`](#expressionerror) for a variable with no `Number` in `vars`,
and for an integer `/` or `%` by zero (a double division by zero gives `inf`,
as in C).

[↑ Topics](#topics)

## Errors

### ExpressionError
```c
class ExpressionError <Error>
String* message(void)
```
What [`parse`](#parse) and [`evaluate`](#evaluate) throw. A parse error gives
the byte offset, as in `bad expression at byte 6: expected ')'`; an evaluation
error names the problem, as in `no Number for the variable 'qty'`.

[↑ Topics](#topics)
