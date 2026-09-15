// ternary_struct.xc — an aggregate through a ternary.
//
// `cond ? structA : structB` lowered to a Phi of an AGGREGATE. But a phi is a
// REGISTER-level merge, and a struct value always lives in a frame slot (aggregates
// are never homed). So the edge copy sized a register from the phi's type, fell back
// to a one-word move, and copied only the FIRST FOUR BYTES — silently dropping the
// rest.
//
// An 8-byte Rect came back with its x,y intact and its w,h garbage. It compiles clean,
// naturally. Found as a damage rect of `12,38 9348x548`: position right, size junk, and
// different junk each run — the nastiest way for it to fail, since too small means
// repaints are silently incomplete and too large means the whole optimisation quietly
// does nothing while appearing to work.
//
// arm64, m68k and arm9 all had it; arm9 showed it honestly (0xa5a5 stack poison),
// arm64 and m68k just happened to read zeros. x86_64 and xt6502 were already correct.
//
// The if/else form has always worked (struct assignment is a proper block copy), so it
// is the oracle: BOTH lines must agree.

#import "Stdio.xc"

struct Rect { i16 x; i16 y; i16 w; i16 h; }        // 8 bytes: two words

Rect grow(Rect a) { Rect r; r.x = a.x; r.y = a.y; r.w = (i16)99; r.h = (i16)77; return r; }

i16 main(void)
{
    Rect abs;  abs.x = (i16)12; abs.y = (i16)38; abs.w = (i16)40; abs.h = (i16)20;
    bool hasDirty = false;

    // T1: the else arm — a plain struct local.
    Rect viaIf;
    if (hasDirty) { viaIf = grow(abs); } else { viaIf = abs; }
    Stdio.printf("if=%d,%d %dx%d\n", viaIf.x, viaIf.y, viaIf.w, viaIf.h);

    Rect viaT = hasDirty ? grow(abs) : abs;
    Stdio.printf("tern=%d,%d %dx%d\n", viaT.x, viaT.y, viaT.w, viaT.h);

    // T2: the then arm — a struct returned from a CALL (no address to phi).
    hasDirty = true;
    Rect viaT2 = hasDirty ? grow(abs) : abs;
    Stdio.printf("tern2=%d,%d %dx%d\n", viaT2.x, viaT2.y, viaT2.w, viaT2.h);
    return 0;
}
