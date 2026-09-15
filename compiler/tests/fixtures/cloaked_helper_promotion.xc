// cloaked_helper_promotion.xc — stage 4b: verifies that runtime-asm
// helpers pulled in only by a `:cloaked` caller end up physically
// placed inside the library-bank segment at $4000-$7FFF, not in
// main RAM.
//
// Setup: `cloakedMul32` is a :cloaked free function that does a u32
// multiply. That expands to a JSR into the u32Mul runtime helper.
// The main path doesn't multiply u32 anywhere — printf's dispatch
// and putChar don't need u32Mul — so u32Mul is reached EXCLUSIVELY
// from the cloaked caller and should get promoted to the cloaked
// segment by the stage-4b helper-promotion pass. The assembly
// output is what really tells us whether promotion happened (grep
// for `^u32Mul:` vs `.cloaked_segment` ordering), but we also
// spot-check correctness by comparing the multiply result against
// the known-correct value.
//
// Why u32Mul specifically: nothing else Stdio prints or computes
// goes through u32Mul by default, so this helper is cleanly
// isolated to the cloaked caller in this fixture.

#import "Stdio.xc"

u32 product;

void cloakedMul32(u32 a, u32 b) : cloaked
{
    product = a * b;
}

void main(void)
{
    product = 0;
    cloakedMul32((u32)12345, (u32)6789);

    // 12345 * 6789 = 83810205.
    if (product == 83810205)
    {
        Stdio.printf("T1 PASS p=%lu\n", product);
    }
    else
    {
        Stdio.printf("T1 FAIL p=%lu\n", product);
    }
    return;
}
