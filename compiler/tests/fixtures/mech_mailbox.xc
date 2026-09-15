//xtc-flags: target=xt6502
// mech0.xc — Phase 0 smoke test for the xts MECH mailbox model.
// Drives the math coprocessor by hand through an asm{} block: map the page,
// poke i32 operands into the slot file, write a MUL/DIV/ADD program, ring the
// doorbell, poll done, copy results out, unmap — then print. Needs no compiler
// MECH support; it validates the xts overlay + $D5C6-$D5C8 registers + interp.

#import "Stdio.xc"

u8 p0; u8 p1;      // product   S2  (i32 mul)
u8 q0; u8 q1;      // quotient  S3  (i32 div)
u8 m0; u8 m1;      // sum       S4  (i32 add)
u8 f0; u8 f1;      // f32 mul -> cvt i32  S11
u8 v0; u8 v1;      // vector sum S14 (VSUM i32)
u8 stat;           // MECH status byte

void main(void)
{
    asm {
        LDA #$01
        STA $D5C6

        LDA #$E8
        STA $4040
        LDA #$03
        STA $4041
        LDA #$00
        STA $4042
        STA $4043
        LDA #$07
        STA $4048
        LDA #$00
        STA $4049
        STA $404A
        STA $404B

        LDA #$00
        STA $4080
        STA $4081
        LDA #$60
        STA $4082
        LDA #$40
        STA $4083
        LDA #$00
        STA $4088
        STA $4089
        STA $408A
        LDA #$40
        STA $408B

        LDA #$0B
        STA $40A0
        LDA #$00
        STA $40A1
        STA $40A2
        STA $40A3
        LDA #$16
        STA $40A4
        LDA #$00
        STA $40A5
        STA $40A6
        STA $40A7
        LDA #$21
        STA $40A8
        LDA #$00
        STA $40A9
        STA $40AA
        STA $40AB
        LDA #$2C
        STA $40AC
        LDA #$00
        STA $40AD
        STA $40AE
        STA $40AF

        LDA #$83
        STA $4840
        LDA #$00
        STA $4841
        LDA #$01
        STA $4842
        LDA #$02
        STA $4843
        LDA #$84
        STA $4844
        LDA #$00
        STA $4845
        LDA #$01
        STA $4846
        LDA #$03
        STA $4847
        LDA #$81
        STA $4848
        LDA #$00
        STA $4849
        LDA #$01
        STA $484A
        LDA #$04
        STA $484B
        LDA #$03
        STA $484C
        LDA #$08
        STA $484D
        LDA #$09
        STA $484E
        LDA #$0A
        STA $484F
        LDA #$A0
        STA $4850
        LDA #$0A
        STA $4851
        LDA #$00
        STA $4852
        LDA #$0B
        STA $4853
        LDA #$BC
        STA $4854
        LDA #$0C
        STA $4855
        LDA #$00
        STA $4856
        LDA #$0E
        STA $4857
        LDA #$04
        STA $4858
        LDA #$01
        STA $4859
        LDA #$00
        STA $485A
        STA $485B

        LDA #$07
        STA $4000
        LDA #$00
        STA $4001

        STA $D5C7
mcpoll:
        LDA $D5C7
        AND #$01
        BEQ mcpoll

        LDA $4050
        STA p0
        LDA $4051
        STA p1
        LDA $4058
        STA q0
        LDA $4059
        STA q1
        LDA $4060
        STA m0
        LDA $4061
        STA m1
        LDA $4098
        STA f0
        LDA $4099
        STA f1
        LDA $40B0
        STA v0
        LDA $40B1
        STA v1
        LDA $4003
        STA stat

        LDA #$00
        STA $D5C6
    }

    Stdio.printf("prod=%d quot=%d sum=%d fmul=%d vsum=%d status=%d\n",
        (i16)(p0 | (p1 << 8)), (i16)(q0 | (q1 << 8)),
        (i16)(m0 | (m1 << 8)), (i16)(f0 | (f1 << 8)),
        (i16)(v0 | (v1 << 8)), (i16)stat);
}
