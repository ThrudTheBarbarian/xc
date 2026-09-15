// cloaked_transitive_clean.xc — stage 4c: a :cloaked function
// calls another :cloaked function and reaches only stack-safe
// runtime helpers (u32 multiply). The transitive ZP-safety
// analyser must clear this chain — both callees sit under the
// same PORTB = $30 bracket so there's no xtc-stack access
// involved. Positive test for Pass C.
//
// Expected behaviour: compiles cleanly on xe/xe-nobank, passes
// runtime correctness check against the known multiply product.

#import "Stdio.xc"

u32 result;

void squarer(u32 x) : cloaked
{
    result = x * x;     // u32Mul — stackSafe: YES
}

void scaler(u32 x, u32 m) : cloaked
{
    squarer(x);         // :cloaked → :cloaked is fine
    result = result * m;
}

void main(void)
{
    result = 0;
    scaler((u32)11, (u32)2);    // 121 * 2 = 242
    if (result == 242)
    {
        Stdio.printf("T1 PASS r=%lu\n", result);
    }
    else
    {
        Stdio.printf("T1 FAIL r=%lu\n", result);
    }
    return;
}
