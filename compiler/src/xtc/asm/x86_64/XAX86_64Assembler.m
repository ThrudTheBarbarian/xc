#import "XAX86_64Assembler.h"
#import "XTDwarfWriter.h"
#include <stdlib.h>
#include <errno.h>

@implementation XAX86_64Fixup
@end

// ───────────────────────────── operand model ─────────────────────────────
// An operand is a register, an immediate, or a memory reference
// [base + index*scale + disp] (Intel syntax, no % prefixes).
// The size an opmask register (k0-k7) parses to: no real operand is this wide,
// so it cannot be mistaken for a GPR or a vector register.
#define XK_SIZE 99

typedef struct {
    enum { OpNone, OpReg, OpImm, OpMem } kind;
    int reg;            // 0-15
    int size;           // operand size in bytes: 1,2,4,8 (regs / mem access)
    int64_t imm;
    int base, index, scale;   // mem: base/index are -1 when absent
    int64_t disp;
    BOOL ripRel;              // mem: [rip + sym]
    uint8_t seg;              // mem: segment-override prefix byte, 0 for none
    BOOL forceRex;            // 8-bit spl/bpl/sil/dil need a REX even with reg<8
    NSString *symbol;         // mem/imm symbolic operand
} XOperand;

static NSError *xerr(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:@"XAX86_64Assembler" code:1
                           userInfo:@{NSLocalizedDescriptionKey: m}];
}

// Register table: name -> (number, size). Covers the 64/32/16/8-bit encodings
// the backend emits, including the r8-r15 families and the sil/dil/spl/bpl forms
// that require a REX prefix even with no extended register.
static BOOL parseReg(NSString *s, int *num, int *size, BOOL *needRex) {
    static NSDictionary<NSString *, NSArray<NSNumber *> *> *T;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        NSArray *r64 = @[@"rax",@"rcx",@"rdx",@"rbx",@"rsp",@"rbp",@"rsi",@"rdi"];
        NSArray *r32 = @[@"eax",@"ecx",@"edx",@"ebx",@"esp",@"ebp",@"esi",@"edi"];
        NSArray *r16 = @[@"ax",@"cx",@"dx",@"bx",@"sp",@"bp",@"si",@"di"];
        NSArray *r8  = @[@"al",@"cl",@"dl",@"bl",@"spl",@"bpl",@"sil",@"dil"];
        NSArray *r8l = @[@"al",@"cl",@"dl",@"bl",@"ah",@"ch",@"dh",@"bh"];
        for (int i=0;i<8;i++) {
            m[r64[i]] = @[@(i), @8, @0];
            m[r32[i]] = @[@(i), @4, @0];
            m[r16[i]] = @[@(i), @2, @0];
            // spl/bpl/sil/dil need REX even though the number is < 8
            m[r8[i]]  = @[@(i), @1, @(i >= 4 ? 1 : 0)];
            if (i >= 4) m[r8l[i]] = @[@(i), @1, @0];   // ah/ch/dh/bh (no REX)
        }
        for (int i=8;i<16;i++) {
            m[[NSString stringWithFormat:@"r%d", i]]  = @[@(i), @8, @0];
            m[[NSString stringWithFormat:@"r%dd", i]] = @[@(i), @4, @0];
            m[[NSString stringWithFormat:@"r%dw", i]] = @[@(i), @2, @0];
            m[[NSString stringWithFormat:@"r%db", i]] = @[@(i), @1, @0];
        }
        for (int i=0;i<16;i++) m[[NSString stringWithFormat:@"xmm%d", i]] = @[@(i), @16, @0];
        // ymm: the same 16 registers at 32 bytes. A ymm operand is what sets
        // VEX.L; nothing else distinguishes the encodings.
        for (int i=0;i<16;i++) m[[NSString stringWithFormat:@"ymm%d", i]] = @[@(i), @32, @0];
        // zmm: the same 16 registers at 64 bytes; a zmm operand is what selects
        // the EVEX encoding. Only zmm0-15: nothing here allocates zmm16-31.
        for (int i=0;i<16;i++) m[[NSString stringWithFormat:@"zmm%d", i]] = @[@(i), @64, @0];
        // k0-k7, the AVX-512 opmask registers, at a size no other operand has.
        for (int i=0;i<8;i++) m[[NSString stringWithFormat:@"k%d", i]] = @[@(i), @(XK_SIZE), @0];
        T = m;
    });
    NSArray<NSNumber *> *e = T[[s lowercaseString]];
    if (!e) return NO;
    *num = e[0].intValue; *size = e[1].intValue;
    if (needRex) *needRex = e[2].boolValue;
    return YES;
}

static BOOL parseNum(NSString *s, int64_t *out) {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!s.length) return NO;
    BOOL neg = NO;
    if ([s hasPrefix:@"-"]) { neg = YES; s = [s substringFromIndex:1]; }
    else if ([s hasPrefix:@"+"]) s = [s substringFromIndex:1];
    // strtoull rather than NSScanner: the scanner's unsigned-long-long / atEnd
    // API differs between Apple Foundation and GNUstep, and this is pure integer
    // parsing that the C library does identically on both.
    const char *c = s.UTF8String;
    int base = ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) ? 16 : 10;
    char *end = NULL;
    errno = 0;
    unsigned long long v = strtoull(base == 16 ? c + 2 : c, &end, base);
    if (errno != 0 || end == c || (base == 16 && end == c + 2) || *end != '\0') return NO;
    *out = neg ? -(int64_t)v : (int64_t)v;
    return YES;
}

// Parse one Intel-syntax operand. `defSize` seeds the size for memory operands
// (which carry no width of their own unless a `ptr` prefix says otherwise).
static BOOL parseOperand(NSString *tok, XOperand *o, NSError **err) {
    memset(o, 0, sizeof(*o)); o->base = o->index = -1; o->scale = 1;
    NSString *s = [tok stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!s.length) { o->kind = OpNone; return YES; }

    // size-override prefixes: "qword ptr [..]", "byte ptr [..]" &c.
    int forced = 0;
    NSArray *pfx = @[@"byte",@"word",@"dword",@"qword",@"xmmword",@"ymmword",@"zmmword"];
    NSArray *psz = @[@1,@2,@4,@8,@16,@32,@64];
    for (NSUInteger i=0;i<pfx.count;i++) {
        NSString *p = [pfx[i] stringByAppendingString:@" ptr"];
        if ([[s lowercaseString] hasPrefix:p]) {
            forced = [psz[i] intValue];
            s = [[s substringFromIndex:p.length] stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceCharacterSet]];
            break;
        }
    }

    // Segment override — `fs:[…]` / `gs:[…]`. The thread pointer lives behind
    // one of these, so thread-local storage is a load rather than a lookup; no
    // other operand in this compiler's output uses a segment.
    uint8_t segByte = 0;
    {
        NSString *ls = s.lowercaseString;
        if ([ls hasPrefix:@"fs:"]) { segByte = 0x64; s = [s substringFromIndex:3]; }
        else if ([ls hasPrefix:@"gs:"]) { segByte = 0x65; s = [s substringFromIndex:3]; }
        else if ([ls hasPrefix:@"es:"]) { segByte = 0x26; s = [s substringFromIndex:3]; }
        else if ([ls hasPrefix:@"ss:"]) { segByte = 0x36; s = [s substringFromIndex:3]; }
        else if ([ls hasPrefix:@"ds:"]) { segByte = 0x3E; s = [s substringFromIndex:3]; }
        else if ([ls hasPrefix:@"cs:"]) { segByte = 0x2E; s = [s substringFromIndex:3]; }
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

    if ([s hasPrefix:@"["]) {                       // memory
        o->kind = OpMem; o->size = forced; o->seg = segByte;
        NSString *inner = [s substringWithRange:NSMakeRange(1, s.length-2)];
        inner = [inner stringByReplacingOccurrencesOfString:@" " withString:@""];
        // split on + / - keeping signs
        NSMutableArray<NSString *> *terms = [NSMutableArray array];
        NSMutableString *cur = [NSMutableString string];
        for (NSUInteger i=0;i<inner.length;i++) {
            unichar c = [inner characterAtIndex:i];
            if ((c=='+'||c=='-') && cur.length) { [terms addObject:cur]; cur = [NSMutableString string]; }
            if (c=='-') [cur appendString:@"-"]; else if (c!='+') [cur appendFormat:@"%C", c];
        }
        if (cur.length) [terms addObject:cur];
        for (NSString *t in terms) {
            int rn, rs; int64_t v;
            NSRange star = [t rangeOfString:@"*"];
            if (star.location != NSNotFound) {       // index*scale, or scale*index
                NSString *lhs = [t substringToIndex:star.location];
                NSString *rhs = [t substringFromIndex:star.location+1];
                int64_t sc;
                if (!(parseReg(lhs,&rn,&rs,NULL) && parseNum(rhs,&sc)) &&
                    !(parseReg(rhs,&rn,&rs,NULL) && parseNum(lhs,&sc))) {
                    if (err) *err = xerr(@"bad index term '%@'", t); return NO; }
                o->index = rn; o->scale = (int)sc;
            } else if ([[t lowercaseString] isEqualToString:@"rip"]) {
                o->ripRel = YES;
            } else if (parseReg(t,&rn,&rs,NULL)) {
                if (o->base < 0) o->base = rn; else { o->index = rn; }
            } else if (parseNum(t,&v)) {
                o->disp += v;
            } else {
                o->symbol = t;                        // symbolic displacement
            }
        }
        return YES;
    }

    int rn, rs; BOOL rex = NO;
    if (parseReg(s,&rn,&rs,&rex)) { o->kind = OpReg; o->reg = rn; o->size = rs; o->forceRex = rex; return YES; }

    int64_t v;
    if (parseNum(s,&v)) { o->kind = OpImm; o->imm = v; o->size = forced ?: 0; return YES; }

    // bare identifier -> symbolic immediate / branch target. `foo@PLT` is just
    // `foo` to us: we are the whole-program linker and either bind the call
    // directly or route it through a thunk we synthesize ourselves, so the
    // relocation-flavour suffix carries no information we act on.
    NSRange at = [s rangeOfString:@"@PLT" options:NSCaseInsensitiveSearch];
    if (at.location != NSNotFound && at.location + at.length == s.length)
        s = [s substringToIndex:at.location];
    o->kind = OpImm; o->symbol = s; o->imm = 0; o->size = forced ?: 0;
    return YES;
}


// Intel condition-code suffix -> cc nibble (shared by setcc and jcc).
static int ccCode(NSString *suffix) {
    static NSDictionary<NSString *, NSNumber *> *T; static dispatch_once_t o;
    dispatch_once(&o, ^{ T = @{@"o":@0,@"no":@1,@"b":@2,@"c":@2,@"nae":@2,
        @"ae":@3,@"nb":@3,@"nc":@3,@"e":@4,@"z":@4,@"ne":@5,@"nz":@5,
        @"be":@6,@"na":@6,@"a":@7,@"nbe":@7,@"s":@8,@"ns":@9,@"p":@10,@"pe":@10,
        @"np":@11,@"po":@11,@"l":@12,@"nge":@12,@"ge":@13,@"nl":@13,
        @"le":@14,@"ng":@14,@"g":@15,@"nle":@15}; });
    NSNumber *n = T[suffix]; return n ? n.intValue : -1;
}

// ───────────────────────────── encoding helpers ─────────────────────────────
static void emit8(NSMutableData *d, uint8_t b) { [d appendBytes:&b length:1]; }
static void emit16(NSMutableData *d, uint16_t v) { for (int i=0;i<2;i++) emit8(d,(uint8_t)(v>>(8*i))); }
static void emit32(NSMutableData *d, uint32_t v) { for (int i=0;i<4;i++) emit8(d,(uint8_t)(v>>(8*i))); }
static void emit64(NSMutableData *d, uint64_t v) { for (int i=0;i<8;i++) emit8(d,(uint8_t)(v>>(8*i))); }

// A full-width immediate for an operand size: 8/16/32 bits. A 64-bit operation
// still takes imm32 (sign-extended by the CPU) everywhere except movabs.
static void emitImmOsz(NSMutableData *d, int osz, int64_t v) {
    if (osz == 1)      emit8(d, (uint8_t)v);
    else if (osz == 2) emit16(d, (uint16_t)v);
    else               emit32(d, (uint32_t)v);
}

// REX: 0100 W R X B. Emitted only when needed (W=64-bit, or any extended reg,
// or an 8-bit spl/bpl/sil/dil).
static void emitRex(NSMutableData *d, BOOL w, int reg, int index, int rm, BOOL force) {
    // An ABSENT base/index arrives as -1; (-1 & 8) is 8, which would wrongly set
    // REX.X/B and emit a spurious prefix (0x4a where clang emits 0x48). Clamp.
    int r = reg   < 0 ? 0 : reg;
    int x = index < 0 ? 0 : index;
    int b = rm    < 0 ? 0 : rm;
    uint8_t rex = 0x40 | (w?8:0) | ((r&8)?4:0) | ((x&8)?2:0) | ((b&8)?1:0);
    if (w || (r&8) || (x&8) || (b&8) || force) emit8(d, rex);
}

// emitModRM publishes where it wrote a RIP-relative disp32, and for which
// symbol, so encodeOne can attach a PC32 fixup without every one of its ~25
// return paths having to. Encoding is single-threaded, so file statics suffice.
static NSInteger gRipDispOffset;      // -1 when the instruction has no rip operand
static NSString *gRipSymbol;
static int64_t   gRipAddend;          // a constant added to the symbol: [rip+sym+80]

// ModRM + SIB + displacement for a reg-and-rm pair.
// An immediate is a BIT PATTERN of the operand's width, and the imm8 short
// forms test it as a SIGNED value — so a full-width pattern with its top bit
// set has to be read as negative before it is tested. `and edi, 0xffffffff`
// is -1 in a 32-bit operand and encodes as the three-byte `83 /4 ff`, which is
// what GNU as and clang both emit; read as +4294967295 it missed the short
// form and came out six bytes long. The self-hosted assembler holds its
// immediates in an i32, so it wrapped for free and got the right answer — and
// the two disagreed byte for byte on five files. private:docs/bugs/240.
static int64_t signedForOperandSize(int64_t v, int osz)
    {
    if (osz == 4 && v >= 0x80000000LL && v <= 0xFFFFFFFFLL) return v - 0x100000000LL;
    if (osz == 2 && v >= 0x8000LL     && v <= 0xFFFFLL)     return v - 0x10000LL;
    if (osz == 1 && v >= 0x80LL       && v <= 0xFFLL)       return v - 0x100LL;
    return v;
    }

static void emitModRM(NSMutableData *d, int reg, const XOperand *rm) {
    if (rm->kind == OpReg) { emit8(d, (uint8_t)(0xC0 | ((reg&7)<<3) | (rm->reg&7))); return; }
    int base = rm->base, index = rm->index;
    BOOL needSib = (index >= 0) || (base >= 0 && (base&7) == 4);   // rsp/r12 base needs SIB
    int mod;
    if (rm->disp == 0 && base >= 0 && (base&7) != 5) mod = 0;      // rbp/r13 base needs disp8
    else if (rm->disp >= -128 && rm->disp <= 127) mod = 1;
    else mod = 2;
    if (base < 0) mod = 0;                                          // disp32 / rip-relative
    uint8_t rmField = needSib ? 4 : (base >= 0 ? (base&7) : 5);
    // A segment-overridden operand with neither base nor index is an ABSOLUTE
    // displacement — `fs:[0]` means offset 0 within that segment, not "0 bytes
    // from here". rip-relative would silently read the wrong memory, so this
    // takes the SIB form the absolute encoding requires: mod=00, rm=100,
    // SIB base=101 index=100, disp32.
    if (rm->seg && index < 0 && base < 0 && !rm->ripRel && !rm->symbol) {
        emit8(d, (uint8_t)(0x00 | ((reg&7)<<3) | 4));
        emit8(d, 0x25);
        emit32(d, (uint32_t)(int32_t)rm->disp);
        return;
    }
    // INDEX WITH NO BASE — `[4*rsi]`, which clang emits for a scaled offset it
    // has nothing to add to. It is not rip-relative and it is not "just a
    // disp32": the only encoding is mod=00 + SIB with base=101, and that form
    // ALWAYS carries a disp32, even when the displacement is zero. Falling into
    // the rip-relative branch below dropped the SIB byte entirely, so the
    // instruction came out one byte short and everything after it in the
    // function executed as garbage — which is how `new i32[N]` came back null on
    // the self-hosted PE path while `new C()` was fine (bug 032).
    if (index >= 0 && base < 0 && !rm->ripRel) {
        emit8(d, (uint8_t)(0x00 | ((reg&7)<<3) | 4));
        int ss = rm->scale==8?3 : rm->scale==4?2 : rm->scale==2?1 : 0;
        emit8(d, (uint8_t)((ss<<6) | ((index&7)<<3) | 5));
        emit32(d, (uint32_t)(int32_t)rm->disp);
        return;
    }
    if (rm->ripRel || base < 0) {
        emit8(d, (uint8_t)(0x00 | ((reg&7)<<3) | 5));
        if (rm->symbol) {
            gRipDispOffset = (NSInteger)d.length; gRipSymbol = rm->symbol;
            gRipAddend = rm->disp;   // `[rip + sym + 80]` — the 80 is part of the target
        }
        emit32(d,(uint32_t)rm->disp); return;
    }
    emit8(d, (uint8_t)((mod<<6) | ((reg&7)<<3) | rmField));
    if (needSib) {
        int ss = rm->scale==8?3 : rm->scale==4?2 : rm->scale==2?1 : 0;
        uint8_t sib = (uint8_t)((ss<<6) | ((index>=0?(index&7):4)<<3) | (base>=0?(base&7):5));
        emit8(d, sib);
    }
    if (mod == 1) emit8(d, (uint8_t)(int8_t)rm->disp);
    else if (mod == 2) emit32(d, (uint32_t)(int32_t)rm->disp);
}

// ModRM for an EVEX instruction. The same as emitModRM except for the 8-bit
// displacement, which EVEX scales by N, the size of the memory operand
// ("disp8*N"): a displacement that is a multiple of N and fits in 8 bits after
// dividing takes the short form, holding disp/N; any other non-zero
// displacement takes disp32, even one that would fit in 8 bits unscaled. The
// forms with no base register carry a disp32 already and are emitModRM's.
static void emitModRMN(NSMutableData *d, int reg, const XOperand *rm, int N) {
    if (rm->kind == OpReg || rm->base < 0 || rm->ripRel || rm->seg) { emitModRM(d, reg, rm); return; }
    int base = rm->base, index = rm->index;
    BOOL needSib = (index >= 0) || ((base&7) == 4);
    int mod;
    int64_t q = 0;
    if (rm->disp == 0 && (base&7) != 5) mod = 0;
    else if (N > 0 && rm->disp % N == 0 && rm->disp / N >= -128 && rm->disp / N <= 127) { mod = 1; q = rm->disp / N; }
    else mod = 2;
    emit8(d, (uint8_t)((mod<<6) | ((reg&7)<<3) | (needSib ? 4 : (base&7))));
    if (needSib) {
        int ss = rm->scale==8?3 : rm->scale==4?2 : rm->scale==2?1 : 0;
        emit8(d, (uint8_t)((ss<<6) | ((index>=0?(index&7):4)<<3) | (base&7)));
    }
    if (mod == 1) emit8(d, (uint8_t)(int8_t)q);
    else if (mod == 2) emit32(d, (uint32_t)(int32_t)rm->disp);
}

// The 4-byte EVEX prefix: 62, then
//   P0  R X B R' 0 m m m     R, X, B, R' inverted; mmm the opcode map (1 0F, 2 0F38, 3 0F3A)
//   P1  W v v v v 1 p p      vvvv the first source inverted (1111 when none); pp 66/F3/F2
//   P2  z L'L b V' a a a     L'L the vector length (2 = 512); V' inverted; aaa the opmask
// Registers here are 0-15, so R' and V' are always 1. For a register r/m, X
// holds bit 4 of that register (1, inverted); for memory it is the index's bit 3.
static void emitEvex(NSMutableData *d, int map, int pp, int W, int reg, int vreg, const XOperand *rm, int LL) {
    int rr = reg < 0 ? 0 : reg;
    int bb = rm->kind == OpReg ? rm->reg : (rm->base < 0 ? 0 : rm->base);
    int xx = rm->kind == OpReg ? 0 : (rm->index < 0 ? 0 : rm->index);
    int vvvv = vreg < 0 ? 0x0F : ((~vreg) & 0x0F);
    emit8(d, 0x62);
    emit8(d, (uint8_t)(((rr & 8) ? 0 : 0x80) | ((xx & 8) ? 0 : 0x40) | ((bb & 8) ? 0 : 0x20) | 0x10 | (map & 7)));
    emit8(d, (uint8_t)((W ? 0x80 : 0) | (vvvv << 3) | 0x04 | (pp & 3)));
    emit8(d, (uint8_t)((LL << 5) | 0x08));
}

@implementation XAX86_64Assembler {
    NSMutableArray<XAX86_64Fixup *> *_fixups;
    NSMutableDictionary<NSString *, NSNumber *> *_symbols;
    NSMutableData *_data;
    NSMutableSet<NSString *> *_dataSymbolNames;
    NSMutableSet<NSString *> *_globalNames;
    // `.comm` COMMON (tentative) symbols: name -> @[size, byteAlign]. A global
    // `.comm` is external-undefined-with-size, so the LINKER gives ONE
    // zero-filled slot every unit binds to (C tentative-definition merge) —
    // mirrors the arm64 assembler (bug 169). `.lcomm` stays a private local def.
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_commonSymbols;
    uint64_t _insnBase;          // offset in __text of the instruction being encoded
}
- (NSArray<XAX86_64Fixup *> *)fixups { return _fixups ?: @[]; }
- (NSDictionary<NSString *, NSNumber *> *)symbols { return _symbols ?: @{}; }
- (NSData *)data { return _data ?: [NSData data]; }
- (NSSet<NSString *> *)dataSymbols { return _dataSymbolNames ?: [NSSet set]; }
- (NSSet<NSString *> *)globalSymbols { return _globalNames ?: [NSSet set]; }
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)commonSymbols { return _commonSymbols ?: @{}; }

// A single-unit IMAGE (executable) has no link stage, so its COMMON (`.comm`)
// symbols must be given real zeroed storage HERE — exactly the slot the final
// linker would allocate for a `-c` object's commons. Sorted so the reference
// and the self-hosted assembler lay them out identically. Called by the image
// paths; `--object` keeps them as true commons for the ELF writer.
- (void)demoteCommonsToLocalData {
    if (!_commonSymbols.count) return;
    NSArray<NSString *> *names = [_commonSymbols.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *nm in names) {
        NSArray<NSNumber *> *info = _commonSymbols[nm];
        uint64_t sz = info[0].unsignedLongLongValue, al = info[1].unsignedLongLongValue;
        if (al < 1) al = 1;
        while (_data.length % al) emit8(_data, 0);
        _symbols[nm] = @(_data.length); [_dataSymbolNames addObject:nm];
        for (uint64_t i = 0; i < sz; i++) emit8(_data, 0);
    }
    [_commonSymbols removeAllObjects];
}

// Encode a single instruction, recording any fixups it needs relative to
// `_insnBase` (the instruction's offset in __text; 0 for the oracle harness,
// which encodes one instruction at a time in isolation).
- (nullable NSData *)encodeOne:(NSString *)line error:(NSError **)error {
    gRipDispOffset = -1; gRipSymbol = nil; gRipAddend = 0;
    NSData *out = [self encodeInsn:line error:error];
    if (out && gRipDispOffset >= 0 && gRipSymbol) {
        // The CPU adds the disp32 to the address of the NEXT instruction, so the
        // addend is minus the number of bytes that follow the displacement —
        // normally 4, but more when an immediate trails it (`mov [rip+x], 1`).
        XAX86_64Fixup *f = [XAX86_64Fixup new];
        f.offset = _insnBase + (uint64_t)gRipDispOffset;
        // A `@GOTPCREL` relocation specifier on the operand — our codegen emits
        // `mov reg, [rip + sym@GOTPCREL]` to take the address of a symbol that
        // may live in another shared object (e.g. an imported `<Class>$vtbl`).
        // It is the relaxable-mov GOT load: strip the suffix and mark it GotLoad
        // so the writer either relaxes it (symbol defined here) or resolves it to
        // a loader-filled GOT slot (symbol imported). The PC-relative addend is
        // identical to a plain PC32, so only the kind and symbol differ.
        NSString *sym = gRipSymbol;
        BOOL isGot = [sym hasSuffix:@"@GOTPCREL"];
        if (isGot) sym = [sym substringToIndex:sym.length - (NSUInteger)9];
        f.kind = isGot ? XAX86FixupGotLoad : XAX86FixupPC32; f.symbol = sym;
        f.addend = gRipAddend - (int64_t)(out.length - (NSUInteger)gRipDispOffset);
        if (!_fixups) _fixups = [NSMutableArray array];
        [_fixups addObject:f];
    }
    return out;
}

- (nullable NSData *)encodeInsn:(NSString *)line error:(NSError **)error {
    NSMutableData *out = [NSMutableData data];
    NSString *s = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSRange sp = [s rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *mn = sp.location == NSNotFound ? s : [s substringToIndex:sp.location];
    NSString *rest = sp.location == NSNotFound ? @"" : [s substringFromIndex:sp.location];
    mn = [mn lowercaseString];

    // split operands on commas at bracket depth 0
    NSMutableArray<NSString *> *toks = [NSMutableArray array];
    { int depth=0; NSUInteger st=0; NSString *r=rest;
      for (NSUInteger i=0;i<r.length;i++) { unichar c=[r characterAtIndex:i];
        if (c=='[') depth++; else if (c==']') depth--;
        else if (c==',' && depth==0) { [toks addObject:[r substringWithRange:NSMakeRange(st,i-st)]]; st=i+1; } }
      NSString *last=[[r substringFromIndex:st] stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
      if (last.length) [toks addObject:last]; }
    XOperand opv[4]; NSUInteger nops = 0;
    for (NSString *t in toks) {
        if (nops >= 4) break;
        if (!parseOperand(t, &opv[nops], error)) return nil;
        nops++;
    }
    #define CLEANUP() do { } while(0)
    XOperand *a = nops > 0 ? &opv[0] : NULL;
    XOperand *b = nops > 1 ? &opv[1] : NULL;
    XOperand *c = nops > 2 ? &opv[2] : NULL;   // imm8 selector (shufps/shufpd)
    NSUInteger opCount = nops;

    // Operand size: from a register operand, else a `ptr` override, else 8.
    int osz = 8;
    if (a && a->kind == OpReg) osz = a->size;
    else if (b && b->kind == OpReg) osz = b->size;
    else if (a && a->kind == OpMem && a->size) osz = a->size;
    BOOL w = (osz == 8);

    // A segment override is the OUTERMOST prefix: it precedes the operand-size
    // 0x66 and the REX byte, so it is emitted first and once.
    for (NSUInteger i = 0; i < nops; i++)
        if (opv[i].kind == OpMem && opv[i].seg) { emit8(out, opv[i].seg); break; }

    // A 16-bit GPR operation takes the 0x66 operand-size prefix, and it must come
    // BEFORE any REX byte — so emit it here, once, ahead of every encoding path.
    // SSE mnemonics can't be caught by this: their register operands are xmm,
    // which parse at size 16, so `osz` is never 2 on those paths.
    if (osz == 2) emit8(out, 0x66);

    // spl/bpl/sil/dil are register numbers 4-7 in an 8-bit operand — the SAME
    // numbers that mean ah/ch/dh/bh without a REX prefix. A REX byte (even an
    // all-zero one) is what selects the low-byte forms, so if ANY operand is one
    // of them, every encoding path below must emit it. Missing this turned
    // `cmp dil, 1` into `cmp bh, 1`: it assembled, ran, and compared the wrong
    // register.
    BOOL force8 = NO;
    for (NSUInteger i = 0; i < nops; i++)
        if (opv[i].kind == OpReg && opv[i].forceRex) force8 = YES;

    // ── zero-operand ──
    if ([mn isEqualToString:@"ret"])  { emit8(out,0xC3); CLEANUP(); return out; }
    if ([mn isEqualToString:@"leave"]){ emit8(out,0xC9); CLEANUP(); return out; }
    if ([mn isEqualToString:@"nop"])  { emit8(out,0x90); CLEANUP(); return out; }
    if ([mn isEqualToString:@"cdq"])  { emit8(out,0x99); CLEANUP(); return out; }
    if ([mn isEqualToString:@"cqo"])  { emit8(out,0x48); emit8(out,0x99); CLEANUP(); return out; }
    if ([mn isEqualToString:@"syscall"]) { emit8(out,0x0F); emit8(out,0x05); CLEANUP(); return out; }
    if ([mn isEqualToString:@"hlt"])  { emit8(out,0xF4); CLEANUP(); return out; }
    if ([mn isEqualToString:@"ud2"])  { emit8(out,0x0F); emit8(out,0x0B); CLEANUP(); return out; }
    if ([mn isEqualToString:@"cwd"])  { emit8(out,0x66); emit8(out,0x99); CLEANUP(); return out; }
    if ([mn isEqualToString:@"cdqe"]) { emit8(out,0x48); emit8(out,0x98); CLEANUP(); return out; }

    // ── atomics (private:docs/Design/threading.md) ──
    // `lock` is a PREFIX, not an instruction: encode the rest and put 0xF0 in
    // front. The rip-relative displacement offset recorded by the inner encode
    // has to shift by that one byte, or a `lock` on a rip-relative operand would
    // relocate one byte short — the kind of bug that only shows up under
    // contention on a global.
    if ([mn isEqualToString:@"lock"]) {
        NSData *inner = [self encodeInsn:rest error:error];
        if (!inner) return nil;
        NSMutableData *o = [NSMutableData data];
        // Prefix ORDER is free architecturally, but clang puts the 0x66
        // operand-size prefix ahead of 0xF0 on a 16-bit locked operation — and
        // byte-identical-to-clang is the standard the oracle diff holds this
        // assembler to, so match it rather than be merely valid.
        const uint8_t *ib = (const uint8_t *)inner.bytes;
        NSUInteger skip = (inner.length && ib[0] == 0x66) ? 1 : 0;
        if (skip) emit8(o, 0x66);
        emit8(o, 0xF0);
        [o appendBytes:ib + skip length:inner.length - skip];
        if (gRipDispOffset >= 0) gRipDispOffset += 1;
        return o;
    }
    // `rex64` is likewise a PREFIX — REX.W, written on its own line. clang emits
    // it on the indirect tail-call thunk (`rex64 jmp rdx`), where the W bit is
    // architecturally redundant but present in the bytes we are held identical
    // to. If the inner encoding already carries a REX byte, set W in THAT one
    // rather than emit a second: two REX bytes would decode the first as a
    // no-op prefix and change the instruction.
    if ([mn isEqualToString:@"rex64"]) {
        NSData *inner = [self encodeInsn:rest error:error];
        if (!inner) return nil;
        const uint8_t *ib = (const uint8_t *)inner.bytes;
        NSMutableData *o = [NSMutableData data];
        // Legacy prefixes come first and REX must sit immediately before the
        // opcode, so step over any the inner encode already emitted.
        NSUInteger i = 0;
        while (i < inner.length && (ib[i]==0x66 || ib[i]==0xF2 || ib[i]==0xF3 || ib[i]==0xF0)) i++;
        [o appendBytes:ib length:i];
        if (i < inner.length && (ib[i] & 0xF0) == 0x40) {
            emit8(o, ib[i] | 0x08);                       // existing REX: set W
            [o appendBytes:ib + i + 1 length:inner.length - i - 1];
        } else {
            emit8(o, 0x48);                               // bare REX.W
            [o appendBytes:ib + i length:inner.length - i];
            if (gRipDispOffset >= 0) gRipDispOffset += 1;
        }
        return o;
    }
    // Fences and the spin-wait hint.
    if ([mn isEqualToString:@"mfence"]) { emit8(out,0x0F); emit8(out,0xAE); emit8(out,0xF0); return out; }
    if ([mn isEqualToString:@"lfence"]) { emit8(out,0x0F); emit8(out,0xAE); emit8(out,0xE8); return out; }
    if ([mn isEqualToString:@"sfence"]) { emit8(out,0x0F); emit8(out,0xAE); emit8(out,0xF8); return out; }
    if ([mn isEqualToString:@"pause"])  { emit8(out,0xF3); emit8(out,0x90); return out; }
    // The CPU-feature reads behind runtime SIMD dispatch (_xt_simd_select).
    if ([mn isEqualToString:@"cpuid"])  { emit8(out,0x0F); emit8(out,0xA2); return out; }
    if ([mn isEqualToString:@"xgetbv"]) { emit8(out,0x0F); emit8(out,0x01); emit8(out,0xD0); return out; }
    // bt / bts / btr / btc — bit test (+set/reset/complement). clang reaches for
    // `bt` on a "is bit N of this mask set?" loop, which is how the threading
    // runtime's CPU-count popcount arrives here.
    {
        static NSDictionary *btOps; static dispatch_once_t btonce;
        dispatch_once(&btonce, ^{ btOps = @{@"bt":@[@0xA3,@4], @"bts":@[@0xAB,@5],
                                            @"btr":@[@0xB3,@6], @"btc":@[@0xBB,@7]}; });
        NSArray *bt = btOps[mn];
        if (bt && a && b) {
            if (b->kind == OpReg) {                       // 0F <op> /r
                emitRex(out, w, b->reg, a->index, a->kind==OpReg ? a->reg : a->base, force8);
                emit8(out, 0x0F); emit8(out, (uint8_t)[bt[0] intValue]);
                emitModRM(out, b->reg, a);
                CLEANUP(); return out;
            }
            if (b->kind == OpImm && !b->symbol) {         // 0F BA /ext ib
                emitRex(out, w, 0, a->index, a->kind==OpReg ? a->reg : a->base, force8);
                emit8(out, 0x0F); emit8(out, 0xBA);
                emitModRM(out, [bt[1] intValue], a);
                emit8(out, (uint8_t)(b->imm & 0xFF));
                CLEANUP(); return out;
            }
        }
    }
    // xadd / cmpxchg / xchg — r/m is the destination, the register is `b`.
    if (([mn isEqualToString:@"xadd"] || [mn isEqualToString:@"cmpxchg"] ||
         [mn isEqualToString:@"xchg"]) && a && b && b->kind == OpReg) {
        emitRex(out, w, b->reg, a->index, a->kind==OpReg ? a->reg : a->base, force8);
        if ([mn isEqualToString:@"xchg"]) {
            emit8(out, (uint8_t)(osz == 1 ? 0x86 : 0x87));
        } else {
            emit8(out, 0x0F);
            uint8_t op = [mn isEqualToString:@"xadd"] ? 0xC1 : 0xB1;
            emit8(out, (uint8_t)(osz == 1 ? op - 1 : op));
        }
        emitModRM(out, b->reg, a);
        CLEANUP(); return out;
    }

    // ── push/pop r64 ──
    if (([mn isEqualToString:@"push"] || [mn isEqualToString:@"pop"]) && a && a->kind == OpReg) {
        if (a->reg & 8) emit8(out, 0x41);
        emit8(out, (uint8_t)(([mn isEqualToString:@"push"] ? 0x50 : 0x58) + (a->reg & 7)));
        CLEANUP(); return out;
    }

    // ── ALU r/m, r  and  r, r/m  and  r/m, imm ──
    static NSDictionary *alu; static dispatch_once_t aonce;
    dispatch_once(&aonce, ^{ alu = @{@"add":@0, @"or":@1, @"adc":@2, @"sbb":@3,
                                     @"and":@4, @"sub":@5, @"xor":@6, @"cmp":@7}; });
    NSNumber *aluOp = alu[mn];
    if (aluOp && a && b) {
        int ext = aluOp.intValue;
        if (b->kind == OpImm && !b->symbol) {
            // There is no `and r64, imm64` — nor or/xor/add/sub/cmp. The widest
            // immediate any of them takes is an imm32, SIGN-EXTENDED to 64 bits,
            // so anything outside int32 has no encoding. Emitting the low half
            // is not a smaller version of the right answer: `x & 0xFF00FF00FF`
            // becomes `x & 0x00FF00FF` and every 64-bit AND loses its high word.
            // The PORT has refused this since bug 089; this assembler never did,
            // and quietly truncated — a divergence no byte gate could see,
            // because the port stopped before either of them wrote anything.
            // `and rdi, 0xffffffff` is caught by the same rule: the two forms
            // both sign-extend, so it would mean `and rdi, -1`, not a 32-bit
            // mask. private:docs/bugs/240.
            if (osz == 8 && (b->imm < INT32_MIN || b->imm > INT32_MAX)) {
                if (error) *error = xerr(@"64-bit immediate does not fit an imm32 "
                                          @"field — load it into a register first "
                                          @"('%@')", mn);
                CLEANUP(); return nil;
            }
            int64_t sv = signedForOperandSize(b->imm, osz);
            BOOL imm8 = (sv >= -128 && sv <= 127);
            // The accumulator short form (`3d id` for `cmp eax, imm32`) saves the
            // ModRM byte. Only worth it for a full-width immediate — with an imm8
            // the `83 /ext ib` form is shorter still. clang always picks it, so
            // matching keeps the oracle byte-exact.
            if (a->kind == OpReg && a->reg == 0 && !imm8 && osz != 1) {
                emitRex(out, w, 0, 0, 0, force8);
                emit8(out, (uint8_t)(ext*8 + 0x05));
                emitImmOsz(out, osz, b->imm); CLEANUP(); return out;
            }
            emitRex(out, w, 0, a->index, a->kind==OpReg ? a->reg : a->base, force8);
            if (osz == 1) emit8(out, 0x80);
            else emit8(out, imm8 ? 0x83 : 0x81);
            emitModRM(out, ext, a);
            if (osz == 1 || imm8) emit8(out, (uint8_t)b->imm); else emitImmOsz(out, osz, b->imm);
            CLEANUP(); return out;
        }
        if (b->kind == OpReg) {                       // r/m, r  (opcode base+1)
            emitRex(out, w, b->reg, a->index, a->kind==OpReg ? a->reg : a->base, force8);
            emit8(out, (uint8_t)(ext*8 + (osz==1 ? 0x00 : 0x01)));
            emitModRM(out, b->reg, a);
            CLEANUP(); return out;
        }
        if (a->kind == OpReg && b->kind == OpMem) {   // r, r/m  (opcode base+3)
            emitRex(out, w, a->reg, b->index, b->base, force8);
            emit8(out, (uint8_t)(ext*8 + (osz==1 ? 0x02 : 0x03)));
            emitModRM(out, a->reg, b);
            CLEANUP(); return out;
        }
    }

    // ── mov ──
    if ([mn isEqualToString:@"mov"] && a && b) {
        if (b->kind == OpImm && !b->symbol) {
            if (a->kind == OpReg && osz == 8 && (b->imm > INT32_MAX || b->imm < INT32_MIN)) {
                emitRex(out, YES, 0, 0, a->reg, NO);          // movabs r64, imm64
                emit8(out, (uint8_t)(0xB8 + (a->reg & 7)));
                emit64(out, (uint64_t)b->imm); CLEANUP(); return out;
            }
            if (a->kind == OpReg && osz == 1) {               // mov r8, imm8 (B0+rd)
                emitRex(out, NO, 0, 0, a->reg, force8);
                emit8(out, (uint8_t)(0xB0 + (a->reg & 7)));
                emit8(out, (uint8_t)b->imm); CLEANUP(); return out;
            }
            if (a->kind == OpReg && (osz == 2 || osz == 4)) { // mov r16/r32, imm16/32
                emitRex(out, NO, 0, 0, a->reg, force8);
                emit8(out, (uint8_t)(0xB8 + (a->reg & 7)));
                emitImmOsz(out, osz, b->imm); CLEANUP(); return out;
            }
            // r64 falls through to C7 /0 with a sign-extended imm32 — B8+rd under
            // REX.W is `movabs` and would demand eight immediate bytes.
            emitRex(out, w, 0, a->index, a->kind==OpReg?a->reg:a->base, force8);
            emit8(out, osz==1 ? 0xC6 : 0xC7);
            emitModRM(out, 0, a);
            emitImmOsz(out, osz, b->imm);
            CLEANUP(); return out;
        }
        if (b->kind == OpReg) {                                // r/m, r
            emitRex(out, w, b->reg, a->index, a->kind==OpReg?a->reg:a->base, force8);
            emit8(out, osz==1 ? 0x88 : 0x89);
            emitModRM(out, b->reg, a); CLEANUP(); return out;
        }
        if (a->kind == OpReg && b->kind == OpMem) {            // r, r/m
            emitRex(out, w, a->reg, b->index, b->base, force8);
            emit8(out, osz==1 ? 0x8A : 0x8B);
            emitModRM(out, a->reg, b); CLEANUP(); return out;
        }
    }

    // ── lea r, [mem] ──
    if ([mn isEqualToString:@"lea"] && a && b && a->kind==OpReg && b->kind==OpMem) {
        emitRex(out, a->size==8, a->reg, b->index, b->base, force8);
        emit8(out, 0x8D); emitModRM(out, a->reg, b); CLEANUP(); return out;
    }

    // ── movsxd r64, r/m32 (63 /r) — the sign-extending 32->64 move ──
    if ([mn isEqualToString:@"movsxd"] && a && b) {
        emitRex(out, YES, a->reg, b->index, b->kind==OpReg?b->reg:b->base, NO);
        emit8(out, 0x63); emitModRM(out, a->reg, b); CLEANUP(); return out;
    }

    // ── movzx / movsx ──
    if (([mn isEqualToString:@"movzx"] || [mn isEqualToString:@"movsx"]) && a && b) {
        BOOL zx = [mn isEqualToString:@"movzx"];
        int srcSize = b->kind==OpReg ? b->size : (b->size ?: 1);
        // 0F B6/B7 and 0F BE/BF extend from a BYTE or a WORD only. A 32-bit
        // source is a different instruction (movsxd, 0x63) — and there is no
        // movzx from 32, because a plain 32-bit mov already zero-extends. Left
        // to the size arithmetic below, both silently encoded as extend-from-
        // byte: assembled fine, ran, and read one byte where four were meant.
        if (srcSize >= 4) {
            if (error) *error = xerr(@"'%@' cannot extend from a %d-byte source — "
                                      @"use movsxd for 32->64, or a plain 32-bit mov "
                                      @"to zero-extend", mn, srcSize);
            CLEANUP(); return nil;
        }
        emitRex(out, a->size==8, a->reg, b->index, b->kind==OpReg?b->reg:b->base, force8);
        emit8(out, 0x0F);
        emit8(out, (uint8_t)((zx ? 0xB6 : 0xBE) + (srcSize==2 ? 1 : 0)));
        emitModRM(out, a->reg, b); CLEANUP(); return out;
    }

    // ── unary: neg / not / mul / imul(1-op) / div / idiv ──
    static NSDictionary *un; static dispatch_once_t uonce;
    dispatch_once(&uonce, ^{ un = @{@"not":@2, @"neg":@3, @"mul":@4, @"imul":@5,
                                    @"div":@6, @"idiv":@7}; });
    NSNumber *unOp = un[mn];
    if (unOp && a && opCount == 1) {
        emitRex(out, w, 0, a->index, a->kind==OpReg?a->reg:a->base, force8);
        emit8(out, osz==1 ? 0xF6 : 0xF7);
        emitModRM(out, unOp.intValue, a); CLEANUP(); return out;
    }

    // ── inc / dec r/m  (FE /0 /1 for bytes, FF /0 /1 otherwise) ──
    if (([mn isEqualToString:@"inc"] || [mn isEqualToString:@"dec"]) && a && opCount == 1) {
        emitRex(out, w, 0, a->index, a->kind==OpReg?a->reg:a->base, force8);
        emit8(out, osz==1 ? 0xFE : 0xFF);
        emitModRM(out, [mn isEqualToString:@"inc"] ? 0 : 1, a); CLEANUP(); return out;
    }

    // ── test r/m, imm  (A8/A9 for the accumulator, else F6/F7 /0) ──
    if ([mn isEqualToString:@"test"] && a && b && b->kind == OpImm && !b->symbol) {
        if (a->kind == OpReg && a->reg == 0 && !force8) {
            emitRex(out, w, 0, 0, 0, NO);
            emit8(out, osz==1 ? 0xA8 : 0xA9);
        } else {
            emitRex(out, w, 0, a->index, a->kind==OpReg?a->reg:a->base, force8);
            emit8(out, osz==1 ? 0xF6 : 0xF7);
            emitModRM(out, 0, a);
        }
        emitImmOsz(out, osz, b->imm); CLEANUP(); return out;
    }

    // ── test r/m, r ──
    if ([mn isEqualToString:@"test"] && a && b && b->kind==OpReg) {
        emitRex(out, w, b->reg, a->index, a->kind==OpReg?a->reg:a->base, force8);
        emit8(out, osz==1 ? 0x84 : 0x85);
        emitModRM(out, b->reg, a); CLEANUP(); return out;
    }


    // ── setcc r/m8 ──
    if ([mn hasPrefix:@"set"] && a && ccCode([mn substringFromIndex:3]) >= 0) {
        int cc = ccCode([mn substringFromIndex:3]);
        emitRex(out, NO, 0, a->index, a->kind==OpReg?a->reg:a->base, force8);
        emit8(out, 0x0F); emit8(out, (uint8_t)(0x90 + cc));
        emitModRM(out, 0, a); CLEANUP(); return out;
    }

    // ── shifts: by imm8 (C1 /ext ib) or by cl (D3 /ext) ──
    static NSDictionary *sh; static dispatch_once_t sonce;
    dispatch_once(&sonce, ^{ sh = @{@"rol":@0,@"ror":@1,@"shl":@4,@"sal":@4,
                                    @"shr":@5,@"sar":@7}; });
    NSNumber *shOp = sh[mn];
    if (shOp && a) {
        emitRex(out, w, 0, a->index, a->kind==OpReg?a->reg:a->base, force8);
        if (!b) {                                     // no count operand = by 1
            emit8(out, osz==1 ? 0xD0 : 0xD1); emitModRM(out, shOp.intValue, a);
        } else if (b->kind == OpReg) {                // by cl
            emit8(out, osz==1 ? 0xD2 : 0xD3); emitModRM(out, shOp.intValue, a);
        } else if (b->imm == 1) {                     // by 1 (short form)
            emit8(out, osz==1 ? 0xD0 : 0xD1); emitModRM(out, shOp.intValue, a);
        } else {
            emit8(out, osz==1 ? 0xC0 : 0xC1); emitModRM(out, shOp.intValue, a);
            emit8(out, (uint8_t)b->imm);
        }
        CLEANUP(); return out;
    }

    // ── imul r, r/m  (two-operand form: 0F AF /r, reg = DEST) ──
    if ([mn isEqualToString:@"imul"] && a && b && opCount == 2 && a->kind == OpReg) {
        emitRex(out, w, a->reg, b->index, b->kind==OpReg?b->reg:b->base, force8);
        emit8(out, 0x0F); emit8(out, 0xAF);
        emitModRM(out, a->reg, b); CLEANUP(); return out;
    }

    // ── movabs r64, imm64 ──
    if ([mn isEqualToString:@"movabs"] && a && b && a->kind == OpReg) {
        emitRex(out, YES, 0, 0, a->reg, NO);
        emit8(out, (uint8_t)(0xB8 + (a->reg & 7)));
        emit64(out, (uint64_t)b->imm); CLEANUP(); return out;
    }

    // ── branches: call/jmp rel32, jcc rel32. The displacement is filled by the
    //    linker (a Rel32 fixup); we emit 0 and record the target symbol. ──
    if (([mn isEqualToString:@"call"] || [mn isEqualToString:@"jmp"]) && a) {
        if (a->kind == OpReg || a->kind == OpMem) {   // indirect: FF /2 (call) /4 (jmp)
            emitRex(out, NO, 0, a->index, a->kind==OpReg?a->reg:a->base, force8);
            emit8(out, 0xFF); emitModRM(out, [mn isEqualToString:@"call"] ? 2 : 4, a);
            CLEANUP(); return out;
        }
        emit8(out, [mn isEqualToString:@"call"] ? 0xE8 : 0xE9);
        [self recordRel32:a->symbol at:out.length];
        emit32(out, 0); CLEANUP(); return out;
    }
    if ([mn hasPrefix:@"j"] && a && ccCode([mn substringFromIndex:1]) >= 0) {
        emit8(out, 0x0F); emit8(out, (uint8_t)(0x80 + ccCode([mn substringFromIndex:1])));
        [self recordRel32:a->symbol at:out.length];
        emit32(out, 0); CLEANUP(); return out;
    }


    // ── SSE / SSE2 (scalar float + the vectoriser's packed forms) ──
    // Encoding is [mandatory prefix F3/F2/66][REX][0F][opcode][ModRM]; note the
    // prefix precedes REX. dest is the ModRM.reg field, src the r/m.
    static NSDictionary *sseRR; static dispatch_once_t sonce2;
    dispatch_once(&sonce2, ^{
        // mnemonic -> @[prefix, opcode]   (0 prefix = none)
        sseRR = @{@"addss":@[@0xF3,@0x58], @"addsd":@[@0xF2,@0x58],
                  @"subss":@[@0xF3,@0x5C], @"subsd":@[@0xF2,@0x5C],
                  @"subpd":@[@0x66,@0x5C], @"subps":@[@0x00,@0x5C],
                  @"addpd":@[@0x66,@0x58], @"addps":@[@0x00,@0x58],
                  @"mulpd":@[@0x66,@0x59], @"mulps":@[@0x00,@0x59],
                  @"divpd":@[@0x66,@0x5E], @"divps":@[@0x00,@0x5E],
                  @"mulss":@[@0xF3,@0x59], @"mulsd":@[@0xF2,@0x59],
                  @"divss":@[@0xF3,@0x5E], @"divsd":@[@0xF2,@0x5E],
                  @"sqrtss":@[@0xF3,@0x51],@"sqrtsd":@[@0xF2,@0x51],
                  @"ucomiss":@[@0x00,@0x2E],@"ucomisd":@[@0x66,@0x2E],
                  @"comiss":@[@0x00,@0x2F], @"comisd":@[@0x66,@0x2F],
                  @"cvtss2sd":@[@0xF3,@0x5A],@"cvtsd2ss":@[@0xF2,@0x5A],
                  @"xorps":@[@0x00,@0x57],  @"xorpd":@[@0x66,@0x57],
                  @"andps":@[@0x00,@0x54],  @"andpd":@[@0x66,@0x54],
                  @"andnps":@[@0x00,@0x55], @"andnpd":@[@0x66,@0x55],
                  @"orps":@[@0x00,@0x56],   @"orpd":@[@0x66,@0x56],
                  @"unpcklpd":@[@0x66,@0x14],@"unpcklps":@[@0x00,@0x14],
                  @"unpckhpd":@[@0x66,@0x15],@"unpckhps":@[@0x00,@0x15],
                  @"paddd":@[@0x66,@0xFE],  @"paddw":@[@0x66,@0xFD],
                  @"paddb":@[@0x66,@0xFC],  @"paddq":@[@0x66,@0xD4],
                  @"psubd":@[@0x66,@0xFA],  @"psubw":@[@0x66,@0xF9],
                  @"maxsd":@[@0xF2,@0x5F],  @"maxss":@[@0xF3,@0x5F],
                  @"minsd":@[@0xF2,@0x5D],  @"minss":@[@0xF3,@0x5D],
                  @"maxpd":@[@0x66,@0x5F],  @"maxps":@[@0x00,@0x5F],
                  @"minpd":@[@0x66,@0x5D],  @"minps":@[@0x00,@0x5D],
                  @"cvttpd2dq":@[@0x66,@0xE6], @"cvtdq2pd":@[@0xF3,@0xE6],
                  @"cvttps2dq":@[@0xF3,@0x5B], @"cvtdq2ps":@[@0x00,@0x5B],
                  @"cvtps2pd":@[@0x00,@0x5A],  @"cvtpd2ps":@[@0x66,@0x5A],
                  @"punpckldq":@[@0x66,@0x62], @"punpcklqdq":@[@0x66,@0x6C],
                  @"pand":@[@0x66,@0xDB],   @"por":@[@0x66,@0xEB],
                  @"pxor":@[@0x66,@0xEF],   @"psrld":@[@0x66,@0xD2],
                  @"pslld":@[@0x66,@0xF2],  @"psrlq":@[@0x66,@0xD3],
                  @"psllq":@[@0x66,@0xF3],
                  // Emitted by the vectoriser's widening-sum / dot-product
                  // reductions; absent until bug 029.
                  @"pcmpeqd":@[@0x66,@0x76], @"pcmpgtd":@[@0x66,@0x66],
                  // The BYTE and WORD lane widths of the same two compares.
                  // Only the dword forms existed, so the back end emitted a
                  // dword compare for byte lanes and string_scan counted zero
                  // matches instead of 64 (bug 223).
                  @"pcmpeqb":@[@0x66,@0x74], @"pcmpgtb":@[@0x66,@0x64],
                  @"pcmpeqw":@[@0x66,@0x75], @"pcmpgtw":@[@0x66,@0x65],
                  @"pmaddwd":@[@0x66,@0xF5], @"punpcklbw":@[@0x66,@0x60],
                  // The i16 multiply the vectoriser emits for a widening
                  // product (vectorize_dot, vectorize_widen_tail).
                  @"pmullw":@[@0x66,@0xD5],
                  // The SSE2 word / byte lane min and max (16-bit signed, 8-bit
                  // unsigned); the other widths and signs are SSE4.1, in VEX's
                  // 0F38 map.
                  @"pmaxsw":@[@0x66,@0xEE], @"pminsw":@[@0x66,@0xEA],
                  @"pmaxub":@[@0x66,@0xDE], @"pminub":@[@0x66,@0xDA],
                  // The unsigned 32x32 -> 64 lane product over lanes 0
                  // and 2. SSE2 has no other widening integer multiply,
                  // and it is what the VMulHi sequence is built from.
                  @"pmuludq":@[@0x66,@0xF4]};
    });
    // ── VEX.128 three-operand forms of the SSE table ──
    //
    // `vaddps xmm0, xmm1, xmm2` is `addps` with a VEX prefix and a
    // NON-DESTRUCTIVE first source, so the same opcode byte serves both and the
    // table above is the only place a mnemonic has to be listed. That is the
    // point of doing it this way: a VEX table that repeated the opcodes would
    // be a second copy to drift, which is how bug 027's allocator contract went
    // wrong.
    //
    // VEX.128 only, and no ymm yet — this is the three-operand half of
    // private:docs/bugs/231, which is testable on its own against the vendor
    // assembler. The 256-bit half needs a register pool and vzeroupper
    // discipline, and is not encoding work.
    //
    //   2-byte form  C5 [R vvvv L pp]                  when X=B=W=0 and map=0F
    //   3-byte form  C4 [RXB mmmmm] [W vvvv L pp]      otherwise
    //
    // pp encodes the mandatory prefix the SSE form carries (66/F3/F2), and
    // mmmmm the opcode map (0F, 0F38). vvvv holds the first source INVERTED.
    // ── AVX/AVX2 forms that are not a three-operand SSE op ──
    // vzeroupper; two-operand moves and broadcasts (VEX.vvvv = 1111);
    // vextract{i,f}128 (the source in reg, the destination in r/m); and the
    // immediate shifts (the DESTINATION in vvvv, the source in r/m).
    // ── EVEX.512: AVX-512 forms (F, DQ, BW, VL) ──
    //
    // Any instruction with a zmm operand. Each entry: @[form, map, pp, W,
    // opcode, N], with pp 0 none / 1 66 / 2 F3 / 3 F2, map 1 0F / 2 0F38 /
    // 3 0F3A, and N the memory operand's size for disp8*N (0 = by form). The
    // forms, by where each operand goes:
    //   1 dst, src1, src2        reg = dst, vvvv = src1, r/m = src2
    //   2 move                   load: reg = dst, r/m = src; store: the reverse
    //   3 broadcast              reg = dst, r/m = the xmm or element in memory
    //   4 compare into k         reg = k, vvvv = src1, r/m = src2   (5: + imm)
    //   6 k to vector            reg = dst, r/m = k
    //   7 shift by immediate     vvvv = dst, r/m = src, reg = the /ext in N
    //   8 extract                reg = the zmm source, r/m = the dest, imm
    //   9 shuffle by immediate   reg = dst, r/m = src, imm
    //  10 dst, src1, src2, imm   reg = dst, vvvv = src1, r/m = src2, imm
    //  11 shift by xmm count     as 1, the count an xmm (N 16)
    //  12 unary                  reg = dst, r/m = src
    {
        BOOL zmm = NO;
        for (NSUInteger i = 0; i < opCount; i++)
            if (opv[i].kind == OpReg && opv[i].size == 64) zmm = YES;
        if (zmm) {
            static NSDictionary *E; static dispatch_once_t eonce;
            dispatch_once(&eonce, ^{
                E = @{
                // 1: three-operand arithmetic and logic
                @"vaddps":@[@1,@1,@0,@0,@0x58,@64], @"vaddpd":@[@1,@1,@1,@1,@0x58,@64],
                @"vsubps":@[@1,@1,@0,@0,@0x5C,@64], @"vsubpd":@[@1,@1,@1,@1,@0x5C,@64],
                @"vmulps":@[@1,@1,@0,@0,@0x59,@64], @"vmulpd":@[@1,@1,@1,@1,@0x59,@64],
                @"vdivps":@[@1,@1,@0,@0,@0x5E,@64], @"vdivpd":@[@1,@1,@1,@1,@0x5E,@64],
                @"vmaxps":@[@1,@1,@0,@0,@0x5F,@64], @"vmaxpd":@[@1,@1,@1,@1,@0x5F,@64],
                @"vminps":@[@1,@1,@0,@0,@0x5D,@64], @"vminpd":@[@1,@1,@1,@1,@0x5D,@64],
                @"vandps":@[@1,@1,@0,@0,@0x54,@64], @"vandpd":@[@1,@1,@1,@1,@0x54,@64],
                @"vandnps":@[@1,@1,@0,@0,@0x55,@64], @"vandnpd":@[@1,@1,@1,@1,@0x55,@64],
                @"vorps":@[@1,@1,@0,@0,@0x56,@64], @"vorpd":@[@1,@1,@1,@1,@0x56,@64],
                @"vxorps":@[@1,@1,@0,@0,@0x57,@64], @"vxorpd":@[@1,@1,@1,@1,@0x57,@64],
                @"vunpcklps":@[@1,@1,@0,@0,@0x14,@64], @"vunpcklpd":@[@1,@1,@1,@1,@0x14,@64],
                @"vunpckhps":@[@1,@1,@0,@0,@0x15,@64], @"vunpckhpd":@[@1,@1,@1,@1,@0x15,@64],
                @"vpaddb":@[@1,@1,@1,@0,@0xFC,@64], @"vpaddw":@[@1,@1,@1,@0,@0xFD,@64],
                @"vpaddd":@[@1,@1,@1,@0,@0xFE,@64], @"vpaddq":@[@1,@1,@1,@1,@0xD4,@64],
                @"vpsubb":@[@1,@1,@1,@0,@0xF8,@64], @"vpsubw":@[@1,@1,@1,@0,@0xF9,@64],
                @"vpsubd":@[@1,@1,@1,@0,@0xFA,@64], @"vpsubq":@[@1,@1,@1,@1,@0xFB,@64],
                @"vpandd":@[@1,@1,@1,@0,@0xDB,@64], @"vpandq":@[@1,@1,@1,@1,@0xDB,@64],
                @"vpandnd":@[@1,@1,@1,@0,@0xDF,@64], @"vpandnq":@[@1,@1,@1,@1,@0xDF,@64],
                @"vpord":@[@1,@1,@1,@0,@0xEB,@64], @"vporq":@[@1,@1,@1,@1,@0xEB,@64],
                @"vpxord":@[@1,@1,@1,@0,@0xEF,@64], @"vpxorq":@[@1,@1,@1,@1,@0xEF,@64],
                @"vpmullw":@[@1,@1,@1,@0,@0xD5,@64], @"vpmuludq":@[@1,@1,@1,@1,@0xF4,@64],
                @"vpmaddwd":@[@1,@1,@1,@0,@0xF5,@64],
                @"vpunpcklbw":@[@1,@1,@1,@0,@0x60,@64], @"vpunpcklwd":@[@1,@1,@1,@0,@0x61,@64],
                @"vpunpckldq":@[@1,@1,@1,@0,@0x62,@64], @"vpunpcklqdq":@[@1,@1,@1,@1,@0x6C,@64],
                @"vpmaxsw":@[@1,@1,@1,@0,@0xEE,@64], @"vpminsw":@[@1,@1,@1,@0,@0xEA,@64],
                @"vpmaxub":@[@1,@1,@1,@0,@0xDE,@64], @"vpminub":@[@1,@1,@1,@0,@0xDA,@64],
                @"vpmulld":@[@1,@2,@1,@0,@0x40,@64], @"vpmullq":@[@1,@2,@1,@1,@0x40,@64],
                @"vpmaxsd":@[@1,@2,@1,@0,@0x3D,@64], @"vpminsd":@[@1,@2,@1,@0,@0x39,@64],
                @"vpmaxud":@[@1,@2,@1,@0,@0x3F,@64], @"vpminud":@[@1,@2,@1,@0,@0x3B,@64],
                @"vpmaxsq":@[@1,@2,@1,@1,@0x3D,@64], @"vpminsq":@[@1,@2,@1,@1,@0x39,@64],
                @"vpmaxuq":@[@1,@2,@1,@1,@0x3F,@64], @"vpminuq":@[@1,@2,@1,@1,@0x3B,@64],
                @"vpmaxsb":@[@1,@2,@1,@0,@0x3C,@64], @"vpminsb":@[@1,@2,@1,@0,@0x38,@64],
                @"vpmaxuw":@[@1,@2,@1,@0,@0x3E,@64], @"vpminuw":@[@1,@2,@1,@0,@0x3A,@64],
                @"vpmaddubsw":@[@1,@2,@1,@0,@0x04,@64],
                // 2: moves (the load opcode; the store is 7F for 6F, otherwise load + 1)
                @"vmovdqu32":@[@2,@1,@2,@0,@0x6F,@64], @"vmovdqu64":@[@2,@1,@2,@1,@0x6F,@64],
                @"vmovdqu8":@[@2,@1,@3,@0,@0x6F,@64], @"vmovdqu16":@[@2,@1,@3,@1,@0x6F,@64],
                @"vmovdqa32":@[@2,@1,@1,@0,@0x6F,@64], @"vmovdqa64":@[@2,@1,@1,@1,@0x6F,@64],
                @"vmovups":@[@2,@1,@0,@0,@0x10,@64], @"vmovupd":@[@2,@1,@1,@1,@0x10,@64],
                @"vmovaps":@[@2,@1,@0,@0,@0x28,@64], @"vmovapd":@[@2,@1,@1,@1,@0x28,@64],
                // 3: broadcasts (N = the element)
                @"vpbroadcastb":@[@3,@2,@1,@0,@0x78,@1], @"vpbroadcastw":@[@3,@2,@1,@0,@0x79,@2],
                @"vpbroadcastd":@[@3,@2,@1,@0,@0x58,@4], @"vpbroadcastq":@[@3,@2,@1,@1,@0x59,@8],
                @"vbroadcastss":@[@3,@2,@1,@0,@0x18,@4], @"vbroadcastsd":@[@3,@2,@1,@1,@0x19,@8],
                // 4: compares into an opmask
                @"vpcmpeqb":@[@4,@1,@1,@0,@0x74,@64], @"vpcmpgtb":@[@4,@1,@1,@0,@0x64,@64],
                @"vpcmpeqw":@[@4,@1,@1,@0,@0x75,@64], @"vpcmpgtw":@[@4,@1,@1,@0,@0x65,@64],
                @"vpcmpeqd":@[@4,@1,@1,@0,@0x76,@64], @"vpcmpgtd":@[@4,@1,@1,@0,@0x66,@64],
                @"vpcmpeqq":@[@4,@2,@1,@1,@0x29,@64], @"vpcmpgtq":@[@4,@2,@1,@1,@0x37,@64],
                // 5: compares with a predicate immediate
                @"vcmpps":@[@5,@1,@0,@0,@0xC2,@64], @"vcmppd":@[@5,@1,@1,@1,@0xC2,@64],
                @"vpcmpd":@[@5,@3,@1,@0,@0x1F,@64], @"vpcmpud":@[@5,@3,@1,@0,@0x1E,@64],
                @"vpcmpq":@[@5,@3,@1,@1,@0x1F,@64], @"vpcmpuq":@[@5,@3,@1,@1,@0x1E,@64],
                @"vpcmpb":@[@5,@3,@1,@0,@0x3F,@64], @"vpcmpub":@[@5,@3,@1,@0,@0x3E,@64],
                @"vpcmpw":@[@5,@3,@1,@1,@0x3F,@64], @"vpcmpuw":@[@5,@3,@1,@1,@0x3E,@64],
                // 6: opmask to vector
                @"vpmovm2b":@[@6,@2,@2,@0,@0x28,@0], @"vpmovm2w":@[@6,@2,@2,@1,@0x28,@0],
                @"vpmovm2d":@[@6,@2,@2,@0,@0x38,@0], @"vpmovm2q":@[@6,@2,@2,@1,@0x38,@0],
                // 7: shifts by an immediate (N holds the /ext)
                @"vpsrlw":@[@7,@1,@1,@0,@0x71,@2], @"vpsraw":@[@7,@1,@1,@0,@0x71,@4], @"vpsllw":@[@7,@1,@1,@0,@0x71,@6],
                @"vpsrld":@[@7,@1,@1,@0,@0x72,@2], @"vpsrad":@[@7,@1,@1,@0,@0x72,@4], @"vpslld":@[@7,@1,@1,@0,@0x72,@6],
                @"vpsrlq":@[@7,@1,@1,@1,@0x73,@2], @"vpsraq":@[@7,@1,@1,@1,@0x72,@4], @"vpsllq":@[@7,@1,@1,@1,@0x73,@6],
                // 8: extracts
                @"vextracti64x4":@[@8,@3,@1,@1,@0x3B,@32], @"vextractf64x4":@[@8,@3,@1,@1,@0x1B,@32],
                @"vextracti32x4":@[@8,@3,@1,@0,@0x39,@16], @"vextractf32x4":@[@8,@3,@1,@0,@0x19,@16],
                // 9: shuffles by an immediate
                @"vpshufd":@[@9,@1,@1,@0,@0x70,@64], @"vpshufhw":@[@9,@1,@2,@0,@0x70,@64],
                @"vpshuflw":@[@9,@1,@3,@0,@0x70,@64],
                // 10: three operands and an immediate
                @"vshufps":@[@10,@1,@0,@0,@0xC6,@64], @"vshufpd":@[@10,@1,@1,@1,@0xC6,@64],
                @"vpternlogd":@[@10,@3,@1,@0,@0x25,@64], @"vpternlogq":@[@10,@3,@1,@1,@0x25,@64],
                @"vinserti64x4":@[@10,@3,@1,@1,@0x3A,@32], @"vinsertf64x4":@[@10,@3,@1,@1,@0x1A,@32],
                // 12: unary
                @"vpabsb":@[@12,@2,@1,@0,@0x1C,@64], @"vpabsw":@[@12,@2,@1,@0,@0x1D,@64],
                @"vpabsd":@[@12,@2,@1,@0,@0x1E,@64], @"vpabsq":@[@12,@2,@1,@1,@0x1F,@64],
                @"vsqrtps":@[@12,@1,@0,@0,@0x51,@64], @"vsqrtpd":@[@12,@1,@1,@1,@0x51,@64],
                @"vcvtdq2ps":@[@12,@1,@0,@0,@0x5B,@64], @"vcvttps2dq":@[@12,@1,@2,@0,@0x5B,@64],
                @"vcvtps2dq":@[@12,@1,@1,@0,@0x5B,@64],
                @"vcvtps2pd":@[@12,@1,@0,@0,@0x5A,@32], @"vcvtpd2ps":@[@12,@1,@1,@1,@0x5A,@64],
                @"vcvttpd2dq":@[@12,@1,@1,@1,@0xE6,@64], @"vcvtdq2pd":@[@12,@1,@2,@0,@0xE6,@32],
                };
            });
            // A shift whose count is an xmm register, not an immediate: form 11.
            static NSDictionary *EX; static dispatch_once_t exonce;
            dispatch_once(&exonce, ^{
                EX = @{@"vpsrlw":@[@11,@1,@1,@0,@0xD1,@16], @"vpsraw":@[@11,@1,@1,@0,@0xE1,@16],
                       @"vpsllw":@[@11,@1,@1,@0,@0xF1,@16], @"vpsrld":@[@11,@1,@1,@0,@0xD2,@16],
                       @"vpsrad":@[@11,@1,@1,@0,@0xE2,@16], @"vpslld":@[@11,@1,@1,@0,@0xF2,@16],
                       @"vpsrlq":@[@11,@1,@1,@1,@0xD3,@16], @"vpsllq":@[@11,@1,@1,@1,@0xF3,@16]};
            });
            NSArray *e = E[mn];
            if (e && [e[0] intValue] == 7 && opCount == 3 && opv[2].kind != OpImm) e = EX[mn];
            if (!e) {
                if (error) *error = xerr(@"x86-64: no EVEX (zmm) form of '%@'", mn);
                CLEANUP(); return nil;
            }
            int form = [e[0] intValue], map = [e[1] intValue], pp = [e[2] intValue];
            int W = [e[3] intValue], op = [e[4] intValue], N = [e[5] intValue];
            XOperand *c = opCount > 2 ? &opv[2] : NULL;
            XOperand *dd = opCount > 3 ? &opv[3] : NULL;
            switch (form) {
            case 1: case 11:
                if (opCount != 3 || a->kind != OpReg || b->kind != OpReg || c->kind == OpImm) break;
                emitEvex(out, map, pp, W, a->reg, b->reg, c, 2); emit8(out, (uint8_t)op);
                emitModRMN(out, a->reg, c, N); CLEANUP(); return out;
            case 2: {
                if (opCount != 2) break;
                BOOL store = a->kind == OpMem;
                XOperand *regop = store ? b : a, *rmop = store ? a : b;
                if (regop->kind != OpReg) break;
                int sop = op == 0x6F ? 0x7F : op + 1;   // 6F/7F, 10/11, 28/29
                emitEvex(out, map, pp, W, regop->reg, -1, rmop, 2);
                emit8(out, (uint8_t)(store ? sop : op));
                emitModRMN(out, regop->reg, rmop, N); CLEANUP(); return out;
            }
            case 3: case 12:
                if (opCount != 2 || a->kind != OpReg) break;
                emitEvex(out, map, pp, W, a->reg, -1, b, 2); emit8(out, (uint8_t)op);
                emitModRMN(out, a->reg, b, N); CLEANUP(); return out;
            case 4:
                if (opCount != 3 || a->size != XK_SIZE || b->kind != OpReg || c->kind == OpImm) break;
                emitEvex(out, map, pp, W, a->reg, b->reg, c, 2); emit8(out, (uint8_t)op);
                emitModRMN(out, a->reg, c, N); CLEANUP(); return out;
            case 5:
                if (opCount != 4 || a->size != XK_SIZE || b->kind != OpReg || dd->kind != OpImm) break;
                emitEvex(out, map, pp, W, a->reg, b->reg, c, 2); emit8(out, (uint8_t)op);
                emitModRMN(out, a->reg, c, N); emit8(out, (uint8_t)dd->imm); CLEANUP(); return out;
            case 6:
                if (opCount != 2 || a->kind != OpReg || b->size != XK_SIZE) break;
                emitEvex(out, map, pp, W, a->reg, -1, b, 2); emit8(out, (uint8_t)op);
                emitModRM(out, a->reg, b); CLEANUP(); return out;
            case 7:
                if (opCount != 3 || a->kind != OpReg || c->kind != OpImm) break;
                emitEvex(out, map, pp, W, N, a->reg, b, 2); emit8(out, (uint8_t)op);
                emitModRMN(out, N, b, 64); emit8(out, (uint8_t)c->imm); CLEANUP(); return out;
            case 8:
                if (opCount != 3 || b->kind != OpReg || c->kind != OpImm) break;
                emitEvex(out, map, pp, W, b->reg, -1, a, 2); emit8(out, (uint8_t)op);
                emitModRMN(out, b->reg, a, N); emit8(out, (uint8_t)c->imm); CLEANUP(); return out;
            case 9:
                if (opCount != 3 || a->kind != OpReg || c->kind != OpImm) break;
                emitEvex(out, map, pp, W, a->reg, -1, b, 2); emit8(out, (uint8_t)op);
                emitModRMN(out, a->reg, b, N); emit8(out, (uint8_t)c->imm); CLEANUP(); return out;
            case 10:
                if (opCount != 4 || a->kind != OpReg || b->kind != OpReg || dd->kind != OpImm) break;
                emitEvex(out, map, pp, W, a->reg, b->reg, c, 2); emit8(out, (uint8_t)op);
                emitModRMN(out, a->reg, c, N); emit8(out, (uint8_t)dd->imm); CLEANUP(); return out;
            }
            if (error) *error = xerr(@"x86-64: '%@' with these operands has no EVEX (zmm) form", mn);
            CLEANUP(); return nil;
        }
    }
    if ([mn isEqualToString:@"vzeroupper"] && opCount == 0) {
        emit8(out, 0xC5); emit8(out, 0xF8); emit8(out, 0x77); CLEANUP(); return out;
    }
    {
        // mnemonic -> @[pp, map, load-opcode, store-opcode (0 = none)]
        static NSDictionary *vex2; static dispatch_once_t v2once;
        dispatch_once(&v2once, ^{
            vex2 = @{@"vmovdqu":@[@2,@1,@0x6F,@0x7F], @"vmovdqa":@[@1,@1,@0x6F,@0x7F],
                     @"vmovups":@[@0,@1,@0x10,@0x11], @"vmovaps":@[@0,@1,@0x28,@0x29],
                     @"vpbroadcastb":@[@1,@2,@0x78,@0], @"vpbroadcastw":@[@1,@2,@0x79,@0],
                     @"vpbroadcastd":@[@1,@2,@0x58,@0], @"vpbroadcastq":@[@1,@2,@0x59,@0],
                     @"vbroadcastss":@[@1,@2,@0x18,@0], @"vbroadcastsd":@[@1,@2,@0x19,@0],
                     @"vpabsb":@[@1,@2,@0x1C,@0], @"vpabsw":@[@1,@2,@0x1D,@0],
                     @"vpabsd":@[@1,@2,@0x1E,@0]};
        });
        NSArray *v2 = vex2[mn];
        if (v2 && opCount == 2 && a && b) {
            BOOL store = (a->kind == OpMem) && [v2[3] intValue] != 0;
            // Register to register from a high source into a low destination:
            // the store opcode puts the source in ModRM.reg, where VEX.R reaches
            // it, so the two-byte prefix still fits. clang picks the same form.
            if (!store && [v2[3] intValue] != 0 && a->kind == OpReg && b->kind == OpReg
                && (b->reg & 8) && !(a->reg & 8))
                store = YES;
            XOperand *regop = store ? b : a, *rmop = store ? a : b;
            int pp = [v2[0] intValue], map = [v2[1] intValue];
            int op = store ? [v2[3] intValue] : [v2[2] intValue];
            int L = (a->size == 32 || b->size == 32) ? 0x04 : 0;
            // A broadcast's L follows its DESTINATION (the source is always xmm/m).
            if ([mn hasPrefix:@"vpbroadcast"] || [mn hasPrefix:@"vbroadcasts"])
                L = a->size == 32 ? 0x04 : 0;
            int rr = regop->reg < 0 ? 0 : regop->reg;
            int bb = rmop->kind == OpReg ? rmop->reg : rmop->base;
            int xx = rmop->kind == OpReg ? 0 : rmop->index;
            bb = bb < 0 ? 0 : bb; xx = xx < 0 ? 0 : xx;
            if (map == 1 && !(xx & 8) && !(bb & 8)) {
                emit8(out, 0xC5);
                emit8(out, (uint8_t)(((rr & 8) ? 0 : 0x80) | (0x0F << 3) | L | pp));
            } else {
                emit8(out, 0xC4);
                emit8(out, (uint8_t)(((rr & 8) ? 0 : 0x80) | ((xx & 8) ? 0 : 0x40)
                                     | ((bb & 8) ? 0 : 0x20) | map));
                emit8(out, (uint8_t)((0x0F << 3) | L | pp));
            }
            emit8(out, (uint8_t)op);
            emitModRM(out, regop->reg, rmop);
            CLEANUP(); return out;
        }
        if (([mn isEqualToString:@"vextracti128"] || [mn isEqualToString:@"vextractf128"])
            && opCount == 3 && a && b && opv[2].kind == OpImm) {
            // VEX.256.66.0F3A 39 (19) /r ib: reg = the ymm source, r/m = the xmm dest.
            int rr = b->reg, bb = a->kind == OpReg ? a->reg : a->base;
            int xx = a->kind == OpReg ? 0 : a->index;
            bb = bb < 0 ? 0 : bb; xx = xx < 0 ? 0 : xx;
            emit8(out, 0xC4);
            emit8(out, (uint8_t)(((rr & 8) ? 0 : 0x80) | ((xx & 8) ? 0 : 0x40) | ((bb & 8) ? 0 : 0x20) | 3));
            emit8(out, (uint8_t)((0x0F << 3) | 0x04 | 1));
            emit8(out, [mn isEqualToString:@"vextracti128"] ? 0x39 : 0x19);
            emitModRM(out, rr, a);
            emit8(out, (uint8_t)opv[2].imm);
            CLEANUP(); return out;
        }
        if ([mn isEqualToString:@"vpshufd"] && opCount == 3 && a && b && opv[2].kind == OpImm) {
            // VEX.66.0F 70 /r ib, no first source.
            int L = a->size == 32 ? 0x04 : 0;
            int rr = a->reg, bb = b->kind == OpReg ? b->reg : b->base;
            int xx = b->kind == OpReg ? 0 : b->index;
            bb = bb < 0 ? 0 : bb; xx = xx < 0 ? 0 : xx;
            if (!(xx & 8) && !(bb & 8)) {
                emit8(out, 0xC5);
                emit8(out, (uint8_t)(((rr & 8) ? 0 : 0x80) | (0x0F << 3) | L | 1));
            } else {
                emit8(out, 0xC4);
                emit8(out, (uint8_t)(((rr & 8) ? 0 : 0x80) | ((xx & 8) ? 0 : 0x40) | ((bb & 8) ? 0 : 0x20) | 1));
                emit8(out, (uint8_t)((0x0F << 3) | L | 1));
            }
            emit8(out, 0x70);
            emitModRM(out, rr, b);
            emit8(out, (uint8_t)opv[2].imm);
            CLEANUP(); return out;
        }
        if ([mn isEqualToString:@"vshufps"] && opCount == 4 && a && b && opv[2].kind != OpImm && opv[3].kind == OpImm) {
            // VEX.NDS.0F C6 /r ib.
            XOperand *s2 = &opv[2];
            int L = (a->size == 32 || b->size == 32) ? 0x04 : 0;
            int rr = a->reg, vvvv = (~b->reg) & 0x0F;
            int bb = s2->kind == OpReg ? s2->reg : s2->base;
            int xx = s2->kind == OpReg ? 0 : s2->index;
            bb = bb < 0 ? 0 : bb; xx = xx < 0 ? 0 : xx;
            if (!(xx & 8) && !(bb & 8)) {
                emit8(out, 0xC5);
                emit8(out, (uint8_t)(((rr & 8) ? 0 : 0x80) | (vvvv << 3) | L | 0));
            } else {
                emit8(out, 0xC4);
                emit8(out, (uint8_t)(((rr & 8) ? 0 : 0x80) | ((xx & 8) ? 0 : 0x40) | ((bb & 8) ? 0 : 0x20) | 1));
                emit8(out, (uint8_t)((vvvv << 3) | L | 0));
            }
            emit8(out, 0xC6);
            emitModRM(out, rr, s2);
            emit8(out, (uint8_t)opv[3].imm);
            CLEANUP(); return out;
        }
        // mnemonic -> @[opcode, /ext]
        static NSDictionary *vexShiftI; static dispatch_once_t vsonce;
        dispatch_once(&vsonce, ^{
            vexShiftI = @{@"vpsrlw":@[@0x71,@2], @"vpsraw":@[@0x71,@4], @"vpsllw":@[@0x71,@6],
                          @"vpsrld":@[@0x72,@2], @"vpsrad":@[@0x72,@4], @"vpslld":@[@0x72,@6],
                          @"vpsrlq":@[@0x73,@2], @"vpsllq":@[@0x73,@6]};
        });
        NSArray *vs = vexShiftI[mn];
        if (vs && opCount == 3 && a && b && opv[2].kind == OpImm && b->kind == OpReg) {
            // VEX.NDD.66.0F <op> /ext ib: vvvv = the destination, r/m = the source.
            int L = a->size == 32 ? 0x04 : 0;
            int vvvv = (~a->reg) & 0x0F;
            int bb = b->reg;
            if (!(bb & 8)) {
                emit8(out, 0xC5);
                emit8(out, (uint8_t)(0x80 | (vvvv << 3) | L | 1));
            } else {
                emit8(out, 0xC4);
                emit8(out, (uint8_t)(0x80 | 0x40 | 0 | 1));
                emit8(out, (uint8_t)((vvvv << 3) | L | 1));
            }
            emit8(out, (uint8_t)[vs[0] intValue]);
            emit8(out, (uint8_t)(0xC0 | ([vs[1] intValue] << 3) | (bb & 7)));
            emit8(out, (uint8_t)opv[2].imm);
            CLEANUP(); return out;
        }
    }
    if ([mn hasPrefix:@"v"] && opCount == 3 && a && b) {
        NSString *base = [mn substringFromIndex:1];
        // The 0F map only, for now: the 0F38 table below is declared after this
        // point, and the vectoriser's VEX-worthy forms all live in sseRR. The
        // three-byte VEX form is written out regardless, because a high
        // register in the r/m or index field needs it whatever the map is.
        NSArray *vr = sseRR[base];
        int map = 1;
        // The 0F38 map: the SSE4.1 lane min/max and the 32-bit multiply, which
        // the 256-bit max/min reductions and i32 maps need.
        static NSDictionary *vex38; static dispatch_once_t v38once;
        dispatch_once(&v38once, ^{
            vex38 = @{@"pmaxsd":@[@0x66,@0x3D], @"pminsd":@[@0x66,@0x39],
                      @"pmaxud":@[@0x66,@0x3F], @"pminud":@[@0x66,@0x3B],
                      @"pmaxsb":@[@0x66,@0x3C], @"pminsb":@[@0x66,@0x38],
                      @"pmaxuw":@[@0x66,@0x3E], @"pminuw":@[@0x66,@0x3A],
                      @"pmulld":@[@0x66,@0x40],
                      // The u8 pair sum the 256-bit widening reductions use (bug 644).
                      @"pmaddubsw":@[@0x66,@0x04]};
        });
        if (!vr && vex38[base]) { vr = vex38[base]; map = 2; }
        XOperand *src1 = &opv[1];
        XOperand *src2 = &opv[2];
        // COMMUTE, when the operation allows it and it buys a byte. The
        // two-byte VEX form cannot express a high register in the r/m field, so
        // `vmulps xmm6, xmm7, xmm8` needs the three-byte form as written — but
        // multiplication does not care which source is which, and with the
        // sources swapped the high register moves into vvvv, which the short
        // form can hold. clang does this, so matching it is required for
        // byte-identity; ours came out five bytes against clang's four.
        //
        // Only for operations that really are commutative. NOT sub or div, and
        // NOT min/max: `minps a, b` returns b when either operand is NaN, so
        // swapping the sources changes the answer, and clang does not swap them
        // either.
        static NSSet *vexCommutes; static dispatch_once_t vconce;
        dispatch_once(&vconce, ^{
            vexCommutes = [NSSet setWithArray:@[@"addps", @"addpd", @"addss", @"addsd",
                                                @"mulps", @"mulpd", @"mulss", @"mulsd",
                                                @"andps", @"andpd", @"orps",  @"orpd",
                                                @"xorps", @"xorpd", @"pand",  @"por",
                                                @"pxor",  @"paddb", @"paddw", @"paddd",
                                                @"paddq", @"pmuludq", @"pmullw", @"pcmpeqb", @"pcmpeqw", @"pcmpeqd", @"pmaxsw", @"pminsw", @"pmaxub", @"pminub"]];
        });
        if (vr && [vexCommutes containsObject:base]
            && src1->kind == OpReg && src2->kind == OpReg
            && (src2->reg & 8) && !(src1->reg & 8)) {
            XOperand *t = src1; src1 = src2; src2 = t;
        }
        if (vr && src1->kind == OpReg && src2->kind != OpImm) {
            uint8_t pfx = (uint8_t)[vr[0] intValue];
            int pp = pfx == 0x66 ? 1 : pfx == 0xF3 ? 2 : pfx == 0xF2 ? 3 : 0;
            int rr = a->reg < 0 ? 0 : a->reg;
            int bb = src2->kind == OpReg ? src2->reg : src2->base;
            int xx = src2->kind == OpReg ? 0 : src2->index;
            bb = bb < 0 ? 0 : bb;
            xx = xx < 0 ? 0 : xx;
            int vvvv = (~src1->reg) & 0x0F;
            // VEX.L: 256-bit when the operands are ymm.
            int L = (a->size == 32 || src1->size == 32 || src2->size == 32) ? 0x04 : 0;
            if (map == 1 && !(xx & 8) && !(bb & 8)) {
                emit8(out, 0xC5);
                emit8(out, (uint8_t)(((rr & 8) ? 0 : 0x80) | (vvvv << 3) | L | pp));
            }
            else {
                emit8(out, 0xC4);
                emit8(out, (uint8_t)(((rr & 8) ? 0 : 0x80) | ((xx & 8) ? 0 : 0x40)
                                     | ((bb & 8) ? 0 : 0x20) | map));
                emit8(out, (uint8_t)((vvvv << 3) | L | pp));
            }
            emit8(out, (uint8_t)[vr[1] intValue]);
            emitModRM(out, a->reg, src2);
            CLEANUP(); return out;
        }
    }

    NSArray *sr = sseRR[mn];
    // b must NOT be an immediate. Four of these mnemonics (psrlw/psrld/psrlq
    // and psllq) ALSO have a shift-by-immediate form, handled below out of its
    // own table because the operands sit in the opposite ModRM fields. Without
    // this test `psrld xmm2, 2` matched here, and emitModRM encoded the literal
    // 2 as if it were a register operand: a silently WRONG encoding that
    // disassembled as garbage and segfaulted, rather than a refusal.
    if (sr && a && b && b->kind != OpImm) {
        uint8_t pfx = (uint8_t)[sr[0] intValue];
        if (pfx) emit8(out, pfx);
        emitRex(out, NO, a->reg, b->index, b->kind==OpReg?b->reg:b->base, NO);
        emit8(out, 0x0F); emit8(out, (uint8_t)[sr[1] intValue]);
        emitModRM(out, a->reg, b); CLEANUP(); return out;
    }

    // SSSE3 three-byte opcodes (66 0F 38 xx). Same operand shape as sseRR, one
    // more opcode byte. The vectoriser reaches these on the u8 widening path.
    static NSDictionary *sse38; static dispatch_once_t once38;
    dispatch_once(&once38, ^{
        sse38 = @{@"pabsb":@[@0x66,@0x1C], @"pabsw":@[@0x66,@0x1D], @"pabsd":@[@0x66,@0x1E],
                  @"phaddd":@[@0x66,@0x02], @"phaddw":@[@0x66,@0x01],
                  @"pmaddubsw":@[@0x66,@0x04],
                  // SSE4.1: the signed i32 lane maximum, which is what a
                  // `max` reduction over i32 lowers to (vectorize_maxmin).
                  @"pmaxsd":@[@0x66,@0x3D], @"pminsd":@[@0x66,@0x39]};
    });
    NSArray *s38 = sse38[mn];
    if (s38 && a && b && b->kind != OpImm) {
        uint8_t pfx = (uint8_t)[s38[0] intValue];
        if (pfx) emit8(out, pfx);
        emitRex(out, NO, a->reg, b->index, b->kind==OpReg?b->reg:b->base, NO);
        emit8(out, 0x0F); emit8(out, 0x38); emit8(out, (uint8_t)[s38[1] intValue]);
        emitModRM(out, a->reg, b); CLEANUP(); return out;
    }

    // Shift a vector by an IMMEDIATE: 66 0F <op> /<ext> ib. The register being
    // shifted goes in the r/m field and the opcode extension in reg — the
    // reverse of every form above, which is why it cannot share their table.
    static NSDictionary *sseShiftI; static dispatch_once_t onceSI;
    dispatch_once(&onceSI, ^{
        // mnemonic -> @[opcode, /ext]
        sseShiftI = @{@"psrlw":@[@0x71,@2], @"psraw":@[@0x71,@4], @"psllw":@[@0x71,@6],
                      @"psrld":@[@0x72,@2], @"psrad":@[@0x72,@4], @"pslld":@[@0x72,@6],
                      @"psrlq":@[@0x73,@2], @"psllq":@[@0x73,@6]};
    });
    NSArray *si = sseShiftI[mn];
    if (si && a && b && a->kind == OpReg && b->kind == OpImm) {
        emit8(out, 0x66);
        emitRex(out, NO, 0, -1, a->reg, NO);
        emit8(out, 0x0F); emit8(out, (uint8_t)[si[0] intValue]);
        emit8(out, (uint8_t)(0xC0 | (([si[1] intValue] & 7) << 3) | (a->reg & 7)));
        emit8(out, (uint8_t)(b->imm & 0xFF));
        CLEANUP(); return out;
    }

    // shufps/shufpd xmm, xmm/m, imm8 — reg/rm plus a trailing selector byte.
    if (([mn isEqualToString:@"shufps"] || [mn isEqualToString:@"shufpd"])
        && a && b && c && c->kind == OpImm) {
        if ([mn isEqualToString:@"shufpd"]) emit8(out, 0x66);
        emitRex(out, NO, a->reg, b->index, b->kind==OpReg?b->reg:b->base, NO);
        emit8(out, 0x0F); emit8(out, 0xC6);
        emitModRM(out, a->reg, b);
        emit8(out, (uint8_t)(c->imm & 0xFF));
        CLEANUP(); return out;
    }

    // cmpps/cmppd xmm, xmm/m, imm8 — the same shape, opcode C2; the imm8 is the
    // predicate (3 = unordered: a lane holding a NaN).
    if (([mn isEqualToString:@"cmpps"] || [mn isEqualToString:@"cmppd"])
        && a && b && c && c->kind == OpImm) {
        if ([mn isEqualToString:@"cmppd"]) emit8(out, 0x66);
        emitRex(out, NO, a->reg, b->index, b->kind==OpReg?b->reg:b->base, NO);
        emit8(out, 0x0F); emit8(out, 0xC2);
        emitModRM(out, a->reg, b);
        emit8(out, (uint8_t)(c->imm & 0xFF));
        CLEANUP(); return out;
    }

    // movss/movsd/movdqu/movdqa — direction picks the opcode (load vs store).
    static NSDictionary *sseMov; static dispatch_once_t monce;
    dispatch_once(&monce, ^{
        // mnemonic -> @[prefix, loadOp, storeOp]
        sseMov = @{@"movss":@[@0xF3,@0x10,@0x11], @"movsd":@[@0xF2,@0x10,@0x11],
                   @"movups":@[@0x00,@0x10,@0x11],@"movaps":@[@0x00,@0x28,@0x29],
                   @"movdqu":@[@0xF3,@0x6F,@0x7F],@"movdqa":@[@0x66,@0x6F,@0x7F],
                   @"movupd":@[@0x66,@0x10,@0x11],@"movapd":@[@0x66,@0x28,@0x29]};
    });
    NSArray *sm = sseMov[mn];
    if (sm && a && b) {
        uint8_t pfx = (uint8_t)[sm[0] intValue];
        BOOL store = (a->kind == OpMem);            // [mem], xmm  -> store form
        XOperand *rmOp  = store ? a : b;
        int regField    = store ? b->reg : a->reg;
        if (pfx) emit8(out, pfx);
        emitRex(out, NO, regField, rmOp->index, rmOp->kind==OpReg?rmOp->reg:rmOp->base, NO);
        emit8(out, 0x0F); emit8(out, (uint8_t)[sm[store?2:1] intValue]);
        emitModRM(out, regField, rmOp); CLEANUP(); return out;
    }

    // cvtsi2ss/sd (xmm <- GP) and cvttss2si/cvttsd2si (GP <- xmm): REX.W follows
    // the GP operand's width, and sits AFTER the mandatory prefix.
    static NSDictionary *sseCvt; static dispatch_once_t conce;
    dispatch_once(&conce, ^{
        // mnemonic -> @[prefix, opcode, gpIsSrc]
        sseCvt = @{@"cvtsi2ss":@[@0xF3,@0x2A,@1], @"cvtsi2sd":@[@0xF2,@0x2A,@1],
                   @"cvttss2si":@[@0xF3,@0x2C,@0],@"cvttsd2si":@[@0xF2,@0x2C,@0],
                   @"cvtss2si":@[@0xF3,@0x2D,@0], @"cvtsd2si":@[@0xF2,@0x2D,@0]};
    });
    NSArray *sc = sseCvt[mn];
    if (sc && a && b) {
        BOOL gpIsSrc = [sc[2] boolValue];
        XOperand *gp = gpIsSrc ? b : a;
        emit8(out, (uint8_t)[sc[0] intValue]);
        emitRex(out, gp->size == 8, a->reg, b->index, b->kind==OpReg?b->reg:b->base, NO);
        emit8(out, 0x0F); emit8(out, (uint8_t)[sc[1] intValue]);
        emitModRM(out, a->reg, b); CLEANUP(); return out;
    }

    // pshufd / pshuflw / pshufhw  xmm, xmm/m, imm8
    static NSDictionary *sseShuf; static dispatch_once_t shonce;
    dispatch_once(&shonce, ^{ sseShuf = @{@"pshufd":@0x66, @"pshuflw":@0xF2, @"pshufhw":@0xF3}; });
    NSNumber *shp = sseShuf[mn];
    if (shp && a && b && opCount == 3) {
        emit8(out, (uint8_t)shp.intValue);
        emitRex(out, NO, a->reg, b->index, b->kind==OpReg?b->reg:b->base, NO);
        emit8(out, 0x0F); emit8(out, 0x70);
        emitModRM(out, a->reg, b);
        emit8(out, (uint8_t)opv[2].imm); CLEANUP(); return out;
    }

    // pmulld — a 3-byte opcode (66 0F 38 40)
    if ([mn isEqualToString:@"pmulld"] && a && b) {
        emit8(out, 0x66);
        emitRex(out, NO, a->reg, b->index, b->kind==OpReg?b->reg:b->base, NO);
        emit8(out, 0x0F); emit8(out, 0x38); emit8(out, 0x40);
        emitModRM(out, a->reg, b); CLEANUP(); return out;
    }

    // movd/movq between an xmm and a GP reg/mem (66 0F 6E load / 7E store)
    if (([mn isEqualToString:@"movd"] || [mn isEqualToString:@"movq"]) && a && b
        && (a->size == 16 || b->size == 16)) {
        BOOL toXmm = (a->size == 16);
        XOperand *xmm = toXmm ? a : b, *other = toXmm ? b : a;
        emit8(out, 0x66);
        emitRex(out, [mn isEqualToString:@"movq"], xmm->reg, other->index,
                other->kind==OpReg?other->reg:other->base, NO);
        emit8(out, 0x0F); emit8(out, toXmm ? 0x6E : 0x7E);
        emitModRM(out, xmm->reg, other); CLEANUP(); return out;
    }

    // ── SSE compares: cmp<pred><sd|ss|pd|ps> xmm, xmm/m  (0F C2 /r ib) ──
    // The predicate is spelled in the mnemonic and encoded as the trailing imm8.
    if ([mn hasPrefix:@"cmp"] && mn.length > 5 && a && b && a->kind == OpReg && a->size == 16) {
        static NSDictionary *pred, *sfx; static dispatch_once_t cmpconce;
        dispatch_once(&cmpconce, ^{
            pred = @{@"eq":@0, @"lt":@1, @"le":@2, @"unord":@3,
                     @"neq":@4, @"nlt":@5, @"nle":@6, @"ord":@7};
            sfx  = @{@"sd":@0xF2, @"ss":@0xF3, @"pd":@0x66, @"ps":@0x00};
        });
        NSString *tail = [mn substringFromIndex:mn.length-2];
        NSNumber *pfx2 = sfx[tail];
        NSNumber *pv = pfx2 ? pred[[mn substringWithRange:NSMakeRange(3, mn.length-5)]] : nil;
        if (pv) {
            if (pfx2.intValue) emit8(out, (uint8_t)pfx2.intValue);
            emitRex(out, NO, a->reg, b->index, b->kind==OpReg?b->reg:b->base, NO);
            emit8(out, 0x0F); emit8(out, 0xC2);
            emitModRM(out, a->reg, b);
            emit8(out, (uint8_t)pv.intValue); CLEANUP(); return out;
        }
    }

    // ── cmovcc r, r/m ──
    if ([mn hasPrefix:@"cmov"] && a && b && ccCode([mn substringFromIndex:4]) >= 0) {
        emitRex(out, w, a->reg, b->index, b->kind==OpReg?b->reg:b->base, NO);
        emit8(out, 0x0F); emit8(out, (uint8_t)(0x40 + ccCode([mn substringFromIndex:4])));
        emitModRM(out, a->reg, b); CLEANUP(); return out;
    }

    // ── imul r, r/m, imm  (three-operand: 6B /r ib or 69 /r id) ──
    if ([mn isEqualToString:@"imul"] && opCount == 3 && a && b) {
        int64_t iv = opv[2].imm;
        BOOL imm8 = (signedForOperandSize(iv, osz) >= -128
                     && signedForOperandSize(iv, osz) <= 127);
        emitRex(out, w, a->reg, b->index, b->kind==OpReg?b->reg:b->base, NO);
        emit8(out, imm8 ? 0x6B : 0x69);
        emitModRM(out, a->reg, b);
        if (imm8) emit8(out, (uint8_t)iv); else emit32(out, (uint32_t)iv);
        CLEANUP(); return out;
    }

    CLEANUP();
    if (error) *error = xerr(@"unhandled mnemonic '%@'", mn);
    return nil;
}

- (void)recordRel32:(NSString *)sym at:(NSUInteger)off {
    if (!sym) return;
    if (!_fixups) _fixups = [NSMutableArray array];
    XAX86_64Fixup *f = [XAX86_64Fixup new];
    f.offset = _insnBase + off; f.kind = XAX86FixupRel32; f.symbol = sym; f.addend = -4;
    [_fixups addObject:f];
}

// ─────────────────────────── whole-file assembly ───────────────────────────
// Strip a `#` or `//` comment, honouring double quotes so a `#` inside a string
// survives. (The x86_64 backend emits `#` comments; clang's own output uses both.)
static NSString *stripAsmComment(NSString *l) {
    BOOL inq = NO;
    for (NSUInteger i = 0; i < l.length; i++) {
        unichar c = [l characterAtIndex:i];
        if (c == '"') { inq = !inq; continue; }
        if (inq) continue;
        if (c == '#') return [l substringToIndex:i];
        if (c == '/' && i+1 < l.length && [l characterAtIndex:i+1] == '/')
            return [l substringToIndex:i];
    }
    return l;
}

// Split a directive's operand list on top-level commas (quotes respected).
static NSArray<NSString *> *splitDirectiveOps(NSString *rest) {
    NSMutableArray *out = [NSMutableArray array];
    BOOL inq = NO; NSUInteger st = 0;
    for (NSUInteger i = 0; i < rest.length; i++) {
        unichar c = [rest characterAtIndex:i];
        if (c == '"') inq = !inq;
        else if (c == ',' && !inq) { [out addObject:[rest substringWithRange:NSMakeRange(st, i-st)]]; st = i+1; }
    }
    if (st <= rest.length) [out addObject:[rest substringFromIndex:st]];
    NSMutableArray *trimmed = [NSMutableArray array];
    for (NSString *t in out) {
        NSString *s = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (s.length) [trimmed addObject:s];
    }
    return trimmed;
}

// A `.quad`/`.8byte` operand that names a symbol rather than a number — a vtable
// slot, say. It becomes eight zero bytes plus an absolute-64 fixup.
static BOOL isSymbolOperand(NSString *t) {
    if (!t.length) return NO;
    int64_t v; if (parseNum(t, &v)) return NO;
    unichar c = [t characterAtIndex:0];
    return c=='_' || c=='.' || (c>='A'&&c<='Z') || (c>='a'&&c<='z');
}

// The right-hand side of a `name = expr` symbol assignment, restricted to a
// plain integer literal. Deliberately NOT parseNum: the ported assembler has to
// make the identical accept/reject call (selfhost/asm/X86_64.xc), and one
// spelled-out rule is easier to hold in step than two number parsers.
static BOOL isPlainIntLiteral(NSString *s) {
    if (!s.length) return NO;
    NSUInteger i = 0;
    unichar c0 = [s characterAtIndex:0];
    if (c0 == '+' || c0 == '-') i = 1;
    BOOL hex = (s.length > i+1 && [s characterAtIndex:i] == '0'
                && ([s characterAtIndex:i+1] == 'x' || [s characterAtIndex:i+1] == 'X'));
    if (hex) i += 2;
    if (i >= s.length) return NO;
    for (; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL dig = (c >= '0' && c <= '9');
        BOOL hd  = hex && ((c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'));
        if (!dig && !hd) return NO;
    }
    return YES;
}

- (nullable NSData *)assemble:(NSString *)source error:(NSError **)error {
    _fixups = [NSMutableArray array];
    _symbols = [NSMutableDictionary dictionary];
    _data = [NSMutableData data];
    _dataSymbolNames = [NSMutableSet set];
    _globalNames = [NSMutableSet set];
    _commonSymbols = [NSMutableDictionary dictionary];
    NSMutableData *text = [NSMutableData data];

    // x86-64 is variable-length, but every symbolic reference the backend emits
    // is a fixed-width field — rel32 for branches, disp32 for RIP-relative
    // operands, a full quad in data. Instruction sizes therefore do NOT depend on
    // symbol values, so ONE pass suffices: encode straight through with zeroed
    // fields and record a fixup, rather than iterating to a fixed point the way a
    // branch-relaxing assembler must.
    int section = 0;                            // 0 = text, 1 = data (.data/.rodata), 2 = bss
    // `.bss` content is zero and goes LAST in the data blob (bug 642): the
    // PE writer leaves a trailing run of zeros out of the file, which it
    // cannot do for zeros that sit between the module's data and the runtime's.
    // Collected here, appended after everything else once the pass is done.
    NSMutableData *bss = [NSMutableData data];
    NSMutableArray<NSString *> *bssLabels = [NSMutableArray array];
    XTDwarfWriter *dwarf = nil;                 // -g: the line table, if the text has one
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];

    // CodeView debug sections (`.section .debug$S`) contribute nothing to the
    // image, and their contents are not instructions or plain data — they use
    // label ARITHMETIC (`.long .Ltmp1-.Ltmp0` for a subsection size) that this
    // assembler has no expression evaluator for. Worse, an unrecognised section
    // used to fall through to `section = 1`, so every CodeView byte was appended
    // to __data. #1083 regenerated the win64 runtime WITH debug info, and this
    // is where the link started failing. Skip such a section until the next one.
    BOOL skipping = NO;

    for (NSString *raw in [source componentsSeparatedByString:@"\n"]) {
        NSString *l = [stripAsmComment(raw) stringByTrimmingCharactersInSet:ws];
        if (!l.length) continue;

        if (skipping) {
            // Only a section change can end the skip; everything else is
            // debug payload, labels included.
            if (!([l hasPrefix:@".section"] || [l hasPrefix:@".text"] ||
                  [l hasPrefix:@".data"]    || [l hasPrefix:@".bss"])) continue;
            skipping = NO;
        }

        if ([l hasPrefix:@"."] && ![l hasSuffix:@":"]) {
            NSRange sp = [l rangeOfCharacterFromSet:ws];
            NSString *d = sp.location==NSNotFound ? l : [l substringToIndex:sp.location];
            NSString *rest = sp.location==NSNotFound ? @"" :
                [[l substringFromIndex:sp.location] stringByTrimmingCharactersInSet:ws];

            if ([d isEqualToString:@".text"])    { section = 0; continue; }
            if ([d isEqualToString:@".data"]) { section = 1; continue; }
            if ([d isEqualToString:@".bss"])  { section = 2; continue; }
            // -g: `.file <n> "<path>"` and `.loc <n> <line> [<col>]` are the line
            // table, recorded against the text offset they precede.
            // -g: `.xc_var "<name>" <reg> <offset> "<type>"` — a variable of the
            // function being assembled, for the debug information.
            if ([d isEqualToString:@".xc_var"] || [d isEqualToString:@".xc_param"]) {
                NSArray<NSString *> *q = [rest componentsSeparatedByString:@"\""];
                if (q.count >= 5) {
                    NSScanner *sc = [NSScanner scannerWithString:q[2]];
                    int reg = 0; long long off = 0;
                    if ([sc scanInt:&reg] && [sc scanLongLong:&off]) {
                        if (!dwarf) dwarf = [[XTDwarfWriter alloc] init];
                        [dwarf addVariable:q[1] atOffset:text.length register:(uint8_t)reg offset:off type:q[3]
                                 parameter:[d isEqualToString:@".xc_param"]];
                    }
                }
                continue;
            }
            if ([d isEqualToString:@".file"] || [d isEqualToString:@".loc"]) {
                NSScanner *sc = [NSScanner scannerWithString:rest];
                int fileNo = 0, lineNo = 0, colNo = 0;
                if (![sc scanInt:&fileNo]) continue;
                if (!dwarf) dwarf = [[XTDwarfWriter alloc] init];
                if ([d isEqualToString:@".file"]) {
                    NSRange q1 = [rest rangeOfString:@"\""], q2 = [rest rangeOfString:@"\"" options:NSBackwardsSearch];
                    if (q1.location != NSNotFound && q2.location > q1.location)
                        [dwarf setFile:(uint32_t)fileNo
                                  path:[rest substringWithRange:NSMakeRange(q1.location + 1, q2.location - q1.location - 1)]];
                } else if (section == 0 && [sc scanInt:&lineNo]) {
                    [sc scanInt:&colNo];
                    [dwarf addRowAtOffset:text.length file:(uint32_t)fileNo line:(uint32_t)lineNo column:(uint32_t)colNo];
                }
                continue;
            }
            if ([d isEqualToString:@".section"]) {
                if ([rest hasPrefix:@".debug"]) { skipping = YES; continue; }
                section = [rest hasPrefix:@".text"] ? 0 : ([rest hasPrefix:@".bss"] ? 2 : 1); continue;
            }
            if ([d isEqualToString:@".globl"] || [d isEqualToString:@".global"]) {
                // Carries no bytes, but names what a shared object exports.
                for (NSString *n in splitDirectiveOps(rest)) [_globalNames addObject:n];
                continue;
            }
            if ([d isEqualToString:@".comm"] || [d isEqualToString:@".lcomm"]) {
                // `.comm name, size, align` — a COMMON (C tentative def): recorded
                // as external-undefined-with-size so the LINKER gives ONE slot every
                // unit binds to (mergeable across objects). `.lcomm` is the LOCAL
                // form — private storage in this object, materialised here. A
                // single-unit image demotes its commons to local data before the
                // write (demoteCommonsToLocalData).
                NSArray<NSString *> *cops = splitDirectiveOps(rest);
                if (cops.count < 2) continue;
                int64_t sz = 0, alg = 0;
                parseNum(cops[1], &sz);
                if (cops.count > 2) parseNum(cops[2], &alg);
                if ([d isEqualToString:@".comm"]) {
                    _commonSymbols[cops[0]] = @[@(sz), @(alg > 0 ? alg : 1)];
                    continue;
                }
                if (alg > 1) { while (_data.length % (uint64_t)alg) emit8(_data, 0); }
                _symbols[cops[0]] = @(_data.length);
                [_dataSymbolNames addObject:cops[0]];
                for (int64_t i = 0; i < sz; i++) emit8(_data, 0);
                continue;
            }
            // Debug and type annotations carry no bytes at all.
            if ([d isEqualToString:@".type"]  || [d isEqualToString:@".size"] ||
                [d isEqualToString:@".intel_syntax"] || [d isEqualToString:@".file"] ||
                [d isEqualToString:@".ident"] || [d isEqualToString:@".local"]) continue;

            if ([d isEqualToString:@".p2align"] || [d isEqualToString:@".align"]) {
                int64_t n = 0; parseNum(splitDirectiveOps(rest).firstObject ?: @"0", &n);
                // .align is byte-granular on some assemblers but the backend only
                // ever emits .p2align; treat both as a power of two.
                uint64_t a = 1ull << n;
                if (section == 0)      { while (text.length % a) emit8(text, 0x90); }   // nop-pad code
                else if (section == 2) { while (bss.length % a) emit8(bss, 0); }
                else                   { while (_data.length % a) emit8(_data, 0); }
                continue;
            }

            NSMutableData *sec = (section == 0) ? text : (section == 2 ? bss : _data);
            NSArray<NSString *> *ops = splitDirectiveOps(rest);
            if ([d isEqualToString:@".zero"] || [d isEqualToString:@".space"]) {
                int64_t n = 0, fill = 0;
                if (ops.count) parseNum(ops[0], &n);
                if (ops.count > 1) parseNum(ops[1], &fill);
                for (int64_t i = 0; i < n; i++) emit8(sec, (uint8_t)fill);
                continue;
            }
            int width = 0;
            if ([d isEqualToString:@".byte"]) width = 1;
            else if ([d isEqualToString:@".short"] || [d isEqualToString:@".hword"] ||
                     [d isEqualToString:@".2byte"]) width = 2;
            else if ([d isEqualToString:@".long"] || [d isEqualToString:@".word"] ||
                     [d isEqualToString:@".4byte"]) width = 4;
            else if ([d isEqualToString:@".quad"] || [d isEqualToString:@".8byte"]) width = 8;
            else if ([d isEqualToString:@".ascii"] || [d isEqualToString:@".asciz"] ||
                     [d isEqualToString:@".string"]) {
                NSRange q1 = [rest rangeOfString:@"\""], q2 = [rest rangeOfString:@"\"" options:NSBackwardsSearch];
                if (q1.location == NSNotFound || q2.location <= q1.location) {
                    if (error) *error = xerr(@"bad string in '%@'", l); return nil; }
                NSString *s = [rest substringWithRange:NSMakeRange(q1.location+1, q2.location-q1.location-1)];
                for (NSUInteger i = 0; i < s.length; i++) {
                    unichar c = [s characterAtIndex:i];
                    if (c == '\\' && i+1 < s.length) { unichar n = [s characterAtIndex:++i];
                        c = n=='n'?'\n': n=='t'?'\t': n=='r'?'\r': n=='0'?0: n; }
                    emit8(sec, (uint8_t)c);
                }
                if (![d isEqualToString:@".ascii"]) emit8(sec, 0);
                continue;
            }
            if (!width) continue;                       // unknown directive: no bytes
            for (NSString *t in ops) {
                if (width == 8 && isSymbolOperand(t)) {  // .quad <symbol>
                    // The writer tells a data fixup from a text one by KIND alone
                    // (Abs64 = data), so a symbolic .quad in __text would have its
                    // offset read against the wrong section and patch a random
                    // address. The backend only ever emits these in .rodata; say
                    // so rather than let it corrupt silently if that changes.
                    if (section != 1) {
                        if (error) *error = xerr(@"'%@' outside the data section: a symbolic "
                                                  @".quad is only supported in data", l);
                        return nil;
                    }
                    XAX86_64Fixup *f = [XAX86_64Fixup new];
                    f.offset = sec.length; f.kind = XAX86FixupAbs64; f.symbol = t; f.addend = 0;
                    [_fixups addObject:f];
                    for (int i = 0; i < 8; i++) emit8(sec, 0);
                    continue;
                }
                int64_t v = 0;
                if (!parseNum(t, &v)) { if (error) *error = xerr(@"bad data value '%@' in '%@'", t, l); return nil; }
                for (int i = 0; i < width; i++) emit8(sec, (uint8_t)(v >> (8*i)));
            }
            continue;
        }

        if ([l hasSuffix:@":"]) {
            NSString *lbl = [l substringToIndex:l.length-1];
            // Silently letting a redefinition win produced code that assembled,
            // linked and jumped into the wrong function: two clang-generated
            // runtime files both used `.LBB0_1`, and every branch in the first
            // one landed in the second. Whoever concatenated them has to fix it.
            if (_symbols[lbl]) {
                if (error) *error = xerr(@"symbol '%@' defined twice — if this is a "
                                          @"concatenation of separately compiled files, "
                                          @"their local labels need namespacing", lbl);
                return nil;
            }
            if (section == 0) _symbols[lbl] = @(text.length);
            else if (section == 2) { _symbols[lbl] = @(bss.length); [bssLabels addObject:lbl]; } // rebased below
            else { _symbols[lbl] = @(_data.length); [_dataSymbolNames addObject:lbl]; }
            continue;
        }

        // `name = expr` — the OTHER spelling of `.set name, expr`, which clang
        // emits for the COFF feature symbol (`@feat.00 = 0`). An unknown
        // directive carries no bytes and defines no symbol (see `if (!width)`
        // above), so `.set` is already ignored; this spelling has to be ignored
        // identically or the two disagree. It reached the mnemonic path instead,
        // where `@feat.00` read as an opcode — and because a link failure counts
        // as an ORACLE failure, ldwin-diff went to 0 compared / 785 skipped while
        // still printing `ok`. The Win64 writer was uncovered from #1083 to here.
        //
        // Only a plain integer is safe to drop. A symbol ALIAS (`a = b`) really
        // does need defining, and quietly discarding one would mis-link rather
        // than fail, so that stays an error until something needs it.
        NSRange eqr = [l rangeOfString:@"="];
        if (eqr.location != NSNotFound) {
            NSString *nm = [[l substringToIndex:eqr.location]
                             stringByTrimmingCharactersInSet:ws];
            NSString *rv = [[l substringFromIndex:NSMaxRange(eqr)]
                             stringByTrimmingCharactersInSet:ws];
            if (nm.length && isPlainIntLiteral(rv)) continue;
            if (error) *error = xerr(@"symbol assignment '%@' is not a plain "
                                      @"integer — an alias needs a real definition", l);
            return nil;
        }

        if (section != 0) {   // a stray non-label line in data is a bare directive
            if (error) *error = xerr(@"unexpected line in data section: '%@'", l);
            return nil;
        }
        NSError *e = nil;
        _insnBase = text.length;
        NSData *bytes = [self encodeOne:l error:&e];
        if (!bytes) {
            if (error) *error = xerr(@"line '%@': %@", l,
                                     e ? e.localizedDescription : @"unencodable");
            return nil;
        }
        [text appendData:bytes];
        // -g: rbp now addresses the saved rbp and the return address above it,
        // so the call frame is rbp + 16 from here.
        if ([l hasPrefix:@"mov"] && [l hasSuffix:@"rbp, rsp"]) {
            if (!dwarf) dwarf = [[XTDwarfWriter alloc] init];
            [dwarf addFrameSetupAtOffset:text.length frameSize:16];
        }
    }
    if (dwarf.hasRows) [XTDwarfWriter setPending:dwarf];

    // The bss, after all the data (bug 642): its labels become data symbols at
    // their final offsets. Before the branch resolution below, which must see
    // them as data.
    if (bss.length) {
        while (_data.length % 16) emit8(_data, 0);
        uint64_t base = _data.length;
        [_data appendData:bss];
        for (NSString *lbl in bssLabels) {
            _symbols[lbl] = @(base + _symbols[lbl].unsignedLongLongValue);
            [_dataSymbolNames addObject:lbl];
        }
    }

    // Resolve text-local branches here — a `call`/`jcc` to a label in this same
    // __text needs no relocation, and leaving it to the writer would mean every
    // consumer re-deriving what we already know. Everything else (data
    // references, imports, .quad pointers) needs final addresses and stays a fixup.
    NSMutableArray<XAX86_64Fixup *> *unresolved = [NSMutableArray array];
    uint8_t *tp = text.mutableBytes;
    for (XAX86_64Fixup *f in _fixups) {
        NSNumber *target = _symbols[f.symbol];
        if (f.kind == XAX86FixupRel32 && target && ![_dataSymbolNames containsObject:f.symbol]) {
            int64_t rel = (int64_t)target.unsignedLongLongValue - (int64_t)f.offset + f.addend;
            for (int i = 0; i < 4; i++) tp[f.offset + i] = (uint8_t)((uint64_t)rel >> (8*i));
            continue;
        }
        [unresolved addObject:f];
    }
    _fixups = unresolved;
    return text;
}
@end
