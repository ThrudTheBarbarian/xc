; bank-xt.asm — xt banked-heap bank driver.
;
; heap.asm is bank-agnostic: it walks one or more heap banks through three
; hooks the layout supplies — _heap_select_bank, _heap_save_caller_bank,
; _heap_restore_caller_bank — plus the bank-bound equates (heap_bank_first
; / heap_bank_last / regC_*) and the window addresses (heap_low / heap_end).
; This file supplies those hooks for the xt data-bank window: the
; __bank_data_reg byte ($D5C1) selects a 12 KB page at $A000-$CFFF, so
; every heap bank shares the same window and the per-bank "address" is just
; the page selector. With 3-byte uniform pointers there is no bank-hi.
; (Flat-heap targets supply RTS no-op hooks instead — see the corpus
; harness's flat config.)
;
; The includer must define, before including this file:
;   heap_bank_first / heap_bank_last   1-based data-page ids (e.g. $01..$08)
;   regC_heap_bank_first / _last = $00  (no region C on xt)
;   heap_low  = $A000   heap_end = $D000   (the 12 KB data window)
;   regC_heap_low / regC_heap_end = $0000
; and call _heap_init once at boot (with __bank_data_reg = 0, the main-RAM page).
;
; __bank_data_reg is callee-saved across every heap entry point: each saves
; the caller's selector on entry and restores it on exit, so a heap call
; never perturbs the data page the caller had mapped. The selector is
; restored to whatever the caller had (0 = main RAM for non-heap code).
; _xcall swaps __bank_code_reg only, never __bank_data_reg, so the
; discipline holds across banked calls too.

; _heap_select_bank — map data page into $A000-$CFFF.
; A = bank-lo (1-based page id). With 3-byte uniform pointers there is no
; bank-hi. The selector is the single byte placed in __bank_data_reg.
; Preserves nothing (heap.asm reloads what it needs after the switch).
_heap_select_bank:
    STA __bank_data_reg
    RTS

; _heap_save_caller_bank — stash the caller's data-bank selector. Preserves
; A/X (callers stage the object pointer there across the call) and Y.
_heap_save_caller_bank:
    STA _hbn_a
    STX _hbn_x
    LDA __bank_data_reg
    STA _hbn_sel
    LDX _hbn_x
    LDA _hbn_a
    RTS

; _heap_restore_caller_bank — put the caller's selector back. Tail-called
; (JMP) from the heap entry points, so it must preserve the A/X return
; value (the allocated / freed pointer).
_heap_restore_caller_bank:
    STA _hbn_a
    STX _hbn_x
    LDA _hbn_sel
    STA __bank_data_reg
    LDX _hbn_x
    LDA _hbn_a
    RTS

; Scratch. heap.asm is non-reentrant, so a single save slot suffices: the
; save→...→restore bracket of one heap entry never nests another.
_hbn_a:   .byte $00
_hbn_x:   .byte $00
_hbn_sel: .byte $00
