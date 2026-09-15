// XTElfGC.m — link-time dead code AND data elimination (bug 196 Stages C + D).
//
// The seed/runtime text [0, tPrefix) and data [0, dPrefix) are kept wholesale.
// Every object and archive member past them is partitioned into UNITS: text at
// every text symbol (any size — the CFG analysis below makes that safe),
// text-section and object start; data at every SIZED data symbol, data-section
// and object start (a size-0 data symbol cannot say where it ends, so it stays
// inside the unit it falls in). Unreachable units are dropped, the survivors
// compacted, and every symbol and fixup offset remapped. A unit's EXTENT is
// [start, nextStart), so padding and unnamed bytes stay with their unit. A
// DUPLICATE definition (weak, or a second copy of an inline method) still gets
// its own unit, because the boundaries come from every object's whole symbol
// table, not from the winners — that is what lets a split build shed its copies.
//
// Vendor objects are NOT built with -ffunction-sections, and that costs three
// things a section-granular linker never has to think about:
//
//   1. An intra-section reference to a local function — `lea thunk(%rip)`,
//      `call static_fn`, `jmp .L` — is resolved by the assembler and carries NO
//      relocation. Reachability through fixups alone cannot see it (OpenSSL's
//      lh_*_comp_thunk was dropped that way), and once units move independently
//      its displacement is wrong. So every text unit is DECODED (x86-64 length
//      disassembler below); each rel32 / RIP-relative operand without a fixup
//      at its position becomes an edge AND a synthetic PC32 fixup anchored to
//      the target unit, which the writer re-resolves after compaction like any
//      relocation.
//   2. A rel8 branch cannot be re-resolved (one byte), and hand-asm falls
//      through from one symbol into the next. Both are GLUE: the units stay
//      adjacent, verbatim, and live together. `sym + addend` reaching past the
//      symbol's own unit is glue too, for text and data alike.
//   3. A unit the disassembler cannot decode with certainty (EVEX, an opcode we
//      do not know) might hide references: its whole OBJECT is glued — exactly
//      the section-atomic behaviour of a normal linker — so the fallback is
//      never less safe than what ld does.
//
// Reachability is one fixpoint over both kinds of unit: a live text unit keeps
// what its fixups and decoded references name (text or data), a live data unit
// keeps what the fixups applied inside it name (a vtable's methods, a jump
// table's cases, a string's bytes). Roots: the entry and every fixup applied in
// the seed prefixes (the TLS image's slots are among those).
//
// Mirror of MergedImage.gcDead (selfhost/asm/ElfMerge.xc): same units, same
// edges, same order of synthetic fixups, same compaction — ldx86-diff gates it.
#import "XTElfGC.h"

#define NONE 0xFFFFFFFFu
#define DATA_BIT 0x80000000u

// ── a growable uint32 vector ─────────────────────────────────────────────
typedef struct
    {
    uint32_t* v;
    uint32_t n, cap;
    } U32Vec;
static void vpush(U32Vec* a, uint32_t x)
    {
    if (a->n == a->cap)
        {
        a->cap = a->cap ? a->cap * 2 : 64;
        a->v = realloc(a->v, a->cap * sizeof(uint32_t));
        }
    a->v[a->n++] = x;
    }
static void vfree(U32Vec* a)
    {
    free(a->v);
    a->v = NULL;
    a->n = a->cap = 0;
    }
static int u32cmp(const void* a, const void* b)
    {
    uint32_t x = *(const uint32_t*)a, y = *(const uint32_t*)b;
    return x < y ? -1 : (x > y ? 1 : 0);
    }
// largest i with starts[i] <= addr, or NONE if addr < starts[0]
static uint32_t unitAt(const uint32_t* starts, uint32_t n, uint32_t addr)
    {
    if (n == 0 || addr < starts[0])
        return NONE;
    uint32_t lo = 0, hi = n - 1;
    while (lo < hi)
        {
        uint32_t mid = (lo + hi + 1) / 2;
        if (starts[mid] <= addr)
            lo = mid;
        else
            hi = mid - 1;
        }
    return lo;
    }
static BOOL inSorted(const uint32_t* a, uint32_t n, uint32_t x)
    {
    uint32_t lo = 0, hi = n;
    while (lo < hi)
        {
        uint32_t mid = (lo + hi) / 2;
        if (a[mid] < x)
            lo = mid + 1;
        else
            hi = mid;
        }
    return lo < n && a[lo] == x;
    }
static int32_t rd32s(const uint8_t* t, uint32_t p)
    {
    return (int32_t)((uint32_t)t[p] | ((uint32_t)t[p + 1] << 8) | ((uint32_t)t[p + 2] << 16) | ((uint32_t)t[p + 3] << 24));
    }

@implementation XTElfGC
    {
    U32Vec _objText, _objData, _objDataAlign, _tBounds, _dBounds;
    NSMutableArray<NSString*>* _objLabel;
    // decoder outputs
    BOOL _lastTerm, _lastNop;
    uint32_t _lastRelPos, _lastRelSize, _lastRipPos, _lastImmSize;
    // GC state (valid during run only)
    uint32_t *_tStart, *_tEnd, _ntu, *_dStart, *_dEnd, _ndu;
    NSMutableArray<NSString*>*_tName, *_dName;
    uint8_t *_tLive, *_dLive, *_tGlue, *_dGlue, *_tFall;
    U32Vec _edgeSrc, _edgeTgt; // encoded ids
    U32Vec _work;
    uint32_t *_tWhy, *_dWhy;
    uint32_t _markWhy;
    NSMutableDictionary<NSString*, NSNumber*>* _syms;
    NSMutableSet<NSString*>*_dataSet, *_bssSet;
    NSMutableDictionary<NSNumber*, NSNumber*>* _ripImm;
    uint32_t* _tblBase;
    uint32_t _ntbl;
    const uint8_t* _text;
    }

- (instancetype)init
    {
    if ((self = [super init]))
        _objLabel = [NSMutableArray array];
    return self;
    }
- (void)dealloc
    {
    vfree(&_objText);
    vfree(&_objData);
    vfree(&_objDataAlign);
    vfree(&_tBounds);
    vfree(&_dBounds);
    }

- (void)noteObjectText:(uint64_t)ts textEnd:(uint64_t)te data:(uint64_t)ds dataEnd:(uint64_t)de
             dataAlign:(uint64_t)da
                 label:(NSString*)label
    {
    vpush(&_objText, (uint32_t)ts);
    vpush(&_objText, (uint32_t)te);
    vpush(&_objData, (uint32_t)ds);
    vpush(&_objData, (uint32_t)de);
    vpush(&_objDataAlign, (uint32_t)da);
    [_objLabel addObject:label];
    }
- (void)noteTextBound:(uint64_t)off
    {
    vpush(&_tBounds, (uint32_t)off);
    }
- (void)noteDataBound:(uint64_t)off
    {
    vpush(&_dBounds, (uint32_t)off);
    }

// ── x86-64 length disassembler ──────────────────────────────────────────
// Returns the byte length of the instruction at `p`, or 0 if it cannot be
// decoded with certainty (unknown opcode / truncated). Only NON-zero lengths
// must be exactly right; 0 makes the caller glue the whole object.
- (uint32_t)insnLenAt:(uint32_t)p end:(uint32_t)end
    {
    const uint8_t* t = _text;
    _lastTerm = NO;
    _lastNop = NO;
    _lastRelPos = NONE;
    _lastRelSize = 0;
    _lastRipPos = NONE;
    _lastImmSize = 0;
    uint32_t s = p;
    BOOL op66 = NO;
    while (p < end)
        {
        uint32_t b = t[p];
        if (b == 0x66)
            {
            op66 = YES;
            p++;
            continue;
            }
        if (b == 0x67)
            {
            p++;
            continue;
            }
        if (b == 0xF0 || b == 0xF2 || b == 0xF3 || b == 0x2E || b == 0x36 || b == 0x3E || b == 0x26 || b == 0x64 || b == 0x65)
            {
            p++;
            continue;
            }
        break;
        }
    BOOL rexW = NO;
    if (p < end)
        {
        uint32_t b = t[p];
        if (b >= 0x40 && b <= 0x4F)
            {
            if (b & 0x08)
                rexW = YES;
            p++;
            }
        }
    if (p >= end)
        return 0;
    uint32_t op = t[p];
    p++;
    uint32_t map = 1;
    BOOL vex = NO;
    if (op == 0xC5)
        {
        if (p + 1 >= end)
            return 0;
        p += 1;
        vex = YES;
        map = 2;
        op = t[p];
        p++;
        }
    else if (op == 0xC4)
        {
        if (p + 2 >= end)
            return 0;
        uint32_t mm = t[p] & 0x1F;
        p += 2;
        vex = YES;
        if (mm == 1)
            map = 2;
        else if (mm == 2)
            map = 38;
        else if (mm == 3)
            map = 3;
        else
            return 0;
        op = t[p];
        p++;
        }
    else if (op == 0x0F)
        {
        if (p >= end)
            return 0;
        uint32_t op2 = t[p];
        p++;
        if (op2 == 0x38 || op2 == 0x3A)
            {
            if (p >= end)
                return 0;
            map = (op2 == 0x38) ? 38 : 3;
            op = t[p];
            p++;
            }
        else
            {
            map = 2;
            op = op2;
            }
        }
    // NB: `grp3` and `far` are both taken by the Windows headers —
    // dlgs.h #defines grp3 as a dialog-control id, and minwindef.h
    // #defines `far` to nothing (a 16-bit-era relic). Both broke
    // `make win64` only; macOS/Linux compiled fine.
    BOOL modrm = NO;
    uint32_t imm = 0;
    BOOL isGrp3 = NO;
    uint32_t relSize = 0;
    if (map == 1)
        {
        uint32_t lo = op & 7, hi = op & 0xF8;
        if ((hi == 0x00 || hi == 0x08 || hi == 0x10 || hi == 0x18 || hi == 0x20 || hi == 0x28 || hi == 0x30 || hi == 0x38) && lo <= 5)
            {
            if (lo <= 3)
                modrm = YES;
            else if (lo == 4)
                imm = 1;
            else
                imm = 5;
            }
        else if (op >= 0x50 && op <= 0x5F)
            {
            }
        else if (op == 0x63)
            modrm = YES;
        else if (op == 0x68)
            imm = 5;
        else if (op == 0x6A)
            imm = 1;
        else if (op == 0x69)
            {
            modrm = YES;
            imm = 5;
            }
        else if (op == 0x6B)
            {
            modrm = YES;
            imm = 1;
            }
        else if (op >= 0x70 && op <= 0x7F)
            {
            imm = 1;
            relSize = 1;
            }
        else if (op == 0x80 || op == 0x83)
            {
            modrm = YES;
            imm = 1;
            }
        else if (op == 0x81)
            {
            modrm = YES;
            imm = 5;
            }
        else if (op >= 0x84 && op <= 0x8E)
            modrm = YES;
        else if (op == 0x90)
            {
            _lastNop = YES;
            }
        else if (op >= 0x91 && op <= 0x9F)
            {
            }
        else if (op >= 0xA0 && op <= 0xA3)
            imm = 8;
        else if (op == 0xA8)
            imm = 1;
        else if (op == 0xA9)
            imm = 5;
        else if (op >= 0xA4 && op <= 0xA7)
            {
            }
        else if (op >= 0xAA && op <= 0xAF)
            {
            }
        else if (op >= 0xB0 && op <= 0xB7)
            imm = 1;
        else if (op >= 0xB8 && op <= 0xBF)
            imm = rexW ? 8 : (op66 ? 2 : 4);
        else if (op == 0xC0 || op == 0xC1)
            {
            modrm = YES;
            imm = 1;
            }
        else if (op == 0xC6)
            {
            modrm = YES;
            imm = 1;
            }
        else if (op == 0xC7)
            {
            modrm = YES;
            imm = 5;
            }
        else if (op == 0xC2)
            {
            imm = 2;
            _lastTerm = YES;
            }
        else if (op == 0xC3)
            {
            _lastTerm = YES;
            }
        else if (op == 0xC8)
            {
            imm = 3;
            }
        else if (op == 0xC9)
            {
            }
        else if (op == 0xCB)
            {
            _lastTerm = YES;
            }
        else if (op == 0xCA)
            {
            imm = 2;
            _lastTerm = YES;
            }
        else if (op == 0xCC)
            {
            _lastNop = YES;
            }
        else if (op == 0xCD)
            imm = 1;
        else if (op == 0xCF)
            {
            _lastTerm = YES;
            }
        else if (op == 0xD0 || op == 0xD1 || op == 0xD2 || op == 0xD3)
            modrm = YES;
        else if (op >= 0xD8 && op <= 0xDF)
            modrm = YES;
        else if (op >= 0xE0 && op <= 0xE3)
            {
            imm = 1;
            relSize = 1;
            }
        else if (op >= 0xE4 && op <= 0xE7)
            imm = 1;
        else if (op == 0xE8)
            {
            imm = 5;
            relSize = 4;
            }
        else if (op == 0xE9)
            {
            imm = 5;
            relSize = 4;
            _lastTerm = YES;
            }
        else if (op == 0xEB)
            {
            imm = 1;
            relSize = 1;
            _lastTerm = YES;
            }
        else if (op >= 0xEC && op <= 0xEF)
            {
            }
        else if (op == 0xF1 || op == 0xF5 || (op >= 0xF8 && op <= 0xFD))
            {
            }
        else if (op == 0xF4)
            {
            _lastTerm = YES;
            }
        else if (op == 0xF6)
            {
            modrm = YES;
            isGrp3 = YES;
            }
        else if (op == 0xF7)
            {
            modrm = YES;
            isGrp3 = YES;
            }
        else if (op == 0xFE)
            modrm = YES;
        else if (op == 0xFF)
            modrm = YES;
        else
            return 0;
        if (relSize != 0 && op66)
            return 0;
        }
    else if (map == 2)
        {
        if (op == 0x0B)
            {
            _lastTerm = YES;
            return p - s;
            }
        else if (op == 0x05 || op == 0x06 || op == 0x07 || op == 0x08 || op == 0x09 || op == 0xA2 || (op >= 0x30 && op <= 0x37) || op == 0x77 || op == 0xA0 || op == 0xA1 || op == 0xA8 || op == 0xA9 || op == 0xAA)
            {
            }
        else if (op >= 0x80 && op <= 0x8F)
            {
            if (vex || op66)
                return 0;
            imm = 5;
            relSize = 4;
            }
        else if (op >= 0xC8 && op <= 0xCF)
            {
            }
        else if (op == 0x70 || op == 0x71 || op == 0x72 || op == 0x73 || op == 0xC2 || op == 0xC4 || op == 0xC5 || op == 0xC6)
            {
            modrm = YES;
            imm = 1;
            }
        else if (op == 0xA4 || op == 0xAC || op == 0xBA)
            {
            modrm = YES;
            imm = 1;
            }
        else if (op == 0x0F)
            return 0;
        else if (op == 0x1F)
            {
            modrm = YES;
            _lastNop = YES;
            }
        else
            {
            modrm = YES;
            }
        }
    else
        {
        modrm = YES;
        if (map == 3)
            imm = 1;
        }
    if (modrm)
        {
        if (p >= end)
            return 0;
        uint32_t mrm = t[p];
        p++;
        uint32_t mod = mrm >> 6, rm = mrm & 7, reg = (mrm >> 3) & 7;
        if (op == 0xFF && map == 1 && (reg == 4 || reg == 5))
            _lastTerm = YES;
        if (isGrp3 && (reg == 0 || reg == 1))
            imm = (op == 0xF6) ? 1 : 5;
        if (map == 1 && op == 0x00 && mrm == 0x00)
            _lastNop = YES;
        if (mod != 3)
            {
            uint32_t base = rm;
            if (rm == 4)
                {
                if (p >= end)
                    return 0;
                uint32_t sib = t[p];
                p++;
                base = sib & 7;
                }
            if (mod == 0)
                {
                if (rm == 5)
                    {
                    _lastRipPos = p;
                    p += 4;
                    }
                else if (rm == 4 && base == 5)
                    p += 4;
                }
            else if (mod == 1)
                p += 1;
            else
                p += 4;
            }
        }
    uint32_t isz = imm;
    if (imm == 5)
        isz = op66 ? 2 : 4;
    if (relSize != 0)
        {
        _lastRelPos = p;
        _lastRelSize = relSize;
        }
    _lastImmSize = isz;
    p += isz;
    if (p > end)
        return 0;
    return p - s;
    }

// The TEXT offset a PC32-in-DATA fixup (a PIC jump-table entry) really means:
// its addend is target + 4k for entry k, recovered from the nearest data
// offset at or below the entry that some `lea table(%rip)` names.
- (uint32_t)pc32DataTargetOf:(XAX86_64Fixup*)f raw:(uint32_t)raw
    {
    if (_ntbl == 0)
        return raw;
    uint32_t pos = (uint32_t)f.offset;
    uint32_t lo = 0, hi = _ntbl;
    while (lo < hi)
        {
        uint32_t mid = (lo + hi) / 2;
        if (_tblBase[mid] <= pos)
            lo = mid + 1;
        else
            hi = mid;
        }
    if (lo == 0)
        return raw;
    uint32_t tb = _tblBase[lo - 1];
    uint32_t k = pos - tb;
    if (k > raw)
        return raw;
    uint32_t tgt = raw - k;
    for (uint32_t i = 0; i + 1 < _objText.n; i += 2)
        {
        uint32_t os = _objText.v[i], oe = _objText.v[i + 1];
        if (raw >= os && raw < oe)
            return (tgt >= os) ? tgt : raw;
        }
    return raw;
    }

// The old-offset address a fixup's `sym + addend` really names.
- (uint32_t)actualOf:(XAX86_64Fixup*)f base:(uint32_t)base toText:(BOOL)toText
    {
    uint32_t raw = base + (uint32_t)(int32_t)f.addend;
    if (f.kind == XAX86FixupAbs64)
        return raw;
    if (f.kind == XAX86FixupPC32Data)
        return toText ? [self pc32DataTargetOf:f raw:raw] : raw;
    uint32_t adj = 4;
    NSNumber* im = _ripImm[@(f.offset)];
    if (im)
        adj += im.unsignedIntValue;
    return raw + adj;
    }

- (void)markId:(uint32_t)id
    {
    if (id == NONE)
        return;
    if (id & DATA_BIT)
        {
        uint32_t j = id & ~DATA_BIT;
        if (_dLive[j])
            return;
        _dLive[j] = 1;
        _dWhy[j] = _markWhy;
        }
    else
        {
        if (_tLive[id])
            return;
        _tLive[id] = 1;
        _tWhy[id] = _markWhy;
        }
    vpush(&_work, id);
    }

static void glueRange(uint8_t* glue, uint32_t a, uint32_t b)
    {
    uint32_t lo = a < b ? a : b, hi = a < b ? b : a;
    for (uint32_t j = lo; j < hi; j++)
        glue[j] = 1;
    }

// The unit a fixup names, encoded, or NONE. A named symbol's addend reaching
// another unit glues the two.
- (uint32_t)targetOf:(XAX86_64Fixup*)f
    {
    NSString* sym = f.symbol;
    if (!sym.length)
        return NONE;
    NSNumber* to = _syms[sym];
    if (!to)
        return NONE;
    if ([_bssSet containsObject:sym])
        return NONE;
    uint32_t base = (uint32_t)to.unsignedLongLongValue;
    BOOL isSec = [sym hasPrefix:@".Lsec"];
    if ([_dataSet containsObject:sym])
        {
        uint32_t faraddr = [self actualOf:f base:base toText:NO];
        uint32_t ub = unitAt(_dStart, _ndu, isSec ? faraddr : base);
        if (ub == NONE)
            return NONE;
        if (!isSec)
            {
            uint32_t uf = unitAt(_dStart, _ndu, faraddr);
            if (uf != NONE && uf != ub)
                glueRange(_dGlue, ub, uf);
            }
        return DATA_BIT | ub;
        }
    uint32_t faraddr = [self actualOf:f base:base toText:YES];
    uint32_t ub = unitAt(_tStart, _ntu, isSec ? faraddr : base);
    if (ub == NONE)
        return NONE;
    if (!isSec)
        {
        uint32_t uf = unitAt(_tStart, _ntu, faraddr);
        if (uf != NONE && uf != ub)
            glueRange(_tGlue, ub, uf);
        }
    return ub;
    }

// A resolved (relocation-less) intra-section reference from text unit `i`.
- (void)ref:(uint32_t)i target:(uint32_t)tgt pos:(uint32_t)pos immAfter:(uint32_t)immAfter rel8:(BOOL)rel8
    objStart:(uint32_t)os
      objEnd:(uint32_t)oe
       synth:(NSMutableArray<XAX86_64Fixup*>*)synth
    {
    if (tgt < os || tgt >= oe)
        return;
    uint32_t tf = unitAt(_tStart, _ntu, tgt);
    if (tf == NONE || tf == i)
        return;
    vpush(&_edgeSrc, i);
    vpush(&_edgeTgt, tf);
    if (rel8)
        {
        glueRange(_tGlue, i, tf);
        return;
        }
    XAX86_64Fixup* nf = [XAX86_64Fixup new];
    nf.offset = pos;
    nf.kind = XAX86FixupPC32;
    nf.symbol = _tName[tf];
    nf.addend = (int64_t)(int32_t)(tgt - _tStart[tf]) - 4 - (int64_t)immAfter;
    [synth addObject:nf];
    }

// Units of one kind: sorted, distinct boundaries, each named by the smallest
// symbol already at that offset or by a synthetic `.Lgc` local.
- (void)unitsFrom:(U32Vec*)bounds prefixEnd:(uint32_t)prefixEnd nameAt:(NSDictionary<NSNumber*, NSString*>*)nameAt
           isData:(BOOL)isData
         outStart:(uint32_t**)outStart
          outName:(NSMutableArray<NSString*>*)outName
            count:(uint32_t*)outN
    {
    uint32_t* b = malloc((bounds->n ? bounds->n : 1) * sizeof(uint32_t));
    uint32_t n = 0;
    for (uint32_t i = 0; i < bounds->n; i++)
        if (bounds->v[i] >= prefixEnd)
            b[n++] = bounds->v[i];
    qsort(b, n, sizeof(uint32_t), u32cmp);
    uint32_t* starts = malloc((n ? n : 1) * sizeof(uint32_t));
    uint32_t m = 0;
    for (uint32_t i = 0; i < n; i++)
        {
        if (m && starts[m - 1] == b[i])
            continue;
        starts[m++] = b[i];
        NSString* nm = nameAt[@(b[i])];
        if (!nm)
            {
            nm = [NSString stringWithFormat:@"%@%u", isData ? @".Lgcd$" : @".Lgct$", b[i]];
            _syms[nm] = @(b[i]);
            if (isData)
                [_dataSet addObject:nm];
            }
        [outName addObject:nm];
        }
    free(b);
    *outStart = starts;
    *outN = m;
    }

// Data GC units are whole-OBJECT data regions (bug 200 safety): one unit per
// merged object that has data, at the object's data base, named by a data
// symbol already there or a synthetic `.Lgcd$` local. Mirror of
// MergedImage._gcDataObjectUnits.
- (void)dataObjectUnits:(uint32_t)seedDataEnd nameAt:(NSDictionary<NSNumber*, NSString*>*)nameAt
               outStart:(uint32_t**)outStart
                outName:(NSMutableArray<NSString*>*)outName
                  count:(uint32_t*)outN
    {
    uint32_t nobj = _objData.n / 2;
    uint32_t* b = malloc((nobj ? nobj : 1) * sizeof(uint32_t));
    uint32_t n = 0;
    NSMutableSet<NSNumber*>* seen = [NSMutableSet set];
    for (uint32_t o = 0; o < nobj; o++)
        {
        uint32_t ds = _objData.v[o * 2], de = _objData.v[o * 2 + 1];
        if (de <= ds || ds < seedDataEnd)
            continue;
        if ([seen containsObject:@(ds)])
            continue;
        [seen addObject:@(ds)];
        b[n++] = ds;
        }
    qsort(b, n, sizeof(uint32_t), u32cmp);
    uint32_t* starts = malloc((n ? n : 1) * sizeof(uint32_t));
    for (uint32_t i = 0; i < n; i++)
        {
        starts[i] = b[i];
        NSString* nm = nameAt[@(b[i])];
        if (!nm)
            {
            nm = [NSString stringWithFormat:@".Lgcd$%u", b[i]];
            _syms[nm] = @(b[i]);
            [_dataSet addObject:nm];
            }
        [outName addObject:nm];
        }
    free(b);
    *outStart = starts;
    *outN = n;
    }

static uint32_t* endsOf(const uint32_t* starts, uint32_t n, uint32_t end)
    {
    uint32_t* e = malloc((n ? n : 1) * sizeof(uint32_t));
    for (uint32_t i = 0; i < n; i++)
        e[i] = (i + 1 < n) ? starts[i + 1] : end;
    return e;
    }
static uint32_t* objIdxOf(const uint32_t* starts, uint32_t n, const U32Vec* ranges)
    {
    uint32_t* o = malloc((n ? n : 1) * sizeof(uint32_t));
    uint32_t oi = 0, nobj = ranges->n / 2;
    for (uint32_t i = 0; i < n; i++)
        {
        while (oi + 1 < nobj && ranges->v[(oi + 1) * 2] <= starts[i])
            oi++;
        o[i] = oi;
        }
    return o;
    }

- (void)runWithText:(NSMutableData*)text data:(NSMutableData*)data
            symbols:(NSMutableDictionary<NSString*, NSNumber*>*)syms
        dataSymbols:(NSMutableSet<NSString*>*)dataSyms
         bssSymbols:(NSArray<NSString*>*)bssSyms
             fixups:(NSMutableArray<XAX86_64Fixup*>*)fixups
        seedTextEnd:(uint64_t)seedTextEnd
        seedDataEnd:(uint64_t)seedDataEnd
              entry:(NSString*)entry
    {
    _syms = syms;
    _dataSet = dataSyms;
    _bssSet = [NSMutableSet setWithArray:bssSyms];
    _text = text.bytes;

    // 1. Units.
    NSMutableDictionary<NSNumber*, NSString*>* tNameAt = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSString*>* dNameAt = [NSMutableDictionary dictionary];
    for (NSString* nm in syms.allKeys)
        {
        uint32_t off = (uint32_t)syms[nm].unsignedLongLongValue;
        if ([_bssSet containsObject:nm])
            continue;
        BOOL isData = [dataSyms containsObject:nm];
        if (isData ? (off < seedDataEnd) : (off < seedTextEnd))
            continue;
        NSMutableDictionary<NSNumber*, NSString*>* nameAt = isData ? dNameAt : tNameAt;
        NSString* prev = nameAt[@(off)];
        if (!prev || strcmp(nm.UTF8String, prev.UTF8String) < 0)
            nameAt[@(off)] = nm;
        }
    // Dead-DATA elimination (Stage D) is OBJECT-granular, NOT per-symbol. This
    // ABI dispatches methods as `vtable + <global-selector-offset>` with NO
    // relocation, so a data object (a vtable and its method table) is indexed
    // by computed runtime offsets that cross symbol boundaries but NEVER cross
    // an OBJECT boundary. So the data GC unit is the whole object's data
    // region: kept byte-exact (only its base moves, a uniform delta — every
    // runtime offset inside it stays valid) or dropped whole. That reclaims the
    // duplicate copies a split build carries without shifting a live slot out
    // from under an index (bug 200). Mirror of MergedImage.gcDead.
    _tName = [NSMutableArray array];
    _dName = [NSMutableArray array];
    [self unitsFrom:&_tBounds prefixEnd:(uint32_t)seedTextEnd nameAt:tNameAt isData:NO outStart:&_tStart outName:_tName count:&_ntu];
    if (_ntu == 0)
        {
        free(_tStart);
        return;
        }
    uint32_t textEnd = (uint32_t)text.length;
    uint32_t tPrefix = _tStart[0];
    _tEnd = endsOf(_tStart, _ntu, textEnd);
    uint32_t* tObj = objIdxOf(_tStart, _ntu, &_objText);

    [self dataObjectUnits:(uint32_t)seedDataEnd nameAt:dNameAt outStart:&_dStart outName:_dName count:&_ndu];
    uint32_t dataEnd = (uint32_t)data.length;
    uint32_t dPrefix = _ndu > 0 ? _dStart[0] : dataEnd;
    _dEnd = endsOf(_dStart, _ndu, dataEnd);
    uint32_t* dObj = objIdxOf(_dStart, _ndu, &_objData);

    _tLive = calloc(_ntu, 1);
    _tGlue = calloc(_ntu, 1);
    _tFall = malloc(_ntu);
    memset(_tFall, 1, _ntu);
    _tWhy = calloc(_ntu, sizeof(uint32_t));
    _dLive = calloc(_ndu ? _ndu : 1, 1);
    _dGlue = calloc(_ndu ? _ndu : 1, 1);
    _dWhy = calloc(_ndu ? _ndu : 1, sizeof(uint32_t));
    uint32_t nobj = _objText.n / 2;
    uint8_t* objBad = calloc(nobj ? nobj : 1, 1);
    _edgeSrc = (U32Vec){0};
    _edgeTgt = (U32Vec){0};
    _work = (U32Vec){0};

    // Text-applied fixups by application offset: a decoded displacement that
    // has one is a relocation placeholder, not a resolved reference.
    U32Vec fixAtV = {0};
    for (XAX86_64Fixup* f in fixups)
        {
        if (f.kind == XAX86FixupAbs64 || f.kind == XAX86FixupPC32Data)
            continue;
        vpush(&fixAtV, (uint32_t)f.offset);
        }
    qsort(fixAtV.v, fixAtV.n, sizeof(uint32_t), u32cmp);

    // 2. Decode every text unit.
    _ripImm = [NSMutableDictionary dictionary];
    NSMutableArray<XAX86_64Fixup*>* synth = [NSMutableArray array];
    for (uint32_t i = 0; i < _ntu; i++)
        {
        uint32_t st = _tStart[i], en = _tEnd[i];
        uint32_t o = tObj[i];
        uint32_t os = _objText.v[o * 2], oe = _objText.v[o * 2 + 1];
        uint32_t p = st;
        BOOL ok = YES;
        BOOL lastRealTerm = NO;
        while (p < en)
            {
            if (_text[p] == 0)
                {
                uint32_t q = p;
                while (q < en && _text[q] == 0)
                    q++;
                if (q == en)
                    break;
                }
            uint32_t len = [self insnLenAt:p end:en];
            if (len == 0)
                {
                ok = NO;
                break;
                }
            if (!_lastNop)
                lastRealTerm = _lastTerm;
            uint32_t insnEnd = p + len;
            if (_lastRelPos != NONE)
                {
                if (_lastRelSize == 4)
                    {
                    if (!inSorted(fixAtV.v, fixAtV.n, _lastRelPos))
                        {
                        uint32_t tgt = insnEnd + (uint32_t)rd32s(_text, _lastRelPos);
                        [self ref:i target:tgt pos:_lastRelPos immAfter:0 rel8:NO objStart:os objEnd:oe synth:synth];
                        }
                    }
                else
                    {
                    uint32_t d8 = _text[_lastRelPos];
                    uint32_t tgt = insnEnd + (d8 >= 0x80 ? d8 - 0x100 : d8);
                    [self ref:i target:tgt pos:_lastRelPos immAfter:0 rel8:YES objStart:os objEnd:oe synth:synth];
                    }
                }
            if (_lastRipPos != NONE)
                {
                if (inSorted(fixAtV.v, fixAtV.n, _lastRipPos))
                    {
                    if (_lastImmSize != 0)
                        _ripImm[@((uint64_t)_lastRipPos)] = @(_lastImmSize);
                    }
                else
                    {
                    uint32_t tgt = insnEnd + (uint32_t)rd32s(_text, _lastRipPos);
                    [self ref:i target:tgt pos:_lastRipPos immAfter:_lastImmSize rel8:NO objStart:os objEnd:oe synth:synth];
                    }
                }
            p = insnEnd;
            }
        if (ok)
            _tFall[i] = lastRealTerm ? 0 : 1;
        else
            objBad[o] = 1;
        }
    for (uint32_t i = 0; i + 1 < _ntu; i++)
        if (objBad[tObj[i]] && tObj[i + 1] == tObj[i])
            _tGlue[i] = 1;
    [fixups addObjectsFromArray:synth];
    vfree(&fixAtV);

    // Jump-table bases: data offsets named by text fixups (`lea table(%rip)`).
    U32Vec tbl = {0};
    for (XAX86_64Fixup* f in fixups)
        {
        if (f.kind != XAX86FixupPC32 && f.kind != XAX86FixupRel32)
            continue;
        if (!f.symbol.length || ![dataSyms containsObject:f.symbol])
            continue;
        NSNumber* to = syms[f.symbol];
        if (!to)
            continue;
        vpush(&tbl, (uint32_t)to.unsignedLongLongValue + (uint32_t)(int32_t)f.addend + 4);
        }
    qsort(tbl.v, tbl.n, sizeof(uint32_t), u32cmp);
    _tblBase = tbl.v;
    _ntbl = tbl.n;

    // 3. Edges and roots, then the fixpoint.
    _markWhy = 1;
    NSNumber* eo = syms[entry];
    if (eo)
        [self markId:unitAt(_tStart, _ntu, (uint32_t)eo.unsignedLongLongValue)];
    for (XAX86_64Fixup* f in fixups)
        {
        uint32_t tgt = [self targetOf:f];
        if (tgt == NONE)
            continue;
        BOOL isDataFix = (f.kind == XAX86FixupAbs64 || f.kind == XAX86FixupPC32Data);
        if (isDataFix)
            {
            if (f.offset < dPrefix)
                {
                _markWhy = 2;
                [self markId:tgt];
                continue;
                }
            uint32_t src = unitAt(_dStart, _ndu, (uint32_t)f.offset);
            if (src != NONE)
                {
                vpush(&_edgeSrc, DATA_BIT | src);
                vpush(&_edgeTgt, tgt);
                }
            }
        else
            {
            if (f.offset < tPrefix)
                {
                _markWhy = 3;
                [self markId:tgt];
                continue;
                }
            uint32_t src = unitAt(_tStart, _ntu, (uint32_t)f.offset);
            if (src != NONE)
                {
                vpush(&_edgeSrc, src);
                vpush(&_edgeTgt, tgt);
                }
            }
        }
    // CSR adjacency over the unified index (text i -> i, data j -> ntu + j)
    uint32_t nall = _ntu + _ndu;
    uint32_t* deg = calloc(nall + 1, sizeof(uint32_t));
    for (uint32_t e = 0; e < _edgeSrc.n; e++)
        {
        uint32_t s = _edgeSrc.v[e];
        uint32_t idx = (s & DATA_BIT) ? _ntu + (s & ~DATA_BIT) : s;
        deg[idx + 1]++;
        }
    for (uint32_t i = 0; i < nall; i++)
        deg[i + 1] += deg[i];
    uint32_t* adj = malloc((_edgeSrc.n ? _edgeSrc.n : 1) * sizeof(uint32_t));
    uint32_t* fill = calloc(nall + 1, sizeof(uint32_t));
    for (uint32_t e = 0; e < _edgeSrc.n; e++)
        {
        uint32_t s = _edgeSrc.v[e];
        uint32_t idx = (s & DATA_BIT) ? _ntu + (s & ~DATA_BIT) : s;
        adj[deg[idx] + fill[idx]++] = _edgeTgt.v[e];
        }
    free(fill);
    uint32_t head = 0;
    while (head < _work.n)
        {
        uint32_t id = _work.v[head++];
        if (id & DATA_BIT)
            {
            uint32_t j = id & ~DATA_BIT;
            uint32_t idx = _ntu + j;
            _markWhy = 4;
            for (uint32_t e = deg[idx]; e < deg[idx + 1]; e++)
                [self markId:adj[e]];
            _markWhy = 7;
            if (j + 1 < _ndu && _dGlue[j])
                [self markId:DATA_BIT | (j + 1)];
            if (j > 0 && _dGlue[j - 1])
                [self markId:DATA_BIT | (j - 1)];
            continue;
            }
        uint32_t fi = id;
        _markWhy = 4;
        for (uint32_t e = deg[fi]; e < deg[fi + 1]; e++)
            [self markId:adj[e]];
        _markWhy = 7;
        if (fi + 1 < _ntu && _tGlue[fi])
            [self markId:fi + 1];
        if (fi > 0 && _tGlue[fi - 1])
            [self markId:fi - 1];
        _markWhy = 6;
        if (fi + 1 < _ntu && _tFall[fi])
            [self markId:fi + 1];
        }
    free(deg);
    free(adj);
    vfree(&_edgeSrc);
    vfree(&_edgeTgt);
    vfree(&_work);

    // 4. Rewrite section-relative fixups (.Lsec + addend) to UNIT-relative,
    //    using OLD offsets, BEFORE the symbol remap.
    for (XAX86_64Fixup* f in fixups)
        {
        NSString* sym = f.symbol;
        if (!sym.length || ![sym hasPrefix:@".Lsec"])
            continue;
        if ([_bssSet containsObject:sym])
            continue;
        NSNumber* to = syms[sym];
        if (!to)
            continue;
        uint32_t base = (uint32_t)to.unsignedLongLongValue;
        BOOL toData = [dataSyms containsObject:sym];
        uint32_t raw = base + (uint32_t)(int32_t)f.addend;
        uint32_t actual = [self actualOf:f base:base toText:!toData];
        uint32_t tf = toData ? unitAt(_dStart, _ndu, actual) : unitAt(_tStart, _ntu, actual);
        if (tf == NONE)
            continue;
        const uint32_t* starts = toData ? _dStart : _tStart;
        NSArray<NSString*>* names = toData ? _dName : _tName;
        f.symbol = names[tf];
        f.addend = (int64_t)(int32_t)(raw - starts[tf]);
        }

    if (getenv("XCC_GC_STATS"))
        [self statsWithTObj:tObj dObj:dObj objBad:objBad nsynth:(uint32_t)synth.count textEnd:textEnd tPrefix:tPrefix dataEnd:dataEnd dPrefix:dPrefix];

    // 5. Compaction.
    NSMutableData* nt = [NSMutableData dataWithCapacity:textEnd];
    [nt appendBytes:_text length:tPrefix];
    NSMutableDictionary<NSNumber*, NSNumber*>* tBase = [NSMutableDictionary dictionary];
    for (uint32_t i = 0; i < _ntu; i++)
        {
        if (!_tLive[i])
            continue;
        BOOL cont = (i > 0) && _tLive[i - 1] && (_tFall[i - 1] || _tGlue[i - 1]);
        uint32_t st = _tStart[i], en = _tEnd[i];
        if (!cont)
            {
            uint8_t z = 0;
            while (nt.length % 64 != st % 64)
                [nt appendBytes:&z length:1];
            }
        tBase[@(st)] = @(nt.length);
        [nt appendBytes:_text + st length:en - st];
        }
    const uint8_t* dp = data.bytes;
    NSMutableData* nd = [NSMutableData dataWithCapacity:dataEnd];
    [nd appendBytes:dp length:dPrefix];
    NSMutableDictionary<NSNumber*, NSNumber*>* dBase = [NSMutableDictionary dictionary];
    for (uint32_t j = 0; j < _ndu; j++)
        {
        if (!_dLive[j])
            continue;
        BOOL cont = (j > 0) && _dLive[j - 1] && _dGlue[j - 1];
        uint32_t st = _dStart[j], en = _dEnd[j];
        if (!cont)
            {
            uint32_t al = _objDataAlign.v[dObj[j]];
            if (al < 64)
                al = 64;
            uint8_t z = 0;
            while (nd.length % al != st % al)
                [nd appendBytes:&z length:1];
            }
        dBase[@(st)] = @(nd.length);
        [nd appendBytes:dp + st length:en - st];
        }

    // 6. Remap symbols (drop the dead); bss/TLS/seed symbols unchanged.
    for (NSString* nm in syms.allKeys)
        {
        if ([_bssSet containsObject:nm])
            continue;
        uint32_t off = (uint32_t)syms[nm].unsignedLongLongValue;
        BOOL isData = [dataSyms containsObject:nm];
        if (isData ? (off < dPrefix) : (off < tPrefix))
            continue;
        uint32_t fi = isData ? unitAt(_dStart, _ndu, off) : unitAt(_tStart, _ntu, off);
        if (fi == NONE)
            continue;
        const uint8_t* liveA = isData ? _dLive : _tLive;
        const uint32_t* starts = isData ? _dStart : _tStart;
        NSDictionary<NSNumber*, NSNumber*>* bases = isData ? dBase : tBase;
        if (!liveA[fi])
            {
            [syms removeObjectForKey:nm];
            continue;
            }
        uint32_t ust = starts[fi];
        uint32_t nb = bases[@(ust)].unsignedIntValue;
        syms[nm] = @(nb + (off - ust));
        }

    // 7. Remap fixup application offsets (drop the dead units'); seed ones unchanged.
    NSMutableArray<XAX86_64Fixup*>* nf2 = [NSMutableArray arrayWithCapacity:fixups.count];
    for (XAX86_64Fixup* f in fixups)
        {
        BOOL isDataFix = (f.kind == XAX86FixupAbs64 || f.kind == XAX86FixupPC32Data);
        uint32_t app = (uint32_t)f.offset;
        if (isDataFix ? (app < dPrefix) : (app < tPrefix))
            {
            [nf2 addObject:f];
            continue;
            }
        uint32_t fi = isDataFix ? unitAt(_dStart, _ndu, app) : unitAt(_tStart, _ntu, app);
        if (fi == NONE)
            {
            [nf2 addObject:f];
            continue;
            }
        const uint8_t* liveA = isDataFix ? _dLive : _tLive;
        const uint32_t* starts = isDataFix ? _dStart : _tStart;
        NSDictionary<NSNumber*, NSNumber*>* bases = isDataFix ? dBase : tBase;
        if (!liveA[fi])
            continue;
        uint32_t ust = starts[fi];
        uint32_t nb = bases[@(ust)].unsignedIntValue;
        f.offset = nb + (app - ust);
        [nf2 addObject:f];
        }
    [fixups setArray:nf2];
    [text setData:nt];
    [data setData:nd];

    free(_tStart);
    free(_tEnd);
    free(_dStart);
    free(_dEnd);
    free(tObj);
    free(dObj);
    free(_tLive);
    free(_dLive);
    free(_tGlue);
    free(_dGlue);
    free(_tFall);
    free(_tWhy);
    free(_dWhy);
    free(objBad);
    free(_tblBase);
    _tblBase = NULL;
    _ntbl = 0;
    _text = NULL;
    _syms = nil;
    _dataSet = nil;
    _bssSet = nil;
    _ripImm = nil;
    }

- (void)statsWithTObj:(const uint32_t*)tObj dObj:(const uint32_t*)dObj objBad:(const uint8_t*)objBad nsynth:(uint32_t)nsynth
              textEnd:(uint32_t)textEnd
              tPrefix:(uint32_t)tPrefix
              dataEnd:(uint32_t)dataEnd
              dPrefix:(uint32_t)dPrefix
    {
    uint32_t nobj = _objText.n / 2;
    uint32_t tl = 0, tk = 0, ng = 0, nfl = 0, bad = 0;
    uint32_t tw[8] = {0}, dw[8] = {0};
    uint32_t *objT = calloc(nobj ? nobj : 1, sizeof(uint32_t)), *objD = calloc(nobj ? nobj : 1, sizeof(uint32_t));
    for (uint32_t i = 0; i < _ntu; i++)
        {
        uint32_t sz = _tEnd[i] - _tStart[i];
        if (_tGlue[i])
            ng++;
        if (_tFall[i])
            nfl++;
        if (!_tLive[i])
            continue;
        tl++;
        tk += sz;
        tw[_tWhy[i]] += sz;
        objT[tObj[i]] += sz;
        if (objBad[tObj[i]])
            bad += sz;
        }
    uint32_t dl = 0, dk = 0;
    for (uint32_t j = 0; j < _ndu; j++)
        {
        uint32_t sz = _dEnd[j] - _dStart[j];
        if (!_dLive[j])
            continue;
        dl++;
        dk += sz;
        dw[_dWhy[j]] += sz;
        objD[dObj[j]] += sz;
        }
    uint32_t nbad = 0;
    for (uint32_t i = 0; i < nobj; i++)
        if (objBad[i])
            nbad++;
    printf("gc: text=%u prefix=%u units=%u live=%u kept=%u dropped=%u synth=%u glue=%u fall=%u badobjs=%u/%u badbytes=%u\n",
           textEnd, tPrefix, _ntu, tl, tk, textEnd - tPrefix - tk, nsynth, ng, nfl, nbad, nobj, bad);
    printf("gc: text kept by reason: entry=%u dataroot=%u seedroot=%u edge=%u fall=%u glue=%u\n",
           tw[1], tw[2], tw[3], tw[4], tw[6], tw[7]);
    printf("gc: data=%u prefix=%u units=%u live=%u kept=%u dropped=%u\n", dataEnd, dPrefix, _ndu, dl, dk, dataEnd - dPrefix - dk);
    printf("gc: data kept by reason: dataroot=%u seedroot=%u edge=%u glue=%u\n", dw[2], dw[3], dw[4], dw[7]);
    const char* mode = getenv("XCC_GC_STATS");
    if (strcmp(mode, "objs") == 0)
        {
        for (uint32_t i = 0; i < nobj; i++)
            {
            uint32_t tt = _objText.v[i * 2 + 1] - _objText.v[i * 2];
            uint32_t dt = _objData.v[i * 2 + 1] - _objData.v[i * 2];
            if (!objT[i] && !objD[i])
                continue;
            printf("gc-obj: text=%u/%u data=%u/%u bad=%u %s\n", objT[i], tt, objD[i], dt, (unsigned)objBad[i], _objLabel[i].UTF8String);
            }
        }
    if (strcmp(mode, "units") == 0)
        {
        for (uint32_t i = 0; i < _ntu; i++)
            {
            if (!_tLive[i])
                continue;
            printf("gc-text: why=%u size=%u fall=%u glue=%u %s\n", _tWhy[i], _tEnd[i] - _tStart[i], (unsigned)_tFall[i], (unsigned)_tGlue[i], _tName[i].UTF8String);
            }
        for (uint32_t j = 0; j < _ndu; j++)
            {
            if (!_dLive[j])
                continue;
            printf("gc-data: why=%u size=%u glue=%u %s\n", _dWhy[j], _dEnd[j] - _dStart[j], (unsigned)_dGlue[j], _dName[j].UTF8String);
            }
        }
    free(objT);
    free(objD);
    }

@end
