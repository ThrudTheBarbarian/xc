---
title: System
description: "Process control on the xt6502: terminate the program and return to DOS from anywhere. A complete method reference."
---

`System` is the xt6502 process-control class. It has one method,
[`exit`](#exit), which terminates the program and returns control to DOS from
anywhere in the program, not only by returning from `main`.

```c
#import <System.xc>          // or the Foundation umbrella
```

## Overview

`System` is a `static` utility class. Call [`exit`](#exit) on the class
(`System.exit(0)`); the `init` is class boilerplate you never use.

:::note[Availability]
`System` is **xt6502-only**. It ships only under `support/xt6502/lib/`, so
`#import <System.xc>` fails to resolve under `-A arm64` and the other native
backends (`Cannot find include file 'System.xc'`). On the native targets, return
from `main` instead; the host runtime turns the return value into the process
exit status.
:::

## Topics

**Process control** · [exit](#exit)

---

## Process control

### exit
```c
static void exit(i16 value)
```
Terminates the program by jumping through the platform `DOSVEC` at `$0A`/`$0B`,
which returns control to DOS. The 16-bit `value` is stored at `$02FD`/`$02FE`
(otherwise unused OS page-2 bytes) for any cooperating caller. **DOS itself
ignores it**; the OS has no process-status mechanism.

Unlike returning from `main`, `exit` works from anywhere, so you do not have to
unwind the call stack back to `main` first.

```c
void main(void)
{
    if (load("data") == 0) {
        Stdio.print("missing data file\n");
        System.exit(1);
    }
    // …normal path…
    System.exit(0);
}
```

If you never call `exit`, returning from `main` has the same effect as `exit(0)`
on default `xcc` builds: the runtime emits an `RTS` back into DOS. The `-Q loop`
switch makes the program enter an infinite loop after `main` instead of an
`RTS`. In that mode `System.exit(...)` is the only way to return to DOS.

[↑ Topics](#topics)
