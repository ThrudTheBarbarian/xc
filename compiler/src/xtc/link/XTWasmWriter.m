// XTWasmWriter.m — assemble xcc-cg-wasm32's WAT dialect into a .wasm binary.
//
// The input is NOT general s-expression WAT: it is the known, linear dialect
// the backend emits — header forms `(import …)` / `(memory …)` / `(global …)`
// / `(data …)`, then `(func …)` bodies of one instruction per line. That is
// what makes an in-house assembler small: the section framing is LEB128 and a
// self-contained module has NO relocations (wasm-target.md §8). The `name`
// custom section is emitted so browser stack traces stay legible.
//
// wat2wasm is never consulted here — it serves only as an independent oracle
// in the codegen tests. An input outside the dialect is a hard error.
#import "XTWasmWriter.h"

// ── LEB128 / byte emission ─────────────────────────────────────────────────
// unsigned LEB128
static void putU(NSMutableData* d, uint64_t v)
    {
    do
        {
        uint8_t b = v & 0x7F;
        v >>= 7;
        if (v)
            b |= 0x80;
        [d appendBytes:&b length:1];
        } while (v);
    }
// signed LEB128
static void putS(NSMutableData* d, int64_t v)
    {
    BOOL more = YES;
    while (more)
        {
        uint8_t b = v & 0x7F;
        v >>= 7;
        if ((v == 0 && !(b & 0x40)) || (v == -1 && (b & 0x40)))
            more = NO;
        else
            b |= 0x80;
        [d appendBytes:&b length:1];
        }
    }
static void putByte(NSMutableData* d, uint8_t b)
    {
    [d appendBytes:&b length:1];
    }
static void putName(NSMutableData* d, NSString* s)
    {
    NSData* u = [s dataUsingEncoding:NSUTF8StringEncoding];
    putU(d, u.length);
    [d appendData:u];
    }
static void putSection(NSMutableData* out, uint8_t id, NSData* payload)
    {
    putByte(out, id);
    putU(out, payload.length);
    [out appendData:payload];
    }

// Error-out helper — a plain function so no block captures the autoreleasing
// out-parameter. Returns nil typed as id so both NSData* and parse-stage
// returns can use it directly.
static id XTWasmFail(NSError* _Nullable* _Nullable error, NSString* why)
    {
    if (error)
        *error = [NSError errorWithDomain:@"XTWasmWriter"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey : why}];
    return nil;
    }

// ── Value types ────────────────────────────────────────────────────────────
static uint8_t valType(NSString* t, BOOL* ok)
    {
    if ([t isEqualToString:@"i32"])
        return 0x7F;
    if ([t isEqualToString:@"i64"])
        return 0x7E;
    if ([t isEqualToString:@"f32"])
        return 0x7D;
    if ([t isEqualToString:@"f64"])
        return 0x7C;
    if ([t isEqualToString:@"v128"])
        return 0x7B;
    if (ok)
        *ok = NO;
    return 0x7F;
    }

// ── Model built from the WAT text ──────────────────────────────────────────
@interface XTWasmSig : NSObject
@property(nonatomic) NSMutableArray<NSString*>* params;
@property(nonatomic) NSMutableArray<NSString*>* results;
@property(nonatomic, readonly) NSString* key;
@end
@implementation XTWasmSig
- (instancetype)init
    {
    if ((self = [super init]))
        {
        _params = [NSMutableArray array];
        _results = [NSMutableArray array];
        }
    return self;
    }
- (NSString*)key
    {
    return [NSString stringWithFormat:@"(%@)->(%@)",
                                      [self.params componentsJoinedByString:@","],
                                      [self.results componentsJoinedByString:@","]];
    }
@end

@interface XTWasmFn : NSObject
@property(nonatomic) NSString* name;     // nil for the anonymous export fn
@property(nonatomic) NSString* exportAs; // non-nil when (export "x") inline
@property(nonatomic) XTWasmSig* sig;
@property(nonatomic) NSMutableArray<NSString*>* paramNames;
@property(nonatomic) NSMutableArray<NSString*>* localNames; // after params
@property(nonatomic) NSMutableArray<NSString*>* localTypes;
@property(nonatomic) NSMutableArray<NSString*>* bodyLines;
@property(nonatomic) BOOL isImport;
@property(nonatomic) NSString* importModule; // imports: the module string (#package)
@end
@implementation XTWasmFn
- (instancetype)init
    {
    if ((self = [super init]))
        {
        _sig = [XTWasmSig new];
        _paramNames = [NSMutableArray array];
        _localNames = [NSMutableArray array];
        _localTypes = [NSMutableArray array];
        _bodyLines = [NSMutableArray array];
        }
    return self;
    }
@end

@implementation XTWasmWriter

+ (nullable NSData*)wasmModuleFromWat:(NSString*)watText
                                error:(NSError* _Nullable* _Nullable)error
    {
    // ── Parse the dialect ──────────────────────────────────────────────────
    NSMutableArray<XTWasmFn*>* imports = [NSMutableArray array];
    NSMutableArray<XTWasmFn*>* funcs = [NSMutableArray array];
    // Data segment offsets are an i32.const OR (multi-module libraries,
    // W2) a `global.get $g` of an imported placement base — same for elem.
    NSMutableArray<NSArray*>* datas = [NSMutableArray array];   // @[addrOrGlobalName, bytes]
    NSMutableArray<NSArray*>* globals = [NSMutableArray array]; // @[mut, init, exportAs]
    NSMutableArray<NSString*>* globalNames = [NSMutableArray array];
    // Non-function imports (W2): @[kind("memory"/"table"/"global"), module,
    // name, $id-or-"", mut] in FILE order — the import section preserves it.
    NSMutableArray<NSArray*>* otherImports = [NSMutableArray array];
    NSMutableArray<NSString*>* importedGlobalNames = [NSMutableArray array];
    BOOL memImported = NO, tableImported = NO, tableExported = NO;
    uint32_t memPages = 1;
    BOOL memExported = NO;
    uint32_t tableSize = 0;
    int64_t elemBase = -1;
    NSString* elemBaseGlobal = nil;
    NSMutableArray<NSString*>* elemFns = [NSMutableArray array];
    NSMutableArray<NSArray*>* namedTypes = [NSMutableArray array]; // @[name, sig]

    XTWasmFn* cur = nil;
    NSInteger curDepth = 0; // tracked so the closing `)` of a func is found

    for (NSString* rawLine in [watText componentsSeparatedByString:@"\n"])
        {
        NSString* line = [rawLine stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceCharacterSet]];
        // Strip ;; comments (never inside a string literal in this dialect
        // except data segments, which are handled whole-line below).
        if (![line hasPrefix:@"(data"])
            {
            NSRange c = [line rangeOfString:@";;"];
            if (c.location != NSNotFound)
                line = [[line substringToIndex:c.location] stringByTrimmingCharactersInSet:
                                                               [NSCharacterSet whitespaceCharacterSet]];
            }
        if (!line.length)
            continue;

        if (cur)
            {
            // Inside a function body until its closing `)`.
            NSInteger opens = 0, closes = 0;
            for (NSUInteger i = 0; i < line.length; i++)
                {
                unichar ch = [line characterAtIndex:i];
                if (ch == '(')
                    opens++;
                else if (ch == ')')
                    closes++;
                }
            if ([line isEqualToString:@")"] && curDepth == 1)
                {
                [funcs addObject:cur];
                cur = nil;
                continue;
                }
            curDepth += opens - closes;
            if ([line hasPrefix:@"(local "])
                {
                // (local $name ty) — possibly several per line.
                NSArray* toks = [self tokensOf:line];
                for (NSUInteger i = 0; i + 1 < toks.count; i++)
                    {
                    if (![toks[i] hasPrefix:@"$"])
                        continue;
                    [cur.localNames addObject:toks[i]];
                    [cur.localTypes addObject:toks[i + 1]];
                    }
                continue;
                }
            [cur.bodyLines addObject:line];
            continue;
            }

        if ([line hasPrefix:@"(module"] || [line isEqualToString:@")"])
            continue;
        if ([line hasPrefix:@";;"])
            continue;

        if ([line hasPrefix:@"(import "])
            {
            // (import "env" "name" (func $name (param T)* (result T)?))
            // (import "env" "memory" (memory N))                 — W2
            // (import "env" "..." (table N funcref))             — W2
            // (import "env" "name" (global $g i32|(mut i32)))    — W2
            NSArray* toks = [self tokensOf:line];
            NSMutableArray<NSString*>* strs = [NSMutableArray array];
            for (NSString* t in toks)
                {
                if ([t hasPrefix:@"\""])
                    [strs addObject:
                              [t substringWithRange:NSMakeRange(1, t.length - 2)]];
                }
            if (strs.count < 2)
                return XTWasmFail(error, @"malformed import");
            if ([line containsString:@"(memory"])
                {
                memImported = YES;
                [otherImports addObject:@[ @"memory", strs[0], strs[1], @"", @NO ]];
                continue;
                }
            if ([line containsString:@"(table"])
                {
                tableImported = YES;
                [otherImports addObject:@[ @"table", strs[0], strs[1], @"", @NO ]];
                continue;
                }
            if ([line containsString:@"(global"])
                {
                NSString* gname = @"";
                for (NSString* t in toks)
                    if ([t hasPrefix:@"$"])
                        {
                        gname = t;
                        break;
                        }
                if (!gname.length)
                    return XTWasmFail(error, @"global import without $name");
                BOOL gmut = [line containsString:@"(mut "];
                [otherImports addObject:@[ @"global", strs[0], strs[1], gname, @(gmut) ]];
                [importedGlobalNames addObject:gname];
                continue;
                }
            XTWasmFn* imp = [XTWasmFn new];
            imp.isImport = YES;
            imp.importModule = strs[0]; // "#package" namespace ("env" default)
            imp.exportAs = strs[1];     // reuse: the import NAME
            for (NSUInteger i = 0; i < toks.count; i++)
                {
                NSString* t = toks[i];
                if ([t hasPrefix:@"$"] && !imp.name)
                    imp.name = t;
                if ([t isEqualToString:@"param"] && i + 1 < toks.count)
                    [imp.sig.params addObject:toks[i + 1]];
                if ([t isEqualToString:@"result"] && i + 1 < toks.count)
                    [imp.sig.results addObject:toks[i + 1]];
                }
            if (!imp.name)
                return XTWasmFail(error, @"import without $name");
            [imports addObject:imp];
            [otherImports addObject:@[ @"func", imp.importModule, imp.exportAs,
                                       imp.name, @NO ]];
            continue;
            }
        if ([line hasPrefix:@"(type "])
            {
            // (type $name (func (param T)* (result T)?))
            NSArray* toks = [self tokensOf:line];
            NSString* name = nil;
            XTWasmSig* sig = [XTWasmSig new];
            for (NSUInteger i = 0; i < toks.count; i++)
                {
                if ([toks[i] hasPrefix:@"$"] && !name)
                    name = toks[i];
                if ([toks[i] isEqualToString:@"param"] && i + 1 < toks.count)
                    [sig.params addObject:toks[i + 1]];
                if ([toks[i] isEqualToString:@"result"] && i + 1 < toks.count)
                    [sig.results addObject:toks[i + 1]];
                }
            if (!name)
                return XTWasmFail(error, @"type without $name");
            [namedTypes addObject:@[ name, sig ]];
            continue;
            }
        if ([line hasPrefix:@"(table"])
            {
            tableExported = [line containsString:@"(export \"__indirect_function_table\")"];
            NSArray* toks = [self tokensOf:line];
            for (NSString* t in toks)
                if (t.intValue > 0)
                    {
                    tableSize = (uint32_t)t.intValue;
                    break;
                    }
            continue;
            }
        if ([line hasPrefix:@"(elem"])
            {
            NSArray* toks = [self tokensOf:line];
            BOOL sawGet = NO;
            for (NSUInteger i = 0; i < toks.count; i++)
                {
                if ([toks[i] isEqualToString:@"i32.const"] && i + 1 < toks.count)
                    elemBase = [toks[i + 1] longLongValue];
                if ([toks[i] isEqualToString:@"global.get"] && i + 1 < toks.count)
                    {
                    elemBaseGlobal = toks[i + 1];
                    sawGet = YES;
                    }
                if ([toks[i] hasPrefix:@"$"])
                    {
                    // the base global's $id
                    if (sawGet)
                        {
                        sawGet = NO;
                        continue;
                        }
                    [elemFns addObject:toks[i]];
                    }
                }
            continue;
            }
        if ([line hasPrefix:@"(memory"])
            {
            memExported = [line containsString:@"(export \"memory\")"];
            NSArray* toks = [self tokensOf:line];
            memPages = (uint32_t)[toks.lastObject intValue] ?: 1;
            continue;
            }
        if ([line hasPrefix:@"(global"])
            {
            // (global $name (mut i32) (i32.const K))  |  (global $name i32 (i32.const K))
            NSArray* toks = [self tokensOf:line];
            NSString* name = nil;
            BOOL mut = [line containsString:@"(mut "];
            int64_t init = 0;
            for (NSUInteger i = 0; i < toks.count; i++)
                {
                if ([toks[i] hasPrefix:@"$"] && !name)
                    name = toks[i];
                if ([toks[i] isEqualToString:@"i32.const"] && i + 1 < toks.count)
                    init = [toks[i + 1] longLongValue];
                }
            if (!name)
                return XTWasmFail(error, @"global without $name");
            // Optional inline (export "x") — an exported address constant.
            NSString* gExp = @"";
            NSArray* toks2 = [self tokensOf:line];
            for (NSUInteger i = 0; i + 1 < toks2.count; i++)
                if ([toks2[i] isEqualToString:@"export"] && [toks2[i + 1] hasPrefix:@"\""])
                    gExp = [toks2[i + 1] substringWithRange:
                                             NSMakeRange(1, [toks2[i + 1] length] - 2)];
            [globalNames addObject:name];
            [globals addObject:@[ @(mut), @(init), gExp ]];
            continue;
            }
        if ([line hasPrefix:@"(data"])
            {
            // (data (i32.const A) "….") ;; name
            NSRange q1 = [line rangeOfString:@"\""];
            NSRange q2 = [line rangeOfString:@"\")" options:NSBackwardsSearch];
            if (q1.location == NSNotFound || q2.location == NSNotFound || q2.location <= q1.location)
                return XTWasmFail(error, @"malformed data segment");
            NSString* lit = [line substringWithRange:
                                      NSMakeRange(q1.location + 1, q2.location - q1.location - 1)];
            NSArray* toks = [self tokensOf:[line substringToIndex:q1.location]];
            int64_t addr = 0;
            NSString* addrGlobal = nil;
            for (NSUInteger i = 0; i < toks.count; i++)
                {
                if ([toks[i] isEqualToString:@"i32.const"] && i + 1 < toks.count)
                    addr = [toks[i + 1] longLongValue];
                if ([toks[i] isEqualToString:@"global.get"] && i + 1 < toks.count)
                    addrGlobal = toks[i + 1];
                }
            [datas addObject:@[ addrGlobal ?: (id) @(addr),
                                [self bytesOfDataLiteral:lit] ]];
            continue;
            }
        if ([line hasPrefix:@"(func"])
            {
            cur = [XTWasmFn new];
            curDepth = 1;
            NSArray* toks = [self tokensOf:line];
            for (NSUInteger i = 0; i < toks.count; i++)
                {
                NSString* t = toks[i];
                if ([t hasPrefix:@"$"] && !cur.name && i > 0 && [toks[i - 1] isEqualToString:@"func"])
                    {
                    cur.name = t;
                    continue;
                    }
                if ([t isEqualToString:@"export"] && i + 1 < toks.count)
                    cur.exportAs = [toks[i + 1] substringWithRange:
                                                    NSMakeRange(1, [toks[i + 1] length] - 2)];
                if ([t isEqualToString:@"param"] && i + 1 < toks.count)
                    {
                    // (param $name ty) or (param ty)
                    if ([toks[i + 1] hasPrefix:@"$"] && i + 2 < toks.count)
                        {
                        [cur.paramNames addObject:toks[i + 1]];
                        [cur.sig.params addObject:toks[i + 2]];
                        }
                    else
                        {
                        [cur.paramNames addObject:
                                            [NSString stringWithFormat:@"$__p%lu",
                                                                       (unsigned long)cur.paramNames.count]];
                        [cur.sig.params addObject:toks[i + 1]];
                        }
                    }
                if ([t isEqualToString:@"result"] && i + 1 < toks.count)
                    [cur.sig.results addObject:toks[i + 1]];
                }
            continue;
            }
        return XTWasmFail(error, [NSString stringWithFormat:
                                               @"unrecognised module-level form: %@", line]);
        }
    if (cur)
        return XTWasmFail(error, @"unterminated (func");

    // ── Index spaces ───────────────────────────────────────────────────────
    NSMutableDictionary<NSString*, NSNumber*>* fnIndex = [NSMutableDictionary dictionary];
    NSUInteger fi = 0;
    for (XTWasmFn* f in imports)
        fnIndex[f.name] = @(fi++);
    for (XTWasmFn* f in funcs)
        if (f.name)
            fnIndex[f.name] = @(fi++);
        else
            fi++;
    // Global index space: IMPORTED globals first (in import order), then the
    // module's own — the same rule as functions.
    NSMutableDictionary<NSString*, NSNumber*>* globalIndex = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < importedGlobalNames.count; i++)
        globalIndex[importedGlobalNames[i]] = @(i);
    for (NSUInteger i = 0; i < globalNames.count; i++)
        globalIndex[globalNames[i]] = @(importedGlobalNames.count + i);

    // Type section: dedupe signatures.
    NSMutableArray<XTWasmSig*>* types = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSNumber*>* typeIndex = [NSMutableDictionary dictionary];
    NSNumber* (^typeFor)(XTWasmSig*) = ^NSNumber*(XTWasmSig* s) {
      NSNumber* have = typeIndex[s.key];
      if (have)
          return have;
      NSNumber* idx = @(types.count);
      [types addObject:s];
      typeIndex[s.key] = idx;
      return idx;
    };
    // Named types first (call_indirect references them by name), then the
    // function signatures — typeFor dedupes structurally either way.
    NSMutableDictionary<NSString*, NSNumber*>* namedTypeIndex =
        [NSMutableDictionary dictionary];
    for (NSArray* nt in namedTypes)
        namedTypeIndex[nt[0]] = typeFor(nt[1]);
    for (XTWasmFn* f in imports)
        typeFor(f.sig);
    for (XTWasmFn* f in funcs)
        typeFor(f.sig);

    // ── Emit ───────────────────────────────────────────────────────────────
    NSMutableData* out = [NSMutableData data];
    uint8_t hdr[8] = {0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00};
    [out appendBytes:hdr length:8];

    BOOL typeOk = YES;
    NSMutableData* sec = [NSMutableData data];
    putU(sec, types.count);
    for (XTWasmSig* s in types)
        {
        putByte(sec, 0x60);
        putU(sec, s.params.count);
        for (NSString* p in s.params)
            putByte(sec, valType(p, &typeOk));
        putU(sec, s.results.count);
        for (NSString* r in s.results)
            putByte(sec, valType(r, &typeOk));
        }
    if (!typeOk)
        return XTWasmFail(error, @"unknown value type in signature");
    putSection(out, 1, sec);

    if (otherImports.count)
        {
        // The import section, in FILE order (mixed kinds — a function
        // import's index among FUNCTIONS is its position among the "func"
        // rows, which is exactly the order `imports` holds).
        sec = [NSMutableData data];
        putU(sec, otherImports.count);
        NSUInteger fk = 0;
        for (NSArray* row in otherImports)
            {
            putName(sec, row[1]);
            putName(sec, row[2]);
            NSString* kind = row[0];
            if ([kind isEqualToString:@"func"])
                {
                XTWasmFn* f = imports[fk++];
                putByte(sec, 0x00);
                putU(sec, typeFor(f.sig).unsignedIntegerValue);
                }
            else if ([kind isEqualToString:@"table"])
                {
                putByte(sec, 0x01);
                putByte(sec, 0x70); // funcref
                putByte(sec, 0x00);
                putU(sec, 0); // limits: min 0
                }
            else if ([kind isEqualToString:@"memory"])
                {
                putByte(sec, 0x02);
                putByte(sec, 0x00);
                putU(sec, 0);
                }
            // global
            else
                {
                putByte(sec, 0x03);
                putByte(sec, 0x7F); // i32
                putByte(sec, [row[4] boolValue] ? 0x01 : 0x00);
                }
            }
        putSection(out, 2, sec);
        }

    sec = [NSMutableData data]; // function section
    putU(sec, funcs.count);
    for (XTWasmFn* f in funcs)
        putU(sec, typeFor(f.sig).unsignedIntegerValue);
    putSection(out, 3, sec);

    // table section
    if (tableSize && !tableImported)
        {
        sec = [NSMutableData data];
        putU(sec, 1);
        putByte(sec, 0x70);
        putByte(sec, 0x00);
        putU(sec, tableSize);
        putSection(out, 4, sec);
        }

    if (!memImported)
        {
        sec = [NSMutableData data]; // memory section
        putU(sec, 1);
        putByte(sec, 0x00);
        putU(sec, memPages);
        putSection(out, 5, sec);
        }

    if (globals.count)
        {
        sec = [NSMutableData data];
        putU(sec, globals.count);
        for (NSArray* g in globals)
            {
            putByte(sec, 0x7F); // i32
            putByte(sec, [g[0] boolValue] ? 0x01 : 0x00);
            putByte(sec, 0x41);
            putS(sec, [g[1] longLongValue]); // i32.const init
            putByte(sec, 0x0B);
            }
        putSection(out, 6, sec);
        }

    sec = [NSMutableData data]; // export section
    NSUInteger nExports = (memExported ? 1 : 0) + (tableExported ? 1 : 0);
    NSUInteger fj = imports.count;
    for (XTWasmFn* f in funcs)
        {
        if (f.exportAs)
            nExports++;
        }
    for (NSArray* g in globals)
        {
        if ([g[2] length])
            nExports++;
        }
    putU(sec, nExports);
    if (memExported)
        {
        putName(sec, @"memory");
        putByte(sec, 0x02);
        putU(sec, 0);
        }
    if (tableExported)
        {
        putName(sec, @"__indirect_function_table");
        putByte(sec, 0x01);
        putU(sec, 0);
        }
    fj = imports.count;
    for (XTWasmFn* f in funcs)
        {
        if (f.exportAs)
            {
            putName(sec, f.exportAs);
            putByte(sec, 0x00);
            putU(sec, fj);
            }
        fj++;
        }
    for (NSUInteger gi = 0; gi < globals.count; gi++)
        {
        if (![globals[gi][2] length])
            continue;
        putName(sec, globals[gi][2]);
        putByte(sec, 0x03);
        putU(sec, importedGlobalNames.count + gi);
        }
    putSection(out, 7, sec);

    // element section
    if (elemFns.count)
        {
        sec = [NSMutableData data];
        putU(sec, 1);
        putU(sec, 0); // active, table 0
        if (elemBaseGlobal)
            {
            NSNumber* gi = globalIndex[elemBaseGlobal];
            if (!gi)
                return XTWasmFail(error,
                                  [NSString stringWithFormat:@"elem offset names unknown global '%@'",
                                                             elemBaseGlobal]);
            putByte(sec, 0x23);
            putU(sec, gi.unsignedIntegerValue);
            putByte(sec, 0x0B);
            }
        else
            {
            putByte(sec, 0x41);
            putS(sec, elemBase < 0 ? 1 : elemBase);
            putByte(sec, 0x0B);
            }
        putU(sec, elemFns.count);
        for (NSString* fname in elemFns)
            {
            NSNumber* idx = fnIndex[fname];
            if (!idx)
                return XTWasmFail(error,
                                  [NSString stringWithFormat:@"elem names unknown function '%@'", fname]);
            putU(sec, idx.unsignedIntegerValue);
            }
        putSection(out, 9, sec);
        }

    sec = [NSMutableData data]; // code section
    putU(sec, funcs.count);
    for (XTWasmFn* f in funcs)
        {
        NSError* bodyErr = nil;
        NSData* body = [self encodeBodyOf:f
                                  fnIndex:fnIndex
                              globalIndex:globalIndex
                                typeIndex:namedTypeIndex
                                    error:&bodyErr];
        if (!body)
            {
            if (error)
                *error = bodyErr;
            return nil;
            }
        putU(sec, body.length);
        [sec appendData:body];
        }
    putSection(out, 10, sec);

    if (datas.count)
        {
        sec = [NSMutableData data];
        putU(sec, datas.count);
        for (NSArray* d in datas)
            {
            putU(sec, 0); // active, memory 0
            if ([d[0] isKindOfClass:[NSString class]])
                {
                NSNumber* gi = globalIndex[d[0]];
                if (!gi)
                    return XTWasmFail(error,
                                      [NSString stringWithFormat:@"data offset names unknown global '%@'",
                                                                 d[0]]);
                putByte(sec, 0x23);
                putU(sec, gi.unsignedIntegerValue);
                putByte(sec, 0x0B);
                }
            else
                {
                putByte(sec, 0x41);
                putS(sec, [d[0] longLongValue]);
                putByte(sec, 0x0B);
                }
            NSData* bytes = d[1];
            putU(sec, bytes.length);
            [sec appendData:bytes];
            }
        putSection(out, 11, sec);
        }

    // `name` custom section — function names for legible stack traces.
    NSMutableData* names = [NSMutableData data];
    putName(names, @"name");
    NSMutableData* fnNames = [NSMutableData data];
    NSUInteger named = 0;
    for (XTWasmFn* f in imports)
        if (f.name)
            named++;
    for (XTWasmFn* f in funcs)
        if (f.name)
            named++;
    putU(fnNames, named);
    fj = 0;
    for (XTWasmFn* f in imports)
        {
        if (f.name)
            {
            putU(fnNames, fj);
            putName(fnNames, [f.name substringFromIndex:1]);
            }
        fj++;
        }
    for (XTWasmFn* f in funcs)
        {
        if (f.name)
            {
            putU(fnNames, fj);
            putName(fnNames, [f.name substringFromIndex:1]);
            }
        fj++;
        }
    putByte(names, 0x01);
    putU(names, fnNames.length);
    [names appendData:fnNames];
    putSection(out, 0, names);

    return out;
    }

#pragma mark - Body encoding

// One opcode table entry: byte(s) + immediate style.
typedef NS_ENUM(uint8_t, WImm) {
    WImmNone,
    WImmI32,
    WImmI64,
    WImmF32,
    WImmF64,
    WImmLabel,
    WImmLocal,
    WImmGlobal,
    WImmCall,
    WImmBrTable,
    WImmMem,
    WImmMemPair,
    WImmLane,    // one lane-index byte (i32x4.extract_lane 2)
    WImmLanes16, // sixteen lane-index bytes (i8x16.shuffle …)
};

+ (NSDictionary<NSString*, NSArray<NSNumber*>*>*)opcodeTable
    {
    static NSDictionary* t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      // @[primary byte, immediate style, (optional) 0xFC sub-opcode]
      t = @{
          @"unreachable" : @[ @0x00, @(WImmNone) ],
          @"nop" : @[ @0x01, @(WImmNone) ],
          @"return" : @[ @0x0F, @(WImmNone) ],
          @"drop" : @[ @0x1A, @(WImmNone) ],
          @"select" : @[ @0x1B, @(WImmNone) ],
          @"br" : @[ @0x0C, @(WImmLabel) ],
          @"br_if" : @[ @0x0D, @(WImmLabel) ],
          @"br_table" : @[ @0x0E, @(WImmBrTable) ],
          @"call" : @[ @0x10, @(WImmCall) ],
          @"return_call" : @[ @0x12, @(WImmCall) ],
          @"local.get" : @[ @0x20, @(WImmLocal) ],
          @"local.set" : @[ @0x21, @(WImmLocal) ],
          @"local.tee" : @[ @0x22, @(WImmLocal) ],
          @"global.get" : @[ @0x23, @(WImmGlobal) ],
          @"global.set" : @[ @0x24, @(WImmGlobal) ],
          @"i32.const" : @[ @0x41, @(WImmI32) ],
          @"i64.const" : @[ @0x42, @(WImmI64) ],
          @"f32.const" : @[ @0x43, @(WImmF32) ],
          @"f64.const" : @[ @0x44, @(WImmF64) ],
          // loads/stores (align+offset immediates, natural align, offset 0)
          @"i32.load" : @[ @0x28, @(WImmMemPair), @2 ],
          @"i64.load" : @[ @0x29, @(WImmMemPair), @3 ],
          @"f32.load" : @[ @0x2A, @(WImmMemPair), @2 ],
          @"f64.load" : @[ @0x2B, @(WImmMemPair), @3 ],
          @"i32.load8_s" : @[ @0x2C, @(WImmMemPair), @0 ],
          @"i32.load8_u" : @[ @0x2D, @(WImmMemPair), @0 ],
          @"i32.load16_s" : @[ @0x2E, @(WImmMemPair), @1 ],
          @"i32.load16_u" : @[ @0x2F, @(WImmMemPair), @1 ],
          @"i64.load8_s" : @[ @0x30, @(WImmMemPair), @0 ],
          @"i64.load8_u" : @[ @0x31, @(WImmMemPair), @0 ],
          @"i64.load16_s" : @[ @0x32, @(WImmMemPair), @1 ],
          @"i64.load16_u" : @[ @0x33, @(WImmMemPair), @1 ],
          @"i64.load32_s" : @[ @0x34, @(WImmMemPair), @2 ],
          @"i64.load32_u" : @[ @0x35, @(WImmMemPair), @2 ],
          @"i32.store" : @[ @0x36, @(WImmMemPair), @2 ],
          @"i64.store" : @[ @0x37, @(WImmMemPair), @3 ],
          @"f32.store" : @[ @0x38, @(WImmMemPair), @2 ],
          @"f64.store" : @[ @0x39, @(WImmMemPair), @3 ],
          @"i32.store8" : @[ @0x3A, @(WImmMemPair), @0 ],
          @"i32.store16" : @[ @0x3B, @(WImmMemPair), @1 ],
          @"i64.store8" : @[ @0x3C, @(WImmMemPair), @0 ],
          @"i64.store16" : @[ @0x3D, @(WImmMemPair), @1 ],
          @"i64.store32" : @[ @0x3E, @(WImmMemPair), @2 ],
          // i32 compare/arith
          @"i32.eqz" : @[ @0x45, @(WImmNone) ],
          @"i32.eq" : @[ @0x46, @(WImmNone) ],
          @"i32.ne" : @[ @0x47, @(WImmNone) ],
          @"i32.lt_s" : @[ @0x48, @(WImmNone) ],
          @"i32.lt_u" : @[ @0x49, @(WImmNone) ],
          @"i32.gt_s" : @[ @0x4A, @(WImmNone) ],
          @"i32.gt_u" : @[ @0x4B, @(WImmNone) ],
          @"i32.le_s" : @[ @0x4C, @(WImmNone) ],
          @"i32.le_u" : @[ @0x4D, @(WImmNone) ],
          @"i32.ge_s" : @[ @0x4E, @(WImmNone) ],
          @"i32.ge_u" : @[ @0x4F, @(WImmNone) ],
          @"i64.eqz" : @[ @0x50, @(WImmNone) ],
          @"i64.eq" : @[ @0x51, @(WImmNone) ],
          @"i64.ne" : @[ @0x52, @(WImmNone) ],
          @"i64.lt_s" : @[ @0x53, @(WImmNone) ],
          @"i64.lt_u" : @[ @0x54, @(WImmNone) ],
          @"i64.gt_s" : @[ @0x55, @(WImmNone) ],
          @"i64.gt_u" : @[ @0x56, @(WImmNone) ],
          @"i64.le_s" : @[ @0x57, @(WImmNone) ],
          @"i64.le_u" : @[ @0x58, @(WImmNone) ],
          @"i64.ge_s" : @[ @0x59, @(WImmNone) ],
          @"i64.ge_u" : @[ @0x5A, @(WImmNone) ],
          @"f32.eq" : @[ @0x5B, @(WImmNone) ],
          @"f32.ne" : @[ @0x5C, @(WImmNone) ],
          @"f32.lt" : @[ @0x5D, @(WImmNone) ],
          @"f32.gt" : @[ @0x5E, @(WImmNone) ],
          @"f32.le" : @[ @0x5F, @(WImmNone) ],
          @"f32.ge" : @[ @0x60, @(WImmNone) ],
          @"f64.eq" : @[ @0x61, @(WImmNone) ],
          @"f64.ne" : @[ @0x62, @(WImmNone) ],
          @"f64.lt" : @[ @0x63, @(WImmNone) ],
          @"f64.gt" : @[ @0x64, @(WImmNone) ],
          @"f64.le" : @[ @0x65, @(WImmNone) ],
          @"f64.ge" : @[ @0x66, @(WImmNone) ],
          @"i32.add" : @[ @0x6A, @(WImmNone) ],
          @"i32.sub" : @[ @0x6B, @(WImmNone) ],
          @"i32.mul" : @[ @0x6C, @(WImmNone) ],
          @"i32.div_s" : @[ @0x6D, @(WImmNone) ],
          @"i32.div_u" : @[ @0x6E, @(WImmNone) ],
          @"i32.rem_s" : @[ @0x6F, @(WImmNone) ],
          @"i32.rem_u" : @[ @0x70, @(WImmNone) ],
          @"i32.and" : @[ @0x71, @(WImmNone) ],
          @"i32.or" : @[ @0x72, @(WImmNone) ],
          @"i32.xor" : @[ @0x73, @(WImmNone) ],
          @"i32.shl" : @[ @0x74, @(WImmNone) ],
          @"i32.shr_s" : @[ @0x75, @(WImmNone) ],
          @"i32.shr_u" : @[ @0x76, @(WImmNone) ],
          @"i32.rotl" : @[ @0x77, @(WImmNone) ],
          @"i32.rotr" : @[ @0x78, @(WImmNone) ],
          @"i64.add" : @[ @0x7C, @(WImmNone) ],
          @"i64.sub" : @[ @0x7D, @(WImmNone) ],
          @"i64.mul" : @[ @0x7E, @(WImmNone) ],
          @"i64.div_s" : @[ @0x7F, @(WImmNone) ],
          @"i64.div_u" : @[ @0x80, @(WImmNone) ],
          @"i64.rem_s" : @[ @0x81, @(WImmNone) ],
          @"i64.rem_u" : @[ @0x82, @(WImmNone) ],
          @"i64.and" : @[ @0x83, @(WImmNone) ],
          @"i64.or" : @[ @0x84, @(WImmNone) ],
          @"i64.xor" : @[ @0x85, @(WImmNone) ],
          @"i64.shl" : @[ @0x86, @(WImmNone) ],
          @"i64.shr_s" : @[ @0x87, @(WImmNone) ],
          @"i64.shr_u" : @[ @0x88, @(WImmNone) ],
          @"i64.rotl" : @[ @0x89, @(WImmNone) ],
          @"i64.rotr" : @[ @0x8A, @(WImmNone) ],
          @"f32.neg" : @[ @0x8C, @(WImmNone) ],
          @"f32.sqrt" : @[ @0x91, @(WImmNone) ],
          @"f32.add" : @[ @0x92, @(WImmNone) ],
          @"f32.sub" : @[ @0x93, @(WImmNone) ],
          @"f32.mul" : @[ @0x94, @(WImmNone) ],
          @"f32.div" : @[ @0x95, @(WImmNone) ],
          @"f64.neg" : @[ @0x9A, @(WImmNone) ],
          @"f64.sqrt" : @[ @0x9F, @(WImmNone) ],
          @"f64.add" : @[ @0xA0, @(WImmNone) ],
          @"f64.sub" : @[ @0xA1, @(WImmNone) ],
          @"f64.mul" : @[ @0xA2, @(WImmNone) ],
          @"f64.div" : @[ @0xA3, @(WImmNone) ],
          @"i32.wrap_i64" : @[ @0xA7, @(WImmNone) ],
          @"i64.extend_i32_s" : @[ @0xAC, @(WImmNone) ],
          @"i64.extend_i32_u" : @[ @0xAD, @(WImmNone) ],
          @"f32.convert_i32_s" : @[ @0xB2, @(WImmNone) ],
          @"f32.convert_i32_u" : @[ @0xB3, @(WImmNone) ],
          @"f32.convert_i64_s" : @[ @0xB4, @(WImmNone) ],
          @"f32.convert_i64_u" : @[ @0xB5, @(WImmNone) ],
          @"f32.demote_f64" : @[ @0xB6, @(WImmNone) ],
          @"f64.convert_i32_s" : @[ @0xB7, @(WImmNone) ],
          @"f64.convert_i32_u" : @[ @0xB8, @(WImmNone) ],
          @"f64.convert_i64_s" : @[ @0xB9, @(WImmNone) ],
          @"f64.convert_i64_u" : @[ @0xBA, @(WImmNone) ],
          @"f64.promote_f32" : @[ @0xBB, @(WImmNone) ],
          @"i32.reinterpret_f32" : @[ @0xBC, @(WImmNone) ],
          @"i64.reinterpret_f64" : @[ @0xBD, @(WImmNone) ],
          @"f32.reinterpret_i32" : @[ @0xBE, @(WImmNone) ],
          @"f64.reinterpret_i64" : @[ @0xBF, @(WImmNone) ],
          @"i32.extend8_s" : @[ @0xC0, @(WImmNone) ],
          @"i32.extend16_s" : @[ @0xC1, @(WImmNone) ],
          @"i64.extend8_s" : @[ @0xC2, @(WImmNone) ],
          @"i64.extend16_s" : @[ @0xC3, @(WImmNone) ],
          @"i64.extend32_s" : @[ @0xC4, @(WImmNone) ],
          // 0xFC-prefixed
          @"i32.trunc_sat_f32_s" : @[ @0xFC, @(WImmNone), @0 ],
          @"i32.trunc_sat_f32_u" : @[ @0xFC, @(WImmNone), @1 ],
          @"i32.trunc_sat_f64_s" : @[ @0xFC, @(WImmNone), @2 ],
          @"i32.trunc_sat_f64_u" : @[ @0xFC, @(WImmNone), @3 ],
          @"i64.trunc_sat_f32_s" : @[ @0xFC, @(WImmNone), @4 ],
          @"i64.trunc_sat_f32_u" : @[ @0xFC, @(WImmNone), @5 ],
          @"i64.trunc_sat_f64_s" : @[ @0xFC, @(WImmNone), @6 ],
          @"i64.trunc_sat_f64_u" : @[ @0xFC, @(WImmNone), @7 ],
          @"memory.copy" : @[ @0xFC, @(WImmNone), @10 ],
          @"memory.fill" : @[ @0xFC, @(WImmNone), @11 ],
          // 0xFD-prefixed SIMD (enc[2] = LEB sub-opcode). The two memory ops
          // carry a memarg — natural align for v128 is 16 bytes (log2 4),
          // which the WImmMemPair arm special-cases on the 0xFD prefix.
          @"v128.load" : @[ @0xFD, @(WImmMemPair), @0 ],
          @"v128.store" : @[ @0xFD, @(WImmMemPair), @11 ],
          @"i8x16.shuffle" : @[ @0xFD, @(WImmLanes16), @13 ],
          @"i8x16.splat" : @[ @0xFD, @(WImmNone), @15 ],
          @"i16x8.splat" : @[ @0xFD, @(WImmNone), @16 ],
          @"i32x4.splat" : @[ @0xFD, @(WImmNone), @17 ],
          @"f32x4.splat" : @[ @0xFD, @(WImmNone), @19 ],
          @"i32x4.extract_lane" : @[ @0xFD, @(WImmLane), @27 ],
          @"i8x16.eq" : @[ @0xFD, @(WImmNone), @35 ],
          @"i8x16.ne" : @[ @0xFD, @(WImmNone), @36 ],
          @"i8x16.lt_s" : @[ @0xFD, @(WImmNone), @37 ],
          @"i8x16.lt_u" : @[ @0xFD, @(WImmNone), @38 ],
          @"i8x16.gt_s" : @[ @0xFD, @(WImmNone), @39 ],
          @"i8x16.gt_u" : @[ @0xFD, @(WImmNone), @40 ],
          @"i8x16.le_s" : @[ @0xFD, @(WImmNone), @41 ],
          @"i8x16.le_u" : @[ @0xFD, @(WImmNone), @42 ],
          @"i8x16.ge_s" : @[ @0xFD, @(WImmNone), @43 ],
          @"i8x16.ge_u" : @[ @0xFD, @(WImmNone), @44 ],
          @"i16x8.eq" : @[ @0xFD, @(WImmNone), @45 ],
          @"i16x8.ne" : @[ @0xFD, @(WImmNone), @46 ],
          @"i16x8.lt_s" : @[ @0xFD, @(WImmNone), @47 ],
          @"i16x8.lt_u" : @[ @0xFD, @(WImmNone), @48 ],
          @"i16x8.gt_s" : @[ @0xFD, @(WImmNone), @49 ],
          @"i16x8.gt_u" : @[ @0xFD, @(WImmNone), @50 ],
          @"i16x8.le_s" : @[ @0xFD, @(WImmNone), @51 ],
          @"i16x8.le_u" : @[ @0xFD, @(WImmNone), @52 ],
          @"i16x8.ge_s" : @[ @0xFD, @(WImmNone), @53 ],
          @"i16x8.ge_u" : @[ @0xFD, @(WImmNone), @54 ],
          @"i32x4.eq" : @[ @0xFD, @(WImmNone), @55 ],
          @"i32x4.ne" : @[ @0xFD, @(WImmNone), @56 ],
          @"i32x4.lt_s" : @[ @0xFD, @(WImmNone), @57 ],
          @"i32x4.lt_u" : @[ @0xFD, @(WImmNone), @58 ],
          @"i32x4.gt_s" : @[ @0xFD, @(WImmNone), @59 ],
          @"i32x4.gt_u" : @[ @0xFD, @(WImmNone), @60 ],
          @"i32x4.le_s" : @[ @0xFD, @(WImmNone), @61 ],
          @"i32x4.le_u" : @[ @0xFD, @(WImmNone), @62 ],
          @"i32x4.ge_s" : @[ @0xFD, @(WImmNone), @63 ],
          @"i32x4.ge_u" : @[ @0xFD, @(WImmNone), @64 ],
          @"v128.and" : @[ @0xFD, @(WImmNone), @78 ],
          @"v128.or" : @[ @0xFD, @(WImmNone), @80 ],
          @"v128.xor" : @[ @0xFD, @(WImmNone), @81 ],
          @"i8x16.add" : @[ @0xFD, @(WImmNone), @110 ],
          @"i8x16.sub" : @[ @0xFD, @(WImmNone), @113 ],
          @"i8x16.min_s" : @[ @0xFD, @(WImmNone), @118 ],
          @"i8x16.min_u" : @[ @0xFD, @(WImmNone), @119 ],
          @"i8x16.max_s" : @[ @0xFD, @(WImmNone), @120 ],
          @"i8x16.max_u" : @[ @0xFD, @(WImmNone), @121 ],
          @"i16x8.extadd_pairwise_i8x16_u" : @[ @0xFD, @(WImmNone), @125 ],
          @"i32x4.extadd_pairwise_i16x8_u" : @[ @0xFD, @(WImmNone), @127 ],
          @"i16x8.extend_low_i8x16_u" : @[ @0xFD, @(WImmNone), @137 ],
          @"i16x8.extend_high_i8x16_u" : @[ @0xFD, @(WImmNone), @138 ],
          @"i16x8.add" : @[ @0xFD, @(WImmNone), @142 ],
          @"i16x8.sub" : @[ @0xFD, @(WImmNone), @145 ],
          @"i16x8.mul" : @[ @0xFD, @(WImmNone), @149 ],
          @"i16x8.min_s" : @[ @0xFD, @(WImmNone), @150 ],
          @"i16x8.min_u" : @[ @0xFD, @(WImmNone), @151 ],
          @"i16x8.max_s" : @[ @0xFD, @(WImmNone), @152 ],
          @"i16x8.max_u" : @[ @0xFD, @(WImmNone), @153 ],
          @"i32x4.add" : @[ @0xFD, @(WImmNone), @174 ],
          @"i32x4.sub" : @[ @0xFD, @(WImmNone), @177 ],
          @"i32x4.mul" : @[ @0xFD, @(WImmNone), @181 ],
          @"i32x4.min_s" : @[ @0xFD, @(WImmNone), @182 ],
          @"i32x4.min_u" : @[ @0xFD, @(WImmNone), @183 ],
          @"i32x4.max_s" : @[ @0xFD, @(WImmNone), @184 ],
          @"i32x4.max_u" : @[ @0xFD, @(WImmNone), @185 ],
          @"f32x4.add" : @[ @0xFD, @(WImmNone), @228 ],
          @"f32x4.sub" : @[ @0xFD, @(WImmNone), @229 ],
          @"f32x4.mul" : @[ @0xFD, @(WImmNone), @230 ],
          @"f32x4.min" : @[ @0xFD, @(WImmNone), @232 ],
          @"f32x4.max" : @[ @0xFD, @(WImmNone), @233 ],
      };
    });
    return t;
    }

+ (nullable NSData*)encodeBodyOf:(XTWasmFn*)f
                         fnIndex:(NSDictionary<NSString*, NSNumber*>*)fnIndex
                     globalIndex:(NSDictionary<NSString*, NSNumber*>*)globalIndex
                       typeIndex:(NSDictionary<NSString*, NSNumber*>*)typeIndex
                           error:(NSError**)error
    {
    NSString* fnLabel = f.name ?: f.exportAs ?
                                             : @"?";
    // Locals: index space = params then locals; run-length-encode by type.
    NSMutableDictionary<NSString*, NSNumber*>* localIndex = [NSMutableDictionary dictionary];
    NSUInteger li = 0;
    for (NSString* p in f.paramNames)
        localIndex[p] = @(li++);
    for (NSString* l in f.localNames)
        localIndex[l] = @(li++);

    NSMutableData* body = [NSMutableData data];
    NSMutableArray<NSArray*>* groups = [NSMutableArray array]; // @[count, type]
    for (NSString* t in f.localTypes)
        {
        if (groups.count && [groups.lastObject[1] isEqualToString:t])
            [groups replaceObjectAtIndex:groups.count - 1
                              withObject:@[ @([groups.lastObject[0] unsignedIntegerValue] + 1), t ]];
        else
            [groups addObject:@[ @1, t ]];
        }
    putU(body, groups.count);
    BOOL tOk = YES;
    for (NSArray* g in groups)
        {
        putU(body, [g[0] unsignedIntegerValue]);
        putByte(body, valType(g[1], &tOk));
        }
    if (!tOk)
        return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", @"unknown local type", fnLabel]);

    // Label stack for depth resolution. `if`/`block`/`loop` push; `else`
    // keeps its frame; `end` pops.
    NSMutableArray<NSString*>* labels = [NSMutableArray array]; // "" = anonymous
    NSDictionary* table = [self opcodeTable];

    for (NSString* line in f.bodyLines)
        {
        NSArray<NSString*>* toks = [self tokensOf:line];
        if (!toks.count)
            continue;
        NSString* op = toks[0];

        if ([op isEqualToString:@"block"] || [op isEqualToString:@"loop"])
            {
            putByte(body, [op isEqualToString:@"block"] ? 0x02 : 0x03);
            putByte(body, 0x40); // void block type
            [labels addObject:toks.count > 1 ? toks[1] : @""];
            continue;
            }
        if ([op isEqualToString:@"if"])
            {
            putByte(body, 0x04);
            putByte(body, 0x40);
            [labels addObject:toks.count > 1 ? toks[1] : @""];
            continue;
            }
        if ([op isEqualToString:@"else"])
            {
            putByte(body, 0x05);
            continue;
            }
        if ([op isEqualToString:@"end"])
            {
            putByte(body, 0x0B);
            if (labels.count)
                [labels removeLastObject];
            continue;
            }

        if ([op isEqualToString:@"call_indirect"] || [op isEqualToString:@"return_call_indirect"])
            {
            // (return_)call_indirect (type $name) → 0x11/0x13 typeidx tableidx(0).
            NSNumber* ti = toks.count > 2 ? typeIndex[toks[2]] : nil;
            if (!ti)
                return XTWasmFail(error, [NSString stringWithFormat:
                                                       @"call_indirect with unknown type (in %@)", fnLabel]);
            putByte(body, [op isEqualToString:@"call_indirect"] ? 0x11 : 0x13);
            putU(body, ti.unsignedIntegerValue);
            putByte(body, 0x00);
            continue;
            }
        if ([op isEqualToString:@"memory.size"])
            {
            putByte(body, 0x3F);
            putByte(body, 0x00);
            continue;
            }
        if ([op isEqualToString:@"memory.grow"])
            {
            putByte(body, 0x40);
            putByte(body, 0x00);
            continue;
            }

        NSArray<NSNumber*>* enc = table[op];
        if (!enc)
            return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", [NSString stringWithFormat:@"unknown instruction '%@'", op], fnLabel]);
        putByte(body, enc[0].unsignedCharValue);
        // enc[2] is the 0xFC/0xFD sub-opcode for prefixed instructions and the
        // natural-alignment log2 for memory ops — dispatch on the prefix.
        if (enc[0].unsignedCharValue == 0xFC || enc[0].unsignedCharValue == 0xFD)
            {
            putU(body, enc[2].unsignedIntegerValue);
            if ([op isEqualToString:@"memory.copy"])
                {
                putByte(body, 0);
                putByte(body, 0);
                }
            else if ([op isEqualToString:@"memory.fill"])
                {
                putByte(body, 0);
                }
            }

        switch ((WImm)enc[1].unsignedCharValue)
            {
        case WImmNone:
            break;
        case WImmI32:
        case WImmI64:
            if (toks.count < 2)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", @"const needs a value", fnLabel]);
            putS(body, strtoll(toks[1].UTF8String, NULL, 0));
            break;
        case WImmF32:
            {
            if (toks.count < 2)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", @"f32.const needs a value", fnLabel]);
            float v = strtof(toks[1].UTF8String, NULL);
            [body appendBytes:&v length:4];
            break;
            }
        case WImmF64:
            {
            if (toks.count < 2)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", @"f64.const needs a value", fnLabel]);
            double v = strtod(toks[1].UTF8String, NULL);
            [body appendBytes:&v length:8];
            break;
            }
        case WImmLabel:
            {
            if (toks.count < 2)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", @"br needs a label", fnLabel]);
            NSInteger depth = -1;
            for (NSInteger i = (NSInteger)labels.count - 1; i >= 0; i--)
                if ([labels[(NSUInteger)i] isEqualToString:toks[1]])
                    {
                    depth = (NSInteger)labels.count - 1 - i;
                    break;
                    }
            if (depth < 0)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", [NSString stringWithFormat:@"unknown label '%@'", toks[1]], fnLabel]);
            putU(body, (uint64_t)depth);
            break;
            }
        case WImmBrTable:
            {
            // br_table $L0 $L1 … $Ldefault (last is the default).
            if (toks.count < 2)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", @"br_table needs labels", fnLabel]);
            NSMutableArray<NSNumber*>* depths = [NSMutableArray array];
            for (NSUInteger i = 1; i < toks.count; i++)
                {
                NSInteger depth = -1;
                for (NSInteger j = (NSInteger)labels.count - 1; j >= 0; j--)
                    if ([labels[(NSUInteger)j] isEqualToString:toks[i]])
                        {
                        depth = (NSInteger)labels.count - 1 - j;
                        break;
                        }
                if (depth < 0)
                    return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", [NSString stringWithFormat:@"unknown br_table label '%@'", toks[i]], fnLabel]);
                [depths addObject:@(depth)];
                }
            putU(body, depths.count - 1);
            for (NSNumber* d in depths)
                putU(body, d.unsignedIntegerValue);
            break;
            }
        case WImmLocal:
            {
            if (toks.count < 2)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", @"local op needs a name", fnLabel]);
            NSNumber* idx = localIndex[toks[1]];
            if (!idx)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", [NSString stringWithFormat:@"unknown local '%@'", toks[1]], fnLabel]);
            putU(body, idx.unsignedIntegerValue);
            break;
            }
        case WImmGlobal:
            {
            if (toks.count < 2)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", @"global op needs a name", fnLabel]);
            NSNumber* idx = globalIndex[toks[1]];
            if (!idx)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", [NSString stringWithFormat:@"unknown global '%@'", toks[1]], fnLabel]);
            putU(body, idx.unsignedIntegerValue);
            break;
            }
        case WImmCall:
            {
            if (toks.count < 2)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", @"call needs a target", fnLabel]);
            NSNumber* idx = fnIndex[toks[1]];
            if (!idx)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", [NSString stringWithFormat:@"unknown function '%@'", toks[1]], fnLabel]);
            putU(body, idx.unsignedIntegerValue);
            break;
            }
        case WImmLane:
            {
            // One lane-index byte (i32x4.extract_lane 2).
            if (toks.count < 2)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", @"lane op needs an index", fnLabel]);
            putByte(body, (uint8_t)strtoul(toks[1].UTF8String, NULL, 0));
            break;
            }
        case WImmLanes16:
            {
            // Sixteen lane-index bytes (i8x16.shuffle 0 2 4 …).
            if (toks.count < 17)
                return XTWasmFail(error, [NSString stringWithFormat:@"%@ (in %@)", @"shuffle needs 16 lanes", fnLabel]);
            for (NSUInteger ti = 1; ti <= 16; ti++)
                putByte(body, (uint8_t)strtoul(toks[ti].UTF8String, NULL, 0));
            break;
            }
        case WImmMemPair:
            break; // handled below
        default:
            break;
            }
        if ((WImm)enc[1].unsignedCharValue == WImmMemPair)
            {
            // Optional `offset=N` immediate token (the generated runtime's
            // free-list uses it); align stays the natural hint — for the
            // 0xFD-prefixed v128.load/store that is 16 bytes (log2 4).
            uint64_t memOff = 0;
            for (NSUInteger ti = 1; ti < toks.count; ti++)
                if ([toks[ti] hasPrefix:@"offset="])
                    memOff = strtoull([toks[ti] substringFromIndex:7].UTF8String, NULL, 0);
            putU(body, enc[0].unsignedCharValue == 0xFD
                           ? 4
                           : enc[2].unsignedIntegerValue); // natural align (log2)
            putU(body, memOff);
            }
        }
    putByte(body, 0x0B); // end of function
    return body;
    }

#pragma mark - Lexing helpers

+ (NSArray<NSString*>*)tokensOf:(NSString*)line
    {
    NSMutableArray<NSString*>* toks = [NSMutableArray array];
    NSMutableString* curTok = [NSMutableString string];
    BOOL inStr = NO;
    for (NSUInteger i = 0; i < line.length; i++)
        {
        unichar c = [line characterAtIndex:i];
        if (inStr)
            {
            [curTok appendFormat:@"%C", c];
            if (c == '"')
                {
                [toks addObject:[curTok copy]];
                [curTok setString:@""];
                inStr = NO;
                }
            continue;
            }
        if (c == '"')
            {
            if (curTok.length)
                {
                [toks addObject:[curTok copy]];
                [curTok setString:@""];
                }
            [curTok appendString:@"\""];
            inStr = YES;
            continue;
            }
        if (c == '(' || c == ')' || c == ' ' || c == '\t')
            {
            if (curTok.length)
                {
                [toks addObject:[curTok copy]];
                [curTok setString:@""];
                }
            continue;
            }
        [curTok appendFormat:@"%C", c];
        }
    if (curTok.length)
        [toks addObject:[curTok copy]];
    return toks;
    }

+ (NSData*)bytesOfDataLiteral:(NSString*)lit
    {
    NSMutableData* d = [NSMutableData data];
    for (NSUInteger i = 0; i < lit.length; i++)
        {
        unichar c = [lit characterAtIndex:i];
        if (c == '\\' && i + 2 < lit.length + 1)
            {
            unsigned hex = 0;
            NSScanner* sc = [NSScanner scannerWithString:
                                           [lit substringWithRange:NSMakeRange(i + 1, 2)]];
            [sc scanHexInt:&hex];
            uint8_t b = (uint8_t)hex;
            [d appendBytes:&b length:1];
            i += 2;
            }
        else
            {
            uint8_t b = (uint8_t)c;
            [d appendBytes:&b length:1];
            }
        }
    return d;
    }

@end
