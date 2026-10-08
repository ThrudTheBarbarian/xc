//xtc-flags: target=arm64
// arc_pinned_decl_temp.xc — a declaration whose local lives in a frame slot
// releases its initialiser's temporaries.
//
// `u32 n = Tok.make(5).value();` makes a +1 Tok that nothing adopts: the slot
// takes the u32. When `n` is an SSA local the end of the statement released
// the Tok. When `n` is PINNED — its address is taken, it is declared in a
// function with a goto, or the build is -g — the reference's pinned path
// returned without releasing it and the next statement's boundary dropped it
// untracked, so the Tok leaked (the port mirrored that under -g only). Both
// compilers now release a pinned declaration's temps as they do an SSA one's.
//
// Each check reads the dealloc count on the statement AFTER the declaration:
// the Tok has to die at the end of its own statement, not at scope exit.

#import "Stdio.xc"
#import "Assert.xc"

u16 tokDealloc;

class Tok
{
    u32 _v;
    static Tok* make(u32 v) { Tok* t = new Tok(); t._v = v; return t; }
    u32 value(void) { return _v; }
    void dealloc(void) { tokDealloc = tokDealloc + 1; }
}

// `n` is pinned because `&n` is taken below.
u32 addrTaken(void)
{
    u32 n = Tok.make((u32)5).value();
    Assert.isEqual(tokDealloc, 1);               // T1 the Tok died with its statement
    u32* p = &n;
    *p = *p + (u32)1;
    return n;
}

// Every local of a goto function is pinned.
u32 withGoto(void)
{
    u32 a = Tok.make((u32)10).value();
    Assert.isEqual(tokDealloc, 2);               // T3 pinned by the goto, released all the same
    u32 b = Tok.make((u32)20).value();
    Assert.isEqual(tokDealloc, 3);               // T4 and the second one
    if (a > (u32)0)
        goto done;
    b = (u32)0;
done:
    return a + b;
}

void main(void)
{
    Assert.reset();
    tokDealloc = 0;
    Assert.isEqual(addrTaken(), (u32)6);         // T2 the slot still holds the value
    Assert.isEqual(withGoto(), (u32)30);         // T5
    Assert.isEqual(tokDealloc, 3);               // T6 nothing leaked, nothing freed twice
    Assert.summary();
}
