---
title: Time
description: "Read the xt6502 RTCLOK real-time clock, measure elapsed jiffies and seconds, and busy-wait for fixed durations. A complete method reference."
---

`Time` reads the xt6502 `RTCLOK` three-byte timer (`$12`/`$13`/`$14`) as a
24-bit **jiffy** counter and provides elapsed-time and busy-wait helpers on top
of it. A jiffy is one VBI tick: 1/50 s on PAL hardware, 1/60 s on NTSC. `Time`
detects which by reading the GTIA `PAL` register at `$D014`, so the same binary
keeps correct time on either.

```c
#import <Time.xc>          // or the Foundation umbrella
```

## Overview

`Time` is a `static` utility class. Every method is called on the class, never
on an instance (`Time.timerValue()`, not `new Time()`). It has an `init` only
because every class has one; you never instantiate it.

`timerValue` reads all three RTCLOK bytes in nine cycles to shrink the window in
which a VBI could fire mid-read. The elapsed-time helpers subtract with
two's-complement arithmetic, so a single rollover is handled transparently.

:::note[Availability]
This page documents the **xt6502** clock, which reads RTCLOK jiffies directly.
The native backends (arm64, x86_64, win64, arm9) ship their own `Time`
(`support/arm64/lib/Time.xc`) that reads a monotonic host clock through the
runtime. The shared methods keep their meaning, but two xt6502-only methods are
absent there:

| Method | xt6502 | native |
|---|---|---|
| `clearTimer()`, `timerValue()`, `ticksSince()`, `secondsSince()`, `delayJiffies()` | yes | yes |
| `dpSecondsSince(u32)` | yes | **no** |
| `delaySeconds(float)` | yes | **no** |

Calling either of the missing two on a native backend is a compile error
(`No method 'delaySeconds' on class 'Time'`). On the native targets
`timerValue()` counts microseconds since the last `clearTimer()` rather than
jiffies.
:::

## Topics

**Reading the timer** · [clearTimer](#cleartimer) · [timerValue](#timervalue)

**Elapsed time** · [ticksSince](#tickssince) · [secondsSince](#secondssince) · [dpSecondsSince](#dpsecondssince)

**Busy-wait delays** · [delayJiffies](#delayjiffies) · [delaySeconds](#delayseconds)

---

## Reading the timer

### clearTimer
```c
static void clearTimer(void)
```
Resets RTCLOK (`$12`/`$13`/`$14`) to zero, so a subsequent
[`timerValue`](#timervalue) counts from now.

### timerValue
```c
static u32 timerValue(void)
```
The current RTCLOK reading packed little-endian into a `u32`:
`$12 << 16 | $13 << 8 | $14`. This is a 24-bit counter (max `$FFFFFF`, about
16.7 M jiffies, which is about 93 hours at 50 Hz or 78 at 60), so the top byte
is always zero. All three bytes are read in nine cycles to minimise the chance
that a VBI fires mid-read and corrupts the value.

[↑ Topics](#topics)

## Elapsed time

### ticksSince
```c
static u32 ticksSince(u32 oldValue)
```
Jiffies elapsed since a value previously returned by [`timerValue`](#timervalue).
The subtraction is two's-complement, so a **single** rollover between the mark
and the read is handled correctly. More than one rollover cannot be detected and
gives a wrong answer.

### secondsSince
```c
static float secondsSince(u32 oldValue)
```
Elapsed jiffies divided by the auto-detected frame rate (50 or 60 Hz), as a
`float`. It reads GTIA `$D014` to pick PAL or NTSC and divides through the
`fpDiv` runtime.

### dpSecondsSince
```c
static double dpSecondsSince(u32 oldValue)
```
The double-precision form of [`secondsSince`](#secondssince). It has its own
name instead of a return-type overload because xcc uses return type as a
tiebreaker only for **zero-arg** overloads, so a `secondsSince(u32) → float` and
`secondsSince(u32) → double` pair would be flagged as a redefinition. Use it for
long intervals where `float`'s ~7 significant digits would lose jiffy
resolution: at ~2 years uptime a `float` second resolves to ~10 s, while the
`double` keeps full jiffy resolution across the whole `u32` range.

[↑ Topics](#topics)

## Busy-wait delays

Both delays block by polling RTCLOK rather than relying on an OS timer, so they
survive OS timer reloads and handle rollover safely.

### delayJiffies
```c
static void delayJiffies(u32 jiffies)
```
Busy-waits for `jiffies` VBI ticks (1/50 s PAL, 1/60 s NTSC), comparing
[`ticksSince`](#tickssince) against a start mark.

### delaySeconds
```c
static void delaySeconds(float secs)
```
Busy-waits for `secs` seconds. It converts `secs` to a jiffy count with integer
math on the float's raw mantissa and exponent (times the auto-detected Hz), then
calls [`delayJiffies`](#delayjiffies). It does **not** go through `fpMul`, which
hangs on floats whose stored mantissa is zero (for example `1.0`). Negative and
very large inputs both result in a zero-jiffy delay rather than an endless wait.

[↑ Topics](#topics)

## Worked example

```c
#import <Stdio.xc>
#import <Time.xc>

void main(void)
{
    u32 t0 = Time.timerValue();
    heavyWork();
    u32   jiffies = Time.ticksSince(t0);
    float secs    = Time.secondsSince(t0);
    Stdio.printf("work took %lu jiffies (%f s)\n", jiffies, secs);

    Stdio.print("starting in ");
    for (u8 i = 3; i > 0; i--) {
        Stdio.printf("%u... ", (u16)i);
        Time.delaySeconds(1.0);
    }
    Stdio.print("go!\n");
}
```
