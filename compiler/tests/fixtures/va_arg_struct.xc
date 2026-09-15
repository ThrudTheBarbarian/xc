// va_arg_struct.xc — regression for the va_arg(ap, T@) struct-pointer
// sugar (Level 1 of the va_arg-struct feature).
//
// A user variadic receives a struct by value. The caller's packer
// emits the struct's raw bytes at full struct width into the shared
// pack buffer. The callee reads them via va_arg(ap, T@), which
// returns a typed pointer into the buffer and advances the cursor
// by sizeof(T).
//
// Field access through the returned pointer uses the `->` sugar —
// (@sp).field has a pre-existing bug that always reads byte 0 and
// is unrelated to this feature; see TODO.txt.
//
// Three shapes exercised:
//   T1  3-byte struct (RGB) — odd size, no alignment
//   T2  6-byte struct (Box) — mixed widths (u16 + u8)
//   T3  mixed trailing scalars after the struct — verifies cursor
//       advances by exactly sizeof(T), not more or less

#import "Stdio.xc"

typedef struct { u8 r; u8 g; u8 b; } RGB;
typedef struct { u16 w; u16 h; u8 tag; u8 flags; } Box;

u8 r_r; u8 r_g; u8 r_b;
u16 b_w; u16 b_h; u8 b_tag; u8 b_flags;
u8 trailing;

void takeRGB(string tag, ...) {
    u8 ap;
    va_start(ap);
    RGB* sp = va_arg(ap, RGB*);
    r_r = sp->r;
    r_g = sp->g;
    r_b = sp->b;
    va_end(ap);
}

void takeBox(string tag, ...) {
    u8 ap;
    va_start(ap);
    Box* bp = va_arg(ap, Box*);
    b_w     = bp->w;
    b_h     = bp->h;
    b_tag   = bp->tag;
    b_flags = bp->flags;
    va_end(ap);
}

void takeBoxThenU8(string tag, ...) {
    u8 ap;
    va_start(ap);
    Box* bp = va_arg(ap, Box*);
    u8   n  = va_arg(ap, u8);
    b_w      = bp->w;
    b_h      = bp->h;
    b_tag    = bp->tag;
    b_flags  = bp->flags;
    trailing = n;
    va_end(ap);
}

void main(void) {
    RGB c = { $11, $22, $33 };
    takeRGB("rgb", c);
    if (r_r == $11 && r_g == $22 && r_b == $33) {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL r=%x g=%x b=%x\n", (u16)r_r, (u16)r_g, (u16)r_b);
    }

    Box x = { $1234, $5678, $AB, $CD };
    takeBox("box", x);
    if (b_w == $1234 && b_h == $5678 && b_tag == $AB && b_flags == $CD) {
        Stdio.printf("T2 PASS\n");
    } else {
        Stdio.printf("T2 FAIL w=%x h=%x tag=%x flags=%x\n",
            b_w, b_h, (u16)b_tag, (u16)b_flags);
    }

    Box y = { $2211, $4433, $55, $66 };
    takeBoxThenU8("mix", y, (u8)$99);
    if (b_w == $2211 && b_h == $4433 && b_tag == $55 &&
        b_flags == $66 && trailing == $99) {
        Stdio.printf("T3 PASS\n");
    } else {
        Stdio.printf("T3 FAIL w=%x h=%x tag=%x flags=%x trail=%x\n",
            b_w, b_h, (u16)b_tag, (u16)b_flags, (u16)trailing);
    }
}
