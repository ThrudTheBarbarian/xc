#import "XTCompilerDriver.h"
#import "XTDesignableSynthesis.h"
#import "XTPreprocessor.h"
#import "XTLexer.h"
#import "XTToken.h"
#import "XTParser.h"
#import "XTDeclNodes.h"
#import "XTTypeTable.h"
#import "XTPointerType.h"
#import "XTSemanticAnalyzer.h"
#import "XTIR.h"
#import "XTIRLowering.h"
#import "XTIRVerifier.h"
#import "XTIRModule.h"
#import "XTIRSymbol.h"
#import "XTIRPrinter.h"
#import "XTArm64Backend.h"
#import "XT6502Backend.h"
#import "XTIRRuntimeEmitter.h"
#import "XTIROptPipeline.h"
#import "XAAssembler.h"
#import "XTDwarfReader.h"
#import "XTDwarfInterface.h"
#import "XTType.h"
#import "XTStructType.h"
#import "XTArrayType.h"
#import "XTEnumType.h"
#import "XTFunctionType.h"
#import "XTSourceLocation.h"

// The full legacy pipeline (preproc → lex → parse → sema → AST codegen → xta)
// is preserved as `XTCompilerDriver.m.old-codegen`. The current driver runs
// the new-IR pipeline (preproc → lex → parse → sema → IR-lower → verify →
// backend) and writes the raw backend asm to -o or stdout. Runtime/heap/ARC
// wrapping (the corpus-harness `buildXt6502Stub` / `buildStubCForFunction`
// glue) is NOT yet emitted from the driver — see the deferred task to factor
// that out of the corpus harness into a shared helper.

#import "XTInterfaceImporter.h"

@implementation XTCompilerDriver

- (instancetype)initWithOptions:(XTCommandLineOptions*)options
    {
    self = [super init];
    if (self)
        {
        _options = options;
        _neededLibraryPaths = @[];
        _diagnostics = [[XTDiagnosticEngine alloc] init];
        for (NSString* cat in options.suppressedWarnings)
            {
            XTWarningCategory c = XTWarningCategoryFromName(cat);
            if (c != XTWarnNone)
                [_diagnostics suppressWarningCategory:c];
            }
        }
    return self;
    }

// The support tree. One resolver for every binary — this used to be a private
// copy of the search, which meant the driver and its subprocesses could each
// decide a different tree was authoritative.
- (nullable NSString*)resolveSupportRoot
    {
    return [XTCommandLineOptions resolveSupportRoot:_options.xtcHome];
    }

// Build the preprocessor include-path list. -I paths win, then the
// platform-specific lib (support/<plat>/lib/) and finally the
// architecture-neutral generic lib (support/generic/lib/). On arm64 the
// platform is "arm64"; for 6502 targets it's whatever the memory model
// reports (atari, c64, …).
- (NSArray<NSString*>*)resolveIncludePaths
    {
    NSMutableArray* paths = [NSMutableArray arrayWithArray:_options.includePaths];
    NSFileManager* fmgr = [NSFileManager defaultManager];
    NSString* support = [self resolveSupportRoot];
    NSString* plat = _options.m68kPlatform
                         ? @"atarist"
                         : (_options.useWin64Backend
                                ? @"win64"
                                : (_options.useX86_64Backend
                                       ? @"x86_64"
                                       : (_options.useWasm32Backend
                                              ? @"wasm32"
                                              : (_options.useArm9Backend
                                                     ? @"arm9"
                                                     : (_options.useArm64Backend
                                                            ? @"arm64"
                                                            : (_options.memoryModel.platform ?: @"atari"))))));
    if (support)
        {
        // win64 shares the x86-64 native library tree (same ISA, libc-backed) —
        // search its own dir first (for any future OS-specific override), then
        // fall through to x86_64's. Every other platform is a single dir.
        // iOS: its own layer first (support/ios/lib — the Platform.xc
        // prelude), then the arm64 tree it shares the ISA and runtime with.
        NSArray<NSString*>* platDirs = _options.useWin64Backend
                                           ? @[ @"win64", @"x86_64" ]
                                           : (_options.applePlatform ? @[ @"ios", plat ] : @[ plat ]);
        for (NSString* pd in platDirs)
            {
            NSString* platLib = [support stringByAppendingPathComponent:
                                             [NSString stringWithFormat:@"%@/lib", pd]];
            if ([fmgr fileExistsAtPath:platLib])
                [paths addObject:platLib];
            }
        NSString* genericLib = [support stringByAppendingPathComponent:@"generic/lib"];
        if ([fmgr fileExistsAtPath:genericLib])
            [paths addObject:genericLib];

        // win64: `#import <kernel32/user32/gdi32>` normally resolves to the mingw
        // sysroot's import libraries, which ALSO makes the linker auto-link them.
        // Bundled interface stubs would shadow that — a program using a system
        // DLL would then compile but fail to link (undefined GetStockObject &c.).
        // So the stubs are searched ONLY when the mingw sysroot is ABSENT (a
        // non-Mac host, or a Mac without the win64 toolchain), where there is no
        // mingw to shadow and the self-hosted PE writer supplies the imports via
        // its own import table instead.
        if (_options.useWin64Backend)
            {
            const char* tc = getenv("XTC_WIN64_TOOLCHAIN");
            NSString* mingw = [(tc ? @(tc) : @"/opt/clang/win64")
                stringByAppendingPathComponent:@"x86_64-w64-mingw32/lib"];
            if (![fmgr fileExistsAtPath:mingw])
                {
                NSString* shIface = [support stringByAppendingPathComponent:@"win64/selfhost-iface"];
                if ([fmgr fileExistsAtPath:shIface])
                    [paths addObject:shIface];
                }
            }
        }
    if (_options.verbose)
        {
        fprintf(stderr, "xcc: platform: %s\n", plat.UTF8String);
        fprintf(stderr, "xcc: include search paths:\n");
        if (paths.count == 0)
            fprintf(stderr, "xcc:   (none)\n");
        else
            for (NSString* p in paths)
                fprintf(stderr, "xcc:   %s\n", p.UTF8String);
        }
    return paths;
    }

// ── Shared-library metadata imports ──────────────────────────────────────
// `#import <GEM>` that resolved to libGEM.so (not a source file) records the
// .so path in the preprocessor; we read each via the DWARF reader and bring
// its types + signatures into scope. See docs/OS/library-imports.md.

// Library search dirs: the user's -L plus the platform's lib dir under the
// support root (the cross-build sysroot), so the shipped .so's are found
// without an explicit -L for the default install.
// `/…/libGEM.so` -> `GEM`, the name the source spelled in `#import <GEM>`.
static NSString* cLibraryNameFromPath(NSString* path)
    {
    NSString* base = path.lastPathComponent.stringByDeletingPathExtension;
    if ([base hasPrefix:@"lib"])
        base = [base substringFromIndex:3];
    return base;
    }

- (nullable NSString*)resolveCLibraryNamed:(NSString*)name
    {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSArray<NSString*>* exts = @[ @"dylib", @"so" ]; // macOS host first, then ELF
    for (NSString* dir in [self resolveLibraryPaths])
        {
        for (NSString* ext in exts)
            {
            NSString* p = [[dir stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"lib%@.%@", name, ext]] stringByStandardizingPath];
            if ([fm fileExistsAtPath:p])
                return p;
            }
        }
    return nil;
    }

// YES if a `Platform.xc` exists on the include search path — gates the implicit
// platform prelude so targets without one (or a bare tree) simply skip it rather
// than failing every compile on a missing include.
- (BOOL)resolvePlatformPrelude
    {
    NSFileManager* fm = [NSFileManager defaultManager];
    for (NSString* dir in [self resolveIncludePaths])
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Platform.xc"]])
            return YES;
    return NO;
    }

// The third-party library roots. XCC_3P (tests, unusual layouts) first, then
// the sibling of the compiler home: /opt/xcc/<version> -> /opt/xcc/3p. The
// sibling placement is the point — make install's prune walks only lib/xc,
// and an upgrade replaces only the versioned root, so 3p content survives
// both with no exemption logic anywhere.
- (NSArray<NSString*>*)resolveThirdPartyRoots
    {
    NSMutableArray<NSString*>* roots = [NSMutableArray array];
    NSFileManager* fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    const char* env = getenv("XCC_3P");
    if (env && *env)
        {
        NSString* p = [@(env) stringByStandardizingPath];
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir)
            [roots addObject:p];
        }
    // Derive the compiler home from the support root (which self-resolves
    // relative to the binary when no -H is given): an install's support is
    // <home>/lib/xc, an in-tree build's is <home>/support. 3p is then the
    // home's SIBLING.
    NSString* support = [self resolveSupportRoot];
    if (support.length)
        {
        NSString* home = [support hasSuffix:@"/lib/xc"]
                             ? [[support stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
                             : [support stringByDeletingLastPathComponent];
        NSString* sib = [[home stringByAppendingPathComponent:@"../3p"]
            stringByStandardizingPath];
        if ([fm fileExistsAtPath:sib isDirectory:&isDir] && isDir && ![roots containsObject:sib])
            [roots addObject:sib];
        }
    return roots;
    }

- (NSArray<NSString*>*)resolveLibraryPaths
    {
    NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithArray:_options.libraryPaths];
    NSString* support = [self resolveSupportRoot];
    NSString* plat = _options.useWin64Backend    ? @"win64"
                     : _options.useX86_64Backend ? @"x86_64"
                     : _options.useWasm32Backend ? @"wasm32"
                     : _options.useArm9Backend   ? @"arm9"
                     : _options.useArm64Backend  ? @"arm64"
                     : _options.m68kPlatform     ? @"atarist"
                                                 : (_options.memoryModel.platform ?: @"atari");
    if (support)
        {
        // win64 shares x86_64's native library tree (see resolveIncludePaths).
        // iOS: its own layer first (support/ios/lib — the Platform.xc
        // prelude), then the arm64 tree it shares the ISA and runtime with.
        NSArray<NSString*>* platDirs = _options.useWin64Backend
                                           ? @[ @"win64", @"x86_64" ]
                                           : (_options.applePlatform ? @[ @"ios", plat ] : @[ plat ]);
        for (NSString* pd in platDirs)
            [paths addObject:[support stringByAppendingPathComponent:
                                          [NSString stringWithFormat:@"%@/lib", pd]]];
        }
    // win64: the mingw sysroot lib dir holds the Win32 system import libraries
    // (libuser32.a, libgdi32.a, …), so `#import <user32>` links the real Windows
    // API. Toolchain root from $XTC_WIN64_TOOLCHAIN (default /opt/clang/win64).
    if (_options.useWin64Backend)
        {
        const char* tc = getenv("XTC_WIN64_TOOLCHAIN");
        NSString* root = tc ? @(tc) : @"/opt/clang/win64";
        [paths addObject:[root stringByAppendingPathComponent:@"x86_64-w64-mingw32/lib"]];
        }
    return paths;
    }

// Locate the platform's `libc.so` in the library search dirs, so a target with a
// real libc can auto-import it (no `#import <c>` in source). nil if absent — a
// platform without a libc (the 6502) simply never gets one.
- (nullable NSString*)resolveLibcLibrary
    {
    NSFileManager* fm = [NSFileManager defaultManager];
    for (NSString* dir in [self resolveLibraryPaths])
        {
        NSString* p = [[dir stringByAppendingPathComponent:@"libc.so"] stringByStandardizingPath];
        if ([fm fileExistsAtPath:p])
            return p;
        }
    return nil;
    }

// The target's native pointer width — used so the DWARF reader reconstructs
// struct padding that reproduces the C offsets at the BACKEND's widths.
- (NSUInteger)targetPointerWidth
    {
    if (_options.useX86_64Backend)
        return 8; // x86-64 LP64
    if (_options.useWin64Backend)
        return 8; // x86-64 Windows LLP64 (pointers still 8)
    if (_options.useWasm32Backend)
        return 4; // wasm32 linear memory
    if (_options.useArm9Backend)
        return 4; // AArch32
    if (_options.useArm64Backend)
        return 8; // host LP64
    if (_options.m68kPlatform)
        return 4; // 68k
    return 2;     // 6502 front-end default
    }

// An anonymous aggregate (a C union or unnamed struct inside another) has a
// DWARF-generated name like `$anon_582569`, which is not an xtc identifier.
// It gets a synthetic one, and its declaration is emitted alongside — the
// name never reaches the IR, only the layout does.
static NSString* XTAnonName(NSString* disp)
    {
    return [@"__xtc_anon_" stringByAppendingString:
                               [disp substringFromIndex:[disp rangeOfString:@"_"].location + 1]];
    }

// The xtc spelling of an imported type, queueing any anonymous aggregate it
// names into `pending` so the caller emits a declaration for that too.
static NSString* XTTypeSpelling(XTType* t, NSMutableDictionary<NSString*, XTType*>* pending)
    {
    NSString* d = t.displayName;
    // A C function pointer has no source spelling that survives to the IR: the
    // original lowers the FUNCTION type itself to `Void` and each `@` on top of
    // it to one pointer level, so `i32(void@,void@)@@` is `void@@`. Read off the
    // original's own IR, not chosen — calling through the field is not the
    // point, occupying the right slot is. The suffix has to be carried across:
    // a pointer TO a function pointer is one level deeper.
    if ([d rangeOfString:@"("].location != NSNotFound)
        {
        NSRange close = [d rangeOfString:@")" options:NSBackwardsSearch];
        NSString* stars = close.location == NSNotFound
                              ? @"@"
                              : [d substringFromIndex:close.location + 1];
        return [@"void" stringByAppendingString:stars];
        }
    if ([d rangeOfString:@"$anon"].location == NSNotFound)
        return d;

    // `$anon_N`, `$anon_N@`, … — rename the head, keep the pointer suffix.
    NSUInteger cut = d.length;
    for (NSUInteger i = 0; i < d.length; i++)
        {
        unichar c = [d characterAtIndex:i];
        if (c == '@' || c == '[')
            {
            cut = i;
            break;
            }
        }
    NSString* head = [d substringToIndex:cut];
    XTType* bare = t;
    while ([bare isKindOfClass:[XTPointerType class]])
        bare = ((XTPointerType*)bare).pointeeType;
    if ([bare isKindOfClass:[XTStructType class]])
        pending[head] = bare;
    return [XTAnonName(head) stringByAppendingString:[d substringFromIndex:cut]];
    }

// One field of an imported struct, spelled as xtc source.
static NSString* XTFieldSpelling(XTStructField* f,
                                 NSMutableDictionary<NSString*, XTType*>* pending)
    {
    XTType* t = f.fieldType;
    if ([t isKindOfClass:[XTArrayType class]])
        {
        XTArrayType* a = (XTArrayType*)t;
        if ([a.elementType isKindOfClass:[XTArrayType class]])
            return nil;
        return [NSString stringWithFormat:@"%@ %@[%lu]",
                                          XTTypeSpelling(a.elementType, pending),
                                          f.fieldName, (unsigned long)a.elementCount];
        }
    return [NSString stringWithFormat:@"%@ %@", XTTypeSpelling(t, pending), f.fieldName];
    }

// `struct <name> { … }` for one imported aggregate, or nil if a field defeats
// the spelling (a nested array-of-array). Anonymous members it names are added
// to `pending` for the caller to emit in turn.
static NSString* XTStructDeclaration(NSString* name, XTStructType* st,
                                     NSMutableDictionary<NSString*, XTType*>* pending)
    {
    NSMutableArray<NSString*>* fs = [NSMutableArray array];
    for (XTStructField* f in st.fields)
        {
        NSString* sp = XTFieldSpelling(f, pending);
        if (!sp)
            return nil;
        [fs addObject:[NSString stringWithFormat:@"    %@;", sp]];
        }
    // A zero-field struct is legitimate — an OPAQUE C type the DWARF declares
    // but never defines (`__locale_t`). The original lays it out as size=0, and
    // `struct X { }` reproduces that.
    return [NSString stringWithFormat:@"struct %@\n{\n%@%@}", name,
                                      [fs componentsJoinedByString:@"\n"], fs.count ? @"\n" : @""];
    }

// --dump-c-iface: the auto-imported C interface, printed as xtc source. See
// the header for why it exists; `selfhost/tools/gen-c-iface.sh` turns it into
// `support/<plat>/selfhost-iface/c.xc`.
- (int)dumpCInterfaceDeclarations
    {
    NSString* libc = [self resolveLibcLibrary];
    if (!libc)
        {
        fprintf(stderr, "xcc-fe: --dump-c-iface: no libc.so on the library "
                        "search path — pass -L <loader build dir>\n");
        return 1;
        }
    NSArray<XTDwarfInterface*>* ifaces = [self readMetadataImports:@[ libc ]];
    NSMutableSet<NSString*>* seen = [NSMutableSet set];
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    for (XTDwarfInterface* iface in ifaces)
        {
        for (XTDwarfFunction* fn in iface.functions)
            {
            if ([seen containsObject:fn.name])
                continue;
            [seen addObject:fn.name];
            NSMutableArray<NSString*>* ps = [NSMutableArray array];
            for (NSUInteger i = 0; i < fn.paramTypes.count; i++)
                {
                NSString* pn = (i < fn.paramNames.count && fn.paramNames[i].length)
                                   ? fn.paramNames[i]
                                   : [NSString stringWithFormat:@"a%lu", (unsigned long)i];
                [ps addObject:[NSString stringWithFormat:@"%@ %@",
                                                         fn.paramTypes[i].displayName, pn]];
                }
            if (fn.isVarArgs)
                [ps addObject:@"..."];
            [lines addObject:[NSString stringWithFormat:@"%@ %@(%@);",
                                                        fn.returnType.displayName, fn.name,
                                                        ps.count ? [ps componentsJoinedByString:@", "] : @"void"]];
            }
        }
    // The struct types those functions name. A struct whose fields the language
    // cannot spell is printed as a comment instead — the generator drops every
    // function that mentions it, because a guessed layout is worse than a
    // missing declaration.
    NSMutableArray<NSString*>* structs = [NSMutableArray array];
    NSMutableDictionary<NSString*, XTType*>* pending = [NSMutableDictionary dictionary];
    for (XTDwarfInterface* iface in ifaces)
        {
        NSArray<NSString*>* names =
            [iface.types.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString* nm in names)
            {
            XTType* t = iface.types[nm];
            if (![t isKindOfClass:[XTStructType class]])
                continue;
            NSString* decl = XTStructDeclaration(nm, (XTStructType*)t, pending);
            [structs addObject:decl ?: [NSString stringWithFormat:@"// struct %@: not spellable in xtc", nm]];
            }
        }
    // The anonymous members those declarations named, and any they name in
    // turn — the queue grows while it is drained.
    NSMutableSet<NSString*>* done = [NSMutableSet set];
    while (YES)
        {
        NSString* key = nil;
        for (NSString* k in [pending.allKeys sortedArrayUsingSelector:@selector(compare:)])
            if (![done containsObject:k])
                {
                key = k;
                break;
                }
        if (!key)
            break;
        [done addObject:key];
        NSString* decl = XTStructDeclaration(XTAnonName(key),
                                             (XTStructType*)pending[key], pending);
        [structs addObject:decl ?: [NSString stringWithFormat:@"// struct %@: not spellable in xtc", XTAnonName(key)]];
        }
    for (NSString* l in structs)
        puts(l.UTF8String);
    for (NSString* l in lines)
        puts(l.UTF8String);
    return 0;
    }

- (NSArray<XTDwarfInterface*>*)readMetadataImports:(NSArray<NSString*>*)paths
    {
    if (paths.count == 0)
        return @[];
    NSUInteger pw = [self targetPointerWidth];
    NSMutableArray<XTDwarfInterface*>* out = [NSMutableArray array];
    for (NSString* p in paths)
        {
        NSError* err = nil;
        XTDwarfInterface* iface = [XTDwarfReader readInterfaceFromPath:p
                                                    targetPointerWidth:pw
                                                                 error:&err];
        if (!iface)
            {
            // A Windows import library (mingw's libuser32.a, libcomctl32.a, …) is a
            // COFF archive that carries no DWARF BY DESIGN: it exists so the DLL
            // lands on the link line, and the caller declares the prototypes itself.
            // Failing to read metadata from one is the expected case, not a fault —
            // warning about it sends people chasing a link failure that isn't
            // happening, so say it only under -V.
            BOOL win64ImportLib = _options.useWin64Backend &&
                                  [p.pathExtension isEqualToString:@"a"];
            if (!win64ImportLib)
                {
                fprintf(stderr, "xcc: warning: cannot read library metadata from '%s': %s\n",
                        p.UTF8String, err.localizedDescription.UTF8String ?: "unknown error");
                }
            else if (_options.verbose)
                {
                fprintf(stderr, "xcc: note: '%s' is a Win32 import library (no DWARF); "
                                "linked by name, declare its prototypes in source\n",
                        p.UTF8String);
                }
            continue;
            }
        if (iface.functions.count == 0 && iface.types.count == 0)
            {
            fprintf(stderr, "xcc: warning: '%s' carries no DWARF — imported names are "
                            "untyped (build the Debug/ variant)\n",
                    p.UTF8String);
            }
        [out addObject:iface];
        }
    return out;
    }

// Register imported struct/enum types BEFORE parsing so user source can name
// them (`MFDB m;`). Built-ins win (never clobbered); the parser's forward-ref
// pre-scan then skips any name already present, so these stay authoritative
// for the import while user types still register under their own names.
- (void)injectImportedTypes:(NSArray<XTDwarfInterface*>*)ifaces
              intoTypeTable:(XTTypeTable*)tt
    {
    for (XTDwarfInterface* iface in ifaces)
        {
        [iface.types enumerateKeysAndObjectsUsingBlock:^(NSString* name, XTType* type, BOOL* stop) {
          if (![tt isTypeName:name])
              [tt registerType:type forName:name];
        }];
        }
    }

/****************************************************************************\
|* Make a C library's enum constants usable as bare identifiers.
|*
|* `#import <GEM>` brought in structs and functions but NOT the enumerators of
|* an anonymous enum — and aes.h declares every constant that way:
|*
|*     enum { G_BOX = 20, ..., G_USERDEF = 24 };
|*     enum { OF_NONE = 0x00, ..., OF_HIDETREE = 0x80 };
|*
|* So `G_USERDEF`, `OF_HIDETREE`, `W_NAME` … were invisible and every binding
|* hand-mirrored them — duplication that silently drifts when the header changes.
|*
|* Synthesised as a single XTEnumDeclNode prepended to the program, which reuses
|* sema's existing enum pre-scan verbatim: it registers each member as a global
|* XTStorageClassConst symbol, exactly like a native `enum`. A constant the user
|* (or an earlier import) already defines is skipped, so a local definition wins
|* and imports never collide.
\****************************************************************************/
// Strip any type-prefix qualifiers ("weak:", "banked:", …) from a displayName,
// leaving the bare type spelling for a cast target ("weak:XGView@" → "XGView@").

// #9 conformance downcast: inject the runtime helper `_xtc_obj_conforms(obj, pid)`
// so a `(P@ ?)obj` cast can ask whether the object's dynamic class carries P's id.
// It walks obj → vtable → itable (the (protoId,&table) list this class emits when
// sVtableConforms/sItableProtocols is on) and scans the ids — pure xtc, so the
// pointer-array stride is right on every backend. Injected only when the backend
// carries the conformance itable; the lowering rewrites the cast into a call here.
// Dead-function-elim drops it when no downcast uses it.
- (XTProgramNode*)injectConformanceHelper:(XTProgramNode*)ast typeTable:(XTTypeTable*)tt
                                    arm64:(BOOL)arm64
    {
    // Takes the object's ALREADY-VALIDATED vtable pointer: the caller reads obj[0]
    // and (with a full-width compare it can't do in xtc source — pointer compares
    // are 16-bit here) passes null when it is a non-vtable class's small class-id
    // or the object itself is null. Given a real vtable it reads the itable at slot
    // 1 and scans the (protoId, &table) pairs for `pid`.
    NSString* src =
        @"bool _xtc_obj_conforms(pointer vtbl, u32 pid) {\n"
        @"  if (vtbl == (pointer)0) { return false; }\n"
        @"  pointer@ vp = (pointer@)vtbl;\n"
        @"  pointer itab = vp[1];\n" // vtable[1] = itable ptr (after parent link)
        @"  if (itab == (pointer)0) { return false; }\n"
        @"  pointer@ ip = (pointer@)itab;\n"
        @"  i32 k = (i32)0;\n"
        @"  while (ip[k + k] != (pointer)0) {\n" // (protoId, &table) pairs; id at even index
        @"    if ((u32)ip[k + k] == pid) { return true; }\n"
        @"    k = k + (i32)1;\n"
        @"  }\n"
        @"  return false;\n"
        @"}\n";
    XTLexer* lexer = [[XTLexer alloc] initWithSource:src
                                            filename:@"<conformance-helper>"
                                         diagnostics:_diagnostics];
    NSArray<XTToken*>* toks = nil;
    toks = [lexer tokenise];
    XTParser* parser = [[XTParser alloc] initWithTokens:toks typeTable:tt diagnostics:_diagnostics];
    parser.defaultPointerPlacement = arm64 ? XTPointerPlacementMain : XTPointerPlacementHeap;
    XTProgramNode* synth = nil;
    synth = [parser parse];
    if (!synth || _diagnostics.errorCount > 0)
        return ast;
    NSMutableArray<XTASTNode*>* decls = [ast.declarations mutableCopy];
    [decls addObjectsFromArray:synth.declarations];
    return [[XTProgramNode alloc] initWithDeclarations:decls location:ast.location];
    }

// NIB reflection (uxkit/026, XG-NIB §4): auto-conform designable classes to the
// binding protocol and synthesise the
// three reflection bodies. A class is "designable" if it declares any `outlet`
// field or `:action` method. The bodies are generated as xtc source, parsed with
// the real lexer/parser (sharing this compilation's type table), then transplanted
// into the real classes — far simpler than hand-building the AST, and it exercises
// the identical failable-cast / bound-method / `new` lowering the user would write.

- (XTProgramNode*)program:(XTProgramNode*)ast
    withImportedEnumConstants:(NSArray<XTDwarfInterface*>*)ifaces
    {
    if (ifaces.count == 0)
        return ast;
    NSMutableArray<XTEnumMemberNode*>* members = [NSMutableArray array];
    NSMutableSet<NSString*>* seen = [NSMutableSet set];
    // A name the source itself declares must win over an imported constant.
    for (XTASTNode* d in ast.declarations)
        {
        if (![d isKindOfClass:[XTEnumDeclNode class]])
            continue;
        for (XTEnumMemberNode* m in ((XTEnumDeclNode*)d).members)
            [seen addObject:m.memberName];
        }
    XTSourceLocation* loc = [XTSourceLocation locationWithFilename:@"<import>" line:0 column:0];
    for (XTDwarfInterface* iface in ifaces)
        {
        // Sorted so the synthesised decl is deterministic across runs.
        for (NSString* name in [iface.enumConstants.allKeys sortedArrayUsingSelector:@selector(compare:)])
            {
            if ([seen containsObject:name])
                continue;
            [seen addObject:name];
            XTEnumMemberNode* m = [[XTEnumMemberNode alloc] initWithName:name
                                                           explicitValue:iface.enumConstants[name]
                                                                location:loc];
            m.resolvedValue = iface.enumConstants[name].longLongValue;
            [members addObject:m];
            }
        }
    if (members.count == 0)
        return ast;
    XTEnumDeclNode* en = [[XTEnumDeclNode alloc] initWithName:@"$imported_constants"
                                                      members:members
                                                     location:loc];
    NSMutableArray<XTASTNode*>* decls = [ast.declarations mutableCopy];
    [decls insertObject:en atIndex:0];
    return [[XTProgramNode alloc] initWithDeclarations:decls location:ast.location];
    }

// Build body-less XTFunctionDeclNode prototypes for every typed export and
// prepend them to the program. A nil body makes each an external symbol the
// backend emits as a bare `bl <cname>` for the linker to resolve.
- (XTProgramNode*)program:(XTProgramNode*)ast
    withImportedFunctions:(NSArray<XTDwarfInterface*>*)ifaces
                usedNames:(NSSet<NSString*>*)usedNames
    {
    if (ifaces.count == 0)
        return ast;
    XTSourceLocation* loc = [XTSourceLocation locationWithFilename:@"<import>" line:0 column:0];
    NSMutableArray<XTASTNode*>* protos = [NSMutableArray array];
    NSMutableSet<NSString*>* seen = [NSMutableSet set];
    // libc is the LOWEST-precedence layer: a free function the user or an imported
    // lib already declares (e.g. Math's `random`, parsed in via `#import "Math.xc"`,
    // or Stdio's text helpers) SHADOWS the libc symbol of that name. Collect those
    // names and skip their libc protos, so the explicit import always wins.
    NSMutableSet<NSString*>* shadowed = [NSMutableSet set];
    for (XTASTNode* d in ast.declarations)
        if ([d isKindOfClass:[XTFunctionDeclNode class]])
            [shadowed addObject:((XTFunctionDeclNode*)d).funcName];
    for (XTDwarfInterface* iface in ifaces)
        {
        for (XTDwarfFunction* fn in iface.functions)
            {
            if (![usedNames containsObject:fn.name])
                continue; // not referenced — skip
            if ([shadowed containsObject:fn.name])
                continue; // shadowed by an explicit decl
            if ([seen containsObject:fn.name])
                continue; // one proto per symbol
            [seen addObject:fn.name];
            NSMutableArray<XTParamNode*>* params = [NSMutableArray array];
            for (NSUInteger i = 0; i < fn.paramTypes.count; i++)
                {
                NSString* pn = (i < fn.paramNames.count && fn.paramNames[i].length)
                                   ? fn.paramNames[i]
                                   : [NSString stringWithFormat:@"a%lu", (unsigned long)i];
                [params addObject:[[XTParamNode alloc] initWithType:fn.paramTypes[i]
                                                               name:pn
                                                           location:loc]];
                }
            XTFunctionDeclNode* proto =
                [[XTFunctionDeclNode alloc] initWithName:fn.name
                                             returnTypes:@[ fn.returnType ]
                                              parameters:params
                                               isVarArgs:fn.isVarArgs
                                                    body:nil
                                                location:loc];
            proto.mangledName = fn.name; // bare C symbol — no overload mangling
            proto.isCImport = YES;       // C/AAPCS ABI (esp. variadic arg passing)
            [protos addObject:proto];
            }
        }
    if (protos.count == 0)
        return ast;
    [protos addObjectsFromArray:ast.declarations];
    return [[XTProgramNode alloc] initWithDeclarations:protos location:ast.location];
    }

// Predefine the layout-driven printf buffer macros, the bank(...) builtin
// selector constants, the ARCH_<arch> sentinel, the heap pointer width,
// and the user's -D defines. Mirrors the corpus-harness frontend setup so
// the same library source files (Stdio, Foundation, …) resolve cleanly.
- (void)setupPreprocessor:(XTPreprocessor*)pp arm64:(BOOL)arm64
    {
    XTMemoryModel* m = _options.memoryModel;
    NSArray* fmtR = m.buffers[@"stdio_fmt"];
    NSUInteger fmtB = (fmtR.count == 2) ? [fmtR[0] unsignedIntegerValue] : 0;
    NSArray* pfR = m.buffers[@"printf"];
    NSUInteger pfB = (pfR.count == 2) ? [pfR[0] unsignedIntegerValue] : 0;
    [pp defineMacro:@"XT_STDIO_FMT_BUF"
              value:[NSString stringWithFormat:@"$%04lX", (unsigned long)fmtB]];
    [pp defineMacro:@"XT_PRINTF_BUF"
              value:[NSString stringWithFormat:@"$%04lX", (unsigned long)pfB]];
    [pp defineMacro:@"XT_PRINTF_DATA_BUF"
              value:[NSString stringWithFormat:@"$%04lX", (unsigned long)(pfB + 2)]];

    [pp defineMacro:@"BANK_DATA" value:@"0"];
    [pp defineMacro:@"BANK_CODE" value:@"1"];
    [pp defineMacro:@"BANK_C" value:@"2"];

    if (_options.m68kPlatform)
        [pp defineMacro:@"ARCH_m68k" value:@"1"];
    else if (_options.useWin64Backend)
        {
        // Windows is x86-64 ISA — define ARCH_x86_64 so ISA-guarded library
        // sources compile, plus ARCH_win64 for OS-specific dispatch.
        [pp defineMacro:@"ARCH_x86_64" value:@"1"];
        [pp defineMacro:@"ARCH_win64" value:@"1"];
        }
    else if (_options.useX86_64Backend)
        [pp defineMacro:@"ARCH_x86_64" value:@"1"];
    else if (_options.useWasm32Backend)
        [pp defineMacro:@"ARCH_wasm32" value:@"1"];
    else if (_options.useArm9Backend)
        [pp defineMacro:@"ARCH_arm9" value:@"1"];
    else if (arm64)
        [pp defineMacro:@"ARCH_arm64" value:@"1"];
    else
        [pp defineMacro:@"ARCH_6502" value:@"1"];
    // The platform LAYER's defines, beside the ISA's: PLATFORM_ios says where
    // the code runs, PLATFORM_ios_sim which flavour (iOS.md stage 4). AFTER
    // the else-if chain above — inserted inside it, this `if` captured the
    // chain's final `else` and every non-iOS arm64 build got ARCH_6502.
    if (_options.applePlatform)
        {
        [pp defineMacro:@"PLATFORM_ios" value:@"1"];
        if ([_options.applePlatform isEqualToString:@"ios-sim"])
            [pp defineMacro:@"PLATFORM_ios_sim" value:@"1"];
        }

    [pp defineMacro:@"XTC_POINTER_WIDTH" value:@"4"];

    // Target-shape macros mirrored from the legacy driver. Inline asm
    // in the runtime library / library classes references these because
    // the preprocessor can't #ifdef on a memory-model property.
    //
    // The xtc *software* stack (XTC_SP) only exists on flat/standard
    // targets whose 256-byte hardware stack is too shallow for the
    // runtime libs' recursion frames. xt has a 4 KB hidden hardware
    // stack, so it drops XTC_SP entirely and the libs push those frames
    // on the hardware stack instead (gated by XTC_LIB_HWSTACK below) —
    // leaving the backend's spill-frame SSP as the one and only software
    // stack pointer. Defining XTC_SP on xt at all is therefore wrong: it
    // used to alias the backend's SSP at $8A.
    if (m.kind != XTMemoryModelKindXT)
        {
        [pp defineMacro:@"XTC_SP_LO" value:@"$82"];
        [pp defineMacro:@"XTC_SP_HI" value:@"$83"];
        }
    [pp defineMacro:@"XTC_HP_LO"
              value:[NSString stringWithFormat:@"$%02X", m.zpHPStart]];
    [pp defineMacro:@"XTC_HP_HI"
              value:[NSString stringWithFormat:@"$%02X", m.zpHPStart + 1]];
    if (m.isBanked)
        [pp defineMacro:@"XTC_TARGET_BANKED" value:@"1"];
    else
        [pp defineMacro:@"XTC_TARGET_STANDARD" value:@"1"];
    [pp defineMacro:@"XTC_TARGET_SHADOW" value:m.hasShadow ? @"1" : @"0"];
    [pp defineMacro:@"XTC_HAS_CLOAKED" value:(m.portBMask != 0) ? @"1" : @"0"];
    // Route the runtime libs' recursion frames onto the CPU hardware
    // stack when the target has a deep enough one: cloak-capable targets
    // (PORTB unmaps the software-stack window mid-cloak) or xt (4 KB
    // hidden stack). Flat xl stays on the software stack (XTC_SP).
    [pp defineMacro:@"XTC_LIB_HWSTACK"
              value:(m.portBMask != 0 || m.kind == XTMemoryModelKindXT) ? @"1" : @"0"];

    [_options.defines enumerateKeysAndObjectsUsingBlock:
                          ^(NSString* k, NSString* v, BOOL* stop) {
                            [pp defineMacro:k value:v];
                          }];
    }

// Gate the `%@` / Object dependency: every backend's Stdio pulls in the
// Object root (and String) for `%@` -> description() dispatch ONLY when the
// program actually uses `%@`, via `#if HAS_ATFMT`. Detect it by a throwaway
// preprocess of the FULLY-EXPANDED source (the spec can live in an imported
// library, and the preprocessor strips comments so Stdio's own `//  %@` doc
// lines don't count), then define HAS_ATFMT on the real preprocessor before
// it evaluates the guard.
//
// This is the ONE printf format-feature gate that's cross-target and worth
// keeping — it fences off a heavy dependency, not just a code branch. The
// xt6502-only width/float gates (HAS_DFMT/…/HAS_LFMT) were removed in
// phase-559 because xt6502 banks the pruned code into abundant pages; the
// parked flat-6502 Stdio in support/6502 still carries them.
- (void)setupObjectFmtGateOnto:(XTPreprocessor*)pp
                    fromSource:(NSString*)rawSource
                      filename:(NSString*)filename
                         arm64:(BOOL)arm64
                  includePaths:(NSArray<NSString*>*)includePaths
    {
    XTPreprocessor* scanPP = [[XTPreprocessor alloc]
        initWithDiagnostics:[[XTDiagnosticEngine alloc] init]];
    scanPP.includePaths = includePaths;
    [self setupPreprocessor:scanPP arm64:arm64];
    NSString* expanded = nil;
    expanded = [scanPP preprocessSource:rawSource filename:filename];
    if (!expanded)
        expanded = rawSource;
    BOOL hasAt = [expanded rangeOfString:@"%@"].location != NSNotFound;
    [pp defineMacro:@"HAS_ATFMT" value:hasAt ? @"1" : @"0"];
    }

// Run preprocess → lex → parse → sema → IR-lower → verify, returning the
// verified IR module on success or nil on any frontend error. Both
// compileFile: (in-process backend) and xtc-fe (writes IR text and exits)
// call this — the split keeps the frontend in one canonical place.
- (nullable XTIRModule*)compileFrontendForFile:(NSString*)inputFile
    {
    BOOL arm64 = _options.useArm64Backend;

    NSString* rawSource = [NSString stringWithContentsOfFile:inputFile
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
    if (!rawSource)
        {
        fprintf(stderr, "xcc: error: cannot read '%s'\n", inputFile.UTF8String);
        return nil;
        }
    [_diagnostics registerSource:rawSource forFile:inputFile];

    NSArray<NSString*>* includePaths = [self resolveIncludePaths];

    // ── Preprocess ───────────────────────────────────────────────────────
    XTPreprocessor* pp = [[XTPreprocessor alloc] initWithDiagnostics:_diagnostics];
    pp.includePaths = includePaths;
    pp.libraryPaths = [self resolveLibraryPaths];
    // Shared-lib resolution order by target object format: arm64 macOS is Mach-O
    // (`.dylib`); win64 is PE (`.dll`, with a `.dll.a` import lib beside it); every
    // other shared-lib target (x86-64 / arm9) is ELF (`.so`). Pin the right one
    // first so a stale sibling of the wrong format in a -L dir never gets picked.
    // For win64 the `.dll` is preferred (it carries the `.xtc_iface` section the
    // front end reads); the linker derives the `.dll.a` import lib from it.
    pp.sharedLibExtensions = _options.useWin64Backend
                                 ? @[ @"dll", @"dll.a", @"a" ]          // xtc DLL, its import lib, or a system import lib (libuser32.a)
                             : _options.useWasm32Backend ? @[ @"wasm" ] // W2: lib<X>.wasm (iface in a custom section)
                             : _options.useArm64Backend  ? @[ @"dylib", @"so" ]
                                                         : @[ @"so", @"dylib" ];
    // Third-party tree: /opt/xcc/3p — a SIBLING of the versioned install
    // root, so it survives make install's prune and compiler upgrades.
    // XCC_3P overrides (tests, unusual layouts). Probed between the explicit
    // -L dirs and the appended defaults; see the header note on
    // explicitLibraryPathCount and private:docs/Design/third-party-libraries.md.
    pp.thirdPartyRoots = [self resolveThirdPartyRoots];
    pp.targetArchName = _options.useWin64Backend    ? @"win64"
                        : _options.useX86_64Backend ? @"x86_64"
                        : _options.useWasm32Backend ? @"wasm32"
                        : _options.useArm9Backend   ? @"arm9"
                        : _options.useArm64Backend  ? @"arm64"
                        : _options.m68kPlatform     ? @"atarist"
                                                    : (_options.memoryModel.platform ?: nil);
    pp.explicitLibraryPathCount = _options.explicitLibraryPathCount;
    // Auto-include the platform's system-dependent header so source stays
    // platform-agnostic: Platform.xc resolves from support/<platform>/lib first
    // (the win64 one does `#import <user32>` …), then the empty generic fallback.
    if ([self resolvePlatformPrelude])
        pp.platformPrelude = @"Platform.xc";
    [self setupPreprocessor:pp arm64:arm64];
    [self setupObjectFmtGateOnto:pp
                      fromSource:rawSource
                        filename:inputFile
                           arm64:arm64
                    includePaths:includePaths];

    NSString* expanded = nil;
    expanded = [pp preprocessSource:rawSource filename:inputFile];
    _preludeFiles = pp.preludeFiles;
    if (!expanded || _diagnostics.hasFatalError)
        {
        [_diagnostics printAll];
        fprintf(stderr, "xcc: preprocess failed\n");
        return nil;
        }
    if (_options.preprocessedOutputPath)
        {
        NSError* err = nil;
        [expanded writeToFile:_options.preprocessedOutputPath
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:&err];
        if (err)
            {
            fprintf(stderr, "xcc: error: cannot write -E output to '%s'\n",
                    _options.preprocessedOutputPath.UTF8String);
            return nil;
            }
        }

    // ── Lex ──────────────────────────────────────────────────────────────
    XTLexer* lexer = [[XTLexer alloc] initWithSource:expanded
                                            filename:inputFile.lastPathComponent
                                         diagnostics:_diagnostics];
    NSArray<XTToken*>* tokens = nil;
    tokens = [lexer tokenise];
    if (_diagnostics.hasFatalError)
        {
        [_diagnostics printAll];
        return nil;
        }

    // ── Library metadata imports (#import <lib> that resolved to a .so) ──
    // The widths go up FIRST, because the DWARF reader RECOMPUTES an imported
    // struct's field offsets at the front end's current pointer width: reading
    // the metadata before this line laid `struct __sFILE` out with 2-byte
    // pointers on arm9, so every field past the first pointer sat at the wrong
    // offset while the struct kept its true C size.
    // Pointer width for the AST and the IR layout: the target's NATIVE width,
    // so it agrees with what the backend actually lays out and loads. It must,
    // because `sizeof` reports it and struct offsets are built from it — arm64
    // used to say 2 here while its backend used 8, so `sizeof(u8@)` was 2 and a
    // struct with a pointer member got a 2-byte slot that the 64-bit store then
    // overran. The banked 6502 keeps 3 ([addr-lo, addr-hi, bank]).
    // NB: the front end is spawned with `-m <platform>`, not `-A <arch>`, so key
    // off the platform flag as well — `-m atarist` sets m68kPlatform, not
    // useM68kBackend, and m68k would otherwise fall through to the 6502's 3.
    NSUInteger ptrWidth = 3; // xt6502
    if (arm64 || _options.useX86_64Backend || _options.useWin64Backend)
        ptrWidth = 8;
    else if (_options.useM68kBackend || _options.m68kPlatform || _options.useArm9Backend || _options.useWasm32Backend)
        ptrWidth = 4;
    [XTPointerType setHeapPointerWidth:ptrWidth];
    // …and the width of the allocation header's COUNT field, which is a
    // different number: arm9 and m68k share a 4-byte pointer but hold 4- and
    // 2-byte counts. `.length` is typed from this, so a wrong value here
    // truncates every long array rather than mis-sizing anything (bug 234).
    // Per RUNTIME HEADER, and they differ: arm64's is 38 bytes with a u64
    // count at payload-26; x86-64/win64's is 30 bytes with a u32 at
    // payload-22; arm9's 24 with a u32; m68k's 10 with a u16. Reading the
    // pointer width instead would have claimed 8 for x86-64 and invented
    // 32 bits the header does not have.
    // Capped at 4 even where the header holds 8 (arm64): 4G elements is beyond
    // any real use, and it keeps `.length` the SAME type on every 32/64-bit
    // target, so portable source sees one width and the for-in / slice index
    // arithmetic never has to carry a u64.
    NSUInteger cntWidth = 2; // m68k [count:2][elemSize:2]; xt6502 stores none
    if (arm64 || _options.useX86_64Backend || _options.useWin64Backend ||
        _options.useArm9Backend || _options.useWasm32Backend)
        cntWidth = 4;
    [XTPointerType setHeapCountWidth:cntWidth];
    // Struct FIELD alignment cap (blewit #5): fields align to
    // min(natural alignment, cap), and the offsets land in the IR layout,
    // which every backend reads verbatim. 8 = full C natural alignment on
    // the register targets; 2 = the m68k C ABI (and keeps multi-byte fields
    // off odd addresses, where a 68000 takes an address error); 1 = the
    // xt6502's tightly packed layout, unchanged. `:packed` structs ignore
    // the cap entirely.
    NSUInteger alignCap = 1; // xt6502
    if (arm64 || _options.useX86_64Backend || _options.useWin64Backend || _options.useArm9Backend || _options.useWasm32Backend)
        alignCap = 8;
    else if (_options.useM68kBackend || _options.m68kPlatform)
        alignCap = 2;
    [XTStructType setFieldAlignmentCap:alignCap];
    // `float` is 4-byte IEEE single on every target. Native backends have a
    // hardware FPU; xt6502 reaches IEEE through the MECH math coprocessor
    // (private:docs/Design/mech-offload-xt6502.md), so the bespoke 5-byte softfloat is
    // retired. The layout must match the backend or the opt passes fold struct
    // offsets the backend then disagrees with (the type-width invariant).
    BOOL ieeeFloat = YES;
    [XTType setFloatWidth:ieeeFloat ? 4 : 5];
    [XTType setFloatIsIEEE:ieeeFloat];

    // Read each library's self-description (.dynsym ∩ DWARF) and bring its
    // types + function prototypes into scope, so the user's source type-
    // checks against the actual library binary. See library-imports.md.
    // Split metadata imports: an xtc library carries a `.xtc.iface` section
    // (binary xtc module, B1); a C library carries only DWARF. xtc libs are
    // reconstructed from their interface; C libs go through the DWARF reader.
    NSMutableArray<NSString*>* cLibPaths = [NSMutableArray array];
    NSMutableArray<NSString*>* xtcLibPaths = [NSMutableArray array];
    NSMutableArray<NSString*>* xtcLibJsons = [NSMutableArray array];
    NSMutableArray<NSString*>* cImportNames = [NSMutableArray array]; // for --emit-lib
    // C libraries the user #imported EXPLICITLY (e.g. a Win32 system import lib
    // like libuser32.a). They have no introspectable interface, so the
    // --as-needed "referenced?" test below can't see their symbols — link them
    // unconditionally, because the user asked for them by name.
    NSMutableArray<NSString*>* explicitCLibs = [NSMutableArray array];
    // The win64 system import libs (mingw sysroot: libuser32.a, …) come in via the
    // ambient Platform.xc, so they are AMBIENT — every win64 program already has
    // them. A --emit-lib DLL must NOT record them as C-library dependencies its
    // clients must re-resolve (the client's own Platform.xc provides them).
    NSString* win64SysLibDir = nil;
    if (_options.useWin64Backend)
        {
        const char* tc = getenv("XTC_WIN64_TOOLCHAIN");
        win64SysLibDir = [(tc ? @(tc) : @"/opt/clang/win64")
            stringByAppendingPathComponent:@"x86_64-w64-mingw32/lib"];
        }
    for (NSString* p in pp.metadataImports)
        {
        NSString* json = [XTInterfaceImporter interfaceJSONFromLibrary:p];
        // Interface format-version gate: one 3p tree serves every installed
        // compiler, so an interface serialised by a NEWER xcc is refused with
        // a diagnosis instead of misparsing. Absent field = pre-versioning
        // library, read as v1.
        if (json.length)
            {
            NSDictionary* hdr = [NSJSONSerialization
                JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                           options:0
                             error:NULL];
            NSInteger v = [hdr[@"ifaceVersion"] integerValue]; // absent -> 0
            if (v > 1)
                {
                [_diagnostics emitError:[NSString stringWithFormat:
                                                      @"'%@' carries interface format v%ld, serialised by a newer "
                                                      @"xcc than this one (reads <= v1) — upgrade the compiler or "
                                                      @"rebuild the library with this one",
                                                      p.lastPathComponent, (long)v]
                                     at:[XTSourceLocation locationWithFilename:@"<import>" line:0 column:0]];
                continue;
                }
            }
        if (json.length)
            {
            [xtcLibPaths addObject:p];
            [xtcLibJsons addObject:json];
            }
        else
            {
            [cLibPaths addObject:p];
            [explicitCLibs addObject:p];
            BOOL ambient = win64SysLibDir &&
                           [[p stringByStandardizingPath] hasPrefix:[win64SysLibDir stringByStandardizingPath]];
            if (!ambient)
                [cImportNames addObject:cLibraryNameFromPath(p)];
            }
        }
    // An imported xtc library tells us which C libraries ITS types come from, and we
    // re-import the same .so through the same DWARF reader. A REFERENCE, not a copy:
    // a binding library exposes a C library's types (Xtg: "a view IS a GEM object",
    // so objects() returns OBJECT@), and those types are not the binding library's to
    // describe. Re-serialising OBJECT would let two libraries silently disagree about
    // its layout after an aes.h change — and a layout disagreement across a .so is the
    // worst failure this project has: nothing type-checks it, nothing reports it.
    for (NSString* json in xtcLibJsons)
        {
        for (NSString* nm in [XTInterfaceImporter cImportsFromJSON:json])
            {
            NSString* path = [self resolveCLibraryNamed:nm];
            if (!path)
                {
                [_diagnostics emitError:[NSString stringWithFormat:
                                                      @"imported library needs C library '%@' for its types, but "
                                                      @"lib%@.so is not on the library search path — add -L",
                                                      nm, nm]
                                     at:[XTSourceLocation locationWithFilename:@"<import>" line:0 column:0]];
                continue;
                }
            if (![cLibPaths containsObject:path])
                [cLibPaths addObject:path];
            }
        }
    // Native-by-default: a target with a real libc (the arm9 loader) ALWAYS has it
    // available — auto-import libc so source needs no `#import <c>` and stays
    // portable. It enters as the LOWEST-precedence layer (any user/imported-lib
    // declaration of the same name shadows it; see program:withImportedFunctions:).
    // The 6502 has no libc.so and is unaffected.
    if (_options.useArm9Backend)
        {
        NSString* libc = [self resolveLibcLibrary];
        if (libc && ![cLibPaths containsObject:libc])
            [cLibPaths addObject:libc];
        // No libc.so on the search path is almost always a missing -L, and the
        // symptom is baffling: the auto-import silently finds nothing, and the
        // first error the user sees is `Call to undeclared function 'snprintf'`
        // pointing INTO support/arm9/lib/Stdio.xc — a file they did not write and
        // that is not wrong. Say what actually happened instead. A warning, not an
        // error: a freestanding arm9 program that touches no C function still links.
        if (!libc)
            {
            fprintf(stderr, "xcc: warning: arm9: no libc.so found on the library "
                            "search path — C functions (snprintf, calloc, write, …) "
                            "will not resolve, and the standard library will fail to "
                            "compile. Pass -L <loader build dir> or set "
                            "XTC_ARM9_SYSROOT.\n");
            }
        }
    NSArray<XTDwarfInterface*>* importedLibs = [self readMetadataImports:cLibPaths];

    // ── Parse ────────────────────────────────────────────────────────────
    XTTypeTable* tt = [[XTTypeTable alloc] init];
    [self injectImportedTypes:importedLibs intoTypeTable:tt];
        // Register the unit's forward type declarations BEFORE the xtc interface
        // import: an imported interface legitimately names ambient types now
        // (String — the platform-prelude surface, task #36), and resolving those
        // to the SAME placeholder objects the parse later fills keeps type
        // identity — and the layout numbering downstream — identical to a
        // source-only compile. Idempotent: the real parse's own prescan skips
        // names already registered. (After the C metadata injection, so the C
        // import keeps its established registration order.)
        {
        XTParser* prescan = [[XTParser alloc] initWithTokens:tokens
                                                   typeTable:tt
                                                 diagnostics:_diagnostics];
        [prescan prescanForwardTypeDeclarations];
        }
    // Reconstruct each imported xtc module's declarations (classes/protocols/
    // enums) into the type table; collect the decl nodes to prepend after parse.
    NSMutableArray<XTASTNode*>* importedXtcDecls = [NSMutableArray array];
    NSMutableDictionary* impProtoSlots = [NSMutableDictionary dictionary];
    NSMutableDictionary* impMethodSlots = [NSMutableDictionary dictionary];
    for (NSUInteger li = 0; li < xtcLibJsons.count; li++)
        {
        NSString* json = xtcLibJsons[li];
        NSArray<XTASTNode*>* libDecls =
            [XTInterfaceImporter declarationsFromJSON:json
                                        intoTypeTable:tt];
        // wasm32 multi-module (W2): a library symbol resolves as a wasm
        // import in the LIBRARY's package (`libX.wasm` → package "X"), so
        // the loader can wire each call to that library's exports. Stamp
        // the package on every reconstructed function/class — it rides into
        // the IR as pkg_<X> attributes (§6's plumbing, reused verbatim).
        if (_options.useWasm32Backend)
            {
            NSString* stem = xtcLibPaths[li].lastPathComponent; // libX.wasm
            if ([stem hasPrefix:@"lib"])
                stem = [stem substringFromIndex:3];
            stem = stem.stringByDeletingPathExtension;
            for (XTASTNode* d in libDecls)
                {
                if ([d isKindOfClass:[XTFunctionDeclNode class]])
                    ((XTFunctionDeclNode*)d).importPackage = stem;
                else if ([d isKindOfClass:[XTClassDeclNode class]])
                    ((XTClassDeclNode*)d).importPackage = stem;
                }
            }
        [importedXtcDecls addObjectsFromArray:libDecls];
        // The library's vtable numbering, which we must adopt rather than re-derive.
        NSDictionary* sl = [XTInterfaceImporter slotsFromJSON:json];
        [impMethodSlots addEntriesFromDictionary:(sl[@"methodSlots"] ?: @{})];
        // AMBIENT slots: the numbers a library assumed for the prelude
        // classes. Under shared-everything wasm the app and the library each
        // emit their own `String$vtbl` and each dispatches on objects the
        // other created, so the layouts have to agree and the library's is
        // already fixed (bug 091). Every other target has the same problem one
        // step removed: a client class that derives from Object is laid out by
        // the client, and a library's `a.equals(b)` on an `Object*` reads the
        // library's slot for Object.equals out of it (bug 266). A library
        // numbers the prelude per class, from each class's ancestry alone, so
        // two libraries agree and a client program adopts the numbers. A
        // library build numbers them the same way itself and does not need to.
        BOOL clientProgram = !(_options.emitLib || _options.compileOnly) &&
                             (_options.useArm64Backend || _options.useX86_64Backend || _options.useArm9Backend);
        if (_options.useWasm32Backend || clientProgram)
            {
            NSDictionary* amb = sl[@"ambientSlots"] ?: @{};
            for (NSString* l in amb)
                {
                NSNumber* prev = impMethodSlots[l];
                // Two libraries that assumed different layouts for the same
                // ambient class cannot both be satisfied; choosing one quietly
                // reproduces 091 for the other. Say so at build time.
                if (prev && ![prev isEqualToNumber:amb[l]])
                    {
                    [_diagnostics emitError:[NSString stringWithFormat:
                                                          @"imported libraries disagree about the vtable slot of "
                                                          @"'%@' (%@ vs %@); they were built against different "
                                                          @"ambient layouts and cannot be linked together",
                                                          l, prev, amb[l]]
                                         at:nil];
                    continue;
                    }
                impMethodSlots[l] = amb[l];
                }
            }
        for (NSString* pn in (sl[@"protocolSlots"] ?: @{}))
            impProtoSlots[pn] = sl[@"protocolSlots"][pn];
        }
    XTParser* parser = [[XTParser alloc] initWithTokens:tokens
                                              typeTable:tt
                                            diagnostics:_diagnostics];
    parser.defaultPointerPlacement = arm64
                                         ? XTPointerPlacementMain
                                         : XTPointerPlacementHeap;
    XTProgramNode* ast = nil;
    ast = [parser parse];
    if (!ast || _diagnostics.hasFatalError)
        {
        [_diagnostics printAll];
        return nil;
        }

    // Prepend imported function prototypes (body == nil → external symbols
    // the backend emits as `bl <cname>` and the dynamic linker resolves).
    // Only protos for symbols actually NAMED in the source are injected — a
    // library exports hundreds of functions, but the program references a
    // handful; pulling in only the referenced ones keeps the IR lean (the
    // same selectivity a linker applies). The token identifier set is a safe
    // over-approximation of "referenced symbols".
    NSMutableSet<NSString*>* usedNames = [NSMutableSet set];
    for (XTToken* t in tokens)
        {
        if (t.type == XTTokenIdentifier && t.value.length)
            [usedNames addObject:t.value];
        }
    ast = [self program:ast withImportedFunctions:importedLibs usedNames:usedNames];
    ast = [self program:ast withImportedEnumConstants:importedLibs];

    // Prepend the reconstructed xtc-library declarations so sema sees the imported
    // classes/protocols/enums (their method bodies are nil — external, in the .so).
    if (importedXtcDecls.count > 0)
        {
        // A library compiles its own imports IN, so its interface can describe
        // the very declarations the client ALSO imports by source: the metadata
        // proto for Stdio's `_putc` meeting the source definition of `_putc`.
        // Same symbol, same types, and the .so satisfies the proto at load —
        // the one collision that is guaranteed benign, and it fired as
        // "Redefinition of '_putc' with same parameter types" on the first
        // out-of-tree library client (XG bug 024). Merge it the way a C
        // prototype meets its definition: the LOCAL declaration wins and the
        // imported proto is dropped. Matched by full parameter signature for
        // functions — a mismatched pair stays, and overloads exactly as two
        // source declarations would. Enums merge by NAME (their members are
        // compile-time constants; a local re-parse of the same source is the
        // same constants), or sema's "Duplicate enum name" fires on the same
        // benign shape. Classes already merge by construction: classesByName
        // is written in declaration order, so the local class, parsed after
        // these prepended imports, wins.
        NSMutableSet<NSString*>* localFnSigs = [NSMutableSet set];
        NSMutableSet<NSString*>* localEnums = [NSMutableSet set];
        for (XTASTNode* d in ast.declarations)
            {
            if ([d isKindOfClass:[XTFunctionDeclNode class]])
                {
                XTFunctionDeclNode* fn = (XTFunctionDeclNode*)d;
                NSMutableArray<NSString*>* ps = [NSMutableArray array];
                for (XTParamNode* p in fn.parameters)
                    [ps addObject:p.paramType.displayName ?: @""];
                [localFnSigs addObject:[NSString stringWithFormat:@"%@(%@)",
                                                                  fn.funcName, [ps componentsJoinedByString:@","]]];
                }
            else if ([d isKindOfClass:[XTEnumDeclNode class]])
                {
                [localEnums addObject:((XTEnumDeclNode*)d).enumName];
                }
            }
        NSMutableArray<XTASTNode*>* keptImports = [NSMutableArray array];
        for (XTASTNode* d in importedXtcDecls)
            {
            if ([d isKindOfClass:[XTFunctionDeclNode class]])
                {
                XTFunctionDeclNode* fn = (XTFunctionDeclNode*)d;
                NSMutableArray<NSString*>* ps = [NSMutableArray array];
                for (XTParamNode* p in fn.parameters)
                    [ps addObject:p.paramType.displayName ?: @""];
                NSString* sig = [NSString stringWithFormat:@"%@(%@)",
                                                           fn.funcName, [ps componentsJoinedByString:@","]];
                if ([localFnSigs containsObject:sig])
                    continue;
                }
            else if ([d isKindOfClass:[XTEnumDeclNode class]] && [localEnums containsObject:((XTEnumDeclNode*)d).enumName])
                {
                continue;
                }
            [keptImports addObject:d];
            }
        importedXtcDecls = keptImports;
        }
    if (importedXtcDecls.count > 0)
        {
        // Guard: a client must not re-declare a protocol it imports. The itable
        // slots come from the ONE exported declaration (the library's numbering,
        // adopted above), so a local copy would silently drift them — the exact
        // failure the XG-NIB slot-consistency rule exists to prevent. Refuse a
        // local protocol whose name an imported library already declares.
        NSMutableSet<NSString*>* importedProtos = [NSMutableSet set];
        for (XTASTNode* d in importedXtcDecls)
            if ([d isKindOfClass:[XTProtocolDeclNode class]])
                [importedProtos addObject:((XTProtocolDeclNode*)d).protocolName];
        NSMutableArray<XTASTNode*>* localDecls = [NSMutableArray array];
        for (XTASTNode* d in ast.declarations)
            {
            if ([d isKindOfClass:[XTProtocolDeclNode class]] &&
                [importedProtos containsObject:((XTProtocolDeclNode*)d).protocolName])
                {
                [_diagnostics emitError:[NSString stringWithFormat:
                                                      @"'%@' redeclares an imported protocol; import it instead of re-declaring "
                                                      @"it (a local copy would drift its itable slots)",
                                                      ((XTProtocolDeclNode*)d).protocolName]
                                     at:d.location];
                continue; // drop the local copy; keep the imported one
                }
            [localDecls addObject:d];
            }
        NSMutableArray<XTASTNode*>* merged = [importedXtcDecls mutableCopy];
        [merged addObjectsFromArray:localDecls];
        ast = [[XTProgramNode alloc] initWithDeclarations:merged location:ast.location];
        if (_diagnostics.errorCount > 0)
            {
            [_diagnostics printAll];
            return nil;
            }
        }

    // XG-NIB (2): a class with any `outlet` field or `:action` method auto-conforms
    // to the binding protocol — synthesise setOutlet/wireAction, a per-module
    // factory, and the mod-init that registers it. Runs before sema so the
    // synthesised methods are what conformance checking sees.
    // `:packed` strict-alignment warning (blewit item 3 follow-up). A packed
    // struct declares BYTE-COMPATIBILITY intent, and a multi-byte field at an
    // offset that is not a multiple of its width is exactly what a
    // strict-alignment target faults on when the field is accessed whole:
    // the 68000 traps on any odd word/long access, and ARMv7's LDRD/STRD
    // pairs fault below 4-byte alignment however tolerant plain LDR/STR are.
    // A WARNING, not an error — "packed as much as you can" stays the rule,
    // the layout is emitted as declared, and -Wno-packed-align silences it.
    if (_options.useArm9Backend || _options.m68kPlatform)
        {
        NSString* tgt = _options.useArm9Backend ? @"arm9" : @"m68k";
        for (XTASTNode* d in ast.declarations)
            {
            XTStructDeclNode* sd = nil;
            NSString* tyName = nil;
            if ([d isKindOfClass:[XTStructDeclNode class]])
                {
                sd = (XTStructDeclNode*)d;
                tyName = sd.structName;
                }
            else if ([d isKindOfClass:[XTTypedefNode class]])
                {
                sd = ((XTTypedefNode*)d).structDecl;
                tyName = ((XTTypedefNode*)d).aliasName;
                }
            if (!sd || !sd.isPacked || !tyName.length)
                continue;
            XTType* ty = [tt typeForName:tyName];
            if (![ty isKindOfClass:[XTStructType class]])
                continue;
            for (XTStructField* f in ((XTStructType*)ty).fields)
                {
                NSUInteger w = f.fieldType.byteWidth;
                BOOL pow2 = w && ((w & (w - 1)) == 0);
                if (w > 1 && pow2 && (f.byteOffset % w) != 0)
                    {
                    [_diagnostics emitWarning:[NSString stringWithFormat:
                                                            @"':packed' struct '%@' places '%@' (%lu bytes) at offset %lu, "
                                                            @"which %@ may fault on when accessed whole — reorder or pad "
                                                            @"the fields, or pass -Wno-packed-align",
                                                            tyName, f.fieldName, (unsigned long)w,
                                                            (unsigned long)f.byteOffset, tgt]
                                     category:XTWarnPackedAlign
                                           at:sd.location];
                    }
                }
            }
        }

    ast = [XTDesignableSynthesis run:ast
                           typeTable:tt
                               arm64:arm64
                         diagnostics:_diagnostics];
    if (_diagnostics.errorCount > 0)
        {
        [_diagnostics printAll];
        return nil;
        }

    // #9: on a backend that carries the conformance itable, provide the runtime
    // helper the `(P@ ?)obj` downcast lowers to. Injected before sema so it is
    // analysed like user code; dead-function-elim drops it when unused. (Gated on
    // _options — the XTIRLowering flags are set later, at sema setup.)
    if (_options.useArm64Backend || _options.useX86_64Backend || _options.useWin64Backend || _options.useArm9Backend || _options.useWasm32Backend)
        {
        ast = [self injectConformanceHelper:ast typeTable:tt arm64:arm64];
        if (_diagnostics.errorCount > 0)
            {
            [_diagnostics printAll];
            return nil;
            }
        }

    // Record which libraries are actually needed at link time: a library is
    // DT_NEEDED only if the source references at least one of its symbols
    // (matching --as-needed). The dispatcher links these .so paths so the ELF
    // records DT_NEEDED from each DT_SONAME.
    NSMutableArray<NSString*>* needed = [NSMutableArray array];
    for (XTDwarfInterface* iface in importedLibs)
        {
        if (iface.sourcePath.length == 0)
            continue;
        BOOL referenced = NO;
        for (XTDwarfFunction* fn in iface.functions)
            {
            if ([usedNames containsObject:fn.name])
                {
                referenced = YES;
                break;
                }
            }
        if (referenced && ![needed containsObject:iface.sourcePath])
            [needed addObject:iface.sourcePath];
        }
    // Explicitly #imported C libraries (system import libs with no interface) are
    // always linked — the user named them and declared their functions by hand.
    for (NSString* p in explicitCLibs)
        if (![needed containsObject:p])
            [needed addObject:p];
    // An imported xtc library is always DT_NEEDED — the app #imported it to use
    // its classes, and its method bodies resolve against the .so.
    [needed addObjectsFromArray:xtcLibPaths];
    _neededLibraryPaths = [needed copy];

    // ── Semantic analysis ───────────────────────────────────────────────
    // Any type an imported interface NAMED but that we could not resolve is a hard
    // error. Printing to stderr and carrying on emits a program built on a type we
    // silently replaced with `void` — the very habit these fixes exist to kill.
    for (NSString* bad in [XTInterfaceImporter drainUnresolvedTypeNames])
        {
        // A name THIS unit declares is not unresolved — the parse binds it and
        // the metadata/source merge (#1077) reconciles the records. With the
        // ambient platform surface (task #36) this is the NORM: every module's
        // interface legitimately names String in a signature, and every
        // consumer's prelude declares it. Only a name the unit never declares
        // stays what this error exists for: a type silently about to become
        // void.
        NSString* asClass = [NSString stringWithFormat:@"class %@", bad];
        NSString* asProto = [NSString stringWithFormat:@"protocol %@", bad];
        BOOL declaredHere = NO;
        for (NSString* probe in @[ asClass, asProto ])
            {
            NSRange r = [expanded rangeOfString:probe];
            while (r.location != NSNotFound)
                {
                NSUInteger after = r.location + r.length;
                unichar c = after < expanded.length ? [expanded characterAtIndex:after] : ' ';
                if (!isalnum(c) && c != '_' && c != '$')
                    {
                    declaredHere = YES;
                    break;
                    }
                r = [expanded rangeOfString:probe
                                    options:0
                                      range:NSMakeRange(after, expanded.length - after)];
                }
            if (declaredHere)
                break;
            }
        if (declaredHere)
            continue;
        [_diagnostics emitError:[NSString stringWithFormat:
                                              @"imported library names the type '%@', which could not be resolved. If it "
                                              @"is a C type, the library that defines it must be on the search path (-L); "
                                              @"if it is an xtc type, rebuild the library that exports it.",
                                              bad]
                             at:[XTSourceLocation locationWithFilename:@"<import>" line:0 column:0]];
        }
    if (_diagnostics.hasFatalError)
        {
        [_diagnostics printAll];
        return nil;
        }

    XTSemanticAnalyzer* sema = [[XTSemanticAnalyzer alloc]
        initWithTypeTable:tt
              diagnostics:_diagnostics];
    sema.allocator = _options.allocator;
    sema.heapBank = arm64 ? 0 : 1;
    // Whole-program devirtualisation is unsound when the program isn't whole,
    // and a `-c` object is no more whole than a `.so`. Compiled as a whole
    // program, a class nothing here overrides gets no vtable at all — and then a
    // client that DOES override it references a `<Class>$vtbl` that exists
    // nowhere, so the program dies at LOAD with "Symbol not found", not at link.
    //
    // The cost is bigger objects: every instance method earns a slot whether or
    // not this translation unit can see an override. That is what correctness
    // costs, and it is the same trade `--emit-lib` already makes.
    sema.libraryBuild = _options.emitLib || _options.compileOnly;
    // NOT the same question. `emittingLibrary` asks "is this compilation THE
    // library?", which a `-c` object is not — it is still part of a final link,
    // and is allowed to extend an imported class (separate-compilation §4.2)
    // where a library is refused. The two were split apart for this.
    sema.emittingLibrary = _options.emitLib;
    // arm9 is the only target that can be linked as multiple modules, and it is the
    // only one where a program-global protocol slot number is unachievable.
    // arm9 AND x86_64 (bug 201): both can link as several independently
    // compiled modules (x86_64 via -c separate compilation), where a
    // program-global protocol slot number is unachievable — dispatch goes
    // through the itable and protocol numbering is not adopted.
    //
    // Bug 266: the same holds for every module that meets another one. On arm64
    // (and iOS and Android), x86_64 and wasm32 a library build, a `-c` object
    // and a program that imports an xtc library each number the protocols they
    // see themselves, and nothing can make the numbers agree for a protocol the
    // library does not declare: a library's `h.hash()` on a client's
    // `Hashable*` read its slot 92 out of a 19-entry client vtable. The itable
    // key (the protocol's name-derived id and the method's declaration index)
    // is derived alike everywhere, so no numbering has to cross the interface.
    // win64 links no libraries yet, so it keeps the slot.
    BOOL multiModule = sema.libraryBuild || xtcLibJsons.count > 0;
    BOOL itableDispatch = _options.useArm9Backend ||
                          ((_options.useArm64Backend || _options.useX86_64Backend || _options.useWasm32Backend) && multiModule);
    sema.itableProtocols = itableDispatch;
    // Native AAPCS varargs — a variadic's args ride the C ABI (arm9: regs+stack;
    // arm64: all on the stack, Apple's rule), NOT the $04B0 pack buffer. Unifying
    // arm64 onto it (bug 179) lets a cross-unit xc variadic and a C native share
    // one ABI, so a bodyless `...` prototype reaches EITHER — fixing the
    // cross-unit variadic call that arrived empty (c2xc 33).
    sema.nativeVarargs = _options.useArm9Backend || _options.useArm64Backend;
    [XTIRLowering setItableProtocols:itableDispatch];
    // The race-free static-init once rides the SAME switch as atomic ARC: both
    // answer "can two threads touch this at once?", so -f[no-]thread-safe-arc
    // forces both together and neither can be turned on without the other. The
    // default (-1) leaves lowering to decide per module — on exactly when the
    // program declares the thread-spawn primitive (threading.md §9.5).
    [XTIRLowering setThreadSafeStatics:(int)_options.threadSafeARC];
    // --migrate=<base>:<to> — sema hides members newer than <base>.
    if (_options.migrateVersions.length)
        {
        NSString* base = [_options.migrateVersions
                             componentsSeparatedByString:@":"]
                             .firstObject;
        [XTSemanticAnalyzer setMigrateBaseVersion:base];
        // ...and exempt the support tree from it (uxkit/025).
        [XTSemanticAnalyzer setMigrateSupportRoot:[self resolveSupportRoot]];
        }
    else
        {
        [XTSemanticAnalyzer setMigrateBaseVersion:nil];
        [XTSemanticAnalyzer setMigrateSupportRoot:nil];
        }
    // Conformance itable on the flat cross-`.so` backends: they dispatch through
    // flat vtable slots (not itables), but a runtime `(P@ ?)obj` conformance
    // downcast still needs the protocol-id list — reachable, cross-module, via the
    // shared vtable. arm9 already carries the full itable; xt6502/m68k keep the
    // compile-time conforming-set (they reject the runtime downcast).
    BOOL vtConforms = (_options.useArm64Backend || _options.useX86_64Backend || _options.useWin64Backend || _options.useWasm32Backend);
    [XTIRLowering setVtableConforms:vtConforms];
    sema.vtableConforms = vtConforms;
    // Runtime-ancestry vtables (a parent link at entry 0 + the walking downcast) are
    // for the backends that link separate shared objects and so must recognise a
    // subclass defined in another module. xt6502 (banked 3-byte pointers) and m68k do
    // not — they keep the parent-free vtable and the compile-time-subtree downcast.
    [XTIRLowering setVtableAncestry:(_options.useArm9Backend || _options.useArm64Backend || _options.useX86_64Backend || _options.useWin64Backend || _options.useWasm32Backend)];
    sema.importedProtocolSlots = impProtoSlots.count ? impProtoSlots : nil;
    sema.importedMethodSlots = impMethodSlots.count ? impMethodSlots : nil;
    [sema analyzeProgram:ast];
    if (_diagnostics.hasFatalError)
        {
        [_diagnostics printAll];
        return nil;
        }

    // ── IR lowering ──────────────────────────────────────────────────────
    NSString* modName = [inputFile.lastPathComponent stringByDeletingPathExtension];
    XTIRModule* mod = nil;
    mod = [XTIRLowering lowerProgram:ast
                          moduleName:modName
                         diagnostics:_diagnostics
                       nativeVarargs:(_options.useArm9Backend || _options.useArm64Backend)
                         boundsCheck:(_options.boundsCheck)];
    if (!mod || _diagnostics.hasFatalError)
        {
        [_diagnostics printAll];
        fprintf(stderr, "xcc: IR lowering failed\n");
        return nil;
        }

    // ── Verify ──────────────────────────────────────────────────────────
    NSArray<NSString*>* vErrs = nil;
    BOOL ok = NO;
    ok = [XTIRVerifier verifyModule:mod errors:&vErrs];
    if (!ok)
        {
        fprintf(stderr, "xcc: IR verifier rejected module:\n");
        for (NSString* e in vErrs)
            fprintf(stderr, "  %s\n", e.UTF8String);
        return nil;
        }

    // Flush accumulated non-fatal diagnostics (warnings / notes) on the
    // success path. The error returns above already print before bailing;
    // without this final flush a clean-but-warned compile silently dropped
    // every warning on the new-IR frontend — including the printf
    // format-specifier checks (e.g. `%d` given an i32) that the legacy
    // driver surfaces via its end-of-run printAll.
    [_diagnostics printAll];

    _analyzedProgram = ast; // expose for --emit-lib interface serialisation
    _cLibraryImports = cImportNames;
    _protocolSlots = sema.protocolMethodSlotsForExport;
    _virtualMethodSlots = sema.virtualSlotByLabel;
    return mod;
    }
@end
