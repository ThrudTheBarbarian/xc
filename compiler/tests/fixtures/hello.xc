// hello.xc — minimal xtc program: a local, a computation, and proof it ran.
#import "Stdio.xc"

void main(void)
{
    u8 x = $5A;            // 90 — distinctive, not $00/$FF
    u8 y = x + $07;        // 97
    Stdio.printf("x=%d y=%d\n", (u16)x, (u16)y);
    return;
}
