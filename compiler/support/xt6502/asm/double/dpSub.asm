; dpSub — subtract double operand2 from double operand1
; Input:  $B0-$B7 = op1, $B8-$BF = op2
; Output: $B0-$B7 = op1 - op2
;
; Method: negate op2's sign bit, then fall through to dpAdd.
;
; Zero op2 must NOT have its sign flipped — that would turn
; `0 - 0 = +0` into a `-0` result (flags $11 instead of $10). Skip
; the sign flip in that case; dpAdd's zero-handling path already
; does the right thing for `x - 0 = x`.
;
; NOTE: mirrored by generic/float/fpSub.asm; keep in sync.

dpSub:
    LDA $B8
    AND #$10                ; op2 zero?
    BNE dpAdd
    LDA $B8
    EOR #$01                ; flip sign bit of op2
    STA $B8
    JMP dpAdd
