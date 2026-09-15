---
title: symbols
description: "The xt6502 platform's memory-map symbols — named addresses for the timing clock, OS and interrupt vectors, display and colour state, and the custom-chip hardware registers, for inline assembly and low-level code."
---

`symbols.xc` is a header of **named constants** for the **xt6502** platform's
memory map: the hardware registers, OS vectors, and memory regions that
low-level code and inline assembly refer to by address. Importing it lets you
write `RTCLOK` instead of `$12`, `COLBK` instead of `$D01A`, and so on.

```c
#import <symbols.xc>
```

## Overview

These are the 6502 target's hardware and OS addresses, defined as macros that
cast a literal address to the width of the location: `((u8)$…)` for a one-byte
register, `((u16)$…)` for a two-byte pointer or vector. They generate no code.
You read, write or `JSR` through them, usually from an `asm { }` block or a raw
pointer dereference.

The header defines about **268** symbols. The tables below cover each group it
defines (the timing clock, the OS/interrupt vectors, the display and colour
state, and the custom-chip register files) and list the main members of each.
For the full list, read the header, which is grouped by memory page in the same
order.

Sections: [Timing](#timing) · [OS, DOS & interrupt vectors](#os-dos--interrupt-vectors) ·
[Memory regions & pointers](#memory-regions--pointers) ·
[Display & screen](#display--screen) · [Colour](#colour) ·
[Keyboard, console & input](#keyboard-console--input) ·
[Zero-page working storage](#zero-page-working-storage) ·
[Hardware registers](#hardware-registers)

:::note[Availability]
`symbols.xc` is **xt6502-only** and low-level. The addresses it names exist only
on the banked-6502 target. The native backends have a flat address space and no
fixed hardware map, so none of it applies to them.
:::

## Timing

The jiffy clock and the software / hardware timers. Most code uses `RTCLOK`, a
3-byte frame counter stored most-significant byte first. The
[`Time`](/compiler/api/time/) class reads it.

| Symbol   | Address | Meaning |
|----------|---------|---------|
| `RTCLOK` | `$12`   | real-time (jiffy) clock, 3 bytes, MSB first |
| `ATRACT` | `$4D`   | attract-mode timer |
| `SRTIMR` | `$22B`  | key auto-repeat timer |
| `CDTMV1`–`CDTMV5` | `$218`–`$220` | system timer 1–5 countdown values |
| `CDTMA1`, `CDTMA2` | `$226`, `$228` | timer 1 / 2 callback addresses |
| `CDTMF3`, `CDTMF4`, `CDTMF5` | `$22A`, `$22C`, `$22E` | timer 3 / 4 / 5 flags |
| `VCOUNT` | `$D40B` | vertical line counter (read) |
| `WSYNC`  | `$D40A` | wait for horizontal sync (strobe) |

## OS, DOS & interrupt vectors

RAM-based vectors the OS dispatches through. Install a handler by writing its
address here, using the OS-safe path where one exists (see
[`Vbi`](/compiler/api/vbi/) for the vertical-blank pair).

| Symbol   | Address | Meaning |
|----------|---------|---------|
| `DOSVEC` | `$0A`   | DOS start vector |
| `DOSINI` | `$0C`   | DOS init address |
| `CASINI` | `$02`   | cassette initialisation vector |
| `RUNAD`  | `$2E0`  | program run-address vector |
| `INITAD` | `$2E2`  | program init-address vector |
| `VDSLST` | `$200`  | display-list interrupt vector |
| `VKEYBD` | `$208`  | keyboard interrupt vector |
| `VBREAK` | `$206`  | `BRK` instruction vector |
| `VSERIN`, `VSEROR`, `VSEROC` | `$20A`, `$20C`, `$20E` | serial input-ready / output-ready / output-complete vectors |
| `VTIMR1`, `VTIMR2`, `VTIMR4` | `$210`, `$212`, `$214` | timer 1 / 2 / 4 interrupt vectors |
| `VIMIRQ` | `$216`  | IRQ immediate vector |
| `VVBLKI` | `$222`  | vertical-blank immediate vector |
| `VVBLKD` | `$224`  | vertical-blank deferred vector |
| `HATABS` | `$31A`  | device handler address table |

## Memory regions & pointers

The bounds of usable RAM. `MEMLO` and `MEMTOP2` bracket the free region; the rest
describe the memory-test and language-runtime pointers.

| Symbol   | Address | Meaning |
|----------|---------|---------|
| `MEMLO`   | `$2E7` | start of free RAM |
| `MEMTOP2` | `$2E5` | top of display memory |
| `MEMTOP`  | `$90`  | top of language-runtime memory |
| `APPMHI`  | `$0E`  | application memory high limit |
| `RAMTOP`  | `$6A`  | RAM size, in 256-byte pages |
| `RAMLO`   | `$04`  | RAM pointer for the memory test |
| `LOMEM`   | `$80`  | language-runtime low-memory pointer |

## Display & screen

Screen-memory location, cursor state, display mode, and the display-list /
DMA control that drive the video hardware.

| Symbol   | Address | Meaning |
|----------|---------|---------|
| `SAVMSC` | `$58`  | screen memory address |
| `DINDEX` | `$57`  | current display (graphics) mode |
| `ROWCRS` | `$54`  | cursor row |
| `COLCRS` | `$55`  | cursor column (2 bytes) |
| `LMARGN`, `RMARGN` | `$52`, `$53` | left / right text margin |
| `SDLSTL` | `$230` | display-list pointer shadow |
| `SDMCTL` | `$22F` | DMA-control shadow |
| `DLISTL`, `DLISTH` | `$D402`, `$D403` | display-list pointer (low / high) |
| `DMACTL` | `$D400` | DMA control (hardware) |
| `CHBAS`  | `$2F4` | character-set base (page) shadow |
| `CHBASE` | `$D409` | character-set base (page, hardware) |
| `GPRIOR` | `$26F` | priority / graphics-mode shadow |

## Colour

Colour is held in RAM **shadows** (copied to the hardware every vertical blank)
and in the hardware registers themselves. Write the shadow for a stable change;
write the hardware register for a mid-frame effect.

| Symbol   | Address | Meaning |
|----------|---------|---------|
| `COLOR0`–`COLOR3` | `$2C4`–`$2C7` | playfield 0–3 colour shadows |
| `COLOR4` | `$2C8` | background colour shadow |
| `PCOLR0`–`PCOLR3` | `$2C0`–`$2C3` | player/missile 0–3 colour shadows |
| `COLPF0`–`COLPF3` | `$D016`–`$D019` | playfield 0–3 colour (hardware) |
| `COLBK`  | `$D01A` | background colour (hardware) |
| `COLPM0`–`COLPM3` | `$D012`–`$D015` | player/missile 0–3 colour (hardware) |

## Keyboard, console & input

Last-key state, the console keys, and the joystick / trigger ports.

| Symbol   | Address | Meaning |
|----------|---------|---------|
| `CH`     | `$2FC`  | last keyboard code pressed |
| `KBCODE` | `$D209` | keyboard code (hardware) |
| `CONSOL` | `$D01F` | console switches |
| `BRKKEY` | `$11`   | break-key flag |
| `TRIG0`–`TRIG3` | `$D010`–`$D013` | joystick trigger 0–3 (read) |
| `PORTA`  | `$D300` | port A (joysticks 0 and 1) |
| `PORTB`  | `$D301` | port B |

## Zero-page working storage

Scratch and floating-point registers in page zero. The FP registers `FR0`,
`FR1`, `FR2` are six bytes each; the input/pointer helpers are two bytes.

| Symbol   | Address | Meaning |
|----------|---------|---------|
| `FR0`    | `$D4`  | floating-point register 0 (6 bytes) |
| `FR1`    | `$E0`  | floating-point register 1 (6 bytes) |
| `FR2`    | `$E6`  | floating-point register 2 (6 bytes) |
| `CIX`    | `$F2`  | character index into the FP input buffer |
| `INBUFF` | `$F3`  | FP input-buffer pointer |
| `FLPTR`  | `$FC`  | floating-point pointer |
| `TEMP`, `HOLD1` | `$50`, `$51` | general temp registers |

The header also names the CIO and SIO zero-page blocks (`ICHIDZ`…`ICAX2Z` around
`$20`; `STATUS`…`DSTAT` around `$30`) used when driving device I/O by hand.

## Hardware registers

The custom-chip register files. Many chips **alias read and write** at one
address: the location means one thing when written and another when read, and
the header has a name for each. The tables below list the commonly used
registers per chip; the header defines each chip's complete register file.

**GTIA** (`$D000`–`$D01F`): players/missiles, collisions, priority, console:

| Symbol   | Address | Meaning |
|----------|---------|---------|
| `HPOSP0`–`HPOSP3` | `$D000`–`$D003` | player 0–3 horizontal position (write) |
| `GRAFP0`–`GRAFP3` | `$D00D`–`$D010` | player 0–3 graphics (write) |
| `PRIOR`  | `$D01B` | priority select (write) |
| `HITCLR` | `$D01E` | collision clear (strobe) |
| `M0PF`–`M3PF` | `$D000`–`$D003` | missile–playfield collisions (read) |
| `P0PL`–`P3PL` | `$D00C`–`$D00F` | player–player collisions (read) |

**POKEY** (`$D200`–`$D20F`): audio, serial, keyboard scan, random:

| Symbol   | Address | Meaning |
|----------|---------|---------|
| `AUDF1`/`AUDC1`…`AUDF4`/`AUDC4` | `$D200`–`$D207` | audio channel 1–4 frequency / control (write) |
| `AUDCTL` | `$D208` | audio control (write) |
| `IRQEN`  | `$D20E` | IRQ interrupt enable (write) |
| `SKCTL`  | `$D20F` | serial-port control (write) |
| `RANDOM` | `$D20A` | random-number generator (read) |
| `KBCODE` | `$D209` | keyboard code (read) |
| `IRQST`  | `$D20E` | IRQ status (read) |

**PIA** (`$D300`–`$D303`): the parallel ports:

| Symbol   | Address | Meaning |
|----------|---------|---------|
| `PORTA`  | `$D300` | port A (joysticks 0 and 1) |
| `PORTB`  | `$D301` | port B |
| `PACTL`  | `$D302` | port A control |
| `PBCTL`  | `$D303` | port B control |

**ANTIC** (`$D400`–`$D40F`): display DMA, scrolling, NMI:

| Symbol   | Address | Meaning |
|----------|---------|---------|
| `DMACTL` | `$D400` | DMA control (write) |
| `CHACTL` | `$D401` | character control (write) |
| `HSCROL`, `VSCROL` | `$D404`, `$D405` | horizontal / vertical scroll (write) |
| `PMBASE` | `$D407` | player/missile base address, page (write) |
| `WSYNC`  | `$D40A` | wait for horizontal sync (strobe) |
| `NMIEN`  | `$D40E` | NMI interrupt enable (write) |
| `VCOUNT` | `$D40B` | vertical line counter (read) |
| `NMIST`  | `$D40F` | NMI status (read) |

## See also

- [The 6502 standard library](/compiler/api/6502/): the system services built
  on these addresses.
- [Vbi](/compiler/api/vbi/): installing vertical-blank handlers safely through
  the `VVBLKI` / `VVBLKD` vectors.
- [Time](/compiler/api/time/): the `RTCLOK`-based clock.
