---
title: UXNib
description: "A .rsc file is the nib, and it is live: there is no inflation step. Load a tree, bind views onto it, and wire outlets and actions by name."
---

`UXNib` loads an interface from a `.rsc` file. The rest of the design follows
from one property: **there is no inflation step**.

```c
#use <UXKit>            // or #import "UXNib.xc"
```

## Overview

A GEM resource already contains an `OBJECT` tree, and a
[`UXView`](/compiler/api/uxkit/uxview/) is *backed by* an `OBJECT`. Loading a
nib means loading that tree and binding a view onto each entry. Nothing is
copied or rebuilt, and on GEM the AES walks the resource's own array
directly.

```
Rocks (macOS)  --writes-->  app.rsc  --load-->  OBJECT[]  --bind-->  UXViewTree
```

The resource editor **is** the interface builder. A dialog designed there
becomes a live view hierarchy with no conversion, rather than a description
that a loader reconstructs.

```c
UXViewTree* tree = UXNib.load((u8*)"app.rsc", 0);      // tree 0 of the file
```

Views are chosen by `ob_type`. The resource supplies the **type, frame, flags
and state**; your code supplies the **behaviour**.

## Wiring by name

Loading gives you a hierarchy. Connecting it to a controller is the other half,
and it needs no per-application code:

```c
UXViewTree* tree = UXNib.loadWired((u8*)"app.rsc", 0, (UXDesignable*)controller);
```

`loadWired` reaches your controller through
[`UXDesignable`](/compiler/api/uxkit/uxdesignable/) and connects the nib's
outlets and actions **by name**.

### Your controller declares, the compiler generates

```c
class MainController : Object
{
    outlet UXLabel*  statusLabel;
    outlet UXView*   canvas;

    void onSave(UXControl* sender) :action { … }
    void onQuit(UXControl* sender) :action { … }
}
```

Declaring any `outlet` field or `:action` method **auto-conforms** the class to
`UXDesignable`, and the compiler generates both method bodies from the
decorations:

- `setOutlet(name, value)`: a checked assignment per outlet, returning false on
  an unknown name or a type mismatch
- `wireAction(name, control)`: `control.setAction(&self.<method>)` per action

There is no reflection beyond what the decorations declare, and the
compiler checks every connection. A nib naming an outlet your controller does
not have fails at load with a false return, instead of leaving a null
field that crashes later.

:::tip[Build the same wiring in code and the nib path stays honest]
A hand-written builder that assigns `c.canvas = view;` directly and a nib both
produce a working window, but only the builder is exercised until a nib
ships. Drive the **same two protocol methods** from your code path:

```c
c.setOutlet((u8*)"canvas", (Object*)view);
c.wireAction((u8*)"onSave", saveButton);
```

The code path is then a hand-written nib. Every wiring name is one a nib will
later carry as data, and a typo fails in both.
:::

## Topics

[load](#load) · [loadWired](#loadwired) · [loadWiredMem](#loadwiredmem) · [loadDoc](#loaddoc) · [viewForType](#viewfortype) · [make](#make) · [registerViewFactory](#registerviewfactory) · [registerObjectFactory](#registerobjectfactory) · [classOverride](#classoverride)

### load

```c
static UXViewTree* load(u8* path, i32 treeIndex)
```

Loads one tree from a `.rsc` file and binds views onto it. A resource holds
several trees (a dialog, a menu, an about box), addressed by index.

### loadWired

```c
static UXViewTree* loadWired(u8* path, i32 treeIndex, UXDesignable* owner)
```

`load`, then connect outlets and actions on `owner` by name.

### loadWiredMem

```c
static UXViewTree* loadWiredMem(u8* data, i32 len, i32 treeIndex, UXDesignable* owner)
```

The same from bytes already in memory: a resource compiled into the binary, or
fetched rather than read from disk.

### loadDoc

```c
static UXViewTree* loadDoc(pointer doc, i32 treeIndex, UXDesignable* owner)
```

From an already-parsed document, when you load several trees out of one
file and do not want to re-read it per tree.

### viewForType

```c
static UXView* viewForType(u16 gtype)
```

The default type-to-view mapping: `G_BUTTON` becomes a
[`UXButton`](/compiler/api/uxkit/uxbutton/), `G_FTEXT` a
[`UXTextField`](/compiler/api/uxkit/uxtextfield/), and so on.

### registerViewFactory

```c
static void registerViewFactory(pointer fn)
```

Overrides the mapping, so a resource object can become **your** view subclass
instead of the stock one. A custom widget designed in the editor comes back
this way as the class that implements it.

### registerObjectFactory

```c
static void registerObjectFactory(pointer fn)
```

The same for non-view objects named by the nib.

### make

```c
static Object* make(u8* cls)
```

Instantiates by class name, through the registered factory.

### classOverride

```c
static u8* classOverride(pointer doc, i32 ncl, i32 tree, i32 obj)
```

The class name a resource records for a particular object, when it wants
something other than the default for that type. This is the stored form of
"this button is a `FancyButton`".

## Two things to know before you rely on it

**The resource owns the layout; you own the behaviour.** Frames, flags and
initial state come from the file, so moving a control is an edit in the editor
instead of a recompile. Anything you set in code after load is overwritten
on the next load, because the file is the source of truth for those fields.

**A tree index is positional.** Trees are addressed by number, not name, because
`.rsc` does not store tree names. If you delete a tree in the editor, every index
after it shifts. Rocks renumbers the links it owns, but you must keep any index
hard-coded in your source correct.

## See also

- [`UXDesignable`](/compiler/api/uxkit/uxdesignable/): the two generated
  methods, and the `outlet` / `:action` decorations
- [`UXNibV2`](/compiler/api/uxkit/uxnibv2/): the newer format, with variants
  per form factor
- [`UXViewTree`](/compiler/api/uxkit/uxviewtree/): what a load produces
- [`UXView`](/compiler/api/uxkit/uxview/): `adoptObject`, the binding step
