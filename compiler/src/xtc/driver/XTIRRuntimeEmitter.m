#import "XTIRRuntimeEmitter.h"
#import "XTIRFunction.h"
#import "XTIRSymbol.h"
#import "XTMemoryModel.h"

// The resolved xtc home (from -H / $XTC_HOME / cwd / install dirs). Runtime
// harness + asm templates live under it (tests/corpus/…, xt6502/asm/…);
// resolving against it makes the xt6502 build CWD-independent. nil ⇒ fall back
// to the historical cwd-relative behaviour (the in-process corpus runs from the
// repo root, so that path still works untouched).
static NSString* sSupportRoot = nil;

@implementation XTIRRuntimeEmitter

+ (void)setSupportRoot:(nullable NSString*)root
    {
    sSupportRoot = [root copy];
    }

// `relPath` is relative to the SUPPORT ROOT (the directory holding xt6502/,
// generic/, ...), not to the home above it — the two are the same thing in a
// source tree and different in an install, which is the whole reason the
// support root is resolved once and passed in.
+ (NSString*)readTemplateAtPath:(NSString*)relPath
    {
    NSFileManager* fm = [NSFileManager defaultManager];
    // 1) under the resolved support root (CWD-independent).
    if (sSupportRoot.length)
        {
        NSString* p = [sSupportRoot stringByAppendingPathComponent:relPath];
        if ([fm isReadableFileAtPath:p])
            {
            NSString* s = [NSString stringWithContentsOfFile:p
                                                    encoding:NSUTF8StringEncoding
                                                       error:NULL];
            if (s)
                return s;
            }
        }
    // 2) cwd-relative under support/, then a one-level-up fallback — the
    //    development tree, where the support root IS ./support.
    NSString* cwdRel = [@"support" stringByAppendingPathComponent:relPath];
    NSString* s = [NSString stringWithContentsOfFile:cwdRel
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    if (!s)
        {
        s = [NSString stringWithContentsOfFile:
                          [@"../support" stringByAppendingPathComponent:relPath]
                                      encoding:NSUTF8StringEncoding
                                         error:NULL];
        }
    return s ?: @"";
    }

+ (void)appendBankedRuntimeThunksInto:(NSMutableString*)out
                           entryNames:(NSArray<NSString*>*)entryNames
                           bankSymbol:(NSString*)bankSymbol
    {
    for (NSString* n in entryNames)
        {
        [out appendFormat:
                 @"_%@:\n"
                 @"    LDA #<%@\n    STA _xcall_vec\n"
                 @"    LDA #>%@\n    STA _xcall_vec+1\n"
                 @"    LDA #%@\n    STA _xc_bank\n"
                 @"    JMP _xcall\n",
                 n, n, n, bankSymbol];
        }
    }

+ (NSString*)wrapXt6502Asm:(NSString*)generatedAsm
                 forModule:(XTIRModule*)mod
               memoryModel:(XTMemoryModel*)model
               harnessPath:(NSString*)harnessPath
    {
    NSMutableString* out = [NSMutableString string];
    NSString* harness = [self readTemplateAtPath:harnessPath];
    // The base harness ships degenerate weak no-op stubs. When the program
    // actually uses weak refs, strip them so the real side-table adapters
    // emitted below (gated on the same condition) don't collide. (#6)
    if ([generatedAsm containsString:@"JSR __xtc_weak_register"] || [generatedAsm containsString:@"JSR __xtc_weak_unregister"])
        {
        harness = [harness stringByReplacingOccurrencesOfString:
                               @"__xtc_weak_register:\n    RTS\n__xtc_weak_unregister:\n    RTS\n"
                               @"__xtc_weak_load:\n    LDA #0\n    LDX #0\n    TAY\n    RTS\n"
                                                     withString:@"; (weak no-op stubs replaced by the real side-table)\n"];
        }
    [out appendString:harness];
    [out appendString:@"\n"];

    static NSDictionary<NSString*, NSNumber*>* primElemWidths;
    static dispatch_once_t onceXt;
    dispatch_once(&onceXt, ^{
      primElemWidths = @{
          @"bool" : @1,
          @"i8" : @1,
          @"u8" : @1,
          @"i16" : @2,
          @"u16" : @2,
          @"i32" : @4,
          @"u32" : @4,
          @"pointer" : @3,
          @"string" : @3,
          // FOUR, not five. Five was the width of the bespoke float
          // format retired when the language moved to IEEE binary32 on
          // every target; the back end was updated and this table was
          // not (private:docs/bugs/073). It over-allocated by 25% and, because
          // 5 is not a power of two, emitted the repeated-addition
          // stride path instead of two shifts.
          @"float" : @4,
          @"double" : @8,
      };
    });
    for (XTIRSymbol* sym in mod.symbols)
        {
        if (sym.kind != XTIRSymbolKindRuntimeHelper)
            continue;
        if (![sym.name hasPrefix:@"_xtc_new_"])
            continue;
        NSString* suffix = [sym.name substringFromIndex:@"_xtc_new_".length];
        NSNumber* widthNum = primElemWidths[suffix];
        if (widthNum)
            {
            NSUInteger w = widthNum.unsignedIntegerValue;
            NSUInteger shift = 0;
            NSUInteger tmp = w;
            while ((tmp & 1) == 0 && tmp > 1)
                {
                shift++;
                tmp >>= 1;
                }
            BOOL isPowerOfTwo = (tmp == 1);

            NSMutableString* stub = [NSMutableString string];
            [stub appendFormat:@"_%@:\n", sym.name];
            if (isPowerOfTwo && shift == 0)
                {
                [stub appendString:@"    LDA +3,SP\n"
                                   @"    LDX +4,SP\n"
                                   @"    JMP _heap_alloc16\n"];
                }
            else if (isPowerOfTwo)
                {
                [stub appendString:@"    LDA +3,SP\n"
                                   @"    TAX\n"
                                   @"    LDA +4,SP\n"];
                for (NSUInteger b = 0; b < shift; b++)
                    {
                    [stub appendString:@"    ASL A\n"
                                       @"    PHA\n"
                                       @"    TXA\n"
                                       @"    ROL A\n"
                                       @"    TAX\n"
                                       @"    PLA\n"];
                    }
                [stub appendString:@"    STX _tmp\n"
                                   @"    ADC #$00\n"
                                   @"    TAX\n"
                                   @"    LDA _tmp\n"
                                   @"    JMP _heap_alloc16\n"];
                }
            else
                {
                NSUInteger nbW = widthNum.unsignedIntegerValue;
                [stub appendString:@"    LDA +3,SP\n"
                                   @"    STA _tmp\n"
                                   @"    LDA +4,SP\n"
                                   @"    STA _tmp+1\n"];
                for (NSUInteger r = 1; r < nbW; r++)
                    {
                    [stub appendString:@"    CLC\n"
                                       @"    LDA _tmp\n"
                                       @"    ADC +3,SP\n"
                                       @"    STA _tmp\n"
                                       @"    LDA _tmp+1\n"
                                       @"    ADC +4,SP\n"
                                       @"    STA _tmp+1\n"];
                    }
                [stub appendString:@"    LDA _tmp\n"
                                   @"    LDX _tmp+1\n"
                                   @"    JMP _heap_alloc16\n"];
                }
            [out appendString:stub];
            continue;
            }
        NSString* className = suffix;
        NSString* deallocName = [NSString stringWithFormat:@"%@$dealloc", className];
        BOOL hasDealloc = NO;
        for (XTIRFunction* fn in mod.functions)
            {
            if ([fn.name isEqualToString:deallocName])
                {
                hasDealloc = YES;
                break;
                }
            }
        if (hasDealloc)
            {
            [out appendFormat:
                     @"_%@:\n"
                     @"    LDX #$00\n"
                     @"    LDA #$40\n"
                     @"    JSR _heap_alloc16\n"
                     @"    STA $90\n"
                     @"    STX $91\n"
                     @"    STY $92\n"
                     @"    STY __bank_data_reg\n"
                     @"    LDA $90\n"
                     @"    STA $98\n"
                     @"    LDA $91\n"
                     @"    STA $99\n"
                     @"    LDY #xtc_desc_off\n"
                     @"    LDA #__dbank_%@$dealloc\n"
                     @"    STA ($98),Y\n"
                     @"    INY\n"
                     @"    LDA #<_%@$dealloc\n"
                     @"    STA ($98),Y\n"
                     @"    INY\n"
                     @"    LDA #>_%@$dealloc\n"
                     @"    STA ($98),Y\n"
                     @"    LDY #56\n"
                     @"    LDA +5,SP\n"
                     @"    STA ($98),Y\n"
                     @"    INY\n"
                     @"    LDA +6,SP\n"
                     @"    STA ($98),Y\n"
                     @"    INY\n"
                     @"    LDA +3,SP\n"
                     @"    STA ($98),Y\n"
                     @"    INY\n"
                     @"    LDA +4,SP\n"
                     @"    STA ($98),Y\n"
                     @"    LDA #$00\n"
                     @"    STA __bank_data_reg\n"
                     @"    LDA $90\n"
                     @"    LDX $91\n"
                     @"    LDY $92\n"
                     @"    RTS\n",
                     sym.name, className, className, className];
            }
        else
            {
            [out appendFormat:
                     @"_%@:\n"
                     @"    LDX #$00\n"
                     @"    LDA #$40\n"
                     @"    JSR _heap_alloc16\n"
                     @"    STA $90\n"
                     @"    STX $91\n"
                     @"    STY $92\n"
                     @"    STY __bank_data_reg\n"
                     @"    LDA $90\n"
                     @"    STA $98\n"
                     @"    LDA $91\n"
                     @"    STA $99\n"
                     @"    LDA #$00\n"
                     @"    LDY #xtc_desc_off\n"
                     @"    STA ($98),Y\n"
                     @"    INY\n"
                     @"    STA ($98),Y\n"
                     @"    INY\n"
                     @"    STA ($98),Y\n"
                     @"    STA __bank_data_reg\n"
                     @"    LDA $90\n"
                     @"    LDX $91\n"
                     @"    LDY $92\n"
                     @"    RTS\n",
                     sym.name];
            }
        }
    // B1: the single generic class allocator. `new T` lowers to
    // `_xtc_alloc(count, stride, deallocPtr)`; one allocator serves every class
    // (the per-class loop above now fires only for primitive-element arrays).
    // Args on the hw stack (little-endian): count @+3,+4; stride @+5,+6;
    // deallocPtr (3-byte banked fn ptr) lo@+7, hi@+8, bank@+9. The descriptor
    // at obj+60 is [bank, lo, hi] (the order __xtc_release reads); a null
    // deallocPtr → all-zero → the no-destructor sentinel. The dealloc fn now
    // carries its code bank (stage 2), so it can stay banked.
    BOOL usesAlloc = NO;
    for (XTIRSymbol* sym in mod.symbols)
        {
        if (sym.kind == XTIRSymbolKindRuntimeHelper && [sym.name isEqualToString:@"_xtc_alloc"])
            {
            usesAlloc = YES;
            break;
            }
        }
    if (usesAlloc)
        {
        [out appendString:
                 @"__xtc_alloc:\n"
                 @"    LDX #$00\n    LDA #$40\n    JSR _heap_alloc16\n"
                 @"    STA $90\n    STX $91\n    STY $92\n    STY __bank_data_reg\n"
                 @"    LDA $90\n    STA $98\n    LDA $91\n    STA $99\n"
                 @"    LDY #xtc_desc_off\n"
                 @"    LDA +9,SP\n    STA ($98),Y\n"          // descriptor bank   <- deallocPtr bank
                 @"    INY\n    LDA +7,SP\n    STA ($98),Y\n" // descriptor lo  <- deallocPtr lo
                 @"    INY\n    LDA +8,SP\n    STA ($98),Y\n" // descriptor hi  <- deallocPtr hi
                 @"    LDY #56\n"
                 @"    LDA +5,SP\n    STA ($98),Y\n"          // cookie elemSize lo
                 @"    INY\n    LDA +6,SP\n    STA ($98),Y\n" // cookie elemSize hi
                 @"    INY\n    LDA +3,SP\n    STA ($98),Y\n" // cookie count lo
                 @"    INY\n    LDA +4,SP\n    STA ($98),Y\n" // cookie count hi
                 @"    LDA #$00\n    STA __bank_data_reg\n"
                 @"    LDA $90\n    LDX $91\n    LDY $92\n    RTS\n"];
        }
    for (XTIRSymbol* sym in mod.symbols)
        {
        if (sym.kind != XTIRSymbolKindRuntimeHelper)
            continue;
        if (![sym.name isEqualToString:@"_xtc_bank"])
            continue;
        // bank(type, idx) → 3-byte banked pointer (A=lo, X=hi, Y=idx) to
        // byte 0 of the data ($D5C1) or code ($D5C0) window in bank `idx`.
        // Window high bytes come from the layout, not hardcoded. For a
        // DATA bank, also mark `idx` claimed in the shared bitmap (when the
        // heap is on-demand) so the heap never hands out the same page —
        // this is how bank() and the heap coexist.
        uint8_t dataWinHi = (uint8_t)(model.dataWindowStart >> 8);
        uint8_t codeWinHi = (uint8_t)(model.bankWindowStart >> 8);
        [out appendFormat:
                 @"__xtc_bank:\n"
                 @"    LDA +4,SP\n"
                 @"    TAY\n" // Y = idx (bank byte)
                 @"    LDA +3,SP\n"
                 @"    BEQ __xb_data\n"
                 @"    CMP #$01\n"
                 @"    BEQ __xb_code\n"
                 @"    LDA #$00\n"
                 @"    LDX #$00\n"
                 @"    LDY #$00\n"
                 @"    RTS\n"
                 @"__xb_data:\n"
                 @"    LDA #heap_bank_dynamic\n" // shared bitmap present?
                 @"    BEQ __xb_data_ret\n"
                 @"    TYA\n" // reserve data bank idx so the
                 @"    PHA\n" //   on-demand heap avoids it
                 @"    JSR _bank_set\n"
                 @"    PLA\n"
                 @"    TAY\n"
                 @"__xb_data_ret:\n"
                 @"    LDA #$00\n"
                 @"    LDX #$%02X\n"
                 @"    RTS\n"
                 @"__xb_code:\n"
                 @"    LDA #$00\n"
                 @"    LDX #$%02X\n"
                 @"    RTS\n",
                 dataWinHi, codeWinHi];
        break;
        }

    // Heap config — sourced from the layout (xt.lnk [heap] + [banking]
    // dataPageSize), never hardcoded. heap_total_bytes = page count ×
    // page size, as a 32-bit little-endian value (Heap.totalSize()).
    uint32_t heapPages = (model.heapBankEnd >= model.heapBank && model.heapBank)
                             ? (uint32_t)(model.heapBankEnd - model.heapBank + 1)
                             : 0;
    uint32_t heapTotal = heapPages * (uint32_t)model.dataPageSize;
    [out appendString:@"\n; ── banked free-list heap config (from layout) ──\n"];
    [out appendFormat:
             @"heap_bank_first = $%02X\n"
             @"heap_bank_last  = $%02X\n"
             @"heap_bank_dynamic = $%02X\n" // 1 = claim banks on demand
             @"regC_heap_bank_first = $00\n"
             @"regC_heap_bank_last  = $00\n"
             @"heap_low  = $%04X\n"
             @"heap_end  = $%04X\n"
             @"regC_heap_low = $0000\n"
             @"regC_heap_end = $0000\n"
             @"heap_total_bytes    = $%04X\n"
             @"heap_total_bytes_b2 = $%02X\n"
             @"heap_total_bytes_b3 = $%02X\n",
             model.heapBank, model.heapBankEnd,
             model.heapBankDynamic ? 1 : 0,
             model.heapLow, model.heapTop,
             (unsigned)(heapTotal & 0xFFFF),
             (unsigned)((heapTotal >> 16) & 0xFF),
             (unsigned)((heapTotal >> 24) & 0xFF)];
    [out appendString:
             @"_tmp: .byte $00, $00\n"];

    // ── Lazy-link gate (size). Only embed the heap + ARC + bank runtime
    // when the program actually reaches it. A pure-computation program
    // (no new/delete, no retain/release) drops ~1.4 KB of unreferenced
    // runtime, matching the legacy path's lazy linking. The harness's own
    // _heap_init call and ARC retain/release/dealloc stubs are stripped to
    // match (markers @@LL-...@@, removed at the end of this method).
    // `generatedAsm` is the user backend code; the per-class / primitive
    // `new` stubs emitted above call _heap_alloc16, so any `new` symbol in
    // the module forces the heap in even when the user code only JSRs the
    // class stub (which lives outside generatedAsm). ARC's release path
    // frees through the heap, so usesARC implies usesHeap.
    BOOL (^refs)(NSString*) = ^BOOL(NSString* s) {
      return [generatedAsm rangeOfString:s].location != NSNotFound;
    };
    BOOL usesARC = refs(@"JSR __xtc_retain") || refs(@"JSR __xtc_release") || refs(@"JSR __xtc_dealloc") || refs(@"JSR _obj_");
    BOOL hasNewSymbol = NO;
    for (XTIRSymbol* s in mod.symbols)
        if (s.kind == XTIRSymbolKindRuntimeHelper && [s.name hasPrefix:@"_xtc_new_"])
            {
            hasNewSymbol = YES;
            break;
            }
    BOOL usesHeap = usesARC || hasNewSymbol || refs(@"JSR _heap_alloc") || refs(@"JSR _heap_free") || refs(@"JSR _xtc_new_")
                    // `new` for a class local lowers to the generic `_xtc_alloc`
                    // (asm `JSR __xtc_alloc`); a program that calls it needs the
                    // heap even if it takes NO retain/release (e.g. a bare class
                    // local `C c = new C()` that ARC doesn't strong-manage). Without
                    // this, the heap runtime + `_heap_init` were stripped and `new`
                    // ran on an uninitialised free-list → garbage pointer → crash
                    // (bug 019, xt6502; masked on arm64 which always links libxt).
                    || refs(@"JSR __xtc_alloc");
    // The bank() intrinsic claims data banks through the same bitmap
    // allocator the heap uses (__xtc_bank → _bank_set), so it needs the
    // bank allocator even with no heap.
    BOOL usesBank = refs(@"JSR __xtc_bank") || refs(@"JSR _bank_");
    // Weak references: the backend emits JSR __xtc_weak_register/unregister
    // for `weak:T@` ivar stores. When present, link weak.asm's side-table
    // and arm retain.asm's zero-on-dealloc hook (private:docs/bugs/011 #6).
    BOOL usesWeak = refs(@"JSR __xtc_weak_register") || refs(@"JSR __xtc_weak_unregister");

    // {{zp.hp}}/{{zp.tmp}} live inside the layout's arc-scratch window
    // ($90-$99): the heap walk pointer at arc+6, the secondary pointer
    // at arc+8 (see xt.lnk's arc-scratch breakdown).
    uint16_t zpHp = model.zpArcScratchStart + 6;
    uint16_t zpTmp = model.zpArcScratchStart + 8;

    if (usesHeap || usesBank)
        {
        // Shared data-bank ownership bitmap — _bank_init / _bank_claim /
        // _bank_free that the on-demand heap and bank() use, plus the xt
        // bank driver.
        NSString* bankAlloc = [self readTemplateAtPath:@"xt6502/asm/heap/bank-alloc.asm"];
        [out appendString:bankAlloc];
        [out appendString:@"\n"];
        NSString* bankXt = [self readTemplateAtPath:@"xt6502/asm/heap/bank-xt.asm"];
        [out appendString:bankXt];
        [out appendString:@"\n"];
        }
    if (usesHeap)
        {
        NSString* heapSrc = [self readTemplateAtPath:@"xt6502/asm/heap/heap.asm"];
        heapSrc = [heapSrc stringByReplacingOccurrencesOfString:@"{{zp.hp}}"
                                                     withString:[NSString stringWithFormat:@"$%02X", zpHp]];
        heapSrc = [heapSrc stringByReplacingOccurrencesOfString:@"{{zp.tmp}}"
                                                     withString:[NSString stringWithFormat:@"$%02X", zpTmp]];
        [out appendString:@"\n"];
        [out appendString:heapSrc];
        [out appendString:@"\n"];
        }
    if (usesARC)
        {
        NSString* retainSrc = [self readTemplateAtPath:@"xt6502/asm/heap/retain.asm"];
        retainSrc = [retainSrc stringByReplacingOccurrencesOfString:@"{{zp.tmp}}"
                                                         withString:[NSString stringWithFormat:@"$%02X", zpTmp]];
        retainSrc = [retainSrc stringByReplacingOccurrencesOfString:@"{{weak.zeroAllHook}}"
                                                         withString:usesWeak ? @"JSR _weak_zero_all_for"
                                                                             : @"; (driver: no weak side-table)"];
        retainSrc = [retainSrc stringByReplacingOccurrencesOfString:@"{{heap.objBankStash}}"
                                                         withString:@"STY _obj_bank"];
        [out appendString:retainSrc];
        [out appendString:@"\n"];
        }

        // ── 64-bit integer pack, linked ONLY when referenced ──────────────
        // The i8/i16/i32 mul/div/mod pack above is included unconditionally: it is
        // small and nearly every program touches some of it. The 64-bit routines
        // are neither — a shift-and-add multiply and a restoring divide at eight
        // bytes are several hundred bytes each, and a program that never says i64
        // should not carry them. So they are pulled in the same way the heap and
        // ARC runtimes are: by scanning the generated asm for the calls.
        {
        NSArray<NSString*>* pack64 = @[
            @"u64/u64Add",
            @"u64/u64Sub",
            @"u64/u64Mul",
            @"u64/u64Div",
            @"u64/u64Mod",
            @"i64/i64Add",
            @"i64/i64Sub",
            @"i64/i64Mul",
            @"i64/i64Div",
            @"i64/i64Mod",
            @"i64/i64Abs",
        ];
        // The three shifts share one file — the back end calls them by the
        // unsigned name at every width, and they are useless separately.
        NSArray<NSString*>* shift64 = @[ @"u64Shl", @"u64LShr", @"u64AShr" ];
        NSMutableString* inc = [NSMutableString string];
        NSMutableString* alias = [NSMutableString string];
        for (NSString* rel in pack64)
            {
            NSString* name = rel.pathComponents.lastObject; // e.g. u64Mul
            if (!refs([NSString stringWithFormat:@"JSR _%@", name]))
                continue;
            [inc appendFormat:@".include \"xt6502/asm/%@.asm\"\n", rel];
            [alias appendFormat:@"_%@ = %@\n", name, name];
            }
        // The signed routines defer to their unsigned siblings, and Mod defers
        // to Div, so pull those in whenever a caller was found even if the
        // generated code never names them directly.
        for (NSString* name in shift64)
            {
            if (!refs([NSString stringWithFormat:@"JSR _%@", name]))
                continue;
            if ([inc rangeOfString:@"u64Shifts"].location == NSNotFound)
                [inc appendString:@".include \"xt6502/asm/u64/u64Shifts.asm\"\n"];
            // No alias: unlike the arithmetic routines, these are already
            // labelled `_u64Shl` etc., exactly as the back end calls them.
            }
        if (inc.length)
            {
            // CLOSE THE DEPENDENCY GRAPH. A routine reaches its siblings by
            // their BARE label — `i64Mod` does `JSR i64Div`, and the signed
            // add/sub/mul TAIL-CALL their unsigned twin with `JMP u64Add` —
            // so scanning the generated asm can never see those edges, and a
            // callee left out resolves to $0000. This used to be a flat
            // force-include of the four unsigned routines, which happened to
            // cover the JMP edges and missed i64Mod -> i64Div entirely: `i64 %`
            // linked i64Mod.asm whose `JSR i64Div` dangled, and the program
            // BRK'd at the first modulo, printing nothing at all. Found by the
            // differential fuzzer (seeds 960075, 960203).
            //
            // The edges are a TABLE, not a scan of the .asm files: this method
            // runs both in-process (the corpus sweep) and in xcc-cg-6502, and
            // sSupportRoot is not the same in both, so a file read that works
            // in one silently returns nil in the other — which is exactly how
            // the first version of this fix passed the subprocess path and
            // regressed int64_ops in-process. Re-derive the table with:
            //   grep -oE "J(SR|MP) _?[a-zA-Z][a-zA-Z0-9_]*" support/xt6502/asm/{i,u}64/*.asm
            NSDictionary<NSString*, NSArray<NSString*>*>* callees = @{
                @"i64/i64Add" : @[ @"u64/u64Add" ], // JMP
                @"i64/i64Sub" : @[ @"u64/u64Sub" ], // JMP
                @"i64/i64Mul" : @[ @"u64/u64Mul" ], // JMP
                @"i64/i64Div" : @[ @"u64/u64Div" ], // JSR
                @"i64/i64Mod" : @[ @"i64/i64Div" ], // JSR (which pulls u64Div in turn)
                @"u64/u64Mod" : @[ @"u64/u64Div" ], // JSR
            };
            NSMutableSet<NSString*>* have = [NSMutableSet set];
            for (NSString* rel in pack64)
                if ([inc rangeOfString:rel].location != NSNotFound)
                    [have addObject:rel];
            BOOL grew = YES;
            while (grew)
                {
                grew = NO;
                for (NSString* rel in [have copy])
                    {
                    for (NSString* cand in callees[rel] ?: @[])
                        {
                        if ([have containsObject:cand])
                            continue;
                        [have addObject:cand];
                        [inc appendFormat:@".include \"xt6502/asm/%@.asm\"\n", cand];
                        [alias appendFormat:@"_%@ = %@\n", cand.pathComponents.lastObject,
                                            cand.pathComponents.lastObject];
                        grew = YES;
                        }
                    }
                }
            [out appendString:inc];
            [out appendString:alias];
            }
        }

    if (usesWeak)
        {
        // weak.asm's intrusive list + the adapters that bridge the backend's
        // $84/$85/$86 (slot lo/hi/bank) + $87/$88/$89 (obj lo/hi/bank)
        // staging ABI to _weak_register's A/X/Y + _weak_slot/_weak_slot_bank
        // ABI. There is no table any more, so nothing to size and no arrays
        // to emit: the chain lives in the slots themselves and its head in
        // the object's heap-block header.
        NSString* weakSrc = [self readTemplateAtPath:@"xt6502/asm/weak/weak.asm"];
        weakSrc = [weakSrc stringByReplacingOccurrencesOfString:@"{{zp.tmp}}"
                                                     withString:[NSString stringWithFormat:@"$%02X", zpTmp]];
        [out appendString:weakSrc];
        [out appendString:
                 @"__xtc_weak_register:\n"
                 @"    LDA $84\n    STA _weak_slot\n"
                 @"    LDA $85\n    STA _weak_slot+1\n"
                 @"    LDA $86\n    STA _weak_slot_bank\n"
                 @"    LDA $87\n    LDX $88\n    LDY $89\n"
                 @"    JMP _weak_register\n"
                 // The slot's BANK matters to unregister now: it walks the links
                 // that live in front of the slot, so the slot's bank has to be
                 // mapped. The side-table version only ever compared main-RAM
                 // bytes and could get away with ignoring it.
                 @"__xtc_weak_unregister:\n"
                 @"    LDA $84\n    STA _weak_slot\n"
                 @"    LDA $85\n    STA _weak_slot+1\n"
                 @"    LDA $86\n    STA _weak_slot_bank\n"
                 @"    JMP _weak_unregister\n"
                 @"__xtc_weak_load:\n"
                 @"    LDY #$00\n    LDA ($84),Y\n    PHA\n"
                 @"    INY\n    LDA ($84),Y\n    TAX\n"
                 @"    INY\n    LDA ($84),Y\n    TAY\n"
                 @"    PLA\n    RTS\n\n"];
        }

    BOOL (^uses)(NSString*) = ^BOOL(NSString* rt) {
      return [generatedAsm containsString:
                               [NSString stringWithFormat:@"JSR _%@", rt]] ||
             [generatedAsm containsString:
                               [NSString stringWithFormat:@"JSR %@", rt]];
    };

    NSMutableSet<NSString*>* neededFloatExtras = [NSMutableSet set];
    if (uses(@"fpSin") || uses(@"fpCos") || uses(@"fpTan") || uses(@"fpAtan"))
        [neededFloatExtras addObject:@"fpTrig"];
    if (uses(@"fpSqrt"))
        [neededFloatExtras addObject:@"fpSqrt"];
    if (uses(@"fpAbs"))
        [neededFloatExtras addObject:@"fpAbs"];
    if (uses(@"fpMod"))
        [neededFloatExtras addObject:@"fpMod"];

    BOOL needDouble =
        [generatedAsm containsString:@"JSR _dp"] ||
        [generatedAsm containsString:@"JSR dp"] ||
        uses(@"u32ToDp") || uses(@"i32ToDp") || uses(@"u16ToDp") ||
        uses(@"i16ToDp") || uses(@"u8ToDp") || uses(@"i8ToDp") ||
        uses(@"dpToFp") || uses(@"fpToDp") || uses(@"asc2dp");

    NSArray<NSString*>* floatNames = @[
        @"u32ToFp", @"i32ToFp", @"i16ToFp", @"i8ToFp", @"u16ToFp", @"u8ToFp",
        @"fpToI32", @"fpAdd", @"fpSub", @"fpMul", @"fpDiv", @"fpCmp", @"fp2Asc",
        @"asc2fp"
    ];
    BOOL needFloat = needDouble || neededFloatExtras.count > 0;
    if (!needFloat)
        for (NSString* n in floatNames)
            if (uses(n))
                {
                needFloat = YES;
                break;
                }
    NSArray<NSString*>* doubleNames = @[
        @"dpAdd", @"dpSub", @"dpMul", @"dpDiv", @"dpCmp", @"dp2Asc",
        @"dpToFp", @"fpToDp", @"i8ToDp", @"i16ToDp", @"i32ToDp",
        @"u8ToDp", @"u16ToDp", @"u32ToDp", @"dpSqrt", @"dpMod", @"asc2dp"
    ];

    NSMutableArray<NSString*>* extrasLinked = [NSMutableArray array];
    if ([neededFloatExtras containsObject:@"fpTrig"])
        [extrasLinked addObjectsFromArray:@[ @"fpSin", @"fpCos", @"fpTan", @"fpAtan" ]];
    if ([neededFloatExtras containsObject:@"fpSqrt"])
        [extrasLinked addObject:@"fpSqrt"];
    if ([neededFloatExtras containsObject:@"fpAbs"])
        [extrasLinked addObject:@"fpAbs"];
    if ([neededFloatExtras containsObject:@"fpMod"])
        [extrasLinked addObject:@"fpMod"];

    if (needFloat || needDouble)
        {
        [out appendString:@"\n; ── Banked-runtime thunks (task #121) ──\n"];
        if (needFloat)
            {
            [self appendBankedRuntimeThunksInto:out
                                     entryNames:floatNames
                                     bankSymbol:@"__bank_fpRuntime"];
            [self appendBankedRuntimeThunksInto:out
                                     entryNames:extrasLinked
                                     bankSymbol:@"__bank_fpRuntime"];
            }
        if (needDouble)
            [self appendBankedRuntimeThunksInto:out
                                     entryNames:doubleNames
                                     bankSymbol:@"__bank_dpRuntime"];
        }

    [out appendString:@"\n"];
    [out appendString:generatedAsm];

    if (needFloat || needDouble)
        [out appendString:@"\n; ── Banked float/double runtime (task #121) ──\n"];
    if (needFloat)
        {
        [out appendString:@".bank fpRuntime\n"];
        for (NSString* name in floatNames)
            [out appendFormat:@".include \"xt6502/asm/float/%@.asm\"\n", name];
        if ([neededFloatExtras containsObject:@"fpTrig"])
            {
            [out appendString:@".include \"xt6502/asm/float/fpTrig.asm\"\n"];
            [out appendString:@".include \"xt6502/asm/float/fpTrigReduce.asm\"\n"];
            }
        if ([neededFloatExtras containsObject:@"fpSqrt"])
            [out appendString:@".include \"xt6502/asm/float/fpSqrt.asm\"\n"];
        if ([neededFloatExtras containsObject:@"fpAbs"])
            [out appendString:@".include \"xt6502/asm/float/fpAbs.asm\"\n"];
        if ([neededFloatExtras containsObject:@"fpMod"])
            [out appendString:@".include \"xt6502/asm/float/fpMod.asm\"\n"];
        }
    if (needDouble)
        {
        [out appendString:@".bank dpRuntime\n"];
        for (NSString* name in doubleNames)
            [out appendFormat:@".include \"xt6502/asm/double/%@.asm\"\n", name];
        }

    // Strip the harness's heap-init call / ARC stubs the program doesn't
    // reach, so the prepended startup matches the embedded runtime above.
    // Both are bracketed by @@LL-...@@ marker comments in the harness.
    void (^strip)(NSString*, NSString*) = ^(NSString* b, NSString* e) {
      NSRange rb = [out rangeOfString:b];
      NSRange re = [out rangeOfString:e];
      if (rb.location != NSNotFound && re.location != NSNotFound && re.location >= rb.location)
          {
          [out deleteCharactersInRange:
                   NSMakeRange(rb.location, NSMaxRange(re) - rb.location)];
          }
    };
    if (!usesHeap)
        strip(@"; @@LL-HEAPINIT-BEGIN@@", @"; @@LL-HEAPINIT-END@@");
    if (!usesARC)
        strip(@"; @@LL-ARC-BEGIN@@", @"; @@LL-ARC-END@@");
    return out;
    }

@end
