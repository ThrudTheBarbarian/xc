# tests/68k — sim68k (Atari ST) smoke fixtures

Hand-assembled GEMDOS `$601A` executables that exercise the `xst`
(sim68k) emulator end to end, before an `xtcg-68k` backend exists to
generate them. Rebuild with:

    python3 tests/68k/build.py

Run one (`-d` streams the program's console output to stdout):

    ./bin/osx/xcc-sim-68k -d tests/68k/hello.prg

| fixture       | exercises                                   | expected stdout |
|---------------|---------------------------------------------|-----------------|
| `hello.prg`   | PEA(pc), Cconws (GEMDOS #9), Pterm0         | `PASS\r\n`      |
| `loop.prg`    | MOVEQ/ADDQ/DBRA/ADDI, Cconout (#2)          | `5\n`           |
| `reloc.prg`   | PEA abs.l + the loader relocation engine    | `RELOC OK\r\n`  |
| `cond.prg`    | CMPI.W + Bcc (signed BGT, N==V)             | `Y`             |
| `fwrite.prg`  | Fwrite (#0x40) to stdout, LEA               | `HELLO`         |
| `fileio.prg`  | Fcreate/Fwrite/Fclose round-trip            | writes `out.txt` = `HELLO` |

Useful instrumentation while debugging a fixture:

    XST_ITRACE=1     ./bin/osx/xcc-sim-68k -d tests/68k/loop.prg     # per-insn trace
    XST_TRAPTRACE=1  ./bin/osx/xcc-sim-68k -d tests/68k/fileio.prg   # GEMDOS/BIOS/XBIOS calls
    XST_WATCH=$01010 ./bin/osx/xcc-sim-68k    tests/68k/hello.prg    # log writes to an address

These are stop-gap fixtures. Once the 68k backend lands they will be
superseded by compiled `.xc` corpus fixtures tagged `target=atarist`.
