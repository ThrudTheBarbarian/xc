---
title: mapData
description: "The xt6502-only helper that bank-switches the data window: select which 8 KB page appears in the banked data region for low-level, banked data access."
---

`mapData` is a small, low-level free function on the **xt6502** target. It
bank-switches the **data window** (the banked data region, the `$A000` region
in the memory map), so you choose which 8 KB page is visible there before
reading or writing through it.

```c
#import "mapData.xc"
```

## Overview

The xt6502 exposes more RAM than the 6502 can address at once by paging 8 KB
banks in and out of fixed windows. `mapData` selects which page is mapped into
the data window, so code can reach data that lives in a bank other than the one
it started in. It is a global function available to all code, called as
`mapData(page)`, not a method on a class.

### mapData
```c
void mapData(i16 page)
```

The `page` argument selects the bank:

- **`page == -1`**: map the *same* page as the current **code** area into the
  data window. This gives the calling class or function its own 8 KB data area,
  located with the running code: the data window then aliases the bank the
  caller executes from.
- **`page >= 0`**: map the specified page number (`0`–`255`) into the data
  window.

The function changes only what is *visible* in the window; it moves no bytes.
After the call, ordinary loads and stores through the window address access the
selected page.

## When to use it

Use `mapData` for manual **banked data access**: reaching into a data bank that
is not currently mapped, or setting up a private per-object or per-function data
area with `mapData(-1)` before using it. It is a building block for low-level
code. Most programs let the compiler and runtime manage banking and never call
it directly.

:::note[Availability]
`mapData` is **xt6502-only** and **low-level**. It ships only under
`support/xt6502/lib/` and has no counterpart on the native backends, which have a
flat address space and no bank windows. Code that calls it will not compile for
another target.
:::

## See also

- [The 6502 standard library](/compiler/api/6502/): the other system services
  implemented specifically for the 6502.
