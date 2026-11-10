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
//     name | .ext .ext | command | IR flags | libraries | reads | linker
//
// `libraries` are `os:name` words (`macos:c++`): on macOS a name is the SDK's
// usr/lib/lib<name>.tbd, elsewhere `-l<name>`. `reads` is `all` (every
// function the reader can read) or `loops` (only functions with a loop that
// are not ODR copies and that no exception can pass through; see
// Languages.loopFunctions). A row in the file
// replaces a built-in one of the same name, and takes over its extensions.
// `linker`, when given, links the program on macOS (C++: clang++, for its
// runtime, unwind tables and exception tables, which the in-house link does
// not carry); empty, xcc links it.
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

    String* name(void)    { return _name; }
    Array* exts(void)     { return _exts; }
    String* command(void) { return _command; }
    String* irFlags(void) { return _irFlags; }
    Array* libs(void)     { return _libs; }
    bool loopsOnly(void)  { return _loopsOnly; }
    String* linker(void)  { return _linker; }

    static LanguageRow* make(String* name, String* exts, String* command, String* irFlags, String* libs, String* reads, String* linker)
        {
        LanguageRow* r = new LanguageRow();
        r._name = name;
        r._exts = Languages.words(exts);
        r._command = command;
        r._irFlags = irFlags;
        r._libs = Languages.words(libs);
        r._loopsOnly = reads.equals(String.withCString("loops"));
        r._linker = linker;
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
                                        ir, String.withCString(""), String.withCString("all"), String.withCString("")));
        t.add((Object*)LanguageRow.make(String.withCString("c++"), String.withCString(".cpp .cc .cxx .C"), String.withCString("clang++"),
                                        ir, String.withCString("macos:c++"), String.withCString("loops"), String.withCString("clang++")));
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
            if (f.count() != 6 && f.count() != 7)
                {
                Stdio.error(String.withFormat("xcc: warning: XC_LANGUAGES line %u: want 6 or 7 fields separated by |, not %u\n",
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
                                            f.count() == 7 ? ((String*)f.get(6)).trimmed() : String.withCString("")));
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
