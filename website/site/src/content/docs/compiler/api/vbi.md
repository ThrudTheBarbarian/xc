---
title: Vbi
description: "Install and remove Vertical-Blank-Interrupt handlers on the xt6502 through the OS-safe SETVBV path. A complete method reference."
---

`Vbi` installs and removes Vertical-Blank-Interrupt handlers. The xt6502 fires a
VBI about 50 times a second on PAL and 60 on NTSC. The OS dispatches first to an
**immediate** vector for time-critical work, then to a **deferred** vector after
its own housekeeping.

```c
#import <Vbi.xc>          // or the Foundation umbrella
```

## Overview

`Vbi` is a `static` utility class: call every method on the class
(`Vbi.addDeferred(&fn)`). The `init` is class boilerplate you never use. Install
and remove always go through `SETVBV` (`$E45C`), so the OS performs an SEI-safe
atomic write to the vector pair. Without it, a VBI could fire between the lo and
hi byte writes and jump through a half-updated pointer.

The OS holds two vectors and runs them in order during every vertical blank:

| Vector | Address | Default | Use for |
|--------|---------|---------|---------|
| **Immediate** (`VVBLKI`) | `$0222` | `SYSVBV` (`$E45F`) | display-list updates, scroll registers — anything that must be in place before ANTIC starts the next frame |
| **Deferred** (`VVBLKD`) | `$0224` | `XITVBV` (`$E462`) | counters, music, slow state machines — everything else |

After the deferred handler returns, the OS exits the interrupt via `XITVBV`.

:::note[Availability]
`Vbi` is **xt6502-only**. It programs the platform vertical-blank vectors, which
no native target has. It ships only under `support/xt6502/lib/`, so
`#import <Vbi.xc>` fails to resolve under `-A arm64` and the other native
backends (`Cannot find include file 'Vbi.xc'`).
:::

## The `:vbi` handler contract

Your handler **must** be declared with the `:vbi` function annotation. This
tells the codegen to save A / X / Y in the prologue, restore them in the
epilogue, and replace the usual `RTS` with a `JMP XITVBV` so the OS finishes the
interrupt cleanly. A plain function would corrupt registers in the interrupted
code and either lock up the machine or skip the rest of the OS chain. On the
banked `xt` target, `:vbi` (and `:irq`) handlers are placed automatically in
**unbanked RAM** at a stable address, because the OS dispatcher jumps through the
vector slot with no chance for the bank-switch trampoline to page the handler
in. You do not annotate the handler `:main` yourself.

```c
volatile u8* COLBK = (u8*)$D01A;    // background colour register

void rainbow(void) :vbi
{
    *COLBK = *COLBK + (u8)1;         // change border colour every frame
}

void main(void)
{
    Vbi.addDeferred(&rainbow);
    while (1) { /* spin */ }
}
```

## Topics

**Installing** · [addImmediate](#addimmediate) · [addDeferred](#adddeferred)

**Removing** · [removeImmediate](#removeimmediate) · [removeDeferred](#removedeferred)

---

## Installing

Choose **immediate** when the work has tight timing (display-list updates and
scroll registers, which must run before ANTIC starts the next frame) and
**deferred** for everything else (counters, music, AI ticks). Without a clear
reason to use immediate, prefer deferred, which keeps your handler out of the
critical path of the OS's own vector handling.

### addImmediate
```c
static void addImmediate(pointer fn)
```
Installs `fn` at the immediate vector `VVBLKI` (`$0222`) via `SETVBV` with A=6.
`fn` must be a `:vbi`-annotated handler.

### addDeferred
```c
static void addDeferred(pointer fn)
```
Installs `fn` at the deferred vector `VVBLKD` (`$0224`) via `SETVBV` with A=7.
`fn` must be a `:vbi`-annotated handler.

[↑ Topics](#topics)

## Removing

### removeImmediate
```c
static void removeImmediate(void)
```
Restores `VVBLKI` to its OS default `SYSVBV` (`$E45F`). This is the teardown for
[`addImmediate`](#addimmediate).

### removeDeferred
```c
static void removeDeferred(void)
```
Restores `VVBLKD` to its OS default `XITVBV` (`$E462`). This is the teardown for
[`addDeferred`](#adddeferred).

[↑ Topics](#topics)
