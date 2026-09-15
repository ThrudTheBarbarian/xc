// global_struct_init.xc — constant-folding of aggregate global
// initialisers.
//
// Until phase-576 the IR lowering only folded a *flat* array of
// scalars. Everything else fell off the end of tryFoldInitialiser:
//
//   - a nested brace list (`OBJECT tree[] = {{…},{…}}`) hit the
//     non-foldable path, emitted a *note*, and zero-initialised the
//     whole table — the program silently read back zeros;
//   - a plain struct global (`OBJECT one = {$DEAD, $BEEF, $C3}`) fell
//     into the scalar byte-list path, which packs one BYTE per brace
//     entry, so multi-byte fields were silently corrupted with no
//     diagnostic at all.
//
// Sentinels are deliberately byte-ASYMMETRIC ($DEAD, not $1111) so a
// byte-order or offset slip can't pass by coincidence.
#import "Stdio.xc"

struct OBJECT { u16 next; u16 head; u8 flags; }

// Nested brace list, explicit length.
OBJECT tree[2]   = { {$DEAD, $BEEF, $C3}, {$1234, $5678, $9A} };
// Nested brace list, length inferred from the initialiser.
OBJECT unsized[] = { {$0102, $0304, $05}, {$0607, $0809, $0A} };
// Plain struct: fields land at their own byte offsets, not one-per-byte.
OBJECT one       = { $CAFE, $BABE, $42 };
// Short initialiser: the missing tail stays zeroed.
OBJECT shortie   = { $F00D };
// Flat array of multi-byte scalars (the path that already worked).
u16    flat[2]   = { $AA55, $55AA };
// Guard: proves the aggregate writes don't overrun into a neighbour.
u8     guard     = $DE;

// Mixed members. A POINTER member differs only in width across backends (2 on
// arm64's IR layout, 3 banked on xt6502, 8 in arm64's own layout), and a FLOAT
// member differs in *format* (xtc 5-byte vs IEEE) — both are re-laid into the
// backend's layout by XTAggInitRelay, so both fold. `-0.25` is a negate node,
// not a literal, which is worth pinning too.
struct Node { u16 tag; u8* link; float coef; u16 tail; }
Node mixed[2] = { {$DEAD, 0, 1.5, $C3C3}, {$BEEF, 0, -0.25, $5A5A} };
// 3.14159 needs its whole mantissa: 1.5 and -0.25 are exact in the top bytes,
// so they survived a truncated float encoding by luck and hid a real precision
// loss (3.14159 came back as 3.141571). Checked by COMPARING against the same
// literal rather than printing it — xtc's 5-byte float and IEEE single round
// 3.14159 to different last digits, so an exact rendering can't be asserted
// across targets, but "the stored value equals the literal" holds in any float
// format and still fails if a mantissa byte is dropped.
Node prec[1]  = { {$0F0F, 0, 3.14159, $F0F0} };

void main()
{
    Stdio.printf("t0=%x,%x,%x\n",  tree[0].next, tree[0].head, tree[0].flags);
    Stdio.printf("t1=%x,%x,%x\n",  tree[1].next, tree[1].head, tree[1].flags);
    Stdio.printf("u0=%x,%x,%x\n",  unsized[0].next, unsized[0].head, unsized[0].flags);
    Stdio.printf("u1=%x,%x,%x\n",  unsized[1].next, unsized[1].head, unsized[1].flags);
    Stdio.printf("one=%x,%x,%x\n", one.next, one.head, one.flags);
    Stdio.printf("sh=%x,%x,%x\n",  shortie.next, shortie.head, shortie.flags);
    Stdio.printf("fl=%x,%x\n",     flat[0], flat[1]);
    Stdio.printf("gd=%x\n",        guard);
    Stdio.printf("m0=%x,%f,%x\n", mixed[0].tag, mixed[0].coef, mixed[0].tail);
    Stdio.printf("m1=%x,%f,%x\n", mixed[1].tag, mixed[1].coef, mixed[1].tail);
    if (mixed[0].link == 0 && mixed[1].link == 0) Stdio.printf("links=null\n");
    if (prec[0].coef == 3.14159) Stdio.printf("pr=ok\n"); else Stdio.printf("pr=BAD\n");
    Stdio.printf("pr=%x,%x\n", prec[0].tag, prec[0].tail);
}
