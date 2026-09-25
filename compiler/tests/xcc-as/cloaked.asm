        .org $2400
        JSR $4000
        RTS
        .cloaked_segment $4000 none
        LDA #1
        RTS
        .cloaked_segment_end
        .cloaked_segment $4100 3
        RTS
        .cloaked_segment_end
        .org $6000
        RTS
