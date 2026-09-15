#import <Foundation/Foundation.h>
#import "XTMemoryModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTCommandLineOptions : NSObject

@property(nonatomic, readonly) NSArray<NSString*>* inputFiles;
@property(nonatomic, readonly) NSArray<NSString*>* includePaths;
@property(nonatomic, readonly) NSArray<NSString*>* libraryPaths; // -L: shared-lib metadata import search dirs
// How many of `libraryPaths` came from EXPLICIT -L flags at parse time. Paths
// appended later (the vendored arm9 sysroot, the win64 mingw dir) are search
// DEFAULTS, and the third-party tree slots between the two: an explicit -L
// wins over /opt/xcc/3p, which wins over the defaults — so a stale sysroot
// copy of a library cannot shadow its 3p deployment, while the user keeps
// ultimate control. private:docs/Design/third-party-libraries.md.
@property(nonatomic, readonly) NSUInteger explicitLibraryPathCount;
@property(nonatomic, readonly) NSArray<NSString*>* linkerArgs; // -l/-framework/-Xlinker/-Wl passthrough to the native link (clang)
@property(nonatomic, readonly) NSString* targetName;           // "xl", "xt", "xe", alias name
@property(nonatomic, readonly) XTMemoryModel* memoryModel;     // parsed form of targetName
@property(nonatomic, readonly, nullable) NSString* outputPath;
@property(nonatomic, readonly) NSDictionary<NSString*, NSString*>* defines; // -D key=value
@property(nonatomic, readonly) NSInteger optimisationLevel;                 // 0=none, 1=-O, 2=-O2, 3=-O3
@property(nonatomic, readonly) BOOL useXtcStack;                            // --xtc-stack: use software stack globally
@property(nonatomic, readonly, nullable) NSString* preprocessedOutputPath;  // -E / --preprocessed
@property(nonatomic, readonly) BOOL quiet;                                  // -q / --quiet
// -fbounds-check: a CHECKED build. Every subscript gets a runtime bounds
// check that reports and aborts. Debug-only — never shipped enabled.
@property(nonatomic, readwrite) BOOL boundsCheck;
@property(nonatomic, readonly) BOOL emitLib; // --emit-lib: build a shared library (export public class API, keep it all, no app main)
// --emit-iface: write the module INTERFACE and stop — no codegen, no link.
// The designer (Rocks) lists a class's outlets and actions to draw the wiring
// UI, and its input is an APP source, not a library; without this the only way
// to get an iface was to build one as a library, which changes vtable slot
// numbering and so describes a different program.
@property(nonatomic, readonly) BOOL emitIface;
@property(nonatomic, readonly) BOOL emitApk; // --emit-apk: -A android — package a NativeActivity APK, not a bare ELF
// --with-dex: a prebuilt classes.dex to store in the APK. The Android UI
// driver's whole Java footprint is one committed ~900-byte dex, built once by a
// maintainer — the same relationship the Objective-C compiler has to this one.
@property(nonatomic, readonly, nullable) NSString* withDex;
// --with-lib: an extra prebuilt .so to store beside the payload in the APK's
// lib/arm64-v8a/ (uxkit/032). The Android UI driver ships a two-lib
// arrangement: the NDK-built shim runs first and dlopens the xcc payload.
@property(nonatomic, readonly, nullable) NSString* withLib;
// --lib-name: the manifest's `android.app.lib_name`, i.e. WHICH of the packaged
// libraries the system loads. Defaults to the payload, which is right for a
// single-lib package and wrong for the driver's.
@property(nonatomic, readonly, nullable) NSString* libName;
// --needed: extra DT_NEEDED sonames for the emitted android ELF. bionic
// resolves a library's imports against its own local group plus the global
// group, and does NOT honour RTLD_GLOBAL promotion of an already-loaded
// library — so the payload has to NAME the shim rather than rely on it being
// loaded first. This is what retires the post-link addneeded.py.
@property(nonatomic, readonly) NSArray<NSString*>* neededSonames;
@property(nonatomic, readonly) BOOL selfHost;                // --self-host: arm64 exe via the in-house assembler+linker+signer (no clang)
@property(nonatomic, readonly) BOOL noSelfHost;              // --no-self-host: force the clang path even if --self-host (or a future default-on) is set
@property(nonatomic, readonly) BOOL verbose;                 // -V / --verbose: print resolved xtc home + include search paths to stderr
@property(nonatomic, readonly, nullable) NSString* xtcHome;  // -H / --xtc-home
@property(nonatomic, readonly) NSUInteger maxLeafInlineSize; // --fn-leaf-inline (default 100)
@property(nonatomic, readonly) NSUInteger loopUnrollMax;     // -Flu / --fn-loop-unroll (default 0 = off)
/****************************************************************************\
|* Minimum size (in 6502 instructions) for a function to be banked when
|* the target supports banking. Banked functions cost a `_xcall`
|* trampoline (~30 cycles, ~5 bytes per call site), so very small
|* functions are cheaper kept in main RAM. Anything emitting fewer
|* than this many instructions is auto-pinned to `:main` even on a
|* banked target. Override with `-Fmb <n>` / `--fn-min-banked <n>`.
|* Default 0 (threshold off). A higher value (e.g. 50) trades main-
|* RAM space for fewer trampoline calls; values around 100 may
|* overflow the 8 KB main region on programs with many small banked
|* functions, until smart overflow-aware demotion lands.
\****************************************************************************/
@property(nonatomic, readonly) NSUInteger fnMinBanked; // -Fmb / --fn-min-banked (default 0 = off)
@property(nonatomic, readonly) BOOL assembleOnly;      // -a / --assemble-only: no header/footer/runtime
// -c: compile to a RELOCATABLE OBJECT and stop, as C does. Distinct from
// --assemble-only, which emits .asm TEXT: this produces a real .o whose
// unresolved references are relocations for a later link.
// private:docs/Design/separate-compilation.md stage 1.
@property(nonatomic, readonly) BOOL compileOnly;
// -flto: at a link of objects, recompile from their carried IR as ONE module,
// so the inliner and cross-function DCE see across object boundaries again.
// private:docs/Design/separate-compilation.md stage 5.
@property(nonatomic, readonly) BOOL lto;
@property(nonatomic, readonly) BOOL dumpLayout; // -dl / --dump-layout: print memory-map diagram and exit
/****************************************************************************\
|* When YES, after codegen completes the driver prints a per-segment
|* usage summary to stderr — every region/bank declared by the active
|* layout, with bytes-used / bytes-available. Used banks list their
|* current consumption; unused banks (heap pool, code-bank pool) are
|* collapsed into ranges. Helps the user scope what's available for
|* more code without having to mentally cross-reference the layout
|* file with the placement dump. Off by default; compile proceeds
|* normally either way.
\****************************************************************************/
@property(nonatomic, readonly) BOOL dumpUsage; // -du / --dump-usage
/****************************************************************************\
|* When YES, after codegen completes the driver prints a placement
|* summary to stderr — every function and method grouped by its final
|* placement (`:main` / `:banked` page N / `:shadow` / `:cloaked` /
|* `:irq` / `:vbi`), with byte sizes from the page tracker. Used for
|* debugging the overflow-driven banked-spill heuristic and for
|* answering "where did this function actually land?" questions.
|* Off by default. Compile proceeds normally — the flag only adds
|* the diagnostic output.
\****************************************************************************/
@property(nonatomic, readonly) BOOL dumpPlacement; // -dp / --dump-placement

/****************************************************************************\
|* Auto-cloak mode (`-fauto-cloak=never|auto|always`). Controls how the
|* codegen handles sema's inferred-cloak-safe set on xe-family targets.
|*  - "never"  — ignore the inference; decls only become :cloaked when
|*                the user annotates them. Preserves pre-feature
|*                behaviour byte-for-byte.
|*  - "auto"   — only promote inferred-safe decls when the two-pass
|*                main-overflow detection runs out of AST demote
|*                candidates. Pays the per-call cloaked-bracket overhead
|*                only on programs that genuinely need the relief.
|*                (Default.)
|*  - "always" — promote every inferred-safe decl up front. Maximum
|*                main-RAM relief; per-callsite bracket cost is paid on
|*                every call regardless of whether main was tight.
|*
|* Flat targets (xl-family) ignore the flag — they have no cloaked
|* segment to promote into.
\****************************************************************************/
@property(nonatomic, readonly) NSString* autoCloakMode; // never|auto|always
@property(nonatomic, readonly) BOOL quitLoop;           // -Q loop: infinite loop after main (default: RTS)
/****************************************************************************\
|* Heap allocator selection. "bump" or "heap". Default resolves to "heap"
|* on targets that support the free-list allocator (currently xl-shadow and
|* xe-nobank — both flat non-banked 64 KB layouts with a dedicated heap
|* region), and "bump" everywhere else. Explicit -falloc=heap on an
|* unsupported target is a driver error.
\****************************************************************************/
@property(nonatomic, readonly) NSString* allocator;

/****************************************************************************\
|* Which host malloc backs `_xtc_alloc` on a HOSTED target: "system" (default)
|* or "mimalloc". Orthogonal to `allocator` above, which picks the xtc-level
|* strategy (bump vs free-list) — this one only decides whose malloc/free the
|* runtime's calloc resolves to at link time, so it is meaningless on the
|* freestanding targets and rejected there.
\****************************************************************************/
@property(nonatomic, readonly) NSString* hostMalloc;
/****************************************************************************\
|* Automatic Reference Counting gate (`-farc` / `-farc=off|no|0`).
|* When enabled (the default), the `retain` and `release` statements are
|* accepted by the front end and lower to the refcount helpers in
|* retain.asm. When disabled, both become compile errors so programs
|* that were written against pre-ARC semantics don't silently pick up
|* refcount behaviour. `delete` is unaffected — it remains the explicit
|* "release once, free if last" operation regardless of the flag.
|*
|* Phase 0 of ARC (the runtime + manual retain/release) is all this
|* flag currently gates; later phases (compiler-inserted retain/release
|* at scope exit, assignment, etc.) will key off the same bit.
\****************************************************************************/
/****************************************************************************\
|* Link-time dead-code-elimination trace (`-fdce-trace`). When YES the
|* post-merge reachability pass appends a human-readable summary of the
|* call graph it built to the output .asm (PR2 of the post-merge
|* reachability track — see doc/Issues). Off by default; exists so
|* developers debugging DCE correctness can see what the trimmer sees
|* without running a separate analysis tool.
\****************************************************************************/
@property(nonatomic, readonly) BOOL dceTrace;
/****************************************************************************\
|* Thread-safe (atomic) ARC — `-fthread-safe-arc` / `-fno-thread-safe-arc`.
|*
|* Two threads retaining or releasing the same object race on its refcount and
|* either leak it or free it while live (private:docs/Design/threading.md §4.1). The
|* backends fix that by emitting the refcount update as an atomic
|* read-modify-write, which costs measurably more on a hot path — so it is on
|* only when it has to be.
|*
|* -1 (the default) leaves the decision to the code generator, which turns it on
|* exactly when the module spawns a thread; 1 and 0 force it either way. Forcing
|* it ON is for a program that receives objects from a thread it did not itself
|* create (a library, say); forcing it OFF is a measurement tool, not a
|* correctness option.
\****************************************************************************/
@property(nonatomic, readonly) NSInteger threadSafeARC;
// --migrate=<base>:<to> — compile as if the library were still <base>:
// members annotated since(<v>) with v > base disappear from lookup, so a
// <base>-era program fails LOUDLY at every renamed/repurposed call site
// (String 0.4: charAt changed meaning) instead of silently changing
// behaviour. nil when off.
@property(nonatomic, readonly, nullable) NSString* migrateVersions;
@property(nonatomic, readonly) BOOL emitIR;        // --emit-ir: dump IR lowering to stderr
@property(nonatomic, readonly) BOOL emitIROpt;     // --emit-ir-opt: dump IR after optimisation to stderr
@property(nonatomic, readonly) BOOL emitAsmFromIR; // --emit-asm-from-ir: replace codegen with IR→asm pipeline
/****************************************************************************\
|* Stack ceiling in bytes (`--stack-size=<n>`). Used on flat-heap targets
|* to reclaim the space between the xtc software stack and the layout-
|* declared heap start. When nonzero the codegen emits
|*   stack_top = stack_low + stackSize
|*   heap_low  = stack_top
|* so the heap grows from right after the bounded stack up to the top of
|* usable RAM. Default 0 means "use the layout's fixed heapLow" (current
|* behaviour — stack expands up to the code-region boundary with the
|* excess between stack usage and that boundary left unused).
\****************************************************************************/
@property(nonatomic, readonly) NSUInteger stackSize;
/****************************************************************************\
|* Warning-category names the user asked to silence via `-Wno-<name>`.
|* The driver feeds these into the diagnostic engine after it's
|* constructed. Category names are the short kebab-case identifiers
|* defined in XTDiagnosticEngine.h.
\****************************************************************************/
@property(nonatomic, readonly) NSArray<NSString*>* suppressedWarnings;
// Target-specific options: `-x-<arch>,<opt>[,<opt>...]` (e.g.
// -x-wasm32,return-call). Keyed by arch name; the VALUE is the option list.
// The driver validates the arch's registry and forwards the raw flag to the
// matching xcc-cg-<arch> subprocess verbatim; options for a DIFFERENT arch
// than the one being compiled are accepted and ignored (build scripts pass
// one flag set across multi-target builds).
@property(nonatomic, readonly) NSDictionary<NSString*, NSArray<NSString*>*>* targetOptions;

/****************************************************************************\
|* When YES, the compiler emits via the new IR pipeline (parse → sema →
|* IR-lower → verify → backend) instead of the legacy AST codegen. Set by
|* `-fnew-ir` / `--with-ir`. Currently the only path that's actually wired
|* up in the driver — the legacy codegen is preserved as
|* XTCompilerDriver.m.old-codegen and not compiled in.
\****************************************************************************/
@property(nonatomic, readonly) BOOL useNewIR;

/****************************************************************************\
|* When YES, the backend is the host arm64 emitter (XTArm64Backend);
|* otherwise the xt6502 backend is used. Selected by `-m arm64`. arm64
|* mode doesn't load a memory model — `memoryModel` stays at its default.
\****************************************************************************/
@property(nonatomic, readonly) BOOL useArm64Backend;
@property(nonatomic, readonly) BOOL useArm9Backend;   // -A arm9 — ARMv7-A / AArch32 (Zynq Cortex-A9)
@property(nonatomic, readonly) BOOL useX86_64Backend; // -A x86_64 — x86-64 Linux (System V AMD64, musl)
@property(nonatomic, readonly) BOOL useWin64Backend;  // -A win64 — x86-64 Windows (Win64 ABI, mingw PE)
@property(nonatomic, readonly) BOOL useWasm32Backend; // -A wasm32 — WebAssembly (Node.js / browser, JS env host)

/****************************************************************************\
|* Which Apple platform an arm64 build targets: nil (macOS, the default),
|* @"ios", or @"ios-sim". Selected by `-A ios` / `-A ios-sim` — the SAME
|* arm64 backend and IR pipeline, differing only in the Mach-O platform
|* stamp (LC_BUILD_VERSION) and which SDK's .tbd stubs resolve system
|* libraries. docs/mobile/iOS.md Stage 0.
\****************************************************************************/
@property(nonatomic, readonly, nullable) NSString* applePlatform;

/****************************************************************************\
|* Android (aarch64 / bionic). Selected by `-A android` — the SAME arm64
|* backend and IR pipeline as macOS, but the Mach-O asm is rewritten to ELF
|* and the link goes through the NDK's aarch64-linux-android clang against
|* bionic, producing a runnable ELF PIE for the emulator/device.
\****************************************************************************/
@property(nonatomic, readwrite) BOOL androidTarget;

/****************************************************************************\
|* Developer code signing (docs/mobile/signing.md). When signIdentityPath is
|* set, the driver runs xcc-sign as a last stage over the finished Mach-O,
|* replacing the default ad-hoc signature with a developer one from that PEM
|* identity bundle. signEntitlementsPath is an optional entitlements plist.
\****************************************************************************/
@property(nonatomic, readonly, nullable) NSString* signIdentityPath;
@property(nonatomic, readonly, nullable) NSString* signEntitlementsPath;

/****************************************************************************\
|* When YES, the backend is the Atari ST 68k emitter (XTM68kBackend),
|* selected by `-A m68k` / `-A 68000` / `-A 68030`. `m68kCpu` records the
|* CPU variant (68000 default, 68030) so the backend can lower 32-bit
|* MUL/DIV natively on the 030. Like arm64, m68k mode doesn't load a 6502
|* memory model.
\****************************************************************************/
@property(nonatomic, readonly) BOOL useM68kBackend;
@property(nonatomic, readonly) NSInteger m68kCpu;

/****************************************************************************\
|* m68k float strategy. NO by default → soft-float (standard ST, runs on a
|* base 68000 with no FPU). `-mhard-float` opts into 68881/68882 FPU
|* instructions (incl. transcendentals → libm) for FPU-equipped machines
|* and the Zynq m68k-JIT target, which maps them onto the A9's native FP.
\****************************************************************************/
@property(nonatomic, readonly) BOOL m68kHardFloat;

/****************************************************************************\
|* `-mpic`: emit the GOT/a5 position-independent model on the 68000 so
|* programs over 32KB work (calls/data through a Global Offset Table
|* addressed by a5, lifting the ±32KB PC-relative limit). Required for MiNT.
|* On 68020+ it's a no-op — 32-bit PC-relative is already unbounded PIC.
\****************************************************************************/
@property(nonatomic, readonly) BOOL m68kPic;

/****************************************************************************\
|* YES when `-m atarist` selected the Atari ST/TT platform: no 6502 memory
|* model (like arm64), libs resolve from support/atarist/, and ARCH_m68k is
|* predefined. The front-end (xtc-fe) is driven with `-m atarist` instead of
|* the old `-m arm64` shim.
\****************************************************************************/
@property(nonatomic, readonly) BOOL m68kPlatform;

/****************************************************************************\
|* Parse argv into options. Returns nil and prints usage on error.
\****************************************************************************/
+ (nullable instancetype)parseArgc:(int)argc argv:(const char* _Nonnull[_Nonnull])argv;

/****************************************************************************\
|* Strip surrounding quotes and normalise backslash separators in an
|* environment-variable path value. Handles the common Windows mistake of
|* SET XTC_HOME="D:\path with spaces" which leaves literal quote characters
|* in the value. Returns nil for nil or empty input.
\****************************************************************************/
+ (nullable NSString*)sanitiseEnvPath:(nullable NSString*)raw;

/****************************************************************************\
|* Try to load a .lnk linker-script for `spec` (file path, layout name, or
|* "<xtcHome>/support/xt6502/layouts/<spec>.lnk"). Returns nil if no match.
|* Exposed so per-arch backend binaries (xtcg-6502 etc.) can resolve `-m`
|* the same way the in-process driver does.
\****************************************************************************/
+ (nullable XTMemoryModel*)tryLoadLinkerScript:(NSString*)spec
                                       xtcHome:(nullable NSString*)xtcHome;

/****************************************************************************\
|* Record argv[0] so the support tree can be found RELATIVE TO THE BINARY.
|* Call once at the top of main. Without it an installed compiler can only
|* find its libraries through a fixed path or -H, which is exactly the
|* "works in the repo, mysteriously not outside it" failure.
\****************************************************************************/
+ (void)setExecutablePath:(nullable const char*)argv0;

/****************************************************************************\
|* Resolve the xcc home directory — the tree CONTAINING the support tree,
|* whatever it is called there (see supportRootForHome:).
\****************************************************************************/
+ (nullable NSString*)resolveXtcHome:(nullable NSString*)explicitHome;

/****************************************************************************\
|* The support tree inside `home`: the directory that holds generic/,
|* arm64/, xt6502/ and friends. Three spellings are accepted, because the
|* installed layout and the development tree do not agree and both have to
|* work from the same binary:
|*
|*   <home>/lib/xc    installed, macOS + Linux   (/opt/xcc/<ver>/lib/xc)
|*   <home>/xc        installed, Windows         (C:\Program Files\xcc\xc)
|*   <home>/support   the source tree, and pre-0.4 installs
|*
|* Returns nil when none of them is there.
\****************************************************************************/
+ (nullable NSString*)supportRootForHome:(nullable NSString*)home;

/****************************************************************************\
|* The resolved support root, or nil. Equivalent to supportRootForHome: of
|* resolveXtcHome:, and the call every consumer should use — appending
|* "support" to a home by hand is what the three-layout rule above exists to
|* stop.
\****************************************************************************/
+ (nullable NSString*)resolveSupportRoot:(nullable NSString*)explicitHome;

/****************************************************************************\
|* Append a -L directory. Used to add the vendored arm9 sysroot so targeting
|* arm9 needs no flag the other targets do not.
\****************************************************************************/
- (void)addLibraryPath:(NSString*)dir;

/****************************************************************************\
|* Print the full usage/help text to stderr.
\****************************************************************************/
- (void)printUsage;

@end

NS_ASSUME_NONNULL_END
