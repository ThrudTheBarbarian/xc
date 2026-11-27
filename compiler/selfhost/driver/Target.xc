// Target.xc — the target table: one row per target, found by its -A token.
// =========================================================================
//
// private:docs/Design/targets.md. A target is named by one token, canonical
// `cpu-os[-env|-libc]` (arm64-macos, x86_64-linux, arm64-android, ...), with
// today's short names and the gcc/clang triples as aliases of the same row.
// The reference's XTTarget holds the same rows, field for field.
//
// Step 1: the rows name the target and carry `legacy`, the arch string the
// rest of the driver still tests (d.arch()); the decisions move onto row
// fields one group at a time after this.

#import "Foundation.xc"

class TargetRow
    {
    String* _name;      // canonical token
    Array* _aliases;    // of String*: other spellings -A takes for this row
    String* _cpu;       // arm64, x86_64, armv7, wasm32, m68k, 6502
    u32 _cpuVariant;    // 68000 / 68030 on m68k; 0 elsewhere
    String* _os;        // macos, ios, android, linux, windows, xtos, web, tos, xt
    String* _env;       // simulator, or 0
    String* _libc;      // darwin, bionic, glibc, musl, msvcrt, xtos, none
    String* _legacy;    // the arch string the driver tests today (d.arch())
    String* _backend;   // platform key: front end target, opt profile (arm64, x86_64, win64, arm9, atarist, wasm32, xt6502)
    String* _codegen;   // the code generator, xcc-cg-<codegen> in the reference
    Array* _supportChain; // of String*: support/<dir>/lib before generic, in order; empty for 6502 (its layout names it)
    String* _platformLayer; // the third-party tree's platform layer before the arch's (ios, ios-sim, android), or 0
    String* _abi;       // the calling convention (the reference's abi says which)
    bool _lse;          // arm64: the baseline has the LSE atomics
    bool _compact;      // `new C` gets the 8-byte instance header (compact-object-header.md)
    u32 _loopAlign;     // arm64: loop heads on 2^n bytes, 0 none (5 on Apple's cores; as the reference)
    bool _rotateChain;  // arm64: loops whose test is a short-circuit chain rotate (not on Apple's cores; as the reference)
    String* _appleSdk;  // macosx, iphoneos, iphonesimulator, or 0: frameworks are on exactly when set
    Array* _parKernels; // of String*: the par kernel forms its runtime runs (metal, ptx, spirv, wgsl)
    String* _matmul;    // the matrix-multiply kernels: sme, x86, or 0
    String* _exeFormat; // macho, elf-pie, elf-dyn, elf-static, elf32-dyn, pe, wasm, prg, xex
    String* _crt;       // arm64 so far: support/arm64/runtime's crt and runtime, or 0
    String* _runtime;
    String* _interp;    // an ELF executable's PT_INTERP, or 0
    Array* _needed;     // of String*: its DT_NEEDED before the program's own
    String* _bundlePlatform; // a bundle's platform directory, <os>-<cpu>
    Array* _libExts;    // of String*: a library's extensions, in the order #import <X> tries them
    String* _checkedRuntime; // -fbounds-check's reporter (support/<cpu>/runtime), or "": Checked.xc reports
    String* _cTriple;   // the clang target of a C program built for it off its host, or "" (host only)
    // Layout and dispatch, one value per back end (setLayout):
    u32 _ptrWidth;      // a pointer's bytes: 8, 4, or 3 (xt6502: lo, hi, bank)
    u32 _countWidth;    // an allocation header's count field (`.length`): 4, or 2
    u32 _fieldAlign;    // a struct field's alignment cap: 8, 2 (m68k), 1 (xt6502)
    u32 _tailAlign;     // what sizeof rounds up to: 8, or 2 (m68k)
    bool _itables;      // classes carry the conformance itable; vtables a parent link
    bool _itableAlways; // protocol calls always go through it (else: a library build or an import)
    bool _nativeVarargs; // a variadic's arguments ride the C ABI, not the pack buffer
    bool _threads;      // a par block has threads to run on (else it runs serially)
    // How C passes a _Float16 or __bf16: "F32" (its bits in the low half of
    // an FP register, as a float's are), "U32" (in a core register, arm9's
    // soft-float convention), or "" where C has neither type.
    String* _cPackCarrier;
    // A C program built for the row off its host (cTriple): the root of that
    // target's C headers, and the variable that overrides it; a C++ program's,
    // which links the target's libstdc++. 0 where the row has no cTriple.
    String* _cRoot;
    String* _cRootVar;
    String* _cxxRoot;
    String* _cxxRootVar;

    void init(void)
        {
        _aliases = new Array();
        _cpuVariant = (u32)0;
        _env = (String*)0;
        }

    String* name(void)     { return _name; }
    Array* aliases(void)   { return _aliases; }
    String* cpu(void)      { return _cpu; }
    u32 cpuVariant(void)   { return _cpuVariant; }
    String* os(void)       { return _os; }
    String* env(void)      { return _env; }
    String* libc(void)     { return _libc; }
    String* legacy(void)   { return _legacy; }
    String* backend(void)  { return _backend; }
    String* codegen(void)  { return _codegen; }
    Array* supportChain(void) { return _supportChain; }
    String* platformLayer(void) { return _platformLayer; }
    String* abi(void) { return _abi; }
    bool lseAtomics(void) { return _lse; }
    bool compactObjects(void) { return _compact; }
    u32 loopAlign(void) { return _loopAlign; }
    TargetRow* withLoopAlign(u32 p2) { _loopAlign = p2; return self; }
    bool rotateChain(void) { return _rotateChain; }
    TargetRow* withRotateChain(void) { _rotateChain = true; return self; }
    String* appleSdk(void) { return _appleSdk; }
    Array* parKernels(void) { return _parKernels; }
    String* matmul(void) { return _matmul; }
    String* exeFormat(void) { return _exeFormat; }
    String* crt(void) { return _crt; }
    String* runtime(void) { return _runtime; }
    String* interp(void) { return _interp; }
    Array* needed(void) { return _needed; }
    String* bundlePlatform(void) { return _bundlePlatform; }
    Array* libExts(void) { return _libExts; }
    String* checkedRuntime(void) { return _checkedRuntime; }
    String* cTriple(void) { return _cTriple; }
    u32 pointerWidth(void) { return _ptrWidth; }
    u32 countWidth(void) { return _countWidth; }
    u32 fieldAlign(void) { return _fieldAlign; }
    u32 tailAlign(void) { return _tailAlign; }
    bool itables(void) { return _itables; }
    bool itableAlways(void) { return _itableAlways; }
    bool nativeVarargs(void) { return _nativeVarargs; }
    bool threads(void) { return _threads; }
    String* cPackCarrier(void) { return _cPackCarrier; }
    String* cRoot(void) { return _cRoot; }
    String* cRootVar(void) { return _cRootVar; }
    String* cxxRoot(void) { return _cxxRoot; }
    String* cxxRootVar(void) { return _cxxRootVar; }

    // The C header roots, from the clang target: musl's for x86-64 Linux
    // (glibc's for C++, which links libstdc++), glibc's (usr/include, copied
    // from an arm64 Linux machine) for arm64 Linux, mingw's for win64.
    void setCRoots(void)
        {
        String* t = _cTriple;
        if (t.hasPrefix(String.withCString("x86_64-linux")))
            {
            _cRoot = String.withCString("/opt/clang/linux/x86_64-linux-musl");
            _cRootVar = String.withCString("XTC_MUSL_ROOT");
            _cxxRoot = String.withCString("/opt/clang/linux/x86_64-linux-gnu");
            _cxxRootVar = String.withCString("XTC_X86_64_LINUX_ROOT");
            }
        else if (t.hasPrefix(String.withCString("aarch64-linux")))
            {
            _cRoot = String.withCString("/opt/clang/linux/aarch64-linux-gnu");
            _cRootVar = String.withCString("XTC_ARM64_LINUX_ROOT");
            _cxxRoot = _cRoot;
            _cxxRootVar = _cRootVar;
            }
        else if (t.byteLength() > (u32)0)
            {
            _cRoot = String.withCString("/opt/clang/win64/x86_64-w64-mingw32");
            _cxxRoot = _cRoot;
            }
        }

    // The layout and dispatch columns, from the back end: every row on one back
    // end shares them, so they are written once per back end, here, rather
    // than as a list of platforms at each decision (two past bugs were a
    // target missing from one such list). As the reference's XTTarget.
    void setLayout(void)
        {
        String* b = _backend;
        bool wide = b.equals(String.withCString("arm64")) || b.equals(String.withCString("x86_64"))
                 || b.equals(String.withCString("win64"));
        bool reg = wide || b.equals(String.withCString("arm9")) || b.equals(String.withCString("wasm32"));
        bool m68k = b.equals(String.withCString("atarist"));
        _ptrWidth = wide ? (u32)8 : (reg || m68k) ? (u32)4 : (u32)3;
        // The header's count: 8 on the 64-bit rows, so an array of more than
        // 2^32 elements has a `.length` (#321); 4 on arm9 and wasm32, 2 on m68k.
        _countWidth = wide ? (u32)8 : reg ? (u32)4 : (u32)2;
        _fieldAlign = reg ? (u32)8 : m68k ? (u32)2 : (u32)1;
        _tailAlign = m68k ? (u32)2 : (u32)8;
        _itables = reg;
        _itableAlways = b.equals(String.withCString("arm9"));
        _nativeVarargs = b.equals(String.withCString("arm9")) || b.equals(String.withCString("arm64"));
        _threads = wide || b.equals(String.withCString("wasm32"));
        _cPackCarrier = String.withCString(wide ? "F32" : b.equals(String.withCString("arm9")) ? "U32" : "");
        }
    static String* orNull(string s)
        {
        String* v = String.withCString(s);
        return v.byteLength() == (u32)0 ? (String*)0 : v;
        }
    bool hasParKernel(string k)
        {
        for (u32 i = (u32)0; i < _parKernels.count(); i = i + (u32)1)
            if (((String*)_parKernels.get(i)).equals(String.withCString(k)))
                return true;
        return false;
        }

    // A row: name, cpu, cpu variant, os, env (or ""), libc, legacy arch, then
    // its aliases separated by spaces.
    static TargetRow* make(string name, string cpu, u32 variant, string os, string env,
                           string libc, string legacy, string backend, string codegen, string chain, string layer, string abi, bool lse, string sdk, string kernels, string matmul, string fmt, string crt, string rt, string interp, string needed, string bundle, string exts, string checked, string ctriple, bool compact, string aliases)
        {
        TargetRow* r = new TargetRow();
        r._name = String.withCString(name);
        r._cpu = String.withCString(cpu);
        r._cpuVariant = variant;
        r._os = String.withCString(os);
        String* e = String.withCString(env);
        r._env = e.byteLength() == (u32)0 ? (String*)0 : e;
        r._libc = String.withCString(libc);
        r._legacy = String.withCString(legacy);
        r._backend = String.withCString(backend);
        r._codegen = String.withCString(codegen);
        r._supportChain = TargetRow.words(String.withCString(chain));
        String* ly = String.withCString(layer);
        r._platformLayer = ly.byteLength() == (u32)0 ? (String*)0 : ly;
        r._abi = String.withCString(abi);
        r._lse = lse;
        String* sd = String.withCString(sdk);
        r._appleSdk = sd.byteLength() == (u32)0 ? (String*)0 : sd;
        r._parKernels = TargetRow.words(String.withCString(kernels));
        String* mmk = String.withCString(matmul);
        r._matmul = mmk.byteLength() == (u32)0 ? (String*)0 : mmk;
        r._exeFormat = String.withCString(fmt);
        r._crt = TargetRow.orNull(crt);
        r._runtime = TargetRow.orNull(rt);
        r._interp = TargetRow.orNull(interp);
        r._needed = TargetRow.words(String.withCString(needed));
        r._bundlePlatform = String.withCString(bundle);
        r._libExts = TargetRow.words(String.withCString(exts));
        r._checkedRuntime = String.withCString(checked);
        r._cTriple = String.withCString(ctriple);
        r._compact = compact;
        r._aliases = TargetRow.words(String.withCString(aliases));
        r.setLayout();
        r.setCRoots();
        return r;
        }

    // The space-separated words of s.
    static Array* words(String* s)
        {
        Array* out = new Array();
        u32 start = (u32)0;
        for (u32 i = (u32)0; i <= s.byteLength(); i = i + (u32)1)
            {
            if (i == s.byteLength() || s.byteAt(i) == (u8)' ')
                {
                if (i > start)
                    out.add((Object*)s.substringBytes(start, i - start));
                start = i + (u32)1;
                }
            }
        return out;
        }

    // The library defines the row generates (the reference's macros says
    // which, in which order), each defined as 1.
    Array* macros(void)
        {
        Array* m = new Array();
        String* a = String.withCString("ARCH_");
        a.append(_cpu);
        m.add((Object*)a);
        String* o = String.withCString("OS_");
        o.append(_os);
        m.add((Object*)o);
        bool darwin = _os.equals(String.withCString("macos")) || _os.equals(String.withCString("ios"));
        if (darwin)
            m.add((Object*)String.withCString("OS_darwin"));
        if (darwin || _os.equals(String.withCString("linux")) || _os.equals(String.withCString("android")))
            m.add((Object*)String.withCString("OS_unix"));
        if (!_libc.equals(String.withCString("none")))
            {
            String* l = String.withCString("LIBC_");
            l.append(_libc);
            m.add((Object*)l);
            }
        if (_env != (String*)0)
            {
            String* e = String.withCString("ENV_");
            e.append(_env);
            m.add((Object*)e);
            }
        // The 8-byte instance header: what a plugin's manifest records as
        // object ABI 2 (BundleSign.objectAbi).
        if (_compact)
            m.add((Object*)String.withCString("OBJECTS_compact"));
        return m;
        }

    // `--print-target`: the row, one field per line, in the order both
    // compilers print it.
    String* describe(void)
        {
        String* s = new String();
        s.appendFormat("target %s\n", _name.cString());
        s.appendFormat("cpu %s\n", _cpu.cString());
        if (_cpuVariant != (u32)0)
            s.appendFormat("cpu-variant %lu\n", _cpuVariant);
        s.appendFormat("os %s\n", _os.cString());
        if (_env != (String*)0)
            s.appendFormat("env %s\n", _env.cString());
        s.appendFormat("libc %s\n", _libc.cString());
        s.appendFormat("legacy %s\n", _legacy.cString());
        s.appendFormat("backend %s\n", _backend.cString());
        s.appendFormat("codegen %s\n", _codegen.cString());
        if (_platformLayer != (String*)0)
            s.appendFormat("platform-layer %s\n", _platformLayer.cString());
        s.appendFormat("abi %s\n", _abi.cString());
        if (_lse)
            s.appendCString("lse-atomics\n");
        if (_compact)
            s.appendCString("compact-objects\n");
        if (_loopAlign != (u32)0)
            s.appendFormat("loop-align %u\n", _loopAlign);
        if (_appleSdk != (String*)0)
            s.appendFormat("apple-sdk %s\n", _appleSdk.cString());
        if (_matmul != (String*)0)
            s.appendFormat("matmul %s\n", _matmul.cString());
        s.appendFormat("format %s\n", _exeFormat.cString());
        if (_crt != (String*)0)
            s.appendFormat("runtime %s %s\n", _crt.cString(), _runtime.cString());
        if (_interp != (String*)0)
            s.appendFormat("interp %s\n", _interp.cString());
        if (_needed.count() > (u32)0)
            {
            s.appendCString("needed");
            for (u32 i = (u32)0; i < _needed.count(); i = i + (u32)1)
                s.appendFormat(" %s", ((String*)_needed.get(i)).cString());
            s.appendCString("\n");
            }
        s.appendFormat("bundle-platform %s\n", _bundlePlatform.cString());
        s.appendCString("lib-exts");
        for (u32 i = (u32)0; i < _libExts.count(); i = i + (u32)1)
            s.appendFormat(" %s", ((String*)_libExts.get(i)).cString());
        s.appendCString("\n");
        s.appendFormat("checked-runtime %s\n", _checkedRuntime.byteLength() > (u32)0 ? _checkedRuntime.cString() : "-");
        s.appendFormat("c-triple %s\n", _cTriple.byteLength() > (u32)0 ? _cTriple.cString() : "-");
        s.appendCString("par-kernels");
        for (u32 i = (u32)0; i < _parKernels.count(); i = i + (u32)1)
            s.appendFormat(" %s", ((String*)_parKernels.get(i)).cString());
        s.appendCString("\n");
        s.appendCString("support");
        for (u32 i = (u32)0; i < _supportChain.count(); i = i + (u32)1)
            s.appendFormat(" %s", ((String*)_supportChain.get(i)).cString());
        s.appendCString("\n");
        s.appendCString("macros");
        Array* ms = macros();
        for (u32 i = (u32)0; i < ms.count(); i = i + (u32)1)
            s.appendFormat(" %s", ((String*)ms.get(i)).cString());
        s.appendCString("\n");
        s.appendCString("aliases");
        for (u32 i = (u32)0; i < _aliases.count(); i = i + (u32)1)
            s.appendFormat(" %s", ((String*)_aliases.get(i)).cString());
        s.appendCString("\n");
        return s;
        }
    }

// The table, built once (as the reference's dispatch_once): rows() is asked
// at every target decision, and used to rebuild all thirteen rows each time.
Array* gTargetRows;

class Targets
    {
    // The rows, in this order in both compilers.
    static Array* rows(void)
        {
        if (gTargetRows != (Array*)0)
            return gTargetRows;
        Array* t = new Array();
        t.add((Object*)TargetRow.make("arm64-macos", "arm64", (u32)0, "macos", "", "darwin", "arm64", "arm64", "arm64", "arm64", "", "darwin64", true, "macosx", "metal", "sme", "macho", "crt-macos.s", "rt-macos.s", "", "", "macos-arm64", "dylib so", "rt-checked-macos.s", "", true,
                                      "arm64 aarch64-apple-darwin arm64-apple-macos arm64-apple-darwin").withLoopAlign((u32)5));
        t.add((Object*)TargetRow.make("arm64-ios", "arm64", (u32)0, "ios", "", "darwin", "ios", "arm64", "arm64", "ios arm64", "ios", "darwin64", true, "iphoneos", "", "", "macho", "crt-macos.s", "rt-macos.s", "", "", "ios-arm64", "dylib so", "rt-checked-macos.s", "", true,
                                      "ios arm64-apple-ios").withLoopAlign((u32)5));
        t.add((Object*)TargetRow.make("arm64-ios-sim", "arm64", (u32)0, "ios", "simulator", "darwin", "ios-sim", "arm64", "arm64", "ios arm64", "ios-sim", "darwin64", true, "iphonesimulator", "", "", "macho", "crt-macos.s", "rt-macos.s", "", "", "ios-arm64", "dylib so", "rt-checked-macos.s", "", true,
                                      "ios-sim arm64-apple-ios-simulator").withLoopAlign((u32)5));
        t.add((Object*)TargetRow.make("arm64-android", "arm64", (u32)0, "android", "", "bionic", "android", "arm64", "arm64", "arm64", "android", "aapcs64", false, "", "spirv", "", "elf-pie", "crt-android.s", "rt-android.s", "/system/bin/linker64", "libc.so libm.so libdl.so", "android-arm64", "so", "", "", true,
                                      "android aarch64-linux-android").withRotateChain());
        t.add((Object*)TargetRow.make("arm64-linux", "arm64", (u32)0, "linux", "", "glibc", "arm64-linux", "arm64", "arm64", "arm64", "linux-arm64", "aapcs64", false, "", "spirv", "neon", "elf-pie", "crt-glibc.s", "rt-glibc.s", "/lib/ld-linux-aarch64.so.1", "libc.so.6 libm.so.6", "linux-arm64", "so", "", "aarch64-linux-gnu", true,
                                      "aarch64-linux-gnu arm64-linux-gnu aarch64-unknown-linux-gnu").withRotateChain().withLoopAlign((u32)5));
        t.add((Object*)TargetRow.make("x86_64-linux", "x86_64", (u32)0, "linux", "", "glibc", "x86_64", "x86_64", "x86_64", "x86_64", "", "sysv", false, "", "ptx spirv", "x86", "elf-dyn", "", "", "", "", "linux-x86_64", "so dylib", "", "x86_64-linux-gnu", true,
                                      "x86_64 x86-64 amd64 x86_64-linux-gnu x86_64-pc-linux-gnu"));
        t.add((Object*)TargetRow.make("x86_64-linux-musl", "x86_64", (u32)0, "linux", "", "musl", "x86_64", "x86_64", "x86_64", "x86_64", "", "sysv", false, "", "", "x86", "elf-static", "", "", "", "", "linux-x86_64", "so dylib", "", "x86_64-linux-musl", true,
                                      "x86_64-pc-linux-musl"));
        t.add((Object*)TargetRow.make("x86_64-windows", "x86_64", (u32)0, "windows", "", "msvcrt", "win64", "win64", "win64", "win64 x86_64", "", "win64", false, "", "ptx spirv", "", "pe", "", "", "", "", "windows-x86_64", "dll dll.a a", "", "x86_64-w64-windows-gnu", true,
                                      "win64 windows x86_64-w64-mingw32 x86_64-w64-windows-gnu x86_64-pc-windows-gnu"));
        t.add((Object*)TargetRow.make("armv7-xtos", "armv7", (u32)0, "xtos", "", "xtos", "arm9", "arm9", "arm9", "arm9", "", "aapcs-vfp", false, "", "", "", "elf32-dyn", "", "", "", "", "xtos-arm9", "so dylib", "", "", false,
                                      "arm9 armv7 armv7-a cortex-a9"));
        t.add((Object*)TargetRow.make("wasm32-web", "wasm32", (u32)0, "web", "", "none", "wasm32", "wasm32", "wasm32", "wasm32", "", "wasm", false, "", "wgsl", "", "wasm", "", "", "", "", "wasm32", "wasm", "", "", false,
                                      "wasm32 wasm wasm32-unknown-unknown"));
        t.add((Object*)TargetRow.make("m68k-tos", "m68k", (u32)68000, "tos", "", "none", "m68k", "atarist", "68k", "atarist", "", "m68k", false, "", "", "", "prg", "", "", "", "", "tos-m68k", "so dylib", "", "", false,
                                      "m68k 68000 atarist m68k-atari-tos"));
        t.add((Object*)TargetRow.make("m68030-tos", "m68k", (u32)68030, "tos", "", "none", "m68k", "atarist", "68k", "atarist", "", "m68k", false, "", "", "", "prg", "", "", "", "", "tos-m68k", "so dylib", "", "", false,
                                      "68030"));
        t.add((Object*)TargetRow.make("6502-xt", "6502", (u32)0, "xt", "", "none", "xt6502", "xt6502", "6502", "", "", "xt6502", false, "", "", "", "xex", "", "", "", "", "xt-6502", "so dylib", "", "", false,
                                      "6502 xt6502 xt"));
        gTargetRows = t;
        return t;
        }

    // The row a -A token names (its canonical name or an alias), or 0.
    static TargetRow* find(String* token)
        {
        Array* t = rows();
        for (u32 i = (u32)0; i < t.count(); i = i + (u32)1)
            {
            TargetRow* r = (TargetRow*)t.get(i);
            if (r.name().equals(token))
                return r;
            for (u32 j = (u32)0; j < r.aliases().count(); j = j + (u32)1)
                if (((String*)r.aliases().get(j)).equals(token))
                    return r;
            }
        return (TargetRow*)0;
        }
    }
