//xtc-flags: skip
// ^ Needs an Atari OS ROM (xts -r support/xt6502/rom/ATARIOSB.ROM)
//   and the xl-shadow layout — corpus xt6502 runs xt-heap without
//   ROM, so the ROM-dependent paths (T2/T4) cannot succeed.
//   arm64 has no Shadow RAM concept at all. Verify manually on a
//   real Atari emulator or `xts -r` with the right ROM.
// Shadow RAM regression test (ROM off by default).
//
// Compile with: xtc shadow_ram.xc -o shadow_ram.xex -m atari/xl-shadow
// Run on:       atari800 -xl shadow_ram.xex
//               xts -r support/xt6502/rom/ATARIOSB.ROM -M 5000000 shadow_ram.xex
//
// Tests:
//   T1  Shadow RAM write/read — ROM is off, write $DE to $FE00,
//       read it back. Proves shadow RAM is directly accessible.
//   T2  ROM content preserved — enable ROM, read $FE00, verify
//       it returns the ROM byte (not $DE).
//   T3  Shadow RAM survives ROM flip — disable ROM, verify $FE00
//       still has $DE.
//   T4  OS VBI still running — RTCLOK ($14) advances between
//       frames. Only passes on a real emulator (xts has no VBI).
//   T5  printf works — proves Stdio output functions with ROM off.
//
// Expected output (atari800):
//   T1 PASS
//   T2 PASS
//   T3 PASS
//   T4 PASS
//   T5 PASS
//   DONE 5

#import "Stdio.xc"

u8 shadowVal;
u8 romByte;
u8 clock1;
u8 clock2;

void main(void)
{
    u16 spin;

    // T1: ROM is off by default. Write/read shadow RAM at $FE00.
    asm {
        LDA #$DE
        STA $FE00
        LDA #$AD
        STA $FE01
        LDA #$BE
        STA $FE02
        LDA #$EF
        STA $FE03
        LDA $FE00
        STA <shadowVal>
    }
    if (shadowVal == $DE) { Stdio.printf("T1 PASS\n"); }
    else { Stdio.printf("T1 FAIL shadowVal=$%x\n", shadowVal); }

    // T2: Enable ROM, read $FE00 — should be the ROM byte.
    asm {
        LDA $D301
        ORA #$01
        STA $D301
        LDA $FE00
        STA <romByte>
        LDA $D301
        AND #$FE
        STA $D301
    }
    if (romByte != $DE) { Stdio.printf("T2 PASS\n"); }
    else { Stdio.printf("T2 FAIL romByte=$%x (same as shadow!)\n", romByte); }

    // T3: ROM is off again — $FE00 should still be $DE.
    asm {
        LDA $FE00
        STA <shadowVal>
    }
    if (shadowVal == $DE) { Stdio.printf("T3 PASS\n"); }
    else { Stdio.printf("T3 FAIL shadowVal=$%x\n", shadowVal); }

    // T4: OS VBI still running — RTCLOK ($14) should advance.
    asm { LDA $14 : STA <clock1> }
    spin = 0;
    while (spin < 20000) { spin = spin + 1; }
    asm { LDA $14 : STA <clock2> }
    if (clock1 != clock2) { Stdio.printf("T4 PASS\n"); }
    else { Stdio.printf("T4 FAIL clock stuck at %u\n", clock1); }

    // T5: printf works with ROM off.
    Stdio.printf("T5 PASS\n");

    Stdio.printf("DONE 5\n");
    while (1) { }
}
