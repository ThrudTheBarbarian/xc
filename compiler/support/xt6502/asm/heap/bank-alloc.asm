; bank-alloc.asm — shared data-bank ownership allocator.
;
; A 256-bit (32-byte) bitmap, one bit per $D5C1 data page. Bit set = the
; bank is claimed (by the on-demand heap, by bank(), or by anything else
; that owns a data bank). Bank 0 — the main-RAM overlay ($D5C1 == 0) — is
; permanently reserved. Every data-bank owner claims and frees through
; here, so the heap and bank() can never hand out the same page.
;
; Routines (all preserve nothing unless noted):
;   _bank_init      clear the bitmap, reserve bank 0. Call once at boot.
;   _bank_claim     claim the lowest free bank. → A = id, C=0; C=1 if full.
;   _bank_claim_n   claim N contiguous free banks. X = N. → A = first id,
;                   C=0; C=1 if no run of N exists.
;   _bank_free      release bank id A.
;   _bank_is_free   C=0 if bank A is claimed, C=1 if free.

_bank_init:
    LDA #$00
    LDX #31
_bka_init_loop:
    STA _bank_bitmap,X
    DEX
    BPL _bka_init_loop
    LDA #$01                 ; reserve bank 0 (bit 0 of byte 0)
    STA _bank_bitmap
    RTS

; _bank_claim — lowest-fit. Scans the 32 bytes for one that isn't $FF,
; finds its lowest clear bit, sets it, returns bank id = byte*8 + bit.
_bank_claim:
    LDX #$00
_bkc_byte:
    LDA _bank_bitmap,X
    CMP #$FF                 ; all 8 bits claimed?
    BNE _bkc_found
    INX
    CPX #32
    BNE _bkc_byte
    SEC                      ; all 256 banks claimed
    RTS
_bkc_found:
    ; A = a byte with at least one clear bit. Find the lowest (bit Y).
    LDY #$00
_bkc_bit:
    LSR                      ; bit Y → carry
    BCC _bkc_take            ; clear → bank byte*8+Y is free
    INY
    BNE _bkc_bit             ; Y is 0..6 here, never wraps
_bkc_take:
    LDA _bit_mask,Y          ; set the bit
    ORA _bank_bitmap,X
    STA _bank_bitmap,X
    TXA                      ; id = X*8 + Y
    ASL
    ASL
    ASL                      ; X<32 ⇒ X*8 < 256, low 3 bits clear
    STY _bka_tmp
    ORA _bka_tmp
    CLC
    RTS

; _bank_claim_n — claim X contiguous free banks (for a future bank(N)
; wanting a span). Naive first-fit over bank ids 1..255. → A = first id,
; C=0; C=1 if no run fits. Bank 0 is reserved so runs start at 1.
_bank_claim_n:
    STX _bka_n
    LDA #$01                 ; candidate start id
    STA _bka_run_start
_bkn_try:
    LDA _bka_run_start
    CLC
    ADC _bka_n
    BCS _bkn_fail            ; start + N overflowed past 255 → no fit
    ; Check banks [run_start, run_start+N).
    LDX _bka_n
    LDA _bka_run_start
    STA _bka_scan
_bkn_scan:
    LDA _bka_scan
    JSR _bank_is_free
    BCC _bkn_gap             ; claimed → run broken
    INC _bka_scan
    DEX
    BNE _bkn_scan
    ; Run of N free banks at run_start — claim them all.
    LDX _bka_n
    LDA _bka_run_start
    STA _bka_scan
_bkn_set:
    LDA _bka_scan
    JSR _bank_set
    INC _bka_scan
    DEX
    BNE _bkn_set
    LDA _bka_run_start
    CLC
    RTS
_bkn_gap:
    ; advance past the claimed bank: next candidate = scan + 1
    INC _bka_scan
    LDA _bka_scan
    STA _bka_run_start
    JMP _bkn_try
_bkn_fail:
    SEC
    RTS

; _bank_claim_at — claim bank id A if it is free. → C=0 and the bit set
; on success; C=1 (already claimed) and the bitmap unchanged otherwise.
; A is preserved. Lets the heap grow strictly contiguously (claim
; hiwater+1) so a bank() reservation in its path causes a graceful OOM
; rather than a non-contiguous owned range.
_bank_claim_at:
    JSR _bank_is_free        ; preserves A (the bank id)
    BCC _bca_taken           ; already claimed
    PHA                      ; _bank_set clobbers A — keep the bank id
    JSR _bank_set            ; free → claim it
    PLA
    CLC
    RTS
_bca_taken:
    SEC
    RTS

; _bank_free — release bank id A (clear its bit).
_bank_free:
    PHA
    LSR
    LSR
    LSR                      ; A/8 = byte index
    TAX
    PLA
    AND #$07                 ; A&7 = bit index
    TAY
    LDA _bit_mask,Y
    EOR #$FF
    AND _bank_bitmap,X
    STA _bank_bitmap,X
    RTS

; _bank_set — internal: set bank id A's bit (mark claimed).
_bank_set:
    PHA
    LSR
    LSR
    LSR
    TAX
    PLA
    AND #$07
    TAY
    LDA _bit_mask,Y
    ORA _bank_bitmap,X
    STA _bank_bitmap,X
    RTS

; _bank_is_free — C=1 if bank id A is free, C=0 if claimed. Preserves A.
_bank_is_free:
    PHA
    LSR
    LSR
    LSR
    TAX                      ; X = byte index
    PLA
    PHA                      ; keep a copy of A on the stack
    AND #$07
    TAY                      ; Y = bit index
    LDA _bit_mask,Y
    AND _bank_bitmap,X       ; Z=1 if bit clear (free)
    BEQ _bif_free            ; branch on the AND result BEFORE restoring A
    PLA                      ; claimed: restore A, C=0
    CLC
    RTS
_bif_free:
    PLA                      ; free: restore A, C=1
    SEC
    RTS

_bit_mask:  .byte $01,$02,$04,$08,$10,$20,$40,$80
_bank_bitmap: .space 32
_bka_tmp:       .byte $00
_bka_n:         .byte $00
_bka_run_start: .byte $00
_bka_scan:      .byte $00
