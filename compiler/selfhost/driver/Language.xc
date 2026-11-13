// Language.xc — the language table: a source file's extension names a row.
// =========================================================================
//
// A language other than xc reaches xcc as LLVM IR. Its row says which
// command writes that IR, with which flags, what the program's link needs
// (the language's runtime libraries) and which functions xcc takes from the
// IR (the rest stay with the IR's compiler, linked as one object). C and C++
// are built in. More rows come from the file $XC_LANGUAGES names, one per
// line:
//
//     name | .ext .ext | command | IR flags | libraries | reads | linker | passes | read flags | frames
//
// `libraries` are `os:name` words (`macos:c++`): on macOS a name is the SDK's
// usr/lib/lib<name>.tbd, elsewhere `-l<name>`. `reads` is `all` (every
// function the reader can read) or `loops` (only functions with a loop that
// are not ODR copies and that no exception can pass through; see
// Languages.loopFunctions). A row in the file
// replaces a built-in one of the same name, and takes over its extensions.
// `linker`, when given, links the program on macOS (C++: clang++, for its
// runtime, unwind tables and exception tables, which the in-house link does
// not carry); empty, xcc links it. `passes`, when given, are clang's flags
// for a second step over the IR before xcc reads it (C++: -O1, which inlines
// the standard library's small functions into the loops and hoists what does
// not change in them); the functions xcc may take are marked noinline first,
// so their loops are not inlined into callers xcc leaves to clang.
// `read flags`, when given, make a second build of the source, with these
// flags added, the one xcc reads; clang's half is still the first build. A
// function is taken from the second only where the first has it and
// everything it names (C++: libc++'s parallel algorithms as plain loops,
// -D_LIBCPP_PSTL_BACKEND_SERIAL, while what xcc does not take keeps the
// library's own parallel backend). `frames` is `eh_frame` for a language
// whose unwinder reads clang's unwind tables (C++'s exceptions): xcc's link
// keeps them (ELF: .eh_frame, registered at start-up; Mach-O: __unwind_info,
// built from clang's __compact_unwind).
// `#` starts a comment line.

#import "Foundation.xc"
#import "Files.xc"
#import "Stdio.xc"
#import <LlvmRead>

// The table, read once (Languages.rows).
Array* gLanguageRows;
// Building a whole program (not -c): an ODR copy (`linkonce_odr`, a member
// function defined in its class, a template) xcc takes is then the
// program's one definition, so it may take one.
bool gLangWholeProgram;

class LanguageRow
    {
    String* _name;      // c, c++
    Array* _exts;       // of String*: ".c"
    String* _command;   // writes the LLVM IR: clang, clang++
    String* _irFlags;   // its flags for IR before LLVM's own passes
    Array* _libs;       // of String*: os:name, the link's runtime libraries
    bool _loopsOnly;    // reads `loops`: xcc takes only the functions with a loop
    String* _linker;    // links the program on macOS, or "": xcc's own link
    String* _passes;    // clang's flags for a second step over the IR, or ""
    String* _readFlags; // flags of a second build, the one xcc reads, or ""
    bool _ehFrames;     // frames `eh_frame`: the link keeps clang's unwind tables

    String* name(void)    { return _name; }
    Array* exts(void)     { return _exts; }
    String* command(void) { return _command; }
    String* irFlags(void) { return _irFlags; }
    Array* libs(void)     { return _libs; }
    bool loopsOnly(void)  { return _loopsOnly; }
    String* linker(void)  { return _linker; }
    String* passes(void)  { return _passes; }
    String* readFlags(void) { return _readFlags; }
    bool ehFrames(void)   { return _ehFrames; }

    static LanguageRow* make(String* name, String* exts, String* command, String* irFlags, String* libs, String* reads, String* linker, String* passes, String* readFlags, String* frames)
        {
        LanguageRow* r = new LanguageRow();
        r._name = name;
        r._exts = Languages.words(exts);
        r._command = command;
        r._irFlags = irFlags;
        r._libs = Languages.words(libs);
        r._loopsOnly = reads.equals(String.withCString("loops"));
        r._linker = linker;
        r._passes = passes;
        r._readFlags = readFlags;
        r._ehFrames = frames.equals(String.withCString("eh_frame"));
        return r;
        }

    bool takes(String* path)
        {
        for (u32 i = 0; i < _exts.count(); i = i + 1)
            if (path.hasSuffix((String*)_exts.get(i)))
                return true;
        return false;
        }

    // The libraries the link needs on `os` (macos, linux, windows).
    Array* libsFor(String* os)
        {
        Array* out = new Array();
        for (u32 i = 0; i < _libs.count(); i = i + 1)
            {
            String* w = (String*)_libs.get(i);
            u32 colon = w.indexOfByte((u8)':');
            if (colon != String.notFound() && w.substringBytes(0, colon).equals(os))
                out.add((Object*)w.substringFromByte(colon + 1));
            }
        return out;
        }
    }

// A pointer the header of a loop steps (Languages.pointerLoops).
class PtrIv
    {
    String* _name;      // %p
    String* _start;     // its value on entry
    String* _pre;       // the block it enters from
    String* _latch;     // the block it steps from
    i64 _step;          // bytes a step
    u32 _stepLine;      // the line of its step
    u32 _line;          // the line of its phi
    String* _elem;      // the type loaded and stored through it

    String* name(void)   { return _name; }
    String* start(void)  { return _start; }
    String* pre(void)    { return _pre; }
    String* latch(void)  { return _latch; }
    i64 step(void)       { return _step; }
    u32 stepLine(void)   { return _stepLine; }
    u32 line(void)       { return _line; }
    String* elem(void)   { return _elem; }
    }

// The characters of an LLVM value's name after its `%`.
class LlvmName
    {
    u8 _unused;
    static bool isNameByte(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9')
            || c == (u8)'_' || c == (u8)'.' || c == (u8)'$' || c == (u8)'-';
        }
    }

class Languages
    {
    u8 _unused;

    // The built-in rows. Both read clang's IR before LLVM's passes, the shape
    // xc's own lowering hands the optimiser. -funroll-loops: at -O1 clang
    // tags every loop llvm.loop.unroll.disable, which kept clang's half (the
    // functions xcc leaves to clang, compiled at -O2 from this IR) from
    // unrolling and interleaving; xcc's reader ignores loop metadata.
    static Array* builtIn(void)
        {
        Array* t = new Array();
        String* ir = String.withCString("-O1 -funroll-loops -Xclang -disable-llvm-passes -fno-discard-value-names -gline-tables-only -S -emit-llvm");
        t.add((Object*)LanguageRow.make(String.withCString("c"), String.withCString(".c"), String.withCString("clang"),
                                        ir, String.withCString(""), String.withCString("all"), String.withCString(""), String.withCString(""), String.withCString(""),
                                        String.withCString("")));
        // C++: libc++'s parallel algorithms (std::execution) are its
        // experimental library on macOS (libc++experimental.a), linked by
        // xcc like any system library. On win64 the mingw root's libc++.a
        // holds libc++abi and libunwind too (each also has its own archive:
        // naming those as well would link the unwinder twice). Its passes' -fno-unroll-loops keeps
        // the IR xcc reads unrolled.
        t.add((Object*)LanguageRow.make(String.withCString("c++"), String.withCString(".cpp .cc .cxx .C"), String.withCString("clang++"),
                                        ir.appending(String.withCString(" -fexperimental-library")),
                                        String.withCString("macos:c++ macos:c++experimental linux::libstdc++.so.6 linux::libgcc_s.so.1 windows:c++"),
                                        String.withCString("loops"), String.withCString(""),
                                        String.withCString("-O1 -fno-unroll-loops -fno-vectorize -fno-slp-vectorize -fno-discard-value-names -mllvm -rotation-max-header-size=0 -mllvm -indvars-widen-indvars=false"),
                                        String.withCString("-D_LIBCPP_PSTL_BACKEND_SERIAL"), String.withCString("eh_frame")));
        return t;
        }

    // The table: the file's rows first, then the built-in rows it does not
    // replace.
    static Array* rows(void)
        {
        if (gLanguageRows != (Array*)0)
            return gLanguageRows;
        Array* t = new Array();
        String* path = Platform.env(String.withCString("XC_LANGUAGES"));
        if (path.byteLength() > 0)
            {
            String* text = Files.readText(path);
            if (text == (String*)0)
                Stdio.error(String.withFormat("xcc: warning: XC_LANGUAGES: cannot read '%s'\n", path.cString()));
            else
                Languages.parse(text, t);
            }
        Array* b = Languages.builtIn();
        for (u32 i = 0; i < b.count(); i = i + 1)
            {
            LanguageRow* r = (LanguageRow*)b.get(i);
            bool replaced = false;
            for (u32 k = 0; k < t.count() && !replaced; k = k + 1)
                replaced = ((LanguageRow*)t.get(k)).name().equals(r.name());
            if (!replaced)
                t.add((Object*)r);
            }
        gLanguageRows = t;
        return t;
        }

    // Rows of the file's form added to t; a line that is not one is reported.
    static void parse(String* text, Array* t)
        {
        Array* lines = text.replacing(String.withCString("\r\n"), String.withCString("\n")).splitOnByte((u8)10);
        for (u32 i = 0; i < lines.count(); i = i + 1)
            {
            String* l = ((String*)lines.get(i)).trimmed();
            if (l.byteLength() == 0 || l.hasPrefix(String.withCString("#")))
                continue;
            Array* f = l.splitOnByte((u8)'|');
            if (f.count() < 6 || f.count() > 10)
                {
                Stdio.error(String.withFormat("xcc: warning: XC_LANGUAGES line %u: want 6 to 10 fields separated by |, not %u\n",
                                              i + 1, f.count()));
                continue;
                }
            String* reads = ((String*)f.get(5)).trimmed();
            if (!reads.equals(String.withCString("all")) && !reads.equals(String.withCString("loops")))
                {
                Stdio.error(String.withFormat("xcc: warning: XC_LANGUAGES line %u: reads is all or loops, not '%s'\n",
                                              i + 1, reads.cString()));
                continue;
                }
            t.add((Object*)LanguageRow.make(((String*)f.get(0)).trimmed(), ((String*)f.get(1)).trimmed(),
                                            ((String*)f.get(2)).trimmed(), ((String*)f.get(3)).trimmed(),
                                            ((String*)f.get(4)).trimmed(), reads,
                                            f.count() >= 7 ? ((String*)f.get(6)).trimmed() : String.withCString(""),
                                            f.count() >= 8 ? ((String*)f.get(7)).trimmed() : String.withCString(""),
                                            f.count() >= 9 ? ((String*)f.get(8)).trimmed() : String.withCString(""),
                                            f.count() == 10 ? ((String*)f.get(9)).trimmed() : String.withCString("")));
            }
        }

    // The row for a source file, or 0 (xc, or not a language of the table).
    static LanguageRow* forFile(String* path)
        {
        if (path == (String*)0)
            return (LanguageRow*)0;
        Array* t = Languages.rows();
        for (u32 i = 0; i < t.count(); i = i + 1)
            if (((LanguageRow*)t.get(i)).takes(path))
                return (LanguageRow*)t.get(i);
        return (LanguageRow*)0;
        }

    // The space-separated words of s.
    static Array* words(String* s)
        {
        Array* out = new Array();
        u32 start = 0;
        for (u32 i = 0; i <= s.byteLength(); i = i + 1)
            {
            if (i == s.byteLength() || s.byteAt(i) == (u8)' ')
                {
                if (i > start)
                    out.add((Object*)s.substringBytes(start, i - start));
                start = i + 1;
                }
            }
        return out;
        }

    // ── reads `loops` ────────────────────────────────────────────────────
    //
    // The IR the reader is given: each function without a loop, each ODR
    // copy (linkonce, weak, available_externally: another object may define
    // it too, and xcc's objects have no weak definitions) and each function
    // an exception could pass through (xcc writes no unwind tables) becomes
    // a declaration, so it stays with the IR's compiler. Only a function
    // with a loop can gain a par block; the rest of a C++ program
    // (constructors, the standard library's templates, exception paths)
    // never reaches xcc.
    static String* loopFunctions(String* text)
        {
        Array* lines = text.splitOnByte((u8)10);
        Map* nounwind = Languages.nounwindNames(lines);
        String* out = new String();
        u32 i = 0;
        while (i < lines.count())
            {
            String* l = (String*)lines.get(i);
            if (!l.hasPrefix(String.withCString("define ")))
                {
                out.append(l);
                out.appendCString("\n");
                i = i + 1;
                continue;
                }
            u32 end = i + 1;
            while (end < lines.count() && !((String*)lines.get(end)).equals(String.withCString("}")))
                end = end + 1;
            String* fname = Languages.calleeOf(l, 0);
            if (!Languages.notOurs(l) && (fname == (String*)0 || !Languages.isStd(fname)) && Languages.hasLoop(lines, i + 1, end)
                && !Languages.mayThrow(lines, i + 1, end, nounwind))
                {
                Languages.plainLabels(lines, i + 1, end);
                Languages.reroll(lines, i + 1, end);
                Languages.elementOffsets(lines, i + 1, end);
                Languages.byteCounts(lines, i + 1, end);
                Languages.counted(lines, i + 1, end);
                Languages.pointerLoops(lines, i + 1, end);
                Languages.downCounts(lines, i + 1, end);
                for (u32 k = i; k <= end && k < lines.count(); k = k + 1)
                    {
                    out.append((String*)lines.get(k));
                    out.appendCString("\n");
                    }
                }
            else
                {
                String* d = Languages.declarationOf(l);
                if (d != (String*)0)
                    {
                    out.append(d);
                    out.appendCString("\n");
                    }
                }
            i = end + 1;
            }
        return out;
        }

    // Whether `@name` is the C++ standard library's (namespace std): a
    // template it instantiates with a lambda has internal linkage, not an
    // ODR copy's, yet it is the library's code, for clang's passes to inline
    // into the caller, never xcc's to take.
    static bool isStd(String* n)
        {
        String* b = n.hasPrefix(String.withCString("@\"")) ? n.substringFromByte(2) : n.substringFromByte(1);
        // libstdc++'s own namespaces too: its parallel algorithms run in
        // __pstl (serially, without TBB), its iterators in __gnu_cxx.
        return b.hasPrefix(String.withCString("_ZNSt")) || b.hasPrefix(String.withCString("_ZNKSt")) || b.hasPrefix(String.withCString("_ZSt"))
            || b.hasPrefix(String.withCString("_ZN6__pstl")) || b.hasPrefix(String.withCString("_ZNK6__pstl"))
            || b.hasPrefix(String.withCString("_ZN9__gnu_cxx")) || b.hasPrefix(String.withCString("_ZNK9__gnu_cxx"));
        }

    // Whether `@name` is a lambda's call operator (`...$_0clE...` for a
    // named local closure type, `...UlRjE_clE...` for an unnamed one): its
    // body belongs inside the loop that calls it (a std::for_each's), so it
    // is never kept out of its callers.
    static bool isLambda(String* n)
        {
        return n.contains(String.withCString("clE")) && (n.contains(String.withCString("$_")) || n.contains(String.withCString("Ul")));
        }

    static void setWholeProgram(bool b) { gLangWholeProgram = b; }

    // Whether xcc leaves the function of define line l to clang for its
    // linkage: an ODR copy outside a whole-program build, and always one
    // defined elsewhere too (available_externally, weak, comdat any).
    static bool notOurs(String* l)
        {
        if (!Languages.isOdr(l))
            return false;
        if (!gLangWholeProgram)
            return true;
        u32 at = l.indexOfByte((u8)'@');
        String* head = at != String.notFound() ? l.substringBytes(0, at) : l;
        return !(head.contains(String.withCString(" linkonce_odr ")) || head.contains(String.withCString(" linkonce ")));
        }

    // The passed text with every function on the C calling convention:
    // LLVM's -O1 gives each internal function `fastcc`, which the reader does
    // not take in a call (a caller of one was left to clang, perlin's render
    // calling shade), and both halves must agree on it. On the define and
    // declare lines and the calls; a string constant is a global's line.
    static String* plainCallingConv(String* text)
        {
        if (!text.contains(String.withCString(" fastcc ")))
            return text;
        Array* lines = text.splitOnByte((u8)10);
        String* out = new String();
        for (u32 i = 0; i < lines.count(); i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.contains(String.withCString(" fastcc ")))
                {
                if (l.hasPrefix(String.withCString("define ")) || l.hasPrefix(String.withCString("declare ")))
                    l = l.replacing(String.withCString(" fastcc "), String.withCString(" "));
                else if (!l.hasPrefix(String.withCString("@")))
                    {
                    l = l.replacing(String.withCString("call fastcc "), String.withCString("call "));
                    l = l.replacing(String.withCString("invoke fastcc "), String.withCString("invoke "));
                    }
                }
            out.append(l);
            if (i + 1 < lines.count())
                out.appendByte((u8)10);
            }
        return out;
        }

    // The read text with each zero-initialised global of a struct that is
    // one array (`%"struct.std::__1::array" = type { [4096 x double] }`,
    // a std::array) declared as that array: the same bytes, which the
    // reader then takes as an array of elements.
    static String* plainArrays(String* text)
        {
        Array* lines = text.splitOnByte((u8)10);
        Map* one = new Map();
        for (u32 i = 0; i < lines.count(); i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (!l.hasPrefix(String.withCString("%")) || !l.contains(String.withCString(" = type { [")))
                continue;
            u32 at = l.byteIndexOf(String.withCString(" = type { ["));
            String* body = l.substringFromByte(at + 11);
            u32 close = Languages.byteFrom(body, (u8)']', 0);
            if (close == String.notFound() || !body.substringFromByte(close).equals(String.withCString("] }")))
                continue;
            one.set((Hashable*)l.substringBytes(0, at), (Object*)String.withFormat("[%s]", body.substringBytes(0, close).cString()));
            }
        if (one.count() == 0)
            return text;
        String* out = new String();
        for (u32 i = 0; i < lines.count(); i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.hasPrefix(String.withCString("@")) && l.contains(String.withCString(" zeroinitializer")))
                {
                Array* ks = one.allKeys();
                for (u32 k = 0; k < ks.count(); k = k + 1)
                    {
                    String* ty = (String*)ks.get(k);
                    String* g = String.withFormat(" global %s zeroinitializer", ty.cString());
                    if (l.contains(g))
                        l = l.replacing(g, String.withFormat(" global %s zeroinitializer", ((String*)one.get((Hashable*)ty)).cString()));
                    }
                }
            out.append(l);
            if (i + 1 < lines.count())
                out.appendCString("\n");
            }
        return out;
        }

    // Loops that count bytes (clang's passes turn an iterator over a
    // std::array or a vector's elements into `idx += 4` and
    // `getelementptr i8, ptr B, i64 %idx`), in a function's body lines
    // [from, end): the header has
    //     %idx = phi i64 [ 0, %pre ], [ %add, %latch ]
    //     %c = icmp eq i64 %idx, E
    // with %add = add ... i64 %idx, S (S a constant, E a constant multiple
    // of it), %idx used otherwise only by `getelementptr inbounds i8, ptr B,
    // i64 %idx` whose every load and store has one type of size S. Such a
    // loop counts elements: %idx's phi counts by 1, each address is
    // `getelementptr inbounds T, ptr B, i64 %idx`, and the test is against
    // E / S (counted() then writes it `ult`).
    static void byteCounts(Array* lines, u32 from, u32 end)
        {
        for (u32 i = from; i < end; i = i + 1)
            {
            String* t = ((String*)lines.get(i)).trimmed();
            if (!t.contains(String.withCString(" = phi i64 [ 0, ")))
                continue;
            String* idx = t.substringBytes(0, Languages.byteFrom(t, (u8)' ', 0));
            // Its step: `add ... i64 idx, S`.
            Array* ins = t.substringFromByte(t.byteIndexOf(String.withCString(" = phi i64 ")) + 11).splitOnByte((u8)'[');
            String* addv = (String*)0;
            for (u32 q = 0; q < ins.count(); q = q + 1)
                {
                String* e = ((String*)ins.get(q)).trimmed();
                u32 comma = Languages.byteFrom(e, (u8)',', 0);
                if (e.byteLength() == 0 || comma == String.notFound())
                    continue;
                String* v = e.substringBytes(0, comma).trimmed();
                if (!v.equals(String.withCString("0")))
                    addv = v;
                }
            if (addv == (String*)0)
                continue;
            u32 addAt = String.notFound();
            i64 step = 0;
            for (u32 k = from; k < end && addAt == String.notFound(); k = k + 1)
                {
                String* m = ((String*)lines.get(k)).trimmed();
                if (!m.hasPrefix(addv.appending(String.withCString(" = add "))))
                    continue;
                String* tail = String.withFormat(" i64 %s, ", idx.cString());
                u32 p = m.byteIndexOf(tail);
                if (p == String.notFound())
                    break;
                String* rest_ = m.substringFromByte(p + tail.byteLength());
                u32 e = 0;
                while (e < rest_.byteLength() && rest_.byteAt(e) >= (u8)'0' && rest_.byteAt(e) <= (u8)'9')
                    e = e + 1;
                step = Languages.intOf(rest_.substringBytes(0, e));
                addAt = k;
                }
            if (addAt == String.notFound() || step <= 1)
                continue;
            // Every other use: the compare, the add, and i8 GEPs.
            u32 cmpAt = String.notFound();
            i64 bound = 0;
            Array* geps = new Array();
            bool ok = true;
            for (u32 k = from; k < end && ok; k = k + 1)
                {
                if (k == i || k == addAt)
                    continue;
                String* m = ((String*)lines.get(k)).trimmed();
                if (Languages.uses(lines, k, k + 1, idx) == 0)
                    continue;
                String* cmpHead = String.withFormat("= icmp eq i64 %s, ", idx.cString());
                if (m.contains(cmpHead))
                    {
                    String* r = m.substringFromByte(m.byteIndexOf(cmpHead) + cmpHead.byteLength());
                    u32 e = 0;
                    while (e < r.byteLength() && r.byteAt(e) >= (u8)'0' && r.byteAt(e) <= (u8)'9')
                        e = e + 1;
                    bound = Languages.intOf(r.substringBytes(0, e));
                    ok = bound > 0 && bound % step == 0 && cmpAt == String.notFound();
                    cmpAt = k;
                    }
                else if (m.contains(String.withCString(" = getelementptr inbounds i8, ptr "))
                         && m.contains(String.withFormat(", i64 %s", idx.cString())))
                    geps.add((Object*)Number.with(k));
                else
                    ok = false;
                }
            if (!ok || cmpAt == String.notFound() || geps.count() == 0)
                continue;
            // Each address's accesses: one type, of the step's size.
            Array* tys = new Array();
            for (u32 g = 0; g < geps.count() && ok; g = g + 1)
                {
                String* m = ((String*)lines.get(((Number*)geps.get(g)).asU32())).trimmed();
                String* pv = m.substringBytes(0, Languages.byteFrom(m, (u8)' ', 0));
                String* ty = Languages.accessType(lines, from, end, pv);
                ok = ty != (String*)0 && Languages.sizeOf(ty) == step;
                tys.add((Object*)ty);
                }
            if (!ok)
                continue;
            for (u32 g = 0; g < geps.count(); g = g + 1)
                {
                u32 k = ((Number*)geps.get(g)).asU32();
                String* m = (String*)lines.get(k);
                lines.set(k, (Object*)m.replacing(String.withCString(" = getelementptr inbounds i8, ptr "),
                                                  String.withFormat(" = getelementptr inbounds %s, ptr ", ((String*)tys.get(g)).cString())));
                }
            String* am = (String*)lines.get(addAt);
            lines.set(addAt, (Object*)am.replacing(String.withFormat(" i64 %s, %ld", idx.cString(), step),
                                                   String.withFormat(" i64 %s, 1", idx.cString())));
            String* cm = (String*)lines.get(cmpAt);
            lines.set(cmpAt, (Object*)cm.replacing(String.withFormat("icmp eq i64 %s, %ld", idx.cString(), bound),
                                                   String.withFormat("icmp eq i64 %s, %ld", idx.cString(), bound / step)));
            }
        }

    // Whether a define line's linkage lets another object define it too.
    static bool isOdr(String* l)
        {
        u32 at = l.indexOfByte((u8)'@');
        String* head = at != String.notFound() ? l.substringBytes(0, at) : l;
        return head.contains(String.withCString(" linkonce")) || head.contains(String.withCString(" weak"))
               || head.contains(String.withCString(" available_externally"))
               || l.contains(String.withCString(" comdat"));
        }

    // Whether the body lines [from, end) branch back to a block already
    // seen: a loop (the current block included, a loop of one block).
    static bool hasLoop(Array* lines, u32 from, u32 end)
        {
        Map* seen = new Map();
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.byteLength() == 0)
                continue;
            if (l.byteAt(0) != (u8)' ' && l.byteAt(0) != (u8)';')
                {
                u32 colon = l.indexOfByte((u8)':');
                if (colon != String.notFound())
                    seen.set((Hashable*)l.substringBytes(0, colon), (Object*)l);
                continue;
                }
            String* key = String.withCString("label %");
            for (u32 p = l.byteIndexOf(key); p != String.notFound(); p = l.byteIndexOf(key, p + 1))
                {
                u32 s = p + key.byteLength();
                u32 e = s;
                while (e < l.byteLength() && l.byteAt(e) != (u8)',' && l.byteAt(e) != (u8)' ' && l.byteAt(e) != (u8)']')
                    e = e + 1;
                if (e > s && seen.get((Hashable*)l.substringBytes(s, e - s)) != (Object*)0)
                    return true;
                }
            }
        return false;
        }

    // What cannot throw: each attribute group `#N` with nounwind, and each
    // function `@name` declared or defined with one.
    static Map* nounwindNames(Array* lines)
        {
        Map* m = new Map();
        for (u32 i = 0; i < lines.count(); i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.hasPrefix(String.withCString("attributes #")) && l.contains(String.withCString(" nounwind")))
                {
                u32 sp = Languages.byteFrom(l, (u8)' ', 11);
                if (sp != String.notFound())
                    m.set((Hashable*)l.substringBytes(11, sp - 11), (Object*)l);
                }
            }
        for (u32 i = 0; i < lines.count(); i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (!l.hasPrefix(String.withCString("define ")) && !l.hasPrefix(String.withCString("declare ")))
                continue;
            String* name = Languages.calleeOf(l, 0);
            if (name != (String*)0 && Languages.hasGroupIn(l, m))
                m.set((Hashable*)name, (Object*)l);
            }
        return m;
        }

    // Whether a body line of [from, end) calls what may throw: a call is
    // safe to an llvm.* intrinsic, or with nounwind on the call or on the
    // function called.
    static bool mayThrow(Array* lines, u32 from, u32 end, Map* nounwind)
        {
        String* key = String.withCString(" call ");
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            // An invoke has a landing pad: the call it makes can throw.
            if (l.contains(String.withCString(" invoke ")))
                return true;
            u32 c = l.byteIndexOf(key);
            if (c == String.notFound())
                continue;
            String* name = Languages.calleeOf(l, c);
            if (name != (String*)0 && (name.hasPrefix(String.withCString("@llvm.")) || nounwind.get((Hashable*)name) != (Object*)0))
                continue;
            if (Languages.hasGroupIn(l, nounwind))
                continue;
            return true;
            }
        return false;
        }

    // The `@name` called (or defined) at or after `from`: the first `@` word
    // followed by `(`; 0 for a call through a pointer.
    static String* calleeOf(String* l, u32 from)
        {
        u32 at = Languages.byteFrom(l, (u8)'@', from);
        while (at != String.notFound())
            {
            u32 e = at + 1;
            if (e < l.byteLength() && l.byteAt(e) == (u8)'"')
                {
                e = e + 1;
                while (e < l.byteLength() && l.byteAt(e) != (u8)'"')
                    e = e + 1;
                e = e + 1;
                }
            else
                while (e < l.byteLength() && l.byteAt(e) != (u8)'(' && l.byteAt(e) != (u8)' ' && l.byteAt(e) != (u8)',')
                    e = e + 1;
            if (e < l.byteLength() && l.byteAt(e) == (u8)'(')
                return l.substringBytes(at, e - at);
            at = Languages.byteFrom(l, (u8)'@', e);
            }
        return (String*)0;
        }

    // The first c in s at or after `from`, or String.notFound().
    static u32 byteFrom(String* s, u8 c, u32 from)
        {
        for (u32 i = from; i < s.byteLength(); i = i + 1)
            if (s.byteAt(i) == c)
                return i;
        return String.notFound();
        }

    // Whether the line names an attribute group `#N` that is in m.
    static bool hasGroupIn(String* l, Map* m)
        {
        for (u32 p = Languages.byteFrom(l, (u8)'#', 0); p != String.notFound(); p = Languages.byteFrom(l, (u8)'#', p + 1))
            {
            u32 e = p + 1;
            while (e < l.byteLength() && l.byteAt(e) >= (u8)'0' && l.byteAt(e) <= (u8)'9')
                e = e + 1;
            if (e > p + 1 && m.get((Hashable*)l.substringBytes(p, e - p)) != (Object*)0)
                return true;
            }
        return false;
        }

    // The IR before the passes, with each function xcc may take marked
    // noinline (a loop, not an ODR copy, not already alwaysinline), so that
    // clang's -O1 inlines the small functions into its loops, and not its
    // loops into a caller xcc leaves to clang.
    static String* markNoinline(String* text)
        {
        return Languages.markNoinlineOf(text, Languages.loopNames(text));
        }

    // The functions markNoinline marks in text: defined, not ODR copies,
    // with a loop. A map from each `@name` to its define line.
    static Map* loopNames(String* text)
        {
        Map* names = new Map();
        Array* lines = text.splitOnByte((u8)10);
        u32 i = 0;
        while (i < lines.count())
            {
            String* l = (String*)lines.get(i);
            if (!l.hasPrefix(String.withCString("define ")))
                {
                i = i + 1;
                continue;
                }
            u32 end = i + 1;
            while (end < lines.count() && !((String*)lines.get(end)).equals(String.withCString("}")))
                end = end + 1;
            String* n = Languages.calleeOf(l, 0);
            if (n != (String*)0 && !Languages.notOurs(l) && !Languages.isStd(n) && !Languages.isLambda(n) && Languages.hasLoop(lines, i + 1, end))
                names.set((Hashable*)n, (Object*)l);
            i = end + 1;
            }
        return names;
        }

    // Every function of text clang's passes could inline that xcc might
    // take: defined, not an ODR copy, not the standard library's, not a
    // lambda's call operator. The probe run keeps them all out of their
    // callers, to see which have loops once their own callees are inlined.
    static Map* userFunctions(String* text)
        {
        Map* names = new Map();
        Map* inner = Languages.calledInLoops(text);
        Array* lines = text.splitOnByte((u8)10);
        for (u32 i = 0; i < lines.count(); i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (!l.hasPrefix(String.withCString("define ")))
                continue;
            String* n = Languages.calleeOf(l, 0);
            if (n != (String*)0 && !Languages.notOurs(l) && !Languages.isStd(n) && !Languages.isLambda(n)
                && inner.get((Hashable*)n) == (Object*)0)
                names.set((Hashable*)n, (Object*)l);
            }
        return names;
        }

    // The functions called from inside a loop of another (in clang's own
    // IR, a loop's blocks lie between its header and the branch back to
    // it): a helper such as perlin's shade, which belongs inlined in its
    // caller's loop for that loop to become a block, not kept out.
    static Map* calledInLoops(String* text)
        {
        Map* inner = new Map();
        Array* lines = text.splitOnByte((u8)10);
        u32 i = 0;
        while (i < lines.count())
            {
            String* l = (String*)lines.get(i);
            if (!l.hasPrefix(String.withCString("define ")))
                {
                i = i + 1;
                continue;
                }
            String* self_ = Languages.calleeOf(l, 0);
            u32 end = i + 1;
            while (end < lines.count() && !((String*)lines.get(end)).equals(String.withCString("}")))
                end = end + 1;
            Map* labelAt = new Map();
            for (u32 k = i + 1; k < end; k = k + 1)
                {
                String* m = (String*)lines.get(k);
                if (m.byteLength() > 0 && m.byteAt(0) != (u8)' ' && m.byteAt(0) != (u8)';')
                    {
                    u32 colon = Languages.byteFrom(m, (u8)':', 0);
                    if (colon != String.notFound())
                        labelAt.set((Hashable*)m.substringBytes(0, colon), (Object*)Number.with(k));
                    continue;
                    }
                // A branch back: lines from its target's label to here.
                String* key = String.withCString("label %");
                for (u32 p = m.byteIndexOf(key); p != String.notFound(); p = m.byteIndexOf(key, p + 1))
                    {
                    u32 s0 = p + key.byteLength();
                    u32 e = s0;
                    while (e < m.byteLength() && m.byteAt(e) != (u8)',' && m.byteAt(e) != (u8)' ')
                        e = e + 1;
                    Number* h = (Number*)labelAt.get((Hashable*)m.substringBytes(s0, e - s0));
                    if (h == (Number*)0)
                        continue;
                    for (u32 q = h.asU32(); q < k; q = q + 1)
                        {
                        String* c = (String*)lines.get(q);
                        u32 at = c.byteIndexOf(String.withCString(" call "));
                        if (at == String.notFound())
                            continue;
                        String* callee = Languages.calleeOf(c, at);
                        if (callee != (String*)0 && (self_ == (String*)0 || !callee.equals(self_)))
                            inner.set((Hashable*)callee, (Object*)c);
                        }
                    }
                }
            i = end + 1;
            }
        return inner;
        }

    // text with each function of `names` marked noinline (not one already
    // alwaysinline or noinline).
    static String* markNoinlineOf(String* text, Map* names)
        {
        Array* lines = text.splitOnByte((u8)10);
        Map* always = new Map();
        for (u32 i = 0; i < lines.count(); i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.hasPrefix(String.withCString("attributes #")) && (l.contains(String.withCString(" alwaysinline"))
                || l.contains(String.withCString(" noinline"))))
                {
                u32 sp = Languages.byteFrom(l, (u8)' ', 11);
                if (sp != String.notFound())
                    always.set((Hashable*)l.substringBytes(11, sp - 11), (Object*)l);
                }
            }
        String* out = new String();
        u32 i = 0;
        while (i < lines.count())
            {
            String* l = (String*)lines.get(i);
            String* ln = l.hasPrefix(String.withCString("define ")) ? Languages.calleeOf(l, 0) : (String*)0;
            if (ln != (String*)0 && names.get((Hashable*)ln) != (Object*)0 && !Languages.hasGroupIn(l, always))
                {
                String* d = Languages.declarationOf(l);
                if (d != (String*)0)
                    {
                    // After the parameter list and any unnamed_addr (which
                    // LLVM wants before the attributes): `define ... @f(...)
                    // unnamed_addr noinline #0 {`.
                    u32 q = d.byteLength() - 7 + 6;
                    String* rest_ = l.substringFromByte(q);
                    if (rest_.hasPrefix(String.withCString(" local_unnamed_addr")))
                        q = q + 19;
                    else if (rest_.hasPrefix(String.withCString(" unnamed_addr")))
                        q = q + 13;
                    l = l.substringBytes(0, q).appending(String.withCString(" noinline")).appending(l.substringFromByte(q));
                    }
                }
            out.append(l);
            if (i + 1 < lines.count())
                out.appendCString("\n");
            i = i + 1;
            }
        return out;
        }

    // The read build's IR (after loopFunctions) with each function it would
    // give xcc kept only where clang's build has it too, with everything it
    // names: each function it calls defined or declared there, each global it
    // names defined there by the same line. Any other becomes a declaration,
    // and stays clang's (as the first build compiles it).
    static String* takeFrom(String* readText, String* clangText)
        {
        Map* cfuncs = new Map();
        Map* cglobs = new Map();
        Languages.symbolsOf(clangText, cfuncs, cglobs);
        Map* rfuncs = new Map();
        Map* rglobs = new Map();
        Languages.symbolsOf(readText, rfuncs, rglobs);
        Array* lines = readText.splitOnByte((u8)10);
        String* out = new String();
        u32 i = 0;
        while (i < lines.count())
            {
            String* l = (String*)lines.get(i);
            if (!l.hasPrefix(String.withCString("define ")))
                {
                out.append(l);
                out.appendCString("\n");
                i = i + 1;
                continue;
                }
            u32 end = i + 1;
            while (end < lines.count() && !((String*)lines.get(end)).equals(String.withCString("}")))
                end = end + 1;
            String* n = Languages.calleeOf(l, 0);
            // A quoted name has no plain `_xclib` twin: not taken.
            bool ok = n != (String*)0 && !n.hasPrefix(String.withCString("@\""))
                      && cfuncs.get((Hashable*)n) != (Object*)0
                      && ((String*)cfuncs.get((Hashable*)n)).hasPrefix(String.withCString("define "));
            for (u32 k = i + 1; k < end && ok; k = k + 1)
                ok = Languages.namesAllIn((String*)lines.get(k), cfuncs, cglobs, rglobs);
            if (ok)
                {
                for (u32 k = i; k <= end && k < lines.count(); k = k + 1)
                    {
                    out.append((String*)lines.get(k));
                    out.appendCString("\n");
                    }
                // clang's own version, which xcc's calls if it makes no block
                // of it (libFallback): `<name>_xclib`.
                String* d = Languages.declarationOf(l);
                if (d != (String*)0)
                    {
                    out.append(d.replacing(n.appending(String.withCString("(")), n.appending(String.withCString("_xclib("))));
                    out.appendCString("\n");
                    }
                }
            else
                {
                String* d = Languages.declarationOf(l);
                if (d != (String*)0)
                    {
                    out.append(d);
                    out.appendCString("\n");
                    }
                }
            i = end + 1;
            }
        return out;
        }

    // The rest's text with clang's own definition of each function the
    // reader took from the read build (each `@<name>_xclib` it declares)
    // added as `@<name>_xclib`, external, its globals renamed as the rest's
    // are: xcc's version calls it where it makes no block (libFallback).
    static String* keepClangCopies(String* restText, String* clangText, String* readText, LlvmReader* r)
        {
        Array* rl = readText.splitOnByte((u8)10);
        Map* want = new Map();
        for (u32 i = 0; i < rl.count(); i = i + 1)
            {
            String* l = (String*)rl.get(i);
            if (!l.hasPrefix(String.withCString("declare ")) || !l.contains(String.withCString("_xclib(")))
                continue;
            String* n = Languages.calleeOf(l, 0);
            if (n != (String*)0 && n.hasSuffix(String.withCString("_xclib")))
                want.set((Hashable*)n.substringBytes(0, n.byteLength() - 6), (Object*)n);
            }
        if (want.count() == 0)
            return restText;
        String* out = String.withString(restText);
        Array* cl = clangText.splitOnByte((u8)10);
        u32 i = 0;
        while (i < cl.count())
            {
            String* l = (String*)cl.get(i);
            String* n = l.hasPrefix(String.withCString("define ")) ? Languages.calleeOf(l, 0) : (String*)0;
            if (n == (String*)0 || want.get((Hashable*)n) == (Object*)0)
                {
                i = i + 1;
                continue;
                }
            out.appendCString("\n");
            // Without its debug information: the function it copies keeps
            // its subprogram, and one subprogram attached to two functions
            // makes clang drop the half's debug information, with a warning.
            String* head = LlvmReader.external(r.renamed(l)).replacing(n.appending(String.withCString("(")),
                                                                        n.appending(String.withCString("_xclib(")));
            // Out of any COMDAT group: the group bears the original's name,
            // which the copy no longer has ("use of undefined comdat").
            head = Languages.withoutComdat(head);
            // Kept even where clang inlines it everywhere: xcc's half calls it.
            head = head.replacing(String.withCString("define linkonce_odr "), String.withCString("define weak_odr "))
                       .replacing(String.withCString("define linkonce "), String.withCString("define weak "));
            out.append(Languages.withoutDbg(head));
            out.appendCString("\n");
            i = i + 1;
            while (i < cl.count() && !((String*)cl.get(i)).equals(String.withCString("}")))
                {
                String* bl = (String*)cl.get(i);
                if (!bl.trimmed().hasPrefix(String.withCString("#dbg_")))
                    {
                    out.append(Languages.withoutDbg(r.renamed(bl)));
                    out.appendCString("\n");
                    }
                i = i + 1;
                }
            out.appendCString("}\n");
            i = i + 1;
            }
        return out;
        }

    // A define line without its ` comdat` / ` comdat($name)`.
    static String* withoutComdat(String* l)
        {
        u32 p = l.byteIndexOf(String.withCString(" comdat"));
        if (p == String.notFound())
            return l;
        u32 e = p + 7;
        if (e < l.byteLength() && l.byteAt(e) == (u8)'(')
            {
            while (e < l.byteLength() && l.byteAt(e) != (u8)')')
                e = e + 1;
            e = e + 1;
            }
        return l.substringBytes(0, p).appending(l.substringFromByte(e));
        }

    // A line without its `!dbg !N` attachments.
    static String* withoutDbg(String* l)
        {
        String* key = String.withCString(" !dbg !");
        u32 p = l.byteIndexOf(key);
        while (p != String.notFound())
            {
            u32 e = p + key.byteLength();
            while (e < l.byteLength() && l.byteAt(e) >= (u8)'0' && l.byteAt(e) <= (u8)'9')
                e = e + 1;
            u32 b = p > 0 && l.byteAt(p - 1) == (u8)',' ? p - 1 : p;
            l = l.substringBytes(0, b).appending(l.substringFromByte(e));
            p = l.byteIndexOf(key);
            }
        return l;
        }

    // The functions (`@name` -> its define or declare line) and globals
    // (`@name` -> its definition line) of an IR text.
    static void symbolsOf(String* text, Map* funcs, Map* globs)
        {
        Array* lines = text.splitOnByte((u8)10);
        for (u32 i = 0; i < lines.count(); i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.hasPrefix(String.withCString("define ")) || l.hasPrefix(String.withCString("declare ")))
                {
                String* n = Languages.calleeOf(l, 0);
                if (n != (String*)0 && (funcs.get((Hashable*)n) == (Object*)0 || l.hasPrefix(String.withCString("define "))))
                    funcs.set((Hashable*)n, (Object*)l);
                }
            else if (l.hasPrefix(String.withCString("@")))
                {
                u32 sp = Languages.byteFrom(l, (u8)' ', 0);
                if (sp != String.notFound())
                    globs.set((Hashable*)l.substringBytes(0, sp), (Object*)l);
                }
            }
        }

    // Whether every `@name` the body line l names is in clang's build: a
    // function defined or declared there, an intrinsic, or a global defined
    // there by the line the read build has.
    static bool namesAllIn(String* l, Map* cfuncs, Map* cglobs, Map* rglobs)
        {
        u32 p = Languages.byteFrom(l, (u8)'@', 0);
        while (p != String.notFound())
            {
            u32 e = p + 1;
            if (e < l.byteLength() && l.byteAt(e) == (u8)'"')
                {
                e = e + 1;
                while (e < l.byteLength() && l.byteAt(e) != (u8)'"')
                    e = e + 1;
                e = e + 1;
                }
            else
                while (e < l.byteLength() && LlvmName.isNameByte(l.byteAt(e)))
                    e = e + 1;
            String* n = l.substringBytes(p, e - p);
            if (!n.hasPrefix(String.withCString("@llvm.")) && cfuncs.get((Hashable*)n) == (Object*)0)
                {
                String* cg = (String*)cglobs.get((Hashable*)n);
                String* rg = (String*)rglobs.get((Hashable*)n);
                if (cg == (String*)0 || rg == (String*)0 || !cg.equals(rg))
                    return false;
                }
            p = e < l.byteLength() ? Languages.byteFrom(l, (u8)'@', e) : String.notFound();
            }
        return true;
        }

    // A function's quoted block labels (`"_ZNSt3__1...exit":`, from code
    // clang inlined, with `$` and the like in them) renamed plain (xcq0,
    // xcq1, ...) in its body lines [from, end), each use (`label %"..."`, a
    // phi's `%"..."`) with it: xc's own IR names a block by a plain word.
    static void plainLabels(Array* lines, u32 from, u32 end)
        {
        Map* renames = new Map();
        u32 n = 0;
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (!l.hasPrefix(String.withCString("\"")))
                continue;
            u32 close = Languages.byteFrom(l, (u8)'"', 1);
            if (close == String.notFound() || close + 1 >= l.byteLength() || l.byteAt(close + 1) != (u8)':')
                continue;
            String* q = l.substringBytes(0, close + 1);
            String* plain = String.withFormat("xcq%u", n);
            n = n + 1;
            renames.set((Hashable*)q, (Object*)plain);
            lines.set(i, (Object*)plain.appending(l.substringFromByte(close + 1)));
            }
        if (n == 0)
            return;
        Array* ks = renames.allKeys();
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (!l.contains(String.withCString("%\"")))
                continue;
            for (u32 k = 0; k < ks.count(); k = k + 1)
                {
                String* q = (String*)ks.get(k);
                l = l.replacing(String.withCString("%").appending(q), String.withCString("%").appending((String*)renames.get((Hashable*)q)));
                }
            lines.set(i, (Object*)l);
            }
        }

    // Each counted loop's exit test in a function's body lines [from, end)
    // in the form the outliner takes. Clang's passes end a loop counting i
    // from 0 by 1 with `icmp eq i, n` and branch to the exit on true; with
    // n set before the loop, `i == n` there is `!(i <u n)`, so the test is
    // written `icmp ult` and the branch's targets swapped (`icmp ne` keeps
    // them).
    static void counted(Array* lines, u32 from, u32 end)
        {
        u32 blockStart = from;
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.byteLength() > 0 && l.byteAt(0) != (u8)' ' && l.byteAt(0) != (u8)';')
                {
                blockStart = i + 1;
                continue;
                }
            bool eq = l.contains(String.withCString(" = icmp eq i"));
            if (!eq && !l.contains(String.withCString(" = icmp ne i")))
                continue;
            String* t = l.trimmed();
            u32 sp = Languages.byteFrom(t, (u8)' ', 0);
            if (sp == String.notFound())
                continue;
            String* c = t.substringBytes(0, sp);
            // `icmp eq i64 %a, %b, !dbg !7`: the type and a, then b.
            u32 at = t.byteIndexOf(String.withCString(" icmp ")) + 9;
            Array* parts = t.substringFromByte(at).splitOnByte((u8)',');
            if (parts.count() < 2)
                continue;
            Array* ta = Languages.words(((String*)parts.get(0)).trimmed());
            String* b = ((String*)parts.get(1)).trimmed();
            if (ta.count() != 2)
                continue;
            String* ty = (String*)ta.get(0);
            String* a = (String*)ta.get(1);
            // The block's branch on c, and c used nowhere else.
            u32 brAt = String.notFound();
            for (u32 k = i + 1; k < end && brAt == String.notFound(); k = k + 1)
                {
                String* m = (String*)lines.get(k);
                if (m.byteLength() > 0 && m.byteAt(0) != (u8)' ')
                    break;
                if (m.trimmed().hasPrefix(String.withFormat("br i1 %s, label ", c.cString())))
                    brAt = k;
                }
            if (brAt == String.notFound() || Languages.uses(lines, from, end, c) != 2)
                continue;
            // a counts by 1 in this block's phi from a value made before the
            // loop; b is not made in the header. Clang's passes write `i == n`
            // for `i < n` only where the start is at most n, so the test is
            // `i <u n`.
            if (!Languages.countsFromZero(lines, blockStart, i, from, end, a, ty) || Languages.definedIn(lines, blockStart, brAt, b))
                continue;
            lines.set(i, (Object*)l.replacing(String.withFormat(" = icmp %s %s ", eq ? "eq" : "ne", ty.cString()),
                                              String.withFormat(" = icmp ult %s ", ty.cString())));
            if (eq)
                {
                String* m = (String*)lines.get(brAt);
                String* head = String.withFormat("br i1 %s, ", c.cString());
                u32 hb = m.byteIndexOf(head);
                Array* tg = m.substringFromByte(hb + head.byteLength()).splitOnByte((u8)',');
                if (tg.count() < 2)
                    continue;
                String* nm = m.substringBytes(0, hb + head.byteLength());
                nm.append(((String*)tg.get(1)).trimmed());
                nm.appendCString(", ");
                nm.append(((String*)tg.get(0)).trimmed());
                for (u32 k = 2; k < tg.count(); k = k + 1)
                    {
                    nm.appendCString(",");
                    nm.append((String*)tg.get(k));
                    }
                lines.set(brAt, (Object*)nm);
                }
            }
        }

    // Loops that count with pointers (C++'s iterators, `for (p = a; p != e;
    // ++p)`) in the form the outliner takes, in a function's body lines
    // [from, end). Clang's passes leave a header
    //     %p = phi ptr [ %s, %pre ], [ %pn, %latch ]
    //     %c = icmp eq ptr %p, %e
    //     br i1 %c, label %exit, label %body
    // with %pn = getelementptr ... %p, a constant step, every load and store
    // through %p of one type T that size, and %e made before the loop. Such
    // a loop runs (e - s) / step times (C and C++ give it no other end: p
    // reaches e exactly), so it is written with a counter i from 0 to n
    // (computed in %pre) and %p = getelementptr T, ptr %s, i64 %i: an element
    // at [i]. Other pointer phis of the header that step with it by their own
    // constant are written the same way. A line that grows is several lines
    // joined by newlines.
    static void pointerLoops(Array* lines, u32 from, u32 end)
        {
        u32 made = 0;
        u32 blockStart = from;
        String* blockName = (String*)0;
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.byteLength() > 0 && l.byteAt(0) != (u8)' ' && l.byteAt(0) != (u8)';')
                {
                blockStart = i + 1;
                u32 colon = Languages.byteFrom(l, (u8)':', 0);
                blockName = colon != String.notFound() ? l.substringBytes(0, colon) : (String*)0;
                continue;
                }
            bool eq = l.contains(String.withCString(" = icmp eq ptr "));
            if (!eq && !l.contains(String.withCString(" = icmp ne ptr ")))
                continue;
            String* t = l.trimmed();
            u32 sp = Languages.byteFrom(t, (u8)' ', 0);
            String* c = t.substringBytes(0, sp);
            Array* parts = t.substringFromByte(t.byteIndexOf(String.withCString(" ptr ")) + 5).splitOnByte((u8)',');
            if (parts.count() < 2 || blockName == (String*)0)
                continue;
            String* a = ((String*)parts.get(0)).trimmed();
            String* b = ((String*)parts.get(1)).trimmed();
            u32 brAt = String.notFound();
            for (u32 k = i + 1; k < end && brAt == String.notFound(); k = k + 1)
                {
                String* m = (String*)lines.get(k);
                if (m.byteLength() > 0 && m.byteAt(0) != (u8)' ')
                    break;
                if (m.trimmed().hasPrefix(String.withFormat("br i1 %s, label ", c.cString())))
                    brAt = k;
                }
            if (brAt == String.notFound() || Languages.uses(lines, from, end, c) != 2)
                continue;
            // Which side is the header's pointer phi; the other is the end.
            PtrIv* iv = Languages.ptrIv(lines, blockStart, i, from, end, a);
            String* e = b;
            if (iv == (PtrIv*)0)
                {
                iv = Languages.ptrIv(lines, blockStart, i, from, end, b);
                e = a;
                }
            if (iv == (PtrIv*)0 || Languages.definedIn(lines, blockStart, brAt, e))
                continue;
            // Every other pointer phi of the header: one that steps too.
            Array* others = new Array();
            bool ok = true;
            for (u32 k = blockStart; k < i && ok; k = k + 1)
                {
                String* m = ((String*)lines.get(k)).trimmed();
                if (!m.contains(String.withCString(" = phi ptr ")) || m.hasPrefix(iv.name().appending(String.withCString(" "))))
                    continue;
                String* qn = m.substringBytes(0, Languages.byteFrom(m, (u8)' ', 0));
                PtrIv* q = Languages.ptrIv(lines, blockStart, i, from, end, qn);
                if (q == (PtrIv*)0 || !q.pre().equals(iv.pre()) || !q.latch().equals(iv.latch()))
                    ok = false;
                else
                    others.add((Object*)q);
                }
            if (!ok)
                continue;
            // The rewrite. Names of our own, per loop.
            String* tag = String.withFormat("%%xcpi%u", made);
            made = made + 1;
            String* idx = tag.appending(String.withCString(".i"));
            String* nxt = tag.appending(String.withCString(".next"));
            String* cnt = tag.appending(String.withCString(".n"));
            // The preheader: n = (e - s) / step, before its branch.
            u32 preBr = Languages.terminatorOf(lines, from, end, iv.pre());
            if (preBr == String.notFound())
                continue;
            String* pre = String.withFormat("  %s.s = ptrtoint ptr %s to i64\n  %s.e = ptrtoint ptr %s to i64\n  %s.d = sub i64 %s.e, %s.s\n  %s = sdiv exact i64 %s.d, %ld\n",
                                            tag.cString(), iv.start().cString(), tag.cString(), e.cString(), tag.cString(), tag.cString(), tag.cString(),
                                            cnt.cString(), tag.cString(), iv.step());
            lines.set(preBr, (Object*)pre.appending((String*)lines.get(preBr)));
            // The header: the counter's phi, then each pointer as [i].
            String* hdr = String.withFormat("  %s = phi i64 [ 0, %s ], [ %s, %s ]", idx.cString(), iv.pre().cString(), nxt.cString(), iv.latch().cString());
            // The body: the branch's target in the loop (the false one for eq).
            String* bodyLabel = Languages.branchTarget((String*)lines.get(brAt), c, eq ? 1 : 0);
            u32 bodyAt = bodyLabel != (String*)0 ? Languages.labelLine(lines, from, end, bodyLabel) : String.notFound();
            if (bodyAt == String.notFound())
                continue;
            Array* all = new Array();
            all.add((Object*)iv);
            all.addAll(others);
            // The header's last phi, found before ours are taken out.
            u32 lastPhi = blockStart;
            for (u32 k = blockStart; k < i; k = k + 1)
                if (((String*)lines.get(k)).contains(String.withCString(" = phi ")))
                    lastPhi = k;
            for (u32 k = 0; k < all.count(); k = k + 1)
                {
                PtrIv* q = (PtrIv*)all.get(k);
                lines.set(q.line(), (Object*)String.withCString(""));
                }
            String* geps = new String();
            for (u32 k = 0; k < all.count(); k = k + 1)
                {
                PtrIv* q = (PtrIv*)all.get(k);
                geps.appendFormat("\n  %s = getelementptr inbounds %s, ptr %s, i64 %s", q.name().cString(), q.elem().cString(),
                                  q.start().cString(), idx.cString());
                }
            // The counter's phi after the header's last phi (in its place, when
            // it was ours). Each pointer is made at the top of the body, where
            // its loads and stores are: made in the header, an unrolled body's
            // copies all read the first copy's.
            String* atPhi = (String*)lines.get(lastPhi);
            if (atPhi.byteLength() == 0)
                lines.set(lastPhi, (Object*)hdr);
            else
                lines.set(lastPhi, (Object*)atPhi.appending(String.withCString("\n")).appending(hdr));
            lines.set(bodyAt, (Object*)((String*)lines.get(bodyAt)).appending(geps));
            // The test and, for eq, the branch's targets swapped.
            lines.set(i, (Object*)String.withFormat("  %s = icmp ult i64 %s, %s", c.cString(), idx.cString(), cnt.cString()));
            if (eq)
                Languages.swapTargets(lines, brAt, c);
            // The latch: the counter's next value beside the pointer's.
            String* sl = (String*)lines.get(iv.stepLine());
            lines.set(iv.stepLine(), (Object*)sl.appending(String.withFormat("\n  %s = add nuw nsw i64 %s, 1", nxt.cString(), idx.cString())));
            }
        }


    // A byte offset from an element's address that is a whole number of
    // elements, in a function's body lines [from, end):
    //     %b = getelementptr [inbounds] T, ptr %p, i64 %x
    //     %a = getelementptr [inbounds nuw] i8, ptr %b, i64 C     ; C = k * sizeof(T)
    // is written %a = getelementptr T, ptr %p, i64 (%x + k): clang's
    // `in[i - 1]` beside `in[i]`, now an element of %p, which the outliner
    // sees as one array read near [i] (stencil's neighbours), not as a
    // pointer made in the loop.
    static void elementOffsets(Array* lines, u32 from, u32 end)
        {
        Map* elemGep = new Map();   // %b -> "T|%p|%x"
        u32 made = 0;
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            String* t = Languages.withoutMeta(l.trimmed());
            u32 eq = t.byteIndexOf(String.withCString(" = getelementptr "));
            if (eq == String.notFound() || !t.hasPrefix(String.withCString("%")))
                continue;
            String* nm = t.substringBytes(0, eq);
            String* rest = t.substringFromByte(eq + 17);
            if (rest.hasPrefix(String.withCString("inbounds ")))
                rest = rest.substringFromByte(9);
            if (rest.hasPrefix(String.withCString("nuw ")))
                rest = rest.substringFromByte(4);
            Array* parts = rest.splitOnByte((u8)',');
            if (parts.count() != 3)
                continue;
            String* ty = ((String*)parts.get(0)).trimmed();
            String* base = ((String*)parts.get(1)).trimmed();
            String* ix = ((String*)parts.get(2)).trimmed();
            if (!base.hasPrefix(String.withCString("ptr %")) || !ix.hasPrefix(String.withCString("i64 ")))
                continue;
            base = base.substringFromByte(4);
            ix = ix.substringFromByte(4);
            if (!ty.equals(String.withCString("i8")))
                {
                if (Languages.sizeOf(ty) > 0)
                    elemGep.set((Hashable*)nm, (Object*)String.withFormat("%s|%s|%s", ty.cString(), base.cString(), ix.cString()));
                continue;
                }
            String* e = (String*)elemGep.get((Hashable*)base);
            if (e == (String*)0)
                continue;
            Array* f = e.splitOnByte((u8)'|');
            String* et = (String*)f.get(0);
            i64 sz = Languages.sizeOf(et);
            bool neg = ix.hasPrefix(String.withCString("-"));
            i64 c = Languages.intOf(neg ? ix.substringFromByte(1) : ix);
            if (sz <= 0 || c == 0 || c % sz != 0)
                continue;
            i64 k = (neg ? (i64)0 - c : c) / sz;
            String* tag = String.withFormat("%%xeo%u", made);
            made = made + 1;
            lines.set(i, (Object*)String.withFormat("  %s = add i64 %s, %ld\n  %s = getelementptr %s, ptr %s, i64 %s",
                                                    tag.cString(), ((String*)f.get(2)).cString(), k,
                                                    nm.cString(), et.cString(), ((String*)f.get(1)).cString(), tag.cString()));
            }
        }

    // The `%names` a line mentions, in order (each as written, with its %).
    static Array* namesIn(String* l)
        {
        Array* out = new Array();
        u32 i = 0;
        while (i < l.byteLength())
            {
            if (l.byteAt(i) != (u8)'%')
                {
                i = i + 1;
                continue;
                }
            u32 e = i + 1;
            while (e < l.byteLength() && LlvmName.isNameByte(l.byteAt(e)))
                e = e + 1;
            if (e > i + 1)
                out.add((Object*)l.substringBytes(i, e - i));
            i = e;
            }
        return out;
        }

    // A commutative binary instruction (`%x = add nsw i32 %a, %b`; add,
    // mul, and, or, xor, fadd, fmul: IEEE's a + b is b + a) with its two
    // operands in one order, so two copies that clang wrote each way round
    // read alike. Any other line as it is.
    static String* commutedInOrder(String* l)
        {
        u32 eq = l.byteIndexOf(String.withCString(" = "));
        if (eq == String.notFound())
            return l;
        String* rest = l.substringFromByte(eq + 3);
        u32 sp = Languages.byteFrom(rest, (u8)' ', 0);
        if (sp == String.notFound())
            return l;
        String* op = rest.substringBytes(0, sp);
        if (!op.equals(String.withCString("add")) && !op.equals(String.withCString("mul")) && !op.equals(String.withCString("and"))
            && !op.equals(String.withCString("or")) && !op.equals(String.withCString("xor")) && !op.equals(String.withCString("fadd"))
            && !op.equals(String.withCString("fmul")))
            return l;
        u32 comma = rest.byteIndexOf(String.withCString(", "));
        if (comma == String.notFound() || rest.byteIndexOf(String.withCString(", "), comma + 1) != String.notFound())
            return l;
        String* b = rest.substringFromByte(comma + 2);
        String* head = rest.substringBytes(0, comma);
        u32 lastSp = String.notFound();
        for (u32 k = 0; k < head.byteLength(); k = k + 1)
            if (head.byteAt(k) == (u8)' ')
                lastSp = k;
        if (lastSp == String.notFound())
            return l;
        String* a = head.substringFromByte(lastSp + 1);
        if (a.compare(b) <= (i8)0)
            return l;
        return l.substringBytes(0, eq + 3).appending(head.substringBytes(0, lastSp + 1)).appending(b)
                .appending(String.withCString(", ")).appending(a);
        }

    // A line without its metadata attachments (`, !dbg !12, !tbaa !4`).
    static String* withoutMeta(String* l)
        {
        u32 p = l.byteIndexOf(String.withCString(", !"));
        return p == String.notFound() ? l : l.substringBytes(0, p);
        }

    // `l` with each whole-name occurrence of a key of `ren` replaced by its value.
    static String* renamed(String* l, Map* ren)
        {
        String* out = new String();
        u32 i = 0;
        while (i < l.byteLength())
            {
            if (l.byteAt(i) != (u8)'%')
                {
                out.appendByte(l.byteAt(i));
                i = i + 1;
                continue;
                }
            u32 e = i + 1;
            while (e < l.byteLength() && LlvmName.isNameByte(l.byteAt(e)))
                e = e + 1;
            String* n = l.substringBytes(i, e - i);
            String* r = (String*)ren.get((Hashable*)n);
            out.append(r != (String*)0 ? r : n);
            i = e;
            }
        return out;
        }

    // A reduction unrolled by hand (libstdc++'s std::reduce and
    // std::transform_reduce: `while (last - first >= 4)` folding first[0..3]
    // into the sum one after another), in a function's body lines [from,
    // end), written back as one element a pass. The header has
    //     %p   = phi ptr [ %s, %pre ], [ %pn, %latch ]
    //     %acc = phi T   [ %init, %pre ], [ %accN, %latch ]
    //     %pi  = ptrtoint ptr %p to i64
    //     %d   = sub i64 %ei, %pi             ; %ei the end, made before
    //     %c   = icmp sgt i64 %d, K
    //     br i1 %c, label %latch, label %exit
    // and the latch loads N elements of size S at %p + k*S, steps %p by N*S,
    // and is N copies of one slice, each folding its element into the value
    // the copy before made (slice 0 into %acc). Kept: slice 0, a counter i
    // from 0 while i < (ei - s - K + S - 1) / S (the passes the unrolled loop
    // made, now one element each, until no more than K bytes are left), and
    // %p = getelementptr T, %s, i in the header, where the loop after it (the
    // rest) still finds it. The order of the folds is the same, so floats
    // give the same sum too.
    static void reroll(Array* lines, u32 from, u32 end)
        {
        u32 made = 0;
        String* hName = (String*)0;
        u32 hStart = from;
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.byteLength() > 0 && l.byteAt(0) != (u8)' ' && l.byteAt(0) != (u8)';')
                {
                u32 colon = Languages.byteFrom(l, (u8)':', 0);
                hName = colon != String.notFound() ? l.substringBytes(0, colon) : (String*)0;
                hStart = i + 1;
                continue;
                }
            String* t = Languages.withoutMeta(l.trimmed());
            if (hName == (String*)0 || !t.contains(String.withCString(" = icmp sgt i64 ")))
                continue;
            // %c = icmp sgt i64 %d, K
            String* c = t.substringBytes(0, Languages.byteFrom(t, (u8)' ', 0));
            Array* cp = t.substringFromByte(t.byteIndexOf(String.withCString(" i64 ")) + 5).splitOnByte((u8)',');
            if (cp.count() != 2)
                continue;
            String* d = ((String*)cp.get(0)).trimmed();
            i64 kBytes = Languages.intOf(((String*)cp.get(1)).trimmed());
            if (kBytes <= 0)
                continue;
            // its branch, to the latch when true
            u32 brAt = String.notFound();
            for (u32 k = i + 1; k < end && brAt == String.notFound(); k = k + 1)
                {
                String* m = (String*)lines.get(k);
                if (m.byteLength() > 0 && m.byteAt(0) != (u8)' ')
                    break;
                if (m.trimmed().hasPrefix(String.withFormat("br i1 %s, label ", c.cString())))
                    brAt = k;
                }
            if (brAt == String.notFound() || Languages.uses(lines, from, end, c) != 2)
                continue;
            String* latch = Languages.branchTarget((String*)lines.get(brAt), c, 0);
            String* exitTo = Languages.branchTarget((String*)lines.get(brAt), c, 1);
            if (latch == (String*)0 || exitTo == (String*)0)
                continue;
            String* latchName = latch.hasPrefix(String.withCString("%")) ? latch.substringFromByte(1) : latch;
            // the latch as phis and branches name it
            latch = String.withFormat("%%%s", latchName.cString());
            // %d = sub i64 %ei, %pi; %pi = ptrtoint ptr %p to i64, in the header
            String* ei = (String*)0;
            String* pi = (String*)0;
            String* p = (String*)0;
            for (u32 k = hStart; k < i; k = k + 1)
                {
                String* m = Languages.withoutMeta(((String*)lines.get(k)).trimmed());
                if (m.hasPrefix(d.appending(String.withCString(" = sub i64 "))) || m.hasPrefix(d.appending(String.withCString(" = sub nsw i64 "))))
                    {
                    Array* sp = m.substringFromByte(m.byteIndexOf(String.withCString(" i64 ")) + 5).splitOnByte((u8)',');
                    if (sp.count() == 2)
                        {
                        ei = ((String*)sp.get(0)).trimmed();
                        pi = Languages.withoutMeta(((String*)sp.get(1)).trimmed());
                        }
                    }
                }
            if (ei == (String*)0 || pi == (String*)0 || Languages.definedIn(lines, hStart, end, ei))
                continue;
            for (u32 k = hStart; k < i; k = k + 1)
                {
                String* m = Languages.withoutMeta(((String*)lines.get(k)).trimmed());
                String* ph = pi.appending(String.withCString(" = ptrtoint ptr "));
                if (m.hasPrefix(ph))
                    {
                    String* rest = Languages.withoutMeta(m.substringFromByte(ph.byteLength()));
                    u32 sp = Languages.byteFrom(rest, (u8)' ', 0);
                    p = sp == String.notFound() ? rest : rest.substringBytes(0, sp);
                    }
                }
            if (p == (String*)0)
                continue;
            // the header's phis: %p and one accumulator, both from the latch
            u32 pLine = String.notFound();
            u32 accLine = String.notFound();
            u32 lastPhi = String.notFound();
            String* sStart = (String*)0;
            String* pre = (String*)0;
            String* pn = (String*)0;
            String* acc = (String*)0;
            String* accTy = (String*)0;
            String* accN = (String*)0;
            u32 phis = 0;
            for (u32 k = hStart; k < i; k = k + 1)
                {
                String* m = Languages.withoutMeta(((String*)lines.get(k)).trimmed());
                if (!m.contains(String.withCString(" = phi ")))
                    continue;
                lastPhi = k;
                phis = phis + 1;
                String* nm = m.substringBytes(0, Languages.byteFrom(m, (u8)' ', 0));
                u32 at = m.byteIndexOf(String.withCString(" = phi ")) + 7;
                u32 sp1 = Languages.byteFrom(m, (u8)' ', at);
                String* ty = m.substringBytes(at, sp1 - at);
                // [ v, %b ], [ w, %latch ]
                Array* ins = m.substringFromByte(sp1).splitOnByte((u8)'[');
                String* fromPre = (String*)0;
                String* preB = (String*)0;
                String* fromLatch = (String*)0;
                u32 nin = 0;
                for (u32 q = 0; q < ins.count(); q = q + 1)
                    {
                    String* e = ((String*)ins.get(q)).trimmed();
                    if (e.byteLength() == 0)
                        continue;
                    nin = nin + 1;
                    u32 close = Languages.byteFrom(e, (u8)']', 0);
                    if (close == String.notFound())
                        continue;
                    Array* vb = e.substringBytes(0, close).splitOnByte((u8)',');
                    if (vb.count() != 2)
                        continue;
                    String* v = ((String*)vb.get(0)).trimmed();
                    String* b = ((String*)vb.get(1)).trimmed();
                    if (b.equals(latch))
                        fromLatch = v;
                    else
                        {
                        fromPre = v;
                        preB = b;
                        }
                    }
                if (nin != 2 || fromLatch == (String*)0 || fromPre == (String*)0)
                    {
                    phis = 99;
                    continue;
                    }
                if (nm.equals(p) && ty.equals(String.withCString("ptr")))
                    {
                    pLine = k;
                    sStart = fromPre;
                    pre = preB;
                    pn = fromLatch;
                    }
                else if (acc == (String*)0)
                    {
                    accLine = k;
                    acc = nm;
                    accTy = ty;
                    accN = fromLatch;
                    }
                else
                    phis = 99;
                }
            if (pLine == String.notFound() || accLine == String.notFound() || phis != 2)
                continue;
            // the latch: its lines [lStart, lBr)
            u32 lLabel = Languages.labelLine(lines, from, end, latchName);
            if (lLabel == String.notFound())
                continue;
            u32 lStart = lLabel + 1;
            u32 lBr = String.notFound();
            for (u32 k = lStart; k < end; k = k + 1)
                {
                String* m = (String*)lines.get(k);
                if (m.byteLength() > 0 && m.byteAt(0) != (u8)' ')
                    break;
                if (m.trimmed().hasPrefix(String.withCString("br ")))
                    {
                    lBr = k;
                    break;
                    }
                }
            if (lBr == String.notFound() || !Languages.withoutMeta(((String*)lines.get(lBr)).trimmed()).equals(String.withFormat("br label %%%s", hName.cString())))
                continue;
            // Each latch line's slice: an address %p + k*S is slice k; the
            // step is none (-2); a line takes the highest slice it uses.
            Map* slice = new Map();
            Map* offs = new Map();      // address -> k
            i64 elemSize = 0;
            String* elemTy = (String*)0;
            i64 stepBytes = 0;
            bool ok = true;
            Array* body = new Array();  // line indices that compute
            for (u32 k = lStart; k < lBr && ok; k = k + 1)
                {
                String* m = Languages.withoutMeta(((String*)lines.get(k)).trimmed());
                if (m.byteLength() == 0 || m.hasPrefix(String.withCString("#dbg_")) || m.hasPrefix(String.withCString("call void @llvm.dbg.")))
                    continue;
                if (!m.hasPrefix(String.withCString("%")) || m.contains(String.withCString(" store ")) || m.hasPrefix(String.withCString("store "))
                    || m.contains(String.withCString(" call ")) || m.contains(String.withCString(" invoke ")))
                    {
                    ok = false;
                    continue;
                    }
                String* nm = m.substringBytes(0, Languages.byteFrom(m, (u8)' ', 0));
                String* gh = String.withFormat("%s = getelementptr inbounds nuw i8, ptr %s, i64 ", nm.cString(), p.cString());
                String* gh2 = String.withFormat("%s = getelementptr inbounds i8, ptr %s, i64 ", nm.cString(), p.cString());
                if (m.hasPrefix(gh) || m.hasPrefix(gh2))
                    {
                    i64 off = Languages.intOf(m.substringFromByte(m.hasPrefix(gh) ? gh.byteLength() : gh2.byteLength()));
                    offs.set((Hashable*)nm, (Object*)Number.withI64(off));
                    continue;
                    }
                body.add((Object*)Number.withU32(k));
                }
            if (!ok || body.count() == 0)
                continue;
            // loads: through %p or an address, all one type
            u32 nLoads = 0;
            for (u32 b = 0; b < body.count() && ok; b = b + 1)
                {
                String* m = Languages.withoutMeta(((String*)lines.get(((Number*)body.get(b)).asU32())).trimmed());
                u32 lp = m.byteIndexOf(String.withCString(" = load "));
                if (lp == String.notFound())
                    continue;
                String* rest = m.substringFromByte(lp + 8);
                String* ty = rest.substringBytes(0, Languages.byteFrom(rest, (u8)',', 0));
                Array* ws = rest.splitOnByte((u8)',');
                String* addr = ws.count() > 1 ? ((String*)ws.get(1)).trimmed() : (String*)0;
                if (addr == (String*)0 || !addr.hasPrefix(String.withCString("ptr ")))
                    {
                    ok = false;
                    continue;
                    }
                addr = addr.substringFromByte(4);
                if (elemTy == (String*)0)
                    elemTy = ty;
                else if (!elemTy.equals(ty))
                    ok = false;
                if (!addr.equals(p) && offs.get((Hashable*)addr) == (Object*)0)
                    ok = false;
                nLoads = nLoads + 1;
                }
            if (!ok || elemTy == (String*)0)
                continue;
            elemSize = Languages.sizeOf(elemTy);
            Object* pnOff = offs.get((Hashable*)pn);
            if (elemSize <= 0 || pnOff == (Object*)0 || nLoads < 2)
                continue;
            stepBytes = ((Number*)pnOff).asI64();
            i64 n = stepBytes / elemSize;
            if (n != (i64)nLoads || stepBytes != n * elemSize || kBytes % elemSize != 0)
                continue;
            // addresses: exactly 1..n-1 times S
            Array* addrs = offs.allKeys();
            for (u32 q = 0; q < addrs.count() && ok; q = q + 1)
                {
                String* an = (String*)addrs.get(q);
                if (an.equals(pn))
                    continue;
                i64 o = ((Number*)offs.get((Hashable*)an)).asI64();
                if (o <= 0 || o >= stepBytes || o % elemSize != 0)
                    ok = false;
                else
                    slice.set((Hashable*)an, (Object*)Number.withI64(o / elemSize));
                }
            if (!ok)
                continue;
            slice.set((Hashable*)p, (Object*)Number.withI64(0));
            // each computing line's slice; the carry into each slice
            Map* sliceOfLine = new Map();
            for (u32 b = 0; b < body.count() && ok; b = b + 1)
                {
                u32 k = ((Number*)body.get(b)).asU32();
                String* m = Languages.withoutMeta(((String*)lines.get(k)).trimmed());
                String* nm = m.substringBytes(0, Languages.byteFrom(m, (u8)' ', 0));
                Array* ns = Languages.namesIn(m.substringFromByte(nm.byteLength()));
                i64 sl = (i64)-1;
                for (u32 q = 0; q < ns.count(); q = q + 1)
                    {
                    Object* so = slice.get((Hashable*)ns.get(q));
                    if (so != (Object*)0 && ((Number*)so).asI64() > sl)
                        sl = ((Number*)so).asI64();
                    if (((String*)ns.get(q)).equals(acc) && sl < (i64)0)
                        sl = 0;
                    }
                if (sl < (i64)0)
                    {
                    ok = false;     // a loop-invariant line in the latch: not this shape
                    continue;
                    }
                slice.set((Hashable*)nm, (Object*)Number.withI64(sl));
                sliceOfLine.set((Hashable*)Number.withU32(k), (Object*)Number.withI64(sl));
                }
            if (!ok)
                continue;
            // per slice: its lines, its carry-in (acc for 0, the previous
            // slice's carry-out), the carry-out (the one line using carry-in)
            Array* carryOut = new Array();
            Array* canon = new Array();
            String* carryIn = acc;
            for (i64 s = 0; s < n && ok; s = s + 1)
                {
                Map* ren = new Map();
                ren.set((Hashable*)carryIn, (Object*)String.withCString("%CARRY"));
                u32 vn = 0;
                String* text = new String();
                String* out = (String*)0;
                for (u32 b = 0; b < body.count(); b = b + 1)
                    {
                    u32 k = ((Number*)body.get(b)).asU32();
                    if (((Number*)sliceOfLine.get((Hashable*)Number.withU32(k))).asI64() != s)
                        continue;
                    String* m = Languages.withoutMeta(((String*)lines.get(k)).trimmed());
                    String* nm = m.substringBytes(0, Languages.byteFrom(m, (u8)' ', 0));
                    Array* ns = Languages.namesIn(m.substringFromByte(nm.byteLength()));
                    for (u32 q = 0; q < ns.count(); q = q + 1)
                        {
                        String* x = (String*)ns.get(q);
                        if (x.equals(carryIn))
                            out = nm;
                        // an address of this slice reads as %Q; any other
                        // name of the latch must be this slice's own
                        Object* so = slice.get((Hashable*)x);
                        if (so != (Object*)0 && ren.get((Hashable*)x) == (Object*)0)
                            {
                            if ((x.equals(p) || offs.get((Hashable*)x) != (Object*)0) && ((Number*)so).asI64() == s)
                                ren.set((Hashable*)x, (Object*)String.withCString("%Q"));
                            else
                                ok = false;
                            }
                        }
                    ren.set((Hashable*)nm, (Object*)String.withFormat("%%v%u", vn));
                    vn = vn + 1;
                    text.append(Languages.commutedInOrder(Languages.renamed(m, ren)));
                    text.appendCString("\n");
                    }
                if (out == (String*)0)
                    ok = false;
                else
                    {
                    carryOut.add((Object*)out);
                    carryIn = out;
                    }
                canon.add((Object*)text);
                }
            if (!ok || !carryIn.equals(accN))
                continue;
            for (u32 q = 1; q < canon.count() && ok; q = q + 1)
                if (!((String*)canon.get(q)).equals((String*)canon.get(0)))
                    ok = false;
            // nothing of a slice used after the loop but the last carry
            for (u32 b = 0; b < body.count() && ok; b = b + 1)
                {
                u32 k = ((Number*)body.get(b)).asU32();
                String* m = ((String*)lines.get(k)).trimmed();
                String* nm = m.substringBytes(0, Languages.byteFrom(m, (u8)' ', 0));
                if (nm.equals(accN))
                    continue;
                if (Languages.uses(lines, from, end, nm) != Languages.uses(lines, lStart, lBr, nm))
                    ok = false;
                }
            if (!ok)
                continue;
            u32 preBr = Languages.terminatorOf(lines, from, end, pre);
            if (preBr == String.notFound())
                continue;
            // The rewrite.
            String* tag = String.withFormat("%%xrr%u", made);
            made = made + 1;
            String* ix = tag.appending(String.withCString(".i"));
            String* cnt = tag.appending(String.withCString(".n"));
            String* nxt = tag.appending(String.withCString(".next"));
            String* pe = tag.appending(String.withCString(".pe"));
            String* exitBlock = String.withFormat("%s.exit", tag.substringFromByte(1).cString());
            String* preCode = String.withFormat("  %s.s = ptrtoint ptr %s to i64\n  %s.d = sub i64 %s, %s.s\n  %s.t = add i64 %s.d, %ld\n  %s = sdiv i64 %s.t, %ld\n",
                                                tag.cString(), sStart.cString(), tag.cString(), ei.cString(), tag.cString(),
                                                tag.cString(), tag.cString(), elemSize - (i64)1 - kBytes,
                                                cnt.cString(), tag.cString(), elemSize);
            preCode.append(String.withFormat("  %s.pos = icmp sgt i64 %s, 0\n  %s.m = select i1 %s.pos, i64 %s, i64 0\n",
                                             tag.cString(), cnt.cString(), tag.cString(), tag.cString(), cnt.cString()));
            preCode.append(String.withFormat("  %s = getelementptr inbounds %s, ptr %s, i64 %s.m\n",
                                             pe.cString(), elemTy.cString(), sStart.cString(), tag.cString()));
            lines.set(preBr, (Object*)preCode.appending((String*)lines.get(preBr)));
            // After the loop %p is pe (the loop leaves when i reaches
            // max(n, 0)): every use outside it reads pe, made before it.
            Map* toPe = new Map();
            toPe.set((Hashable*)p, (Object*)pe);
            for (u32 k = from; k < end; k = k + 1)
                {
                if ((k >= hStart && k <= brAt) || (k >= lStart && k <= lBr))
                    continue;
                String* m = (String*)lines.get(k);
                if (Languages.uses(lines, k, k + 1, p) > 0)
                    lines.set(k, (Object*)Languages.renamed(m, toPe));
                }
            // The exit through a block of its own, where what follows the
            // loop can put what it computes first (outside the loop).
            String* brLine = (String*)lines.get(brAt);
            lines.set(brAt, (Object*)brLine.replacing(String.withFormat("label %%%s", exitTo.cString()), String.withFormat("label %%%s", exitBlock.cString())));
            u32 xLabel = Languages.labelLine(lines, from, end, exitTo);
            for (u32 k = xLabel + 1; xLabel != String.notFound() && k < end; k = k + 1)
                {
                String* m = (String*)lines.get(k);
                if (m.byteLength() > 0 && m.byteAt(0) != (u8)' ')
                    break;
                if (m.contains(String.withCString(" = phi ")))
                    lines.set(k, (Object*)m.replacing(String.withFormat(", %%%s ]", hName.cString()), String.withFormat(", %%%s ]", exitBlock.cString())));
                }
            String* preLabel = pre;
            lines.set(pLine, (Object*)String.withFormat("  %s = phi i64 [ 0, %s ], [ %s, %s ]", ix.cString(), preLabel.cString(), nxt.cString(), latch.cString()));
            String* accLineText = (String*)lines.get(accLine);
            lines.set(accLine, (Object*)accLineText.replacing(String.withFormat("[ %s, %s ]", accN.cString(), latch.cString()),
                                                               String.withFormat("[ %s, %s ]", ((String*)carryOut.get(0)).cString(), latch.cString())));
            // %p at the top of the latch, where its loads are (made in the
            // header, xcc's unroller trips on it); the header's distance,
            // which only the old test read, goes.
            lines.set(lLabel, (Object*)((String*)lines.get(lLabel)).appending(
                String.withFormat("\n  %s = getelementptr inbounds %s, ptr %s, i64 %s", p.cString(), elemTy.cString(), sStart.cString(), ix.cString())));
            lines.set(i, (Object*)String.withFormat("  %s = icmp slt i64 %s, %s", c.cString(), ix.cString(), cnt.cString()));
            for (u32 k = hStart; k < i; k = k + 1)
                {
                String* m = Languages.withoutMeta(((String*)lines.get(k)).trimmed());
                if (m.hasPrefix(d.appending(String.withCString(" = "))) && Languages.uses(lines, from, end, d) == 1)
                    lines.set(k, (Object*)String.withCString(""));
                }
            for (u32 k = hStart; k < i; k = k + 1)
                {
                String* m = Languages.withoutMeta(((String*)lines.get(k)).trimmed());
                if (m.hasPrefix(pi.appending(String.withCString(" = "))) && Languages.uses(lines, from, end, pi) == 1)
                    lines.set(k, (Object*)String.withCString(""));
                }
            for (u32 k = lStart; k < lBr; k = k + 1)
                {
                String* m = Languages.withoutMeta(((String*)lines.get(k)).trimmed());
                if (m.byteLength() == 0)
                    continue;
                String* nm = m.substringBytes(0, Languages.byteFrom(m, (u8)' ', 0));
                Object* so = sliceOfLine.get((Hashable*)Number.withU32(k));
                bool keep = so != (Object*)0 && ((Number*)so).asI64() == (i64)0;
                if (!keep)
                    lines.set(k, (Object*)String.withCString(""));
                }
            lines.set(lBr, (Object*)String.withFormat("  %s = add nuw nsw i64 %s, 1\n", nxt.cString(), ix.cString()).appending((String*)lines.get(lBr))
                                     .appending(String.withFormat("\n%s:\n  br label %%%s", exitBlock.cString(), exitTo.cString())));
            }
        }

    // Loops that count down to 0 while pointers step up (libc++'s fill_n,
    // copy_n and the like: `for (; n > 0; --n, ++p)`), in a function's body
    // lines [from, end): the header has
    //     %n = phi i64 [ %n0, %pre ], [ %dec, %latch ]
    //     %c = icmp sgt i64 %n, 0
    //     br i1 %c, label %body, label %exit
    // with %dec = add nsw i64 %n, -1 and n used by nothing else, and every
    // other phi of the header a pointer that steps by the size of what is
    // loaded and stored through it. Such a loop runs max(n0, 0) times: it is
    // written with a counter i from 0, the test `i < n0` (signed), and each
    // pointer as `getelementptr T, ptr %s, i64 %i` at the top of the body.
    static void downCounts(Array* lines, u32 from, u32 end)
        {
        u32 made = 0;
        u32 blockStart = from;
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.byteLength() > 0 && l.byteAt(0) != (u8)' ' && l.byteAt(0) != (u8)';')
                {
                blockStart = i + 1;
                continue;
                }
            if (!l.contains(String.withCString(" = icmp sgt i64 ")))
                continue;
            String* t = l.trimmed();
            String* c = t.substringBytes(0, Languages.byteFrom(t, (u8)' ', 0));
            Array* parts = t.substringFromByte(t.byteIndexOf(String.withCString(" i64 ")) + 5).splitOnByte((u8)',');
            if (parts.count() < 2 || !((String*)parts.get(1)).trimmed().equals(String.withCString("0")))
                continue;
            String* n = ((String*)parts.get(0)).trimmed();
            u32 brAt = String.notFound();
            for (u32 k = i + 1; k < end && brAt == String.notFound(); k = k + 1)
                {
                String* m = (String*)lines.get(k);
                if (m.byteLength() > 0 && m.byteAt(0) != (u8)' ')
                    break;
                if (m.trimmed().hasPrefix(String.withFormat("br i1 %s, label ", c.cString())))
                    brAt = k;
                }
            if (brAt == String.notFound() || Languages.uses(lines, from, end, c) != 2 || Languages.uses(lines, from, end, n) != 3)
                continue;
            // n's phi: [ n0, pre ], [ dec, latch ], and dec = add nsw i64 n, -1.
            u32 nAt = String.notFound();
            String* n0 = (String*)0;
            String* pre = (String*)0;
            String* dec = (String*)0;
            String* latch = (String*)0;
            String* head = n.appending(String.withCString(" = phi i64 "));
            for (u32 k = blockStart; k < i; k = k + 1)
                {
                String* m = ((String*)lines.get(k)).trimmed();
                if (!m.hasPrefix(head))
                    continue;
                Array* ins = m.substringFromByte(head.byteLength()).splitOnByte((u8)'[');
                for (u32 q = 0; q < ins.count(); q = q + 1)
                    {
                    String* e = ((String*)ins.get(q)).trimmed();
                    u32 close = Languages.byteFrom(e, (u8)']', 0);
                    if (e.byteLength() == 0 || close == String.notFound())
                        continue;
                    Array* vb = e.substringBytes(0, close).splitOnByte((u8)',');
                    if (vb.count() != 2)
                        continue;
                    String* v = ((String*)vb.get(0)).trimmed();
                    String* b = ((String*)vb.get(1)).trimmed();
                    if (Languages.isDecOf(lines, from, end, v, n))
                        {
                        dec = v;
                        latch = b;
                        }
                    else
                        {
                        n0 = v;
                        pre = b;
                        }
                    }
                nAt = k;
                }
            if (nAt == String.notFound() || n0 == (String*)0 || dec == (String*)0 || Languages.uses(lines, from, end, dec) != 2)
                continue;
            // Every other phi of the header: a pointer that steps.
            Array* ivs = new Array();
            bool ok = true;
            for (u32 k = blockStart; k < i && ok; k = k + 1)
                {
                String* m = ((String*)lines.get(k)).trimmed();
                if (k == nAt || !m.contains(String.withCString(" = phi ")))
                    continue;
                if (!m.contains(String.withCString(" = phi ptr ")))
                    {
                    ok = false;
                    continue;
                    }
                PtrIv* q = Languages.ptrIv(lines, blockStart, i, from, end, m.substringBytes(0, Languages.byteFrom(m, (u8)' ', 0)));
                if (q == (PtrIv*)0 || !q.pre().equals(pre) || !q.latch().equals(latch))
                    ok = false;
                else
                    ivs.add((Object*)q);
                }
            if (!ok || ivs.count() == 0)
                continue;
            String* bodyLabel = Languages.branchTarget((String*)lines.get(brAt), c, 0);
            u32 bodyAt = bodyLabel != (String*)0 ? Languages.labelLine(lines, from, end, bodyLabel) : String.notFound();
            if (bodyAt == String.notFound())
                continue;
            String* idx = String.withFormat("%%xcdn%u.i", made);
            String* nxt = String.withFormat("%%xcdn%u.next", made);
            made = made + 1;
            // The counter in n's place; n's step gone with it.
            lines.set(nAt, (Object*)String.withFormat("  %s = phi i64 [ 0, %s ], [ %s, %s ]", idx.cString(), pre.cString(), nxt.cString(), latch.cString()));
            for (u32 k = from; k < end; k = k + 1)
                if (((String*)lines.get(k)).trimmed().hasPrefix(dec.appending(String.withCString(" = "))))
                    lines.set(k, (Object*)String.withFormat("  %s = add nuw nsw i64 %s, 1", nxt.cString(), idx.cString()));
            String* geps = new String();
            for (u32 k = 0; k < ivs.count(); k = k + 1)
                {
                PtrIv* q = (PtrIv*)ivs.get(k);
                lines.set(q.line(), (Object*)String.withCString(""));
                geps.appendFormat("\n  %s = getelementptr inbounds %s, ptr %s, i64 %s", q.name().cString(), q.elem().cString(),
                                  q.start().cString(), idx.cString());
                }
            lines.set(bodyAt, (Object*)((String*)lines.get(bodyAt)).appending(geps));
            lines.set(i, (Object*)String.withFormat("  %s = icmp slt i64 %s, %s", c.cString(), idx.cString(), n0.cString()));
            }
        }

    // Whether line-defined value v is `add nsw i64 n, -1` (or `add i64`).
    static bool isDecOf(Array* lines, u32 from, u32 end, String* v, String* n)
        {
        String* head = v.appending(String.withCString(" = add "));
        String* tail = String.withFormat("i64 %s, -1", n.cString());
        for (u32 k = from; k < end; k = k + 1)
            {
            String* m = ((String*)lines.get(k)).trimmed();
            if (!m.hasPrefix(head))
                continue;
            u32 p = m.byteIndexOf(tail);
            if (p == String.notFound())
                return false;
            u32 e = p + tail.byteLength();
            return e == m.byteLength() || m.byteAt(e) == (u8)',';
            }
        return false;
        }

    // Target w (0 or 1) of `br i1 c, label %a, label %b`, without its `%`; or 0.
    static String* branchTarget(String* m, String* c, u32 w)
        {
        String* head = String.withFormat("br i1 %s, ", c.cString());
        u32 hb = m.byteIndexOf(head);
        if (hb == String.notFound())
            return (String*)0;
        Array* tg = m.substringFromByte(hb + head.byteLength()).splitOnByte((u8)',');
        if (tg.count() < 2)
            return (String*)0;
        String* t = ((String*)tg.get(w)).trimmed();
        if (!t.hasPrefix(String.withCString("label %")))
            return (String*)0;
        return t.substringFromByte(7);
        }

    // The line of the label `name:` in [from, end), or notFound.
    static u32 labelLine(Array* lines, u32 from, u32 end, String* name)
        {
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.hasPrefix(name) && l.byteLength() > name.byteLength() && l.byteAt(name.byteLength()) == (u8)':')
                return i;
            }
        return String.notFound();
        }

    // The `br i1 c, label %a, label %b` at line k as `br i1 c, label %b, label %a`.
    static void swapTargets(Array* lines, u32 k, String* c)
        {
        String* m = (String*)lines.get(k);
        String* head = String.withFormat("br i1 %s, ", c.cString());
        u32 hb = m.byteIndexOf(head);
        Array* tg = m.substringFromByte(hb + head.byteLength()).splitOnByte((u8)',');
        if (tg.count() < 2)
            return;
        String* nm = m.substringBytes(0, hb + head.byteLength());
        nm.append(((String*)tg.get(1)).trimmed());
        nm.appendCString(", ");
        nm.append(((String*)tg.get(0)).trimmed());
        for (u32 j = 2; j < tg.count(); j = j + 1)
            {
            nm.appendCString(",");
            nm.append((String*)tg.get(j));
            }
        lines.set(k, (Object*)nm);
        }

    // The line of block `name`'s terminator (`  br ...`), or notFound.
    static u32 terminatorOf(Array* lines, u32 from, u32 end, String* name)
        {
        String* label = name.hasPrefix(String.withCString("%")) ? name.substringFromByte(1) : name;
        bool inside = false;
        u32 last = String.notFound();
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            if (l.byteLength() > 0 && l.byteAt(0) != (u8)' ' && l.byteAt(0) != (u8)';')
                {
                if (inside)
                    return last;
                u32 colon = Languages.byteFrom(l, (u8)':', 0);
                inside = colon != String.notFound() && l.substringBytes(0, colon).equals(label);
                continue;
                }
            if (inside && l.trimmed().hasPrefix(String.withCString("br ")))
                last = i;
            }
        return inside ? last : String.notFound();
        }

    // The pointer phi `name` of the header (lines [blockStart, upto)), with
    // two incomings, a step by a constant in the function and every load and
    // store through it of one type that size; or 0.
    static PtrIv* ptrIv(Array* lines, u32 blockStart, u32 upto, u32 from, u32 end, String* name)
        {
        String* head = name.appending(String.withCString(" = phi ptr "));
        for (u32 i = blockStart; i < upto; i = i + 1)
            {
            String* t = ((String*)lines.get(i)).trimmed();
            if (!t.hasPrefix(head))
                continue;
            Array* ins = t.substringFromByte(head.byteLength()).splitOnByte((u8)'[');
            Array* vals = new Array();
            Array* from2 = new Array();
            for (u32 k = 0; k < ins.count(); k = k + 1)
                {
                String* e = ((String*)ins.get(k)).trimmed();
                if (e.byteLength() == 0)
                    continue;
                u32 close = Languages.byteFrom(e, (u8)']', 0);
                if (close == String.notFound())
                    return (PtrIv*)0;
                Array* vb = e.substringBytes(0, close).splitOnByte((u8)',');
                if (vb.count() != 2)
                    return (PtrIv*)0;
                vals.add((Object*)((String*)vb.get(0)).trimmed());
                from2.add((Object*)((String*)vb.get(1)).trimmed());
                }
            if (vals.count() != 2)
                return (PtrIv*)0;
            // Which incoming steps: `%pn = getelementptr inbounds T, ptr name, i64 K`.
            for (u32 w = 0; w < 2; w = w + 1)
                {
                String* pn = (String*)vals.get(w);
                u32 sl = String.notFound();
                i64 step = 0;
                String* gh = pn.appending(String.withCString(" = getelementptr "));
                for (u32 k = from; k < end; k = k + 1)
                    {
                    String* m = ((String*)lines.get(k)).trimmed();
                    if (!m.hasPrefix(gh))
                        continue;
                    // `inbounds`, `nuw` and `nusw` say nothing to the count.
                    String* gr = m.substringFromByte(gh.byteLength());
                    for (u32 f = 0; f < 3; f = f + 1)
                        {
                        if (gr.hasPrefix(String.withCString("inbounds ")))
                            gr = gr.substringFromByte(9);
                        else if (gr.hasPrefix(String.withCString("nuw ")))
                            gr = gr.substringFromByte(4);
                        else if (gr.hasPrefix(String.withCString("nusw ")))
                            gr = gr.substringFromByte(5);
                        }
                    Array* gp = gr.splitOnByte((u8)',');
                    if (gp.count() < 3)
                        break;
                    String* gt = ((String*)gp.get(0)).trimmed();
                    if (gt.hasPrefix(String.withCString("nuw ")))
                        gt = gt.substringFromByte(4);
                    if (!((String*)gp.get(1)).trimmed().equals(String.withFormat("ptr %s", name.cString())))
                        break;
                    Array* kw = Languages.words(((String*)gp.get(2)).trimmed());
                    if (kw.count() != 2)
                        break;
                    i64 kk = Languages.intOf((String*)kw.get(1));
                    i64 sz = Languages.sizeOf(gt);
                    if (kk <= 0 || sz <= 0)
                        break;
                    step = kk * sz;
                    sl = k;
                    break;
                    }
                if (sl == String.notFound())
                    continue;
                String* elem = Languages.accessType(lines, from, end, name);
                if (elem == (String*)0 || Languages.sizeOf(elem) != step)
                    return (PtrIv*)0;
                PtrIv* r = new PtrIv();
                r._name = name;
                r._start = (String*)vals.get(1 - w);
                r._pre = (String*)from2.get(1 - w);
                r._latch = (String*)from2.get(w);
                r._step = step;
                r._stepLine = sl;
                r._line = i;
                r._elem = elem;
                return r;
                }
            return (PtrIv*)0;
            }
        return (PtrIv*)0;
        }

    // The one type every load and store through p has (`load T, ptr p`,
    // `store T v, ptr p`), with p used otherwise only by its step and the
    // test; or 0.
    static String* accessType(Array* lines, u32 from, u32 end, String* p)
        {
        String* ty = (String*)0;
        String* lk = String.withFormat(", ptr %s", p.cString());
        for (u32 i = from; i < end; i = i + 1)
            {
            String* t = ((String*)lines.get(i)).trimmed();
            u32 at = t.byteIndexOf(lk);
            if (at == String.notFound())
                continue;
            u32 e = at + lk.byteLength();
            if (e < t.byteLength() && LlvmName.isNameByte(t.byteAt(e)))
                continue;
            String* one = (String*)0;
            u32 ld = t.byteIndexOf(String.withCString(" = load "));
            if (ld != String.notFound() && ld < at)
                one = (String*)Languages.words(t.substringBytes(ld + 8, at - ld - 8).trimmed()).get(0);
            else if (t.hasPrefix(String.withCString("store ")))
                one = (String*)Languages.words(t.substringFromByte(6)).get(0);
            else
                continue;
            if (one == (String*)0 || (ty != (String*)0 && !ty.equals(one)))
                return (String*)0;
            ty = one;
            }
        return ty;
        }

    static i64 sizeOf(String* t)
        {
        if (t.equals(String.withCString("i8"))) return 1;
        if (t.equals(String.withCString("i16")) || t.equals(String.withCString("half")) || t.equals(String.withCString("bfloat"))) return 2;
        if (t.equals(String.withCString("i32")) || t.equals(String.withCString("float"))) return 4;
        if (t.equals(String.withCString("i64")) || t.equals(String.withCString("double")) || t.equals(String.withCString("ptr"))) return 8;
        return 0;
        }

    static i64 intOf(String* w)
        {
        i64 v = 0;
        if (w.byteLength() == 0)
            return 0;
        for (u32 i = 0; i < w.byteLength(); i = i + 1)
            {
            u8 c = w.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return 0;
            v = v * 10 + (i64)(c - (u8)'0');
            }
        return v;
        }

    // How many times the value v appears in lines [from, end), as a whole name.
    static u32 uses(Array* lines, u32 from, u32 end, String* v)
        {
        u32 n = 0;
        for (u32 i = from; i < end; i = i + 1)
            {
            String* l = (String*)lines.get(i);
            for (u32 p = l.byteIndexOf(v); p != String.notFound(); p = l.byteIndexOf(v, p + 1))
                {
                u32 e = p + v.byteLength();
                if (e >= l.byteLength() || !LlvmName.isNameByte(l.byteAt(e)))
                    n = n + 1;
                }
            }
        return n;
        }

    // Whether a is `phi T [ s, %p ], [ %inc, %l ]` in the block's lines
    // [blockStart, upto), s a constant or a value not made in the block, with
    // `%inc = add ... T a, 1` in the function.
    static bool countsFromZero(Array* lines, u32 blockStart, u32 upto, u32 from, u32 end, String* a, String* ty)
        {
        String* head = String.withFormat("%s = phi %s ", a.cString(), ty.cString());
        for (u32 i = blockStart; i < upto; i = i + 1)
            {
            String* t = ((String*)lines.get(i)).trimmed();
            if (!t.hasPrefix(head))
                continue;
            Array* ins = t.substringFromByte(head.byteLength()).splitOnByte((u8)'[');
            String* inc = (String*)0;
            bool started = false;
            u32 n = 0;
            for (u32 k = 0; k < ins.count(); k = k + 1)
                {
                String* e = ((String*)ins.get(k)).trimmed();
                if (e.byteLength() == 0)
                    continue;
                n = n + 1;
                u32 comma = Languages.byteFrom(e, (u8)',', 0);
                if (comma == String.notFound())
                    return false;
                String* v = e.substringBytes(0, comma).trimmed();
                // The step's incoming is `add ... a, 1`; the other is the start.
                if (Languages.isIncOf(lines, from, end, v, a, ty))
                    inc = v;
                else if (!Languages.definedIn(lines, blockStart, upto, v))
                    started = true;
                }
            if (n != 2 || !started || inc == (String*)0)
                return false;
            String* addHead = String.withFormat("%s = add ", inc.cString());
            String* tail = String.withFormat(" %s %s, 1", ty.cString(), a.cString());
            for (u32 k = from; k < end; k = k + 1)
                {
                String* m = ((String*)lines.get(k)).trimmed();
                if (!m.hasPrefix(addHead))
                    continue;
                u32 p = m.byteIndexOf(tail);
                if (p == String.notFound())
                    return false;
                u32 e = p + tail.byteLength();
                return e == m.byteLength() || m.byteAt(e) == (u8)',';
                }
            return false;
            }
        return false;
        }

    // Whether v is `add ... T a, 1` in lines [from, end).
    static bool isIncOf(Array* lines, u32 from, u32 end, String* v, String* a, String* ty)
        {
        if (!v.hasPrefix(String.withCString("%")))
            return false;
        String* head = v.appending(String.withCString(" = add "));
        String* tail = String.withFormat(" %s %s, 1", ty.cString(), a.cString());
        for (u32 k = from; k < end; k = k + 1)
            {
            String* m = ((String*)lines.get(k)).trimmed();
            if (!m.hasPrefix(head))
                continue;
            u32 p = m.byteIndexOf(tail);
            if (p == String.notFound())
                return false;
            u32 e = p + tail.byteLength();
            return e == m.byteLength() || m.byteAt(e) == (u8)',';
            }
        return false;
        }

    // Whether v is made in lines [from, upto) (`v = ...`).
    static bool definedIn(Array* lines, u32 from, u32 upto, String* v)
        {
        if (!v.hasPrefix(String.withCString("%")))
            return false;
        String* head = String.withFormat("%s = ", v.cString());
        for (u32 i = from; i < upto; i = i + 1)
            if (((String*)lines.get(i)).trimmed().hasPrefix(head))
                return true;
        return false;
        }

    // `declare RET @name(PARAMS)` from a define line: the words up to the
    // parameter list's closing parenthesis, attributes after it dropped.
    static String* declarationOf(String* l)
        {
        u32 at = l.indexOfByte((u8)'@');
        if (at == String.notFound())
            return (String*)0;
        u32 p = at + 1;
        if (p < l.byteLength() && l.byteAt(p) == (u8)'"')
            {
            p = p + 1;
            while (p < l.byteLength() && l.byteAt(p) != (u8)'"')
                p = p + 1;
            }
        while (p < l.byteLength() && l.byteAt(p) != (u8)'(')
            p = p + 1;
        u32 depth = 0;
        u32 q = p;
        while (q < l.byteLength())
            {
            u8 c = l.byteAt(q);
            if (c == (u8)'(')
                depth = depth + 1;
            else if (c == (u8)')')
                {
                depth = depth - 1;
                if (depth == 0)
                    break;
                }
            q = q + 1;
            }
        if (q >= l.byteLength())
            return (String*)0;
        String* d = String.withCString("declare");
        d.append(l.substringBytes(6, q + 1 - 6));
        return d;
        }

    // The IR its compiler builds once xcc has taken its functions: an ODR
    // copy is kept (weak_odr, weak), since xcc's half may call one that the
    // compiler's half has inlined everywhere and would otherwise drop.
    static String* keepOdr(String* text)
        {
        String* r = text.replacing(String.withCString("\ndefine linkonce_odr "), String.withCString("\ndefine weak_odr "));
        return r.replacing(String.withCString("\ndefine linkonce "), String.withCString("\ndefine weak "));
        }
    }
