#!/usr/bin/env python3
"""Build the hand-assembled GEMDOS ($601A) smoke-test fixtures for xst.

We have no 68k assembler yet, so these tiny programs are hand-assembled
byte tables. Each proves a slice of the emulator end to end:

  hello   PEA(pc) + Cconws + Pterm0          -> "PASS\r\n"
  loop    MOVEQ/ADDQ/DBRA/ADDI + Cconout     -> "5\n"
  reloc   PEA abs.l + the relocation engine  -> "RELOC OK\r\n"
  cond    CMPI.W + Bcc (signed GT)           -> "Y"
  fwrite  Fwrite to stdout (handle 1)        -> "HELLO"
  fileio  Fcreate/Fwrite/Fclose round-trip   -> writes out.txt = "HELLO"

Run:  python3 tests/68k/build.py     (from the repo root)
"""
import struct, os

HERE = os.path.dirname(os.path.abspath(__file__))

def prg(text, reloc=b"\x00\x00\x00\x00"):
    # absflag = 0; a 4-byte reloc of 0 means "no fixups".
    return struct.pack(">HIIIIIIH", 0x601A, len(text), 0, 0, 0, 0, 0, 0) + text + reloc

def write(name, data):
    open(os.path.join(HERE, name), "wb").write(data)

# ── hello: Cconws("PASS\r\n"); Pterm0 ──────────────────────────────────
write("hello.prg", prg(bytes([
    0x48,0x7A,0x00,0x0E,            # pea  14(pc)        -> msg
    0x3F,0x3C,0x00,0x09,            # move.w #9,-(sp)    Cconws
    0x4E,0x41,                      # trap #1
    0x5C,0x8F,                      # addq.l #6,sp
    0x42,0x67,                      # clr.w -(sp)        Pterm0
    0x4E,0x41,                      # trap #1
]) + b"PASS\r\n\x00"))

# ── loop: sum 1..5 via DBRA, print '5' then newline ────────────────────
write("loop.prg", prg(bytes([
    0x70,0x00,                      # moveq #0,d0
    0x72,0x04,                      # moveq #4,d1
    0x52,0x80,                      # addq.l #1,d0   <-loop (0x04)
    0x51,0xC9,0xFF,0xFC,            # dbra d1,loop
    0x06,0x40,0x00,0x30,            # addi.w #0x30,d0
    0x3F,0x00,                      # move.w d0,-(sp)
    0x3F,0x3C,0x00,0x02,            # move.w #2,-(sp)  Cconout
    0x4E,0x41,                      # trap #1
    0x58,0x8F,                      # addq.l #4,sp
    0x3F,0x3C,0x00,0x0A,            # move.w #10,-(sp) '\n'
    0x3F,0x3C,0x00,0x02,            # move.w #2,-(sp)  Cconout
    0x4E,0x41,                      # trap #1
    0x58,0x8F,                      # addq.l #4,sp
    0x42,0x67,                      # clr.w -(sp)
    0x4E,0x41,                      # trap #1
])))

# ── reloc: PEA abs.l msg — exercises the loader's fixup engine ─────────
write("reloc.prg", prg(bytes([
    0x48,0x79,0x00,0x00,0x00,0x12,  # pea msg.l (link addr 0x12)
    0x3F,0x3C,0x00,0x09,            # move.w #9,-(sp) Cconws
    0x4E,0x41,                      # trap #1
    0x5C,0x8F,                      # addq.l #6,sp
    0x42,0x67,                      # clr.w -(sp)
    0x4E,0x41,                      # trap #1
]) + b"RELOC OK\r\n\x00", b"\x00\x00\x00\x02\x00"))  # fixup at off 0x02

# ── cond: CMPI.W #3,d0 ; BGT — signed conditional ─────────────────────
write("cond.prg", prg(bytes([
    0x70,0x05,                      # moveq #5,d0
    0x0C,0x40,0x00,0x03,            # cmpi.w #3,d0
    0x6E,0x06,                      # bgt.s yes (->0x0E)
    0x3F,0x3C,0x00,0x4E,            # move.w #'N',-(sp)
    0x60,0x04,                      # bra.s done (->0x12)
    0x3F,0x3C,0x00,0x59,            # yes: move.w #'Y',-(sp)
    0x3F,0x3C,0x00,0x02,            # done: move.w #2,-(sp) Cconout
    0x4E,0x41,                      # trap #1
    0x58,0x8F,                      # addq.l #4,sp
    0x42,0x67,                      # clr.w -(sp)
    0x4E,0x41,                      # trap #1
])))

# ── fwrite: Fwrite(1,5,"HELLO") to stdout ─────────────────────────────
write("fwrite.prg", prg(bytes([
    0x48,0x7A,0x00,0x1A,            # pea msg(pc)
    0x2F,0x3C,0x00,0x00,0x00,0x05,  # move.l #5,-(sp)  count
    0x3F,0x3C,0x00,0x01,            # move.w #1,-(sp)  handle=stdout
    0x3F,0x3C,0x00,0x40,            # move.w #0x40,-(sp) Fwrite
    0x4E,0x41,                      # trap #1
    0x4F,0xEF,0x00,0x0C,            # lea 12(sp),sp
    0x42,0x67,                      # clr.w -(sp)
    0x4E,0x41,                      # trap #1
]) + b"HELLO"))

# ── fileio: Fcreate/Fwrite/Fclose round-trip to out.txt ───────────────
write("fileio.prg", prg(bytes([
    0x42,0x67,                      # clr.w -(sp)  attr
    0x48,0x7A,0x00,0x32,            # pea fname(pc)
    0x3F,0x3C,0x00,0x3C,            # move.w #0x3C,-(sp) Fcreate
    0x4E,0x41,                      # trap #1
    0x4F,0xEF,0x00,0x08,            # lea 8(sp),sp
    0x3C,0x00,                      # move.w d0,d6  (save handle)
    0x48,0x7A,0x00,0x2A,            # pea msg(pc)
    0x2F,0x3C,0x00,0x00,0x00,0x05,  # move.l #5,-(sp) count
    0x3F,0x06,                      # move.w d6,-(sp) handle
    0x3F,0x3C,0x00,0x40,            # move.w #0x40,-(sp) Fwrite
    0x4E,0x41,                      # trap #1
    0x4F,0xEF,0x00,0x0C,            # lea 12(sp),sp
    0x3F,0x06,                      # move.w d6,-(sp) handle
    0x3F,0x3C,0x00,0x3E,            # move.w #0x3E,-(sp) Fclose
    0x4E,0x41,                      # trap #1
    0x58,0x8F,                      # addq.l #4,sp
    0x42,0x67,                      # clr.w -(sp)
    0x4E,0x41,                      # trap #1
]) + b"out.txt\x00" + b"HELLO"))

print("built:", ", ".join(sorted(f for f in os.listdir(HERE) if f.endswith(".prg"))))
