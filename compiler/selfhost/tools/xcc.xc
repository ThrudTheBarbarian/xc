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

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Frontend.xc"
#import "IrParse.xc"
#import "Opt.xc"
#import "Arm64.xc"          // the BACK END
#import "Arm64Asm.xc"       // the ASSEMBLER — different class, different dir
#import "MachO.xc"
#import "MachOLink.xc"
#import "Tbd.xc"
#import "PeLink.xc"
#import "CodeSign.xc"
#import "Iface.xc"
#import "ElfArm64.xc"
#import "Apk.xc"
#import "ApkSign.xc"
#import "RsaKeygen.xc"
#import "Layout.xc"
#import "Xt6502.xc"
#import "Xta.xc"
#import "Runtime6502.xc"
#import "Peep6502.xc"
#import "M68k.xc"            // the m68k BACK END
#import "M68kAsm.xc"         // …and its assembler, which writes the GEMDOS container
#import "Wasm32.xc"          // the wasm32 BACK END (emits WAT)
#import "Wasm.xc"            // …and the writer that turns WAT into a .wasm module
#import "Arm9.xc"            // the ARMv7-A BACK END
#import "Arm32.xc"           // …its assembler
#import "Elf32.xc"           // …and the ET_DYN writer the XTOS loader takes
#import "X86_64.xc"          // the x86-64 BACK END
#import "X86Link.xc"    // …and the link, shared with xtldx86 so they cannot drift
#import "Elf64.xc"      // …and the ET_REL object writer `-c` needs
#import "Pe.xc"         // the Windows PE/COFF writer, shared with xtldwin

// ── options ──────────────────────────────────────────────────────────────
class DriverOptions
{
    FeOptions* _fe;
    String*    _arch;        // arm64 | android
    u32        _opt;
    bool       _keepAsm;     // -S: stop after the back end
    bool       _emitLib;     // --emit-lib: a SHARED LIBRARY, not an executable
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

    void init(void)
    {
        _fe = new FeOptions();
        // The default target is the HOST — the arch this compiler was itself
        // compiled for — so `xcc -o prog prog.xc` builds a native binary the
        // way cc does, on every host. This was a literal "arm64", which is
        // invisibly correct on a Mac and wrong everywhere else: the x86_64
        // build of this compiler, running on Linux, emitted a Mach-O arm64
        // binary for a bare `xcc -o prog prog.xc` and the user got
        // "Exec format error". `ARCH_<arch>` is predefined by the compiler
        // building this file, so the answer is known here with no host probe.
        //
        // ORDER MATTERS: `-A win64` predefines ARCH_win64 AND ARCH_x86_64,
        // because win64 IS x86-64 — it is the same architecture with a
        // different container and ABI. Testing x86_64 first made the Windows
        // compiler default to emitting Linux ELFs. The more specific platform
        // is therefore tested first, and this is the general rule for any
        // future host that shares an arch with another.
#if ARCH_win64
        _arch = String.withCString("win64");
#elif ARCH_x86_64
        _arch = String.withCString("x86_64");
#elif ARCH_arm9
        _arch = String.withCString("arm9");
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
    }

    FeOptions* fe(void)  { return _fe; }
    String* arch(void)   { return _arch; }
    u32 opt(void)        { return _opt; }
    bool keepAsm(void)   { return _keepAsm; }
    bool emitLib(void)   { return _emitLib; }
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
}

bool isAndroid(DriverOptions* d) { return d.arch().equals(String.withCString("android")); }
bool isWasm(DriverOptions* d)
{
    return d.arch().equals(String.withCString("wasm32"))
        || d.arch().equals(String.withCString("wasm"));
}
bool isX86_64(DriverOptions* d)
{
    return d.arch().equals(String.withCString("x86_64"));
}

bool isArm9(DriverOptions* d) { return d.arch().equals(String.withCString("arm9")); }
// iOS is the ARM64 back end with a Mach-O platform flavour, exactly as android
// is the arm64 back end under different options. Stage 0 of docs/mobile/iOS.md:
// the target spelling, the platform stamp, and libraries resolved from the
// arm64 support tree. `-A ios` is the device, `-A ios-sim` the simulator.
bool isIos(DriverOptions* d)
{
    return d.arch().equals(String.withCString("ios"))
        || d.arch().equals(String.withCString("ios-sim"));
}
bool isM68k(DriverOptions* d)
{
    return d.arch().equals(String.withCString("m68k"))
        || d.arch().equals(String.withCString("atarist"));
}
bool isXt6502(DriverOptions* d)
{
    return d.arch().equals(String.withCString("xt6502"))
        || d.arch().equals(String.withCString("6502"))
        || d.arch().equals(String.withCString("xt"));
}

// The back end's own target name. Android IS the arm64 back end — a different
// ABI and a different link, not a different code generator.
String* backendTargetOf(DriverOptions* d)
{
    // Android IS the arm64 back end under different options; xt6502 is its own.
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
    if (d.arch().equals(String.withCString("win64")))
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
            out.appendCString("    mov x2, #0\n");
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
    Array* nb = (Array*)k.get((u32)0);
    Array* eb = (Array*)k.get((u32)1);
    Array* db = (Array*)k.get((u32)2);
    Array* cert = ApkSign.selfSignedCert(nb, eb, db, String.withCString("xc debug"));
    if (cert.count() == (u32)0) return false;

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
        Array* v = (Array*)fields.get(f);
        u32 n = v.count();
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            out.appendByte((u8)((n >> (i * (u32)8)) & (u32)$FF));
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            out.appendByte((u8)((Number*)v.get(i)).asU32());
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
        Process.exit((i32)1);
        return (String*)0;
    }
    String* stem = arg.substringFromByte((u32)2);
    Array* dirs = d.fe().libs();
    // A `.dylib` is a Mach-O library — only a Mach-O target (the arm64 / iOS
    // host) can link it. On an ELF (x86_64 / arm9) or PE (win64) target it must
    // NOT be a `-l<name>` candidate: 0.5 grabbed a stray macOS `libfoo.dylib`
    // off the -L path and handed it to the ELF linker, which then refused it;
    // 0.4 skipped it (c2xc bug 37). Those targets use `.so` / `.a` instead.
    String* arch = d.arch();
    bool machO = !(arch.equals(String.withCString("x86_64"))
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
    String* sdk = appleSdkRoot(d);
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
    if (d.arch().equals(String.withCString("win64"))) {
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
    if (d.arch().equals(String.withCString("ios")))
        roots.add((Object*)String.withCString("/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"));
    else if (d.arch().equals(String.withCString("ios-sim")))
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
        if (dataContains(blob, "_OBJC_CLASS_$_") || dataContains(blob, "_objc_msgSend")) return true;
    }
    return false;
}

// The dependency list for an arm64 / iOS executable: what the program (or its
// objects) `#import`ed, then the libraries and frameworks named on the line,
// then libobjc when the merged objects need it — the reference's order.
Array* arm64LinkDeps(DriverOptions* d, Array* neededLibs, Array* extraObjects)
{
    Array* deps = new Array();
    for (u32 i = (u32)0; neededLibs != (Array*)0 && i < neededLibs.count(); i = i + (u32)1) {
        String* lp = (String*)neededLibs.get(i);
        if (!lp.hasSuffix(String.withCString(".dylib"))) continue;
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
    // iOS: the platform shim (xtios.c) reaches NSURLSession through the ObjC
    // runtime, so every iOS image depends on Foundation and libobjc — added
    // after the user's frameworks unless the user named Foundation already.
    bool wantFoundation = isIos(d);
    for (u32 i = (u32)0; fw != (Array*)0 && i < fw.count(); i = i + (u32)1)
        if (((String*)fw.get(i)).equals(String.withCString("Foundation"))) wantFoundation = false;
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

void emitApkPackage(DriverOptions* d, String* prog)
{
    FeOptions* o = d.fe();
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
            Process.exit((i32)1); return;
        }
        keyPath = String.withString(home);
        keyPath.appendCString("/.xcc/android-debug.key.raw");
    }
    if (!Files.exists(keyPath)) {
        Stdio.printf("xcc: generating a debug signing key (once) -> %s\n", keyPath.cString());
        if (!writeDebugKey(keyPath)) {
            Stdio.printf("xcc: error: cannot create a signing key\n");
            Process.exit((i32)1); return;
        }
    }
    String* name = out.lastPathComponent().deletingPathExtension();
    String* crt = (String*)0;                       // a .so has no entry point
    String* rt  = readRuntime(o, String.withCString("rt-android.s"));
    String* glue = readRuntime(o, String.withCString("glue-android.s"));
    if (rt == (String*)0 || glue == (String*)0) {
        Stdio.printf("xcc: error: the android runtime/glue is missing from the support tree\n");
        Process.exit((i32)1); return;
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
        Process.exit((i32)1); return;
    }
    Array* needed = new Array();
    needed.add((Object*)String.withCString("libc.so"));
    needed.add((Object*)String.withCString("libm.so"));
    needed.add((Object*)String.withCString("libdl.so"));
    needed.add((Object*)String.withCString("liblog.so"));
    needed.add((Object*)String.withCString("libandroid.so"));
    Array* exports = new Array();
    exports.add((Object*)String.withCString("ANativeActivity_onCreate"));
    String* soname = String.withCString("lib");
    soname.append(name); soname.appendCString(".so");

    // Bug 124: the constructor array is kept OUT of dataBytes by the assembler,
    // so it has to be appended here or every load-time constructor is dropped.
    Array* apkData = a.dataBytes();
    Array* apkFix  = a.fixups();
    u32 apkMi = Arm64Asm.appendModInit(a, apkData, apkFix);
    ElfArm64* w = new ElfArm64();
    w.image(a.textBytes(), apkData, a.symbols(), a.dataSyms(),
            exports, apkFix, soname, needed, (String*)0, apkMi);
    if (w.failed()) {
        Stdio.printf("xcc: apk: link failed: %s\n", w.why().cString());
        Process.exit((i32)1); return;
    }

    String* pkg = String.withCString("org.compile_xc.");
    pkg.append(name);
    Array* manifest = ApkXml.manifest(pkg, name, name, (u32)24, (u32)35, false);

    Array* entries = new Array();
    entries.add((Object*)ApkEntry.with(String.withCString("AndroidManifest.xml"), manifest));
    String* libPath = String.withCString("lib/arm64-v8a/");
    libPath.append(soname);
    entries.add((Object*)ApkEntry.with(libPath, w.bytes()));
    Array* zip = ApkZip.build(entries, (u32)4096, String.withCString(".so"));

    Data* kd = Files.readData(keyPath);
    if (kd == (Data*)0 || kd.length() < (u32)5) {
        Stdio.printf("xcc: error: cannot read the signing key '%s'\n", keyPath.cString());
        Process.exit((i32)1); return;
    }
    u32 at = (u32)5;                                 // past "XKEY1"
    Array* kn = apkKeyField(kd, &at);
    Array* ke = apkKeyField(kd, &at);
    Array* kdd = apkKeyField(kd, &at);
    Array* kc = apkKeyField(kd, &at);
    Array* signedApk = ApkSign.sign(zip, kc, kn, ke, kdd);
    if (signedApk.count() == (u32)0) {
        Stdio.printf("xcc: error: apk signing failed\n");
        Process.exit((i32)1); return;
    }

    Data* fileOut = Data.withCapacity((u32)0);
    for (u32 i = (u32)0; i < signedApk.count(); i = i + (u32)1)
        fileOut.appendByte((u8)((Number*)signedApk.get(i)).asU32());
    Files.writeData(out, fileOut);
    Stdio.printf("xcc: android APK -> '%s'  (adb install -r %s)\n",
                 out.cString(), out.cString());
}

// "XKEY1" then four little-endian length-prefixed blobs: n, e, d, cert.
Array* apkKeyField(Data* dd, u32* at)
{
    u32 p = *at;
    u32 n = (u32)dd.byteAt(p) | ((u32)dd.byteAt(p + (u32)1) << (u32)8)
          | ((u32)dd.byteAt(p + (u32)2) << (u32)16) | ((u32)dd.byteAt(p + (u32)3) << (u32)24);
    p = p + (u32)4;
    Array* out = new Array();
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        out.add((Object*)Number.withU32((u32)dd.byteAt(p + i)));
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
String* wasmLibSidecar(String* wat)
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
    j.appendFormat("{\"dataSize\": %lu, \"tableSize\": %lu}\n", dataSize, tableSize);
    return j;
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
    Opt* opt = Opt.atLevel(d.opt(), pw);
    // A LIBRARY's public surface is every function it defines: nothing in the
    // module calls them, the CLIENT does, and dead-function elimination cannot
    // see the client. Without this the library dropped `Greeter$init` — a
    // constructor no internal code calls — and the app that did call it failed
    // at instantiation with `depExports[d][n] is not a function`.
    if (d.emitLib()) opt.setKeepAllFunctions(true);
    opt.run(mod);

    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    Wasm32* be = new Wasm32();
    be.setOptLevel(d.opt());
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
    }
    String* wat = be.assembly(mod);
    // The wasm back end reports a fatal unresolved import rather than a
    // generic failure — a module that imports something the host will not
    // supply cannot be instantiated, so it is refused here rather than
    // written and failing at load.
    if (be.fatalImport()) { Process.exit((i32)1); return; }

    String* out = d.fe().output();
    if (d.keepAsm() || out.hasSuffix(String.withCString(".wat"))) {
        if (!Files.writeText(out, wat)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", out.cString());
            Process.exit((i32)1); return;
        }
        return;
    }

    // ── library build ────────────────────────────────────────────────────
    // No loader: a library is instantiated BY an app's loader, not on its own.
    // Two extra outputs instead:
    //   * the interface, embedded as a `xtc.iface` CUSTOM section — the wasm
    //     analogue of the ELF `.xtc.iface`, so `#import <X>` reads the types
    //     out of the binary itself rather than a side file that can go missing.
    //   * lib<Name>.json, the placement sidecar {dataSize, tableSize}, which
    //     the loader needs BEFORE instantiating to know where to put the
    //     library's statics and how far to grow the table.
    if (d.emitLib()) {
        String* lbase = out;
        if (lbase.hasSuffix(String.withCString(".wasm")))
            lbase = lbase.substringBytes((u32)0, lbase.byteLength() - (u32)5);
        WasmWriter* lw = new WasmWriter();
        Data* lmod = lw.moduleFromWat(wat);
        if (lmod == (Data*)0) {
            Stdio.printf("xcc: wasm write failed: %s\n",
                         lw.why() == 0 ? "(no detail)" : lw.why().cString());
            Process.exit((i32)1); return;
        }
        String* iface = d.fe().ifaceJson();
        if (iface != (String*)0 && iface.byteLength() > (u32)0)
            appendWasmCustomSection(lmod, String.withCString("xtc.iface"), iface);
        String* wpath = String.withString(lbase); wpath.appendCString(".wasm");
        if (!Files.writeData(wpath, lmod)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", wpath.cString());
            Process.exit((i32)1); return;
        }
        String* jpath = String.withString(lbase); jpath.appendCString(".json");
        if (!Files.writeText(jpath, wasmLibSidecar(wat))) {
            Stdio.printf("xcc: error: cannot write '%s'\n", jpath.cString());
            Process.exit((i32)1); return;
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
        Process.exit((i32)1); return;
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
    String* deps = String.withCString("[");
    Array* nl = d.fe().neededLibs();
    bool dfirst = true;
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
        String* lp = (String*)nl.get(i);
        if (!lp.hasSuffix(String.withCString(".wasm"))) continue;
        String* fn = baseNameOf(lp);
        if (!fn.hasPrefix(String.withCString("lib"))) continue;
        String* nm = fn.substringBytes((u32)3, fn.byteLength() - (u32)3 - (u32)5);
        if (!dfirst) deps.appendCString(", ");
        dfirst = false;
        deps.appendCString("\"");
        deps.append(nm);
        deps.appendCString("\"");
    }
    deps.appendCString("]");
    js = js.replacing(String.withCString("__DEPS__"), deps);
    String* jsPath = String.withString(base);
    jsPath.appendCString(".js");
    if (!Files.writeText(jsPath, js)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", jsPath.cString());
        Process.exit((i32)1); return;
    }

    WasmWriter* w = new WasmWriter();
    Data* module = w.moduleFromWat(wat);
    if (module == (Data*)0) {
        Stdio.printf("xcc: wasm write failed: %s\n",
                     w.why() == 0 ? "(no detail)" : w.why().cString());
        Process.exit((i32)1); return;
    }
    String* wasmPath = String.withString(base);
    wasmPath.appendCString(".wasm");
    if (!Files.writeData(wasmPath, module)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", wasmPath.cString());
        Process.exit((i32)1); return;
    }
    if (!d.quiet())
        Stdio.printf("xcc: wasm32 module -> '%s.wasm' + '%s.js' (run: node %s.js)\n",
                     base.cString(), base.cString(), base.cString());
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
            out.appendCString(win64 ? "\txor\tr8d, r8d\n" : "\txor\tedx, edx\n");
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
    Opt* prof = Opt.atLevel(d.opt(), pw);
    // An OBJECT's functions are all potentially called from ANOTHER object, so
    // cross-function DCE must not read "nothing here calls it" as dead.
    if (d.emitLib() || d.compileOnly()) prof.setKeepAllFunctions(true);
    prof.run(mod);

    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    X86_64* be = new X86_64();
    be.setWin64(true);
    String* prog = be.assembly(mod);
    if (be.failed()) {
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < be.missing().count(); k = k + (u32)1) {
            if (k > (u32)0) list.appendCString(" ");
            list.append((String*)be.missing().get(k));
        }
        Stdio.printf("xcc: %s: unsupported: %s\n", d.fe().input().cString(), list.cString());
        Process.exit((i32)3); return;
    }
    if (d.keepAsm()) {
        if (!Files.writeText(d.fe().output(), prog)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            Process.exit((i32)1); return;
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
            Process.exit((i32)1); return;
        }
        Pe* pw = new Pe();
        Array* img = pw.objectFromText(oa.text(), oa.data(), oa.symbols(), oa.dataSyms(),
                                       oa.globalSyms(), oa.fixups());
        if (pw.failed() || img == (Array*)0) {
            Stdio.printf("xcc: %s\n", pw.failed() ? pw.why().cString() : "object write failed");
            Process.exit((i32)1); return;
        }
        Data* od = Data.withCapacity(img.count());
        for (u32 i = (u32)0; i < img.count(); i = i + (u32)1)
            od.appendByte((u8)((Number*)img.get(i)).asU32());
        if (!Files.writeData(d.fe().output(), od)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            Process.exit((i32)1); return;
        }
        writeObjectSidecars(d);
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

// The win64 link, from program asm (or none — an object-only link) to the PE
// on disk: runtime + stubs + program assembled as one input, then the
// objects and archives named on the line, then the C-runtime pool, then the
// kernel32 imports and the import map for whatever the pool did not define.
void linkWin64(DriverOptions* d, String* prog)
{
    Array* srcs = new Array();
    Array* rtNames = new Array();
    rtNames.add((Object*)String.withCString("crt-win64.s"));
    rtNames.add((Object*)String.withCString("rtgen-win64.s"));
    rtNames.add((Object*)String.withCString("rtfiles-win64.s"));
    rtNames.add((Object*)String.withCString("libmgen-win64.s"));
    for (u32 k = (u32)0; k < rtNames.count(); k = k + (u32)1) {
        String* t = readRuntimeIn(d.fe(), "win64/runtime", (String*)rtNames.get(k));
        if (t == 0) {
            Stdio.printf("xcc: error: cannot read %s from the support tree\n",
                         ((String*)rtNames.get(k)).cString());
            Process.exit((i32)1); return;
        }
        srcs.add((Object*)t);
    }
    srcs.add((Object*)x86ClassAllocStubs(prog, true));
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
        Process.exit((i32)1); return;
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
            Process.exit((i32)1); return;
        }
    }
    Array* pool = win64Pool(d);
    for (u32 i = (u32)0; i < pool.count(); i = i + (u32)1) ars.add(pool.get(i));
    if (objs.count() > (u32)0 || ars.count() > (u32)0) {
        PeLink* pl = new PeLink();
        pl.merge(objs, ars, a.text(), a.data(), a.symbols(), a.dataSyms(), a.fixups());
        if (pl.rc() != (u32)0) {
            Stdio.printf("xcc: error: win64 link: %s\n", pl.why() == 0 ? "?" : pl.why().cString());
            Process.exit((i32)1); return;
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
                if (sym.byteLength() == (u32)0 || dll.byteLength() == (u32)0) continue;
                // An explicit entry wins: the floor above is what the runtime
                // itself calls, and the map is a wider catalogue that may name
                // the same symbol in a different DLL.
                bool have = false;
                for (u32 i = (u32)0; i < syms.count(); i = i + (u32)1) {
                    Array* one = (Array*)syms.get(i);
                    for (u32 j = (u32)0; j < one.count(); j = j + (u32)1)
                        if (((String*)one.get(j)).equals(sym)) have = true;
                }
                if (have) continue;
                i32 at = (i32)-1;
                for (u32 i = (u32)0; i < dlls.count(); i = i + (u32)1)
                    if (((String*)dlls.get(i)).equals(dll)) at = (i32)i;
                if (at < (i32)0) {
                    dlls.add((Object*)dll);
                    syms.add((Object*)new Array());
                    at = (i32)(dlls.count() - (u32)1);
                }
                ((Array*)syms.get((u32)at)).add((Object*)sym);
            }
        }
    }

    Pe* pe = new Pe();
    pe.executable(a.text(), a.data(), a.symbols(), a.dataSyms(), a.fixups(),
                  String.withCString("_start"), dlls, syms);
    if (pe.failed()) {
        Stdio.printf("xcc: %s\n", pe.why().cString());
        Process.exit((i32)1); return;
    }
    Array* image = pe.bytes();
    Data* out = Data.withCapacity(image.count());
    for (u32 k = (u32)0; k < image.count(); k = k + (u32)1)
        out.appendByte((u8)((Number*)image.get(k)).asU32());
    if (!Files.writeData(d.fe().output(), out)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        Process.exit((i32)1); return;
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
void writeObjectSidecars(DriverOptions* d)
{
    String* base = stripExtension(d.fe().output());
    String* ij = d.fe().ifaceJson();
    if (ij != (String*)0 && ij.byteLength() > (u32)0) {
        String* p = String.withString(base); p.appendCString(".xtc.iface");
        Files.writeText(p, ij);
    }
    String* needs = new String();
    Array* nl = d.fe().neededLibs();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1) {
        String* l = (String*)nl.get(i);
        if (!l.hasSuffix(String.withCString(".so"))
         && !l.hasSuffix(String.withCString(".dylib"))
         && !l.contains(String.withCString(".so."))) continue;
        if (needs.byteLength() > (u32)0) needs.appendCString("\n");
        needs.append(l);
    }
    String* np = String.withString(base); np.appendCString(".xtc.needs");
    Files.writeText(np, needs);

    if (d.irText() != (String*)0 && d.irText().byteLength() > (u32)0) {
        String* ip = String.withString(base); ip.appendCString(".xtc.ir");
        Files.writeText(ip, d.irText());
    }
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
    Opt* prof = Opt.atLevel(d.opt(), px);
    // A LIBRARY keeps every function it defines — the client is what calls
    // them, and dead-function elimination cannot see the client.
    // An OBJECT's functions are all potentially called from ANOTHER object, so
    // cross-function DCE must not read "nothing here calls it" as dead.
    if (d.emitLib() || d.compileOnly()) prof.setKeepAllFunctions(true);
    prof.run(mod);

    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    X86_64* be = new X86_64();
    String* prog = be.assembly(mod);
    if (be.failed()) {
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < be.missing().count(); k = k + (u32)1) {
            if (k > (u32)0) list.appendCString(" ");
            list.append((String*)be.missing().get(k));
        }
        Stdio.printf("xcc: %s: unsupported: %s\n", d.fe().input().cString(), list.cString());
        Process.exit((i32)3); return;
    }
    if (d.keepAsm()) {
        if (!Files.writeText(d.fe().output(), prog)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            Process.exit((i32)1); return;
        }
        return;
    }

    // ── -c: an object, not an image ──────────────────────────────────────
    if (d.compileOnly()) {
        String* one = new String();
        one.append(x86ClassAllocStubs(prog, false));
        one.appendCString("\n");
        one.append(prog);
        X86Asm* as = new X86Asm();
        as.assemble(one);
        if (as.failed()) {
            Stdio.printf("xcc: %s\n", as.why().cString());
            Process.exit((i32)1); return;
        }
        Elf64* w = new Elf64();
        Data* img = w.objectFromText(as.text(), as.data(), as.symbols(),
                                      as.dataSyms(), as.globalSyms(), as.commonSyms(), as.fixups());
        if (w.failed() || img == (Data*)0) {
            Stdio.printf("xcc: %s\n", w.failed() ? w.why().cString() : "object write failed");
            Process.exit((i32)1); return;
        }
        if (!Files.writeData(d.fe().output(), img)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            Process.exit((i32)1); return;
        }
        writeObjectSidecars(d);
        return;
    }

    linkX86_64(d, prog);
}

// The x86-64 link, from program asm (or none — an object-only link) to the
// ELF on disk. Split out of emitX86_64 so `xcc a.o b.o -o prog` can reach it
// without a module (bug 138).
void linkX86_64(DriverOptions* d, String* prog)
{
    String* libdir = muslLibDir(d.fe());
    if (libdir == 0) {
        Stdio.printf("xcc: error: the x86-64 static link needs musl's libc.a and no copy was found.\n"
                     "  looked in $XTC_MUSL_ROOT/lib, /opt/clang/linux/x86_64-linux-musl/lib,\n"
                     "  and <support>/x86_64-sysroot\n");
        Process.exit((i32)1); return;
    }

    // The runtime pieces, each its OWN input for the label-namespacing reason
    // above, in the order the reference passes them.
    Array* srcs = new Array();
    Array* rtNames = new Array();
    // crt-linux.s is the process entry — a SHARED OBJECT has none, and taking
    // it would leave the library importing `main`, which only a program
    // defines. Same rule as the arm64 dylib.
    if (!d.emitLib()) rtNames.add((Object*)String.withCString("crt-linux.s"));
    rtNames.add((Object*)String.withCString("sys-linux.s"));
    rtNames.add((Object*)String.withCString("rtgen-linux.s"));
    rtNames.add((Object*)String.withCString("rtfiles-linux.s"));
    rtNames.add((Object*)String.withCString("libmgen-linux.s"));
    for (u32 k = (u32)0; k < rtNames.count(); k = k + (u32)1) {
        String* t = readRuntimeIn(d.fe(), "x86_64/runtime", (String*)rtNames.get(k));
        if (t == 0) {
            Stdio.printf("xcc: error: cannot read %s from the support tree\n",
                         ((String*)rtNames.get(k)).cString());
            Process.exit((i32)1); return;
        }
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
            String* lp = resolveLinkInput(d, (String*)li.get(i));
            if (lp == (String*)0) continue;            // a system library: dyld/ld finds it
            if (lp.hasSuffix(String.withCString(".a"))) { ars.add((Object*)lp); continue; }
            if (lp.hasSuffix(String.withCString(".o"))) { objs.add((Object*)lp); continue; }
            if (lp.hasSuffix(String.withCString(".so"))) continue;   // handled as a dep below
            Stdio.printf("xcc: error: -Xlinker '%s': this driver links x86-64 "
                         "in-house and takes .a archives, .o objects and .so "
                         "libraries — it has no external linker to hand anything "
                         "else to\n", lp.cString());
            Process.exit((i32)1); return;
        }
    }
    if (d.frameworks().count() > (u32)0) {
        Stdio.printf("xcc: error: -framework is a macOS concept and this is an "
                     "x86-64 ELF link\n");
        Process.exit((i32)1); return;
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
        img = ln.linkShared(srcs, objs, ars,
                            baseNameOf(d.fe().output()), (Array*)0,
                            new Array(), (String*)0, iface);
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
        Stdio.printf("xcc: %s\n", ln.why().cString());
        Process.exit((i32)1); return;
    }
    if (!Files.writeData(d.fe().output(), img)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        Process.exit((i32)1); return;
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
    Opt* prof = Opt.atLevel(d.opt(), px);
    // A LIBRARY keeps every function it defines — the client is what calls
    // them, and dead-function elimination cannot see the client.
    if (d.emitLib() || d.compileOnly()) prof.setKeepAllFunctions(true);
    prof.run(mod);

    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    Arm9* be = new Arm9();
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
        Process.exit((i32)3); return;
    }
    // The xtc entry gives up the name `main` to the runtime, unless this is a
    // library, which has no entry to give up.
    // An OBJECT keeps `main`: the runtime that renames it is not in this file,
    // and the final link is what decides which module owns the entry.
    if (!d.emitLib() && !d.compileOnly()) prog = renameArm9Main(prog);
    if (d.keepAsm()) {
        if (!Files.writeText(d.fe().output(), prog)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            Process.exit((i32)1); return;
        }
        return;
    }

    // ── -c: an object, not an image ──────────────────────────────────────
    //
    // The runtime is deliberately absent: it belongs to the final link, and
    // baking it into every object would collide the moment two of them met.
    if (d.compileOnly()) {
        String* one = new String();
        one.append(arm9ClassAllocStubs(prog));
        one.appendCString("\n");
        one.append(prog);
        Arm32* oas = new Arm32();
        Array* otext = oas.assemble(one);
        if (oas.failed()) {
            Stdio.printf("xcc: %s\n", oas.why().cString());
            Process.exit((i32)1); return;
        }
        Elf32* ow = new Elf32();
        Array* img = ow.write(otext, oas.data(), oas.symbols(), oas.relocations());
        if (img == (Array*)0) {
            Stdio.printf("xcc: error: arm9 object write failed\n");
            Process.exit((i32)1); return;
        }
        Data* od = Data.withCapacity(img.count());
        for (u32 i = (u32)0; i < img.count(); i = i + (u32)1)
            od.appendByte((u8)((Number*)img.get(i)).asU32());
        if (!Files.writeData(d.fe().output(), od)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            Process.exit((i32)1); return;
        }
        writeObjectSidecars(d);
        return;
    }

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
            Process.exit((i32)1); return;
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
    Array* text = as.assemble(all);
    if (as.failed()) {
        Stdio.printf("xcc: %s\n", as.why().cString());
        Process.exit((i32)1); return;
    }

    // DT_NEEDED. The loader resolves an import by NAME across the libraries it
    // has mapped, so every library that might satisfy one has to be listed —
    // `pow` lives in libm.so, and recording only libc.so is how a program
    // linked cleanly and then failed to LOAD.
    Array* needed = new Array();
    Array* nl = d.fe().neededLibs();
    for (u32 i = (u32)0; nl != (Array*)0 && i < nl.count(); i = i + (u32)1)
        needed.add((Object*)((String*)nl.get(i)).lastPathComponent());
    Array* sysLibs = new Array();
    sysLibs.add((Object*)String.withCString("libc.so"));
    sysLibs.add((Object*)String.withCString("libm.so"));
    for (u32 i = (u32)0; i < sysLibs.count(); i = i + (u32)1)
        if (arm9SysrootLib(d, (String*)sysLibs.get(i)) != (String*)0)
            needed.add(sysLibs.get(i));

    Array* iface = new Array();
    String* ij = d.fe().ifaceJson();
    if (ij != (String*)0)
        for (u32 i = (u32)0; i < ij.byteLength(); i = i + (u32)1)
            iface.add((Object*)Number.withU32((u32)ij.byteAt(i)));

    Elf32* w = new Elf32();
    Array* img = w.sharedObject(text, as.data(), as.symbols(), as.relocations(),
                                needed,
                                d.emitLib() ? baseNameOf(d.fe().output()) : (String*)0,
                                iface);
    if (w.failed() || img == (Array*)0) {
        Stdio.printf("xcc: %s\n", w.failed() ? w.why().cString() : "arm9 link failed");
        Process.exit((i32)1); return;
    }
    Data* out = Data.withCapacity(img.count());
    for (u32 i = (u32)0; i < img.count(); i = i + (u32)1)
        out.appendByte((u8)((Number*)img.get(i)).asU32());
    if (!Files.writeData(d.fe().output(), out)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        Process.exit((i32)1); return;
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

void emitM68k(DriverOptions* d, IRModule* mod)
{
    Opt* prof = (Opt*)0;
    OptProfile* p68 = OptProfile.forTarget(String.withCString("atarist"));
    Opt.setUnrollOverride(p68, d.unroll());
    prof = Opt.atLevel(d.opt(), p68);
    prof.run(mod);

    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    M68k* be = new M68k();
    String* prog = be.assembly(mod);
    if (be.failed()) {
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < be.missing().count(); k = k + (u32)1) {
            if (k > (u32)0) list.appendCString(" ");
            list.append((String*)be.missing().get(k));
        }
        Stdio.printf("xcc: %s: unsupported: %s\n", d.fe().input().cString(),
                     list.cString());
        Process.exit((i32)3); return;
    }

    // `-o x.s` stops here, as it does on every other target.
    if (d.keepAsm()) {
        if (!Files.writeText(d.fe().output(), prog)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            Process.exit((i32)1); return;
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
    as.assemble(prog);
    if (as.failed()) {
        Stdio.printf("xcc: assembly failed: %s\n", as.why().cString());
        Process.exit((i32)1); return;
    }
    Array* image = as.image();
    Data* out = Data.withCapacity((u32)0);
    for (u32 k = (u32)0; k < image.count(); k = k + (u32)1)
        out.appendByte((u8)((Number*)image.get(k)).asU32());
    if (!Files.writeData(d.fe().output(), out)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        Process.exit((i32)1); return;
    }
}

void emitXt6502(DriverOptions* d, IRModule* mod)
{
    String* root = supportRoot(d.fe());
    if (root == (String*)0) {
        Stdio.printf("xcc: error: cannot find the support tree (-H)\n");
        Process.exit((i32)1); return;
    }
    String* lnk = String.withString(root);
    lnk.appendCString("/xt6502/layouts/xt.lnk");
    Layout* layout = Layout.read(lnk);
    if (layout.failed()) {
        Stdio.printf("xcc: %s: %s\n", lnk.cString(), layout.why().cString());
        Process.exit((i32)1); return;
    }
    // The model's NAME is its layout file's stem; the emitted header carries it.
    layout.setName(String.withCString("xt"));

    Opt* opt = Opt.atLevel(d.opt(), OptProfile.forTarget(String.withCString("xt6502")));
    opt.run(mod);
    if (opt.failed()) {
        Stdio.printf("xcc: %s: opt unsupported: %s\n", d.fe().input().cString(),
                     opt.why() == 0 ? "?" : opt.why().cString());
        Process.exit((i32)3); return;
    }
    // The lowering passes just made values with no id, and a back end keys its
    // frame slots off value ids.
    for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
        ((IRFunc*)mod.funcs().get(f)).numberFreshValues();

    Xt6502* be = new Xt6502();
    be.setLayout(layout);
    String* asmText = be.assembly(mod);
    if (be.failed()) {
        String* list = String.withCString("");
        for (u32 k = (u32)0; k < be.missing().count(); k = k + (u32)1) {
            if (k > (u32)0) list.appendCString(" ");
            list.append((String*)be.missing().get(k));
        }
        Stdio.printf("xcc: %s: unsupported: %s\n", d.fe().input().cString(), list.cString());
        Process.exit((i32)3); return;
    }

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
    asmText = Runtime6502.wrap(asmText, mod, layout, root,
                               String.withCString("xt6502/runtime/xt6502-harness.asm"));

    if (d.keepAsm()) {
        if (!Files.writeText(d.fe().output(), asmText)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            Process.exit((i32)1);
        }
        return;
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
    Array* lines = a.preprocess(asmText, d.fe().output());
    a.assemble(lines);
    if (a.errors().count() > (u32)0) {
        for (u32 k = (u32)0; k < a.errors().count(); k = k + (u32)1)
            Stdio.printf("xcc: assembly failed: %s\n", ((String*)a.errors().get(k)).cString());
        Process.exit((i32)1); return;
    }
    u32 entry = (u32)$2000;
    if (a.segments().count() > (u32)0)
        entry = ((XaSegment*)a.segments().get((u32)0)).origin();
    Array* img = a.writeBankedXex(entry);
    Data* img8 = Data.withCapacity((u32)0);
    for (u32 k = (u32)0; k < img.count(); k = k + (u32)1)
        img8.appendByte((u8)((Number*)img.get(k)).asU32());
    if (!Files.writeData(d.fe().output(), img8)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        Process.exit((i32)1);
    }
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
Array* mergeLinkObjects(DriverOptions* d, Array* mtext, Array* mdata, Map* msyms,
                        Array* mdataSyms, Array* mfix, Array* extra)
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
        ml.merge(objs, ars, mtext, mdata, msyms, mdataSyms, mfix, mObjc);
        if (ml.rc() != (u32)0) {
            Stdio.printf("xcc: error: arm64 link: %s\n", ml.why() == 0 ? "?" : ml.why().cString());
            Process.exit((i32)1); return (Array*)0;
        }
    }
    return MachOLink.repartitionObjc(mdata, mObjc, msyms, mdataSyms, mfix);
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
        if (!op.hasSuffix(String.withCString(".o"))) continue;
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
void linkObjectsArm64(DriverOptions* d)
{
    String* crt = readRuntime(d.fe(), String.withCString("crt-macos.s"));
    String* rt  = readRuntime(d.fe(), String.withCString("rt-macos.s"));
    if (crt == 0 || rt == 0) {
        Stdio.printf("xcc: error: cannot read the arm64 runtime from the support tree\n");
        Process.exit((i32)1); return;
    }
    String* combined = new String();
    combined.append(crt); combined.appendByte((u8)'\n'); combined.append(rt);
    if (isIos(d)) { combined.appendByte((u8)'\n'); combined.append(iosRuntimeSource(d)); }   // stage 4 shim
    Arm64Asm* as = new Arm64Asm();
    as.assemble(Arm64Asm.machoDialectFromElf(combined));
    as.demoteCommonsToLocalData();
    if (as.failed()) {
        Stdio.printf("xcc: assembly failed: %s\n", as.why().cString());
        Process.exit((i32)1); return;
    }
    Object* entry = as.symbols().get((Hashable*)String.withCString("_xtc_start"));
    if (entry == (Object*)0) entry = as.symbols().get((Hashable*)String.withCString("_main"));
    if (entry == (Object*)0) {
        Stdio.printf("xcc: no entry symbol (_xtc_start / _main)\n");
        Process.exit((i32)1); return;
    }
    Array* dataBytes = as.dataBytes();
    Array* fixups    = as.fixups();
    Array* objcSects = mergeLinkObjects(d, as.textBytes(), dataBytes, as.symbols(),
                                        as.dataSyms(), fixups, d.objectInputs());
    u32 miLen = Arm64Asm.appendModInit(as, dataBytes, fixups);

    // What the objects `#import <Lib>`ed (their .xtc.needs sidecars), then
    // the libraries and frameworks named on the line — one rule (arm64LinkDeps).
    Array* deps = arm64LinkDeps(d, objectNeeds(d.objectInputs()), d.objectInputs());
    MachO* m = new MachO();
    if (isIos(d)) m.setApplePlatform(d.arch());
    m.setDeps(deps);
    m.executable(as.textBytes(), ((Number*)entry).asU32(), as.symbols(),
                 dataBytes, as.dataSyms(), fixups, miLen, objcSects);
    Array* image = m.bytes();
    Data* out = Data.withCapacity(image.count());
    for (u32 i = (u32)0; i < image.count(); i = i + (u32)1)
        out.appendByte((u8)((Number*)image.get(i)).asU32());
    if (!Files.writeData(d.fe().output(), out)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        Process.exit((i32)1); return;
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
        String* text = shiftIRIndices((String*)texts.get(ti), layouts.count(), constants.count());
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
                bool dup = seenSym.get((Hashable*)nm) != (Object*)0;
                if (!dup) seenSym.set((Hashable*)nm, (Object*)Number.withU32((u32)1));
                String* blk = String.withString(l);
                while (i + (u32)1 < lines.count()) {
                    String* nx = ((String*)lines.get(i + (u32)1)).trimmed();
                    if (!nx.hasPrefix(String.withCString("attributes:"))) break;
                    i = i + (u32)1;
                    blk.appendCString("\n"); blk.append((String*)lines.get(i));
                }
                if (!dup) symbols.add((Object*)blk);
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
    if (pem == (String*)0) { Stdio.printf("xcc: error: --sign: cannot read '%s'\n", d.signIdentity().cString()); Process.exit((i32)1); return; }
    String* pass = Platform.env(String.withCString("XCC_SIGN_PASSPHRASE"));
    if (pass != 0 && pass.byteLength() == (u32)0) pass = (String*)0;
    Identity* id = Identity.fromPEM(pem, pass);
    if (id.why() != (String*)0) { Stdio.printf("xcc: error: --sign: %s\n", id.why().cString()); Process.exit((i32)1); return; }
    Data* md = Files.readData(outPath);
    if (md == (Data*)0) { Stdio.printf("xcc: error: --sign: cannot read '%s'\n", outPath.cString()); Process.exit((i32)1); return; }
    Array* ent = id.entitlements();
    if (d.signEntitlements() != (String*)0) {
        Data* ed = Files.readData(d.signEntitlements());
        if (ed == (Data*)0) { Stdio.printf("xcc: error: --sign-entitlements: cannot read '%s'\n", d.signEntitlements().cString()); Process.exit((i32)1); return; }
        ent = Bytes.fromData(ed);
    }
    CodeSign* cs = new CodeSign();
    Array* img = cs.resign(Bytes.fromData(md), outPath.lastPathComponent(), id, ent, (Array*)0, (Array*)0, String.withCString("20260101000000Z"));
    if (img == (Array*)0) { Stdio.printf("xcc: error: --sign: %s\n", cs.why().cString()); Process.exit((i32)1); return; }
    if (!Files.writeData(outPath, Bytes.toData(img))) { Stdio.printf("xcc: error: cannot write '%s'\n", outPath.cString()); Process.exit((i32)1); return; }
    Files.setExecutable(outPath);
    if (!d.quiet()) Stdio.printf("xcc: developer-signed -> '%s'\n", outPath.cString());
}

// The iOS platform shim (support/ios/runtime, iOS.md stage 4): the
// simulator or device flavour of xtios.c's assembly, linked as one more
// runtime source after rt-macos.s. 0 when the target is not iOS.
String* iosRuntimeSource(DriverOptions* d)
{
    if (!isIos(d)) return (String*)0;
    String* name = String.withCString(d.arch().equals(String.withCString("ios-sim")) ? "xtios-sim.s" : "xtios.s");
    String* t = readRuntimeIn(d.fe(), "ios/runtime", name);
    if (t == 0) {
        Stdio.printf("xcc: error: cannot read %s from the support tree\n", name.cString());
        Process.exit((i32)1);
    }
    return t;
}

// Objects as inputs, dispatched per target. What is not ported is REFUSED
// naming the gap, never linked as something else.
void linkObjects(DriverOptions* d)
{
    bool anyObject = false;
    for (u32 i = (u32)0; i < d.objectInputs().count(); i = i + (u32)1)
        if (((String*)d.objectInputs().get(i)).hasSuffix(String.withCString(".o"))) anyObject = true;
    if (!anyObject) {
        Stdio.printf("xcc: error: a link of archives alone has nothing to seed the demand — "
                     "name at least one .o\n");
        Process.exit((i32)1); return;
    }
    if (d.compileOnly() || d.emitLib()) {
        Stdio.printf("xcc: error: -c / --emit-lib take source, not objects\n");
        Process.exit((i32)1); return;
    }
    if (d.fe().output() == (String*)0) {
        Stdio.printf("xcc: error: an object link needs -o <program>\n");
        Process.exit((i32)1); return;
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
                Process.exit((i32)1); return;
            }
            irs.add((Object*)t);
        }
        String* merged = mergeIRTexts(irs);
        IrParser* ip = new IrParser();
        IRModule* mod = ip.run(merged);
        if (mod == 0 || ip.failed()) {
            Stdio.printf("xcc: error: -flto: the merged IR did not parse: %s\n",
                         ip.why() == 0 ? "?" : ip.why().cString());
            Process.exit((i32)3); return;
        }
        d.setIrText(merged);
        d.fe().setTarget(backendTargetOf(d));
    if (isIos(d)) d.fe().setLibPlatform(d.arch());
        emitModule(d, mod);
        return;
    }
    if (d.arch().equals(String.withCString("arm64")) || isIos(d)) { linkObjectsArm64(d); return; }
    if (isX86_64(d)) { linkX86_64(d, String.withCString("")); return; }
    if (d.arch().equals(String.withCString("win64"))) {
        // A win64 object link is a STATIC PE and cannot record a DLL
        // dependency for an xtc library the objects imported.
        Array* needs = objectNeeds(d.objectInputs());
        if (needs.count() > (u32)0) {
            Stdio.printf("xcc: error: these objects import xtc libraries, but a win64 object link "
                         "cannot record a DLL dependency for them yet.\n  Link from source, or "
                         "compile the modules together.\n");
            Process.exit((i32)1); return;
        }
        linkWin64(d, String.withCString(""));
        return;
    }
    Stdio.printf("xcc: error: linking objects for '%s' is not ported in this driver yet "
                 "(arm64, ios, ios-sim, x86_64 and win64 are)\n", d.arch().cString());
    Process.exit((i32)1);
}

void main(void)
{
    DriverOptions* d = parseDriverArgs();
    if (d == 0 || (d.fe().input() == 0 && d.objectInputs().count() == (u32)0)) {
        Stdio.printf("usage: xcc [-A arm64|android|xt6502|m68k|wasm32|x86_64|arm9] [-On] [-H home] [-I dir] "
                     "[-D k=v] <file.xc> -o <out>\n");
        Process.exit((i32)2); return;
    }
    // `--emit-lib` is implemented for wasm32 only. On the other targets the
    // driver ran the ordinary EXECUTABLE path and said nothing: `-A arm64
    // --emit-lib` produced a Mach-O executable where the reference produces a
    // dylib, with no `.xtc.iface` beside it, and exit 0. A library that is
    // silently not a library is the worst of the three outcomes — worse than
    // refusing, and worse than failing — because it is discovered by whatever
    // tries to LOAD it, a build step away. See private:docs/bugs/097.
    if (d.emitLib() && !isWasm(d) && !isX86_64(d) && !isArm9(d)
        && !d.arch().equals(String.withCString("arm64"))) {
        Stdio.printf("xcc: error: --emit-lib is implemented for wasm32, arm64, "
                     "x86_64 and arm9 in this driver (task #52); '%s' would need its "
                     "shared-library writer ported first.\n"
                     "  Use `xcc-bootstrap --emit-lib -A %s` until then.\n",
                     d.arch().cString(), d.arch().cString());
        Process.exit((i32)1); return;
    }
    if (!d.arch().equals(String.withCString("arm64")) && !isAndroid(d)
        && !isXt6502(d) && !isM68k(d) && !isWasm(d) && !isX86_64(d) && !isArm9(d)
        && !isIos(d)
        && !d.arch().equals(String.withCString("win64"))) {
        // Say what is ACTUALLY in the way. This used to tell every refused
        // target it needed "archive reading in the linker — task #47", which
        // is true of x86_64 and win64 and of nothing else, so anyone asking
        // for arm9 or ios was sent to the wrong work.
        string why = "it is not implemented in this driver";
        if (d.arch().equals(String.withCString("win64")))
            why = "its linker must read .a archives and foreign COFF objects first (task #47); "
                  "the ELF half of that is done and x86_64 now works";
        Stdio.printf("xcc: error: '%s' is not wired in this driver yet — %s.\n"
                     "  built in: arm64, ios, ios-sim, android, xt6502, m68k, wasm32,\n"
                     "             x86_64, win64, arm9\n",
                     d.arch().cString(), why);
        Process.exit((i32)2); return;
    }
    // -c is x86_64 only for now: the other targets need their own object
    // writers ported (Mach-O for arm64/android, PE/COFF for win64, and the
    // ELF32 one exists but is not wired). Refusing is the point — a driver
    // that quietly built an EXECUTABLE for `-c` would be discovered by whatever
    // tried to link it.
    if (d.compileOnly() && !isX86_64(d) && !isArm9(d) && !isIos(d)
        && !d.arch().equals(String.withCString("win64"))
        && !d.arch().equals(String.withCString("arm64"))) {
        Stdio.printf("xcc: error: -c is implemented for arm64, ios, ios-sim, x86_64, win64 and arm9 "
                     "in this driver (task #63); '%s' needs its object writer "
                     "ported first.\n", d.arch().cString());
        Process.exit((i32)1); return;
    }
    if (d.fe().boundsCheck() && (isXt6502(d) || isAndroid(d))) {
        Stdio.printf("xcc: error: -fbounds-check is native-only (arm64); "
                     "'%s' has no checked runtime\n", d.arch().cString());
        Process.exit((i32)2); return;
    }
    d.fe().setTarget(backendTargetOf(d));
    if (isIos(d)) d.fe().setLibPlatform(d.arch());

    // Objects as inputs: the link step. No front end runs — the runtime is
    // the primary input and the objects ride as extras, exactly the shape the
    // linker already takes for archives (separate-compilation Stage 2).
    if (d.fe().input() == 0) { linkObjects(d); return; }
    if (!d.compileOnly() && d.fe().output() != (String*)0
        && d.fe().output().hasSuffix(String.withCString(".o"))) {
        Stdio.printf("xcc: error: '-o %s' without -c would LINK an executable and name it "
                     "'.o'. Use `-c` to compile to an object, or choose another output name\n",
                     d.fe().output().cString());
        Process.exit((i32)1); return;
    }
    if (d.objectInputs().count() > (u32)0) {
        Stdio.printf("xcc: error: a source file and object files cannot be mixed on one line — "
                     "compile the source with -c first, then link the objects\n");
        Process.exit((i32)1); return;
    }

    IRModule* mod = Frontend.lower(d.fe());
    if (mod == 0) { Process.exit((i32)3); return; }

    // --emit-iface stops HERE. Running the optimiser and a back end would be
    // pure latency for a caller that wanted the declarations.
    if (d.emitIfaceOnly()) {
        String* ij = d.fe().ifaceJson();
        if (ij == (String*)0 || ij.byteLength() == (u32)0) {
            Stdio.error(String.withCString(
                "xcc: --emit-iface: no public declarations to describe\n"));
            Process.exit((i32)1); return;
        }
        String* out = d.fe().output();
        if (out != (String*)0 && !out.equals(String.withCString("-"))) {
            if (!Files.writeText(out, ij)) {
                Stdio.printf("xcc: error: cannot write '%s'\n", out.cString());
                Process.exit((i32)1); return;
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
        Process.exit((i32)3); return;
    }
    mod = parsed;
    // Stashed for `-c`, which keeps the module's IR beside the object so a
    // later link can re-run the inliner across module boundaries — the thing
    // per-object compilation otherwise gives up.
    d.setIrText(irText);
    emitModule(d, mod);
}

// From a (round-tripped) IR module to the output file, per target. Split out
// of main so a link-time recompile (`-flto`, bug 139) can enter with the
// objects' MERGED module where a normal build enters with the front end's.
void emitModule(DriverOptions* d, IRModule* mod)
{

    // A link input this target's path does not consume must not be dropped.
    // arm64 and x86_64 honour them below; anything else says so, because a
    // library silently missing from a link is a symbol that resolves nowhere
    // and a failure with no message at run time.
    if ((d.linkInputs().count() > (u32)0 || d.frameworks().count() > (u32)0)
        && !isX86_64(d) && !d.arch().equals(String.withCString("arm64"))
        && !isAndroid(d) && !isIos(d)) {
        Stdio.printf("xcc: error: -Xlinker/-l/-framework is not wired for '%s' in "
                     "this driver — the link would silently omit it.\n",
                     d.arch().cString());
        Process.exit((i32)1); return;
    }
    if (isXt6502(d)) { emitXt6502(d, mod); return; }
    if (isX86_64(d)) { emitX86_64(d, mod); return; }
    if (d.arch().equals(String.withCString("win64"))) { emitWin64(d, mod); return; }
    if (isArm9(d))   { emitArm9(d, mod);   return; }
    if (isM68k(d))   { emitM68k(d, mod);   return; }
    if (isWasm(d))   { emitWasm(d, mod);   return; }

    OptProfile* prof = OptProfile.forTarget(backendTargetOf(d));
    Opt.setUnrollOverride(prof, d.unroll());
    Opt* opt = Opt.atLevel(d.opt(), prof);
    // A LIBRARY's public surface is every function it defines: nothing in the
    // module calls them, the CLIENT does, and dead-function elimination cannot
    // see the client. Wired into the wasm path first and missing here, which
    // cost a library its `Adder$init` — a constructor no internal code calls —
    // and the app that called it died at LOAD naming libSystem.
    // An OBJECT's functions are all potentially called from ANOTHER object,
    // for the same reason.
    if (d.emitLib() || d.compileOnly()) opt.setKeepAllFunctions(true);
    opt.run(mod);

    Arm64* be = new Arm64();
    be.setAapcs64Abi(isAndroid(d));
    be.setLseAtomics(!isAndroid(d));
    String* prog = be.assembly(mod);
    if (be.failed()) {
        Stdio.printf("xcc: %s: unsupported: %s\n", d.fe().input().cString(),
                     be.why() == 0 ? "?" : be.why().cString());
        Process.exit((i32)3); return;
    }

    if (d.keepAsm()) {
        if (!Files.writeText(d.fe().output(), prog)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            Process.exit((i32)1); return;
        }
        return;
    }

    // ── -c: an object, not an image ──────────────────────────────────────
    //
    // The object carries the MODULE and nothing else: its own code plus its
    // per-class allocators, deliberately NOT the crt or the runtime. Those
    // belong to the final link and baking them into every object would collide
    // the moment two of them met.
    if (d.compileOnly()) {
        String* one = new String();
        one.append(classAllocStubs(prog));
        one.appendByte((u8)'\n');
        one.append(prog);
        Arm64Asm* oas = new Arm64Asm();
        oas.assemble(Arm64Asm.machoDialectFromElf(one));
        if (oas.failed()) {
            Stdio.printf("xcc: assembly failed: %s\n", oas.why().cString());
            Process.exit((i32)1); return;
        }
        MachO* mo = new MachO();
        // The platform stamp — the reference passes `-platform` to its object
        // writer for -A ios/ios-sim (bug 137: the port wrote PLATFORM_MACOS).
        if (isIos(d)) mo.setApplePlatform(d.arch());
        Array* img = mo.objectFromText(oas.textBytes(), oas.dataBytes(), oas.symbols(),
                                       oas.dataSyms(), oas.fixups(), oas.globals(), oas.commonSyms());
        if (img == (Array*)0) {
            Stdio.printf("xcc: error: arm64 object write failed\n");
            Process.exit((i32)1); return;
        }
        Data* od = Data.withCapacity(img.count());
        for (u32 i = (u32)0; i < img.count(); i = i + (u32)1)
            od.appendByte((u8)((Number*)img.get(i)).asU32());
        if (!Files.writeData(d.fe().output(), od)) {
            Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
            Process.exit((i32)1); return;
        }
        writeObjectSidecars(d);
        return;
    }

    // The whole image is ONE assembly unit: crt, runtime, per-class allocators,
    // then the program. That is what lets the linker resolve everything at link
    // time and leave only the imports dynamic.
    bool android = isAndroid(d);
    String* crt = readRuntime(d.fe(), String.withCString(android ? "crt-android.s" : "crt-macos.s"));
    String* rt  = readRuntime(d.fe(), String.withCString(android ? "rt-android.s"  : "rt-macos.s"));
    if (crt == 0 || rt == 0) {
        Stdio.printf("xcc: error: cannot read the arm64 runtime from the support tree\n");
        Process.exit((i32)1); return;
    }
    // The checked runtime is a SEPARATE translation unit — it walks from its
    // own frame and is built with different flags — so it is concatenated only
    // when asked for. An ordinary build links none of it.
    String* checked = (String*)0;
    if (d.fe().boundsCheck()) {
        checked = readRuntime(d.fe(), String.withCString("rt-checked-macos.s"));
        if (checked == 0) {
            Stdio.printf("xcc: error: -fbounds-check needs rt-checked-macos.s in the support tree\n");
            Process.exit((i32)1); return;
        }
    }
    String* stubs = classAllocStubs(prog);
    String* combined = new String();
    // A LIBRARY gets the runtime but NOT the crt. The crt is the program
    // entry — it calls `_main` — so bundling it into a library leaves the
    // library importing a symbol only a PROGRAM defines, and the load fails
    // with `symbol not found in flat namespace '_main'` naming neither the
    // library nor the crt. Mirrors the reference, which concatenates
    // rt + stubs + program for a dylib and crt + rt + … for an executable.
    if (!d.emitLib()) { combined.append(crt); combined.appendByte((u8)'\n'); }
    combined.append(rt);        combined.appendByte((u8)'\n');
    if (isIos(d)) { combined.append(iosRuntimeSource(d)); combined.appendByte((u8)'\n'); }   // stage 4 shim
    if (checked != 0) { combined.append(checked); combined.appendByte((u8)'\n'); }
    combined.append(android ? stripLeadingUnderscore(stubs) : stubs);
    combined.appendByte((u8)'\n');
    combined.append(android ? stripLeadingUnderscore(prog) : prog);

    Arm64Asm* as = new Arm64Asm();
    as.assemble(Arm64Asm.machoDialectFromElf(combined));
    as.demoteCommonsToLocalData();
    if (as.failed()) {
        Stdio.printf("xcc: assembly failed: %s\n", as.why().cString());
        Process.exit((i32)1); return;
    }

    // --emit-apk: the program is packaged as a NativeActivity payload, which is
    // a SHARED OBJECT and not an executable — Android dlopen()s it and calls
    // ANativeActivity_onCreate. So the crt goes away, the glue comes in, and the
    // user's `main` is renamed to the `xt_main` the glue calls.
    if (android && d.emitApk()) {
        emitApkPackage(d, prog);
        return;
    }

    Array* image = (Array*)0;
    if (android) {
        Array* needed = new Array();
        needed.add((Object*)String.withCString("libc.so"));
        needed.add((Object*)String.withCString("libm.so"));
        needed.add((Object*)String.withCString("libdl.so"));
        // Bug 124: as above — append the constructor array before linking.
        Array* aData = as.dataBytes();
        Array* aFix  = as.fixups();
        u32 aMi = Arm64Asm.appendModInit(as, aData, aFix);
        ElfArm64* w = new ElfArm64();
        w.image(as.textBytes(), aData, as.symbols(), as.dataSyms(),
                new Array(), aFix, (String*)0, needed,
                String.withCString("_start"), aMi);
        if (w.failed()) {
            Stdio.printf("xcc: android link failed: %s\n", w.why().cString());
            Process.exit((i32)1); return;
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
            Process.exit((i32)1); return;
        }
        // Bug 138: `-Xlinker x.o` / `-Xlinker lib.a` are OBJECTS to merge (a
        // platform shell compiled by clang, a static archive), not libraries
        // to load — they used to become an LC_LOAD_DYLIB naming a .o, which
        // dyld refused at launch. Merged into the assembler's own model,
        // exactly as xcc-ln-arm64 does, BEFORE the mod-init tail is appended.
        Array* dataBytes = as.dataBytes();
        Array* fixups    = as.fixups();
        Array* objcSects = mergeLinkObjects(d, as.textBytes(), dataBytes, as.symbols(),
                                            as.dataSyms(), fixups, new Array());
        // Bug 066: the __mod_init_func pointer array goes at the END of __data,
        // with its fixups shifted to match, so the writer can give that tail an
        // S_MOD_INIT_FUNC_POINTERS section. Without it dyld sees inert data and
        // no load-time constructor runs. Same placement as xtld64, because the
        // two must produce the same bytes.
        u32 miLen = as.modInitBytes().count();
        if (miLen > (u32)0) {
            while (dataBytes.count() % (u32)8 != (u32)0)
                dataBytes.add((Object*)Number.withU32((u32)0));
            u32 base = dataBytes.count();
            for (u32 i = (u32)0; i < as.modInitBytes().count(); i = i + (u32)1)
                dataBytes.add(as.modInitBytes().get(i));
            for (u32 i = (u32)0; i < as.modInitFixups().count(); i = i + (u32)1) {
                Arm64Fixup* f = (Arm64Fixup*)as.modInitFixups().get(i);
                fixups.add((Object*)Arm64Fixup.make(base + f.offset(), f.kind(),
                                                    f.symbol(), f.scale()));
            }
        }
        MachO* m = new MachO();
        // An EXECUTABLE for -A ios/ios-sim carries the iOS LC_BUILD_VERSION
        // (PLATFORM_IOS 2 / IOSSIMULATOR 7, minos 15.0), as the reference's
        // xcc-ln-arm64 is told with `-platform`. The dylib path is not stamped
        // there either, so it is not stamped here (bug 137).
        if (isIos(d) && !d.emitLib()) m.setApplePlatform(d.arch());
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
            Array* iface = new Array();
            String* ij = d.fe().ifaceJson();
            if (ij != (String*)0)
                for (u32 i = (u32)0; i < ij.byteLength(); i = i + (u32)1)
                    iface.add((Object*)Number.withU32((u32)ij.byteAt(i)));
            m.dylib(as.textBytes(), baseNameOf(d.fe().output()), exports, iface,
                    as.symbols(), dataBytes, as.dataSyms(), fixups, miLen, objcSects);
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
            m.executable(as.textBytes(), ((Number*)entry).asU32(), as.symbols(),
                         dataBytes, as.dataSyms(), fixups, miLen, objcSects);
        }
        image = m.bytes();
    }

    Data* out = Data.withCapacity((u32)0);
    for (u32 i = (u32)0; i < image.count(); i = i + (u32)1)
        out.appendByte((u8)((Number*)image.get(i)).asU32());
    if (!Files.writeData(d.fe().output(), out)) {
        Stdio.printf("xcc: error: cannot write '%s'\n", d.fe().output().cString());
        Process.exit((i32)1); return;
    }
    Files.setExecutable(d.fe().output());
    if (!d.emitLib()) signIfRequested(d, d.fe().output());   // --sign (144): the Mach-O executable
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

// What this compiler accepts. Deliberately NOT a copy of the reference's help:
// it lists what THIS driver implements, because a help text that promises flags
// the compiler refuses is worse than a short one.
void usage(void)
{
    Stdio.printf("Usage: xcc [options] <input.xc>\n");
    Stdio.printf("\n");
    Stdio.printf("  -o <path>          output file\n");
    // Every target the driver ACTUALLY builds. m68k and wasm32 both worked
    // and neither was listed, so the help understated the compiler and sent
    // readers to another toolchain for a target it already had.
    Stdio.printf("  -A <arch>          arm64 (default) | android | xt6502 | m68k | wasm32 | x86_64\n");
    Stdio.printf("  -m <layout>        6502 memory layout (xt, xt6502/xt) — implies -A xt6502\n");
    Stdio.printf("  -O0 … -O3          optimisation level, JOINED (-O0, not -O 0). Default -O3\n");
    Stdio.printf("  -I <path>          add an include search path\n");
    Stdio.printf("  -D <name[=value]>  define a preprocessor symbol\n");
    Stdio.printf("  -L <path>          add a library search path\n");
    Stdio.printf("  -H <path>          root holding the support tree\n");
    Stdio.printf("  -S                 stop after the back end, keeping the assembly\n");
    Stdio.printf("  -c                 compile only: an object plus its .xtc.* sidecars\n");
    // Naming the targets: `--help` used to list arm64/arm9/x86_64/win64 and
    // leave wasm32 out, while the binary plainly says `wasm32 library -> …`
    // (blewit FINDINGS). A help text that under-reports what the tool does is
    // read as a limitation.
    Stdio.printf("  --emit-lib         build a shared library "
                 "(arm64, x86_64, arm9, wasm32)\n");
    Stdio.printf("  --emit-iface       print the module interface and stop\n");
    Stdio.printf("  -Xlinker <lib>     link against a library (also -l<name>, -framework <F>)\n");
    Stdio.printf("  --emit-apk         (-A android) package an installable APK\n");
    Stdio.printf("  --sign-key <path>  signing key for --emit-apk\n");
    Stdio.printf("  -V, --verbose      print the resolved support root and search paths\n");
    Stdio.printf("  -v, --version      print the version and exit\n");
    Stdio.printf("  -h, --help         this text\n");
    Stdio.printf("\n");
    Stdio.printf("An unrecognised option is an ERROR, never ignored: a driver that\n");
    Stdio.printf("quietly drops a flag builds something other than what it was asked for.\n");
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
        "covariant-return, unguarded-action, toolchain-fallback");
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

DriverOptions* parseDriverArgs(void)
{
    DriverOptions* d = new DriverOptions();
    FeOptions* o = d.fe();
    u32 argc = Process.argumentCount();
    u32 i = (u32)1;
    while (i < argc) {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("-o")) && i + (u32)1 < argc) {
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
            i = i + (u32)2; continue;
        }
        if (a.equals(String.withCString("-A")) && i + (u32)1 < argc) {
            d.setArch(Process.argument(i + (u32)1)); i = i + (u32)2; continue;
        }
        if (a.equals(String.withCString("-H")) && i + (u32)1 < argc) {
            o.setHome(Process.argument(i + (u32)1)); i = i + (u32)2; continue;
        }
        if (a.equals(String.withCString("-I")) && i + (u32)1 < argc) {
            o.incs().add((Object*)Process.argument(i + (u32)1)); i = i + (u32)2; continue;
        }
        if (a.equals(String.withCString("-D")) && i + (u32)1 < argc) {
            o.defs().add((Object*)Process.argument(i + (u32)1)); i = i + (u32)2; continue;
        }
        // ── linker passthrough ───────────────────────────────────────
        //
        // This driver LINKS IN-HOUSE, so there is no clang to forward these to
        // — they are honoured rather than passed on. `-Xlinker <lib.dylib>` is
        // how every UXKit driver gate names its platform shim, and rejecting
        // the flag made six back ends unbuildable (uxkit bug 034-E).
        if ((a.equals(String.withCString("-Xlinker"))
          || a.equals(String.withCString("-framework"))) && i + (u32)1 < argc) {
            bool isFw = a.equals(String.withCString("-framework"));
            String* v = Process.argument(i + (u32)1);
            if (isFw) d.frameworks().add((Object*)v);
            else      d.linkInputs().add((Object*)v);
            i = i + (u32)2;
            continue;
        }
        if (a.hasPrefix(String.withCString("-l")) && a.byteLength() > (u32)2) {
            d.linkInputs().add((Object*)a);              // resolved on the -L path
            i = i + (u32)1;
            continue;
        }
        if (a.hasPrefix(String.withCString("-Wl,"))) {
            // `-Wl,<file>[,<file>…]`: a FILE the linker takes — an object, an
            // archive, a dylib or a stub — is honoured exactly as `-Xlinker
            // <file>` is (bug 139: the harness names its objects this way, as
            // clang users do). A FLAG is still refused below: there is no
            // external linker here to hand it to.
            Array* toks = a.substringFromByte((u32)4).splitOnByte((u8)',');
            bool allFiles = toks.count() > (u32)0;
            for (u32 k = (u32)0; k < toks.count(); k = k + (u32)1) {
                String* t = (String*)toks.get(k);
                bool isLib = t.hasPrefix(String.withCString("-l")) && t.byteLength() > (u32)2;
                bool isFile = t.hasSuffix(String.withCString(".o")) || t.hasSuffix(String.withCString(".a"))
                           || t.hasSuffix(String.withCString(".dylib")) || t.hasSuffix(String.withCString(".tbd"))
                           || t.hasSuffix(String.withCString(".so"));
                if (!isLib && !isFile) allFiles = false;
            }
            if (allFiles) {
                for (u32 k = (u32)0; k < toks.count(); k = k + (u32)1)
                    d.linkInputs().add(toks.get(k));
                i = i + (u32)1;
                continue;
            }
            // A raw linker flag. There is no linker behind this one to take it,
            // so saying "accepted" would be a lie that surfaces as a missing
            // symbol at launch. Named, and refused.
            Stdio.printf("xcc: error: '%s' is a flag for an external linker, and "
                         "this driver links in-house — there is nothing to pass "
                         "it to.\n  Use -Xlinker <library> to name a library to "
                         "link against.\n", a.cString());
            Process.exit((i32)2); return (DriverOptions*)0;
        }
        if (a.equals(String.withCString("-L")) && i + (u32)1 < argc) {
            o.libs().add((Object*)Process.argument(i + (u32)1)); i = i + (u32)2; continue;
        }
        if (a.equals(String.withCString("-S"))) { d.setKeepAsm(true); i = i + (u32)1; continue; }
        if (a.equals(String.withCString("--emit-apk"))) { d.setEmitApk(true); i = i + (u32)1; continue; }
        if (a.equals(String.withCString("--sign-key")) && i + (u32)1 < argc) {
            d.setSignKey(Process.argument(i + (u32)1)); i = i + (u32)2; continue;
        }
        // `--migrate=<base>:<to>` — compile as if the library were still
        // <base>: a member marked since("V") with V newer than <base> vanishes
        // from lookup, so a call whose MEANING changed between the two fails
        // loudly instead of quietly resolving to the new one. Joined, like -O.
        // -fbounds-check: a checked build. NATIVE ONLY, and a hard error
        // elsewhere rather than a flag that quietly does nothing — the checked
        // runtime is arm64 assembly and only the arm64 back end emits the
        // parameter map it walks.
        if (a.equals(String.withCString("-fbounds-check"))) {
            o.setBoundsCheck(true); i = i + (u32)1; continue;
        }
        if (a.hasPrefix(String.withCString("--migrate="))) {
            o.setMigrate(a.substringFromByte((u32)10));
            i = i + (u32)1; continue;
        }
        // `-q` — suppress the informational lines. A build system wants the
        // errors and nothing else.
        if (a.equals(String.withCString("-q")) || a.equals(String.withCString("--quiet"))) {
            d.setQuiet(true); i = i + (u32)1; continue;
        }
        // `-Flu <n>` — auto-unroll counted loops with trip count <= n. The
        // per-target default stands unless this says otherwise.
        if ((a.equals(String.withCString("-Flu"))
             || a.equals(String.withCString("--fn-loop-unroll")))
            && i + (u32)1 < argc) {
            i32 lu = parseCount(Process.argument(i + (u32)1));
            if (lu < (i32)0) {
                // Not a number. Refused rather than quietly left at the
                // target's default: this driver's whole argument policy is
                // that an option it cannot honour is an error, and `-Flu wat`
                // silently compiling something other than what was asked for
                // is the failure that policy exists to prevent.
                Stdio.printf("xcc: error: -Flu takes a decimal trip count, got '%s'\n",
                             Process.argument(i + (u32)1).cString());
                Process.exit((i32)1);
                return (DriverOptions*)0;
            }
            d.setUnroll(lu);
            i = i + (u32)2; continue;
        }
        if (a.equals(String.withCString("-h")) || a.equals(String.withCString("--help"))) {
            usage();
            Process.exit((i32)0);
            return (DriverOptions*)0;
        }
        if (a.equals(String.withCString("-v")) || a.equals(String.withCString("--version"))) {
            // XCC_VERSION comes from the Makefile, which reads the VERSION
            // file — the same source the Objective-C driver uses. It was a
            // literal "0.6" here, which is one fact in two places: bumping
            // VERSION moved the bootstrap compiler to 0.61 and left the
            // compiler that actually SHIPS reporting 0.6.
#ifndef XCC_VERSION
#define XCC_VERSION "unversioned"
#endif
            Stdio.printf("xcc %s (xc, self-hosted)\n", XCC_VERSION);
            Process.exit((i32)0);
            return (DriverOptions*)0;
        }
        // `-m <layout>` is the reference's spelling for a 6502 memory model.
        // Accepted here and mapped onto the target, so one command line drives
        // either compiler — `-m xt` and `-m xt6502/xt` both mean xt6502.
        if (a.equals(String.withCString("-m")) && i + (u32)1 < argc) {
            String* layout = Process.argument(i + (u32)1);
            if (layout.hasPrefix(String.withCString("xt"))
                || layout.hasPrefix(String.withCString("6502"))) {
                d.setArch(String.withCString("xt6502"));
            } else if (layout.equals(String.withCString("arm64"))) {
                d.setArch(String.withCString("arm64"));
            } else {
                Stdio.printf("xcc: error: unknown memory layout '%s'\n", layout.cString());
                Stdio.printf("       (this compiler drives arm64, android and xt6502)\n");
                Process.exit((i32)1);
                return (DriverOptions*)0;
            }
            i = i + (u32)2; continue;
        }
        if (a.equals(String.withCString("-V")) || a.equals(String.withCString("--verbose"))) {
            o.setVerbose(true); i = i + (u32)1; continue;
        }
        // `-O3`, joined — NOT `-O 3`. Both spellings used to be accepted in the
        // sense that the second was SILENTLY IGNORED: `-O 0` left the driver at
        // its -O3 default and compiled the wrong thing without a word, which is
        // exactly the failure this compiler refuses everywhere else.
        if (a.hasPrefix(String.withCString("-O")) && a.byteLength() == (u32)3) {
            d.setOpt((u32)(a.byteAt((u32)2) - (u8)'0')); i = i + (u32)1; continue;
        }
        // -Wanalyze: the static analyser. Off by default — an unknown
        // false-positive rate must not destabilise the corpus.
        if (a.equals(String.withCString("-Wanalyze"))) {
            o.setAnalyze(true); i = i + (u32)1; continue;
        }
        // -Wno-<category>. The port rejected every one of these as an
        // unrecognised OPTION, so `xcc -Wno-comment` failed the build outright
        // while the reference suppressed and carried on — a user following the
        // documented advice got a hard error from the shipped compiler. An
        // unknown category is a warning, not an error: mistyping a suppression
        // must not stop a compile, and the known names are listed, as the
        // reference does.
        if (a.hasPrefix(String.withCString("-Wno-"))) {
            String* cat = a.substringBytes((u32)5, a.byteLength() - (u32)5);
            if (!isWarningCategory(cat)) {
                Stdio.printf("xcc: warning: unknown warning category '%s' — known: %s\n",
                             cat.cString(), warningCategoryNames().cString());
            } else {
                o.suppressWarning(cat);
            }
            i = i + (u32)1; continue;
        }
        if (a.equals(String.withCString("--emit-lib"))) {
            d.setEmitLib(true);
            o.setEmitIface(true);        // the library carries its own interface
            o.setLibraryBuild(true);     // …and numbers every method a slot
            i = i + (u32)1;
            continue;
        }
        // --emit-iface: the interface IS the output. The caller is asking what
        // this source DECLARES, not asking for code — an editor, or the writer
        // differential — so the front end runs and nothing after it does.
        // -c: separate compilation. The object carries the MODULE and nothing
        // else — its own code plus its per-class allocators, deliberately NOT
        // the crt or the runtime, which belong to the final link and would
        // collide the moment two objects met.
        if (a.equals(String.withCString("-flto"))) { d.setLto(true); i = i + (u32)1; continue; }
        if (a.equals(String.withCString("--sign")) && i + (u32)1 < argc) {
            d.setSignIdentity(Process.argument(i + (u32)1)); i = i + (u32)2; continue;
        }
        if (a.equals(String.withCString("--sign-entitlements")) && i + (u32)1 < argc) {
            d.setSignEntitlements(Process.argument(i + (u32)1)); i = i + (u32)2; continue;
        }
        if (a.equals(String.withCString("-c"))) {
            d.setCompileOnly(true);
            o.setEmitIface(true);     // the interface is a build artifact of -c
            // An object is part of a library too: the overrides may live in a
            // module that is not being compiled, so every instance method
            // earns a slot. The numbering an object publishes has to be the
            // one the final link will use.
            o.setLibraryBuild(true);
            i = i + (u32)1;
            continue;
        }
        if (a.equals(String.withCString("--emit-iface"))) {
            d.setEmitIfaceOnly(true);
            o.setEmitIface(true);
            i = i + (u32)1;
            continue;
        }
        // An unrecognised flag is an ERROR, not something to skip. A driver that
        // quietly drops an option it does not know builds something other than
        // what it was asked for and says it succeeded.
        if (a.hasPrefix(String.withCString("-"))) {
            // A flag this driver has not ported YET is worth saying so about.
            // "unrecognised option" reads as "no such flag", which sends the
            // reader to check their spelling; the truth is that the flag
            // exists, the bootstrap compiler has it, and this one does not
            // yet. Naming the working command beats making them find it.
            if (a.equals(String.withCString("--link-libs"))) {
                Stdio.printf("xcc: error: '%s' is not ported to this driver yet (task #52).\n",
                             a.cString());
                Stdio.printf("       The bootstrap compiler has it — same arguments:\n");
                Stdio.printf("         xcc-bootstrap %s ...\n", a.cString());
                Stdio.printf("       (it sits beside this binary after `make install`)\n");
                Process.exit((i32)2);
                return (DriverOptions*)0;
            }
            Stdio.printf("xcc: error: unrecognised option '%s'\n", a.cString());
            Stdio.printf("       (note: the optimisation level is joined — -O0, not -O 0)\n");
            Process.exit((i32)1);
            return (DriverOptions*)0;
        }
        // `xcc a.o b.o -o prog` / `xcc a.o lib.a -o prog`: objects and archives
        // named as inputs are the LINK step of separate compilation, not
        // source (bug 138: they used to be parsed as .xc and fail on byte 1).
        if (a.hasSuffix(String.withCString(".o")) || a.hasSuffix(String.withCString(".a"))) {
            d.objectInputs().add((Object*)a);
            i = i + (u32)1;
            continue;
        }
        o.setInput(a);
        i = i + (u32)1;
    }
    return d;
}
