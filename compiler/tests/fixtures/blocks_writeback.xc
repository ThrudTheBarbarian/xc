// blocks_writeback.xc — blocks v2: `block:` captures (task #26, note §4).
// Copy-in at creation, write-back through a hidden pointer at every
// invocation exit — emitted as a synthesized `defer`, so the throw path
// writes back too. The enclosing frame is correct the statement after a
// callback-taking call returns.
#import "Stdio.xc"
#import "Foundation.xc"

u32 drive(block cb u32(u32), u32 n)
{
    u32 acc = (u32)0;
    for (u32 i = (u32)0; i < n; i++) { acc = acc + cb(i); }
    return acc;
}

i32 main(void)
{
    // T1: accumulate across invocations driven by a callee.
    block:u32 total = (u32)0;
    u32 r = drive(block u32(u32 v) { total = total + v; return v; }, (u32)5);
    Stdio.printf("T1 %ld %ld\n", total, r);

    // T2: per-invocation write-back — visible between manual calls.
    block:u32 seen = (u32)100;
    block bump u32(u32 d) = { seen = seen + d; return seen; }
    u32 a = bump((u32)1);
    u32 mid = seen;                      // written back by the first call
    u32 b = bump((u32)2);
    Stdio.printf("T2 %ld %ld %ld %ld\n", a, mid, b, seen);

    // T3: read-only capture stays a snapshot alongside a write-back one.
    u32 base = (u32)1000;
    block:u32 sum = (u32)0;
    block add void(u32 v) = { sum = sum + base + v; }
    base = (u32)9999;                    // snapshot: adds still use 1000
    add((u32)1);
    add((u32)2);
    Stdio.printf("T3 %ld\n", sum);
    return 0;
}
