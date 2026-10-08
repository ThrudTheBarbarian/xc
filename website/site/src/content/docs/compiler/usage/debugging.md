---
title: Debugging
description: Building with -g for lldb and gdb, what the debug information holds on each target, and what a build without it keeps.
---

From 0.74, `xcc -g` writes DWARF debug information into the executable, so
lldb and gdb can stop on a source line, step line by line and show a backtrace
with the file and line of every frame.

```bash
xcc -g -O0 -o game game.xc
lldb game
(lldb) breakpoint set --file game.xc --line 42
(lldb) run
(lldb) bt
(lldb) next
```

The same build works with gdb on Linux:

```bash
xcc -g -O0 -o game game.xc
gdb game
(gdb) break game.xc:42
(gdb) run
(gdb) bt
```

`-O0` keeps the code in the order of the source, which is what stepping
expects. `-g` works at any optimisation level, but an optimised build moves and
merges code, so a step can jump between lines or skip one.

## What `-g` contains

- **A line table**: every source line's first instruction, in the program's
  own files and in the library files it imports. Breakpoints by `file:line`,
  stepping by line and the source line of each frame come from it.
- **A function for every function and method**, with its address range, so a
  breakpoint on a name stops after the function's prologue, at its first
  statement.
- **Call frames**: where each function keeps its return address and frame
  pointer, so a backtrace is right in every frame, including leaf functions
  that set up no frame of their own.
- **Variables**: each function's integer, floating-point and `bool` variables
  and parameters, and its pointers to them (a `u8*` shows as a string), so
  `frame variable`, `print x` and expressions such as `p x + 1` work. To make
  that possible, `-g` keeps each of them in memory for the whole function, as
  C compilers do at `-O0`; the program's behaviour is the same.

The debug information goes into the executable itself, not a separate file, so
there is nothing else to keep beside it. A build without `-g` is unchanged.

## Targets

| Target | Format | Debuggers |
| --- | --- | --- |
| macOS (`arm64`) | DWARF in a `__DWARF` segment | lldb |
| Linux (`x86_64`), dynamic or `-static` | DWARF sections | gdb, lldb |
| Windows (`win64`) | DWARF sections | gdb (MinGW), lldb |

On Windows, an executable also always has a symbol table now, so a debugger or
a crash report names its functions with or without `-g`. Visual Studio and
WinDbg read PDB files, which xcc does not write yet.

## Without `-g`

Executables on every target keep their symbol table, so a debugger can break on
a function by name and a backtrace names each function, even without `-g`.
Source lines, stepping by line and call-frame information need `-g`.

## Not yet

- **Objects, structs and arrays.** Variables holding a class instance, a
  struct or an array are not described yet, and neither is a variable that is
  declared again in an inner scope.
- **Temporaries in `-g` builds.** An object made only to compute a variable's
  initial value, such as the string in `i32 n = count(String.withCString("a,b"))`,
  is not released in a `-g` build. That costs a little memory while debugging
  and is fixed in a later release; builds without `-g` release it as before.
- **Other targets.** `-g` is accepted on `arm9`, `m68k`, `wasm32`, `android`
  and the 6502, and adds nothing there yet.
