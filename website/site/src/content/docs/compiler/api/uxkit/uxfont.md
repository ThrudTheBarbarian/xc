---
title: UXFont
description: "A font descriptor value (family, size and traits) where every derivation returns a new font and nothing is mutated."
---

`UXFont` is a font **descriptor**: a family, a point size, and the bold and
italic traits. A font chooser edits this value and text drawing carries it.

Glyph rasterisation and the list of available families belong to the
backend. This type touches neither, so it works the same on GEM and macOS,
and it can be compared, stored and passed around freely.

```c
#use <UXKit>            // or #import "UXFont.xc"
```

## Overview

```c
UXFont* base = UXFont.make((u8*)"Helvetica", 12);
UXFont* head = base.bolded().withSize(18);
```

**Every derivation returns a new font.** Nothing mutates:

```c
base.bolded();          // Helvetica 12 Bold
base;                   // Helvetica 12   — unchanged
```

The type is built around this property. Whoever else holds a reference to
a font handed to a label cannot change it underneath the label, so there is
no defensive copying and no question about who owns a style.

Derivations **chain**, which is how a style menu composes:

```c
base.bolded().italicized().withSize(14);    // Helvetica 14 Bold Italic
```

## Topics

[make](#make) · [makeTraits](#maketraits) · [dup](#dup) · [withSize](#withsize) · [withFamily](#withfamily) · [bolded](#bolded--unbolded) · [unbolded](#bolded--unbolded) · [italicized](#italicized) · [togglingBold](#togglingbold--togglingitalic) · [togglingItalic](#togglingbold--togglingitalic) · [scaledBy](#scaledby) · [isBold](#isbold--isitalic) · [isItalic](#isbold--isitalic) · [isEqualTo](#isequalto) · [description](#description)

### make

```c
static UXFont* make(u8* family, i16 size)
```

Family and point size, no traits. The default font is `System 12`.

### makeTraits

```c
static UXFont* makeTraits(u8* family, i16 size, bool bold, bool italic)
```

Sets all four at once. Use it to restore a saved font, where the traits are
known rather than derived.

### dup

```c
UXFont* dup(void)
```

An independent copy. Every derivation below is `dup` plus one change, so
none of them can affect the receiver.

### withSize

```c
UXFont* withSize(i16 s)
```

### withFamily

```c
UXFont* withFamily(u8* fam)
```

### bolded / unbolded

```c
UXFont* bolded(void)
UXFont* unbolded(void)
```

Set the trait, regardless of its previous value.

### italicized

```c
UXFont* italicized(void)
```

Sets italic on, regardless of its previous value.

:::note[There is no `unitalicized`]
Bold has both setters; italic has only one. To turn italic off, use
[`togglingItalic`](#togglingbold--togglingitalic) when you know it is on,
test [`isItalic`](#isbold--isitalic) first when you do not, or derive from a
base font that never had it.
:::

### togglingBold / togglingItalic

```c
UXFont* togglingBold(void)
UXFont* togglingItalic(void)
```

**Flip** the trait. A Bold or Italic menu item uses this pair: the menu does
not need to know the current state, and applying it twice returns the
original font.

```c
UXFont* b = base.togglingBold();       // Helvetica 12 Bold
b.togglingBold();                      // Helvetica 12
```

### scaledBy

```c
UXFont* scaledBy(i16 pct)
```

A percentage of the current size, integer-rounded: `scaledBy(150)` on 12
gives 18. Use it to make text one step larger without knowing the base
size.

### isBold / isItalic

```c
bool isBold(void)
bool isItalic(void)
```

### isEqualTo

```c
bool isEqualTo(UXFont* o)
```

**Value** equality: family, size and both traits. Two separately
constructed `Helvetica 12`s are equal:

```c
UXFont* a = UXFont.make((u8*)"Helvetica", 12);
UXFont* b = UXFont.make((u8*)"Helvetica", 12);
a.isEqualTo(b)              // true
a.isEqualTo(a.bolded())     // false
```

:::note[Not `equals`]
Dispatch in xc is by name only, so `Object.equals` (pointer identity) would
shadow a custom `equals`. The toolkit uses `isEqualTo` wherever it needs
value comparison. The two answers differ here: the fonts above are
`isEqualTo` and are **not** `equals`.
:::

### description

```c
u8* description(void)
```

A human-readable label such as `"Helvetica 12 Bold Italic"`. Traits appear
only when set, so a plain font is `"Helvetica 12"`. A chooser's preview line
and a font menu item show this string.

## Example

```c
#import <Stdio.xc>
#import "UXFont.xc"

void main(void) {
    UXFont* base = UXFont.make((u8*)"Helvetica", 12);

    base.bolded();                                 // Helvetica 12 Bold
    base.italicized();                             // Helvetica 12 Italic
    base.withSize(18);                             // Helvetica 18
    base.scaledBy(150);                            // Helvetica 18
    base;                                          // Helvetica 12 — untouched

    base.bolded().italicized().withSize(14);       // Helvetica 14 Bold Italic

    UXFont* b = base.togglingBold();               // Helvetica 12 Bold
    b.togglingBold();                              // Helvetica 12

    UXFont* other = UXFont.make((u8*)"Helvetica", 12);
    base.isEqualTo(other);                         // true
    base.isEqualTo(base.bolded());                 // false
}
```

The full program is `website/site/examples/uxkit/font.xc`. The
`doc-examples` gate compiles it, and the comments are its real output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXTextLayout`](/compiler/api/uxkit/uxtextlayout/): measuring and wrapping
  text in a font
- [`UXAttributedString`](/compiler/api/uxkit/uxattributedstring/): runs of text
  that each carry their own font
- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): where a font becomes glyphs
