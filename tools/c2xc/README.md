# c2xc — C to xc

A converter from C to the xc language. It was written to bring across
Kundert's Sparse 1.4 (a sparse-matrix library, for a SPICE engine in a browser
Worker), and it works on any ANSI C program that stays within the C library
table.

    python3 c2xc.py [-o out.xc] [-I dir]... [-D name=v]... file.c [file2.c ...]

Every input file becomes one xc translation unit. `tests/run.py` is the
differential suite: each `tests/*.c` is built with clang and run, then
converted, built with xcc and run, and the outputs must agree.

## What it lowers

xc reads most of C directly. The converter's work is a C type pass, so
that C's implicit conversions become the casts xc needs (xc has no
promotion to int and a comparison is a bool), and the lowering of what xc
lacks or does differently:

| C | xc |
|---|---|
| a function pointer handed to C (a native prototype, a system-header struct field) | `pointer`, with `(pointer)(&fn)` at the call: C reads one word, and xc's `callback` is a two-word pair |
| a function pointer within the program | `callback name RET(params)`; arrays `callback name RET(params)[n]`; struct fields `callback RET(params) name;` |
| `struct tag {..}`, `struct tag x` | `struct tag {..};` and `tag x` (self-references work) |
| `union` | a struct holding `u8 raw[N]`; members read through a cast |
| bit-fields | whole fields of the declared type (layout changes) |
| `int a[3][4]` | `i32 a[12]` with `a[i][j]` as `a[i*4+j]`; a row decays to `&a[i*4]` |
| `p++`, `*p++`, `p1 - p2` | `p = p + 1`, a temporary, `(i64)((u64)p1 - (u64)p2) / sizeof` |
| `s.fn(a)`, `tab[i](a)` | a temporary `Fn^` then the call (xc calls a `^` by a bare name) |
| function pointers | one `typedef R FnN_t(..)` per signature, used as `FnN_t^`; `fn` as a value is `&fn` |
| `do .. while (c)` | `bool first = true; while (first \|\| (c)) { first = false; .. }` |
| `for (a, b; c; d, e)` | a `while (true)` with a first-pass flag, so `continue` still steps |
| comma expressions | hoisted statements |
| `enum` | `#define` constants; the type is `i32` |
| `switch` | structured ifs with a run flag (fallthrough), each case in a one-pass loop (`break`), a continue flag; no xc `switch` is emitted |
| `goto` | where one block holds every label its gotos aim at, a state machine over that block: segments guarded by `_st <= k`, a jump flag unwinding loops and switches. Otherwise xc's own `goto` and labels, emitted as they stand |
| `static` functions/globals, `const`, prototypes | dropped; a name defined static in two files is suffixed |
| `"\xff"`, `"\377"` | a global `u8` array (xc's literals are UTF-8) |
| aggregate initialisers with strings or addresses | assignments in `c2xc_init_globals()`, called first in `main` |
| `int *a, b` | `i32* a; i32 b;` (xc binds `*` to the type) |
| `va_list` forwarded to `vsnprintf` | `c2xc_snprintf(.., ...)` in c2xc_rt.xc, an xc formatter |
| names that are xc keywords (`string`, `in`, `new` ..) | suffixed with `_` |
| unreachable code after a return | dropped (xcc's IR verifier rejects it); the drop stops at a label, which a `goto` still reaches |

libc is a table (`libc.py`): only the names a program uses are declared,
as natives, with the host's symbol for variables like `stderr`.

## Status

`tests/`: 13 programs agree with clang. Sparse 1.4: the library (14.7k
lines) converts and compiles; its test program converts and compiles to
assembly, and links only when the arm64 backend's `fmsub`, `neg w,x` and
`and w,d` encoding errors are fixed.
