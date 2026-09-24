// ptr_width_ok.xc — what the width check must NOT refuse.
//
// Same width with a different SIGN is everywhere and harmless; `void*` is the
// escape hatch; a cast says "I meant it". If any of these starts failing, the
// check has been widened past what was measured. private:docs/bugs/244.
//
// The cast case deliberately narrows — `u32*` onto an i64 — so it writes FOUR
// bytes into eight. The reverse would write eight into four and smash whatever
// follows, which is the very thing the check exists to stop; a fixture must
// not depend on it. That is why the sentinel below is checked on the low half.
#import "Stdio.xc"

void sameWidth(u32* o)   { o[0] = (u32)7; }
void anyPointer(void* o) { }
void wide(i64* o)        { o[0] = (i64)9; }

void main()
{
    i32 s = (i32)0;
    sameWidth(&s);                 // sign only, same width
    anyPointer(&s);                // void*
    i64 w = (i64)0;
    anyPointer(&w);
    wide(&w);                      // exact
    i64 c = (i64)0;
    sameWidth((u32*)&c);           // cast: deliberate, and allowed
    Stdio.printf("s=%d w=%ld c=%ld\n", s, (u32)w, (u32)c);
}
