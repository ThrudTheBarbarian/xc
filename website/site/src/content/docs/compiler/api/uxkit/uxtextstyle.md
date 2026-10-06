---
title: UXTextStyle
description: "How a span of rich text is drawn: the style attributes UXKit reads from a Foundation AttributedString."
---

Rich text in UXKit is a Foundation
[`AttributedString`](/compiler/api/attributedstring/). `UXTextStyle` names the
attributes UXKit draws and reads them as one value:

| Attribute | Value | Default |
|---|---|---|
| `bold`, `italic`, `underline`, `monospace` | Number booleans | off |
| `pen` | Number, the colour pen | `1`, ink |
| `color` | Number, `0xRRGGBB` | none: the view's ink |
| `size` | Number, the point size | `0`: the view's own |
| `alignment` | Number, `UX_ALIGN_*` | `UX_ALIGN_LEFT` |

[`UXTextView`](/compiler/api/uxkit/uxtextview/) applies `alignment` to whole
paragraphs and draws `color`; the drawn text views use `pen`. Other attributes
are kept by the string and ignored when drawing. From 0.72.

```c
#import "UXTextStyle.xc"
```

## Overview

```c
AttributedString* s = AttributedString.withString(String.withCString("The quick fox"));
UXTextStyle.setBold(s, true, (i32)4, (i32)5);    // "quick"
UXTextStyle.setPen(s, (i32)2, (i32)10, (i32)3);  // "fox" in red
UXTextStyle* st = UXTextStyle.at(s, (i32)4);     // st.bold is true
```

[`UXTextLayout`](/compiler/api/uxkit/uxtextlayout/) measures and wraps each run
in its own style, and [`UXMarkdown`](/compiler/api/uxkit/uxmarkdown/) produces
strings styled this way.

## Topics

[of](#of) · [at](#at) · [sameAs](#sameas) · [setBold](#setbold--setitalic--setunderline--setmonospace--setpen--setcolor--setsize--setalignment) · [setItalic](#setbold--setitalic--setunderline--setmonospace--setpen--setcolor--setsize--setalignment) · [setUnderline](#setbold--setitalic--setunderline--setmonospace--setpen--setcolor--setsize--setalignment) · [setMonospace](#setbold--setitalic--setunderline--setmonospace--setpen--setcolor--setsize--setalignment) · [setPen](#setbold--setitalic--setunderline--setmonospace--setpen--setcolor--setsize--setalignment) · [setColor](#setbold--setitalic--setunderline--setmonospace--setpen--setcolor--setsize--setalignment) · [setSize](#setbold--setitalic--setunderline--setmonospace--setpen--setcolor--setsize--setalignment) · [setAlignment](#setbold--setitalic--setunderline--setmonospace--setpen--setcolor--setsize--setalignment)

### of

```c
static UXTextStyle* of(Map* attrs)
```

The style an attribute set describes. Names it does not have keep their
defaults. The fields are `bold`, `italic`, `underline`, `monospace`, `pen`,
`color` (`-1` for none), `size` and `alignment`.

### at

```c
static UXTextStyle* at(AttributedString* as, i32 i)
```

The style of the byte at `i`.

### sameAs

```c
bool sameAs(UXTextStyle* o)
```

Whether two styles draw the same.

### setBold / setItalic / setUnderline / setMonospace / setPen / setColor / setSize / setAlignment

```c
static void setBold(AttributedString* as, bool v, i32 start, i32 len)
static void setItalic(AttributedString* as, bool v, i32 start, i32 len)
static void setUnderline(AttributedString* as, bool v, i32 start, i32 len)
static void setMonospace(AttributedString* as, bool v, i32 start, i32 len)
static void setPen(AttributedString* as, i32 pen, i32 start, i32 len)
static void setColor(AttributedString* as, i32 rgb, i32 start, i32 len)
static void setSize(AttributedString* as, i16 size, i32 start, i32 len)
static void setAlignment(AttributedString* as, i32 align, i32 start, i32 len)
```

Set one attribute over `len` bytes from `start`. `setColor` with `-1` takes
the colour off, back to the view's ink.
