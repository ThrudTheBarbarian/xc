---
title: UXDesignable
description: "The nib wiring protocol. Declare an outlet or an :action and the compiler generates both methods for you, with connections by name checked at compile time."
---

`UXDesignable` is how a loaded nib connects itself to your controller. It has
two methods, and **you do not write either of them**.

```c
#use <UXKit>            // or #import "UXDesignable.xc"
```

## Overview

```c
protocol UXDesignable {
    bool setOutlet(u8* name, Object* value);
    bool wireAction(u8* name, UXControl* control);
}
```

A class that declares any `outlet` field or `:action` method **auto-conforms**,
and the compiler generates both bodies from the decorations:

```c
class MainController : Object
{
    outlet UXLabel* statusLabel;
    outlet UXView*  canvas;

    void onSave(UXControl* sender) :action { … }
    void onQuit(UXControl* sender) :action { … }
}
```

That class now answers `setOutlet("canvas", …)` and `wireAction("onSave", …)`
with no further code. Writing `: Object <UXDesignable>` by hand is equivalent;
either way the compiler generates the bodies.

[`UXNib.loadWired`](/compiler/api/uxkit/uxnib/) uses these two methods to
connect a resource's outlets and actions by name.

## Why this and not reflection

xc has no reflection, no selectors and no message forwarding, so a nib cannot
look up a field by string at run time the way Cocoa does. The information a nib
needs is **declared** (`outlet`, `:action`) and the lookup is **generated** from
those declarations.

This has three benefits:

- A misspelled outlet in your source is a **compile** error, not a nil field
  that crashes at first use.
- A nib naming an outlet your controller does not have returns `false` at
  **load**, so a mis-wired interface fails where you can see it.
- There is no run-time cost beyond a string compare, and no metadata to keep in
  step with the code.

## Topics

[setOutlet](#setoutlet) · [wireAction](#wireaction)

### setOutlet

```c
bool setOutlet(u8* name, Object* value)
```

Assigns the named `outlet` field with a **checked cast**. Returns `false` for an
unknown name or a type mismatch, so connecting a `UXButton` to an outlet
declared `UXLabel*` fails instead of corrupting the field.

### wireAction

```c
bool wireAction(u8* name, UXControl* control)
```

Binds the named `:action` method to the control: `control.setAction(&self.<method>)`,
performed **inside this call**. Returns `false` for an unknown name.

:::note[Why it binds rather than returning a callback]
The obvious signature would return a callback for the caller to install. That
return type cannot be written at present: a callback return does not parse, and
a reference to one does not round-trip. A callback held as a **local**, which is
all `wireAction` needs internally, works, so the binding happens here.
:::

## Using it from code, so the nib path stays honest

This protocol is useful even if you never load a nib. A hand-written builder can
call the **same two methods** instead of assigning fields directly.

```c
// Not this — it works, and it exercises nothing a nib will use:
c.canvas = view;

// This — the code path becomes a hand-written nib:
if (!c.setOutlet((u8*)"canvas", (Object*)view))   { return false; }
if (!c.wireAction((u8*)"onSave", saveButton))     { return false; }
```

Written the second way, every wiring name in your builder is one a nib will
later carry as data, and a typo fails in **both** paths. Written the first way,
the nib path is never exercised, and its errors surface only when a nib is first
loaded.

Rocks builds its own main window this way. The builder is a nib written in code,
so replacing it with `UXNib.loadWired` later changes one file and nothing else.

## See also

- [`UXNib`](/compiler/api/uxkit/uxnib/): loads a resource and calls these two
  methods
- [`UXNibV2`](/compiler/api/uxkit/uxnibv2/): the newer format
- [`UXControl`](/compiler/api/uxkit/uxcontrol/): what `wireAction` calls
  `setAction` on
- [Bound methods and callbacks](/compiler/language/bound-methods/): what
  `&self.onSave` is
