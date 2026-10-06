---
title: UXTextStyle
description: "How a span of rich text is drawn: the bold, italic, pen and size attributes UXKit reads from a Foundation AttributedString."
---

Rich text in UXKit is a Foundation
[`AttributedString`](/compiler/api/attributedstring/). `UXTextStyle` names the
attributes UXKit draws and reads them as one value: `bold` and `italic`
(Number booleans), `pen` (a Number, the colour pen; `1` is ink) and `size` (a
Number, the point size; `0` is the view's own). Other attributes are kept by
the string and ignored when drawing. From 0.72.

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

[of](#of) · [at](#at) · [sameAs](#sameas) · [setBold](#setbold--setitalic--setpen--setsize) · [setItalic](#setbold--setitalic--setpen--setsize) · [setPen](#setbold--setitalic--setpen--setsize) · [setSize](#setbold--setitalic--setpen--setsize)

### of

```c
static UXTextStyle* of(Map* attrs)
```

The style an attribute set describes. Names it does not have keep their
defaults: not bold, not italic, pen `1`, size `0`.

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

### setBold / setItalic / setPen / setSize

```c
static void setBold(AttributedString* as, bool v, i32 start, i32 len)
static void setItalic(AttributedString* as, bool v, i32 start, i32 len)
static void setPen(AttributedString* as, i32 pen, i32 start, i32 len)
static void setSize(AttributedString* as, i16 size, i32 start, i32 len)
```

Set one attribute over `len` bytes from `start`.
