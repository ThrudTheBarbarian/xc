---
title: UXTextLayout
description: "Greedy word wrap and line layout. Lines come back as ranges into the original string with no copies, and alignment is numbered to match GEM's te_just."
---

`UXTextLayout` breaks a string into **lines that fit a pixel width**, and lays
out each line within its measure. It does the job of `NSTypesetter` on a small
scale.

```c
#use <UXKit>            // or #import "UXTextLayout.xc"
```

## Overview

```c
Array<UXRange>* lines = UXTextLayout.wrap(text, 80, 8);   // 80px wide, 8px per char
```

**A line is a [`UXRange`](/compiler/api/uxkit/uxrange/) into the original
string**, not a copy. The text is stored once however many times it is
re-wrapped. Re-wrapping on resize allocates nothing for the text itself, and
drawing or hit-testing a row indexes straight back into the source.

```
the quick brown fox jumps over the lazy dog     wrapped to 80px:
  [0..8]   the quick
  [10..18] brown fox
  [20..29] jumps over
  [31..38] the lazy
  [40..42] dog
```

The **breaking space is consumed**: line 0 ends at 8, line 1 starts at 10, and
character 9 (the space) belongs to neither. Drawing a line never paints a
trailing space, and the ranges do not tile contiguously as
[`UXRange`](/compiler/api/uxkit/uxrange/)'s adjacency contract otherwise implies.

### Breaking rules

Greedy, in this order:

1. **Explicit newlines always break**, whatever the measure.
2. Otherwise break at the last **space** that fits.
3. If a single word is wider than the whole measure, **break it mid-word**, so
   it does not overflow the column:

```
antidisestablishmentarianism ok     wrapped to 80px:
  [0..9]   antidisest
  [10..19] ablishment
  [20..27] arianism
  [29..30] ok
```

### Widths are arithmetic, unless you ask for metrics

[`wrap`](#wrap) estimates from a **uniform character width**, so it is pure
arithmetic: deterministic, unit-testable, identical on every backend, and needs
no font loaded. [`wrapFont`](#wrapfont) asks the driver for real glyph metrics,
which you need on screen where the font is proportional.

Use `wrap` when testing layout logic and `wrapFont` when drawing.

## Alignment

```c
#define UX_ALIGN_LEFT     0
#define UX_ALIGN_RIGHT    1
#define UX_ALIGN_CENTER   2
#define UX_ALIGN_JUSTIFY  3
```

:::note[Numbered to match GEM, not visual order]
The order is **not** left/centre/right. The numbering matches GEM's `TEDINFO`
`te_just`, which is fixed by a file format the toolkit reads and writes.

Both orders are arbitrary, and GEM's is fixed, so matching it removes a
translation step and the bugs that come with it. With a different numbering,
passing `te_just` through as `UX_ALIGN` would swap **right** and **centre**.
That looks nearly correct on screen and writes the wrong value into every
resource it touches. With identical numbering there is no mapping to get wrong.
:::

**`JUSTIFY` does not stretch the last line.** Stretching the final line of a
paragraph to the full measure is a typesetting error, and only the layout knows
which line is last; a drawing seam cannot tell. For this reason
[`layoutLine`](#layoutline) takes an `isLast` flag rather than inferring it.

## Topics

[wrap](#wrap) · [wrapFont](#wrapfont) · [wrapAttr](#wrapattr) · [lineCount](#linecount) · [layoutLine](#layoutline) · [layoutLineAttr](#layoutlineattr) · [layoutLineWidth](#layoutlinewidth) · [spanWidth](#spanwidth) · [charsThatFit](#charsthatfit) · [isParagraphEnd](#isparagraphend)

### wrap

```c
static Array<UXRange>* wrap(u8* text, i16 width, i16 charWidth)
```

Breaks to `width` pixels, assuming every character is `charWidth` wide.

### wrapFont

```c
static Array<UXRange>* wrapFont(u8* text, i16 width, i32 size)
```

The same, measuring with the driver's real glyph metrics at point `size`.

### wrapAttr

```c
static Array<UXRange>* wrapAttr(UXAttributedString* as, i16 width, i32 baseSize)
```

Wraps rich text, measuring **each run in its own font**. A bold word inside a
sentence takes the width it will draw at, so the break lands where the reader
expects.

### lineCount

```c
static i32 lineCount(u8* text, i16 width, i16 charWidth)
```

How many lines the text wraps to, without building the array. Use it to size a
view before laying it out.

### layoutLine

```c
static Array<UXTextRun>* layoutLine(u8* text, UXRange* ln, i16 measure,
                                    i32 size, i32 align, bool isLast)
```

Positions one line within its measure and returns the [runs](#uxtextrun) to
draw, with their positions. `isLast` suppresses justification on a paragraph's
final line; see [Alignment](#alignment).

### layoutLineAttr

```c
static Array<UXTextRun>* layoutLineAttr(UXAttributedString* as, UXRange* ln, …)
```

The rich-text form: each returned run carries the style to draw it in.

### layoutLineWidth

```c
static Array<UXTextRun>* layoutLineWidth(UXAttributedString* as, UXRange* ln, …)
```

As above, also reporting widths, for a caller placing a caret or measuring a
selection.

### spanWidth

```c
static i32 spanWidth(u8* text, i32 start, i32 end, i32 size)
```

The pixel width of a character span.

### charsThatFit

```c
static i32 charsThatFit(u8* text, i32 start, i32 end, i32 size, i16 width)
```

How many characters of a span fit in `width`. Both the hard mid-word break and
hit-testing a click to a character use it.

### isParagraphEnd

```c
static bool isParagraphEnd(u8* text, Array<UXRange>* lines, u16 i)
```

Whether line `i` ends a paragraph. Pass the result as `isLast`.

## UXTextRun

```c
class UXTextRun : UXRange {
    i32         x;        // where to draw it, within the measure
    UXCharAttr* attr;     // the style; nil = the view's default
}
```

A run **is a range**, extended with a position and a style, rather than a
separate type that repeats `loc`/`len` beside its payload. This follows the
single vocabulary [`UXRange`](/compiler/api/uxkit/uxrange/) describes, so a
reader can see that a text line is a range without opening another file.

## Example

```c
#import <Stdio.xc>
#import "UXTextLayout.xc"

void main(void) {
    u8* text = (u8*)"the quick brown fox jumps over the lazy dog";

    Array<UXRange>* lines = UXTextLayout.wrap(text, 80, 8);
    for (u16 i = 0; i < lines.count(); i = i + 1) {
        UXRange* ln = (UXRange* ?)lines.get(i);
        for (i32 c = ln.loc; c < ln.end(); c = c + 1) { Stdio.printf("%c", text[c]); }
        Stdio.printf("\n");
    }
    // the quick / brown fox / jumps over / the lazy / dog

    UXTextLayout.lineCount(text, 80, 8);        // 5, without building the array
}
```

The full program, including the long-word and explicit-newline cases shown
above, is `website/site/examples/uxkit/textwrap.xc`. The `doc-examples` gate
compiles it.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXRange`](/compiler/api/uxkit/uxrange/): what a line is
- [`UXAttributedString`](/compiler/api/uxkit/uxattributedstring/): rich text,
  wrapped per run
- [`UXFont`](/compiler/api/uxkit/uxfont/): what `wrapFont` measures in
- [`UXText`](/compiler/api/uxkit/uxtext/): the view that puts this on screen
