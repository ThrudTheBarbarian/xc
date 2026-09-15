// A pinned local (struct, not &-taken) live ACROSS a call must keep its
// bytes. The xt6502 ZP pinned-local pool used to reset per function, so a
// callee's pinned locals aliased the caller's storage — phase-118 fixed the
// &-taken case (escapesViaPointer) and left this shape noted as an open
// hazard with no fixture. The callee writes distinctive sentinels ($BEEF /
// $CAFE) over where aliasing would land; the caller's $DEAD/$1234 must
// survive them.
#import "Stdio.xc"
struct S { u16 x; u16 y; };
void clobber(void)
{
    S t;
    t.x = (u16)$BEEF; t.y = (u16)$CAFE;
    Stdio.printf("%x\n", t.x);
}
void main(void)
{
    S s;
    s.x = (u16)$DEAD; s.y = (u16)$1234;
    clobber();
    Stdio.printf("%x %x\n", s.x, s.y);
}
