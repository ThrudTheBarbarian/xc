---
title: UXRscDoc
description: "A .rsc document in memory: its trees, its forms and their layout themes, and the rsc graph of class overrides, top-level objects and connections."
---

`UXRscDoc` is a GEM resource held as objects: what Rocks edits and what
[`UXRsc`](/compiler/api/uxkit/uxrsc/) loads from. From 0.7 (earlier it was
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

Beside the trees is the **rsc graph**:

| field | |
| --- | --- |
| `classOverrides` | [`UXRscClassOverride`](#uxrscclassoverride): a control whose class is not the one its GEM type implies |
| `topObjects` | [`UXRscTopObject`](#uxrsctopobject): the non-view objects a form loads with |
| `connections` | [`UXRscConnection`](/compiler/api/uxkit/uxrscconnection/): outlets and actions, each scoped to layout themes |
| `extSections` | [`UXRscExtSection`](#uxrscextsection): chunk sections this build does not interpret, kept for re-saving |
| `ownerClass` | File's Owner's class, so a designer can list its outlets and actions; "" when unset |
| `attrs` | [`UXRscAttr`](#uxrscattr): settings a control has no `OBJECT` field for, such as a slider's range |

On disk the trees are a classic `.rsc`, readable by any GEM AES, and the graph
is the rsc chunk after them.

## Topics

[treeCount](#treecount) · [treeAt](#treeat) · [deepCopy](#deepcopy) · [formIdOf](#formidof) · [ensureLogicalId](#ensurelogicalid) · [refFor](#reffor) · [classOf](#classof) · [setClassOf](#setclassof) · [addTopObject](#addtopobject) · [topObjectById](#topobjectbyid) · [removeTopObject](#removetopobject) · [removeConnectionsTo](#removeconnectionsto) · [refHits](#refhits) · [attrIn](#attrin) · [setAttrIn](#setattrin) · [attrOf](#attrof) · [setAttrOf](#setattrof) · [seq](#seq) · [addTree](#addtree) · [indexOfTree](#indexoftree) · [formCount](#formcount) · [formAt](#format) · [formOf](#formof) · [formById](#formbyid) · [addVariant](#addvariant) · [variantSuffix](#variantsuffix) · [emptyDialog](#emptydialog) · [flatten](#flatten)

### deepCopy

```c
UXRscDoc* deepCopy(void)
```

A copy that can be edited without touching the original: every tree, form and
rsc-graph record is new. Strings and image bytes are shared, because an edit
replaces them instead of writing into them. An editor keeps these for undo.

### formIdOf

```c
i32 formIdOf(UXRscTree* t)
```

The id a tree's form is loaded by: its form's, or for a tree in no form the
tree's own index.

### ensureLogicalId

```c
i32 ensureLogicalId(UXRscTree* t, UXRscObject* o)
```

The control's logical id, giving it one first if it has none. A new id is
unused in every layout of the form.

### refFor

```c
UXRscRef* refFor(UXRscTree* t, UXRscObject* o)
```

A reference to a control by logical id, which holds in every layout of its
form. A connection or a class override names a control this way.

### classOf

```c
u8* classOf(UXRscTree* t, UXRscObject* o)
```

The class the document gives a control, or null for the one its type implies
([`UXRsc.defaultClassFor`](/compiler/api/uxkit/uxrsc/#defaultclassfor)).

### setClassOf

```c
void setClassOf(UXRscTree* t, UXRscObject* o, u8* cls)
```

Gives a control a class. Null or "" removes the override.

### addTopObject

```c
UXRscTopObject* addTopObject(u8* cls, u8* label)
```

Adds one of the document's objects, with the next free id.

### topObjectById

```c
UXRscTopObject* topObjectById(i32 id)
```

### removeTopObject

```c
void removeTopObject(i32 id)
```

Removes the object and every connection to or from it.

### removeConnectionsTo

```c
void removeConnectionsTo(UXRscRef* r)
```

Removes every connection with `r` at either end.

### refHits

```c
static bool refHits(UXRscRef* a, UXRscRef* r)
```

Whether `a` names what `r` names.

### attrIn

```c
u8* attrIn(i32 formId, i32 logicalId, i32 theme, u8* key)
```

A control's attribute in a theme: the theme's own value if it varies it, else
the shared one, else null. `theme` is a theme bit, or `UXR_ATTR_SHARED`.

### setAttrIn

```c
void setAttrIn(i32 formId, i32 logicalId, i32 theme, u8* key, u8* value)
```

Sets it; null removes it.

### attrOf

```c
u8* attrOf(UXRscTree* t, UXRscObject* o, u8* key)
```

The shared value, for a control in a tree.

### setAttrOf

```c
void setAttrOf(UXRscTree* t, UXRscObject* o, u8* key, u8* value)
```

Sets the shared value, giving the control a logical id if it has none.

### seq

```c
static bool seq(u8* a, u8* b)
```

Whether two C strings are equal.

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

## UXRscAttr

`formId`, `logicalId`, `theme`, `key` and `value`: one setting of a control,
kept in the chunk's `ATTR` section. Values are text. A record whose `theme` is
a theme bit is that layout's variation of the setting.

## UXRscExtSection

`tag` and `body`: a chunk section kept as it was read.

## See also

- [`UXRscReader`](/compiler/api/uxkit/uxrscreader/) and
  [`UXRscWriter`](/compiler/api/uxkit/uxrscwriter/)
- [`UXRscConnection`](/compiler/api/uxkit/uxrscconnection/)
- [`UXRsc`](/compiler/api/uxkit/uxrsc/)
