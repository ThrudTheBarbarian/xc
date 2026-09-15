#import "XAArm64Assembler.h"
#import "XTRegexCompat.h"
#include <stdlib.h>
#include <errno.h>

@implementation XAArm64Fixup
@end

// ─────────────────────────── small parse helpers ───────────────────────────

static NSError *asmErr(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:@"XAArm64" code:1
                           userInfo:@{NSLocalizedDescriptionKey: m}];
}

/****************************************************************************\
|* Reject a data-processing instruction whose register operands are not all
|* the same width.
|*
|* arm64 has no `lsr x0, x1, w2` — the operands of a plain register form share
|* the destination's width, and `sf` is encoded once for the whole
|* instruction. Parsing each operand's width and then encoding only the
|* destination's silently produced that instruction anyway: the backend emitted
|* it for a 64-bit shift whose count was a `u8`, this assembler accepted it, and
|* clang rejected the same text outright. An assembler that is laxer than the
|* one people cross-check against is a place bugs hide.
|*
|* NOT applied to the extended-register form (`add x0, x1, w2, uxtw`), where a
|* narrower Rm is the entire point, nor to the SP forms that imply uxtx/uxtw.
|* @return YES when the widths agree; fills `error` and returns NO otherwise.
\****************************************************************************/
static BOOL xaSameWidth(NSString *mn, BOOL a, BOOL b, NSError **error) {
    if (a == b) return YES;
    if (error) *error = asmErr(@"%@: operand width mismatch — %@ and %@ registers "
                               @"cannot be mixed in this form", mn,
                               a ? @"x" : @"w", b ? @"x" : @"w");
    return NO;
}


// Register: returns YES on success; *num 0-31, *is64 for X, *isSP for sp/wsp.
static BOOL parseReg(NSString *s, int *num, BOOL *is64, BOOL *isSP) {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    *isSP = NO;
    if ([s isEqualToString:@"sp"])  { *num = 31; *is64 = YES; *isSP = YES; return YES; }
    if ([s isEqualToString:@"wsp"]) { *num = 31; *is64 = NO;  *isSP = YES; return YES; }
    if ([s isEqualToString:@"xzr"]) { *num = 31; *is64 = YES; return YES; }
    if ([s isEqualToString:@"wzr"]) { *num = 31; *is64 = NO;  return YES; }
    if ([s isEqualToString:@"fp"])  { *num = 29; *is64 = YES; return YES; }
    if ([s isEqualToString:@"lr"])  { *num = 30; *is64 = YES; return YES; }
    if (s.length < 2) return NO;
    unichar c = [s characterAtIndex:0];
    if (c != 'w' && c != 'x') return NO;
    NSString *rest = [s substringFromIndex:1];
    NSScanner *sc = [NSScanner scannerWithString:rest];
    int n; if (![sc scanInt:&n] || ![sc isAtEnd] || n < 0 || n > 30) return NO;
    *num = n; *is64 = (c == 'x'); return YES;
}

// Immediate "#..." (also bare number). Handles 0x hex, negatives, '_' digit seps.
static BOOL parseImm(NSString *s, int64_t *out) {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    s = [s stringByReplacingOccurrencesOfString:@"_" withString:@""];
    if (s.length == 0) return NO;
    BOOL neg = NO;
    if ([s hasPrefix:@"-"]) { neg = YES; s = [s substringFromIndex:1]; }
    // strtoull rather than NSScanner: scanUnsignedLongLong: / the atEnd property
    // differ between Apple Foundation and GNUstep; the C library parses integers
    // identically on both.
    const char *cs = s.UTF8String;
    int base = ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) ? 16 : 10;
    char *endp = NULL;
    errno = 0;
    unsigned long long v = strtoull(base == 16 ? cs + 2 : cs, &endp, base);
    if (errno != 0 || (base == 16 && endp == cs + 2) || endp == cs || *endp != '\0') return NO;
    *out = neg ? -(int64_t)v : (int64_t)v;
    return YES;
}

// Scalar FP/SIMD register: s/d (also b/h/q). *sz: 0=b 1=h 2=s 3=d 4=q.
static BOOL parseFReg(NSString *s, int *num, int *sz) {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (s.length < 2) return NO;
    unichar c = [s characterAtIndex:0];
    int z; switch (c) { case 'b':z=0;break; case 'h':z=1;break; case 's':z=2;break;
                        case 'd':z=3;break; case 'q':z=4;break; default: return NO; }
    NSScanner *sc = [NSScanner scannerWithString:[s substringFromIndex:1]];
    int n; if (![sc scanInt:&n] || ![sc isAtEnd] || n < 0 || n > 31) return NO;
    *num = n; *sz = z; return YES;
}

// Vector register `vN.<arr>` (NEON). *size: 0=b 1=h 2=s 3=d; *q: 1 for the
// 128-bit arrangements (16b/8h/4s/2d). Returns NO if not a vN.arr operand.
static BOOL parseVReg(NSString *s, int *num, int *size, int *q) {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (![s hasPrefix:@"v"]) return NO;
    NSArray *p = [s componentsSeparatedByString:@"."]; if (p.count!=2) return NO;
    NSScanner *sc=[NSScanner scannerWithString:[p[0] substringFromIndex:1]];
    int n; if(![sc scanInt:&n]||![sc isAtEnd]||n<0||n>31) return NO;
    static NSDictionary *A; if(!A) A=@{@"8b":@[@0,@0],@"16b":@[@0,@1],@"4h":@[@1,@0],@"8h":@[@1,@1],
        @"2s":@[@2,@0],@"4s":@[@2,@1],@"1d":@[@3,@0],@"2d":@[@3,@1]};
    NSArray *a=A[p[1]]; if(!a) return NO;
    *num=n; *size=[a[0] intValue]; *q=[a[1] intValue]; return YES;
}

// Vector element `vN.<t>[i]` (a lane of one register), e.g. `v2.s[1]`. *size:
// 0=b 1=h 2=s 3=d; *idx the lane index. Returns NO if not a vN.<t>[i] operand.
static BOOL parseVElem(NSString *s, int *num, int *size, int *idx) {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (![s hasPrefix:@"v"]) return NO;
    NSRange dot=[s rangeOfString:@"."], lb=[s rangeOfString:@"["], rb=[s rangeOfString:@"]"];
    if (dot.location==NSNotFound||lb.location==NSNotFound||rb.location==NSNotFound
        || !(dot.location<lb.location && lb.location<rb.location)) return NO;
    NSScanner *sc=[NSScanner scannerWithString:[s substringWithRange:NSMakeRange(1,dot.location-1)]];
    int n; if(![sc scanInt:&n]||![sc isAtEnd]||n<0||n>31) return NO;
    NSString *ty=[s substringWithRange:NSMakeRange(dot.location+1,lb.location-dot.location-1)];
    int sz; if([ty isEqualToString:@"b"])sz=0; else if([ty isEqualToString:@"h"])sz=1;
    else if([ty isEqualToString:@"s"])sz=2; else if([ty isEqualToString:@"d"])sz=3; else return NO;
    NSScanner *ic=[NSScanner scannerWithString:[s substringWithRange:NSMakeRange(lb.location+1,rb.location-lb.location-1)]];
    int i; if(![ic scanInt:&i]||![ic isAtEnd]||i<0) return NO;
    *num=n; *size=sz; *idx=i; return YES;
}

// Strip an end-of-line comment (`//` — our backend, or `;` — clang's arm64
// output), respecting double-quoted strings so a `;`/`//` inside .asciz survives.
static NSString *stripComment(NSString *l) {
    BOOL inStr = NO;
    for (NSUInteger i=0;i<l.length;i++) {
        unichar c=[l characterAtIndex:i];
        if (c=='"') inStr=!inStr;
        else if (!inStr) {
            if (c==';') return [l substringToIndex:i];
            if (c=='/' && i+1<l.length && [l characterAtIndex:i+1]=='/') return [l substringToIndex:i];
        }
    }
    return l;
}

// Split "op1, op2, [x, #y]" on commas at bracket-depth 0.
// Collapse whitespace around the `@` of a `sym@PAGE` / `sym@PAGEOFF` modifier.
// xtc's inline-asm capture re-tokenises the body and, because `@` is the language's
// pointer operator, re-emits `_g@PAGE` as `_g @ PAGE`. clang tolerates the spaces;
// we must too — otherwise `bare` (the symbol before `@`) keeps a trailing space,
// never matches the defined symbol, and the adrp/add resolve to 0 (a wild store).
static NSString *normPageMod(NSString *op) {
    if ([op rangeOfString:@"@"].location == NSNotFound) return op;
    static NSRegularExpression *re; static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"\\s*@\\s*PAGE" options:0 error:NULL];
    });
    return XTRegexReplace(re, op, @"@PAGE");
}

static NSArray<NSString *> *splitOperands(NSString *s) {
    NSMutableArray *out = [NSMutableArray array];
    int depth = 0; NSUInteger start = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '[') depth++;
        else if (c == ']') depth--;
        else if (c == ',' && depth == 0) {
            [out addObject:normPageMod([[s substringWithRange:NSMakeRange(start, i - start)]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]])];
            start = i + 1;
        }
    }
    NSString *last = normPageMod([[s substringFromIndex:start]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
    if (last.length) [out addObject:last];
    return out;
}

// condition mnemonic (after "b.") -> 4-bit code
static int condCode(NSString *cc) {
    static NSDictionary *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = @{@"eq":@0,@"ne":@1,@"cs":@2,@"hs":@2,@"cc":@3,@"lo":@3,
        @"mi":@4,@"pl":@5,@"vs":@6,@"vc":@7,@"hi":@8,@"ls":@9,@"ge":@10,@"lt":@11,
        @"gt":@12,@"le":@13,@"al":@14}; });
    NSNumber *n = m[cc]; return n ? n.intValue : -1;
}

// ─────────────────────────── the assembler ───────────────────────────

@implementation XAArm64Assembler {
    NSMutableArray<XAArm64Fixup *> *_fixups;
    NSMutableDictionary<NSString *, NSNumber *> *_symbols;
    NSMutableData *_data;
    NSMutableSet<NSString *> *_dataSymbolNames;
    NSMutableSet<NSString *> *_globalNames;
    // Bug 066: the __DATA,__mod_init_func pointer array, kept SEPARATE from
    // `_data` rather than folded into it. The writer describes it with its own
    // S_MOD_INIT_FUNC_POINTERS section — which is the whole mechanism: the same
    // bytes under a regular section are inert and dyld runs nothing.
    //
    // Separate rather than "the tail of _data" because the LINKER appends every
    // object's and archive's data after ours, so a tail range recorded here
    // would stop being the tail the moment anything else contributes data. The
    // linker appends this last and shifts these fixups to match.
    NSMutableData *_modInit;
    NSMutableArray<XAArm64Fixup *> *_modInitFixups;
    // `.comm` COMMON (tentative) symbols: name → @[size, log2align]. Unlike a
    // `.globl`+label these carry NO storage in THIS object — they are external
    // undefined-with-size, so the linker gives ONE zero-filled slot and every
    // unit binds to it (bug 169). A `.comm` used to become a private LOCAL def
    // in every unit, which is why shared globals read back zero cross-unit.
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_commonSymbols;
}

- (NSArray<XAArm64Fixup *> *)fixups { return _fixups ?: @[]; }
- (NSDictionary<NSString *, NSNumber *> *)symbols { return _symbols ?: @{}; }
- (NSData *)data { return _data ?: [NSData data]; }
- (NSSet<NSString *> *)dataSymbols { return _dataSymbolNames ?: [NSSet set]; }
- (NSSet<NSString *> *)globalSymbols { return _globalNames ?: [NSSet set]; }
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)commonSymbols { return _commonSymbols ?: @{}; }
- (NSData *)modInitData { return _modInit ?: [NSData data]; }

// A single-unit IMAGE (executable/dylib) has no separate link stage, so its
// COMMON (`.comm`) symbols must be given real storage HERE — exactly the slot the
// final linker would allocate for a `-c` object's commons. Allocate each in
// __data and define it locally, then drop it from the common set. Called by every
// image path but `--object` (which keeps them as true commons). Sorted order so
// the reference and the self-hosted assembler lay them out identically.
- (void)demoteCommonsToLocalData {
    if (!_commonSymbols.count) return;
    NSArray<NSString *> *names = [_commonSymbols.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *nm in names) {
        NSArray<NSNumber *> *info = _commonSymbols[nm];
        uint64_t sz = info[0].unsignedLongLongValue, alg = info[1].unsignedLongLongValue;
        uint64_t al = 1ull << alg;
        while (_data.length % al) { uint8_t z = 0; [_data appendBytes:&z length:1]; }
        _symbols[nm] = @(_data.length); [_dataSymbolNames addObject:nm];
        for (uint64_t i = 0; i < sz; i++) { uint8_t z = 0; [_data appendBytes:&z length:1]; }
    }
    [_commonSymbols removeAllObjects];
}
- (NSArray<XAArm64Fixup *> *)modInitFixups { return _modInitFixups ?: @[]; }

// Encode a memory addressing tail "[Xn]" / "[Xn, #imm]" / "[Xn, #imm]!" / "[Xn], #imm".
// Returns base reg in *rn, immediate in *imm, and index mode in *mode
// (0 = offset, 1 = pre-index, 2 = post-index).
static BOOL parseMem(NSArray<NSString *> *ops, NSUInteger memIdx,
                     int *rn, int64_t *imm, int *mode, NSError **err) {
    *imm = 0; *mode = 0;
    NSString *m = ops[memIdx];
    BOOL is64, isSP;
    // post-index: "[Xn]" is one operand, "#imm" the next
    if (![m hasPrefix:@"["]) { if (err) *err = asmErr(@"expected [ in %@", m); return NO; }
    if ([m hasSuffix:@"]"] && memIdx + 1 < ops.count) {
        // "[Xn], #imm"  (post-index)
        NSString *inner = [m substringWithRange:NSMakeRange(1, m.length - 2)];
        if (!parseReg(inner, rn, &is64, &isSP)) { if (err) *err = asmErr(@"bad base %@", inner); return NO; }
        if (!parseImm(ops[memIdx + 1], imm)) { if (err) *err = asmErr(@"bad post imm"); return NO; }
        *mode = 2; return YES;
    }
    BOOL pre = NO;
    NSString *body = m;
    if ([body hasSuffix:@"]!"]) { pre = YES; body = [body substringToIndex:body.length - 2]; body = [body substringFromIndex:1]; }
    else if ([body hasSuffix:@"]"]) { body = [body substringWithRange:NSMakeRange(1, body.length - 2)]; }
    else { if (err) *err = asmErr(@"unterminated mem %@", m); return NO; }
    NSArray *parts = splitOperands(body);
    if (parts.count < 1) { if (err) *err = asmErr(@"empty mem"); return NO; }
    if (!parseReg(parts[0], rn, &is64, &isSP)) { if (err) *err = asmErr(@"bad base %@", parts[0]); return NO; }
    if (parts.count >= 2) { if (!parseImm(parts[1], imm)) { if (err) *err = asmErr(@"bad offset %@", parts[1]); return NO; } }
    *mode = pre ? 1 : 0;
    return YES;
}

// add/sub/adds/subs immediate (handles LSL #12 for values that are n<<12)
static BOOL encAddSubImm(uint32_t base, NSArray *ops, uint32_t *out, NSError **err) {
    int rd, rn; BOOL d64, n64, dSP, nSP;
    if (!parseReg(ops[0], &rd, &d64, &dSP) || !parseReg(ops[1], &rn, &n64, &nSP)) {
        if (err) *err = asmErr(@"bad reg"); return NO; }
    // The immediate form has ONE width bit (sf), taken from Rd — a mixed
    // spelling like `add x10, w16, #1` is invalid AArch64, and encoding it
    // from Rd alone silently reads the X view of the source (blewit's #8
    // followup). Reject, as the reference assembler does. (SP registers
    // parse with their neighbour's width, so the SP forms pass unchanged.)
    if (d64 != n64) {
        if (err) *err = asmErr(@"add/sub width mismatch: %@ vs %@", ops[0], ops[1]);
        return NO;
    }
    int64_t imm; if (!parseImm(ops[2], &imm)) { if (err) *err = asmErr(@"bad imm %@", ops[2]); return NO; }
    uint32_t sh = 0;
    if (ops.count >= 4) {
        // EXPLICIT shift: `add Rd, Rn, #imm, lsl #12`. The immediate is then the
        // UNSHIFTED value — `#1, lsl #12` is 4096, not 1 — so it is taken as
        // written and the shift bit set, rather than divided down as the bare
        // spelling below is. Getting that backwards would encode 1 for 4096:
        // silently wrong code instead of a rejection, which is the worse bug.
        NSString *mod = [ops[3] stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
        NSRange h = [mod rangeOfString:@"#"];
        int64_t amt = 0;
        if (![[mod lowercaseString] hasPrefix:@"lsl"] || h.location == NSNotFound
            || !parseImm([mod substringFromIndex:h.location], &amt)) {
            if (err) *err = asmErr(@"bad add/sub shift %@", ops[3]); return NO; }
        if (amt == 12) sh = 1;
        else if (amt != 0) {
            if (err) *err = asmErr(@"add/sub shift must be 0 or 12, got %lld", (long long)amt);
            return NO; }
        if (imm < 0 || imm > 0xFFF) {
            if (err) *err = asmErr(@"imm out of range %lld", (long long)imm); return NO; }
    } else if (imm < 0 || imm > 0xFFF) {
        if ((imm & 0xFFF) == 0 && (imm >> 12) >= 0 && (imm >> 12) <= 0xFFF) { sh = 1; imm >>= 12; }
        else { if (err) *err = asmErr(@"imm out of range %lld", (long long)imm); return NO; }
    }
    uint32_t sf = d64 ? 0x80000000u : 0;
    *out = base | sf | (sh << 22) | ((uint32_t)(imm & 0xFFF) << 10) | ((uint32_t)rn << 5) | (uint32_t)rd;
    return YES;
}

// AArch64 logical-immediate (bitmask) encoding -> N:immr:imms (13 bits). Ported
// from LLVM AArch64_AM::processLogicalImmediate. Returns NO if not encodable.
static BOOL isMask64(uint64_t v){ return v && (((v+1)&v)==0); }
static BOOL isShiftedMask64(uint64_t v){ return v && isMask64(((v-1)|v)); }
static BOOL encodeLogImm(uint64_t imm, int regSize, uint32_t *enc) {
    if (imm==0ULL || imm==~0ULL) return NO;
    if (regSize!=64 && (imm>>regSize!=0 || imm==(~0ULL>>(64-regSize)))) return NO;
    unsigned size=regSize;
    do { size/=2; uint64_t m=(1ULL<<size)-1; if((imm&m)!=((imm>>size)&m)){size*=2;break;} } while(size>2);
    uint64_t mask = ((uint64_t)-1LL) >> (64-size);
    imm &= mask;
    uint32_t cto, i;
    if (isShiftedMask64(imm)) { i=(uint32_t)__builtin_ctzll(imm); cto=(uint32_t)__builtin_ctzll(~(imm>>i)); }
    else { imm |= ~mask; if(!isShiftedMask64(~imm)) return NO;
        unsigned clo=(unsigned)__builtin_clzll(~imm); i=64-clo; cto=clo+(unsigned)__builtin_ctzll(~imm)-(64-size); }
    unsigned immr=(size-i)&(size-1);
    uint64_t nimms=~(uint64_t)(size-1)<<1; nimms|=(cto-1);
    uint32_t N=((nimms>>6)&1)^1;
    *enc=(N<<12)|(immr<<6)|(uint32_t)(nimms&0x3f);
    return YES;
}

// data-processing 3-source (madd/msub/umaddl/smaddl); mul/umull/smull pass ra=31
// Split an atomic mnemonic into (operation, ordering, width): `ldaddalh` is
// prefix "ld" + op "add" + acquire-release + halfword. The width suffix is
// peeled BEFORE the ordering, because `l` (release) and `b`/`h` can both end the
// mnemonic and only that order is unambiguous. Returns NO if `mn` doesn't start
// with `prefix`; *body is then untouched, so a non-atomic `ldr`/`ldp` falls
// through to the ordinary load handlers.
//   *sizeBits: 0=byte, 1=halfword, left at -1 when the width comes from the
//   register (w→2, x→3) instead of the mnemonic.
static BOOL xaSplitAtomic(NSString *mn, NSString *prefix, NSString **body,
                          uint32_t *A, uint32_t *R, int *sizeBits) {
    if (![mn hasPrefix:prefix]) return NO;
    NSString *t = [mn substringFromIndex:prefix.length];
    if      ([t hasSuffix:@"b"]) { *sizeBits = 0; t = [t substringToIndex:t.length-1]; }
    else if ([t hasSuffix:@"h"]) { *sizeBits = 1; t = [t substringToIndex:t.length-1]; }
    if      ([t hasSuffix:@"al"]) { *A = 1; *R = 1; t = [t substringToIndex:t.length-2]; }
    else if ([t hasSuffix:@"a"])  { *A = 1;         t = [t substringToIndex:t.length-1]; }
    else if ([t hasSuffix:@"l"])  { *R = 1;         t = [t substringToIndex:t.length-1]; }
    *body = t;
    return YES;
}

static uint32_t encMul(uint32_t base, int rd, int rn, int rm, int ra) {
    return base | ((uint32_t)rm << 16) | ((uint32_t)ra << 10) | ((uint32_t)rn << 5) | (uint32_t)rd;
}

- (uint32_t)encodeLine:(NSString *)line
                    pc:(uint64_t)pc
               resolve:(uint32_t (^)(NSString *, BOOL *))resolve
                 error:(NSError **)error {
    // strip comment
    line = stripComment(line);
    line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (line.length == 0) { if (error) *error = asmErr(@"empty"); return 0; }

    // mnemonic = up to first whitespace
    NSRange sp = [line rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *mn, *rest;
    if (sp.location == NSNotFound) { mn = line; rest = @""; }
    else { mn = [line substringToIndex:sp.location]; rest = [[line substringFromIndex:sp.location]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]; }
    NSArray<NSString *> *ops = splitOperands(rest);
    int rd, rn, rm, ra; BOOL d64, n64, m64, dSP, nSP, mSP;

    #define NEED(n) do { if (ops.count < (n)) { if(error)*error=asmErr(@"%@ needs %d ops",mn,(n)); return 0; } } while(0)
    #define REG(i,rr,w,ss) do { if(!parseReg(ops[i],&rr,&w,&ss)){if(error)*error=asmErr(@"bad reg %@",ops[i]);return 0;} } while(0)

    // ── NEON (Advanced SIMD) — dispatch before the scalar handlers, which share
    //    add/mul/f* mnemonics but take non-vector operands. Base opcodes derived
    //    byte-exact from clang (tests/asm-arm64/oracle-diff). Fields OR'd in:
    //    Q<<30, size<<22 (element size 0=b/1=h/2=s/3=d, or the 1-bit float sz),
    //    Rm<<16, Rn<<5, Rd.  ──
    {
        static NSDictionary *int3, *logic3, *float3, *misc2i, *misc2f, *red, *perm, *pairlp;
        static dispatch_once_t nonce;
        dispatch_once(&nonce, ^{
            // 3-same, element size from the arrangement (size<<22):
            int3 = @{@"add":@0x0E208400u,@"sub":@0x2E208400u,@"mul":@0x0E209C00u,
                     @"mla":@0x0E209400u,@"mls":@0x2E209400u,
                     @"smax":@0x0E206400u,@"smin":@0x0E206C00u,@"umax":@0x2E206400u,@"umin":@0x2E206C00u,
                     @"cmeq":@0x2E208C00u,@"cmgt":@0x0E203400u,@"cmge":@0x0E203C00u,
                     @"cmhi":@0x2E203400u,@"cmhs":@0x2E203C00u,
                     @"sshl":@0x0E204400u,@"ushl":@0x2E204400u,
                     @"saba":@0x0E207C00u,@"uaba":@0x2E207C00u,@"sabd":@0x0E207400u,@"uabd":@0x2E207400u};
            // logical 3-same — no size field (arrangement must be 8b/16b):
            logic3 = @{@"and":@0x0E201C00u,@"bic":@0x0E601C00u,@"orr":@0x0EA01C00u,
                       @"orn":@0x0EE01C00u,@"eor":@0x2E201C00u};
            // float 3-same — 1-bit sz at bit22 (0 for .2s/.4s, 1 for .2d):
            float3 = @{@"fadd":@0x0E20D400u,@"fsub":@0x0EA0D400u,@"fmul":@0x2E20DC00u,@"fdiv":@0x2E20FC00u,
                       @"fmla":@0x0E20CC00u,@"fmls":@0x0EA0CC00u,@"fmax":@0x0E20F400u,@"fmin":@0x0EA0F400u,
                       @"fcmeq":@0x0E20E400u,@"fcmgt":@0x2EA0E400u};
            // 2-reg misc, integer (size<<22):
            misc2i = @{@"neg":@0x2E20B800u,@"abs":@0x0E20B800u,@"not":@0x2E205800u,@"mvn":@0x2E205800u,
                       @"cnt":@0x0E205800u,@"rev64":@0x0E200800u,@"rev16":@0x0E201800u,@"rev32":@0x2E200800u};
            // 2-reg misc, float (1-bit sz at bit22):
            misc2f = @{@"fneg":@0x2EA0F800u,@"fabs":@0x0EA0F800u,@"scvtf":@0x0E21D800u,@"ucvtf":@0x2E21D800u,
                       @"fcvtzs":@0x0EA1B800u,@"fcvtzu":@0x2EA1B800u,@"frintz":@0x0EA19800u};
            // across-lanes reduction (scalar Vd, vector Vn.T; size<<22):
            red = @{@"addv":@0x0E31B800u,@"saddlv":@0x0E303800u,@"uaddlv":@0x2E303800u,
                    @"smaxv":@0x0E30A800u,@"sminv":@0x0E31A800u,@"umaxv":@0x2E30A800u,@"uminv":@0x2E31A800u};
            // permute 3-same (size<<22):
            perm = @{@"zip1":@0x0E003800u,@"zip2":@0x0E007800u,@"uzp1":@0x0E001800u,
                     @"uzp2":@0x0E005800u,@"trn1":@0x0E002800u,@"trn2":@0x0E006800u};
            // pairwise add long: adds ADJACENT lanes of Vn and widens, so the
            // destination arrangement is HALF the lane count at twice the width
            // (`uaddlp v0.4s, v1.8h`). Both Q and size therefore come from the
            // SOURCE operand, not the destination as every table above takes
            // them — the one exception, and the reason this is its own case.
            // The vectoriser's widening-sum reduction emits it (bug 028).
            pairlp = @{@"saddlp":@0x0E202800u, @"uaddlp":@0x2E202800u};
        });
        int vd,vs,vq,vn2,vm2,t;
        BOOL op0vec = ops.count>=1 && parseVReg(ops[0],&vd,&vs,&vq);
        // dup Vd.T, Rn  (duplicate a GP reg across lanes)
        if (op0vec && [mn isEqualToString:@"dup"] && ops.count==2 && ![ops[1] hasPrefix:@"v"]) {
            BOOL w,sp; if(!parseReg(ops[1],&rn,&w,&sp)){if(error)*error=asmErr(@"bad dup src");return 0;}
            return 0x0E000C00u | ((uint32_t)vq<<30) | ((1u<<vs)<<16) | ((uint32_t)rn<<5) | (uint32_t)vd;
        }
        NSNumber *b;
        if (op0vec && (b=int3[mn]) && ops.count==3 && parseVReg(ops[1],&vn2,&t,&t) && parseVReg(ops[2],&vm2,&t,&t))
            return b.unsignedIntValue | ((uint32_t)vq<<30) | ((uint32_t)vs<<22) | ((uint32_t)vm2<<16) | ((uint32_t)vn2<<5) | (uint32_t)vd;
        if (op0vec && (b=logic3[mn]) && ops.count==3 && parseVReg(ops[1],&vn2,&t,&t) && parseVReg(ops[2],&vm2,&t,&t))
            return b.unsignedIntValue | ((uint32_t)vq<<30) | ((uint32_t)vm2<<16) | ((uint32_t)vn2<<5) | (uint32_t)vd;
        if (op0vec && (b=float3[mn]) && ops.count==3 && parseVReg(ops[1],&vn2,&t,&t) && parseVReg(ops[2],&vm2,&t,&t))
            return b.unsignedIntValue | ((uint32_t)vq<<30) | ((uint32_t)(vs==3?1:0)<<22) | ((uint32_t)vm2<<16) | ((uint32_t)vn2<<5) | (uint32_t)vd;
        if (op0vec && (b=perm[mn]) && ops.count==3 && parseVReg(ops[1],&vn2,&t,&t) && parseVReg(ops[2],&vm2,&t,&t))
            return b.unsignedIntValue | ((uint32_t)vq<<30) | ((uint32_t)vs<<22) | ((uint32_t)vm2<<16) | ((uint32_t)vn2<<5) | (uint32_t)vd;
        if (op0vec && (b=pairlp[mn]) && ops.count==2) {
            int srcVs, srcQ;
            if (!parseVReg(ops[1],&vn2,&srcVs,&srcQ)) {
                if (error) *error = asmErr(@"bad %@ source arrangement", mn);
                return 0;
            }
            return b.unsignedIntValue | ((uint32_t)srcQ<<30) | ((uint32_t)srcVs<<22)
                 | ((uint32_t)vn2<<5) | (uint32_t)vd;
        }
        if (op0vec && (b=misc2i[mn]) && ops.count==2 && parseVReg(ops[1],&vn2,&t,&t))
            return b.unsignedIntValue | ((uint32_t)vq<<30) | ((uint32_t)vs<<22) | ((uint32_t)vn2<<5) | (uint32_t)vd;
        if (op0vec && (b=misc2f[mn]) && ops.count==2 && parseVReg(ops[1],&vn2,&t,&t))
            return b.unsignedIntValue | ((uint32_t)vq<<30) | ((uint32_t)(vs==3?1:0)<<22) | ((uint32_t)vn2<<5) | (uint32_t)vd;
        // ext Vd.16b, Vn.16b, Vm.16b, #imm4  (byte extract)
        if (op0vec && [mn isEqualToString:@"ext"] && ops.count==4 && parseVReg(ops[1],&vn2,&t,&t) && parseVReg(ops[2],&vm2,&t,&t)) {
            int64_t idx=0; parseImm(ops[3],&idx);
            return 0x2E000000u | ((uint32_t)vq<<30) | ((uint32_t)vm2<<16) | (((uint32_t)idx&0xF)<<11) | ((uint32_t)vn2<<5) | (uint32_t)vd;
        }
        // across-lanes reduction:  <mn> <scalar Vd>, Vn.T
        if ((b=red[mn]) && ops.count==2 && !op0vec && parseVReg(ops[1],&vn2,&vs,&vq)) {
            int rd0,rz; if(!parseFReg(ops[0],&rd0,&rz)){if(error)*error=asmErr(@"bad reduce dst");return 0;}
            return b.unsignedIntValue | ((uint32_t)vq<<30) | ((uint32_t)vs<<22) | ((uint32_t)vn2<<5) | (uint32_t)rd0;
        }
        // by-element: Vd.T, Vn.T, Vm.Ts[i].  H:L:M hold the lane; for .s the index
        // is L(bit21):H(bit11), for .d it is H(bit11); Vm is 4-bit (v0-v15) + M(bit20).
        static NSDictionary *elem; static dispatch_once_t eonce;
        dispatch_once(&eonce, ^{
            elem = @{@"fmla":@0x0F801000u,@"fmls":@0x0F805000u,@"fmul":@0x0F809000u,
                     @"mul":@0x0F808000u,@"mla":@0x2F800000u,@"mls":@0x6F804000u};
        });
        int ei,esz;
        if (op0vec && (b=elem[mn]) && ops.count==3 && parseVReg(ops[1],&vn2,&t,&t) && parseVElem(ops[2],&vm2,&esz,&ei)) {
            uint32_t L,H,sz;
            if (esz==2) { sz=0; L=(uint32_t)(ei&1); H=(uint32_t)((ei>>1)&1); }   // .s
            else        { sz=1; L=0; H=(uint32_t)(ei&1); }                        // .d
            uint32_t M=(uint32_t)((vm2>>4)&1);
            return b.unsignedIntValue | ((uint32_t)vq<<30) | (sz<<22) | (L<<21)
                 | (M<<20) | (((uint32_t)vm2&0xF)<<16) | (H<<11) | ((uint32_t)vn2<<5) | (uint32_t)vd;
        }
        // dup Vd.T, Vn.Ts[i]  (duplicate one lane across all lanes).
        if (op0vec && [mn isEqualToString:@"dup"] && ops.count==2 && parseVElem(ops[1],&vn2,&esz,&ei)) {
            uint32_t imm5 = ((uint32_t)ei << (esz+1)) | (1u << esz);
            return 0x0E000400u | ((uint32_t)vq<<30) | (imm5<<16) | ((uint32_t)vn2<<5) | (uint32_t)vd;
        }
        // ld1/st1 { Vt.T }, [Xn]  (single-register, no offset). The `{ Vt.T }` list
        // arrives as one operand (splitOperands doesn't break on the inner comma of
        // a single-reg list); strip the braces and parse the arrangement.
        if (([mn isEqualToString:@"ld1"]||[mn isEqualToString:@"st1"]) && ops.count==2
            && [ops[0] hasPrefix:@"{"]) {
            NSString *inner=[[ops[0] stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"{} "]] stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            int vt,vsz,vqq;
            if (parseVReg(inner,&vt,&vsz,&vqq) && [ops[1] hasPrefix:@"["] && [ops[1] hasSuffix:@"]"]) {
                NSString *bn=[[ops[1] substringWithRange:NSMakeRange(1,ops[1].length-2)]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                BOOL w,sp; if(!parseReg(bn,&rn,&w,&sp)){if(error)*error=asmErr(@"bad ld1/st1 base");return 0;}
                uint32_t base=[mn isEqualToString:@"ld1"]?0x0C407000u:0x0C007000u;
                return base | ((uint32_t)vqq<<30) | ((uint32_t)vsz<<10) | ((uint32_t)rn<<5) | (uint32_t)vt;
            }
        }
    }

    // ── moves ──
    if ([mn isEqualToString:@"mov"]) {
        NEED(2); REG(0, rd, d64, dSP);
        int64_t imm;
        if ([ops[1] hasPrefix:@"#"] && parseImm(ops[1], &imm)) {
            // mov reg,#imm — single-instruction only (clang emits movz/movk
            // explicitly for wider constants): try MOVZ (imm16<<hw) then MOVN (~).
            int nsh = d64 ? 4 : 2;
            uint64_t u = (uint64_t)imm; if (!d64) u &= 0xFFFFFFFFu;
            for (int sft=0; sft<nsh; sft++) {
                uint64_t mask = 0xFFFFull << (16*sft);
                if ((u & ~mask) == 0)
                    return (d64?0xD2800000u:0x52800000u) | ((uint32_t)sft<<21) | ((uint32_t)((u>>(16*sft))&0xFFFF)<<5) | (uint32_t)rd;
            }
            uint64_t nv = (~u) & (d64 ? ~0ull : 0xFFFFFFFFu);
            for (int sft=0; sft<nsh; sft++) {
                uint64_t mask = 0xFFFFull << (16*sft);
                if ((nv & ~mask) == 0)
                    return (d64?0x92800000u:0x12800000u) | ((uint32_t)sft<<21) | ((uint32_t)((nv>>(16*sft))&0xFFFF)<<5) | (uint32_t)rd;
            }
            uint32_t bm;   // ORR Rd,ZR,#bitmask — clang's `mov` for a logical immediate
            if (encodeLogImm(u, d64?64:32, &bm))
                return (d64?0xB2000000u:0x32000000u) | (bm<<10) | (31u<<5) | (uint32_t)rd;
            if(error)*error=asmErr(@"mov imm %lld needs >1 instruction",(long long)imm); return 0;
        }
        REG(1, rm, m64, mSP);
        if (dSP || mSP) {                                          // mov involving sp -> add Rd,Rm,#0
            return (d64?0x91000000u:0x11000000u) | ((uint32_t)rm << 5) | (uint32_t)rd;
        }
        return (d64?0xAA0003E0u:0x2A0003E0u) | ((uint32_t)rm << 16) | (uint32_t)rd; // orr Rd,ZR,Rm
    }

    // ── scalar floating-point ──  ('ty' bit22: 0=single,1=double)
    if ([mn hasPrefix:@"f"] || [mn isEqualToString:@"scvtf"] || [mn isEqualToString:@"ucvtf"]) {
        int fd,fdz,fn,fnz,fm,fmz,fa,faz;
        // 3-source: fmadd/fmsub/fnmadd/fnmsub Fd,Fn,Fm,Fa. One encoding group;
        // o1 (bit 21) and o0 (bit 15) select which.
        if (([mn isEqualToString:@"fmadd"]||[mn isEqualToString:@"fmsub"]
             ||[mn isEqualToString:@"fnmadd"]||[mn isEqualToString:@"fnmsub"]) && ops.count==4
            && parseFReg(ops[0],&fd,&fdz)) {
            parseFReg(ops[1],&fn,&fnz); parseFReg(ops[2],&fm,&fmz); parseFReg(ops[3],&fa,&faz);
            uint32_t ty=(fdz==3)?0x00400000u:0; uint32_t base=0x1F000000u;
            if ([mn isEqualToString:@"fmsub"])  base=0x1F008000u;
            if ([mn isEqualToString:@"fnmadd"]) base=0x1F200000u;
            if ([mn isEqualToString:@"fnmsub"]) base=0x1F208000u;
            return base|ty|((uint32_t)fm<<16)|((uint32_t)fa<<10)|((uint32_t)fn<<5)|(uint32_t)fd;
        }
        // arithmetic: fadd/fsub/fmul/fdiv Fd,Fn,Fm
        static NSDictionary *f3; if(!f3) f3=@{@"fadd":@0x1E202800,@"fsub":@0x1E203800,@"fmul":@0x1E200800,@"fdiv":@0x1E201800};
        if (f3[mn] && ops.count==3 && parseFReg(ops[0],&fd,&fdz)) {
            parseFReg(ops[1],&fn,&fnz); parseFReg(ops[2],&fm,&fmz);
            uint32_t ty=(fdz==3)?0x00400000u:0;
            return [f3[mn] unsignedIntValue]|ty|((uint32_t)fm<<16)|((uint32_t)fn<<5)|(uint32_t)fd;
        }
        // fcsel Fd,Fn,Fm,cond — the FP conditional select. The integer csel
        // cannot take an FP destination ("bad reg d9"), so a float `?:` or an
        // if-converted `if (x < 0) x = -x` needs this one.
        if ([mn isEqualToString:@"fcsel"] && ops.count==4 && parseFReg(ops[0],&fd,&fdz)) {
            parseFReg(ops[1],&fn,&fnz); parseFReg(ops[2],&fm,&fmz);
            int cc=condCode(ops[3]);
            if(cc<0){if(error)*error=asmErr(@"bad cond %@",ops[3]);return 0;}
            uint32_t ty=(fdz==3)?0x00400000u:0;          // 3 == d (double)
            return 0x1E200C00u|ty|((uint32_t)fm<<16)|((uint32_t)cc<<12)
                 |((uint32_t)fn<<5)|(uint32_t)fd;
        }
        // 2-reg fp: fneg/fsqrt Fd,Fn ; fcvt Fd,Fn (precision) ; fcmp Fn,Fm
        if ([mn isEqualToString:@"fneg"]||[mn isEqualToString:@"fsqrt"]) {
            parseFReg(ops[0],&fd,&fdz); parseFReg(ops[1],&fn,&fnz);
            uint32_t ty=(fdz==3)?0x00400000u:0; uint32_t base=[mn isEqualToString:@"fneg"]?0x1E214000u:0x1E21C000u;
            return base|ty|((uint32_t)fn<<5)|(uint32_t)fd;
        }
        if ([mn isEqualToString:@"fcmp"]) {
            parseFReg(ops[0],&fn,&fnz); parseFReg(ops[1],&fm,&fmz);
            uint32_t ty=(fnz==3)?0x00400000u:0;
            return 0x1E202000u|ty|((uint32_t)fm<<16)|((uint32_t)fn<<5);
        }
        if ([mn isEqualToString:@"fcvt"]) {   // precision convert; encode by src/dst size
            parseFReg(ops[0],&fd,&fdz); parseFReg(ops[1],&fn,&fnz);
            uint32_t base = (fnz==2 && fdz==3)?0x1E22C000u : (fnz==3 && fdz==2)?0x1E624000u : 0;
            if(!base){if(error)*error=asmErr(@"unsupported fcvt");return 0;}
            return base|((uint32_t)fn<<5)|(uint32_t)fd;
        }
        // fmov: reg-reg, gpr->fp, fp->gpr, immediate
        if ([mn isEqualToString:@"fmov"]) {
            int rn2; BOOL w2,s2;
            if (ops.count>=2 && parseFReg(ops[0],&fd,&fdz) && [ops[1] hasPrefix:@"#"]) {  // fmov Fd, #<float>
                double val = atof([ops[1] substringFromIndex:1].UTF8String);
                BOOL dbl = (fdz==3); int found=-1;
                for (int i=0;i<256;i++) {                     // brute-force the 8-bit fp immediate (VFPExpandImm)
                    int b6=(i>>6)&1;
                    if (!dbl) {
                        uint32_t exp=((b6?0u:1u)<<7)|((b6?0x1Fu:0u)<<2)|(((uint32_t)i>>4)&3);
                        uint32_t bits=(((uint32_t)i>>7)<<31)|(exp<<23)|(((uint32_t)i&0xF)<<19);
                        float f; memcpy(&f,&bits,4); if ((double)f==val){found=i;break;}
                    } else {
                        uint64_t exp=((b6?0ull:1ull)<<10)|((b6?0xFFull:0ull)<<2)|(((uint64_t)i>>4)&3);
                        uint64_t bits=(((uint64_t)i>>7)<<63)|(exp<<52)|(((uint64_t)i&0xF)<<48);
                        double d; memcpy(&d,&bits,8); if (d==val){found=i;break;}
                    }
                }
                if (found<0){if(error)*error=asmErr(@"fmov #%@ not an 8-bit fp immediate",ops[1]);return 0;}
                return (dbl?0x1E601000u:0x1E201000u) | ((uint32_t)found<<13) | (uint32_t)fd;
            }
            if (parseFReg(ops[0],&fd,&fdz) && parseFReg(ops[1],&fn,&fnz)) {   // FMOV reg
                uint32_t ty=(fdz==3)?0x00400000u:0; return 0x1E204000u|ty|((uint32_t)fn<<5)|(uint32_t)fd;
            }
            if (parseFReg(ops[0],&fd,&fdz) && parseReg(ops[1],&rn2,&w2,&s2)) { // GPR -> FP
                uint32_t base=(fdz==3)?0x9E670000u:0x1E270000u; return base|((uint32_t)rn2<<5)|(uint32_t)fd;
            }
            if (parseReg(ops[0],&rd,&d64,&dSP) && parseFReg(ops[1],&fn,&fnz)) { // FP -> GPR
                uint32_t base=(fnz==3)?0x9E660000u:0x1E260000u; return base|((uint32_t)fn<<5)|(uint32_t)rd;
            }
            if(error)*error=asmErr(@"unsupported fmov"); return 0;
        }
        // SIMD-scalar FP<->FP round-trip forms (both operands d/s): scvtf/ucvtf
        // Fd,Fn (int-in-fp-reg -> fp) and fcvtzs/fcvtzu Fd,Fn (fp -> int-in-fp-reg).
        // clang uses these to compute trunc()/(double)(long)x without leaving the
        // FP file. Distinguished from the GPR forms by ops.lastObject being an FP reg.
        // scvtf/ucvtf take an int-in-fp source (ops[1]); fcvtzs/fcvtzu produce an
        // int-in-fp dest (ops[0]). The SIMD-scalar form is selected by that operand
        // being an FP (d/s) reg rather than a GPR.
        BOOL toFP = [mn isEqualToString:@"scvtf"]||[mn isEqualToString:@"ucvtf"];
        NSString *discr = toFP ? (ops.count>1?ops[1]:@"") : (ops.count>0?ops[0]:@"");
        BOOL discrIsFP = discr.length && ({ unichar c=[discr characterAtIndex:0]; c=='d'||c=='s'; });
        if (discrIsFP && (toFP || [mn isEqualToString:@"fcvtzs"]||[mn isEqualToString:@"fcvtzu"])) {
            int fdz2; parseFReg(ops[0],&fd,&fdz); parseFReg(ops[1],&fn,&fdz2);
            uint32_t dbl=(fdz==3)?0x00400000u:0;   // sz bit22: double vs single
            uint32_t base;
            if ([mn isEqualToString:@"scvtf"])      base=0x5E21D800u|dbl;
            else if ([mn isEqualToString:@"ucvtf"]) base=0x7E21D800u|dbl;
            else if ([mn isEqualToString:@"fcvtzs"])base=0x5EA1B800u|dbl;
            else                                    base=0x7EA1B800u|dbl;
            return base|((uint32_t)fn<<5)|(uint32_t)fd;
        }
        // int -> fp: scvtf/ucvtf Fd, Wn[, #fbits] ; fp -> int: fcvtzs/fcvtzu Xd, Fn
        if ([mn isEqualToString:@"scvtf"]||[mn isEqualToString:@"ucvtf"]) {
            int rn2; BOOL w2,s2; parseFReg(ops[0],&fd,&fdz); parseReg(ops[1],&rn2,&w2,&s2);
            if (ops.count>=3 && [ops[2] hasPrefix:@"#"]) { // fixed-point variant
                int64_t fb; parseImm(ops[2],&fb);
                uint32_t base=[mn isEqualToString:@"scvtf"]?0x1E020000u:0x1E030000u;
                uint32_t sf=w2?0x80000000u:0; uint32_t ty=(fdz==3)?0x00400000u:0;
                uint32_t scale=(uint32_t)(64-fb);
                return base|sf|ty|(scale<<10)|((uint32_t)rn2<<5)|(uint32_t)fd;
            }
            uint32_t base=[mn isEqualToString:@"scvtf"]
                ?((fdz==3)?0x1E620000u:0x1E220000u):((fdz==3)?0x1E630000u:0x1E230000u);
            uint32_t sf=w2?0x80000000u:0;
            return base|sf|((uint32_t)rn2<<5)|(uint32_t)fd;
        }
        if ([mn isEqualToString:@"fcvtzs"]||[mn isEqualToString:@"fcvtzu"]) {
            BOOL w2,s2; parseReg(ops[0],&rd,&w2,&s2); parseFReg(ops[1],&fn,&fnz);
            uint32_t base=[mn isEqualToString:@"fcvtzs"]
                ?((fnz==3)?0x1E780000u:0x1E380000u):((fnz==3)?0x1E790000u:0x1E390000u);
            uint32_t sf=w2?0x80000000u:0;   // x-dest sets sf (bit31) -> 0x9E..
            return base|sf|((uint32_t)fn<<5)|(uint32_t)rd;
        }
        // fall through to integer handling if not a recognised FP form (none currently)
    }

    if ([mn isEqualToString:@"movz"] || [mn isEqualToString:@"movk"] || [mn isEqualToString:@"movn"]) {
        NEED(2); REG(0, rd, d64, dSP);
        int64_t imm; if (!parseImm(ops[1], &imm)) { if(error)*error=asmErr(@"bad imm"); return 0; }
        uint32_t hw = 0;
        if (ops.count >= 3) { // lsl #s
            int64_t s; NSString *sh = ops[2];
            NSRange r = [sh rangeOfString:@"#"];
            if (r.location != NSNotFound && parseImm([sh substringFromIndex:r.location], &s)) hw = (uint32_t)(s / 16);
        }
        uint32_t base = [mn isEqualToString:@"movk"] ? (d64?0xF2800000u:0x72800000u)
                     : [mn isEqualToString:@"movn"] ? (d64?0x92800000u:0x12800000u)
                                                     : (d64?0xD2800000u:0x52800000u);
        return base | (hw << 21) | ((uint32_t)(imm & 0xFFFF) << 5) | (uint32_t)rd;
    }

    // ── add/sub family ──
    NSDictionary *asImm = @{@"add":@0x11000000,@"sub":@0x51000000,@"adds":@0x31000000,@"subs":@0x71000000};
    NSDictionary *asReg = @{@"add":@0x0B000000,@"sub":@0x4B000000,@"adds":@0x2B000000,@"subs":@0x6B000000};
    // add Xd, Xn, sym@PAGEOFF  ->  ADD imm, imm12=0 + PAGEOFF12 fixup
    if (([mn isEqualToString:@"add"]) && ops.count>=3 && [ops[2] rangeOfString:@"@"].location!=NSNotFound) {
        REG(0,rd,d64,dSP); REG(1,rn,n64,nSP);
        NSString *sym=ops[2]; NSRange at=[sym rangeOfString:@"@"]; NSString *bare=[sym substringToIndex:at.location];
        XAArm64Fixup *f=[XAArm64Fixup new]; f.offset=pc; f.symbol=bare; f.kind=XAArm64FixupPageOff12;
        if(_fixups)[_fixups addObject:f];
        return (d64?0x91000000u:0x11000000u) | ((uint32_t)rn<<5) | (uint32_t)rd;
    }
    if (asImm[mn] || [mn isEqualToString:@"cmp"] || [mn isEqualToString:@"cmn"] || [mn isEqualToString:@"neg"]) {
        BOOL isCmp = [mn isEqualToString:@"cmp"] || [mn isEqualToString:@"cmn"];
        BOOL isNeg = [mn isEqualToString:@"neg"];
        NSString *key = isCmp ? ([mn isEqualToString:@"cmp"]?@"subs":@"adds")
                     : isNeg ? @"sub" : mn;
        // build a normalized operand list with an explicit Rd
        NSMutableArray *o = [ops mutableCopy];
        if (isCmp) [o insertObject:@"wzr" atIndex:0];      // cmp Rn,X -> subs wzr,Rn,X (width fixed below)
        if (isNeg) [o insertObject:(([ops[0] hasPrefix:@"x"])?@"xzr":@"wzr") atIndex:1]; // neg Rd,Rm -> sub Rd,ZR,Rm
        // Immediate vs register is decided by operand 2, NOT by the last one.
        // The shifted spelling `add Rd, Rn, #imm, lsl #12` ends in a shift, so
        // testing the last operand sent it down the REGISTER path, which then
        // tried to parse `#1` as a register and reported "bad rm #1". That form
        // is valid AArch64 and emitSpAddr emits it for any frame-slot address at
        // a 4096-aligned offset, so it was a hard build failure on big frames.
        // A register shift (`add x0, x1, x2, lsl #3`) still has a register at
        // operand 2 and is unaffected.
        BOOL lastImm = (o.count > 2) && [o[2] hasPrefix:@"#"];
        if (isCmp) { // fix zero-reg width to match Rn
            BOOL w64,ss; int t; parseReg(ops[0], &t, &w64, &ss); o[0] = w64?@"xzr":@"wzr";
        }
        if (lastImm && !isNeg) {
            uint32_t out; if (!encAddSubImm([asImm[key] unsignedIntValue], o, &out, error)) return 0; return out;
        }
        // register form (incl neg, and extended register "Rm, uxtw") — parse from `o`
        if(!parseReg(o[0],&rd,&d64,&dSP)||!parseReg(o[1],&rn,&n64,&nSP)){if(error)*error=asmErr(@"bad reg");return 0;}
        BOOL wm,ms; int rmn; if(!parseReg(o[2], &rmn,&wm,&ms)){if(error)*error=asmErr(@"bad rm %@",o[2]);return 0;}
        rm = rmn;
        uint32_t base = [asReg[key] unsignedIntValue];
        if (o.count >= 4) {
            NSString *mod = [o[3] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *mkw = [[mod componentsSeparatedByString:@" "] firstObject];
            uint32_t sf = d64?0x80000000u:0;
            NSDictionary *shk = @{@"lsl":@0,@"lsr":@1,@"asr":@2};
            if (shk[mkw]) { // shifted register: shift(23:22), imm6(15:10)
                int64_t amt=0; NSRange h=[mod rangeOfString:@"#"]; if(h.location!=NSNotFound) parseImm([mod substringFromIndex:h.location],&amt);
                return base | sf | ((uint32_t)[shk[mkw] unsignedIntValue]<<22) | ((uint32_t)rm<<16) | ((uint32_t)(amt&0x3F)<<10) | ((uint32_t)rn<<5) | (uint32_t)rd;
            }
            static NSDictionary *em; if(!em) em=@{@"uxtb":@0,@"uxth":@1,@"uxtw":@2,@"uxtx":@3,@"sxtb":@4,@"sxth":@5,@"sxtw":@6,@"sxtx":@7};
            NSNumber *opt = em[mkw]; if(!opt){if(error)*error=asmErr(@"bad extend %@",mod);return 0;}
            // The extend names IMPLY the index width — uxtb/uxth/uxtw/sxtb/
            // sxth/sxtw take Wm, uxtx/sxtx take Xm. The encoding has no
            // separate width bit, so accepting the wrong spelling silently
            // encodes an instruction that reads a DIFFERENT register view
            // (`add x0, x1, x2, uxtw` executes as `…, w2, uxtw` — blewit
            // finding #8's other half). Reject, like the reference assembler.
            {
                uint32_t ov = (uint32_t)opt.intValue;
                BOOL wantsX = (ov == 3u || ov == 7u);
                if (wantsX != (BOOL)wm) {
                    if(error)*error=asmErr(@"extend %@ requires %s index register (got %@)",
                                           mkw, wantsX?"an X":"a W", o[2]);
                    return 0;
                }
            }
            int64_t amt=0; NSRange h=[mod rangeOfString:@"#"]; if(h.location!=NSNotFound) parseImm([mod substringFromIndex:h.location],&amt);
            return base | 0x00200000u | sf | ((uint32_t)rm<<16) | ((uint32_t)opt.intValue<<13) | ((uint32_t)(amt&7)<<10) | ((uint32_t)rn<<5) | (uint32_t)rd;
        }
        uint32_t sf = d64?0x80000000u:0;
        if (!dSP && !nSP) {   // the SP forms below imply an extend, which may narrow
            if (!xaSameWidth(mn, d64, n64, error)) return 0;
            if (!xaSameWidth(mn, d64, wm,  error)) return 0;
        }
        if (dSP || nSP) { // SP can't use shifted-reg form -> extended reg, uxtx/uxtw, imm3=0
            uint32_t opt = d64 ? 3u : 2u;
            return base | 0x00200000u | sf | ((uint32_t)rm<<16) | (opt<<13) | ((uint32_t)rn<<5) | (uint32_t)rd;
        }
        return base | sf | ((uint32_t)rm<<16) | ((uint32_t)rn<<5) | (uint32_t)rd; // shift=0,imm6=0
    }
    if (asReg[mn] && (ops.count>=3) && ![[ops lastObject] hasPrefix:@"#"] && ![ops[2] hasPrefix:@"#"]) {
        // add/sub/subs pure register form when third op is a register (handled above for imm)
    }

    // ── logical (shifted reg) ──
    // The N-bit forms (bic/orn/eon/bics — "op with the inverted second operand")
    // sit at +0x200000 from their plain siblings. clang emits `bic Wd,Wn,Wm,asr
    // #31` for a signed-max idiom, which is also the first shifted-register
    // logical operand in the runtime, hence the optional 4th operand below.
    NSDictionary *logReg = @{@"and":@0x0A000000,@"orr":@0x2A000000,@"eor":@0x4A000000,@"ands":@0x6A000000,
                             @"bic":@0x0A200000,@"orn":@0x2A200000,@"eon":@0x4A200000,@"bics":@0x6A200000};
    NSDictionary *logImm = @{@"and":@0x12000000,@"orr":@0x32000000,@"eor":@0x52000000,@"ands":@0x72000000};
    // `tst Rn, op` is `ands ZR, Rn, op`. Rewriting it into the alias it stands
    // for reuses the bitmask-immediate encoder below; a second copy of that is
    // the kind that drifts.
    if ([mn isEqualToString:@"tst"] && ops.count >= 2) {
        BOOL wide = [ops[0] hasPrefix:@"x"] || [ops[0] hasPrefix:@"X"];
        NSMutableArray<NSString *> *a2 = [@[wide ? @"xzr" : @"wzr"] mutableCopy];
        [a2 addObjectsFromArray:ops];
        mn = @"ands"; ops = a2;
    }
    if (logReg[mn]) {
        NEED(3); REG(0,rd,d64,dSP); REG(1,rn,n64,nSP);
        if ([ops[2] hasPrefix:@"#"]) {               // logical immediate (bitmask)
            if (!logImm[mn]) { if(error)*error=asmErr(@"%@ has no immediate form",mn); return 0; }
            int64_t v; if(!parseImm(ops[2],&v)){if(error)*error=asmErr(@"bad imm");return 0;}
            uint32_t bm; if(!encodeLogImm((uint64_t)v, d64?64:32, &bm)){if(error)*error=asmErr(@"bad bitmask #%llx",(unsigned long long)v);return 0;}
            uint32_t sf=d64?0x80000000u:0;
            return [logImm[mn] unsignedIntValue] | sf | (bm<<10) | ((uint32_t)rn<<5) | (uint32_t)rd;
        }
        REG(2,rm,m64,mSP);
        if (!xaSameWidth(mn, d64, n64, error)) return 0;
        if (!xaSameWidth(mn, d64, m64, error)) return 0;
        uint32_t sf=d64?0x80000000u:0, shTy=0, shAmt=0;
        if (ops.count >= 4) {                        // `, <lsl|lsr|asr|ror> #imm`
            NSArray<NSString *> *sw = [ops[3] componentsSeparatedByString:@"#"];
            NSString *kind = [sw[0] stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
            NSDictionary *shk = @{@"lsl":@0,@"lsr":@1,@"asr":@2,@"ror":@3};
            if (sw.count != 2 || !shk[kind]) { if(error)*error=asmErr(@"bad shift '%@'",ops[3]); return 0; }
            int64_t amt=0; if(!parseImm([@"#" stringByAppendingString:sw[1]],&amt)){if(error)*error=asmErr(@"bad shift amount");return 0;}
            shTy = [shk[kind] unsignedIntValue];
            shAmt = (uint32_t)(amt & (d64 ? 63 : 31));
        }
        return [logReg[mn] unsignedIntValue] | sf | (shTy<<22) | ((uint32_t)rm<<16)
             | (shAmt<<10) | ((uint32_t)rn<<5) | (uint32_t)rd;
    }

    // ── atomics: acquire/release loads-stores, and the LSE read-modify-writes ──
    // Threading (private:docs/Design/threading.md) puts these in the toolchain's path in
    // two ways: the runtime's C atomics compile to them, and the backend emits
    // `ldaddh`/`ldaddalh` inline for the ARC refcount under -fthread-safe-arc.
    //
    //   LDAR/STLR   size 001000 1 L 0 11111 1 11111 Rn Rt
    //   LD<op>/SWP  size 111000 A R 1 Rs  o3 opc 00 Rn Rt
    //   CAS         size 0010001 A 1 Rs  R  11111    Rn Rt
    //
    // The suffix carries BOTH the width (b/h/none/x-from-register) and the
    // ordering (a=acquire, l=release, al=both), so the mnemonic is split rather
    // than tabulated: `ldaddalh` is add + acquire-release + halfword.
    {
        static NSDictionary *lseOpc;   // opc field (bits 14:12) of the LSE RMW group
        static dispatch_once_t lonce;
        dispatch_once(&lonce, ^{
            lseOpc = @{@"add":@0u,@"clr":@1u,@"eor":@2u,@"set":@3u,
                       @"smax":@4u,@"smin":@5u,@"umax":@6u,@"umin":@7u};
        });
        NSString *body = nil; uint32_t A=0, R=0; int sizeBits = -1;
        // ── load/store EXCLUSIVE ──────────────────────────────────────────
        //   size 001000 o2 L o1 Rs o0 Rt2 Rn Rt
        // L picks load vs store, o0 the acquire/release ordering. The runtime's
        // compare-and-swap loops are built from these: without LSE (Android's
        // armv8-a baseline has no `cas`) an atomic RMW *is* an ldaxr/stlxr pair,
        // so this is not an optional corner of the encoding.
        if (([mn hasPrefix:@"ldxr"] || [mn hasPrefix:@"ldaxr"] ||
             [mn hasPrefix:@"stxr"] || [mn hasPrefix:@"stlxr"])) {
            BOOL isLoad = [mn hasPrefix:@"ld"];
            uint32_t o0 = ([mn hasPrefix:@"ldaxr"] || [mn hasPrefix:@"stlxr"]) ? 1 : 0;
            NSString *sfx = [mn substringFromIndex:
                (isLoad ? (o0 ? 5 : 4) : (o0 ? 5 : 4))];
            int sz;
            if      (sfx.length == 0)            sz = -1;   // width from the register
            else if ([sfx isEqualToString:@"b"]) sz = 0;
            else if ([sfx isEqualToString:@"h"]) sz = 1;
            else sz = -2;
            if (sz != -2 && ops.count == (isLoad ? 2u : 3u)) {
                NSUInteger ti = isLoad ? 0 : 1;             // index of Rt
                int rt; BOOL t64, tSP;
                if (!parseReg(ops[ti], &rt, &t64, &tSP)) {
                    if(error)*error=asmErr(@"bad %@ operand",mn); return 0; }
                if (sz < 0) sz = t64 ? 3 : 2;
                uint32_t rs = 31;
                if (!isLoad) {
                    int rsr; BOOL w3, s3;
                    if (!parseReg(ops[0], &rsr, &w3, &s3)) {
                        if(error)*error=asmErr(@"bad %@ status register",mn); return 0; }
                    rs = (uint32_t)rsr;
                }
                NSString *mem = [ops[ops.count-1] stringByTrimmingCharactersInSet:
                                    [NSCharacterSet characterSetWithCharactersInString:@"[] "]];
                BOOL w2, s2;
                if (!parseReg(mem, &rn, &w2, &s2)) { if(error)*error=asmErr(@"bad %@ base",mn); return 0; }
                return ((uint32_t)sz<<30) | 0x08000000u | ((isLoad?1u:0u)<<22)
                     | (rs<<16) | (o0<<15) | (31u<<10) | ((uint32_t)rn<<5) | (uint32_t)rt;
            }
        }
        // clrex — drop the exclusive monitor on the failure path of such a loop.
        if ([mn isEqualToString:@"clrex"]) return 0xD5033F5Fu;
        // ldar / ldarb / ldarh / stlr / stlrb / stlrh — Rt, [Xn]
        if (([mn hasPrefix:@"ldar"] || [mn hasPrefix:@"stlr"]) && ops.count == 2) {
            BOOL isLoad = [mn hasPrefix:@"ldar"];
            NSString *sfx = [mn substringFromIndex:4];
            int sz;
            if      (sfx.length == 0)              sz = -1;   // width from the register
            else if ([sfx isEqualToString:@"b"])   sz = 0;
            else if ([sfx isEqualToString:@"h"])   sz = 1;
            else sz = -2;
            if (sz != -2) {
                REG(0, rd, d64, dSP);
                if (sz < 0) sz = d64 ? 3 : 2;
                NSString *mem = [ops[1] stringByTrimmingCharactersInSet:
                                    [NSCharacterSet characterSetWithCharactersInString:@"[] "]];
                BOOL w2, s2;
                if (!parseReg(mem, &rn, &w2, &s2)) { if(error)*error=asmErr(@"bad %@ base",mn); return 0; }
                return ((uint32_t)sz<<30) | 0x08000000u | (1u<<23) | ((isLoad?1u:0u)<<22)
                     | (31u<<16) | (1u<<15) | (31u<<10) | ((uint32_t)rn<<5) | (uint32_t)rd;
            }
        }
        // ld<op>{a}{l}{b|h} Rs, Rt, [Xn]   /   swp{a}{l}{b|h} Rs, Rt, [Xn]
        BOOL isSwp = [mn hasPrefix:@"swp"];
        if (xaSplitAtomic(mn, isSwp ? @"swp" : @"ld", &body, &A, &R, &sizeBits)
            && (isSwp ? body.length == 0 : lseOpc[body] != nil)) {
            if (ops.count == 3) {
                uint32_t opc = isSwp ? 0u : [lseOpc[body] unsignedIntValue];
                int rs, rt; BOOL s64, t64, sSP2, tSP2;
                if (!parseReg(ops[0], &rs, &s64, &sSP2) || !parseReg(ops[1], &rt, &t64, &tSP2)) {
                    if (error) *error = asmErr(@"bad %@ operands", mn); return 0;
                }
                if (sizeBits < 0) sizeBits = s64 ? 3 : 2;
                NSString *mem = [ops[2] stringByTrimmingCharactersInSet:
                                    [NSCharacterSet characterSetWithCharactersInString:@"[] "]];
                BOOL w2, sp2;
                if (!parseReg(mem, &rn, &w2, &sp2)) { if(error)*error=asmErr(@"bad %@ base",mn); return 0; }
                return ((uint32_t)sizeBits<<30) | 0x38000000u | (A<<23) | (R<<22) | (1u<<21)
                     | ((uint32_t)rs<<16) | ((isSwp?1u:0u)<<15) | (opc<<12)
                     | ((uint32_t)rn<<5) | (uint32_t)rt;
            }
        }
        // cas{a}{l}{b|h} Rs, Rt, [Xn]
        body = nil; A = 0; R = 0; sizeBits = -1;
        if (xaSplitAtomic(mn, @"cas", &body, &A, &R, &sizeBits) && body.length == 0 && ops.count == 3) {
            int rs, rt; BOOL s64, t64, sSP2, tSP2;
            if (!parseReg(ops[0], &rs, &s64, &sSP2) || !parseReg(ops[1], &rt, &t64, &tSP2)) {
                if (error) *error = asmErr(@"bad %@ operands", mn); return 0;
            }
            if (sizeBits < 0) sizeBits = s64 ? 3 : 2;
            NSString *mem = [ops[2] stringByTrimmingCharactersInSet:
                                [NSCharacterSet characterSetWithCharactersInString:@"[] "]];
            BOOL w2, sp2;
            if (!parseReg(mem, &rn, &w2, &sp2)) { if(error)*error=asmErr(@"bad %@ base",mn); return 0; }
            return ((uint32_t)sizeBits<<30) | 0x08A00000u | (A<<22) | ((uint32_t)rs<<16)
                 | (R<<15) | (31u<<10) | ((uint32_t)rn<<5) | (uint32_t)rt;
        }
        // dmb/dsb/isb <option> — barriers, in case a runtime path needs one.
        if (([mn isEqualToString:@"dmb"] || [mn isEqualToString:@"dsb"]) && ops.count == 1) {
            static NSDictionary *bopt;
            static dispatch_once_t bonce;
            dispatch_once(&bonce, ^{
                bopt = @{@"oshld":@1u,@"oshst":@2u,@"osh":@3u,@"nshld":@5u,@"nshst":@6u,@"nsh":@7u,
                         @"ishld":@9u,@"ishst":@10u,@"ish":@11u,@"ld":@13u,@"st":@14u,@"sy":@15u};
            });
            NSNumber *o = bopt[ops[0]];
            if (!o) { if(error)*error=asmErr(@"bad barrier option '%@'",ops[0]); return 0; }
            uint32_t opc2 = [mn isEqualToString:@"dmb"] ? 5u : 4u;   // CRm-op2: dmb=101, dsb=100
            return 0xD503309Fu | ([o unsignedIntValue]<<8) | (opc2<<5);
        }
        if ([mn isEqualToString:@"isb"]) return 0xD5033FDFu;
    }
    if ([mn isEqualToString:@"mvn"]) { // orn Rd,ZR,Rm
        NEED(2); REG(0,rd,d64,dSP); REG(1,rm,m64,mSP);
        uint32_t sf=d64?0x80000000u:0;
        return 0x2A200000u | sf | ((uint32_t)rm<<16) | (31u<<5) | (uint32_t)rd;
    }

    // ── bitfield: uxtb/uxth/uxtw/sxtb/sxth/sxtw, lsl/lsr/asr (imm) ──
    if ([mn isEqualToString:@"uxtb"]||[mn isEqualToString:@"uxth"]||[mn isEqualToString:@"uxtw"]||
        [mn isEqualToString:@"sxtb"]||[mn isEqualToString:@"sxth"]||[mn isEqualToString:@"sxtw"]) {
        NEED(2); REG(0,rd,d64,dSP); REG(1,rn,n64,nSP);
        BOOL sign = [mn hasPrefix:@"s"];
        int imms = ([mn hasSuffix:@"b"])?7 : ([mn hasSuffix:@"h"])?15 : 31;
        // dest width (d64) picks 32- vs 64-bit BFM; SBFM/UBFM base per sign.
        uint32_t base = sign ? (d64?0x93400000u:0x13000000u) : (d64?0xD3400000u:0x53000000u);
        return base | (0u<<16) | ((uint32_t)imms<<10) | ((uint32_t)rn<<5) | (uint32_t)rd; // immr=0
    }
    if ([mn isEqualToString:@"lsl"]||[mn isEqualToString:@"lsr"]||[mn isEqualToString:@"asr"]||[mn isEqualToString:@"ror"]) {
        NEED(3); REG(0,rd,d64,dSP); REG(1,rn,n64,nSP);
        int64_t s;
        if (![ops[2] hasPrefix:@"#"]) {   // variable shift: LSLV/LSRV/ASRV/RORV
            BOOL w,ss; if(!parseReg(ops[2],&rm,&w,&ss)){if(error)*error=asmErr(@"bad shift reg");return 0;}
            if (!xaSameWidth(mn, d64, n64, error)) return 0;
            if (!xaSameWidth(mn, d64, w,   error)) return 0;
            uint32_t sf=d64?0x80000000u:0;
            uint32_t base=[mn isEqualToString:@"lsl"]?0x1AC02000u:[mn isEqualToString:@"lsr"]?0x1AC02400u:
                          [mn isEqualToString:@"asr"]?0x1AC02800u:0x1AC02C00u;
            return base|sf|((uint32_t)rm<<16)|((uint32_t)rn<<5)|(uint32_t)rd;
        }
        if (!parseImm(ops[2], &s)) { if(error)*error=asmErr(@"bad shift imm"); return 0; }
        int W = d64?64:32;
        if ([mn isEqualToString:@"lsl"]) {
            uint32_t immr=(uint32_t)((W - s)%W), imms=(uint32_t)(W-1-s);
            uint32_t base=d64?0xD3400000u:0x53000000u;
            return base | (immr<<16) | (imms<<10) | ((uint32_t)rn<<5)|(uint32_t)rd;
        } else if ([mn isEqualToString:@"lsr"]) {
            uint32_t base=d64?0xD3400000u:0x53000000u;
            return base | ((uint32_t)s<<16) | ((uint32_t)(W-1)<<10) | ((uint32_t)rn<<5)|(uint32_t)rd;
        } else {
            uint32_t base=d64?0x93400000u:0x13000000u;
            return base | ((uint32_t)s<<16) | ((uint32_t)(W-1)<<10) | ((uint32_t)rn<<5)|(uint32_t)rd;
        }
    }

    // ── mul family ──
    if ([mn isEqualToString:@"mul"]) { NEED(3); REG(0,rd,d64,dSP);REG(1,rn,n64,nSP);REG(2,rm,m64,mSP);
        return encMul(d64?0x9B000000u:0x1B000000u, rd,rn,rm,31); }
    if ([mn isEqualToString:@"madd"]||[mn isEqualToString:@"msub"]) { NEED(4);
        REG(0,rd,d64,dSP);REG(1,rn,n64,nSP);REG(2,rm,m64,mSP); BOOL w;BOOL s;REG(3,ra,w,s);
        uint32_t base = [mn isEqualToString:@"msub"] ? (d64?0x9B008000u:0x1B008000u):(d64?0x9B000000u:0x1B000000u);
        return encMul(base, rd,rn,rm,ra); }
    if ([mn isEqualToString:@"umull"]||[mn isEqualToString:@"smull"]) { NEED(3);
        BOOL w; REG(0,rd,w,dSP); REG(1,rn,w,nSP); REG(2,rm,w,mSP);
        return encMul([mn isEqualToString:@"umull"]?0x9BA00000u:0x9B200000u, rd,rn,rm,31); }
    if ([mn isEqualToString:@"umaddl"]||[mn isEqualToString:@"smaddl"]||[mn isEqualToString:@"msubl"]) { NEED(4);
        BOOL w;BOOL s; REG(0,rd,w,dSP);REG(1,rn,w,nSP);REG(2,rm,w,mSP);REG(3,ra,w,s);
        return encMul([mn isEqualToString:@"smaddl"]?0x9B200000u:0x9BA00000u, rd,rn,rm,ra); }
    if ([mn isEqualToString:@"sdiv"]||[mn isEqualToString:@"udiv"]) { NEED(3);
        REG(0,rd,d64,dSP);REG(1,rn,n64,nSP);REG(2,rm,m64,mSP); uint32_t sf=d64?0x80000000u:0;
        uint32_t base=[mn isEqualToString:@"sdiv"]?0x1AC00C00u:0x1AC00800u;
        return base|sf|((uint32_t)rm<<16)|((uint32_t)rn<<5)|(uint32_t)rd; }

    // ── conditional select / cset ──
    if ([mn isEqualToString:@"cset"]) { NEED(2); REG(0,rd,d64,dSP);
        int cc=condCode(ops[1]); if(cc<0){if(error)*error=asmErr(@"bad cond %@",ops[1]);return 0;}
        uint32_t sf=d64?0x80000000u:0;
        return 0x1A800400u|sf|(31u<<16)|((uint32_t)(cc^1)<<12)|(31u<<5)|(uint32_t)rd; } // csinc Rd,ZR,ZR,inv
    // ── conditional compare ──
    // ccmp/ccmn Rn, #imm5|Rm, #nzcv, cond — compare when `cond` holds, otherwise
    // just set the flags to #nzcv. clang emits it for short-circuit comparisons
    // (`i < 0 || i >= n`), so the self-hosted runtime hit it as soon as a host C
    // file with a compound condition was assembled here.
    if ([mn isEqualToString:@"ccmp"]||[mn isEqualToString:@"ccmn"]) { NEED(4);
        REG(0,rn,n64,nSP);
        int cc=condCode(ops[3]); if(cc<0){if(error)*error=asmErr(@"bad cond %@",ops[3]);return 0;}
        int64_t nz; if(!parseImm(ops[2],&nz)||nz<0||nz>15){
            if(error)*error=asmErr(@"bad nzcv %@",ops[2]); return 0; }
        uint32_t sf=n64?0x80000000u:0;
        uint32_t op =[mn isEqualToString:@"ccmp"]?0x40000000u:0;   // bit 30
        uint32_t base=0x3A400000u|op|sf|((uint32_t)cc<<12)|((uint32_t)rn<<5)|(uint32_t)nz;
        if ([ops[1] hasPrefix:@"#"]) {
            int64_t imm; if(!parseImm(ops[1],&imm)||imm<0||imm>31){
                if(error)*error=asmErr(@"bad ccmp imm %@",ops[1]); return 0; }
            return base|0x800u|((uint32_t)imm<<16);              // immediate form
        }
        REG(1,rm,m64,mSP);
        return base|((uint32_t)rm<<16); }

    // csetm Rd,cond — csinv Rd,ZR,ZR,inv: all-ones on the condition, 0 otherwise.
    if ([mn isEqualToString:@"csetm"]) { NEED(2); REG(0,rd,d64,dSP);
        int cc=condCode(ops[1]); if(cc<0){if(error)*error=asmErr(@"bad cond %@",ops[1]);return 0;}
        uint32_t sf=d64?0x80000000u:0;
        return 0x5A800000u|sf|(31u<<16)|((uint32_t)(cc^1)<<12)|(31u<<5)|(uint32_t)rd; }
    // The four conditional selects differ only in bit 30 (invert) and bits 11:10
    // (increment). csinv/csneg turned up the first time a host C file was
    // compiled into the self-hosted runtime — clang emits csinv for a `?:` that
    // yields -1 — and the link failed with "unhandled mnemonic" rather than
    // wrong code, which is the good failure mode.
    // The two-operand conditional aliases clang emits for `c ? x+1 : x` and
    // friends: cinc/cinv/cneg Rd, Rn, cond == csinc/csinv/csneg Rd, Rn, Rn,
    // invert(cond). Found by the iOS platform shim (xtios.c, iOS.md stage 4)
    // — the first C the in-house link took that clang compiled to a cinc.
    if ([mn isEqualToString:@"cinc"]||[mn isEqualToString:@"cinv"]||[mn isEqualToString:@"cneg"]) { NEED(3);
        REG(0,rd,d64,dSP);REG(1,rn,n64,nSP);
        int cc=condCode(ops[2]); if(cc<0){if(error)*error=asmErr(@"bad cond");return 0;}
        uint32_t sf=d64?0x80000000u:0;
        uint32_t inv=([mn isEqualToString:@"cinv"]||[mn isEqualToString:@"cneg"])?0x40000000u:0;
        uint32_t op2=([mn isEqualToString:@"cinc"]||[mn isEqualToString:@"cneg"])?0x400u:0;
        return 0x1A800000u|inv|op2|sf|((uint32_t)rn<<16)|((uint32_t)(cc^1)<<12)|((uint32_t)rn<<5)|(uint32_t)rd; }
    if ([mn isEqualToString:@"csel"]||[mn isEqualToString:@"csinc"]
        ||[mn isEqualToString:@"csinv"]||[mn isEqualToString:@"csneg"]) { NEED(4);
        REG(0,rd,d64,dSP);REG(1,rn,n64,nSP);REG(2,rm,m64,mSP);
        int cc=condCode(ops[3]); if(cc<0){if(error)*error=asmErr(@"bad cond");return 0;}
        uint32_t sf=d64?0x80000000u:0;
        uint32_t inv=([mn isEqualToString:@"csinv"]||[mn isEqualToString:@"csneg"])?0x40000000u:0;
        uint32_t op2=([mn isEqualToString:@"csinc"]||[mn isEqualToString:@"csneg"])?0x400u:0;
        return 0x1A800000u|inv|op2|sf|((uint32_t)rm<<16)|((uint32_t)cc<<12)|((uint32_t)rn<<5)|(uint32_t)rd; }

    // ── loads/stores (single) ──
    // mnemonic -> @[uoff-base, unscaled-base, log2scale]; ldur/stur force unscaled.
    static NSDictionary *ldst, *unsc_only; if(!ldst){ ldst=@{
        @"str": @[@0xB9000000,@0xB8000000,@2], @"ldr": @[@0xB9400000,@0xB8400000,@2],
        @"strb":@[@0x39000000,@0x38000000,@0], @"ldrb":@[@0x39400000,@0x38400000,@0],
        @"strh":@[@0x79000000,@0x78000000,@1], @"ldrh":@[@0x79400000,@0x78400000,@1],
        @"ldrsb":@[@0x39C00000,@0x38C00000,@0], @"ldrsh":@[@0x79C00000,@0x78C00000,@1],
        @"ldrsw":@[@0xB9800000,@0xB8800000,@2],
    }; unsc_only=@{
        @"stur":@[@0xB8000000,@0xB8000000,@2], @"ldur":@[@0xB8400000,@0xB8400000,@2],
        @"sturb":@[@0x38000000,@0x38000000,@0],@"ldurb":@[@0x38400000,@0x38400000,@0],
        @"sturh":@[@0x78000000,@0x78000000,@1],@"ldurh":@[@0x78400000,@0x78400000,@1],
        @"ldursb":@[@0x38C00000,@0x38C00000,@0],@"ldursh":@[@0x78C00000,@0x78C00000,@1],
        @"ldursw":@[@0xB8800000,@0xB8800000,@2],
    }; }
    NSArray *info = ldst[mn] ?: unsc_only[mn];
    // FP load/store: ldr/str of an s/d register (V=1 forms)
    if (([mn isEqualToString:@"ldr"]||[mn isEqualToString:@"str"]) && ops.count>=2) {
        int ft,fz; if (parseFReg(ops[0],&ft,&fz)) {
            BOOL isL=[mn isEqualToString:@"ldr"]; int fscale=fz; // s->2, d->3, q->4
            uint32_t fbase = (fz==4)?(isL?0x3DC00000u:0x3D800000u)  // 128-bit q (NEON)
                           : (fz==3)?(isL?0xFD400000u:0xFD000000u):(isL?0xBD400000u:0xBD000000u);
            NSString *fmem=ops[1];
            NSString *fin=([fmem hasPrefix:@"["]&&[fmem hasSuffix:@"]"])?[fmem substringWithRange:NSMakeRange(1,fmem.length-2)]:fmem;
            if ([fin rangeOfString:@"@PAGEOFF"].location!=NSNotFound) {   // [Xn, sym@PAGEOFF]
                NSArray *fp2=splitOperands(fin); int fbn2; BOOL w,s;
                if (fp2.count>=2 && parseReg(fp2[0],&fbn2,&w,&s)) {
                    NSString *sy=fp2[1]; NSString *bare=[sy substringToIndex:[sy rangeOfString:@"@"].location];
                    XAArm64Fixup *f=[XAArm64Fixup new]; f.offset=pc; f.symbol=bare; f.kind=XAArm64FixupPageOff12; f.scale=(uint32_t)fscale;
                    if(_fixups)[_fixups addObject:f];
                    return fbase | ((uint32_t)fbn2<<5) | (uint32_t)ft;
                }
            }
            // register-offset form:  [Xn, Wm, uxtw #s] / [Xn, Xm, lsl #s].
            // The immediate paths below (via parseMem) cannot express it, so a
            // scaled double store `str d8, [x11, w10, uxtw #3]` was rejected as
            // "bad offset w10" (c2xc bug 34). The V=1 register-offset word is
            // the scaled-immediate base with bit 24 (the unsigned-offset flag)
            // cleared and bits 21 and 11-10 set — mirroring the GP path below.
            {
                NSArray *fmp = splitOperands(fin);
            // NB: `frm2` would be a local here, but mingw's dlgs.h
            // #defines frm1..frm4 as dialog-control ids, so the name
            // expands to 0x0435 and `make win64` fails to parse this
            // declaration. Renamed rather than #undef'd.
                int frn2, frmr2; BOOL fw1,fw2,fs1,fs2;
                if (fmp.count>=2 && parseReg(fmp[0],&frn2,&fw1,&fs1)
                                 && parseReg(fmp[1],&frmr2,&fw2,&fs2)) {
                    uint32_t regBase = (fbase & ~0x01000000u) | 0x00200000u | 0x00000800u;
                    uint32_t option = fw2 ? 3u : 2u;   // Xm -> uxtx, Wm -> uxtw
                    uint32_t S = 0;
                    for (NSUInteger k=2;k<fmp.count;k++){
                        NSString *e=[fmp[k] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        static NSDictionary *fem; if(!fem) fem=@{@"uxtb":@0,@"uxth":@1,@"uxtw":@2,@"uxtx":@3,@"lsl":@3,@"sxtb":@4,@"sxth":@5,@"sxtw":@6,@"sxtx":@7};
                        NSString *ew=[[e componentsSeparatedByString:@" "] firstObject]; NSNumber *o=fem[ew]; if(o) option=o.unsignedIntValue;
                        NSRange h=[e rangeOfString:@"#"]; if(h.location!=NSNotFound) S=1;
                    }
                    // The option field IMPLIES the index width (uxtw/sxtw ↔ Wm,
                    // lsl/uxtx/sxtx ↔ Xm); a mismatched spelling would read the
                    // other view of the register, so reject it like the GP path.
                    if ((option == 3u || option == 7u) != (BOOL)fw2) {
                        if(error)*error=asmErr(@"%@ index extend requires %s register (got %@)",
                                               mn, (option==3u||option==7u)?"an X":"a W", fmp[1]);
                        return 0;
                    }
                    return regBase | ((uint32_t)frmr2<<16) | (option<<13) | (S<<12)
                                   | ((uint32_t)frn2<<5) | (uint32_t)ft;
                }
            }
            int fbn; int64_t foff; int fmode; NSError *fe=nil;
            if(!parseMem(ops,1,&fbn,&foff,&fmode,&fe)){if(error)*error=fe;return 0;}
            if (fmode==0 && foff>=0 && (foff%(1<<fscale))==0 && (foff>>fscale)<=0xFFF)
                return fbase | ((uint32_t)(foff>>fscale)<<10) | ((uint32_t)fbn<<5) | (uint32_t)ft;
            uint32_t imm9=(uint32_t)(foff&0x1FF);
            uint32_t unscBase=(fbase&0x3FFFFFFFu)|((fz==3)?0xC0000000u:0x80000000u);
            uint32_t idx=(fmode==1)?0xC00u:(fmode==2)?0x400u:0x000u;
            return (unscBase & ~0x00000C00u) | (imm9<<12) | idx | ((uint32_t)fbn<<5) | (uint32_t)ft;
        }
    }
    if (info) {
        BOOL forceUnscaled = (unsc_only[mn] != nil);
        NEED(2); BOOL t64,tSP; REG(0,rd,t64,tSP);
        int scale=[info[2] intValue];
        uint32_t uoff=[info[0] unsignedIntValue], unsc=[info[1] unsignedIntValue];
        BOOL isLDR = [mn isEqualToString:@"ldr"]||[mn isEqualToString:@"str"]
                   ||[mn isEqualToString:@"ldur"]||[mn isEqualToString:@"stur"];
        if (isLDR) {   // width from Rt sets size field + scale
            uint32_t sizeBits = t64 ? 0xC0000000u : 0x80000000u;
            scale = t64 ? 3 : 2;
            uoff = (uoff & 0x3FFFFFFFu) | sizeBits;
            unsc = (unsc & 0x3FFFFFFFu) | sizeBits;
        }
        // register-offset form?  "[Xn, Wm, uxtw #s]" / "[Xn, Xm, lsl #s]"
        NSString *mem = ops[1];
        NSString *inner = ([mem hasPrefix:@"["]&&[mem hasSuffix:@"]"]) ? [mem substringWithRange:NSMakeRange(1,mem.length-2)] : mem;
        // scaled ld/st with a symbol page-offset:  [Xn, sym@PAGEOFF]  (adrp + ld/st)
        BOOL innerIsGot = [inner rangeOfString:@"@GOTPAGEOFF"].location != NSNotFound;
        if (innerIsGot || [inner rangeOfString:@"@PAGEOFF"].location!=NSNotFound) {
            NSArray *sp2=splitOperands(inner); int bn; BOOL w,s;
            if (sp2.count>=2 && parseReg(sp2[0],&bn,&w,&s)) {
                NSString *sy=sp2[1]; NSString *bare=[sy substringToIndex:[sy rangeOfString:@"@"].location];
                XAArm64Fixup *f=[XAArm64Fixup new]; f.offset=pc; f.symbol=bare;
                // A GOT slot is always 8 bytes, so the writer scales the
                // displacement by 8 itself; the access size is irrelevant here.
                f.kind = innerIsGot ? XAArm64FixupGotPageOff12 : XAArm64FixupPageOff12;
                f.scale = innerIsGot ? 0 : (uint32_t)scale;
                if(_fixups)[_fixups addObject:f];
                return uoff | ((uint32_t)bn<<5) | (uint32_t)rd;   // imm12=0, patched by the linker
            }
        }
        NSArray *mp = splitOperands(inner);
        int trn,trm; BOOL w1,w2,s1,s2;
        if (mp.count>=2 && parseReg(mp[0],&trn,&w1,&s1) && parseReg(mp[1],&trm,&w2,&s2)) {
            uint32_t regBase = (unsc & 0x3FFFFFFFu) | (isLDR?(t64?0xC0000000u:0x80000000u):(unsc&0xC0000000u)) | 0x00200800u;
            uint32_t option = w2 ? 3u : 2u;   // Xm -> uxtx(3 via lsl), Wm -> uxtw(2)
            uint32_t S = 0;
            for (NSUInteger k=2;k<mp.count;k++){
                NSString *e=[mp[k] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                static NSDictionary *em; if(!em) em=@{@"uxtb":@0,@"uxth":@1,@"uxtw":@2,@"uxtx":@3,@"lsl":@3,@"sxtb":@4,@"sxth":@5,@"sxtw":@6,@"sxtx":@7};
                NSString *w=[[e componentsSeparatedByString:@" "] firstObject]; NSNumber *o=em[w]; if(o) option=o.unsignedIntValue;
                NSRange h=[e rangeOfString:@"#"]; if(h.location!=NSNotFound) S=1; // explicit amount -> S=1
            }
            // The option field IMPLIES the index width (uxtw/sxtw ↔ Wm,
            // lsl/sxtx ↔ Xm); there is no separate bit, so a mismatched
            // spelling would encode an instruction reading the OTHER view
            // of the register — `[x1, x2, uxtw #3]` executed as w2 (blewit
            // finding #8). Reject it, like the reference assembler does.
            if ((option == 3u || option == 7u) != (BOOL)w2) {
                if(error)*error=asmErr(@"%@ index extend requires %s register (got %@)",
                                       mn, (option==3u||option==7u)?"an X":"a W", mp[1]);
                return 0;
            }
            return regBase | ((uint32_t)trm<<16) | (option<<13) | (S<<12) | ((uint32_t)trn<<5) | (uint32_t)rd;
        }
        int base; int64_t offv; int mode; NSError *e=nil;
        if(!parseMem(ops,1,&base,&offv,&mode,&e)){ if(error)*error=e; return 0; }
        if (!forceUnscaled && mode==0 && offv>=0 && (offv % (1<<scale))==0 && (offv>>scale)<=0xFFF) {
            return uoff | ((uint32_t)(offv>>scale)<<10) | ((uint32_t)base<<5) | (uint32_t)rd;
        }
        uint32_t imm9 = (uint32_t)(offv & 0x1FF);
        uint32_t idx = (mode==1)?0xC00u : (mode==2)?0x400u : 0x000u; // pre=11,post=01,unscaled=00
        return unsc | (imm9<<12) | idx | ((uint32_t)base<<5) | (uint32_t)rd;
    }

    // ── load/store pair (GPR and FP/SIMD) ──
    if ([mn isEqualToString:@"stp"]||[mn isEqualToString:@"ldp"]) {
        NEED(3); BOOL a64,b64,aSP,bSP; int rt,rt2,fz,fz2; BOOL L=[mn isEqualToString:@"ldp"];
        int base; int64_t off; int mode; NSError *e=nil;
        if (parseFReg(ops[0],&rt,&fz) && parseFReg(ops[1],&rt2,&fz2)) {   // FP pair: s/d/q
            if(!parseMem(ops,2,&base,&off,&mode,&e)){if(error)*error=e;return 0;}
            int scale=fz; int64_t imm7=off>>scale;                       // s->2,d->3,q->4
            uint32_t fb = (fz==4)?(mode==1?0xAD800000u:mode==2?0xAC800000u:0xAD000000u)
                        : (fz==3)?(mode==1?0x6D800000u:mode==2?0x6C800000u:0x6D000000u)
                                 :(mode==1?0x2D800000u:mode==2?0x2C800000u:0x2D000000u);
            if (L) fb |= 0x00400000u;
            return fb | ((uint32_t)(imm7 & 0x7F)<<15) | ((uint32_t)rt2<<10) | ((uint32_t)base<<5) | (uint32_t)rt;
        }
        if(!parseReg(ops[0],&rt,&a64,&aSP)||!parseReg(ops[1],&rt2,&b64,&bSP)){if(error)*error=asmErr(@"bad pair reg");return 0;}
        if(!parseMem(ops,2,&base,&off,&mode,&e)){if(error)*error=e;return 0;}
        int scale=a64?3:2; int64_t imm7=off>>scale;
        uint32_t base32;   // 32-bit: offset 0x29.., pre 0x29800000, post 0x28800000; 64-bit: 0xA9../0xA9800000/0xA8800000
        if (mode==0) base32 = a64?0xA9000000u:0x29000000u;
        else if (mode==1) base32 = a64?0xA9800000u:0x29800000u;
        else base32 = a64?0xA8800000u:0x28800000u;
        if (L) base32 |= 0x00400000u;
        return base32 | ((uint32_t)(imm7 & 0x7F)<<15) | ((uint32_t)rt2<<10) | ((uint32_t)base<<5) | (uint32_t)rt;
    }

    // ── adrp / adr ──
    if ([mn isEqualToString:@"adrp"]||[mn isEqualToString:@"adr"]) {
        NEED(2); REG(0,rd,d64,dSP);
        // symbol operand (possibly @PAGE/@PAGEOFF) -> imm 0 + fixup for adrp
        NSString *sym=ops[1]; NSString *bare=sym;
        NSRange at=[sym rangeOfString:@"@"]; if(at.location!=NSNotFound) bare=[sym substringToIndex:at.location];
        unichar c0 = bare.length ? [bare characterAtIndex:0] : 0;   // _, ., or any letter (incl clang's l_.str)
        if (c0=='_'||c0=='.'||(c0>='A'&&c0<='Z')||(c0>='a'&&c0<='z')) {
            // `sym@GOTPAGE` is the page of the symbol's __got SLOT, not of the
            // symbol — the target is an imported DATA symbol (libSystem's
            // ___stderrp is the one that matters here) which has no in-image
            // address to take. Without this the whole self-host link fell back
            // to clang for every program that touches stderr, which is every
            // program that links the host runtime.
            BOOL isGot = (at.location != NSNotFound)
                && [[sym substringFromIndex:at.location] hasPrefix:@"@GOTPAGE"];
            XAArm64Fixup *f=[XAArm64Fixup new]; f.offset=pc; f.symbol=bare;
            if ([mn isEqualToString:@"adrp"])
                f.kind = isGot ? XAArm64FixupGotPage21 : XAArm64FixupPage21;
            else
                f.kind = isGot ? XAArm64FixupGotPageOff12 : XAArm64FixupPageOff12;
            if(_fixups) [_fixups addObject:f];
            return ([mn isEqualToString:@"adrp"]?0x90000000u:0x10000000u) | (uint32_t)rd;
        }
        if(error)*error=asmErr(@"adr needs symbol"); return 0;
    }

    // ── branches ──
    if ([mn isEqualToString:@"b"]||[mn isEqualToString:@"bl"]) {
        NEED(1); NSString *tgt=ops[0]; BOOL isLocal=NO; uint32_t addr=0;
        if (resolve) addr=resolve(tgt,&isLocal);
        uint32_t base=[mn isEqualToString:@"bl"]?0x94000000u:0x14000000u;
        if (isLocal) { int32_t rel=((int32_t)addr-(int32_t)pc)>>2; return base | ((uint32_t)rel & 0x03FFFFFFu); }
        XAArm64Fixup *f=[XAArm64Fixup new]; f.offset=pc; f.symbol=tgt; f.kind=XAArm64FixupBranch26;
        if(_fixups)[_fixups addObject:f];
        return base;
    }
    // Conditional branches carry a SIGNED offset in a narrow field — 19 bits
    // (±1 MB) for b.cond/cbz/cbnz, 14 (±32 KB) for tbz/tbnz. Masking an
    // out-of-range displacement into the field produces a valid-looking
    // instruction that jumps somewhere else entirely, and the program dies far
    // away with a PC in the middle of nothing. So each one is CHECKED: an
    // over-long branch is an assembly error, not a silent miscompile.
    //
    // The check exists because it fired: a self-hosted link of a program with
    // the Foundation plus the self-hosted preprocessor crashed with the PC on
    // the stack, and the cause was a truncated conditional branch.
    if ([mn hasPrefix:@"b."]) {
        NEED(1); int cc=condCode([mn substringFromIndex:2]); if(cc<0){if(error)*error=asmErr(@"bad cond %@",mn);return 0;}
        BOOL isLocal=NO; uint32_t addr=resolve?resolve(ops[0],&isLocal):0;
        int32_t rel=isLocal?(((int32_t)addr-(int32_t)pc)>>2):0;
        if (rel < -(1<<18) || rel >= (1<<18)) {
            if(error)*error=asmErr(@"conditional branch out of range (%d instructions to '%@'; "
                                    @"b.cond reaches ±1MB)", rel, ops[0]);
            return 0;
        }
        return 0x54000000u | (((uint32_t)rel & 0x7FFFF)<<5) | (uint32_t)cc;
    }
    if ([mn isEqualToString:@"cbz"]||[mn isEqualToString:@"cbnz"]) {
        NEED(2); REG(0,rd,d64,dSP); BOOL isLocal=NO; uint32_t addr=resolve?resolve(ops[1],&isLocal):0;
        int32_t rel=isLocal?(((int32_t)addr-(int32_t)pc)>>2):0;
        if (rel < -(1<<18) || rel >= (1<<18)) {
            if(error)*error=asmErr(@"%@ out of range (%d instructions to '%@'; reaches ±1MB)",
                                   mn, rel, ops[1]);
            return 0;
        }
        uint32_t base=[mn isEqualToString:@"cbnz"]?0x35000000u:0x34000000u; if(d64) base|=0x80000000u;
        return base | (((uint32_t)rel & 0x7FFFF)<<5) | (uint32_t)rd;
    }
    if ([mn isEqualToString:@"tbz"]||[mn isEqualToString:@"tbnz"]) {   // test bit & branch (imm14)
        NEED(3); BOOL w,sp; REG(0,rd,w,sp);
        int64_t bit; if(!parseImm(ops[1],&bit)){if(error)*error=asmErr(@"bad tb bit");return 0;}
        BOOL isLocal=NO; uint32_t addr=resolve?resolve(ops[2],&isLocal):0;
        int32_t rel=isLocal?(((int32_t)addr-(int32_t)pc)>>2):0;
        if (rel < -(1<<13) || rel >= (1<<13)) {
            if(error)*error=asmErr(@"%@ out of range (%d instructions to '%@'; reaches ±32KB)",
                                   mn, rel, ops[2]);
            return 0;
        }
        uint32_t op=[mn isEqualToString:@"tbnz"]?1u:0u;
        return 0x36000000u | (((uint32_t)(bit>>5)&1)<<31) | (op<<24) | (((uint32_t)bit&0x1F)<<19)
             | (((uint32_t)rel & 0x3FFF)<<5) | (uint32_t)rd;
    }
    if ([mn isEqualToString:@"ret"]) { int r=30; if(ops.count){BOOL w,s;REG(0,r,w,s);} return 0xD65F0000u|((uint32_t)r<<5); }
    // system: svc/brk #imm16 (syscall / breakpoint — the self-host crt svc-exits)
    if (([mn isEqualToString:@"svc"]||[mn isEqualToString:@"brk"]||[mn isEqualToString:@"hlt"]) && ops.count==1) {
        int64_t imm=0; parseImm(ops[0],&imm);
        uint32_t base = [mn isEqualToString:@"svc"]?0xD4000001u : [mn isEqualToString:@"brk"]?0xD4200000u : 0xD4400000u;
        return base | (((uint32_t)imm & 0xFFFF)<<5);
    }
    if ([mn isEqualToString:@"blr"]||[mn isEqualToString:@"br"]) { NEED(1); BOOL w,s;REG(0,rn,w,s);
        return ([mn isEqualToString:@"blr"]?0xD63F0000u:0xD61F0000u)|((uint32_t)rn<<5); }
    if ([mn isEqualToString:@"brk"]) { NEED(1); int64_t imm;parseImm(ops[0],&imm); return 0xD4200000u|(((uint32_t)imm&0xFFFF)<<5); }
    if ([mn isEqualToString:@"nop"]) return 0xD503201Fu;

    if (error) *error = asmErr(@"unhandled mnemonic: %@", mn);
    return 0;
}

// Emit the bytes of a data directive (.byte/.hword/.short/.word/.long/.quad/
// .ascii/.asciz/.space/.zero) into `out`; returns NO if `l` is not one. Numeric
// operands only (a symbol-valued .quad would need a rebase — not emitted here).
static BOOL emitDataDirective(NSString *l, NSMutableData *out, NSError **err) {
    NSRange sp = [l rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *mn = sp.location==NSNotFound ? l : [l substringToIndex:sp.location];
    NSString *rest = sp.location==NSNotFound ? @"" :
        [[l substringFromIndex:sp.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    int width = 0;
    if ([mn isEqualToString:@".byte"]) width=1;
    else if ([mn isEqualToString:@".hword"]||[mn isEqualToString:@".short"]||[mn isEqualToString:@".2byte"]) width=2;
    else if ([mn isEqualToString:@".word"]||[mn isEqualToString:@".long"]||[mn isEqualToString:@".4byte"]) width=4;
    else if ([mn isEqualToString:@".quad"]||[mn isEqualToString:@".8byte"]
             ||[mn isEqualToString:@".xword"]) width=8;   // .xword: the ELF spelling
    else if ([mn isEqualToString:@".ascii"]||[mn isEqualToString:@".asciz"]||[mn isEqualToString:@".string"]) {
        NSRange q1=[rest rangeOfString:@"\""], q2=[rest rangeOfString:@"\"" options:NSBackwardsSearch];
        if (q1.location==NSNotFound||q2.location<=q1.location) { if(err)*err=asmErr(@"bad string %@",l); return NO; }
        NSString *s=[rest substringWithRange:NSMakeRange(q1.location+1, q2.location-q1.location-1)];
        // minimal C escapes
        NSMutableData *sd=[NSMutableData data];
        for (NSUInteger i=0;i<s.length;i++){ unichar c=[s characterAtIndex:i];
            if (c=='\\' && i+1<s.length){ unichar n=[s characterAtIndex:++i];
                c = n=='n'?'\n': n=='t'?'\t': n=='r'?'\r': n=='0'?0: n=='\\'?'\\': n=='"'?'"': n; }
            uint8_t b=(uint8_t)c; [sd appendBytes:&b length:1]; }
        [out appendData:sd];
        if (![mn isEqualToString:@".ascii"]) { uint8_t z=0; [out appendBytes:&z length:1]; }
        return YES;
    }
    else if ([mn isEqualToString:@".space"]||[mn isEqualToString:@".zero"]) {
        NSArray *a=splitOperands(rest); int64_t n=0,fill=0; parseImm(a[0],&n);
        if (a.count>1) parseImm(a[1],&fill);
        for (int64_t i=0;i<n;i++){ uint8_t b=(uint8_t)fill; [out appendBytes:&b length:1]; } return YES;
    }
    else return NO;
    // width-based comma list
    for (NSString *tok in splitOperands(rest)) {
        int64_t v; if(!parseImm(tok,&v)){ if(err)*err=asmErr(@"bad data value '%@' in %@",tok,l); return NO; }
        for (int i=0;i<width;i++){ uint8_t b=(uint8_t)(v>>(8*i)); [out appendBytes:&b length:1]; }
    }
    return YES;
}

// If `l` is `.quad <symbol>` / `.8byte <symbol>` (a symbol-valued pointer, not a
// number), return the bare symbol name; else nil. These become an 8-byte rebased
// pointer in __data (e.g. a vtable's method-pointer slot).
static NSString *quadSymbolOperand(NSString *l) {
    NSRange sp = [l rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    if (sp.location == NSNotFound) return nil;
    NSString *mn = [l substringToIndex:sp.location];
    if (![mn isEqualToString:@".quad"] && ![mn isEqualToString:@".8byte"]
        && ![mn isEqualToString:@".xword"]) return nil;
    NSString *rest = [[l substringFromIndex:sp.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([rest rangeOfString:@","].location != NSNotFound) return nil;   // a list -> numeric path
    int64_t v; if (parseImm(rest, &v)) return nil;                       // parses as a number -> numeric
    unichar c = rest.length ? [rest characterAtIndex:0] : 0;
    return (c=='_'||c=='.'||c=='L'||(c>='A'&&c<='Z')||(c>='a'&&c<='z')) ? rest : nil;
}

+ (NSString *)machoDialectFromElf:(NSString *)elfAsm {
    if (!elfAsm) return @"";
    NSRegularExpression *(^rx)(NSString *) = ^(NSString *p){
        return [NSRegularExpression regularExpressionWithPattern:p options:0 error:NULL];
    };
    // `:got_lo12:` before `:got:` and `:lo12:` is not strictly required (neither
    // shorter pattern can match inside it), but the order states the intent.
    NSRegularExpression *gotLo = rx(@":got_lo12:([A-Za-z_$.][A-Za-z0-9_$.]*)");
    NSRegularExpression *got   = rx(@":got:([A-Za-z_$.][A-Za-z0-9_$.]*)");
    NSRegularExpression *lo12  = rx(@":lo12:([A-Za-z_$.][A-Za-z0-9_$.]*)");
    // A bare symbol operand on adrp. Anything already carrying an `@` modifier
    // is left alone, which is what makes this idempotent.
    NSRegularExpression *adrp  = rx(@"^(\\s*adrp\\s+[A-Za-z0-9]+\\s*,\\s*)"
                                    "([A-Za-z_$.][A-Za-z0-9_$.]*)\\s*$");
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *lineIn in [elfAsm componentsSeparatedByString:@"\n"]) {
        // Through XTRegexReplace: GNUstep returns nil for a blank line, and
        // assigning that back would discard the rest of the line's rewriting
        // silently. See XTRegexCompat.h.
        NSString *l = lineIn;
        l = XTRegexReplace(gotLo, l, @"$1@GOTPAGEOFF");
        l = XTRegexReplace(got,   l, @"$1@GOTPAGE");
        l = XTRegexReplace(lo12,  l, @"$1@PAGEOFF");
        l = XTRegexReplace(adrp,  l, @"$1$2@PAGE");
        [out addObject:l];
    }
    return [out componentsJoinedByString:@"\n"];
}

- (NSData *)assemble:(NSString *)asmText error:(NSError **)error {
    _fixups=[NSMutableArray array]; _symbols=[NSMutableDictionary dictionary];
    _data=[NSMutableData data]; _dataSymbolNames=[NSMutableSet set]; _globalNames=[NSMutableSet set];
    _commonSymbols=[NSMutableDictionary dictionary];
    _modInit=[NSMutableData data]; _modInitFixups=[NSMutableArray array];
    NSArray<NSString *> *rawLines=[asmText componentsSeparatedByString:@"\n"];
    // section 0 = __text (code), 1 = __DATA,__data. Each has its own address
    // space (section-relative); the linker assigns final bases.
    // Pass 1: assign section-relative addresses to labels; collect text insns
    // and data directives in program order per section.
    NSMutableArray<NSString *> *insns=[NSMutableArray array];
    uint64_t textAddr=0, dataAddr=0; int section=0;
    BOOL inModInit=NO;   // bug 066: inside __DATA,__mod_init_func
    for (NSString *raw in rawLines) {
        NSString *l=stripComment(raw);
        l=[l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if(l.length==0) continue;
        // A line starting with '.' is a directive UNLESS it ends with ':' — then
        // it is a local label like `.Lmain_retain_done_0:` (clang / our ARC
        // guards), which must be recorded, not skipped as an unknown directive.
        if([l hasPrefix:@"."] && ![l hasSuffix:@":"]) {
            if([l hasPrefix:@".text"]) { section=0; inModInit=NO; continue; }
            if([l hasPrefix:@".section"]) {   // __text stays code; __cstring/__const/__DATA -> data
                section=([l rangeOfString:@"__text"].location!=NSNotFound)?0:1;
                // Bug 066: __mod_init_func's pointers are ordinary __DATA bytes
                // — but dyld runs them only if a SECTION says what they are, and
                // folding them anonymously into __data is exactly why load-time
                // constructors never ran. The bytes still go to `_data`; only
                // the RANGE is remembered, for the writer to describe.
                // Bug 124: match the section name WITHOUT its leading
                // underscores, and accept the ELF spelling too.
                //
                // The android driver runs the whole unit through
                // stripSymbolUnderscoreArm64, whose regex strips one `_` after a
                // comma — so `.section __DATA,__mod_init_func,mod_init_funcs`
                // arrives here as `.section _DATA,_mod_init_func,...` and a
                // needle of `__mod_init_func` misses. The pointers then folded
                // anonymously into `_data`, which is exactly the state bug 066
                // fixed for Mach-O, so no load-time constructor ever ran on
                // android. `.init_array` covers the other route in, where
                // XTMachOToElfArm64 renames the directive instead; the leading
                // dot keeps `.preinit_array` from matching.
                inModInit = (section==1 &&
                    ([l rangeOfString:@"mod_init_func"].location!=NSNotFound ||
                     [l rangeOfString:@".init_array"].location!=NSNotFound));
                continue; }
            if([l hasPrefix:@".data"]) { section=1; inModInit=NO; continue; }
            // ELF spelling. Zero bytes emitted here are still the LAST thing in
            // the image's data, and the writers drop a trailing zero run from
            // the file, so .bss costs nothing on disk.
            if([l hasPrefix:@".bss"]) { section=1; continue; }
            // NOTE (bug 066): a `.p2align` seen INSIDE __mod_init_func pads
            // `_data`, not `_modInit` — it aligns the buffer the pointers are
            // not in. Harmless, because the linker 8-aligns the merged __data
            // before appending the array, so the pointers land aligned however
            // this directive falls; it costs at most 7 bytes of __data padding.
            // Left as is rather than "fixed" because changing it moves the
            // bytes of every linked arm64 image for no behavioural gain — but
            // anything ELSE ever emitted into that section would need this
            // sorted out first.
            if([l hasPrefix:@".align"]||[l hasPrefix:@".p2align"]){
                int64_t a; NSScanner*s=[NSScanner scannerWithString:[l substringFromIndex:([l hasPrefix:@".p2align"]?8:6)]];
                [s scanInteger:(NSInteger*)&a]; uint64_t al=1ull<<a;
                if(section==0){ while(textAddr%al) textAddr++; } else { while(dataAddr%al){ uint8_t z=0;[_data appendBytes:&z length:1]; dataAddr++; } }
                continue;
            }
            if([l hasPrefix:@".comm"]||[l hasPrefix:@".zerofill"]||[l hasPrefix:@".lcomm"]) {
                // Zero-init global (BSS), allocated in __data:
                //   .comm/.lcomm  name, size, align            (name at operand 0)
                //   .zerofill     SEG, SECT, name, size, align  (name at operand 2)
                // The mnemonic may be separated from its operands by a TAB —
                // clang's ELF output is tab-separated where its Mach-O output is
                // not, and splitting on a literal space threw NSRangeException
                // on the first `.comm` of an NDK-generated runtime.
                NSRange ws = [l rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
                if (ws.location == NSNotFound) continue;
                NSArray *a = splitOperands([l substringFromIndex:ws.location + 1]);
                NSUInteger ni = [l hasPrefix:@".zerofill"] ? 2 : 0;   // index of the name operand
                if (a.count > ni+1) {
                    NSString *nm = [a[ni] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    int64_t sz=0, alg=0; parseImm(a[ni+1],&sz); if(a.count>ni+2) parseImm(a[ni+2],&alg);
                    // `.comm` is a COMMON (external tentative def): NO storage in
                    // this object, so the linker gives it one shared zero-filled
                    // slot and every unit binds to it (bug 169). `.lcomm` and
                    // `.zerofill` stay a private LOCAL zero-init in __data.
                    if ([l hasPrefix:@".comm"]) {
                        _commonSymbols[nm] = @[@(sz), @(alg)];
                    } else {
                        uint64_t al=1ull<<alg; while(dataAddr%al){ uint8_t z=0;[_data appendBytes:&z length:1]; dataAddr++; }
                        _symbols[nm]=@(dataAddr); [_dataSymbolNames addObject:nm];
                        for(int64_t i=0;i<sz;i++){ uint8_t z=0;[_data appendBytes:&z length:1]; } dataAddr+=sz;
                    }
                }
                continue;
            }
            if([l hasPrefix:@".globl"]) {
                // Visibility: the object writer exports exactly these; every
                // other defined symbol is a local, private to its object. (It
                // used to export everything, so two objects' `_str_N` literals
                // collided at link — bug 136.)
                NSString *nm=[[l substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if(nm.length) [_globalNames addObject:nm];
                continue;
            }
            // a data directive (only meaningful in the data section)
            if(section==1){
                NSString *qsym = quadSymbolOperand(l);
                if (qsym) {   // .quad <symbol> -> 8-byte rebased pointer + fixup
                    // Bug 066: a constructor pointer goes to its own buffer, with
                    // its fixup offset relative to that buffer; the linker places
                    // both once it knows where the array lands.
                    NSMutableData *dst = inModInit ? _modInit : _data;
                    XAArm64Fixup *f=[XAArm64Fixup new];
                    f.offset = inModInit ? _modInit.length : dataAddr;
                    f.symbol=qsym; f.kind=XAArm64FixupPointer64;
                    [(inModInit ? _modInitFixups : _fixups) addObject:f];
                    for(int i=0;i<8;i++){ uint8_t z=0;[dst appendBytes:&z length:1]; }
                    if (!inModInit) dataAddr+=8;
                    continue;
                }
                NSError*e=nil; NSUInteger before=_data.length;
                if(emitDataDirective(l,_data,&e)){ dataAddr+=(_data.length-before); continue; }
                if(e){ if(error)*error=e; return nil; } }
            continue; // unknown/ignored directive (.subsections_via_symbols, etc.)
        }
        if([l hasSuffix:@":"]) { NSString*lbl=[l substringToIndex:l.length-1];
            // A label defined TWICE in one translation unit is an error, not a
            // last-one-wins. The symbol table is flat, so a second definition
            // silently retargets every branch to the first — and two
            // clang-generated files concatenated together both spell their
            // local labels `.LBB0_1`, which is how a NativeActivity library
            // ended up branching out of its own glue into the middle of the
            // runtime. Nothing about that failed to assemble or link.
            // `Lloh<N>` is exempt: Mach-O linker-optimization-hint markers,
            // which Darwin's clang numbers per FUNCTION and scopes with
            // .subsections_via_symbols, so rt-macos.s legitimately defines
            // Lloh5 twice. They are only ever operands of a `.loh` directive,
            // which this assembler ignores, so they are never branch targets
            // and a collision between them cannot mislead anything.
            if(_symbols[lbl] && ![lbl hasPrefix:@"Lloh"]) {
                if(error)*error=asmErr(@"duplicate label '%@' — two definitions in one "
                                        @"assembly unit; local labels from separately "
                                        @"generated files must be namespaced", lbl);
                return nil;
            }
            if(section==0) _symbols[lbl]=@(textAddr);
            else { _symbols[lbl]=@(dataAddr); [_dataSymbolNames addObject:lbl]; }
            continue; }
        if(section==0){ [insns addObject:l]; textAddr+=4; }
        else { NSError*e=nil; NSUInteger before=_data.length;   // stray non-label data line
            if(emitDataDirective(l,_data,&e)){ dataAddr+=(_data.length-before); } else if(e){ if(error)*error=e; return nil; } }
    }
    // Pass 2: encode text. Only TEXT symbols resolve as local (relative
    // branches); data symbols reach code via adrp/add fixups, never branches.
    NSMutableData *out=[NSMutableData data]; uint64_t pc=0;
    NSDictionary *syms=_symbols; NSSet *dataSyms=_dataSymbolNames;
    uint32_t(^resolve)(NSString*,BOOL*)=^uint32_t(NSString*n,BOOL*local){
        NSNumber*a=syms[n]; if(a && ![dataSyms containsObject:n]){ *local=YES; return a.unsignedIntValue; }
        *local=NO; return 0; };
    for (NSString *insn in insns) {
        NSError *e=nil; uint32_t w=[self encodeLine:insn pc:pc resolve:resolve error:&e];
        if(e){ if(error)*error=asmErr(@"line '%@': %@",insn,e.localizedDescription); return nil; }
        uint8_t b[4]={(uint8_t)w,(uint8_t)(w>>8),(uint8_t)(w>>16),(uint8_t)(w>>24)};
        [out appendBytes:b length:4]; pc+=4;
    }
    return out;
}
@end
