; xt-shadow-heap.asm — banked xt startup + shadow ROM + data-pool heap
;
; Startup for the xt-shadow-heap.lnk layout — split banking +
; shadow ROM + data-pool heap. Identical to xt-shadow.asm except
; the data selector $83 is preloaded with heap_bank_first so the
; bank window exposes the heap from the first instruction of
; main(), matching xt-heap / xe-heap behaviour.
;
; $82 (code selector) stays at zero — banked calls set it
; themselves via _xcall. $83 (data selector) points at the
; heap bank; the free-list allocator's internal walk may swap
; it via _heap_select_bank during multi-bank allocation, but
; every heap entry point restores it to heap_bank_first before
; returning.
;
; Substitution variables (resolved by the codegen):
;   {{zp.sp}}              stack pointer ZP address
;   {{zp.hp}}              heap pointer ZP address
;   {{zp.bankReg}}         bank-select register low byte ($82 — code)
;   {{heapBank}}           first heap bank id
;   {{shadow.reg}}         shadow register address (e.g. $D301)
;   {{shadow.mask}}        shadow register bitmask
;   {{shadow.notMask}}     ~mask & $FF (pre-computed AND operand)
;   {{skipLabel}}           label to jump past trampoline body
;
; Shadow mode: ROM off by default. Charset copied to $2000,
; code starts at $2400 in the system region.

    ; Copy 1KB charset from current CHBAS to $2000
    LDA $02F4
    STA _shadow_src+2
    LDX #$04
    LDY #$00
_shadow_src:
    LDA $FF00,Y
    STA $2000,Y
    INY
    BNE _shadow_src
    INC _shadow_src+2
    INC _shadow_src+5
    DEX
    BNE _shadow_src

    LDA #$20
    STA $02F4
    STA $D409

    LDA #<stack_low
    STA {{zp.sp}}
    LDA #>stack_low
    STA {{zp.sp}} + 1

    LDA #<heap_top
    STA {{zp.hp}}
    LDA #>heap_top
    STA {{zp.hp}} + 1

    ; Initial bank state: code selector zero, data selector pointing
    ; at the first heap bank so `(sp),Y` / `(hp),Y` style heap loads
    ; work without a per-access bank select.
    LDA #$00
    STA {{zp.bankReg}}
    LDA #{{heapBank}}
    STA {{zp.bankReg}} + 1

    ; Shadow mode setup
    SEI
    LDA #$00
    STA $D40E

    ; Save the OS IRQ vector from ROM before ROM is disabled; see
    ; xe.asm for the full explanation. _shadow_irq below dispatches
    ; each IRQ / BRK through this saved vector so POKEY / serial /
    ; keyboard IRQs keep working under shadow mode.
    LDA $FFFE
    STA _shadow_irq_vec
    LDA $FFFF
    STA _shadow_irq_vec + 1

    ; Disable ROM before installing the vectors — see xe.asm for
    ; the atari800 write-through caveat.
    LDA {{shadow.reg}}
    AND #{{shadow.notMask}}
    STA {{shadow.reg}}

    LDA #<_shadow_nmi
    STA $FFFA
    LDA #>_shadow_nmi
    STA $FFFB

    LDA #<_shadow_irq
    STA $FFFE
    LDA #>_shadow_irq
    STA $FFFF

    LDA #$40
    STA $D40E
    CLI
    JMP {{skipLabel}}

_shadow_nmi:
    BIT $D40F
    BVS _shadow_vbi
    JMP ($0200)

_shadow_vbi:
    PHA
    TXA
    PHA
    TYA
    PHA

    LDA {{shadow.reg}}
    ORA #{{shadow.mask}}
    STA {{shadow.reg}}

    TSX
    LDA $0106,X
    STA _shadow_p_tmp

    LDA #>_shadow_nmi_epilogue
    PHA
    LDA #<_shadow_nmi_epilogue
    PHA
    LDA _shadow_p_tmp
    PHA

    CLD
    LDA #$00
    PHA
    PHA
    PHA

    STA $D40F
    JMP ($0222)

_shadow_nmi_epilogue:
    LDA {{shadow.reg}}
    AND #{{shadow.notMask}}
    STA {{shadow.reg}}

    PLA
    TAY
    PLA
    TAX
    PLA
    RTI

_shadow_p_tmp:
    .byte $00

; IRQ trampoline — dispatches IRQ / BRK through the saved OS IRQ
; vector with ROM re-enabled. See xe.asm for the full walkthrough.
_shadow_irq:
    PHA
    TXA
    PHA

    LDA {{shadow.reg}}
    ORA #{{shadow.mask}}
    STA {{shadow.reg}}

    TSX
    LDA $0103,X
    STA _shadow_irq_user_p
    LDA $0104,X
    STA _shadow_irq_user_pcl
    LDA $0105,X
    STA _shadow_irq_user_pch

    ; Force I=1 in the stacked P so the OS handler's RTI returns
    ; with interrupts masked — see xe.asm for the full rationale
    ; (prevents nested-IRQ reentry from clobbering user_p/pcl/pch).
    LDA $0103,X
    ORA #$04
    STA $0103,X

    LDA #<_shadow_irq_epilogue
    STA $0104,X
    LDA #>_shadow_irq_epilogue
    STA $0105,X

    PLA
    TAX
    PLA

    JMP (_shadow_irq_vec)

_shadow_irq_epilogue:
    PHA
    LDA {{shadow.reg}}
    AND #{{shadow.notMask}}
    STA {{shadow.reg}}
    PLA

    LDA _shadow_irq_user_pch
    PHA
    LDA _shadow_irq_user_pcl
    PHA
    LDA _shadow_irq_user_p
    PHA
    RTI

_shadow_irq_user_p:
    .byte $00
_shadow_irq_user_pcl:
    .byte $00
_shadow_irq_user_pch:
    .byte $00
_shadow_irq_vec:
    .word $0000

{{skipLabel}}:
