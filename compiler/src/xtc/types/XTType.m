#import "XTType.h"
#import "XTPointerType.h"
#import "XTArrayType.h"
#include <float.h>
#include <math.h>

@interface XTType ()
    {
    // A pack's width, exponent and mantissa bits, kind and signedness.
    @public
    unsigned _pw, _pe, _pm, _pk;
    BOOL _pu;
    }
@property(nonatomic, readwrite) XTTypeKind kind;
@property(nonatomic, readwrite) NSString* displayName;
@end

@implementation XTType

- (void)overrideDisplayName:(NSString*)name
    {
    _displayName = [name copy];
    }

/****************************************************************************\
|* Designated initialiser for type objects.
|* @param kind  The type-kind enum value.
|* @param name  The human-readable display name for diagnostics.
|* @return A new type object.
\****************************************************************************/
- (instancetype)initWithKind:(XTTypeKind)kind displayName:(NSString*)name
    {
    self = [super init];
    if (self)
        {
        _kind = kind;
        _displayName = [name copy];
        }
    return self;
    }

/****************************************************************************\
|* Return self since types are immutable singletons / value objects.
|* @param zone  Ignored.
|* @return self.
\****************************************************************************/
- (id)copyWithZone:(nullable NSZone*)zone
    {
    return self; // types are immutable singletons / value objects
    }

+ (instancetype)i8Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindI8 displayName:@"i8"];
    });
    return t;
    }
+ (instancetype)u8Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindU8 displayName:@"u8"];
    });
    return t;
    }
+ (instancetype)i16Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindI16 displayName:@"i16"];
    });
    return t;
    }
+ (instancetype)u16Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindU16 displayName:@"u16"];
    });
    return t;
    }
+ (instancetype)i32Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindI32 displayName:@"i32"];
    });
    return t;
    }
+ (instancetype)u32Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindU32 displayName:@"u32"];
    });
    return t;
    }
+ (instancetype)i64Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindI64 displayName:@"i64"];
    });
    return t;
    }
+ (instancetype)u64Type
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindU64 displayName:@"u64"];
    });
    return t;
    }
+ (instancetype)boolType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindBool displayName:@"bool"];
    });
    return t;
    }
+ (instancetype)floatType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindFloat displayName:@"float"];
    });
    return t;
    }
+ (instancetype)doubleType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindDouble displayName:@"double"];
    });
    return t;
    }
/****************************************************************************\
|* The small floats. A pack is (width, exponent bits X, mantissa bits Y, kind,
|* unsigned), and its type is the one object for its canonical name: `f16`
|* (e5m10), `bf16` (e8m7), `f8` (e4m3, finite), otherwise `fW$eXmY`, with
|* `$kind` added when the kind is not the split's default (finite for f8's
|* e4m3, ieee for every other), and `f8$ue8m0`, the unsigned scale. No source
|* can spell such a name (`$` starts a number), and it holds no `:`, which
|* begins a pointer qualifier in a type's spelling, nor anything a symbol
|* cannot hold, so it travels through mangling and interfaces as any type
|* name does. A diagnostic writes it as the source does, `f8:pack(e5m2)`
|* (XTDiagnosticEngine). Mirrored in the port's Types.
\****************************************************************************/
static NSMutableDictionary<NSString*, XTType*>* XTPackTypes(void)
    {
    static NSMutableDictionary* d;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      d = [NSMutableDictionary dictionary];
    });
    return d;
    }

// "eXmY" (or "ueXmY" when uns may be YES) as its two numbers.
static BOOL XTParsePackSplit(NSString* pk, unsigned* e, unsigned* m, BOOL* uns)
    {
    const char* c = pk.UTF8String;
    *uns = NO;
    if (c[0] == 'u')
        {
        *uns = YES;
        c++;
        }
    if (c[0] != 'e' || c[1] < '0' || c[1] > '9')
        return NO;
    unsigned a = 0, b = 0;
    c++;
    while (*c >= '0' && *c <= '9' && a < 1000)
        a = a * 10 + (unsigned)(*c++ - '0');
    if (*c != 'm' || c[1] < '0' || c[1] > '9')
        return NO;
    c++;
    while (*c >= '0' && *c <= '9' && b < 1000)
        b = b * 10 + (unsigned)(*c++ - '0');
    if (*c != 0)
        return NO;
    *e = a;
    *m = b;
    return YES;
    }

static unsigned XTPackDefaultKind(unsigned w, unsigned e, unsigned m)
    {
    return (w == 8 && e == 4 && m == 3) ? 1 : 0;
    }

static NSString* XTPackKindWord(unsigned k)
    {
    return k == 1 ? @"finite" : k == 2 ? @"none" : @"ieee";
    }

static NSString* XTPackCanonicalName(unsigned w, unsigned e, unsigned m, unsigned kind, BOOL uns)
    {
    if (uns)
        return @"f8$ue8m0";
    if (w == 16 && e == 5 && m == 10 && kind == 0)
        return @"f16";
    if (w == 16 && e == 8 && m == 7 && kind == 0)
        return @"bf16";
    if (w == 8 && e == 4 && m == 3 && kind == 1)
        return @"f8";
    if (kind == XTPackDefaultKind(w, e, m))
        return [NSString stringWithFormat:@"f%u$e%um%u", w, e, m];
    return [NSString stringWithFormat:@"f%u$e%um%u$%@", w, e, m, XTPackKindWord(kind)];
    }

// A canonical name's pack. NO for any other name.
static BOOL XTParsePackName(NSString* name, unsigned* w, unsigned* e, unsigned* m, unsigned* kind, BOOL* uns)
    {
    *uns = NO;
    if ([name isEqualToString:@"f16"])
        {
        *w = 16, *e = 5, *m = 10, *kind = 0;
        return YES;
        }
    if ([name isEqualToString:@"bf16"])
        {
        *w = 16, *e = 8, *m = 7, *kind = 0;
        return YES;
        }
    if ([name isEqualToString:@"f8"])
        {
        *w = 8, *e = 4, *m = 3, *kind = 1;
        return YES;
        }
    unsigned width;
    NSString* rest;
    if ([name hasPrefix:@"f8$"])
        width = 8, rest = [name substringFromIndex:3];
    else if ([name hasPrefix:@"f16$"])
        width = 16, rest = [name substringFromIndex:4];
    else
        return NO;
    NSString* split = rest;
    NSString* kw = nil;
    NSRange dollar = [rest rangeOfString:@"$"];
    if (dollar.location != NSNotFound)
        {
        split = [rest substringToIndex:dollar.location];
        kw = [rest substringFromIndex:dollar.location + 1];
        }
    if (!XTParsePackSplit(split, e, m, uns))
        return NO;
    *w = width;
    if (*uns)
        {
        if (kw || width != 8 || *e != 8 || *m != 0)
            return NO;
        *kind = 1;
        return YES;
        }
    if (*e + *m + 1 != width)
        return NO;
    if (!kw)
        *kind = XTPackDefaultKind(width, *e, *m);
    else if ([kw isEqualToString:@"ieee"])
        *kind = 0;
    else if ([kw isEqualToString:@"finite"])
        *kind = 1;
    else if ([kw isEqualToString:@"none"])
        *kind = 2;
    else
        return NO;
    return [XTPackCanonicalName(width, *e, *m, *kind, NO) isEqualToString:name];
    }

+ (nullable XTType*)packTypeNamed:(NSString*)name
    {
    unsigned w, e, m, k;
    BOOL u;
    if (!name || !XTParsePackName(name, &w, &e, &m, &k, &u))
        return nil;
    NSMutableDictionary<NSString*, XTType*>* d = XTPackTypes();
    @synchronized(d)
        {
        XTType* t = d[name];
        if (!t)
            {
            t = [(XTType*)[self alloc] initWithKind:XTTypeKindPack displayName:name];
            t->_pw = w;
            t->_pe = e;
            t->_pm = m;
            t->_pk = k;
            t->_pu = u;
            d[name] = t;
            }
        return t;
        }
    }

+ (instancetype)f16Type
    {
    return (id)[self packTypeNamed:@"f16"];
    }
+ (instancetype)bf16Type
    {
    return (id)[self packTypeNamed:@"bf16"];
    }
+ (instancetype)f8Type
    {
    return (id)[self packTypeNamed:@"f8"];
    }

+ (nullable NSString*)packNameForBase:(NSString*)base
                                 pack:(NSString*)pk
                                 kind:(nullable NSString*)kind
                                error:(NSString* _Nullable* _Nonnull)err
    {
    *err = nil;
    unsigned e = 0, m = 0, k = 0;
    BOOL uns = NO;
    BOOL split = XTParsePackSplit(pk, &e, &m, &uns);
    if ([base isEqualToString:@"f32"] || [base isEqualToString:@"f64"])
        {
        NSString* own = [base isEqualToString:@"f32"] ? @"e8m23" : @"e11m52";
        if (![pk isEqualToString:own])
            *err = [NSString stringWithFormat:@"%@ has no pack '%@': it takes only its own, %@; write '%@'", base, pk, own,
                                              base];
        else if (kind)
            *err = [NSString stringWithFormat:@"%@ takes no special-value kind: its pack is IEEE's; write '%@'", base, base];
        return *err ? nil : base;
        }
    if ([base isEqualToString:@"bf16"])
        {
        *err = [NSString stringWithFormat:@"bf16 is already f16:pack(e8m7) and takes no pack; write 'bf16', or "
                                          @"'f16:pack(%@)' for another layout of f16",
                                          pk];
        return nil;
        }
    if ([base isEqualToString:@"f4"])
        {
        *err = @"'f4' is not a type yet: the float types are f8, f16, bf16, f32 and f64";
        return nil;
        }
    if (![base isEqualToString:@"f16"] && ![base isEqualToString:@"f8"])
        {
        *err = [NSString stringWithFormat:@"'%@' has no pack: a pack is written on a float type, f8, f16, f32 or f64",
                                          base];
        return nil;
        }
    unsigned w = [base isEqualToString:@"f8"] ? 8 : 16;
    if (w == 16 && (!split || uns || e + m + 1 != 16 || e < 5 || e > 8))
        {
        *err = [NSString stringWithFormat:@"f16 has no pack '%@': its packs are e5m10 (the default, IEEE binary16), e6m9, "
                                          @"e7m8 and e8m7 (bfloat16)",
                                          pk];
        return nil;
        }
    if (w == 8 && uns && !(split && e == 8 && m == 0))
        {
        *err = [NSString stringWithFormat:@"f8 has no pack '%@': its one unsigned pack is ue8m0", pk];
        return nil;
        }
    if (w == 8 && !uns && (!split || e + m + 1 != 8 || e < 2 || m < 1))
        {
        *err = [NSString stringWithFormat:@"f8 has no pack '%@': a signed pack has 1 + X + Y = 8 bits, e2m5 to e6m1 (e4m3 "
                                          @"the default, e5m2), and the unsigned scale is ue8m0",
                                          pk];
        return nil;
        }
    if (uns)
        {
        if (kind)
            {
            *err = @"ue8m0 takes no special-value kind: 0xFF is its NaN and it has no infinity; write 'f8:pack(ue8m0)'";
            return nil;
            }
        return XTPackCanonicalName(8, 8, 0, 1, YES);
        }
    k = XTPackDefaultKind(w, e, m);
    if (kind)
        {
        if ([kind isEqualToString:@"ieee"])
            k = 0;
        else if ([kind isEqualToString:@"finite"])
            k = 1;
        else if ([kind isEqualToString:@"none"])
            k = 2;
        else
            {
            *err = [NSString stringWithFormat:@"'%@' is not a special-value kind: write ieee, finite or none", kind];
            return nil;
            }
        }
    if (k != 0 && e > 7)
        {
        *err = [NSString stringWithFormat:@"a %@ pack has at most 7 exponent bits, so that its largest values fit f32; "
                                          @"write 'f%u:pack(%@)'",
                                          XTPackKindWord(k), w, pk];
        return nil;
        }
    return XTPackCanonicalName(w, e, m, k, NO);
    }

- (BOOL)isFloatPack
    {
    return _kind == XTTypeKindPack;
    }
- (NSUInteger)packExpBits
    {
    return _kind == XTTypeKindPack ? _pe : 0;
    }
- (NSUInteger)packMantBits
    {
    return _kind == XTTypeKindPack ? _pm : 0;
    }
- (NSUInteger)packKind
    {
    return _kind == XTTypeKindPack ? _pk : 0;
    }
- (BOOL)packUnsigned
    {
    return _kind == XTTypeKindPack && _pu;
    }
- (uint32_t)packFlags
    {
    if (_kind != XTTypeKindPack)
        return 0;
    return _pk | (_pu ? 4u : 0u);
    }
- (BOOL)isCPack
    {
    return _kind == XTTypeKindPack && _pw == 16 && _pk == 0 && ((_pe == 5 && _pm == 10) || (_pe == 8 && _pm == 7));
    }
- (uint32_t)packSignBit
    {
    if (_kind != XTTypeKindPack || _pu)
        return 0;
    return 1u << (_pe + _pm);
    }

// A pack's exponent bias, and its largest finite pattern (magnitude bits).
static int32_t XTPackBias(unsigned e, BOOL uns)
    {
    return uns ? 127 : (int32_t)((1u << (e - 1)) - 1);
    }
static uint32_t XTPackMaxBits(unsigned e, unsigned m, unsigned kind, BOOL uns)
    {
    if (uns)
        return 0xFE;
    uint32_t all = (1u << (e + m)) - 1;
    if (kind == 0)
        return (((1u << e) - 1) << m) - 1;
    return kind == 1 ? all - 1 : all;
    }

// The value of a finite pattern (magnitude bits) of a pack.
static double XTPackValue(uint32_t bits, unsigned e, unsigned m, BOOL uns)
    {
    if (uns)
        return ldexp(1.0, (int)bits - 127);
    uint32_t ex = bits >> m, mant = bits & ((1u << m) - 1);
    int32_t bias = XTPackBias(e, NO);
    if (ex == 0)
        return ldexp((double)mant, 1 - bias - (int)m);
    return ldexp((double)((1u << m) | mant), (int)ex - bias - (int)m);
    }

- (double)packMaxFinite
    {
    if (_kind != XTTypeKindPack)
        return 0;
    return XTPackValue(XTPackMaxBits(_pe, _pm, _pk, _pu), _pe, _pm, _pu);
    }

// A number as a diagnostic writes it: an integer below 1e10 in full, any other
// value below that exactly, and a larger one to three figures (3.39e38). Both
// compilers take the same steps.
- (NSString*)packMaxFiniteText
    {
    double v = self.packMaxFinite;
    if (v < 1e10)
        {
        int64_t ip = (int64_t)v;
        double frac = v - (double)ip;
        NSMutableString* s = [NSMutableString stringWithFormat:@"%lld", (long long)ip];
        if (frac > 0)
            {
            [s appendString:@"."];
            while (frac > 0)
                {
                frac = frac * 10.0;
                int64_t d = (int64_t)frac;
                [s appendFormat:@"%lld", (long long)d];
                frac = frac - (double)d;
                }
            }
        return s;
        }
    double d = v;
    int64_t n = 0;
    while (d >= 10.0)
        {
        d = d / 10.0;
        n = n + 1;
        }
    int64_t r = (int64_t)(d * 100.0 + 0.5);
    if (r >= 1000)
        {
        r = r / 10;
        n = n + 1;
        }
    return [NSString stringWithFormat:@"%lld.%lld%llde%lld", (long long)(r / 100), (long long)(r / 10 % 10),
                                      (long long)(r % 10), (long long)n];
    }

/****************************************************************************\
|* A double rounded to a pack: FloatPack.xc's _xt_fpk_pack_f64 and
|* FloatPackKinds.xc's _xt_fpk_pack_f64k, the same steps, so the compiler and
|* the program round a literal and a value the same way. Bit 31 of the result
|* says the rounded magnitude was beyond the largest finite value (whatever
|* the pack then made of it). flags: the kind, 4 unsigned, 8 overflow to NaN,
|* 16 overflow and infinity to the largest finite value.
\****************************************************************************/
static uint32_t XTPackRound(uint32_t sign, int32_t unb, uint32_t sig, uint32_t e, uint32_t m, uint32_t k)
    {
    uint32_t kind = k & 3;
    if (k & 4)
        {
        // ue8m0: the nearest power of two, ties to the even exponent.
        if (sign)
            return 0xFF;
        while ((sig & 0x80000000u) == 0)
            {
            sig <<= 1;
            unb--;
            }
        int32_t E = unb + 127;
        uint32_t rem = sig & 0x7FFFFFFFu;
        if (rem > 0x40000000u || (rem == 0x40000000u && (E & 1)))
            E++;
        if (E < 0)
            return 0;
        if (E > 254)
            return 0x80000000u | ((k & 8) ? 0xFFu : 0xFEu);
        return (uint32_t)E;
        }
    int32_t bias = (int32_t)((1u << (e - 1)) - 1);
    int32_t te = unb + bias;
    int32_t s = 31 - (int32_t)m;
    if (te < 1)
        {
        s = s + 1 - te;
        te = 1;
        }
    uint32_t q = 0;
    if (s == 32)
        q = sig > 0x80000000u ? 1 : 0;
    else if (s < 32)
        {
        q = sig >> s;
        uint32_t rem = sig & ((1u << s) - 1);
        uint32_t half = 1u << (s - 1);
        if (rem > half || (rem == half && (q & 1)))
            q++;
        }
    uint32_t bits = ((uint32_t)(te - 1) << m) + q;
    uint32_t all = (1u << (e + m)) - 1;
    uint32_t inf = ((1u << e) - 1) << m;
    uint32_t over = 0;
    if (kind == 0 && bits >= inf)
        {
        over = 0x80000000u;
        bits = (k & 16) ? inf - 1 : inf;
        }
    else if (kind == 1 && bits >= all)
        {
        over = 0x80000000u;
        bits = (k & 8) ? all : all - 1;
        }
    else if (kind == 2 && bits > all)
        {
        over = 0x80000000u;
        bits = all;
        }
    return over | (sign << (e + m)) | bits;
    }

static uint32_t XTPackRoundDouble(double v, uint32_t e, uint32_t m, uint32_t k)
    {
    uint32_t kind = k & 3;
    BOOL uns = (k & 4) != 0;
    uint64_t x;
    memcpy(&x, &v, 8);
    uint32_t hi = (uint32_t)(x >> 32), lo = (uint32_t)x;
    uint32_t sign = hi >> 31;
    uint32_t ex = (hi >> 20) & 0x7FF;
    uint32_t mhi = hi & 0xFFFFF;
    uint32_t sig = (mhi << 11) | (lo >> 21);
    if (lo & 0x1FFFFF)
        sig |= 1;
    uint32_t all = uns ? 0xFF : (1u << (e + m)) - 1;
    uint32_t sbit = uns ? 0 : sign << (e + m);
    if (ex == 0x7FF)
        {
        if (mhi == 0 && lo == 0)
            {
            // An infinity.
            if (uns)
                return sign ? 0xFF : ((k & 8) ? 0xFF : 0xFE);
            if (kind == 0)
                return sbit | ((k & 16) ? XTPackMaxBits(e, m, 0, NO) : ((1u << e) - 1) << m);
            if (kind == 1 && (k & 8))
                return sbit | all;
            return sbit | XTPackMaxBits(e, m, kind, NO);
            }
        // A NaN: ieee keeps its payload's top bits, quiet; finite is the
        // all-ones pattern; none has no NaN and takes 0.
        if (uns)
            return 0xFF;
        if (kind == 1)
            return sbit | all;
        if (kind == 2)
            return 0;
        uint32_t top = (sig << 1) | 1;
        return sbit | (((1u << e) - 1) << m) | (1u << (m - 1)) | (top >> (32 - m));
        }
    if (ex == 0 && mhi == 0 && lo == 0)
        return uns ? 0 : sbit;
    int32_t unb = ex == 0 ? -1022 : (int32_t)ex - 1023;
    if (ex != 0)
        sig |= 0x80000000u;
    return XTPackRound(sign, unb, sig, e, m, k);
    }

- (uint16_t)packBitsForDouble:(double)v
    {
    return (uint16_t)XTPackRoundDouble(v, _pe, _pm, self.packFlags);
    }

- (BOOL)packLiteralOutOfRange:(double)v
    {
    if (_pu && !(v > 0))
        return YES;
    return (XTPackRoundDouble(v, _pe, _pm, self.packFlags) & 0x80000000u) != 0;
    }

// The numbers packHolds:in: compares, for a pack, f32 or f64: mantissa bits,
// the exponent of the smallest positive value, the largest finite value, and
// which specials it has.
static BOOL XTPackShape(XTType* t, unsigned* m, int* qmin, double* max, BOOL* inf, BOOL* nan, BOOL* uns)
    {
    if (t.kind == XTTypeKindFloat || t.kind == XTTypeKindDouble)
        {
        BOOL d = t.kind == XTTypeKindDouble;
        *m = d ? 52 : 23;
        *qmin = d ? -1074 : -149;
        *max = d ? DBL_MAX : FLT_MAX;
        *inf = *nan = YES;
        *uns = NO;
        return YES;
        }
    if (!t.isFloatPack)
        return NO;
    unsigned e = (unsigned)t.packExpBits;
    *m = (unsigned)t.packMantBits;
    *uns = t.packUnsigned;
    *qmin = *uns ? -127 : 1 - XTPackBias(e, NO) - (int)*m;
    *max = t.packMaxFinite;
    *inf = t.packKind == 0 && !*uns;
    *nan = t.packKind != 2;
    return YES;
    }

+ (BOOL)packHolds:(XTType*)from in:(XTType*)to
    {
    if (from == to)
        return YES;
    unsigned ma, mb;
    int qa, qb;
    double xa, xb;
    BOOL ia, ib, na, nb, ua, ub;
    if (!XTPackShape(from, &ma, &qa, &xa, &ia, &na, &ua) || !XTPackShape(to, &mb, &qb, &xb, &ib, &nb, &ub))
        return NO;
    if (ub && !ua)
        return NO;
    if ((ia && !ib) || (na && !nb))
        return NO;
    return mb >= ma && qa >= qb && xa <= xb;
    }

+ (BOOL)packConvertsImplicitly:(XTType*)from to:(XTType*)to
    {
    if (!from || !to)
        return YES;
    if (to.isFloatPack)
        {
        // A pack or nothing: an integer, even one every value of which the
        // pack holds, is converted with a cast (a literal takes the type),
        // and so is f32 or f64.
        return from.isFloatPack && [self packHolds:from in:to];
        }
    if (from.isFloatPack)
        return to.isFloating && [self packHolds:from in:to];
    return YES;
    }
+ (instancetype)voidType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindVoid displayName:@"void"];
    });
    return t;
    }
static NSUInteger sFloatWidth = 5; // xtc's own format unless a target says otherwise
static BOOL sFloatIsIEEE = NO;

+ (NSUInteger)floatWidth
    {
    return sFloatWidth;
    }
+ (void)setFloatWidth:(NSUInteger)w
    {
    NSAssert(w == 4 || w == 5,
             @"floatWidth must be 4 or 5, got %lu",
             (unsigned long)w);
    sFloatWidth = w;
    }
+ (BOOL)floatIsIEEE
    {
    return sFloatIsIEEE;
    }
+ (void)setFloatIsIEEE:(BOOL)b
    {
    sFloatIsIEEE = b;
    }

+ (instancetype)autoType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindAuto displayName:@"auto"];
    });
    return t;
    }
+ (instancetype)pointerType
    {
    static XTType* t;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
      t = [(XTType*)[self alloc] initWithKind:XTTypeKindPointer displayName:@"pointer"];
    });
    return t;
    }

/****************************************************************************\
|* Width of this type in bytes. Returns 0 for void/auto.
|* @return The byte width of the type.
\****************************************************************************/
- (NSUInteger)byteWidth
    {
    switch (_kind)
        {
    case XTTypeKindI8:
    case XTTypeKindU8:
    case XTTypeKindBool:
        return 1;
    case XTTypeKindI16:
    case XTTypeKindU16:
        return 2;
    case XTTypeKindPointer:
        return [XTPointerType heapPointerWidth];
    case XTTypeKindI32:
    case XTTypeKindU32:
        return 4;
    case XTTypeKindI64:
    case XTTypeKindU64:
        return 8;
    case XTTypeKindFloat:
        return [XTType floatWidth];
    case XTTypeKindDouble:
        return 8;
    case XTTypeKindPack:
        return _pw / 8;
    default:
        return 0;
        }
    }

/****************************************************************************\
|* Returns YES for signed integer types (i8, i16, i32).
\****************************************************************************/
- (BOOL)isSigned
    {
    return (_kind == XTTypeKindI8 || _kind == XTTypeKindI16 ||
            _kind == XTTypeKindI32 || _kind == XTTypeKindI64);
    }

/****************************************************************************\
|* Returns YES for any integer-like type (i8/u8/i16/u16/i32/u32/bool/enum).
\****************************************************************************/
- (BOOL)isInteger
    {
    return (_kind == XTTypeKindI8 || _kind == XTTypeKindU8 ||
            _kind == XTTypeKindI16 || _kind == XTTypeKindU16 ||
            _kind == XTTypeKindI32 || _kind == XTTypeKindU32 ||
            _kind == XTTypeKindI64 || _kind == XTTypeKindU64 ||
            _kind == XTTypeKindBool || _kind == XTTypeKindEnum);
    }

/****************************************************************************\
|* Returns YES for the 5-byte float or 8-byte double type.
\****************************************************************************/
- (BOOL)isFloating
    {
    return _kind == XTTypeKindFloat || _kind == XTTypeKindDouble;
    }

/****************************************************************************\
|* Returns YES for pointer or array types (both are 2-byte addresses).
\****************************************************************************/
- (BOOL)isPointerLike
    {
    return (_kind == XTTypeKindPointer || _kind == XTTypeKindArray);
    }

/****************************************************************************\
|* Returns YES for the void type.
\****************************************************************************/
- (BOOL)isVoid
    {
    return _kind == XTTypeKindVoid;
    }

/****************************************************************************\
|* Returns YES for the auto placeholder type (pending inference).
\****************************************************************************/
- (BOOL)isAuto
    {
    return _kind == XTTypeKindAuto;
    }

/****************************************************************************\
|* Returns YES if this type can be implicitly converted to `other` without
|* data loss. Integer-to-integer and float-to/from-integer are allowed.
|* @param other  The target type to check compatibility with.
|* @return YES if implicit conversion is allowed.
\****************************************************************************/
- (BOOL)isCompatibleWithType:(XTType*)other
    {
    if (self == other)
        return YES;
    if (self.kind == other.kind)
        return YES;
    if (self.isInteger && other.isInteger)
        return YES;
    if (self.isFloating && other.isFloating)
        return YES;
    if (self.isFloating && other.isInteger)
        return YES;
    if (self.isInteger && other.isFloating)
        return YES;
    // A 16-bit float meets every number: whether the conversion needs a cast
    // is the site's question (packConvertsImplicitly:to:), not a mismatch.
    if ((self.isFloatPack || other.isFloatPack) &&
        (self.isFloatPack || self.isFloating || self.isInteger) &&
        (other.isFloatPack || other.isFloating || other.isInteger))
        return YES;
    return NO;
    }

/****************************************************************************\
|* YES for an array whose element is not itself an array.
\****************************************************************************/
+ (BOOL)isOneDimArray:(XTType*)t
    {
    return t.kind == XTTypeKindArray && [t isKindOfClass:[XTArrayType class]]
           && ((XTArrayType*)t).elementType.kind != XTTypeKindArray;
    }

/****************************************************************************\
|* An ARRAY operand of `+` or `-` decays to a pointer to its element, as a C
|* array does: `b + 1` is `&b[1]` and `b - p` is a pointer difference. Without
|* this the array met the integer in widenType:with: by byte width, the sum
|* was typed as the array, and lowering added the array's address to the
|* integer as a narrow value (#516). One dimension only, where the element is
|* not itself an array; the other operand must be an integer, a pointer or
|* such an array.
|* @param t      The operand's type.
|* @param other  The other operand's type.
|* @return The pointer to t's element, or t unchanged.
\****************************************************************************/
+ (XTType*)arithmeticDecay:(XTType*)t other:(XTType*)other
    {
    if (!t || !other || ![self isOneDimArray:t])
        return t;
    if (!other.isInteger && other.kind != XTTypeKindPointer && ![self isOneDimArray:other])
        return t;
    return [XTPointerType pointerToType:((XTArrayType*)t).elementType];
    }

/****************************************************************************\
|* Returns the wider of the two types for binary-op type promotion. If either
|* is float, the result is float. Otherwise picks the wider integer, preferring
|* signed if either operand is signed.
|* @param a  The first operand type.
|* @param b  The second operand type.
|* @return The promoted type.
\****************************************************************************/
+ (XTType*)widenType:(XTType*)a with:(XTType*)b
    {
    // A small float widens to the type that holds both operands: the pack that
    // holds the other, itself for an integer it holds every value of (f16 and
    // bf16 an 8-bit one), f32 for a wider integer up to 16 bits, f64 beyond;
    // float and double win as they do over an integer. Two packs neither of
    // which holds the other have no common type (sema refuses them); f32
    // stands in.
    if (a.isFloatPack || b.isFloatPack)
        {
        XTType* p = a.isFloatPack ? a : b;
        XTType* o = a.isFloatPack ? b : a;
        if (o.kind == XTTypeKindDouble)
            return [XTType doubleType];
        if (o.kind == XTTypeKindFloat)
            return [XTType floatType];
        if (o.isFloatPack)
            {
            if (o == p || [XTType packHolds:o in:p])
                return p;
            if ([XTType packHolds:p in:o])
                return o;
            return [XTType floatType];
            }
        if (o.kind == XTTypeKindU8 || o.kind == XTTypeKindI8 || o.kind == XTTypeKindBool || o.kind == XTTypeKindEnum)
            return (!p.packUnsigned && p.packMantBits >= 7 && p.packMaxFinite >= 256.0) ? p : [XTType floatType];
        if (o.isInteger && o.byteWidth <= 2)
            return [XTType floatType];
        if (o.isInteger)
            return [XTType doubleType];
        return p;
        }
    if (a.kind == XTTypeKindDouble || b.kind == XTTypeKindDouble)
        return [XTType doubleType];
    if (a.isFloating || b.isFloating)
        return [XTType floatType];
    // Pointer arithmetic (`p + int` / `int + p`) keeps the POINTER type — never
    // collapse a pointer to a scalar by byte width. That collapse lost the
    // pointee, so `@(p ± N)` saw a non-pointer operand and defaulted its deref
    // to u8 (arch-dependently — the pointer's byte width is arch-specific): it
    // broke the value width AND, once the load was widened, produced an IR `Or`
    // whose result type disagreed with its operands (verifier reject on arm64).
    if (a.kind == XTTypeKindPointer && b.isInteger)
        return a;
    if (b.kind == XTTypeKindPointer && a.isInteger)
        return b;
    // Use byte width to decide, preferring signed if either is signed
    if (a.byteWidth >= b.byteWidth)
        {
        if (a.isSigned || b.isSigned)
            {
            // Return signed version of widest
            switch (MAX(a.byteWidth, b.byteWidth))
                {
            case 1:
                return [XTType i8Type];
            case 2:
                return [XTType i16Type];
            case 4:
                return [XTType i32Type];
            case 8:
                return [XTType i64Type];
            default:
                return a;
                }
            }
        return a;
        }
    else
        {
        if (b.isSigned || a.isSigned)
            {
            switch (MAX(a.byteWidth, b.byteWidth))
                {
            case 1:
                return [XTType i8Type];
            case 2:
                return [XTType i16Type];
            case 4:
                return [XTType i32Type];
            case 8:
                return [XTType i64Type];
            default:
                return b;
                }
            }
        return b;
        }
    }

/****************************************************************************\
|* Return the display name of this type for diagnostic output.
|* @return The type's display name string.
\****************************************************************************/
- (NSString*)description
    {
    return _displayName;
    }

@end
