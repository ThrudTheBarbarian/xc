; funcReturn — bank-switched function return dispatcher
; Located at $0500 in non-swapped RAM
;
; Called by function epilogue via JMP funcReturn.
; At this point, old page index is on the 6502 stack (pushed by caller).
;
; This routine:
;   1. Pulls old page index from stack
;   2. Stores it in $82 (restores caller's code page)
;   3. RTS (returns to caller's JSR funcCall + 1)

    .org $0500

funcReturn:
    PLA             ; pull old page index
    STA $82         ; restore caller's code page
    RTS
