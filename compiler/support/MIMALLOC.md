# mimalloc — the optional host allocator (`-fmalloc=mimalloc`)

`support/x86_64/runtime/mimalloc.o` is mimalloc **2.1.7** built as a SINGLE
translation unit (`src/static.c`, which `#include`s the whole library; see its
own comment: *"For a static override we create a single object file containing
the whole library. If it is linked first it will override all the standard
library allocation functions"*).

## Why an OBJECT and not an archive

Under a static link, an archive member is only pulled in to satisfy an
**undefined** symbol. If libc's `malloc` has already been pulled in, a mimalloc
`.a` overrides only *some* of the family. That is worse than not overriding at
all: two allocators in one program, and a `free` handed a pointer the other one
owns. A plain `.o` is unconditional, and is placed FIRST in the link so its
strong definitions win.

## Regenerate

    tar xzf mimalloc-2.1.7.tar.gz
    # x86-64 (Linux, musl) — the only target this is wired for
    x86_64-linux-musl-clang \
          -c -O2 -DNDEBUG -DMI_MALLOC_OVERRIDE=1 \
          -I mimalloc-2.1.7/include \
          -o support/x86_64/runtime/mimalloc.o mimalloc-2.1.7/src/static.c

MIT licensed (Microsoft Research, Daan Leijen); see the upstream LICENSE.

## Why x86-64 only

`-fmalloc=mimalloc` needs a linker that can consume a foreign OBJECT, and only
the x86-64 path has one: it drives `ld.lld` directly.

* **arm64**: the self-host linker ASSEMBLES the compiler's own `.s` and has no
  object reader, so there is nowhere to put a prebuilt `.o`. Supporting it means
  teaching `xcc-ln-arm64` to link Mach-O objects, which is worth doing only if
  the numbers justify it (they may not: Apple's allocator is already good,
  unlike musl's).
* **win64**: freestanding, reaches the OS through kernel32 and links no libc,
  so mimalloc's Windows primitives have nothing to sit on.

Both REJECT the flag with an explanation rather than accepting it and quietly
building a system-malloc binary. A silent no-op there would be
indistinguishable from "measured, made no difference".

## Measured (x86-64 Linux, static musl)

| workload | system (musl) | mimalloc | |
|---|---:|---:|---|
| allocation churn, 3.2M objects | 0.47s | 0.06s | **7.8x** |
| mixed alloc + string/array work | 2.37s | 0.27s | **8.8x** |

Both produced identical output. A real application workload measured **2.3x**:
these microbenchmarks are near the upper bound because they are mostly
allocator. The cost is **+148 KB** of binary (75 KB -> 223 KB on a
hello-world-sized program), on every binary that opts in.

On the multiplier: `_xtc_alloc` floors every allocation at 256 bytes (+38
header), so xtc never exercises the small size classes where allocators usually
differ most. The gap here is musl's mallocng being slow at this size, not
mimalloc winning a small-object race.
