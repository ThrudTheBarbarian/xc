// byte-list-init — `{ … }` / `[ … ]` byte-list initialisers set a
// sized scalar's raw byte pattern.
//
// bl(): integers assemble little-endian — u32 {$78,$56,$34,$12} =
// 0x12345678, low u16 = 0x5678 = 22136. Exact on both backends, no
// float runtime needed.
//
// three(): floats read the IEEE-754 pattern into the format-neutral
// Const, exactly like a float literal — {$00,$00,$40,$40} is 3.0f,
// little-endian. The IR golden shows `Const #fp4008000000000000`
// (= 3.0). It used to be the xtc 5-byte softfloat pattern
// {$00,$01,$80,$00,$00}; that format is retired (Task #835) and a
// `float` is four bytes on every target. Kept call-free at runtime so
// the harness needn't link the float→int helper.
u16 bl(void)
    {
    u32 v = {$78, $56, $34, $12};
    return (u16)v;
    }

float three(void)
    {
    float r = {$00, $00, $40, $40};
    return r;
    }
