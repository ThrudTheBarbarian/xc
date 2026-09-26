#import "XTCommandLineOptions.h"
#import "XTDiagnosticEngine.h"
#import "XTLinkerScriptParser.h"

// Set by the build (-DXTC_VERSION); the guard keeps this file compilable
// on its own, e.g. in an editor index or a one-off syntax check.
#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

@interface XTCommandLineOptions ()
@property(nonatomic, readwrite) NSMutableArray<NSString*>* mutableInputFiles;
@property(nonatomic, readwrite) NSMutableArray<NSString*>* mutableIncludePaths;
@property(nonatomic, readwrite) NSMutableArray<NSString*>* mutableLibraryPaths;
@property(nonatomic, readwrite) NSMutableArray<NSString*>* mutableLinkerArgs;
@property(nonatomic, readwrite) NSString* targetName;
@property(nonatomic, readwrite) XTMemoryModel* memoryModel;
@property(nonatomic, readwrite, nullable) NSString* outputPath;
@property(nonatomic, readwrite) NSMutableDictionary<NSString*, NSString*>* mutableDefines;
@property(nonatomic, readwrite) NSInteger optimisationLevel;
@property(nonatomic, readwrite) BOOL useXtcStack;
@property(nonatomic, readwrite, nullable) NSString* preprocessedOutputPath;
@property(nonatomic, readwrite) BOOL quiet;
@property(nonatomic, readwrite) BOOL emitLib;
@property(nonatomic, readwrite) BOOL emitIface;
@property(nonatomic, readwrite, nullable) NSString* withLib;
@property(nonatomic, readwrite, nullable) NSString* libName;
@property(nonatomic, readwrite) NSArray<NSString*>* neededSonames;
@property(nonatomic, readwrite) BOOL emitApk;
@property(nonatomic, readwrite, copy, nullable) NSString* withDex;
@property(nonatomic, readwrite) BOOL selfHost;
@property(nonatomic, readwrite) BOOL noSelfHost;
@property(nonatomic, readwrite) BOOL verbose;
@property(nonatomic, readwrite, nullable) NSString* xtcHome;
@property(nonatomic, readwrite) NSUInteger maxLeafInlineSize;
@property(nonatomic, readwrite) NSUInteger loopUnrollMax;
@property(nonatomic, readwrite) BOOL loopUnrollMaxExplicit;
@property(nonatomic, readwrite) NSUInteger fnMinBanked;
@property(nonatomic, readwrite) BOOL assembleOnly;
@property(nonatomic, readwrite) BOOL compileOnly;
@property(nonatomic, readwrite) BOOL lto;
@property(nonatomic, readwrite) BOOL dumpLayout;
@property(nonatomic, readwrite) BOOL dumpPlacement;
@property(nonatomic, readwrite) BOOL dumpUsage;
@property(nonatomic, readwrite) NSString* autoCloakMode;
@property(nonatomic, readwrite) BOOL quitLoop;
@property(nonatomic, readwrite) NSString* allocator;
@property(nonatomic, readwrite) NSString* hostMalloc;
@property(nonatomic, readwrite) BOOL allocatorExplicit;
@property(nonatomic, readwrite) BOOL dceTrace;
@property(nonatomic, readwrite) NSInteger threadSafeARC;
@property(nonatomic, readwrite, nullable) NSString* migrateVersions;
@property(nonatomic, readwrite) BOOL emitIR;
@property(nonatomic, readwrite) BOOL emitIROpt;
@property(nonatomic, readwrite) BOOL emitAsmFromIR;
@property(nonatomic, readwrite) NSUInteger stackSize;
@property(nonatomic, readwrite) NSMutableArray<NSString*>* mutableSuppressedWarnings;
@property(nonatomic, readwrite) NSMutableDictionary<NSString*, NSMutableArray<NSString*>*>* mutableTargetOptions;
@property(nonatomic, readwrite) BOOL useNewIR;
@property(nonatomic, readwrite) BOOL useArm64Backend;
@property(nonatomic, readwrite) BOOL useArm9Backend;
@property(nonatomic, readwrite) BOOL useX86_64Backend;
@property(nonatomic, readwrite) BOOL useWin64Backend;
@property(nonatomic, readwrite, nullable) NSString* applePlatform;
@property(nonatomic, readwrite, nullable) NSString* signIdentityPath;
@property(nonatomic, readwrite, nullable) NSString* signEntitlementsPath;
@property(nonatomic, readwrite) BOOL useWasm32Backend;
@property(nonatomic, readwrite) BOOL useM68kBackend;
@property(nonatomic, readwrite) NSInteger m68kCpu;
@property(nonatomic, readwrite) BOOL m68kHardFloat;
@property(nonatomic, readwrite) BOOL m68kPic;
@property(nonatomic, readwrite) BOOL m68kPlatform;
@end

@implementation XTCommandLineOptions

/****************************************************************************\
|* Initialise with default option values (xl target, no output path, etc.).
|* @return  A default-configured options instance.
\****************************************************************************/
- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _mutableInputFiles = [NSMutableArray array];
        _mutableIncludePaths = [NSMutableArray array];
        _mutableLibraryPaths = [NSMutableArray array];
        _mutableLinkerArgs = [NSMutableArray array];
        _targetName = @"xl";
        _memoryModel = [XTMemoryModel defaultModel];
        _outputPath = nil;
        _mutableDefines = [NSMutableDictionary dictionary];
        _mutableSuppressedWarnings = [NSMutableArray array];
        _mutableTargetOptions = [NSMutableDictionary dictionary];
        _maxLeafInlineSize = 100;
        // Default 0 = threshold disabled. The 100-instruction value
        // suggested in the design discussion is too aggressive a
        // default — programs heavy on small banked functions
        // (struct_byval-style fixtures, heap ARC fixtures) overflow
        // their 8 KB main code region when every sub-100-insn fn
        // gets demoted at once. Users opt in per program with
        // `-Fmb <n>`; future work can raise the default once smart
        // overflow-aware demotion is in place.
        _fnMinBanked = 0;
        _allocator = @"bump";
        _hostMalloc = @"system";
        _allocatorExplicit = NO;
        _autoCloakMode = @"auto";
        _optimisationLevel = 3; // -O3 default (space-constrained 6502)
        }
    return self;
    }

/****************************************************************************\
|* Return an immutable copy of the input file list.
|* @return  An array of input file path strings.
\****************************************************************************/
- (NSArray<NSString*>*)inputFiles
    {
    return [_mutableInputFiles copy];
    }
/****************************************************************************\
|* Return an immutable copy of the include search paths.
|* @return  An array of directory path strings.
\****************************************************************************/
- (NSArray<NSString*>*)includePaths
    {
    return [_mutableIncludePaths copy];
    }
- (NSArray<NSString*>*)libraryPaths
    {
    return [_mutableLibraryPaths copy];
    }
@synthesize explicitLibraryPathCount = _explicitLibraryPathCount;
- (void)addLibraryPath:(NSString*)dir
    {
    if (dir.length && ![_mutableLibraryPaths containsObject:dir])
        [_mutableLibraryPaths addObject:dir];
    }
- (NSArray<NSString*>*)linkerArgs
    {
    return [_mutableLinkerArgs copy];
    }
/****************************************************************************\
|* Return an immutable copy of the preprocessor defines.
|* @return  A dictionary mapping define names to their values.
\****************************************************************************/
- (NSDictionary<NSString*, NSString*>*)defines
    {
    return [_mutableDefines copy];
    }
/****************************************************************************\
|* Return an immutable copy of the suppressed warning category names.
|* @return  An array of kebab-case warning category name strings.
\****************************************************************************/
- (NSArray<NSString*>*)suppressedWarnings
    {
    return [_mutableSuppressedWarnings copy];
    }
- (NSDictionary<NSString*, NSArray<NSString*>*>*)targetOptions
    {
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    [_mutableTargetOptions enumerateKeysAndObjectsUsingBlock:^(NSString* k, NSMutableArray* v, BOOL* stop) {
      out[k] = [v copy];
    }];
    return out;
    }

// The per-arch registry of target-specific options. An arch not listed here
// accepts nothing; an unknown option is a HARD error naming the arch, so a
// typo fails the build instead of silently compiling without the feature.
static NSDictionary<NSString*, NSArray<NSString*>*>* XTTargetOptionRegistry(void)
    {
    return @{@"wasm32" : @[ @"return-call" ]};
    }

/****************************************************************************\
|* Strip surrounding double-quotes and normalise backslash path separators.
|* Windows users often write SET XTC_HOME="D:\path" which embeds the quotes
|* in the value; backslashes also break NSString path methods on GNUstep.
\****************************************************************************/
+ (nullable NSString*)sanitiseEnvPath:(nullable NSString*)raw
    {
    if (!raw.length)
        return nil;
    NSString* s = [raw stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
    if (s.length >= 2 && [s hasPrefix:@"\""] && [s hasSuffix:@"\""])
        s = [s substringWithRange:NSMakeRange(1, s.length - 2)];
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    return s.length ? s : nil;
    }

// argv[0], recorded by main so the support tree can be located relative to
// the BINARY rather than to the current directory.
static NSString* sExecutablePath = nil;

+ (void)setExecutablePath:(nullable const char*)argv0
    {
    sExecutablePath = argv0 ? [NSString stringWithUTF8String:argv0] : nil;
    }

+ (nullable NSString*)supportRootForHome:(nullable NSString*)home
    {
    if (!home.length)
        return nil;
    NSFileManager* fm = [NSFileManager defaultManager];
    // lib/xc first: an install and a source tree can both be visible at once
    // (the repo has support/, /opt has lib/xc), and the INSTALLED layout is
    // the more specific of the two, so it must not lose to a stray support/.
    for (NSString* rel in @[ @"lib/xc", @"xc", @"support" ])
        {
        BOOL isDir = NO;
        NSString* p = [home stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir)
            return p;
        }
    return nil;
    }

/****************************************************************************\
|* Resolve the xcc home. In order: -H, $XCC_HOME (then $XTC_HOME, still
|* honoured), the directory the BINARY lives in and its parent, cwd, then the
|* well-known install roots.
|*
|* The binary-relative candidates are what make an install self-locating:
|* /opt/xcc/<ver>/bin/xcc finds /opt/xcc/<ver>/lib/xc by going up one level,
|* and the Windows layout (binaries and xc/ in one directory) finds it by not
|* going up at all. Neither needs -H, a fixed path, or an environment variable.
\****************************************************************************/
+ (nullable NSString*)resolveXtcHome:(nullable NSString*)explicitHome
    {
    NSMutableArray<NSString*>* candidates = [NSMutableArray array];
    if (explicitHome)
        [candidates addObject:explicitHome];
    for (NSString* var in @[ @"XCC_HOME", @"XTC_HOME" ])
        {
        NSString* env = [XTCommandLineOptions sanitiseEnvPath:
                                                  [NSProcessInfo processInfo].environment[var]];
        if (env)
            [candidates addObject:env];
        }
    if (sExecutablePath.length)
        {
        NSString* bin = [sExecutablePath stringByDeletingLastPathComponent];
        if (bin.length)
            {
            [candidates addObject:bin];                                        // Windows: xcc.exe + xc/
            [candidates addObject:[bin stringByAppendingPathComponent:@".."]]; // bin/ -> root
            }
        }
    [candidates addObject:@"."];
    NSString* home = NSHomeDirectory();
    if (home)
        {
        [candidates addObject:[home stringByAppendingPathComponent:@"xcc"]];
        [candidates addObject:[home stringByAppendingPathComponent:@"xtc"]];
        }
    [candidates addObjectsFromArray:@[
        [@"/opt/xcc" stringByAppendingPathComponent:@XTC_VERSION],
        @"/opt/xcc", @"/usr/local/xcc",
        @"/usr/local/xtc", @"/opt/xtc"
    ]];
    for (NSString* c in candidates)
        if ([XTCommandLineOptions supportRootForHome:c])
            return c;
    return nil;
    }

+ (nullable NSString*)resolveSupportRoot:(nullable NSString*)explicitHome
    {
    return [XTCommandLineOptions supportRootForHome:
                                     [XTCommandLineOptions resolveXtcHome:explicitHome]];
    }

/****************************************************************************\
|* Scan support/<platform>/layouts/ and list available layouts grouped
|* by platform. Skips symlinks (like default.lnk).
\****************************************************************************/
+ (void)listLayouts:(nullable NSString*)xtcHome
    {
    NSString* supportDir = [XTCommandLineOptions supportRootForHome:xtcHome]
                               ?: [XTCommandLineOptions resolveSupportRoot:nil] ?
                                                                                : @"support";
    NSFileManager* fm = [NSFileManager defaultManager];
    NSArray<NSString*>* platforms = [[fm contentsOfDirectoryAtPath:supportDir error:nil]
        sortedArrayUsingSelector:@selector(compare:)];
    BOOL any = NO;
    fprintf(stderr, "Available layouts (use with -m <platform>/<layout>):\n\n");
    for (NSString* platform in platforms)
        {
        if ([platform isEqualToString:@"generic"])
            continue;
        NSString* layoutDir = [[supportDir stringByAppendingPathComponent:platform]
            stringByAppendingPathComponent:@"layouts"];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:layoutDir isDirectory:&isDir] || !isDir)
            continue;
        NSArray<NSString*>* files = [[fm contentsOfDirectoryAtPath:layoutDir error:nil]
            sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray<NSString*>* layouts = [NSMutableArray array];
        for (NSString* f in files)
            {
            if (![f.pathExtension isEqualToString:@"lnk"])
                continue;
            // Skip symlinks
            NSString* fullPath = [layoutDir stringByAppendingPathComponent:f];
            NSDictionary* attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            if ([attrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink])
                continue;
            [layouts addObject:[f stringByDeletingPathExtension]];
            }
        if (layouts.count == 0)
            continue;
        any = YES;
        fprintf(stderr, "  %s:\n", platform.UTF8String);
        for (NSString* layout in layouts)
            {
            fprintf(stderr, "    -m %s/%s\n", platform.UTF8String, layout.UTF8String);
            }
        fprintf(stderr, "\n");
        }
    if (!any)
        fprintf(stderr, "  (no layouts found in %s/)\n", supportDir.UTF8String);
    }

/****************************************************************************\
|* Try to load a .lnk file for the given -m argument. Accepts:
|*   platform/layout  (e.g. "atari/xl", "c64/base")
|*   layout           (e.g. "xl" — defaults to atari platform)
|*   direct file path (e.g. "my/custom.lnk")
|* Searches support/<platform>/layouts/<layout>.lnk under xtc home.
|* Returns nil if no .lnk file is found (caller falls back to
|* the hardcoded model path).
\****************************************************************************/
+ (nullable XTMemoryModel*)tryLoadLinkerScript:(NSString*)spec
                                       xtcHome:(nullable NSString*)xtcHome
    {
    NSFileManager* fm = [NSFileManager defaultManager];
    // (a) Direct file path.
    if ([fm fileExistsAtPath:spec])
        {
        NSError* err = nil;
        XTMemoryModel* m = [XTLinkerScriptParser parseFile:spec error:&err];
        if (!m && err)
            fprintf(stderr, "xcc: %s\n", err.localizedDescription.UTF8String);
        if (m && !m.name)
            m.name = spec;
        return m;
        }
    NSString* specLnk = [spec stringByAppendingString:@".lnk"];
    if ([fm fileExistsAtPath:specLnk])
        {
        NSError* err = nil;
        XTMemoryModel* m = [XTLinkerScriptParser parseFile:specLnk error:&err];
        if (!m && err)
            fprintf(stderr, "xcc: %s\n", err.localizedDescription.UTF8String);
        if (m && !m.name)
            m.name = spec;
        return m;
        }
    // (b) Platform-based layout under xtc home: support/<platform>/layouts/<layout>.lnk,
    // with a fallback to support/<platform>/internal/<layout>.lnk for retired
    // regression-only targets (e.g. xt-heap, kept alive for spill_overflow).
    // Internal layouts aren't surfaced by --list-layouts but stay reachable
    // via the same -m <name> form so test fixtures don't need path-form
    // workarounds.
    if (xtcHome)
        {
        // A spec may name its platform explicitly ("xt6502/xt"); otherwise we
        // search every platform dir under support/ for <layout>.lnk. This keeps
        // `-m xt`, `-m xl`, `-m c64` working without hardcoding which platform
        // each lives in (xt → support/xt6502, xl/xe → support/6502, …) and
        // generalises as more 6502 variants are added.
        NSString* layout = spec;
        NSArray<NSString*>* platforms;
        NSRange slash = [spec rangeOfString:@"/"];
        // The support ROOT — the layout tree is called lib/xc in an install and
        // support/ in the source tree, and this lookup must work in both.
        NSString* supportDir = [XTCommandLineOptions supportRootForHome:xtcHome]
                                   ?: [XTCommandLineOptions resolveSupportRoot:nil] ?
                                                                                    : @"support";
        if (slash.location != NSNotFound)
            {
            platforms = @[ [spec substringToIndex:slash.location] ];
            layout = [spec substringFromIndex:slash.location + 1];
            }
        else
            {
            platforms = [[fm contentsOfDirectoryAtPath:supportDir error:nil]
                            sortedArrayUsingSelector:@selector(compare:)]
                            ?: @[];
            }
        NSArray<NSString*>* subdirs = @[ @"layouts", @"internal" ];
        for (NSString* platform in platforms)
            {
            for (NSString* sub in subdirs)
                {
                NSString* builtIn = [[supportDir
                    stringByAppendingPathComponent:platform]
                    stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%@/%@.lnk", sub, layout]];
                if (![fm fileExistsAtPath:builtIn])
                    continue;
                NSError* err = nil;
                XTMemoryModel* m = [XTLinkerScriptParser parseFile:builtIn error:&err];
                if (!m && err)
                    fprintf(stderr, "xcc: %s\n", err.localizedDescription.UTF8String);
                if (m && !m.name)
                    m.name = layout;
                if (m && !m.platform)
                    m.platform = platform;
                return m;
                }
            }
        }
    return nil;
    }

/****************************************************************************\
|* Parse argv into options. Returns nil and prints usage on error.
|* @param argc  The argument count from main().
|* @param argv  The argument vector from main().
|* @return  A populated options instance, or nil on parse failure.
\****************************************************************************/
+ (nullable instancetype)parseArgc:(int)argc argv:(const char*[])argv
    {
    XTCommandLineOptions* opts = [[XTCommandLineOptions alloc] init];
    // Did the user actually NAME a target? `cc -o x x.c` builds for the host,
    // and xcc follows that: with neither -A nor -m, the default is this
    // machine. Historically the default was 6502, which made the simplest
    // possible command line the one that needed the most explanation.
    BOOL sawArch = NO, sawModel = NO;
    for (int k = 1; k < argc; k++)
        {
        if (!strcmp(argv[k], "-A") || !strcmp(argv[k], "--arch"))
            sawArch = YES;
        if (!strcmp(argv[k], "-m") || !strcmp(argv[k], "--memory-model"))
            sawModel = YES;
        }
    // -1 means "let the code generator decide" — see the property's comment.
    opts.threadSafeARC = -1;

    // Pre-scan for -H / --xtc-home so it's available for -m resolution
    // even if -H appears after -m on the command line. The argument
    // runs through `sanitiseEnvPath:` for the same reason XTC_HOME
    // does — Windows cmd.exe preserves the quotes when the user types
    // `-H "C:\path with spaces"`, so the value arrives as the literal
    // 5-char string `"C:\path with spaces"` (with the quotes), and
    // lookups against `<that>/support` then trip on the embedded
    // quote characters.
    for (int i = 1; i < argc - 1; i++)
        {
        NSString* a = [NSString stringWithUTF8String:argv[i]];
        if ([a isEqualToString:@"-H"] || [a isEqualToString:@"--xtc-home"])
            {
            opts.xtcHome = [XTCommandLineOptions sanitiseEnvPath:
                                                     [NSString stringWithUTF8String:argv[i + 1]]];
            break;
            }
        }
    NSString* resolvedHome = [XTCommandLineOptions resolveXtcHome:opts.xtcHome];

    // Whether the user named a target explicitly via -m. When NO (and the
    // arm64 host backend wasn't selected either) we fall back to the
    // xt6502/xt layout post-parse — that is the default 6502 target.
    BOOL explicitModel = NO;

    for (int i = 1; i < argc; i++)
        {
        NSString* arg = [NSString stringWithUTF8String:argv[i]];

        if ([arg isEqualToString:@"-I"] || [arg isEqualToString:@"--include"])
            {
            if (i + 1 < argc)
                {
                [opts.mutableIncludePaths addObject:[NSString stringWithUTF8String:argv[++i]]];
                }
            else
                {
                fprintf(stderr, "xcc: error: -I requires an argument\n");
                return nil;
                }
            }
        else if ([arg isEqualToString:@"-L"] || [arg isEqualToString:@"--library-path"])
            {
            // Shared-library metadata-import search dir (`#import <GEM>` →
            // libGEM.so read for its .dynsym ∩ DWARF). Supports both the
            // separated `-L dir` and the glued `-Ldir` forms.
            if (i + 1 < argc)
                {
                [opts.mutableLibraryPaths addObject:[NSString stringWithUTF8String:argv[++i]]];
                }
            else
                {
                fprintf(stderr, "xcc: error: -L requires an argument\n");
                return nil;
                }
            }
        else if ([arg hasPrefix:@"-L"] && arg.length > 2)
            {
            [opts.mutableLibraryPaths addObject:[arg substringFromIndex:2]];
            }
        else if ([arg isEqualToString:@"-framework"])
            {
            // Native-link passthrough: `-framework AppKit` → clang `-framework AppKit`.
            if (i + 1 < argc)
                {
                [opts.mutableLinkerArgs addObject:@"-framework"];
                [opts.mutableLinkerArgs addObject:[NSString stringWithUTF8String:argv[++i]]];
                }
            else
                {
                fprintf(stderr, "xcc: error: -framework requires an argument\n");
                return nil;
                }
            }
        else if ([arg isEqualToString:@"-Xlinker"])
            {
            // Raw arg forwarded to the linker via clang `-Xlinker <arg>`.
            if (i + 1 < argc)
                {
                [opts.mutableLinkerArgs addObject:@"-Xlinker"];
                [opts.mutableLinkerArgs addObject:[NSString stringWithUTF8String:argv[++i]]];
                }
            else
                {
                fprintf(stderr, "xcc: error: -Xlinker requires an argument\n");
                return nil;
                }
            }
        else if (([arg hasPrefix:@"-l"] && arg.length > 2) || [arg hasPrefix:@"-Wl,"])
            {
            // `-lobjc` / `-Wl,...` forwarded verbatim to the native link (clang).
            [opts.mutableLinkerArgs addObject:arg];
            }
        else if ([arg isEqualToString:@"-m"] || [arg isEqualToString:@"--memory-model"])
            {
            if (i + 1 < argc)
                {
                NSString* spec = [NSString stringWithUTF8String:argv[++i]];
                // arm64 is the host backend — no layout, no memory model.
                // The driver picks XTArm64Backend when useArm64Backend is set.
                if ([spec isEqualToString:@"arm64"])
                    {
                    opts.targetName = spec;
                    opts.useArm64Backend = YES;
                    explicitModel = YES;
                    continue;
                    }
                // Atari ST/TT (m68k): like arm64, no 6502 memory model;
                // libs from support/atarist/, ARCH_m68k predefined.
                if ([spec isEqualToString:@"atarist"])
                    {
                    opts.targetName = spec;
                    opts.m68kPlatform = YES;
                    explicitModel = YES;
                    continue;
                    }
                // arm9 (ARMv7-A / AArch32, Zynq Cortex-A9): like arm64, no 6502
                // memory model; libs from support/arm9/, ARCH_arm9 predefined.
                if ([spec isEqualToString:@"arm9"])
                    {
                    opts.targetName = spec;
                    opts.useArm9Backend = YES;
                    explicitModel = YES;
                    continue;
                    }
                // x86-64 Linux (System V AMD64, musl): like arm64, no 6502 memory
                // model; libs from support/x86_64/, ARCH_x86_64 predefined.
                if ([spec isEqualToString:@"x86_64"] || [spec isEqualToString:@"x86-64"] || [spec isEqualToString:@"amd64"])
                    {
                    opts.targetName = @"x86_64";
                    opts.useX86_64Backend = YES;
                    explicitModel = YES;
                    continue;
                    }
                // x86-64 Windows (Win64 ABI, mingw PE): libs from support/win64/,
                // ARCH_x86_64 + ARCH_win64. Same ISA as x86_64, different ABI/format.
                if ([spec isEqualToString:@"win64"] || [spec isEqualToString:@"windows"])
                    {
                    opts.targetName = @"win64";
                    opts.useWin64Backend = YES;
                    explicitModel = YES;
                    continue;
                    }
                // WebAssembly (wasm32): like arm64, no 6502 memory model;
                // libs from support/wasm32/, ARCH_wasm32 predefined.
                if ([spec isEqualToString:@"wasm32"] || [spec isEqualToString:@"wasm"])
                    {
                    opts.targetName = @"wasm32";
                    opts.useWasm32Backend = YES;
                    explicitModel = YES;
                    continue;
                    }
                // The .lnk is the single source of truth. The only spec
                // built without one is the parametric `xe:<size>:<mask>`
                // triplet (no .lnk exists for it by design); everything else
                // that can't be found is a hard error — no hardcoded fallback.
                XTMemoryModel* m = [XTCommandLineOptions tryLoadLinkerScript:spec
                                                                     xtcHome:resolvedHome];
                if (!m && [spec hasPrefix:@"xe:"])
                    m = [XTMemoryModel modelFromSpec:spec];
                if (!m)
                    {
                    fprintf(stderr, "xcc: error: no layout file for -m '%s' "
                                    "(looked for support/<platform>/layouts/%s.lnk under "
                                    "the xtc home). The layout is the single source of "
                                    "truth; there is no built-in fallback.\n",
                            spec.UTF8String, spec.UTF8String);
                    return nil;
                    }
                opts.targetName = spec;
                opts.memoryModel = m;
                explicitModel = YES;
                }
            else
                {
                fprintf(stderr, "xcc: error: -m requires an argument\n");
                return nil;
                }
            }
        else if ([arg isEqualToString:@"--sign"])
            {
            if (i + 1 < argc)
                opts.signIdentityPath = [NSString stringWithUTF8String:argv[++i]];
            else
                {
                fprintf(stderr, "xcc: error: --sign requires an identity.pem\n");
                return nil;
                }
            }
        else if ([arg isEqualToString:@"--sign-entitlements"])
            {
            if (i + 1 < argc)
                opts.signEntitlementsPath = [NSString stringWithUTF8String:argv[++i]];
            else
                {
                fprintf(stderr, "xcc: error: --sign-entitlements requires a plist\n");
                return nil;
                }
            }
        else if ([arg isEqualToString:@"-A"] || [arg isEqualToString:@"--arch"])
            {
            // CPU architecture, orthogonal to the -m platform/memory-model.
            // `-A arm64` selects the native arm64 backend (and a native
            // executable when linked); `-A 6502` is the default. The platform
            // (-m) still selects board/OS libs; arch × platform layering of the
            // support libs is future work — today -A arm64 is a host build.
            if (i + 1 < argc)
                {
                NSString* a = [NSString stringWithUTF8String:argv[++i]];
                if ([a isEqualToString:@"arm64"])
                    {
                    opts.useArm64Backend = YES;
                    }
                else if ([a isEqualToString:@"ios"] || [a isEqualToString:@"ios-sim"])
                    {
                    // Same arm64 backend, iOS platform flavour: the Mach-O
                    // platform stamp and the SDK whose .tbd stubs resolve
                    // system libraries are the only deltas (iOS.md Stage 0).
                    opts.useArm64Backend = YES;
                    opts.applePlatform = a;
                    }
                else if ([a isEqualToString:@"arm9"] || [a isEqualToString:@"armv7"] || [a isEqualToString:@"armv7-a"] || [a isEqualToString:@"cortex-a9"])
                    {
                    opts.useArm9Backend = YES;
                    opts.targetName = @"arm9";
                    }
                else if ([a isEqualToString:@"x86_64"] || [a isEqualToString:@"x86-64"] || [a isEqualToString:@"amd64"])
                    {
                    opts.useX86_64Backend = YES;
                    opts.targetName = @"x86_64";
                    }
                else if ([a isEqualToString:@"win64"] || [a isEqualToString:@"windows"] || [a isEqualToString:@"x86_64-windows"])
                    {
                    // x86-64 Windows: same ISA as x86_64, Win64 ABI (rcx/rdx/r8/r9
                    // + 32-byte shadow space), PE/COFF via the mingw toolchain.
                    opts.useWin64Backend = YES;
                    opts.targetName = @"win64";
                    }
                else if ([a isEqualToString:@"wasm32"] || [a isEqualToString:@"wasm"])
                    {
                    // WebAssembly: 32-bit linear memory, runs under Node.js or
                    // a browser against the emitted JS loader (env host imports).
                    opts.useWasm32Backend = YES;
                    opts.targetName = @"wasm32";
                    }
                else if ([a isEqualToString:@"6502"])
                    {
                    opts.useArm64Backend = NO;
                    }
                else if ([a isEqualToString:@"m68k"] || [a isEqualToString:@"68000"])
                    {
                    opts.useM68kBackend = YES;
                    opts.m68kCpu = 68000;
                    }
                else if ([a isEqualToString:@"68030"])
                    {
                    opts.useM68kBackend = YES;
                    opts.m68kCpu = 68030;
                    }
                else if ([a isEqualToString:@"android"])
                    {
                    // Android aarch64: the arm64 backend + IR pipeline, linked
                    // to bionic via the NDK (Mach-O asm rewritten to ELF).
                    opts.useArm64Backend = YES;
                    opts.androidTarget = YES;
                    opts.targetName = @"android";
                    }
                else
                    {
                    fprintf(stderr, "xcc: error: unknown -A architecture '%s' "
                                    "(supported: arm64, ios, ios-sim, arm9, 6502, m68k, 68000, 68030, x86_64, win64, wasm32)\n",
                            a.UTF8String);
                    return nil;
                    }
                }
            else
                {
                fprintf(stderr, "xcc: error: -A requires an argument (6502 | arm64 | arm9 | m68k | x86_64 | win64 | wasm32)\n");
                return nil;
                }
            }
        else if ([arg isEqualToString:@"-mhard-float"] || [arg isEqualToString:@"-mfpu"])
            {
            opts.m68kHardFloat = YES;
            }
        else if ([arg isEqualToString:@"-msoft-float"])
            {
            opts.m68kHardFloat = NO;
            }
        else if ([arg isEqualToString:@"-mpic"] || [arg isEqualToString:@"-fPIC"] || [arg isEqualToString:@"-fpic"])
            {
            opts.m68kPic = YES;
            }
        else if ([arg isEqualToString:@"-fnew-ir"] || [arg isEqualToString:@"--with-ir"])
            {
            // Deprecated no-op: the IR pipeline is now the only/default path.
            // Still accepted so existing scripts and Makefiles don't break.
            opts.useNewIR = YES;
            }
        else if ([arg isEqualToString:@"-o"] || [arg isEqualToString:@"--output"])
            {
            if (i + 1 < argc)
                {
                opts.outputPath = [NSString stringWithUTF8String:argv[++i]];
                }
            else
                {
                fprintf(stderr, "xcc: error: -o requires an argument\n");
                return nil;
                }
            }
        else if ([arg hasPrefix:@"-D"])
            {
            NSString* defStr;
            if (arg.length > 2)
                {
                defStr = [arg substringFromIndex:2];
                }
            else if (i + 1 < argc)
                {
                defStr = [NSString stringWithUTF8String:argv[++i]];
                }
            else
                {
                fprintf(stderr, "xcc: error: -D requires an argument\n");
                return nil;
                }
            NSRange eqRange = [defStr rangeOfString:@"="];
            if (eqRange.location != NSNotFound)
                {
                NSString* key = [defStr substringToIndex:eqRange.location];
                NSString* val = [defStr substringFromIndex:eqRange.location + 1];
                opts.mutableDefines[key] = val;
                }
            else
                {
                opts.mutableDefines[defStr] = @"1";
                }
            }
        else if (([arg isEqualToString:@"-E"] || [arg isEqualToString:@"--preprocessed"]) && i + 1 < argc)
            {
            opts.preprocessedOutputPath = [NSString stringWithUTF8String:argv[++i]];
            }
        else if (([arg isEqualToString:@"-H"] || [arg isEqualToString:@"--xtc-home"]) && i + 1 < argc)
            {
            opts.xtcHome = [XTCommandLineOptions sanitiseEnvPath:
                                                     [NSString stringWithUTF8String:argv[++i]]];
            }
        else if (([arg isEqualToString:@"-Fli"] || [arg isEqualToString:@"--fn-leaf-inline"]) && i + 1 < argc)
            {
            opts.maxLeafInlineSize = (NSUInteger)atoi(argv[++i]);
            }
        else if (([arg isEqualToString:@"-Flu"] || [arg isEqualToString:@"--fn-loop-unroll"]) && i + 1 < argc)
            {
            opts.loopUnrollMax = (NSUInteger)atoi(argv[++i]);
            opts.loopUnrollMaxExplicit = YES;
            }
        else if (([arg isEqualToString:@"-Fmb"] || [arg isEqualToString:@"--fn-min-banked"]) && i + 1 < argc)
            {
            opts.fnMinBanked = (NSUInteger)atoi(argv[++i]);
            }
        else if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"])
            {
            [[[XTCommandLineOptions alloc] init] printUsage];
            exit(0);
            }
        else if ([arg isEqualToString:@"-dl"] || [arg isEqualToString:@"--dump-layout"])
            {
            opts.dumpLayout = YES;
            }
        else if ([arg isEqualToString:@"-dp"] || [arg isEqualToString:@"--dump-placement"])
            {
            opts.dumpPlacement = YES;
            }
        else if ([arg isEqualToString:@"-du"] || [arg isEqualToString:@"--dump-usage"])
            {
            opts.dumpUsage = YES;
            }
        else if ([arg isEqualToString:@"-ll"] || [arg isEqualToString:@"--list-layouts"])
            {
            [XTCommandLineOptions listLayouts:resolvedHome];
            exit(0);
            }
        else if ([arg isEqualToString:@"-Q"] || [arg isEqualToString:@"--quit-style"])
            {
            if (i + 1 >= argc)
                {
                fprintf(stderr, "xcc: -Q requires 'rts' or 'loop'\n");
                return nil;
                }
            NSString* val = [@(argv[++i]) lowercaseString];
            if ([val isEqualToString:@"loop"])
                {
                opts.quitLoop = YES;
                }
            else if ([val isEqualToString:@"rts"])
                {
                opts.quitLoop = NO;
                }
            else
                {
                fprintf(stderr, "xcc: -Q expects 'rts' or 'loop', got '%s'\n",
                        val.UTF8String);
                return nil;
                }
            }
        else if ([arg isEqualToString:@"-flto"])
            {
            opts.lto = YES;
            }
        else if ([arg isEqualToString:@"-c"])
            {
            opts.compileOnly = YES;
            }
        else if ([arg isEqualToString:@"-a"] || [arg isEqualToString:@"--assemble-only"])
            {
            opts.assembleOnly = YES;
            }
        else if ([arg isEqualToString:@"-q"] || [arg isEqualToString:@"--quiet"])
            {
            opts.quiet = YES;
            }
        else if ([arg isEqualToString:@"--emit-iface"])
            {
            opts.emitIface = YES;
            }
        else if ([arg isEqualToString:@"--emit-lib"])
            {
            opts.emitLib = YES;
            }
        else if ([arg isEqualToString:@"--with-lib"] && i + 1 < argc)
            {
            // uxkit/032: a prebuilt .so to ride beside the payload.
            opts.withLib = [NSString stringWithUTF8String:argv[++i]];
            }
        else if ([arg isEqualToString:@"--lib-name"] && i + 1 < argc)
            {
            opts.libName = [NSString stringWithUTF8String:argv[++i]];
            }
        else if ([arg isEqualToString:@"--needed"] && i + 1 < argc)
            {
            // Repeatable: each -needed names one more DT_NEEDED soname.
            NSString* n = [NSString stringWithUTF8String:argv[++i]];
            opts.neededSonames = [(opts.neededSonames ?: @[]) arrayByAddingObject:n];
            }
        else if ([arg isEqualToString:@"--with-dex"] && i + 1 < argc)
            {
            // A committed classes.dex to ride along in the package (uxkit/031).
            opts.withDex = [NSString stringWithUTF8String:argv[++i]];
            }
        else if ([arg isEqualToString:@"--emit-apk"])
            {
            // -A android only: package the program as an installable
            // NativeActivity APK instead of a bare ELF executable.
            opts.emitApk = YES;
            }
        else if ([arg isEqualToString:@"--self-host"])
            {
            opts.selfHost = YES;
            opts.noSelfHost = NO;
            }
        else if ([arg isEqualToString:@"--no-self-host"])
            {
            opts.noSelfHost = YES;
            opts.selfHost = NO; // force the clang path
            }
        else if ([arg isEqualToString:@"-V"] || [arg isEqualToString:@"--verbose"])
            {
            opts.verbose = YES;
            }
        else if ([arg isEqualToString:@"--xtc-stack"])
            {
            opts.useXtcStack = YES;
            }
        else if ([arg isEqualToString:@"-S"])
            {
            // cc's "keep the assembly", as in the shipped driver. The output's
            // extension (.s/.asm) is what selects assembly here, so there is
            // nothing to set. It used to be --xtc-stack's short form; the
            // harnesses that pass `-S -o x.s` would then have compared the
            // software-stack convention against the port's default.
            }
        else if ([arg hasPrefix:@"-fmalloc="])
            {
            // WHOSE malloc backs the runtime on a hosted target — a different
            // axis from -falloc=, which picks the xtc-level strategy. Kept
            // separate deliberately: conflating "bump vs free-list" with
            // "system vs mimalloc" reads as one setting and is two.
            NSString* val = [[arg substringFromIndex:9] lowercaseString];
            if (![val isEqualToString:@"system"] && ![val isEqualToString:@"mimalloc"])
                {
                fprintf(stderr, "xcc: -fmalloc= expects 'system' or 'mimalloc', got '%s'\n",
                        val.UTF8String);
                return nil;
                }
            opts.hostMalloc = val;
            }
        else if ([arg hasPrefix:@"-falloc="])
            {
            NSString* val = [[arg substringFromIndex:8] lowercaseString];
            if (![val isEqualToString:@"bump"] && ![val isEqualToString:@"heap"])
                {
                fprintf(stderr, "xcc: -falloc= expects 'bump' or 'heap', got '%s'\n",
                        val.UTF8String);
                return nil;
                }
            opts.allocator = val;
            opts.allocatorExplicit = YES;
            }
        else if ([arg isEqualToString:@"-fthread-safe-arc"])
            {
            opts.threadSafeARC = 1;
            }
        else if ([arg isEqualToString:@"-fno-thread-safe-arc"])
            {
            opts.threadSafeARC = 0;
            }
        else if ([arg hasPrefix:@"--migrate="])
            {
            NSString* v = [arg substringFromIndex:10];
            NSArray* parts = [v componentsSeparatedByString:@":"];
            BOOL ok = parts.count == 2;
            for (NSString* pt in parts)
                if (ok && ![pt length])
                    ok = NO;
            if (!ok)
                {
                fprintf(stderr, "xtc: error: --migrate wants <base>:<to>, "
                                "e.g. --migrate=0.3:0.4\n");
                return nil;
                }
            opts.migrateVersions = v;
            }
        else if ([arg isEqualToString:@"-fdce-trace"])
            {
            opts.dceTrace = YES;
            }
        else if ([arg isEqualToString:@"--emit-ir"])
            {
            opts.emitIR = YES;
            }
        else if ([arg isEqualToString:@"--emit-ir-opt"])
            {
            opts.emitIROpt = YES;
            }
        else if ([arg isEqualToString:@"--emit-asm-from-ir"])
            {
            opts.emitAsmFromIR = YES;
            }
        else if ([arg hasPrefix:@"-fauto-cloak="])
            {
            NSString* val = [[arg substringFromIndex:13] lowercaseString];
            if ([val isEqualToString:@"never"] ||
                [val isEqualToString:@"auto"] ||
                [val isEqualToString:@"always"])
                {
                opts.autoCloakMode = val;
                }
            else
                {
                fprintf(stderr,
                        "xcc: -fauto-cloak= expects 'never|auto|always', got '%s'\n",
                        val.UTF8String);
                return nil;
                }
            }
        else if ([arg isEqualToString:@"-fbounds-check"])
            {
            // A CHECKED build (private:docs/Design/memory-safety.md). Native targets
            // only: xt6502 has no room for the reporter and nowhere to print a
            // backtrace, so it is a hard error rather than a silent no-op —
            // a flag that quietly does nothing is what made "verified with ARC
            // off" mean nothing during bug 025.
            opts->_boundsCheck = YES;
            }
        else if ([arg isEqualToString:@"-farc"] || [arg hasPrefix:@"-farc="])
            {
            // RETIRED (bug 026). The flag never reached the IR lowering, so a
            // build with it and a build without it produced byte-identical IR —
            // 17 fixtures carried `-farc=off` and were ARC builds regardless.
            // It is still ACCEPTED so existing command lines and fixture
            // directives do not break, and it still says plainly that it does
            // nothing, because a silently-ignored flag is what made "verified
            // with ARC off" mean nothing during bug 025.
            //
            // What it was FOR was the 6502, where refcount traffic looked too
            // expensive; xt6502's hardware stack and banked runtime made that
            // case much weaker, and manual lifetime management deserves a
            // design rather than a flag that half-existed.
            fprintf(stderr,
                    "xcc: warning: %s is retired and does nothing — ARC is always "
                    "on. `delete` on a struct or primitive array is still allowed "
                    "(ARC never managed those); on a class instance it is not.\n",
                    arg.UTF8String);
            }
        else if ([arg hasPrefix:@"--stack-size="] || [arg hasPrefix:@"-ss="] || [arg isEqualToString:@"--stack-size"] || [arg isEqualToString:@"-ss"])
            {
            // Accept -ss <n>, -ss=<n>, --stack-size <n>, --stack-size=<n>.
            NSString* val = nil;
            NSRange eq = [arg rangeOfString:@"="];
            if (eq.location != NSNotFound)
                {
                val = [arg substringFromIndex:eq.location + 1];
                }
            else if (i + 1 < argc)
                {
                val = [NSString stringWithUTF8String:argv[++i]];
                }
            else
                {
                fprintf(stderr, "xcc: error: %s requires an argument\n", argv[i]);
                return nil;
                }
            NSScanner* sc = [NSScanner scannerWithString:val];
            long long n = 0;
            // Accept both decimal (`512`) and hex (`$200` or `0x200`).
            BOOL ok;
            if ([val hasPrefix:@"$"])
                {
                unsigned int hx = 0;
                NSScanner* hs = [NSScanner scannerWithString:[val substringFromIndex:1]];
                ok = [hs scanHexInt:&hx] && hs.isAtEnd;
                n = (long long)hx;
                }
            else if ([val hasPrefix:@"0x"] || [val hasPrefix:@"0X"])
                {
                unsigned int hx = 0;
                NSScanner* hs = [NSScanner scannerWithString:[val substringFromIndex:2]];
                ok = [hs scanHexInt:&hx] && hs.isAtEnd;
                n = (long long)hx;
                }
            else
                {
                ok = [sc scanLongLong:&n] && sc.isAtEnd;
                }
            if (!ok || n <= 0 || n > 0xFFFF)
                {
                fprintf(stderr, "xcc: --stack-size expects a positive integer up to 65535, got '%s'\n",
                        val.UTF8String);
                return nil;
                }
            opts.stackSize = (NSUInteger)n;
            }
        else if ([arg hasPrefix:@"-Wno-"])
            {
            NSString* cat = [arg substringFromIndex:5];
            if (XTWarningCategoryFromName(cat) == XTWarnNone)
                {
                fprintf(stderr,
                        "xcc: warning: unknown warning category '%s' — known: %s\n",
                        cat.UTF8String,
                        [[XTWarningCategoryAllNames() componentsJoinedByString:@", "] UTF8String]);
                }
            else
                {
                [opts.mutableSuppressedWarnings addObject:cat];
                }
            }
        else if ([arg isEqualToString:@"-O3"])
            {
            opts.optimisationLevel = 3;
            }
        else if ([arg isEqualToString:@"-O2"])
            {
            opts.optimisationLevel = 2;
            }
        else if ([arg isEqualToString:@"-O"] || [arg isEqualToString:@"-O1"])
            {
            opts.optimisationLevel = 1;
            }
        else if ([arg isEqualToString:@"-O0"])
            {
            opts.optimisationLevel = 0;
            }
        else if ([arg hasPrefix:@"-x-"])
            {
            // -x-<arch>,<opt>[,<opt>...] — target-specific options.
            NSArray<NSString*>* parts =
                [[arg substringFromIndex:3] componentsSeparatedByString:@","];
            NSString* xarch = parts.firstObject;
            NSArray<NSString*>* known = XTTargetOptionRegistry()[xarch];
            if (parts.count < 2 || xarch.length == 0)
                {
                fprintf(stderr, "xcc: error: '%s' — expected -x-<arch>,<option>[,<option>...]\n",
                        argv[i]);
                return nil;
                }
            if (!known)
                {
                fprintf(stderr, "xcc: error: no target-specific options exist for arch '%s'\n",
                        xarch.UTF8String);
                return nil;
                }
            for (NSString* o in [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)])
                {
                if (![known containsObject:o])
                    {
                    fprintf(stderr, "xcc: error: unknown %s option '%s' — known: %s\n",
                            xarch.UTF8String, o.UTF8String,
                            [known componentsJoinedByString:@", "].UTF8String);
                    return nil;
                    }
                NSMutableArray* lst = opts.mutableTargetOptions[xarch];
                if (!lst)
                    {
                    lst = [NSMutableArray array];
                    opts.mutableTargetOptions[xarch] = lst;
                    }
                if (![lst containsObject:o])
                    [lst addObject:o];
                }
            }
        else if ([arg hasPrefix:@"-"])
            {
            fprintf(stderr, "xcc: warning: unknown option '%s'\n", argv[i]);
            }
        else
            {
            [opts.mutableInputFiles addObject:arg];
            }
        }

    if (opts.mutableInputFiles.count == 0 && !opts.dumpLayout)
        {
        fprintf(stderr, "xcc: error: no input files\n");
        [opts printUsage];
        return nil;
        }

    // No explicit -m and not the arm64 host backend → default to the
    // xt6502/xt layout. (xl/xe/c64 were retired; xt6502 and arm64 are the
    // only supported targets.) The init-time defaultModel placeholder is
    // replaced here so the platform/lib resolution lands on support/xt6502.
    if (!explicitModel && !opts.useArm64Backend && !opts.useArm9Backend && !opts.useX86_64Backend && !opts.useWin64Backend && !opts.useWasm32Backend && !opts.m68kPlatform)
        {
        XTMemoryModel* m = [XTCommandLineOptions tryLoadLinkerScript:@"xt6502/xt"
                                                             xtcHome:resolvedHome];
        if (!m)
            {
            fprintf(stderr, "xcc: error: cannot load the default layout "
                            "'xt6502/xt' (looked for support/xt6502/layouts/xt.lnk under "
                            "the xtc home). Set XTC_HOME / -H, or pass -m or -A arm64.\n");
            return nil;
            }
        opts.targetName = @"xt6502/xt";
        opts.memoryModel = m;
        }

    // -O2 and above auto-unroll counted loops with trip count <= 5
    // unless the user explicitly passed -Flu / --fn-loop-unroll.
    if (!opts.loopUnrollMaxExplicit && opts.optimisationLevel >= 2)
        {
        opts.loopUnrollMax = 5;
        }

    // -fmalloc=mimalloc needs a linker that can consume a foreign OBJECT file.
    // Only the x86-64 path has one today: it links with ld.lld directly. The
    // arm64 self-host linker ASSEMBLES our own `.s` and has no object reader,
    // and the freestanding win64 runtime reaches the OS through kernel32 with
    // no libc for mimalloc's primitives to sit on. Reject rather than accept
    // the flag and quietly build a system-malloc binary — a silent no-op here
    // would be indistinguishable from "measured, made no difference".
    if ([opts.hostMalloc isEqualToString:@"mimalloc"] && !opts.useX86_64Backend)
        {
        fprintf(stderr,
                "xcc: -fmalloc=mimalloc is only supported on -A x86_64 today.\n"
                "  It ships as an OBJECT that must be linked first, and only the\n"
                "  x86-64 path links with ld.lld directly; the arm64 self-host\n"
                "  linker assembles its own source and cannot take an object, and\n"
                "  win64 is freestanding with no libc under mimalloc. See\n"
                "  support/MIMALLOC.md.\n");
        return nil;
        }

    // Resolve the allocator default. A target supports the free-list heap
    // iff its memory model declares either a dedicated flat heap region
    // (heapLow != 0) or a reserved heap bank (heapBank != 0). Implicit
    // default on such targets is "heap"; elsewhere it stays "bump".
    // Explicit -falloc=heap on an unsupported target is an error.
    // arm64 (host) always supports heap via host malloc — no layout needed.
    // arm64 (host malloc) and the Atari ST/TT m68k (GEMDOS Malloc/Mfree)
    // both have a real free-capable heap — no layout heap region needed.
    BOOL targetSupportsHeap = (opts.memoryModel.heapLow != 0) ||
                              (opts.memoryModel.heapBank != 0) ||
                              opts.useArm64Backend ||
                              opts.useArm9Backend ||
                              opts.useX86_64Backend || // host malloc, like arm64
                              opts.useWin64Backend ||  // mingw host malloc
                              opts.useWasm32Backend || // free-list over memory.grow
                              opts.m68kPlatform;
    if (opts.allocatorExplicit)
        {
        if ([opts.allocator isEqualToString:@"heap"] && !targetSupportsHeap)
            {
            fprintf(stderr,
                    "xcc: -falloc=heap requires a target with a dedicated heap region "
                    "(currently xl-shadow or xe-nobank); target '%s' has none\n",
                    opts.targetName.UTF8String);
            return nil;
            }
        }
    else if (targetSupportsHeap)
        {
        opts.allocator = @"heap";
        }

    // Default to the host architecture (see sawArch/sawModel above). A memory
    // Everything in libraryPaths at this point came from an explicit -L; the
    // sysroot / toolchain defaults are appended AFTER parse (main.m, the
    // driver), and the 3p probe slots between the two tiers.
    opts->_explicitLibraryPathCount = opts.libraryPaths.count;

    // model implies a 6502 board, so -m alone still selects 6502.
    if (!sawArch && !sawModel)
        {
#if defined(_WIN32)
        // Before the CPU test: a Windows x86-64 host defines __x86_64__ too,
        // and picking the Linux target there hands the user a static ELF
        // that Windows cannot exec.
        opts.useWin64Backend = YES;
        opts.targetName = @"win64";
#elif defined(__aarch64__) || defined(__arm64__)
        opts.useArm64Backend = YES;
#elif defined(__x86_64__) || defined(_M_X64)
        opts.useX86_64Backend = YES;
        opts.targetName = @"x86_64";
#endif
        }

    // Checked after the host default above has resolved the backend flags.
    // Placed before it, this rejected a plain `xcc -fbounds-check` on the
    // host: useArm64Backend is only set by -A arm64 at that point, and the
    // default host build sets it further down.
    //
    // -fbounds-check is NATIVE ONLY, and a HARD ERROR elsewhere rather than a
    // silent no-op. The reporter needs a symbol table to name frames, a frame
    // chain to walk and somewhere to print a backtrace; xt6502 has none of
    // those, and the checked runtime is arm64 assembly. Emitting the calls
    // anyway would produce a link failure at best and a checked build that
    // checks nothing at worst — and a flag that quietly does nothing is what
    // made "verified with ARC off" mean nothing during bug 025.
    if (opts.boundsCheck)
        {
        BOOL nativeTarget = opts.useArm64Backend || opts.useArm9Backend || opts.useX86_64Backend || opts.useWin64Backend;
        if (!nativeTarget)
            {
            fprintf(stderr,
                    "xcc: error: -fbounds-check is native-only (arm64, arm9, x86_64,\n"
                    "  win64). The checked runtime needs a symbol table to name frames,\n"
                    "  a frame chain to walk and somewhere to print a trace — the 6502\n"
                    "  has none of those. See private:docs/Design/memory-safety.md.\n");
            return nil;
            }
        if (!opts.useArm64Backend)
            {
            fprintf(stderr,
                    "xcc: error: -fbounds-check is implemented for arm64 so far; the\n"
                    "  checked runtime (rt-checked-macos.s) is arm64 assembly and the\n"
                    "  parameter map is emitted by the arm64 back end only.\n");
            return nil;
            }
        }

    return opts;
    }

/****************************************************************************\
|* Print the full usage/help text to stderr.
\****************************************************************************/
- (void)printUsage
    {
    fprintf(stderr,
            "Usage: xcc [options] <input.xc ...>\n"
            "\n"
            "With no -A, xcc builds a native executable for THIS machine, as cc does:\n"
            "    xcc -o prog prog.xc\n"
            "\n"
            "Options:\n"
            "  -a, --assemble-only        Compile to .asm module (no runtime)\n"
            "  -flto                      At a link of objects, recompile from the IR\n"
            "                             each carries, as one module — restores\n"
            "                             cross-object inlining and dead-code removal\n"
            "  -c                         Compile to a relocatable object (.o) and\n"
            "                             stop, as C does — unresolved references\n"
            "                             become relocations for a later link.\n"
            "                             (arm64 today; see separate-compilation.md)\n"
            "  -D <name[=value]>          Define preprocessor symbol\n"
            "  -E, --preprocessed <path>  Write preprocessed output to file\n"
            "  -fauto-cloak=never|auto|always\n"
            "                             Auto-promote cloak-safe decls into the\n"
            "                             :cloaked segment. Accepted, but INERT on\n"
            "                             every live target: it applied to the\n"
            "                             retired xe/xl Atari models, and no current\n"
            "                             layout has a cloaked region.\n"
            "  -fthread-safe-arc          Atomic ARC refcounts, so two threads can\n"
            "                             share an object. Default: on exactly when\n"
            "                             the program spawns a thread.\n"
            "  -fno-thread-safe-arc       Force plain, non-atomic ARC refcounts.\n"
            "  -fmalloc=system|mimalloc   Host malloc behind the runtime (hosted\n"
            "                             targets only; mimalloc must link FIRST to\n"
            "                             override, so it is passed as an object)\n"
            "  -falloc=bump|heap          Heap allocator: bump (fast, no free)\n"
            "                             or heap (coalescing free-list, supports\n"
            "                             delete). Default: heap on targets with a\n"
            "                             dedicated heap region, bump elsewhere.\n"
            "  -farc[=on|off]             Automatic reference counting: controls\n"
            "                             whether `retain` and `release` statements\n"
            "                             are accepted (delete is unaffected).\n"
            "                             Accepts on|yes|1 or off|no|0. Default: on.\n"
            "  -fbounds-check             Checked build: subscripts are range-checked,\n"
            "                             and a failure reports the site, the real\n"
            "                             bounds and a symbolised stack before it\n"
            "                             aborts. An array with a declared length —\n"
            "                             local, global, or sized by its own\n"
            "                             initialiser — is checked against that\n"
            "                             length; a heap allocation against its own\n"
            "                             header. A bare pointer has neither, so it\n"
            "                             is checked as a heap allocation and means\n"
            "                             something only if that is what it points\n"
            "                             at. Debug-time only; native (arm64) so far,\n"
            "                             an error elsewhere. Default: off.\n"
            "  -Fli, --fn-leaf-inline <n> Max leaf-function size to inline\n"
            "                             (default: 100, requires -O2+)\n"
            "  -Flu, --fn-loop-unroll <n> Auto-unroll counted for-loops with trip\n"
            "                             count <= n (default: 5 at -O2+, 0 otherwise)\n"
            "  -Fmb, --fn-min-banked <n>  Minimum function size (in 6502 instructions)\n"
            "                             to be banked on a banked target. Below this,\n"
            "                             auto-placement keeps the function in main RAM\n"
            "                             so the call site avoids the _xcall trampoline.\n"
            "                             Default: 0 (off — opt in with e.g. -Fmb 50).\n"
            "  -H, --xcc-home <path>      Root holding the support tree. Rarely needed:\n"
            "                             xcc finds it relative to its own binary\n"
            "                             (<bin>/../lib/xc, or <bin>/xc on Windows),\n"
            "                             then $XCC_HOME, the cwd, and the install\n"
            "                             roots. The tree is lib/xc in an install and\n"
            "                             support/ in a source checkout; both work.\n"
            "  -h, --help                 Show this help\n"
            "  -I <path>                  Add include search path\n"
            "  -L, --library-path <path>  Add library search path (for `#import <Lib>`,\n"
            "                             which resolves to lib<Lib>.so and reads its\n"
            "                             DWARF for types, functions and enum constants)\n"
            "  -l<name>                   Link a system library (native targets); forwarded\n"
            "                             to the linker. e.g. -lobjc for the ObjC runtime\n"
            "  --migrate=<base>:<to>      Compile as if the library were still <base>:\n"
            "                             members marked since(\"V\") with V newer than\n"
            "                             <base> vanish from lookup, so a call whose\n"
            "                             MEANING changed between the versions fails\n"
            "                             loudly instead of resolving to the new one.\n"
            "                             e.g. --migrate=0.3:0.4 while porting to the\n"
            "                             0.4 String (see private:docs/Design/string-utf8.md)\n"
            "  -framework <F>             Link a macOS framework (native). e.g. -framework AppKit\n"
            "  -Xlinker <arg>, -Wl,<arg>  Pass an argument straight through to the linker\n"
            "                             ($XTC_LDFLAGS is also appended to the native link)\n"
            "  --self-host                (arm64) DEFAULT: assemble + link + sign in-house —\n"
            "                             no clang, no codesign, no system assembler. Links\n"
            "                             -l/-framework via .dylib/.tbd/.a and forwards\n"
            "                             -Wl,/-Xlinker. Accepted explicitly; already on.\n"
            "  --no-self-host             force the clang link path instead\n"
            "  -O0                        No optimisation (assembly output only)\n"
            "  -O, -O1                    Peephole + register tracking\n"
            "  -O2                        + const prop, dead code/store elim, tail call\n"
            "                               opt, leaf inlining, loop unrolling (<=5)\n"
            "  -O3                        + branch inversion, branch threading,\n"
            "                               strength reduction, cross-function DCE,\n"
            "                               label cleanup (the default)\n"
            "  -o, --output <path>        Output file (.asm or binary)\n"
            "  -Q, --quit-style <which>   Action after main() returns: rts (default), loop\n"
            "  -q, --quiet                Suppress informational output\n"
            "  -S                         Keep the assembly (the output's .s extension\n"
            "                             selects it)\n"
            "  --xtc-stack                Keep return addresses and saved registers on\n"
            "                             the xtc software stack (xt6502)\n"
            "  --needed <soname>          -A android: add a DT_NEEDED entry naming\n"
            "                             <soname>. Repeatable. bionic resolves a\n"
            "                             library's imports against its own local\n"
            "                             group only, so a payload that calls into a\n"
            "                             companion .so must NAME it.\n"
            "  --with-lib <path>          -A android --emit-apk: store an extra\n"
            "                             prebuilt .so in lib/arm64-v8a/.\n"
            "  --lib-name <name>          -A android --emit-apk: the manifest's\n"
            "                             android.app.lib_name — WHICH packaged\n"
            "                             library the system loads (default: the\n"
            "                             payload).\n"
            "  --emit-iface               Write the module INTERFACE (JSON: classes,\n"
            "                             members, vtable slots, and each class's\n"
            "                             `outlet` fields and `:action` methods) to\n"
            "                             -o, or stdout, and stop. No codegen.\n"
            "  --emit-lib                 Build a SHARED LIBRARY instead of an\n"
            "                             executable (arm64 / arm9 / x86_64 /\n"
            "                             win64 / wasm32). Writes the object plus\n"
            "                             a sibling .xtc.iface describing the\n"
            "                             classes, protocols, structs and enums it\n"
            "                             exports, which is what `#import <Lib>`\n"
            "                             type-checks a client against. -fpic is\n"
            "                             implied.\n"
            "                             On wasm32 it writes lib<Name>.wasm plus\n"
            "                             lib<Name>.json (dataSize/tableSize/deps); the\n"
            "                             loader needs BOTH before it can place the\n"
            "                             library's statics and grow the table.\n"
            "  --with-dex <path>          (-A android --emit-apk) Carry this\n"
            "                             classes.dex in the package, and mark the\n"
            "                             manifest hasCode=\"true\" so ART loads it.\n"
            "  --emit-apk                 (-A android) Package the program as an\n"
            "                             installable NativeActivity APK instead of\n"
            "                             a bare ELF. stdout/stderr are routed to\n"
            "                             logcat under the tag `xcapp`; run it with\n"
            "                             adb install + am start.\n"
            "  -fpic, -fPIC, -mpic        Position-independent code. On by default\n"
            "                             for --emit-lib; on arm9 it is what makes\n"
            "                             an ET_DYN .so rather than a fixed-load ELF.\n"
            "  -mhard-float, -mfpu        (arm9) Use VFP instructions for float and\n"
            "                             double. Default on the boards that have it.\n"
            "  -msoft-float               (arm9) Route float/double through the\n"
            "                             libgcc soft-float helpers instead.\n"
            "  --emit-ir                  Dump IR lowering to stderr after semantic\n"
            "                             analysis (diagnostic, assembly unchanged).\n"
            "  --emit-ir-opt              Dump IR after peephole optimisation pass to\n"
            "                             stderr (diagnostic, assembly unchanged).\n"
            "  --emit-asm-from-ir         Replace the standard codegen with the IR\n"
            "                             pipeline for comparison/correctness testing.\n"
            "                             Implies --assemble-only.\n"
            "  -V, --verbose              Print the resolved support root + every include\n"
            "                             search path to stderr at startup. First stop\n"
            "                             when 'Cannot find include file' fires on a new\n"
            "                             install or alien platform.\n"
            "  -v, --version              Print version and exit\n"
            "  -ss, --stack-size <n>      Cap the xtc stack at <n> bytes (decimal,\n"
            "                             $hex, or 0xhex; 1..65535). No effect on\n"
            "                             banked-heap or non-heap targets, which is\n"
            "                             all of them today — kept for layouts with a\n"
            "                             flat heap.\n"
            "\n"
            "Platform options:\n"
            "  -dl, --dump-layout         Print memory-map diagram and exit (use with -m)\n"
            "  -dp, --dump-placement      After codegen, print every function/method's\n"
            "                             final placement (main / banked page N / shadow /\n"
            "                             cloaked / irq / vbi) to stderr, with per-bank\n"
            "                             byte usage for the buckets that are populated.\n"
            "                             Useful for debugging packing decisions on\n"
            "                             banked targets.\n"
            "  -du, --dump-usage          After codegen, print a per-segment usage\n"
            "                             summary covering every region/bank in the\n"
            "                             layout — used banks show bytes-used /\n"
            "                             available, unused banks (heap pool, code-bank\n"
            "                             pool) collapse into a single 'unused N-M' line.\n"
            "                             Lets you scope room for more code at a glance.\n"
            "  --list-layouts, -ll        List available built-in layouts by platform\n"
            "  -m <layout>                Load a memory layout (.lnk file). Searches\n"
            "                             for <layout> as a file path (appends .lnk\n"
            "                             if needed), then support/layouts/<layout>.lnk\n"
            "                             There is NO default: with neither -m nor -A\n"
            "                             xcc targets the host. `-m xt` is the banked\n"
            "                             6502 map (implies -A 6502); `arm64` selects\n"
            "                             the host arm64 backend (no layout);\n"
            "                             `atarist` selects the Atari ST/TT m68k\n"
            "                             platform (no layout; use with -A m68k).\n"
            "  -A, --arch <arch>          Target architecture. With no -A, xcc builds\n"
            "                             for the machine it is running on.\n"
            "                               arm64   native macOS / Linux host\n"
            "                               x86_64  Linux (musl)\n"
            "                               win64   Windows (PE/COFF, via mingw)\n"
            "                               arm9    AArch32 / XTOS — also builds a .so\n"
            "                                       (see --emit-lib)\n"
            "                               m68k    Atari ST/TT   (68000, or 68030)\n"
            "                               wasm32  WebAssembly (.wasm + .js loader,\n"
            "                                       runs under Node.js or a browser)\n"
            "                               6502    banked 6502 (xt6502)\n"
            "                               ios     iOS device / ios-sim simulator\n"
            "  --sign <identity.pem>      Developer-sign the finished Mach-O with an\n"
            "                             identity bundle (else output is ad-hoc signed).\n"
            "  --sign-entitlements <p>    Entitlements plist to embed when --sign is used.\n"
            "                             Orthogonal to -m, which picks the platform /\n"
            "                             memory model. A non-.s output path on a native\n"
            "                             target links a runnable executable.\n"
            "  -fnew-ir, --with-ir        Deprecated no-op: the IR pipeline (parse →\n"
            "                             sema → IR-lower → verify → backend) is now the\n"
            "                             default and only path. Accepted for\n"
            "                             compatibility with existing build scripts.\n"
            "\n"
            "Warning options (-Wno-<category> to suppress):\n"
            "    asm-clobbers             asm{} clobbers annotation mismatch\n"
            "    class-init               bad initialiser on stack class\n"
            "    escape                   stack-addr stored in longer-lived slot\n"
            "                             (global, heap field, outer scope)\n"
            "    packed-align             :packed field at an offset the target may fault on\n"
            "    toolchain-fallback       built by the SYSTEM toolchain (clang/mingw),\n"
            "                             not the in-house assembler+linker\n"
            "    unguarded-action         a `^` called without being tested since its\n"
            "                             last assignment (it goes null when its\n"
            "                             receiver dies — see bound-methods.md 6)\n"
            "    unknown-annotation       unrecognised function annotation\n"
            "    unknown-pragma           unrecognised # directive\n"
            "\n"
            "Function annotations (after params, comma-separated):\n"
            "  Calling convention / prologue:\n"
            "    : hwStack                Force 6502 hardware stack\n"
            "    : naked                  No prologue/epilogue (for ISRs)\n"
            "    : xtcStack               Force xtc software stack\n"
            "  Interrupt handlers (mutually exclusive with :naked):\n"
            "    : irq                    IRQ handler; OS-safe prologue, RTI epilogue\n"
            "    : vbi                    VBI handler; same shape as :irq, runs each\n"
            "                             vertical-blank (install via Vbi.install)\n"
            "  Placement (where in the memory map the function lives):\n"
            "    : banked                 Force into a bank page (banked targets only;\n"
            "                             incompatible with :irq / :vbi)\n"
            "    : main                   Force into the main (always-visible) region\n"
            "    : shadow                 Force into shadow RAM under the OS ROM\n"
            "                             (only on a layout that declares one; no\n"
            "                             current layout does)\n"
            "  Shadow-target helpers:\n"
            "    : needsOS                Wrap body with ROM enable/disable on shadow\n"
            "                             targets (no-op on non-shadow)\n"
            "                             (all annotations are case-insensitive)\n"
            "\n"
            "Output format:\n"
            "  On a NATIVE target (arm64 / x86_64 / win64 / arm9) the output is a\n"
            "  runnable executable unless the -o path ends in .s (assembly) or .o\n"
            "  (object); --emit-lib gives a shared library instead.\n"
            "  On 6502 and m68k the -o extension picks the container:\n"
            "    .asm                     assembly source (stops before the assembler)\n"
            "    .xex .exe .bin .com      Atari XEX binary (6502)\n"
            "    .tos .prg                GEMDOS executable (m68k)\n"
            "\n"
            "Support tree search order. Each root below is probed for lib/xc, then\n"
            "xc, then support/ — so an install and a source checkout both work:\n"
            "    -H  >  $XCC_HOME  >  $XTC_HOME\n"
            "        >  <the directory holding xcc>  and its parent\n"
            "        >  cwd  >  ~/xcc  >  ~/xtc\n"
            "        >  /opt/xcc/<version>  >  /opt/xcc  >  /usr/local/xcc\n"
            "        >  /usr/local/xtc  >  /opt/xtc\n"
            "  The binary-relative step is the one that matters: an installed xcc\n"
            "  finds its own libraries with no flags and no environment. -V prints\n"
            "  which root actually won.\n"
            "\n"
            "Environment variables (set to any non-empty value to enable):\n"
            "  XCC_HOME                   Override the support-tree search. Honoured\n"
            "                             ahead of the binary-relative and system\n"
            "                             paths; -H overrides it in turn.\n"
            "  XTC_HOME                   Legacy spelling of XCC_HOME, still read.\n"
            "  XTC_LDFLAGS                Extra arguments appended to the native link.\n"
            "  XTC_DEBUG_STATIC_FRAME     Dump every function's static-frame\n"
            "                             eligibility verdict and the reason if\n"
            "                             it fell back to the xtc-stack path\n"
            "                             (external / address-taken / recursive).\n"
            "  XTC_DEBUG_SPILL            Dump the two-pass main-overflow retry\n"
            "                             — pre-emit estimate vs budget per pass,\n"
            "                             demote candidates with size and call\n"
            "                             counts, and which got picked each\n"
            "                             retry iteration.\n"
            "  XTC_DEBUG_CLOAK_INFER      Dump every function/method's cloak-\n"
            "                             safety verdict from sema's inference\n"
            "                             pass, plus a SAFE/unsafe summary count.\n"
            "                             Useful for debugging why a method\n"
            "                             didn't auto-cloak under -fauto-cloak.\n");
    }

@end
