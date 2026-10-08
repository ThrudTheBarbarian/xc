---
title: UXRsc
description: "Load a form from a .rsc document as UXKit views on every backend: the layout for this device, the connections in its scope, the top-level objects, and awakeFromRsc."
---

`UXRsc` loads a form designed in Rocks and gives you its views, already wired
to your code. It runs on every backend. From 0.7.

```c
#import "UXRsc.xc"
```

## Overview

```c
UXRscInstance* ni = UXRsc.load(bytes, len, FORM_TRANSPORT, (UXDesignable*)self, window.contentView);
```

One call does five things:

1. **Picks the layout.** A form can have a layout per form factor (desktop,
   tablet, phone) and, on a device, per orientation. The loader asks the driver
   which this device is and walks the fallback chain described on
   [`UXRscV2`](/compiler/api/uxkit/uxrscv2/#variant-selection-walks-a-chain).
2. **Builds the views.** Each object in that layout becomes a UXKit control:
   `G_BUTTON` a [`UXButton`](/compiler/api/uxkit/uxbutton/), `G_FTEXT` a
   [`UXTextField`](/compiler/api/uxkit/uxtextfield/), and so on. A control the
   document gives a class of its own (a `G_USERDEF` that is a `WaveformView`)
   becomes that class.
3. **Makes the top-level objects**: the controllers and other non-view objects
   the document lists.
4. **Binds the connections in scope.** Each outlet or action names the layout
   themes it applies to. Only those whose scope includes the loaded theme are
   bound, and only when both ends exist in that layout.
5. **Sends `awakeFromRsc`** to every object it made that conforms to
   [`UXRscAwaking`](/compiler/api/uxkit/uxrscawaking/), then to File's Owner.

The result is a [`UXRscInstance`](/compiler/api/uxkit/uxrscinstance/): the root
view, the views by logical id, the top-level objects, and counts of what bound.

Rocks builds its canvas with the same [`viewFor`](#viewfor), so what the
designer shows is what an app loads.

## Connections per layout theme

The same outlet or action can be connected differently in different layouts.
On a desktop, `showDetail` might be fired by a list's selection; on a phone,
by a toolbar button. Both are connections to `showDetail`, each scoped to its
own themes:

| connection | scope | binds on |
| --- | --- | --- |
| list selection → `showDetail` | desktop, tablet | desktop, tablet |
| toolbar button → `showDetail` | phone | phone |
| `nameField` outlet | all | every layout that has the field |

A connection with scope "all" binds in every layout. A connection whose control
a layout leaves out is skipped there, which is how a phone layout drops a
control.

## Where the views go

Pass a container, usually a window's content view, and the form's root view is
added to it at its origin. Pass null and the form gets a
[`UXViewTree`](/compiler/api/uxkit/uxviewtree/) of its own, held by the
instance.

## Topics

[load](#load) · [loadDoc](#loaddoc) · [loadDocAs](#loaddocas) · [selectTree](#selecttree) · [viewFor](#viewfor) · [defaultClassFor](#defaultclassfor) · [classFor](#classfor) · [applyState](#applystate) · [applyText](#applytext) · [textOf](#textof) · [typeName](#typename) · [make](#make) · [makeUXKit](#makeuxkit) · [applyAttrs](#applyattrs) · [autoresizeOf](#autoresizeof) · [attrInt](#attrint) · [eachPart](#eachpart) · [dateFrom](#datefrom) · [registerObjectFactory](#registerobjectfactory) · [registerViewFactory](#registerviewfactory)

### load

```c
static UXRscInstance* load(u8* bytes, i32 n, i32 formId, UXDesignable* owner, UXView* into)
```

Reads a `.rsc` image and loads form `formId` for this device. `owner` is File's
Owner. Returns null when the bytes are not a resource or there is no such form.

`into` is the view the form is added to, and must be in a window's tree. With
`into` null, the form is built in a [`UXViewTree`](/compiler/api/uxkit/uxviewtree/)
of its own (`viewTree` on the result).

A form's id is the index of its first tree, so a form designed before layout
variants keeps the id it had.

### loadDoc

```c
static UXRscInstance* loadDoc(UXRscDoc* doc, i32 formId, UXDesignable* owner, UXView* into)
```

The same from a document already read with
[`UXRscReader`](/compiler/api/uxkit/uxrscreader/), to load several forms from one
file without reading it again.

### loadDocAs

```c
static UXRscInstance* loadDocAs(UXRscDoc* doc, i32 formId, i32 klass, i32 orient, UXDesignable* owner, UXView* into)
```

Loads for a given theme instead of the device's: `klass` is a `UX_FORM_*` form
factor and `orient` a `UX_ORIENT_*`. Use it in tests and previews.

### selectTree

```c
static UXRscTree* selectTree(UXRscDoc* doc, i32 formId, i32 klass, i32 orient, i32* gotClass, i32* gotOrient)
```

The layout a form loads with for a theme, and the theme that layout was drawn
for. A tablet with only a desktop layout gets the desktop's, and `gotClass`
says so.

### viewFor

```c
static UXView* viewFor(UXRscObject* o, u8* cls)
```

The view for one object. If `cls` names a class a registered factory can make,
that class; otherwise the control for the object's GEM type. A type with no
UXKit equivalent becomes a visible placeholder titled with its class or type,
so a form never has a silent gap.

### defaultClassFor

```c
static u8* defaultClassFor(i32 t)
```

The UXKit class `viewFor` makes for a GEM type when nothing overrides it:
`"UXButton"` for `G_BUTTON`, `"UXView"` for a type with no control of its own.

### classFor

```c
static u8* classFor(UXRscDoc* doc, i32 formId, i32 treeIndex, UXRscObject* o, i32 objIndex)
```

The class the document gives an object, or null. It is looked up by logical
id, so a control is the same class in every layout.

### applyState

```c
static void applyState(UXView* w, UXRscObject* o)
```

Copies an object's state into its view: enabled, hidden, checked, selected and
text alignment.

### applyText

```c
static void applyText(UXView* w, UXRscObject* o)
```

Copies an object's text into the view already built for it, without replacing
the view.

### textOf

```c
static u8* textOf(UXRscObject* o)
```

An object's text: its string, or its `TEDINFO` text, or "".

### typeName

```c
static u8* typeName(i32 t)
```

A short name for a GEM type ("button", "ftext"), for placeholders and outlines.

### make

```c
static Object* make(u8* cls)
```

Makes an object by class name through the registered factories, or returns
null when none knows the name.

### makeUXKit

```c
static Object* makeUXKit(u8* cls)
```

UXKit's controls that GEM has no type for, by class name: `UXSlider`,
`UXStepper`, `UXProgressBar`, `UXSegmentedControl`, `UXComboBox`, and from
0.75 `UXTextView`, `UXDatePicker` and `UXBreadcrumb`. A
document holds one as a `G_USERDEF` of that class, with its settings in
[attributes](/compiler/api/uxkit/uxrscdoc/#uxrscattr). `make` falls back to
this when no registered factory knows the name. From 0.7.

### applyAttrs

```c
static void applyAttrs(UXView* v, UXRscDoc* doc, i32 formId, i32 logicalId, i32 theme)
```

Gives a control its settings from the document's attributes: a slider's
`min`, `max` and `value`; a stepper's and its `step`; a progress bar's `total`
and `completed`; a segmented control's `segments` (`"One|Two|Three"`) and
`selected`; a combo box's `items` and `text`; a text view's `text`,
`fontSize` and `monospace` (1 for on); a date picker's `date`, written
`2026-10-08`; a breadcrumb's `segments` and `separator`. A value the theme varies wins
over the shared one. The loader calls it for every control.

### autoresizeOf

```c
static i32 autoresizeOf(UXRscDoc* doc, i32 formId, i32 logicalId, i32 theme)
```

The autoresize mask the layout gives a control, from its `autoresize` attribute
(see [`UXRscDoc.autoresizeOf`](/compiler/api/uxkit/uxrscdoc/#autoresizeof)), or
0. The loader sets it on every view it makes, the form's root included, so a
loaded form follows its window when that is resized.

### attrInt

```c
static i32 attrInt(UXRscDoc* doc, i32 formId, i32 logicalId, i32 theme, u8* key, i32 dflt)
```

An attribute read as a number, or `dflt`.

### eachPart

```c
static i32 eachPart(u8* list, pointer target, i32 to)
```

Adds each part of `"A|B|C"` to a segmented control (`to` 0), a combo box
(`to` 1) or a breadcrumb (`to` 2); returns how many.

### dateFrom

```c
static UXDate* dateFrom(u8* s)
```

The date a `YYYY-MM-DD` value names, or null when it is empty or not a date.

### registerObjectFactory

```c
static void registerObjectFactory(pointer fn)
```

Adds a factory, a function from a class name to a new object or null. The
compiler generates one for each module that has designable classes and
registers it at load time, so you only call this for a factory you write
yourself. Up to eight are tried in turn, so classes can come from several
libraries.

### registerViewFactory

```c
static void registerViewFactory(pointer fn)
```

The older name for `registerObjectFactory`.

## See also

- [`UXRscInstance`](/compiler/api/uxkit/uxrscinstance/): what a load returns
- [`UXRscAwaking`](/compiler/api/uxkit/uxrscawaking/): finishing setup after
  the outlets are connected
- [`UXDesignable`](/compiler/api/uxkit/uxdesignable/): the `outlet` and
  `:action` decorations the connections bind to
- [`UXRscDoc`](/compiler/api/uxkit/uxrscdoc/): the document model
- [`UXRscGem`](/compiler/api/uxkit/uxrscgem/): the GEM-only loader that binds
  views onto libGEM's own object array
