---
title: UXNumberFormatter
description: "Integers with digit grouping and fixed-point decimals (1,234,567 or $1,299.00), computed as scaled integers so the result is exact on every backend."
---

`UXNumberFormatter` turns an integer into the string a column needs:
`1234567` into `1,234,567`, the cents value `129900` into `$1,299.00`, `42` into
`42%`.

```c
#use <UXKit>            // or #import "UXNumberFormatter.xc"
```

## Overview

```c
UXNumberFormatter* f = UXNumberFormatter.decimal();
f.format(1234567);                      // 1,234,567

UXNumberFormatter* money = UXNumberFormatter.currency((u8*)"$");
money.formatFixed(129900, 2);           // $1,299.00
```

## Fixed point is a scaled integer

There is no floating point. A fractional value is passed as an **integer scaled
by a power of ten**, together with how many decimal places that represents:

```c
f.formatFixed(129900, 2);     // 1,299.00   — 129900 cents
f.formatFixed(425, 1);        // 42.5
f.formatFixed(5, 2);          // 0.05       — padded, not truncated
```

You pass **cents, not dollars**. Careful money code works this way, and it also
makes the output identical on every backend, including ones with no FPU where
`double` is not available.

The formatter never rounds: the value you give it is the value it prints.

## Grouping is on by default

```c
new UXNumberFormatter();             // already groups: 1,234,567
f.setGrouping(false);                // 1234567
```

A plain formatter is therefore `new` **plus** `setGrouping(false)`.
[`decimal()`](#decimal) is the same as a fresh formatter, and exists because
it reads better at a call site.

Separators are settable. This is the extent of locale support:

```c
UXNumberFormatter* euro = UXNumberFormatter.currency((u8*)"EUR ");
euro.setGroupSeparator((u8)'.');
euro.setDecimalSeparator((u8)',');
euro.formatFixed(129900, 2);          // EUR 1.299,00
```

Groups are always **three digits**, so the Indian lakh/crore grouping
(`12,34,567`) is not expressible. Like the English-only month names in
[`UXDateFormatter`](/compiler/api/uxkit/uxdateformatter/#names-are-english),
this is an intended limit.

## Prefix and suffix

The prefix and suffix are literal text, so one class covers currency,
percentages and units:

```c
f.setPrefix((u8*)"$");      // $1,299.00
f.setSuffix((u8*)"%");      // 42%
f.setSuffix((u8*)" px");    // 640 px
```

:::note[The minus sign goes after the prefix]
`money.formatFixed(-129900, 2)` gives **`$-1,299.00`**, not `-$1,299.00`.

The sign is emitted where the number starts, and the prefix is emitted before
it. For the accounting form, format the magnitude and place the sign
yourself.
:::

## Topics

[format](#format) · [formatFixed](#formatfixed) · [setPrefix](#setprefix) · [setSuffix](#setsuffix) · [setGrouping](#setgrouping) · [setGroupSeparator](#setgroupseparator) · [setDecimalSeparator](#setdecimalseparator) · [decimal](#decimal) · [currency](#currency) · [percent](#percent)

### format

```c
u8* format(i32 value)
```

An integer with no decimal part. Equivalent to [`formatFixed`](#formatfixed)
with `0`.

### formatFixed

```c
u8* formatFixed(i32 value, i32 decimals)
```

`value` scaled by 10^`decimals`. The fractional digits are **zero-padded** to
`decimals`, so `5` with `2` is `0.05` rather than `0.5`.

Each call returns a fresh buffer.

:::caution[The scaled value must fit in an `i32`]
Two decimal places cost two digits of range, so the largest representable
amount is about **21 million** at `decimals == 2`. Beyond that, the
multiplication that produced your scaled value has already overflowed before
the formatter sees it.
:::

### setPrefix

```c
void setPrefix(u8* p)
```

Kept, not copied. Pass a literal or a
[`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup).

### setSuffix

```c
void setSuffix(u8* s)
```

Same ownership rule.

### setGrouping

```c
void setGrouping(bool on)
```

`true` restores `,`; `false` turns grouping off. Use
[`setGroupSeparator`](#setgroupseparator) to choose a *different*
separator; `setGrouping(true)` resets it to a comma.

### setGroupSeparator

```c
void setGroupSeparator(u8 c)
```

One byte. `0` means no grouping, which is what `setGrouping(false)` sets.

### setDecimalSeparator

```c
void setDecimalSeparator(u8 c)
```

### decimal

```c
static UXNumberFormatter* decimal(void)
```

Grouped, no prefix or suffix.

### currency

```c
static UXNumberFormatter* currency(u8* symbol)
```

Grouped, with the symbol as prefix. Pass `"$"`, `"£"`, or `"EUR "` with its own
space. The symbol is placed verbatim, so you control the spacing.

### percent

```c
static UXNumberFormatter* percent(void)
```

A `%` suffix.

## Example

```
ungrouped: 1234567   default: 1,234,567
money: $1,299.00   negative: $-1,299.00
euro:  EUR 1.299,00
pct:   42%   one dp: 42.5%
edges: 0 999 0.05
```

The program is `website/site/examples/uxkit/dates.xc`; the `doc-examples` gate
compiles it, and this is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXStr.fromInt`](/compiler/api/uxkit/uxstr/#fromint): when no formatting is
  wanted
- [`UXDateFormatter`](/compiler/api/uxkit/uxdateformatter/): the same job for
  dates
- [`UXTableView`](/compiler/api/uxkit/uxtableview/): the formatted column this
  serves
