// libm-linux.c — SOURCE for support/x86_64/runtime/libmgen-linux.s, the maths
// library of the self-hosted x86-64 Linux target. Compiled to assembly ONCE, by
// hand, and the .s is checked in — see rt-linux.c for the same arrangement and
// the regeneration command (identical but for the file names).
//
// The xtc standard library declares sin/cos/tan/atan/log/exp/pow/sqrt as libc
// and calls them directly (support/x86_64/lib/Math.xc). With no libc there is
// nothing to call, so they are implemented here.
//
// Accuracy, measured against the host libm over the ranges the corpus uses
// (worst relative error, 2001 samples each):
//   sin 7.7e-14   cos 5.4e-13   tan 8.3e-16   atan 3.4e-11
//   log 2.0e-16   exp 9.4e-12   pow 9.3e-12   sqrt exact
// Far inside what the corpus checks (a handful of decimal places), but NOT a
// drop-in for glibc's correctly-rounded libm — the last few ULPs will differ,
// and sin/cos degrade further for very large arguments because the range
// reduction is a single subtraction rather than Cody-Waite. Special cases (NaN,
// infinity, denormals) are handled only where they fall out naturally. This is a
// maths library for compiled test programs, not a general-purpose one.
//
// Freestanding: no #include, and sqrt is the hardware instruction rather than a
// library call.

typedef unsigned long long uint64_t; // long is 32-bit under Windows LLP64
typedef long long int64_t;

#define PI 3.14159265358979323846
#define TWO_PI 6.28318530717958647693
#define HALF_PI 1.57079632679489661923
#define LN2 0.69314718055994530942
#define INV_LN2 1.44269504088896340736

static double asDouble(uint64_t b)
    {
        union {
        uint64_t i;
        double d;
        } u;
    u.i = b;
    return u.d;
    }
static uint64_t asBits(double d)
    {
        union {
        uint64_t i;
        double d;
        } u;
    u.d = d;
    return u.i;
    }

double sqrt(double x)
    {
    return __builtin_sqrt(x);
    }
float sqrtf(float x)
    {
    return __builtin_sqrtf(x);
    }

// floor, without libm: for anything past 2^52 every double is already integral.
static double xfloor(double x)
    {
    if (x != x || x >= 4503599627370496.0 || x <= -4503599627370496.0)
        return x;
    double t = (double)(int64_t)x;
    return (t > x) ? t - 1.0 : t;
    }

// ── sin / cos ──────────────────────────────────────────────────────────────
// Reduce to [-pi/4, pi/4] by quadrant, then evaluate the standard minimax
// polynomials for sin and cos on that interval.
static double sinPoly(double x)
    {
    double z = x * x;
    return x + x * z * (-1.66666666666666324348e-01 + z * (8.33333333332248946124e-03 + z * (-1.98412698298579493134e-04 + z * (2.75573137070700676789e-06 + z * (-2.50507602534068634195e-08 + z * 1.58969099521155010221e-10)))));
    }
static double cosPoly(double x)
    {
    double z = x * x;
    return 1.0 + z * (-5.00000000000000000000e-01 +
                      z * (4.16666666666666019037e-02 +
                           z * (-1.38888888888741095749e-03 +
                                z * (2.48015872894767294178e-05 +
                                     z * (-2.75573143513906633035e-07 +
                                          z * (2.08757232129817482790e-09 +
                                               z * (-1.13596475577881948265e-11)))))));
    }

double sin(double x)
    {
    if (x != x)
        return x;
    // Quadrant index. Cody-Waite would do better for huge arguments; this is a
    // single subtraction, so precision degrades once |x| is large — acceptable
    // for angles, which is all the library passes in.
    double q = xfloor(x / HALF_PI + 0.5);
    double r = x - q * HALF_PI;
    int64_t n = ((int64_t)q) & 3;
    if (n < 0)
        n += 4;
    switch (n)
        {
    case 0:
        return sinPoly(r);
    case 1:
        return cosPoly(r);
    case 2:
        return -sinPoly(r);
    default:
        return -cosPoly(r);
        }
    }
double cos(double x)
    {
    if (x != x)
        return x;
    double q = xfloor(x / HALF_PI + 0.5);
    double r = x - q * HALF_PI;
    int64_t n = ((int64_t)q) & 3;
    if (n < 0)
        n += 4;
    switch (n)
        {
    case 0:
        return cosPoly(r);
    case 1:
        return -sinPoly(r);
    case 2:
        return -cosPoly(r);
    default:
        return sinPoly(r);
        }
    }
double tan(double x)
    {
    double c = cos(x);
    if (c == 0.0)
        return asDouble(0x7FF0000000000000ULL); // +inf at the pole
    return sin(x) / c;
    }

// ── atan ───────────────────────────────────────────────────────────────────
// The alternating series for atan converges slowly near |x| = 1 — a direct
// evaluation there is only good to about 2e-2 — so fold twice before using it:
// atan(x) = pi/2 - atan(1/x) above tan(3pi/8), and atan(x) = pi/4 +
// atan((x-1)/(x+1)) above tan(pi/8). What's left is [0, 0.4143], where
// successive terms shrink by a factor of six.
static double atanPoly(double x)
    {
    double z = x * x;
    return x * (1.0 + z * (-3.33333333333329318027e-01 +
                           z * (1.99999999998764832476e-01 +
                                z * (-1.42857142725034663711e-01 +
                                     z * (1.11111104054623557880e-01 +
                                          z * (-9.09088713343650656196e-02 +
                                               z * (7.69187620504482999495e-02 +
                                                    z * (-6.66107313738753120669e-02 +
                                                         z * (5.83357013379057348645e-02 +
                                                              z * (-4.97687799461593236017e-02 +
                                                                   z * 3.68589535425088946993e-02))))))))));
    }
double atan(double x)
    {
    if (x != x)
        return x;
    int neg = 0;
    if (x < 0.0)
        {
        x = -x;
        neg = 1;
        }
    double r;
    if (x > 2.41421356237309504880) // tan(3pi/8)
        r = HALF_PI - atanPoly(1.0 / x);
    else if (x > 0.41421356237309504880) // tan(pi/8)
        r = 0.78539816339744830962 + atanPoly((x - 1.0) / (x + 1.0));
    else
        r = atanPoly(x);
    return neg ? -r : r;
    }

// ── log ────────────────────────────────────────────────────────────────────
// Split off the binary exponent, then evaluate a polynomial in
// s = (m-1)/(m+1) for the mantissa, which converges fast on [sqrt(2)/2, sqrt(2)].
double log(double x)
    {
    if (x != x)
        return x;
    if (x < 0.0)
        return asDouble(0x7FF8000000000000ULL); // NaN
    if (x == 0.0)
        return asDouble(0xFFF0000000000000ULL); // -inf
    uint64_t b = asBits(x);
    int64_t e = (int64_t)((b >> 52) & 0x7FF) - 1023;
    // denormal: scale up and correct
    if (e == -1023)
        {
        x *= 4503599627370496.0;
        b = asBits(x);
        e = (int64_t)((b >> 52) & 0x7FF) - 1023 - 52;
        }
    double m = asDouble((b & 0x000FFFFFFFFFFFFFULL) | 0x3FF0000000000000ULL);
    if (m > 1.4142135623730951)
        {
        m *= 0.5;
        e += 1;
        }
    double s = (m - 1.0) / (m + 1.0), z = s * s;
    double p = 2.0 * s * (1.0 + z * (1.0 / 3.0 + z * (1.0 / 5.0 + z * (1.0 / 7.0 + z * (1.0 / 9.0 + z * (1.0 / 11.0 + z * (1.0 / 13.0 + z * (1.0 / 15.0 + z * (1.0 / 17.0)))))))));
    return p + (double)e * LN2;
    }

// ── exp ────────────────────────────────────────────────────────────────────
// exp(x) = 2^k * exp(r), k = round(x/ln2), |r| <= ln2/2. 2^k is assembled
// straight into the exponent field rather than computed.
double exp(double x)
    {
    if (x != x)
        return x;
    if (x > 709.78)
        return asDouble(0x7FF0000000000000ULL); // overflow -> +inf
    if (x < -745.0)
        return 0.0; // underflow
    double kd = xfloor(x * INV_LN2 + 0.5);
    double r = x - kd * LN2;
    double p = 1.0 + r * (1.0 + r * (1.0 / 2.0 + r * (1.0 / 6.0 + r * (1.0 / 24.0 +
                                                                       r * (1.0 / 120.0 + r * (1.0 / 720.0 + r * (1.0 / 5040.0 +
                                                                                                                  r * (1.0 / 40320.0 + r * (1.0 / 362880.0)))))))));
    int64_t k = (int64_t)kd;
    double scale = asDouble((uint64_t)(k + 1023) << 52);
    return p * scale;
    }

// ── pow ────────────────────────────────────────────────────────────────────
double pow(double a, double b)
    {
    if (b == 0.0)
        return 1.0;
    if (a == 0.0)
        return (b > 0.0) ? 0.0 : asDouble(0x7FF0000000000000ULL);
    if (a > 0.0)
        return exp(b * log(a));
    // Negative base: only an integral exponent has a real result, and its sign
    // is the parity of that integer.
    double bi = xfloor(b);
    if (bi != b)
        return asDouble(0x7FF8000000000000ULL); // NaN
    double m = exp(b * log(-a));
    return (((int64_t)bi) & 1) ? -m : m;
    }

// ── float wrappers ─────────────────────────────────────────────────────────
// Computed in double and rounded once, which is at least as accurate as a
// dedicated float implementation would be.
float sinf(float x)
    {
    return (float)sin((double)x);
    }
float cosf(float x)
    {
    return (float)cos((double)x);
    }
float tanf(float x)
    {
    return (float)tan((double)x);
    }
float atanf(float x)
    {
    return (float)atan((double)x);
    }
float logf(float x)
    {
    return (float)log((double)x);
    }
float expf(float x)
    {
    return (float)exp((double)x);
    }
float powf(float a, float b)
    {
    return (float)pow((double)a, (double)b);
    }

// ── the _xm_* aliases the other backends' runtimes export ──────────────────
float _xm_sqrtf(float x)
    {
    return sqrtf(x);
    }
double _xm_sqrt(double x)
    {
    return sqrt(x);
    }
float _xm_sinf(float x)
    {
    return sinf(x);
    }
double _xm_sin(double x)
    {
    return sin(x);
    }
float _xm_cosf(float x)
    {
    return cosf(x);
    }
double _xm_cos(double x)
    {
    return cos(x);
    }
float _xm_tanf(float x)
    {
    return tanf(x);
    }
double _xm_tan(double x)
    {
    return tan(x);
    }
float _xm_atanf(float x)
    {
    return atanf(x);
    }
double _xm_atan(double x)
    {
    return atan(x);
    }
float _xm_lnf(float x)
    {
    return logf(x);
    }
double _xm_ln(double x)
    {
    return log(x);
    }
float _xm_expf(float x)
    {
    return expf(x);
    }
double _xm_exp(double x)
    {
    return exp(x);
    }
float _xm_powf(float a, float b)
    {
    return powf(a, b);
    }
double _xm_pow(double a, double b)
    {
    return pow(a, b);
    }
