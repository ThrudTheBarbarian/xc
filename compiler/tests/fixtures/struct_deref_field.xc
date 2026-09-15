// struct_deref_field.xc — regression for `(@p).field` on a struct
// pointer. Documented as sugar for `p->field`, but pre-fix the dot
// form always read byte 0 (the deref's A-return) and ignored the
// field offset. Both forms now resolve via the same arrow-access
// path in emitMemberAccess.

#import "Stdio.xc"

typedef struct { u8 r; u8 g; u8 b; } RGB;
typedef struct { u16 w; u16 h; u8 tag; u8 flags; } Box;

void main(void) {
    RGB c = { $11, $22, $33 };
    RGB* p = &c;
    Box b = { $1234, $5678, $AB, $CD };
    Box* bp = &b;

    // Dot-form vs arrow-form must agree on every field and width.
    if ((*p).r == $11 && p->r == $11 &&
        (*p).g == $22 && p->g == $22 &&
        (*p).b == $33 && p->b == $33)
    {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL\n");
    }

    if ((*bp).w    == $1234 && bp->w    == $1234 &&
        (*bp).h    == $5678 && bp->h    == $5678 &&
        (*bp).tag  == $AB   && bp->tag  == $AB &&
        (*bp).flags== $CD   && bp->flags== $CD)
    {
        Stdio.printf("T2 PASS\n");
    } else {
        Stdio.printf("T2 FAIL\n");
    }
}
