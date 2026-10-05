---
title: UXRscDoc
description: "A .rsc document in memory: its trees, its forms and their layout themes, and the nib graph of class overrides, top-level objects and connections."
---

`UXRscDoc` is a GEM resource held as objects: what Rocks edits and what
[`UXNib`](/compiler/api/uxkit/uxnib/) loads from. From 0.67 (earlier it was
part of Rocks).

```c
#import "UXRscModel.xc"
```

## Overview

A document is a list of **trees**. Each tree is a root
[`UXRscObject`](#uxrscobject) with nested children, in the classic `OBJECT`
fields: type, flags, state, geometry relative to the parent, and a payload by
type (a string, a `TEDINFO`, a box colour word, an icon).

A **form** is one piece of UI as an application sees it. When a form has more
than one layout, it is a [`UXRscForm`](#uxrscform) whose **variants** each hold
a whole tree for one theme: a form factor and, on a device, an orientation. The
trees are separate designs. What ties them together is the **logical id** each
control carries, which is the same in every layout that has the control.

Beside the trees is the **nib graph**:

| field | |
| --- | --- |
| `classOverrides` | [`UXRscClassOverride`](#uxrscclassoverride): a control whose class is not the one its GEM type implies |
| `topObjects` | [`UXRscTopObject`](#uxrsctopobject): the non-view objects a form loads with |
| `connections` | [`UXRscConnection`](/compiler/api/uxkit/uxrscconnection/): outlets and actions, each scoped to layout themes |
| `extSections` | [`UXRscExtSection`](#uxrscextsection): chunk sections this build does not interpret, kept for re-saving |

On disk the trees are a classic `.rsc`, readable by any GEM AES, and the graph
is the nib chunk after them.

## Topics

[treeCount](#treecount) · [treeAt](#treeat) · [addTree](#addtree) · [indexOfTree](#indexoftree) · [formCount](#formcount) · [formAt](#format) · [formOf](#formof) · [formById](#formbyid) · [addVariant](#addvariant) · [variantSuffix](#variantsuffix) · [emptyDialog](#emptydialog) · [flatten](#flatten)

### treeCount

```c
i32 treeCount(void)
```

### treeAt

```c
UXRscTree* treeAt(i32 i)
```

### addTree

```c
void addTree(UXRscTree* t)
```

### indexOfTree

```c
i32 indexOfTree(UXRscTree* t)
```

A tree's position, which is its index in the written file; -1 if it is not in
this document.

### formCount

```c
i32 formCount(void)
```

The forms with more than one layout. A tree in no form is a form of its own,
with one layout for every theme.

### formAt

```c
UXRscForm* formAt(i32 i)
```

### formOf

```c
UXRscForm* formOf(UXRscTree* t)
```

The form a tree is a layout of, or null.

### formById

```c
UXRscForm* formById(i32 formId)
```

### addVariant

```c
UXRscTree* addVariant(UXRscTree* from, i32 klass, i32 orient)
```

Adds a layout for a theme to `from`'s form, seeded as a copy of `from`. The
copy is a one-time seed: later edits to either layout do not reach the other.
Controls without a logical id get one first. Returns null if the form already
has that theme, or for an orientation on the desktop.

### variantSuffix

```c
static u8* variantSuffix(i32 klass, i32 orient)
```

The suffix a layout's tree name takes after its form's: `_PHONE_P`,
`_TABLET_L`, and so on.

### emptyDialog

```c
static UXRscDoc* emptyDialog(void)
```

A new document with one empty dialog tree.

### flatten

```c
Array<UXRscFlatNode>* flatten(UXRscTree* t)
```

A tree as the classic pre-order array with next, head and tail links, which is
what the writer emits.

## UXRscObject

One object of a tree. `type`, `flags`, `state`, `x`, `y`, `w`, `h`, `text`,
`ted`, `logicalId` and `children` hold what the `OBJECT` holds.

### make

```c
static UXRscObject* make(i32 type, i32 x, i32 y, i32 w, i32 h)
```

### addChild / childAt / childCount

```c
void addChild(UXRscObject* c)
UXRscObject* childAt(i32 i)
i32 childCount(void)
```

### parentOf

```c
UXRscObject* parentOf(UXRscObject* target)
```

### deepCopy

```c
UXRscObject* deepCopy(void)
```

A copy of the object and its children, logical ids included.

### collect

```c
void collect(Array<UXRscObject>* out)
```

The object and its descendants, in pre-order.

### hasStringSpec / hasTedinfo / hasBox / hasIcon / hasBitblk / canHaveChildren

```c
bool hasStringSpec(void)
bool hasTedinfo(void)
bool hasBox(void)
bool hasIcon(void)
bool hasBitblk(void)
bool canHaveChildren(void)
```

Which payload the type carries, and whether it is a container.

### typeHasTedinfo

```c
static bool typeHasTedinfo(i32 t)
```

### seedPayload

```c
void seedPayload(void)
```

Gives a new object the payload its type needs.

## UXRscTree

A named root object and a kind (dialog, menu, free).

### allObjects

```c
Array<UXRscObject>* allObjects(void)
```

Every object in pre-order. An object's position here is its index in the
written tree.

### parentOf

```c
UXRscObject* parentOf(UXRscObject* node)
```

### absoluteOriginOf

```c
bool absoluteOriginOf(UXRscObject* node, i32* ox, i32* oy)
```

### reparentByGeometry

```c
i32 reparentByGeometry(void)
```

Moves each object into the innermost container that holds it, after a drag.

### isMenu

```c
bool isMenu(void)
```

### setNameJoined

```c
void setNameJoined(u8* base, u8* suffix)
```

### len

```c
static i32 len(u8* s)
```

## UXRscForm

A form with several layouts: `formId`, `name`, and `variants`.

### variantCount / variantAt

```c
i32 variantCount(void)
UXRscVariant* variantAt(i32 i)
```

### find

```c
UXRscVariant* find(i32 klass, i32 orient)
```

The layout for one theme, or null.

### variantFor

```c
UXRscVariant* variantFor(UXRscTree* t)
```

### nextLogicalId

```c
i32 nextLogicalId(void)
```

A logical id no layout of the form uses. Ids are not reused.

A `UXRscVariant` is `klass`, `orient` and `tree`.

## UXRscRef

One end of a connection: `space`, `a`, `b`.

| space | | a | b |
| --- | --- | --- | --- |
| `UXR_REF_VIEW` | a control by position, in a form with one layout | tree | object |
| `UXR_REF_TOP` | a top-level object | id | |
| `UXR_REF_OWNER` | File's Owner | | |
| `UXR_REF_FIRSTR` | First Responder | | |
| `UXR_REF_LOGICAL` | a control by logical id | form | logical id |

### make

```c
static UXRscRef* make(i32 space, i32 a, i32 b)
```

### same

```c
bool same(UXRscRef* o)
```

## UXRscClassOverride

`view`, a ref, and `cls`, the class name.

## UXRscTopObject

`id`, `cls`, and `label`, the name the designer shows for it.

## UXRscExtSection

`tag` and `body`: a chunk section kept as it was read.

## See also

- [`UXRscReader`](/compiler/api/uxkit/uxrscreader/) and
  [`UXRscWriter`](/compiler/api/uxkit/uxrscwriter/)
- [`UXRscConnection`](/compiler/api/uxkit/uxrscconnection/)
- [`UXNib`](/compiler/api/uxkit/uxnib/)
