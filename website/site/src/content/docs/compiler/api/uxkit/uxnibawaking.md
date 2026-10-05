---
title: UXNibAwaking
description: "awakeFromNib: called on each object a nib load made, and on File's Owner, once every outlet is connected."
---

A protocol for objects that finish setting up after a nib load. From 0.67.

```c
#import "UXNib.xc"
```

## Overview

```c
class LibraryController : Object<UXNibAwaking>
{
    outlet UXTableView* table;

    void awakeFromNib(void)
    {
        table.reloadData();      // the outlet is connected by now
    }
}
```

During `init` a nib-made object's outlets are still null, because the loader
connects them afterwards. [`UXNib`](/compiler/api/uxkit/uxnib/) sends
`awakeFromNib` when every connection of the load is made: first to the
top-level objects, then to the views, then to File's Owner.

An object that does not conform is not sent anything.

## Topics

[awakeFromNib](#awakefromnib)

### awakeFromNib

```c
void awakeFromNib(void);
```

Called once per load, after all of that load's connections.

## See also

- [`UXNib`](/compiler/api/uxkit/uxnib/)
- [`UXDesignable`](/compiler/api/uxkit/uxdesignable/)
