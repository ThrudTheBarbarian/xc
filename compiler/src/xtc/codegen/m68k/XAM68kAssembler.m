/****************************************************************************\
|* XAM68kAssembler.m — see header. Minimal two-pass 68k assembler → $601A.
\****************************************************************************/
#import "XAM68kAssembler.h"

// ── Operand model ───────────────────────────────────────────────────────
typedef enum
{
    OP_DREG,
    OP_AREG,
    OP_IMM,
    OP_IND,
    OP_INDDISP,
    OP_PREDEC,
    OP_POSTINC,
    OP_ABS,
    OP_PCDISP,
    OP_FREG,
    OP_INDEX,
    OP_NONE
} OpKind;

typedef struct
    {
    OpKind kind;
    int reg;    // 0-7 for data/addr registers (base An for OP_INDEX)
    long value; // immediate / displacement / absolute value
    BOOL isSym; // value resolves from `sym`
    // A mangled label is `.<Class>$<method>__<params>$bb_<n>_<tag>` and runs
    // long: 89 chars in xtld64.xc today. This was 80, and `strncpy(…, 79)`
    // silently TRUNCATED anything longer, so the use no longer matched its
    // definition, `symVal` handed back 0 for the miss, and every `bra` to an
    // 80+-char label in `MachO.executable` jumped to offset 0 — 128 bytes
    // wrong in a 381 KB image, found by `as68-diff` (the port, holding names
    // in a String, resolved them). Copy through `copySym`, which refuses
    // rather than truncates: a limit that fails loudly is a limit; one that
    // clips is a miscompile.
    char sym[256];
    // OP_INDEX — (d8,An,Xn.SIZE*SCALE), 68020 brief extension word:
    int idxReg;     // index register Xn
    BOOL idxIsAddr; // Xn is an address register (else data)
    BOOL idxLong;   // .l (else .w, sign-extended)
    int scale;      // 0/1/2/3 → ×1/×2/×4/×8
    } Op;

// ── Number / register parsing ───────────────────────────────────────────
static long parseNum(NSString* s, BOOL* ok)
    {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    long sign = 1;
    if ([s hasPrefix:@"-"])
        {
        sign = -1;
        s = [s substringFromIndex:1];
        }
    else if ([s hasPrefix:@"+"])
        {
        s = [s substringFromIndex:1];
        }
    const char* c = s.UTF8String;
    char* end = NULL;
    long v;
    if (s.length == 0)
        {
        *ok = NO;
        return 0;
        }
    if ([s hasPrefix:@"$"])
        v = strtol(c + 1, &end, 16);
    else if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"])
        v = strtol(c + 2, &end, 16);
    else if ([s hasPrefix:@"%"])
        v = strtol(c + 1, &end, 2);
    else
        v = strtol(c, &end, 10);
    *ok = (end && *end == 0);
    return sign * v;
    }

// Returns YES and fills *reg/*isAddr for d0-d7/a0-a7/sp; NO otherwise.
static BOOL parseReg(NSString* s, int* reg, BOOL* isAddr)
    {
    s = [s.lowercaseString stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
    if ([s isEqualToString:@"sp"])
        {
        *reg = 7;
        *isAddr = YES;
        return YES;
        }
    if (s.length == 2 && (([s hasPrefix:@"d"] && (*isAddr = NO, 1)) ||
                          ([s hasPrefix:@"a"] && (*isAddr = YES, 1))))
        {
        unichar d = [s characterAtIndex:1];
        if (d >= '0' && d <= '7')
            {
            *reg = d - '0';
            return YES;
            }
        }
    return NO;
    }

// Copy a symbol name into `o->sym`, or fail. Never truncate: a clipped name
// is a different symbol, and the lookup that follows will not say so.
static BOOL copySym(Op* o, NSString* name, NSString** err)
    {
    const char* c = name.UTF8String;
    size_t n = strlen(c);
    if (n >= sizeof o->sym)
        {
        if (err)
            *err = [NSString stringWithFormat:
                                 @"symbol '%@' is %zu bytes; the 68k assembler holds at most %zu",
                                 name, n, sizeof o->sym - 1];
        return NO;
        }
    memcpy(o->sym, c, n + 1);
    o->isSym = YES;
    return YES;
    }

static BOOL parseOperand(NSString* raw, Op* o, NSString** err)
    {
    raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    memset(o, 0, sizeof *o);
    int reg;
    BOOL isAddr;

    if ([raw hasPrefix:@"#"])
        {
        NSString* rest = [raw substringFromIndex:1];
        o->kind = OP_IMM;
        BOOL ok;
        long v = parseNum(rest, &ok);
        if (ok)
            o->value = v;
        else if (!copySym(o, rest, err))
            return NO;
        return YES;
        }
    if (parseReg(raw, &reg, &isAddr))
        {
        o->kind = isAddr ? OP_AREG : OP_DREG;
        o->reg = reg;
        return YES;
        // fp0..fp7
        }
        {
        NSString* lc = raw.lowercaseString;
        if (lc.length == 3 && [lc hasPrefix:@"fp"])
            {
            unichar c = [lc characterAtIndex:2];
            if (c >= '0' && c <= '7')
                {
                o->kind = OP_FREG;
                o->reg = c - '0';
                return YES;
                }
            }
        }
    if ([raw hasPrefix:@"-("] && [raw hasSuffix:@")"])
        {
        NSString* inner = [raw substringWithRange:NSMakeRange(2, raw.length - 3)];
        if (!parseReg(inner, &reg, &isAddr) || !isAddr)
            {
            *err = @"bad -(An)";
            return NO;
            }
        o->kind = OP_PREDEC;
        o->reg = reg;
        return YES;
        }
    if ([raw hasPrefix:@"("] && [raw hasSuffix:@")+"])
        {
        NSString* inner = [raw substringWithRange:NSMakeRange(1, raw.length - 3)];
        if (!parseReg(inner, &reg, &isAddr) || !isAddr)
            {
            *err = @"bad (An)+";
            return NO;
            }
        o->kind = OP_POSTINC;
        o->reg = reg;
        return YES;
        }
    if ([raw hasPrefix:@"("] && [raw hasSuffix:@")"])
        {
        NSString* inner = [raw substringWithRange:NSMakeRange(1, raw.length - 2)];
        NSRange comma = [inner rangeOfString:@","];
        // (An,Xn.SIZE*SCALE) — 68020 indexed
        if (comma.location != NSNotFound)
            {
            NSString* baseS = [inner substringToIndex:comma.location];
            NSString* idxS = [[inner substringFromIndex:comma.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            int breg;
            BOOL bAddr;
            if (!parseReg(baseS, &breg, &bAddr) || !bAddr)
                {
                *err = @"bad (An,Xn) base";
                return NO;
                }
            NSRange dot = [idxS rangeOfString:@"."];
            NSString* regS = dot.location == NSNotFound ? idxS : [idxS substringToIndex:dot.location];
            int ireg;
            BOOL iAddr;
            if (!parseReg(regS, &ireg, &iAddr))
                {
                *err = @"bad index reg";
                return NO;
                }
            BOOL isLong = YES;
            int scale = 0;
            if (dot.location != NSNotFound)
                {
                NSString* suf = [[idxS substringFromIndex:dot.location + 1] lowercaseString];
                isLong = ![suf hasPrefix:@"w"];
                NSRange star = [suf rangeOfString:@"*"];
                if (star.location != NSNotFound)
                    {
                    int s = [[suf substringFromIndex:star.location + 1] intValue];
                    scale = s == 2 ? 1 : s == 4 ? 2
                                     : s == 8   ? 3
                                                : 0;
                    }
                }
            o->kind = OP_INDEX;
            o->reg = breg;
            o->idxReg = ireg;
            o->idxIsAddr = iAddr;
            o->idxLong = isLong;
            o->scale = scale;
            return YES;
            }
        if (!parseReg(inner, &reg, &isAddr) || !isAddr)
            {
            *err = @"bad (An)";
            return NO;
            }
        o->kind = OP_IND;
        o->reg = reg;
        return YES;
        }
    NSRange paren = [raw rangeOfString:@"("];
    // disp(An) / disp(pc)
    if (paren.location != NSNotFound && [raw hasSuffix:@")"])
        {
        NSString* disp = [raw substringToIndex:paren.location];
        NSString* inner = [raw substringWithRange:
                                   NSMakeRange(paren.location + 1, raw.length - paren.location - 2)];
        if ([inner.lowercaseString isEqualToString:@"pc"])
            {
            o->kind = OP_PCDISP;
            BOOL ok;
            o->value = parseNum(disp, &ok);
            return YES;
            }
        if (!parseReg(inner, &reg, &isAddr) || !isAddr)
            {
            *err = @"bad disp(An)";
            return NO;
            }
        o->kind = OP_INDDISP;
        o->reg = reg;
        BOOL ok;
        o->value = parseNum(disp, &ok);
        return YES;
        }
    // Bare: absolute number or a symbol (abs.l).
    o->kind = OP_ABS;
    BOOL ok;
    long v = parseNum(raw, &ok);
    if (ok)
        o->value = v;
    else if (!copySym(o, raw, err))
        return NO;
    return YES;
    }

static int eaField(const Op* o)
    {
    switch (o->kind)
        {
    case OP_DREG:
        return (0 << 3) | o->reg;
    case OP_AREG:
        return (1 << 3) | o->reg;
    case OP_IND:
        return (2 << 3) | o->reg;
    case OP_POSTINC:
        return (3 << 3) | o->reg;
    case OP_PREDEC:
        return (4 << 3) | o->reg;
    case OP_INDDISP:
        return (5 << 3) | o->reg;
    case OP_INDEX:
        return (6 << 3) | o->reg;
    case OP_PCDISP:
        return (7 << 3) | 2;
    case OP_ABS:
        return (7 << 3) | 1; // abs.l
    case OP_IMM:
        return (7 << 3) | 4;
    default:
        return 0;
        }
    }

@implementation XAM68kAssembler
    {
    BOOL _gotMode; // pic && cpu < 68020
    NSMutableDictionary<NSString*, NSNumber*>* _gotSlots;
    NSMutableArray<NSString*>* _gotOrder; // slot index -> symbol
    }

// Assign (or look up) the GOT slot index for a symbol. Idempotent across the
// two passes since both visit references in the same order.
- (int)gotSlotForSym:(const char*)sym
    {
    NSString* name = @(sym);
    NSNumber* s = _gotSlots[name];
    if (s)
        return s.intValue;
    int idx = (int)_gotOrder.count;
    _gotSlots[name] = @(idx);
    [_gotOrder addObject:name];
    return idx;
    }

static void app16(NSMutableData* d, uint16_t w)
    {
    uint8_t b[2] = {w >> 8, w & 0xFF};
    [d appendBytes:b length:2];
    }
static void app32(NSMutableData* d, uint32_t l)
    {
    uint8_t b[4] = {l >> 24, l >> 16, l >> 8, l};
    [d appendBytes:b length:4];
    }

// A `symA-symB` value resolves to a link-time constant (no relocation) —
// used by the GOT/a5 setup (`#_GOT-.Lpicpc`) and PIC vtable offsets.
static BOOL symIsDiff(const Op* o)
    {
    if (!o->isSym)
        return NO;
    const char* p = o->sym;
    return p[0] != '-' && strchr(p, '-') != NULL;
    }
// The last symbol `symVal` could not find, or nil. Pass 1 legitimately
// misses forward references, so it is not an error there; pass 2 has the
// whole table, and a miss there used to resolve to 0 SILENTLY — a branch to
// the start of the image, a load from address 0 — with nothing to say so.
// The pass-2 loop clears this before each line and refuses if it is set.
static NSString* sMissingSym = nil;
static long symLookup(NSDictionary* syms, NSString* name)
    {
    NSNumber* v = syms[name];
    if (!v)
        {
        sMissingSym = name;
        return 0;
        }
    return v.longValue;
    }
static long symVal(NSDictionary* syms, const Op* o)
    {
    if (!o->isSym)
        return o->value;
    if (symIsDiff(o))
        {
        NSString* s = @(o->sym);
        NSRange dash = [s rangeOfString:@"-"];
        NSString* a = [s substringToIndex:dash.location];
        NSString* b = [s substringFromIndex:dash.location + 1];
        return symLookup(syms, a) - symLookup(syms, b);
        }
    return symLookup(syms, @(o->sym));
    }

// Append the extension words for one EA operand; record a relocation
// (relative byte offset within `d`) for abs.l SINGLE-symbol references (a
// symbol DIFFERENCE is a constant and needs no relocation).
static void appendExt(NSMutableData* d, const Op* o, int size,
                      NSDictionary* syms, NSMutableArray* relRelocs)
    {
    switch (o->kind)
        {
    case OP_INDDISP:
    case OP_PCDISP:
        app16(d, (uint16_t)(o->value & 0xFFFF));
        break;
    // brief extension word (disp8 = 0)
    case OP_INDEX:
        {
        uint16_t ext = (o->idxIsAddr ? (1 << 15) : 0) | ((o->idxReg & 7) << 12) | (o->idxLong ? (1 << 11) : 0) | ((o->scale & 3) << 9);
        app16(d, ext);
        break;
        }
    case OP_ABS:
        if (relRelocs && o->isSym && !symIsDiff(o))
            [relRelocs addObject:@(d.length)];
        app32(d, (uint32_t)symVal(syms, o));
        break;
    case OP_IMM:
        if (size == 4)
            {
            if (o->isSym && !symIsDiff(o) && relRelocs)
                [relRelocs addObject:@(d.length)];
            app32(d, (uint32_t)symVal(syms, o));
            }
        else
            app16(d, (uint16_t)(symVal(syms, o) & 0xFFFF));
        break;
    default:
        break;
        }
    }

// Condition-code value for a branch suffix (after "b"); -1 if unknown.
static int branchCC(NSString* m)
    {
    static NSDictionary* cc;
    if (!cc)
        cc = @{@"bra" : @0,
               @"bsr" : @1,
               @"bhi" : @2,
               @"bls" : @3,
               @"bcc" : @4,
               @"bhs" : @4,
               @"bcs" : @5,
               @"blo" : @5,
               @"bne" : @6,
               @"beq" : @7,
               @"bvc" : @8,
               @"bvs" : @9,
               @"bpl" : @10,
               @"bmi" : @11,
               @"bge" : @12,
               @"blt" : @13,
               @"bgt" : @14,
               @"ble" : @15};
    NSNumber* n = cc[m];
    return n ? n.intValue : -1;
    }

// Encode one instruction/data item into a fresh NSData. curOff = the
// item's byte offset (for PC-relative branches). On error returns nil.
- (NSData*)encode:(NSString*)mnem
             size:(int)size
              ops:(NSArray<NSString*>*)opStrs
          symbols:(NSDictionary*)syms
               at:(uint32_t)curOff
        relRelocs:(NSMutableArray*)rr
            error:(NSString**)err
    {
    NSMutableData* d = [NSMutableData data];

    // Data directives that may carry relocatable symbol values go through
    // the encode path (which records relocations). .dc.l of a symbol emits
    // a 4-byte relocated pointer (used for vtables / pointer tables).
    if ([mnem isEqualToString:@".dc.l"] || [mnem isEqualToString:@".dc.w"])
        {
        BOOL isLong = [mnem isEqualToString:@".dc.l"];
        for (NSString* s in opStrs)
            {
            // `symA-symB` is a relocation-free symbol difference (PIC offset,
            // e.g. a vtable slot holding method - vtable_base).
            NSRange dash = [s rangeOfString:@"-"];
            if (dash.location != NSNotFound && dash.location > 0)
                {
                Op a, b;
                NSString* sa = [[s substringToIndex:dash.location]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSString* sb = [[s substringFromIndex:dash.location + 1]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (parseOperand(sa, &a, err) && parseOperand(sb, &b, err))
                    {
                    uint32_t v = (uint32_t)(symVal(syms, &a) - symVal(syms, &b));
                    if (isLong)
                        app32(d, v);
                    else
                        app16(d, (uint16_t)v);
                    continue;
                    }
                }
            Op e;
            if (!parseOperand(s, &e, err))
                return nil;
            uint32_t v = (uint32_t)symVal(syms, &e);
            if (isLong)
                {
                if (e.kind == OP_ABS && e.isSym && rr)
                    [rr addObject:@(d.length)];
                app32(d, v);
                }
            else
                app16(d, (uint16_t)v);
            }
        return d;
        }

    Op o[2];
    memset(o, 0, sizeof o);
    int nops = (int)opStrs.count;
    for (int i = 0; i < nops && i < 2; i++)
        if (!parseOperand(opStrs[i], &o[i], err))
            return nil;

        // FBcc — FPU conditional branch (word displacement, pc-relative).
        {
        static NSDictionary* fb;
        if (!fb)
            fb = @{@"fbeq" : @0x01,
                   @"fbne" : @0x0E,
                   @"fbgt" : @0x12,
                   @"fbge" : @0x13,
                   @"fblt" : @0x14,
                   @"fble" : @0x15};
        NSNumber* p = fb[mnem];
        if (p)
            {
            long target = symVal(syms, &o[0]);
            app16(d, 0xF280 | p.intValue);
            app16(d, (uint16_t)((target - (long)(curOff + 2)) & 0xFFFF));
            return d;
            }
        }

    int sb = (size == 1) ? 0 : (size == 2) ? 1
                                           : 2; // size bits (b/w/l)

    // ── Branches ────────────────────────────────────────────────────────
    int cc = branchCC(mnem);
    if (cc >= 0)
        {
        long target = symVal(syms, &o[0]);
        long disp = target - (long)(curOff + 2); // always word form
        app16(d, 0x6000 | (cc << 8));
        app16(d, (uint16_t)(disp & 0xFFFF));
        return d;
        }

    // ── move / movea ────────────────────────────────────────────────────
    if ([mnem isEqualToString:@"move"] || [mnem isEqualToString:@"movea"])
        {
        int top = (size == 1) ? 0x1000 : (size == 2) ? 0x3000
                                                     : 0x2000;
        int s_ea = eaField(&o[0]), d_ea = eaField(&o[1]);
        int word = top | (((d_ea & 7)) << 9) | (((d_ea >> 3)) << 6) | (((s_ea >> 3)) << 3) | (s_ea & 7);
        app16(d, word);
        appendExt(d, &o[0], size, syms, rr);
        appendExt(d, &o[1], size, syms, rr);
        return d;
        }
    if ([mnem isEqualToString:@"moveq"])
        {
        // The byte is sign-extended to 32 bits; allow a signed byte or the
        // unsigned-byte bit pattern, but flag anything that wouldn't fit.
        if (o[0].kind != OP_IMM || o[0].value < -128 || o[0].value > 255)
            {
            if (err)
                *err = [NSString stringWithFormat:
                                     @"moveq immediate #%ld out of range — must be -128..255 (one byte, "
                                     @"sign-extended)",
                                     o[0].value];
            return nil;
            }
        app16(d, 0x7000 | (o[1].reg << 9) | (o[0].value & 0xFF));
        return d;
        }

    // ── binary ALU (add/sub/and/or/cmp/eor) ─────────────────────────────
    NSDictionary* aluBase = @{@"add" : @0xD000, @"sub" : @0x9000, @"and" : @0xC000, @"or" : @0x8000, @"cmp" : @0xB000, @"eor" : @0xB000};
    if (aluBase[mnem])
        {
        int base = [aluBase[mnem] intValue];
        // immediate form (xxxI)
        if (o[0].kind == OP_IMM)
            {
            NSDictionary* ik = @{@"or" : @0, @"and" : @1, @"sub" : @2, @"add" : @3, @"eor" : @5, @"cmp" : @6};
            int word = 0x0000 | ([ik[mnem] intValue] << 9) | (sb << 6) | eaField(&o[1]);
            app16(d, word);
            appendExt(d, &o[0], size, syms, rr); // immediate
            appendExt(d, &o[1], size, syms, rr); // dest EA
            return d;
            }
        // ADDA/SUBA/CMPA <ea>,An
        if (o[1].kind == OP_AREG && ![mnem isEqualToString:@"eor"])
            {
            int opm = (size == 2) ? 3 : 7; // word=opmode3, long=opmode7
            int word = base | (o[1].reg << 9) | (opm << 6) | eaField(&o[0]);
            app16(d, word);
            appendExt(d, &o[0], size, syms, rr);
            return d;
            }
        // EOR Dx,<ea> (dir1 only)
        if ([mnem isEqualToString:@"eor"])
            {
            // no `<ea>,Dn` form exists
            if (o[0].kind != OP_DREG)
                {
                *err = @"eor source must be a data register";
                return nil;
                }
            int word = base | (o[0].reg << 9) | ((4 | sb) << 6) | eaField(&o[1]);
            app16(d, word);
            appendExt(d, &o[1], size, syms, rr);
            return d;
            }
        // add/sub/and/or Dn,<mem> (dir1): source is a Dreg, dest is memory.
        // (cmp has no dir1 form — it's always <ea>,Dn.)
        if (o[0].kind == OP_DREG && o[1].kind != OP_DREG &&
            ![mnem isEqualToString:@"cmp"])
            {
            int word = base | (o[0].reg << 9) | ((4 | sb) << 6) | eaField(&o[1]);
            app16(d, word);
            appendExt(d, &o[1], size, syms, rr);
            return d;
            }
        // <ea>,Dn (dir0): Dn = ops[1], ea = ops[0]
        int word = base | (o[1].reg << 9) | (sb << 6) | eaField(&o[0]);
        app16(d, word);
        appendExt(d, &o[0], size, syms, rr);
        return d;
        }

    // ── shifts/rotates (register or immediate count) ────────────────────
    NSDictionary* shType = @{@"asl" : @0, @"asr" : @0, @"lsl" : @1, @"lsr" : @1, @"roxl" : @2, @"roxr" : @2, @"rol" : @3, @"ror" : @3};
    if (shType[mnem])
        {
        int type = [shType[mnem] intValue];
        int dir = [mnem hasSuffix:@"l"] ? 1 : 0; // ...l = left
        int word = 0xE000 | (dir << 8) | (sb << 6) | (type << 3) | o[1].reg;
        if (o[0].kind == OP_DREG)
            word |= (o[0].reg << 9) | (1 << 5); // count in Dn
        else
            {
            if (o[0].kind != OP_IMM || o[0].value < 1 || o[0].value > 8)
                {
                if (err)
                    *err = [NSString stringWithFormat:
                                         @"%@ immediate shift count #%ld out of range — must be 1..8",
                                         mnem, o[0].value];
                return nil;
                }
            word |= ((o[0].value & 7) << 9); // imm count 1-8
            }
        app16(d, word);
        return d;
        }

    // ── addq / subq (#n in 1..8, to <ea>) ───────────────────────────────
    if ([mnem isEqualToString:@"addq"] || [mnem isEqualToString:@"subq"])
        {
        int base = [mnem isEqualToString:@"addq"] ? 0x5000 : 0x5100;
        if (o[0].kind != OP_IMM || o[0].value < 1 || o[0].value > 8)
            {
            if (err)
                *err = [NSString stringWithFormat:
                                     @"%@ immediate #%ld out of range — must be 1..8 (addq/subq encode "
                                     @"3 bits; a larger value would silently wrap)",
                                     mnem, o[0].value];
            return nil;
            }
        int n = (int)(o[0].value & 7); // 8 encodes as 0
        app16(d, base | (n << 9) | (sb << 6) | eaField(&o[1]));
        appendExt(d, &o[1], size, syms, rr);
        return d;
        }

        // ── Scc (set on condition) ──────────────────────────────────────────
        {
        static NSDictionary* scc;
        if (!scc)
            scc = @{@"st" : @0,
                    @"sf" : @1,
                    @"shi" : @2,
                    @"sls" : @3,
                    @"scc" : @4,
                    @"shs" : @4,
                    @"scs" : @5,
                    @"slo" : @5,
                    @"sne" : @6,
                    @"seq" : @7,
                    @"svc" : @8,
                    @"svs" : @9,
                    @"spl" : @10,
                    @"smi" : @11,
                    @"sge" : @12,
                    @"slt" : @13,
                    @"sgt" : @14,
                    @"sle" : @15};
        NSNumber* c = scc[mnem];
        if (c)
            {
            app16(d, 0x50C0 | (c.intValue << 8) | eaField(&o[0]));
            appendExt(d, &o[0], 1, syms, rr);
            return d;
            }
        }

    // ── single-EA unary (neg/not/clr/tst/negx) ──────────────────────────
    NSDictionary* unBase = @{@"negx" : @0x4000, @"clr" : @0x4200, @"neg" : @0x4400, @"not" : @0x4600, @"tst" : @0x4A00};
    if (unBase[mnem])
        {
        int word = [unBase[mnem] intValue] | (sb << 6) | eaField(&o[0]);
        app16(d, word);
        appendExt(d, &o[0], size, syms, rr);
        return d;
        }
    if ([mnem isEqualToString:@"ext"])
        {
        app16(d, (size == 4 ? 0x48C0 : 0x4880) | o[0].reg);
        return d;
        }
    if ([mnem isEqualToString:@"swap"])
        {
        app16(d, 0x4840 | o[0].reg);
        return d;
        }
    if ([mnem isEqualToString:@"addx"] || [mnem isEqualToString:@"subx"])
        {
        // ADDX/SUBX Dy,Dx (register form): base | Dx<<9 | size<<6 | Dy
        int base = [mnem isEqualToString:@"addx"] ? 0xD100 : 0x9100;
        app16(d, base | (o[1].reg << 9) | (sb << 6) | o[0].reg);
        return d;
        }
    if ([mnem isEqualToString:@"exg"])
        {
        if (o[0].kind == OP_DREG && o[1].kind == OP_DREG)
            app16(d, 0xC140 | (o[0].reg << 9) | o[1].reg); // Dx,Dy
        else if (o[0].kind == OP_AREG && o[1].kind == OP_AREG)
            app16(d, 0xC148 | (o[0].reg << 9) | o[1].reg); // Ax,Ay
        // Dx,Ay (data first)
        else
            {
            int dr = o[0].kind == OP_DREG ? o[0].reg : o[1].reg;
            int ar = o[0].kind == OP_AREG ? o[0].reg : o[1].reg;
            app16(d, 0xC188 | (dr << 9) | ar);
            }
        return d;
        }

    // ── multiply: word form (16x16->32, 68000) and long form (68020+) ───
    if ([mnem isEqualToString:@"muls"] || [mnem isEqualToString:@"mulu"])
        {
        BOOL isS = [mnem isEqualToString:@"muls"];
        // MULU.W/MULS.W Dn
        if (size == 2)
            {
            app16(d, (isS ? 0xC1C0 : 0xC0C0) | (o[1].reg << 9) | eaField(&o[0]));
            appendExt(d, &o[0], 2, syms, rr);
            return d;
            }
        app16(d, 0x4C00 | eaField(&o[0])); // long form
        app16(d, (o[1].reg << 12) | (isS ? 0x0800 : 0));
        appendExt(d, &o[0], size, syms, rr);
        return d;
        }
    if ([mnem isEqualToString:@"divs"] || [mnem isEqualToString:@"divu"])
        {
        int sign = [mnem isEqualToString:@"divs"] ? 0x0800 : 0;
        app16(d, 0x4C40 | eaField(&o[0]));
        app16(d, (o[1].reg << 12) | sign | o[1].reg); // Dq=Dr=ops[1]
        appendExt(d, &o[0], size, syms, rr);
        return d;
        }

        // ── 68881/68882 FPU (line-F, coprocessor id 1) ──────────────────────
        {
        static NSDictionary* fop;
        if (!fop)
            fop = @{@"fmove" : @0x00,
                    @"fadd" : @0x22,
                    @"fsub" : @0x28,
                    @"fmul" : @0x23,
                    @"fdiv" : @0x20,
                    @"fneg" : @0x1A,
                    @"fabs" : @0x18,
                    @"fcmp" : @0x38,
                    @"fsqrt" : @0x04,
                    @"fintrz" : @0x03,
                    @"fint" : @0x01,
                    @"ftst" : @0x3A,
                    // 68881 transcendentals (-> host/JIT libm)
                    @"fsin" : @0x0E,
                    @"fcos" : @0x1D,
                    @"ftan" : @0x0F,
                    @"fasin" : @0x0C,
                    @"facos" : @0x1C,
                    @"fatan" : @0x0A,
                    @"fetox" : @0x10,
                    @"flogn" : @0x14,
                    @"flog10" : @0x15,
                    @"flog2" : @0x16,
                    @"ftwotox" : @0x11,
                    @"ftentox" : @0x12,
                    @"fsinh" : @0x02,
                    @"fcosh" : @0x19,
                    @"ftanh" : @0x09};
        NSNumber* opm = fop[mnem];
        if (opm)
            {
            int opmode = opm.intValue;
            // FPU source specifier: .l(long int)=0, .s(single)=1, .w=4,
            // .d(double)=5, .b=6. Our size codes: 4=.l 5=.s 2=.w 8=.d 1=.b.
            int fmt = size == 4 ? 0 : size == 5 ? 1
                                  : size == 2   ? 4
                                  : size == 8   ? 5
                                  : size == 1   ? 6
                                                : 1;
            int eabytes = size == 8 ? 8 : 4;
            if ([mnem isEqualToString:@"fmove"] && o[0].kind == OP_FREG && o[1].kind != OP_FREG)
                {
                app16(d, 0xF200 | eaField(&o[1])); // store fpN -> <ea>
                app16(d, 0x6000 | (fmt << 10) | (o[0].reg << 7));
                appendExt(d, &o[1], eabytes, syms, rr);
                return d;
                }
            int dst = o[1].reg; // general: src -> fpN(=o[1])
            if (o[0].kind == OP_FREG)
                {
                app16(d, 0xF200);
                app16(d, (o[0].reg << 10) | (dst << 7) | opmode);
                }
            else
                {
                app16(d, 0xF200 | eaField(&o[0]));
                app16(d, 0x4000 | (fmt << 10) | (dst << 7) | opmode);
                appendExt(d, &o[0], eabytes, syms, rr);
                }
            return d;
            }
        // FScc — set on FP condition
        static NSDictionary* fscc;
        if (!fscc)
            fscc = @{@"fseq" : @0x01,
                     @"fsne" : @0x0E,
                     @"fsgt" : @0x12,
                     @"fsge" : @0x13,
                     @"fslt" : @0x14,
                     @"fsle" : @0x15};
        NSNumber* fc = fscc[mnem];
        if (fc)
            {
            app16(d, 0xF240 | eaField(&o[0]));
            app16(d, fc.intValue);
            appendExt(d, &o[0], 1, syms, rr);
            return d;
            }
        }

    // ── control / misc ──────────────────────────────────────────────────
    // PIC: a reference to a program symbol is emitted PC-relative so the
    // code needs no load-time relocation (required for the MiNT port). A
    // numeric absolute (hardware address etc.) keeps absolute addressing.
    BOOL picSym = (o[0].kind == OP_ABS && o[0].isSym);
    BOOL wide = (self.cpu >= 68020); // 68020+: 32-bit PC-relative (no ±32KB limit)
// pass-2 16-bit overflow guard (pass 1 has unresolved fwd refs -> skip)
#define PC_DISP16_OK(dd) (!(rr) || ((dd) >= -32768 && (dd) <= 32767))
    BOOL got = _gotMode && picSym && !symIsDiff(&o[0]); // GOT/a5 load (68000)
    if ([mnem isEqualToString:@"jsr"])
        {
        // move.l sym@GOT(a5),a1 ; jsr (a1)
        if (got)
            {
            int slot = [self gotSlotForSym:o[0].sym] * 4;
            app16(d, 0x226D);
            app16(d, (uint16_t)slot);
            app16(d, 0x4E91);
            return d;
            }
        if (picSym)
            {
            long disp = symVal(syms, &o[0]) - (long)(curOff + 2);
            // bsr.l
            if (wide)
                {
                app16(d, 0x61FF);
                app32(d, (uint32_t)disp);
                return d;
                }
            // 68000, not PIC: use an ABSOLUTE jsr (xxx).L with a load-time
            // relocation rather than a ±32KB bsr.w. The $601A image carries a
            // fixup stream, so an absolute call reaches anywhere — whereas
            // bsr.w simply FAILS THE BUILD once a program's code span passes
            // 32 KB, which is not a large program.
            //
            // It has to be unconditional, not a relax-on-overflow: pass 1 sizes
            // a forward reference without knowing the displacement, so choosing
            // 4 bytes there and 6 here would shift every label after it. Both
            // forms are 6 bytes now, so the two passes agree.
            //
            // True PIC (MiNT) cannot take a relocation at all — that is what the
            // -mpic GOT model above is for, and it is handled before this.
            if (!self.pic)
                {
                app16(d, 0x4E80 | eaField(&o[0]));
                appendExt(d, &o[0], 4, syms, rr);
                return d;
                }
            if (!PC_DISP16_OK(disp))
                {
                if (err)
                    *err = [NSString stringWithFormat:
                                         @"bsr '%s' out of ±32KB (build -A 68030, or -mpic for the 68000 GOT model)", o[0].sym];
                return nil;
                }
            app16(d, 0x6100);
            app16(d, (uint16_t)(disp & 0xFFFF));
            return d; // bsr.w
            }
        app16(d, 0x4E80 | eaField(&o[0]));
        appendExt(d, &o[0], 4, syms, rr);
        return d;
        }
    if ([mnem isEqualToString:@"jmp"])
        {
        // move.l sym@GOT(a5),a1 ; jmp (a1)
        if (got)
            {
            int slot = [self gotSlotForSym:o[0].sym] * 4;
            app16(d, 0x226D);
            app16(d, (uint16_t)slot);
            app16(d, 0x4ED1);
            return d;
            }
        if (picSym)
            {
            long disp = symVal(syms, &o[0]) - (long)(curOff + 2);
            // bra.l
            if (wide)
                {
                app16(d, 0x60FF);
                app32(d, (uint32_t)disp);
                return d;
                }
            // Same reasoning as jsr above: absolute jmp (xxx).L + relocation on a
            // non-PIC 68000, so a jump is not limited to a ±32KB span.
            if (!self.pic)
                {
                app16(d, 0x4EC0 | eaField(&o[0]));
                appendExt(d, &o[0], 4, syms, rr);
                return d;
                }
            if (!PC_DISP16_OK(disp))
                {
                if (err)
                    *err = [NSString stringWithFormat:
                                         @"bra '%s' out of ±32KB (build -A 68030 or -mpic)", o[0].sym];
                return nil;
                }
            app16(d, 0x6000);
            app16(d, (uint16_t)(disp & 0xFFFF));
            return d; // bra.w
            }
        app16(d, 0x4EC0 | eaField(&o[0]));
        appendExt(d, &o[0], 4, syms, rr);
        return d;
        }
    if ([mnem isEqualToString:@"pea"])
        {
        // move.l sym@GOT(a5),-(sp)
        if (got)
            {
            int slot = [self gotSlotForSym:o[0].sym] * 4;
            app16(d, 0x2F2D);
            app16(d, (uint16_t)slot);
            return d;
            }
        if (picSym)
            {
            long disp = symVal(syms, &o[0]) - (long)(curOff + 2);
            // pea (bd32,pc)
            if (wide)
                {
                app16(d, 0x4840 | ((7 << 3) | 3));
                app16(d, 0x0170);
                app32(d, (uint32_t)disp);
                return d;
                }
            // Non-PIC 68000: absolute pea (xxx).L + relocation, so the address
            // of a symbol is reachable however far away it sits. Same
            // pass-1/pass-2 sizing argument as jsr — both forms are 6 bytes.
            if (!self.pic)
                {
                app16(d, 0x4840 | eaField(&o[0]));
                appendExt(d, &o[0], 4, syms, rr);
                return d;
                }
            if (!PC_DISP16_OK(disp))
                {
                if (err)
                    *err = @"pea sym out of ±32KB (build -A 68030 or -mpic)";
                return nil;
                }
            app16(d, 0x4840 | ((7 << 3) | 2));
            app16(d, (uint16_t)(disp & 0xFFFF));
            return d;
            }
        app16(d, 0x4840 | eaField(&o[0]));
        appendExt(d, &o[0], 4, syms, rr);
        return d;
        }
    // lea <ea>,An
    if ([mnem isEqualToString:@"lea"])
        {
        // move.l sym@GOT(a5),An
        if (got)
            {
            int slot = [self gotSlotForSym:o[0].sym] * 4;
            app16(d, 0x206D | (o[1].reg << 9));
            app16(d, (uint16_t)slot);
            return d;
            }
        if (picSym)
            {
            long disp = symVal(syms, &o[0]) - (long)(curOff + 2);
            // lea (bd32,pc),An
            if (wide)
                {
                app16(d, 0x41C0 | (o[1].reg << 9) | ((7 << 3) | 3));
                app16(d, 0x0170);
                app32(d, (uint32_t)disp);
                return d;
                }
            // Non-PIC 68000: absolute lea (xxx).L,An + relocation. See jsr.
            if (!self.pic)
                {
                app16(d, 0x41C0 | (o[1].reg << 9) | eaField(&o[0]));
                appendExt(d, &o[0], 4, syms, rr);
                return d;
                }
            if (!PC_DISP16_OK(disp))
                {
                if (err)
                    *err = @"lea sym out of ±32KB (build -A 68030 or -mpic)";
                return nil;
                }
            app16(d, 0x41C0 | (o[1].reg << 9) | ((7 << 3) | 2));
            app16(d, (uint16_t)(disp & 0xFFFF));
            return d;
            }
        app16(d, 0x41C0 | (o[1].reg << 9) | eaField(&o[0]));
        appendExt(d, &o[0], 4, syms, rr);
        return d;
        }
#undef PC_DISP16_OK
    if ([mnem isEqualToString:@"link"])
        {
        app16(d, 0x4E50 | o[0].reg);
        app16(d, (uint16_t)(o[1].value & 0xFFFF));
        return d;
        }
    if ([mnem isEqualToString:@"unlk"])
        {
        app16(d, 0x4E58 | o[0].reg);
        return d;
        }
    if ([mnem isEqualToString:@"rts"])
        {
        app16(d, 0x4E75);
        return d;
        }
    if ([mnem isEqualToString:@"rte"])
        {
        app16(d, 0x4E73);
        return d;
        }
    if ([mnem isEqualToString:@"rtr"])
        {
        app16(d, 0x4E77);
        return d;
        }
    if ([mnem isEqualToString:@"nop"])
        {
        app16(d, 0x4E71);
        return d;
        }
    // ILLEGAL ($4AFC) — the architecturally-guaranteed illegal instruction,
    // which is how the back end lowers `Unreachable` (a failed checked
    // downcast). The back end emitted it before this table knew it, so it
    // assembled to nothing and the failing cast fell through into the code
    // after it. A mnemonic the code generator emits and the assembler does not
    // know is exactly the gap the no-fallback rule exists to expose.
    if ([mnem isEqualToString:@"illegal"])
        {
        app16(d, 0x4AFC);
        return d;
        }
    if ([mnem isEqualToString:@"trap"])
        {
        if (o[0].kind != OP_IMM || o[0].value < 0 || o[0].value > 15)
            {
            if (err)
                *err = [NSString stringWithFormat:
                                     @"trap vector #%ld out of range — must be 0..15", o[0].value];
            return nil;
            }
        app16(d, 0x4E40 | (o[0].value & 0xF));
        return d;
        }

    *err = [NSString stringWithFormat:@"unsupported mnemonic '%@'", mnem];
    return nil;
    }

// ── Line parsing helpers ────────────────────────────────────────────────
// Split a comma-separated operand list, honouring parens (e.g. "12(a6),d0").
static NSArray<NSString*>* splitOperands(NSString* s)
    {
    NSMutableArray* out = [NSMutableArray array];
    int depth = 0;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < s.length; i++)
        {
        unichar c = [s characterAtIndex:i];
        if (c == '(')
            depth++;
        else if (c == ')')
            depth--;
        else if (c == ',' && depth == 0)
            {
            [out addObject:[s substringWithRange:NSMakeRange(start, i - start)]];
            start = i + 1;
            }
        }
    NSString* last = [s substringFromIndex:start];
    last = [last stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (last.length)
        [out addObject:last];
    return out;
    }

- (nullable NSData*)assemble:(NSString*)source error:(NSString**)error
    {
    NSString* __autoreleasing dummy = nil;
    if (!error)
        error = &dummy;

    // Parse into a flat item list: each item is a label, a data/insn line, or
    // a directive. We keep raw fields and (re)encode in both passes.
    NSMutableArray<NSDictionary*>* items = [NSMutableArray array];
    for (NSString* rawLine in [source componentsSeparatedByString:@"\n"])
        {
        NSString* line = rawLine;
        NSRange semi = [line rangeOfString:@";"]; // strip comments
        if (semi.location != NSNotFound)
            line = [line substringToIndex:semi.location];
        // A label sits at column 0 as `name:`.
        NSString* trimmed = [line stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0)
            continue;
        if (![line hasPrefix:@" "] && ![line hasPrefix:@"\t"])
            {
            NSRange colon = [trimmed rangeOfString:@":"];
            if (colon.location != NSNotFound)
                {
                NSString* lbl = [trimmed substringToIndex:colon.location];
                // A label named after a register (a0-a7/d0-d7/sp/fp0-fp7) can
                // never be referenced — every operand mention parses as the
                // REGISTER — so defining one is always a bug in whatever
                // emitted the asm (the backend mangles them; see m68kSym).
                // Refuse it rather than let stores silently go through
                // whatever the register holds.
                int rr;
                BOOL ra;
                if (parseReg(lbl, &rr, &ra) || (lbl.length == 3 && [lbl.lowercaseString hasPrefix:@"fp"] && [lbl characterAtIndex:2] >= '0' && [lbl characterAtIndex:2] <= '7'))
                    {
                    *error = [NSString stringWithFormat:
                                           @"label '%@' shadows a register name", lbl];
                    return nil;
                    }
                [items addObject:@{@"label" : lbl}];
                trimmed = [[trimmed substringFromIndex:colon.location + 1]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (trimmed.length == 0)
                    continue;
                }
            }
        // Directive or instruction.
        NSScanner* sc = [NSScanner scannerWithString:trimmed];
        NSString* head = nil;
        [sc scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&head];
        NSString* restOfLine = [[trimmed substringFromIndex:sc.scanLocation]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        // .dc.l/.dc.w may hold relocatable symbols → route through encode
        // (which records relocations); other directives are plain data.
        if ([head isEqualToString:@".dc.l"] || [head isEqualToString:@".dc.w"])
            {
            [items addObject:@{@"mnem" : head, @"size" : @4, @"ops" : (restOfLine.length ? splitOperands(restOfLine) : @[])}];
            continue;
            }
        if ([head hasPrefix:@"."])
            {
            [items addObject:@{@"dir" : head, @"args" : restOfLine ?: @""}];
            continue;
            }
        // Instruction: split mnemonic.size and operand list.
        NSString *mnem = head, *szs = nil;
        NSRange dot = [head rangeOfString:@"."];
        if (dot.location != NSNotFound)
            {
            mnem = [head substringToIndex:dot.location];
            szs = [head substringFromIndex:dot.location + 1];
            }
        int size = 2;
        if ([szs isEqualToString:@"b"])
            size = 1;
        else if ([szs isEqualToString:@"l"])
            size = 4;
        else if ([szs isEqualToString:@"w"])
            size = 2;
        else if ([szs isEqualToString:@"s"])
            size = 5; // FPU single (f32)
        else if ([szs isEqualToString:@"d"])
            size = 8; // FPU double (f64)
        NSArray* ops = restOfLine.length ? splitOperands(restOfLine) : @[];
        [items addObject:@{@"mnem" : mnem.lowercaseString, @"size" : @(size), @"ops" : ops}];
        }

    // ── data-directive bytes (for both passes) ──────────────────────────
    NSData* (^dataForDir)(NSString*, NSString*, uint32_t) =
        ^NSData*(NSString* dir, NSString* args, uint32_t curOff) {
          NSMutableData* d = [NSMutableData data];
          if ([dir isEqualToString:@".even"])
              {
              if (curOff & 1)
                  {
                  uint8_t z = 0;
                  [d appendBytes:&z length:1];
                  }
              }
          else if ([dir isEqualToString:@".ascii"] || [dir isEqualToString:@".asciz"])
              {
              NSRange q1 = [args rangeOfString:@"\""];
              NSRange q2 = [args rangeOfString:@"\"" options:NSBackwardsSearch];
              if (q1.location != NSNotFound && q2.location > q1.location)
                  {
                  NSString* str = [args substringWithRange:
                                            NSMakeRange(q1.location + 1, q2.location - q1.location - 1)];
                  str = [str stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
                  str = [str stringByReplacingOccurrencesOfString:@"\\r" withString:@"\r"];
                  str = [str stringByReplacingOccurrencesOfString:@"\\0" withString:@"\0"];
                  [d appendData:[str dataUsingEncoding:NSISOLatin1StringEncoding]];
                  }
              if ([dir isEqualToString:@".asciz"])
                  {
                  uint8_t z = 0;
                  [d appendBytes:&z length:1];
                  }
              }
          else if ([dir isEqualToString:@".space"] || [dir isEqualToString:@".ds.b"])
              {
              BOOL ok;
              long n = parseNum(args, &ok);
              for (long k = 0; ok && k < n; k++)
                  {
                  uint8_t z = 0;
                  [d appendBytes:&z length:1];
                  }
              }
          else if ([dir isEqualToString:@".dc.b"] || [dir isEqualToString:@".byte"])
              {
              for (NSString* t in splitOperands(args))
                  {
                  BOOL ok;
                  long v = parseNum(t, &ok);
                  uint8_t b = (uint8_t)v;
                  if (ok)
                      [d appendBytes:&b length:1];
                  }
              }
          return d;
        };

    // ── Pass 1: assign label offsets ────────────────────────────────────
    // Segments are laid out contiguously (GEMDOS loads text+data adjacently
    // and zeroes bss after), so offsets are sequential across all three; we
    // just record where .data and .bss begin to split tsize/dsize/bsize.
    _gotMode = self.pic && self.cpu < 68020;
    _gotSlots = [NSMutableDictionary dictionary];
    _gotOrder = [NSMutableArray array];
    NSMutableDictionary* syms = [NSMutableDictionary dictionary];
    uint32_t off = 0, segDataStart = 0, segBssStart = 0;
    BOOL haveData = NO, haveBss = NO;
    for (NSDictionary* it in items)
        {
        if (it[@"label"])
            {
            // A label defined twice is a program with two answers to one
            // name; the dictionary would keep the later one silently. Bug
            // 128's second `_start` assembled without a word from here.
            if (syms[it[@"label"]])
                {
                *error = [NSString stringWithFormat:@"duplicate label '%@'", it[@"label"]];
                return nil;
                }
            syms[it[@"label"]] = @(off);
            continue;
            }
        if (it[@"dir"])
            {
            NSString* dir = it[@"dir"];
            if ([dir isEqualToString:@".data"])
                {
                segDataStart = off;
                haveData = YES;
                continue;
                }
            if ([dir isEqualToString:@".bss"])
                {
                segBssStart = off;
                haveBss = YES;
                continue;
                }
            if ([dir isEqualToString:@".text"] || [dir isEqualToString:@".globl"])
                continue;
            off += dataForDir(dir, it[@"args"], off).length;
            continue;
            }
        NSString* e = nil;
        NSData* enc = [self encode:it[@"mnem"]
                              size:[it[@"size"] intValue]
                               ops:it[@"ops"]
                           symbols:syms
                                at:off
                         relRelocs:nil
                             error:&e];
        if (!enc)
            {
            *error = e ?: @"encode error (pass1)";
            return nil;
            }
        off += enc.length;
        }
    // The GOT (relocated address table) lives at the end of the in-file image.
    // In GOT mode the backend folds bss into .data, so there is no separate
    // bss segment to displace.
    if (_gotMode)
        {
        syms[@"_GOT"] = @(off);
        off += (uint32_t)_gotOrder.count * 4;
        }

    // Split sizes: text [0,segDataStart), data [segDataStart,segBssStart),
    // bss [segBssStart,off). The file image holds text+data; bss is size-only.
    uint32_t totalOff = off;
    uint32_t tsize = haveData ? segDataStart : (haveBss ? segBssStart : totalOff);
    uint32_t dataEnd = haveBss ? segBssStart : totalOff;
    uint32_t dsize = haveData ? (dataEnd - segDataStart) : 0;
    uint32_t bsize = haveBss ? (totalOff - segBssStart) : 0;

    // ── Pass 2: emit bytes + relocations ────────────────────────────────
    // The image is text+data (everything before .bss); bss reserves no file
    // bytes — its labels were assigned in pass 1 and the loader zeroes it.
    NSMutableData* text = [NSMutableData data];
    NSMutableArray<NSNumber*>* relocs = [NSMutableArray array];
    BOOL inBss = NO;
    for (NSDictionary* it in items)
        {
        if (it[@"label"])
            continue;
        if (it[@"dir"])
            {
            NSString* dir = it[@"dir"];
            if ([dir isEqualToString:@".bss"])
                {
                inBss = YES;
                continue;
                }
            if ([dir isEqualToString:@".text"] || [dir isEqualToString:@".data"] || [dir isEqualToString:@".globl"])
                continue;
            if (inBss)
                continue;
            [text appendData:dataForDir(dir, it[@"args"], (uint32_t)text.length)];
            continue;
            }
        if (inBss)
            continue;
        NSMutableArray* rr = [NSMutableArray array];
        NSString* e = nil;
        uint32_t base = (uint32_t)text.length;
        sMissingSym = nil;
        NSData* enc = [self encode:it[@"mnem"]
                              size:[it[@"size"] intValue]
                               ops:it[@"ops"]
                           symbols:syms
                                at:base
                         relRelocs:rr
                             error:&e];
        if (!enc)
            {
            *error = e ?: @"encode error (pass2)";
            return nil;
            }
        if (sMissingSym)
            {
            *error = [NSString stringWithFormat:@"undefined symbol '%@' in '%@'",
                                                sMissingSym, it[@"mnem"]];
            return nil;
            }
        for (NSNumber* r in rr)
            [relocs addObject:@(base + r.unsignedIntValue)];
        [text appendData:enc];
        }
    // Emit the GOT: one relocated .dc.l per referenced symbol, in slot order.
    if (_gotMode)
        {
        for (NSString* sym in _gotOrder)
            {
            Op o;
            memset(&o, 0, sizeof o);
            o.kind = OP_ABS;
            o.isSym = YES;
            NSString* e = nil;
            if (!copySym(&o, sym, &e))
                {
                *error = e;
                return nil;
                }
            [relocs addObject:@(text.length)];
            sMissingSym = nil;
            app32(text, (uint32_t)symVal(syms, &o));
            if (sMissingSym)
                {
                *error = [NSString stringWithFormat:@"undefined symbol '%@' in the GOT", sMissingSym];
                return nil;
                }
            }
        }

    // ── Build the $601A image ───────────────────────────────────────────
    NSMutableData* out = [NSMutableData data];
    app16(out, 0x601A); // magic
    app32(out, tsize);  // tsize
    app32(out, dsize);  // dsize
    app32(out, bsize);  // bsize (loader allocates + zeroes)
    app32(out, 0);      // ssize
    app32(out, 0);      // res1
    // prgflags (MiNT). The generated code is fully position-independent, so
    // it is safe to load into and Malloc from alternative (TT/fast) RAM.
    // Protection mode = PF_PRIVATE (bits 4-5 = 0). FASTLOAD is left off so
    // the OS still zeroes the TPA heap (the runtime doesn't pre-zero it).
    //   PF_TTRAMLOAD 0x02 | PF_TTRAMMEM 0x04 = 0x06
    app32(out, 0x06); // prgflags
    app16(out, 0);    // absflag (0 -> DRI relocation table present)
    [out appendData:text];

    // Relocation stream: first-fixup longword, then advance bytes (1 = +254).
    [relocs sortUsingSelector:@selector(compare:)];
    if (relocs.count == 0)
        {
        app32(out, 0);
        }
    else
        {
        uint32_t prev = relocs[0].unsignedIntValue;
        app32(out, prev);
        for (NSUInteger i = 1; i < relocs.count; i++)
            {
            uint32_t cur = relocs[i].unsignedIntValue, delta = cur - prev;
            while (delta > 254)
                {
                uint8_t one = 1;
                [out appendBytes:&one length:1];
                delta -= 254;
                }
            uint8_t b = (uint8_t)delta;
            [out appendBytes:&b length:1];
            prev = cur;
            }
        uint8_t zero = 0;
        [out appendBytes:&zero length:1];
        }
    return out;
    }

@end
