---
title: UXPasteboard
description: "A typed pasteboard: one payload per type, so a copy offers several forms and a paste takes the richest it understands."
---

`UXPasteboard` holds **one payload per type**, so a copy can offer the same
content several ways and a paste can take the richest form it understands. It
has the shape of `NSPasteboard` and is the basis of both copy/paste and drag and
drop.

```c
#use <UXKit>            // or #import "UXPasteboard.xc"
```

## Overview

```c
UXPasteboard* pb = UXPasteboard.general();     // the clipboard

pb.clearContents();
pb.setString((u8*)"<b>Report</b>", (u8*)"public.html");
pb.writeText((u8*)"Report");                    // public.utf8-plain-text
```

Both forms are now on the board. What comes back depends on what the *reader*
can handle, not on the order they were written:

```c
pb.preferredType((u8*)"public.html", (u8*)"public.utf8-plain-text")
// -> "public.html"                  an HTML-capable paste

pb.preferredType((u8*)"public.rtf", (u8*)"public.utf8-plain-text")
// -> "public.utf8-plain-text"       a plain-text-only paste
```

A copy that wrote only its richest form would paste as nothing into a
plain-text field. One that wrote only plain text would lose the formatting
everywhere.

Type names are UTIs: `"public.utf8-plain-text"`, `"public.file-url"`, or your
application's own. Nothing validates them; the contract is an agreed string.

## Topics

[general](#general) · [setString](#setstring) · [writeText](#writetext) · [stringForType](#stringfortype) · [text](#text) · [hasType](#hastype) · [preferredType](#preferredtype) · [typeCount](#typecount--typeat) · [typeAt](#typecount--typeat) · [clearContents](#clearcontents) · [entryForType](#entryfortype)

### general

```c
static UXPasteboard* general(void)
```

The shared clipboard, made on first use.

**A drag does not use this.** A drag session carries its own fresh pasteboard,
so dragging something never destroys what the user copied earlier. See
[`UXDragSession`](/compiler/api/uxkit/uxdragsession/).

### setString

```c
void setString(u8* s, u8* type)
```

Write one payload under one type. Writing a type that is already present
replaces it.

### writeText

```c
void writeText(u8* s)
```

Shorthand for `setString(s, "public.utf8-plain-text")`. Almost everything can
read this form, so write it alongside any richer one.

### stringForType

```c
u8* stringForType(u8* type)       // 0 when absent
```

An absent type returns null instead of an error, so the only guard needed is a
check of the result.

### text

```c
u8* text(void)
```

Shorthand for the plain-text payload.

### hasType

```c
bool hasType(u8* type)
```

Whether a type is on offer. A drag destination asks this cheap question on every
pointer move; see
[`UXDragDestination`](/compiler/api/uxkit/uxdragdestination/).

### preferredType

```c
u8* preferredType(u8* a, u8* b)   // 0 when neither is present
```

The richer of two types, preferring `a`. This covers richest-first paste in the
common two-way case; for more than two, ask `hasType` in your own order of
preference.

### typeCount / typeAt

```c
i32 typeCount(void)
u8* typeAt(i32 i)
```

Enumerate what is on offer, for a paste-special menu or for debugging what a
copy wrote.

### clearContents

```c
void clearContents(void)
```

:::caution[Clearing is a write]
`clearContents` drops every type **and bumps the change count**, as
`NSPasteboard` does. The sequence for a copy is clear-then-write, and an observer
watching `changeCount` sees the clear as activity in its own right.
:::

### entryForType

```c
UXPasteboardEntry* entryForType(u8* type)
```

The raw entry, when you want the type and data together.

## changeCount

```c
i32 changeCount
```

Ticks on every write. Use it to notice that **someone else** wrote to the
clipboard since you last looked. A paste menu item that greys itself, or a panel
that refreshes a preview, reads this instead of polling contents.

## Example

```
types offered: 2
  public.html
  public.utf8-plain-text
an HTML-capable paste takes:   public.html            -> <b>Report</b>
a plain-text-only paste takes: public.utf8-plain-text -> Report
has public.file-url: no  value: (null)
after clear: types=0  change count 3 -> 4
drag pasteboard is separate: clipboard types=0  drag types=1
```

The program is `website/site/examples/uxkit/pasteboard.xc`. The `doc-examples`
gate compiles it, and the output above is what it prints.

## Data is string-typed

Payloads are strings: text, serialized forms, URLs. Raw bytes are not supported
yet, so binary content needs an encoding you choose (and a type name that says
so).

## See also

- [`UXDragSession`](/compiler/api/uxkit/uxdragsession/): carries one of these
  through a drag
- [`UXDragDestination`](/compiler/api/uxkit/uxdragdestination/): asks
  `hasType` to decide whether it can accept a drop
- [`UXPasteboardEntry`](/compiler/api/uxkit/uxpasteboardentry/): one type and
  its payload
