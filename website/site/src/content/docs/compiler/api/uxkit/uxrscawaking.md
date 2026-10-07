---
title: UXRscAwaking
description: "awakeFromRsc: called on each object an rsc file load made, and on File's Owner, once every outlet is connected."
---

A protocol for objects that finish setting up after an rsc file load. From 0.7.

```c
#import "UXRsc.xc"
```

## Overview

```c
class LibraryController : Object<UXRscAwaking>
{
    outlet UXTableView* table;

    void awakeFromRsc(void)
    {
        table.reloadData();      // the outlet is connected by now
    }
}
```

During `init` an rsc file-made object's outlets are still null, because the loader
connects them afterwards. [`UXRsc`](/compiler/api/uxkit/uxrsc/) sends
`awakeFromRsc` when every connection of the load is made: first to the
top-level objects, then to the views, then to File's Owner.

An object that does not conform is not sent anything.

## Topics

[awakeFromRsc](#awakefromrsc)

### awakeFromRsc

```c
void awakeFromRsc(void);
```

Called once per load, after all of that load's connections.

## See also

- [`UXRsc`](/compiler/api/uxkit/uxrsc/)
- [`UXDesignable`](/compiler/api/uxkit/uxdesignable/)
