// sizeof_widths.xc — sizeof reports the OPERAND's width.
//xtc-na: m68k — m68k sizeof follows the m68k C ABI since blewit #5 (tail rounds to 2, so {u8*,u16} is 6 not 8); the shared oracle encodes the 8-cap sizes and the width-invariant tripwire guards the m68k numbers
//
// lowerSizeofExpr read the width off node.resolvedType, which is the type of
// the sizeof *expression* (u16) rather than the type being measured. So every
// sizeof evaluated to sizeof(u16) == 2 — sizeof(u8), sizeof(u32) and
// sizeof(some_struct) all came back 2. Nothing covered it.
//
// The pointer line is target-dependent by design, so it is checked against a
// relation rather than a literal: a pointer must be wide enough to be a real
// address on the target (3 on xt6502, 4 on m68k/arm9, 8 on arm64/x86-64), and
// a struct's size must be the sum of its members, not a fixed 2. `sizeof(u8@)`
// used to report 2 on arm64 while the backend laid pointers out 8 wide, so a
// struct with a pointer member got a 2-byte slot and the 64-bit store overran.
#import "Stdio.xc"

struct P { u8* p; u16 tag; }

void main()
{
    u16 ptr = sizeof(u8*);
    u16 pst = sizeof(P);

    Stdio.printf("u8=%d u16=%d u32=%d\n", sizeof(u8), sizeof(u16), sizeof(u32));
    // A pointer is at least 3 bytes on every live target, and never 2.
    if (ptr >= 3)        Stdio.printf("ptr-wide=ok\n");   else Stdio.printf("ptr-wide=BAD\n");
    // struct P is a pointer plus a u16, ROUNDED UP to the struct's alignment
    // (bug 015 — C pads `sizeof` up so an array strides right). The pointer is
    // the widest member, so P aligns to it; rounding (ptr+2) up to a multiple of
    // `ptr` gives the padded size on every target (arm64 16, m68k/arm9 8, xt6502
    // 6 — 3-byte ptr rounds the 5-byte body up to 6 either way).
    u16 padded = ((ptr + 2 + ptr - 1) / ptr) * ptr;
    if (pst == padded)   Stdio.printf("struct-sum=ok\n"); else Stdio.printf("struct-sum=BAD\n");
}
