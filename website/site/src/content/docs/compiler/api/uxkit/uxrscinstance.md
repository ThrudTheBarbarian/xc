---
title: UXRscInstance
description: "One loaded form: its root view, its views by logical id, its top-level objects, and what happened to its connections."
---

A `UXRscInstance` is what [`UXRsc.load`](/compiler/api/uxkit/uxrsc/#load)
returns. From 0.7.

```c
#import "UXRsc.xc"
```

## Overview

```c
UXRscInstance* ni = UXRsc.load(bytes, len, FORM_TRANSPORT, (UXDesignable*)self, window.contentView);
UXButton* play = (UXButton* ?)ni.viewForLogical(PLAY);
```

Outlets are the usual way to reach a loaded control. The instance is for code
that needs more: a test asserting what loaded, or a tool listing a form's views.

| field | |
| --- | --- |
| `root` | the form's root view, the size of its root box |
| `viewTree` | the view tree the form lives in when it was loaded with no container; null otherwise |
| `tree` | the layout that loaded |
| `formId` | the form |
| `klass`, `orient` | the theme the layout was drawn for: `UX_FORM_*` and `UX_ORIENT_*` |
| `bound` | connections made |
| `skipped` | connections in scope that did not bind, usually because the layout leaves out one end |
| `outOfScope` | connections scoped to other themes |

`klass` can differ from the device's form factor: a tablet loading a form that
has only a desktop layout reports the desktop.

## Topics

[viewFor](#viewfor) · [viewForLogical](#viewforlogical) · [topObjectCount](#topobjectcount) · [topObjectAt](#topobjectat) · [topObject](#topobject)

### viewFor

```c
UXView* viewFor(UXRscObject* o)
```

The view built for an object of the loaded layout, or null.

### viewForLogical

```c
UXView* viewForLogical(i32 logicalId)
```

The view for a control by logical id, or null when this layout leaves it out.
The same id names the control in every layout.

### topObjectCount

```c
i32 topObjectCount(void)
```

How many top-level objects the load made.

### topObjectAt

```c
Object* topObjectAt(i32 i)
```

A top-level object by position.

### topObject

```c
Object* topObject(i32 id)
```

A top-level object by the id the document gives it, or null.

## See also

- [`UXRsc`](/compiler/api/uxkit/uxrsc/)
