; Errors reported by pass 2: a mode the mnemonic lacks, a stack offset that
; does not fit, and a PSH frame too large for one instruction.
        .org $2000
        STX $12,X
        LDA +200,SP
        ADD SP,#-300
        PSH #300
        PLL #-1
        STA (+5,SP),Y
        LDA +3,SP,X
