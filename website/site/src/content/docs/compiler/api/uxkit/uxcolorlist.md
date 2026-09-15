---
title: UXColorList
description: "Colours by name: a semantic theme, so a widget reads 'windowBackground' instead of hardcoding a pen, and the whole UI restyles when the theme changes."
---

`UXColorList` maps names to colours. In shape it is `NSColorList` plus AppKit's
semantic colours.

```c
#use <UXKit>            // or #import "UXColorList.xc"
```

## Overview

```c
UXColorList* theme = UXColorList.defaultTheme();

theme.color((u8*)"windowBackground");
theme.color((u8*)"accent");
theme.colorOr((u8*)"gridLine", UXColor.gray());     // with a fallback
```

A widget that hardcodes a pen cannot be re-themed. One that asks for
`"controlFace"` gets whatever the theme says, and swapping the theme restyles the
whole interface without touching a control.

## The names are semantic

They say what a colour is **for**, not what it looks like:

| name | |
| --- | --- |
| `windowBackground` | behind everything |
| `controlFace` | a button's body |
| `controlShadow` / `controlHighlight` | its bevel |
| `text` / `disabledText` | label text, and the greyed version |
| `accent` | the system's highlight colour |
| `selectionFill` / `selectedText` | a selected row |
| `separator` | a divider line |

Use `"text"`, not `"black"`. A dark theme sets `text` to white and every label
follows; a colour named `black` would be wrong in that theme.

## Overriding is setting

```c
UXColorList* mine = UXColorList.defaultTheme();
mine.set((u8*)"accent", UXColor.rgb(200, 30, 30));
```

There is no separate override mechanism. [`set`](#set) replaces the entry for a
name, and every lookup finds the entry for that name.

:::caution[`defaultTheme()` is a shared singleton]
It is made once and returned on every later call, so setting a name on it
changes the theme **for the whole process**, including every widget already
drawing from it.

That is usually what you want, but avoid doing it by accident. To vary a theme
locally, build a fresh `UXColorList` instead.
:::

An application can also invent names of its own. `"gridLine"` is no different in
kind from `"accent"`; only the default theme's own entries are shipped.

## Missing names

```c
theme.has((u8*)"gridLine");                          // false
theme.color((u8*)"gridLine");                        // 0
theme.colorOr((u8*)"gridLine", UXColor.gray());      // gray
```

[`color`](#color) returns **null** for a name that is not there, so a typo gives
a null rather than a wrong colour. Use [`colorOr`](#coloror) in drawing code: a
widget can ask for an optional refinement and fall back without a branch.

This is also how an application adds a name that older themes lack: ask with a
fallback, and an old theme uses the fallback.

## Topics

[defaultTheme](#defaulttheme) · [set](#set) · [color](#color) · [colorOr](#coloror) · [has](#has) · [count](#count)

### defaultTheme

```c
static UXColorList* defaultTheme(void)
```

The shipped semantic set, made on first use. A shared singleton; see the
[caution](#overriding-is-setting).

### set

```c
void set(u8* name, UXColor* color)
```

Add or replace. The name is **kept, not copied**: pass a literal or a
[`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup).

The colour is shared rather than copied. This is safe because
[`UXColor`](/compiler/api/uxkit/uxcolor/) is treated as immutable everywhere.

### color

```c
UXColor* color(u8* name)
```

The colour, or **null**.

### colorOr

```c
UXColor* colorOr(u8* name, UXColor* fallback)
```

The colour, or the fallback. Drawing code should use this.

### has

```c
bool has(u8* name)
```

### count

```c
i32 count(void)
```

The number of entries. With [`UXColorEntry`](/compiler/api/uxkit/uxcolorentry/),
this is how a theme editor enumerates what it can change.

## Cost

Lookup is a **linear scan** comparing names by content. A theme has a couple of
dozen entries, so this is faster than a hash and simpler.

A colour looked up inside a per-pixel loop costs a string comparison per pixel.
Look colours up once, at the top of a draw.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXColorEntry`](/compiler/api/uxkit/uxcolorentry/): one named colour
- [`UXColor`](/compiler/api/uxkit/uxcolor/): the colour, and its derivations
- [`UXColorPanel`](/compiler/api/uxkit/uxcolorpanel/): letting the user pick one
