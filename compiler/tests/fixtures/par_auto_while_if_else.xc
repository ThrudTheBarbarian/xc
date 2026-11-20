//xtc-flags: target=arm64 --par-style=auto
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_auto_while_if_else.xc — with --par-style=auto, a counted while loop that
// is the lone statement of an if, an else or a loop body stays one statement
// (#488). The loop becomes a for loop with the counter set to the bound after
// it; the two go together, so an else after the loop belongs to the if around
// it, an if whose condition fails runs neither, and a loop around it runs both
// on every pass. A counted while inside another one's body keeps the counter
// value it leaves there too.
#import "Stdio.xc"
#import "Par.xc"
#define N 200000
u32 a[N];

// The loop as the then-branch, an else after it.
void thenWhile(u32 c)
{
    u32 v = 0;
    u32 x = 0;
    if (c == 1) while (v < N) { v = v + 1; } else x = 7;
    Stdio.printf("then c=%u: v=%u x=%u\n", c, v, x);
}

// The same with a loop whose body writes an array.
void thenWhileArray(u32 c)
{
    u32 v = 0;
    u32 x = 0;
    if (c == 1) while (v < N) { a[v] = v * 3; v++; } else x = 9;
    u64 s = 0;
    for (u32 k = 0; k < N; k++)
        s = s + a[k];
    Stdio.printf("then array c=%u: v=%u x=%u s=%llu\n", c, v, x, s);
}

// The loop as the else-branch.
void elseWhile(u32 c)
{
    u32 w = 0;
    u32 x = 0;
    if (c == 1) x = 1; else while (w < 50) { x = x + 2; w++; }
    Stdio.printf("else c=%u: w=%u x=%u\n", c, w, x);
}

// The loop as the body of a for loop, without braces: the first pass runs
// it, the later ones find the counter at the bound.
void forBody(void)
{
    u32 v = 0;
    u32 s = 0;
    for (u32 k = 0; k < 3; k++) while (v < 10) { s = s + v; v++; }
    Stdio.printf("for body: v=%u s=%u\n", v, s);
}

// A counted while inside another one's body.
void nested(void)
{
    u32 i = 0;
    u32 j = 0;
    u32 t = 0;
    while (i < 4) { while (j < 10) { t = t + 1; j++; } i++; }
    Stdio.printf("nested: i=%u j=%u t=%u\n", i, j, t);
}

i32 main(void)
{
    thenWhile(0);
    thenWhile(1);
    thenWhileArray(0);
    thenWhileArray(1);
    elseWhile(0);
    elseWhile(1);
    forBody();
    nested();
    return 0;
}
