; fpSub — subtract float operand2 from float operand1
; Input:  $B0-$B4 = operand1, $B5-$B9 = operand2
; Output: $B0-$B4 = result
; Method: negate operand2 sign, then add.
;
; NOTE: mirrored by generic/double/dpSub.asm; keep in sync.
;
; Zero operand2 must NOT have its sign flipped — that would turn
; `0 - 0 = +0` into a `-0` result (flags byte $11 instead of $10).
; Skip the sign flip entirely in that case; fpAdd's zero-handling
; path already does the right thing for `x - 0 = x`.

fpSub:
    LDA $B5
    AND #$10            ; op2 zero?
    BNE fpAdd
    LDA $B5
    EOR #$01            ; flip sign bit of operand2
    STA $B5
    JMP fpAdd
