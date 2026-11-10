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
//     name | .ext .ext | command | IR flags | libraries | reads | linker | passes
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
// `#` starts a comment line.

#import "Foundation.xc"
#import "Files.xc"
#import "Stdio.xc"

// The table, read once (Languages.rows).
Array* gLanguageRows;

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

    String* name(void)    { return _name; }
    Array* exts(void)     { return _exts; }
    String* command(void) { return _command; }
    String* irFlags(void) { return _irFlags; }
    Array* libs(void)     { return _libs; }
    bool loopsOnly(void)  { return _loopsOnly; }
    String* linker(void)  { return _linker; }
    String* passes(void)  { return _passes; }

    static LanguageRow* make(String* name, String* exts, String* command, String* irFlags, String* libs, String* reads, String* linker, String* passes)
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
    // xc's own lowering hands the optimiser.
    static Array* builtIn(void)
        {
        Array* t = new Array();
        String* ir = String.withCString("-O1 -Xclang -disable-llvm-passes -fno-discard-value-names -gline-tables-only -S -emit-llvm");
        t.add((Object*)LanguageRow.make(String.withCString("c"), String.withCString(".c"), String.withCString("clang"),
                                        ir, String.withCString(""), String.withCString("all"), String.withCString(""), String.withCString("")));
        t.add((Object*)LanguageRow.make(String.withCString("c++"), String.withCString(".cpp .cc .cxx .C"), String.withCString("clang++"),
                                        ir, String.withCString("macos:c++"), String.withCString("loops"), String.withCString("clang++"),
                                        String.withCString("-O1 -fno-unroll-loops -fno-vectorize -fno-slp-vectorize -fno-discard-value-names -mllvm -rotation-max-header-size=0 -mllvm -indvars-widen-indvars=false")));
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
            if (f.count() < 6 || f.count() > 8)
                {
                Stdio.error(String.withFormat("xcc: warning: XC_LANGUAGES line %u: want 6 to 8 fields separated by |, not %u\n",
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
                                            f.count() == 8 ? ((String*)f.get(7)).trimmed() : String.withCString("")));
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
            if (!Languages.isOdr(l) && Languages.hasLoop(lines, i + 1, end) && !Languages.mayThrow(lines, i + 1, end, nounwind))
                {
                Languages.counted(lines, i + 1, end);
                Languages.pointerLoops(lines, i + 1, end);
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
            if (l.hasPrefix(String.withCString("define ")) && !Languages.isOdr(l) && !Languages.hasGroupIn(l, always))
                {
                u32 end = i + 1;
                while (end < lines.count() && !((String*)lines.get(end)).equals(String.withCString("}")))
                    end = end + 1;
                String* d = Languages.declarationOf(l);
                if (d != (String*)0 && Languages.hasLoop(lines, i + 1, end))
                    {
                    // After the parameter list: `define ... @f(...) noinline #0 {`.
                    u32 q = d.byteLength() - 7 + 6;
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
            // a counts from 0 by 1 in this block's phi; b is not made in it.
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
                String* gh = pn.appending(String.withCString(" = getelementptr inbounds "));
                for (u32 k = from; k < end; k = k + 1)
                    {
                    String* m = ((String*)lines.get(k)).trimmed();
                    if (!m.hasPrefix(gh))
                        continue;
                    Array* gp = m.substringFromByte(gh.byteLength()).splitOnByte((u8)',');
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

    // Whether a is `phi T [ 0, %p ], [ %inc, %l ]` in the block's lines
    // [blockStart, upto), with `%inc = add ... T a, 1` in the function.
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
            bool zero = false;
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
                if (v.equals(String.withCString("0")))
                    zero = true;
                else
                    inc = v;
                }
            if (n != 2 || !zero || inc == (String*)0)
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
