; float-cg.harness.asm — call run() (gR = (i16)(gA + gB)), print gR.
; gA = 1.5, gB = 3.25 -> sum 4.75 -> (i16)4. Expected: "4".
;
; Pulls in the real 5-byte float helpers so _fpAdd / _fpToI32
; resolve to the actual routines (not stubs) — this validates the
; xt6502 float codegen end-to-end on the xts simulator. Include
; paths resolve relative to the combined .asm under
; build/xt6502-fixtures/, hence the ../../ prefix to the repo root.

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59             ; SAVMSC = $9C00
    LDA #0
    STA $94             ; screen column = 0

    JSR _run
    LDA _gR
    LDX _gR+1
    JSR print_i16
    BRK

.include "../../support/xt6502/asm/float/fpAdd.asm"
.include "../../support/xt6502/asm/float/fpToI32.asm"

; The codegen emits `_`-prefixed helper names (matching the corpus's
; underscore stubs); the real helper sources use bare labels. Bridge
; them for this end-to-end fixture.
_fpAdd = fpAdd
_fpToI32 = fpToI32
