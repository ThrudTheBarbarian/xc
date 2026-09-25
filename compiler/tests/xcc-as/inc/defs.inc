COUNT = 8
.macro wait n, v
        LDA #v
        LDX #n
