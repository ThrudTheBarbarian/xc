// Narrow-int canonicalisation: wasm has only i32/i64, so u8/i8/u16/i16 live
// canonicalised in i32 locals (signed sign-extended, unsigned masked). Each
// case below broke — or nearly broke — during bring-up.
extern void putw(i32 v);

void main(void)
    {
    // u8 + u8 wraps at 8 bits (spec §3.1 — no same-width promotion).
    u8 a = 200;
    u8 b = 100;
    putw(a + b); // 44, not 300

    // Arithmetic shift of a signed narrow value.
    i8 x = -100;
    putw(x >> 2); // -25

    // LShr whose SOURCE is u16 but result stored narrow: the pre-mask must
    // key on the source width, not the result width (the T8 trap).
    u16 v = 1000;
    u8 t = v >> 8;
    putw(t); // 3

    // Unsigned compare on a masked narrow value (200 must not read as -56).
    u8 hi = 200;
    if (hi > 100)
        putw(1);
    else
        putw(0); // 1

    // Sign-extended i8 re-masked on the cast to unsigned.
    i8 neg = -1;
    u8 asU = (u8)neg;
    putw(asU); // 255
    }
