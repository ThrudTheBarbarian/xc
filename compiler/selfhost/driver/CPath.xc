// CPath.xc — `xcc prog.c`: the C path's driver half.
// =========================================================================
//
// cpp-front-end.md, "The C path". clang turns the C into LLVM IR before
// LLVM's passes; LlvmRead.xc turns that into an IRModule; the module then
// goes the way a lowered xc module goes (the optimiser, IR Propose and the
// outliner, a back end, the link). Without clang there is no C path: the
// caller says so ("install clang").
//
// First step: every function of the program is read and compiled by xcc. A
// function the reader does not read stops the build with the reader's
// reason; leaving such functions to clang (and linking its object) is the
// next.

#import "Foundation.xc"
#import "Directory.xc"
#import <Ir>
#import "IrDefs.xc"
#import <LlvmRead>
#import <Frontend>
#import <Language>
#import <External>

// clang's object for the part of the C program xcc does not compile (the
// globals, and any function the reader did not read); the link adds it.
String* gCRestObject;
// Whether clang's half is built with its own stack protector: its runtime
// (__stack_chk_guard, __stack_chk_fail) is libSystem's and glibc's, so the
// driver says yes for macOS and the dynamic glibc link, and no for a static
// Linux program and Windows, whose links have no such runtime.
bool gCPathProtect;
// clang's target, when it is not the host's: ` -target <triple> --sysroot
// <root>` (or empty), for both clang runs. `xcc -A x86_64 prog.c` on a Mac
// gave clang no target, so its half was a host object the x86-64 link could
// not read ("rest.o is not a readable x86-64 object").
String* gCPathTarget;
// -ffp-contract=<x>, handed to clang: `fast` is the C source asking for fused
// multiply-adds (LlvmRead keeps clang's `contract` flags); 0 for clang's default.
String* gCPathFpContract;

// -c of a C file: xcc's object and clang's become one relocatable object
// (`clang -r`: the system linker, or ld.lld for another target where it is
// installed), not a
// program. 0 when it worked, else the shell's status.
// Whether `prog` is a file in one of $PATH's directories.
bool cPathOnPath(u8* prog)
    {
    Array* dirs = Platform.env(String.withCString("PATH")).splitOnByte((u8)':');
    for (u32 i = (u32)0; i < dirs.count(); i = i + (u32)1)
        {
        String* dir = (String*)dirs.get(i);
        if (dir.byteLength() == (u32)0) continue;
        String* f = String.withString(dir);
        f.appendCString("/");
        f.appendCString(prog);
        if (Files.exists(f)) return true;
        }
    return false;
    }

// The reader takes exception handlers (phase 2): where the target's back end
// writes their tables (the driver says, cPathSetHandlers), or under
// XC_C_HANDLERS=1 (development, on a target not there yet).
bool gCPathHandlers;
bool gCPathHandlersTarget;
void cPathSetHandlers(bool b) { gCPathHandlersTarget = b; }

i32 cPathRelocatable(String* xo, String* out)
    {
    String* cc = String.withCString("clang");
    if (gCPathTarget != (String*)0 && gCPathTarget.byteLength() > (u32)0)
        {
        cc.append(gCPathTarget);
        // ld.lld for another target's objects (the Mac's linker reads only
        // Mach-O); a Linux host without it combines with its own ld -r.
        if (cPathOnPath("ld.lld"))
            cc.appendCString(" -fuse-ld=lld");
        }
    cc.appendCString(" -r -nostdlib -o ");
    cc.append(CPath.quoted(out));
    cc.appendCString(" ");
    cc.append(CPath.quoted(xo));
    if (gCRestObject != (String*)0)
        {
        cc.appendCString(" ");
        cc.append(CPath.quoted(gCRestObject));
        }
#if OS_darwin
    // Apple's ld writes a debug map into the combined object: an N_OSO entry
    // naming each input that has debug info (clang's half, in this run's
    // scratch directory) and that file's modification time. Both differ on
    // every run, so the same source gave different objects (#429). The
    // scratch prefix comes off the name (-oso_prefix) and ZERO_AR_DATE makes
    // the time 0, as for an archive member. Only on the host's own link: a
    // cross target goes to ld.lld, which writes no debug map.
    if (gCPathTarget == (String*)0 || gCPathTarget.byteLength() == (u32)0)
        {
        String* dir = (gCRestObject != (String*)0) ? gCRestObject.deletingLastPathComponent() : (String*)0;
        if (dir != (String*)0 && dir.byteLength() > (u32)0)
            {
            String* pre = String.withString(dir);
            pre.appendCString("/");
            cc.appendCString(" -Wl,-oso_prefix,");
            cc.append(CPath.quoted(pre));
            }
        String* z = String.withCString("ZERO_AR_DATE=1 ");
        z.append(cc);
        cc = z;
        }
#endif
    return system(cc.cString());
    }

// The two above, as functions, for a file compiled against this interface.
String* cRestObject(void) { return gCRestObject; }
void cPathSetProtect(bool b) { gCPathProtect = b; }
// C fuses clang's llvm.fmuladd on every target, as GCC and clang do (the
// driver sets it; LlvmReader.setFuseMulAdd); -fgoal=accuracy asks for none.
bool gCPathFuseMulAdd;
void cPathSetFuseMulAdd(bool b) { gCPathFuseMulAdd = b; }
void cPathSetTarget(String* t) { gCPathTarget = t; }
void cPathSetFpContract(String* v) { gCPathFpContract = v; }
String* cPathFpContract(void) { return gCPathFpContract; }
// -std=<x>: the language standard, handed to clang; 0 for clang's default.
String* gCPathStd;
void cPathSetStd(String* v) { gCPathStd = v; }
String* cPathStd(void) { return gCPathStd; }
// The target writes ELF: a language whose unwinder reads clang's frame table
// (row field frames) gets it registered at start-up.
bool gCPathElf;
void cPathSetElf(bool b) { gCPathElf = b; }
// The program's large malloc blocks are the runtime's (#235): xcc's half
// carries CAlloc.xc, which the link turns on (x86-64 glibc, macOS).
bool gCPathHeap;
void cPathSetHeap(bool b) { gCPathHeap = b; }
// Whether this build drops the runtime stub when no loop is lifted: a linked
// program, not an object (-c), an assembly listing or a relocatable split
// part, which another object's lifted loop may still need (#278).
bool gCPathDropBase;
void cPathSetDropBase(bool b) { gCPathDropBase = b; }
// The source's row of the language table (Language.xc): the command that
// writes its LLVM IR, and which functions xcc takes. 0: C's.
LanguageRow* gCPathLang;
void cPathSetLanguage(LanguageRow* l) { gCPathLang = l; }

// The scratch files a C compile leaves once the program is linked: clang's
// object, xcc's and its sidecars. Each run's names carry its pid, so nothing
// else removed them, and a build host's /tmp filled (12 GB on one gate host).
void cPathCleanup(void)
    {
    if (gCRestObject == (String*)0)
        return;
    String* s = CPath.scratch();
    u8* tails[5];
    tails[0] = ".rest.o";
    tails[1] = ".x.o";
    tails[2] = ".x.xtc.ir";
    tails[3] = ".x.xtc.needs";
    tails[4] = ".x.xtc.iface";
    for (u32 i = (u32)0; i < (u32)5; i = i + (u32)1)
        {
        String* p = String.withString(s);
        p.appendCString(tails[i]);
        Directory._unlink(p);
        }
    }

// The C library's: the shell runs clang, with this process's environment.
i32 system(u8* command);
i32 getpid(void);

class CPath
    {
    u8 _unused;

    // One argument quoted for the shell system() runs (External.quote).
    // Whether LLVM IR text has a loop in any function (#278): only then can
    // the outliner lift one, so only then is the par runtime's stub read in.
    // In any order of a function's blocks a cycle has an edge back to a block
    // at or before its own, so a loop is exactly a branch to a label already
    // seen in that function. (A function's entry block cannot be a target.)
    static bool irHasLoop(String* ll)
    {
        Array* lines = ll.splitOnByte((u8)10);
        Set* seen = (Set*)0;
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
        {
            String* l = (String*)lines.get(i);
            u32 n = l.byteLength();
            if (l.hasPrefix(String.withCString("define ")))
            {
                seen = new Set();
                continue;
            }
            if (seen == (Set*)0)
                continue;
            if (n == (u32)1 && l.byteAt((u32)0) == (u8)'}')
            {
                seen = (Set*)0;
                continue;
            }
            // A block label: `name:` at the start of the line.
            u32 k = (u32)0;
            while (k < n && CPath.labelChar(l.byteAt(k)))
                k = k + (u32)1;
            if (k > (u32)0 && k < n && l.byteAt(k) == (u8)':')
            {
                seen.add((Hashable*)l.substringBytes((u32)0, k));
                continue;
            }
            // Every `label %name` the line branches to.
            u32 at = l.byteIndexOf(String.withCString("label %"));
            while (at != String.notFound())
            {
                u32 b = at + (u32)7;
                u32 e = b;
                while (e < n && CPath.labelChar(l.byteAt(e)))
                    e = e + (u32)1;
                if (e > b && seen.contains((Hashable*)l.substringBytes(b, e - b)))
                    return true;
                at = l.byteIndexOf(String.withCString("label %"), e);
            }
        }
        return false;
    }

    static bool labelChar(u8 c)
    {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9')
            || c == (u8)'_' || c == (u8)'.' || c == (u8)'$' || c == (u8)'-';
    }

    static String* quoted(String* a)
        {
        return External.quote(a);   // the one quoting rule (#337)
        }

    // A scratch path for clang's output: `c` in the run's private scratch
    // directory (External.tempDir, #337), which goes when the run ends. It
    // was /tmp/xcc-c-<pid>, beside it and ignoring $TMPDIR.
    static String* scratch(void)
        {
#if OS_windows
        String* p = External.tempDir();
        p.appendCString("\\c");
        return p;
#else
        return External.tempPath("c");
#endif
        }

    // Whether clang runs here.
    static bool haveClang(void)
        {
        return CPath.have(String.withCString("clang"));
        }

    // Whether `command` runs here.
    static bool have(String* command)
        {
        String* c = String.withString(command);
#if OS_windows
        c.appendCString(" --version >NUL 2>&1");
#else
        c.appendCString(" --version >/dev/null 2>&1");
#endif
        return system(c.cString()) == 0;
        }

    // The row the source is compiled by: the one set, else C's.
    static LanguageRow* language(void)
        {
        if (gCPathLang == (LanguageRow*)0)
            gCPathLang = Languages.forFile(String.withCString("x.c"));
        return gCPathLang;
        }

    // The IR after the row's passes (clang, over its own output), or 0 with
    // the reason printed.
    static String* passed(String* text, String* scratch, LanguageRow* lang, Map* names)
        {
        String* feLl = String.withString(scratch);
        feLl.appendCString(".fe.ll");
        String* out = String.withString(scratch);
        out.appendCString(".ll");
        if (!Files.writeText(feLl, Languages.markNoinlineOf(text, names)))
            {
            Stdio.error(String.withFormat("xcc: error: cannot write '%s'\n", feLl.cString()));
            return (String*)0;
            }
        String* cmd = String.withCString("clang");
        if (gCPathTarget != (String*)0)
            cmd.append(gCPathTarget);
        cmd.appendCString(" ");
        cmd.append(lang.passes());
        cmd.appendCString(" -Wno-override-module -S -emit-llvm -o ");
        cmd.append(CPath.quoted(out));
        cmd.appendCString(" ");
        cmd.append(CPath.quoted(feLl));
        if (system(cmd.cString()) != 0)
            {
            Stdio.error(String.withFormat("xcc: error: clang could not run the %s passes over '%s'\n", lang.name().cString(), feLl.cString()));
            return (String*)0;
            }
        Directory._unlink(feLl);
        String* r = Files.readText(out);
        Directory._unlink(out);
        if (r == (String*)0)
            Stdio.error(String.withFormat("xcc: error: cannot read clang's output '%s'\n", out.cString()));
        return r != (String*)0 ? Languages.plainCallingConv(r) : r;
        }

    // A load-time function that calls mingw's __main (the program's
    // constructors), for a main of xcc's.
    static void callMingwMain(IRModule* m)
        {
        m.addSym(IRSymbol.func(String.withCString("__main"), String.withCString("() -> Void"), false, true));
        IRFunc* f = new IRFunc();
        f.setName(String.withCString("__xc_mingw_main"));
        IRValue* mem = new IRValue(String.withCString("Mem"));
        f.addParam(mem);
        IRBlock* b = new IRBlock(String.withCString("bb_entry"));
        IRInsn* c = IRInsn.with(String.withCString("Call"));
        c.setCc(String.withCString("CallConv::Standard"));
        c.add(IROperand.sym(String.withCString("__main")));
        c.add(IROperand.useVal(mem));
        IRValue* mo = new IRValue(String.withCString("Mem"));
        c.setMemRes(mo);
        b.add(c);
        IRInsn* r = IRInsn.with(String.withCString("Return"));
        r.add(IROperand.useVal(mo));
        b.setTerm(r);
        f.addBlock(b);
        m.addFunc(f);
        m.addSym(IRSymbol.func(String.withCString("__xc_mingw_main"), String.withCString("() -> Void"), false, false));
        m.modinits().add((Object*)String.withCString("__xc_mingw_main"));
        }

    // A load-time function that calls __register_frame(&__xc_eh_frame_start)
    // once per program: every C/C++ object carries one, and the link gathers
    // their tables under that one symbol, so each checks and sets a flag that
    // the objects share (an uninitialised global: a common symbol, merged).
    static void registerFrames(IRModule* m)
        {
        String* u8p = String.withCString("Ptr(U8, unbanked)");
        IRSymbol* eh = IRSymbol.dataGlobal(String.withCString("__xc_eh_frame_start"), String.withCString("U8"));
        eh.setAttr(String.withCString("extern"), true);
        m.addSym(eh);
        m.addSym(IRSymbol.dataGlobal(String.withCString("__xc_eh_registered"), String.withCString("U8")));
        m.addSym(IRSymbol.func(String.withCString("__register_frame"), String.withFormat("(%s) -> Void", u8p.cString()), false, true));
        IRFunc* f = new IRFunc();
        f.setName(String.withCString("__xc_register_frames"));
        IRValue* mem = new IRValue(String.withCString("Mem"));
        f.addParam(mem);
        IRBlock* b = new IRBlock(String.withCString("bb_entry"));
        IRBlock* done = new IRBlock(String.withCString("bb_done"));
        IRBlock* reg = new IRBlock(String.withCString("bb_register"));
        // entry: the flag, and on to done when it is set.
        IRInsn* fa = IRInsn.with(String.withCString("AddrOf"));
        IRValue* fav = new IRValue(u8p);
        fa.setRes(fav);
        fa.add(IROperand.sym(String.withCString("__xc_eh_registered")));
        b.add(fa);
        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        IRValue* fv = new IRValue(String.withCString("U8"));
        IRValue* m1 = new IRValue(String.withCString("Mem"));
        ld.setRes(fv);
        ld.setMemRes(m1);
        ld.add(IROperand.useVal(fav));
        ld.add(IROperand.useVal(mem));
        b.add(ld);
        IRInsn* zero = IRInsn.with(String.withCString("Const"));
        IRValue* zv = new IRValue(String.withCString("U8"));
        zero.setRes(zv);
        zero.add(IROperand.immI((i64)0, String.withCString("U8")));
        b.add(zero);
        IRInsn* cmp = IRInsn.with(String.withCString("ICmp"));
        IRValue* set = new IRValue(String.withCString("Bool"));
        cmp.setRes(set);
        cmp.setPred(String.withCString("NE"));
        cmp.add(IROperand.useVal(fv));
        cmp.add(IROperand.useVal(zv));
        b.add(cmp);
        IRInsn* br = IRInsn.with(String.withCString("CondBranch"));
        br.add(IROperand.useVal(set));
        br.add(IROperand.block(done));
        br.add(IROperand.block(reg));
        b.setTerm(br);
        IRInsn* r0 = IRInsn.with(String.withCString("Return"));
        r0.add(IROperand.useVal(m1));
        done.setTerm(r0);
        // register: set the flag, then hand the table over.
        IRInsn* one = IRInsn.with(String.withCString("Const"));
        IRValue* ov = new IRValue(String.withCString("U8"));
        one.setRes(ov);
        one.add(IROperand.immI((i64)1, String.withCString("U8")));
        reg.add(one);
        IRInsn* st = IRInsn.with(String.withCString("Store"));
        IRValue* m2 = new IRValue(String.withCString("Mem"));
        st.add(IROperand.useVal(fav));
        st.add(IROperand.useVal(ov));
        st.add(IROperand.useVal(m1));
        st.setMemRes(m2);
        reg.add(st);
        IRInsn* a = IRInsn.with(String.withCString("AddrOf"));
        IRValue* av = new IRValue(u8p);
        a.setRes(av);
        a.add(IROperand.sym(String.withCString("__xc_eh_frame_start")));
        reg.add(a);
        IRInsn* c = IRInsn.with(String.withCString("Call"));
        c.setCc(String.withCString("CallConv::Standard"));
        c.add(IROperand.sym(String.withCString("__register_frame")));
        c.add(IROperand.useVal(av));
        c.add(IROperand.useVal(m2));
        IRValue* mo = new IRValue(String.withCString("Mem"));
        c.setMemRes(mo);
        reg.add(c);
        IRInsn* r = IRInsn.with(String.withCString("Return"));
        r.add(IROperand.useVal(mo));
        reg.setTerm(r);
        f.addBlock(b);
        f.addBlock(done);
        f.addBlock(reg);
        m.addFunc(f);
        m.addSym(IRSymbol.func(String.withCString("__xc_register_frames"), String.withCString("() -> Void"), false, false));
        m.modinits().add((Object*)String.withCString("__xc_register_frames"));
        }

    // The C file as an IRModule, or 0 with the reason printed. `incs` and
    // `defs` are the -I directories and -D definitions, handed to clang.
    static IRModule* lower(String* input, String* scratch, Array* incs, Array* defs)
        {
        return CPath.lowerWith(input, scratch, incs, defs, (FeOptions*)0);
        }

    // The same, read into the module the front end lowers from `fe` when it
    // is given: a stub importing the par runtime, for the IR outliner.
    static IRModule* lowerWith(String* input, String* scratch, Array* incs, Array* defs, FeOptions* fe)
        {
        gCPathHandlers = gCPathHandlersTarget || Platform.env(String.withCString("XC_C_HANDLERS")).equals(String.withCString("1"));
        Languages.setReadHandlers(gCPathHandlers);
        LanguageRow* lang = CPath.language();
        // The C file, when the row is C's: a message the tests know.
        if (lang.name().equals(String.withCString("c")) && !CPath.haveClang())
            {
            Stdio.error(String.withCString("xcc: error: a C file needs clang, which compiles it (xcc then makes par blocks of its loops); install clang\n"));
            return (IRModule*)0;
            }
        else if (!lang.name().equals(String.withCString("c")) && (!CPath.have(lang.command()) || !CPath.haveClang()))
            {
            Stdio.error(String.withFormat("xcc: error: a %s file needs %s and clang, which compile it (xcc then makes par blocks of its loops); install them\n",
                                          lang.name().cString(), lang.command().cString()));
            return (IRModule*)0;
            }
        String* ll = String.withString(scratch);
        ll.appendCString(".ll");
        String* cmd = String.withString(lang.command());
        if (gCPathTarget != (String*)0)
            cmd.append(gCPathTarget);
        cmd.appendCString(" ");
        cmd.append(lang.irFlags());
        if (gCPathStd != (String*)0)
            {
            // The user's value, quoted like any other argument (#337).
            cmd.appendCString(" ");
            cmd.append(CPath.quoted(String.withFormat("-std=%s", gCPathStd.cString())));
            }
        if (gCPathFpContract != (String*)0)
            {
            cmd.appendCString(" ");
            cmd.append(CPath.quoted(String.withFormat("-ffp-contract=%s", gCPathFpContract.cString())));
            }
        for (u32 i = (u32)0; i < incs.count(); i = i + (u32)1)
            {
            cmd.appendCString(" -I ");
            cmd.append(CPath.quoted((String*)incs.get(i)));
            }
        for (u32 i = (u32)0; i < defs.count(); i = i + (u32)1)
            {
            cmd.appendCString(" -D");
            cmd.append(CPath.quoted((String*)defs.get(i)));
            }
        cmd.appendCString(" -o ");
        cmd.append(CPath.quoted(ll));
        cmd.appendCString(" ");
        cmd.append(CPath.quoted(input));
        // XC_C_LL: read this file as clang's IR instead (tests/par/cpath.sh
        // gives the reader IR in the forms other clangs write: CRLF lines,
        // LLVM 23's `f0x` floats).
        String* given = Platform.env(String.withCString("XC_C_LL"));
        if (given.byteLength() > (u32)0)
            ll = given;
        else if (system(cmd.cString()) != (i32)0)
            {
            Stdio.error(String.withFormat("xcc: error: %s could not compile '%s'\n", lang.command().cString(), input.cString()));
            return (IRModule*)0;
            }
        String* text = Files.readText(ll);
        if (text == (String*)0)
            {
            Stdio.error(String.withFormat("xcc: error: cannot read clang's output '%s'\n", ll.cString()));
            return (IRModule*)0;
            }
        if (given.byteLength() == (u32)0)
            Directory._unlink(ll);
        // clang on Windows ends its lines CRLF. The reader finds a function's
        // end as a line that is `}`, and with a `\r` on every line it found
        // none: the first function ran to the end of the file and every one
        // after it (main included) was left to clang, unread.
        text = text.replacing(String.withCString("\r\n"), String.withCString("\n"));
        // The row's passes: clang optimises the IR before xcc reads it, the
        // functions xcc may take kept out of their callers. XC_C_LL's file
        // is the IR as read, after any passes.
        // The row's read flags: a second build, the one xcc reads (clang's
        // half is still the first).
        String* readBuild = (String*)0;
        if (lang.readFlags().byteLength() > 0 && given.byteLength() == 0)
            {
            String* llB = String.withString(scratch);
            llB.appendCString(".read.ll");
            String* cmdB = cmd.replacing(CPath.quoted(ll), CPath.quoted(llB));
            String* at = String.withFormat(" %s", lang.irFlags().cString());
            cmdB = cmdB.replacing(at, at.appending(String.withCString(" ")).appending(lang.readFlags()));
            if (system(cmdB.cString()) != 0)
                {
                Stdio.error(String.withFormat("xcc: error: %s could not compile '%s' with %s\n", lang.command().cString(),
                                              input.cString(), lang.readFlags().cString()));
                return (IRModule*)0;
                }
            readBuild = Files.readText(llB);
            Directory._unlink(llB);
            if (readBuild == (String*)0)
                {
                Stdio.error(String.withFormat("xcc: error: cannot read clang's output '%s'\n", llB.cString()));
                return (IRModule*)0;
                }
            readBuild = readBuild.replacing(String.withCString("\r\n"), String.withCString("\n"));
            }
        if (lang.passes().byteLength() > 0 && given.byteLength() == 0)
            {
            // One set of functions kept out of their callers in both builds,
            // so a function xcc takes from the second is called in the first:
            // those with a loop once clang's passes have inlined their callees
            // (a std::fill, a parallel algorithm, a lambda). A probe run, with
            // every function xcc might take kept out, says which; a function
            // with a loop of its own is one already.
            String* textFe = text;
            String* readFe = readBuild;
            String* probeFe = readFe != (String*)0 ? readFe : textFe;
            Map* all = Languages.userFunctions(probeFe);
            String* probe = CPath.passed(probeFe, scratch, lang, all);
            if (probe == (String*)0)
                return (IRModule*)0;
            Map* names = Languages.loopNames(probe);
            // A function with a loop of its own is one too, unless another
            // function's loop calls it: perlin's shade belongs inlined in
            // render's loop (as one loop in C), not kept out of it.
            Map* own = Languages.loopNames(textFe);
            Map* inner = Languages.calledInLoops(textFe);
            Array* ok = own.allKeys();
            for (u32 k = 0; k < ok.count(); k = k + 1)
                if (inner.get((Hashable*)ok.get(k)) == (Object*)0)
                    names.set((Hashable*)ok.get(k), own.get((Hashable*)ok.get(k)));
            text = CPath.passed(textFe, scratch, lang, names);
            if (text == (String*)0)
                return (IRModule*)0;
            if (readFe != (String*)0)
                {
                readBuild = CPath.passed(readFe, scratch, lang, names);
                if (readBuild == (String*)0)
                    return (IRModule*)0;
                }
            }
        // A function xcc leaves to clang (one an exception may pass through)
        // has its loops moved into functions of their own, which xcc takes
        // (Languages.extractLoops); in clang's build, whose calls they are,
        // and added to the read build as they are there.
        if (lang.loopsOnly())
            {
            text = Languages.extractLoops(text);
            if (readBuild != (String*)0)
                readBuild = Languages.withExtracted(readBuild, Languages.extractedOnly(text), text);
            }
        // reads `loops`: the reader sees only the functions xcc may take,
        // from the read build where there is one (and clang's build has them).
        String* readText = lang.loopsOnly() ? Languages.loopFunctions(readBuild != (String*)0 ? readBuild : text) : text;
        if (readBuild != (String*)0)
            readText = Languages.takeFrom(readText, text);
        // std::array globals as their arrays, for the reader.
        if (lang.loopsOnly())
            readText = Languages.plainArrays(readText);
        // XC_C_KEEP=<prefix>: the text xcc reads, as <prefix>.read.ll (and
        // clang's half as <prefix>.rest.ll), to see what a refusal refers to.
        String* keep = Platform.env(String.withCString("XC_C_KEEP"));
        if (keep.byteLength() > (u32)0)
            Files.writeText(keep.appending(String.withCString(".read.ll")), readText);
        LlvmReader* r = new LlvmReader();
        r.setPath(input);
        // clang compiles what xcc does not take, and the globals: their
        // objects are linked (CPath.restObject).
        r.setSplit(true);
        r.setFuseMulAdd(gCPathFuseMulAdd);
        // clang's whole IR: the names it keeps to this file.
        r.setPath(input);
        r.noteLocalNames(text);
        // Exception handlers (phase 2): read only where a back end writes
        // their tables; XC_C_HANDLERS=1 reads them anyway (development: the
        // IR of such a function, --emit-ir).
        r.setReadHandlers(gCPathHandlers);
        if (Platform.env(String.withCString("XC_C_CABI")).byteLength() > (u32)0)
            r.setCabiAll(true);
        IRModule* m = (IRModule*)0;
        // No loop, nothing to lift: the program is the C file's own code, with
        // no runtime stub to lower and then drop (#278). The C heap's
        // allocator (CAlloc) goes with the stub, as it did when the optimiser
        // dropped an unused one: the program keeps libc's. Only where the
        // optimiser would drop the stub anyway (gCPathDropBase).
        if (fe != (FeOptions*)0 && gCPathDropBase && !CPath.irHasLoop(readText))
            fe = (FeOptions*)0;
        if (fe != (FeOptions*)0)
            {
            String* stub = String.withString(scratch);
            stub.appendCString(".xc");
            String* stubText = String.withCString("#import \"Par.xc\"\n");
            if (gCPathHeap)
                stubText.appendCString("#import \"CAlloc.xc\"\n");
            if (!Files.writeText(stub, stubText))
                {
                Stdio.error(String.withFormat("xcc: error: cannot write '%s'\n", stub.cString()));
                return (IRModule*)0;
                }
            fe.setInput(stub);
            IRModule* base = Frontend.lower(fe);
            Directory._unlink(stub);
            if (base == (IRModule*)0)
                return (IRModule*)0;
            // The stub's place in the debug file table names the C source
            // (#349): it was the scratch path, which carries this process's
            // id, so the same .c gave different assembly every run and -g
            // named a file deleted once the compile ends. The stub holds only
            // imports; the reader then finds the source's path already in the
            // table and its lines share the entry.
            String* stubPath = IRDbg.canonicalPath(stub);
            Array* dbgFiles = IRDbg.files();
            for (u32 k = (u32)0; k < dbgFiles.count(); k = k + (u32)1)
                if (((String*)dbgFiles.get(k)).equals(stubPath))
                    {
                    IRDbg.setPath(IRDbg.canonicalPath(input), k);
                    break;
                    }
            // What the stub brought, for the optimiser to remove when no
            // loop is lifted (Opt.dropBase).
            base.markBase();
            m = r.readInto(readText, base);
            }
        else
            m = r.read(readText);
        if (m == (IRModule*)0)
            return (IRModule*)0;
        // xcc's object is the program's entry module even when main is
        // clang's: a back end writes the load-time constructor table (which
        // the runtime's start walks) only for a module with main or a
        // constructor, so it gets one that does nothing.
        bool hasMain = false;
        for (u32 i = (u32)0; i < m.funcs().count() && !hasMain; i = i + (u32)1)
            hasMain = ((IRFunc*)m.funcs().get(i)).name().equals(String.withCString("main"));
        // mingw: clang's back end makes main call __main first, which runs
        // the program's constructors (.ctors); the call is not in the IR. When
        // main is xcc's, a load-time function makes it, before main.
        if (hasMain && gCPathTarget != (String*)0 && gCPathTarget.contains(String.withCString("mingw")))
            CPath.callMingwMain(m);
        if (!hasMain)
            {
            IRFunc* ctor = new IRFunc();
            ctor.setName(String.withCString("__xc_cpath_init"));
            IRValue* cm = new IRValue(String.withCString("Mem"));
            ctor.addParam(cm);
            IRBlock* cb = new IRBlock(String.withCString("bb_entry"));
            IRInsn* cr = IRInsn.with(String.withCString("Return"));
            cr.add(IROperand.useVal(cm));
            cb.setTerm(cr);
            ctor.addBlock(cb);
            m.addFunc(ctor);
            m.addSym(IRSymbol.func(String.withCString("__xc_cpath_init"), String.withCString("() -> Void"), false, false));
            m.modinits().add((Object*)String.withCString("__xc_cpath_init"));
            }
        // C++'s exceptions on an ELF target: the unwinder finds clang's frame
        // table (merged by the link at __xc_eh_frame_start, ended by a zero
        // word) once it is registered, at load time.
        if (lang.ehFrames() && gCPathElf)
            CPath.registerFrames(m);
        // XC_C_TRACE: the functions left to clang, and why the first was.
        if (r.unread().count() > (u32)0 && Platform.env(String.withCString("XC_C_TRACE")).byteLength() > (u32)0)
            {
            Stdio.error(String.withFormat("xcc: C path: %u function(s) left to clang; the first because of %s\n",
                                          r.unread().count(), r.why() != (String*)0 ? r.why().cString() : "?"));
            // Each by name, so a harness can tell that main was not one.
            for (u32 i = (u32)0; i < r.unread().count(); i = i + (u32)1)
                Stdio.error(String.withFormat("xcc: C path: left to clang: %s\nxcc: C path:   because of %s\n",
                                              ((String*)r.unread().get(i)).cString(),
                                              ((String*)r.unreadWhy().get(i)).cString()));
            }
        // The rest: clang compiles it to an object the link takes.
        String* restLl = String.withString(scratch);
        restLl.appendCString(".rest.ll");
        String* restO = String.withString(scratch);
        restO.appendCString(".rest.o");
        String* restText = r.rest(text);
        if (lang.loopsOnly())
            {
            restText = Languages.keepOdr(restText);
            restText = Languages.plainExtracted(restText);
            }
        // A function taken from the read build keeps clang's own version too.
        if (readBuild != (String*)0)
            restText = Languages.keepClangCopies(restText, text, readText, r);
        // A C++ program's static destructors are registered with
        // __cxa_atexit(dtor, obj, &__dso_handle); on ELF the toolchain's
        // crtbegin.o defines __dso_handle, which xcc's link does not take, so
        // clang's half defines it (an address naming this program).
        if (gCPathElf)
            restText = restText.replacing(String.withCString("@__dso_handle = external hidden global i8"),
                                          String.withCString("@__dso_handle = hidden global i8 0"));
        if (keep.byteLength() > (u32)0)
            Files.writeText(keep.appending(String.withCString(".rest.ll")), restText);
        if (!Files.writeText(restLl, restText))
            {
            Stdio.error(String.withFormat("xcc: error: cannot write '%s'\n", restLl.cString()));
            return (IRModule*)0;
            }
        // clang's half gets clang's own stack protector where its runtime is
        // there (gCPathProtect), as xcc's half gets its canaries (the
        // security review, 2026-10-21).
        String* cc = String.withCString("clang");
        if (gCPathTarget != (String*)0)
            cc.append(gCPathTarget);
        cc.appendCString(gCPathProtect ? " -O2 -fstack-protector-strong" : " -O2");
        // Unwind tables only for a language that needs them (C++'s
        // exceptions): one with a frame table, or a platform linker.
        if (lang.linker().byteLength() == 0 && !lang.ehFrames())
            cc.appendCString(" -fno-unwind-tables -fno-asynchronous-unwind-tables");
        cc.appendCString(" -Wno-override-module -c -o ");
        cc.append(CPath.quoted(restO));
        cc.appendCString(" ");
        cc.append(CPath.quoted(restLl));
        if (system(cc.cString()) != (i32)0)
            {
            Stdio.error(String.withFormat("xcc: error: clang could not compile the rest of '%s' (%s)\n",
                                          input.cString(), restLl.cString()));
            return (IRModule*)0;
            }
        Directory._unlink(restLl);
        gCRestObject = restO;
        return m;
        }
    }
