// shadow_scopes.xc — a nested declaration SHADOWS an outer name; leaving the
// scope must restore the outer binding (finding #16, blewit spike).
//
// The lowering's name tables were flat: `for (u32 t ...)` after a
// `String* t` rebound the name for the rest of the function, so
//   - the enclosing scope's exit release released the LOOP COUNTER as if it
//     were the String — a u16 refcount write through an integer, SIGBUS
//     after main returned (only once the counter's slot-pair value cleared
//     the >= 0x10000 object guard, which is why small repros "worked");
//   - any read of the outer name after the block saw the shadow's value.
// Sentinels are $DE-style on purpose; zeros would pass by accident.
#import "Stdio.xc"
#import "Foundation.xc"

String* mk(string s) { return String.withCString(s); }

i32 main(void)
{
    // T1: plain-block shadow — outer read after the block.
    String* t = mk((u8*)"outer");
    {
        u32 t = (u32)$DEAD;
        Stdio.printf("T1 %lx\n", t);
    }
    Stdio.printf("T2 %s\n", t.cString());

    // T3: for-init shadow — the counter scopes to the loop, and the
    // enclosing exit must release the STRING, not the counter (the
    // crash needed the counter >= 0x10000, so run it that far).
    u32 acc = (u32)0;
    for (u32 t = (u32)0; t < (u32)$12000; t++) { acc = acc + (u32)1; }
    Stdio.printf("T3 %lx %s\n", acc, t.cString());

    // T4: for-in shadow — the loop variable scopes to the loop.
    u8 xs[3];
    xs[0] = (u8)$11; xs[1] = (u8)$22; xs[2] = (u8)$33;
    u32 sum = (u32)0;
    for (u8 t in xs) { sum = sum + (u32)t; }
    Stdio.printf("T4 %lx %s\n", sum, t.cString());

    // T5: shadow inside a nested block of a for body — two levels deep.
    String* u = mk((u8*)"deep");
    for (u32 i = (u32)0; i < (u32)2; i++) {
        String* u = mk((u8*)"inner");
        { u32 u = (u32)$BEEF; if (u == (u32)0) { Stdio.printf("no\n"); } }
    }
    Stdio.printf("T5 %s\n", u.cString());
    return 0;
}
