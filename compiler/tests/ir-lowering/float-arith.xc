// float-arith — pins the format-NEUTRAL float-op lowering. The IR
// only describes the actions (FAdd / FMul / FCmp / FpToSI / SIToFp);
// each backend renders them in its own format later (xt6502 helper
// calls, arm64 native FP). All work happens on float globals inside
// a void function so the astTypeExposesFloat: gate (float params /
// returns deferred) doesn't abandon it.
float gA = 1.5;
float gB = 3.25;
float gSum;
float gProd;
bool gLess;
i16 gI;

void compute(void)
    {
    gSum = gA + gB;  // FAdd
    gProd = gA * gB; // FMul
    gLess = gA < gB; // FCmp OLT -> Bool
    gI = (i16)gB;    // FpToSI
    gA = (float)gI;  // SIToFp
    }
