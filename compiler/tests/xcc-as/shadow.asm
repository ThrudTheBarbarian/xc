; Bytes that land in shadowed RAM are staged and copied in by an INITAD stub.
        .shadow_ranges $C000-$C0FF, $D800-$D8FF
        .shadow_stage $4000
        .org $BFF0
        .byte 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20
        .org $D800
        LDA #1
        RTS
        .org $2000
        RTS
