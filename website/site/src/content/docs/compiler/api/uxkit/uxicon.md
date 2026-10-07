---
title: UXIcon
description: "Icons by neutral name, shown as each platform's own picture: SF Symbols, Android's drawables, and UXKit's glyphs where UXKit draws."
---

`UXIcon` names icons in a way every platform understands. A toolbar item is
given a name with [`UXToolbar.setItemIcon`](/compiler/api/uxkit/uxtoolbar/#setitemicon),
and each backend shows the platform's own picture for it:

| Backend | Picture |
|---|---|
| macOS, iOS | the SF Symbol |
| Android | the system drawable |
| Windows, GTK, GEM, the web | UXKit's 16-pixel glyph |

A name with no picture on a platform shows the item's label alone. From 0.73.

```c
#use <UXKit>     // or #import "UXIcon.xc"
```

## The names

| Name | SF Symbol | Android drawable |
|---|---|---|
| `new` | `doc.badge.plus` | `ic_menu_add` |
| `open` | `folder` | `ic_menu_upload` |
| `save` | `square.and.arrow.down` | `ic_menu_save` |
| `delete` | `trash` | `ic_menu_delete` |
| `cut` | `scissors` | none |
| `copy` | `doc.on.doc` | none |
| `paste` | `doc.on.clipboard` | none |
| `undo` | `arrow.uturn.backward` | `ic_menu_revert` |
| `redo` | `arrow.uturn.forward` | none |
| `add` | `plus` | `ic_input_add` |
| `remove` | `minus` | `ic_input_delete` |
| `play` | `play.fill` | `ic_media_play` |
| `pause` | `pause.fill` | `ic_media_pause` |
| `stop` | `stop.fill` | none |
| `back` | `chevron.backward` | `ic_media_previous` |
| `forward` | `chevron.forward` | `ic_media_next` |
| `search` | `magnifyingglass` | `ic_menu_search` |
| `settings` | `gearshape` | `ic_menu_preferences` |
| `info` | `info.circle` | `ic_menu_info_details` |
| `share` | `square.and.arrow.up` | `ic_menu_share` |
| `print` | `printer` | none |
| `refresh` | `arrow.clockwise` | `ic_menu_rotate` |
| `edit` | `pencil` | `ic_menu_edit` |
| `close` | `xmark` | `ic_menu_close_clear_cancel` |
| `folder` | `folder` | `ic_menu_upload` |

UXKit draws a glyph for every name.

## Topics

[isKnown](#isknown) · [indexOf](#indexof) · [nameAt](#nameat) · [sfSymbol](#sfsymbol) · [androidDrawable](#androiddrawable) · [win32Std](#win32std) · [draw](#draw)

### isKnown

```c
static bool isKnown(u8* name)
```

Whether `name` is one of the names above.

### indexOf

```c
static i32 indexOf(u8* name)
```

The name's place in the table, or `-1`.

### nameAt

```c
static u8* nameAt(i32 k)
```

The `k`th name, for `k` from `0` to `24`.

### sfSymbol

```c
static u8* sfSymbol(u8* name)
```

The SF Symbol for a name, or `""`.

### androidDrawable

```c
static u8* androidDrawable(u8* name)
```

The field of `android.R.drawable` for a name, or `""`.

### win32Std

```c
static i32 win32Std(u8* name)
```

The Windows common-control standard bitmap (`STD_*`) for a name, or `-1`.

### draw

```c
static bool draw(UXGraphics* g, u8* name, i32 x, i32 y, i32 pen)
```

Draws UXKit's 16-pixel glyph for a name at `(x, y)` in `pen`. `false`, and
nothing drawn, for a name not in the table.
