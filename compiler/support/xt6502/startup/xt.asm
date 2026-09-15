; xt.asm — banked xt startup (two independent 8 KB bank windows)
;
; Substitution variables (resolved by the codegen):
;   {{zp.sp}}              stack pointer ZP address
;   {{zp.hp}}              heap pointer ZP address
;   {{zp.bankReg}}         bank-select register low byte ($82)
;
; Each selector is an independent 8-bit bank id: $82 governs the
; code window at $4000-$5FFF, $83 governs the data window at
; $6000-$7FFF. We zero both at boot.

    LDA #<stack_low
    STA {{zp.sp}}
    LDA #>stack_low
    STA {{zp.sp}} + 1

    LDA #<heap_top
    STA {{zp.hp}}
    LDA #>heap_top
    STA {{zp.hp}} + 1

    ; Initial bank state: no bank paged in on either selector.
    ; $82 is the code-bank register; $83 is the data-bank register.
    LDA #$00
    STA {{zp.bankReg}}
    STA {{zp.bankReg}} + 1
