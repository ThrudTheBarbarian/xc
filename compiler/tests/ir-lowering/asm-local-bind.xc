// Mirror of Stdio.scroll's body to repro the inline-asm-local binding.
class T
    {
    u16 screenBase; // offset 0 (+vtbl)
    u8 cols;
    u8 rows;

    static void scroll(void)
        {
        u16 sb = screenBase;
        u16 numCols = (u16)cols;
        u16 size = numCols * (u16)(rows - 1);
        u16 src = sb + numCols;
        u16 dst = sb;
        u8 szLo = (u8)(size & $FF);
        u8 szHi = (u8)(size >> 8);
        u8 cLo = (u8)numCols;
        asm
        {
            LDA dst
            STA $B0
            LDA dst+1
            STA $B1
            LDA src
            STA $B2
            LDA src+1
            STA $B3
            LDX szHi
            LDX szLo
            LDX cLo
        }
        }
    }

    void
    main(void)
    {
    T.scroll();
    }
