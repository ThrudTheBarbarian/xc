---
title: NumberFormatter
description: "Numbers to display text and back: grouping, fraction digits, currency and percent styles, exact fixed point."
---

`NumberFormatter` turns a [`Number`](/compiler/api/number/) into display text
and reads such text back (`NSNumberFormatter` in shape): `1234567` as
`1,234,567`, `1299.5` as `$1,299.50`, `0.25` as `25%`.
**From 0.72.**

```c
#import "NumberFormatter.xc"   // not in the Foundation umbrella: import it by name
```

## Overview

```c
NumberFormatter* f = NumberFormatter.decimal();
f.format(Number.withI64((i64)1234567));                                   // "1,234,567"
NumberFormatter.currency(String.withCString("$")).format(Number.withDouble(1299.5d));  // "$1,299.50"
NumberFormatter.percent().format(Number.withDouble(0.256d));              // "26%"
```

A formatter is a set of choices, held in public fields you may change:

| Field | Default | |
|---|---|---|
| `String* prefix` | `""` | before the digits: a currency symbol |
| `String* suffix` | `""` | after them: `%`, a unit |
| `bool grouping` | `true` | separate thousands |
| `String* groupSeparator` | `","` | |
| `String* decimalSeparator` | `"."` | |
| `u8 minimumFractionDigits` | `0` | pad with zeros to this many |
| `u8 maximumFractionDigits` | `3` | round to this many |
| `i64 multiplier` | `1` | `100` for a percentage |

**Rounding.** Integers are formatted exactly. A double is rounded to
`maximumFractionDigits` as C's `printf` rounds it (to the nearest, with ties to
even on the binary value, so `2.675` is `2.67`: the double is just below it).
Trailing zeros past `minimumFractionDigits` are then dropped. A minus sign goes
before the prefix (`-$5.00`), and a value that rounds to zero has none.

```c
NumberFormatter* eu = NumberFormatter.decimal();
eu.groupSeparator = String.withCString(".");
eu.decimalSeparator = String.withCString(",");
eu.format(Number.withDouble(1234567.891d));      // "1.234.567,891"
```

:::note[Availability]
Every target except xt6502.
:::

## Topics

**Styles** · [decimal](#decimal) · [currency](#currency) · [percent](#percent)

**Formatting** · [format](#format) · [formatI64](#formati64) · [formatDouble](#formatdouble) · [formatFixed](#formatfixed)

**Parsing** · [parse](#parse)

---

## Styles

### decimal
```c
static NumberFormatter* decimal(void)
```
Grouped, up to three fraction digits: `1,234.567`. Also what `new
NumberFormatter()` gives.

### currency
```c
static NumberFormatter* currency(String* symbol)
```
`symbol` in front and exactly two fraction digits: `$1,299.00`.

### percent
```c
static NumberFormatter* percent(void)
```
Times 100, `%` after, no fraction digits: `0.256` is `26%`.

[↑ Topics](#topics)

## Formatting

### format
```c
String* format(Number* n)
```
`n` as text, through [`formatI64`](#formati64) or
[`formatDouble`](#formatdouble) by its kind; a null `n` is `""`.

### formatI64
```c
String* formatI64(i64 v)
```
An integer, exactly (in double only if the multiplier would overflow it), padded
with `minimumFractionDigits` zeros.

### formatDouble
```c
String* formatDouble(double v)
```
A double, rounded as described above. NaN is `NaN`; an infinity is `∞` between
the prefix and suffix.

### formatFixed
```c
String* formatFixed(i64 scaled, u8 decimals)
```
A fixed-point value in units of 10<sup>-decimals</sup>, exactly: 129900 with 2
decimals is `1,299.00`. The fraction always has `decimals` digits, whatever the
least and most are. What money kept in cents wants.

[↑ Topics](#topics)

## Parsing

### parse
```c
Number* parse(String* text)
```
The `Number` that `text` shows, or null if it is not one. The prefix and suffix
are optional, a leading `-` may come before or after the prefix, grouping
separators are ignored, and the result is divided by the multiplier. Text with
no decimal separator gives an int when it fits and the multiplier divides it:
`"300%"` is `3`, `"25%"` is `0.25`.

[↑ Topics](#topics)
