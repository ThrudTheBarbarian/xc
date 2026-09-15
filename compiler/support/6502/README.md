# support/6502 — parked standard (flat) 6502 target

This tree is **not wired to a live target**. The compiler supports one
6502-family memory model (`xt6502`, banked); the flat Atari `xl`/`xe` and
Commodore `c64` targets are retired. This directory keeps the one piece of
standard-6502 strategy that is not obvious, so a future flat, unbanked 6502
target doesn't have to rediscover it.

## What's here, and why

`lib/Stdio.xc` is a snapshot of the xt6502 `Stdio.xc` **from when it carried
the `#if HAS_*FMT` printf format-feature gating**. On a flat 6502 that gating
matters: `printf` lives in an unbanked ~40 KB code space, and its
per-conversion branches pull in heavy helpers (`dp2Asc` for `%lf` is ~800
bytes; `%@` drags in `Object` + `description()` dispatch). Dead-code
elimination **cannot** remove them, because `Stdio.printf` runs a runtime loop
over the format pointer and every branch is reachable to the optimiser. Only
cutting the branch out at source with `#if` (which then orphans the helper for
DCE to sweep) prunes it. A flat 6502 needs this gating.

xt6502 itself does **not** use this gating. There, all non-`main` code is
packed into 16 KB code-bank pages ($6000–$9FFF, 256 pages ≈ 4 MB) reached via
the `_xcall` trampoline, so the pruned code lands in abundant banked space and
the two scarce resources (the $D800–$FFF9 unbanked region and zero page) are
untouched. Gating there would save only binary size, not fit, which does not
justify the machinery.

## Re-enablement notes

The gating has **two halves**, and this snapshot is only the first:

1. **`Stdio.xc` `#if HAS_*FMT` blocks** (here). Integer radixes are folded:
   `HAS_DFMT` gates both the `%d` and `%ld` branch (likewise `%u`/`%lu`,
   `%x`/`%lx`), because type-directed printf lets the compiler pick the width.
   `HAS_FFMT` (%f) and `HAS_LFMT` (%lf) stay distinct kinds.
2. **The driver format pre-scan** that sets the `HAS_*FMT` defines from the
   program's format strings. It lived in
   `XTCompilerDriver.setupHasFmtMacrosOnto:` (with a mirror in
   `tests/corpus/XTCorpusSweep.m`) and was removed together with the xt6502
   gating. Restore it from the repository history alongside this file when a
   flat 6502 target comes back.
