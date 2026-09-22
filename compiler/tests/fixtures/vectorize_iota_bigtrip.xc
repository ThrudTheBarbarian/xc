//xtc-flags: target=arm64 skip
// A reduction whose ELEMENT is the induction variable — `acc += f(r)` with no
// array in sight. The vectoriser builds the lane-index vector <0,1,2,3> from a
// read-only global and adds a splat of the base, so there are no loads to take
// a lane type from: the type comes from the induction variable itself.
//
// COMPILE-ONLY (skip): 2.8e9 iterations is far too slow to run. It exists
// for opt-diff, which compares the two optimisers without executing.
//
// This shape had NO fixture, and that is the point of adding one. The
// reference vectorises it and the shipped compiler does not — 100 NEON
// instructions against none — while opt-diff reported 796 of 796 agreeing,
// because nothing in the corpus made the two optimisers meet this case.
// A differential gate only covers what some file exercises.
#use Stdio

u32 leaf(u32 x) { return (x * (u32)3) ^ (x >> (u32)2); }

i32 main(i32 argc, u8** argv)
{
    u32 seed = (u32)argc;
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)2800000000; r++)
        acc = acc + leaf(leaf(r + seed));
    Stdio.printf("%lu\n", acc);
    return 0;
}
