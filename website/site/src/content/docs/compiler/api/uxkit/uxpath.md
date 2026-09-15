---
title: UXPath
description: "A slash-separated path as a value: split it, rebuild it, take its extension, and resolve '.' and '..' by text alone, without touching the filesystem."
---

`UXPath` is a filesystem path held as **components** instead of a string:
`"/usr/local/bin"` is three names plus the fact that it began with `/`.

All of its work is string work. Nothing here opens, stats or resolves anything on
disk, so it is fully testable and safe to use on a path that does not exist yet.

```c
#use <UXKit>            // or #import "UXPath.xc"
```

## Overview

```c
UXPath* p = UXPath.parse((u8*)"/usr/local/share/fonts/system.fnt");

p.count();                      // 5
p.isAbsolute();                 // true
p.lastComponent();              // "system.fnt"
p.pathExtension();              // "fnt"
p.lastComponentWithoutExtension();   // "system"
p.toString();                   // back to "/usr/local/share/fonts/system.fnt"
```

It has the shape of `NSString`'s path category, and it feeds the breadcrumb bar
([`UXPathComp`](/compiler/api/uxkit/uxpathcomp/) is one crumb) and file
navigation.

## Parsing tidies as it goes

Empty components are dropped, so doubled and trailing separators do not survive
the round trip:

```c
UXPath.parse((u8*)"//usr//local///bin/").toString();   // "/usr/local/bin"
```

`parse` → `toString` is therefore a **separator normalizer**. Use it when
comparing two paths from different sources, such as one typed and one built by
concatenation.

The leading `/` is not a component; it is the separate `absolute` flag. An
absolute path and a relative one with the same names differ in a field, not in
the array, and `count()` never counts a phantom empty first element.

`parse` **copies** the bytes of each component, so the string you passed in can
go away afterwards.

## Every mutator returns a new path

```c
UXPath* dir  = p.deletingLastComponent();          // /usr/local/share/fonts
UXPath* next = dir.appendingComponent((u8*)"mono.fnt");
// p is unchanged
```

`UXPath` behaves as a **value**: nothing mutates the receiver. A caller you hand
a path to cannot alter it, and a chain of derivations needs no defensive copies.

## Extensions split at the last dot

```c
UXPath.parse((u8*)"backup.tar.gz").pathExtension();               // "gz"
UXPath.parse((u8*)"backup.tar.gz").lastComponentWithoutExtension(); // "backup.tar"
```

The **last** dot splits, not the first, so `stem + "." + ext` always rebuilds the
name. A double extension keeps its first half in the stem, which suits a Save
panel that replaces `.gz` with something else.

:::note[A leading dot is a hidden file, not an extension]
```c
UXPath.parse((u8*)"/home/user/.profile").pathExtension();   // ""
UXPath.parse((u8*)"/home/user/.profile")
      .lastComponentWithoutExtension();                     // ".profile"
```
`.profile` is a name that starts with a dot, not an empty name with a `profile`
extension. Reading it the other way leads a file manager to offer to rename a
dotfile to nothing.

A **trailing** dot is not an extension either: `"archive."` has none.
:::

## Normalizing is textual, and knows about the root

```c
UXPath.parse((u8*)"/a/b/./c/../../d").normalized();   // "/a/d"
```

`.` is dropped and `..` pops the component before it. The two edge cases are at
the ends:

```c
UXPath.parse((u8*)"/../../etc").normalized();       // "/etc"
UXPath.parse((u8*)"../../etc/passwd").normalized(); // "../../etc/passwd"
```

At the **root**, `..` has nowhere to go and is discarded, as a real filesystem
treats `/..` as `/`. In a **relative** path a leading `..` is kept, because
`../sibling` has meaning and dropping it would change where the path points.
This asymmetry makes `normalized` safe to run on either kind.

:::caution[It resolves text, not symlinks]
`normalized` never touches the disk, so it is not `realpath`. Where a component
is a symlink, `a/link/..` textually becomes `a`, while the filesystem would take
you to the parent of the link's *target*.

That suits a path bar, a comparison or a display, all of which must work for
paths that do not exist. When you need the state on disk, ask the filesystem.
:::

## Topics

[parse](#parse) · [count](#count) · [component](#component) · [lastComponent](#lastcomponent) · [isAbsolute](#isabsolute) · [toString](#tostring) · [copy](#copy) · [appendingComponent](#appendingcomponent) · [deletingLastComponent](#deletinglastcomponent) · [pathExtension](#pathextension) · [lastComponentWithoutExtension](#lastcomponentwithoutextension) · [normalized](#normalized) · [addComp](#addcomp)

### parse

```c
static UXPath* parse(u8* s)
```

Split a string. Empty components are dropped; a leading `/` sets
[`isAbsolute`](#isabsolute). Copies the bytes.

### count

```c
i32 count(void)
```

How many components. `0` for both `"/"` and `""`; [`isAbsolute`](#isabsolute)
tells them apart.

### component

```c
u8* component(i32 i)
```

One component by index, without separators.

### lastComponent

```c
u8* lastComponent(void)
```

The filename. `""` instead of null when there are no components, so it is
always safe to print.

### isAbsolute

```c
bool isAbsolute(void)
```

Whether the path began with `/`. Every derivation preserves it.

### toString

```c
u8* toString(void)
```

Rebuild, joining with `/` and restoring the leading one. Returns `"/"` for an
absolute empty path and `""` for a relative one.

### copy

```c
UXPath* copy(void)
```

A new path with the same components and flag.

:::note
The copy **shares** the component buffers instead of duplicating them. This is
safe because nothing in this class writes through a component pointer. Do not
write through one yourself.
:::

### appendingComponent

```c
UXPath* appendingComponent(u8* c)
```

A new path with one more name on the end. Copies `c`, so a stack buffer is fine.

### deletingLastComponent

```c
UXPath* deletingLastComponent(void)
```

The parent directory. An already-empty path stays empty; there is no error.

### pathExtension

```c
u8* pathExtension(void)
```

The text after the final dot in the last component, or `""`. See
[above](#extensions-split-at-the-last-dot) for dotfiles and trailing dots.

### lastComponentWithoutExtension

```c
u8* lastComponentWithoutExtension(void)
```

The last component with its extension removed: the other half of the split.

### normalized

```c
UXPath* normalized(void)
```

Resolve `.` and `..` by text. See
[above](#normalizing-is-textual-and-knows-about-the-root).

### addComp

```c
void addComp(u8* s)
```

Append in place, **taking the pointer** instead of copying it. [`parse`](#parse)
is built on this. Prefer [`appendingComponent`](#appendingcomponent), which
copies and does not mutate.

## Example

```
parsed:       '/usr/local/share/fonts/system.fnt'  count=5 abs=1
last=system.fnt ext=fnt stem=system
messy:        '/usr/local/bin'  count=3 abs=1
dir:          '/usr/local/share/fonts'  count=4 abs=1
sibling:      '/usr/local/share/fonts/mono.fnt'  count=5 abs=1
original:     '/usr/local/share/fonts/system.fnt'  count=5 abs=1
tar.gz: ext=gz stem=backup.tar
dotfile: ext='' stem=.profile
abs before:   '/a/b/./c/../../d'  count=7 abs=1
abs after:    '/a/d'  count=2 abs=1
above root:   '/etc'  count=1 abs=1
relative:     '../../etc/passwd'  count=4 abs=0
rel mixed:    '../b'  count=2 abs=0
```

The program is `website/site/examples/uxkit/paths.xc`. The `doc-examples` gate
compiles it, and the output above is what it prints. It boots no driver and
touches no disk.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXPathComp`](/compiler/api/uxkit/uxpathcomp/): one component
- [`UXURL`](/compiler/api/uxkit/uxurl/): the same job for URLs; `file:` is
  the bridge between them
- [`UXFilePanel`](/compiler/api/uxkit/uxfilepanel/): where paths come from
