// float-cg — end-to-end xt6502 float codegen check. A void
// function (not gated — no float params/return) adds two float
// globals and truncates to an i16 global. The harness calls it,
// then prints gR. gA=1.5 + gB=3.25 = 4.75 -> (i16)4. Exercises the
// float Const encode, FAdd via _fpAdd + the $B0-$B4 mailbox, and
// FpToSI via _fpToI32 — all on the real xts simulator.
float gA = 1.5;
float gB = 3.25;
i16 gR;

void run(void)
    {
    gR = (i16)(gA + gB);
    }
