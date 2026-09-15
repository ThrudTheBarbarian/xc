; funcCall — bank-switched function call dispatcher
; Located at $0480 in non-swapped RAM
;
; Calling convention:
;   1. Caller pushes old page index on 6502 stack
;   2. Caller pushes new page index on 6502 stack
;   3. Caller stores function address in $0580,$0581
;   4. Caller JSRs to funcCall
;
; This routine:
;   1. Pulls new page index from stack
;   2. Stores it in $82 (bank-swap register for $6000-$7FFF)
;   3. JMPs through the vector at ($0580)

    .org $0480

funcCall:
    PLA             ; pull new page index
    STA $82         ; bank-swap code page at $6000-$7FFF
    JMP ($0580)     ; jump to function entry point
