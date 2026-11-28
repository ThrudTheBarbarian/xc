// A vectorised float add or multiply of two NaNs with different payloads
// gives the first operand's NaN in every lane, at every -O level (#767): the
// vector form of float_nan_operand_order.xc. On x86-64 the SSE two-address
// form computed in whichever source already sat in the result's register, so
// a lane's NaN depended on register allocation.
#import "Stdio.xc"

void add(float* x, float* y, float* r, u32 n) { for (u32 i = 0; i < n; i++) r[i] = x[i] + y[i]; }
void mul(float* x, float* y, float* r, u32 n) { for (u32 i = 0; i < n; i++) r[i] = x[i] * y[i]; }
// the second operand computed in the loop, so it is the one in a register
void addk(float* x, float* y, float* r, u32 n) { for (u32 i = 0; i < n; i++) { float t = y[i] * 1.0f; r[i] = x[i] + t; } }
void mulk(float* x, float* y, float* r, u32 n) { for (u32 i = 0; i < n; i++) { float t = y[i] * 1.0f; r[i] = x[i] * t; } }
void dadd(double* x, double* y, double* r, u32 n) { for (u32 i = 0; i < n; i++) { double t = y[i] * 1.0d; r[i] = x[i] + t; } }

// every lane's bits the same: that value, else "mixed"
void show(u8* what, u32* r, u32 n)
    {
    for (u32 i = 1; i < n; i++)
        if (r[i] != r[0])
            {
            Stdio.printf("%s mixed\n", what);
            return;
            }
    Stdio.printf("%s %x\n", what, r[0]);
    }

i32 main(void)
    {
    u32 n = 16;
    float* a = new float[n]; float* b = new float[n]; float* r = new float[n];
    u32* ab = (u32*)a; u32* bb = (u32*)b;
    for (u32 i = 0; i < n; i++) { ab[i] = $7FC00102; bb[i] = $7FC00103; }
    add(a, b, r, n); show("add ", (u32*)r, n);
    add(b, a, r, n); show("add'", (u32*)r, n);
    mul(a, b, r, n); show("mul ", (u32*)r, n);
    addk(a, b, r, n); show("addk", (u32*)r, n);
    mulk(a, b, r, n); show("mulk", (u32*)r, n);
    double* da = new double[n]; double* db = new double[n]; double* dr = new double[n];
    u64* dab = (u64*)da; u64* dbb = (u64*)db;
    for (u32 i = 0; i < n; i++) { dab[i] = $7FF8000000000102; dbb[i] = $7FF8000000000103; }
    dadd(da, db, dr, n);
    u64* drb = (u64*)dr;
    bool same = true;
    for (u32 i = 1; i < n; i++) if (drb[i] != drb[0]) same = false;
    if (same) Stdio.printf("dadd %lx\n", drb[0]); else Stdio.printf("dadd mixed\n");
    return 0;
    }
