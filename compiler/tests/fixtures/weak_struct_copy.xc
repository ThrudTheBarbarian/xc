// weak_struct_copy.xc — copying a struct must RE-LINK its auto-zeroing slots.
//
// An aggregate copy is a Load+Store of the whole struct, so it duplicates the
// payload AND the two hidden link words — but linking is a side effect the copy
// never performed. The destination therefore LOOKED registered and was not:
// when the referent died the runtime walked its chain, found only the source
// slot and zeroed that one, while the copy kept its stale pointer. `if (h.p)`
// tested true and the call went through freed memory.
//
// Both slot kinds ride the same links, so both were affected — this was NOT a
// `^`-specific bug, which is why the fix is in the copy path rather than a ban
// on one of the spellings.
//
//   T1  `weak:C@`  copied by INITIALISATION   (S b = a)
//   T2  `weak:C@`  copied by ASSIGNMENT       (b = a)
//   T3  `act_t^`   copied by initialisation
//
// The source must still be correct afterwards (checked in every case): the fix
// zeroes the destination's copied link words BEFORE registering, because
// _xtc_weak_register unlinks using the slot's CURRENT links. Registering a
// fresh copy while it still held the source's pprev/next would splice the
// destination into the source's neighbours and write through them.
//
// Every local has its OWN name and there are no nested scopes: reusing a name
// across sibling blocks makes the frame allocator reuse one pinned slot for
// differently-shaped structs, which is a real difference between the two
// compilers but has nothing to do with what this fixture is pinning.
#import "Stdio.xc"

typedef u16 act_t(void);

class C
{
    u16  v;
    void init(void)    { v = (u16)9; }
    u16  g(void)       { return v; }
    void dealloc(void) { Stdio.printf("died\n"); }
}

struct WH { weak:C* p; }
struct AH { act_t^ a; }

void main(void)
{
    // T1: weak pointer, copied by initialisation.
    WH w1; C* c1 = new C();
    w1.p = c1;
    WH w2 = w1;
    Stdio.printf("t1-alive=%d\n", (u16)(w2.p != (C*)0 ? (u16)1 : (u16)0));
    c1 = 0;
    Stdio.printf("t1-src=%d t1-copy=%d\n",
                 (u16)(w1.p != (C*)0 ? (u16)1 : (u16)0),
                 (u16)(w2.p != (C*)0 ? (u16)1 : (u16)0));

    // T2: weak pointer, copied by assignment.
    WH w3; WH w4; C* c2 = new C();
    w3.p = c2;
    w4 = w3;
    c2 = 0;
    Stdio.printf("t2-src=%d t2-copy=%d\n",
                 (u16)(w3.p != (C*)0 ? (u16)1 : (u16)0),
                 (u16)(w4.p != (C*)0 ? (u16)1 : (u16)0));

    // T3: bound method, copied by initialisation.
    AH a1; C* c3 = new C();
    a1.a = &c3.g;
    AH a2 = a1;
    Stdio.printf("t3-alive=%d\n", (u16)(a2.a ? (u16)1 : (u16)0));
    c3 = 0;
    Stdio.printf("t3-src=%d t3-copy=%d\n",
                 (u16)(a1.a ? (u16)1 : (u16)0),
                 (u16)(a2.a ? (u16)1 : (u16)0));
}
