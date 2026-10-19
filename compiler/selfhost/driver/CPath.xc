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
#import "Ir.xc"
#import "LlvmRead.xc"
#import "Frontend.xc"

// clang's object for the part of the C program xcc does not compile (the
// globals, and any function the reader did not read); the link adds it.
String* gCRestObject;

// The C library's: the shell runs clang, with this process's environment.
i32 system(u8* command);
i32 getpid(void);

class CPath
    {
    u8 _unused;

    // `'a'` for the shell, a `'` inside written `'\''`.
    static String* quoted(String* a)
        {
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
        }

    // A scratch path for clang's output, this process's own.
    static String* scratch(void)
        {
        return String.withFormat("/tmp/xcc-c-%ld", getpid());
        }

    // Whether clang runs here.
    static bool haveClang(void)
        {
        return system("clang --version >/dev/null 2>&1") == (i32)0;
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
        String* cmd = String.withCString("clang -O1 -Xclang -disable-llvm-passes -fno-discard-value-names -gline-tables-only -S -emit-llvm");
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
        if (system(cmd.cString()) != (i32)0)
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
        // XC_C_TRACE: the functions left to clang, and why the first was.
        if (r.unread().count() > (u32)0 && Platform.env(String.withCString("XC_C_TRACE")).byteLength() > (u32)0)
            Stdio.error(String.withFormat("xcc: C path: %u function(s) left to clang; the first because of %s\n",
                                          r.unread().count(), r.why() != (String*)0 ? r.why().cString() : "?"));
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
        String* cc = String.withCString("clang -O2 -fno-unwind-tables -fno-asynchronous-unwind-tables -Wno-override-module -c -o ");
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
