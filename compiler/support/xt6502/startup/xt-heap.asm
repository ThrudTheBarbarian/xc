; xt-heap.asm — banked xt startup with a data-pool heap
;
; Pairs with xt-heap.lnk. Initialises the software stack and
; heap pointer like the other xt variants, then selects the first
; heap bank into the data window ($83) so code can start using
; the heap immediately without per-access bank setup. $82 (the
; code-bank selector) is left at zero — the caller gets control
; of it directly.
;
; Substitution variables (resolved by the codegen):
;   {{zp.sp}}          stack pointer ZP address
;   {{zp.hp}}          heap pointer ZP address (legacy bump slot;
;                      unused under the free-list allocator but kept
;                      initialised for fallback bump-path sites)
;   {{zp.bankReg}}     bank-select register low byte ($82; data bank
;                      on $83 is {{zp.bankReg}} + 1)
;   {{heapBank}}       first heap bank id

    LDA #<stack_low
    STA {{zp.sp}}
    LDA #>stack_low
    STA {{zp.sp}} + 1

    LDA #<heap_top
    STA {{zp.hp}}
    LDA #>heap_top
    STA {{zp.hp}} + 1

    ; Code bank cleared: $82 points at "no code bank paged".
    ; Banked class / :banked function calls set $82 themselves
    ; via _xcall, so the initial value just needs to be sane.
    LDA #$00
    STA {{zp.bankReg}}

    ; Data bank: select the first heap bank into the $83-driven
    ; $6000-$7FFF window. The free-list allocator's internal
    ; walk still does per-allocation bank swaps via
    ; _heap_select_bank (which writes $83), but after each heap
    ; access the caller's window stays on the heap bank —
    ; consistent with the xe-heap convention.
    LDA #{{heapBank}}
    STA {{zp.bankReg}} + 1
