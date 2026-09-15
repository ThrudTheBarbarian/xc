// vectorize_var_trip.xc — a reduction over a RUNTIME trip count.
//
// Every other vectorise fixture counts to a literal, so the vectoriser was only
// ever asked the question it could already answer. XTIROptVectorize bails when
// the loop bound is not a compile-time constant:
//
//     // guard: ICmp <ULT/SLT> i, N(const); i is the iv on the left.
//     if (!resolveConstInt(guard.operands[1], defOf, &N) || N <= 0) continue;
//
// so `for (i = 0; i < n; i++)` — the shape essentially all real code uses, and
// the only shape a library function CAN use — never vectorises on any backend.
// Measured cost: on a reduction+dot kernel this leaves us 8.6x off clang -O3 on
// arm64 and 3.1x off gcc -O3 on x86-64, both measured against the platform's own
// compiler on the platform's own machine.
//
// This fixture exists to make that visible. It checks RESULTS, not vector
// instructions: the answer must be identical whether the loop vectorises, runs
// a vector body plus a scalar remainder, or stays scalar — including when the
// trip count is not a multiple of the vector width, which is where a remainder
// loop goes wrong.
#import "Stdio.xc"

u32 sumTo(u32* p, u32 n)
{
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1) s = s + p[i];
    return s;
}

u32 dotTo(u32* a, u32* b, u32 n)
{
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1) s = s + a[i] * b[i];
    return s;
}

u32 gx[16];
u32 gy[16];

void main(void)
{
    for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1) { gx[i] = i; gy[i] = i + (u32)1; }

    // Trip counts around the vector width (4 lanes): every remainder case.
    for (u32 n = (u32)0; n <= (u32)9; n = n + (u32)1)
        Stdio.printf("sum(%d)=%ld\n", n, sumTo(&gx[0], n));

    Stdio.printf("sum(16)=%ld\n",  sumTo(&gx[0], (u32)16));
    Stdio.printf("sum(15)=%ld\n",  sumTo(&gx[0], (u32)15));
    Stdio.printf("dot(16)=%ld\n",  dotTo(&gx[0], &gy[0], (u32)16));
    Stdio.printf("dot(7)=%ld\n",   dotTo(&gx[0], &gy[0], (u32)7));
}
