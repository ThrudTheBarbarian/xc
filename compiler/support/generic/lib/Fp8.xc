// Fp8.xc — explicit conversions to and from the 8-bit float packs.
//
// A cast gives each pack's default overflow rule: f8 (OCP FP8 E4M3, no
// infinity) and f8:pack(ue8m0) saturate to their largest finite value, and
// f8:pack(e5m2) (OCP FP8 E5M2) overflows to infinity. These functions give
// the other rule, as the OCP FP8 specification's non-saturating and
// saturating conversions do:
//
//   fp8E4M3Nan    a value beyond 448, or an infinity, becomes NaN
//   fp8E5M2Sat    a value beyond 57344, or an infinity, becomes ±57344
//   fp8UE8M0Nan   a value beyond 2^127, or an infinity, becomes NaN (0xFF)
//
// and the default rule by name (fp8E4M3, fp8E5M2, fp8UE8M0), with the value of
// each (fp8E4M3Value and the rest, exact). All round to nearest, ties to even,
// from an f64 (an f32 converts to it exactly).
//
// Each is `extern`, so C may call it: C has no 8-bit float type and sees each
// value as its bit pattern, a uint8_t:
//
//   uint8_t fp8E4M3Nan(double x);
//   float fp8E4M3Value(uint8_t v);

#import "FloatPack.xc"
#import "FloatPackKinds.xc"

f8 fp8BitsE4M3(u16 b)
{
    u8 v = (u8)b;
    return *(f8*)&v;
}

f8:pack(e5m2) fp8BitsE5M2(u16 b)
{
    u8 v = (u8)b;
    return *(f8:pack(e5m2)*)&v;
}

f8:pack(ue8m0) fp8BitsUE8M0(u16 b)
{
    u8 v = (u8)b;
    return *(f8:pack(ue8m0)*)&v;
}

extern f8 fp8E4M3(f64 x)
{
    return (f8)x;
}

extern f8 fp8E4M3Nan(f64 x)
{
    return fp8BitsE4M3(_xt_fpk_pack_f64k(x, 4, 3, 9));
}

extern f32 fp8E4M3Value(f8 v)
{
    return v;
}

extern f8:pack(e5m2) fp8E5M2(f64 x)
{
    return (f8:pack(e5m2))x;
}

extern f8:pack(e5m2) fp8E5M2Sat(f64 x)
{
    return fp8BitsE5M2(_xt_fpk_pack_f64k(x, 5, 2, 16));
}

extern f32 fp8E5M2Value(f8:pack(e5m2) v)
{
    return v;
}

extern f8:pack(ue8m0) fp8UE8M0(f64 x)
{
    return (f8:pack(ue8m0))x;
}

extern f8:pack(ue8m0) fp8UE8M0Nan(f64 x)
{
    return fp8BitsUE8M0(_xt_fpk_pack_f64k(x, 8, 0, 13));
}

extern f32 fp8UE8M0Value(f8:pack(ue8m0) v)
{
    return v;
}
