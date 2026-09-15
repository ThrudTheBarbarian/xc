---
title: UXDateFormatter
description: "Turn a UXDate into a string from a pattern such as yyyy-MM-dd, EEE d MMM yyyy or HH:mm:ss, with the field width chosen by how many letters you write."
---

`UXDateFormatter` formats a [`UXDate`](/compiler/api/uxkit/uxdate/) from a
pattern string, in the `NSDateFormatter` style.

```c
#use <UXKit>            // or #import "UXDate.xc"
```

## Overview

```c
UXDateFormatter* f = UXDateFormatter.withPattern((u8*)"EEEE d MMMM yyyy");
f.format(d);            // Monday 14 September 2026
```

```c
UXDateFormatter.withPattern((u8*)"yyyy-MM-dd").format(d);   // 2026-09-14
UXDateFormatter.withPattern((u8*)"HH:mm:ss").format(d);     // 16:45:07
UXDateFormatter.withPattern((u8*)"EEE d MMM yy").format(d); // Mon 14 Sep 26
```

The formatter is cheap and holds no state apart from its pattern. You can keep
one per format on a controller, or make one per call.

## The run length picks the form

A run of the same letter is **one field**, and the number of letters chooses how
it is rendered:

| pattern | field | `1` | `2` | `3` | `4`+ |
| --- | --- | --- | --- | --- | --- |
| `y` | year | `26` | `26` | `2026` | `2026` |
| `M` | month | `9` | `09` | `Sep` | `September` |
| `d` | day | `14` | `14` | — | — |
| `H` | hour (24) | `16` | `16` | — | — |
| `m` | minute | `45` | `45` | — | — |
| `s` | second | `7` | `07` | — | — |
| `E` | weekday | `Mon` | `Mon` | `Mon` | `Monday` |

`M MM MMM MMMM` gives `9 09 Sep September` from one date. Throughout, one or two
letters give the plain and zero-padded numeric forms.

`H` is the **24-hour** clock. There is no 12-hour field and no AM/PM field (see
below).

## Anything else is literal — including letters

Characters outside that table are copied through, which is how `-`, `:`, `/` and
spaces work. Letters need care:

:::danger[There is no escape mechanism]
Literal **text** in a pattern is not safe, because its letters are still fields:

```c
UXDateFormatter.withPattern((u8*)"Ends yyyy").format(d);
// Monn147 2026     <- E became Mon, d became 14, s became 07
```

Quotes do not help: `'yyyy'` gives `'2026'`, with the quotes as literal
characters and the year still expanded. CLDR's `'...'` escaping is not
implemented.

**Build labels in pieces** instead of embedding words in a pattern:

```c
UXStr.append((u8*)"Ends ",
             UXDateFormatter.withPattern((u8*)"yyyy").format(d));
```

Patterns made only of fields and punctuation, such as every pattern in the
table above, are unaffected.
:::

ISO 8601 works because `T` and `Z` are not field letters:

```c
UXDateFormatter.withPattern((u8*)"yyyy-MM-ddTHH:mm:ss").format(d);
// 2026-09-14T16:45:07
```

## Not implemented

Each of these letters is taken literally, not rejected:

| | |
| --- | --- |
| `h` | 12-hour clock |
| `a` | AM/PM |
| `S` | fractional seconds |
| `Z` / `z` | zone name or offset; use [`UXTimeZone.offsetString`](/compiler/api/uxkit/uxtimezone/#offsetstring) |
| `D`, `w`, `Q`, `G` | day-of-year, week, quarter, era |

`hh:mm a` therefore renders as `hh:45 a`. This looks like a bug but is the
documented behaviour of an unknown field.

## Names are English

Month and weekday names come from a fixed English table (`Sep`/`September`,
`Mon`/`Monday`). There is no locale, and `setLocale` does not exist.

[`UXTimeZone`](/compiler/api/uxkit/uxtimezone/#why-fixed-offset) makes the same
decision. Real localisation needs data that is large, versioned and politically
contested, and half a locale system is worse than none. For a date shown to a
user in a specific language, format the numeric parts and supply your own names.

## Topics

[withPattern](#withpattern) · [setPattern](#setpattern) · [format](#format)

### withPattern

```c
static UXDateFormatter* withPattern(u8* p)
```

Makes a formatter. The usual entry point.

### setPattern

```c
void setPattern(u8* p)
```

Changes the pattern on an existing formatter. The pointer is **kept, not
copied**, so the string must outlive the formatter. Use a literal, or a copy
made with [`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup).

### format

```c
u8* format(UXDate* d)
```

Returns a fresh buffer each call. The date's own components are used as they
stand. Formatting does **not** convert zones, so call
[`inZone`](/compiler/api/uxkit/uxdate/#inzone) first if you want local time.

An empty pattern gives an empty string.

## Example

```
iso:       2026-09-14
time:      16:45:07
long:      Monday 14 September 2026
short:     Mon 14 Sep 26
single:    14/9/2026 16:45
M widths:  9 09 Sep September
E widths:  Mon Monday
```

The program is `website/site/examples/uxkit/dates.xc`; the `doc-examples` gate
compiles it, and the output above is what it prints.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXDate`](/compiler/api/uxkit/uxdate/): the value being formatted
- [`UXTimeZone`](/compiler/api/uxkit/uxtimezone/): offsets, and printing them
- [`UXNumberFormatter`](/compiler/api/uxkit/uxnumberformatter/): the same job
  for numbers
