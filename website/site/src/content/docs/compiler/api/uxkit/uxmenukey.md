---
title: UXMenuKey
description: "Reads a menu item's shortcut back out of its driver form, for a driver showing it in its own menus."
---

`UXMenuKey` is for drivers. It reads the shortcut that
[`UXMenuItem.encoded`](/compiler/api/uxkit/uxmenuitem/#encoded) writes after
an item's title: a tab, `+` when Shift is needed, then the key. From 0.67.

```c
#import "UXViewDriver.xc"
```

## Overview

```c
u8* s = items[j];                         // "Redo\t+Z"
u8* title = UXMenuKey.title(s);           // "Redo"
u8 key = UXMenuKey.key(s);                // 'Z'
bool shift = UXMenuKey.shift(s);          // true
u8* w = UXMenuKey.labelled(s, (u8*)"\t", (u8*)"Ctrl+", (u8*)"Shift+");   // "Redo\tShift+Ctrl+Z"
```

## Topics

[tabAt](#tabat) · [key](#key) · [shift](#shift) · [title](#title) · [labelled](#labelled) · [append](#append)

### tabAt

```c
static i32 tabAt(u8* s)
```

Where the shortcut starts, or -1 when there is none.

### key

```c
static u8 key(u8* s)
```

The key, or 0.

### shift

```c
static bool shift(u8* s)
```

### title

```c
static u8* title(u8* s)
```

The text before the shortcut: `s` itself when it has none, otherwise a new
copy.

### labelled

```c
static u8* labelled(u8* s, u8* sep, u8* ctrl, u8* shiftWord)
```

The text with the shortcut spelled out after `sep`, using `ctrl` and
`shiftWord` for the modifiers. Win32 uses `"\t"`, `"Ctrl+"`, `"Shift+"`; GEM
uses two spaces, `"^"` and the system font's up arrow.

### append

```c
static i32 append(u8* b, i32 at, u8* w)
```

Copies `w` into `b` at `at` and returns the new end.

## See also

- [`UXMenuItem`](/compiler/api/uxkit/uxmenuitem/#keyboard-shortcuts)
