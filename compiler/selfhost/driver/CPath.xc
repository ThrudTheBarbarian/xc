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
#import <Ir>
#import "IrDefs.xc"
#import <LlvmRead>
#import <Frontend>

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

// -c of a C file: xcc's object and clang's become one relocatable object
// (`clang -r`, the system linker on macOS, ld.lld for another target), not a
// program. 0 when it worked, else the shell's status.
i32 cPathRelocatable(String* xo, String* out)
    {
    String* cc = String.withCString("clang");
    if (gCPathTarget != (String*)0 && gCPathTarget.byteLength() > (u32)0)
        {
        cc.append(gCPathTarget);
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
    return system(cc.cString());
    }

// The two above, as functions, for a file compiled against this interface.
String* cRestObject(void) { return gCRestObject; }
void cPathSetProtect(bool b) { gCPathProtect = b; }
void cPathSetTarget(String* t) { gCPathTarget = t; }

// The C library's: the shell runs clang, with this process's environment.
i32 system(u8* command);
i32 getpid(void);

class CPath
    {
    u8 _unused;

    // `'a'` for the shell, a `'` inside written `'\''`. On Windows system()
    // runs cmd.exe, which knows only double quotes: `"a"`, with no `"` inside
    // a path to escape.
    static String* quoted(String* a)
        {
#if ARCH_win64
        String* w = String.withCString("\"");
        w.append(a);
        w.appendCString("\"");
        return w;
#else
        String* q = String.withCString("'");
        for (u32 i = (u32)0; i < a.byteLength(); i = i + (u32)1)
            {
            u8 c = a.byteAt(i);
            if (c == (u8)'\'')
                q.appendCString("'\\''");
            else
                q.appendByte(c);
            }
        q.appendCString("'");
        return q;
#endif
        }

    // A scratch path for clang's output, this process's own.
    static String* scratch(void)
        {
#if ARCH_win64
        // %TEMP%, as every Windows program's scratch: there is no /tmp.
        String* t = Platform.env(String.withCString("TEMP"));
        if (t.byteLength() == (u32)0)
            t = String.withCString(".");
        return String.withFormat("%s\\xcc-c-%ld", t.cString(), getpid());
#else
        return String.withFormat("/tmp/xcc-c-%ld", getpid());
#endif
        }

    // Whether clang runs here.
    static bool haveClang(void)
        {
#if ARCH_win64
        return system("clang --version >NUL 2>&1") == (i32)0;
#else
        return system("clang --version >/dev/null 2>&1") == (i32)0;
#endif
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
        if (!CPath.haveClang())
            {
            Stdio.error(String.withCString("xcc: error: a C file needs clang, which compiles it (xcc then makes par blocks of its loops); install clang\n"));
            return (IRModule*)0;
            }
        String* ll = String.withString(scratch);
        ll.appendCString(".ll");
        String* cmd = String.withCString("clang");
        if (gCPathTarget != (String*)0)
            cmd.append(gCPathTarget);
        cmd.appendCString(" -O1 -Xclang -disable-llvm-passes -fno-discard-value-names -gline-tables-only -S -emit-llvm");
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
            Stdio.error(String.withFormat("xcc: error: clang could not compile '%s'\n", input.cString()));
            return (IRModule*)0;
            }
        String* text = Files.readText(ll);
        if (text == (String*)0)
            {
            Stdio.error(String.withFormat("xcc: error: cannot read clang's output '%s'\n", ll.cString()));
            return (IRModule*)0;
            }
        // clang on Windows ends its lines CRLF. The reader finds a function's
        // end as a line that is `}`, and with a `\r` on every line it found
        // none: the first function ran to the end of the file and every one
        // after it (main included) was left to clang, unread.
        text = text.replacing(String.withCString("\r\n"), String.withCString("\n"));
        LlvmReader* r = new LlvmReader();
        r.setPath(input);
        // clang compiles what xcc does not take, and the globals: their
        // objects are linked (CPath.restObject).
        r.setSplit(true);
        if (Platform.env(String.withCString("XC_C_CABI")).byteLength() > (u32)0)
            r.setCabiAll(true);
        IRModule* m = (IRModule*)0;
        if (fe != (FeOptions*)0)
            {
            String* stub = String.withString(scratch);
            stub.appendCString(".xc");
            if (!Files.writeText(stub, String.withCString("#import \"Par.xc\"\n")))
                {
                Stdio.error(String.withFormat("xcc: error: cannot write '%s'\n", stub.cString()));
                return (IRModule*)0;
                }
            fe.setInput(stub);
            IRModule* base = Frontend.lower(fe);
            if (base == (IRModule*)0)
                return (IRModule*)0;
            m = r.readInto(text, base);
            }
        else
            m = r.read(text);
        if (m == (IRModule*)0)
            return (IRModule*)0;
        // xcc's object is the program's entry module even when main is
        // clang's: a back end writes the load-time constructor table (which
        // the runtime's start walks) only for a module with main or a
        // constructor, so it gets one that does nothing.
        bool hasMain = false;
        for (u32 i = (u32)0; i < m.funcs().count() && !hasMain; i = i + (u32)1)
            hasMain = ((IRFunc*)m.funcs().get(i)).name().equals(String.withCString("main"));
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
        if (!Files.writeText(restLl, r.rest(text)))
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
        cc.appendCString(gCPathProtect
            ? " -O2 -fstack-protector-strong -fno-unwind-tables -fno-asynchronous-unwind-tables -Wno-override-module -c -o "
            : " -O2 -fno-unwind-tables -fno-asynchronous-unwind-tables -Wno-override-module -c -o ");
        cc.append(CPath.quoted(restO));
        cc.appendCString(" ");
        cc.append(CPath.quoted(restLl));
        if (system(cc.cString()) != (i32)0)
            {
            Stdio.error(String.withFormat("xcc: error: clang could not compile the rest of '%s' (%s)\n",
                                          input.cString(), restLl.cString()));
            return (IRModule*)0;
            }
        gCRestObject = restO;
        return m;
        }
    }
