# sim68k — instrumented Atari ST (68000/68030) emulator

`xcc-sim-68k` (`src/xst/sim68k.c`, binary `bin/<plat>/xcc-sim-68k`) is the
Atari ST/TT counterpart to `xcc-sim-6502`. It is a single self-contained simulator in pure C
that loads a GEMDOS executable and runs it, so xtc's 68k backend can be
tested and oracle-diffed in the same way as the 6502 backend.

## Design decisions

- **Hand-written CPU core, pure C.** There is no third-party 68k core. The
  code follows `sim6502.c`, so every state transition can be instrumented
  directly.
- **HLE, but ABI-faithful.** There is no TOS ROM. GEMDOS (`trap #1`), BIOS
  (`trap #13`) and XBIOS (`trap #14`) are emulated at a high level against
  the documented Atari ABI, and the `$601A` executable format (basepage
  and relocation) is honoured. The aim is that a binary that runs here
  runs identically on real ST hardware.
- **Text-first.** Console and file I/O go to host stdout and host files.
  A framebuffer region and a `trap #2` (AES/VDI) hook are reserved but
  stubbed, for a later graphics phase backed by the GEM desktop (the
  `GEM_DIR` variable in `build.env`).

## Memory & CPU

- Flat big-endian RAM (default 4 MB, `--mem`). All multi-byte access
  goes through `rd8/16/32` / `wr8/16/32`, so byte order is handled in one
  place. The bus is masked to 24 bits.
- State: `D0–D7`, `A0–A7` (A7 = SP), `PC`, CCR (X N Z V C) and the S bit.
- `decode_ea` handles all 68000 addressing modes, including `(An)+`/`-(An)`
  with the A7 byte +2 rule and the `d8(An,Xn)` brief index. The 68020+
  scaled index is enabled only with `--cpu 68030`. `ea_load`/`ea_store`
  read and write a decoded operand; `ea_address` gives the address for
  control modes.
- Implemented instruction families: MOVE/MOVEA/MOVEQ, ADD/ADDA/ADDI/ADDQ,
  SUB/SUBA/SUBI/SUBQ, AND/ANDI, OR/ORI, EOR/EORI, NOT/NEG/CLR/TST,
  CMP/CMPA/CMPI/CMPM, MULS/MULU, DIVS/DIVU, shifts/rotates (AS/LS/RO/ROX,
  register & memory-by-1), BTST/BSET/BCLR/BCHG (static & dynamic),
  Bcc/BRA/BSR, DBcc, Scc, JMP/JSR/RTS/RTR/RTE, LINK/UNLK, LEA/PEA, MOVEM,
  EXT/SWAP/EXG, MOVE to/from CCR/SR, TRAP, NOP, STOP, CHK.
- Flags are computed per size by `set_add_flags`/`set_sub_flags`/
  `set_cmp_flags`/`set_logic_flags`.

## Trap HLE

On `TRAP #n`, the user-mode caller has pushed `[fn.w][args…]` onto its
stack, and `A7` points at `fn`. The emulator reads the arguments directly
from `A7` (`arg16`/`arg32`), sets the result in `D0` and resumes; the
caller removes its own arguments. No supervisor frame is created. This
matches the caller's ABI, which is the compatibility contract.

- **GEMDOS** (`trap #1`): Cconin/Cnecin/Cconout/Cconws, Pterm0/Pterm,
  Super (benign), Tgetdate/Tgettime (fixed values, so runs are
  deterministic), Sversion, Malloc/Mfree/Mshrink (bump allocator in the
  TPA), Fcreate/Fopen/Fclose/Fread/Fwrite/Fseek (host files; handles ≥6,
  std handles 0/1/2 = console).
- **BIOS** (`trap #13`): Bconstat/Bconin/Bconout, Drvmap, Getbpb, Kbshift.
- **XBIOS** (`trap #14`): Physbase/Logbase (→ reserved framebuffer),
  Getrez, Setscreen/Setpalette/Setcolor (no-op), Vsync, Random (LCG).
- **`trap #2`** (AES/VDI): stub, reserved for the GEM desktop backend.

## Executable loader

`load_prg` parses the `$601A` header (text/data/bss/symtab sizes,
absflag) and loads TEXT+DATA at `LOAD_BASE+0x100`. It then zeroes BSS,
applies the DRI/GEMDOS relocation byte stream (a first-fixup longword,
then advance bytes, with `1` = +254), builds the 256-byte basepage
(`p_lowtpa`…`p_env`, with `p_cmdlin` as a Pascal string), sets up the
stack so that `4(sp)` is the basepage, and sets `PC = p_tbase`.

## Instrumentation (mirrors `xcc-sim-6502`'s `XTS_*` under `XST_*`)

| env var | effect |
|---------|--------|
| `XST_ITRACE=1` | trace every instruction to stderr |
| `XST_ITRACE_TRIGGER=hex` | begin tracing when PC reaches addr |
| `XST_ITRACE_STOP=hex` | stop tracing at addr |
| `XST_ITRACE_MAX=dec` | cap traced instructions (default 200000) |
| `XST_WATCH=hex` | log every write to an address |
| `XST_TRAPTRACE=1` | log every GEMDOS/BIOS/XBIOS call (args + return) |

CLI: `xcc-sim-68k [opts] <file.prg> [mapfile]` with `-d`/`--dump-output`,
`--cycles`, `--cpu 68000|68030`, `--mem <MB>`, `--args "<cmdline>"`.
The optional mapfile uses the same `ADDR: b0 b1 …` prefill format as `xcc-sim-6502`.

## Validation

`tests/68k/` holds hand-assembled fixtures (see its README) for the
loader, the relocation engine, the core instruction families, signed
conditionals, and the GEMDOS console and file paths. Rebuild them with
`python3 tests/68k/build.py`.

## Toolchain status

The 68k code generator runs end to end:

    xcc -A m68k|68000|68030  foo.xc  -o foo.prg

This runs `xcc-fe` → `xcc-cg-68k` (`XTM68kBackend`, a naive
slot-per-SSA-value LINK-frame lowering) → `XAM68kAssembler` (two-pass,
in-process) and produces a GEMDOS `$601A` executable that `xcc-sim-68k` runs. The
return value of `main()` becomes the process exit code through the crt0
Pterm wrapper. The assembler is cross-validated by running its output in
this emulator (encode against decode). See `tests/68k/compile_run.sh`
(`ret42`→42, `arith`→32 on both 68000 and 68030). Real lowering of
control flow, calls, memory and Stdio, and a proper ABI, are not yet
implemented.

## Known gaps

- No FPU (68881/68882); the TT uses soft float.
- 68020+ extras beyond the scaled index (bitfield ops, 32-bit MUL/DIV.L,
  memory-indirect modes) are not decoded.
- ABCD/SBCD/NBCD, TAS and MOVEP are not implemented; the compiler is
  unlikely to emit them.
- `trap #2` AES/VDI and the framebuffer are the reserved graphics
  interface, to be backed by the GEM desktop (an RGBA-8888 surface
  through its `gfx.h`; see `GEM_DIR` in `build.env`).
- No supervisor/USP-SSP separation and no real exception vectors; the
  HLE traps make them unnecessary.
