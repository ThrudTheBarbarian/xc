; An out-of-range branch becomes the inverse branch over a JMP, and BRA a plain
; JMP. Each pair sits just inside and just outside the -128..+127 reach. The
; rewrites move every label after them, and one branch is pushed out of range
; by an earlier rewrite, so it is caught on the second pass.
        .org $2000
top:    BEQ far                 ; forward, out of range, labelled
        BRA far                 ; out of range: a plain JMP
        BNE top                 ; backward, in range
; Forward: +127 stays, +128 is rewritten.
        BCC f127
        .space 127
f127:   BCS f128
        .space 128
f128:   NOP
; Backward: -128 stays, -129 is rewritten.
b128:   .space 126
        BPL b128
b129:   .space 127
        BMI b129
; +127 until the BVC inside its reach grows by three bytes.
        BVS late
        BVC far
        .space 125
late:   NOP
; The second statement of a compound line.
        CLC : BCC top
        .space 130
far:    BCC top                 ; backward, out of range, labelled
        RTS
