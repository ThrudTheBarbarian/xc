// xcc.xc — the driver, written in xtc.
// =================================================================
//
//   xcc [-A arch] [-O n] [-H home] [-I dir] [-D k=v] <file.xc> -o <out>
//
// The Objective-C `xcc` is a DISPATCHER: it spawns xcc-fe, then xcc-cg-<arch>,
// then a linker, because its stages are separate binaries. This one has no
// stages to spawn — every one of them is already an xtc class in selfhost/ —
// so it runs the whole pipeline IN PROCESS and never forks. That also means it
// needs no process-spawning primitive, which xtc does not have.
//
//   source → Frontend (preproc, lex, parse, sema, lower)
//          → Opt      (the IR pipeline at the target's profile)
//          → back end (asm text)
//          → assembler + writer (a runnable file)
//
// The runtime is PREPENDED as assembly, exactly as the reference driver does
// it: the crt, the generated runtime, and the per-class allocators the program
// needs, all assembled together with the program's own output as one unit.
//
// arm64 (macOS) and android are wired; the other targets are refused by name
// rather than half-attempted, because a driver that silently produces the wrong
// shape is worse than one that says it cannot.

#import "BundleSign.xc"
#import "Exports.xc"
#import "KeyStore.xc"
#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import <Frontend>
#import <IrParse>
#import <OptBase>
#import <LlvmRead>
#import <Opt>
#import "OptDefs.xc"
#import <Arm64>          // the BACK END
#import <Arm64Asm>       // the ASSEMBLER — different class, different dir
#import <SectionBytes>
#import "Arm64AsmDefs.xc"
#import <MachO>
#import "MachODefs.xc"
#import <MachOLink>
#import <MachOObject>
#import <ElfObject>
#import <Tbd>
#import <PeLink>
#import <CoffObject>
#import <CodeSign>
#import <Iface>
#import <ElfArm64>
#import "ElfArm64Defs.xc"
#import <ElfLinkArm64>
#import "ElfLinkArm64Defs.xc"
#import <Apk>
#import <ApkSign>
#import <RsaKeygen>
#import <Layout>
#import <LayoutMap>     // -dl: a layout drawn as a memory map
#import <Target>        // the target table: -A names a row
#import <Xt6502>
#import <Xta>
#import "XtaDefs.xc"
#import <Runtime6502>
#import <Peep6502>
#import "Peep6502Defs.xc"
#import <M68k>            // the m68k BACK END
#import <M68kAsm>         // …and its assembler, which writes the GEMDOS container
#import "M68kAsmDefs.xc"
#import <Wasm32>          // the wasm32 BACK END (emits WAT)
#import <Wasm>            // …and the writer that turns WAT into a .wasm module
#import "WasmDefs.xc"
#import <Arm9>            // the ARMv7-A BACK END
#import <Arm32>           // …its assembler
#import "Arm32Defs.xc"
#import <Elf32>           // …and the ET_DYN writer the XTOS loader takes
#import "Elf32Defs.xc"
#import <X86_64>          // the x86-64 BACK END
#import <X86Link>    // …and the link, shared with xtldx86 so they cannot drift
#import <Elf64>      // …and the ET_REL object writer `-c` needs
#import "Elf64Defs.xc"
#import <Pe>         // the Windows PE/COFF writer, shared with xtldwin
#import "PeDefs.xc"
#import <Language>   // the language table: a source extension names a row
#import <CPath>      // `xcc prog.c`: clang's LLVM IR read into a module (cpp-front-end.md)

// A C program's own output while xcc's part is compiled to an object (the
// C path): set, the object is linked with clang's into it (cSplitLink).
String* gCSplitOut;
// --c-pair (internal: a several-source build on win64, whose COFF link has no
// relocatable form): -c of a C/C++ file writes its two objects, xcc's at the
// output and clang's beside it (<name>.rest.o), for the one link to take both.
bool gCSplitPair;
bool gHalfXcArgs;       // the C path: xcc's half has a par block (--xc-* options, #148)
// -c of a C file: cSplitLink makes one relocatable object, not a program.
bool gCSplitRelocatable;
// The macOS object link's redirections for those objects (linkObjectsArm64).
Map* gMachORedirect;
// A language whose row names a linker (C++: clang++): the program is one
// assembly unit, as --no-self-host's, linked by it with clang's object.
String* gLangLinker;
#import <External>   // --no-self-host: the vendor-toolchain path
#import <Parser>
#import <ArArchive>
#import <Ir>
#import "IrDefs.xc"
#import <X86Asm>
#import "X86AsmDefs.xc"

// ── capability options ───────────────────────────────────────────────────
//
// The flags that change WHAT is built rather than how the driver runs: the
// allocator and host malloc, atomic ARC, position independence, the FPU, the
// m68k CPU, debug info, the Android packaging inputs, and the external
// toolchain. Kept in one class, parsed by parseCapabilityFlag and checked
// against the target by checkCapabilities once the whole line has been read.
class CapOptions
{
    String* _alloc;        // -falloc=bump|heap, or 0 when not given
    String* _malloc;       // -fmalloc=system|mimalloc
    bool    _pic;          // -fpic / -fPIC / -mpic
    bool    _hardFloat;    // -mhard-float / -mfpu (m68k: the 68881); -msoft-float clears it
    bool    _softFloat;    // -msoft-float was the LAST float flag given
    u32     _m68kCpu;      // 68000 | 68030 (-A 68000 / -A 68030)
    bool    _debugInfo;    // -g
    Array*  _needed;       // --needed <soname>, repeatable
    Array* _withLibs;      // --with-lib <path>, each one given
    String* _libName;      // --lib-name <name>
    Array*  _manifestAttrs; // --manifest-attr name=value, repeatable (bug 616)
    String* _withDex;      // --with-dex <path>
    bool    _noSelfHost;   // --no-self-host
    bool    _threadFlag;   // -f[no-]thread-safe-arc was given
    String* _simd;         // the x86-64 vector level: 0 (default), "base", "avx2"
    String* _simdFlag;     // the flag that chose it, for the target check
    bool _dynamic;         // an x86-64 executable linked against glibc: the default
    bool _dynamicExplicit; // -dynamic given
    bool _staticLink;      // -static: the static musl link instead
    bool _rowStatic;       // the last -A named the musl row (merged after parsing)
    bool _noMatmul;           // -fno-matmul: no SME matrix kernels (arm64 macOS)

    void init(void)
    {
        _alloc = (String*)0;
        _malloc = String.withCString("system");
        _pic = false;
        _hardFloat = false;
        _softFloat = false;
        _m68kCpu = (u32)68000;
        _debugInfo = false;
        _needed = new Array();
        _withLibs = new Array();
        _libName = (String*)0;
        _manifestAttrs = new Array();
        _withDex = (String*)0;
        _noSelfHost = false;
        _threadFlag = false;
        _simd = (String*)0;
        _simdFlag = (String*)0;
        _dynamic = false;
        _dynamicExplicit = false;
        _staticLink = false;
        _rowStatic = false;
        _noMatmul = false;
    }

    String* alloc(void)     { return _alloc; }
    String* hostMalloc(void) { return _malloc; }
    bool pic(void)          { return _pic; }
    bool hardFloat(void)    { return _hardFloat; }
    bool softFloat(void)    { return _softFloat; }
    u32  m68kCpu(void)      { return _m68kCpu; }
    bool debugInfo(void)    { return _debugInfo; }
    Array* needed(void)     { return _needed; }
    Array* withLibs(void)   { return _withLibs; }
    String* libName(void)   { return _libName; }
    Array* manifestAttrs(void) { return _manifestAttrs; }
    String* withDex(void)   { return _withDex; }
    bool noSelfHost(void)   { return _noSelfHost; }
    bool threadFlag(void)   { return _threadFlag; }
    String* simd(void)      { return _simd; }
    String* simdFlag(void)  { return _simdFlag; }
    bool dynamic(void)      { return _dynamic; }
    void setDynamic(void)   { _dynamicExplicit = true; }
    bool dynamicExplicit(void) { return _dynamicExplicit; }
    bool staticLink(void)   { return _staticLink; }
    void setStatic(void)    { _staticLink = true; }
    bool rowStatic(void)    { return _rowStatic; }
    void setRowStatic(bool b) { _rowStatic = b; }
    // From 0.73 a library follows the executable's rule (glibc unless -static).
    void resolveDynamic(bool x86) { _dynamic = x86 && !_staticLink; }
    bool noMatmul(void)        { return _noMatmul; }
    void setNoMatmul(void)     { _noMatmul = true; }

    void setAlloc(String* v)     { _alloc = v; }
    void setHostMalloc(String* v) { _malloc = v; }
    void setPic(bool b)          { _pic = b; }
    void setHardFloat(bool b)    { _hardFloat = b; _softFloat = !b; }
    void setM68kCpu(u32 c)       { _m68kCpu = c; }
    void setDebugInfo(bool b)    { _debugInfo = b; }
    void addWithLib(String* p)   { _withLibs.add((Object*)p); }
    void setLibName(String* n)   { _libName = n; }
    void setWithDex(String* p)   { _withDex = p; }
    void setNoSelfHost(bool b)   { _noSelfHost = b; }
    void setThreadFlag(bool b)   { _threadFlag = b; }
    void setSimd(String* level, String* flag) { _simd = level; _simdFlag = flag; }
}

// ── options ──────────────────────────────────────────────────────────────
class DriverOptions
{
    FeOptions* _fe;
    CapOptions* _caps;       // parseCapabilityFlag's options
    String*    _arch;        // arm64 | android
    u32        _opt;
    bool       _keepAsm;     // -S: stop after the back end
    bool       _emitLib;     // --emit-lib: a SHARED LIBRARY, not an executable
    bool       _emitRuntime; // --emit-runtime: libRuntime itself (an --emit-lib build of Runtime.list's files)
    bool       _runtimeSupport; // --emit-runtime-support: libRuntimeSupport, the same with its standard library (#278)
    bool       _noRuntimeLib; // --no-runtime-lib: compile the runtime's files in, as source
    bool       _noXcArgs;    // -fno-xc-args: the start code passes every argument through
    // --bundle <dir> (bundles-and-plugins.md §2): the library goes into a
    // signed bundle there; name, version, resources, key and publisher.
    String*    _bundleDir;
    String*    _bundleName;
    String*    _bundleVersion;
    String*    _bundleResources;
    String*    _bundleKey;
    String*    _publisher;
    String*    _publisherDomain;
    String*    _trusted;          // --trust key.pub...: the only publishers Plugin.load accepts
    String*    _rotateFrom;       // --rotate-from <old key>: hand the bundle over to the new key
    Array*     _bundleLibs;       // --bundle-lib <file>: a library the code needs, shipped beside it
    bool       _noSign;           // --no-sign: lay the bundle out unsigned, for --sign-bundle elsewhere
    String*    _signBundle;       // --sign-bundle <dir>: sign a bundle laid out elsewhere, and nothing else
    Map*       _bundleReadonly;   // --property k=v: the publisher's, final
    Map*       _bundleWriteable;  // --setting k=v: a default a user may change
    bool       _emitIfaceOnly;  // --emit-iface: the interface, and nothing else
    bool       _compileOnly;    // -c: an OBJECT, plus its build-artifact sidecars
    Array*     _linkInputs;     // -Xlinker <path> / -l<name>: libraries to load
    Array*     _frameworks;     // -framework <F>
    Array*     _objectInputs;   // `a.o` / `lib.a` named as INPUTS: the link step (bug 138)
    bool       _lto;            // -flto: recompile the objects' carried IR as one module (139)
    String*    _signIdentity;   // --sign <identity.pem>: developer-sign the Mach-O (144)
    String*    _signEntitlements; // --sign-entitlements <plist>
    String*    _irText;         // …one of which is the module's own IR
    bool       _emitApk;     // --emit-apk: package an installable APK
    bool       _quiet;       // -q: errors only
    i32        _unroll;      // -Flu <n>, or -1 for the target's own cap
    String*    _signKey;     // --sign-key: the raw debug key both drivers share
    bool       _sawArch;        // -A / --arch was given
    TargetRow* _targetRow;      // the row -A named (or the host's), private:docs/Design/targets.md
    bool       _printTarget;    // --print-target: print the row and stop
    bool       _print3pDir;     // --print-3p-dir: print the own third-party tree and stop
    String*    _layoutSpec;     // -m <layout>: as typed, resolved after the parse
    String*    _layoutPath;     // …the .lnk it resolved to
    String*    _layoutName;     // …and the model's name (the file's stem)
    bool       _dumpLayout;     // -dl: print the layout's memory map and stop
    bool       _listLayouts;    // -ll: list the built-in layouts and stop
    bool       _emitIR;         // --emit-ir: the lowered IR to stderr
    bool       _emitIROpt;      // --emit-ir-opt: the optimised IR to stderr
    bool       _tailCalls;      // -x-wasm32,return-call
    bool       _linkLibs;       // --link-libs: a wasm32 app that links .wasm libraries
    u32        _stackSize;      // -ss / --stack-size: the wasm32 shadow stack, 0 = default
    Array*     _rawLinkFlags;   // linker FLAGS from -Xlinker / -Wl, / $XTC_LDFLAGS
    Array*     _rpaths;         // -rpath <dir>: extra LC_RPATH entries (Mach-O)
    bool       _rpathPending;   // the last flag was -rpath; its directory comes next
    Array*     _ldDirs;         // -L<dir> from $XTC_LDFLAGS: -l search, link only
    i32        _inlineMax;      // -Fli <n>, or -1 for the inliner's own ceiling
    bool       _dceTrace;       // -fdce-trace
    bool       _quitLoop;       // -Q loop: an xt6502 program spins after main
    bool       _xtcStack;       // --xtc-stack: the xt6502 software-stack convention
    u32        _fnMinBanked;    // -Fmb <n>: keep smaller 6502 functions unbanked
    bool       _dumpPlacement;  // -dp: print each 6502 function's placement
    bool       _dumpUsage;      // -du: print the 6502 image's use of the layout

    void init(void)
    {
        _fe = new FeOptions();
        _caps = new CapOptions();
        // The default target is the HOST — the arch this compiler was itself
        // compiled for — so `xcc -o prog prog.xc` builds a native binary the
        // way cc does, on every host. This was a literal "arm64", which is
        // invisibly correct on a Mac and wrong everywhere else: the x86_64
        // build of this compiler, running on Linux, emitted a Mach-O arm64
        // binary for a bare `xcc -o prog prog.xc` and the user got
        // "Exec format error". `ARCH_<arch>` is predefined by the compiler
        // building this file, so the answer is known here with no host probe.
        //
        // ORDER MATTERS: `-A win64` predefines OS_windows AND ARCH_x86_64,
        // because win64 IS x86-64 — it is the same architecture with a
        // different container and ABI. Testing x86_64 first made the Windows
        // compiler default to emitting Linux ELFs. The more specific platform
        // is therefore tested first, and this is the general rule for any
        // future host that shares an arch with another.
#if OS_windows
        _arch = String.withCString("win64");
#elif ARCH_x86_64
        _arch = String.withCString("x86_64");
#elif ARCH_armv7
        _arch = String.withCString("arm9");
#elif OS_linux
        // A Raspberry Pi and the other arm64 Linux machines: their own row.
        _arch = String.withCString("arm64-linux");
#else
        _arch = String.withCString("arm64");
#endif
        _opt = (u32)3;
        _keepAsm = false;
        _emitLib = false;
        _emitIfaceOnly = false;
        _compileOnly = false;
        _irText = (String*)0;
        _linkInputs = new Array();
        _frameworks = new Array();
        _objectInputs = new Array();
        _lto = false;
        _signIdentity = (String*)0; _signEntitlements = (String*)0;
        _emitApk = false;
        _quiet = false;
        _unroll = (i32)-1;
        _signKey = String.withCString("");
        _sawArch = false;
        _targetRow = (TargetRow*)0;
        _printTarget = false;
        _print3pDir = false;
        _layoutSpec = (String*)0;
        _layoutPath = (String*)0;
        _layoutName = (String*)0;
        _dumpLayout = false;
        _listLayouts = false;
        _emitIR = false;
        _emitIROpt = false;
        _tailCalls = false;
        _linkLibs = false;
        _stackSize = (u32)0;
        _rawLinkFlags = new Array();
        _rpaths = new Array();
        _emitRuntime = false;
        _runtimeSupport = false;
        _noRuntimeLib = false;
        _noXcArgs = false;
        _rpathPending = false;
        _ldDirs = new Array();
        _inlineMax = (i32)-1;
        _dceTrace = false;
    }

    FeOptions* fe(void)  { return _fe; }
    CapOptions* caps(void) { return _caps; }
    String* arch(void)   { return _arch; }
    u32 opt(void)        { return _opt; }
    bool keepAsm(void)   { return _keepAsm; }
    bool emitLib(void)   { return _emitLib; }
    String* bundleDir(void) { return _bundleDir; }
    bool emitIfaceOnly(void) { return _emitIfaceOnly; }
    bool compileOnly(void)   { return _compileOnly; }
    bool lto(void)           { return _lto; }
    String* irText(void)     { return _irText; }
    Array* linkInputs(void)  { return _linkInputs; }
    Array* frameworks(void)  { return _frameworks; }
    Array* objectInputs(void) { return _objectInputs; }
    bool emitApk(void)   { return _emitApk; }
    bool quiet(void)     { return _quiet; }
    i32  unroll(void)    { return _unroll; }
    String* signKey(void) { return _signKey; }

    void setArch(String* a) { _arch = a; }
    void setOpt(u32 n)      { _opt = n; }
    void setKeepAsm(bool b) { _keepAsm = b; }
    void setEmitLib(bool b) { _emitLib = b; }
    void setEmitIfaceOnly(bool b) { _emitIfaceOnly = b; }
    void setCompileOnly(bool b) { _compileOnly = b; }
    void setLto(bool b)         { _lto = b; }
    String* signIdentity(void)      { return _signIdentity; }
    String* signEntitlements(void)  { return _signEntitlements; }
    void setSignIdentity(String* p)     { _signIdentity = p; }
    void setSignEntitlements(String* p) { _signEntitlements = p; }
    void setIrText(String* t) { _irText = t; }
    void setEmitApk(bool b)   { _emitApk = b; }
    void setQuiet(bool b)     { _quiet = b; }
    void setUnroll(i32 n)     { _unroll = n; }
    void setSignKey(String* p) { _signKey = p; }

    bool sawArch(void)              { return _sawArch; }
    // The row the options select, -A or not: found from the arch string while
    // it still decides, so the two can never disagree; the -A row is kept when
    // it is that row (68030).
    TargetRow* targetRow(void)
        {
        // x86-64 Linux: -static is the musl row, whatever -A spelt.
        if (_arch.equals(String.withCString("x86_64")))
            return Targets.find(String.withCString(_caps.staticLink() ? "x86_64-linux-musl" : "x86_64-linux"));
        if (_targetRow != (TargetRow*)0 && _targetRow.legacy().equals(_arch))
            return _targetRow;
        return Targets.find(_arch);
        }
    void setTargetRow(TargetRow* r) { _targetRow = r; }
    bool printTarget(void)          { return _printTarget; }
    void setPrintTarget(bool b)     { _printTarget = b; }
    bool print3pDir(void)           { return _print3pDir; }
    void setPrint3pDir(bool b)      { _print3pDir = b; }
    void setSawArch(bool b)         { _sawArch = b; }
    String* layoutSpec(void)        { return _layoutSpec; }
    void setLayoutSpec(String* s)   { _layoutSpec = s; }
    String* layoutPath(void)        { return _layoutPath; }
    void setLayoutPath(String* p)   { _layoutPath = p; }
    String* layoutName(void)        { return _layoutName; }
    void setLayoutName(String* n)   { _layoutName = n; }
    bool dumpLayout(void)           { return _dumpLayout; }
    void setDumpLayout(bool b)      { _dumpLayout = b; }
    bool listLayouts(void)          { return _listLayouts; }
    void setListLayouts(bool b)     { _listLayouts = b; }
    bool emitIR(void)               { return _emitIR; }
    void setEmitIR(bool b)          { _emitIR = b; }
    bool emitIROpt(void)            { return _emitIROpt; }
    void setEmitIROpt(bool b)       { _emitIROpt = b; }
    bool tailCalls(void)            { return _tailCalls; }
    void setTailCalls(bool b)       { _tailCalls = b; }
    bool linkLibs(void)             { return _linkLibs; }
    void setLinkLibs(bool b)        { _linkLibs = b; }
    u32 stackSize(void)             { return _stackSize; }
    void setStackSize(u32 n)        { _stackSize = n; }
    Array* rawLinkFlags(void)       { return _rawLinkFlags; }
    Array* rpaths(void)             { return _rpaths; }
    bool emitRuntime(void)          { return _emitRuntime; }
    bool runtimeSupport(void)       { return _runtimeSupport; }
    bool noRuntimeLib(void)         { return _noRuntimeLib; }
    bool noXcArgs(void)             { return _noXcArgs; }
    Array* ldDirs(void)             { return _ldDirs; }
    i32 inlineMax(void)             { return _inlineMax; }
    void setInlineMax(i32 n)        { _inlineMax = n; }
    bool dceTrace(void)             { return _dceTrace; }
    void setDceTrace(bool b)        { _dceTrace = b; }
    bool quitLoop(void)             { return _quitLoop; }
    void setQuitLoop(bool b)        { _quitLoop = b; }
    bool xtcStack(void)             { return _xtcStack; }
    void setXtcStack(bool b)        { _xtcStack = b; }
    u32  fnMinBanked(void)          { return _fnMinBanked; }
    void setFnMinBanked(u32 n)      { _fnMinBanked = n; }
    bool dumpPlacement(void)        { return _dumpPlacement; }
    void setDumpPlacement(bool b)   { _dumpPlacement = b; }
    bool dumpUsage(void)            { return _dumpUsage; }
    void setDumpUsage(bool b)       { _dumpUsage = b; }

    // One token addressed to the LINKER — from -Xlinker, a -Wl, list or
    // $XTC_LDFLAGS. A library or object is a link input, `-rpath <dir>` is
    // recorded for the Mach-O writer, and any other flag is kept to be
    // reported at link time: the linker here is in-house, so a flag it does
    // not implement is named and skipped, as the in-house arm64 linker does,
    // rather than silently dropped or handed to a system linker.
    void addLinkToken(String* t)
    {
        if (t == (String*)0 || t.byteLength() == (u32)0) return;
        if (_rpathPending) {
            _rpathPending = false;
            bool seen = false;
            for (u32 i = (u32)0; i < _rpaths.count(); i = i + (u32)1)
                if (((String*)_rpaths.get(i)).equals(t)) seen = true;
            if (!seen && !t.equals(String.withCString("@loader_path"))) _rpaths.add((Object*)t);
            return;
        }
        if (t.equals(String.withCString("-rpath"))) { _rpathPending = true; return; }
        if (t.hasPrefix(String.withCString("-l")) && t.byteLength() > (u32)2) {
            _linkInputs.add((Object*)t);
            return;
        }
        if (t.hasPrefix(String.withCString("-L")) && t.byteLength() > (u32)2) {
            _ldDirs.add((Object*)t.substringFromByte((u32)2));
            return;
        }
        if (t.hasPrefix(String.withCString("-"))) { _rawLinkFlags.add((Object*)t); return; }
        _linkInputs.add((Object*)t);
    }
}

// Whether a program's link takes objects or archives besides its own module
// (-Wl,foo.o, -Xlinker libbar.a, a path in $XTC_LDFLAGS). Their code may call
// the class-name root `_xtc_class_new`, which then has to survive dead-function
// elimination although nothing in this module calls it (bug 605).
bool linkJoinsObjects(DriverOptions* d)
{
    Array* li = d.linkInputs();
    for (u32 i = (u32)0; i < li.count(); i = i + (u32)1) {
        String* t = (String*)li.get(i);
        if (t.hasPrefix(String.withCString("-"))) continue;
        if (t.hasSuffix(String.withCString(".o")) || t.hasSuffix(String.withCString(".a"))) return true;
    }
    return false;
}

// The target predicates read the target row, never the arch string (#332):
// every spelling -A or -m takes (atarist, xt, wasm, ...) resolves to its row,
// and a token no row has answers false everywhere, as before.
bool rowOs(DriverOptions* d, string os)
{
    TargetRow* r = d.targetRow();
    return r != (TargetRow*)0 && r.os().equals(String.withCString(os));
}
bool rowCpu(DriverOptions* d, string cpu)
{
    TargetRow* r = d.targetRow();
    return r != (TargetRow*)0 && r.cpu().equals(String.withCString(cpu));
}
bool isAndroid(DriverOptions* d) { return rowOs(d, "android"); }
bool isWasm(DriverOptions* d) { return rowCpu(d, "wasm32"); }
// x86-64 Linux, glibc or musl; Windows is isWin64.
bool isX86_64(DriverOptions* d) { return rowCpu(d, "x86_64") && rowOs(d, "linux"); }
bool isWin64(DriverOptions* d) { return rowOs(d, "windows"); }
bool isArm9(DriverOptions* d) { return rowCpu(d, "armv7"); }
// iOS is the ARM64 back end with a Mach-O platform flavour, exactly as android
// is the arm64 back end under different options. Stage 0 of docs/mobile/iOS.md:
// the target spelling, the platform stamp, and libraries resolved from the
// arm64 support tree. `-A ios` is the device, `-A ios-sim` the simulator.
bool isIos(DriverOptions* d) { return rowOs(d, "ios"); }
bool isIosSim(DriverOptions* d) { return isIos(d) && d.targetRow().env() != (String*)0; }
// arm64 macOS: the `arm64` spelling (arm64 Linux is its own row).
bool isMacArm64(DriverOptions* d) { return rowCpu(d, "arm64") && rowOs(d, "macos"); }
bool isM68k(DriverOptions* d) { return rowCpu(d, "m68k"); }
bool isXt6502(DriverOptions* d) { return rowCpu(d, "6502"); }

// The back end's own target name. Android IS the arm64 back end — a different
// ABI and a different link, not a different code generator.
String* backendTargetOf(DriverOptions* d)
{
    // Android IS the arm64 back end under different options; xt6502 is its own.
    // The target table's platform key for the row (step 2); an arch no row has
    // keeps the arm64 fallback it always had.
    TargetRow* row = d.targetRow();
    if (row != (TargetRow*)0) return row.backend();
    if (isXt6502(d)) return String.withCString("xt6502");
    if (isX86_64(d)) return String.withCString("x86_64");
    if (isArm9(d))   return String.withCString("arm9");
    if (isM68k(d))   return String.withCString("atarist");
    if (isWasm(d))   return String.withCString("wasm32");
    // iOS uses the arm64 back end AND the arm64 support tree — stage 0 ships no
    // support/ios layer, so saying "arm64" here is the truth, not a fallthrough.
    if (isIos(d))    return String.withCString("arm64");
    // win64 is its own PLATFORM even though it is the x86-64 back end: it
    // resolves libraries from support/win64 then support/x86_64, and getting
    // this wrong is silent. Falling through to arm64 here compiled a Windows
    // program against the ARM64 library, whose `_putc` is declared extern for
    // a runtime that is not in the image — so the failure surfaced at the LINK,
    // naming `_putc`, with nothing pointing at the platform choice that caused
    // it. Same shape as bug 083.
    if (isWin64(d))
        return String.withCString("win64");
    return String.withCString("arm64");
}

bool identByte(u8 c)
{
    return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z')
        || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_' || c == (u8)'$';
}

bool identStartByte(u8 c)
{
    return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z')
        || c == (u8)'_' || c == (u8)'$';
}

// String has no "find from offset", and the alloc-stub scan needs one.
u32 findFrom(String* hay, String* needle, u32 from)
{
    if (needle.byteLength() == (u32)0) return String.notFound();
    u32 last = hay.byteLength();
    if (needle.byteLength() > last) return String.notFound();
    for (u32 i = from; i + needle.byteLength() <= last; i = i + (u32)1) {
        bool hit = true;
        for (u32 j = (u32)0; j < needle.byteLength(); j = j + (u32)1)
            if (hay.byteAt(i + j) != needle.byteAt(j)) { hit = false; break; }
        if (hit) return i;
    }
    return String.notFound();
}

// ── the runtime, as assembly ─────────────────────────────────────────────
//
// `new Class` lowers to a call to `_xtc_new_<Class>`, which is per-PROGRAM (it
// has to know that class's destructor), so it cannot live in the shipped
// runtime. Each stub is a three-instruction tail call.
//
// The names emitted here are ALWAYS the Mach-O flavour, as the reference's
// arm64ClassAllocStubs does. An ELF target converts the whole unit once via
// stripLeadingUnderscore, and the stubs go through that pass with everything
// else — so spelling them the ELF way here strips a SECOND underscore and
// defines `xtc_alloc` against a program that calls `_xtc_alloc` (bug 123).
String* classAllocStubs(String* prog)
{
    String* out = new String();
    if (prog == 0) return out;
    String* u = String.withCString("__xtc_new_");
    Array* seen = new Array();
    u32 i = (u32)0;
    while (true) {
        u32 at = findFrom(prog, u, i);
        if (at == String.notFound()) break;
        u32 s = at + u.byteLength();
        u32 e = s;
        while (e < prog.byteLength() && identByte(prog.byteAt(e))) e = e + (u32)1;
        i = e;
        String* cls = prog.substringBytes(s, e - s);
        if (isPrimitiveName(cls)) continue;
        bool dup = false;
        for (u32 k = (u32)0; k < seen.count(); k = k + (u32)1)
            if (((String*)seen.get(k)).equals(cls)) dup = true;
        if (dup) continue;
        seen.add((Object*)cls);

        String* dealloc = String.withCString("_");
        dealloc.append(cls);
        dealloc.appendCString("$dealloc:");
        bool hasDe = prog.byteIndexOf(dealloc) != String.notFound();

        out.appendCString(".text\n.globl ");
        out.append(u); out.append(cls);
        out.appendCString("\n.align 2\n");
        out.append(u); out.append(cls); out.appendCString(":\n");
        if (hasDe) {
            String* d2 = String.withCString("_");
            d2.append(cls); d2.appendCString("$dealloc");
            out.appendCString("    adrp x2, "); out.append(d2); out.appendCString("@PAGE\n");
            out.appendCString("    add x2, x2, "); out.append(d2); out.appendCString("@PAGEOFF\n");
        } else {
            // No dealloc hook: an array of 64 KB or more is page-aligned and
            // registered (#113; the x86 stub explains). As the reference.
            out.appendCString("    mul x9, x0, x1\n    mov x2, #0\n    lsr x10, x9, #16\n    cbz x10, L");
            out.append(u); out.append(cls); out.appendCString("_small\n    b __xtc_alloc_aligned\nL");
            out.append(u); out.append(cls); out.appendCString("_small:\n");
        }
        out.appendCString("    b ");
        out.appendCString("__xtc_alloc\n");
    }
    return out;
}

// Which element types the RUNTIME already provides a `_xtc_new_<T>(count)`
// for, so no per-program thunk is synthesised. Mirrors the reference's
// XTIRIsPrimitiveElemName, and must: the two decide the allocator CALL SHAPE,
// and the list existed in seven places before bug 233 — one gap in it reached
// three stub generators at once, and a missing entry here instead emits a
// thunk that collides with the runtime's own symbol.
bool isPrimitiveName(String* s)
{
    // `simd_<prim>`: the page-aligned allocator for a `simd:` pointer
    // (par-blocks.md §3), the same one-argument form, provided by every
    // 64-bit runtime beside the plain one — so no per-program thunk either.
    if (s.byteLength() > (u32)5 && s.substringBytes((u32)0, (u32)5).equals(String.withCString("simd_")))
        return isPrimitiveName(s.substringBytes((u32)5, s.byteLength() - (u32)5));
    Array* p = new Array();
    p.add((Object*)String.withCString("u8"));   p.add((Object*)String.withCString("i8"));
    p.add((Object*)String.withCString("u16"));  p.add((Object*)String.withCString("i16"));
    p.add((Object*)String.withCString("u32"));  p.add((Object*)String.withCString("i32"));
    p.add((Object*)String.withCString("u64"));  p.add((Object*)String.withCString("i64"));
    p.add((Object*)String.withCString("pointer")); p.add((Object*)String.withCString("bool"));
    p.add((Object*)String.withCString("float")); p.add((Object*)String.withCString("double"));
    p.add((Object*)String.withCString("string"));
    for (u32 i = (u32)0; i < p.count(); i = i + (u32)1)
        if (((String*)p.get(i)).equals(s)) return true;
    return false;
}

// Android names symbols the ELF way; the back end names them the Mach-O way.
// Exactly ONE leading underscore is the whole difference — C's `_xtc_alloc`
// gains one on Darwin and none on ELF.
String* stripLeadingUnderscore(String* asmText)
{
    String* out = new String();
    Array* lines = asmText.splitOnByte((u8)'\n');
    for (u32 li = (u32)0; li < lines.count(); li = li + (u32)1) {
        String* l = (String*)lines.get(li);
        String* o = new String();
        u32 i = (u32)0;
        while (i < l.byteLength()) {
            u8 c = l.byteAt(i);
            bool atStart = i == (u32)0;
            bool afterSep = !atStart && (l.byteAt(i - (u32)1) == (u8)' '
                                      || l.byteAt(i - (u32)1) == (u8)'\t'
                                      || l.byteAt(i - (u32)1) == (u8)','
                                      || l.byteAt(i - (u32)1) == (u8)'[');
            if (c == (u8)'_' && (atStart || afterSep) && i + (u32)1 < l.byteLength()
                && identStartByte(l.byteAt(i + (u32)1))) {
                i = i + (u32)1;                 // drop exactly one
                continue;
            }
            o.appendByte(c);
            i = i + (u32)1;
        }
        if (li > (u32)0) out.appendByte((u8)'\n');
        out.append(o);
    }
    return out;
}

// Whether an object or archive names a symbol of xcc's runtime: `_xtc_`
// (the allocator, ARC, the classes' helpers) or `__xt_` (the stack guard, the
// threads), with Mach-O's extra underscore or ELF's without; what an xcc -c
// object always does and a C or Objective-C one never does. The bytes are
// searched, not the symbol table: a string that happens to hold the text
// only keeps the runtime the image's own, as before. A file that cannot be
// read counts as one that names it.
bool namesRuntime(String* path)
{
    Data* data = Files.readData(path);
    if (data == (Data*)0) return true;
    u8* b = data.bytes();
    u32 n = data.length();
    for (u32 i = (u32)0; i + (u32)5 <= n; i = i + (u32)1) {
        if (b[i] != (u8)'_') continue;
        if (b[i + (u32)1] == (u8)'x' && b[i + (u32)2] == (u8)'t' && b[i + (u32)3] == (u8)'c' && b[i + (u32)4] == (u8)'_')
            return true;
        if (b[i + (u32)1] == (u8)'_' && b[i + (u32)2] == (u8)'x' && b[i + (u32)3] == (u8)'t' && b[i + (u32)4] == (u8)'_')
            return true;
    }
    return false;
}

// Whether a shared library this link names depends on libRuntime: an xc
// library. A C or C++ program linking one keeps libRuntime, so the process
// has one object runtime, not that library's and libRuntimeSupport's (#278).
bool linksXcLibrary(DriverOptions* d)
{
    Array* li = d.linkInputs();
    for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) {
        String* t = (String*)li.get(i);
        Array* cands = new Array();
        if (t.hasPrefix(String.withCString("-l"))) {
            String* stem = t.substringFromByte((u32)2);
            Array* dirs = new Array();
            for (u32 k = (u32)0; k < d.fe().libs().count(); k = k + (u32)1) dirs.add(d.fe().libs().get(k));
            for (u32 k = (u32)0; k < d.ldDirs().count(); k = k + (u32)1) dirs.add(d.ldDirs().get(k));
            for (u32 k = (u32)0; k < dirs.count(); k = k + (u32)1) {
                cands.add((Object*)String.withFormat("%s/lib%s.dylib", ((String*)dirs.get(k)).cString(), stem.cString()));
                cands.add((Object*)String.withFormat("%s/lib%s.so", ((String*)dirs.get(k)).cString(), stem.cString()));
                cands.add((Object*)String.withFormat("%s/lib%s.dll", ((String*)dirs.get(k)).cString(), stem.cString()));
            }
        } else if (t.hasSuffix(String.withCString(".dylib")) || t.hasSuffix(String.withCString(".dll")) || isSharedLib(t)) {
            cands.add((Object*)t);
        }
        for (u32 k = (u32)0; k < cands.count(); k = k + (u32)1) {
            String* f = (String*)cands.get(k);
            if (!Files.exists(f)) continue;
            Data* data = Files.readData(f);
            if (data != (Data*)0 && String.withBytes(data.bytes(), data.length()).contains(String.withCString("libRuntime.")))
                return true;
        }
    }
    return false;
}

// Whether a linked object took libRuntimeSupport, not libRuntime (#278):
// set while the objects' .deplibs are read (objectLinkDeps).
bool gObjWantRuntimeSupport; // …and it is libRuntimeSupport (#278)

// libRuntime (owner, 2026-11-03): the runtime's files, prebuilt per target
// as one shared library, at <support>/runtime-lib/<row>/libRuntime.<ext>
// (lib/xc/runtime-lib/... in an install). Building it (--emit-runtime): the
// files are Runtime.list's. A program or library: that library, when the
// target has one built and it is wanted — not --no-runtime-lib, not -static
// (no dynamic loader) — imported where the program first imports a file of
// it, and found at run time by the runpath the link writes for any imported
// library (Mach-O: an LC_RPATH to its directory). A program that imports
// none of them is as before; with no library built, the runtime's files are
// compiled in as source.
void resolveRuntimeLib(DriverOptions* d)
{
    String* root = supportRoot(d.fe());
    if (root == (String*)0) return;
    if (d.emitRuntime()) {
        String* lp = String.withString(root);
        lp.appendCString("/generic/lib/Runtime.list");
        String* text = Files.readText(lp);
        if (text == (String*)0) {
            Stdio.printf("xcc: error: --emit-runtime: no %s\n", lp.cString());
            driverExit((i32)1); return;
        }
        Array* names = new Array();
        Array* lines = text.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
            String* l = ((String*)lines.get(i)).trimmed();
            if (l.byteLength() == (u32)0 || l.byteAt((u32)0) == (u8)'#') continue;
            names.add((Object*)l);
        }
        d.fe().setRuntimeMembers(names);
        if (d.runtimeSupport()) {
            d.fe().setRuntimeAllStd(true);
            d.fe().setNoPlatformPrelude(true);
        }
        return;
    }
    // XCC_NO_RUNTIME_LIB=1 as --no-runtime-lib: the build of the tools an
    // archive ships, which must not name this tree's libRuntime.
    if (Platform.env(String.withCString("XCC_NO_RUNTIME_LIB")).equals(String.withCString("1"))) return;
    if (d.noRuntimeLib() || d.caps().staticLink() || d.targetRow() == (TargetRow*)0) return;
    // An image that links an xcc object or archive (-Wl,x.o, -Xlinker liby.a,
    // $XTC_LDFLAGS) keeps the runtime its own, as before: an xcc -c object
    // reads the canary guard and the runtime's data directly, which the
    // rewrite of the program's text cannot reach. One that names none of the
    // runtime's symbols (a C or Objective-C shim) does not decide it: a
    // library that kept its own runtime for such a shim gave its clients a
    // second span table, and their par blocks ran serially (#453). As the
    // reference.
    Array* li = d.linkInputs();
    for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) {
        String* t = (String*)li.get(i);
        if ((t.hasSuffix(String.withCString(".o")) || t.hasSuffix(String.withCString(".a"))) && namesRuntime(t)) return;
    }
    // An xc file's x86-64 -c object is compiled without it: it carries the
    // classes it uses and reads the guard directly, so the dynamic and the
    // -static object link can both take it. Such an object link keeps the
    // runtime its own; a C or C++ object's xcc half reads the guard through
    // the GOT, compiled for the library, and its link takes it. An -flto link
    // compiles the program again and takes it as a build from source does.
    if (isX86_64(d) && d.compileOnly() && d.fe().input() != (String*)0
        && Languages.forFile(d.fe().input()) == (LanguageRow*)0) return;
    if (!d.lto() && isX86_64(d) && objectsReadGuardDirectly(d)) return;
    // A C or C++ program takes it too (2026-11-14): its xc half's objects
    // then share one runtime, so a program of several C/C++ objects has one.
    String* dir = String.withString(root);
    dir.appendCString("/runtime-lib/");
    dir.append(d.targetRow().name());
    Array* exts = d.targetRow().libExts();
    // A linked C or C++ program (an LLVM-IR language) takes libRuntimeSupport
    // when the target has one (#278): the runtime and the standard library it
    // uses, so the program compiles only its own code and its lifted loops.
    // Its stub is then read with no platform prelude. An object (-c) keeps
    // libRuntime, as any other object of the program may, and so does a
    // program that links an xc library (linksXcLibrary).
    // …or an object link whose C or C++ objects took it (their .deplibs).
    bool support = !d.compileOnly() && !linksXcLibrary(d)
                   && ((d.fe().input() != (String*)0 && Languages.forFile(d.fe().input()) != (LanguageRow*)0)
                       || gObjWantRuntimeSupport);
    for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1) {
    if (pass == (u32)0 && !support) continue;
    for (u32 i = (u32)0; exts != (Array*)0 && i < exts.count(); i = i + (u32)1) {
        String* f = String.withString(dir);
        f.appendCString(pass == (u32)0 ? "/libRuntimeSupport." : "/libRuntime.");
        f.append((String*)exts.get(i));
        if (!Files.exists(f)) continue;
        // Absolute (the runpath and LC_RPATH are read from wherever the
        // program runs), from this compile's working directory.
        String* abs = dir;
        if (dir.byteAt((u32)0) != (u8)'/') {
            abs = String.withString(Frontend.workingDirectory());
            abs.appendCString("/");
            abs.append(dir);
        }
        IRDbg.setWorkingDirectory(Frontend.workingDirectory());
        abs = IRDbg.canonicalPath(abs);
        d.fe().setRuntimeLibDir(abs);
        String* file = String.withString(abs);
        file.appendCString(pass == (u32)0 ? "/libRuntimeSupport." : "/libRuntime.");
        file.append((String*)exts.get(i));
        d.fe().setRuntimeLibFile(file);
        if (pass == (u32)0)
            d.fe().setNoPlatformPrelude(true);
        // The program knows it shares the library, and which: a plugin built
        // to share it is loaded only into a program that does, by this xcc
        // (Plugin._checkAbi).
        String* def = String.withCString("XC_RUNTIME_LIB=\"");
        def.appendCString(XCC_VERSION);
        def.appendCString("\"");
        d.fe().defs().add((Object*)def);
        return;
    }
    }
}

// A plugin's object ABI for its bundle.json: "2" with the 8-byte instance
// header, "1" with the 40-byte one, and "+rt" when it shares the program's
// libRuntime, which only a program that links the same one loads it into
// (an older loader sees an ABI it does not know, and refuses it).
String* bundleAbiOf(DriverOptions* d)
{
    String* a = String.withCString(d.targetRow() != (TargetRow*)0 && d.targetRow().compactObjects() ? "2" : "1");
    if (d.fe().runtimeLibFile() != (String*)0) a.appendCString("+rt");
    return a;
}

// Whether this image takes its object runtime from the target's libRuntime
// (owner, 2026-11-03: every program and library, par or not, when one is
// built and the link is not -static). It then carries none of its own: one
// copy per process, the library's — two kept apart what each other set (the
// threads flag that makes ARC atomic, the simd: span table). The library is
// then a load-time dependency, whether or not the program imported its
// interface (only a par program does).
bool runtimeTaken(DriverOptions* d)
{
    String* f = d.fe().runtimeLibFile();
    if (f == (String*)0 || d.emitRuntime()) return false;
    Array* nl = d.fe().neededLibs();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1)
        if (((String*)nl.get(i)).equals(f)) return true;
    nl.add((Object*)f);
    return true;
}

// The stack canary's guard word is the runtime's: a program that takes
// libRuntime reads the library's through the GOT, as any imported data.
String* guardThroughGot(String* prog)
{
    String* a = prog.replacing(String.withCString("    adrp x16, ___xt_stack_guard@PAGE\n    ldr x16, [x16, ___xt_stack_guard@PAGEOFF]\n"),
                               String.withCString("    adrp x16, ___xt_stack_guard@GOTPAGE\n    ldr x16, [x16, ___xt_stack_guard@GOTPAGEOFF]\n    ldr x16, [x16]\n"));
    return a.replacing(String.withCString("    adrp x17, ___xt_stack_guard@PAGE\n    ldr x17, [x17, ___xt_stack_guard@PAGEOFF]\n"),
                       String.withCString("    adrp x17, ___xt_stack_guard@GOTPAGE\n    ldr x17, [x17, ___xt_stack_guard@GOTPAGEOFF]\n    ldr x17, [x17]\n"));
}

// …and on x86-64 (r10 holds the address at the check: volatile, and no
// return value is in it on either ABI).
String* guardThroughGotX86(String* prog)
{
    String* a = prog.replacing(String.withCString("\tmov\tr11, qword ptr [rip + __xt_stack_guard]\n"),
                               String.withCString("\tmov\tr11, qword ptr [rip + __xt_stack_guard@GOTPCREL]\n\tmov\tr11, qword ptr [r11]\n"));
    return a.replacing(String.withCString("\tmov\tr11, qword ptr [rbp-8]\n\tcmp\tr11, qword ptr [rip + __xt_stack_guard]\n"),
                       String.withCString("\tmov\tr10, qword ptr [rip + __xt_stack_guard@GOTPCREL]\n\tmov\tr11, qword ptr [rbp-8]\n\tcmp\tr11, qword ptr [r10]\n"));
}

// The glibc crt keeps argc and argv for Process.arguments() in the runtime's
// variables: through the GOT when the runtime is libRuntime's (rax is free
// there: the entry has stored nothing in it).
String* crtArgsThroughGot(String* crt)
{
    String* a = crt.replacing(String.withCString("\tmov\t[rip + _xt_saved_argc], edi"),
                              String.withCString("\tmov\trax, [rip + _xt_saved_argc@GOTPCREL]\n\tmov\t[rax], edi"));
    return a.replacing(String.withCString("\tmov\t[rip + _xt_saved_argv], rsi"),
                       String.withCString("\tmov\trax, [rip + _xt_saved_argv@GOTPCREL]\n\tmov\t[rax], rsi"));
}

// The --xc-* options (#148): a program with a par block takes every argument
// starting `--xc-` out of its arguments before main and sets the runtime
// variable it names (rt-xcargs.c). The block's dispatch, Par.run, is the
// signal: the program's assembly names it (a call, and in a source-runtime
// build its definition) only when a block is left after the optimiser. A
// library has no start code; -fno-xc-args leaves the arguments alone.
bool xcArgsWanted(DriverOptions* d, String* prog)
{
    if (d.noXcArgs() || d.emitLib() || d.emitRuntime() || prog == (String*)0) return false;
    // A block the outliner made (a C/C++ loop, --par-style=auto) runs
    // through its ParImpl$o<n> class, not Par.run: the program has one too.
    // (Its name was found before only because the runtime's own source,
    // Par.run's definition, was in the same text, which libRuntime is not.)
    if (prog.byteIndexOf(String.withCString("ParImpl$o")) != String.notFound()) return true;
    String* run = String.withCString("Par$run");
    u32 at = prog.byteIndexOf(run);
    while (at != String.notFound()) {
        u32 e = at + run.byteLength();
        u8 c = e < prog.byteLength() ? prog.byteAt(e) : (u8)' ';
        bool ident = (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z')
                  || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_' || c == (u8)'$';
        if (!ident) return true;
        at = prog.byteIndexOf(run, e);
    }
    return false;
}

// …or, at the link of a C program's two halves, xcc's half had one.
bool xcArgsFor(DriverOptions* d, String* prog)
{
    if (d.noXcArgs() || d.emitLib() || d.emitRuntime()) return false;
    return gHalfXcArgs || xcArgsWanted(d, prog);
}

// The crt and the filter, as one text, for an image whose crt is `crt`
// (an arm64 row's).
String* crtArm64WithXcArgs(DriverOptions* d, String* crt, String* crtName)
{
    String* xa = readRuntime(d.fe(), String.withCString(
        crtName.equals(String.withCString("crt-macos.s")) ? "xcargs-macos.s" : "xcargs-elf.s"));
    if (xa == 0) {
        Stdio.printf("xcc: error: cannot read the --xc-* options' runtime from the support tree\n");
        driverExit((i32)1); return crt;
    }
    String* t = crtWithXcArgs(crt);
    t.appendByte((u8)'\n');
    t.append(xa);
    return t;
}

// The crt with the call to the options' filter: before the runtime keeps
// argc and argv, so Process.arguments() and main both get the filtered list.
// arm64 hands the count it returns to _xt_set_args and main; x86-64 Linux
// keeps it in r12 (main's argc) and _xt_saved_argc; Windows rewrites the
// command line before the runtime first parses it.
String* crtWithXcArgs(String* crt)
{
    if (crt.contains(String.withCString("    bl __xt_set_args\n")))
        return crt.replacing(String.withCString("    bl __xt_set_args\n"),
            String.withCString("    bl __xt_xcargs                     // the --xc-* options out\n"
                               "    str x0, [sp, #16]                   // the count they leave\n"
                               "    ldp x0, x1, [sp, #16]\n"
                               "    bl __xt_set_args\n"));
    if (crt.contains(String.withCString("    bl _xt_set_args\n")))
        return crt.replacing(String.withCString("    bl _xt_set_args\n"),
            String.withCString("    bl _xt_xcargs                      // the --xc-* options out\n"
                               "    str x0, [sp, #16]                   // the count they leave\n"
                               "    ldp x0, x1, [sp, #16]\n"
                               "    bl _xt_set_args\n"));
    String* guard = String.withCString("\tcall\t_xt_stack_guard_init\n");
    if (crt.contains(String.withCString("\tcall\t_xt_argv_table")))   // Windows
        return crt.replacing(guard, String.withCString("\tcall\t_xt_stack_guard_init\n"
                                                       "\tcall\t_xt_xcargs\t\t# the --xc-* options out of the command line\n"));
    return crt.replacing(guard, String.withCString("\tcall\t_xt_stack_guard_init\n"
                                                   "\tmov\tedi, r12d\t\t# the --xc-* options out\n"
                                                   "\tmov\trsi, r13\n"
                                                   "\tcall\t_xt_xcargs\n"
                                                   "\tmov\tr12d, eax\t\t# the count they leave, for main\n"
                                                   "\tmov\tedi, eax\n"
                                                   "\tmov\t[rip + _xt_saved_argc], edi\n"));
}

// libRuntime exports the object runtime: its guard word too, which every
// image's canaries read (Mach-O private_extern; ELF hidden).
String* runtimeForLibRuntime(String* rt)
{
    String* a = rt.replacing(String.withCString(".private_extern\t___xt_stack_guard"),
                             String.withCString(".globl\t___xt_stack_guard"));
    return a.replacing(String.withCString("\t.hidden\t__xt_stack_guard"), String.withCString("\t.globl\t__xt_stack_guard"));
}

// A runtime or startup file from the support tree. The SUBDIRECTORY is the
// platform's, not always arm64's: m68k keeps its crt0.s under
// atarist/startup/, and hardcoding one path meant a second target could not
// find its own startup at all.
String* readRuntimeIn(FeOptions* o, string sub, String* name)
{
    String* p = supportRoot(o);
    if (p == 0) return (String*)0;
    String* full = String.withString(p);
    full.appendByte((u8)'/');
    full.appendCString(sub);
    full.appendByte((u8)'/');
    full.append(name);
    return Files.readText(full);
}

String* readRuntime(FeOptions* o, String* name)
{
    return readRuntimeIn(o, "arm64/runtime", name);
}

// ── main ─────────────────────────────────────────────────────────────────

// The user's `main` becomes `xt_main`; the glue supplies the entry the
// framework dlsym()s. Text substitution on the asm, as the reference does it.
String* renameMain(String* asmText)
{
    String* a = asmText.replacing(String.withCString(".globl _main"),
                                 String.withCString(".globl _xt_main"));
    a = a.replacing(String.withCString("\n_main:"), String.withCString("\nxt_main:"));
    return a;
}

// --emit-apk, end to end: link the payload .so, build the manifest, zip it,
// and sign it. Nothing here needs the Android SDK — the same claim the
// Objective-C driver makes, now true of the xtc one.

// Generate a 2048-bit debug key and its self-signed certificate, and cache them
// in the raw form both drivers read: "XKEY1" then four little-endian
// length-prefixed blobs — n, e, d, cert. NOT for release; a release build is
// signed with the developer's own key.
bool writeDebugKey(String* path)
{
    Array* k = Rsa.generate((u32)2048);
    if (k.count() < (u32)3) return false;
    Data* nb = (Data*)k.get((u32)0);
    Data* eb = (Data*)k.get((u32)1);
    Data* db = (Data*)k.get((u32)2);
    Data* cert = ApkSign.selfSignedCert(nb, eb, db, String.withCString("xc debug"));
    if (cert.length() == (u32)0) return false;

    // The directory may not exist yet.
    String* dir = path.deletingLastPathComponent();
    if (dir.byteLength() > (u32)0) Files.createDirectory(dir);

    Data* out = Data.withCapacity((u32)0);
    String* magic = String.withCString("XKEY1");
    for (u32 i = (u32)0; i < (u32)5; i = i + (u32)1) out.appendByte(magic.byteAt(i));
    Array* fields = new Array();
    fields.add((Object*)nb); fields.add((Object*)eb);
    fields.add((Object*)db); fields.add((Object*)cert);
    for (u32 f = (u32)0; f < (u32)4; f = f + (u32)1) {
        Data* v = (Data*)fields.get(f);
        u32 n = v.length();
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            out.appendByte((u8)((n >> (i * (u32)8)) & (u32)$FF));
        out.append(v);
    }
    return Files.writeData(path, out);
}

// A `-Xlinker <path>` or `-l<name>` argument, as a readable file.
//
// `-l<name>` is searched on the -L path exactly as a linker searches it —
// `libname.dylib` first, then `libname.so`. A path is taken as given. Anything
// that cannot be found is REFUSED by name: a library silently dropped from a
// link is a symbol that resolves nowhere, and the program dies at launch
// naming something the user believes they linked.
String* resolveLinkInput(DriverOptions* d, String* arg)
{
    if (!arg.hasPrefix(String.withCString("-l"))) {
        if (Files.exists(arg)) return arg;
        Stdio.printf("xcc: error: -Xlinker '%s': no such file\n", arg.cString());
        driverExit((i32)1);
        return (String*)0;
    }
    String* stem = arg.substringFromByte((u32)2);
    // The -L path, then any -L<dir> that reached the linker through
    // -Wl, / $XTC_LDFLAGS: those name where a -l is found, and nothing else.
    Array* dirs = new Array();
    for (u32 i = (u32)0; i < d.fe().libs().count(); i = i + (u32)1) dirs.add(d.fe().libs().get(i));
    for (u32 i = (u32)0; i < d.ldDirs().count(); i = i + (u32)1) dirs.add(d.ldDirs().get(i));
    // A `.dylib` is a Mach-O library — only a Mach-O target (the arm64 / iOS
    // host) can link it. On an ELF (x86_64 / arm9) or PE (win64) target it must
    // NOT be a `-l<name>` candidate: 0.5 grabbed a stray macOS `libfoo.dylib`
    // off the -L path and handed it to the ELF linker, which then refused it;
    // 0.4 skipped it (c2xc bug 37). Those targets use `.so` / `.a` instead.
    // The row's format decides (android and arm64 Linux are ELF though their
    // back end is arm64's).
    // -l:<file>: that file by its own name (ld's form: a versioned shared
    // object, libstdc++.so.6), on the -L path, then in the target's
    // multiarch directories.
    if (stem.hasPrefix(String.withCString(":"))) {
        String* fname = stem.substringFromByte((u32)1);
        Array* fdirs = new Array();
        for (u32 i = (u32)0; i < dirs.count(); i = i + (u32)1) fdirs.add(dirs.get(i));
        String* triple = d.targetRow() != (TargetRow*)0 && d.targetRow().cpu().equals(String.withCString("arm64"))
                       ? String.withCString("aarch64-linux-gnu") : String.withCString("x86_64-linux-gnu");
        // A cross build's sysroot first (its usr/lib and lib copied from a
        // machine of the target), then this machine's own.
        if (gCPathRoot != (String*)0) {
            fdirs.add((Object*)String.withFormat("%s/usr/lib/%s", gCPathRoot.cString(), triple.cString()));
            fdirs.add((Object*)String.withFormat("%s/lib/%s", gCPathRoot.cString(), triple.cString()));
        }
        fdirs.add((Object*)String.withCString("/usr/lib/").appending(triple));
        fdirs.add((Object*)String.withCString("/lib/").appending(triple));
        fdirs.add((Object*)String.withCString("/usr/lib"));
        for (u32 i = (u32)0; i < fdirs.count(); i = i + (u32)1) {
            String* p = String.withString((String*)fdirs.get(i));
            p.appendCString("/"); p.append(fname);
            if (Files.exists(p)) return p;
        }
        Stdio.printf("xcc: error: -l%s: no %s on the -L path or in the system library directories\n",
                     stem.cString(), fname.cString());
        driverExit((i32)1);
        return (String*)0;
    }
    String* arch = d.arch();
    bool machO = d.targetRow() != (TargetRow*)0 ? d.targetRow().exeFormat().equals(String.withCString("macho"))
               : !(arch.equals(String.withCString("x86_64"))
                || arch.equals(String.withCString("arm9"))
                || arch.equals(String.withCString("win64")));
    for (u32 i = (u32)0; dirs != (Array*)0 && i < dirs.count(); i = i + (u32)1) {
        String* base = String.withString((String*)dirs.get(i));
        base.appendCString("/lib");
        base.append(stem);
        if (machO) {
            String* dy = String.withString(base); dy.appendCString(".dylib");
            if (Files.exists(dy)) return dy;
        }
        String* so = String.withString(base); so.appendCString(".so");
        if (Files.exists(so)) return so;
    }
    // No real dylib: a system library lives in the shared cache with no file
    // to open, but the SDK ships a `.tbd` text stub naming its exports — and
    // that is what tells the bind which dylib ordinal the symbol belongs to
    // (bug 138 / uxkit 028: without it every import fell to ordinal 1).
    // A Mach-O target's only: from a Mac, a win64 program's -lc++ is
    // mingw's libc++.a, not macOS's stub.
    String* sdk = machO ? appleSdkRoot(d) : (String*)0;
    if (sdk != (String*)0) {
        String* t1 = String.withString(sdk); t1.appendCString("/usr/lib/lib"); t1.append(stem); t1.appendCString(".tbd");
        if (Files.exists(t1)) return t1;
        String* t2 = String.withString(sdk); t2.appendCString("/usr/lib/system/lib"); t2.append(stem); t2.appendCString(".tbd");
        if (Files.exists(t2)) return t2;
    }
    // A static archive on the -L path: the pool an in-house link pulls from.
    // win64 adds the mingw toolchain's lib and clang-rt dirs (bug 141).
    Array* ardirs = new Array();
    for (u32 i = (u32)0; dirs != (Array*)0 && i < dirs.count(); i = i + (u32)1) ardirs.add(dirs.get(i));
    if (isWin64(d)) {
        String* tc = win64Toolchain();
        ardirs.add((Object*)String.withString(tc).appending(String.withCString("/x86_64-w64-mingw32/lib")));
        ardirs.add((Object*)String.withString(tc).appending(String.withCString("/x86_64-w64-mingw32/clang-rt")));
    }
    for (u32 i = (u32)0; i < ardirs.count(); i = i + (u32)1) {
        String* ar = String.withString((String*)ardirs.get(i));
        ar.appendCString("/lib"); ar.append(stem); ar.appendCString(".a");
        if (Files.exists(ar)) return ar;
    }
    // Nothing on disk at all: dyld resolves it at launch by flat lookup.
    return (String*)0;
}

// The Apple SDK for the platform being linked: $SDKROOT first, then the
// version-independent .sdk symlink under Xcode (and, for macOS, the Command
// Line Tools). Nil when none is installed — the link then knows no
// framework's exports, which is the pre-138 behaviour, not an error.
String* appleSdkRoot(DriverOptions* d)
{
    Array* roots = new Array();
    String* env = Platform.env(String.withCString("SDKROOT"));
    if (env != 0 && env.byteLength() > (u32)0) roots.add((Object*)env);
    if (isIos(d) && !isIosSim(d))
        roots.add((Object*)String.withCString("/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"));
    else if (isIosSim(d))
        roots.add((Object*)String.withCString("/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"));
    else {
        roots.add((Object*)String.withCString("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"));
        roots.add((Object*)String.withCString("/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"));
    }
    for (u32 i = (u32)0; i < roots.count(); i = i + (u32)1) {
        String* lib = String.withString((String*)roots.get(i)); lib.appendCString("/usr/lib");
        if (Files.exists(lib)) return (String*)roots.get(i);
    }
    return (String*)0;
}

// One LC_LOAD_DYLIB dependency for a library PATH: a `.tbd` stub is read for
// its install-name and exports (per platform), a real dylib for its export
// trie. Each claims the imports it exports, so a symbol binds to the library
// that has it rather than falling through to libSystem.
// Bug 580: a C function the program calls that no linked library exports
// used to bind to libSystem and fail only at launch (`Symbol not found`).
// With an SDK at hand, libSystem's own export list says which imports it
// really has; any other unclaimed import is a link error naming it. Without
// an SDK nothing is known, and the old behaviour stands.
// A direct @PAGE/@PAGEOFF load or store of a symbol a library defines
// (#350): the writer refuses it rather than leave the address zero.
void checkPageImports(MachO* m)
{
    // Fixups that do not fit their instruction (#285).
    Array* le = m.linkErrors();
    for (u32 i = (u32)0; i < le.count(); i = i + (u32)1)
        Stdio.printf("xcc: error: %s\n", ((String*)le.get(i)).cString());
    Array* bad = m.unreachableImports();
    if (bad.count() == (u32)0 && le.count() == (u32)0) return;
    for (u32 i = (u32)0; i < bad.count(); i = i + (u32)1) {
        Array* pair = (Array*)bad.get(i);
        String* s = (String*)pair.get((u32)0);
        String* fn = (String*)pair.get((u32)1);
        String* shown = s.hasPrefix(String.withCString("_")) ? s.substringFromByte((u32)1) : s;
        String* where = String.withCString("");
        if (fn.byteLength() > (u32)0) {
            where.appendCString(" in '");
            where.append(fn.hasPrefix(String.withCString("_")) ? fn.substringFromByte((u32)1) : fn);
            where.appendCString("'");
        }
        Stdio.printf("xcc: error: '%s' is loaded or stored directly%s (an @PAGE/@PAGEOFF pair), but a "
                     "library defines it, and such a reference cannot reach another image: it has to "
                     "go through the GOT\n", shown.cString(), where.cString());
    }
    driverExit((i32)1);
}

void checkSystemImports(DriverOptions* d, MachO* m)
{
    checkPageImports(m);
    // macOS only for now: the iOS SDKs inline libSystem's sub-libraries as
    // further documents in the same .tbd, which the reader does not merge yet,
    // so `write` and the pthread calls would look missing (580 follow-up).
    if (isIos(d)) return;
    String* sdk = appleSdkRoot(d);
    if (sdk == (String*)0) return;
    String* path = String.withString(sdk);
    path.appendCString("/usr/lib/libSystem.B.tbd");
    if (!Files.exists(path)) return;
    Tbd.setPlatform(isIos(d) ? d.arch() : String.withCString("macos"));
    TbdInfo* t = Tbd.inspect(path, sdk);
    if (t == (TbdInfo*)0) return;
    Map* have = new Map();
    Array* syms = t.symbols();
    for (u32 i = (u32)0; i < syms.count(); i = i + (u32)1)
        have.set((Hashable*)syms.get(i), syms.get(i));
    Array* bad = m.unexportedSystemImports(have);
    if (bad.count() == (u32)0) return;
    for (u32 i = (u32)0; i < bad.count(); i = i + (u32)1) {
        String* s = (String*)bad.get(i);
        String* shown = s.hasPrefix(String.withCString("_")) ? s.substringFromByte((u32)1) : s;
        Stdio.printf("xcc: error: undefined symbol '%s': no linked library exports it, and "
                     "libSystem does not have it. If it lives in a framework, #import <Framework> "
                     "or pass -framework <Framework>\n", shown.cString());
    }
    driverExit((i32)1);
}

MachODep* depForPath(DriverOptions* d, String* lp)
{
    if (lp.hasSuffix(String.withCString(".tbd"))) {
        Tbd.setPlatform(isIos(d) ? d.arch() : String.withCString("macos"));
        TbdInfo* t = Tbd.inspect(lp, appleSdkRoot(d));
        if (t == (TbdInfo*)0) {
            Stdio.printf("xcc: note: skipping unreadable tbd stub '%s'\n", lp.cString());
            return (MachODep*)0;
        }
        return MachODep.with(t.install(), t.symbols());
    }
    String* install = lp.hasPrefix(String.withCString("/"))
                    ? String.withString(lp)
                    : String.withCString("@rpath/").appending(lp.lastPathComponent());
    return MachODep.with(install, IfaceImport.machoExports(lp));
}

// `-framework <F>` binds `<F>.framework/<F>.tbd` from the SDK (Frameworks,
// then PrivateFrameworks). With no SDK the framework is named by its
// shared-cache path and claims nothing — dyld's flat lookup finds it on
// macOS, and only there.
MachODep* depForFramework(DriverOptions* d, String* nm)
{
    String* sdk = appleSdkRoot(d);
    if (sdk != (String*)0) {
        String* p1 = String.withString(sdk); p1.appendCString("/System/Library/Frameworks/");
        p1.append(nm); p1.appendCString(".framework/"); p1.append(nm); p1.appendCString(".tbd");
        if (Files.exists(p1)) return depForPath(d, p1);
        String* p2 = String.withString(sdk); p2.appendCString("/System/Library/PrivateFrameworks/");
        p2.append(nm); p2.appendCString(".framework/"); p2.append(nm); p2.appendCString(".tbd");
        if (Files.exists(p2)) return depForPath(d, p2);
    }
    String* path = String.withCString("/System/Library/Frameworks/");
    path.append(nm); path.appendCString(".framework/"); path.append(nm);
    return MachODep.with(path, new Array());
}

bool dataContains(Data* d, string needle)
{
    String* n = String.withCString(needle);
    u32 nl = n.byteLength();
    if (d == (Data*)0 || d.length() < nl) return false;
    for (u32 i = (u32)0; i + nl <= d.length(); i = i + (u32)1) {
        bool m = true;
        for (u32 k = (u32)0; k < nl && m; k = k + (u32)1)
            if (d.byteAt(i + k) != n.byteAt(k)) m = false;
        if (m) return true;
    }
    return false;
}

u32 leU32(Data* b, u32 at)
{
    return (u32)b.byteAt(at) | ((u32)b.byteAt(at + (u32)1) << (u32)8)
         | ((u32)b.byteAt(at + (u32)2) << (u32)16) | ((u32)b.byteAt(at + (u32)3) << (u32)24);
}

// Whether a 64-bit Mach-O object's symbol table names an UNDEFINED external
// `_objc_msgSend…` or `_OBJC_CLASS_$_…`: LC_SYMTAB's nlist_64 entries, an
// undefined one being N_EXT with type N_UNDF. Anything unreadable: no. As
// the reference.
bool machoObjectNeedsObjc(Data* b)
{
    if (b == (Data*)0) return false;
    u32 n = b.length();
    if (n < (u32)32 || leU32(b, (u32)0) != (u32)$FEEDFACF) return false;
    u32 ncmds = leU32(b, (u32)16);
    u32 at = (u32)32;
    for (u32 c = (u32)0; c < ncmds && at + (u32)8 <= n; c = c + (u32)1) {
        u32 cmd = leU32(b, at);
        u32 size = leU32(b, at + (u32)4);
        if (cmd == (u32)2 && at + (u32)24 <= n) {
            u32 symoff = leU32(b, at + (u32)8);
            u32 nsyms = leU32(b, at + (u32)12);
            u32 stroff = leU32(b, at + (u32)16);
            u32 strsize = leU32(b, at + (u32)20);
            for (u32 k = (u32)0; k < nsyms; k = k + (u32)1) {
                u32 e = symoff + k * (u32)16;
                if (e + (u32)16 > n) return false;
                u32 strx = leU32(b, e);
                u8 type = b.byteAt(e + (u32)4);
                if ((type & (u8)1) == (u8)0 || (type & (u8)$0E) != (u8)0 || strx >= strsize || stroff + strx >= n) continue;
                u32 q = stroff + strx;
                String* nm = new String();
                while (q < n && b.byteAt(q) != (u8)0) { nm.appendByte(b.byteAt(q)); q = q + (u32)1; }
                if (q >= n) continue;
                // `_objc_msgSend`, or clang's per-selector stub `_objc_msgSend$length`.
                if (nm.hasPrefix(String.withCString("_objc_msgSend")) || nm.hasPrefix(String.withCString("_OBJC_CLASS_$_")))
                    return true;
            }
            return false;
        }
        if (size == (u32)0) return false;
        at = at + size;
    }
    return false;
}

// Bug 068: an ObjC object needs libobjc, and nothing else in the link
// provides it (libSystem does not re-export `_objc_msgSend`). Added only when
// a merged object or archive actually references ObjC — its string table
// carries the names as plain text, so a byte scan is a faithful signal.
bool objectsWantObjc(DriverOptions* d, Array* extra)
{
    Array* paths = new Array();
    for (u32 i = (u32)0; i < extra.count(); i = i + (u32)1) paths.add(extra.get(i));
    Array* li = d.linkInputs();
    for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) {
        String* lp = resolveLinkInput(d, (String*)li.get(i));
        if (lp != (String*)0) paths.add((Object*)lp);
    }
    for (u32 i = (u32)0; i < paths.count(); i = i + (u32)1) {
        String* p = (String*)paths.get(i);
        if (!p.hasSuffix(String.withCString(".o")) && !p.hasSuffix(String.withCString(".a"))) continue;
        Data* blob = Files.readData(p);
        // An object: its symbol table, for an UNDEFINED ObjC name. The bytes
        // alone matched a compiler whose own sources hold "_objc_msgSend" as
        // a string (every split-built xcc linked libobjc, and the install
        // refused it as an Objective-C build). An archive: still the bytes.
        // As the reference.
        if (p.hasSuffix(String.withCString(".o"))) {
            if (machoObjectNeedsObjc(blob)) return true;
            continue;
        }
        if (dataContains(blob, "_OBJC_CLASS_$_") || dataContains(blob, "_objc_msgSend")) return true;
    }
    return false;
}

// The libraries an arm64 LIBRARY `#import`s (bug 440), each once, by its
// `@rpath/` install name — the reference's xcc-ln-arm64 --dylib rule. A -l
// library or framework on a library build stays recorded on the client.
// A 64-bit Mach-O file, told by its magic rather than its name.
bool isMachOFile(String* path)
{
    Data* b = Files.readData(path);
    return b != (Data*)0 && b.length() >= (u32)4
        && b.byteAt((u32)0) == (u8)$CF && b.byteAt((u32)1) == (u8)$FA
        && b.byteAt((u32)2) == (u8)$ED && b.byteAt((u32)3) == (u8)$FE;
}

Array* dylibImportDeps(DriverOptions* d, Array* neededLibs)
{
    Array* deps = new Array();
    for (u32 i = (u32)0; neededLibs != (Array*)0 && i < neededLibs.count(); i = i + (u32)1) {
        String* lp = (String*)neededLibs.get(i);
        if (lp.hasPrefix(String.withCString("framework:"))) {
            MachODep* fdep = depForFramework(d, lp.substringFromByte((u32)10));
            if (fdep != (MachODep*)0) deps.add((Object*)fdep);
            continue;
        }
        if (!lp.hasSuffix(String.withCString(".dylib")) && !isMachOFile(lp)) continue;
        String* rp = String.withCString("@rpath/");
        rp.append(lp.lastPathComponent());
        bool have = false;
        for (u32 k = (u32)0; k < deps.count(); k = k + (u32)1)
            if (((MachODep*)deps.get(k)).path().equals(rp)) have = true;
        if (!have) deps.add((Object*)MachODep.with(rp, IfaceImport.machoExports(lp)));
    }
    return deps;
}

// The dependency list for an arm64 / iOS executable: what the program (or its
// objects) `#import`ed, then the libraries and frameworks named on the line,
// then libobjc when the merged objects need it — the reference's order.
// The LC_RPATH entries after @loader_path, in the reference linker's order:
// the directory of each `#import`ed dylib, then of each -l dylib, then each
// -rpath. A `.tbd` names a shared-cache library dyld finds without help, so it
// adds none. Without the dylib directories a program importing a library
// from /opt/xcc/3p (`#use <tls>`) built but could not load it.
// The directory a dylib's rpath names, or "" for none. A library in the
// current directory gets none: "." is resolved against wherever the program is
// RUN from, and the @loader_path every image carries already finds a library
// beside the binary — which is also all the reference's in-process link writes.
String* rpathDirOf(String* lp)
{
    // Spelt as the reference spells it (standardPath, bug 629).
    String* dir = standardPath(lp.deletingLastPathComponent());
    if (dir.equals(String.withCString(".")) || dir.equals(String.withCString("./")))
        return String.withCString("");
    for (u32 i = (u32)0; i < lp.byteLength(); i = i + (u32)1)
        if (lp.byteAt(i) == (u8)'/') return dir;
    return String.withCString("");
}

Array* arm64Rpaths(DriverOptions* d, Array* neededLibs)
{
    Array* out = new Array();
    Array* dirs = new Array();
    for (u32 i = (u32)0; neededLibs != (Array*)0 && i < neededLibs.count(); i = i + (u32)1) {
        String* lp = (String*)neededLibs.get(i);
        if (lp.hasSuffix(String.withCString(".dylib"))) dirs.add((Object*)rpathDirOf(lp));
    }
    Array* li = d.linkInputs();
    for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) {
        String* lp = resolveLinkInput(d, (String*)li.get(i));
        if (lp != (String*)0 && lp.hasSuffix(String.withCString(".dylib")))
            dirs.add((Object*)rpathDirOf(lp));
    }
    for (u32 i = (u32)0; i < d.rpaths().count(); i = i + (u32)1)
        dirs.add(d.rpaths().get(i));
    for (u32 i = (u32)0; i < dirs.count(); i = i + (u32)1) {
        String* dir = (String*)dirs.get(i);
        if (dir.byteLength() == (u32)0 || dir.equals(String.withCString("@loader_path"))) continue;
        bool seen = false;
        for (u32 k = (u32)0; k < out.count(); k = k + (u32)1)
            if (((String*)out.get(k)).equals(dir)) seen = true;
        if (!seen) out.add((Object*)dir);
    }
    return out;
}

Array* arm64LinkDeps(DriverOptions* d, Array* neededLibs, Array* extraObjects)
{
    Array* deps = new Array();
    for (u32 i = (u32)0; neededLibs != (Array*)0 && i < neededLibs.count(); i = i + (u32)1) {
        String* lp = (String*)neededLibs.get(i);
        // A Mach-O library is one whatever it is called: `libFoo.so` built for
        // arm64 is found by `#use <Foo>`, its interface is read, and it has to
        // be linked too, or its classes bind to nothing (bug 583).
        if (!lp.hasSuffix(String.withCString(".dylib")) && !isMachOFile(lp)) continue;
        String* rp = String.withCString("@rpath/");
        rp.append(lp.lastPathComponent());
        deps.add((Object*)MachODep.with(rp, IfaceImport.machoExports(lp)));
    }
    Array* li = d.linkInputs();
    for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) {
        String* lp = resolveLinkInput(d, (String*)li.get(i));
        if (lp == (String*)0) continue;
        if (lp.hasSuffix(String.withCString(".o")) || lp.hasSuffix(String.withCString(".a"))) continue;
        MachODep* dep = depForPath(d, lp);
        if (dep != (MachODep*)0) deps.add((Object*)dep);
    }
    Array* fw = d.frameworks();
    for (u32 i = (u32)0; fw != (Array*)0 && i < fw.count(); i = i + (u32)1) {
        MachODep* dep = depForFramework(d, (String*)fw.get(i));
        if (dep != (MachODep*)0) deps.add((Object*)dep);
    }
    // Frameworks the program `#import`ed by name (`#import <CoreFoundation>`),
    // after the ones on the line, unless the line named them already.
    for (u32 i = (u32)0; neededLibs != (Array*)0 && i < neededLibs.count(); i = i + (u32)1) {
        String* lp = (String*)neededLibs.get(i);
        if (!lp.hasPrefix(String.withCString("framework:"))) continue;
        String* nm = lp.substringFromByte((u32)10);
        bool named = false;
        for (u32 k = (u32)0; fw != (Array*)0 && k < fw.count(); k = k + (u32)1)
            if (((String*)fw.get(k)).equals(nm)) named = true;
        if (named) continue;
        MachODep* dep = depForFramework(d, nm);
        if (dep != (MachODep*)0) deps.add((Object*)dep);
    }
    // iOS: the platform shim (xtios.c) reaches NSURLSession through the ObjC
    // runtime, so every iOS image depends on Foundation and libobjc — added
    // after the user's frameworks unless the user named Foundation already.
    bool wantFoundation = isIos(d);
    for (u32 i = (u32)0; fw != (Array*)0 && i < fw.count(); i = i + (u32)1)
        if (((String*)fw.get(i)).equals(String.withCString("Foundation"))) wantFoundation = false;
    for (u32 i = (u32)0; neededLibs != (Array*)0 && i < neededLibs.count(); i = i + (u32)1)
        if (((String*)neededLibs.get(i)).equals(String.withCString("framework:Foundation"))) wantFoundation = false;
    if (wantFoundation) {
        MachODep* dep = depForFramework(d, String.withCString("Foundation"));
        if (dep != (MachODep*)0) deps.add((Object*)dep);
    }
    if (isIos(d) || objectsWantObjc(d, extraObjects)) {
        String* sdk = appleSdkRoot(d);
        String* lib = sdk == (String*)0 ? (String*)0 : String.withString(sdk);
        if (lib != (String*)0) lib.appendCString("/usr/lib/libobjc.tbd");
        if (lib != (String*)0 && Files.exists(lib)) {
            MachODep* dep = depForPath(d, lib);
            bool have = false;
            for (u32 i = (u32)0; dep != (MachODep*)0 && i < deps.count(); i = i + (u32)1)
                if (((MachODep*)deps.get(i)).path().equals(dep.path())) have = true;
            if (dep != (MachODep*)0 && !have) deps.add((Object*)dep);
        }
    }
    return deps;
}

// The DT_NEEDED list for an Android image: the base set every image names,
// then each --needed soname not already in it. bionic resolves a library's
// imports against its own group only, so a payload that calls into a companion
// .so has to NAME it.
Array* androidNeeded(DriverOptions* d, string base)
{
    Array* out = new Array();
    Array* parts = String.withCString(base).splitOnByte((u8)',');
    for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
        out.add(parts.get(i));
    Array* extra = d.caps().needed();
    for (u32 i = (u32)0; i < extra.count(); i = i + (u32)1) {
        String* n = (String*)extra.get(i);
        bool have = false;
        for (u32 k = (u32)0; k < out.count(); k = k + (u32)1)
            if (((String*)out.get(k)).equals(n)) have = true;
        if (!have) out.add((Object*)n);
    }
    return out;
}

// The name bionic resolves a library by: its DT_SONAME when it has one, else
// its file name. An android `--emit-lib` records the output's file name as the
// soname, so the two agree for a library used in place; an installed copy may
// carry a versioned file name (libUXKit-1-0.so) under the soname libUXKit.so,
// and naming the file there left dlopen looking for a library that is not in
// the APK (bug 635).
String* androidSonameOf(String* path)
{
    ElfSharedInfo* info = Elf64.sharedInfo(path);
    if (info != (ElfSharedInfo*)0 && info.soname() != (String*)0 && info.soname().byteLength() > (u32)0)
        return info.soname();
    return path.lastPathComponent();
}

// Whether a library path names a shared object: libX.so, or a versioned
// soname (libstdc++.so.6, which a -l:<file> names).
bool isSharedLib(String* p)
{
    return p.hasSuffix(String.withCString(".so")) || p.contains(String.withCString(".so."));
}

// The same list with the `.so` libraries the program or library `#import`ed
// after the base set, each by its soname (bug 460). Without them the image had
// no DT_NEEDED for a library it calls into, and bionic had nothing to resolve
// those imports in.
// arm64 Linux: the symbols an executable may import — glibc's
// (glibc-imports.map), then what each library the program links defines —
// as the reference hands its linker (arm64KnownImportsFile).
Map* arm64KnownImports(DriverOptions* d)
{
    String* map = readRuntimeIn(d.fe(), "arm64", String.withCString("glibc-imports.map"));
    if (map == 0) {
        Stdio.printf("xcc: error: cannot read arm64/glibc-imports.map from the support tree\n");
        driverExit((i32)1);
        return (Map*)0;
    }
    Map* m = new Map();
    Array* lines = map.splitOnByte((u8)'\n');
    for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
        String* line = (String*)lines.get(i);
        if (line.byteLength() == (u32)0 || line.byteAt((u32)0) == (u8)'#') continue;
        String* n = (String*)line.splitOnByte((u8)'\t').get((u32)0);
        m.set((Hashable*)n, (Object*)n);
    }
    Array* nl = d.fe().neededLibs();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
        String* lp = (String*)nl.get(i);
        if (!isSharedLib(lp)) continue;
        ElfSharedInfo* info = Elf64.sharedInfo(lp);
        if (info == (ElfSharedInfo*)0) {
            Stdio.printf("xcc: error: '%s' is not a readable ELF64 shared object\n", lp.cString());
            driverExit((i32)1);
            return (Map*)0;
        }
        for (u32 k = (u32)0; k < info.exported().count(); k = k + (u32)1)
            m.set((Hashable*)info.exported().get(k), info.exported().get(k));
    }
    return m;
}

// arm64 Linux: the imported libraries' DT_RUNPATH, $ORIGIN then where each
// was linked from (the reference's arm64ElfRunpath); 0 when it imports none,
// and always for android, whose images carry none.
String* arm64ElfRunpath(DriverOptions* d, TargetRow* row)
{
    if (!row.os().equals(String.withCString("linux"))) return (String*)0;
    Array* nl = d.fe().neededLibs();
    String* rp = String.withCString("$ORIGIN");
    bool any = false;
    Array* dirs = new Array();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
        String* lp = (String*)nl.get(i);
        if (!isSharedLib(lp)) continue;
        String* dir = standardPath(lp.deletingLastPathComponent());
        bool seen = false;
        for (u32 k = (u32)0; k < dirs.count(); k = k + (u32)1)
            if (((String*)dirs.get(k)).equals(dir)) seen = true;
        if (dir.byteLength() > (u32)0 && !seen) {
            dirs.add((Object*)dir);
            rp.appendCString(":");
            rp.append(dir);
            any = true;
        }
    }
    return any ? rp : (String*)0;
}

Array* androidNeededWithImports(DriverOptions* d, string base)
{
    String* all = String.withCString(base);
    Array* nl = d.fe().neededLibs();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
        String* lp = (String*)nl.get(i);
        if (!isSharedLib(lp)) continue;
        String* sn = androidSonameOf(lp);
        Array* have = all.splitOnByte((u8)',');
        bool seen = false;
        for (u32 k = (u32)0; k < have.count(); k = k + (u32)1)
            if (((String*)have.get(k)).equals(sn)) seen = true;
        if (seen) continue;
        all.appendCString(",");
        all.append(sn);
    }
    return androidNeeded(d, all.cString());
}


void emitApkPackage(DriverOptions* d, String* prog)
{
    FeOptions* o = d.fe();
    String* out = d.fe().output();
    String* name = out.lastPathComponent().deletingPathExtension();
    String* crt = (String*)0;                       // a .so has no entry point
    String* rt  = readRuntime(o, String.withCString("rt-android.s"));
    String* glue = readRuntime(o, String.withCString("glue-android.s"));
    if (rt == (String*)0 || glue == (String*)0) {
        Stdio.printf("xcc: error: the android runtime/glue is missing from the support tree\n");
        driverExit((i32)1); return;
    }
    String* renamed = renameMain(prog);
    String* combined = String.withString(glue);
    combined.appendCString("\n");
    combined.append(rt);
    combined.appendCString("\n");
    combined.append(stripLeadingUnderscore(classAllocStubs(renamed)));
    combined.appendCString("\n");
    combined.append(stripLeadingUnderscore(renamed));

    // The glue and the android runtime are ELF-flavoured (both generated by the
    // NDK clang), and this assembler parses the Mach-O flavour — so the text is
    // normalised first, exactly as xcc-ln-arm64 does on its android branch.
    Arm64Asm* a = new Arm64Asm();
    a.assemble(Arm64Asm.machoDialectFromElf(combined));
    a.demoteCommonsToLocalData();
    if (a.failed()) {
        Stdio.printf("xcc: apk: assembly failed: %s\n", a.why().cString());
        driverExit((i32)1); return;
    }
    // With the libraries the program `#import`s, as the --emit-lib image names
    // them: an app built against an installed library recorded no DT_NEEDED for
    // it and failed at dlopen, "cannot locate symbol UXView$vtbl" (bug 635).
    Array* needed = androidNeededWithImports(d, "libc.so,libm.so,libdl.so,liblog.so,libandroid.so");
    Array* exports = new Array();
    exports.add((Object*)String.withCString("ANativeActivity_onCreate"));
    String* soname = String.withCString("lib");
    soname.append(name); soname.appendCString(".so");

    // --no-self-host: the same unit, linked by the NDK's clang (#31).
    if (d.caps().noSelfHost()) {
        String* so = External.tempPath(soname.cString());
        ndkLink(d, a, so, soname);
        Data* sb = Files.readData(so);
        if (sb == (Data*)0) {
            Stdio.printf("xcc: apk: cannot read the payload the NDK linked\n");
            driverExit((i32)1); return;
        }
        packageApk(d, name, soname, sb);
        if (!d.fe().verbose()) External.cleanup();
        return;
    }

    // Bug 124: the constructor array is kept OUT of dataBytes by the assembler,
    // so it has to be appended here or every load-time constructor is dropped.
    SectionBytes* apkData = a.dataBytes();
    Array* apkFix  = a.fixups();
    u32 apkMi = Arm64Asm.appendModInit(a, apkData, apkFix);
    ElfArm64* w = new ElfArm64();
    w.image(a.textBytes(), apkData, a.symbols(), a.dataSyms(),
            exports, apkFix, soname, needed, (String*)0, apkMi);
    if (w.failed()) {
        Stdio.printf("xcc: apk: link failed: %s\n", w.why().cString());
        driverExit((i32)1); return;
    }
    packageApk(d, name, soname, w.bytes());
}

// The package around a linked payload: manifest, the payload and any
// --with-lib/--with-dex extras, zipped, signed (APK Signature Scheme v2) and
// written. Shared by the in-house link and the --no-self-host NDK one.
void packageApk(DriverOptions* d, String* name, String* soname, Data* soBytes)
{
    String* out = d.fe().output();
    // The signing key: named, or the conventional cache under $HOME/.xcc —
    // GENERATED here if it is not there. A shipped compiler cannot answer
    // "another compiler makes your key": for its user, that compiler does not
    // exist.
    String* keyPath = d.signKey();
    if (keyPath.byteLength() == (u32)0) {
        String* home = Platform.home();
        if (home.byteLength() == (u32)0) {
            Stdio.printf("xcc: error: no $HOME, so --sign-key must name the key\n");
            driverExit((i32)1); return;
        }
        keyPath = String.withString(home);
        keyPath.appendCString("/.xcc/android-debug.key.raw");
    }
    if (!Files.exists(keyPath)) {
        Stdio.printf("xcc: generating a debug signing key (once) -> %s\n", keyPath.cString());
        if (!writeDebugKey(keyPath)) {
            Stdio.printf("xcc: error: cannot create a signing key\n");
            driverExit((i32)1); return;
        }
    }
    // An optional committed classes.dex rides at the archive root, and the
    // manifest's hasCode follows it: with hasCode="false" ART never looks at
    // classes.dex, which is indistinguishable from a dex that failed to load.
    Data* dex = (Data*)0;
    CapOptions* c = d.caps();
    if (c.withDex() != (String*)0) {
        dex = Files.readData(c.withDex());
        if (dex == (Data*)0) {
            Stdio.printf("xcc: error: cannot read --with-dex '%s'\n", c.withDex().cString());
            driverExit((i32)1); return;
        }
    }
    // An extra prebuilt .so beside the payload (a shim whose onCreate runs
    // first, say), and --lib-name for which of the two the system loads.
    // Android loads from lib/arm64-v8a/ by soname, so the stored name has to
    // be the library's own lib<X>.so: its DT_SONAME when it has one (an
    // installed libUXKit-1-0.so is loaded as libUXKit.so, bug 635), else the
    // file's name.
    // Each --with-lib, in the order given (the option repeats).
    Array* extras = new Array();
    for (u32 w = (u32)0; w < c.withLibs().count(); w = w + (u32)1) {
        String* withLib = (String*)c.withLibs().get(w);
        Data* extraLib = Files.readData(withLib);
        if (extraLib == (Data*)0) {
            Stdio.printf("xcc: error: cannot read --with-lib '%s'\n", withLib.cString());
            driverExit((i32)1); return;
        }
        String* bn = androidSonameOf(withLib);
        if (!bn.hasPrefix(String.withCString("lib")) || !bn.hasSuffix(String.withCString(".so"))) {
            Stdio.printf("xcc: error: --with-lib '%s' must be named lib<name>.so "
                         "— Android resolves it from lib/arm64-v8a/ by that name\n", bn.cString());
            driverExit((i32)1); return;
        }
        String* extraEntry = String.withCString("lib/arm64-v8a/");
        extraEntry.append(bn);
        for (u32 k = (u32)0; k < extras.count(); k = k + (u32)1)
            if (((ApkEntry*)extras.get(k)).name.equals(extraEntry)) {
                Stdio.printf("xcc: error: --with-lib names %s twice\n", bn.cString());
                driverExit((i32)1); return;
            }
        extras.add((Object*)ApkEntry.with(extraEntry, extraLib));
    }
    String* manifestLib = name;
    if (c.libName() != (String*)0 && c.libName().byteLength() > (u32)0) manifestLib = c.libName();

    String* pkg = String.withCString("org.compile_xc.");
    pkg.append(name);
    for (u32 k = (u32)0; k < c.manifestAttrs().count(); k = k + (u32)1) {
        String* err = ApkXml.manifestAttrError((String*)c.manifestAttrs().get(k));
        if (err != (String*)0) {
            Stdio.printf("xcc: error: %s\n", err.cString());
            driverExit((i32)1); return;
        }
    }
    Data* manifest = ApkXml.manifest(pkg, manifestLib, name, (u32)24, (u32)35, dex != (Data*)0, c.manifestAttrs());

    Array* entries = new Array();
    entries.add((Object*)ApkEntry.with(String.withCString("AndroidManifest.xml"), manifest));
    String* libPath = String.withCString("lib/arm64-v8a/");
    libPath.append(soname);
    entries.add((Object*)ApkEntry.with(libPath, soBytes));
    for (u32 k = (u32)0; k < extras.count(); k = k + (u32)1) entries.add(extras.get(k));
    if (dex != (Data*)0) entries.add((Object*)ApkEntry.with(String.withCString("classes.dex"), dex));
    Data* zip = ApkZip.build(entries, (u32)4096, String.withCString(".so"));

    Data* kd = Files.readData(keyPath);
    if (kd == (Data*)0 || kd.length() < (u32)5) {
        Stdio.printf("xcc: error: cannot read the signing key '%s'\n", keyPath.cString());
        driverExit((i32)1); return;
    }
    u32 at = (u32)5;                                 // past "XKEY1"
    Data* kn = apkKeyField(kd, &at);
    Data* ke = apkKeyField(kd, &at);
    Data* kdd = apkKeyField(kd, &at);
    Data* kc = apkKeyField(kd, &at);
    Data* signedApk = ApkSign.sign(zip, kc, kn, ke, kdd);
    if (signedApk.length() == (u32)0) {
        Stdio.printf("xcc: error: apk signing failed\n");
        driverExit((i32)1); return;
    }
    if (!Files.writeData(out, signedApk)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", out.cString());
        driverExit((i32)1); return;
    }
    Stdio.printf("xcc: android APK -> '%s'  (adb install -r %s)\n",
                 out.cString(), out.cString());
}

// "XKEY1" then four little-endian length-prefixed blobs: n, e, d, cert.
Data* apkKeyField(Data* dd, u32* at)
{
    u32 p = *at;
    u32 n = (u32)dd.byteAt(p) | ((u32)dd.byteAt(p + (u32)1) << (u32)8)
          | ((u32)dd.byteAt(p + (u32)2) << (u32)16) | ((u32)dd.byteAt(p + (u32)3) << (u32)24);
    p = p + (u32)4;
    Data* out = dd.subdata(p, n);
    *at = p + n;
    return out;
}


// ── xt6502 ───────────────────────────────────────────────────────────────
//
// Not "the arm64 path with a different back end". Three things differ, and all
// three are the reason this took a runtime port rather than a flag:
//
//   * the memory map is a .lnk LAYOUT, not something the host implies;
//   * the runtime is a TREE of hand-written asm, LAZY-LINKED against what the
//     generated code actually calls (Runtime6502) — embedding all of it costs
//     ~1.4 KB in a program that never allocates;
//   * there is no separate linker. xta places the banked regions and writes
//     the XEX itself, so "assemble" and "link" are one step.
// `a/b/prog` -> `prog`. The loader references the module by BASE NAME, so a
// program built into a directory still finds its own .wasm beside it.
String* baseNameOf(String* path)
{
    u32 cut = (u32)0;
    for (u32 i = (u32)0; i < path.byteLength(); i = i + (u32)1)
        if (path.byteAt(i) == (u8)'/') cut = i + (u32)1;
    if (cut == (u32)0) return path;
    return path.substringBytes(cut, path.byteLength() - cut);
}

// ── wasm32 ───────────────────────────────────────────────────────────────
// IR in, a `.wasm` module out. The back end emits WAT and the writer turns it
// into the binary module — no assembler, no linker, no sysroot, which is why
// this one wires in-process as easily as m68k did.
//
// `-o x.wat` (or .s) stops at the text, the same rule every other target
// follows.

// A wasm CUSTOM section (id 0): [size][nameLen][name][payload], the size and
// name length both LEB128. Appended after the module's own sections, which is
// where a custom section is allowed to sit and where a reader looks for it.
void appendWasmCustomSection(Data* mod, String* name, String* payload)
{
    Data* body = new Data();
    // The name length is a LEB128; every name we emit is far under 128, so one
    // byte — but encode it properly rather than assuming.
    u32 n = name.byteLength();
    while (true) {
        u8 b = (u8)(n & (u32)$7F);
        n = n >> (u32)7;
        if (n != (u32)0) b = b | (u8)$80;
        body.appendByte(b);
        if (n == (u32)0) break;
    }
    for (u32 i = (u32)0; i < name.byteLength(); i = i + (u32)1) body.appendByte(name.byteAt(i));
    for (u32 i = (u32)0; i < payload.byteLength(); i = i + (u32)1) body.appendByte(payload.byteAt(i));

    mod.appendByte((u8)0);                       // section id 0 = custom
    u32 sz = body.length();
    while (true) {
        u8 b = (u8)(sz & (u32)$7F);
        sz = sz >> (u32)7;
        if (sz != (u32)0) b = b | (u8)$80;
        mod.appendByte(b);
        if (sz == (u32)0) break;
    }
    mod.append(body);
}

// The placement sidecar, read off the back end's own marker line rather than
// recomputed here: `;; xtc-lib data=<N> table=<M>`. Recomputing would be a
// second implementation of the layout, free to disagree with the one that
// actually laid it out.
//
// `deps` names the libraries this one imports, so the loader can load the
// ones an app does not import itself and set each library up before the
// libraries that import it.
String* wasmLibSidecar(String* wat, Array* deps)
{
    u32 dataSize = (u32)0;
    u32 tableSize = (u32)0;
    Array* lines = wat.splitOnByte((u8)'\n');
    for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
        String* ln = ((String*)lines.get(i)).trimmed();
        if (!ln.hasPrefix(String.withCString(";; xtc-lib "))) continue;
        dataSize  = uintAfter(ln, String.withCString("data="));
        tableSize = uintAfter(ln, String.withCString("table="));
        break;
    }
    String* j = new String();
    j.appendFormat("{\"dataSize\": %lu, \"tableSize\": %lu, \"deps\": ", dataSize, tableSize);
    j.append(wasmDepList(deps));
    j.appendCString("}\n");
    return j;
}

// The wasm libraries `#import <X>` resolved to, by bare name (lib<X>.wasm ->
// X), each once, in import order.
Array* wasmDepNames(FeOptions* fe)
{
    Array* names = new Array();
    Array* nl = fe.neededLibs();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
        String* lp = (String*)nl.get(i);
        if (!lp.hasSuffix(String.withCString(".wasm"))) continue;
        String* fn = baseNameOf(lp);
        if (!fn.hasPrefix(String.withCString("lib"))) continue;
        String* nm = fn.substringBytes((u32)3, fn.byteLength() - (u32)3 - (u32)5);
        bool seen = false;
        for (u32 k = (u32)0; k < names.count(); k = k + (u32)1)
            if (((String*)names.get(k)).equals(nm)) seen = true;
        if (!seen) names.add((Object*)nm);
    }
    return names;
}

// `["A", "B"]`, the form both the loader's __DEPS__ and the sidecar use.
String* wasmDepList(Array* names)
{
    String* s = String.withCString("[");
    for (u32 i = (u32)0; i < names.count(); i = i + (u32)1) {
        if (i > (u32)0) s.appendCString(", ");
        s.appendCString("\"");
        s.append((String*)names.get(i));
        s.appendCString("\"");
    }
    s.appendCString("]");
    return s;
}

u32 uintAfter(String* s, String* key)
{
    u32 at = s.byteIndexOf(key);
    if (at == String.notFound()) return (u32)0;
    u32 i = at + key.byteLength();
    u32 v = (u32)0;
    while (i < s.byteLength()) {
        u8 c = s.byteAt(i);
        if (c < (u8)'0' || c > (u8)'9') break;
        v = v * (u32)10 + (u32)(c - (u8)'0');
        i = i + (u32)1;
    }
    return v;
}

void emitWasm(DriverOptions* d, IRModule* mod)
{
    OptProfile* pw = OptProfile.forTarget(String.withCString("wasm32"));
    Opt.setUnrollOverride(pw, d.unroll());
    applyOptFlags(d, pw);
    Opt* opt = Opt.atLevel(d.opt(), pw);
    // A LIBRARY's public surface is every function it defines: nothing in the
    // module calls them, the CLIENT does, and dead-function elimination cannot
    // see the client. Without this the library dropped `Greeter$init` — a
    // constructor no internal code calls — and the app that did call it failed
    // at instantiation with `depExports[d][n] is not a function`.
    if (d.emitLib()) opt.setKeepAllFunctions(true);
    else if (linkJoinsObjects(d)) opt.setKeepClassRoot(true);
    opt.run(mod);
    dumpOptIR(d, mod);

    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    Wasm32* be = new Wasm32();
    be.setOptLevel(d.opt());
    be.setThreadSafeArcOverride(d.fe().threadSafeArc());
    // A library build is the back end's own mode — it emits the `;; xtc-lib
    // data=N table=M` marker the placement sidecar is read from, and a module
    // header with no start/_start.
    be.setEmitLib(d.emitLib());
    // An APP that imports a .wasm library is built in LINK-LIBS mode: it owns
    // memory and the table, exports `__data_end` for the loader to place each
    // library's statics after, and resolves the library's symbols through
    // package imports. Without it the loader had nothing to read and died on
    // `Cannot read properties of undefined (reading 'value')`.
    if (!d.emitLib()) {
        Array* nl = d.fe().neededLibs();
        for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1)
            if (((String*)nl.get(i)).hasSuffix(String.withCString(".wasm")))
                be.setLinkLibs(true);
        if (d.linkLibs()) be.setLinkLibs(true);   // --link-libs asks for it outright
    }
    // -x-wasm32,return-call: a tail call becomes `return_call`.
    if (d.tailCalls()) be.setTailCalls(true);
    // -ss: the app's shadow stack (a library runs on the app's).
    if (!d.emitLib()) be.setStackSize(d.stackSize());
    String* wat = be.assembly(mod);
    // The wasm back end reports a fatal unresolved import rather than a
    // generic failure — a module that imports something the host will not
    // supply cannot be instantiated, so it is refused here rather than
    // written and failing at load.
    if (be.fatalImport()) { driverExit((i32)1); return; }

    String* out = d.fe().output();
    if (d.keepAsm() || out.hasSuffix(String.withCString(".wat"))) {
        if (!Files.writeText(out, wat)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", out.cString());
            driverExit((i32)1); return;
        }
        return;
    }

    // ── library build ────────────────────────────────────────────────────
    // No loader: a library is instantiated BY an app's loader, not on its own.
    // Two extra outputs instead:
    //   * the interface, embedded as a `xtc.iface` CUSTOM section — the wasm
    //     analogue of the ELF `.xtc.iface`, so `#import <X>` reads the types
    //     out of the binary itself rather than a side file that can go missing.
    //   * lib<Name>.json, the placement sidecar {dataSize, tableSize, deps},
    //     which the loader needs BEFORE instantiating to know where to put the
    //     library's statics, how far to grow the table, and which libraries
    //     must be loaded and set up before this one.
    if (d.emitLib()) {
        String* lbase = out;
        if (lbase.hasSuffix(String.withCString(".wasm")))
            lbase = lbase.substringBytes((u32)0, lbase.byteLength() - (u32)5);
        WasmWriter* lw = new WasmWriter();
        Data* lmod = lw.moduleFromWat(wat);
        if (lmod == (Data*)0) {
            Stdio.printf("xcc: wasm write failed: %s\n",
                         lw.why() == 0 ? "(no detail)" : lw.why().cString());
            driverExit((i32)1); return;
        }
        String* iface = d.fe().ifaceJson();
        if (iface != (String*)0 && iface.byteLength() > (u32)0)
            appendWasmCustomSection(lmod, String.withCString("xtc.iface"), iface);
        String* wpath = String.withString(lbase); wpath.appendCString(".wasm");
        if (!Files.writeData(wpath, lmod)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", wpath.cString());
            driverExit((i32)1); return;
        }
        String* jpath = String.withString(lbase); jpath.appendCString(".json");
        if (!Files.writeText(jpath, wasmLibSidecar(wat, wasmDepNames(d.fe())))) {
            Stdio.printf("xcc: error: cannot write '%s'\n", jpath.cString());
            driverExit((i32)1); return;
        }
        if (!d.quiet())
            Stdio.printf("xcc: wasm32 library -> '%s' + '%s'\n",
                         wpath.cString(), jpath.cString());
        return;
    }

    // The `.js` LOADER beside the module. A `.wasm` with no way to instantiate
    // it is not a deliverable — the same shape as `-o x.s` writing a Mach-O.
    //
    // The template lives in the support tree rather than in either compiler:
    // it was 269 lines embedded in the reference's linker, and a second copy
    // here would be 269 lines to keep in step. One file, two readers, and the
    // two drivers emit the same loader by construction.
    String* tmpl = readRuntimeIn(d.fe(), "wasm32/runtime",
                                 String.withCString("loader.js.in"));
    if (tmpl == 0) {
        Stdio.printf("xcc: error: cannot read wasm32/runtime/loader.js.in "
                     "from the support tree\n");
        driverExit((i32)1); return;
    }
    String* base = out;
    if (base.hasSuffix(String.withCString(".wasm")))
        base = base.substringBytes((u32)0, base.byteLength() - (u32)5);
    String* js = tmpl.replacing(String.withCString("__BASE__"), baseNameOf(base));
    // The libraries this app `#import <X>`ed, by BARE name: the loader fetches
    // lib<X>.wasm and lib<X>.json beside the app and wires their exports into
    // its imports. Empty here meant the app instantiated with no library at
    // all and died on `missing host import env.Greeter$init` — the imports were
    // in the module, and nothing supplied them.
    js = js.replacing(String.withCString("__DEPS__"), wasmDepList(wasmDepNames(d.fe())));
    String* jsPath = String.withString(base);
    jsPath.appendCString(".js");
    if (!Files.writeText(jsPath, js)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", jsPath.cString());
        driverExit((i32)1); return;
    }

    WasmWriter* w = new WasmWriter();
    Data* module = w.moduleFromWat(wat);
    if (module == (Data*)0) {
        Stdio.printf("xcc: wasm write failed: %s\n",
                     w.why() == 0 ? "(no detail)" : w.why().cString());
        driverExit((i32)1); return;
    }
    String* wasmPath = String.withString(base);
    wasmPath.appendCString(".wasm");
    if (!Files.writeData(wasmPath, module)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", wasmPath.cString());
        driverExit((i32)1); return;
    }
    // A starter page beside them, so the module runs in a browser as well as
    // under node. Written only when there is none: the page is the user's to
    // change, and a rebuild must not undo that.
    String* htmlPath = String.withString(base);
    htmlPath.appendCString(".html");
    if (!Files.exists(htmlPath)) Files.writeText(htmlPath, starterHtml(baseNameOf(base)));
    if (!d.quiet())
        Stdio.printf("xcc: wasm32 module -> '%s.wasm' + '%s.js' (run: node %s.js)\n",
                     base.cString(), base.cString(), base.cString());
}

// The starter page: the program's stdout into a <pre>, through the loader's
// xccOut hook. Byte for byte the page the reference linker writes.
String* starterHtml(String* n)
{
    u8* b = n.cString();
    String* h = String.withFormat("<!doctype html>\n"
        "<!-- Generated once by xcc-ln-wasm32 for %s.wasm — edit freely; a rebuild\n"
        "     rewrites %s.js and %s.wasm but leaves this page alone. -->\n", b, b, b);
    h.appendCString("<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    h.append(String.withFormat("<title>%s</title>\n", b));
    h.appendCString("<style>\n"
        "  body { background: #1e1e1e; color: #d4d4d4; font: 14px/1.5 ui-monospace, monospace;\n"
        "         margin: 2rem; }\n"
        "  pre  { white-space: pre-wrap; }\n"
        "</style>\n</head>\n<body>\n");
    h.append(String.withFormat("<h1>%s</h1>\n", b));
    h.appendCString("<pre id=\"out\"></pre>\n<script>\n"
        "  const out = document.getElementById(\"out\");\n"
        "  globalThis.xccOut = (line) => { out.textContent += line + \"\\n\"; };\n"
        "  // Host packages (#package): define before the loader runs, e.g.\n"
        "  // globalThis.xccImports = { js: { jsPing: (v) => console.log(v) } };\n"
        "</script>\n");
    h.append(String.withFormat("<script src=\"%s.js\"></script>\n", b));
    h.appendCString("</body>\n</html>\n");
    return h;
}

// ── m68k / Atari ST ──────────────────────────────────────────────────────
// IR in, a GEMDOS $601A executable out. The assembler writes the container
// itself — there is no separate linker step and no sysroot, which is why this
// target could be wired in-process while x86_64 and win64 wait on archive
// reading (task #47).

// A per-class allocator thunk for every `_xtc_new_<Class>` the program
// mentions. The reference builds these by scanning its own assembly, and they
// go in as a SEPARATE linker input rather than being concatenated: the linker
// namespaces each input's local labels, and a plain concatenation of
// separately compiled files collides on clang's `.LBB` numbering.
// One list, not two in one file: this used to carry its own copy and they
// drifted (bug 233).
bool isPrimName(String* c)
{
    return isPrimitiveName(c);
}

String* x86ClassAllocStubs(String* prog, bool win64)
{
    String* out = new String();
    Array* seen = new Array();
    String* needle = String.withCString("_xtc_new_");
    u32 i = (u32)0;
    while (i < prog.byteLength()) {
        u32 at = prog.byteIndexOf(needle, i);
        if (at == String.notFound()) break;
        u32 j = at + needle.byteLength();
        String* cls = new String();
        while (j < prog.byteLength()) {
            u8 c = prog.byteAt(j);
            bool ok = (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z')
                   || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_';
            if (!ok) break;
            cls.appendByte(c);
            j = j + (u32)1;
        }
        i = j;
        if (cls.byteLength() == (u32)0 || isPrimName(cls)) continue;
        bool dup = false;
        for (u32 k = (u32)0; k < seen.count(); k = k + (u32)1)
            if (((String*)seen.get(k)).equals(cls)) dup = true;
        if (dup) continue;
        seen.add((Object*)cls);
        String* deallocMark = String.withString(cls);
        deallocMark.appendCString("$dealloc:");
        bool hasDe = prog.contains(deallocMark);
        out.appendCString("\t.intel_syntax noprefix\n\t.text\n\t.globl\t_xtc_new_");
        out.append(cls); out.appendCString("\n_xtc_new_");
        out.append(cls); out.appendCString(":\n");
        if (hasDe) {
            // The dealloc hook is `_xtc_alloc`'s THIRD argument: rdx under SysV,
            // r8 under Win64 (bug 141: the port passed it in rdx on win64 too —
            // a one-byte encoding difference that was also the wrong register).
            out.appendCString(win64 ? "\tlea\tr8, [rip+" : "\tlea\trdx, [rip+");
            out.append(cls);
            out.appendCString("$dealloc]\n");
        } else {
            // No dealloc hook: plain data, and an array of 64 KB or more is
            // page-aligned and registered as a numeric one is, so a par block
            // can size it and share it with the GPU (#113). As the reference.
            out.appendCString(win64 ? "\tmov\trax, rcx\n\timul\trax, rdx\n\txor\tr8d, r8d\n"
                                    : "\tmov\trax, rdi\n\timul\trax, rsi\n\txor\tedx, edx\n");
            out.appendCString("\tcmp\trax, 65536\n\tjb\t.L_xtc_new_");
            out.append(cls); out.appendCString("_small\n\tjmp\t_xtc_alloc_aligned\n.L_xtc_new_");
            out.append(cls); out.appendCString("_small:\n");
        }
        out.appendCString("\tjmp\t_xtc_alloc\n");
    }
    return out;
}

// musl's libc.a, looked for where the reference looks: the environment first,
// then the toolchain, then the vendored sysroot. A miss is a HARD error — a
// static link with no pool cannot be completed, and saying so beats emitting
// something that will not run.
String* muslLibDir(FeOptions* o)
{
    String* env = Platform.env(String.withCString("XTC_MUSL_ROOT"));
    if (env != 0 && env.byteLength() > (u32)0) {
        String* c = String.withString(env);
        c.appendCString("/lib/libc.a");
        if (Files.exists(c)) { String* d = String.withString(env); d.appendCString("/lib"); return d; }
    }
    String* tc = String.withCString("/opt/clang/linux/x86_64-linux-musl/lib");
    String* c1 = String.withString(tc); c1.appendCString("/libc.a");
    if (Files.exists(c1)) return tc;
    String* root = supportRoot(o);
    if (root != 0) {
        String* v = String.withString(root);
        v.appendCString("/x86_64-sysroot");
        String* c2 = String.withString(v); c2.appendCString("/libc.a");
        if (Files.exists(c2)) return v;
    }
    return (String*)0;
}

// The clang target words for the C path (` -target <triple> --sysroot <root>`),
// empty when the target is the host, or 0 after saying why it cannot be
// built here. A program for x86-64 Linux or win64 built on another host needs
// that target's C headers: the musl root ($XTC_MUSL_ROOT, else
// /opt/clang/linux/x86_64-linux-musl) or the mingw one
// (/opt/clang/win64/x86_64-w64-mingw32), each with an include/ directory.
// The sysroot a C or C++ build for another target uses (cPathTargetFlags),
// whose library directories the link searches for a -l:<file> too.
String* gCPathRoot;

String* cPathTargetFlags(DriverOptions* d, bool cxx)
{
#if OS_windows
    String* host = String.withCString("win64");
#elif ARCH_x86_64
    String* host = String.withCString("x86_64");
#elif ARCH_armv7
    String* host = String.withCString("arm9");
#elif OS_linux
    String* host = String.withCString("arm64-linux");
#else
    String* host = String.withCString("arm64");
#endif
    String* a = d.arch();
    // arm64 Linux: atomics inline (-mno-outline-atomics). Outlined, they are
    // calls to __aarch64_ldadd4_acq_rel and its kin, which only GCC's static
    // libgcc.a defines, and xcc's link takes the shared libgcc_s.
    String* atom = (rowCpu(d, "arm64") && rowOs(d, "linux")) ? String.withCString(" -mno-outline-atomics") : String.withCString("");
    if (a.equals(host))
        return atom;
    // The row's clang target (the target table); its C headers from a root
    // for that target: musl's for x86-64 Linux, mingw's for win64, glibc's
    // (usr/include, copied from an arm64 Linux machine) for arm64 Linux.
    TargetRow* row = d.targetRow();
    String* triple = row != (TargetRow*)0 ? row.cTriple() : String.withCString("");
    String* root = (String*)0;
    String* rootVar = (String*)0;
    if (triple.byteLength() == (u32)0) {
        Stdio.error(String.withFormat("xcc: error: a C program builds for the host or for x86_64, win64 and arm64-linux; not for '%s'\n", a.cString()));
        return (String*)0;
    }
    // The row's header root and the variable that overrides it; C++ has its
    // own (it links the target's libstdc++).
    root = cxx ? row.cxxRoot() : row.cRoot();
    rootVar = cxx ? row.cxxRootVar() : row.cRootVar();
    if (rootVar != (String*)0) {
        String* env = Platform.env(rootVar);
        if (env != 0 && env.byteLength() > (u32)0) root = env;
    }
    // musl's and mingw's roots keep the headers in include/, glibc's in usr/include.
    String* hdr = String.withString(root);
    hdr.appendCString("/include/stdio.h");
    String* hdr2 = String.withString(root);
    hdr2.appendCString("/usr/include/stdio.h");
    if (!Files.exists(hdr) && !Files.exists(hdr2)) {
        Stdio.error(String.withFormat("xcc: error: a C program for %s built on this host needs that target's C headers: "
                                      "none at %s/include or %s/usr/include%s%s%s (build it on that host instead)\n",
                                      a.cString(), root.cString(), root.cString(),
                                      rootVar != (String*)0 ? " (set " : "",
                                      rootVar != (String*)0 ? rootVar.cString() : "",
                                      rootVar != (String*)0 ? " to a sysroot)" : ""));
        return (String*)0;
    }
    gCPathRoot = root;
    String* f = String.withCString(" -target ");
    f.append(triple);
    f.appendCString(" --sysroot ");
    f.append(root);
    f.append(atom);
    // C++ from a glibc root: clang finds libstdc++'s headers only beside a
    // whole GCC installation (crtbegin.o), which a copied usr/include lacks,
    // so they are named: usr/include/c++/<N> (the newest), its target
    // directory and backward/, for C++ compilations only (-cxx-isystem).
    if (cxx)
        f.append(cxxHeaderFlags(root));
    return f;
}

// The -cxx-isystem flags for a glibc root's libstdc++ headers, or "".
String* cxxHeaderFlags(String* root)
{
    String* out = String.withCString("");
    String* base = String.withFormat("%s/usr/include/c++", root.cString());
    Array* vs = Directory.list(base);
    if (vs == (Array*)0)
        return out;
    String* best = (String*)0;
    i64 bestN = (i64)-1;
    for (u32 i = (u32)0; i < vs.count(); i = i + (u32)1) {
        String* v = ((DirEntry*)vs.get(i)).name;
        i64 n = (i64)0;
        bool num = v.byteLength() > (u32)0;
        for (u32 k = (u32)0; k < v.byteLength() && num; k = k + (u32)1) {
            u8 c = v.byteAt(k);
            if (c < (u8)'0' || c > (u8)'9') num = false;
            else n = n * (i64)10 + (i64)(c - (u8)'0');
        }
        if (num && n > bestN) { bestN = n; best = v; }
    }
    if (best == (String*)0)
        return out;
    out.appendFormat(" -cxx-isystem %s/%s", base.cString(), best.cString());
    // The target directory: usr/include/<multiarch>/c++/<N>.
    Array* ds = Directory.list(String.withFormat("%s/usr/include", root.cString()));
    for (u32 i = (u32)0; ds != (Array*)0 && i < ds.count(); i = i + (u32)1) {
        String* dname = ((DirEntry*)ds.get(i)).name;
        String* t = String.withFormat("%s/usr/include/%s/c++/%s", root.cString(), dname.cString(), best.cString());
        if (dname.contains(String.withCString("-linux-")) && Files.exists(t))
            out.appendFormat(" -cxx-isystem %s", t.cString());
    }
    out.appendFormat(" -cxx-isystem %s/%s/backward", base.cString(), best.cString());
    return out;
}

// ── win64 ────────────────────────────────────────────────────────────────
//
// The same back end as x86_64 with the MS ABI, then the PE writer. Windows has
// no stable syscall ABI, so unlike Linux the imports are unavoidable:
// kernel32.dll is the floor, and the wider `win32-imports.map` rides along —
// listing a symbol there costs nothing in the binary, because the writer emits
// a descriptor only for names the program actually references.
void emitWin64(DriverOptions* d, IRModule* mod)
{
    OptProfile* pw = OptProfile.forTarget(String.withCString("win64"));
    Opt.setUnrollOverride(pw, d.unroll());
    applyOptFlags(d, pw);
    Opt* prof = Opt.atLevel(d.opt(), pw);
    // An OBJECT's functions are all potentially called from ANOTHER object, so
    // cross-function DCE must not read "nothing here calls it" as dead.
    if (d.emitLib() || (d.compileOnly() && gCSplitOut == (String*)0)) prof.setKeepAllFunctions(true);
    else if (linkJoinsObjects(d)) prof.setKeepClassRoot(true);
    prof.run(mod);
    dumpOptIR(d, mod);

    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    X86_64* be = new X86_64();
    be.setWin64(true);
    be.setThreadSafeArcOverride(d.fe().threadSafeArc());
    be.setBuildFma(!pw.simdDispatch() && pw.vectorLaneBytes() >= (u32)32);
    String* prog = be.assembly(mod);
    if (be.failed()) {
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < be.missing().count(); k = k + (u32)1) {
            if (k > (u32)0) list.appendCString(" ");
            list.append((String*)be.missing().get(k));
        }
        Stdio.printf("xcc: %s: unsupported: %s\n", d.fe().input().cString(), list.cString());
        driverExit((i32)3); return;
    }
    if (d.keepAsm()) {
        if (!writeAsmOut(d, prog)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            driverExit((i32)1); return;
        }
        return;
    }

    // One assembly unit: crt, runtime, per-class allocator stubs, program.
    if (d.compileOnly()) {
        // An OBJECT: stubs + program assembled, every unresolved fixup a
        // COFF relocation, the kernel32 imports included — an object
        // declares no import table (bug 139/141).
        String* one = new String();
        one.append(x86ClassAllocStubs(prog, true));
        one.appendCString("\n");
        one.append(prog);
        X86Asm* oa = new X86Asm();
        oa.assemble(one);
        if (oa.failed()) {
            Stdio.printf("xcc: assembly failed: %s\n", oa.why().cString());
            driverExit((i32)1); return;
        }
        Pe* pw = new Pe();
        pw.setDirectives(objectDepLibs(d));
        pw.setSeh(oa.sehFunctions());
        Data* od = pw.objectFromText(oa.text(), oa.data(), oa.symbols(), oa.dataSyms(),
                                     oa.globalSyms(), oa.fixups());
        if (pw.failed() || od == (Data*)0) {
            Stdio.printf("xcc: %s\n", pw.failed() ? pw.why().cString() : "object write failed");
            driverExit((i32)1); return;
        }
        if (!Files.writeData(d.fe().output(), od)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            driverExit((i32)1); return;
        }
        writeObjectSidecars(d);
        if (gCSplitOut != (String*)0) {
            gHalfXcArgs = xcArgsWanted(d, prog);
            cSplitLink(d);
        }
        return;
    }
    linkWin64(d, prog);
}

// The mingw toolchain root the win64 pool and `-l` archives come from.
String* win64Toolchain(void)
{
    String* env = Platform.env(String.withCString("XTC_WIN64_TOOLCHAIN"));
    if (env != 0 && env.byteLength() > (u32)0) return env;
    return String.withCString("/opt/clang/win64");
}

// The Windows C runtime as a POOL our own linker pulls from (bug 141): mingw's
// libmingwex.a (its C99 code), libmsvcrt.a (the ucrt_extra objects — where
// snprintf actually lives), and the compiler builtins LAST. Each falls back
// to the install's vendored win64-sysroot copy; absence stays non-fatal, the
// freestanding runtime carries its own printf and allocator.
Array* win64Pool(DriverOptions* d)
{
    Array* out = new Array();
    String* tc = win64Toolchain();
    String* vend = supportRoot(d.fe());
    Array* rels = new Array();
    rels.add((Object*)String.withCString("x86_64-w64-mingw32/lib/libmingwex.a"));
    rels.add((Object*)String.withCString("x86_64-w64-mingw32/lib/libmsvcrt.a"));
    rels.add((Object*)String.withCString("x86_64-w64-mingw32/clang-rt/libclang_rt.builtins-x86_64.a"));
    for (u32 i = (u32)0; i < rels.count(); i = i + (u32)1) {
        String* rel = (String*)rels.get(i);
        String* p = String.withString(tc); p.appendCString("/"); p.append(rel);
        if (Files.exists(p)) { out.add((Object*)p); continue; }
        if (vend == (String*)0) continue;
        String* v = String.withString(vend); v.appendCString("/win64-sysroot/"); v.append(rel.lastPathComponent());
        if (Files.exists(v)) out.add((Object*)v);
    }
    return out;
}

// The per-program inputs a win64 link adds to the runtime: the class
// allocator stubs, and for a DLL whose module has no load-time constructors an
// empty constructor table, so dllmain-win64.s always has one to walk.
String* win64StubSource(String* prog, bool shared)
{
    String* stubs = x86ClassAllocStubs(prog, true);
    if (shared && !prog.contains(String.withCString("\n__xt_ctors_start:")))
        stubs.appendCString("\t.data\n__xt_ctors_start:\n__xt_ctors_end:\n\t.text\n");
    return stubs;
}

// The win64 link, from program asm (or none — an object-only link) to the PE
// on disk: runtime + stubs + program assembled as one input, then the
// objects and archives named on the line, then the C-runtime pool, then the
// kernel32 imports and the import map for whatever the pool did not define.
//
// With --emit-lib the same link writes a DLL (bug 255): the runtime without
// crt-win64.s, whose place dllmain-win64.s takes, every `.globl` exported, and
// the interface in an `xtciface` section. An xc library the program imports
// (`libLib.dll`) is linked against by reading its export directory — no import
// library.
void linkWin64(DriverOptions* d, String* prog)
{
    bool shared = d.emitLib() && !d.compileOnly();
    Array* srcs = new Array();
    Array* rtNames = new Array();
    if (!shared) rtNames.add((Object*)String.withCString("crt-win64.s"));
    bool xcArgs = !shared && xcArgsFor(d, prog);
    if (xcArgs) rtNames.add((Object*)String.withCString("xcargs-win64.s"));
    rtNames.add((Object*)String.withCString("rtgen-win64.s"));
    rtNames.add((Object*)String.withCString("rtfiles-win64.s"));
    rtNames.add((Object*)String.withCString("libmgen-win64.s"));
    if (shared) rtNames.add((Object*)String.withCString("dllmain-win64.s"));
    for (u32 k = (u32)0; k < rtNames.count(); k = k + (u32)1) {
        String* t = readRuntimeIn(d.fe(), "win64/runtime", (String*)rtNames.get(k));
        if (t == 0) {
            Stdio.printf("xcc: error: cannot read %s from the support tree\n",
                         ((String*)rtNames.get(k)).cString());
            driverExit((i32)1); return;
        }
        if (xcArgs && k == (u32)0) t = crtWithXcArgs(t);
        srcs.add((Object*)t);
    }
    srcs.add((Object*)win64StubSource(prog, shared));
    srcs.add((Object*)prog);

    String* src = new String();
    for (u32 k = (u32)0; k < srcs.count(); k = k + (u32)1) {
        // `.L` locals are namespaced per input for the same reason the x86_64
        // path does it: clang restarts its numbering per translation unit, so a
        // plain concatenation makes the first file's branches land in the
        // second.
        src.append(X86Link.namespaceLocals((String*)srcs.get(k), k));
        src.appendCString("\n");
    }

    X86Asm* a = new X86Asm();
    a.assemble(src);
    if (a.failed()) {
        Stdio.printf("xcc: assembly failed: %s\n", a.why().cString());
        driverExit((i32)1); return;
    }

    // Bug 141: objects named as inputs or via -Xlinker/-Wl, archives from
    // -l on the -L/mingw path, then the C-runtime pool — merged into the
    // assembler's model exactly as xcc-ln-win64 does.
    Array* objs = new Array();
    Array* ars = new Array();
    for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1) {
        String* op = (String*)d.objectInputs().get(i);
        if (op.hasSuffix(String.withCString(".a"))) ars.add((Object*)op); else objs.add((Object*)op);
    }
    Array* li = d.linkInputs();
    for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) {
        String* lp = resolveLinkInput(d, (String*)li.get(i));
        if (lp == (String*)0) continue;
        if (lp.hasSuffix(String.withCString(".o"))) objs.add((Object*)lp);
        else if (lp.hasSuffix(String.withCString(".a"))) ars.add((Object*)lp);
        else {
            Stdio.printf("xcc: error: '%s': a win64 link takes .o objects and .a archives — "
                         "it has no external linker to hand anything else to\n", lp.cString());
            driverExit((i32)1); return;
        }
    }
    Array* pool = win64Pool(d);
    for (u32 i = (u32)0; i < pool.count(); i = i + (u32)1) ars.add(pool.get(i));
    if (objs.count() > (u32)0 || ars.count() > (u32)0) {
        PeLink* pl = new PeLink();
        pl.merge(objs, ars, a.text(), a.data(), a.symbols(), a.dataSyms(), a.fixups());
        if (pl.rc() != (u32)0) {
            Stdio.printf("xcc: error: win64 link: %s\n", pl.why() == 0 ? "?" : pl.why().cString());
            driverExit((i32)1); return;
        }
    }

    // The import table: the kernel32 floor first, then whatever the map adds.
    Array* dlls = new Array();
    Array* syms = new Array();
    dlls.add((Object*)String.withCString("kernel32.dll"));
    Array* k32 = new Array();
    k32.add((Object*)String.withCString("ExitProcess"));
    k32.add((Object*)String.withCString("GetStdHandle"));
    k32.add((Object*)String.withCString("WriteFile"));
    k32.add((Object*)String.withCString("VirtualAlloc"));
    k32.add((Object*)String.withCString("GetSystemTimeAsFileTime"));
    k32.add((Object*)String.withCString("Sleep"));
    syms.add((Object*)k32);
    // Every name already importable, so each symbol lands in ONE list: an
    // explicit entry wins, then the xc DLLs in the order the program imported
    // them, then the map.
    Map* listed = new Map();
    for (u32 j = (u32)0; j < k32.count(); j = j + (u32)1)
        listed.set((Hashable*)(String*)k32.get(j), (Object*)k32.get(j));
    {
        Array* nl = d.fe().neededLibs();
        for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
            String* lp = (String*)nl.get(i);
            if (!lp.lowercased().hasSuffix(String.withCString(".dll"))) continue;
            Array* ex = Pe.dllExports(lp);
            if (ex == (Array*)0) {
                Stdio.printf("xcc: error: '%s' is not a DLL with an export directory\n",
                             lp.cString());
                driverExit((i32)1); return;
            }
            String* dn = lp.lastPathComponent();
            i32 at = (i32)-1;
            for (u32 k = (u32)0; k < dlls.count(); k = k + (u32)1)
                if (((String*)dlls.get(k)).equals(dn)) at = (i32)k;
            if (at < (i32)0) {
                dlls.add((Object*)dn);
                syms.add((Object*)new Array());
                at = (i32)(dlls.count() - (u32)1);
            }
            Array* into = (Array*)syms.get((u32)at);
            for (u32 k = (u32)0; k < ex.count(); k = k + (u32)1) {
                String* sym = (String*)ex.get(k);
                if (listed.get((Hashable*)sym) != (Object*)0) continue;
                listed.set((Hashable*)sym, (Object*)sym);
                into.add((Object*)sym);
            }
        }
    }
    {
        String* body = readRuntimeIn(d.fe(), "win64",
                                     String.withCString("win32-imports.map"));
        if (body != 0) {
            Array* lines = body.splitOnByte((u8)'\n');
            for (u32 k = (u32)0; k < lines.count(); k = k + (u32)1) {
                String* ln = (String*)lines.get(k);
                if (ln.byteLength() == (u32)0 || ln.hasPrefix(String.withCString("#"))) continue;
                u32 tab = ln.byteIndexOf(String.withCString("\t"));
                if (tab == (u32)$FFFF_FFFF) continue;
                String* sym = ln.substringBytes((u32)0, tab);
                String* dll = ln.substringFromByte(tab + (u32)1).trimmed();
                // A third column is the export the symbol binds to (close ->
                // _close): passed on to the writer as `close=_close`.
                String* entry = sym;
                u32 tab2 = dll.byteIndexOf(String.withCString("\t"));
                if (tab2 != (u32)$FFFF_FFFF) {
                    entry = String.withString(sym);
                    entry.appendCString("=");
                    entry.append(dll.substringFromByte(tab2 + (u32)1).trimmed());
                    dll = dll.substringBytes((u32)0, tab2);
                }
                if (sym.byteLength() == (u32)0 || dll.byteLength() == (u32)0) continue;
                // An explicit entry wins: the floor above is what the runtime
                // itself calls, and the map is a wider catalogue that may name
                // the same symbol in a different DLL.
                if (listed.get((Hashable*)sym) != (Object*)0) continue;
                listed.set((Hashable*)sym, (Object*)sym);
                i32 at = (i32)-1;
                for (u32 i = (u32)0; i < dlls.count(); i = i + (u32)1)
                    if (((String*)dlls.get(i)).equals(dll)) at = (i32)i;
                if (at < (i32)0) {
                    dlls.add((Object*)dll);
                    syms.add((Object*)new Array());
                    at = (i32)(dlls.count() - (u32)1);
                }
                ((Array*)syms.get((u32)at)).add((Object*)entry);
            }
        }
    }

    Pe* pe = new Pe();
    if (shared) {
        // The library publishes what the assembler saw `.globl`, as the x86-64
        // shared object does, and carries its interface so `#import <Lib>`
        // reads the types out of the binary.
        Data* iface = (Data*)0;
        String* ij = d.fe().ifaceJson();
        if (ij != (String*)0 && ij.byteLength() > (u32)0) {
            iface = Data.withCapacity(ij.byteLength());
            for (u32 i = (u32)0; i < ij.byteLength(); i = i + (u32)1)
                iface.appendByte(ij.byteAt(i));
        }
        pe.dll(a.text(), a.data(), a.symbols(), a.dataSyms(), a.fixups(),
               String.withCString("_xt_dll_main"), dlls, syms,
               d.fe().output().lastPathComponent(), a.globalSyms(), iface);
    } else
        pe.executable(a.text(), a.data(), a.symbols(), a.dataSyms(), a.fixups(),
                      String.withCString("_start"), dlls, syms);
    if (pe.failed()) {
        noteUndefinedCall(d, pe.why());
        Stdio.printf("xcc: %s\n", pe.why().cString());
        driverExit((i32)1); return;
    }
    Data* out = pe.bytes();
    if (!Files.writeData(d.fe().output(), out)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        driverExit((i32)1); return;
    }
    Files.setExecutable(d.fe().output());
}

// The three files `-c` leaves beside the object. Each is a BUILD ARTIFACT of
// compiling the module, exactly as the `.o` is.
//
//   * `.xtc.iface` — whoever compiles against this module reads it rather than
//     its source.
//   * `.xtc.needs` — `#import <Lib>` is a FRONT-END fact, and an object link
//     has no front end, so without this the linker cannot know the program
//     needs the library at all. It does not fail at link; it fails at LOAD.
//     Written even when EMPTY, so a link can tell "needs nothing" from "this
//     object predates the sidecar". SHARED libraries only — a `.a` is linked
//     in, not loaded, and recording one made every object link refuse itself.
//   * `.xtc.ir` — so a later link can re-run the inliner across module
//     boundaries, which per-object compilation otherwise gives up.
//
// A sidecar with nothing to say is removed, so one left by an earlier build of
// the same object cannot be read as this one's: `-flto` would otherwise build
// the old program from a stale `.xtc.ir`.
void writeObjectSidecars(DriverOptions* d)
{
    String* base = stripExtension(d.fe().output());
    writeSidecar(base, ".xtc.iface", d.fe().ifaceJson());
    String* needs = new String();
    Array* nl = d.fe().neededLibs();
    // arm9's libc is auto-imported rather than `#import`ed, and the reference
    // lists it first when the module names any of its functions. Without it
    // an object link ordered DT_NEEDED differently from the reference's.
    if (isArm9(d) && d.fe().libcReferenced()) {
        String* libc = arm9SysrootLib(d, String.withCString("libc.so"));
        if (libc != (String*)0) {
            Array* withLibc = new Array();
            withLibc.add((Object*)libc);
            for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1)
                if (!((String*)nl.get(i)).equals(libc)) withLibc.add(nl.get(i));
            nl = withLibc;
        }
    }
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
        String* l = (String*)nl.get(i);
        // A framework the module imported by name (`framework:CoreFoundation`)
        // goes with the object too: the link that takes it adds the framework.
        if (!l.hasSuffix(String.withCString(".so"))
         && !l.hasSuffix(String.withCString(".dylib"))
         && !l.contains(String.withCString(".so."))
         && !l.hasPrefix(String.withCString("framework:"))) continue;
        if (needs.byteLength() > (u32)0) needs.appendCString("\n");
        needs.append(l);
    }
    String* np = String.withString(base); np.appendCString(".xtc.needs");
    if (!Files.writeText(np, needs)) {
        Stdio.error(String.withFormat("xcc: error: cannot write '%s'\n", np.cString()));
        driverExit((i32)1); return;
    }
    writeSidecar(base, ".xtc.ir", d.irText());
}

// <base><ext> holds text when there is any; otherwise it is removed. Either
// failing stops the build.
void writeSidecar(String* base, string ext, String* text)
{
    String* p = String.withString(base); p.appendCString(ext);
    if (text != (String*)0 && text.byteLength() > (u32)0) {
        if (!Files.writeText(p, text)) {
            Stdio.error(String.withFormat("xcc: error: cannot write '%s'\n", p.cString()));
            driverExit((i32)1);
        }
        return;
    }
    if (Files.exists(p) && !Directory._unlink(p)) {
        Stdio.error(String.withFormat("xcc: error: cannot remove the stale '%s'\n", p.cString()));
        driverExit((i32)1);
    }
}

// A C file's object, made from xcc's half (at xo) and clang's: its sidecars.
// The needs are xcc's half's, so an object link adds the libraries and
// frameworks its par runtime calls. It has no interface, and the IR covers
// only xcc's half, so `-flto` refuses the object rather than build part of it.
void writeCObjectSidecars(String* xo, String* out)
{
    String* xbase = stripExtension(xo);
    String* base = stripExtension(out);
    String* xn = String.withString(xbase); xn.appendCString(".xtc.needs");
    String* needs = Files.readText(xn);
    if (needs == (String*)0) needs = new String();
    String* np = String.withString(base); np.appendCString(".xtc.needs");
    if (!Files.writeText(np, needs)) {
        Stdio.error(String.withFormat("xcc: error: cannot write '%s'\n", np.cString()));
        driverExit((i32)1); return;
    }
    writeSidecar(base, ".xtc.iface", (String*)0);
    writeSidecar(base, ".xtc.ir", (String*)0);
}

// `a/b.o` -> `a/b`. The LAST dot only, and only after the last separator, so a
// path with a dotted directory keeps it.
String* stripExtension(String* p)
{
    u32 cut = String.notFound();
    for (u32 i = (u32)0; i < p.byteLength(); i = i + (u32)1) {
        u8 c = p.byteAt(i);
        if (c == (u8)'/') cut = String.notFound();
        else if (c == (u8)'.') cut = i;
    }
    if (cut == String.notFound()) return String.withString(p);
    return p.substringBytes((u32)0, cut);
}

void emitX86_64(DriverOptions* d, IRModule* mod)
{
    OptProfile* px = OptProfile.forTarget(String.withCString("x86_64"));
    Opt.setUnrollOverride(px, d.unroll());
    applyOptFlags(d, px);
    Opt* prof = Opt.atLevel(d.opt(), px);
    // A LIBRARY keeps every function it defines — the client is what calls
    // them, and dead-function elimination cannot see the client.
    // An OBJECT's functions are all potentially called from ANOTHER object, so
    // cross-function DCE must not read "nothing here calls it" as dead.
    if (d.emitLib() || (d.compileOnly() && gCSplitOut == (String*)0)) prof.setKeepAllFunctions(true);
    else if (linkJoinsObjects(d)) prof.setKeepClassRoot(true);
    prof.run(mod);
    dumpOptIR(d, mod);

    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    X86_64* be = new X86_64();
    be.setThreadSafeArcOverride(d.fe().threadSafeArc());
    be.setBuildFma(!px.simdDispatch() && px.vectorLaneBytes() >= (u32)32);
    String* prog = be.assembly(mod);
    if (be.failed()) {
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < be.missing().count(); k = k + (u32)1) {
            if (k > (u32)0) list.appendCString(" ");
            list.append((String*)be.missing().get(k));
        }
        Stdio.printf("xcc: %s: unsupported: %s\n", d.fe().input().cString(), list.cString());
        driverExit((i32)3); return;
    }
    if (d.keepAsm()) {
        if (!writeAsmOut(d, prog)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            driverExit((i32)1); return;
        }
        return;
    }

    // ── -c: an object, not an image ──────────────────────────────────────
    if (d.compileOnly()) {
        // A C/C++ file's xcc half links libRuntime (when the target has one):
        // it reads the library's canary guard through the GOT, as a program
        // that takes it does (linkX86_64Glibc), the rewrite made here since
        // the link sees only the object.
        if (gCSplitOut != (String*)0 && d.fe().runtimeLibFile() != (String*)0 && !d.caps().staticLink())
            prog = guardThroughGotX86(prog);
        String* one = new String();
        one.append(x86ClassAllocStubs(prog, false));
        one.appendCString("\n");
        one.append(prog);
        X86Asm* as = new X86Asm();
        as.assemble(one);
        if (as.failed()) {
            Stdio.printf("xcc: %s\n", as.why().cString());
            driverExit((i32)1); return;
        }
        Elf64* w = new Elf64();
        w.setDepLibs(objectDepLibs(d));
        Data* img = w.objectFromText(as.text(), as.data(), as.symbols(),
                                      as.dataSyms(), as.globalSyms(), as.commonSyms(), as.fixups());
        if (w.failed() || img == (Data*)0) {
            Stdio.printf("xcc: %s\n", w.failed() ? w.why().cString() : "object write failed");
            driverExit((i32)1); return;
        }
        if (!Files.writeData(d.fe().output(), img)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            driverExit((i32)1); return;
        }
        writeObjectSidecars(d);
        if (gCSplitOut != (String*)0) {
            gHalfXcArgs = xcArgsWanted(d, prog);
            cSplitLink(d);
        }
        return;
    }

    if (x86GlibcLink(d)) { linkX86_64Glibc(d, prog); return; }
    linkX86_64(d, prog);
}

// Does the executable link against glibc? The default on -A x86_64, except
// where the program imports a library xcc built (its .so carries the musl
// runtime): that keeps the musl dynamic link unless -dynamic was given. A
// library xcc built carries a `.xtc.iface` section. As the reference.
bool x86GlibcLink(DriverOptions* d)
{
    if (!d.caps().dynamic()) return false;
    if (d.caps().dynamicExplicit()) return true;
    // A library xcc built against glibc (--emit-lib without -static, from
    // 0.73) names libc.so.6 among its DT_NEEDED; a musl one never does.
    Array* nl = d.fe().neededLibs();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
        Data* data = Files.readData((String*)nl.get(i));
        if (data == (Data*)0) continue;
        if (dataContains(data, String.withCString(".xtc.iface"), false)
            && !dataContains(data, String.withCString("libc.so.6"), true))
            return false;
    }
    return true;
}

// Whether `data` holds the bytes of `s` (and its NUL when `nul`).
bool dataContains(Data* data, String* s, bool nul)
{
    u8* p = data.bytes();
    u32 n = data.length();
    u32 m = s.byteLength() + (nul ? (u32)1 : (u32)0);
    for (u32 k = (u32)0; k + m <= n; k = k + (u32)1) {
        bool same = true;
        for (u32 q = (u32)0; q < m && same; q = q + (u32)1)
            if (p[k + q] != (q < s.byteLength() ? s.byteAt(q) : (u8)0)) same = false;
        if (same) return true;
    }
    return false;
}

// The x86-64 link, from program asm (or none — an object-only link) to the
// ELF on disk. Split out of emitX86_64 so `xcc a.o b.o -o prog` can reach it
// without a module (bug 138).
// `-dynamic`: an x86-64 executable linked dynamically against glibc — what a
// program needs to load GTK 4 or libGL, which a static musl image cannot. All
// in-house: the glibc runtime (crt-glibc.s, rtgen-glibc.s) is in the support
// tree, glibc's exports come from glibc-imports.map, and each -l library is
// read for its SONAME and what it defines. Same inputs, in the same order, as
// the reference driver's linkX86_64Glibc.
// A directory as the reference spells it (NSString's stringByStandardizingPath):
// a leading "./" goes, so "." is no directory at all; and on macOS a leading
// /private goes when the path without it still exists (the temporary
// directory lives under it). Bug 629: the runpaths differed by exactly these.
String* standardPath(String* p)
{
    while (p.hasPrefix(String.withCString("./"))) p = p.substringFromByte((u32)2);
    if (p.equals(String.withCString("."))) return String.withCString("");
    String* pre = String.withCString("/private/");
    if (!p.hasPrefix(pre)) return p;
    String* rest = p.substringFromByte((u32)8);
    return Files.exists(rest) ? rest : p;
}

// The names a module's assembly declares `.globl`, sorted: a library's own API.
// Appends each name of `from` that `into` does not hold yet, in order (#335):
// the lists ran to thousands of names and were searched once per name.
void addMissing(Array* into, Array* from)
{
    Map* seen = new Map();
    for (u32 i = (u32)0; i < into.count(); i = i + (u32)1)
        seen.set((Hashable*)into.get(i), into.get(i));
    for (u32 i = (u32)0; i < from.count(); i = i + (u32)1) {
        Object* n = from.get(i);
        if (seen.get((Hashable*)n) != (Object*)0) continue;
        seen.set((Hashable*)n, n);
        into.add(n);
    }
}

Array* globlNames(String* prog)
{
    Array* out = new Array();
    Map* seen = new Map();
    Array* lines = prog.splitOnByte((u8)'\n');
    for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
        String* l = (String*)lines.get(i);
        u32 k = (u32)0;
        while (k < l.byteLength() && (l.byteAt(k) == (u8)' ' || l.byteAt(k) == (u8)'\t')) k = k + (u32)1;
        if (k + (u32)6 > l.byteLength() || !l.substringFromByte(k).hasPrefix(String.withCString(".globl"))) continue;
        k = k + (u32)6;
        u32 st = k;
        while (k < l.byteLength() && (l.byteAt(k) == (u8)' ' || l.byteAt(k) == (u8)'\t')) k = k + (u32)1;
        if (k == st || k >= l.byteLength()) continue;
        u32 e = k;
        while (e < l.byteLength() && l.byteAt(e) != (u8)' ' && l.byteAt(e) != (u8)'\t' && l.byteAt(e) != (u8)'\r') e = e + (u32)1;
        String* n = l.substringBytes(k, e - k);
        if (seen.get((Hashable*)n) == (Object*)0) { seen.set((Hashable*)n, (Object*)n); out.add((Object*)n); }
    }
    Elf64.sortStrings(out);
    return out;
}

bool isGlibcOwnLib(String* base)
{
    return base.equals(String.withCString("c")) || base.equals(String.withCString("m"))
        || base.equals(String.withCString("pthread")) || base.equals(String.withCString("dl"))
        || base.equals(String.withCString("rt"));
}

void linkX86_64Glibc(DriverOptions* d, String* prog)
{
    // --emit-lib: a glibc SHARED library — no process entry, load-time
    // constructors registered with the program (libinit), its own API
    // exported. As the reference's linkX86_64GlibcShared.
    bool shared = d.emitLib();
    // libRuntime (owner, 2026-11-03): an image that takes it keeps the crt
    // (and a library's constructor glue) and links the object runtime from it.
    bool rtFromLib = runtimeTaken(d);
    if (rtFromLib) prog = guardThroughGotX86(prog);
    Array* srcs = new Array();
    Array* rtNames = new Array();
    if (!shared) rtNames.add((Object*)String.withCString("crt-glibc.s"));
    bool xcArgs = !shared && xcArgsFor(d, prog);
    if (xcArgs) rtNames.add((Object*)String.withCString("xcargs-glibc.s"));
    if (!rtFromLib) {
        rtNames.add((Object*)String.withCString("rtgen-glibc.s"));
        rtNames.add((Object*)String.withCString("rtfiles-linux.s"));
        rtNames.add((Object*)String.withCString("libmgen-linux.s"));
    }
    if (shared && prog.contains(String.withCString("\n__xt_ctors_start:")))
        rtNames.add((Object*)String.withCString("libinit-linux.s"));
    Array* rtExports = new Array();
    for (u32 k = (u32)0; k < rtNames.count(); k = k + (u32)1) {
        String* t = readRuntimeIn(d.fe(), "x86_64/runtime", (String*)rtNames.get(k));
        if (t == 0) {
            Stdio.printf("xcc: error: -dynamic: cannot read %s from the support tree\n",
                         ((String*)rtNames.get(k)).cString());
            driverExit((i32)1); return;
        }
        // libRuntime exports the runtime it carries (not the crt or glue).
        String* rn = (String*)rtNames.get(k);
        if (xcArgs && rn.hasPrefix(String.withCString("crt-"))) t = crtWithXcArgs(t);
        if (rtFromLib && rn.hasPrefix(String.withCString("crt-"))) t = crtArgsThroughGot(t);
        if (d.emitRuntime() && !rn.hasPrefix(String.withCString("crt-")) && !rn.hasPrefix(String.withCString("libinit-"))) {
            t = runtimeForLibRuntime(t);
            Array* g = globlNames(t);
            addMissing(rtExports, g);
        }
        srcs.add((Object*)t);
    }
    srcs.add((Object*)x86ClassAllocStubs(prog, false));
    srcs.add((Object*)prog);
    String* mapText = readRuntimeIn(d.fe(), "x86_64", String.withCString("glibc-imports.map"));
    if (mapText == 0) {
        Stdio.printf("xcc: error: -dynamic: cannot read x86_64/glibc-imports.map from the support tree\n");
        driverExit((i32)1); return;
    }

    Array* objs = new Array();
    Array* ars = new Array();
    Array* sos = new Array();
    for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1) {
        String* op = (String*)d.objectInputs().get(i);
        if (op.hasSuffix(String.withCString(".a"))) ars.add((Object*)op); else objs.add((Object*)op);
    }
    // -L dirs, then the standard multiarch directories, so `-lgtk-4` works on
    // the Linux host as it stands; a cross-link names a copy with -L.
    Array* dirs = new Array();
    for (u32 i = (u32)0; i < d.fe().libs().count(); i = i + (u32)1) dirs.add(d.fe().libs().get(i));
    for (u32 i = (u32)0; i < d.ldDirs().count(); i = i + (u32)1) dirs.add(d.ldDirs().get(i));
    // A C/C++ cross build's sysroot (cPathTargetFlags) before this machine's.
    if (gCPathRoot != (String*)0) {
        dirs.add((Object*)String.withFormat("%s/usr/lib/x86_64-linux-gnu", gCPathRoot.cString()));
        dirs.add((Object*)String.withFormat("%s/lib/x86_64-linux-gnu", gCPathRoot.cString()));
    }
    dirs.add((Object*)String.withCString("/usr/lib/x86_64-linux-gnu"));
    dirs.add((Object*)String.withCString("/lib/x86_64-linux-gnu"));
    dirs.add((Object*)String.withCString("/usr/lib64"));
    dirs.add((Object*)String.withCString("/usr/lib"));
    Array* li = d.linkInputs();
    for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) {
        String* t = (String*)li.get(i);
        if (t.hasPrefix(String.withCString("-l")) && t.byteLength() > (u32)2) {
            String* base = t.substringFromByte((u32)2);
            if (isGlibcOwnLib(base)) continue;          // glibc itself: the import map
            String* found = (String*)0;
            // -l:<file>: that file, by its own name (ld's form), as a
            // versioned shared object (libstdc++.so.6) is found.
            if (base.hasPrefix(String.withCString(":"))) {
                String* fname = base.substringFromByte((u32)1);
                for (u32 k = (u32)0; k < dirs.count() && found == (String*)0; k = k + (u32)1) {
                    String* p = String.withString((String*)dirs.get(k));
                    p.appendCString("/"); p.append(fname);
                    if (Files.exists(p)) found = p;
                }
                if (found == (String*)0) {
                    Stdio.printf("xcc: error: -l%s: no %s on the -L path or in the system library directories\n",
                                 base.cString(), fname.cString());
                    driverExit((i32)1); return;
                }
                if (found.contains(String.withCString(".so"))) sos.add((Object*)found);
                else ars.add((Object*)found);
                continue;
            }
            for (u32 e = (u32)0; e < (u32)2 && found == (String*)0; e = e + (u32)1) {
                for (u32 k = (u32)0; k < dirs.count() && found == (String*)0; k = k + (u32)1) {
                    String* p = String.withString((String*)dirs.get(k));
                    p.appendCString("/lib"); p.append(base);
                    p.appendCString(e == (u32)0 ? ".so" : ".a");
                    if (Files.exists(p)) found = p;
                }
            }
            if (found == (String*)0) {
                Stdio.printf("xcc: error: -l%s: no lib%s.so or lib%s.a on the -L path "
                             "or in the system library directories (cross-linking: "
                             "-L a copy of the libraries)\n",
                             base.cString(), base.cString(), base.cString());
                driverExit((i32)1); return;
            }
            if (found.hasSuffix(String.withCString(".so"))) sos.add((Object*)found);
            else ars.add((Object*)found);
            continue;
        }
        if (!Files.exists(t)) {
            Stdio.printf("xcc: error: '%s': no such file\n", t.cString());
            driverExit((i32)1); return;
        }
        if (t.hasSuffix(String.withCString(".so"))) sos.add((Object*)t);
        else if (t.hasSuffix(String.withCString(".a"))) ars.add((Object*)t);
        else if (t.hasSuffix(String.withCString(".o"))) objs.add((Object*)t);
        else {
            Stdio.printf("xcc: error: -dynamic: linker input '%s': this driver links "
                         "in-house and takes -l, -L, .o, .a and .so only\n", t.cString());
            driverExit((i32)1); return;
        }
    }
    // libgcc LAST, as a pool: the helpers C compiled by gcc or clang calls
    // where the ISA has no instruction (__udivti3, a 128-bit divide, which
    // Mbed TLS's bignum code needs). A C toolchain's glibc link takes them
    // from libgcc.a too. A member joins only when something still needs it,
    // so a link that needs none is unchanged.
    String* pooldir = muslLibDir(d.fe());
    if (pooldir != 0) {
        String* libgcc = String.withString(pooldir); libgcc.appendCString("/libgcc.a");
        if (Files.exists(libgcc)) ars.add((Object*)libgcc);
    }
    // Libraries the program #imported (xc-built .so files).
    // Found beside the program ($ORIGIN) or where each was linked from, in
    // that order: DT_RUNPATH as the reference writes it (bug 626).
    Array* nl = d.fe().neededLibs();
    bool haveDeps = false;
    String* runpath = String.withCString("$ORIGIN");
    Array* depDirs = new Array();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
        String* lp = (String*)nl.get(i);
        if (!lp.hasSuffix(String.withCString(".so"))) continue;
        sos.add((Object*)lp);
        haveDeps = true;
        String* dir = standardPath(lp.deletingLastPathComponent());
        bool seen = false;
        for (u32 k = (u32)0; k < depDirs.count(); k = k + (u32)1)
            if (((String*)depDirs.get(k)).equals(dir)) seen = true;
        if (dir.byteLength() > (u32)0 && !seen) {
            depDirs.add((Object*)dir);
            runpath.appendCString(":");
            runpath.append(dir);
        }
    }
    X86Link* ln = new X86Link();
    // A C or C++ program: its large malloc blocks are the runtime's (#235).
    if (!shared && cAllocFor(d, false)) ln.setCAlloc(cAllocRedirects(false), cAllocExports());
    Data* img = (Data*)0;
    if (shared) {
        Array* iface = new Array();
        String* ij = d.fe().ifaceJson();
        if (ij != (String*)0)
            for (u32 i = (u32)0; i < ij.byteLength(); i = i + (u32)1)
                iface.add((Object*)Number.withU32((u32)ij.byteAt(i)));
        Array* exports = globlNames(prog);
        addMissing(exports, rtExports);
        Elf64.sortStrings(exports);
        img = ln.linkGlibcShared(srcs, objs, ars, sos, mapText, baseNameOf(d.fe().output()),
                                 exports, String.withCString("$ORIGIN"), iface);
    } else {
        img = ln.linkGlibc(srcs, objs, ars, String.withCString("_start"), sos, mapText,
                           haveDeps ? runpath : (String*)0);
    }
    if (ln.failed()) {
        noteUndefinedCall(d, ln.why());
        Stdio.printf("xcc: %s\n", ln.why().cString());
        driverExit((i32)1); return;
    }
    if (!Files.writeData(d.fe().output(), img)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        driverExit((i32)1); return;
    }
    Files.setExecutable(d.fe().output());
}

void linkX86_64(DriverOptions* d, String* prog)
{
    String* libdir = muslLibDir(d.fe());
    if (libdir == 0) {
        Stdio.printf("xcc: error: the x86-64 static link needs musl's libc.a and no copy was found.\n"
                     "  looked in $XTC_MUSL_ROOT/lib, /opt/clang/linux/x86_64-linux-musl/lib,\n"
                     "  and <support>/x86_64-sysroot\n");
        driverExit((i32)1); return;
    }

    // The runtime pieces, each its OWN input for the label-namespacing reason
    // above, in the order the reference passes them.
    Array* srcs = new Array();
    Array* rtNames = new Array();
    // crt-linux.s is the process entry — a SHARED OBJECT has none, and taking
    // it would leave the library importing `main`, which only a program
    // defines. Same rule as the arm64 dylib.
    if (!d.emitLib()) rtNames.add((Object*)String.withCString("crt-linux.s"));
    bool xcArgs = !d.emitLib() && xcArgsFor(d, prog);
    if (xcArgs) rtNames.add((Object*)String.withCString("xcargs-linux.s"));
    rtNames.add((Object*)String.withCString("sys-linux.s"));
    rtNames.add((Object*)String.withCString("rtgen-linux.s"));
    rtNames.add((Object*)String.withCString("rtfiles-linux.s"));
    rtNames.add((Object*)String.withCString("libmgen-linux.s"));
    // A library with load-time constructors registers its table with the
    // program at load, and the program's _start runs it (bug 470).
    if (d.emitLib() && prog != (String*)0
        && prog.contains(String.withCString("\n__xt_ctors_start:")))
        rtNames.add((Object*)String.withCString("libinit-linux.s"));
    for (u32 k = (u32)0; k < rtNames.count(); k = k + (u32)1) {
        String* t = readRuntimeIn(d.fe(), "x86_64/runtime", (String*)rtNames.get(k));
        if (t == 0) {
            Stdio.printf("xcc: error: cannot read %s from the support tree\n",
                         ((String*)rtNames.get(k)).cString());
            driverExit((i32)1); return;
        }
        if (xcArgs && k == (u32)0) t = crtWithXcArgs(t);
        srcs.add((Object*)t);
    }
    srcs.add((Object*)x86ClassAllocStubs(prog, false));
    srcs.add((Object*)prog);

    // libc goes LAST, so it is only ever a POOL for what is still undefined:
    // our own runtime keeps its `_xt_*` contract and its definitions win.
    // A LIBRARY does not bundle libc: what it does not define becomes an
    // IMPORT, resolved from whatever libc the process that loads it already
    // has. Bundling one would put a second copy of malloc in the address space
    // and hand the library a heap the program cannot see. An EXECUTABLE is the
    // opposite — it is the libc provider, so the archive is its pool.
    Array* ars = new Array();
    Array* objs = new Array();
    // -fmalloc=mimalloc: the allocator is an OBJECT, and the first one. An
    // archive member joins only for a symbol still undefined, so a mimalloc
    // `.a` would override only what libc had not already supplied — two
    // allocators in one program. An object's definitions are unconditional,
    // and libc's malloc members are then never pulled. support/MIMALLOC.md.
    if (d.caps().hostMalloc().equals(String.withCString("mimalloc"))) {
        String* mi = supportRoot(d.fe());
        if (mi != (String*)0) { mi = String.withString(mi); mi.appendCString("/x86_64/runtime/mimalloc.o"); }
        if (mi == (String*)0 || !Files.exists(mi)) {
            Stdio.printf("xcc: error: -fmalloc=mimalloc needs x86_64/runtime/mimalloc.o "
                         "in the support tree, and it is not there\n");
            driverExit((i32)1); return;
        }
        objs.add((Object*)mi);
    }
    // Objects and archives named as INPUTS (`xcc a.o lib.a -o prog`) — the
    // link step of separate compilation (bug 138).
    for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1) {
        String* op = (String*)d.objectInputs().get(i);
        if (op.hasSuffix(String.withCString(".a"))) ars.add((Object*)op); else objs.add((Object*)op);
    }
    // The libraries named on the command line, BEFORE libc: an archive is a
    // POOL, and a member joins only if something already undefined needs it, so
    // the user's archives have to be scanned while their symbols are still
    // wanted. `-L <dir> -l<name>` is the form the spike found works on every
    // target (blewit FINDINGS), and it must not be silently dropped: accepting
    // a link input and ignoring it is a symbol that resolves nowhere, reported
    // at run time as a fault with no message.
    {
        Array* li = d.linkInputs();
        for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) {
            String* tok = (String*)li.get(i);
            // A static image takes an ARCHIVE for -l<name>, as the reference
            // does. It used to accept whatever resolveLinkInput found — a
            // `.so` first — and then drop it ("handled as a dep below", which
            // only covered #import), or drop a name it found nothing for: a
            // `-lgtk-4` vanished without a word and its symbols resolved
            // nowhere. musl's libc.a is libc, libm and libpthread at once, so
            // those names are already satisfied.
            if (!d.emitLib() && tok.hasPrefix(String.withCString("-l")) && tok.byteLength() > (u32)2) {
                String* base = tok.substringFromByte((u32)2);
                if (isGlibcOwnLib(base)) continue;
                Array* dirs = new Array();
                for (u32 k = (u32)0; k < d.fe().libs().count(); k = k + (u32)1) dirs.add(d.fe().libs().get(k));
                for (u32 k = (u32)0; k < d.ldDirs().count(); k = k + (u32)1) dirs.add(d.ldDirs().get(k));
                String* found = (String*)0;
                bool soOnly = false;
                for (u32 k = (u32)0; k < dirs.count() && found == (String*)0; k = k + (u32)1) {
                    String* p = String.withString((String*)dirs.get(k));
                    p.appendCString("/lib"); p.append(base);
                    String* so = String.withString(p); so.appendCString(".so");
                    p.appendCString(".a");
                    if (Files.exists(p)) found = p;
                    else if (Files.exists(so)) soOnly = true;
                }
                if (found == (String*)0) {
                    if (soOnly)
                        Stdio.printf("xcc: error: -l%s: only a shared lib%s.so was found, and a "
                                     "static x86-64 link cannot load one; link with -dynamic\n",
                                     base.cString(), base.cString());
                    else
                        Stdio.printf("xcc: error: -l%s: no lib%s.a on the -L path\n",
                                     base.cString(), base.cString());
                    driverExit((i32)1); return;
                }
                ars.add((Object*)found);
                continue;
            }
            String* lp = resolveLinkInput(d, tok);
            if (lp == (String*)0) continue;            // a system library: dyld/ld finds it
            if (lp.hasSuffix(String.withCString(".a"))) { ars.add((Object*)lp); continue; }
            if (lp.hasSuffix(String.withCString(".o"))) { objs.add((Object*)lp); continue; }
            if (lp.hasSuffix(String.withCString(".so"))) continue;   // handled as a dep below
            Stdio.printf("xcc: error: -Xlinker '%s': this driver links x86-64 "
                         "in-house and takes .a archives, .o objects and .so "
                         "libraries — it has no external linker to hand anything "
                         "else to\n", lp.cString());
            driverExit((i32)1); return;
        }
    }
    if (d.frameworks().count() > (u32)0) {
        Stdio.printf("xcc: error: -framework is a macOS concept and this is an "
                     "x86-64 ELF link\n");
        driverExit((i32)1); return;
    }
    if (!d.emitLib()) {
        String* libc = String.withString(libdir); libc.appendCString("/libc.a");
        String* libgcc = String.withString(libdir); libgcc.appendCString("/libgcc.a");
        ars.add((Object*)libc);
        if (Files.exists(libgcc)) ars.add((Object*)libgcc);
    }

    X86Link* ln = new X86Link();
    Data* img = (Data*)0;
    if (d.emitLib()) {
        // The library publishes what the assembler saw `.globl` — the same rule
        // the reference uses — and carries its interface in a `.xtc.iface`
        // section so `#import <Lib>` reads the types out of the binary.
        Array* iface = new Array();
        String* ij = d.fe().ifaceJson();
        if (ij != (String*)0)
            for (u32 i = (u32)0; i < ij.byteLength(); i = i + (u32)1)
                iface.add((Object*)Number.withU32((u32)ij.byteAt(i)));
        // The libraries this one `#import`s (bug 471): each a DT_NEEDED,
        // found beside this library through a DT_RUNPATH of $ORIGIN, so a
        // program that imports only this library still loads them, and
        // before this one.
        Array* needed = new Array();
        Array* nl = d.fe().neededLibs();
        for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
            String* lp = (String*)nl.get(i);
            if (!lp.hasSuffix(String.withCString(".so"))) continue;
            ElfSharedInfo* info = Elf64.sharedInfo(lp);
            String* sn = info != (ElfSharedInfo*)0 ? info.soname() : lp.lastPathComponent();
            bool have = false;
            for (u32 k = (u32)0; k < needed.count(); k = k + (u32)1)
                if (((String*)needed.get(k)).equals(sn)) have = true;
            if (!have) needed.add((Object*)sn);
        }
        img = ln.linkShared(srcs, objs, ars,
                            baseNameOf(d.fe().output()), (Array*)0,
                            needed, needed.count() > (u32)0 ? String.withCString("$ORIGIN") : (String*)0,
                            iface);
    } else {
        // A program that `#import <Lib>`ed a `.so` must be DYNAMIC: a static
        // image has no interpreter and no DT_NEEDED, so the library it named
        // is simply not there when it runs. One DT_NEEDED per library, and a
        // DT_RUNPATH of `$ORIGIN` so a library beside the program is found
        // without the caller saying so.
        Array* needed = new Array();
        Array* provide = new Array();
        Array* nl = d.fe().neededLibs();
        for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
            String* lp = (String*)nl.get(i);
            if (!lp.hasSuffix(String.withCString(".so"))) continue;
            ElfSharedInfo* info = Elf64.sharedInfo(lp);
            needed.add((Object*)(info != (ElfSharedInfo*)0
                                 ? info.soname() : lp.lastPathComponent()));
            // …and what that library needs FROM US. There is one libc in the
            // image and the executable is the provider, so every symbol the
            // library left undefined must be exported here — otherwise it
            // loads and then dies on the first one, naming a function the app
            // has had all along.
            if (info != (ElfSharedInfo*)0)
                for (u32 k = (u32)0; k < info.undefined().count(); k = k + (u32)1)
                    provide.add(info.undefined().get(k));
        }
        if (needed.count() > (u32)0)
            img = ln.linkDynamic(srcs, objs, ars, String.withCString("_start"),
                                 needed, String.withCString("$ORIGIN"), provide);
        else
            img = ln.link(srcs, objs, ars, String.withCString("_start"));
    }
    if (ln.failed()) {
        noteUndefinedCall(d, ln.why());
        Stdio.printf("xcc: %s\n", ln.why().cString());
        driverExit((i32)1); return;
    }
    if (!Files.writeData(d.fe().output(), img)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        driverExit((i32)1); return;
    }
    Files.setExecutable(d.fe().output());
}

// The per-program allocator trampolines for arm9, as ARM ASSEMBLY — the same
// split x86_64 has, where the fixed runtime is a checked-in `.s` and only these
// vary with the program. `new u8[N]` lowers to `_xtc_new_u8(count)`, which
// over-allocates eight bytes per element (always at least the A32 element size)
// and writes the same 24-byte header `_xtc_alloc` does; a CLASS goes through
// `_xtc_alloc` itself and needs nothing here.
String* arm9ClassAllocStubs(String* prog)
{
    String* out = new String();
    Array* seen = new Array();
    String* needle = String.withCString("_xtc_new_");
    u32 i = (u32)0;
    while (i < prog.byteLength()) {
        u32 at = prog.byteIndexOf(needle, i);
        if (at == String.notFound()) break;
        u32 j = at + needle.byteLength();
        String* t = new String();
        while (j < prog.byteLength()) {
            u8 c = prog.byteAt(j);
            bool ok = (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z')
                   || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_';
            if (!ok) break;
            t.appendByte(c);
            j = j + (u32)1;
        }
        i = j;
        if (t.byteLength() == (u32)0) continue;
        bool dup = false;
        for (u32 k = (u32)0; k < seen.count(); k = k + (u32)1)
            if (((String*)seen.get(k)).equals(t)) dup = true;
        if (dup) continue;
        seen.add((Object*)t);
        // `_xtc_new_<T>(count)` — one argument, so the stride argument has to
        // be supplied here. Eight is the widest element the A32 target has.
        out.appendFormat("\t.text\n\t.globl\t_xtc_new_%s\n"
                         "\t.type\t_xtc_new_%s, %%%%function\n"
                         "_xtc_new_%s:\n", t.cString(), t.cString(), t.cString());
        out.appendCString("\tmov\tr1, #8\n\tmov\tr2, #0\n\tb\t_xtc_alloc\n");
    }
    return out;
}

// The XTOS loader looks up `_app_entry`, then `main`, and calls it as
// `main(argc, argv)` — so the RUNTIME owns `main` (rtgen-arm9.s), records the
// two arguments an xtc `main(void)` cannot see, and calls the renamed xtc
// entry. Line-wise and skipping string data, because unlike the Mach-O `_main`
// the ELF symbol is spelled exactly like the word a `.asciz` might contain.
String* renameArm9Main(String* asmText)
{
    String* out = new String();
    Array* lines = asmText.splitOnByte((u8)'\n');
    for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
        String* ln = (String*)lines.get(i);
        if (i > (u32)0) out.appendByte((u8)'\n');
        if (ln.contains(String.withCString(".ascii"))
         || ln.contains(String.withCString(".asciz"))
         || ln.contains(String.withCString(".string"))) { out.append(ln); continue; }
        out.append(replaceWord(ln, String.withCString("main"),
                               String.withCString("xt_main")));
    }
    return out;
}

// Whole-word replacement: `main` but not `domain`, `main2` or `xt_main`.
String* replaceWord(String* s, String* from, String* to)
{
    String* out = new String();
    u32 i = (u32)0;
    while (i < s.byteLength()) {
        bool hit = true;
        if (i + from.byteLength() > s.byteLength()) hit = false;
        for (u32 k = (u32)0; hit && k < from.byteLength(); k = k + (u32)1)
            if (s.byteAt(i + k) != from.byteAt(k)) hit = false;
        if (hit && i > (u32)0 && isWordByte(s.byteAt(i - (u32)1))) hit = false;
        if (hit && i + from.byteLength() < s.byteLength()
                && isWordByte(s.byteAt(i + from.byteLength()))) hit = false;
        if (hit) { out.append(to); i = i + from.byteLength(); continue; }
        out.appendByte(s.byteAt(i));
        i = i + (u32)1;
    }
    return out;
}

bool isWordByte(u8 c)
{
    return (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z')
        || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_' || c == (u8)'$'
        || c == (u8)'.';
}

// ── arm9: assemble + link a Tier-2 PIC ET_DYN entirely in-house ──────────
//
// No arm-none-eabi-gcc, no ld, no libgcc, and no C compiler anywhere in the
// path: Arm32 encodes, Elf32.sharedObject lays the image out and writes the
// dynamic sections the XTOS loader reads. This is what `-A arm9` was waiting
// for — the driver used to refuse the target outright, because the port could
// turn IR into ARM assembly and then had nothing to hand it to.
//
// An arm9 PROGRAM is a `.so` too: the loader maps it and calls `main`. The
// only difference a library makes is that it keeps its symbols visible, gets
// a DT_SONAME, and does not give up the name `main`.
void emitArm9(DriverOptions* d, IRModule* mod)
{
    OptProfile* px = OptProfile.forTarget(String.withCString("arm9"));
    Opt.setUnrollOverride(px, d.unroll());
    applyOptFlags(d, px);
    Opt* prof = Opt.atLevel(d.opt(), px);
    // A LIBRARY keeps every function it defines — the client is what calls
    // them, and dead-function elimination cannot see the client.
    if (d.emitLib() || (d.compileOnly() && gCSplitOut == (String*)0)) prof.setKeepAllFunctions(true);
    else if (linkJoinsObjects(d)) prof.setKeepClassRoot(true);
    prof.run(mod);
    dumpOptIR(d, mod);

    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    Arm9* be = new Arm9();
    be.setThreadSafeArcOverride(d.fe().threadSafeArc());
    // -c: every function this object defines is part of its surface, so it
    // keeps default visibility — the same rule --emit-lib follows.
    be.setEmitLib(d.emitLib() || d.compileOnly());
    String* prog = be.assembly(mod);
    if (be.failed()) {
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < be.missing().count(); k = k + (u32)1) {
            if (k > (u32)0) list.appendCString(" ");
            list.append((String*)be.missing().get(k));
        }
        Stdio.printf("xcc: %s: unsupported: %s\n", d.fe().input().cString(), list.cString());
        driverExit((i32)3); return;
    }
    // The xtc entry gives up the name `main` to the runtime, unless this is a
    // library, which has no entry to give up. An object gives it up too, but
    // only in the object (below): `-S` shows the module as it was compiled.
    if (!d.emitLib() && !d.compileOnly()) prog = renameArm9Main(prog);
    if (d.keepAsm()) {
        if (!writeAsmOut(d, prog)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            driverExit((i32)1); return;
        }
        return;
    }

    // ── -c: an object, not an image ──────────────────────────────────────
    //
    // The fixed runtime is absent: it belongs to the final link, which merges
    // the prebuilt runtime `.s` with the objects. The per-type allocation
    // trampolines the module calls vary with it, so they are here, ahead of
    // its code; the link takes the first of any duplicate. `main` becomes
    // `xt_main` here, in the module that defines it, because the runtime's
    // `main` calls that and a link cannot rename inside an object.
    if (d.compileOnly()) {
        prog = renameArm9Main(prog);
        String* one = new String();
        one.append(arm9ClassAllocStubs(prog));
        one.appendCString("\n");
        one.append(prog);
        Arm32* oas = new Arm32();
        Data* otext = oas.assemble(one);
        if (oas.failed()) {
            Stdio.printf("xcc: %s\n", oas.why().cString());
            driverExit((i32)1); return;
        }
        Elf32* ow = new Elf32();
        ow.setCtorTable(oas.ctorTable());
        Data* img = ow.write(otext, oas.data(), oas.symbols(), oas.relocations());
        if (img == (Data*)0) {
            Stdio.printf("xcc: error: arm9 object write failed\n");
            driverExit((i32)1); return;
        }
        if (!Files.writeData(d.fe().output(), img)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            driverExit((i32)1); return;
        }
        writeObjectSidecars(d);
        if (gCSplitOut != (String*)0) {
            gHalfXcArgs = xcArgsWanted(d, prog);
            cSplitLink(d);
        }
        return;
    }

    if (d.caps().noSelfHost()) { externalArm9(d, prog); return; }

    // The runtime pieces, each its OWN input so their local labels are
    // namespaced apart, in the order the reference passes them.
    Array* srcs = new Array();
    Array* rtNames = new Array();
    rtNames.add((Object*)String.withCString("rtgen-arm9.s"));
    rtNames.add((Object*)String.withCString("libxtgen-arm9.s"));
    rtNames.add((Object*)String.withCString("aeabi64.s"));
    for (u32 k = (u32)0; k < rtNames.count(); k = k + (u32)1) {
        String* t = readRuntimeIn(d.fe(), "arm9/runtime", (String*)rtNames.get(k));
        if (t == 0) {
            Stdio.printf("xcc: error: cannot read %s from the support tree\n",
                         ((String*)rtNames.get(k)).cString());
            driverExit((i32)1); return;
        }
        srcs.add((Object*)t);
    }
    srcs.add((Object*)arm9ClassAllocStubs(prog));
    srcs.add((Object*)prog);

    String* all = new String();
    for (u32 k = (u32)0; k < srcs.count(); k = k + (u32)1) {
        all.append(X86Link.namespaceLocals((String*)srcs.get(k), k));
        all.appendCString("\n");
    }
    Arm32* as = new Arm32();
    Data* text = as.assemble(all);
    if (as.failed()) {
        Stdio.printf("xcc: %s\n", as.why().cString());
        driverExit((i32)1); return;
    }

    // DT_NEEDED. The loader resolves an import by NAME across the libraries it
    // has mapped, so every library that might satisfy one has to be listed —
    // `pow` lives in libm.so, and recording only libc.so is how a program
    // linked cleanly and then failed to LOAD.
    //
    // ORDER is the reference's: the auto-imported libc is the first library
    // its front end records, ahead of every `#import <X>`, then libc and libm
    // again, each name once. Listing the imports first put libGEM.so ahead of
    // libc.so in crossmod/bmlib.
    Array* needed = new Array();
    Array* order = new Array();
    if (arm9SysrootLib(d, String.withCString("libc.so")) != (String*)0)
        order.add((Object*)String.withCString("libc.so"));
    Array* nl = d.fe().neededLibs();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1)
        order.add((Object*)((String*)nl.get(i)).lastPathComponent());
    Array* sysLibs = new Array();
    sysLibs.add((Object*)String.withCString("libc.so"));
    sysLibs.add((Object*)String.withCString("libm.so"));
    for (u32 i = (u32)0; i < sysLibs.count(); i = i + (u32)1)
        if (arm9SysrootLib(d, (String*)sysLibs.get(i)) != (String*)0)
            order.add(sysLibs.get(i));
    for (u32 i = (u32)0; i < order.count(); i = i + (u32)1) {
        String* n = (String*)order.get(i);
        bool seen = false;
        for (u32 k = (u32)0; k < needed.count(); k = k + (u32)1)
            if (((String*)needed.get(k)).equals(n)) seen = true;
        if (!seen) needed.add((Object*)n);
    }

    Data* iface = new Data();
    String* ij = d.fe().ifaceJson();
    if (ij != (String*)0)
        for (u32 i = (u32)0; i < ij.byteLength(); i = i + (u32)1)
            iface.appendByte(ij.byteAt(i));

    Elf32* w = new Elf32();
    w.setCtorTable(as.ctorTable());
    Data* img = w.sharedObject(text, as.data(), as.symbols(), as.relocations(),
                                needed,
                                d.emitLib() ? baseNameOf(d.fe().output()) : (String*)0,
                                iface);
    if (w.failed() || img == (Data*)0) {
        Stdio.printf("xcc: %s\n", w.failed() ? w.why().cString() : "arm9 link failed");
        driverExit((i32)1); return;
    }
    if (!Files.writeData(d.fe().output(), img)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        driverExit((i32)1); return;
    }
    Files.setExecutable(d.fe().output());
}

// A device library on the -L path, or in the support tree's own arm9/lib.
String* arm9SysrootLib(DriverOptions* d, String* libName)
{
    Array* dirs = new Array();
    Array* ls = d.fe().libs();
    for (u32 i = (u32)0; ls != (Array*)0 && i < ls.count(); i = i + (u32)1)
        dirs.add(ls.get(i));
    String* sup = supportRoot(d.fe());
    if (sup != (String*)0) {
        String* p = String.withString(sup); p.appendCString("/arm9/lib");
        dirs.add((Object*)p);
    }
    for (u32 i = (u32)0; i < dirs.count(); i = i + (u32)1) {
        String* p = String.withString((String*)dirs.get(i));
        p.appendByte((u8)'/'); p.append(libName);
        if (Files.exists(p)) return p;
    }
    return (String*)0;
}

// ── arm9: link `-c` objects into the loader-hosted ET_DYN ───────────────
//
// The same image an all-source link writes: the prebuilt runtime `.s` files
// assembled as one unit (each file's local labels namespaced), each object
// merged in after it, the archives pulled from on demand, and the whole
// handed to Elf32.sharedObject. The objects carry their own `_xtc_new_<T>`
// trampolines (see `-c` in emitArm9), so nothing is generated here. Mirrors
// the reference's object link through `xcc-ln-arm9 --shared`.
void linkObjectsArm9(DriverOptions* d)
{
    Array* all = new Array();
    Array* rtNames = new Array();
    rtNames.add((Object*)String.withCString("rtgen-arm9.s"));
    rtNames.add((Object*)String.withCString("libxtgen-arm9.s"));
    rtNames.add((Object*)String.withCString("aeabi64.s"));
    String* src = new String();
    for (u32 k = (u32)0; k < rtNames.count(); k = k + (u32)1) {
        String* t = readRuntimeIn(d.fe(), "arm9/runtime", (String*)rtNames.get(k));
        if (t == 0) {
            Stdio.printf("xcc: error: cannot read %s from the support tree\n",
                         ((String*)rtNames.get(k)).cString());
            driverExit((i32)1); return;
        }
        src.append(X86Link.namespaceLocals(t, k));
        src.appendCString("\n");
    }
    Arm32* as = new Arm32();
    Data* text = as.assemble(src);
    if (as.failed()) {
        Stdio.printf("xcc: %s\n", as.why().cString());
        driverExit((i32)1); return;
    }
    Data* mdata = Data.withData(as.data());
    Array* msyms = new Array();
    for (u32 i = (u32)0; i < as.symbols().count(); i = i + (u32)1) msyms.add(as.symbols().get(i));
    Array* mrels = new Array();
    for (u32 i = (u32)0; i < as.relocations().count(); i = i + (u32)1) mrels.add(as.relocations().get(i));
    // The constructor tables are concatenated, so the image has ONE, whose
    // bounds the loader is given.
    Data* mctors = Data.withData(as.ctorTable());

    Map* defined = new Map();
    for (u32 i = (u32)0; i < msyms.count(); i = i + (u32)1) {
        AsmSymbol* sy = (AsmSymbol*)msyms.get(i);
        if (sy.section() != (u32)0) defined.set((Hashable*)sy.name(), (Object*)Number.withU32((u32)1));
    }
    Array* pool = new Array();
    u32 seq = (u32)0; // which merged object this is, for tagging its locals
    for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1) {
        String* op = (String*)d.objectInputs().get(i);
        if (op.hasSuffix(String.withCString(".o"))) {
            Elf32Object* o = Elf32Object.read(Files.readData(op));
            if (o == (Elf32Object*)0) {
                Stdio.printf("xcc: error: '%s' is not a readable ARM ELF32 object (or carries "
                             "a relocation this linker does not emit)\n", op.cString());
                driverExit((i32)1); return;
            }
            if (!mergeArm9Object(o, text, mdata, mctors, msyms, mrels, defined, seq)) {
                driverExit((i32)1); return;
            }
            seq = seq + (u32)1;
        }
    }
    // A `.a` is a POOL: a member joins only when it defines something still
    // undefined, and pulling one can make new names undefined, so this runs
    // to a fixpoint. Archives are read after every object, as the reference
    // separates them.
    for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1) {
        String* ap = (String*)d.objectInputs().get(i);
        if (!ap.hasSuffix(String.withCString(".a"))) continue;
        Array* ms = ArArchive.membersOfFile(ap);
        if (ms == (Array*)0) {
            Stdio.printf("xcc: error: '%s' is not a static archive\n", ap.cString());
            driverExit((i32)1); return;
        }
        for (u32 k = (u32)0; k < ms.count(); k = k + (u32)1) {
            Elf32Object* o = Elf32Object.read(((ArMember*)ms.get(k)).data());
            if (o != (Elf32Object*)0) pool.add((Object*)o);
        }
    }
    Map* taken = new Map();
    bool progress = pool.count() > (u32)0;
    while (progress) {
        progress = false;
        Map* needed = new Map();
        for (u32 i = (u32)0; i < mrels.count(); i = i + (u32)1) {
            String* s = ((AsmReloc*)mrels.get(i)).symbol();
            if (s != (String*)0 && s.byteLength() > (u32)0 && defined.get((Hashable*)s) == (Object*)0)
                needed.set((Hashable*)s, (Object*)Number.withU32((u32)1));
        }
        if (needed.count() == (u32)0) break;
        for (u32 mi = (u32)0; mi < pool.count(); mi = mi + (u32)1) {
            String* key = Number.withU32(mi).description();
            if (taken.get((Hashable*)key) != (Object*)0) continue;
            Elf32Object* o = (Elf32Object*)pool.get(mi);
            bool defines = false;
            for (u32 k = (u32)0; k < o.symbols().count() && !defines; k = k + (u32)1) {
                AsmSymbol* sy = (AsmSymbol*)o.symbols().get(k);
                if (sy.section() != (u32)0 && sy.isGlobal() && needed.get((Hashable*)sy.name()) != (Object*)0)
                    defines = true;
            }
            if (!defines) continue;
            taken.set((Hashable*)key, (Object*)Number.withU32((u32)1));
            progress = true;
            if (!mergeArm9Object(o, text, mdata, mctors, msyms, mrels, defined, seq)) {
                driverExit((i32)1); return;
            }
            seq = seq + (u32)1;
        }
    }

    // DT_NEEDED: what the objects `#import <Lib>`ed (their .xtc.needs
    // sidecars), then the device libc and libm, as the reference lists them.
    Array* needed = new Array();
    Array* on = objectNeeds(d.objectInputs());
    for (u32 i = (u32)0; i < on.count(); i = i + (u32)1)
        needed.add((Object*)((String*)on.get(i)).lastPathComponent());
    if (arm9SysrootLib(d, String.withCString("libc.so")) != (String*)0)
        needed.add((Object*)String.withCString("libc.so"));
    if (arm9SysrootLib(d, String.withCString("libm.so")) != (String*)0)
        needed.add((Object*)String.withCString("libm.so"));

    Elf32* w = new Elf32();
    w.setCtorTable(mctors);
    Data* img = w.sharedObject(text, mdata, msyms, mrels, needed, (String*)0, new Data());
    if (w.failed() || img == (Data*)0) {
        Stdio.printf("xcc: %s\n", w.failed() ? w.why().cString() : "arm9 link failed");
        driverExit((i32)1); return;
    }
    Data* out = img;
    if (!Files.writeData(d.fe().output(), out)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        driverExit((i32)1); return;
    }
    Files.setExecutable(d.fe().output());
}

// One object into the image being built: its text and data appended (each
// padded to a word first), its defined symbols rebased, its relocations
// moved with it. FIRST DEFINITION WINS, as every in-house linker does — `-c`
// compiles a module's imports into it, so a duplicate is the same body twice —
// except the category-chain anchors (§4.3b), where first-wins would run one
// module's category method as another's body. False (having said why) on
// one of those.
bool mergeArm9Object(Elf32Object* o, Data* mtext, Data* mdata, Data* mctors,
                     Array* msyms, Array* mrels, Map* defined, u32 seq)
{
    // A LOCAL symbol is private to its object, so it is tagged per object
    // (`name$o<n>`), in its definition and in the object's own relocations.
    // Merged under the bare name, the first object's `str_0` answered for
    // every later object's, and one module printed another's strings.
    Map* local = new Map();
    for (u32 i = (u32)0; i < o.symbols().count(); i = i + (u32)1) {
        AsmSymbol* sy = (AsmSymbol*)o.symbols().get(i);
        if (sy.section() == (u32)0 || sy.isGlobal()) continue;
        String* tagged = String.withString(sy.name());
        tagged.appendFormat("$o%lu", seq);
        local.set((Hashable*)sy.name(), (Object*)tagged);
    }
    for (u32 i = (u32)0; i < o.symbols().count(); i = i + (u32)1) {
        AsmSymbol* sy = (AsmSymbol*)o.symbols().get(i);
        Object* t = local.get((Hashable*)sy.name());
        if (t != (Object*)0 && sy.section() != (u32)0 && !sy.isGlobal()) sy.setName((String*)t);
    }
    Array* rels = new Array();
    for (u32 i = (u32)0; i < o.relocations().count(); i = i + (u32)1) {
        AsmReloc* r = (AsmReloc*)o.relocations().get(i);
        Object* t = local.get((Hashable*)r.symbol());
        rels.add((Object*)(t == (Object*)0 ? r
                           : AsmReloc.with(r.section(), r.offset(), (String*)t, r.type())));
    }
    while ((mtext.length() & (u32)3) != (u32)0) mtext.appendByte((u8)0);
    u32 tbase = mtext.length();
    mtext.append(o.text());
    while ((mdata.length() & (u32)3) != (u32)0) mdata.appendByte((u8)0);
    u32 dbase = mdata.length();
    mdata.append(o.data());
    while ((mctors.length() & (u32)3) != (u32)0) mctors.appendByte((u8)0);
    u32 cbase = mctors.length();
    mctors.append(o.ctorTable());
    for (u32 i = (u32)0; i < o.symbols().count(); i = i + (u32)1) {
        AsmSymbol* sy = (AsmSymbol*)o.symbols().get(i);
        if (sy.section() == (u32)0) continue; // undefined: the link resolves it
        String* nm = sy.name();
        if (defined.get((Hashable*)nm) != (Object*)0) {
            u32 cat = nm.byteIndexOf(String.withCString("$cat$"));
            if (cat != String.notFound()) {
                Stdio.printf("xcc: error: two modules define category '%s' on class '%s' ('%s' "
                             "defined twice). The category name is the extender's identity "
                             "(separate-compilation §4.3b) — rename one, or compile both from "
                             "one module\n",
                             nm.substringFromByte(cat + (u32)5).cString(),
                             nm.substringBytes((u32)0, cat).cString(), nm.cString());
                return false;
            }
            if (nm.hasSuffix(String.withCString("$cat"))) {
                Stdio.printf("xcc: error: class '%s' is compiled into two modules ('%s', its "
                             "category-chain table, defined twice)\n",
                             nm.substringBytes((u32)0, nm.byteLength() - (u32)4).cString(), nm.cString());
                return false;
            }
            continue;
        }
        defined.set((Hashable*)nm, (Object*)Number.withU32((u32)1));
        // Drop the UNDEFINED entry the runtime's assembly left for this name,
        // or it goes into .dynsym twice, once defined and once not.
        for (u32 k = (u32)0; k < msyms.count(); k = k + (u32)1) {
            AsmSymbol* u = (AsmSymbol*)msyms.get(k);
            if (u.section() == (u32)0 && u.name().equals(nm)) {
                msyms.removeAt(k);
                k = msyms.count();
            }
        }
        // A COMMON symbol's value is its ALIGNMENT, not an offset.
        if (sy.section() == (u32)1) sy.setValue(sy.value() + tbase);
        else if (sy.section() == (u32)2) sy.setValue(sy.value() + dbase);
        else if (sy.section() == (u32)4) sy.setValue(sy.value() + cbase);
        msyms.add((Object*)sy);
    }
    for (u32 i = (u32)0; i < rels.count(); i = i + (u32)1) {
        AsmReloc* r = (AsmReloc*)rels.get(i);
        u32 base = r.section() == (u32)1 ? tbase : r.section() == (u32)4 ? cbase : dbase;
        mrels.add((Object*)AsmReloc.with(r.section(), r.offset() + base, r.symbol(), r.type()));
    }
    return true;
}

void emitM68k(DriverOptions* d, IRModule* mod)
{
    Opt* prof = (Opt*)0;
    OptProfile* p68 = OptProfile.forTarget(String.withCString("atarist"));
    Opt.setUnrollOverride(p68, d.unroll());
    applyOptFlags(d, p68);
    prof = Opt.atLevel(d.opt(), p68);
    prof.run(mod);
    dumpOptIR(d, mod);

    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    M68k* be = new M68k();
    be.setCpu(d.caps().m68kCpu());
    be.setHardFloat(d.caps().hardFloat());
    be.setPic(d.caps().pic());
    String* prog = be.assembly(mod);
    if (be.failed()) {
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < be.missing().count(); k = k + (u32)1) {
            if (k > (u32)0) list.appendCString(" ");
            list.append((String*)be.missing().get(k));
        }
        Stdio.printf("xcc: %s: unsupported: %s\n", d.fe().input().cString(),
                     list.cString());
        driverExit((i32)3); return;
    }

    // `-o x.s` stops here, as it does on every other target.
    if (d.keepAsm()) {
        if (!writeAsmOut(d, prog)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            driverExit((i32)1); return;
        }
        return;
    }

    // NO crt0.s in front of the program. The back end embeds `_start` itself
    // (Mshrink, stack, jsr main, Pterm — emitCrt0), exactly as the reference
    // driver builds it. This driver ALSO prepended support/atarist/startup/
    // crt0.s, whose bare `jsr main; Pterm` then sat at the first byte of TEXT
    // — where GEMDOS enters — so every shipped m68k program skipped the
    // Mshrink and ran on the loader's stack, 14 bytes longer than the
    // reference's and with two `_start` labels nobody flagged (bug 128).
    // xcc-diff compares asm and as68-diff assembles the REFERENCE's asm, so
    // nothing compared the two drivers' .prg until files_roundtrip.xc was
    // built both ways by hand.
    M68kAsm* as = new M68kAsm();
    as.setCpu(d.caps().m68kCpu());   // 68020+: 32-bit PC-relative, no ±32KB limit
    as.setPic(d.caps().pic());       // 68000: the GOT/a5 model
    as.assemble(prog);
    if (as.failed()) {
        noteUndefinedCall(d, as.why());
        Stdio.printf("xcc: assembly failed: %s\n", as.why().cString());
        driverExit((i32)1); return;
    }
    if (!Files.writeData(d.fe().output(), as.image())) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        driverExit((i32)1); return;
    }
}

// An assembler or linker error about an undefined symbol, placed at the
// source call that needs it. The symbol is the first quoted name after
// "undefined symbol"; a back end that prefixes `_` is matched with it
// stripped. Nothing is printed when no direct call to it was lowered.
void noteUndefinedCall(DriverOptions* d, String* msg)
{
    if (msg == (String*)0) return;
    u32 at = msg.byteIndexOf(String.withCString("undefined symbol"));
    if (at == String.notFound()) return;
    u32 q1 = msg.byteIndexOf(String.withCString("'"), at);
    if (q1 == String.notFound()) return;
    u32 q2 = msg.byteIndexOf(String.withCString("'"), q1 + (u32)1);
    if (q2 == String.notFound()) return;
    String* name = msg.substringBytes(q1 + (u32)1, q2 - q1 - (u32)1);
    Map* sites = d.fe().callSites();
    Object* site = sites.get((Hashable*)name);
    if (site == (Object*)0 && name.hasPrefix(String.withCString("_"))) {
        name = name.substringFromByte((u32)1);
        site = sites.get((Hashable*)name);
    }
    if (site == (Object*)0) return;
    String* m = String.withString((String*)site);
    m.appendCString(": error: call to '");
    m.append(name);
    m.appendCString("', which is declared but never defined");
    Frontend.printDiagnostic(m);
}

void emitXt6502(DriverOptions* d, IRModule* mod)
{
    String* root = supportRoot(d.fe());
    if (root == (String*)0) {
        Stdio.printf("xcc: error: cannot find the support tree (-H)\n");
        driverExit((i32)1); return;
    }
    // The layout -m named, or the xt map.
    String* lnk = d.layoutPath();
    String* lname = d.layoutName();
    if (lnk == (String*)0) {
        lnk = String.withString(root);
        lnk.appendCString("/xt6502/layouts/xt.lnk");
        lname = String.withCString("xt");
    }
    Layout* layout = Layout.read(lnk);
    if (layout.failed()) {
        Stdio.printf("xcc: %s: %s\n", lnk.cString(), layout.why().cString());
        driverExit((i32)1); return;
    }
    // A layout line the back end's reader did not use is a feature this
    // compiler does not have — split code/data banking, a region-C window, a
    // startup file of its own. Building anyway would quietly produce the xt
    // map's program under another layout's name, so each one is named and the
    // build stops. The two `grows = up` lines are the xt map's own, and say
    // what the back end already does.
    u32 unused = (u32)0;
    for (u32 k = (u32)0; k < layout.unapplied().count(); k = k + (u32)1) {
        String* u = (String*)layout.unapplied().get(k);
        if (u.equals(String.withCString("[stack] grows = up"))
            || u.equals(String.withCString("[heap] grows = up")))
            continue;
        if (unused == (u32)0)
            Stdio.printf("xcc: error: layout '%s' uses what the 6502 back end does not "
                         "implement:\n", lname.cString());
        Stdio.printf("  %s\n", u.cString());
        unused = unused + (u32)1;
    }
    if (unused > (u32)0) { driverExit((i32)1); return; }
    // The model's NAME is its layout file's stem; the emitted header carries it.
    layout.setName(lname);

    OptProfile* p65 = OptProfile.forTarget(String.withCString("xt6502"));
    applyOptFlags(d, p65);
    Opt* opt = Opt.atLevel(d.opt(), p65);
    opt.run(mod);
    dumpOptIR(d, mod);
    if (opt.failed()) {
        Stdio.printf("xcc: %s: opt unsupported: %s\n", d.fe().input().cString(),
                     opt.why() == 0 ? "?" : opt.why().cString());
        driverExit((i32)3); return;
    }
    // The lowering passes just made values with no id, and a back end keys its
    // frame slots off value ids.
    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    Xt6502* be = new Xt6502();
    be.setLayout(layout);
    be.setXtcStackDefault(d.xtcStack());
    be.setFnMinBanked(d.fnMinBanked());
    String* asmText = be.assembly(mod);
    if (be.failed()) {
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < be.missing().count(); k = k + (u32)1) {
            if (k > (u32)0) list.appendCString(" ");
            list.append((String*)be.missing().get(k));
        }
        Stdio.printf("xcc: %s: unsupported: %s\n", d.fe().input().cString(), list.cString());
        driverExit((i32)3); return;
    }
    if (d.dumpPlacement()) Stdio.error(be.placementReport());

    // The asm-text peephole, -O>=1 as the original gates it, and BEFORE the
    // rename and the wrap so it sees exactly the text the original's does.
    // Not cosmetic: vtable_stack_args runs correctly at -O1 and produces
    // nothing at -O2 without it, so the pre-peephole text is a path the
    // reference has never executed either.
    asmText = Peep6502.optimise(asmText, d.opt());

    // `_main` becomes `_xt_main` so the harness's startup JSR resolves. A
    // rename over the finished text on WHOLE-WORD boundaries, so `_main_loop`
    // is left alone.
    asmText = renameMainXt(asmText);
    asmText = Runtime6502.wrapQuit(asmText, mod, layout, root,
                                   String.withCString("xt6502/runtime/xt6502-harness.asm"),
                                   d.quitLoop());

    // -du reports what the ASSEMBLER placed, so with -S the text is assembled
    // too, only to measure it.
    if (d.keepAsm()) {
        if (!writeAsmOut(d, asmText)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            driverExit((i32)1);
        }
        if (!d.dumpUsage()) return;
    }

    // Assemble AND link. The banking configuration comes from the layout —
    // xt.lnk is the single source of truth for the windows and the two
    // memory-mapped bank-select registers. Split banking stays OFF: xt
    // declares both windows and both registers without it, which is the
    // configuration xta-diff proves byte-identical.
    Xta* a = new Xta();
    Array* incs = new Array();
    incs.add((Object*)root);        // `.include "xt6502/asm/…"` is relative to it
    incs.add((Object*)String.withCString("."));
    a.setIncludePaths(incs);
    a.setBankRegs(layout.codeBankReg(), layout.dataBankReg());
    a.setBankWindow(layout.bankWindowStart(), layout.bankWindowEnd());
    a.setDataWindow(layout.dataWindowStart(), layout.dataWindowEnd());
    a.setSplitBanking(false);
    // The first main range bounds the unbanked code, as the reference's
    // back end tells its assembler; diagnostics name the output file.
    if (layout.mainRanges().count() > (u32)0) {
        LayoutRange* mr = (LayoutRange*)layout.mainRanges().get((u32)0);
        a.setMainRegion(mr.lo(), mr.hi());
    }
    a.setFilename(d.fe().output());
    Array* lines = a.preprocess(asmText, d.fe().output());
    a.assemble(lines);
    if (a.errors().count() > (u32)0) {
        for (u32 k = (u32)0; k < a.errors().count(); k = k + (u32)1) {
            noteUndefinedCall(d, (String*)a.errors().get(k));
            Stdio.printf("xcc: assembly failed: %s\n", ((String*)a.errors().get(k)).cString());
        }
        driverExit((i32)1); return;
    }
    if (d.dumpUsage()) Stdio.error(usageReport6502(a.segments(), layout));
    if (d.keepAsm()) return;
    u32 entry = (u32)$2000;
    if (a.segments().count() > (u32)0)
        entry = ((XaSegment*)a.segments().get((u32)0)).origin();
    Data* img = a.writeBankedXex(entry);
    if (img == (Data*)0) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        driverExit((i32)1); return;
    }
    if (!Files.writeData(d.fe().output(), img)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        driverExit((i32)1);
    }
}

// ── -du: the assembled image against the layout ──────────────────────────

String* padRightTo(String* s, u32 width)
{
    String* o = String.withString(s);
    while (o.byteLength() < width) o.appendCString(" ");
    return o;
}

String* padLeftNumTo(u32 v, u32 width)
{
    String* num = String.withCString("");
    num.appendFormat("%lu", v);
    String* o = String.withCString("");
    while (o.byteLength() + num.byteLength() < width) o.appendCString(" ");
    o.append(num);
    return o;
}

// `$` and `digits` uppercase hex digits of v.
String* hexDigitsOf(u32 v, u32 digits)
{
    String* o = String.withCString("$");
    u32 shift = digits * (u32)4;
    while (shift > (u32)0) {
        shift = shift - (u32)4;
        u32 d = (v >> shift) & (u32)$F;
        o.appendByte(d < (u32)10 ? (u8)((u32)'0' + d) : (u8)((u32)'A' + d - (u32)10));
    }
    return o;
}

String* hexAddr4(u32 v)
{
    return hexDigitsOf(v, (u32)4);
}

// Bytes of [lo, hi] (inclusive) that the unbanked segments occupy.
u32 segBytesIn(Array* segs, u32 lo, u32 hi, u32 bwStart, u32 bwEnd)
{
    u32 n = (u32)0;
    for (u32 k = (u32)0; k < segs.count(); k = k + (u32)1) {
        XaSegment* sg = (XaSegment*)segs.get(k);
        if (sg.isCloaked() || (sg.origin() >= bwStart && sg.origin() <= bwEnd)) continue;
        u32 a = sg.origin();
        u32 b = a + sg.data().length();          // [a, b)
        if (a < lo) a = lo;
        if (b > hi + (u32)1) b = hi + (u32)1;
        if (b > a) n = n + (b - a);
    }
    return n;
}

// What the assembled image uses of each region and bank the layout declares.
// Code banks are numbered as the XEX writer numbers them: a segment in the
// code window takes its `.bank` number if it has one, else the next page in
// encounter order.
String* usageReport6502(Array* segs, Layout* l)
{
    String* r = String.withCString("xcc: usage for layout '");
    r.append(l.name());
    r.appendCString("':\n");
    u32 bwStart = l.bankWindowStart();
    u32 bwEnd = l.bankWindowEnd();
    bool banked = l.hasBanking() && bwStart != (u32)0;
    if (!banked) { bwStart = (u32)1; bwEnd = (u32)0; }
    if (l.varsRanges().count() > (u32)0) {
        String* list = String.withCString("");
        u32 total = (u32)0;
        for (u32 k = (u32)0; k < l.varsRanges().count(); k = k + (u32)1) {
            LayoutRange* z = (LayoutRange*)l.varsRanges().get(k);
            if (k > (u32)0) list.appendCString(", ");
            list.append(hexDigitsOf(z.lo(), (u32)2));
            list.appendCString("-");
            list.append(hexDigitsOf(z.hi(), (u32)2));
            total = total + (z.hi() - z.lo() + (u32)1);
        }
        r.appendCString("  ");
        r.append(padRightTo(String.withCString("zero page"), (u32)12));
        r.appendFormat(" %s  %lu bytes of variables\n", list.cString(), total);
    }
    if (l.stackEnd() != (u32)0) {
        r.appendCString("  ");
        r.append(padRightTo(String.withCString("stack"), (u32)12));
        r.appendFormat(" %s-%s  %lu bytes, the software stack\n",
                       hexAddr4(l.stackStart()).cString(), hexAddr4(l.stackEnd()).cString(),
                       l.stackEnd() - l.stackStart() + (u32)1);
    }
    Array* names = new Array();
    Array* los = new Array();
    Array* his = new Array();
    if (l.systemEnd() > l.systemStart()) {
        names.add((Object*)String.withCString("system"));
        los.add((Object*)Number.withU32(l.systemStart()));
        his.add((Object*)Number.withU32(l.systemEnd()));
    }
    if (l.screenEnd() > l.screenStart()) {
        names.add((Object*)String.withCString("screen"));
        los.add((Object*)Number.withU32(l.screenStart()));
        his.add((Object*)Number.withU32(l.screenEnd()));
    }
    for (u32 k = (u32)0; k < l.mainRanges().count(); k = k + (u32)1) {
        LayoutRange* m = (LayoutRange*)l.mainRanges().get(k);
        names.add((Object*)String.withCString("main"));
        los.add((Object*)Number.withU32(m.lo()));
        his.add((Object*)Number.withU32(m.hi()));
    }
    u32 accounted = (u32)0;
    for (u32 k = (u32)0; k < names.count(); k = k + (u32)1) {
        String* name = (String*)names.get(k);
        u32 lo = ((Number*)los.get(k)).asU32();
        u32 hi = ((Number*)his.get(k)).asU32();
        u32 used = segBytesIn(segs, lo, hi, bwStart, bwEnd);
        accounted = accounted + used;
        r.appendCString("  ");
        r.append(padRightTo(name, (u32)12));
        r.appendFormat(" %s-%s  ", hexAddr4(lo).cString(), hexAddr4(hi).cString());
        if (name.equals(String.withCString("screen")) && used == (u32)0) {
            r.appendCString("screen RAM\n");
        } else {
            r.append(padLeftNumTo(used, (u32)6));
            r.appendFormat(" of %lu bytes used\n", hi - lo + (u32)1);
        }
    }
    u32 all = segBytesIn(segs, (u32)0, (u32)$FFFF, bwStart, bwEnd);
    if (all > accounted) {
        r.appendCString("  ");
        r.append(padRightTo(String.withCString("other"), (u32)12));
        r.appendFormat(" %lu bytes outside the declared regions\n", all - accounted);
    }
    if (banked) {
        Array* pages = new Array();       // Number@ page per used segment
        Array* sizes = new Array();       // Number@ its bytes
        u32 counter = (u32)1;
        u32 highest = (u32)0;
        for (u32 k = (u32)0; k < segs.count(); k = k + (u32)1) {
            XaSegment* sg = (XaSegment*)segs.get(k);
            if (sg.isCloaked() || sg.origin() < bwStart || sg.origin() > bwEnd) continue;
            u32 page = sg.bankNumber() >= (i32)0 ? (u32)sg.bankNumber() : counter;
            counter = counter + (u32)1;
            if (sg.data().length() == (u32)0) continue;
            pages.add((Object*)Number.withU32(page));
            sizes.add((Object*)Number.withU32(sg.data().length()));
            if (page > highest) highest = page;
        }
        u32 winSize = bwEnd - bwStart + (u32)1;
        u32 firstUnused = (u32)1;
        for (u32 b = (u32)1; b <= highest; b = b + (u32)1) {
            u32 used = (u32)0;
            bool any = false;
            for (u32 k = (u32)0; k < pages.count(); k = k + (u32)1)
                if (((Number*)pages.get(k)).asU32() == b) {
                    used = used + ((Number*)sizes.get(k)).asU32();
                    any = true;
                }
            if (!any) continue;
            String* label = String.withCString("code bank ");
            label.appendFormat("%lu", b);
            r.appendCString("  ");
            r.append(padRightTo(label, (u32)12));
            r.appendFormat(" %s-%s  ", hexAddr4(bwStart).cString(), hexAddr4(bwEnd).cString());
            r.append(padLeftNumTo(used, (u32)6));
            r.appendFormat(" of %lu bytes used\n", winSize);
            firstUnused = b + (u32)1;
        }
        if (firstUnused <= (u32)255) {
            r.appendCString("  ");
            r.append(padRightTo(String.withCString("code banks"), (u32)12));
            r.appendFormat(" %s-%s  unused: code banks %lu-255\n",
                           hexAddr4(bwStart).cString(), hexAddr4(bwEnd).cString(), firstUnused);
        }
    }
    if (l.dataWindowStart() != (u32)0 && l.dataWindowEnd() > l.dataWindowStart()) {
        r.appendCString("  ");
        r.append(padRightTo(String.withCString("data window"), (u32)12));
        r.appendFormat(" %s-%s  ", hexAddr4(l.dataWindowStart()).cString(),
                       hexAddr4(l.dataWindowEnd()).cString());
        if (l.heapBankDynamic())
            r.appendCString("the heap: data banks taken as it grows, at run time\n");
        else if (l.heapBankFirst() != (u32)0)
            r.appendFormat("the heap: data banks %lu-%lu\n", l.heapBankFirst(), l.heapBankLast());
        else
            r.appendCString("unused\n");
    }
    return r;
}

// Whole-word `_main` -> `_xt_main`.
String* renameMainXt(String* text)
{
    String* from = String.withCString("_main");
    String* out = String.withCString("");
    u32 i = (u32)0;
    while (i < text.byteLength()) {
        u32 at = text.byteIndexOf(from, i);
        if (at == (u32)$FFFF_FFFF) { out.append(text.substringFromByte(i)); break; }
        u32 e = at + from.byteLength();
        u8 before = at > (u32)0 ? text.byteAt(at - (u32)1) : (u8)' ';
        u8 after = e < text.byteLength() ? text.byteAt(e) : (u8)' ';
        out.append(text.substringBytes(i, at - i));
        bool wordBefore = (before >= (u8)'a' && before <= (u8)'z')
                       || (before >= (u8)'A' && before <= (u8)'Z')
                       || (before >= (u8)'0' && before <= (u8)'9')
                       || before == (u8)'_';
        bool wordAfter = (after >= (u8)'a' && after <= (u8)'z')
                      || (after >= (u8)'A' && after <= (u8)'Z')
                      || (after >= (u8)'0' && after <= (u8)'9')
                      || after == (u8)'_';
        if (wordBefore || wordAfter) out.append(from);
        else                         out.appendCString("_xt_main");
        i = e;
    }
    return out;
}

// Every `.globl <name>` in a chunk of asm that is also DEFINED in the assembled
// image, in the order the symbol table lists them. `.globl` is how the back end
// marks a name as public, so this is the library's surface as the code itself
// declares it — not a guess, and not everything that happens to have a label.
Array* globlNames(String* asmText, Map* symbols)
{
    Array* out = new Array();
    Array* lines = asmText.splitOnByte((u8)'\n');
    Set* seen = new Set();
    for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
        String* ln = ((String*)lines.get(i)).trimmed();
        if (!ln.hasPrefix(String.withCString(".globl"))) continue;
        String* nm = ln.substringFromByte((u32)6).trimmed();
        // The name alone: clang's runtime files follow it with a comment
        // (`; -- Begin function`), which the program's text never has.
        u32 e = (u32)0;
        while (e < nm.byteLength() && nm.byteAt(e) != (u8)' ' && nm.byteAt(e) != (u8)'\t' && nm.byteAt(e) != (u8)';')
            e = e + (u32)1;
        nm = nm.substringBytes((u32)0, e);
        if (nm.byteLength() == (u32)0) continue;
        // The back end emits ELF-flavoured names; the Mach-O dialect adds the
        // leading underscore, so look for both rather than guessing which
        // stage this text came from.
        String* us = String.withCString("_");
        us.append(nm);
        if (symbols.get((Hashable*)nm) != (Object*)0) {
            if (!seen.contains((Hashable*)nm)) { seen.add((Hashable*)nm); out.add((Object*)nm); }
        } else if (symbols.get((Hashable*)us) != (Object*)0) {
            if (!seen.contains((Hashable*)us)) { seen.add((Hashable*)us); out.add((Object*)us); }
        }
    }
    return out;
}

// ── Bug 138: objects and archives in the arm64 / iOS link ────────────────
//
// Merge every `.o` / `.a` this link names — `-Xlinker` inputs plus `extra`
// (the objects named as inputs in an object-only link) — into the
// assembler's model, then give the ObjC metadata its section identity back.
// Returns the ObjC section table for the writer (empty when there is none).
Array* mergeLinkObjects(DriverOptions* d, SectionBytes* mtext, SectionBytes* mdata, Map* msyms,
                        Array* mdataSyms, Array* mfix, Array* extra, Arm64Asm* as)
{
    Array* objs = new Array();
    Array* ars = new Array();
    for (u32 i = (u32)0; i < extra.count(); i = i + (u32)1) {
        String* op = (String*)extra.get(i);
        if (op.hasSuffix(String.withCString(".a"))) ars.add((Object*)op); else objs.add((Object*)op);
    }
    Array* li = d.linkInputs();
    for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) {
        String* lp = resolveLinkInput(d, (String*)li.get(i));
        if (lp == (String*)0) continue;
        if (lp.hasSuffix(String.withCString(".o"))) objs.add((Object*)lp);
        else if (lp.hasSuffix(String.withCString(".a"))) ars.add((Object*)lp);
    }
    Array* mObjc = new Array();
    if (objs.count() > (u32)0 || ars.count() > (u32)0) {
        MachOLink* ml = new MachOLink();
        if (gMachORedirect != (Map*)0) ml.setRedirect(gMachORedirect);
        ml.merge(objs, ars, mtext, mdata, msyms, mdataSyms, mfix, mObjc);
        if (ml.rc() != (u32)0) {
            Stdio.printf("xcc: error: arm64 link: %s\n", ml.why() == 0 ? "?" : ml.why().cString());
            driverExit((i32)1); return (Array*)0;
        }
        // The objects' load-time constructors after the program's own, in the
        // list the writer ends __data with (appendModInit).
        u32 mb = as.modInitBytes().length();
        as.modInitBytes().append(ml.objModInit());
        for (u32 i = (u32)0; i < ml.objModInitFix().count(); i = i + (u32)1) {
            Arm64Fixup* f = (Arm64Fixup*)ml.objModInitFix().get(i);
            as.modInitFixups().add((Object*)Arm64Fixup.make(mb + f.offset(), f.kind(), f.symbol(), f.scale()));
        }
    }
    MachOLink.addVtblRuns(msyms, mObjc);
    return MachOLink.repartitionObjc(mdata, mObjc, msyms, mdataSyms, mfix);
}

// The android link's twin of mergeLinkObjects: `-Wl,x.o` / `-Xlinker lib.a`
// are aarch64 ELF objects and archives (the NDK's clang built them), merged
// into the assembler's model before the image is written. It used to drop
// them without a word, so a library bundling C code came out with that code
// undefined.
// What an arm64 Linux C program's executable exports for its libraries (the
// heap's free, realloc and malloc_usable_size, #326), or 0.
Array* gArm64CExports;

void mergeElfLinkObjects(DriverOptions* d, SectionBytes* mtext, SectionBytes* mdata, Map* msyms,
                         Array* mdataSyms, Array* mfix, Array* extra, Arm64Asm* as)
{
    Array* objs = new Array();
    Array* ars = new Array();
    for (u32 i = (u32)0; i < extra.count(); i = i + (u32)1) {
        String* op = (String*)extra.get(i);
        if (op.hasSuffix(String.withCString(".a"))) ars.add((Object*)op); else objs.add((Object*)op);
    }
    Array* li = d.linkInputs();
    for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) {
        String* lp = resolveLinkInput(d, (String*)li.get(i));
        if (lp == (String*)0) continue;
        if (lp.hasSuffix(String.withCString(".o"))) objs.add((Object*)lp);
        else if (lp.hasSuffix(String.withCString(".a"))) ars.add((Object*)lp);
    }
    // A C or C++ program on arm64 Linux with glibc whose xc half carries the
    // heap (CAlloc.xc's _xc_malloc, #326): its objects' allocator calls are
    // the heap's, and the executable exports free, realloc and
    // malloc_usable_size as the heap's, so its libraries' calls reach them.
    // (The split link of a C program brings xcc's half as an object, which
    // cAllocFor reads; a build from source has it in this model.)
    bool heap = !d.emitLib() && d.targetRow() != (TargetRow*)0 && d.targetRow().os().equals(String.withCString("linux"))
                && (msyms.get((Hashable*)String.withCString("_xc_malloc")) != (Object*)0 || cAllocFor(d, false));
    // Only the objects' calls are redirected, as on x86-64: this model holds
    // the runtime, whose own allocations must stay glibc's (renamed, the
    // heap's start re-entered itself through them and waited for itself).
    Map* redirect = heap ? cAllocRedirects(false) : (Map*)0;
    ElfLinkArm64* el = new ElfLinkArm64();
    if (objs.count() > (u32)0 || ars.count() > (u32)0) {
        if (heap)
            el.setRedirect(redirect);
        el.merge(objs, ars, mtext, mdata, msyms, mdataSyms, mfix);
    }
    if (heap && el.rc() == (u32)0) {
        Map* ex = cAllocExports();
        Array* ks = ex.allKeys();
        Elf64.sortStrings(ks);
        gArm64CExports = new Array();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1) {
            Object* at = msyms.get(ex.get(ks.get(i)));
            if (at == (Object*)0) continue;
            msyms.set((Hashable*)ks.get(i), at);
            gArm64CExports.add(ks.get(i));
        }
    }
    if (objs.count() == (u32)0 && ars.count() == (u32)0) return;
    if (el.rc() != (u32)0) {
        Stdio.printf("xcc: error: %s link: %s\n", d.targetRow().name().cString(), el.why() == 0 ? "?" : el.why().cString());
        driverExit((i32)1); return;
    }
    // The objects' load-time constructors after the program's own, in the
    // list appendModInit ends the data with: xcc's own -c objects carry a
    // module's this way, and a C object's .init_array runs as well.
    u32 mb = as.modInitBytes().length();
    as.modInitBytes().append(el.objModInit());
    for (u32 i = (u32)0; i < el.objModInitFix().count(); i = i + (u32)1) {
        Arm64Fixup* f = (Arm64Fixup*)el.objModInitFix().get(i);
        Arm64Fixup* g = Arm64Fixup.make(mb + f.offset(), f.kind(), f.symbol(), f.scale());
        g.setAddend(f.addend());
        as.modInitFixups().add((Object*)g);
    }
}

// The `#import <Lib>` list each object recorded when it was compiled
// (`<obj>.xtc.needs`, one library path per line). An object link has no
// front end, so this sidecar is the only way it learns the program needs a
// library at all. Union, first mention wins the order.
Array* objectNeeds(Array* objectInputs)
{
    Array* out = new Array();
    for (u32 i = (u32)0; i < objectInputs.count(); i = i + (u32)1) {
        String* op = (String*)objectInputs.get(i);
        if (!op.hasSuffix(String.withCString(".o")) && !op.hasSuffix(String.withCString(".obj"))) continue;
        String* side = stripExtension(op); side.appendCString(".xtc.needs");
        String* body = Files.readText(side);
        if (body == (String*)0) continue;
        Array* lines = body.splitOnByte((u8)10);
        for (u32 k = (u32)0; k < lines.count(); k = k + (u32)1) {
            String* t = ((String*)lines.get(k)).trimmed();
            if (t.byteLength() == (u32)0) continue;
            bool seen = false;
            for (u32 q = (u32)0; q < out.count() && !seen; q = q + (u32)1)
                if (((String*)out.get(q)).equals(t)) seen = true;
            if (!seen) out.add((Object*)t);
        }
    }
    return out;
}

// `xcc a.o b.o -o prog` for arm64 / ios / ios-sim: the runtime (crt + rt) is
// assembled as the primary input, the objects merge in forced, the archives
// on demand, and the image is written exactly as the source path writes it.
// An object link for the aarch64 ELF rows (arm64 Linux, android): the row's
// crt and runtime assembled as the image path does, the objects and archives
// merged into that model (ElfLinkArm64), their constructors after it, and the
// image written by ElfArm64. The split build links the compiler for an arm64
// Linux host this way.
void linkObjectsArm64Elf(DriverOptions* d)
{
    TargetRow* lrow = d.targetRow();
    String* crt = readRuntime(d.fe(), lrow.crt());
    String* rt  = readRuntime(d.fe(), lrow.runtime());
    if (crt == 0 || rt == 0) {
        Stdio.printf("xcc: error: cannot read the %s runtime from the support tree\n", lrow.name().cString());
        driverExit((i32)1); return;
    }
    String* combined = new String();
    if (xcArgsFor(d, (String*)0)) crt = crtArm64WithXcArgs(d, crt, lrow.crt());
    // Already in the ELF spelling, as the image path takes them.
    combined.append(crt); combined.appendByte((u8)'\n');
    // A program whose objects ask for libRuntime (C/C++ objects, .deplibs)
    // links the library's runtime, not one of its own: one per process. xc
    // objects read the runtime directly: their link keeps its own.
    if (!(lrow.os().equals(String.withCString("linux")) && gObjWantRuntime && runtimeTaken(d))) {
        combined.append(rt);  combined.appendByte((u8)'\n');
    }
    Arm64Asm* as = new Arm64Asm();
    as.assemble(Arm64Asm.machoDialectFromElf(combined));
    as.demoteCommonsToLocalData();
    if (as.failed()) {
        Stdio.printf("xcc: assembly failed: %s\n", as.why().cString());
        driverExit((i32)1); return;
    }
    // The libraries the objects imported (their .xtc.needs sidecars) are
    // needed as an #import <X> in one source would make them.
    Array* needs = objectNeeds(d.objectInputs());
    // So is each shared library a -l names (C++'s -l:libstdc++.so.6).
    for (u32 i = (u32)0; i < d.linkInputs().count(); i = i + (u32)1) {
        String* t = (String*)d.linkInputs().get(i);
        if (!t.hasPrefix(String.withCString("-l"))) continue;
        String* lp = resolveLinkInput(d, t);
        if (lp != (String*)0 && isSharedLib(lp)) needs.add((Object*)lp);
    }
    for (u32 i = (u32)0; i < needs.count(); i = i + (u32)1) {
        bool have = false;
        for (u32 k = (u32)0; k < d.fe().neededLibs().count(); k = k + (u32)1)
            if (((String*)d.fe().neededLibs().get(k)).equals((String*)needs.get(i))) have = true;
        if (!have) d.fe().neededLibs().add(needs.get(i));
    }
    SectionBytes* aData = as.dataBytes();
    Array* aFix  = as.fixups();
    mergeElfLinkObjects(d, as.textBytes(), aData, as.symbols(), as.dataSyms(), aFix, d.objectInputs(), as);
    u32 aMi = Arm64Asm.appendModInit(as, aData, aFix);
    String* baseNeeded = new String();
    for (u32 ni = (u32)0; ni < lrow.needed().count(); ni = ni + (u32)1) {
        if (ni > (u32)0) baseNeeded.appendCString(",");
        baseNeeded.append((String*)lrow.needed().get(ni));
    }
    ElfArm64* w = new ElfArm64();
    w.setInterp(lrow.interp());
    w.setRunpath(arm64ElfRunpath(d, lrow));
    if (lrow.os().equals(String.withCString("linux")))
        w.setKnownImports(arm64KnownImports(d));
    w.image(as.textBytes(), aData, as.symbols(), as.dataSyms(), gArm64CExports != (Array*)0 ? gArm64CExports : new Array(), aFix, (String*)0,
            androidNeededWithImports(d, baseNeeded.cString()), String.withCString("_start"), aMi);
    if (w.failed()) {
        Stdio.printf("xcc: %s link failed: %s\n", lrow.name().cString(), w.why().cString());
        driverExit((i32)1); return;
    }
    Data* od = w.bytes();
    if (!Files.writeData(d.fe().output(), od)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        driverExit((i32)1); return;
    }
    Files.setExecutable(d.fe().output());
}

// The functions of Mach-O-spelled assembly, by their ELF names: each line
// `_name:` (a block label is `L…` or `.L…`), its underscore dropped.
Map* machoFunctionNames(String* text)
{
    Map* out = new Map();
    Array* lines = text.splitOnByte((u8)'\n');
    for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
        String* l = (String*)lines.get(i);
        u32 n = l.byteLength();
        if (n < (u32)3 || l.byteAt((u32)0) != (u8)'_' || l.byteAt(n - (u32)1) != (u8)':') continue;
        bool plain = true;
        for (u32 k = (u32)1; k + (u32)1 < n; k = k + (u32)1) {
            u8 c = l.byteAt(k);
            if (c == (u8)' ' || c == (u8)'\t' || c == (u8)'"') plain = false;
        }
        if (!plain) continue;
        String* nm = l.substringBytes((u32)1, n - (u32)2);
        out.set((Hashable*)nm, (Object*)nm);
    }
    return out;
}

// The libraries an ELF C/C++ object asks its link for (.deplibs): the `-l`
// entries of objectLinkerOptions without their `-l` (`Runtime`,
// `:libstdc++.so.6`). Empty for an xc object.
Array* objectDepLibs(DriverOptions* d)
{
    Array* out = new Array();
    Array* groups = objectLinkerOptions(d);
    for (u32 i = (u32)0; i < groups.count(); i = i + (u32)1) {
        Array* g = (Array*)groups.get(i);
        if (g.count() != (u32)1) continue;
        String* a = (String*)g.get((u32)0);
        if (a.hasPrefix(String.withCString("-l"))) out.add((Object*)a.substringFromByte((u32)2));
    }
    return out;
}

// An object-only ELF link: each object's .deplibs. `Runtime` is this target's
// libRuntime, taken as a C/C++ program takes it (resolveRuntimeLib); any other
// name is a `-l` input. Whether any object asked for something.
// Whether an object of this link asked for the runtime library (`Runtime` in
// its .deplibs): a C/C++ object, whose xcc half reads libRuntime's canary
// guard through the GOT. An xc object reads the runtime directly, so its link
// keeps a runtime of its own even where the target has a libRuntime.
bool gObjWantRuntime;

bool addObjectDepLibs(DriverOptions* d)
{
    bool any = false;
    bool wantRt = false;
    for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1) {
        String* op = (String*)d.objectInputs().get(i);
        if (!op.hasSuffix(String.withCString(".o"))) continue;
        Data* od = Files.readData(op);
        Array* dl = (Array*)0;
        if (isWin64(d))
            dl = CoffObject.defaultLibsOf(od);
        else
            dl = ElfObject.parse(od).depLibs();
        for (u32 k = (u32)0; dl != (Array*)0 && k < dl.count(); k = k + (u32)1) {
            String* nm = (String*)dl.get(k);
            any = true;
            // libRuntime, or the libRuntimeSupport a C or C++ object took (#278):
            // either way the program's runtime is the library's.
            if (nm.equals(String.withCString("Runtime")) || nm.equals(String.withCString("RuntimeSupport"))) {
                wantRt = true; gObjWantRuntime = true;
                if (nm.equals(String.withCString("RuntimeSupport"))) gObjWantRuntimeSupport = true;
                continue;
            }
            String* li = String.withCString("-l").appending(nm);
            bool have = false;
            for (u32 q = (u32)0; q < d.linkInputs().count(); q = q + (u32)1)
                if (((String*)d.linkInputs().get(q)).equals(li)) have = true;
            if (!have) d.linkInputs().add((Object*)li);
        }
    }
    if (wantRt && d.fe().runtimeLibFile() == (String*)0) resolveRuntimeLib(d);
    return any;
}

// The LC_LINKER_OPTION groups an arm64 macOS C/C++ object carries: `-framework X`
// for each framework the module needs (#import <X>, -framework on the line),
// and `-l<name>` for each library its language links (C++: libc++).
Array* objectLinkerOptions(DriverOptions* d)
{
    Array* out = new Array();
    // C/C++ objects only: an xc object stays byte for byte as it was.
    if (gCSplitOut == (String*)0) return out;
    Map* seen = new Map();
    Array* fws = new Array();
    Array* nl = d.fe().neededLibs();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
        String* lp = (String*)nl.get(i);
        if (lp.hasPrefix(String.withCString("framework:"))) fws.add((Object*)lp.substringFromByte((u32)10));
    }
    Array* fw = d.frameworks();
    for (u32 i = (u32)0; fw != (Array*)0 && i < fw.count(); i = i + (u32)1) fws.add(fw.get(i));
    for (u32 i = (u32)0; i < fws.count(); i = i + (u32)1) {
        String* nm = (String*)fws.get(i);
        String* key = String.withFormat("framework:%s", nm.cString());
        if (seen.get((Hashable*)key) != (Object*)0) continue;
        seen.set((Hashable*)key, (Object*)nm);
        Array* g = new Array();
        g.add((Object*)String.withCString("-framework"));
        g.add((Object*)nm);
        out.add((Object*)g);
    }
    // The shared runtime the object's xc half takes (resolveRuntimeLib), as
    // `-lRuntime` (a relocatable link keeps only -l and -framework): the
    // link finds it as resolveRuntimeLib does.
    if (d.fe().runtimeLibFile() != (String*)0) {
        Array* g = new Array();
        // libRuntimeSupport's object (#278) asks for that library, not libRuntime.
        String* rb = d.fe().runtimeLibFile().lastPathComponent();
        g.add((Object*)String.withCString(rb.hasPrefix(String.withCString("libRuntimeSupport.")) ? "-lRuntimeSupport" : "-lRuntime"));
        out.add((Object*)g);
    }
    if (d.targetRow() != (TargetRow*)0) {
        Array* libs = CPath.language().libsFor(d.targetRow().os());
        for (u32 i = (u32)0; i < libs.count(); i = i + (u32)1) {
            Array* g = new Array();
            g.add((Object*)String.withFormat("-l%s", ((String*)libs.get(i)).cString()));
            out.add((Object*)g);
        }
    }
    return out;
}

// The libRuntime an object-only link's objects asked for (`-lRuntime`), or 0:
// the link then imports it and assembles no runtime of its own.
String* gObjRuntimeLib;

// An object-only link takes what its objects ask for (LC_LINKER_OPTION):
// each `-framework X` joins the frameworks, each `-l<name>` the libraries
// (on macOS the SDK's stub of it, or its static library), once each.
void addObjectLinkerOptions(DriverOptions* d)
{
    for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1) {
        String* op = (String*)d.objectInputs().get(i);
        if (!op.hasSuffix(String.withCString(".o"))) continue;
        MachOObject* o = MachOObject.atPath(op);
        if (o == (MachOObject*)0 || o.linkerOpts() == (Array*)0) continue;
        for (u32 k = (u32)0; k < o.linkerOpts().count(); k = k + (u32)1) {
            Array* g = (Array*)o.linkerOpts().get(k);
            if (g.count() == (u32)2 && ((String*)g.get((u32)0)).equals(String.withCString("-framework"))) {
                String* nm = (String*)g.get((u32)1);
                bool have = false;
                for (u32 q = (u32)0; q < d.frameworks().count(); q = q + (u32)1)
                    if (((String*)d.frameworks().get(q)).equals(nm)) have = true;
                if (!have) d.frameworks().add((Object*)nm);
            } else if (g.count() == (u32)1 && (((String*)g.get((u32)0)).equals(String.withCString("-lRuntime"))
                                               || ((String*)g.get((u32)0)).equals(String.withCString("-lRuntimeSupport")))) {
                // xcc's shared runtime (the objects' xc halves took it): this
                // target's libRuntime, or the libRuntimeSupport a C or C++
                // program's took (#278), imported, its directory a runpath.
                String* rname = ((String*)g.get((u32)0)).substringFromByte((u32)2);
                String* root = supportRoot(d.fe());
                if (root == (String*)0 || d.targetRow() == (TargetRow*)0) continue;
                Array* exts = d.targetRow().libExts();
                for (u32 e = (u32)0; exts != (Array*)0 && e < exts.count(); e = e + (u32)1) {
                    String* lp = String.withFormat("%s/runtime-lib/%s/lib%s.%s", root.cString(),
                                                   d.targetRow().name().cString(), rname.cString(), ((String*)exts.get(e)).cString());
                    if (!Files.exists(lp)) continue;
                    if (lp.byteAt((u32)0) != (u8)'/') {
                        IRDbg.setWorkingDirectory(Frontend.workingDirectory());
                        lp = IRDbg.canonicalPath(String.withFormat("%s/%s", Frontend.workingDirectory().cString(), lp.cString()));
                    }
                    gObjRuntimeLib = lp;
                    break;
                }
            } else if (g.count() == (u32)1 && ((String*)g.get((u32)0)).hasPrefix(String.withCString("-l"))) {
                String* nm = ((String*)g.get((u32)0)).substringFromByte((u32)2);
                String* sdk = appleSdkRoot(d);
                if (sdk == (String*)0) continue;
                String* lib = String.withFormat("%s/usr/lib/lib%s.tbd", sdk.cString(), nm.cString());
                if (!Files.exists(lib)) lib = String.withFormat("%s/usr/lib/lib%s.a", sdk.cString(), nm.cString());
                if (!Files.exists(lib)) continue;
                bool have = false;
                for (u32 q = (u32)0; q < d.linkInputs().count(); q = q + (u32)1)
                    if (((String*)d.linkInputs().get(q)).equals(lib)) have = true;
                if (!have) d.linkInputs().add((Object*)lib);
            }
        }
    }
}

void linkObjectsArm64(DriverOptions* d)
{
    // An object-only link has no xc source to keep byte for byte: the
    // objects' unwind tables (a C/C++ object's xcc functions, clang's
    // DWARF-mode entries) are merged into the image.
    machoSetEhMerge(true);
    addObjectLinkerOptions(d);
    String* crt = readRuntime(d.fe(), String.withCString("crt-macos.s"));
    String* rt  = readRuntime(d.fe(), String.withCString("rt-macos.s"));
    if (crt == 0 || rt == 0) {
        Stdio.printf("xcc: error: cannot read the arm64 runtime from the support tree\n");
        driverExit((i32)1); return;
    }
    String* combined = new String();
    if (xcArgsFor(d, (String*)0)) crt = crtArm64WithXcArgs(d, crt, String.withCString("crt-macos.s"));
    combined.append(crt); combined.appendByte((u8)'\n');
    // Objects that took libRuntime: the library carries the runtime.
    if (gObjRuntimeLib == (String*)0) combined.append(rt);
    if (isIos(d)) { combined.appendByte((u8)'\n'); combined.append(iosRuntimeSource(d)); }   // stage 4 shim
    // A C or C++ program: its large malloc blocks are the runtime's (#235).
    gMachORedirect = !isIos(d) && cAllocFor(d, true) ? cAllocRedirects(true) : (Map*)0;
    Arm64Asm* as = new Arm64Asm();
    as.assemble(Arm64Asm.machoDialectFromElf(combined));
    Array* bssCommons = as.takeCommons(); // bug 642: __bss, not __data
    if (as.failed()) {
        Stdio.printf("xcc: assembly failed: %s\n", as.why().cString());
        driverExit((i32)1); return;
    }
    Object* entry = as.symbols().get((Hashable*)String.withCString("_xtc_start"));
    if (entry == (Object*)0) entry = as.symbols().get((Hashable*)String.withCString("_main"));
    if (entry == (Object*)0) {
        Stdio.printf("xcc: no entry symbol (_xtc_start / _main)\n");
        driverExit((i32)1); return;
    }
    SectionBytes* dataBytes = as.dataBytes();
    Array* fixups    = as.fixups();
    Array* objcSects = mergeLinkObjects(d, as.textBytes(), dataBytes, as.symbols(),
                                        as.dataSyms(), fixups, d.objectInputs(), as);
    u32 miLen = Arm64Asm.appendModInit(as, dataBytes, fixups);
    // After the mod-init tail, so the __bss symbols sit past the data (642).
    u32 bssLen = Arm64Asm.allocateBss(bssCommons, dataBytes, as.symbols(), as.dataSyms());

    // What the objects `#import <Lib>`ed (their .xtc.needs sidecars), then
    // the libraries and frameworks named on the line — one rule (arm64LinkDeps).
    Array* objNeeds = objectNeeds(d.objectInputs());
    if (gObjRuntimeLib != (String*)0) {
        if (objNeeds == (Array*)0) objNeeds = new Array();
        // Once: the object's sidecar may name it already, spelled otherwise.
        bool have = false;
        for (u32 k = (u32)0; k < objNeeds.count(); k = k + (u32)1)
            if (((String*)objNeeds.get(k)).lastPathComponent().equals(gObjRuntimeLib.lastPathComponent()))
                have = true;
        if (!have)
            objNeeds.add((Object*)gObjRuntimeLib);
    }
    Array* deps = arm64LinkDeps(d, objNeeds, d.objectInputs());
    MachO* m = new MachO();
    if (isIos(d)) m.setApplePlatform(d.arch());
    m.setDeps(deps);
    m.setRpaths(arm64Rpaths(d, objNeeds));
    m.executable(as.textBytes(), ((Number*)entry).asU32(), as.symbols(),
                 dataBytes, as.dataSyms(), fixups, miLen, objcSects, bssLen);
    checkSystemImports(d, m);
    Data* out = m.bytes();
    if (!Files.writeData(d.fe().output(), out)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        driverExit((i32)1); return;
    }
    Files.setExecutable(d.fe().output());
    signIfRequested(d, d.fe().output());
    if (!d.quiet())
        Stdio.printf("xcc: arm64 executable (from %lu object%s) -> '%s'\n",
                     d.objectInputs().count(), d.objectInputs().count() == (u32)1 ? "" : "s",
                     d.fe().output().cString());
}

// Shift every `Agg(N)` / `#cpool:N` reference in one module's text by the
// running totals, so the merged module's layout and constant indices stay
// consistent (the reference's mergeIRTexts, bug 139).
String* shiftIRIndices(String* text, u32 dLayout, u32 dConst)
{
    if (dLayout == (u32)0 && dConst == (u32)0) return text;
    String* out = new String();
    u32 n = text.byteLength();
    u32 i = (u32)0;
    while (i < n) {
        u8 c = text.byteAt(i);
        // `Agg(` … `)`
        if (dLayout != (u32)0 && c == (u8)'A' && i + (u32)4 <= n
            && text.byteAt(i + (u32)1) == (u8)'g' && text.byteAt(i + (u32)2) == (u8)'g'
            && text.byteAt(i + (u32)3) == (u8)'(') {
            u32 j = i + (u32)4; u32 v = (u32)0; bool digits = false;
            while (j < n && text.byteAt(j) >= (u8)'0' && text.byteAt(j) <= (u8)'9') {
                v = v * (u32)10 + (u32)(text.byteAt(j) - (u8)'0'); j = j + (u32)1; digits = true;
            }
            if (digits && j < n && text.byteAt(j) == (u8)')') {
                out.appendCString("Agg("); out.append(Number.withU32(v + dLayout).description());
                out.appendCString(")");
                i = j + (u32)1; continue;
            }
        }
        // `#cpool:` digits
        if (dConst != (u32)0 && c == (u8)'#' && i + (u32)7 <= n
            && text.substringBytes(i, (u32)7).equals(String.withCString("#cpool:"))) {
            u32 j = i + (u32)7; u32 v = (u32)0; bool digits = false;
            while (j < n && text.byteAt(j) >= (u8)'0' && text.byteAt(j) <= (u8)'9') {
                v = v * (u32)10 + (u32)(text.byteAt(j) - (u8)'0'); j = j + (u32)1; digits = true;
            }
            if (digits) {
                out.appendCString("#cpool:"); out.append(Number.withU32(v + dConst).description());
                i = j; continue;
            }
        }
        out.appendByte(c);
        i = i + (u32)1;
    }
    return out;
}

// String literals are module-local symbols numbered from 0 in every module
// (`str_<n>`), so two objects both have a `str_3` that mean different text.
// Module `k` (k > 0) renames its own to `str_<k>_<n>` before the merge; the
// originals are `str_` and digits only, so the new names cannot collide.
String* renameIRStrLits(String* text, u32 k)
{
    if (k == (u32)0) return text;
    String* out = new String();
    u8* b = text.cString();
    u32 n = text.byteLength();
    u32 i = (u32)0;
    while (i < n) {
        if (i + (u32)4 < n && b[i] == (u8)'s' && b[i + (u32)1] == (u8)'t' && b[i + (u32)2] == (u8)'r'
            && b[i + (u32)3] == (u8)'_' && (i == (u32)0 || !identByte(b[i - (u32)1]))) {
            u32 j = i + (u32)4;
            while (j < n && b[j] >= (u8)'0' && b[j] <= (u8)'9') j = j + (u32)1;
            if (j > i + (u32)4 && (j == n || !identByte(b[j]))) {
                out.appendCString("str_");
                out.append(Number.withU32(k).description());
                out.appendByte((u8)'_');
                out.append(text.substringBytes(i + (u32)4, j - i - (u32)4));
                i = j;
                continue;
            }
        }
        out.appendByte(b[i]);
        i = i + (u32)1;
    }
    return out;
}

// Merge several IR modules into one, for a link-time recompile. The IR text
// is name-based at module scope, so the merge is mostly concatenation. TWO
// things are INDEXED and must be renumbered — `layout N` (referenced as
// Agg(N)) and `constant N` (#cpool:N) — in the declarations AND in every
// reference. Duplicate symbols and functions (the runtime helpers every
// module carries) keep the FIRST definition, as a linker would.
String* mergeIRTexts(Array* texts)
{
    Array* layouts = new Array(); Array* constants = new Array();
    Array* symbols = new Array(); Array* functions = new Array();
    Map* seenSym = new Map(); Map* seenFn = new Map();
    for (u32 ti = (u32)0; ti < texts.count(); ti = ti + (u32)1) {
        String* text = renameIRStrLits(shiftIRIndices((String*)texts.get(ti), layouts.count(), constants.count()), ti);
        Array* lines = text.splitOnByte((u8)10);
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
            String* l = (String*)lines.get(i);
            String* t = l.trimmed();
            if (t.hasPrefix(String.withCString("module ")) || t.equals(String.withCString("}"))
                || t.byteLength() == (u32)0) continue;
            if (t.hasPrefix(String.withCString("layout "))) {
                u32 c = t.byteIndexOf(String.withCString(":"));
                if (c == String.notFound()) continue;
                String* o = String.withCString("  layout "); o.append(Number.withU32(layouts.count()).description());
                o.append(t.substringFromByte(c));
                layouts.add((Object*)o);
                continue;
            }
            if (t.hasPrefix(String.withCString("constant "))) {
                u32 c = t.byteIndexOf(String.withCString(":"));
                if (c == String.notFound()) continue;
                String* o = String.withCString("  constant "); o.append(Number.withU32(constants.count()).description());
                o.append(t.substringFromByte(c));
                constants.add((Object*)o);
                continue;
            }
            if (t.hasPrefix(String.withCString("symbol "))) {
                u32 sp = t.byteIndexOf(String.withCString(":"));
                String* nm = sp == String.notFound() ? t : t.substringBytes((u32)7, sp - (u32)7).trimmed();
                String* blk = String.withString(l);
                while (i + (u32)1 < lines.count()) {
                    String* nx = ((String*)lines.get(i + (u32)1)).trimmed();
                    if (!nx.hasPrefix(String.withCString("attributes:"))) break;
                    i = i + (u32)1;
                    blk.appendCString("\n"); blk.append((String*)lines.get(i));
                }
                // The first declaration of a name is kept, except that a
                // DEFINITION replaces an `extern` one: the object that imports
                // a class may come first, and its vtable declaration is only a
                // reference to the one the defining object carries.
                Number* at = (Number*)seenSym.get((Hashable*)nm);
                if (at == (Number*)0) {
                    seenSym.set((Hashable*)nm, (Object*)Number.withU32(symbols.count()));
                    symbols.add((Object*)blk);
                } else {
                    String* kept = (String*)symbols.get(at.asU32());
                    String* ext = String.withCString("extern: true");
                    if (kept.contains(ext) && !blk.contains(ext))
                        symbols.set(at.asU32(), (Object*)blk);
                }
                continue;
            }
            if (t.hasPrefix(String.withCString("function "))) {
                u32 par = t.byteIndexOf(String.withCString("("));
                String* nm = par == String.notFound() ? t : t.substringBytes((u32)9, par - (u32)9).trimmed();
                String* blk = String.withString(l);
                u32 j = i + (u32)1;
                for (; j < lines.count(); j = j + (u32)1) {
                    blk.appendCString("\n"); blk.append((String*)lines.get(j));
                    if (((String*)lines.get(j)).equals(String.withCString("  }"))) break;
                }
                i = j;
                if (seenFn.get((Hashable*)nm) == (Object*)0) {
                    seenFn.set((Hashable*)nm, (Object*)Number.withU32((u32)1));
                    functions.add((Object*)blk);
                }
                continue;
            }
        }
    }
    String* out = String.withCString("module \"lto\" {\n");
    for (u32 i = (u32)0; i < layouts.count(); i = i + (u32)1)   { out.append((String*)layouts.get(i));   out.appendCString("\n"); }
    for (u32 i = (u32)0; i < constants.count(); i = i + (u32)1) { out.append((String*)constants.get(i)); out.appendCString("\n"); }
    for (u32 i = (u32)0; i < symbols.count(); i = i + (u32)1)   { out.append((String*)symbols.get(i));   out.appendCString("\n"); }
    for (u32 i = (u32)0; i < functions.count(); i = i + (u32)1) { out.append((String*)functions.get(i)); out.appendCString("\n"); }
    out.appendCString("}\n");
    return out;
}

// --sign: replace the finished Mach-O's ad-hoc signature with the identity's
// (bug 144 — the signer is in-process here; the reference spawns xcc-sign).
// Only meaningful for Mach-O outputs (arm64 / ios / ios-sim).
void signIfRequested(DriverOptions* d, String* outPath)
{
    if (d.signIdentity() == (String*)0) return;
    String* pem = Files.readText(d.signIdentity());
    if (pem == (String*)0) { Stdio.printf("xcc: error: --sign: cannot read '%s'\n", d.signIdentity().cString()); driverExit((i32)1); return; }
    String* pass = Platform.env(String.withCString("XCC_SIGN_PASSPHRASE"));
    if (pass != 0 && pass.byteLength() == (u32)0) pass = (String*)0;
    Identity* id = Identity.fromPEM(pem, pass);
    if (id.why() != (String*)0) { Stdio.printf("xcc: error: --sign: %s\n", id.why().cString()); driverExit((i32)1); return; }
    Data* md = Files.readData(outPath);
    if (md == (Data*)0) { Stdio.printf("xcc: error: --sign: cannot read '%s'\n", outPath.cString()); driverExit((i32)1); return; }
    Data* ent = id.entitlements();
    if (d.signEntitlements() != (String*)0) {
        Data* ed = Files.readData(d.signEntitlements());
        if (ed == (Data*)0) { Stdio.printf("xcc: error: --sign-entitlements: cannot read '%s'\n", d.signEntitlements().cString()); driverExit((i32)1); return; }
        ent = Bytes.fromData(ed);
    }
    CodeSign* cs = new CodeSign();
    Data* img = cs.resign(md, outPath.lastPathComponent(), id, ent, (Data*)0, (Data*)0, String.withCString("20260101000000Z"));
    if (img == (Data*)0) { Stdio.printf("xcc: error: --sign: %s\n", cs.why().cString()); driverExit((i32)1); return; }
    if (!Files.writeData(outPath, img)) { Stdio.printf("xcc: error: cannot write '%s'\n", outPath.cString()); driverExit((i32)1); return; }
    Files.setExecutable(outPath);
    if (!d.quiet()) Stdio.printf("xcc: developer-signed -> '%s'\n", outPath.cString());
}

// The iOS platform shim (support/ios/runtime, iOS.md stage 4): the
// simulator or device flavour of xtios.c's assembly, linked as one more
// runtime source after rt-macos.s. 0 when the target is not iOS.
String* iosRuntimeSource(DriverOptions* d)
{
    if (!isIos(d)) return (String*)0;
    String* name = String.withCString(isIosSim(d) ? "xtios-sim.s" : "xtios.s");
    String* t = readRuntimeIn(d.fe(), "ios/runtime", name);
    if (t == 0) {
        Stdio.printf("xcc: error: cannot read %s from the support tree\n", name.cString());
        driverExit((i32)1);
    }
    return t;
}

// The allocator names CAlloc.xc takes over in a C or C++ program's own
// objects (operator new and delete among them), each mapped to its entry
// point there (ELF spelling, or Mach-O's leading underscore). Libraries keep
// their references. macOS has no memalign. Its
// free() and realloc() find the heap's zone without being renamed; the
// program's are renamed so that an owned block skips the zone search and its
// realloc(NULL, n) of a large n is the heap's block.
Map* cAllocRedirects(bool macho)
{
    Map* m = new Map();
    String* list = String.withCString(macho ? "malloc calloc realloc reallocarray aligned_alloc posix_memalign free"
                                            : "malloc calloc realloc reallocarray aligned_alloc posix_memalign memalign free");
    // C++'s operator new and delete: plain and array, sized, nothrow.
    list.appendCString(" _Znwm _Znam _ZnwmRKSt9nothrow_t _ZnamRKSt9nothrow_t _ZdlPv _ZdaPv _ZdlPvm _ZdaPvm");
    Array* names = list.splitOnByte((u8)' ');
    for (u32 i = (u32)0; i < names.count(); i = i + (u32)1) {
        String* n = (String*)names.get(i);
        String* from = String.withCString(macho ? "_" : "");
        from.append(n);
        String* to = String.withCString(macho ? "__xc_" : "_xc_");
        to.append(n.hasPrefix(String.withCString("_")) ? n.substringFromByte((u32)1) : n);
        m.set((Hashable*)from, (Object*)to);
    }
    return m;
}

// What a Linux C program's executable exports for its libraries, each the
// name of the CAlloc.xc function it is: every library's free, realloc and
// malloc_usable_size reach the heap.
Map* cAllocExports(void)
{
    Map* m = new Map();
    m.set((Hashable*)String.withCString("free"), (Object*)String.withCString("_xc_lib_free"));
    m.set((Hashable*)String.withCString("realloc"), (Object*)String.withCString("_xc_lib_realloc"));
    m.set((Hashable*)String.withCString("malloc_usable_size"), (Object*)String.withCString("_xc_lib_usable_size"));
    return m;
}

// Whether an object of the link carries the heap (CAlloc.xc's _xc_malloc).
// Whether an x86-64 object of the link reads the runtime's canary guard
// other than through the GOT: one written by -c from an xc file, which
// expects the runtime in the image.
bool objectsReadGuardDirectly(DriverOptions* d)
{
    String* guard = String.withCString("__xt_stack_guard");
    for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1) {
        String* op = (String*)d.objectInputs().get(i);
        if (!op.hasSuffix(String.withCString(".o"))) continue;
        Data* od = Files.readData(op);
        if (od == (Data*)0) continue;
        ElfObject* o = ElfObject.parse(od);
        if (!o.ok()) continue;
        Array* syms = o.symdefs();
        Array* rs = o.relocs();
        for (u32 k = (u32)0; k < rs.count(); k = k + (u32)1) {
            ElfReloc* r = (ElfReloc*)rs.get(k);
            if (r.sym() >= syms.count()) continue;
            String* n = ((ElfSymDef*)syms.get(r.sym())).name();
            // R_X86_64_GOTPCREL, GOTPCRELX, REX_GOTPCRELX
            if (n != (String*)0 && n.equals(guard)
                && r.type() != (u32)9 && r.type() != (u32)41 && r.type() != (u32)42) return true;
        }
    }
    return false;
}

bool objectsCarryHeap(DriverOptions* d)
{
    Map* heap = new Map();
    String* hn = String.withCString("_xc_malloc");
    heap.set((Hashable*)hn, (Object*)hn);
    for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1) {
        String* op = (String*)d.objectInputs().get(i);
        if (!op.hasSuffix(String.withCString(".o"))) continue;
        Data* od = Files.readData(op);
        if (od == (Data*)0) continue;
        ElfObject* o = ElfObject.parse(od);
        if (o.ok() && o.definesAnyOf(heap)) return true;
    }
    return false;
}

// Whether this link turns on the heap of a C program's large blocks: an
// object carries it (CAlloc.xc, in a C or C++ object's xcc half) and no
// object defines an allocator of its own (a program that brings its own
// malloc keeps it, with every block unknown to par, as before).
bool cAllocFor(DriverOptions* d, bool macho)
{
    Map* names = cAllocRedirects(macho);
    String* us = String.withCString(macho ? "_malloc_usable_size" : "malloc_usable_size");
    names.set((Hashable*)us, (Object*)us);
    Map* heap = new Map();
    String* hn = String.withCString(macho ? "__xc_malloc" : "_xc_malloc");
    heap.set((Hashable*)hn, (Object*)hn);
    bool carried = false;
    Array* paths = new Array();
    paths.addAll(d.objectInputs());
    Array* li = d.linkInputs();
    for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) paths.add(li.get(i));
    for (u32 i = (u32)0; i < paths.count(); i = i + (u32)1) {
        String* op = (String*)paths.get(i);
        if (!op.hasSuffix(String.withCString(".o"))) continue;
        if (macho) {
            MachOObject* o = MachOObject.atPath(op);
            if (o == (MachOObject*)0) continue;
            if (o.definesAny(names)) return false;
            if (o.definesAny(heap)) carried = true;
        } else {
            Data* od = Files.readData(op);
            if (od == (Data*)0) continue;
            ElfObject* o = ElfObject.parse(od);
            if (!o.ok()) continue;
            if (o.definesAnyOf(names)) return false;
            if (o.definesAnyOf(heap)) carried = true;
        }
    }
    return carried;
}

// Objects as inputs, dispatched per target. What is not ported is REFUSED
// naming the gap, never linked as something else.
// A C program (the C path): xcc's object, just written, and clang's for the
// rest, linked into the program the command line asked for.
void cSplitLink(DriverOptions* d)
{
    String* xo = d.fe().output();
    // XC_C_KEEP=<prefix>: xcc's half as an object too (<prefix>.x.o).
    String* keepPrefix = Platform.env(String.withCString("XC_C_KEEP"));
    if (keepPrefix.byteLength() > (u32)0) {
        Data* xd = Files.readData(xo);
        if (xd != (Data*)0) Files.writeData(keepPrefix.appending(String.withCString(".x.o")), xd);
    }
    if (gCSplitRelocatable && gCSplitPair) {
        // win64's two objects, side by side (--c-pair).
        String* out = gCSplitOut;
        gCSplitOut = (String*)0;
        String* rest = stripExtension(out);
        rest.appendCString(".rest.o");
        Data* xd = Files.readData(xo);
        Data* rd = Files.readData(cRestObject());
        if (xd == (Data*)0 || rd == (Data*)0 || !Files.writeData(out, xd) || !Files.writeData(rest, rd)) {
            Stdio.printf("xcc: error: cannot write '%s' and '%s'\n", out.cString(), rest.cString());
            driverExit((i32)1); return;
        }
        writeCObjectSidecars(xo, out);
        d.fe().setOutput(out);
        return;
    }
    if (gCSplitRelocatable) {
        String* out = gCSplitOut;
        gCSplitOut = (String*)0;
        if (cPathRelocatable(xo, out) != (i32)0) {
            Stdio.printf("xcc: error: clang -r could not make '%s' from the two halves of the C file\n", out.cString());
            driverExit((i32)1); return;
        }
        writeCObjectSidecars(xo, out);
        d.fe().setOutput(out);
        return;
    }
    d.objectInputs().add((Object*)xo);
    d.objectInputs().add((Object*)cRestObject());
    d.fe().setOutput(gCSplitOut);
    d.setCompileOnly(false);
    gCSplitOut = (String*)0;
    // Linked as the program was compiled: on x86-64 that is the dynamic
    // glibc link by default (an object-only link is otherwise the static
    // musl one), which the par runtime's dlopen of a GPU library needs, and
    // which Par.xc was told of (LIBC_glibc).
    if (isX86_64(d) && d.caps().dynamic()) {
        noteLinkFlags(d);
        linkX86_64Glibc(d, String.withCString(""));
        return;
    }
    linkObjects(d);
}

// The language's runtime libraries (C++: libc++), for the program's link:
// on macOS the SDK's stub of each, elsewhere -l<name>.
void addLanguageLibs(DriverOptions* d, LanguageRow* lang)
{
    TargetRow* row = d.targetRow();
    if (row == (TargetRow*)0) return;
    Array* libs = lang.libsFor(row.os());
    for (u32 i = 0; i < libs.count(); i = i + 1) {
        String* nm = (String*)libs.get(i);
        if (row.os().equals(String.withCString("macos"))) {
            String* sdk = appleSdkRoot(d);
            String* tbd = sdk != (String*)0 ? String.withString(sdk) : String.withCString("");
            tbd.appendCString("/usr/lib/lib");
            tbd.append(nm);
            tbd.appendCString(".tbd");
            // A static library where the SDK has no stub (libc++'s
            // experimental library: the parallel algorithms' libdispatch
            // back end).
            if (sdk != (String*)0 && !Files.exists(tbd)) {
                String* ar = String.withString(sdk);
                ar.appendCString("/usr/lib/lib");
                ar.append(nm);
                ar.appendCString(".a");
                if (Files.exists(ar)) tbd = ar;
            }
            if (sdk == (String*)0 || !Files.exists(tbd)) {
                Stdio.printf("xcc: error: a %s program links lib%s, and no macOS SDK has it (install the Command Line Tools)\n",
                             lang.name().cString(), nm.cString());
                driverExit((i32)1); return;
            }
            d.linkInputs().add((Object*)tbd);
        } else {
            d.linkInputs().add((Object*)String.withCString("-l").appending(nm));
        }
    }
}

void linkObjects(DriverOptions* d)
{
    noteLinkFlags(d);
    bool anyObject = false;
    for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1)
        if (((String*)d.objectInputs().get(i)).hasSuffix(String.withCString(".o"))
            || ((String*)d.objectInputs().get(i)).hasSuffix(String.withCString(".obj"))) anyObject = true;
    if (!anyObject) {
        Stdio.printf("xcc: error: a link of archives alone has nothing to seed the demand — "
                     "name at least one .o\n");
        driverExit((i32)1); return;
    }
    if (d.compileOnly() || d.emitLib()) {
        Stdio.printf("xcc: error: -c / --emit-lib take source, not objects\n");
        driverExit((i32)1); return;
    }
    if (d.fe().output() == (String*)0) {
        Stdio.printf("xcc: error: an object link needs -o <program>\n");
        driverExit((i32)1); return;
    }
    if (d.lto()) {
        // Link-time recompile: every object's carried IR (`<obj>.xtc.ir`,
        // written by -c) merged into one module and compiled as if the
        // program had been one source — the optimiser then sees across the
        // module boundaries. An object without its IR is refused by name.
        Array* irs = new Array();
        for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1) {
            String* op = (String*)d.objectInputs().get(i);
            if (!op.hasSuffix(String.withCString(".o"))) continue;
            String* side = stripExtension(op); side.appendCString(".xtc.ir");
            String* t = Files.readText(side);
            if (t == (String*)0 || t.byteLength() == (u32)0) {
                Stdio.printf("xcc: error: -flto needs '%s' (compile that module with -c so it "
                             "carries its IR)\n", side.cString());
                driverExit((i32)1); return;
            }
            irs.add((Object*)t);
        }
        String* merged = mergeIRTexts(irs);
        IrParser* ip = new IrParser();
        IRModule* mod = ip.run(merged);
        if (mod == 0 || ip.failed()) {
            Stdio.printf("xcc: error: -flto: the merged IR did not parse: %s\n",
                         ip.why() == 0 ? "?" : ip.why().cString());
            driverExit((i32)3); return;
        }
        d.setIrText(merged);
        // arm9 records the objects' `#import <Lib>` dependencies as DT_NEEDED
        // from their sidecars, as the reference's LTO link does; the merged
        // module has no front end to name them.
        if (isArm9(d)) d.fe().setNeededLibs(objectNeeds(d.objectInputs()));
        d.fe().setTarget(backendTargetOf(d));
    if (isIos(d)) d.fe().setLibPlatform(d.arch());
    d.fe().setTargetRow(d.targetRow());
        emitModule(d, mod);
        return;
    }
    // Objects that say what they link (a C/C++ object's ELF .deplibs, COFF
    // .drectve).
    bool askers = false;
    if ((d.targetRow() != (TargetRow*)0 && d.targetRow().exeFormat().hasPrefix(String.withCString("elf")))
        || isWin64(d))
        askers = addObjectDepLibs(d);
    // A C or C++ object that asks for no library is one too when it carries
    // the heap of the program's large blocks (CAlloc.xc, compiled for the
    // glibc link).
    if (!askers && d.targetRow() != (TargetRow*)0 && d.targetRow().exeFormat().hasPrefix(String.withCString("elf"))
        && isX86_64(d) && objectsCarryHeap(d))
        askers = true;
    // win64: a C++ program's objects keep clang's SEH tables (.pdata/.xdata),
    // as the one-step C path does.
    if (askers && isWin64(d))
        CoffObject.setKeepUnwind(true);
    // A C/C++ program's objects: their frame tables gathered, as the C path's.
    if (askers) elfSetEhGather(true);
    if (d.targetRow() != (TargetRow*)0 && d.targetRow().exeFormat().equals(String.withCString("elf-pie"))) {
        linkObjectsArm64Elf(d); return;
    }
    if (isMacArm64(d) || isIos(d)) { linkObjectsArm64(d); return; }
    // An object link is the dynamic glibc one, as a build from source is
    // (-c compiled the objects for glibc); -static gives the static musl one.
    if (isX86_64(d) && !d.caps().staticLink()) {
        linkX86_64Glibc(d, String.withCString("")); return;
    }
    if (isX86_64(d)) { linkX86_64(d, String.withCString("")); return; }
    if (isArm9(d)) { linkObjectsArm9(d); return; }
    if (isWin64(d)) {
        // A win64 object link is a STATIC PE and cannot record a DLL
        // dependency for an xtc library the objects imported.
        Array* needs = objectNeeds(d.objectInputs());
        if (needs.count() > (u32)0) {
            Stdio.printf("xcc: error: these objects import xtc libraries, but a win64 object link "
                         "cannot record a DLL dependency for them yet.\n  Link from source, or "
                         "compile the modules together.\n");
            driverExit((i32)1); return;
        }
        linkWin64(d, String.withCString(""));
        return;
    }
    Stdio.printf("xcc: error: linking objects for '%s' is not ported in this driver yet "
                 "(arm64, ios, ios-sim, x86_64, win64 and arm9 are)\n", d.arch().cString());
    driverExit((i32)1);
}

#if OS_linux
// struct rlimit: { rlim_cur, rlim_max }, two u64s.
i32 getrlimit(i32 resource, u64* rl);
i32 setrlimit(i32 resource, u64* rl);
#endif

// Compiling a large program recurses deeply (the compiler itself for win64
// overflowed the default 8 MB after six minutes). Linux grows the main
// thread's stack on demand up to the soft RLIMIT_STACK, checked when it
// faults, and leaves at least 128 MB below it at exec; so the soft limit is
// raised towards the hard one (at most 1 GB), and nothing else changes.
void raiseStackLimit(void)
{
#if OS_linux
    u64 rl[2];
    if (getrlimit((i32)3, &rl[0]) != (i32)0) return; // RLIMIT_STACK
    u64 want = (u64)1 << (u64)30;
    if (rl[1] < want) want = rl[1];
    if (rl[0] >= want) return;
    rl[0] = want;
    setrlimit((i32)3, &rl[0]);
#endif
}

// The source files after the first (`xcc a.cpp b.c c.xc -o prog`), or 0.
Array* gExtraSources;

// A build of several source files: each compiled by this xcc as `-c` would
// compile it, with the line's other options, into an object (a temporary
// one, or with -c `<name>.o` here, as other compilers do), then the objects
// linked by this xcc into the program. Each file is its own module, as with
// separate compilation (C/C++ objects say what they link and share the
// runtime, #225). The status is the first failure's, else 0.
i32 multiSourceBuild(DriverOptions* d)
{
    Array* srcs = new Array();
    srcs.add((Object*)d.fe().input());
    srcs.addAll(gExtraSources);
    bool cOnly = d.compileOnly();
    String* out = d.fe().output();
    if (cOnly && out != (String*)0) {
        Stdio.printf("xcc: error: -o names one object, and -c with several sources makes one each\n");
        return (i32)1;
    }
    // The line's options: everything but the sources, -c and -o <file>.
    Array* flags = new Array();
    u32 argc = Process.argumentCount();
    for (u32 i = (u32)1; i < argc; i = i + (u32)1) {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("-o"))) { i = i + (u32)1; continue; }
        if (a.equals(String.withCString("-c"))) continue;
        bool isSrc = false;
        for (u32 k = (u32)0; k < srcs.count(); k = k + (u32)1)
            if (((String*)srcs.get(k)).equals(a)) isSrc = true;
        if (!isSrc) flags.add((Object*)a);
    }
    String* self = Process.argument((u32)0);
    Array* objs = new Array();
    for (u32 k = (u32)0; k < srcs.count(); k = k + (u32)1) {
        String* src = (String*)srcs.get(k);
        String* obj = (String*)0;
        if (cOnly) {
            String* base = src.lastPathComponent();
            u32 dot = (u32)$FFFFFFFF;
            for (u32 q = (u32)0; q < base.byteLength(); q = q + (u32)1)
                if (base.byteAt(q) == (u8)'.') dot = q;
            obj = (dot != (u32)$FFFFFFFF ? base.substringBytes((u32)0, dot) : base).appending(String.withCString(".o"));
        } else
            obj = External.tempPath(String.withFormat("xcc-src%u.o", k).cString());
        Array* argv = new Array();
        argv.add((Object*)self);
        // A -std= goes to the files of its language only (`-std=c++20` to the
        // C++ files, `-std=c17` to the C ones) in a build that mixes them.
        LanguageRow* lr = Languages.forFile(src);
        bool isCxx = lr != (LanguageRow*)0 && lr.name().equals(String.withCString("c++"));
        bool isC = lr != (LanguageRow*)0 && lr.name().equals(String.withCString("c"));
        for (u32 q = (u32)0; q < flags.count(); q = q + (u32)1) {
            String* f = (String*)flags.get(q);
            if (f.hasPrefix(String.withCString("-std="))) {
                bool cxxStd = f.contains(String.withCString("++"));
                if ((isC && cxxStd) || (isCxx && !cxxStd)) continue;
            }
            argv.add((Object*)f);
        }
        argv.add((Object*)String.withCString("-c"));
        // win64 has no relocatable COFF link: a C/C++ file's two objects.
        if (!cOnly && isWin64(d))
            argv.add((Object*)String.withCString("--c-pair"));
        argv.add((Object*)String.withCString("-o"));
        argv.add((Object*)obj);
        argv.add((Object*)src);
        if (External.run(argv) != (i32)0) return (i32)1;
        objs.add((Object*)obj);
        String* rest = stripExtension(obj);
        rest.appendCString(".rest.o");
        if (Files.exists(rest)) objs.add((Object*)rest);
    }
    if (cOnly) return (i32)0;
    Array* link = new Array();
    link.add((Object*)self);
    for (u32 q = (u32)0; q < flags.count(); q = q + (u32)1)
        if (!((String*)flags.get(q)).hasPrefix(String.withCString("-std=")))
            link.add(flags.get(q));
    link.add((Object*)String.withCString("-o"));
    link.add((Object*)(out != (String*)0 ? out : String.withCString("a.out")));
    link.addAll(objs);
    i32 rc = External.run(link);
    for (u32 k = (u32)0; k < objs.count(); k = k + (u32)1)
        Directory._unlink((String*)objs.get(k));
    return rc == (i32)0 ? (i32)0 : (i32)1;
}

// The run, then its scratch directory removed (#337) whichever way the run
// ended without exiting: xccMain returns from many places.
void main(void)
{
    xccMain();
    if (!External.keepingScratch())
        External.cleanup();
}

void xccMain(void)
{
    raiseStackLimit();
    DriverOptions* d = parseDriverArgs();
    // -V (--verbose) keeps the run's scratch directory for a look; otherwise it goes on
    // every way out (driverExit, #337).
    External.setKeepScratch(d.fe().verbose());
    if (d != 0 && gExtraSources != (Array*)0 && gExtraSources.count() > (u32)0) {
        driverExit(multiSourceBuild(d));
        return;
    }
    // --print-target: the row the command line names, and nothing else.
    if (d != 0 && d.printTarget()) {
        TargetRow* r = d.targetRow();
        if (r == (TargetRow*)0) {
            Stdio.printf("xcc: error: --print-target: '%s' is not a target\n", d.arch().cString());
            driverExit((i32)1); return;
        }
        Stdio.printf("%s", r.describe().cString());
        driverExit((i32)0); return;
    }
    // --print-3p-dir: the compiler's OWN third-party tree, <home>/3p (an
    // install's <prefix>/3p), the first it searches after $XCC_3P, whether or
    // not it exists yet. As the reference.
    if (d != 0 && d.print3pDir()) {
        String* sup = supportRoot(d.fe());
        String* home = (String*)0;
        if (sup != 0)
            home = sup.hasSuffix(String.withCString("/lib/xc")) ? dirOf(dirOf(sup)) : dirOf(sup);
        if (home == (String*)0) {
            Stdio.printf("xcc: error: --print-3p-dir: no support tree found\n");
            driverExit((i32)1); return;
        }
        // Absolute, with `.` and `..` resolved, so a script can use it as is
        // (as the reference's URLByStandardizingPath).
        String* p3 = home.appendingPathComponent(String.withCString("3p"));
        if (!p3.hasPrefix(String.withCString("/")))
            p3 = Frontend.workingDirectory().appendingPathComponent(p3);
        Array* parts = p3.splitOnByte((u8)'/');
        Array* keep = new Array();
        for (u32 k = (u32)0; k < parts.count(); k = k + (u32)1) {
            String* c = (String*)parts.get(k);
            if (c.byteLength() == (u32)0 || c.equals(String.withCString(".")))
                continue;
            if (c.equals(String.withCString(".."))) {
                if (keep.count() > (u32)0) keep.removeLast();
                continue;
            }
            keep.add((Object*)c);
        }
        String* out = String.withCString("/");
        out.append(String.join(keep, String.withCString("/")));
        Stdio.printf("%s\n", out.cString());
        driverExit((i32)0); return;
    }
    // --sign-bundle <dir>: sign, and compile nothing.
    if (d != 0 && d._signBundle != (String*)0) {
        signBundle(d);
        return;
    }
    if (d == 0 || (d.fe().input() == 0 && d.objectInputs().count() == (u32)0)) {
        Stdio.printf("usage: xcc [-A arm64|ios|ios-sim|android|x86_64|win64|arm9|m68k|wasm32|6502] "
                     "[-On] [-H home] [-I dir] [-D k=v] <file.xc> -o <out>\n"
                     "       xcc -h lists every option\n");
        driverExit((i32)2); return;
    }
    // No -o: a program's assembly to standard output, as the reference does
    // (writeAsmOut). Without it the driver went on to link a program to no
    // path and died.
    if (d.fe().output() == (String*)0 && d.fe().input() != 0 && d.fe().input().hasSuffix(String.withCString(".xc"))
        && !d.compileOnly() && !d.emitLib())
        d.setKeepAsm(true);
    // --trust: the publishers' fingerprints, for Plugin.xc.
    if (d._trusted != (String*)0) {
        String* def = String.withCString("XC_PLUGIN_TRUST=\"");
        def.append(d._trusted);
        def.appendByte((u8)'"');
        d.fe().defs().add((Object*)def);
    }
    // --bundle on wasm32: a plugin is a module of its own with its own
    // memory (bundles-and-plugins.md §2), not the library shape that shares
    // the app's.
    if (d.bundleDir() != (String*)0 && isWasm(d)) {
        d.setEmitLib(false);
        d.fe().setEmitIface(false);
        d.fe().setLibraryBuild(false);
    }
    checkCapabilities(d);
    // `--emit-lib` on a target with no library form is REFUSED, never run
    // down the executable path: a library that is silently not a library is
    // discovered by whatever tries to load it, a build step away
    // (private:docs/bugs/097). A GEMDOS program and a banked XEX are whole
    // images loaded at one place; neither format has a shared-object form.
    if (d.emitLib() && (isM68k(d) || isXt6502(d))) {
        Stdio.printf("xcc: error: --emit-lib: '%s' has no shared-library format — "
                     "%s is loaded whole, so build the program instead\n",
                     d.arch().cString(),
                     isM68k(d) ? "a GEMDOS .prg" : "a banked 6502 .xex");
        driverExit((i32)1); return;
    }
    if (d.emitLib() && !isWasm(d) && !isX86_64(d) && !isArm9(d) && !isAndroid(d)
        && (d.targetRow() == (TargetRow*)0 || !d.targetRow().exeFormat().equals(String.withCString("elf-pie")))
        && !isIos(d) && !isMacArm64(d)
        && !isWin64(d)) {
        Stdio.printf("xcc: error: --emit-lib is not supported for '%s' "
                     "(it is for arm64, ios, android, x86_64, win64, arm9 and wasm32)\n",
                     d.arch().cString());
        driverExit((i32)1); return;
    }
    // A target is wired when the table has its row.
    if (d.targetRow() == (TargetRow*)0) {
        // Say what is ACTUALLY in the way. This used to tell every refused
        // target it needed "archive reading in the linker — task #47", which
        // is true of x86_64 and win64 and of nothing else, so anyone asking
        // for arm9 or ios was sent to the wrong work.
        string why = "it is not implemented in this driver";
        if (isWin64(d))
            why = "its linker must read .a archives and foreign COFF objects first (task #47); "
                  "the ELF half of that is done and x86_64 now works";
        Stdio.printf("xcc: error: '%s' is not wired in this driver yet — %s.\n"
                     "  built in: arm64, ios, ios-sim, android, xt6502, m68k, wasm32,\n"
                     "             x86_64, win64, arm9\n",
                     d.arch().cString(), why);
        driverExit((i32)2); return;
    }
    // -c is x86_64 only for now: the other targets need their own object
    // writers ported (Mach-O for arm64/android, PE/COFF for win64, and the
    // ELF32 one exists but is not wired). Refusing is the point — a driver
    // that quietly built an EXECUTABLE for `-c` would be discovered by whatever
    // tried to link it.
    if (d.compileOnly() && !isX86_64(d) && !isArm9(d) && !isIos(d)
        && !isWin64(d)
        && !isMacArm64(d)
        && !d.targetRow().exeFormat().equals(String.withCString("elf-pie"))) {
        Stdio.printf("xcc: error: -c is implemented for arm64, ios, ios-sim, x86_64, win64 and arm9 "
                     "in this driver (task #63); '%s' needs its object writer "
                     "ported first.\n", d.arch().cString());
        driverExit((i32)1); return;
    }
    // macOS and iOS link the row's checked runtime (rt-checked: a backtrace
    // with arguments, from the parameter map the arm64 back end emits); every
    // other arm64, x86-64 and win64 row takes its checks from Checked.xc, which
    // the front end imports. Every other target is refused, as the reference
    // refuses it.
    String* ccg = d.targetRow() != (TargetRow*)0 ? d.targetRow().codegen() : String.withCString("");
    if (d.fe().boundsReport()
        && !ccg.equals(String.withCString("arm64")) && !ccg.equals(String.withCString("x86_64"))
        && !ccg.equals(String.withCString("win64"))) {
        Stdio.printf("xcc: error: -fbounds-check is implemented for arm64, x86_64 and win64 so far; "
                     "'%s' has no checked runtime\n", d.arch().cString());
        driverExit((i32)2); return;
    }
    // --link-libs is a wasm32 app's mode; nothing else has one to switch on.
    if (d.linkLibs() && !isWasm(d)) {
        Stdio.printf("xcc: error: --link-libs applies to -A wasm32 (an app that links .wasm "
                     "libraries); '%s' has no such mode\n", d.arch().cString());
        driverExit((i32)1); return;
    }
    d.fe().setTarget(backendTargetOf(d));
    if (isIos(d)) d.fe().setLibPlatform(d.arch());
    d.fe().setTargetRow(d.targetRow());
    resolveRuntimeLib(d);

    // Objects as inputs: the link step. No front end runs — the runtime is
    // the primary input and the objects ride as extras, exactly the shape the
    // linker already takes for archives (separate-compilation Stage 2).
    if (d.fe().input() == 0) { linkObjects(d); return; }
    if (!d.compileOnly() && d.fe().output() != (String*)0
        && d.fe().output().hasSuffix(String.withCString(".o"))) {
        Stdio.printf("xcc: error: '-o %s' without -c would LINK an executable and name it "
                     "'.o'. Use `-c` to compile to an object, or choose another output name\n",
                     d.fe().output().cString());
        driverExit((i32)1); return;
    }
    if (d.objectInputs().count() > (u32)0) {
        Stdio.printf("xcc: error: a source file and object files cannot be mixed on one line — "
                     "compile the source with -c first, then link the objects\n");
        driverExit((i32)1); return;
    }

    // A C or C++ file (a row of the language table): clang compiles it to
    // LLVM IR and the C path reads that (cpp-front-end.md, "The C path").
    IRModule* mod = (IRModule*)0;
    LanguageRow* lang = Languages.forFile(d.fe().input());
    // -std= is clang's, for a C or C++ file; xc has one language.
    if (lang == (LanguageRow*)0 && cPathStd() != (String*)0)
        {
        Stdio.printf("xcc: error: -std= is for a C or C++ file, not '%s'\n", d.fe().input().cString());
        driverExit((i32)1); return;
        }
    if (lang != (LanguageRow*)0)
        {
        cPathSetLanguage(lang);
        // With the IR outliner on (--par-style=auto, or XC_PAR_PROPOSE=outline),
        // the par runtime comes too, lowered from a stub, so loops can
        // become blocks. The user's -I and -D go to clang.
        String* cin = d.fe().input();
        if (d.fe().parAuto())
            optSetOutline(true);
        // -fgoal=speed: a float sum may become a block too (#206).
        if (d.fe().goalDefault() == (u32)1)
            optSetOutlineFloatSum(true);
        Array* cIncs = new Array();
        cIncs.addAll(d.fe().incs());
        Array* cDefs = new Array();
        cDefs.addAll(d.fe().defs());
        optSetPromoteScalars(true);
        // The arm64 ELF rows (arm64 Linux, android): xcc's half is an
        // aarch64 ELF object, and clang's joins it (one step, through the ELF
        // object merge as a -Wl object does; -c, through clang -r).
        TargetRow* crow = d.targetRow();
        bool cElfArm64 = crow != (TargetRow*)0 && crow.cpu().equals(String.withCString("arm64"))
                         && crow.exeFormat().hasPrefix(String.withCString("elf"));
        // -c: one object, xcc's and clang's halves together (cSplitLink).
        // win64's link has no relocatable form: there, build in one step.
        if (d.compileOnly() && !d.keepAsm())
            {
            if (isWin64(d) && !gCSplitPair)
                {
                Stdio.printf("xcc: error: -c of a C file is not done for %s: build the program in one step\n",
                             crow != (TargetRow*)0 ? crow.name().cString() : d.arch().cString());
                driverExit((i32)1); return;
                }
            gCSplitRelocatable = true;
            }
        // clang's own stack protector for its half, where the link has its
        // runtime: macOS, and Linux linked against glibc (the default; arm64
        // Linux is glibc's).
        cPathSetProtect((isMacArm64(d) && !isIos(d))
                        || (isX86_64(d) && d.caps().dynamic())
                        || (cElfArm64 && !isAndroid(d)));
        // A whole program (not -c, not -S): xcc may take an ODR copy, the
        // program's one definition of it then.
        Languages.setWholeProgram(!gCSplitRelocatable && !d.keepAsm() && !d.compileOnly());
        // …and with no loop lifted, the par runtime the C path lowered goes
        // (#278): the program keeps libc's allocator and none of the runtime.
        optSetDropBase(!gCSplitRelocatable && !d.keepAsm() && !d.compileOnly());
        cPathSetDropBase(!gCSplitRelocatable && !d.keepAsm() && !d.compileOnly());
        // The class-name root stays for an object or archive the command line
        // joins (bug 605), not for the language's own libraries (libc++'s
        // archive), which addLanguageLibs adds below.
        optSetDropBaseClassRoot(linkJoinsObjects(d));
        cPathSetElf(crow != (TargetRow*)0 && crow.exeFormat().hasPrefix(String.withCString("elf")));
        // xcc's half carries the heap of the program's large blocks
        // (CAlloc.xc, #235) where the link can turn it on: macOS, x86-64
        // linked against glibc, and arm64 Linux (glibc, #326).
        cPathSetHeap((isMacArm64(d) && !isIos(d) && !cElfArm64)
                     || (isX86_64(d) && d.caps().dynamic())
                     || (cElfArm64 && !isAndroid(d)));
        // arm64 Linux: xcc's half is the image's model, not an object the
        // link redirects, so the C file's allocator calls are renamed in its IR.
        cPathSetAllocRedirect(cElfArm64 && !isAndroid(d) ? cAllocRedirects(false) : (Map*)0);
        // -Wpar-auto: the outliner says what it lifted from this file, and why not.
        optSetWarnParAuto(!d.fe().warningSuppressed(String.withCString("par-auto")));
        // C and C++: unwind tables for xcc's functions, so a C++ exception
        // can pass through one (arm64: the back end reports its saves).
        arm64SetEhTables(true);
        x86SetEhTables(true);
        // C++ handlers compiled by xcc (option (a) phase 2) where the back end
        // writes their tables: arm64 macOS and Linux, x86-64 Linux and win64.
        cPathSetHandlers(crow != (TargetRow*)0 && (crow.name().equals(String.withCString("arm64-macos"))
                                                  || crow.name().equals(String.withCString("arm64-linux"))
                                                  || crow.name().equals(String.withCString("x86_64-linux"))
                                                  || crow.name().equals(String.withCString("x86_64-windows"))));
        machoSetEhMerge(true);
        // This file's suffix for the outliner's symbols, as the reader's for
        // its internal names: two C/C++ objects in one program stay apart.
        optSetModTag(LlvmReader.modTagFor(cin));
        // ELF: every object's frame table (xcc's, clang's) under the one
        // __register_frame, not the first object's alone.
        elfSetEhGather(true);
        // C++ on win64: the link keeps .pdata/.xdata, the SEH tables its
        // exceptions unwind by.
        CoffObject.setKeepUnwind(lang.ehFrames());
        // clang builds for the target, not the host: a triple, and from
        // another host the target's C headers (a sysroot with include/).
        String* tgt = cPathTargetFlags(d, lang.name().equals(String.withCString("c++")));
        if (tgt == (String*)0)
            {
            driverExit((i32)1); return;
            }
        // C++ for win64 from another host: the mingw root's libc++ (its
        // headers here, its static libraries in the link: libc++, libc++abi
        // and libunwind, the row's windows: libraries).
        if (lang.name().equals(String.withCString("c++")) && tgt.contains(String.withCString("mingw")))
            {
            u32 sr = tgt.byteIndexOf(String.withCString("--sysroot "));
            String* root = tgt.substringFromByte(sr + (u32)10);
            tgt = tgt.appending(String.withFormat(" -stdlib=libc++ -nostdinc++ -cxx-isystem %s/include/c++/v1", root.cString()));
            }
        cPathSetTarget(tgt);
        // C fuses the multiply-adds clang marks (llvm.fmuladd, its default
        // -ffp-contract=on), on every target, as GCC and clang do (owner,
        // 2026-11-09). Under -fgoal=accuracy nothing fuses (owner: accuracy
        // never fuses), so clang is asked for none, whatever -ffp-contract says.
        cPathSetFuseMulAdd(true);
        if (d.fe().goalDefault() == (u32)2)
            cPathSetFpContract(String.withCString("off"));
        if (optOutline() || Platform.env(String.withCString("XC_PAR_PROPOSE")).equals(String.withCString("outline")))
            mod = CPath.lowerWith(cin, CPath.scratch(), cIncs, cDefs, d.fe());
        else
            mod = CPath.lower(cin, CPath.scratch(), cIncs, cDefs);
        // xcc's part compiles to an object, clang's is one already: the two
        // are linked where an object of xcc's would be written (cSplitLink).
        // -S: the assembly of xcc's part, at the user's -o (the functions
        // clang compiles are not in it). It used to go to the scratch object
        // and nothing was written where asked.
        bool platformLink = lang.linker().byteLength() > 0 && crow != (TargetRow*)0
                            && crow.name().equals(String.withCString("arm64-macos")) && !gCSplitRelocatable;
        if (mod != (IRModule*)0 && d.keepAsm())
            d.setCompileOnly(true);
        else if (mod != (IRModule*)0 && platformLink)
            gLangLinker = lang.linker();
        // android: clang's object joins the image xcc writes. arm64 Linux
        // takes the general route below (xcc's half an object, the two
        // linked as objects are), where its unwind and exception tables are
        // written (ElfArm64.objectFromText) and gathered (ElfLinkArm64).
        else if (mod != (IRModule*)0 && cElfArm64 && !gCSplitRelocatable && isAndroid(d))
            d.linkInputs().add((Object*)cRestObject());
        else if (mod != (IRModule*)0)
            {
            gCSplitOut = d.fe().output() != (String*)0 ? d.fe().output() : String.withCString("a.out");
            if (gCSplitRelocatable && d.fe().output() == (String*)0)
                {
                // -c with no -o: prog.c gives prog.o, beside where it runs.
                gCSplitOut = stripExtension(cin.lastPathComponent());
                gCSplitOut.appendCString(".o");
                }
            String* xo = CPath.scratch();
            xo.appendCString(".x.o");
            d.fe().setOutput(xo);
            d.setCompileOnly(true);
            }
        if (mod == 0) { driverExit((i32)1); return; }
        if (!gCSplitRelocatable && !d.keepAsm() && gLangLinker == (String*)0)
            addLanguageLibs(d, lang);
        }
    else if (d.fe().input().hasSuffix(String.withCString(".ir")))
        {
        // IR text, as --emit-ir writes it: parsed, then optimised and compiled
        // like a module the front end made (the reference's xcc-cg-* tools,
        // which are not shipped, took this input).
        String* text = Files.readText(d.fe().input());
        if (text == (String*)0)
            {
            Stdio.printf("xcc: error: cannot read '%s'\n", d.fe().input().cString());
            driverExit((i32)1); return;
            }
        IrParser* ip = new IrParser();
        mod = ip.run(text);
        if (mod == 0 || ip.failed())
            {
            Stdio.printf("xcc: %s: not IR this xcc reads: %s\n", d.fe().input().cString(),
                         ip.why() == 0 ? "?" : ip.why().cString());
            driverExit((i32)1); return;
            }
        }
    else
        mod = Frontend.lower(d.fe());
    if (mod == 0) { driverExit((i32)3); return; }
    // --emit-ir: the module as lowering left it, before any optimisation.
    if (d.emitIR()) Stdio.error(mod.text());

    // --emit-iface stops HERE. Running the optimiser and a back end would be
    // pure latency for a caller that wanted the declarations.
    if (d.emitIfaceOnly()) {
        String* ij = d.fe().ifaceJson();
        if (ij == (String*)0 || ij.byteLength() == (u32)0) {
            Stdio.error(String.withCString(
                "xcc: --emit-iface: no public declarations to describe\n"));
            driverExit((i32)1); return;
        }
        String* out = d.fe().output();
        if (out != (String*)0 && !out.equals(String.withCString("-"))) {
            if (!Files.writeText(out, ij)) {
                Stdio.printf("xcc: error: cannot write '%s'\n", out.cString());
                driverExit((i32)1); return;
            }
        } else {
            Stdio.printf("%s", ij.cString());
            if (!ij.hasSuffix(String.withCString("\n"))) Stdio.printf("\n");
        }
        return;
    }

    // Round-trip the IR through its TEXT form before optimising.
    //
    // Not ceremony: the reference driver is two processes, so its IR always
    // makes this trip, and the parse is what fixes the ORDER the later stages
    // see. Skipping it produced structurally identical code with different
    // register assignments — same instruction count, x22 where the reference
    // used x23 — because the register allocator walked an in-memory module
    // whose order the text had never pinned down. Doing what the reference
    // does is also what keeps the round-trip on the tested path.
    String* irText = mod.text();
    IrParser* irrt = new IrParser();
    IRModule* parsed = irrt.run(irText);
    if (parsed == 0 || irrt.failed()) {
        Stdio.printf("xcc: internal: the IR did not round-trip: %s\n",
                     irrt.why() == 0 ? "?" : irrt.why().cString());
        driverExit((i32)3); return;
    }
    // What a C file's stub module brought (CPath) is not in the text.
    parsed.setBaseNames(mod.baseNames());
    mod = parsed;
    // Stashed for `-c`, which keeps the module's IR beside the object so a
    // later link can re-run the inliner across module boundaries — the thing
    // per-object compilation otherwise gives up. Nothing else reads it again,
    // so otherwise the text and the parser (which holds every line of it) are
    // let go before code generation, rather than living through it beside
    // the module they were parsed into.
    if (d.compileOnly())
        d.setIrText(irText);
    irText = (String*)0;
    irrt = (IrParser*)0;
    parsed = (IRModule*)0;
    emitModule(d, mod);
    if (d.bundleDir() != (String*)0)
        makeBundle(d);
    cPathCleanup();
}

// The bundle's platform directory for the target: <os>-<arch>.
String* bundlePlatform(DriverOptions* d)
{
    // The row's (the target table); an arch no row has keeps macOS's.
    if (d.targetRow() != (TargetRow*)0) return d.targetRow().bundlePlatform();
    return String.withCString("macos-arm64");
}

#ifndef XCC_VERSION
#define XCC_VERSION "unversioned"
#endif

// --bundle: the library just written goes into the signed bundle
// (BundleSign.xc), with what the protocols say it provides and requires.
void makeBundle(DriverOptions* d)
{
    String* out = d.fe().output();
    if (out == (String*)0) {
        Stdio.printf("xcc: error: --bundle needs -o <library>: the file that goes into the bundle\n");
        driverExit((i32)1); return;
    }
    String* name = d._bundleName;
    if (name == (String*)0) {
        String* src = d.fe().input();
        u32 s = src.byteLength();
        while (s > (u32)0 && src.byteAt(s - (u32)1) != (u8)'/') s = s - (u32)1;
        u32 e = src.byteLength();
        while (e > s && src.byteAt(e - (u32)1) != (u8)'.') e = e - (u32)1;
        name = src.substringBytes(s, (e > s + (u32)1 ? e - (u32)1 : src.byteLength()) - s);
    }
    String* keyWhere = (String*)0;
    bool made = false;
    Data* seed = (Data*)0;
    if (!d._noSign)
        seed = publisherSeed(d._bundleKey, true, &keyWhere, &made);
    Map* provides = new Map();
    Map* requires = new Map();
    Map* seen = Parser.protocolsSeen();
    if (seen != (Map*)0) {
        Array* ks = seen.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1) {
            String* k = (String*)ks.get(i);
            Array* v = (Array*)seen.get((Hashable*)k);
            if (((String*)v.get((u32)1)).equals(String.withCString("provides")))
                provides.set((Hashable*)k, v.get((u32)0));
            else
                requires.set((Hashable*)k, v.get((u32)0));
        }
    }
    // What the code loads must be the system's, or shipped in the bundle
    // (bundles-and-plugins.md, review 2): the OS would otherwise load an
    // unverified library from wherever it found one.
    Array* deps = Exports.needs(Files.readData(out));
    for (u32 k = (u32)0; deps != (Array*)0 && k < deps.count(); k = k + (u32)1) {
        String* dep = (String*)deps.get(k);
        if (Exports.isSystem(dep, bundlePlatform(d)))
            continue;
        u32 sl = dep.byteLength();
        while (sl > (u32)0 && dep.byteAt(sl - (u32)1) != (u8)'/' && dep.byteAt(sl - (u32)1) != (u8)92)
            sl = sl - (u32)1;
        String* base = dep.substringFromByte(sl);
        // libRuntime is the program's: loaded before any plugin, so the
        // plugin's need binds to that copy and no file is searched for. The
        // loader takes the plugin only into a program that shares the same
        // one (its ABI says "+rt"; Plugin._checkAbi).
        if ((base.hasPrefix(String.withCString("libRuntime.")) || base.hasPrefix(String.withCString("libRuntimeSupport.")))
            && d.fe().runtimeLibFile() != (String*)0)
            continue;
        bool shipped = false;
        for (u32 j = (u32)0; d._bundleLibs != (Array*)0 && j < d._bundleLibs.count(); j = j + (u32)1) {
            String* lib = (String*)d._bundleLibs.get(j);
            if (lib.hasSuffix(base) && (lib.byteLength() == base.byteLength()
                                        || lib.byteAt(lib.byteLength() - base.byteLength() - (u32)1) == (u8)'/'))
                shipped = true;
        }
        if (!shipped) {
            Stdio.printf("xcc: error: --bundle: %s needs %s, which is not a system library: ship it in the bundle "
                         "with --bundle-lib <file>, or build it into the plugin\n", out.cString(), dep.cString());
            driverExit((i32)1); return;
        }
    }
    Data* previous = (Data*)0;
    if (d._rotateFrom != (String*)0 && !d._noSign) {
        String* pw = (String*)0;
        bool pm = false;
        previous = publisherSeed(d._rotateFrom, false, &pw, &pm);
    }
    String* err = BundleSign.makeWith(d._bundleDir, name,
                                      d._bundleVersion,
                                      bundlePlatform(d), out, d._bundleResources, seed,
                                      d._publisher, d._publisherDomain, provides, requires,
                                      d._bundleReadonly, d._bundleWriteable, previous, d._bundleLibs,
                                      bundleAbiOf(d),
                                      String.withCString(XCC_VERSION));
    if (err != (String*)0) {
        Stdio.printf("xcc: error: --bundle: %s\n", err.cString());
        driverExit((i32)1); return;
    }
    if (d._noSign) {
        Stdio.printf("xcc: %s/ laid out UNSIGNED: nothing loads it until it is signed, with "
                     "xcc --sign-bundle %s on the machine that holds the publisher key\n",
                     d._bundleDir.cString(), d._bundleDir.cString());
        return;
    }
    signedLine(d._bundleDir, seed, keyWhere, made, d._bundleKey);
}

// The publisher's signing key. spec: 0 for the default, a private 0600 file
// ~/.xcc/bundle-key; a path for that file; `keychain` for the operating
// system's store (KeyStore.xc: the macOS login keychain, DPAPI, the Secret
// Service), an opt-in that never prompts. create: make one when there is
// none. Exits with the reason when it cannot.
Data* publisherSeed(String* spec, bool create, String** where, bool* made)
{
    *made = false;
    if (spec != (String*)0 && spec.equals(String.withCString("keychain"))) {
        String* w = KeyStore.where();
        *where = w;
        Data* k = KeyStore.load(String.withCString("bundle-key"));
        if (k != (Data*)0 && k.length() == (u32)32)
            return k;
        if (KeyStore.lastError() != (String*)0 || !create) {
            Stdio.printf("xcc: error: the publisher key in %s: %s; use a key file instead (--bundle-key <file>, "
                         "or the default ~/.xcc/bundle-key)\n", w.cString(),
                         KeyStore.lastError() != (String*)0 ? KeyStore.lastError().cString() : "there is none");
            driverExit((i32)1);
        }
        k = SecureRandom.bytes((u32)32);
        if (k == (Data*)0 || !KeyStore.save(String.withCString("bundle-key"), k)) {
            Stdio.printf("xcc: error: the publisher key could not be kept in %s: %s; use a key file instead\n",
                         w.cString(), KeyStore.lastError() != (String*)0 ? KeyStore.lastError().cString() : "no random source");
            driverExit((i32)1);
        }
        *made = true;
        return k;
    }
    String* path = spec;
    if (path == (String*)0) {
        String* dirp = Platform.home();
        dirp.appendCString("/.xcc");
        Files.createDirectory(dirp);
        path = String.withString(dirp);
        path.appendCString("/bundle-key");
    }
    *where = path;
    bool existed = Files.exists(path);
    if (!existed && !create) {
        Stdio.printf("xcc: error: no key at %s\n", path.cString());
        driverExit((i32)1);
    }
    Data* seed = BundleSign.publisherKey(path);
    if (seed == (Data*)0) {
        Stdio.printf("xcc: error: cannot read or make the publisher key at %s\n", path.cString());
        driverExit((i32)1);
    }
    *made = !existed;
    return seed;
}

// "signed by key …", and the public half beside the key (for a curated
// program's --trust): next to the key file, or ~/.xcc/bundle-keychain.pub.
void signedLine(String* dir, Data* seed, String* where, bool made, String* spec)
{
    Data* pub = Ed25519.publicKey(seed.bytes());
    String* pubPath = (String*)0;
    if (spec != (String*)0 && spec.equals(String.withCString("keychain"))) {
        pubPath = Platform.home();
        pubPath.appendCString("/.xcc/bundle-keychain.pub");
    } else {
        pubPath = String.withString(where);
        pubPath.appendCString(".pub");
    }
    if (!Files.exists(pubPath)) {
        String* ph = BundleSign._hex(pub.bytes(), (u32)32);
        ph.appendByte((u8)10);
        if (!Files.writeText(pubPath, ph)) {
            Stdio.printf("xcc: error: cannot write the public key '%s'\n", pubPath.cString());
            driverExit((i32)1); return;
        }
    }
    Stdio.printf("xcc: %s/ signed by key %s (%s%s); keep it: losing it means an update needs a key rotation\n",
                 dir.cString(), Sha256.hex(pub.bytes(), (u32)32).substringBytes((u32)0, (u32)16).cString(),
                 where.cString(), made ? ", made now" : "");
}

// --sign-bundle <dir>: a bundle laid out elsewhere (--bundle --no-sign) is
// checked against its manifest and signed here; --publisher,
// --publisher-domain and --rotate-from apply as they do to --bundle.
void signBundle(DriverOptions* d)
{
    String* where = (String*)0;
    bool made = false;
    Data* seed = publisherSeed(d._bundleKey, true, &where, &made);
    Data* previous = (Data*)0;
    if (d._rotateFrom != (String*)0) {
        String* pw = (String*)0;
        bool pm = false;
        previous = publisherSeed(d._rotateFrom, false, &pw, &pm);
    }
    String* err = BundleSign.sign(d._signBundle, seed, d._publisher, d._publisherDomain, previous);
    if (err != (String*)0) {
        Stdio.printf("xcc: error: --sign-bundle %s: %s\n", d._signBundle.cString(), err.cString());
        driverExit((i32)1); return;
    }
    signedLine(d._signBundle, seed, where, made, d._bundleKey);
}

// From a (round-tripped) IR module to the output file, per target. Split out
// of main so a link-time recompile (`-flto`, bug 139) can enter with the
// objects' MERGED module where a normal build enters with the front end's.
void emitModule(DriverOptions* d, IRModule* mod)
{
    if (!d.keepAsm() && !d.compileOnly() && !linksExternally(d)) noteLinkFlags(d);

    // A link input this target's path does not consume must not be dropped.
    // arm64 and x86_64 honour them below, and win64 takes objects and archives
    // (linkWin64, which refuses anything else by name); anything else says so,
    // because a library silently missing from a link is a symbol that resolves
    // nowhere and a failure with no message at run time.
    bool win64 = isWin64(d);
    if ((d.linkInputs().count() > (u32)0 || d.frameworks().count() > (u32)0)
        && !isX86_64(d) && !isMacArm64(d)
        && !isIos(d)
        && !(d.targetRow() != (TargetRow*)0 && d.targetRow().exeFormat().equals(String.withCString("elf-pie")))
        && !(win64 && d.frameworks().count() == (u32)0)) {
        Stdio.printf("xcc: error: -Xlinker/-l/-framework is not wired for '%s' in "
                     "this driver — the link would silently omit it.\n",
                     d.arch().cString());
        driverExit((i32)1); return;
    }
    if (isXt6502(d)) { emitXt6502(d, mod); return; }
    if (isX86_64(d)) { emitX86_64(d, mod); return; }
    if (isWin64(d)) { emitWin64(d, mod); return; }
    if (isArm9(d))   { emitArm9(d, mod);   return; }
    if (isM68k(d))   { emitM68k(d, mod);   return; }
    if (isWasm(d))   { emitWasm(d, mod);   return; }

    OptProfile* prof = OptProfile.forTarget(backendTargetOf(d));
    if (d.targetRow().rotateChain()) prof.setLoopRotateChain(true);
    Opt.setUnrollOverride(prof, d.unroll());
    applyOptFlags(d, prof);
    Opt* opt = Opt.atLevel(d.opt(), prof);
    // A LIBRARY's public surface is every function it defines: nothing in the
    // module calls them, the CLIENT does, and dead-function elimination cannot
    // see the client. Wired into the wasm path first and missing here, which
    // cost a library its `Adder$init` — a constructor no internal code calls —
    // and the app that called it died at LOAD naming libSystem.
    // An OBJECT's functions are all potentially called from ANOTHER object,
    // for the same reason.
    if (d.emitLib() || (d.compileOnly() && gCSplitOut == (String*)0)) opt.setKeepAllFunctions(true);
    else if (linkJoinsObjects(d)) opt.setKeepClassRoot(true);
    opt.run(mod);
    dumpOptIR(d, mod);

    Arm64* be = new Arm64();
    // The row's calling convention and atomics (the reference says why).
    be.setAapcs64Abi(d.targetRow().abi().equals(String.withCString("aapcs64")));
    be.setLseAtomics(d.targetRow().lseAtomics());
    be.setLoopAlign(d.targetRow().loopAlign());
    be.setThreadSafeArcOverride(d.fe().threadSafeArc());
    String* prog = be.assembly(mod);
    if (be.failed()) {
        Stdio.printf("xcc: %s: unsupported: %s\n", d.fe().input().cString(),
                     be.why() == 0 ? "?" : be.why().cString());
        driverExit((i32)3); return;
    }

    if (d.keepAsm()) {
        if (!writeAsmOut(d, prog)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            driverExit((i32)1); return;
        }
        return;
    }

    // ── -c: an object, not an image ──────────────────────────────────────
    //
    // The object carries the MODULE and nothing else: its own code plus its
    // per-class allocators, deliberately NOT the crt or the runtime. Those
    // belong to the final link and baking them into every object would collide
    // the moment two of them met.
    if (d.compileOnly() && d.targetRow() != (TargetRow*)0
        && d.targetRow().exeFormat().equals(String.withCString("elf-pie"))) {
        // The aarch64 ELF rows (arm64 Linux, android): an ET_REL object, with
        // the ELF spelling of the names (no leading underscore), as the image
        // path assembles them; ElfLinkArm64 reads it back at the link.
        // A C/C++ file's xcc half links libRuntime: the guard through the GOT.
        if (gCSplitOut != (String*)0 && d.fe().runtimeLibFile() != (String*)0 && !isAndroid(d))
            prog = guardThroughGot(prog);
        String* one0 = new String();
        one0.append(classAllocStubs(prog));
        one0.appendByte((u8)'\n');
        one0.append(prog);
        String* one = stripLeadingUnderscore(one0);
        Arm64Asm* oas = new Arm64Asm();
        Arm64Asm.setLsdaElf(true);
        oas.assemble(Arm64Asm.machoDialectFromElf(one));
        Arm64Asm.setLsdaElf(false);
        if (oas.failed()) {
            Stdio.printf("xcc: assembly failed: %s\n", oas.why().cString());
            driverExit((i32)1); return;
        }
        ElfArm64* eo = new ElfArm64();
        eo.setDepLibs(objectDepLibs(d));
        if (gCSplitOut != (String*)0) eo.setEhFunctions(machoFunctionNames(one0));
        Data* od = eo.objectFromText(oas.textBytes(), oas.dataBytes(), oas.symbols(), oas.dataSyms(),
                                     oas.fixups(), oas.globals(), oas.commonSyms(),
                                     oas.modInitBytes(), oas.modInitFixups());
        if (od == (Data*)0 || eo.failed()) {
            Stdio.printf("xcc: error: %s object write failed: %s\n", d.targetRow().name().cString(),
                         eo.why() == (String*)0 ? "?" : eo.why().cString());
            driverExit((i32)1); return;
        }
        if (!Files.writeData(d.fe().output(), od)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            driverExit((i32)1); return;
        }
        writeObjectSidecars(d);
        if (gCSplitOut != (String*)0) {
            gHalfXcArgs = xcArgsWanted(d, prog);
            cSplitLink(d);
        }
        return;
    }
    if (d.compileOnly()) {
        // A C/C++ file's xcc half that links libRuntime reads the guard
        // through the GOT, as on the ELF rows: the image does not define it,
        // and an @PAGE reference to an import is not patched.
        if (gCSplitOut != (String*)0 && d.fe().runtimeLibFile() != (String*)0 && !isIos(d))
            prog = guardThroughGot(prog);
        String* one = new String();
        one.append(classAllocStubs(prog));
        one.appendByte((u8)'\n');
        one.append(prog);
        Arm64Asm* oas = new Arm64Asm();
        oas.assemble(Arm64Asm.machoDialectFromElf(one));
        if (oas.failed()) {
            Stdio.printf("xcc: assembly failed: %s\n", oas.why().cString());
            driverExit((i32)1); return;
        }
        MachO* mo = new MachO();
        // The platform stamp — the reference passes `-platform` to its object
        // writer for -A ios/ios-sim (bug 137: the port wrote PLATFORM_MACOS).
        if (isIos(d)) mo.setApplePlatform(d.arch());
        // The module's load-time constructors (XG-NIB registration) travel in
        // the object as its __mod_init_func, for the link to run.
        mo.setModInit(oas.modInitBytes(), oas.modInitFixups());
        // What a link of the object alone needs: the frameworks the module
        // imports, and on the C path its language's libraries.
        mo.setLinkerOptions(objectLinkerOptions(d));
        Data* od = mo.objectFromText(oas.textBytes(), oas.dataBytes(), oas.symbols(),
                                     oas.dataSyms(), oas.fixups(), oas.globals(), oas.commonSyms());
        if (od == (Data*)0) {
            Stdio.printf("xcc: error: arm64 object write failed\n");
            driverExit((i32)1); return;
        }
        if (!Files.writeData(d.fe().output(), od)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            driverExit((i32)1); return;
        }
        writeObjectSidecars(d);
        if (gCSplitOut != (String*)0) {
            gHalfXcArgs = xcArgsWanted(d, prog);
            cSplitLink(d);
        }
        return;
    }

    if ((d.caps().noSelfHost() || gLangLinker != (String*)0) && externalArm64(d, prog)) return;

    // The whole image is ONE assembly unit: crt, runtime, per-class allocators,
    // then the program. That is what lets the linker resolve everything at link
    // time and leave only the imports dynamic.
    // The row's format and runtime (the target table): an ELF image for
    // android and arm64 Linux, a Mach-O one for macOS and iOS.
    TargetRow* lrow = d.targetRow();
    bool android = lrow.exeFormat().equals(String.withCString("elf-pie"));
    String* crt = readRuntime(d.fe(), lrow.crt());
    String* rt  = readRuntime(d.fe(), lrow.runtime());
    if (crt == 0 || rt == 0) {
        Stdio.printf("xcc: error: cannot read the arm64 runtime from the support tree\n");
        driverExit((i32)1); return;
    }
    // The checked runtime is a SEPARATE translation unit — it walks from its
    // own frame and is built with different flags — so it is concatenated only
    // when asked for. An ordinary build links none of it.
    String* checked = (String*)0;
    // A row with no checked runtime (arm64 Linux, Android) takes its checks
    // from Checked.xc instead, as the reference does: nothing to link (#475).
    if (d.fe().boundsReport() && d.targetRow().checkedRuntime().byteLength() > (u32)0) {
        checked = readRuntime(d.fe(), d.targetRow().checkedRuntime());
        if (checked == 0) {
            Stdio.printf("xcc: error: -fbounds-check needs %s in the support tree\n", d.targetRow().checkedRuntime().cString());
            driverExit((i32)1); return;
        }
    }
    String* stubs = classAllocStubs(prog);
    String* combined = new String();
    // libRuntime (owner, 2026-11-03): a program that took it links the crt and
    // not the runtime, which the library carries and exports.
    // Not Android yet (no device to prove it on); arm64 Linux, macOS and iOS.
    bool rtFromLib = !isAndroid(d) && runtimeTaken(d);
    if (rtFromLib) prog = guardThroughGot(prog);
    if (d.emitRuntime()) rt = runtimeForLibRuntime(rt);
    // A LIBRARY gets the runtime but NOT the crt. The crt is the program
    // entry — it calls `_main` — so bundling it into a library leaves the
    // library importing a symbol only a PROGRAM defines, and the load fails
    // with `symbol not found in flat namespace '_main'` naming neither the
    // library nor the crt. Mirrors the reference, which concatenates
    // rt + stubs + program for a dylib and crt + rt + … for an executable.
    if (!d.emitLib()) {
        // The --xc-* options (#148): the filter rides after the crt that calls it.
        if (xcArgsFor(d, prog)) crt = crtArm64WithXcArgs(d, crt, lrow.crt());
        combined.append(crt); combined.appendByte((u8)'\n');
    }
    if (!rtFromLib) { combined.append(rt); combined.appendByte((u8)'\n'); }
    // The iOS shim rides after the runtime in a LIBRARY too: its code calls
    // `_xt_ios_log` and the fetch functions through Platform.xc, and the app
    // that loads it does not export its own copy, so a dylib without the shim
    // failed at load, "symbol not found in flat namespace '__xt_ios_log'" (bug
    // 634). The shim keeps no state; each image carries its own, as it does
    // the runtime.
    if (isIos(d)) { combined.append(iosRuntimeSource(d)); combined.appendByte((u8)'\n'); }   // stage 4 shim
    if (checked != 0) { combined.append(checked); combined.appendByte((u8)'\n'); }
    combined.append(android ? stripLeadingUnderscore(stubs) : stubs);
    combined.appendByte((u8)'\n');
    combined.append(android ? stripLeadingUnderscore(prog) : prog);

    Arm64Asm* as = new Arm64Asm();
    as.assemble(Arm64Asm.machoDialectFromElf(combined));
    // Bug 642: a Mach-O image keeps its commons for __bss (storage after the
    // mod-init tail); an Android image gives them data bytes as before.
    Array* bssCommons = android ? (Array*)0 : as.takeCommons();
    if (android) as.demoteCommonsToLocalData();
    if (as.failed()) {
        Stdio.printf("xcc: assembly failed: %s\n", as.why().cString());
        driverExit((i32)1); return;
    }

    // --emit-apk: the program is packaged as a NativeActivity payload, which is
    // a SHARED OBJECT and not an executable — Android dlopen()s it and calls
    // ANativeActivity_onCreate. So the crt goes away, the glue comes in, and the
    // user's `main` is renamed to the `xt_main` the glue calls.
    if (isAndroid(d) && d.emitApk()) {
        emitApkPackage(d, prog);
        return;
    }
    // --no-self-host: the same unit, linked by the NDK's clang (#31).
    if (isAndroid(d) && d.caps().noSelfHost() && !d.emitLib()) {
        ndkLink(d, as, d.fe().output(), (String*)0);
        if (!d.fe().verbose()) External.cleanup();
        if (!d.quiet())
            Stdio.printf("xcc: android executable -> '%s'\n", d.fe().output().cString());
        return;
    }

    Data* image = (Data*)0;
    if (android) {
        // A shared library on the link line (-l<name>, -Wl,x.so) is needed as
        // an #import <X> is: named by its soname and, on Linux, found through
        // the runpath. The object merge below takes only objects and archives,
        // and a .so given here used to be left out without a word.
        // A -l found nowhere is an error, except the C library's own names,
        // which the row's DT_NEEDED already covers (glibc's libpthread, libdl
        // and librt are libc.so.6 since 2.34; bionic's are libc.so).
        Array* li = d.linkInputs();
        for (u32 i = (u32)0; li != (Array*)0 && i < li.count(); i = i + (u32)1) {
            String* arg = (String*)li.get(i);
            String* lp = resolveLinkInput(d, arg);
            if (lp == (String*)0) {
                String* stem = arg.substringFromByte((u32)2);
                if (!stem.equals(String.withCString("c")) && !stem.equals(String.withCString("m"))
                    && !stem.equals(String.withCString("dl")) && !stem.equals(String.withCString("pthread"))
                    && !stem.equals(String.withCString("rt"))) {
                    Stdio.printf("xcc: error: %s: no lib%s.so on the -L path\n", arg.cString(), stem.cString());
                    driverExit((i32)1); return;
                }
                continue;
            }
            if (!isSharedLib(lp)) continue;
            bool have = false;
            for (u32 k = (u32)0; k < d.fe().neededLibs().count(); k = k + (u32)1)
                if (((String*)d.fe().neededLibs().get(k)).equals(lp)) have = true;
            if (!have) d.fe().neededLibs().add((Object*)lp);
        }
        String* baseNeeded = new String();
        for (u32 ni = (u32)0; ni < lrow.needed().count(); ni = ni + (u32)1) {
            if (ni > (u32)0) baseNeeded.appendCString(",");
            baseNeeded.append((String*)lrow.needed().get(ni));
        }
        Array* needed = androidNeededWithImports(d, baseNeeded.cString());
        // Bug 124: as above — append the constructor array before linking,
        // and the C objects and archives of the command line before that.
        SectionBytes* aData = as.dataBytes();
        Array* aFix  = as.fixups();
        mergeElfLinkObjects(d, as.textBytes(), aData, as.symbols(), as.dataSyms(), aFix, new Array(), as);
        u32 aMi = Arm64Asm.appendModInit(as, aData, aFix);
        ElfArm64* w = new ElfArm64();
        w.setInterp(lrow.interp());
        w.setRunpath(arm64ElfRunpath(d, lrow));
        if (!d.emitLib() && lrow.os().equals(String.withCString("linux")))
            w.setKnownImports(arm64KnownImports(d));
        if (d.emitLib()) {
            // A real Android shared library: no crt and no glue (that is the
            // APK payload's shape), its own public API exported — the
            // module's `.globl`s, read before the runtime was prepended so the
            // runtime's globals stay private — and a soname naming the file.
            Array* exports = globlNames(stripLeadingUnderscore(prog), as.symbols());
            // …and libRuntime the runtime's: it is the one copy.
            if (d.emitRuntime()) {
                // The runtime is ELF-flavoured already: its names as they are.
                Array* rx = globlNames(rt, as.symbols());
                addMissing(exports, rx);
                Elf64.sortStrings(exports);
            }
            // The interface rides in a `.xtc.iface` section, as on the other
            // ELF targets, so a client's `#import <Lib>` reads it (bug 460).
            Array* iface = new Array();
            String* ij = d.fe().ifaceJson();
            if (ij != (String*)0)
                for (u32 i = (u32)0; i < ij.byteLength(); i = i + (u32)1)
                    iface.add((Object*)Number.withU32((u32)ij.byteAt(i)));
            w.image(as.textBytes(), aData, as.symbols(), as.dataSyms(),
                    exports, aFix, baseNameOf(d.fe().output()), needed,
                    (String*)0, aMi, iface);
        } else {
            w.image(as.textBytes(), aData, as.symbols(), as.dataSyms(),
                    gArm64CExports != (Array*)0 ? gArm64CExports : new Array(), aFix, (String*)0, needed,
                    String.withCString("_start"), aMi);
        }
        if (w.failed()) {
            Stdio.printf("xcc: %s link failed: %s\n", lrow.name().cString(), w.why().cString());
            driverExit((i32)1); return;
        }
        image = w.bytes();
    } else {
        Object* entry = as.symbols().get((Hashable*)String.withCString("_xtc_start"));
        if (entry == (Object*)0)
            entry = as.symbols().get((Hashable*)String.withCString("_main"));
        // A LIBRARY has no entry point — that is what makes it a library. The
        // check belongs to the executable path alone.
        if (entry == (Object*)0 && !d.emitLib()) {
            Stdio.printf("xcc: no entry symbol (_xtc_start / _main)\n");
            driverExit((i32)1); return;
        }
        // Bug 138: `-Xlinker x.o` / `-Xlinker lib.a` are OBJECTS to merge (a
        // platform shell compiled by clang, a static archive), not libraries
        // to load — they used to become an LC_LOAD_DYLIB naming a .o, which
        // dyld refused at launch. Merged into the assembler's own model,
        // exactly as xcc-ln-arm64 does, BEFORE the mod-init tail is appended.
        SectionBytes* dataBytes = as.dataBytes();
        Array* fixups    = as.fixups();
        Array* objcSects = mergeLinkObjects(d, as.textBytes(), dataBytes, as.symbols(),
                                            as.dataSyms(), fixups, new Array(), as);
        // Bug 066: the __mod_init_func pointer array goes at the END of __data,
        // with its fixups shifted to match, so the writer can give that tail an
        // S_MOD_INIT_FUNC_POINTERS section. Without it dyld sees inert data and
        // no load-time constructor runs. Same placement as xtld64, because the
        // two must produce the same bytes.
        u32 miLen = as.modInitBytes().length();
        if (miLen > (u32)0) {
            dataBytes.padTo((u32)8);
            u32 base = dataBytes.length();
            dataBytes.append(as.modInitBytes());
            for (u32 i = (u32)0; i < as.modInitFixups().count(); i = i + (u32)1) {
                Arm64Fixup* f = (Arm64Fixup*)as.modInitFixups().get(i);
                fixups.add((Object*)Arm64Fixup.make(base + f.offset(), f.kind(),
                                                    f.symbol(), f.scale()));
            }
        }
        // After the mod-init tail, so the __bss symbols sit past the data (642).
        u32 bssLen = Arm64Asm.allocateBss(bssCommons, dataBytes, as.symbols(), as.dataSyms());
        MachO* m = new MachO();
        // Every image for -A ios/ios-sim carries the iOS LC_BUILD_VERSION
        // (PLATFORM_IOS 2 / IOSSIMULATOR 7, minos 15.0), as the reference's
        // xcc-ln-arm64 is told with `-platform`. The library was left with the
        // macOS stamp (bug 137 did only the executable), and dyld refused it:
        // "incompatible platform (have 'macOS', need 'iOS-sim')" (bug 633).
        if (isIos(d)) m.setApplePlatform(d.arch());
        if (d.emitLib()) {
            // A LIBRARY, not a program: MH_DYLIB, based at 0, with its
            // interface in an `__XTC,__iface` section so `#import <X>` reads
            // the types out of the binary rather than a side file that can go
            // missing — and an export trie, which is the only thing dyld
            // consults when a client asks for a symbol.
            //
            // Every DEFINED symbol is exported. A library's surface is what it
            // defines: narrowing it here would need a rule the language does
            // not have (there is no `private` on a free function), and a name
            // wrongly withheld fails in the CLIENT, at load, naming the
            // library rather than this decision.
            // The library's PUBLIC API is its own `.globl` names, read off the
            // program asm BEFORE the runtime was prepended: the runtime's
            // globals belong to whoever links it, and re-exporting them from
            // every library would have two definitions of `_xtc_alloc` racing
            // for a client's binds. Mirrors the reference's rule exactly.
            Array* exports = globlNames(prog, as.symbols());
            // …and libRuntime the runtime's as well: it is the one copy.
            if (d.emitRuntime()) {
                Array* rx = globlNames(rt, as.symbols());
                addMissing(exports, rx);
                Elf64.sortStrings(exports);
            }
            Array* iface = new Array();
            String* ij = d.fe().ifaceJson();
            if (ij != (String*)0)
                for (u32 i = (u32)0; i < ij.byteLength(); i = i + (u32)1)
                    iface.add((Object*)Number.withU32((u32)ij.byteAt(i)));
            // The install name is `@rpath/<file>`, as the reference writes it:
            // a program records it as the load path and finds the library
            // beside itself through its LC_RPATH of @loader_path. A bare file
            // name would be looked up relative to the working directory.
            String* instName = String.withCString("@rpath/");
            instName.append(baseNameOf(d.fe().output()));
            // The libraries this one `#import`s (bug 440): each an
            // LC_LOAD_DYLIB, so a client that imports only this library still
            // loads them, and the imports each exports bind to it. Then the
            // libraries and frameworks on the line and the frameworks the
            // source imports (bug 591), and on iOS Foundation and libobjc,
            // which the shim the library now carries calls into (bug 634) —
            // the same list, in the same order, as an executable's.
            m.setDeps(arm64LinkDeps(d, d.fe().neededLibs(), new Array()));
            m.dylib(as.textBytes(), instName, exports, iface,
                    as.symbols(), dataBytes, as.dataSyms(), fixups, miLen, objcSects, bssLen);
            checkPageImports(m);
        } else {
            // The dylibs this program `#import <X>`ed. Each becomes an
            // LC_LOAD_DYLIB and claims the imports it exports, so dyld looks
            // for `_Adder$vtbl` in libAdder rather than in libSystem — which
            // is where an unclaimed import goes, and where it is not.
            // Bug 138: one rule for the dependency list — `#import`ed dylibs,
            // then -Xlinker/-l libraries (SDK `.tbd` stubs read for their
            // exports), then frameworks, then libobjc if an object needs it.
            Array* deps = arm64LinkDeps(d, d.fe().neededLibs(), new Array());
            m.setDeps(deps);
            m.setRpaths(arm64Rpaths(d, d.fe().neededLibs()));
            m.executable(as.textBytes(), ((Number*)entry).asU32(), as.symbols(),
                         dataBytes, as.dataSyms(), fixups, miLen, objcSects, bssLen);
            checkSystemImports(d, m);
        }
        image = m.bytes();
    }

    if (!Files.writeData(d.fe().output(), image)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        driverExit((i32)1); return;
    }
    Files.setExecutable(d.fe().output());
    if (!d.emitLib()) signIfRequested(d, d.fe().output());   // --sign (144): the Mach-O executable
}

// ── --no-self-host: the vendor toolchains ─────────────────────────────────
//
// The in-house path is the default and needs nothing installed. This is the
// opt-in the other way: the same compiler output handed to the platform's own
// tools, for comparing a program's behaviour against them. On arm64 macOS clang
// links it against the generated runtime the in-house link uses; on arm9 the
// program's `main` becomes `xt_main` and a generated C stub owns the real
// `main` and the program-specific ARC/heap helpers.

String* supportFile(DriverOptions* d, string rel)
{
    String* root = supportRoot(d.fe());
    if (root == (String*)0) return (String*)0;
    String* p = String.withString(root);
    p.appendByte((u8)'/');
    p.appendCString(rel);
    return p;
}

void writeTempOrDie(String* path, String* text)
{
    if (!Files.writeText(path, text)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", path.cString());
        driverExit((i32)1);
    }
}

// Whether an earlier argument of a vendor link is this string.
bool argsHave(Array* a, String* s)
{
    for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
        if (((String*)a.get(i)).equals(s)) return true;
    return false;
}

// Whether a vendor link already records the run-path dir (as the pair
// `-Wl,-rpath -Wl,<dir>`).
bool argsHaveRpath(Array* a, String* dir)
{
    String* w = String.withCString("-Wl,");
    w.append(dir);
    for (u32 i = (u32)0; i + (u32)1 < a.count(); i = i + (u32)1)
        if (((String*)a.get(i)).equals(String.withCString("-Wl,-rpath"))
            && ((String*)a.get(i + (u32)1)).equals(w)) return true;
    return false;
}

// The link arguments of the command line and $XTC_LDFLAGS, in the form clang
// takes them: -L dirs, -l names and files as given, -framework pairs, run
// paths, then the other linker flags. $XTC_LDFLAGS is already merged into
// these lists (addLdFlagsFromEnvironment), so it is not read again here.
void addLinkerFlags(DriverOptions* d, Array* a)
{
    Array* dirs = new Array();
    Array* ls = d.fe().libs();
    for (u32 i = (u32)0; ls != (Array*)0 && i < ls.count(); i = i + (u32)1) dirs.add(ls.get(i));
    for (u32 i = (u32)0; i < d.ldDirs().count(); i = i + (u32)1) dirs.add(d.ldDirs().get(i));
    for (u32 i = (u32)0; i < dirs.count(); i = i + (u32)1) {
        String* f = String.withCString("-L");
        f.append((String*)dirs.get(i));
        if (!argsHave(a, f)) a.add((Object*)f);
    }
    for (u32 i = (u32)0; i < d.linkInputs().count(); i = i + (u32)1)
        a.add(d.linkInputs().get(i));
    for (u32 i = (u32)0; i < d.frameworks().count(); i = i + (u32)1) {
        a.add((Object*)String.withCString("-framework"));
        a.add(d.frameworks().get(i));
    }
    for (u32 i = (u32)0; i < d.rpaths().count(); i = i + (u32)1) {
        String* dir = (String*)d.rpaths().get(i);
        if (argsHaveRpath(a, dir)) continue;
        a.add((Object*)String.withCString("-Wl,-rpath"));
        String* r = String.withCString("-Wl,");
        r.append(dir);
        a.add((Object*)r);
    }
    for (u32 i = (u32)0; i < d.rawLinkFlags().count(); i = i + (u32)1) {
        String* f = String.withCString("-Wl,");
        f.append((String*)d.rawLinkFlags().get(i));
        a.add((Object*)f);
    }
}

// Whether this build's link goes to a vendor driver (clang on arm64 macOS,
// the NDK's clang for android), which takes the linker flags itself
// (addLinkerFlags), so none of them is reported as ignored.
bool linksExternally(DriverOptions* d)
{
    if (isAndroid(d)) return d.caps().noSelfHost() && (d.emitApk() || !d.emitLib());
    if (!isMacArm64(d) || d.emitLib()) return false;
    return d.caps().noSelfHost() || gLangLinker != (String*)0;
}

// Run a vendor tool, and stop the build with its status if it failed.
void runOrDie(Array* argv, bool keep)
{
    // -V shows the command, as it shows every other resolved path.
    if (keep) {
        String* line = String.withCString("xcc: running:");
        for (u32 i = (u32)0; i < argv.count(); i = i + (u32)1) {
            line.appendByte((u8)' ');
            line.append(External.quote((String*)argv.get(i)));
        }
        Stdio.printf("%s\n", line.cString());
    }
    i32 rc = External.run(argv);
    if (rc != (i32)0) {
        if (rc < (i32)0)
            Stdio.printf("xcc: error: cannot run '%s'\n", ((String*)argv.get((u32)0)).cString());
        if (!keep) External.cleanup();
        driverExit(rc < (i32)0 ? (i32)1 : rc);
    }
}

// A support-tree file, sub/name, by path (for a vendor tool's command line).
String* supportPath(DriverOptions* d, string sub, String* name)
{
    String* root = supportRoot(d.fe());
    if (root == (String*)0) return (String*)0;
    String* p = String.withString(root);
    p.appendByte((u8)'/');
    p.appendCString(sub);
    p.appendByte((u8)'/');
    p.append(name);
    return p;
}

// The NDK's clang (#31): under $ANDROID_NDK_HOME, or in the newest NDK in
// $ANDROID_HOME, $ANDROID_SDK_ROOT or the SDK's default place on a Mac; 0 when
// there is none.
String* ndkClang(void)
{
    String* t = External.captureAll(String.withCString(
        "for n in \"$ANDROID_NDK_HOME\" $(ls -d \"$ANDROID_HOME\"/ndk/* \"$ANDROID_SDK_ROOT\"/ndk/* "
        "\"$HOME\"/Library/Android/sdk/ndk/* 2>/dev/null | sort -rV); do "
        "for c in \"$n\"/toolchains/llvm/prebuilt/*/bin/clang; do "
        "[ -x \"$c\" ] && { echo \"$c\"; exit 0; }; done; done")).trimmed();
    return t.byteLength() == (u32)0 ? (String*)0 : t;
}

// An android image through the NDK's clang (--no-self-host, #31). The unit is
// the one the in-house link assembles (the crt or the APK's glue, the runtime,
// the allocators, the program), written as one ET_REL object, which clang
// links against bionic. clang's own start files stay out: crt-android.s's
// _start is the entry, as in the in-house image. A NativeActivity payload is a
// shared object, linked -Bsymbolic: the code reaches its own symbols
// pc-relative, which lld refuses against a symbol a .so leaves preemptible.
void ndkLink(DriverOptions* d, Arm64Asm* as, String* out, String* soname)
{
    String* cc = ndkClang();
    if (cc == (String*)0) {
        Stdio.printf("xcc: error: --no-self-host -A android needs the NDK: set $ANDROID_NDK_HOME, "
                     "or $ANDROID_HOME to an SDK with one\n");
        driverExit((i32)1); return;
    }
    ElfArm64* eo = new ElfArm64();
    Data* od = eo.objectFromText(as.textBytes(), as.dataBytes(), as.symbols(), as.dataSyms(),
                                 as.fixups(), as.globals(), as.commonSyms(),
                                 as.modInitBytes(), as.modInitFixups());
    if (od == (Data*)0 || eo.failed()) {
        Stdio.printf("xcc: error: android object write failed: %s\n",
                     eo.why() == (String*)0 ? "?" : eo.why().cString());
        driverExit((i32)1); return;
    }
    String* obj = External.tempPath("xtc-android.o");
    if (!Files.writeData(obj, od)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", obj.cString());
        driverExit((i32)1); return;
    }
    bool keep = d.fe().verbose();
    Array* a = new Array();
    a.add((Object*)cc);
    a.add((Object*)String.withCString("--target=aarch64-linux-android24"));
    a.add((Object*)String.withCString("-nostartfiles"));
    if (soname != (String*)0) {
        a.add((Object*)String.withCString("-shared"));
        a.add((Object*)String.withCString("-Wl,-Bsymbolic"));
        a.add((Object*)String.withCString("-Wl,-soname,").appending(soname));
    } else {
        a.add((Object*)String.withCString("-Wl,-e,_start"));
    }
    a.add((Object*)obj);
    addLinkerFlags(d, a);
    // The libraries the program imports, by path (lld records their sonames),
    // then the system ones the in-house image names.
    Array* nl = d.fe().neededLibs();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1)
        if (((String*)nl.get(i)).hasSuffix(String.withCString(".so"))) a.add(nl.get(i));
    a.add((Object*)String.withCString("-lm"));
    a.add((Object*)String.withCString("-ldl"));
    if (soname != (String*)0) {
        a.add((Object*)String.withCString("-llog"));
        a.add((Object*)String.withCString("-landroid"));
    }
    Array* sys = d.caps().needed();
    for (u32 i = (u32)0; i < sys.count(); i = i + (u32)1) {
        String* n = (String*)sys.get(i);
        if (n.hasPrefix(String.withCString("lib")) && n.hasSuffix(String.withCString(".so")))
            a.add((Object*)String.withCString("-l").appending(n.substringBytes((u32)3, n.byteLength() - (u32)6)));
    }
    a.add((Object*)String.withCString("-o")); a.add((Object*)out);
    runOrDie(a, keep);
}

// The assembly without its debug directives, for an assembler of the
// platform's: xcc's own (.xc_frame, .xc_var, .xc_param), which only xcc's
// assembler reads, and the line table (.file, .loc), whose file numbers xcc
// reuses for another file where clang's assembler refuses that. A C or C++
// program always has them: clang's IR carries line tables.
String* withoutXcDirectives(String* prog)
{
    if (!prog.contains(String.withCString("\n    .xc_")) && !prog.contains(String.withCString("\n    .loc "))
        && !prog.contains(String.withCString("\n    .file "))) return prog;
    Array* lines = prog.splitOnByte((u8)10);
    String* out = new String();
    for (u32 i = 0; i < lines.count(); i = i + 1) {
        String* l = (String*)lines.get(i);
        if (l.hasPrefix(String.withCString("    .xc_")) || l.hasPrefix(String.withCString("    .loc "))
            || l.hasPrefix(String.withCString("    .file "))) continue;
        out.append(l);
        if (i + 1 < lines.count()) out.appendCString("\n");
    }
    return out;
}

// arm64 macOS through the vendor clang. False when this shape has no external
// path and the in-house link should run instead: a library, which links
// in-house either way, and android, which goes to the NDK's clang once its
// unit is assembled (ndkLink).
bool externalArm64(DriverOptions* d, String* prog)
{
    if (d.emitLib() || isAndroid(d)) return false;
    String* out = d.fe().output();
    bool keep = d.fe().verbose();
    // clang links the program against the same runtime as the in-house link,
    // entered at crt-macos.s's _xtc_start (which calls the program's _main).
    // Each piece is its own file: rt-macos.s marks .subsections_via_symbols,
    // and the program's branches to its own local labels must not fall under
    // it. One runtime for both links, so this path cannot drift from the
    // object layout (it had: the C stub it used to generate still wrote the
    // header from before the 32-bit refcount).
    TargetRow* row = d.targetRow();
    Array* files = new Array();
    files.add((Object*)supportPath(d, "arm64/runtime", row.crt()));
    files.add((Object*)supportPath(d, "arm64/runtime", row.runtime()));
    if (d.fe().boundsReport() && row.checkedRuntime().byteLength() > (u32)0)
        files.add((Object*)supportPath(d, "arm64/runtime", row.checkedRuntime()));
    if (isIos(d))
        files.add((Object*)supportPath(d, "ios/runtime",
            String.withCString(isIosSim(d) ? "xtios-sim.s" : "xtios.s")));
    for (u32 i = (u32)0; i < files.count(); i = i + (u32)1) {
        String* f = (String*)files.get(i);
        if (f == (String*)0 || !Files.exists(f)) {
            Stdio.printf("xcc: error: the arm64 runtime piece %s is missing\n",
                         f == (String*)0 ? "(no support tree)" : f.cString());
            driverExit((i32)1); return true;
        }
    }
    // The --xc-* options (#148): the crt with the call, and the filter.
    if (xcArgsFor(d, prog)) {
        String* crtText = Files.readText((String*)files.get((u32)0));
        String* cp = External.tempPath("xtc-crt.s");
        writeTempOrDie(cp, crtWithXcArgs(crtText));
        files.set((u32)0, (Object*)cp);
        String* xa = supportPath(d, "arm64/runtime", String.withCString(
            row.crt().equals(String.withCString("crt-macos.s")) ? "xcargs-macos.s" : "xcargs-elf.s"));
        if (xa == (String*)0 || !Files.exists(xa)) {
            Stdio.printf("xcc: error: the arm64 runtime piece for the --xc-* options is missing\n");
            driverExit((i32)1); return true;
        }
        files.add((Object*)xa);
    }
    String* stubs = classAllocStubs(prog);
    if (stubs.byteLength() > (u32)0) {
        String* sp = External.tempPath("xtc-allocators.s");
        writeTempOrDie(sp, stubs);
        files.add((Object*)sp);
    }
    String* asmPath = External.tempPath("xtc-prog.s");
    writeTempOrDie(asmPath, withoutXcDirectives(prog));
    Array* a = new Array();
    // The row's linker may carry flags (`clang++ -fexperimental-library`): a word each.
    if (gLangLinker != (String*)0) {
        Array* lw = Languages.words(gLangLinker);
        for (u32 i = 0; i < lw.count(); i = i + 1) a.add(lw.get(i));
    } else
        a.add((Object*)String.withCString("clang"));
    a.add((Object*)String.withCString("-arch"));
    a.add((Object*)String.withCString("arm64"));
    a.add((Object*)String.withCString("-O2"));
    for (u32 i = (u32)0; i < files.count(); i = i + (u32)1)
        a.add(files.get(i));
    a.add((Object*)asmPath);
    // A C++ program's other half: clang's object (the C path's split).
    if (gLangLinker != (String*)0)
        a.add((Object*)cRestObject());
    a.add((Object*)String.withCString("-Wl,-e,_xtc_start"));
    // Each `#import <Lib>` dylib by path, and an rpath to its directory so
    // the program finds it at run time.
    Array* nl = d.fe().neededLibs();
    Array* rpaths = new Array();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
        String* lib = (String*)nl.get(i);
        if (lib.hasPrefix(String.withCString("framework:"))) {
            a.add((Object*)String.withCString("-framework"));
            a.add((Object*)lib.substringFromByte((u32)10));
            continue;
        }
        a.add((Object*)lib);
        String* dir = lib.deletingLastPathComponent();
        bool seen = false;
        for (u32 k = (u32)0; k < rpaths.count(); k = k + (u32)1)
            if (((String*)rpaths.get(k)).equals(dir)) seen = true;
        if (!seen && dir.byteLength() > (u32)0) rpaths.add((Object*)dir);
    }
    for (u32 k = (u32)0; k < rpaths.count(); k = k + (u32)1) {
        a.add((Object*)String.withCString("-Wl,-rpath"));
        String* r = String.withCString("-Wl,");
        r.append((String*)rpaths.get(k));
        a.add((Object*)r);
    }
    addLinkerFlags(d, a);
    a.add((Object*)String.withCString("-o")); a.add((Object*)out);
    runOrDie(a, keep);
    if (!keep) External.cleanup();
    if (!d.quiet())
        Stdio.printf("xcc: arm64 executable -> '%s'\n", out.cString());
    signIfRequested(d, out);
    return true;
}

// The Cortex-A9 ABI flags from support/arm9/bsp-flags.sh (it reads them out
// of the Vitis BSP, with its own documented fallback), or that fallback when
// the script is missing or fails.
Array* arm9BspFlags(DriverOptions* d)
{
    Array* out = new Array();
    String* script = supportFile(d, "arm9/bsp-flags.sh");
    String* text = (String*)0;
    if (script != (String*)0 && Files.exists(script)) {
        Array* a = new Array();
        a.add((Object*)String.withCString("/bin/sh"));
        a.add((Object*)script);
        text = External.captureArgv(a);
    }
    if (text != (String*)0) {
        Array* toks = text.replacing(String.withCString("\n"), String.withCString(" ")).splitOnByte((u8)' ');
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1) {
            String* t = ((String*)toks.get(i)).trimmed();
            if (t.byteLength() > (u32)0) out.add((Object*)t);
        }
    }
    if (out.count() == (u32)0) {
        out.add((Object*)String.withCString("-mcpu=cortex-a9"));
        out.add((Object*)String.withCString("-mfloat-abi=hard"));
        out.add((Object*)String.withCString("-mfpu=vfpv3"));
    }
    return out;
}

// arm9 through arm-none-eabi-gcc: the same loader-hosted PIC ET_DYN, linked
// against the device libc.so/libm.so as needed. `prog` has already given up
// `main` when this is a program.
void externalArm9(DriverOptions* d, String* prog)
{
    String* libxtPic = supportFile(d, "arm9/runtime/libxt-pic.c");
    if (libxtPic == (String*)0 || !Files.exists(libxtPic)) {
        Stdio.printf("xcc: error: arm9 PIC runtime not found at '%s'\n",
                     libxtPic == (String*)0 ? "(no support tree)" : libxtPic.cString());
        driverExit((i32)1); return;
    }
    bool keep = d.fe().verbose();
    String* out = d.fe().output();
    String* asmPath = External.tempPath("xtc-arm9.s");
    String* stubPath = External.tempPath("xtc-arm9-pic-stub.c");
    writeTempOrDie(asmPath, prog);
    writeTempOrDie(stubPath, External.arm9StubSource(prog, d.emitLib()));
    // A library's interface rides in a `.xtc.iface` section, from a one-line
    // `.incbin` of the JSON.
    String* ifaceAsm = (String*)0;
    String* jsonPath = (String*)0;
    String* ij = d.fe().ifaceJson();
    if (ij != (String*)0 && ij.byteLength() > (u32)0 && d.emitLib()) {
        jsonPath = External.tempPath("xtc-iface.json");
        writeTempOrDie(jsonPath, ij);
        ifaceAsm = External.tempPath("xtc-iface.s");
        String* t = String.withCString("\t.section .xtc.iface,\"\",%progbits\n\t.incbin \"");
        t.append(jsonPath);
        t.appendCString("\"\n\t.byte 0\n");
        writeTempOrDie(ifaceAsm, t);
    }
    Array* a = new Array();
    a.add((Object*)String.withCString("arm-none-eabi-gcc"));
    Array* bsp = arm9BspFlags(d);
    for (u32 i = (u32)0; i < bsp.count(); i = i + (u32)1) a.add(bsp.get(i));
    a.add((Object*)String.withCString("-mfloat-abi=softfp"));
    a.add((Object*)String.withCString("-fPIC"));
    a.add((Object*)String.withCString("-shared"));
    a.add((Object*)String.withCString("-nostdlib"));
    a.add((Object*)String.withCString("-Wl,-Bsymbolic"));
    a.add((Object*)asmPath); a.add((Object*)libxtPic); a.add((Object*)stubPath);
    String* aeabi64 = supportFile(d, "arm9/runtime/aeabi64.s");
    if (Files.exists(aeabi64)) a.add((Object*)aeabi64);
    a.add((Object*)String.withCString("-lgcc"));
    if (ifaceAsm != (String*)0) a.add((Object*)ifaceAsm);
    if (d.emitLib()) {
        String* so = String.withCString("-Wl,-soname,");
        so.append(baseNameOf(out));
        a.add((Object*)so);
    }
    // The `#import <lib>` dependencies are named outright; the device libc and
    // libm only as needed, so a program that never touches them records
    // neither.
    Array* seenBase = new Array();
    Array* nl = d.fe().neededLibs();
    if (nl != (Array*)0 && nl.count() > (u32)0) {
        a.add((Object*)String.withCString("-Wl,--no-as-needed"));
        for (u32 i = (u32)0; i < nl.count(); i = i + (u32)1) {
            a.add(nl.get(i));
            seenBase.add((Object*)((String*)nl.get(i)).lastPathComponent());
        }
    }
    Array* asNeeded = new Array();
    Array* sys = new Array();
    sys.add((Object*)String.withCString("libc.so"));
    sys.add((Object*)String.withCString("libm.so"));
    for (u32 i = (u32)0; i < sys.count(); i = i + (u32)1) {
        String* ln = (String*)sys.get(i);
        bool seen = false;
        for (u32 k = (u32)0; k < seenBase.count(); k = k + (u32)1)
            if (((String*)seenBase.get(k)).equals(ln)) seen = true;
        if (seen) continue;
        String* p = arm9SysrootLib(d, ln);
        if (p != (String*)0) asNeeded.add((Object*)p);
    }
    if (asNeeded.count() > (u32)0) {
        a.add((Object*)String.withCString("-Wl,--as-needed"));
        for (u32 i = (u32)0; i < asNeeded.count(); i = i + (u32)1) a.add(asNeeded.get(i));
    }
    a.add((Object*)String.withCString("-o")); a.add((Object*)out);
    runOrDie(a, keep);
    if (!keep) External.cleanup();
    if (!d.quiet())
        Stdio.printf("xcc: arm9 PIC ELF (ET_DYN) -> '%s'\n", out.cString());
}

// A decimal argument. -1 when it is not one, which the caller reads as "leave
// the target's own default alone" rather than as zero — `-Flu wat` must not
// silently mean "never unroll".
i32 parseCount(String* s)
{
    if (s == 0 || s.byteLength() == (u32)0) return (i32)-1;
    i32 v = (i32)0;
    for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
        u8 c = s.byteAt(i);
        if (c < (u8)'0' || c > (u8)'9') return (i32)-1;
        v = v * (i32)10 + (i32)(c - (u8)'0');
    }
    return v;
}

// What this compiler accepts: every option the parser takes, grouped, and
// nothing it does not. A help text that promises a flag the compiler
// refuses is worse than a short one, and one that leaves a working flag out
// sends the reader to look elsewhere.
void usage(void)
{
    Stdio.printf("Usage: xcc [options] <input.xc>\n");
    Stdio.printf("       xcc [options] <a.o> [<b.o> <lib.a> ...] -o <program>\n");
    Stdio.printf("\n");
    Stdio.printf("With no -A, xcc builds a native executable for this machine:\n");
    Stdio.printf("    xcc -o prog prog.xc\n");
    Stdio.printf("\n");
    Stdio.printf("Output:\n");
    Stdio.printf("  -o, --output <path>        Output file. On a native target the result is an\n");
    Stdio.printf("                             executable unless the path ends in .s (assembly)\n");
    Stdio.printf("                             or .o (an object, with -c). On 6502 and m68k the\n");
    Stdio.printf("                             extension picks the container (see below).\n");
    Stdio.printf("  -c                         Compile to a relocatable object plus its .xtc.*\n");
    Stdio.printf("                             sidecars (arm64, ios, ios-sim, x86_64, win64, arm9)\n");
    Stdio.printf("  -S                         Stop after code generation; write assembly to -o\n");
    Stdio.printf("  -a, --assemble-only        The same as -S\n");
    Stdio.printf("  --emit-asm-from-ir         The same as -S (an older name)\n");
    Stdio.printf("  -E, --preprocessed <path>  Also write the preprocessed source to <path>\n");
    Stdio.printf("  --emit-iface               Write the module interface (JSON) to -o, or to\n");
    Stdio.printf("                             stdout with no -o, and stop\n");
    Stdio.printf("  --emit-lib                 Build a shared library, with its interface\n");
    Stdio.printf("                             embedded (arm64, x86_64, arm9, wasm32)\n");
    Stdio.printf("  --emit-runtime             Build the target's libRuntime from its root file\n");
    Stdio.printf("  --emit-runtime-support     Build the target's libRuntimeSupport (the runtime\n");
    Stdio.printf("                             with its standard library), which C and C++\n");
    Stdio.printf("                             programs link\n");
    Stdio.printf("  --no-runtime-lib           Compile the runtime in as source, not linking the\n");
    Stdio.printf("                             target's prebuilt libRuntime\n");
    Stdio.printf("  -dynamic                   (-A x86_64) Link against glibc and the -l\n");
    Stdio.printf("                             libraries (GTK 4, libGL, ...) instead of\n");
    Stdio.printf("                             statically over musl\n");
    Stdio.printf("  --emit-apk                 (-A android) Package an installable APK\n");
    Stdio.printf("  --sign-key <path>          Signing key for --emit-apk\n");
    Stdio.printf("  --sign <identity.pem>      Developer-sign the Mach-O (macOS / iOS)\n");
    Stdio.printf("  --sign-entitlements <path> Entitlements plist to embed with --sign\n");
    Stdio.printf("\n");
    Stdio.printf("Target:\n");
    Stdio.printf("  -A, --arch <arch>          Target. The default is the host.\n");
    Stdio.printf("                               arm64    macOS on Apple silicon (Mach-O)\n");
    Stdio.printf("                               ios      iOS device; ios-sim for the simulator\n");
    Stdio.printf("                               android  Android on arm64 (--emit-apk: an APK)\n");
    Stdio.printf("                               x86_64   Linux, static over musl (ELF);\n");
    Stdio.printf("                                        also x86-64, amd64\n");
    Stdio.printf("                               win64    Windows (PE); also windows,\n");
    Stdio.printf("                                        x86_64-windows\n");
    Stdio.printf("                               arm9     AArch32 / XTOS (ELF, or a .so);\n");
    Stdio.printf("                                        also armv7, armv7-a, cortex-a9\n");
    Stdio.printf("                               m68k     Atari ST/TT (GEMDOS .prg/.tos)\n");
    Stdio.printf("                               wasm32   WebAssembly (.wasm + .js loader);\n");
    Stdio.printf("                                        also wasm\n");
    Stdio.printf("                               6502     banked xt6502 (.xex); also xt6502\n");
    Stdio.printf("  -m, --memory-model <layout>\n");
    Stdio.printf("                             A memory layout, which selects the 6502 target:\n");
    Stdio.printf("                             a .lnk path (with or without .lnk),\n");
    Stdio.printf("                             <platform>/<layout>, or a layout name searched\n");
    Stdio.printf("                             for under every platform. `arm64`, `atarist`\n");
    Stdio.printf("                             (m68k), `arm9`, `x86_64`, `win64` and `wasm32`\n");
    Stdio.printf("                             name a platform instead and select it.\n");
    Stdio.printf("  --list-layouts, -ll        List the built-in layouts by platform and exit\n");
    Stdio.printf("  -dl, --dump-layout         Print the layout's memory map and exit (-m, or\n");
    Stdio.printf("                             the xt map by default)\n");
    Stdio.printf("  -x-<arch>,<opt>[,<opt>]    Target-specific options. wasm32: return-call\n");
    Stdio.printf("                             (tail calls become return_call)\n");
    Stdio.printf("\n");
    Stdio.printf("6502 (xt6502):\n");
    Stdio.printf("  -Q, --quit-style rts|loop  What the program does when main returns: rts\n");
    Stdio.printf("                             (the default) returns to the loader, DOS, with\n");
    Stdio.printf("                             main's value in A; loop spins in place\n");
    Stdio.printf("  --xtc-stack                Keep every function's return address and saved\n");
    Stdio.printf("                             registers on the software stack, not the\n");
    Stdio.printf("                             hardware stack. :hwStack on a function opts out;\n");
    Stdio.printf("                             :xtcStack opts one in without the flag\n");
    Stdio.printf("  -Fmb, --fn-min-banked <n>  Keep functions of fewer than n instructions in\n");
    Stdio.printf("                             main RAM instead of a code bank, so calls to\n");
    Stdio.printf("                             them need no bank switch. Default 0 (off)\n");
    Stdio.printf("  -dp, --dump-placement      Print each function's placement (main, bank N,\n");
    Stdio.printf("                             irq, vbi) and the bytes used per bank, to stderr\n");
    Stdio.printf("  -du, --dump-usage          Print the bytes the image uses in every region\n");
    Stdio.printf("                             and code bank of the layout, to stderr\n");
    Stdio.printf("\n");
    Stdio.printf("Paths and definitions:\n");
    Stdio.printf("  -I, --include <path>       Add an include search path\n");
    Stdio.printf("  -D <name[=value]>          Define a preprocessor symbol (also -Dname=value)\n");
    Stdio.printf("  -L, --library-path <path>  Add a library search path for `#import <Lib>`\n");
    Stdio.printf("                             and -l (also -L<path>)\n");
    Stdio.printf("  -H, --xcc-home <path>      Root holding the support tree (also --xtc-home).\n");
    Stdio.printf("                             Rarely needed: see the search order below.\n");
    Stdio.printf("\n");
    Stdio.printf("Optimisation:\n");
    Stdio.printf("  -O0 ... -O3                Optimisation level, joined (-O0, not -O 0).\n");
    Stdio.printf("                             Default -O3. A bare -O is -O1.\n");
    Stdio.printf("  -Flu, --fn-loop-unroll <n> Unroll counted loops whose constant trip count\n");
    Stdio.printf("                             is at most n (the default depends on the target)\n");
    Stdio.printf("  -Fli, --fn-leaf-inline <n> Inline callees of up to n IR instructions\n");
    Stdio.printf("                             (default 64)\n");
    Stdio.printf("  -flto                      At a link of objects, recompile the IR they\n");
    Stdio.printf("                             carry as one module\n");
    Stdio.printf("  -ffp-contract=fast|on|off  For C: clang's float contraction setting\n");
    Stdio.printf("  -std=<standard>            For C: the language standard, such as c99, c11\n");
    Stdio.printf("                             or c17, handed to clang (default: clang's own)\n");
    Stdio.printf("  -fbounds-check=light       Range-check subscripts (arm64 macOS, x86-64,\n");
    Stdio.printf("                             win64): an array with a declared length against\n");
    Stdio.printf("                             that length, a heap allocation against its\n");
    Stdio.printf("                             header; a check the compiler proves is dropped,\n");
    Stdio.printf("                             and a failure names the site and the bounds and\n");
    Stdio.printf("                             stops\n");
    Stdio.printf("  -fbounds-check             The debug build of the same checks: a failure\n");
    Stdio.printf("                             also prints a symbolised stack (arm64 macOS keeps\n");
    Stdio.printf("                             every frame for it)\n");
    Stdio.printf("  -fno-bounds-check          No subscript checks (the default)\n");
    Stdio.printf("  -fno-xc-args               A program with a par block passes every argument\n");
    Stdio.printf("                             to main, --xc-* options included (by default\n");
    Stdio.printf("                             the start code takes them out and sets the\n");
    Stdio.printf("                             runtime variables they name)\n");
    Stdio.printf("\n");
    Stdio.printf("Linking (in-house unless --no-self-host):\n");
    Stdio.printf("  -l<name>                   Link a library found on the -L path, or a system\n");
    Stdio.printf("                             library through its SDK stub\n");
    Stdio.printf("  -framework <F>             Link a macOS / iOS framework\n");
    Stdio.printf("  -Xlinker <arg>             Pass <arg> to the linker: a library or object\n");
    Stdio.printf("                             path joins the link; `-rpath <dir>` adds a search\n");
    Stdio.printf("                             path (Mach-O); any other flag is reported and\n");
    Stdio.printf("                             skipped\n");
    Stdio.printf("  -Wl,<arg>[,<arg>...]       The same as one -Xlinker per argument\n");
    Stdio.printf("  --link-libs                (-A wasm32) Build the app in the mode that links\n");
    Stdio.printf("                             .wasm libraries. Chosen by itself when the\n");
    Stdio.printf("                             program imports one.\n");
    Stdio.printf("  --self-host                Assemble and link in-house (the default)\n");
    Stdio.printf("  --no-self-host             Link with the installed platform toolchain:\n");
    Stdio.printf("                             clang (arm64), the NDK clang (android),\n");
    Stdio.printf("                             arm-none-eabi-gcc (arm9)\n");
    Stdio.printf("\n");
    Stdio.printf("Diagnostics:\n");
    Stdio.printf("  -q, --quiet                Errors and warnings only\n");
    Stdio.printf("  -V, --verbose              Print the support root and include search paths\n");
    Stdio.printf("  --emit-ir                  Print the IR after lowering to stderr\n");
    Stdio.printf("  --emit-ir-opt              Print the IR after the optimiser to stderr\n");
    Stdio.printf("  --print-3p-dir             Print this compiler's own third-party library tree\n");
    Stdio.printf("  -fdce-trace                Name each function dead-function elimination\n");
    Stdio.printf("                             removes, on stderr\n");
    Stdio.printf("  -W                         All warnings (the default)\n");
    Stdio.printf("  -Wanalyze                  Also run the static-analysis warnings\n");
    Stdio.printf("  -Wno-<category>            Silence one warning category:\n");
    printCategories();
    Stdio.printf("  --migrate=<base>:<to>      Compile as if the library were still <base>:\n");
    Stdio.printf("                             members marked since(\"V\") with V newer than\n");
    Stdio.printf("                             <base> are not found, so a call whose meaning\n");
    Stdio.printf("                             changed between the versions is an error\n");
    Stdio.printf("  -v, --version              Print the version and exit\n");
    Stdio.printf("  -h, --help                 This text\n");
    Stdio.printf("\n");
    capabilityUsage();
    Stdio.printf("\n");
    Stdio.printf("Accepted for compatibility:\n");
    Stdio.printf("  -fnew-ir, --with-ir        No effect: the IR pipeline is the only one\n");
    Stdio.printf("  -farc[=...]                Retired, with a warning: ARC is always on\n");
    Stdio.printf("  -fauto-cloak=never|auto|always\n");
    Stdio.printf("                             Checked; no effect, as no layout has a cloaked\n");
    Stdio.printf("                             region\n");
    Stdio.printf("  -ss, --stack-size <n>      wasm32: the shadow stack's size in bytes\n");
    Stdio.printf("                             (decimal, $hex or 0xhex; default 1 MiB, at\n");
    Stdio.printf("                             most 1 GiB). No effect on other targets\n");
    Stdio.printf("\n");
    Stdio.printf("Output containers on 6502 and m68k:\n");
    Stdio.printf("    .s .asm                  assembly (stops before the assembler)\n");
    Stdio.printf("    .xex .exe .bin .com      banked xt6502 executable (any other name too)\n");
    Stdio.printf("    .tos .prg                GEMDOS executable (any other name too)\n");
    Stdio.printf("\n");
    Stdio.printf("Support tree search. Each root is probed for lib/xc, then xc, then support:\n");
    Stdio.printf("    -H  >  $XCC_HOME  >  $XTC_HOME  >  the directory holding xcc and its\n");
    Stdio.printf("    parent  >  the current directory  >  ~/xcc  >  ~/xtc  >  /opt/xcc/<version>\n");
    Stdio.printf("    >  /opt/xcc  >  /usr/local/xcc  >  /usr/local/xtc  >  /opt/xtc\n");
    Stdio.printf("\n");
    envUsage();
    Stdio.printf("An unrecognised option is an error, never ignored.\n");
}

// Every environment variable the compiler reads, in one place (#337): the
// settings first, then the switches for diagnosing the compiler itself.
// tests/driver/env-registry.sh checks that each variable the sources read is
// listed here.
void envUsage(void)
{
    Array* settings = new Array();
    settings.add((Object*)String.withCString("XCC_HOME|A support root, ahead of the built-in search"));
    settings.add((Object*)String.withCString("XTC_HOME|The older spelling of XCC_HOME"));
    settings.add((Object*)String.withCString("XCC_3P|A third-party library root, ahead of /opt/xcc/3p"));
    settings.add((Object*)String.withCString("XTC_LDFLAGS|More linker arguments, as if each were given with -Xlinker"));
    settings.add((Object*)String.withCString("SDKROOT|The Apple SDK whose frameworks' exports a link checks"));
    settings.add((Object*)String.withCString("XTC_MUSL_ROOT|The musl pool a static x86-64 Linux link takes libc from"));
    settings.add((Object*)String.withCString("XTC_WIN64_TOOLCHAIN|The mingw root win64 -l archives come from"));
    settings.add((Object*)String.withCString("XCC_DEBUG_DIR|Roots for separate debug files (colon-separated; /usr/lib/debug)"));
    settings.add((Object*)String.withCString("XCC_NO_RUNTIME_LIB|=1: as --no-runtime-lib"));
    settings.add((Object*)String.withCString("XC_PAR_REMOTE|A remote GPU worker: programs carry every GPU kernel form"));
    settings.add((Object*)String.withCString("XC_PAR_MDNS_WAIT|=<ms>: the longest a program's mDNS search for daemons listens (2000)"));
    settings.add((Object*)String.withCString("XC_LANGUAGES|A language table file, replacing the built-in rows"));
    settings.add((Object*)String.withCString("XCC_SIGN_PASSPHRASE|The passphrase of the --sign key"));
    settings.add((Object*)String.withCString("XCC_SIGN_CA_FILE|The CA bundle --sign's HTTPS requests trust"));
    settings.add((Object*)String.withCString("TMPDIR|Where each run's private scratch directory is made"));
    Array* diag = new Array();
    diag.add((Object*)String.withCString("XC_C_KEEP|=<prefix>: keep a C build's IR and objects as <prefix>.*"));
    diag.add((Object*)String.withCString("XC_C_TRACE|Name the C functions left to clang, and why"));
    diag.add((Object*)String.withCString("XC_C_LL|=<file>: read this file as clang's IR"));
    diag.add((Object*)String.withCString("XC_C_HANDLERS|=1: read C++ exception handlers on any target"));
    diag.add((Object*)String.withCString("XC_C_CABI|Give every C function read the C calling convention"));
    diag.add((Object*)String.withCString("XC_PAR_PROPOSE|=report|outline: report or outline the loops par would take"));
    diag.add((Object*)String.withCString("XC_PAR_OUTLINE_TRACE|Why a block has no GPU form (=ir: the outliner's functions)"));
    diag.add((Object*)String.withCString("XC_PAR_OUTLINE_DUMP|=<path>: the module after outlining"));
    diag.add((Object*)String.withCString("XC_PAR_AUTO_TRACE|A line for each loop --par-style=auto considers: lifted or serial, and the rule"));
    diag.add((Object*)String.withCString("XTIR_OPT_STOP_AFTER|=<pass>: stop the optimiser after that pass"));
    diag.add((Object*)String.withCString("XC_OPT_CAPS|Say when a capped run-until-settled loop stopped at its cap"));
    diag.add((Object*)String.withCString("XC_OPT_VERIFY|Check every cached optimiser analysis against a fresh build; stop on a difference"));
    diag.add((Object*)String.withCString("XC_DUMP_DRIVER_STATE|Print the parsed options and stop (the option-table check)"));
    diag.add((Object*)String.withCString("XTIC_OFF|No if-conversion after bounds checks are removed"));
    diag.add((Object*)String.withCString("XTGPU_ESC_TRIPS|=<n>: the escape-loop GPU variant's trip count"));
    diag.add((Object*)String.withCString("XCC_GC_STATS|Print what the ELF link's section GC kept"));
    diag.add((Object*)String.withCString("XCC_SIGN_HTTPS_CONNECT|=<host:port>: where --sign's HTTPS requests connect"));
    Stdio.printf("Environment:\n");
    envRows(settings);
    Stdio.printf("\nDiagnostics (for working on the compiler):\n");
    envRows(diag);
    Stdio.printf("\n");
}

void envRows(Array* rows)
{
    for (u32 i = (u32)0; i < rows.count(); i = i + (u32)1)
        {
        String* r = (String*)rows.get(i);
        u32 bar = r.indexOfByte((u8)'|');
        String* name = r.substringBytes((u32)0, bar);
        String* line = String.withCString("  ");
        line.append(name);
        while (line.byteLength() < (u32)29)
            line.appendByte((u8)' ');
        line.appendByte((u8)' ');
        line.append(r.substringFromByte(bar + (u32)1));
        Stdio.printf("%s\n", line.cString());
        }
}

// The -Wno- categories, one indented line each.
void printCategories(void)
{
    Array* cats = warningCategoryNames().splitOnByte((u8)',');
    for (u32 i = (u32)0; i < cats.count(); i = i + (u32)1)
        Stdio.printf("                               %s\n", ((String*)cats.get(i)).trimmed().cString());
}

// The capability flags' half of --help, beside the parser that reads them.
void capabilityUsage(void)
{
    Stdio.printf("Code generation:\n");
    Stdio.printf("  -A 68000, -A 68030         m68k for a specific CPU (-A m68k is the 68000)\n");
    Stdio.printf("  -mhard-float, -mfpu        (m68k) Use the 68881 FPU for float and double\n");
    Stdio.printf("  -msoft-float               (m68k) Floating point in software, the default\n");
    Stdio.printf("  -fpic, -fPIC, -mpic        Position-independent code: the GOT/a5 model on\n");
    Stdio.printf("                             m68k. arm64, android and arm9 are always PIC\n");
    Stdio.printf("  -mavx2, -msimd=avx2        x86-64/win64: 256-bit AVX2 vectors (the\n");
    Stdio.printf("                             binary then needs an AVX2 CPU)\n");
    Stdio.printf("  -mavx512, -msimd=avx512    x86-64/win64: 512-bit AVX-512 vectors (F, DQ,\n");
    Stdio.printf("                             BW and VL; the binary then needs such a CPU)\n");
    Stdio.printf("  -msimd=base                x86-64/win64: SSE2 only, one version\n");
    Stdio.printf("  -msimd=auto                x86-64/win64: SSE2 and AVX2 versions of each\n");
    Stdio.printf("                             vectorised function, picked at load (the\n");
    Stdio.printf("                             default; XC_SIMD=base|avx2 overrides it)\n");
    Stdio.printf("  -mnative                   x86-64/win64: the level of this machine\n");
    Stdio.printf("  -fno-matmul                Leave recognised matrix multiplies as loops\n");
    Stdio.printf("                             (arm64 macOS: no SME kernel; x86-64: no\n");
    Stdio.printf("                             vector kernel)\n");
    Stdio.printf("  -fthread-safe-arc          Atomic ARC refcounts. Default: on when the\n");
    Stdio.printf("                             program spawns a thread\n");
    Stdio.printf("  -fno-thread-safe-arc       Plain, non-atomic refcounts\n");
    Stdio.printf("  -fpar-kernels=all          Every par block carries every GPU kernel form,\n");
    Stdio.printf("                             for workers on other machines (xcd); on by\n");
    Stdio.printf("                             itself where XC_PAR_REMOTE is set\n");
    Stdio.printf("  --par-style=auto|threads|gpu|cpu\n");
    Stdio.printf("                             How plain loops run. auto (the default): a\n");
    Stdio.printf("                             for (i in a..b) loop becomes a par block where\n");
    Stdio.printf("                             its shape allows, and each block picks CPU\n");
    Stdio.printf("                             threads, the GPU or both as it runs; threads:\n");
    Stdio.printf("                             the CPU's threads only; gpu: the GPU first;\n");
    Stdio.printf("                             cpu: no loop changes (one thread, vectorised).\n");
    Stdio.printf("                             -Wpar-auto says what was lifted and why not.\n");
    Stdio.printf("  -fgoal=speed|accuracy      The default goal of loops and par blocks\n");
    Stdio.printf("                             (#goal in a file overrides it, :goal(...) both)\n");
    Stdio.printf("  -Wpar-auto                 Say what --par-style lifted and what it left\n");
    Stdio.printf("  -falloc=bump|heap          Allocator. Every current target uses heap\n");
    Stdio.printf("  -fmalloc=system|mimalloc   The C heap behind the runtime. mimalloc is\n");
    Stdio.printf("                             -A x86_64 only, linked ahead of libc\n");
    Stdio.printf("  -g                         Emit DWARF debug information: line tables,\n");
    Stdio.printf("                             functions and call frames\n");
    Stdio.printf("\n");
    Stdio.printf("Android packaging:\n");
    Stdio.printf("  --needed <soname>          Add a DT_NEEDED entry; repeatable\n");
    Stdio.printf("  --with-lib <path>          (--emit-apk) Package a prebuilt lib<name>.so too\n");
    Stdio.printf("  --lib-name <name>          (--emit-apk) The library Android loads first\n");
    Stdio.printf("  --manifest-attr <n>=<v>    (--emit-apk) An attribute on <application>; repeatable\n");
    Stdio.printf("  --with-dex <path>          (--emit-apk) Package a classes.dex\n");
}

// The warning categories, which must AGREE with the reference's
// XTWarningCategory table in src/xtc/diagnostics/XTDiagnosticEngine.m. Two
// lists of one set is the drift shape this project keeps being bitten by, so
// the reference's file is named here and the order is kept identical to make a
// diff between the two readable.
String* warningCategoryNames(void)
{
    return String.withCString(
        "escape, class-init, asm-clobbers, unknown-annotation, "
        "unknown-pragma, printf-format, unowned-bound, cloaked-transitive, "
        "unreachable-catch, comment, packed-align, range-init-count, "
        "covariant-return, unguarded-action, toolchain-fallback, return-type, "
        "par-scatter, par-auto, par-gpu, retain-cycle");
}

bool isWarningCategory(String* c)
{
    if (c == (String*)0) return false;
    String* all = warningCategoryNames();
    u32 i = (u32)0;
    u32 start = (u32)0;
    while (i <= all.byteLength()) {
        if (i == all.byteLength() || all.byteAt(i) == (u8)',') {
            String* one = all.substringBytes(start, i - start).trimmed();
            if (one.equals(c)) return true;
            start = i + (u32)1;
        }
        i = i + (u32)1;
    }
    return false;
}

// The `-m` names that are a PLATFORM rather than a layout, and the target each
// selects. 0 for a layout name.
String* platformLayoutArch(String* m)
{
    if (m.equals(String.withCString("arm64"))) return String.withCString("arm64");
    if (m.equals(String.withCString("atarist"))) return String.withCString("m68k");
    if (m.equals(String.withCString("arm9"))) return String.withCString("arm9");
    if (m.equals(String.withCString("x86_64")) || m.equals(String.withCString("x86-64"))
        || m.equals(String.withCString("amd64")))
        return String.withCString("x86_64");
    if (m.equals(String.withCString("win64")) || m.equals(String.withCString("windows")))
        return String.withCString("win64");
    if (m.equals(String.withCString("wasm32")) || m.equals(String.withCString("wasm")))
        return String.withCString("wasm32");
    return (String*)0;
}

// `-ss <n>`: decimal, `$hex` or `0xhex`. -1 when it is none of those; the
// caller range-checks, so a large value only has to stay large.
i32 parseStackSize(String* v)
{
    u32 i = (u32)0;
    bool hex = false;
    if (v.byteLength() > (u32)0 && v.byteAt((u32)0) == (u8)'$') { hex = true; i = (u32)1; }
    else if (v.byteLength() > (u32)1 && v.byteAt((u32)0) == (u8)'0'
             && (v.byteAt((u32)1) == (u8)'x' || v.byteAt((u32)1) == (u8)'X')) { hex = true; i = (u32)2; }
    if (i >= v.byteLength()) return (i32)-1;
    u32 n = (u32)0;
    for (; i < v.byteLength(); i = i + (u32)1) {
        u8 c = v.byteAt(i);
        u32 dgt = (u32)99;
        if (c >= (u8)'0' && c <= (u8)'9') dgt = (u32)(c - (u8)'0');
        else if (hex && c >= (u8)'a' && c <= (u8)'f') dgt = (u32)(c - (u8)'a') + (u32)10;
        else if (hex && c >= (u8)'A' && c <= (u8)'F') dgt = (u32)(c - (u8)'A') + (u32)10;
        if (dgt == (u32)99) return (i32)-1;
        n = n * (hex ? (u32)16 : (u32)10) + dgt;
        if (n > (u32)$40000001) n = (u32)$40000001;   // out of range either way
    }
    return (i32)n;
}

// ── directory listing ────────────────────────────────────────────────────
//
// The layout search and --list-layouts walk directories, and the runtime has
// no primitive for that, so it goes to the host C library: opendir/readdir on
// the POSIX hosts, FindFirstFileA on Windows. The entry layout is the host's,
// hence the per-host offsets: d_type/d_name at 20/21 on macOS, 18/19 on musl.
#if OS_windows
u8* FindFirstFileA(u8* pattern, u8* data);
i32 FindNextFileA(u8* h, u8* data);
i32 FindClose(u8* h);
#else
u8* opendir(u8* path);
u8* readdir(u8* d);
i32 closedir(u8* d);
#endif

// The names in `dir`, sorted, without `.`, `..` or symbolic links (a layout
// directory keeps `default.lnk`-style aliases that are not layouts of their
// own). Empty when the directory cannot be read.
Array* listDirectory(String* dir)
{
    Array* out = new Array();
#if OS_windows
    u8 fd[320];
    String* pat = String.withString(dir);
    pat.appendCString("/*");
    u8* h = FindFirstFileA(pat.cString(), &fd[0]);
    if (h == (u8*)0 || (i64)h == (i64)-1) return out;
    bool more = true;
    while (more) {
        u32 attrs = (u32)fd[0] | ((u32)fd[1] << (u32)8) | ((u32)fd[2] << (u32)16) | ((u32)fd[3] << (u32)24);
        String* nm = String.withCString(&fd[44]);
        if ((attrs & (u32)$400) == (u32)0 && !nm.equals(String.withCString("."))
            && !nm.equals(String.withCString("..")))
            out.add((Object*)nm);
        more = FindNextFileA(h, &fd[0]) != (i32)0;
    }
    FindClose(h);
#elif ARCH_armv7
    // No host C library to ask on this target.
    return out;
#else
#if ARCH_x86_64 || OS_linux
    // glibc's dirent (both arches): d_type at 18, the name at 19.
    u32 typeAt = (u32)18;
    u32 nameAt = (u32)19;
#else
    u32 typeAt = (u32)20;
    u32 nameAt = (u32)21;
#endif
    u8* dp = opendir(dir.cString());
    if (dp == (u8*)0) return out;
    u8* e = readdir(dp);
    while (e != (u8*)0) {
        String* nm = String.withCString(e + nameAt);
        if (e[typeAt] != (u8)10 && !nm.equals(String.withCString("."))   // 10 = DT_LNK
            && !nm.equals(String.withCString("..")))
            out.add((Object*)nm);
        e = readdir(dp);
    }
    closedir(dp);
#endif
    out.sort();
    return out;
}

// ── layouts ──────────────────────────────────────────────────────────────
//
// `-m <spec>` to a `.lnk` path, in the original's order: the spec as a file,
// the spec with `.lnk` added, then `<platform>/<layout>` — or, with no
// platform named, every platform directory in turn — under the support root,
// in `layouts/` and then `internal/`. 0 when nothing matches.
String* resolveLayoutFile(FeOptions* o, String* spec)
{
    if (Files.exists(spec) && !spec.hasSuffix(String.withCString("/"))) {
        if (Files.readText(spec) != (String*)0) return spec;
    }
    String* withExt = String.withString(spec); withExt.appendCString(".lnk");
    if (Files.exists(withExt)) return withExt;
    String* root = supportRoot(o);
    if (root == (String*)0) return (String*)0;
    Array* platforms = new Array();
    String* layout = spec;
    u32 slash = spec.indexOfByte((u8)'/');
    if (slash != String.notFound()) {
        platforms.add((Object*)spec.substringBytes((u32)0, slash));
        layout = spec.substringFromByte(slash + (u32)1);
    } else {
        platforms = listDirectory(root);
        // A host that cannot list a directory still finds the one platform
        // that has layouts today.
        if (platforms.count() == (u32)0) platforms.add((Object*)String.withCString("xt6502"));
    }
    for (u32 p = (u32)0; p < platforms.count(); p = p + (u32)1) {
        for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1) {
            String* c = String.withString(root);
            c.appendCString("/");
            c.append((String*)platforms.get(p));
            c.appendCString(k == (u32)0 ? "/layouts/" : "/internal/");
            c.append(layout);
            c.appendCString(".lnk");
            if (Files.exists(c)) return c;
        }
    }
    return (String*)0;
}

// --list-layouts: every `.lnk` under `<support>/<platform>/layouts/`, grouped
// by platform, on stderr — the original's listing, line for line.
void listLayouts(FeOptions* o)
{
    String* root = supportRoot(o);
    if (root == (String*)0) root = String.withCString("support");
    String* out = String.withCString("Available layouts (use with -m <platform>/<layout>):\n\n");
    bool any = false;
    Array* platforms = listDirectory(root);
    for (u32 p = (u32)0; p < platforms.count(); p = p + (u32)1) {
        String* plat = (String*)platforms.get(p);
        if (plat.equals(String.withCString("generic"))) continue;
        String* dir = String.withString(root);
        dir.appendCString("/"); dir.append(plat); dir.appendCString("/layouts");
        Array* files = listDirectory(dir);
        Array* names = new Array();
        for (u32 f = (u32)0; f < files.count(); f = f + (u32)1) {
            String* fn = (String*)files.get(f);
            if (fn.hasSuffix(String.withCString(".lnk")))
                names.add((Object*)fn.substringBytes((u32)0, fn.byteLength() - (u32)4));
        }
        if (names.count() == (u32)0) continue;
        any = true;
        out.appendCString("  "); out.append(plat); out.appendCString(":\n");
        for (u32 f = (u32)0; f < names.count(); f = f + (u32)1) {
            out.appendCString("    -m "); out.append(plat); out.appendCString("/");
            out.append((String*)names.get(f)); out.appendCString("\n");
        }
        out.appendCString("\n");
    }
    if (!any) { out.appendCString("  (no layouts found in "); out.append(root); out.appendCString("/)\n"); }
    Stdio.error(out);
}

// Every token of $XTC_LDFLAGS joins the link, after the command line's own:
// `-Xlinker <arg>` and `-Wl,a,b` unwrap, `-framework <F>` names a framework,
// and the rest go through the same rule as a -Wl, token.
void addLdFlagsFromEnvironment(DriverOptions* d)
{
    String* env = Platform.env(String.withCString("XTC_LDFLAGS"));
    if (env == (String*)0) return;
    Array* toks = new Array();
    String* cur = new String();
    for (u32 i = (u32)0; i <= env.byteLength(); i = i + (u32)1) {
        u8 c = i < env.byteLength() ? env.byteAt(i) : (u8)' ';
        if (c == (u8)' ' || c == (u8)9 || c == (u8)10 || c == (u8)13) {
            if (cur.byteLength() > (u32)0) { toks.add((Object*)cur); cur = new String(); }
        } else {
            cur.appendByte(c);
        }
    }
    u32 k = (u32)0;
    while (k < toks.count()) {
        String* t = (String*)toks.get(k);
        if (t.equals(String.withCString("-Xlinker")) && k + (u32)1 < toks.count()) {
            d.addLinkToken((String*)toks.get(k + (u32)1)); k = k + (u32)2; continue;
        }
        if (t.equals(String.withCString("-framework")) && k + (u32)1 < toks.count()) {
            d.frameworks().add(toks.get(k + (u32)1)); k = k + (u32)2; continue;
        }
        if (t.equals(String.withCString("-L")) && k + (u32)1 < toks.count()) {
            d.ldDirs().add(toks.get(k + (u32)1)); k = k + (u32)2; continue;
        }
        if (t.hasPrefix(String.withCString("-Wl,"))) {
            Array* parts = t.substringFromByte((u32)4).splitOnByte((u8)',');
            for (u32 q = (u32)0; q < parts.count(); q = q + (u32)1) d.addLinkToken((String*)parts.get(q));
            k = k + (u32)1; continue;
        }
        d.addLinkToken(t);
        k = k + (u32)1;
    }
}

// Linker flags the in-house linker does not implement are named, once, when a
// link runs — the same note the in-house arm64 linker gives — and skipped.
// `-rpath` is implemented only where the output is Mach-O.
void noteLinkFlags(DriverOptions* d)
{
    bool machO = isMacArm64(d) || isIos(d);
    for (u32 i = (u32)0; i < d.rawLinkFlags().count(); i = i + (u32)1)
        Stdio.error(String.withFormat("xcc: note: ignoring unrecognised linker flag '%s'\n",
                                      ((String*)d.rawLinkFlags().get(i)).cString()));
    if (!machO)
        for (u32 i = (u32)0; i < d.rpaths().count(); i = i + (u32)1)
            Stdio.error(String.withFormat("xcc: note: ignoring '-rpath %s': only a Mach-O "
                                          "link records a search path\n",
                                          ((String*)d.rpaths().get(i)).cString()));
}

// The assembly a build stops at: to the -o file, or with no -o to standard
// output, as the reference does (`xcc prog.xc` prints the program's
// assembly). The port used to take a missing -o for a program and died
// writing to no path (2026-10-31: every release since 0.86).
bool writeAsmOut(DriverOptions* d, String* text)
{
    if (d.fe().output() == (String*)0) {
        Stdio.printf("%s", text.cString());
        return true;
    }
    return Files.writeText(d.fe().output(), text);
}

// The IR after the optimiser, when --emit-ir-opt asked for it.
void dumpOptIR(DriverOptions* d, IRModule* mod)
{
    if (!d.emitIROpt()) return;
    Stdio.error(mod.text());
}

// -Fli and -fdce-trace reach the optimiser through the target's profile.
void applyOptFlags(DriverOptions* d, OptProfile* p)
{
    Opt.setInlineOverride(p, d.inlineMax());
    Opt.setDceTrace(p, d.dceTrace());
    // -fbounds-check=light: the subscript checks bounds-elide leaves inline in
    // loops (-O2+, the arm64, x86-64 and win64 code generators: every arm64
    // row, android and arm64 Linux among them); the debug build keeps them calls.
    String* cg = d.targetRow() != (TargetRow*)0 ? d.targetRow().codegen() : String.withCString("");
    if ((cg.equals(String.withCString("arm64")) || cg.equals(String.withCString("x86_64")) || cg.equals(String.withCString("win64")))
        && d.fe().boundsCheck() && !d.fe().boundsReport() && d.opt() >= (u32)2)
        p.setInlineChecks(true);
    // Matrix kernels, -O2+, unless -fno-matmul: arm64 macOS (SME; the kernel
    // checks for SME at run time and leaves the loop to run when it is absent)
    // and x86-64 Linux (a kernel per vector tier, named below with the level).
    bool matMul = !d.caps().noMatmul() && d.opt() >= (u32)2;
    String* mmKind = d.targetRow() != (TargetRow*)0 ? d.targetRow().matmul() : (String*)0;
    if (matMul && mmKind != (String*)0 && mmKind.equals(String.withCString("sme"))) {
        p.setMatMul(String.withCString("__xt_sme_gemm_"), String.withCString(""));
        p.setMatMulFastSuffix(String.withCString("_fast"));
        p.setMatMulInts(true);
    }
    // The vector level only ever reaches an x86-64 profile (checkCapabilities
    // refuses it elsewhere): avx2 gives the vectoriser 32-byte vectors, which
    // the back end emits as ymm.
    String* simd = d.caps().simd();
    // With no -m flag the level is `auto` (runtime SIMD dispatch), as the
    // reference's driver forwards it.
    // Only for an executable built in one invocation: a -c object or a library
    // carries its own constructor table, and two in one link collide. A C
    // program's xcc half is compiled as an object, but it is the program's
    // only one with a table (clang's half, the globals, has none), so it
    // dispatches too.
    if (simd == (String*)0 && (isX86_64(d) || isWin64(d))
        && (!d.compileOnly() || gCSplitOut != (String*)0) && !d.emitLib())
        simd = String.withCString("auto");
    if (simd != (String*)0)
    {
        p.setVectorLaneBytes(simd.equals(String.withCString("avx512")) ? (u32)64
                             : (simd.equals(String.withCString("avx2")) ? (u32)32 : (u32)16));
        // -msimd=auto: base code plus avx2 clones, picked at load.
        p.setSimdDispatch(simd.equals(String.withCString("auto")));
    }
    if (matMul && mmKind != (String*)0 && mmKind.equals(String.withCString("x86")))
    {
        String* lv = simd == (String*)0 ? String.withCString("base") : simd;
        if (!lv.equals(String.withCString("avx512")) && !lv.equals(String.withCString("avx2"))
            && !lv.equals(String.withCString("auto")))
            lv = String.withCString("base");
        String* suffix = String.withCString("_");
        suffix.append(lv);
        p.setMatMul(String.withCString("__xt_x86_gemm_"), suffix);
    }
}

#if OS_windows
i32 IsProcessorFeaturePresent(u32 feature);
#endif

// The vector level of the machine running the compiler, for -mnative:
// "avx512" when the CPU has AVX-512 F, DQ, BW and VL and the OS saves the zmm
// state, "avx2" when it has AVX2 and the OS saves the ymm state, "base"
// otherwise, 0 when
// this compiler is not running on x86-64 (an arm64 Mac has no AVX to read).
// Windows answers both halves in IsProcessorFeaturePresent (40 =
// PF_AVX2_INSTRUCTIONS_AVAILABLE); Linux lists avx2 in /proc/cpuinfo only when
// the kernel supports it. Matches the reference's hostSimdLevel.
String* hostSimdLevel(void)
{
#if OS_windows
    // 41 = PF_AVX512F_INSTRUCTIONS_AVAILABLE. Windows has no flag for DQ, BW
    // and VL, but every part with AVX-512F that Windows runs on has all three.
    if (IsProcessorFeaturePresent((u32)41) != (i32)0)
        return String.withCString("avx512");
    return IsProcessorFeaturePresent((u32)40) != (i32)0 ? String.withCString("avx2") : String.withCString("base");
#elif ARCH_x86_64
    String* info = Files.readText(String.withCString("/proc/cpuinfo"));
    if (info == (String*)0) return String.withCString("base");
    Array* lines = info.splitOnByte((u8)'\n');
    for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
        String* ln = (String*)lines.get(i);
        if (!ln.hasPrefix(String.withCString("flags"))) continue;
        Array* w = ln.splitOnByte((u8)' ');
        u32 v4 = (u32)0;
        bool avx2 = false;
        for (u32 k = (u32)0; k < w.count(); k = k + (u32)1) {
            String* f = (String*)w.get(k);
            if (f.equals(String.withCString("avx512f")) || f.equals(String.withCString("avx512dq"))
                || f.equals(String.withCString("avx512bw")) || f.equals(String.withCString("avx512vl")))
                v4 = v4 + (u32)1;
            if (f.equals(String.withCString("avx2")))
                avx2 = true;
        }
        if (v4 == (u32)4)
            return String.withCString("avx512");
        return String.withCString(avx2 ? "avx2" : "base");
    }
    return String.withCString("base");
#else
    return (String*)0;
#endif
}

// One capability flag at argv[*i], or false when it is not one. Advances *i
// past the flag and its value. The target may not be known yet (-A can come
// later on the line), so anything that depends on it waits for
// checkCapabilities.
bool parseCapabilityFlag(DriverOptions* d, u32* ip, u32 argc)
{
    u32 i = *ip;
    String* a = Process.argument(i);
    CapOptions* c = d.caps();
    bool hasVal = i + (u32)1 < argc;
    // -A m68k / 68000 / 68030: the m68k back end, and WHICH 68k. The CPU is a
    // code-generation choice (32-bit PC-relative addressing on the 030, so no
    // 32 KB branch limit) and an assembler one, so it rides with the target.
    if (a.hasPrefix(String.withCString("-falloc="))) {
        String* v = a.substringFromByte((u32)8).lowercased();
        if (!v.equals(String.withCString("bump")) && !v.equals(String.withCString("heap"))) {
            Stdio.printf("xcc: -falloc= expects 'bump' or 'heap', got '%s'\n", v.cString());
            driverExit((i32)1); return true;
        }
        c.setAlloc(v);
        *ip = i + (u32)1; return true;
    }
    if (a.hasPrefix(String.withCString("-fmalloc="))) {
        String* v = a.substringFromByte((u32)9).lowercased();
        if (!v.equals(String.withCString("system")) && !v.equals(String.withCString("mimalloc"))) {
            Stdio.printf("xcc: -fmalloc= expects 'system' or 'mimalloc', got '%s'\n", v.cString());
            driverExit((i32)1); return true;
        }
        c.setHostMalloc(v);
        *ip = i + (u32)1; return true;
    }
    // Atomic ARC is a back-end decision, but the race-free static-init once
    // that rides the same switch is decided in LOWERING — so the front end is
    // told as well, and the back ends read it from there.
    // The x86-64 vector level (SIMD step 1, S1). Checked against the target in
    // checkCapabilities, once the whole line is read.
    if (a.equals(String.withCString("-dynamic"))) {
        c.setDynamic();
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-static"))) {
        c.setStatic();
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-fno-matmul"))) {
        c.setNoMatmul();
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-mavx2"))) {
        c.setSimd(String.withCString("avx2"), a);
        *ip = i + (u32)1; return true;
    }
    // AVX-512 F + DQ + BW + VL, the level xcc's 512-bit code needs.
    if (a.equals(String.withCString("-mavx512")) || a.equals(String.withCString("-mavx512f"))) {
        c.setSimd(String.withCString("avx512"), a);
        *ip = i + (u32)1; return true;
    }
    if (a.hasPrefix(String.withCString("-msimd="))) {
        String* v = a.substringFromByte((u32)7);
        if (!v.equals(String.withCString("base")) && !v.equals(String.withCString("avx2"))
            && !v.equals(String.withCString("avx512")) && !v.equals(String.withCString("auto"))) {
            Stdio.printf("xcc: -msimd= expects 'base', 'avx2', 'avx512' or 'auto', got '%s'\n", v.cString());
            driverExit((i32)1); return true;
        }
        c.setSimd(v, a);
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-mnative"))) {
        String* lvl = hostSimdLevel();
        if (lvl == (String*)0) {
            Stdio.printf("xcc: -mnative: this machine is not x86-64, so it has no vector "
                         "level to read; name one (-mavx2, -msimd=base)\n");
            driverExit((i32)1); return true;
        }
        c.setSimd(lvl, a);
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-fthread-safe-arc"))) {
        d.fe().setThreadSafeArc((i32)1); c.setThreadFlag(true);
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-fno-thread-safe-arc"))) {
        d.fe().setThreadSafeArc((i32)0); c.setThreadFlag(true);
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-fpar-kernels=all"))) {
        d.fe().setParKernelsAll(true);
        *ip = i + (u32)1; return true;
    }
    if (a.hasPrefix(String.withCString("--par-style="))) {
        // auto (the default): loops become par blocks, each choosing its
        // devices at run time; threads: the CPU's threads only; gpu: the GPU
        // first; cpu: nothing is lifted (plain loops stay serial, vectorised
        // as ever). As the reference.
        String* v = a.substringFromByte((u32)12);
        if (v.equals(String.withCString("auto"))) { d.fe().setParAuto(true); d.fe().setParDeviceDefault((u32)0); }
        else if (v.equals(String.withCString("threads"))) { d.fe().setParAuto(true); d.fe().setParDeviceDefault((u32)1); }
        else if (v.equals(String.withCString("gpu"))) { d.fe().setParAuto(true); d.fe().setParDeviceDefault((u32)2); }
        else if (v.equals(String.withCString("cpu"))) { d.fe().setParAuto(false); d.fe().setParDeviceDefault((u32)0); }
        else {
            Stdio.printf("xcc: --par-style= expects auto, threads, gpu or cpu, got '%s'\n", v.cString());
            driverExit((i32)1);
            return false;
        }
        *ip = i + (u32)1; return true;
    }
    if (a.hasPrefix(String.withCString("-fgoal="))) {
        String* v = a.substringFromByte((u32)7).lowercased();
        if (!v.equals(String.withCString("speed")) && !v.equals(String.withCString("accuracy"))) {
            Stdio.printf("xcc: -fgoal= expects 'speed' or 'accuracy', got '%s'\n", v.cString());
            driverExit((i32)1);
            return false;
        }
        d.fe().setGoalDefault(v.equals(String.withCString("speed")) ? (u32)1 : (u32)2);
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-Wpar-auto"))) {
        d.fe().enableWarning(String.withCString("par-auto"));
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-fpic")) || a.equals(String.withCString("-fPIC"))
        || a.equals(String.withCString("-mpic"))) {
        c.setPic(true);
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-mhard-float")) || a.equals(String.withCString("-mfpu"))) {
        c.setHardFloat(true);
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-msoft-float"))) {
        c.setHardFloat(false);
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("-g"))) {
        c.setDebugInfo(true);
        *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("--needed")) && hasVal) {
        String* n = Process.argument(i + (u32)1);
        bool dup = false;
        for (u32 k = (u32)0; k < c.needed().count(); k = k + (u32)1)
            if (((String*)c.needed().get(k)).equals(n)) dup = true;
        if (!dup && n.byteLength() > (u32)0) c.needed().add((Object*)n);
        *ip = i + (u32)2; return true;
    }
    if (a.equals(String.withCString("--with-lib")) && hasVal) {
        c.addWithLib(Process.argument(i + (u32)1)); *ip = i + (u32)2; return true;
    }
    if (a.equals(String.withCString("--lib-name")) && hasVal) {
        c.setLibName(Process.argument(i + (u32)1)); *ip = i + (u32)2; return true;
    }
    if (a.equals(String.withCString("--manifest-attr")) && hasVal) {
        c.manifestAttrs().add((Object*)Process.argument(i + (u32)1)); *ip = i + (u32)2; return true;
    }
    if (a.equals(String.withCString("--with-dex")) && hasVal) {
        c.setWithDex(Process.argument(i + (u32)1)); *ip = i + (u32)2; return true;
    }
    if (a.equals(String.withCString("--no-self-host"))) {
        c.setNoSelfHost(true); *ip = i + (u32)1; return true;
    }
    if (a.equals(String.withCString("--self-host"))) {
        c.setNoSelfHost(false); *ip = i + (u32)1; return true;
    }
    return false;
}

// The capability flags against the target, once the whole line is read. A
// flag that cannot apply is refused or named, never silently dropped.
void checkCapabilities(DriverOptions* d)
{
    CapOptions* c = d.caps();
    String* arch = d.arch();
    if (c.simdFlag() != (String*)0 && !isX86_64(d) && !isWin64(d)) {
        Stdio.printf("xcc: %s: the vector level applies to -A x86_64 and -A win64 only\n",
                     c.simdFlag().cString());
        driverExit((i32)1); return;
    }
    // From 0.72 an x86-64 executable links dynamically
    // against glibc unless -static asks for the static musl link, as a C
    // compiler on Linux does; -dynamic names the default. As the reference.
    if (c.dynamicExplicit() && c.staticLink()) {
        Stdio.printf("xcc: -dynamic and -static: choose one\n");
        driverExit((i32)1); return;
    }
    if ((c.dynamicExplicit() || c.staticLink()) && !isX86_64(d)) {
        Stdio.printf("xcc: %s: the dynamic (glibc) and static (musl) links are "
                     "for -A x86_64 only\n", c.staticLink() ? "-static" : "-dynamic");
        driverExit((i32)1); return;
    }
    c.resolveDynamic(isX86_64(d));
    if (c.dynamic() && c.hostMalloc().equals(String.withCString("mimalloc"))) {
        Stdio.printf("xcc: -fmalloc=mimalloc: link with -static (the dynamic glibc "
                     "link uses glibc's malloc)\n");
        driverExit((i32)1); return;
    }
    if (c.threadFlag() && (isM68k(d) || isXt6502(d))) {
        Stdio.printf("xcc: error: -f[no-]thread-safe-arc: '%s' has no threads, so there "
                     "is no atomic reference count to choose\n", arch.cString());
        driverExit((i32)1); return;
    }
    if (c.hostMalloc().equals(String.withCString("mimalloc")) && !isX86_64(d)) {
        Stdio.printf("xcc: -fmalloc=mimalloc is only supported on -A x86_64.\n"
                     "  mimalloc ships as an x86-64 ELF object linked ahead of libc;\n"
                     "  '%s' has no build of it to link.\n", arch.cString());
        driverExit((i32)1); return;
    }
    // The allocator is chosen by the program's LINK. A library uses whatever
    // malloc the process that loads it already has, and an object is not a
    // link at all.
    if (c.hostMalloc().equals(String.withCString("mimalloc")) && (d.emitLib() || d.compileOnly())) {
        Stdio.printf("xcc: error: -fmalloc=mimalloc applies to an executable's link; "
                     "a library or object uses the allocator of the program it ends up in\n");
        driverExit((i32)1); return;
    }
    // Every live target has a free-capable heap, so `heap` is what they all
    // build with and `bump` changes nothing. Said, rather than dropped.
    if (c.alloc() != (String*)0 && c.alloc().equals(String.withCString("bump")))
        Stdio.printf("xcc: warning: -falloc=bump: every supported target uses the "
                     "free-list heap allocator; the build is unchanged\n");
    // -g: the LOWERING stamps source locations on instructions (the front
    // end), and the back end turns them into line tables, so both are told —
    // as the reference driver passes -g on to xcc-fe.
    if (c.debugInfo())
        d.fe().setDebugInfo(true);
    // The FPU flags choose code only on m68k (the 68881). arm9 code is always
    // VFP, so -mhard-float is its default and -msoft-float cannot be honoured.
    if (!isM68k(d)) {
        if (c.softFloat())
            Stdio.printf("xcc: warning: -msoft-float has no effect on '%s'; floating "
                         "point uses the hardware\n", arch.cString());
        else if (c.hardFloat() && !isArm9(d))
            Stdio.printf("xcc: warning: -mhard-float has no effect on '%s'\n", arch.cString());
    }
    // --no-self-host hands the link to a vendor toolchain where one exists:
    // clang on arm64 macOS, the NDK for android, arm-none-eabi-gcc for arm9.
    // An object (-c) is written in-house either way, and an android library
    // has no vendor path to switch to.
    if (c.noSelfHost() && !d.compileOnly() && !d.keepAsm() && !d.emitIfaceOnly()) {
        if (isM68k(d) || isXt6502(d) || isWasm(d)) {
            Stdio.printf("xcc: warning: --no-self-host has no effect on '%s': its "
                         "image is always written in-house\n", arch.cString());
        } else if (isX86_64(d) || isWin64(d)) {
            Stdio.printf("xcc: error: --no-self-host: '%s' has no vendor-toolchain "
                         "link; its runtime is linked in-house only\n", arch.cString());
            driverExit((i32)1); return;
        } else if (isIos(d)) {
            Stdio.printf("xcc: error: --no-self-host: '%s' links in-house only\n", arch.cString());
            driverExit((i32)1); return;
        } else if (d.emitLib() && !isAndroid(d) && !isArm9(d)) {
            Stdio.printf("xcc: error: --no-self-host: an arm64 library links in-house only\n");
            driverExit((i32)1); return;
        }
#if OS_windows
        Stdio.printf("xcc: error: --no-self-host runs a POSIX shell toolchain and is not "
                     "available on a Windows host\n");
        driverExit((i32)1); return;
#endif
    }
    if (c.needed().count() > (u32)0 && !isAndroid(d)) {
        Stdio.printf("xcc: error: --needed names an Android DT_NEEDED entry and needs -A android\n");
        driverExit((i32)1); return;
    }
    if ((c.withLibs().count() > (u32)0 || c.libName() != (String*)0 || c.withDex() != (String*)0
         || c.manifestAttrs().count() > (u32)0)
        && !(isAndroid(d) && d.emitApk())) {
        Stdio.printf("xcc: error: --with-lib, --lib-name, --with-dex and --manifest-attr package an APK "
                     "and need -A android --emit-apk\n");
        driverExit((i32)1); return;
    }
}

// ── the option table ──────────────────────────────────────────────────────
//
// The options parseDriverArgs reads after parseCapabilityFlag, one row each,
// in the order they are tested: the first row that matches an argument takes
// it, so where two rows can match (-O and -O<n>, -ll and -l<name>, -D and
// -D<name>, -L and -L<dir>), the earlier row wins. A row's kind says how its
// names match:
//   Exact         the argument is one of the names
//   ExactValue    the argument is one of the names and a value follows it;
//                 with no value the row does not match and later rows are tried
//   Prefix        the argument starts with the name
//   PrefixLonger  the argument starts with the name and is longer than minLen
//   Custom        driverOptionCustom decides (spellings with different rules)
// The first name is the one messages use. applyOption does what each row's
// option means and returns how many arguments it took (#337). A row marked
// inert does nothing (its value is still checked): once applyOption has
// accepted it, inertFlag says it will be removed, naming it as the mark says.
enum DriverOptionKind = {
    doptkExact = 1,
    doptkExactValue,
    doptkPrefix,
    doptkPrefixLonger,
    doptkCustom
};

// How an inert row's warning names it: not inert; the argument as given; the
// row's first name; the argument up to its `=`.
enum DriverOptionInert = {
    doptiNone = 0,
    doptiArgument,
    doptiName,
    doptiBeforeEq
};

enum DriverOptionId = {
    doptOutput = 1,
    doptArch,
    doptHome,
    doptInclude,
    doptDefine,
    doptDefineJoined,
    doptXlinker,
    doptListLayouts,
    doptLib,
    doptWl,
    doptLibPath,
    doptLibPathJoined,
    doptKeepAsm,
    doptEmitApk,
    doptSignKey,
    doptBoundsCheck,
    doptBoundsCheckLight,
    doptStd,
    doptFpContract,
    doptNoBoundsCheck,
    doptMigrate,
    doptQuiet,
    doptLoopUnroll,
    doptHelp,
    doptPrintTarget,
    doptPrint3pDir,
    doptVersion,
    doptMemoryModel,
    doptVerbose,
    doptOptBare,
    doptOptLevel,
    doptAnalyze,
    doptWarnOff,
    doptBundle,
    doptProperty,
    doptBundleName,
    doptBundleVersion,
    doptResources,
    doptTrust,
    doptNoSign,
    doptSignBundle,
    doptBundleLib,
    doptRotateFrom,
    doptBundleKey,
    doptPublisher,
    doptPublisherDomain,
    doptEmitRuntime,
    doptEmitRuntimeSupport,
    doptNoRuntimeLib,
    doptNoXcArgs,
    doptEmitLib,
    doptLto,
    doptSign,
    doptSignEntitlements,
    doptCompileOnly,
    doptEmitIface,
    doptPreprocessed,
    doptEmitIR,
    doptEmitIROpt,
    doptAssembleOnly,
    doptDumpLayout,
    doptDceTrace,
    doptLeafInline,
    doptArchOptions,
    doptLinkLibs,
    doptArc,
    doptAutoCloak,
    doptStackSize,
    doptSelfHost,
    doptNewIr,
    doptWarnAll,
    doptQuitStyle,
    doptXtcStack,
    doptMinBanked,
    doptDumpPlacement,
    doptDumpUsage,
    doptCPair
};

class DriverOption
{
    u32    _id;
    u32    _kind;
    Array* _names;   // String*: the spellings; the first is the name messages use
    u32    _minLen;  // PrefixLonger: the argument must be longer than this
    u32    _inert;   // DriverOptionInert: a flag that does nothing, and how it is named

    void init(void)
    {
        _id = (u32)0;
        _kind = (u32)0;
        _names = (Array*)0;
        _minLen = (u32)0;
        _inert = (u32)doptiNone;
    }

    u32 id(void)         { return _id; }
    u32 kind(void)       { return _kind; }
    Array* names(void)   { return _names; }
    String* name(void)   { return (String*)_names.get((u32)0); }
    u32 minLen(void)     { return _minLen; }
    u32 inert(void)      { return _inert; }
}

Array* gDriverOptions;

void driverOption(u32 id, u32 kind, string names, u32 minLen)
{
    DriverOption* r = new DriverOption();
    r._id = id;
    r._kind = kind;
    r._names = String.withCString(names).splitOnByte((u8)' ');
    r._minLen = minLen;
    gDriverOptions.add((Object*)r);
}

// The row just added does nothing; its warning names it as `how` says.
void inertOption(u32 how)
{
    DriverOption* r = (DriverOption*)gDriverOptions.get(gDriverOptions.count() - (u32)1);
    r._inert = how;
}

// The rows, in the order they are tested.
Array* driverOptions(void)
{
    if (gDriverOptions != (Array*)0)
        return gDriverOptions;
    gDriverOptions = new Array();
    driverOption((u32)doptOutput, (u32)doptkExactValue, "-o --output", (u32)0);
    driverOption((u32)doptArch, (u32)doptkExactValue, "-A --arch", (u32)0);
    driverOption((u32)doptHome, (u32)doptkExactValue, "-H --xcc-home --xtc-home", (u32)0);
    driverOption((u32)doptInclude, (u32)doptkExactValue, "-I --include", (u32)0);
    driverOption((u32)doptDefine, (u32)doptkExactValue, "-D", (u32)0);
    driverOption((u32)doptDefineJoined, (u32)doptkPrefixLonger, "-D", (u32)2);
    driverOption((u32)doptXlinker, (u32)doptkExactValue, "-Xlinker -framework", (u32)0);
    driverOption((u32)doptListLayouts, (u32)doptkExact, "-ll --list-layouts", (u32)0);
    driverOption((u32)doptLib, (u32)doptkPrefixLonger, "-l", (u32)2);
    driverOption((u32)doptWl, (u32)doptkPrefix, "-Wl,", (u32)0);
    driverOption((u32)doptLibPath, (u32)doptkExactValue, "-L --library-path", (u32)0);
    driverOption((u32)doptLibPathJoined, (u32)doptkPrefixLonger, "-L", (u32)2);
    driverOption((u32)doptKeepAsm, (u32)doptkExact, "-S", (u32)0);
    driverOption((u32)doptEmitApk, (u32)doptkExact, "--emit-apk", (u32)0);
    driverOption((u32)doptSignKey, (u32)doptkExactValue, "--sign-key", (u32)0);
    driverOption((u32)doptBoundsCheck, (u32)doptkExact, "-fbounds-check", (u32)0);
    driverOption((u32)doptBoundsCheckLight, (u32)doptkExact, "-fbounds-check=light", (u32)0);
    driverOption((u32)doptStd, (u32)doptkPrefixLonger, "-std=", (u32)5);
    driverOption((u32)doptFpContract, (u32)doptkPrefix, "-ffp-contract=", (u32)0);
    driverOption((u32)doptNoBoundsCheck, (u32)doptkExact, "-fno-bounds-check", (u32)0);
    driverOption((u32)doptMigrate, (u32)doptkPrefix, "--migrate=", (u32)0);
    driverOption((u32)doptQuiet, (u32)doptkExact, "-q --quiet", (u32)0);
    driverOption((u32)doptLoopUnroll, (u32)doptkExactValue, "-Flu --fn-loop-unroll", (u32)0);
    driverOption((u32)doptHelp, (u32)doptkExact, "-h --help", (u32)0);
    driverOption((u32)doptPrintTarget, (u32)doptkExact, "--print-target", (u32)0);
    driverOption((u32)doptPrint3pDir, (u32)doptkExact, "--print-3p-dir", (u32)0);
    driverOption((u32)doptVersion, (u32)doptkExact, "-v --version", (u32)0);
    driverOption((u32)doptMemoryModel, (u32)doptkExactValue, "-m --memory-model", (u32)0);
    driverOption((u32)doptVerbose, (u32)doptkExact, "-V --verbose", (u32)0);
    driverOption((u32)doptOptBare, (u32)doptkExact, "-O", (u32)0);
    driverOption((u32)doptOptLevel, (u32)doptkPrefix, "-O", (u32)0);
    driverOption((u32)doptAnalyze, (u32)doptkExact, "-Wanalyze", (u32)0);
    driverOption((u32)doptWarnOff, (u32)doptkPrefix, "-Wno-", (u32)0);
    driverOption((u32)doptBundle, (u32)doptkExactValue, "--bundle", (u32)0);
    driverOption((u32)doptProperty, (u32)doptkExactValue, "--property --setting", (u32)0);
    driverOption((u32)doptBundleName, (u32)doptkExactValue, "--bundle-name", (u32)0);
    driverOption((u32)doptBundleVersion, (u32)doptkExactValue, "--bundle-version", (u32)0);
    driverOption((u32)doptResources, (u32)doptkExactValue, "--resources", (u32)0);
    driverOption((u32)doptTrust, (u32)doptkExactValue, "--trust", (u32)0);
    driverOption((u32)doptNoSign, (u32)doptkExact, "--no-sign", (u32)0);
    driverOption((u32)doptSignBundle, (u32)doptkExactValue, "--sign-bundle", (u32)0);
    driverOption((u32)doptBundleLib, (u32)doptkExactValue, "--bundle-lib", (u32)0);
    driverOption((u32)doptRotateFrom, (u32)doptkExactValue, "--rotate-from", (u32)0);
    driverOption((u32)doptBundleKey, (u32)doptkExactValue, "--bundle-key", (u32)0);
    driverOption((u32)doptPublisher, (u32)doptkExactValue, "--publisher", (u32)0);
    driverOption((u32)doptPublisherDomain, (u32)doptkExactValue, "--publisher-domain", (u32)0);
    driverOption((u32)doptEmitRuntime, (u32)doptkExact, "--emit-runtime", (u32)0);
    driverOption((u32)doptEmitRuntimeSupport, (u32)doptkExact, "--emit-runtime-support", (u32)0);
    driverOption((u32)doptNoRuntimeLib, (u32)doptkExact, "--no-runtime-lib", (u32)0);
    driverOption((u32)doptNoXcArgs, (u32)doptkExact, "-fno-xc-args", (u32)0);
    driverOption((u32)doptEmitLib, (u32)doptkExact, "--emit-lib", (u32)0);
    driverOption((u32)doptLto, (u32)doptkExact, "-flto", (u32)0);
    driverOption((u32)doptSign, (u32)doptkExactValue, "--sign", (u32)0);
    driverOption((u32)doptSignEntitlements, (u32)doptkExactValue, "--sign-entitlements", (u32)0);
    driverOption((u32)doptCompileOnly, (u32)doptkExact, "-c", (u32)0);
    driverOption((u32)doptEmitIface, (u32)doptkExact, "--emit-iface", (u32)0);
    driverOption((u32)doptPreprocessed, (u32)doptkExactValue, "-E --preprocessed", (u32)0);
    driverOption((u32)doptEmitIR, (u32)doptkExact, "--emit-ir", (u32)0);
    driverOption((u32)doptEmitIROpt, (u32)doptkExact, "--emit-ir-opt", (u32)0);
    driverOption((u32)doptAssembleOnly, (u32)doptkExact, "-a --assemble-only --emit-asm-from-ir", (u32)0);
    driverOption((u32)doptDumpLayout, (u32)doptkExact, "-dl --dump-layout", (u32)0);
    driverOption((u32)doptDceTrace, (u32)doptkExact, "-fdce-trace", (u32)0);
    driverOption((u32)doptLeafInline, (u32)doptkExactValue, "-Fli --fn-leaf-inline", (u32)0);
    driverOption((u32)doptArchOptions, (u32)doptkPrefix, "-x-", (u32)0);
    driverOption((u32)doptLinkLibs, (u32)doptkExact, "--link-libs", (u32)0);
    driverOption((u32)doptArc, (u32)doptkCustom, "-farc -farc=", (u32)0);
    inertOption((u32)doptiArgument);    // ARC is always on
    driverOption((u32)doptAutoCloak, (u32)doptkPrefix, "-fauto-cloak=", (u32)0);
    inertOption((u32)doptiName);
    driverOption((u32)doptStackSize, (u32)doptkCustom, "-ss --stack-size -ss= --stack-size=", (u32)0);
    inertOption((u32)doptiBeforeEq);
    driverOption((u32)doptSelfHost, (u32)doptkExact, "--self-host", (u32)0);
    driverOption((u32)doptNewIr, (u32)doptkExact, "-fnew-ir --with-ir", (u32)0);
    inertOption((u32)doptiArgument);
    driverOption((u32)doptWarnAll, (u32)doptkExact, "-W", (u32)0);
    inertOption((u32)doptiArgument);
    driverOption((u32)doptQuitStyle, (u32)doptkExactValue, "-Q --quit-style", (u32)0);
    driverOption((u32)doptXtcStack, (u32)doptkExact, "--xtc-stack", (u32)0);
    driverOption((u32)doptMinBanked, (u32)doptkExactValue, "-Fmb --fn-min-banked", (u32)0);
    driverOption((u32)doptDumpPlacement, (u32)doptkExact, "-dp --dump-placement", (u32)0);
    driverOption((u32)doptDumpUsage, (u32)doptkExact, "-du --dump-usage", (u32)0);
    driverOption((u32)doptCPair, (u32)doptkExact, "--c-pair", (u32)0);
    return gDriverOptions;
}

// The Custom rows' tests, as the branches they replace wrote them.
bool driverOptionCustom(u32 id, String* a)
{
    if (id == (u32)doptArc)
        return a.equals(String.withCString("-farc")) || a.hasPrefix(String.withCString("-farc="));
    if (id == (u32)doptStackSize)
        return a.equals(String.withCString("-ss")) || a.equals(String.withCString("--stack-size"))
               || a.hasPrefix(String.withCString("-ss=")) || a.hasPrefix(String.withCString("--stack-size="));
    return false;
}

bool driverOptionMatches(DriverOption* r, String* a, u32 i, u32 argc)
{
    u32 kind = r.kind();
    if (kind == (u32)doptkCustom)
        return driverOptionCustom(r.id(), a);
    Array* ns = r.names();
    for (u32 k = (u32)0; k < ns.count(); k = k + (u32)1) {
        String* n = (String*)ns.get(k);
        if (kind == (u32)doptkExact && a.equals(n))
            return true;
        if (kind == (u32)doptkExactValue && a.equals(n) && i + (u32)1 < argc)
            return true;
        if (kind == (u32)doptkPrefix && a.hasPrefix(n))
            return true;
        if (kind == (u32)doptkPrefixLonger && a.hasPrefix(n) && a.byteLength() > r.minLen())
            return true;
    }
    return false;
}

// The first row that takes argument i, or 0.
DriverOption* driverOptionFor(String* a, u32 i, u32 argc)
{
    Array* rows = driverOptions();
    for (u32 k = (u32)0; k < rows.count(); k = k + (u32)1) {
        DriverOption* r = (DriverOption*)rows.get(k);
        if (driverOptionMatches(r, a, i, argc))
            return r;
    }
    return (DriverOption*)0;
}

// What row `id` means, for argument i (`a`). Returns how many arguments it
// took: 1, or 2 with the value that followed. A row that fails exits.
u32 applyOption(DriverOptions* d, u32 id, String* a, u32 i, u32 argc)
{
    FeOptions* o = d.fe();
    if (id == (u32)doptOutput) {
        String* out = Process.argument(i + (u32)1);
        o.setOutput(out);
        // The output EXTENSION decides the format, as it does in the
        // reference: `-o x.s` means ASSEMBLY, and stops before the link.
        // Without this the driver linked an executable and CALLED it x.s,
        // so anything asking this compiler for assembly — a build system,
        // a differential, the staged self-build — silently got a Mach-O
        // with an .s on the end.
        if (out.hasSuffix(String.withCString(".s"))
            || out.hasSuffix(String.withCString(".asm")))
            d.setKeepAsm(true);
        return (u32)2;
    }
    if (id == (u32)doptArch) {
        // -A names a row of the target table; the driver still tests the
        // row's legacy arch string. A token no row has is kept as typed
        // and refused later, with the list of targets.
        String* tok = Process.argument(i + (u32)1);
        TargetRow* row = Targets.find(tok);
        d.setTargetRow(row);
        d.setArch(row != (TargetRow*)0 ? row.legacy() : tok);
        if (row != (TargetRow*)0 && row.cpuVariant() != (u32)0)
            d.caps().setM68kCpu(row.cpuVariant());
        // The musl row is -A x86_64 -static. Kept apart from -static and
        // merged after parsing, so a later -A replaces it: it used to
        // stick, and `-A x86_64-linux-musl -A arm64` was refused for a
        // -static nobody wrote.
        d.caps().setRowStatic(row != (TargetRow*)0 && row.name().equals(String.withCString("x86_64-linux-musl")));
        d.setSawArch(true);
        return (u32)2;
    }
    // `--xcc-home` is the documented long form; `--xtc-home` is the older
    // spelling. The value is cleaned as $XCC_HOME is — a Windows shell
    // keeps the quotes in `-H "C:\path with spaces"`.
    if (id == (u32)doptHome) {
        o.setHome(sanitiseEnvPath(Process.argument(i + (u32)1))); return (u32)2;
    }
    if (id == (u32)doptInclude) {
        o.incs().add((Object*)Process.argument(i + (u32)1)); return (u32)2;
    }
    if (id == (u32)doptDefine) {
        o.defs().add((Object*)Process.argument(i + (u32)1)); return (u32)2;
    }
    // `-DNAME` / `-DNAME=VALUE`, joined, as cc takes it.
    if (id == (u32)doptDefineJoined) {
        o.defs().add((Object*)a.substringFromByte((u32)2)); return (u32)1;
    }
    // ── linker passthrough ───────────────────────────────────────
    //
    // This driver LINKS IN-HOUSE, so there is no clang to forward these to
    // — they are honoured rather than passed on. `-Xlinker <lib.dylib>` is
    // how every UXKit driver gate names its platform shim, and rejecting
    // the flag made six back ends unbuildable (uxkit bug 034-E).
    if (id == (u32)doptXlinker) {
        bool isFw = a.equals(String.withCString("-framework"));
        String* v = Process.argument(i + (u32)1);
        if (isFw) d.frameworks().add((Object*)v);
        else      d.addLinkToken(v);
        return (u32)2;
    }
    // `-ll` lists the layouts. It has to be tested before `-l<name>`, which
    // would otherwise read it as a library called `l`.
    if (id == (u32)doptListLayouts) {
        d.setListLayouts(true); return (u32)1;
    }
    if (id == (u32)doptLib) {
        d.linkInputs().add((Object*)a);              // resolved on the -L path
        return (u32)1;
    }
    if (id == (u32)doptWl) {
        // `-Wl,a,b,c` is `-Xlinker a -Xlinker b -Xlinker c`. A FILE the
        // linker takes — an object, an archive, a dylib or a stub — is a
        // link input (bug 139: the harness names its objects this way, as
        // clang users do); `-rpath <dir>` is honoured on a Mach-O link; any
        // other flag is named at link time and skipped (addLinkToken).
        Array* toks = a.substringFromByte((u32)4).splitOnByte((u8)',');
        for (u32 k = (u32)0; k < toks.count(); k = k + (u32)1)
            d.addLinkToken((String*)toks.get(k));
        return (u32)1;
    }
    if (id == (u32)doptLibPath) {
        o.libs().add((Object*)Process.argument(i + (u32)1)); return (u32)2;
    }
    // `-L<dir>`, joined.
    if (id == (u32)doptLibPathJoined) {
        o.libs().add((Object*)a.substringFromByte((u32)2)); return (u32)1;
    }
    if (id == (u32)doptKeepAsm) { d.setKeepAsm(true); return (u32)1; }
    if (id == (u32)doptEmitApk) { d.setEmitApk(true); return (u32)1; }
    if (id == (u32)doptSignKey) {
        d.setSignKey(Process.argument(i + (u32)1)); return (u32)2;
    }
    // `--migrate=<base>:<to>` — compile as if the library were still
    // <base>: a member marked since("V") with V newer than <base> vanishes
    // from lookup, so a call whose MEANING changed between the two fails
    // loudly instead of quietly resolving to the new one. Joined, like -O.
    // -fbounds-check: a checked build. NATIVE ONLY, and a hard error
    // elsewhere rather than a flag that quietly does nothing — the checked
    // runtime is arm64 assembly and only the arm64 back end emits the
    // parameter map it walks.
    if (id == (u32)doptBoundsCheck) {
        o.setBoundsCheck(true); o.setBoundsReport(true); return (u32)1;
    }
    // -fbounds-check=light: the checks without the debug build's frames
    // and backtrace — a failure names the site and the bounds and stops.
    if (id == (u32)doptBoundsCheckLight) {
        o.setBoundsCheck(true); o.setBoundsReport(false); return (u32)1;
    }
    // -std=<standard>: for a C or C++ file, handed to clang (whose own
    // default is otherwise used; Apple's clang++ defaults to C++14).
    if (id == (u32)doptStd) {
        String* v = a.substringFromByte((u32)5);
        for (u32 k = 0; k < v.byteLength(); k = k + 1) {
            u8 c = v.byteAt(k);
            if (!((c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'+' || c == (u8)':')) {
                Stdio.printf("xcc: error: -std= takes a language standard such as c11 or c++17\n");
                driverExit((i32)1);
            }
        }
        cPathSetStd(v); return (u32)1;
    }
    // -ffp-contract=fast|on|off: for a C file, handed to clang. `on` (clang's
    // default) fuses within an expression, `fast` across statements too,
    // `off` not at all; -fgoal=accuracy means off (owner, 2026-11-09).
    if (id == (u32)doptFpContract) {
        String* v = a.substringFromByte((u32)14);
        if (!v.equals(String.withCString("fast")) && !v.equals(String.withCString("on")) && !v.equals(String.withCString("off"))) {
            Stdio.printf("xcc: error: -ffp-contract= takes fast, on or off\n");
            driverExit((i32)1);
        }
        cPathSetFpContract(v); return (u32)1;
    }
    // -fno-bounds-check: no checks, the default (benchmarks say it anyway).
    if (id == (u32)doptNoBoundsCheck) {
        o.setBoundsCheck(false); o.setBoundsReport(false); return (u32)1;
    }
    if (id == (u32)doptMigrate) {
        o.setMigrate(a.substringFromByte((u32)10));
        return (u32)1;
    }
    // `-q` — suppress the informational lines. A build system wants the
    // errors and nothing else.
    if (id == (u32)doptQuiet) {
        d.setQuiet(true); return (u32)1;
    }
    // `-Flu <n>` — auto-unroll counted loops with trip count <= n. The
    // per-target default stands unless this says otherwise.
    if (id == (u32)doptLoopUnroll) {
        i32 lu = parseCount(Process.argument(i + (u32)1));
        if (lu < (i32)0) {
            // Not a number. Refused rather than quietly left at the
            // target's default: this driver's whole argument policy is
            // that an option it cannot honour is an error, and `-Flu wat`
            // silently compiling something other than what was asked for
            // is the failure that policy exists to prevent.
            Stdio.printf("xcc: error: -Flu takes a decimal trip count, got '%s'\n",
                         Process.argument(i + (u32)1).cString());
            driverExit((i32)1);
            return (u32)0;
        }
        d.setUnroll(lu);
        return (u32)2;
    }
    if (id == (u32)doptHelp) {
        usage();
        driverExit((i32)0);
        return (u32)0;
    }
    if (id == (u32)doptPrintTarget) {
        d.setPrintTarget(true);
        return (u32)1;
    }
    if (id == (u32)doptPrint3pDir) {
        d.setPrint3pDir(true);
        return (u32)1;
    }
    if (id == (u32)doptVersion) {
        // XCC_VERSION comes from the Makefile, which reads the VERSION
        // file — the same source the Objective-C driver uses. It was a
        // literal "0.6" here, which is one fact in two places: bumping
        // VERSION moved the bootstrap compiler to 0.61 and left the
        // compiler that actually SHIPS reporting 0.6.
#ifndef XCC_VERSION
#define XCC_VERSION "unversioned"
#endif
        Stdio.printf("xcc %s (xc, self-hosted)\n", XCC_VERSION);
        driverExit((i32)0);
        return (u32)0;
    }
    // `-m <layout>` picks a memory layout, and with it the 6502 target. A
    // handful of names are PLATFORMS with no layout and select their
    // target instead. Anything else is a `.lnk` — a file path, a path
    // without its `.lnk`, `<platform>/<layout>`, or a bare layout name
    // searched for under every platform — and is resolved after the parse,
    // when -H and the environment have both been seen.
    if (id == (u32)doptMemoryModel) {
        String* layout = Process.argument(i + (u32)1);
        String* plat = platformLayoutArch(layout);
        if (plat != (String*)0) {
            // `atarist` is the m68k PLATFORM, so it leaves an m68k CPU
            // already chosen by -A alone.
            if (!plat.equals(String.withCString("m68k")) || !isM68k(d)) d.setArch(plat);
            d.setLayoutSpec((String*)0);
        } else {
            d.setArch(String.withCString("xt6502"));
            d.setLayoutSpec(layout);
        }
        return (u32)2;
    }
    if (id == (u32)doptVerbose) {
        o.setVerbose(true); return (u32)1;
    }
    // `-O3`, joined — NOT `-O 3`. Both spellings used to be accepted in the
    // sense that the second was SILENTLY IGNORED: `-O 0` left the driver at
    // its -O3 default and compiled the wrong thing without a word, which is
    // exactly the failure this compiler refuses everywhere else.
    // A bare `-O` is `-O1`, as cc reads it.
    if (id == (u32)doptOptBare) { d.setOpt((u32)1); return (u32)1; }
    // -O0 to -O3 and nothing else: -Os, -Oz, -Og and -O9 are errors, not
    // levels computed from whatever byte follows the O.
    if (id == (u32)doptOptLevel) {
        if (a.byteLength() == (u32)3 && a.byteAt((u32)2) >= (u8)'0' && a.byteAt((u32)2) <= (u8)'3') {
            d.setOpt((u32)(a.byteAt((u32)2) - (u8)'0')); return (u32)1;
        }
        Stdio.error(String.withFormat("xcc: error: unsupported optimisation level '%s' (use -O0, -O1, -O2 or -O3)\n", a.cString()));
        driverExit((i32)1);
        return (u32)0;
    }
    // -Wanalyze: the static analyser. Off by default — an unknown
    // false-positive rate must not destabilise the corpus.
    if (id == (u32)doptAnalyze) {
        o.setAnalyze(true); return (u32)1;
    }
    // -Wno-<category>. The port rejected every one of these as an
    // unrecognised OPTION, so `xcc -Wno-comment` failed the build outright
    // while the reference suppressed and carried on — a user following the
    // documented advice got a hard error from the shipped compiler. An
    // unknown category is a warning, not an error: mistyping a suppression
    // must not stop a compile, and the known names are listed, as the
    // reference does.
    if (id == (u32)doptWarnOff) {
        String* cat = a.substringBytes((u32)5, a.byteLength() - (u32)5);
        if (!isWarningCategory(cat)) {
            Stdio.printf("xcc: warning: unknown warning category '%s' — known: %s\n",
                         cat.cString(), warningCategoryNames().cString());
        } else {
            o.suppressWarning(cat);
        }
        return (u32)1;
    }
    // --bundle <dir> and its companions: a library, laid out and signed.
    if (id == (u32)doptBundle) {
        d._bundleDir = Process.argument(i + (u32)1);
        d.setEmitLib(true);
        o.setEmitIface(true);
        o.setLibraryBuild(true);
        return (u32)2;
    }
    // --property k=v / --setting k=v: the bundle's developer properties.
    if (id == (u32)doptProperty) {
        String* kv = Process.argument(i + (u32)1);
        u32 eq = kv.indexOfByte((u8)'=');
        if (eq == String.notFound() || eq == (u32)0) {
            Stdio.printf("xcc: error: %s wants key=value, not '%s'\n", a.cString(), kv.cString());
            driverExit((i32)1);
        }
        bool ro = a.equals(String.withCString("--property"));
        if (ro && d._bundleReadonly == (Map*)0) d._bundleReadonly = new Map();
        if (!ro && d._bundleWriteable == (Map*)0) d._bundleWriteable = new Map();
        (ro ? d._bundleReadonly : d._bundleWriteable).set((Hashable*)kv.substringBytes((u32)0, eq),
                                                           (Object*)kv.substringFromByte(eq + (u32)1));
        return (u32)2;
    }
    if (id == (u32)doptBundleName) {
        d._bundleName = Process.argument(i + (u32)1); return (u32)2;
    }
    if (id == (u32)doptBundleVersion) {
        d._bundleVersion = Process.argument(i + (u32)1); return (u32)2;
    }
    if (id == (u32)doptResources) {
        d._bundleResources = Process.argument(i + (u32)1); return (u32)2;
    }
    // --trust <key.pub>: a curated program, which loads plugins only from
    // the publishers it names (bundles-and-plugins.md §2a); repeatable.
    if (id == (u32)doptTrust) {
        String* f = Process.argument(i + (u32)1);
        String* t = Files.readText(f);
        if (t != (String*)0)
            while (t.byteLength() > (u32)0 && (t.byteAt(t.byteLength() - (u32)1) == (u8)10
                                               || t.byteAt(t.byteLength() - (u32)1) == (u8)13
                                               || t.byteAt(t.byteLength() - (u32)1) == (u8)' '))
                t = t.substringBytes((u32)0, t.byteLength() - (u32)1);
        Data* pk = t == (String*)0 ? (Data*)0 : BundleSign._unhex(t, (u32)32);
        if (pk == (Data*)0) {
            Stdio.printf("xcc: error: --trust %s: not a publisher's public key (64 hex digits, as xcc --bundle writes beside its key)\n",
                         f.cString());
            driverExit((i32)1);
        }
        if (d._trusted == (String*)0) d._trusted = new String();
        else d._trusted.appendByte((u8)' ');
        d._trusted.append(Sha256.hex(pk.bytes(), (u32)32));
        return (u32)2;
    }
    if (id == (u32)doptNoSign) {
        d._noSign = true; return (u32)1;
    }
    if (id == (u32)doptSignBundle) {
        d._signBundle = Process.argument(i + (u32)1); return (u32)2;
    }
    if (id == (u32)doptBundleLib) {
        if (d._bundleLibs == (Array*)0) d._bundleLibs = new Array();
        d._bundleLibs.add((Object*)Process.argument(i + (u32)1));
        return (u32)2;
    }
    if (id == (u32)doptRotateFrom) {
        d._rotateFrom = Process.argument(i + (u32)1); return (u32)2;
    }
    if (id == (u32)doptBundleKey) {
        d._bundleKey = Process.argument(i + (u32)1); return (u32)2;
    }
    if (id == (u32)doptPublisher) {
        d._publisher = Process.argument(i + (u32)1); return (u32)2;
    }
    if (id == (u32)doptPublisherDomain) {
        d._publisherDomain = Process.argument(i + (u32)1); return (u32)2;
    }
    // --emit-runtime: libRuntime (owner, 2026-11-03), a library build of
    // the runtime's files, which then export their classes; the input is
    // the runtime's root file (Par.xc).
    // --emit-runtime-support (#278): libRuntimeSupport, the runtime with every
    // standard-library file it reaches as its own, which the LLVM-IR
    // languages' programs link so they compile none of it.
    if (id == (u32)doptEmitRuntime || id == (u32)doptEmitRuntimeSupport) {
        d._emitRuntime = true;
        d._runtimeSupport = id == (u32)doptEmitRuntimeSupport;
        d.setEmitLib(true);
        o.setEmitIface(true);
        o.setLibraryBuild(true);
        o.setEmitLib(true);
        return (u32)1;
    }
    if (id == (u32)doptNoRuntimeLib) {
        d._noRuntimeLib = true; return (u32)1;
    }
    if (id == (u32)doptNoXcArgs) {
        d._noXcArgs = true; return (u32)1;
    }
    if (id == (u32)doptEmitLib) {
        d.setEmitLib(true);
        o.setEmitIface(true);        // the library carries its own interface
        o.setLibraryBuild(true);     // …and numbers every method a slot
        o.setEmitLib(true);          // …and exports its standard-library state
        return (u32)1;
    }
    // --emit-iface: the interface IS the output. The caller is asking what
    // this source DECLARES, not asking for code — an editor, or the writer
    // differential — so the front end runs and nothing after it does.
    // -c: separate compilation. The object carries the MODULE and nothing
    // else — its own code plus its per-class allocators, deliberately NOT
    // the crt or the runtime, which belong to the final link and would
    // collide the moment two objects met.
    if (id == (u32)doptLto) { d.setLto(true); return (u32)1; }
    if (id == (u32)doptSign) {
        d.setSignIdentity(Process.argument(i + (u32)1)); return (u32)2;
    }
    if (id == (u32)doptSignEntitlements) {
        d.setSignEntitlements(Process.argument(i + (u32)1)); return (u32)2;
    }
    if (id == (u32)doptCompileOnly) {
        d.setCompileOnly(true);
        o.setCompileOnly(true);   // …so `main`, if any, is the class-name root
        o.setEmitIface(true);     // the interface is a build artifact of -c
        // An object is part of a library too: the overrides may live in a
        // module that is not being compiled, so every instance method
        // earns a slot. The numbering an object publishes has to be the
        // one the final link will use.
        o.setLibraryBuild(true);
        return (u32)1;
    }
    if (id == (u32)doptEmitIface) {
        d.setEmitIfaceOnly(true);
        o.setEmitIface(true);
        return (u32)1;
    }
    // ── output modes and diagnostics ─────────────────────────────
    //
    // -E <path>: the preprocessed source, written as the compile goes on.
    if (id == (u32)doptPreprocessed) {
        o.setPreprocessedPath(Process.argument(i + (u32)1)); return (u32)2;
    }
    // The IR after lowering / after the optimiser, to stderr. Diagnostics:
    // the output file is the same with or without them.
    if (id == (u32)doptEmitIR) { d.setEmitIR(true); return (u32)1; }
    if (id == (u32)doptEmitIROpt) { d.setEmitIROpt(true); return (u32)1; }
    // -a: stop after the back end and write the assembly, which is what
    // -S means here. --emit-asm-from-ir is the old name for the same thing,
    // from when the IR pipeline ran beside another code generator.
    if (id == (u32)doptAssembleOnly) {
        if (a.equals(String.withCString("--emit-asm-from-ir")))
            Stdio.error(String.withCString("xcc: warning: --emit-asm-from-ir will be removed; it is -S\n"));
        d.setKeepAsm(true); return (u32)1;
    }
    if (id == (u32)doptDumpLayout) {
        d.setDumpLayout(true); return (u32)1;
    }
    // -fdce-trace: name each function dead-function elimination removes.
    if (id == (u32)doptDceTrace) { d.setDceTrace(true); return (u32)1; }
    // -Fli <n>: the largest callee, in IR instructions, the inliner splices.
    if (id == (u32)doptLeafInline) {
        i32 li = parseCount(Process.argument(i + (u32)1));
        if (li < (i32)0) {
            Stdio.printf("xcc: error: -Fli takes a decimal instruction count, got '%s'\n",
                         Process.argument(i + (u32)1).cString());
            driverExit((i32)1);
            return (u32)0;
        }
        d.setInlineMax(li);
        return (u32)2;
    }
    // -x-<arch>,<option>[,<option>…]: options that exist for one target
    // only. An arch with none, or an option the arch does not have, is an
    // error — a typo must not build without the feature it asked for.
    if (id == (u32)doptArchOptions) {
        Array* parts = a.substringFromByte((u32)3).splitOnByte((u8)',');
        String* xarch = parts.count() > (u32)0 ? (String*)parts.get((u32)0) : String.withCString("");
        if (parts.count() < (u32)2 || xarch.byteLength() == (u32)0) {
            Stdio.printf("xcc: error: '%s' — expected -x-<arch>,<option>[,<option>...]\n", a.cString());
            driverExit((i32)1);
            return (u32)0;
        }
        if (!xarch.equals(String.withCString("wasm32"))) {
            Stdio.printf("xcc: error: no target-specific options exist for arch '%s'\n", xarch.cString());
            driverExit((i32)1);
            return (u32)0;
        }
        for (u32 k = (u32)1; k < parts.count(); k = k + (u32)1) {
            String* xo = (String*)parts.get(k);
            if (!xo.equals(String.withCString("return-call"))) {
                Stdio.printf("xcc: error: unknown wasm32 option '%s' — known: return-call\n", xo.cString());
                driverExit((i32)1);
                return (u32)0;
            }
            d.setTailCalls(true);
        }
        return (u32)1;
    }
    // --link-libs: build a wasm32 APP in the mode that links .wasm
    // libraries — it owns memory and the table and exports what each
    // library's loader wiring needs. The driver chooses it by itself when
    // the program imports a .wasm library; this asks for it outright.
    if (id == (u32)doptLinkLibs) { d.setLinkLibs(true); return (u32)1; }
    // `-farc` retired (bug 026): ARC is always on. Still accepted so old
    // command lines build, and said out loud, because a silently ignored
    // flag is what made "verified with ARC off" mean nothing.
    if (id == (u32)doptArc) {
        return (u32)1;
    }
    // -fauto-cloak=never|auto|always: the value is checked, and the flag is
    // inert — it placed code in the cloaked region of the retired Atari
    // xl/xe layouts, and no live layout has one.
    if (id == (u32)doptAutoCloak) {
        String* v = a.substringFromByte((u32)13).lowercased();
        if (!v.equals(String.withCString("never")) && !v.equals(String.withCString("auto"))
            && !v.equals(String.withCString("always"))) {
            Stdio.printf("xcc: -fauto-cloak= expects 'never|auto|always', got '%s'\n", v.cString());
            driverExit((i32)1);
            return (u32)0;
        }
        return (u32)1;
    }
    // -ss / --stack-size <n>, also joined with `=`: the wasm32 shadow
    // stack's size; no other target has a stack this sets.
    if (id == (u32)doptStackSize) {
        u32 i0 = i;
        String* v = (String*)0;
        u32 eq = a.indexOfByte((u8)'=');
        if (eq != String.notFound()) {
            v = a.substringFromByte(eq + (u32)1);
            i = i + (u32)1;
        } else if (i + (u32)1 < argc) {
            v = Process.argument(i + (u32)1);
            i = i + (u32)2;
        } else {
            Stdio.printf("xcc: error: %s requires an argument\n", a.cString());
            driverExit((i32)1);
            return (u32)0;
        }
        i32 n = parseStackSize(v);
        if (n <= (i32)0 || n > (i32)$40000000) {
            Stdio.printf("xcc: --stack-size expects a positive integer up to 1073741824, got '%s'\n",
                         v.cString());
            driverExit((i32)1);
            return (u32)0;
        }
        d.setStackSize((u32)n);
        return i - i0;
    }
    // Accepted, and already what happens: every build links in-house, and
    // the IR pipeline is the only code generator.
    if (id == (u32)doptSelfHost) {
        return (u32)1;
    }
    if (id == (u32)doptNewIr) {
        return (u32)1;
    }
    // A bare -W: every warning category is on unless -Wno- turns it off,
    // so there is nothing more to enable.
    if (id == (u32)doptWarnAll) { return (u32)1; }
    // The xt6502 options. Each is the 6502 back end's or its startup's
    // business; on another target they change nothing.
    if (id == (u32)doptQuitStyle) {
        String* v = Process.argument(i + (u32)1).lowercased();
        if (!v.equals(String.withCString("rts")) && !v.equals(String.withCString("loop"))) {
            Stdio.printf("xcc: -Q expects 'rts' or 'loop', got '%s'\n", v.cString());
            driverExit((i32)1);
            return (u32)0;
        }
        d.setQuitLoop(v.equals(String.withCString("loop")));
        return (u32)2;
    }
    if (id == (u32)doptXtcStack) {
        d.setXtcStack(true);
        return (u32)1;
    }
    if (id == (u32)doptMinBanked) {
        i32 mb = parseCount(Process.argument(i + (u32)1));
        if (mb < (i32)0 || mb > (i32)65535) {
            Stdio.printf("xcc: error: -Fmb takes a decimal instruction count, got '%s'\n",
                         Process.argument(i + (u32)1).cString());
            driverExit((i32)1);
            return (u32)0;
        }
        d.setFnMinBanked((u32)mb);
        return (u32)2;
    }
    if (id == (u32)doptDumpPlacement) {
        d.setDumpPlacement(true);
        return (u32)1;
    }
    if (id == (u32)doptDumpUsage) {
        d.setDumpUsage(true);
        return (u32)1;
    }
    if (id == (u32)doptCPair) {
        gCSplitPair = true;
        return (u32)1;
    }
    return (u32)0;
}

// The flags that take their value as the next argument (the table's
// ExactValue rows), each with the name its message gives it: the row's first
// spelling, as the reference driver names `--output` as -o. 0 for a flag
// that takes none.
String* valueFlagName(String* a)
{
    Array* rows = driverOptions();
    for (u32 k = (u32)0; k < rows.count(); k = k + (u32)1)
        {
        DriverOption* r = (DriverOption*)rows.get(k);
        if (r.kind() != (u32)doptkExactValue)
            continue;
        Array* ns = r.names();
        for (u32 j = (u32)0; j < ns.count(); j = j + (u32)1)
            if (a.equals((String*)ns.get(j)))
                return r.name();
        }
    return (String*)0;
}

// Flags that do nothing now, still accepted so command lines keep building,
// each with one warning that it will be removed (#337); they go in a later
// release, once announced.
void inertFlag(String* a)
{
    Stdio.error(String.withFormat("xcc: warning: %s has no effect and will be removed\n", a.cString()));
}

// How an inert row's warning names argument `a` (DriverOptionInert).
String* inertSpelling(DriverOption* r, String* a)
{
    if (r.inert() == (u32)doptiName)
        return r.name();
    if (r.inert() == (u32)doptiBeforeEq) {
        u32 eq = a.indexOfByte((u8)'=');
        return eq != String.notFound() ? a.substringBytes((u32)0, eq) : a;
    }
    return a;
}

DriverOptions* parseDriverArgs(void)
{
    DriverOptions* d = new DriverOptions();
    FeOptions* o = d.fe();
    u32 argc = Process.argumentCount();
    // A program built where a remote worker is named (XC_PAR_REMOTE in the
    // environment) carries every GPU kernel form, as -fpar-kernels=all (the
    // reference explains). `none` names no remote.
    String* remote = Platform.env(String.withCString("XC_PAR_REMOTE"));
    if (remote.byteLength() > (u32)0 && !remote.equals(String.withCString("none")))
        d.fe().setParKernelsAll(true);
    u32 i = (u32)1;
    while (i < argc) {
        if (parseCapabilityFlag(d, &i, argc)) continue;
        String* a = Process.argument(i);
        // The option table, top to bottom: the first row that matches takes
        // the argument, and its value when it has one (#337).
        DriverOption* hit = driverOptionFor(a, i, argc);
        if (hit != (DriverOption*)0) {
            i = i + applyOption(d, hit.id(), a, i, argc);
            if (hit.inert() != (u32)doptiNone)
                inertFlag(inertSpelling(hit, a));
            continue;
        }
        // An unrecognised flag is an ERROR, not something to skip. A driver that
        // quietly drops an option it does not know builds something other than
        // what it was asked for and says it succeeded.
        // A flag that takes a value, given none (it was the last argument):
        // said as that, as the reference driver says it, not as unrecognised
        // (#337).
        if (i + (u32)1 >= argc && valueFlagName(a) != (String*)0) {
            String* fl = valueFlagName(a);
            if (fl.equals(String.withCString("-A")))
                Stdio.printf("xcc: error: %s requires an argument (6502 | arm64 | arm9 | m68k | x86_64 | win64 | wasm32)\n", fl.cString());
            else
                Stdio.printf("xcc: error: %s requires an argument\n", fl.cString());
            Process.exit((i32)1);
            return (DriverOptions*)0;
        }
        if (a.hasPrefix(String.withCString("-"))) {
            Stdio.printf("xcc: error: unrecognised option '%s'\n", a.cString());
            Stdio.printf("       (note: the optimisation level is joined — -O0, not -O 0)\n");
            driverExit((i32)1);
            return (DriverOptions*)0;
        }
        // `xcc a.o b.o -o prog` / `xcc a.o lib.a -o prog`: objects and archives
        // named as inputs are the LINK step of separate compilation, not
        // source (bug 138: they used to be parsed as .xc and fail on byte 1).
        // `.obj` too: the name Windows tools give a COFF object (it was read
        // as source: "unterminated block comment").
        if (a.hasSuffix(String.withCString(".o")) || a.hasSuffix(String.withCString(".a"))
            || a.hasSuffix(String.withCString(".obj"))) {
            d.objectInputs().add((Object*)a);
            i = i + (u32)1;
            continue;
        }
        // ONE source file. The reference refuses a second outright; this
        // driver used to overwrite the first silently, compile only the last,
        // and hand back a binary with no `_main` — which fails at LOAD time
        // with a dyld error and never mentions the dropped file.
        // private:docs/bugs/245.
        // Several: each is compiled as `-c` would (multiSourceBuild) and the
        // objects linked, one program.
        if (o.input() != (String*)0 && o.input().byteLength() > (u32)0) {
            if (gExtraSources == (Array*)0) gExtraSources = new Array();
            gExtraSources.add((Object*)a);
            i = i + (u32)1;
            continue;
        }
        o.setInput(a);
        i = i + (u32)1;
    }
    // The dynamic glibc link is the x86-64 default (-static: musl); settled
    // here, before the front end is told, as the reference settles it while
    // reading the options. checkCapabilities refuses the bad combinations.
    if (d.caps().rowStatic())
        d.caps().setStatic();
    d.caps().resolveDynamic(isX86_64(d));
#if !OS_darwin
    // An Apple target from another host: the par runtime it would import
    // needs the SDK's frameworks (Metal, CoreFoundation), which this host has
    // not, so its loops stay loops. As the reference.
    if (d.targetRow() != (TargetRow*)0
        && (d.targetRow().os().equals(String.withCString("macos")) || d.targetRow().os().equals(String.withCString("ios"))))
        d.fe().setParAuto(false);
#endif
    finishDriverArgs(d);
    // XC_DUMP_DRIVER_STATE: print what the line parsed to and stop, so two
    // builds of the driver can be compared on the same command line.
    if (Platform.env(String.withCString("XC_DUMP_DRIVER_STATE")).byteLength() > (u32)0) {
        Stdio.printf("%s", driverStateDump(d).cString());
        Process.exit((i32)0);
        return (DriverOptions*)0;
    }
    return d;
}

// One `name=value` line of driverStateDump for each kind of field. A null
// object is `<null>`; an array lists its strings between brackets, a map its
// pairs sorted by key, a target row its name.
void stateDumpStr(String* out, string name, String* v)
{
    out.append(String.withFormat("%s=%s\n", name, v == (String*)0 ? "<null>" : v.cString()));
}

void stateDumpBool(String* out, string name, bool v)
{
    out.append(String.withFormat("%s=%s\n", name, v ? "true" : "false"));
}

void stateDumpU32(String* out, string name, u32 v)
{
    out.append(String.withFormat("%s=%u\n", name, v));
}

void stateDumpI32(String* out, string name, i32 v)
{
    out.append(String.withFormat("%s=%d\n", name, v));
}

void stateDumpArray(String* out, string name, Array* v)
{
    if (v == (Array*)0) { stateDumpStr(out, name, (String*)0); return; }
    String* s = String.withCString("[");
    for (u32 k = (u32)0; k < v.count(); k = k + (u32)1) {
        if (k > (u32)0) s.append(String.withCString(" | "));
        String* e = (String*)v.get(k);
        s.append(e == (String*)0 ? String.withCString("<null>") : e);
    }
    s.append(String.withCString("]"));
    stateDumpStr(out, name, s);
}

void stateDumpMap(String* out, string name, Map* v)
{
    if (v == (Map*)0) { stateDumpStr(out, name, (String*)0); return; }
    Array* ks = v.allKeys();
    ks.sort();
    String* s = String.withCString("{");
    for (u32 k = (u32)0; k < ks.count(); k = k + (u32)1) {
        if (k > (u32)0) s.append(String.withCString(" | "));
        String* key = (String*)ks.get(k);
        String* val = (String*)v.get((Hashable*)key);
        s.append(key);
        s.append(String.withCString("="));
        s.append(val == (String*)0 ? String.withCString("<null>") : val);
    }
    s.append(String.withCString("}"));
    stateDumpStr(out, name, s);
}

void stateDumpRow(String* out, string name, TargetRow* v)
{
    stateDumpStr(out, name, v == (TargetRow*)0 ? (String*)0 : v.name());
}

// Every field of DriverOptions, its CapOptions and its FeOptions, in
// declaration order, plus the globals the parse sets. Read by
// tests/driver/option-table.sh, which compares two drivers' dumps (#337).
String* driverStateDump(DriverOptions* d)
{
    String* out = new String();
    // DriverOptions
    stateDumpStr(out, "d._arch", d._arch);
    stateDumpU32(out, "d._opt", d._opt);
    stateDumpBool(out, "d._keepAsm", d._keepAsm);
    stateDumpBool(out, "d._emitLib", d._emitLib);
    stateDumpBool(out, "d._emitRuntime", d._emitRuntime);
    stateDumpBool(out, "d._noRuntimeLib", d._noRuntimeLib);
    stateDumpBool(out, "d._noXcArgs", d._noXcArgs);
    stateDumpStr(out, "d._bundleDir", d._bundleDir);
    stateDumpStr(out, "d._bundleName", d._bundleName);
    stateDumpStr(out, "d._bundleVersion", d._bundleVersion);
    stateDumpStr(out, "d._bundleResources", d._bundleResources);
    stateDumpStr(out, "d._bundleKey", d._bundleKey);
    stateDumpStr(out, "d._publisher", d._publisher);
    stateDumpStr(out, "d._publisherDomain", d._publisherDomain);
    stateDumpStr(out, "d._trusted", d._trusted);
    stateDumpStr(out, "d._rotateFrom", d._rotateFrom);
    stateDumpArray(out, "d._bundleLibs", d._bundleLibs);
    stateDumpBool(out, "d._noSign", d._noSign);
    stateDumpStr(out, "d._signBundle", d._signBundle);
    stateDumpMap(out, "d._bundleReadonly", d._bundleReadonly);
    stateDumpMap(out, "d._bundleWriteable", d._bundleWriteable);
    stateDumpBool(out, "d._emitIfaceOnly", d._emitIfaceOnly);
    stateDumpBool(out, "d._compileOnly", d._compileOnly);
    stateDumpArray(out, "d._linkInputs", d._linkInputs);
    stateDumpArray(out, "d._frameworks", d._frameworks);
    stateDumpArray(out, "d._objectInputs", d._objectInputs);
    stateDumpBool(out, "d._lto", d._lto);
    stateDumpStr(out, "d._signIdentity", d._signIdentity);
    stateDumpStr(out, "d._signEntitlements", d._signEntitlements);
    stateDumpStr(out, "d._irText", d._irText);
    stateDumpBool(out, "d._emitApk", d._emitApk);
    stateDumpBool(out, "d._quiet", d._quiet);
    stateDumpI32(out, "d._unroll", d._unroll);
    stateDumpStr(out, "d._signKey", d._signKey);
    stateDumpBool(out, "d._sawArch", d._sawArch);
    stateDumpRow(out, "d._targetRow", d._targetRow);
    stateDumpBool(out, "d._printTarget", d._printTarget);
    stateDumpBool(out, "d._print3pDir", d._print3pDir);
    stateDumpStr(out, "d._layoutSpec", d._layoutSpec);
    stateDumpStr(out, "d._layoutPath", d._layoutPath);
    stateDumpStr(out, "d._layoutName", d._layoutName);
    stateDumpBool(out, "d._dumpLayout", d._dumpLayout);
    stateDumpBool(out, "d._listLayouts", d._listLayouts);
    stateDumpBool(out, "d._emitIR", d._emitIR);
    stateDumpBool(out, "d._emitIROpt", d._emitIROpt);
    stateDumpBool(out, "d._tailCalls", d._tailCalls);
    stateDumpBool(out, "d._linkLibs", d._linkLibs);
    stateDumpArray(out, "d._rawLinkFlags", d._rawLinkFlags);
    stateDumpArray(out, "d._rpaths", d._rpaths);
    stateDumpBool(out, "d._rpathPending", d._rpathPending);
    stateDumpArray(out, "d._ldDirs", d._ldDirs);
    stateDumpI32(out, "d._inlineMax", d._inlineMax);
    stateDumpBool(out, "d._dceTrace", d._dceTrace);
    stateDumpBool(out, "d._quitLoop", d._quitLoop);
    stateDumpBool(out, "d._xtcStack", d._xtcStack);
    stateDumpU32(out, "d._fnMinBanked", d._fnMinBanked);
    stateDumpBool(out, "d._dumpPlacement", d._dumpPlacement);
    stateDumpBool(out, "d._dumpUsage", d._dumpUsage);
    // CapOptions
    CapOptions* c = d._caps;
    stateDumpStr(out, "caps._alloc", c._alloc);
    stateDumpStr(out, "caps._malloc", c._malloc);
    stateDumpBool(out, "caps._pic", c._pic);
    stateDumpBool(out, "caps._hardFloat", c._hardFloat);
    stateDumpBool(out, "caps._softFloat", c._softFloat);
    stateDumpU32(out, "caps._m68kCpu", c._m68kCpu);
    stateDumpBool(out, "caps._debugInfo", c._debugInfo);
    stateDumpArray(out, "caps._needed", c._needed);
    stateDumpArray(out, "caps._withLibs", c._withLibs);
    stateDumpStr(out, "caps._libName", c._libName);
    stateDumpArray(out, "caps._manifestAttrs", c._manifestAttrs);
    stateDumpStr(out, "caps._withDex", c._withDex);
    stateDumpBool(out, "caps._noSelfHost", c._noSelfHost);
    stateDumpBool(out, "caps._threadFlag", c._threadFlag);
    stateDumpStr(out, "caps._simd", c._simd);
    stateDumpStr(out, "caps._simdFlag", c._simdFlag);
    stateDumpBool(out, "caps._dynamic", c._dynamic);
    stateDumpBool(out, "caps._dynamicExplicit", c._dynamicExplicit);
    stateDumpBool(out, "caps._staticLink", c._staticLink);
    stateDumpBool(out, "caps._noMatmul", c._noMatmul);
    // FeOptions
    FeOptions* o = d._fe;
    stateDumpStr(out, "fe._input", o._input);
    stateDumpStr(out, "fe._output", o._output);
    stateDumpStr(out, "fe._target", o._target);
    stateDumpStr(out, "fe._libPlatform", o._libPlatform);
    stateDumpRow(out, "fe._targetRow", o._targetRow);
    stateDumpStr(out, "fe._home", o._home);
    stateDumpArray(out, "fe._incs", o._incs);
    stateDumpArray(out, "fe._stdlibs", o._stdlibs);
    stateDumpArray(out, "fe._defs", o._defs);
    stateDumpArray(out, "fe._libs", o._libs);
    stateDumpBool(out, "fe._verbose", o._verbose);
    stateDumpBool(out, "fe._boundsCheck", o._boundsCheck);
    stateDumpBool(out, "fe._boundsReport", o._boundsReport);
    stateDumpBool(out, "fe._debugInfo", o._debugInfo);
    stateDumpI32(out, "fe._threadSafeArc", o._threadSafeArc);
    stateDumpBool(out, "fe._parKernelsAll", o._parKernelsAll);
    stateDumpBool(out, "fe._parAuto", o._parAuto);
    stateDumpU32(out, "fe._parDeviceDefault", o._parDeviceDefault);
    stateDumpBool(out, "fe._parAutoImport", o._parAutoImport);
    stateDumpU32(out, "fe._goalDefault", o._goalDefault);
    stateDumpBool(out, "fe._emitIface", o._emitIface);
    stateDumpBool(out, "fe._libraryBuild", o._libraryBuild);
    stateDumpBool(out, "fe._emitLib", o._emitLib);
    stateDumpArray(out, "fe._runtimeMembers", o._runtimeMembers);
    stateDumpStr(out, "fe._runtimeLibDir", o._runtimeLibDir);
    stateDumpStr(out, "fe._runtimeLibFile", o._runtimeLibFile);
    stateDumpBool(out, "fe._compileOnly", o._compileOnly);
    stateDumpStr(out, "fe._classTable", o._classTable);
    stateDumpBool(out, "fe._analyze", o._analyze);
    stateDumpStr(out, "fe._ifaceJson", o._ifaceJson);
    stateDumpArray(out, "fe._neededLibs", o._neededLibs);
    stateDumpStr(out, "fe._migrate", o._migrate);
    stateDumpBool(out, "fe._libcReferenced", o._libcReferenced);
    stateDumpStr(out, "fe._ppOut", o._ppOut);
    stateDumpMap(out, "fe._callSites", o._callSites);
    stateDumpArray(out, "fe._wno", o._wno);
    // The globals the option loop sets.
    stateDumpBool(out, "gCSplitPair", gCSplitPair);
    stateDumpArray(out, "gExtraSources", gExtraSources);
    stateDumpStr(out, "gCPathStd", cPathStd());
    stateDumpStr(out, "gCPathFpContract", cPathFpContract());
    return out;
}

// What the parse cannot settle argument by argument: $XTC_LDFLAGS joins the
// link, `-m` resolves against the support root (which -H, wherever it sits on
// the line, and the environment decide), and -ll / -dl run and exit.
void finishDriverArgs(DriverOptions* d)
{
    FeOptions* o = d.fe();
    addLdFlagsFromEnvironment(d);
    if (d.listLayouts()) {
        listLayouts(o);
        driverExit((i32)0);
        return;
    }
    String* spec = d.layoutSpec();
    if (spec != (String*)0) {
        String* lp = resolveLayoutFile(o, spec);
        // `-m xt6502` / `-m 6502` name the platform, and mean its xt map.
        if (lp == (String*)0 && (spec.equals(String.withCString("xt6502"))
                                 || spec.equals(String.withCString("6502"))))
            lp = resolveLayoutFile(o, String.withCString("xt6502/xt"));
        if (lp == (String*)0) {
            if (spec.hasPrefix(String.withCString("xe:")))
                Stdio.printf("xcc: error: '-m %s': the parametric Atari xe layouts are retired; "
                             "the 6502 target is xt6502 (-m xt)\n", spec.cString());
            else
                Stdio.printf("xcc: error: no layout file for -m '%s' (looked for "
                             "<platform>/layouts/%s.lnk under the support root). The layout is "
                             "the single source of truth; there is no built-in fallback.\n",
                             spec.cString(), spec.cString());
            driverExit((i32)1);
            return;
        }
        d.setLayoutPath(lp);
        d.setLayoutName(lp.lastPathComponent().deletingPathExtension());
    }
    if (d.dumpLayout()) {
        String* lp = d.layoutPath();
        if (lp == (String*)0) {
            // Never a silent fallback for a target that has none (the host
            // when no -A is given). As the reference.
            if (!isXt6502(d)) {
                Stdio.error(String.withCString("xcc: error: --dump-layout draws a 6502 memory layout: "
                                               "name one with -m <layout>, or -A 6502 for the default\n"));
                driverExit((i32)1);
                return;
            }
            lp = resolveLayoutFile(o, String.withCString("xt6502/xt"));
            if (lp == (String*)0) {
                Stdio.printf("xcc: error: cannot find the default layout xt6502/xt under the "
                             "support root (-H)\n");
                driverExit((i32)1);
                return;
            }
        }
        LayoutMap* m = LayoutMap.read(lp);
        for (u32 i = (u32)0; i < m.warnings().count(); i = i + (u32)1)
            Stdio.error(String.withFormat("xcc: warning: %s\n", ((String*)m.warnings().get(i)).cString()));
        if (m.failed()) {
            Stdio.printf("xcc: error: %s\n", m.why().cString());
            driverExit((i32)1);
            return;
        }
        Stdio.printf("%s", m.diagram().cString());
        driverExit((i32)0);
        return;
    }
}
