---
title: UXRscConnection
description: "One outlet or action in a nib, and the layout themes it binds in."
---

A connection from a [`UXRscDoc`](/compiler/api/uxkit/uxrscdoc/)'s nib graph.
From 0.67.

```c
#import "UXRscModel.xc"
```

## Overview

| field | |
| --- | --- |
| `kind` | `UXR_CONN_OUTLET`: `src.member = dst`. `UXR_CONN_ACTION`: the control `src` fires `dst.member` |
| `src`, `dst` | the two ends, as [`UXRscRef`](/compiler/api/uxkit/uxrscdoc/#uxrscref)s |
| `member` | the outlet or action name |
| `scope` | the layout themes it binds in; 0 for all |

A theme is a form factor and an orientation. `scope` has one bit per theme, and
`themeBit` gives it:

```c
c.scope = UXRscConnection.themeBit(UXR_V_PHONE, UXR_V_ORIENT_PORTRAIT) |
          UXRscConnection.themeBit(UXR_V_PHONE, UXR_V_ORIENT_LANDSCAPE);
```

One member may have several connections with different scopes, so a phone and
a desktop can fire the same action from different controls.

## Topics

[themeBit](#themebit) · [inScope](#inscope)

### themeBit

```c
static u32 themeBit(i32 klass, i32 orient)
```

The scope bit for one theme: bit `klass * 3 + orient`.

### inScope

```c
bool inScope(i32 klass, i32 orient)
```

Whether the connection binds in a theme.

## See also

- [`UXNib`](/compiler/api/uxkit/uxnib/#connections-per-layout-theme)
