// Preprocessor.xc — the xtc preprocessor, written in xtc.
// =================================================================
//
// self-hosting M5, the second module ported (after the lexer, M4). A faithful
// port of src/xtc/preprocessor/XTPreprocessor.m: comment stripping, line
// continuation, #import / #include with the quote-vs-angle search order,
// #define / #undef with parameters, varargs, `#` stringize and `##` paste,
// #if / #ifdef / #ifndef / #elif / #else / #endif with a full integer
// expression evaluator, #warning / #error, and the `#line N "file"` stream that
// keeps the lexer's positions pointing at the original source.
//
// The output is compared BYTE FOR BYTE against the Objective-C original
// (selfhost/tools/pp-diff.sh), so behaviour is copied rather than improved,
// including the parts that look odd:
//
//   * a directive line emits a newline of its own AND a following `#line`, so
//     the line count of the output tracks the input;
//   * an inactive conditional branch emits blank lines, not nothing;
//   * a macro body's trailing `// comment` is stripped at definition time;
//   * an identifier that is not a macro evaluates to 0 inside #if, per C;
//   * `#use K` is sugar for `#import <K>` plus a `use K;` line.
//
// Differences that are real, and stated rather than hidden:
//
//   * #if arithmetic is i32, not int64_t. xtc has no 64-bit integer; a
//     condition needing more than 32 bits would differ, and nothing in the
//     tree has one.
//   * library (`.so`/`.dylib`) metadata imports are RECORDED, not resolved:
//     the port has no DWARF reader. The oracle used by the differential test
//     runs with no library paths, so both sides agree.
//   * the case-sensitive existence check needs a directory listing, so it uses
//     the host primitive `_xt_file_exists_exact` (Files.existsExact).

#import "Foundation.xc"
#import "Files.xc"
#import "MacroDef.xc"

// One open #if / #ifdef / #ifndef.
//
// `taken` is per CHAIN, not per branch: once any arm of an #if/#elif/#else has
// been entered, every later arm is inactive whatever its condition says.
// `parentActive` is captured on push so #elif and #else can re-evaluate without
// walking the stack.
class IfFrame
    {
    bool _active;
    bool _taken;
    bool _parentActive;

    void init(void)
        {
        _active = false;
        _taken = false;
        _parentActive = false;
        }

    static IfFrame* with(bool active, bool taken, bool parentActive)
        {
        IfFrame* f = new IfFrame();
        f._active = active;
        f._taken = taken;
        f._parentActive = parentActive;
        return f;
        }

    bool active(void)
        {
        return _active;
        }
    bool taken(void)
        {
        return _taken;
        }
    bool parentActive(void)
        {
        return _parentActive;
        }
    void setActive(bool v)
        {
        _active = v;
        }
    void setTaken(bool v)
        {
        _taken = v;
        }
    }

    class Preprocessor
    {
    Map* _macros;            // String@ name → MacroDef@
    Set* _expanding;         // macro names currently being expanded (blue paint)
    Set* _imported;          // absolute paths already #imported
    Set* _preludeFiles;      // …and which of them arrived UNDER the prelude
    bool _inPrelude;         // expanding the implicit platform header now
    u32 _sourceDepth;        // preprocessSource recursion (0 = entry file)
    Array* _ifStack;         // of IfFrame@
    Array* _includePaths;    // of String@
    Array* _libraryPaths;    // of String@
    Array* _metadataImports; // of String@ — libraries seen, not text-included
    String* _prelude;        // the target's implicit platform header, if any
    Array* _errors;
    // `#package <ns>` — the host import namespace in force for subsequent
    // BODYLESS declarations (wasm-target.md §6). A STATE directive: it holds
    // until changed. 0 = the default package.
    String* _currentPackage;
    String* _arch;    // of String@
    Array* _warnings; // of String@

    void init(void)
        {
        _macros = new Map();
        _expanding = new Set();
        _imported = new Set();
        _preludeFiles = new Set();
        _inPrelude = false;
        _sourceDepth = (u32)0;
        _ifStack = new Array();
        _includePaths = new Array();
        _libraryPaths = new Array();
        _metadataImports = new Array();
        _errors = new Array();
        _currentPackage = (String*)0;
        _arch = (String*)0;
        _warnings = new Array();
        }

    // ── Configuration ────────────────────────────────────────────
    // The target, for the one directive that is target-specific.
    void setArch(String* a)
        {
        _arch = a;
        }

    void addIncludePath(String* dir)
        {
        _includePaths.add((Object*)dir);
        }
    Array* includePaths(void)
        {
        return _includePaths;
        }
    void addLibraryPath(String* dir)
        {
        _libraryPaths.add((Object*)dir);
        }

    // -D name[=value]; an empty value means "1", as the driver's -D does.
    void define(String* name, String* value)
        {
        String* body = (value == 0) ? String.withCString("1") : value;
        _macros.set((Hashable*)name, (Object*)MacroDef.with(name, (Array*)0, body));
        }

    void defineCString(string name, string value)
        {
        define(String.withCString(name), String.withCString(value));
        }

    Array* errors(void)
        {
        return _errors;
        }
    Array* warnings(void)
        {
        return _warnings;
        }
    Array* metadataImports(void)
        {
        return _metadataImports;
        }

    void setPrelude(String* p)
        {
        _prelude = p;
        }
    Set* preludeFiles(void)
        {
        return _preludeFiles;
        }

    // Two spellings of one directory have to compare EQUAL, or a file living in
    // a library directory is not recognised as living there and its own
    // neighbours get searched first. `support/generic/lib/Object.xc` would then
    // pick up the neighbouring `Platform.xc` instead of the TARGET's — which is
    // exactly the head start the library rule exists to withhold. The driver
    // spells its search paths `./support/<plat>/lib` and a file's own directory
    // comes back as `support/<plat>/lib`, so the two differ by a prefix and
    // nothing else. (The original standardises the path; this handles the
    // leading `./`, an embedded `/./`, a doubled `/` and a trailing one, which
    // is every spelling the driver can produce.)
    static String* canonPath(String* p)
        {
        if (p == 0)
            return String.withCString("");
        String* out = String.withCString("");
        u32 i = (u32)0;
        while (i + (u32)1 < p.byteLength() && p.byteAt(i) == (u8)'.' && p.byteAt(i + (u32)1) == (u8)'/')
            i = i + (u32)2;
        while (i < p.byteLength())
            {
            u8 c = p.byteAt(i);
            if (c == (u8)'/')
                {
                // Collapse `//` and drop `/./`.
                while (i + (u32)1 < p.byteLength() && p.byteAt(i + (u32)1) == (u8)'/')
                    i = i + (u32)1;
                while (i + (u32)2 < p.byteLength() && p.byteAt(i + (u32)1) == (u8)'.' && p.byteAt(i + (u32)2) == (u8)'/')
                    i = i + (u32)2;
                // trailing /
                if (i + (u32)1 >= p.byteLength())
                    {
                    i = i + (u32)1;
                    continue;
                    }
                }
            out.appendByte(c);
            i = i + (u32)1;
            }
        return out;
        }

    void _error(String* msg)
        {
        _errors.add((Object*)msg);
        }

    // `file:line:1: error: msg` when the line is known, `file: error: msg`
    // when it is not (a synthesised prelude include has no line).
    static String* positioned(String* filename, u32 line, String* msg)
        {
        String* out = String.withString(filename);
        if (line != (u32)0)
            {
            out.appendByte((u8)':');
            out.append(String.withU32(line));
            out.appendCString(":1");
            }
        out.appendCString(": error: ");
        out.append(msg);
        return out;
        }
    void _warn(String* msg)
        {
        _warnings.add((Object*)msg);
        }

    // ── Entry points ─────────────────────────────────────────────
    String* preprocessFile(String* path)
        {
        String* src = Files.readText(path);
        if (src == 0)
            {
            _error(String.withCString("cannot read file"));
            return (String*)0;
            }
        return preprocessSource(src, path);
        }

    // ── Comments ─────────────────────────────────────────────────
    // Stripped BEFORE any directive or macro processing, so `// #import <X>`
    // really is commented out. Newlines inside a block comment are kept and
    // everything else becomes a space, so line numbering is untouched — and the
    // pass knows about string and character literals, so a "// not a comment"
    // inside a string survives.
    String* stripComments(String* src)
        {
        String* out = String.withCString("");
        out.reserve(src.byteLength());
        u32 i = (u32)0;
        u32 n = src.byteLength();
        u8* b = src.cString();
        bool inBlock = false;
        bool inString = false;
        bool inChar = false;
        // Comments do NOT nest — the FIRST `*/` closes, as in C. Both ways of
        // getting that wrong used to be silent: a `/*` inside the comment was
        // blanked like any other text, so the author's intended closer ended it
        // early and their prose reached the parser as CODE; and an unterminated
        // comment ran to end-of-input, swallowing the rest of the file.
        bool warnedNested = false;

        while (i < n)
            {
            u8 c = b[i];
            u8 next = (i + (u32)1 < n) ? b[i + (u32)1] : (u8)0;

            if (inBlock)
                {
                if (c == (u8)'*' && next == (u8)'/')
                    {
                    out.appendCString("  ");
                    i = i + (u32)2;
                    inBlock = false;
                    }
                else
                    {
                    if (!warnedNested && c == (u8)'/' && next == (u8)'*')
                        {
                        // Once per comment: a run of them is one mistake.
                        _warn(String.withCString(
                            "'/*' within a block comment - comments do not nest, "
                            "so the first '*/' ends it"));
                        warnedNested = true;
                        }
                    out.appendByte((c == (u8)10) ? c : (u8)32);
                    i = i + (u32)1;
                    }
                continue;
                }

            if (inString)
                {
                out.appendByte(c);
                // backslash
                if (c == (u8)92 && i + (u32)1 < n)
                    {
                    out.appendByte(next);
                    i = i + (u32)2;
                    continue;
                    }
                if (c == (u8)34)
                    inString = false;
                i = i + (u32)1;
                continue;
                }

            if (inChar)
                {
                out.appendByte(c);
                if (c == (u8)92 && i + (u32)1 < n)
                    {
                    out.appendByte(next);
                    i = i + (u32)2;
                    continue;
                    }
                if (c == (u8)39)
                    inChar = false;
                i = i + (u32)1;
                continue;
                }

            if (c == (u8)'/' && next == (u8)'/')
                {
                while (i < n && b[i] != (u8)10)
                    i = i + (u32)1;
                continue;
                }
            if (c == (u8)'/' && next == (u8)'*')
                {
                inBlock = true;
                warnedNested = false;
                out.appendCString("  ");
                i = i + (u32)2;
                continue;
                }
            if (c == (u8)34)
                {
                inString = true;
                out.appendByte(c);
                i = i + (u32)1;
                continue;
                }
            if (c == (u8)39)
                {
                inChar = true;
                out.appendByte(c);
                i = i + (u32)1;
                continue;
                }

            out.appendByte(c);
            i = i + (u32)1;
            }
        // Running off the end still inside a block comment swallowed the rest
        // of the file silently. Checked HERE — `inBlock` is this function's,
        // and the check had been appended to canonPath(), where the name does
        // not exist and the file therefore did not compile at all.
        if (inBlock)
            _error(String.withCString("unterminated block comment - no closing '*/'"));
        return out;
        }

    // ── The main pass ────────────────────────────────────────────
    String* preprocessSource(String* source, String* filename)
        {
        // Re-entrant: an #import recurses into this. A parent file's open #if
        // legitimately spans the included file, so the "unterminated #if" check
        // compares against the depth AT ENTRY, not against zero.
        u32 entryIfDepth = _ifStack.count();
        // The TOP-LEVEL file joins the once-only set, so an import cycle that
        // leads back to it (Object.xc -> String.xc -> CharacterSet.xc ->
        // Object.xc) hits the once-only check instead of re-including the
        // entry file mid-cycle (which defined every class in it twice).
        // Depth-guarded: included files are registered at their import site,
        // and a plain #include must stay re-includable.
        if (_sourceDepth == (u32)0 && filename != (String*)0 && filename.byteLength() > (u32)0)
            _imported.add((Hashable*)Preprocessor.canonPath(filename));
        _sourceDepth = _sourceDepth + (u32)1;

        String* stripped = stripComments(source);

        // Join continuation lines, remembering each joined line's ORIGINAL
        // number so the emitted #line directives stay truthful.
        Array* rawLines = stripped.splitOnByte((u8)10);
        Array* lines = new Array();
        Array* origins = new Array();
        String* pending = (String*)0;
        u32 origLine = (u32)0;
        u32 pendingStart = (u32)0;

        for (u32 li = (u32)0; li < rawLines.count(); li = li + (u32)1)
            {
            String* rawLine = (String*)rawLines.get(li);
            origLine = origLine + (u32)1;
            String* trimmed = rawLine.trimmed();
            if (trimmed.byteLength() > (u32)0 && trimmed.byteAt(trimmed.byteLength() - (u32)1) == (u8)92)
                {
                String* withoutSlash = trimmed.substringBytes((u32)0, trimmed.byteLength() - (u32)1);
                if (pending != 0)
                    {
                    pending.append(withoutSlash);
                    }
                else
                    {
                    pending = String.withString(withoutSlash);
                    pendingStart = origLine;
                    }
                }
            else
                {
                if (pending != 0)
                    {
                    pending.append(rawLine);
                    lines.add((Object*)pending);
                    origins.add((Object*)Number.with(pendingStart));
                    pending = (String*)0;
                    }
                else
                    {
                    lines.add((Object*)rawLine);
                    origins.add((Object*)Number.with(origLine));
                    }
                }
            }
        if (pending != 0)
            {
            lines.add((Object*)pending);
            origins.add((Object*)Number.with(pendingStart));
            }

        String* output = String.withCString("");
        output.appendFormat("#line 1 \"%s\"\n", filename.cString());
        u32 lastEmittedLine = (u32)1;

        // The implicit platform PRELUDE: the target's system-dependent header,
        // imported before the source names anything, so a program stays
        // platform-agnostic and still reaches the native API. It is imported
        // ONCE — this runs for every included file too, and `#import` already
        // dedups by resolved path, so every attempt after the first is a
        // no-op. The #line is reset afterwards so the user's line numbers are
        // unaffected by it.
        if (_prelude != 0 && _prelude.byteLength() > (u32)0)
            {
            String* d = String.withCString("import \"");
            d.append(_prelude);
            d.appendCString("\"");
            // Save and restore rather than set and clear: this runs for every
            // included file, and a nested (no-op) prelude block must not clear
            // the flag while the OUTER one is still expanding.
            bool savedInPrelude = _inPrelude;
            _inPrelude = true;
            handleInclude(d, filename, (u32)0, output, true);
            _inPrelude = savedInPrelude;
            output.appendFormat("#line 1 \"%s\"\n", filename.cString());
            }

        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* rawLine = (String*)lines.get(i);
            Number* ln = (Number*)origins.get(i);
            u32 thisOrigLine = ln.asU32();
            String* line = rawLine.trimmed();

            bool currentlyActive = conditionalActive();

            if (line.byteLength() > (u32)0 && line.byteAt((u32)0) == (u8)'#')
                {
                // Conditional directives always run: they mutate the if-stack
                // and decide what "active" means from here on. Everything else
                // is skipped inside an inactive branch.
                bool isCond = isConditionalDirective(line);
                if (currentlyActive || isCond)
                    {
                    processDirective(line, filename, thisOrigLine, output);
                    }
                else
                    {
                    output.appendByte((u8)10);
                    }
                u32 nextOrigLine = thisOrigLine + (u32)1;
                if (i + (u32)1 < origins.count())
                    {
                    Number* nx = (Number*)origins.get(i + (u32)1);
                    nextOrigLine = nx.asU32();
                    }
                output.appendFormat("#line %lu \"%s\"\n", nextOrigLine, filename.cString());
                lastEmittedLine = nextOrigLine;
                }
            else if (!currentlyActive)
                {
                output.appendByte((u8)10);
                lastEmittedLine = thisOrigLine + (u32)1;
                }
            else
                {
                if (thisOrigLine != lastEmittedLine)
                    {
                    output.appendFormat("#line %lu \"%s\"\n", thisOrigLine, filename.cString());
                    }
                output.append(expandMacrosInText(rawLine));
                output.appendByte((u8)10);
                lastEmittedLine = thisOrigLine + (u32)1;
                }
            }

        if (_ifStack.count() > entryIfDepth)
            _error(String.withCString("unterminated #if / #ifdef block"));
        _sourceDepth = _sourceDepth - (u32)1;
        return output;
        }

    // ── Conditional state ────────────────────────────────────────
    bool conditionalActive(void)
        {
        if (_ifStack.count() == (u32)0)
            return true;
        IfFrame* f = (IfFrame*)_ifStack.last();
        return f.active();
        }

    bool isConditionalDirective(String* line)
        {
        String* body = line.substringFromByte((u32)1).trimmed();
        if (Preprocessor._sameCString(body, "else"))
            return true;
        if (Preprocessor._sameCString(body, "endif"))
            return true;
        if (Preprocessor._sameCString(body, "if"))
            return true;
        if (Preprocessor._sameCString(body, "ifdef"))
            return true;
        if (Preprocessor._sameCString(body, "ifndef"))
            return true;
        if (Preprocessor._sameCString(body, "elif"))
            return true;
        if (Preprocessor._hasCPrefix(body, "if "))
            return true;
        if (Preprocessor._hasCPrefix(body, "if("))
            return true;
        if (Preprocessor._hasCPrefix(body, "ifdef "))
            return true;
        if (Preprocessor._hasCPrefix(body, "ifndef "))
            return true;
        if (Preprocessor._hasCPrefix(body, "elif "))
            return true;
        if (Preprocessor._hasCPrefix(body, "elif("))
            return true;
        if (Preprocessor._hasCPrefix(body, "else "))
            return true;
        if (Preprocessor._hasCPrefix(body, "endif "))
            return true;
        return false;
        }

    void pushIf(bool cond)
        {
        bool parentActive = true;
        if (_ifStack.count() > (u32)0)
            {
            IfFrame* top = (IfFrame*)_ifStack.last();
            parentActive = top.active();
            }
        bool active = parentActive && cond;
        _ifStack.add((Object*)IfFrame.with(active, active, parentActive));
        }

    void applyElif(String* expr)
        {
        if (_ifStack.count() == (u32)0)
            {
            _error(String.withCString("#elif without matching #if"));
            return;
            }
        IfFrame* f = (IfFrame*)_ifStack.last();
        if (!f.parentActive() || f.taken())
            {
            f.setActive(false);
            return;
            }
        i32 v = evaluateIfExpression(expr);
        f.setActive(v != (i32)0);
        f.setTaken(f.active());
        }

    void applyElse(void)
        {
        if (_ifStack.count() == (u32)0)
            {
            _error(String.withCString("#else without matching #if"));
            return;
            }
        IfFrame* f = (IfFrame*)_ifStack.last();
        if (!f.parentActive() || f.taken())
            {
            f.setActive(false);
            return;
            }
        f.setActive(true);
        f.setTaken(true);
        }

    // ── #if expression evaluation ────────────────────────────────
    // `defined X` resolves BEFORE macro expansion, so its argument is not
    // substituted away; every identifier still standing afterwards is 0, per C.
    i32 evaluateIfExpression(String* expr)
        {
        String* e = resolveDefinedIn(expr);
        e = expandMacrosInText(e);
        e = substituteUndefinedIdentifiers(e);

        u32 pos = (u32)0;
        i32 v = _parseExpr(e, pos);
        return v;
        }

    String* resolveDefinedIn(String* expr)
        {
        String* out = String.withCString("");
        u32 i = (u32)0;
        u32 len = expr.byteLength();
        while (i < len)
            {
            u8 c = expr.byteAt(i);
            bool isDefined = false;
            if (c == (u8)'d' && i + (u32)7 <= len)
                {
                String* word = expr.substringBytes(i, (u32)7);
                bool leftOK = (i == (u32)0) || !Preprocessor.isIdentChar(expr.byteAt(i - (u32)1));
                bool rightOK = (i + (u32)7 >= len) || !Preprocessor.isIdentChar(expr.byteAt(i + (u32)7));
                isDefined = Preprocessor._sameCString(word, "defined") && leftOK && rightOK;
                }
            if (!isDefined)
                {
                out.appendByte(c);
                i = i + (u32)1;
                continue;
                }

            i = i + (u32)7;
            while (i < len && (expr.byteAt(i) == (u8)32 || expr.byteAt(i) == (u8)9))
                i = i + (u32)1;
            bool paren = (i < len && expr.byteAt(i) == (u8)'(');
            if (paren)
                {
                i = i + (u32)1;
                while (i < len && (expr.byteAt(i) == (u8)32 || expr.byteAt(i) == (u8)9))
                    i = i + (u32)1;
                }
            String* name = String.withCString("");
            while (i < len && Preprocessor.isIdentChar(expr.byteAt(i)))
                {
                name.appendByte(expr.byteAt(i));
                i = i + (u32)1;
                }
            if (paren)
                {
                while (i < len && (expr.byteAt(i) == (u8)32 || expr.byteAt(i) == (u8)9))
                    i = i + (u32)1;
                if (i < len && expr.byteAt(i) == (u8)')')
                    i = i + (u32)1;
                }
            out.appendCString(_macros.contains((Hashable*)name) ? "1" : "0");
            }
        return out;
        }

    String* substituteUndefinedIdentifiers(String* expr)
        {
        String* out = String.withCString("");
        u32 i = (u32)0;
        u32 len = expr.byteLength();
        while (i < len)
            {
            u8 c = expr.byteAt(i);
            if ((c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z') || c == (u8)'_')
                {
                while (i < len && Preprocessor.isIdentChar(expr.byteAt(i)))
                    i = i + (u32)1;
                out.appendByte((u8)'0');
                }
            else
                {
                out.appendByte(c);
                i = i + (u32)1;
                }
            }
        return out;
        }

    static bool isIdentChar(u8 c)
        {
        return (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_';
        }

    // The expression grammar, one method per precedence level — the same shape
    // as the original's parseExprC…parsePrimary chain. `pos` is threaded by
    // reference through an ivar-free style: each level takes and returns it.
    void _skipSpaces(String* s, u32* pos)
        {
        u32 p = pos[0];
        while (p < s.byteLength() && (s.byteAt(p) == (u8)32 || s.byteAt(p) == (u8)9))
            p = p + (u32)1;
        pos[0] = p;
        }

    i32 _parseExpr(String* s, u32 startPos)
        {
        u32 p[1];
        p[0] = startPos;
        return _parseLogicalOr(s, &p[0]);
        }

    i32 _parseLogicalOr(String* s, u32* pos)
        {
        i32 a = _parseLogicalAnd(s, pos);
        _skipSpaces(s, pos);
        while (pos[0] + (u32)1 < s.byteLength() && s.byteAt(pos[0]) == (u8)'|' && s.byteAt(pos[0] + (u32)1) == (u8)'|')
            {
            pos[0] = pos[0] + (u32)2;
            i32 b = _parseLogicalAnd(s, pos);
            a = ((a != (i32)0) || (b != (i32)0)) ? (i32)1 : (i32)0;
            _skipSpaces(s, pos);
            }
        return a;
        }

    i32 _parseLogicalAnd(String* s, u32* pos)
        {
        i32 a = _parseBitOr(s, pos);
        _skipSpaces(s, pos);
        while (pos[0] + (u32)1 < s.byteLength() && s.byteAt(pos[0]) == (u8)'&' && s.byteAt(pos[0] + (u32)1) == (u8)'&')
            {
            pos[0] = pos[0] + (u32)2;
            i32 b = _parseBitOr(s, pos);
            a = ((a != (i32)0) && (b != (i32)0)) ? (i32)1 : (i32)0;
            _skipSpaces(s, pos);
            }
        return a;
        }

    i32 _parseBitOr(String* s, u32* pos)
        {
        i32 a = _parseBitXor(s, pos);
        _skipSpaces(s, pos);
        while (pos[0] < s.byteLength() && s.byteAt(pos[0]) == (u8)'|' && !(pos[0] + (u32)1 < s.byteLength() && s.byteAt(pos[0] + (u32)1) == (u8)'|'))
            {
            pos[0] = pos[0] + (u32)1;
            i32 b = _parseBitXor(s, pos);
            a = a | b;
            _skipSpaces(s, pos);
            }
        return a;
        }

    i32 _parseBitXor(String* s, u32* pos)
        {
        i32 a = _parseBitAnd(s, pos);
        _skipSpaces(s, pos);
        while (pos[0] < s.byteLength() && s.byteAt(pos[0]) == (u8)'^')
            {
            pos[0] = pos[0] + (u32)1;
            i32 b = _parseBitAnd(s, pos);
            a = a ^ b;
            _skipSpaces(s, pos);
            }
        return a;
        }

    i32 _parseBitAnd(String* s, u32* pos)
        {
        i32 a = _parseEquality(s, pos);
        _skipSpaces(s, pos);
        while (pos[0] < s.byteLength() && s.byteAt(pos[0]) == (u8)'&' && !(pos[0] + (u32)1 < s.byteLength() && s.byteAt(pos[0] + (u32)1) == (u8)'&'))
            {
            pos[0] = pos[0] + (u32)1;
            i32 b = _parseEquality(s, pos);
            a = a & b;
            _skipSpaces(s, pos);
            }
        return a;
        }

    i32 _parseEquality(String* s, u32* pos)
        {
        i32 a = _parseRelational(s, pos);
        _skipSpaces(s, pos);
        while (pos[0] + (u32)1 < s.byteLength())
            {
            u8 c0 = s.byteAt(pos[0]);
            u8 c1 = s.byteAt(pos[0] + (u32)1);
            if (c0 == (u8)'=' && c1 == (u8)'=')
                {
                pos[0] = pos[0] + (u32)2;
                i32 b = _parseRelational(s, pos);
                a = (a == b) ? (i32)1 : (i32)0;
                }
            else if (c0 == (u8)'!' && c1 == (u8)'=')
                {
                pos[0] = pos[0] + (u32)2;
                i32 b = _parseRelational(s, pos);
                a = (a != b) ? (i32)1 : (i32)0;
                }
            else
                {
                break;
                }
            _skipSpaces(s, pos);
            }
        return a;
        }

    i32 _parseRelational(String* s, u32* pos)
        {
        i32 a = _parseShift(s, pos);
        _skipSpaces(s, pos);
        while (pos[0] < s.byteLength())
            {
            u8 c0 = s.byteAt(pos[0]);
            u8 c1 = (pos[0] + (u32)1 < s.byteLength()) ? s.byteAt(pos[0] + (u32)1) : (u8)0;
            if (c0 == (u8)'<' && c1 == (u8)'=')
                {
                pos[0] = pos[0] + (u32)2;
                i32 b = _parseShift(s, pos);
                a = (a <= b) ? (i32)1 : (i32)0;
                }
            else if (c0 == (u8)'>' && c1 == (u8)'=')
                {
                pos[0] = pos[0] + (u32)2;
                i32 b = _parseShift(s, pos);
                a = (a >= b) ? (i32)1 : (i32)0;
                }
            else if (c0 == (u8)'<' && c1 != (u8)'<')
                {
                pos[0] = pos[0] + (u32)1;
                i32 b = _parseShift(s, pos);
                a = (a < b) ? (i32)1 : (i32)0;
                }
            else if (c0 == (u8)'>' && c1 != (u8)'>')
                {
                pos[0] = pos[0] + (u32)1;
                i32 b = _parseShift(s, pos);
                a = (a > b) ? (i32)1 : (i32)0;
                }
            else
                {
                break;
                }
            _skipSpaces(s, pos);
            }
        return a;
        }

    i32 _parseShift(String* s, u32* pos)
        {
        i32 a = _parseAdditive(s, pos);
        _skipSpaces(s, pos);
        while (pos[0] + (u32)1 < s.byteLength())
            {
            u8 c0 = s.byteAt(pos[0]);
            u8 c1 = s.byteAt(pos[0] + (u32)1);
            if (c0 == (u8)'<' && c1 == (u8)'<')
                {
                pos[0] = pos[0] + (u32)2;
                i32 b = _parseAdditive(s, pos);
                a = a << b;
                }
            else if (c0 == (u8)'>' && c1 == (u8)'>')
                {
                pos[0] = pos[0] + (u32)2;
                i32 b = _parseAdditive(s, pos);
                a = a >> b;
                }
            else
                {
                break;
                }
            _skipSpaces(s, pos);
            }
        return a;
        }

    i32 _parseAdditive(String* s, u32* pos)
        {
        i32 a = _parseMultiplicative(s, pos);
        _skipSpaces(s, pos);
        while (pos[0] < s.byteLength())
            {
            u8 c = s.byteAt(pos[0]);
            if (c == (u8)'+')
                {
                pos[0] = pos[0] + (u32)1;
                a = a + _parseMultiplicative(s, pos);
                }
            else if (c == (u8)'-')
                {
                pos[0] = pos[0] + (u32)1;
                a = a - _parseMultiplicative(s, pos);
                }
            else
                {
                break;
                }
            _skipSpaces(s, pos);
            }
        return a;
        }

    i32 _parseMultiplicative(String* s, u32* pos)
        {
        i32 a = _parseUnary(s, pos);
        _skipSpaces(s, pos);
        while (pos[0] < s.byteLength())
            {
            u8 c = s.byteAt(pos[0]);
            if (c == (u8)'*')
                {
                pos[0] = pos[0] + (u32)1;
                a = a * _parseUnary(s, pos);
                }
            else if (c == (u8)'/')
                {
                pos[0] = pos[0] + (u32)1;
                i32 b = _parseUnary(s, pos);
                a = (b == (i32)0) ? (i32)0 : (a / b); // no division by zero
                }
            else if (c == (u8)'%')
                {
                pos[0] = pos[0] + (u32)1;
                i32 b = _parseUnary(s, pos);
                a = (b == (i32)0) ? (i32)0 : (a % b);
                }
            else
                {
                break;
                }
            _skipSpaces(s, pos);
            }
        return a;
        }

    i32 _parseUnary(String* s, u32* pos)
        {
        _skipSpaces(s, pos);
        if (pos[0] < s.byteLength())
            {
            u8 c = s.byteAt(pos[0]);
            if (c == (u8)'!')
                {
                pos[0] = pos[0] + (u32)1;
                return (_parseUnary(s, pos) == (i32)0) ? (i32)1 : (i32)0;
                }
            if (c == (u8)'-')
                {
                pos[0] = pos[0] + (u32)1;
                return (i32)0 - _parseUnary(s, pos);
                }
            if (c == (u8)'+')
                {
                pos[0] = pos[0] + (u32)1;
                return _parseUnary(s, pos);
                }
            if (c == (u8)'~')
                {
                pos[0] = pos[0] + (u32)1;
                return ~_parseUnary(s, pos);
                }
            }
        return _parsePrimary(s, pos);
        }

    i32 _parsePrimary(String* s, u32* pos)
        {
        _skipSpaces(s, pos);
        if (pos[0] >= s.byteLength())
            {
            _error(String.withCString("unexpected end of #if expression"));
            return (i32)0;
            }
        u8 c = s.byteAt(pos[0]);

        if (c == (u8)'(')
            {
            pos[0] = pos[0] + (u32)1;
            i32 v = _parseLogicalOr(s, pos);
            _skipSpaces(s, pos);
            if (pos[0] < s.byteLength() && s.byteAt(pos[0]) == (u8)')')
                pos[0] = pos[0] + (u32)1;
            else
                _error(String.withCString("missing ')' in #if expression"));
            return v;
            }

        if (c >= (u8)'0' && c <= (u8)'9')
            {
            i32 v = (i32)0;
            i32 base = (i32)10;
            if (c == (u8)'0' && pos[0] + (u32)1 < s.byteLength())
                {
                u8 c1 = s.byteAt(pos[0] + (u32)1);
                if (c1 == (u8)'x' || c1 == (u8)'X')
                    {
                    base = (i32)16;
                    pos[0] = pos[0] + (u32)2;
                    }
                }
            while (pos[0] < s.byteLength())
                {
                u8 d = s.byteAt(pos[0]);
                i32 digit = (i32)-1;
                if (d >= (u8)'0' && d <= (u8)'9')
                    digit = (i32)(d - (u8)'0');
                else if (base == (i32)16 && d >= (u8)'A' && d <= (u8)'F')
                    digit = (i32)10 + (i32)(d - (u8)'A');
                else if (base == (i32)16 && d >= (u8)'a' && d <= (u8)'f')
                    digit = (i32)10 + (i32)(d - (u8)'a');
                if (digit < (i32)0)
                    break;
                v = v * base + digit;
                pos[0] = pos[0] + (u32)1;
                }
            return v;
            }

        // xtc-style hex literal
        if (c == (u8)'$')
            {
            pos[0] = pos[0] + (u32)1;
            i32 v = (i32)0;
            while (pos[0] < s.byteLength())
                {
                u8 d = s.byteAt(pos[0]);
                i32 digit = (i32)-1;
                if (d >= (u8)'0' && d <= (u8)'9')
                    digit = (i32)(d - (u8)'0');
                else if (d >= (u8)'A' && d <= (u8)'F')
                    digit = (i32)10 + (i32)(d - (u8)'A');
                else if (d >= (u8)'a' && d <= (u8)'f')
                    digit = (i32)10 + (i32)(d - (u8)'a');
                if (digit < (i32)0)
                    break;
                v = v * (i32)16 + digit;
                pos[0] = pos[0] + (u32)1;
                }
            return v;
            }

        _error(String.withCString("unexpected character in #if expression"));
        pos[0] = pos[0] + (u32)1;
        return (i32)0;
        }

    // ── Directives ───────────────────────────────────────────────
    void processDirective(String* line, String* filename, u32 lineNumber, String* output)
        {
        String* content = line.substringFromByte((u32)1).trimmed();

        if (Preprocessor._hasCPrefix(content, "import"))
            {
            handleInclude(content, filename, lineNumber, output, true);
            return;
            }
        if (Preprocessor._hasCPrefix(content, "include"))
            {
            handleInclude(content, filename, lineNumber, output, false);
            return;
            }
        if (Preprocessor._hasCPrefix(content, "use") && (content.byteLength() == (u32)3 || !Preprocessor.isIdentChar(content.byteAt((u32)3))))
            {
            // `#use K` == `#import <K>` plus a `use K;` line for the parser.
            String* rest = content.substringFromByte((u32)3).trimmed();
            bool wasAngle = rest.byteLength() >= (u32)2 && rest.byteAt((u32)0) == (u8)'<' && rest.byteAt(rest.byteLength() - (u32)1) == (u8)'>';
            bool wasQuote = rest.byteLength() >= (u32)2 && rest.byteAt((u32)0) == (u8)34 && rest.byteAt(rest.byteLength() - (u32)1) == (u8)34;
            if (wasAngle || wasQuote)
                rest = rest.substringBytes((u32)1, rest.byteLength() - (u32)2);
            if (rest.byteLength() > (u32)3 && (rest.hasSuffix(String.withCString(".xc")) || rest.hasSuffix(String.withCString(".xt"))))
                rest = rest.substringBytes((u32)0, rest.byteLength() - (u32)3);
            if (rest.byteLength() == (u32)0)
                {
                _error(String.withCString("#use requires a class name"));
                return;
                }
            String* synth = String.withCString("");
            if (wasAngle)
                synth.appendFormat("import <%s>", rest.cString());
            else
                synth.appendFormat("import \"%s\"", rest.cString());
            handleInclude(synth, filename, lineNumber, output, true);
            output.appendFormat("use %s;\n", rest.cString());
            return;
            }
        // `#package <ns>` — the host import namespace for subsequent bodyless
        // (imported) declarations, rewritten to a `package <ns>;` line the
        // parser consumes, exactly as `#use` becomes `use K;`.
        //
        // A HARD ERROR off wasm32: it performs no lookup, so there is nothing
        // to degrade silently, and it appears only in per-platform files.
        // Without it the externs land in `env`, and the loader — which
        // supplies them under `browser` — hands back a stub that throws when
        // called. That was a wasm program that built, ran, and trapped.
        if (Preprocessor._hasCPrefix(content, "package") && (content.byteLength() == (u32)7 || !Preprocessor.isIdentChar(content.byteAt((u32)7))))
            {
            if (_arch == 0 || !_arch.equals(String.withCString("wasm32")))
                {
                _error(String.withCString("#package names a host import namespace, "
                                          "which this target does not have (wasm32 only)"));
                return;
                }
            String* rest = content.substringFromByte((u32)7).trimmed();
            bool ang = rest.byteLength() >= (u32)2 && rest.byteAt((u32)0) == (u8)'<' && rest.byteAt(rest.byteLength() - (u32)1) == (u8)'>';
            bool qot = rest.byteLength() >= (u32)2 && rest.byteAt((u32)0) == (u8)34 && rest.byteAt(rest.byteLength() - (u32)1) == (u8)34;
            if (ang || qot)
                rest = rest.substringBytes((u32)1, rest.byteLength() - (u32)2);
            if (rest.byteLength() == (u32)0)
                {
                _error(String.withCString("#package requires a namespace name"));
                return;
                }
            _currentPackage = rest;
            output.appendFormat("package %s;\n", rest.cString());
            return;
            }
        if (Preprocessor._hasCPrefix(content, "define"))
            {
            handleDefine(content);
            return;
            }
        if (Preprocessor._hasCPrefix(content, "undef"))
            {
            String* name = content.substringFromByte((u32)5).trimmed();
            _macros.remove((Hashable*)name);
            return;
            }
        if (Preprocessor._hasCPrefix(content, "warning"))
            {
            _warn(content.substringFromByte((u32)7).trimmed());
            return;
            }
        if (Preprocessor._hasCPrefix(content, "error"))
            {
            _error(content.substringFromByte((u32)5).trimmed());
            return;
            }
        if (Preprocessor._hasCPrefix(content, "ifdef") && (content.byteLength() == (u32)5 || !Preprocessor.isIdentChar(content.byteAt((u32)5))))
            {
            String* rest = content.substringFromByte((u32)5).trimmed();
            pushIf(_macros.contains((Hashable*)rest));
            output.appendByte((u8)10);
            return;
            }
        if (Preprocessor._hasCPrefix(content, "ifndef") && (content.byteLength() == (u32)6 || !Preprocessor.isIdentChar(content.byteAt((u32)6))))
            {
            String* rest = content.substringFromByte((u32)6).trimmed();
            pushIf(!_macros.contains((Hashable*)rest));
            output.appendByte((u8)10);
            return;
            }
        if (Preprocessor._hasCPrefix(content, "if") && (content.byteLength() == (u32)2 || !Preprocessor.isIdentChar(content.byteAt((u32)2))))
            {
            String* expr = content.substringFromByte((u32)2).trimmed();
            i32 v = evaluateIfExpression(expr);
            pushIf(v != (i32)0);
            output.appendByte((u8)10);
            return;
            }
        if (Preprocessor._hasCPrefix(content, "elif") && (content.byteLength() == (u32)4 || !Preprocessor.isIdentChar(content.byteAt((u32)4))))
            {
            applyElif(content.substringFromByte((u32)4).trimmed());
            output.appendByte((u8)10);
            return;
            }
        if (Preprocessor._sameCString(content, "else") || Preprocessor._hasCPrefix(content, "else "))
            {
            applyElse();
            output.appendByte((u8)10);
            return;
            }
        if (Preprocessor._sameCString(content, "endif") || Preprocessor._hasCPrefix(content, "endif "))
            {
            if (_ifStack.count() == (u32)0)
                _error(String.withCString("#endif without matching #if"));
            else
                _ifStack.removeLast();
            output.appendByte((u8)10);
            return;
            }

        _warn(String.withCString("Unknown preprocessor directive"));
        output.appendByte((u8)10);
        }

    // #import / #include. The quote form searches the current file's directory
    // first, the angle form does not — except that a file already living in a
    // search directory (a library) gets no head start either way, which is what
    // lets generic/lib/Object.xc pick up the TARGET's String rather than its own
    // neighbour.
    void handleInclude(String* content, String* filename, u32 line, String* output, bool onceOnly)
        {
        String* rest = content;
        if (Preprocessor._hasCPrefix(rest, "import"))
            rest = rest.substringFromByte((u32)6);
        else if (Preprocessor._hasCPrefix(rest, "include"))
            rest = rest.substringFromByte((u32)7);
        rest = rest.trimmed();

        String* target = (String*)0;
        bool isSystemForm = false;
        if (rest.byteLength() >= (u32)2 && rest.byteAt((u32)0) == (u8)'<' && rest.byteAt(rest.byteLength() - (u32)1) == (u8)'>')
            {
            target = rest.substringBytes((u32)1, rest.byteLength() - (u32)2);
            isSystemForm = true;
            }
        else if (rest.byteLength() >= (u32)2 && rest.byteAt((u32)0) == (u8)34 && rest.byteAt(rest.byteLength() - (u32)1) == (u8)34)
            {
            target = rest.substringBytes((u32)1, rest.byteLength() - (u32)2);
            }
        else
            {
            _error(Preprocessor.positioned(filename, line, String.withCString("Malformed #include/#import directive")));
            return;
            }

        Array* searchPaths = new Array();
        if (!isSystemForm)
            {
            String* currentDir = filename.deletingLastPathComponent();
            bool currentIsLibraryDir = false;
            String* curCanon = Preprocessor.canonPath(currentDir);
            for (u32 i = (u32)0; i < _includePaths.count(); i = i + (u32)1)
                {
                String* dir = (String*)_includePaths.get(i);
                if (Preprocessor.canonPath(dir).equals(curCanon))
                    currentIsLibraryDir = true;
                }
            if (!currentIsLibraryDir)
                searchPaths.add((Object*)currentDir);
            }
        searchPaths.addAll(_includePaths);

        // A bare module name also tries `<name>.xc`, so `#import <X>` resolves a
        // source class as well as a binary library. `.xt` is the OLD extension
        // and is still honoured two ways — a bare name falls back to it, and an
        // explicit `#import "Stdio.xt"` that is missing retries as `Stdio.xc`,
        // which is what lets a tree that has NOT been renamed keep importing
        // libraries that have. Must match the ObjC resolver exactly: a bare
        // import that finds a different file in the two implementations is a
        // divergence no differential would attribute to the preprocessor.
        bool bareName = (target.indexOfByte((u8)'.') == String.notFound());
        String* renamed = (String*)0;
        if (target.hasSuffix(String.withCString(".xt")))
            {
            renamed = target.substringBytes((u32)0, target.byteLength() - (u32)3);
            renamed.append(String.withCString(".xc"));
            }
        String* foundPath = (String*)0;
        for (u32 i = (u32)0; i < searchPaths.count() && foundPath == 0; i = i + (u32)1)
            {
            String* dir = (String*)searchPaths.get(i);
            String* candidate = dir.appendingPathComponent(target);
            if (Files.existsExact(candidate))
                {
                foundPath = candidate;
                }
            else if (renamed != (String*)0)
                {
                String* rc = dir.appendingPathComponent(renamed);
                if (Files.existsExact(rc))
                    foundPath = rc;
                }
            if (foundPath == (String*)0 && bareName)
                {
                String* withExt = candidate.appendingPathExtension(String.withCString("xc"));
                if (Files.existsExact(withExt))
                    foundPath = withExt;
                else
                    {
                    withExt = candidate.appendingPathExtension(String.withCString("xt"));
                    if (Files.existsExact(withExt))
                        foundPath = withExt;
                    }
                }
            }

        // Not a source file — a shared library is RECORDED, not included; the
        // caller (xtfe) turns the recorded path into typed declarations. A
        // BARE `<name>.xtc.iface`, as `xcc -c` leaves beside its object, is the
        // module's header and resolves the same way — listed LAST per dir so a
        // real library still wins when both exist, mirroring the reference's
        // candidate order (separate-compilation stage 3). Binary libraries are
        // recorded but the port has no Mach-O/ELF section readers, so the
        // caller refuses them loudly rather than compiling without imports.
        if (foundPath == 0 && _libraryPaths.count() > (u32)0)
            {
            // The extension order is TARGET-DRIVEN, as the reference does it
            // (XTCompilerDriver's `sharedLibExtensions`): pin the right object
            // format first so a stale sibling of the wrong one in a -L dir can
            // never be picked. This used to be a fixed chain — dylib, so, wasm
            // — for every target, which had two consequences. A wasm build
            // could match a stray `.so`; and win64, whose system libraries are
            // mingw IMPORT LIBRARIES (`libuser32.a`), matched nothing at all,
            // so a program naming any Win32 library beyond the three bundled
            // stubs could not be compiled (bug 120).
            Array* exts = new Array();
            if (_arch != 0 && _arch.equals(String.withCString("win64")))
                {
                // The xtc DLL first — it carries the `.xtc_iface` section the
                // front end reads — then its import lib, then a SYSTEM import
                // library, which is what `libcomdlg32.a` is.
                exts.add((Object*)String.withCString("dll"));
                exts.add((Object*)String.withCString("dll.a"));
                exts.add((Object*)String.withCString("a"));
                }
            else if (_arch != 0 && _arch.equals(String.withCString("wasm32")))
                {
                // A wasm LIBRARY carries its interface in an `xtc.iface`
                // custom section, so the module IS the header.
                exts.add((Object*)String.withCString("wasm"));
                }
            else if (_arch != 0 && _arch.equals(String.withCString("arm64")))
                {
                exts.add((Object*)String.withCString("dylib"));
                exts.add((Object*)String.withCString("so"));
                }
            else
                {
                exts.add((Object*)String.withCString("so"));
                exts.add((Object*)String.withCString("dylib"));
                }
            for (u32 i = (u32)0; i < _libraryPaths.count(); i = i + (u32)1)
                {
                String* dir = (String*)_libraryPaths.get(i);
                for (u32 e = (u32)0; e < exts.count(); e = e + (u32)1)
                    {
                    String* cand = String.withCString("lib");
                    cand.append(target);
                    cand.appendCString(".");
                    cand.append((String*)exts.get(e));
                    String* p = dir.appendingPathComponent(cand);
                    if (Files.existsExact(p))
                        {
                        _metadataImports.add((Object*)p);
                        return;
                        }
                    }
                // Already a lib name? The reference tries the bare stem too,
                // so `#use <libfoo.a>` and the like resolve.
                String* pbare = dir.appendingPathComponent(target);
                if (Files.existsExact(pbare))
                    {
                    _metadataImports.add((Object*)pbare);
                    return;
                    }
                String* cand3 = String.withString(target);
                cand3.appendCString(".xtc.iface");
                String* p3 = dir.appendingPathComponent(cand3);
                if (Files.existsExact(p3))
                    {
                    _metadataImports.add((Object*)p3);
                    return;
                    }
                }
            }

        if (foundPath == 0)
            {
            // Name the file that asked and the places looked: an include that
            // is not found is nearly always a search-path problem, and the
            // paths are the answer.
            // `file:line:1: error: …` — the directive's own line, column 1,
            // which is where the reference points too (bug 129's last two
            // diag-diff cases; an include the compiler cannot find is the one
            // diagnostic a user hits first, and it had no line to jump to).
            String* msg = String.withString(filename);
            if (line != (u32)0)
                {
                msg.appendByte((u8)':');
                msg.append(String.withU32(line));
                msg.appendCString(":1");
                }
            msg.appendCString(": error: Cannot find include file '");
            msg.append(target);
            msg.appendCString("' (searched:");
            for (u32 i = (u32)0; i < _includePaths.count(); i = i + (u32)1)
                {
                msg.appendCString(" '");
                msg.append((String*)_includePaths.get(i));
                msg.appendCString("'");
                }
            for (u32 i = (u32)0; i < _libraryPaths.count(); i = i + (u32)1)
                {
                msg.appendCString(" -L '");
                msg.append((String*)_libraryPaths.get(i));
                msg.appendCString("'");
                }
            msg.appendCString(")");
            _error(msg);
            return;
            }

        if (onceOnly)
            {
            String* key = Preprocessor.canonPath(foundPath);
            // The already-imported check comes FIRST, and the prelude record
            // after it — the order the reference uses (XTPreprocessor.m, the
            // `_importedFiles` early return above `_mutablePreludeFiles`).
            //
            // Recording before it looks equivalent and is not: the file being
            // COMPILED is registered as imported before the prelude runs, so
            // when the prelude also imports it — which it does for every
            // `support/*/lib/*.xc` — the unit marked ITSELF ambient and its
            // whole public surface vanished from the interface. `Array.xc`
            // published no Array class, no functions and no typedefs.
            //
            // The intent the old order was reaching for still holds without
            // it: the prelude imports Stdio FIRST, so Stdio is recorded on
            // that first sighting, and a later explicit `#import "Stdio.xc"`
            // (a once-only no-op) still does not make Stdio this module's to
            // export.
            if (_imported.contains((Hashable*)key))
                return;
            _imported.add((Hashable*)key);
            if (_inPrelude)
                {
                _preludeFiles.add((Hashable*)key);
                // …and under the spelling that reaches `#line`, which is
                // what an AST node carries. The consumer (IfaceWrite) then
                // needs no path canonicaliser of its own — a second copy of
                // that rule is a second thing to drift.
                _preludeFiles.add((Hashable*)String.withString(foundPath));
                }
            }

        String* included = Files.readText(foundPath);
        if (included == 0)
            {
            _error(String.withCString("Cannot read include file"));
            return;
            }
        // A `#package` inside an included header is scoped to that header: a
        // header imported mid-file must not leak its namespace into everything
        // after it (wasm-target.md §6 rule 2). Save it across the include and
        // emit a restore line — the parser tracks the package from the token
        // stream, so re-arming it needs a line, not just internal state.
        // `__none` clears it.
        //
        // Without this, support/wasm32/lib/Platform.xc's `#package browser`
        // stayed in force for every file included after it, and Math's
        // externs — `_xm_cosf`, `_xm_pow` — were imported from `browser`
        // instead of `env`. The loader supplies them under `env`, so the
        // module failed to instantiate: LinkError, not a wrong answer.
        String* savedPackage = _currentPackage;
        output.append(preprocessSource(included, foundPath));
        bool changed = (savedPackage == (String*)0) != (_currentPackage == (String*)0);
        if (!changed && savedPackage != (String*)0 && _currentPackage != (String*)0)
            changed = !savedPackage.equals(_currentPackage);
        if (changed)
            {
            output.appendFormat("package %s;\n",
                                savedPackage == (String*)0 ? "__none" : savedPackage.cString());
            _currentPackage = savedPackage;
            }
        }

    void handleDefine(String* content)
        {
        String* rest = content.substringFromByte((u32)6).trimmed();
        if (rest.byteLength() == (u32)0)
            {
            _error(String.withCString("#define requires a name"));
            return;
            }

        u32 idx = (u32)0;
        while (idx < rest.byteLength() && Preprocessor.isIdentChar(rest.byteAt(idx)))
            idx = idx + (u32)1;
        String* name = rest.substringBytes((u32)0, idx);
        String* remainder = rest.substringFromByte(idx);

        Array* params = (Array*)0;
        String* body = String.withCString("");

        if (remainder.byteLength() > (u32)0 && remainder.byteAt((u32)0) == (u8)'(')
            {
            u32 closeIdx = remainder.indexOfByte((u8)')');
            if (closeIdx == String.notFound())
                {
                _error(String.withCString("Unterminated macro parameter list"));
                return;
                }
            String* paramStr = remainder.substringBytes((u32)1, closeIdx - (u32)1);
            params = new Array();
            if (paramStr.byteLength() > (u32)0)
                {
                Array* raw = paramStr.splitOnByte((u8)',');
                for (u32 i = (u32)0; i < raw.count(); i = i + (u32)1)
                    {
                    String* p = (String*)raw.get(i);
                    params.add((Object*)p.trimmed());
                    }
                }
            body = remainder.substringFromByte(closeIdx + (u32)1).trimmed();
            }
        else
            {
            body = remainder.trimmed();
            }

        // A trailing `// comment` in a macro body is not part of the body.
        u32 slashes = body.byteIndexOf(String.withCString("//"));
        if (slashes != String.notFound())
            body = body.substringBytes((u32)0, slashes).trimmed();

        _macros.set((Hashable*)name, (Object*)MacroDef.with(name, params, body));
        }

    // ── Macro expansion ──────────────────────────────────────────
    // Blue-painting: a macro currently being expanded is not re-expanded, which
    // is what terminates `#define A A`.
    String* expandMacrosInText(String* text)
        {
        String* result = String.withCString("");
        u32 pos = (u32)0;
        u32 len = text.byteLength();

        while (pos < len)
            {
            u8 ch = text.byteAt(pos);

            // String and character literals pass through untouched.
            if (ch == (u8)34 || ch == (u8)39)
                {
                u8 quote = ch;
                result.appendByte(ch);
                pos = pos + (u32)1;
                while (pos < len)
                    {
                    u8 c = text.byteAt(pos);
                    if (c == (u8)92 && pos + (u32)1 < len)
                        {
                        result.appendByte(c);
                        result.appendByte(text.byteAt(pos + (u32)1));
                        pos = pos + (u32)2;
                        continue;
                        }
                    result.appendByte(c);
                    pos = pos + (u32)1;
                    if (c == quote)
                        break;
                    }
                continue;
                }

            if ((ch >= (u8)'A' && ch <= (u8)'Z') || (ch >= (u8)'a' && ch <= (u8)'z') || ch == (u8)'_')
                {
                u32 identStart = pos;
                while (pos < len && Preprocessor.isIdentChar(text.byteAt(pos)))
                    pos = pos + (u32)1;
                String* ident = text.substringBytes(identStart, pos - identStart);

                MacroDef* macro = (MacroDef* ?)_macros.get((Hashable*)ident);
                if (macro == 0 || _expanding.contains((Hashable*)ident))
                    {
                    result.append(ident);
                    continue;
                    }

                if (macro.functionLike())
                    {
                    u32 savedPos = pos;
                    while (pos < len && (text.byteAt(pos) == (u8)32 || text.byteAt(pos) == (u8)9))
                        pos = pos + (u32)1;
                    if (pos < len && text.byteAt(pos) == (u8)'(')
                        {
                        pos = pos + (u32)1;
                        u32 p[1];
                        p[0] = pos;
                        Array* args = parseCallArgs(text, &p[0]);
                        pos = p[0];
                        result.append(expandFunctionMacro(macro, args));
                        }
                    else
                        {
                        // No argument list: a function-like macro name alone is
                        // just an identifier.
                        pos = savedPos;
                        result.append(ident);
                        }
                    }
                else
                    {
                    _expanding.add((Hashable*)ident);
                    String* pasted = substituteInBody(macro.body(), (Map*)0, (Map*)0);
                    result.append(expandMacrosInText(pasted));
                    _expanding.remove((Hashable*)ident);
                    }
                continue;
                }

            result.appendByte(ch);
            pos = pos + (u32)1;
            }
        return result;
        }

    // Comma-separated arguments up to the matching ')', with nesting, and with
    // literals passing through whole so a comma inside one is not structure.
    Array* parseCallArgs(String* text, u32* posPtr)
        {
        Array* args = new Array();
        String* current = String.withCString("");
        i32 depth = (i32)1;
        u32 pos = posPtr[0];
        u32 len = text.byteLength();

        while (pos < len && depth > (i32)0)
            {
            u8 ch = text.byteAt(pos);

            if (ch == (u8)34 || ch == (u8)39)
                {
                u8 quote = ch;
                current.appendByte(ch);
                pos = pos + (u32)1;
                while (pos < len)
                    {
                    u8 c = text.byteAt(pos);
                    if (c == (u8)92 && pos + (u32)1 < len)
                        {
                        current.appendByte(c);
                        current.appendByte(text.byteAt(pos + (u32)1));
                        pos = pos + (u32)2;
                        continue;
                        }
                    current.appendByte(c);
                    pos = pos + (u32)1;
                    if (c == quote)
                        break;
                    }
                continue;
                }

            if (ch == (u8)'(')
                {
                depth = depth + (i32)1;
                current.appendByte(ch);
                pos = pos + (u32)1;
                }
            else if (ch == (u8)')')
                {
                depth = depth - (i32)1;
                if (depth == (i32)0)
                    {
                    pos = pos + (u32)1;
                    break;
                    }
                current.appendByte(ch);
                pos = pos + (u32)1;
                }
            else if (ch == (u8)',' && depth == (i32)1)
                {
                args.add((Object*)current.trimmed());
                current = String.withCString("");
                pos = pos + (u32)1;
                }
            else
                {
                current.appendByte(ch);
                pos = pos + (u32)1;
                }
            }

        String* last = current.trimmed();
        if (last.byteLength() > (u32)0 || args.count() > (u32)0)
            args.add((Object*)last);
        posPtr[0] = pos;
        return args;
        }

    // Each parameter carries TWO values: the raw spelling, which `#` and `##`
    // operate on, and the expanded one, which an ordinary substitution uses.
    // That split is what makes the two-level CAT(a,b) → CAT2(a,b) → a##b idiom
    // paste already-expanded arguments.
    String* expandFunctionMacro(MacroDef* macro, Array* args)
        {
        Map* rawArgs = new Map();
        Map* expandedArgs = new Map();

        Array* params = macro.params();
        u32 fixed = params.count();
        if (macro.varArgs())
            fixed = fixed - (u32)1;

        for (u32 i = (u32)0; i < fixed; i = i + (u32)1)
            {
            String* p = (String*)params.get(i);
            String* raw = (i < args.count()) ? (String*)args.get(i) : String.withCString("");
            rawArgs.set((Hashable*)p, (Object*)raw);
            expandedArgs.set((Hashable*)p, (Object*)expandMacrosInText(raw));
            }
        if (macro.varArgs())
            {
            String* vaRaw = String.withCString("");
            for (u32 i = fixed; i < args.count(); i = i + (u32)1)
                {
                if (i > fixed)
                    vaRaw.appendCString(", ");
                vaRaw.append((String*)args.get(i));
                }
            String* va = String.withCString("__VA_ARGS__");
            rawArgs.set((Hashable*)va, (Object*)vaRaw);
            expandedArgs.set((Hashable*)va, (Object*)expandMacrosInText(vaRaw));
            }

        _expanding.add((Hashable*)macro.name());
        String* substituted = substituteInBody(macro.body(), rawArgs, expandedArgs);
        String* expanded = expandMacrosInText(substituted);
        _expanding.remove((Hashable*)macro.name());
        return expanded;
        }

    // Split a macro body into preprocessing tokens. Substitution MUST be
    // token-aware: a plain textual replace rewrites the parameter's letters
    // wherever they occur, so a body mentioning `abs_val` with a parameter named
    // `a` came out as `<arg>bs_val`.
    Array* tokenizeMacroBody(String* body)
        {
        Array* toks = new Array();
        u32 pos = (u32)0;
        u32 len = body.byteLength();

        while (pos < len)
            {
            u8 ch = body.byteAt(pos);

            if (ch == (u8)32 || ch == (u8)9)
                {
                u32 start = pos;
                while (pos < len && (body.byteAt(pos) == (u8)32 || body.byteAt(pos) == (u8)9))
                    pos = pos + (u32)1;
                toks.add((Object*)body.substringBytes(start, pos - start));
                continue;
                }

            if (ch == (u8)34 || ch == (u8)39)
                {
                u8 quote = ch;
                u32 start = pos;
                pos = pos + (u32)1;
                while (pos < len)
                    {
                    u8 c = body.byteAt(pos);
                    if (c == (u8)92 && pos + (u32)1 < len)
                        {
                        pos = pos + (u32)2;
                        continue;
                        }
                    pos = pos + (u32)1;
                    if (c == quote)
                        break;
                    }
                toks.add((Object*)body.substringBytes(start, pos - start));
                continue;
                }

            if ((ch >= (u8)'A' && ch <= (u8)'Z') || (ch >= (u8)'a' && ch <= (u8)'z') || ch == (u8)'_')
                {
                u32 start = pos;
                while (pos < len && Preprocessor.isIdentChar(body.byteAt(pos)))
                    pos = pos + (u32)1;
                toks.add((Object*)body.substringBytes(start, pos - start));
                continue;
                }

            if (ch == (u8)'#')
                {
                if (pos + (u32)1 < len && body.byteAt(pos + (u32)1) == (u8)'#')
                    {
                    toks.add((Object*)String.withCString("##"));
                    pos = pos + (u32)2;
                    }
                else
                    {
                    toks.add((Object*)String.withCString("#"));
                    pos = pos + (u32)1;
                    }
                continue;
                }

            toks.add((Object*)body.substringBytes(pos, (u32)1));
            pos = pos + (u32)1;
            }
        return toks;
        }

    static bool _isSpaceToken(String* tok)
        {
        if (tok.byteLength() == (u32)0)
            return false;
        u8 c = tok.byteAt((u32)0);
        return c == (u8)32 || c == (u8)9;
        }

    String* stringizeArgument(String* arg)
        {
        String* out = String.withCString("\"");
        for (u32 i = (u32)0; i < arg.byteLength(); i = i + (u32)1)
            {
            u8 c = arg.byteAt(i);
            if (c == (u8)34 || c == (u8)92)
                out.appendByte((u8)92);
            out.appendByte(c);
            }
        out.appendByte((u8)34);
        return out;
        }

    // Index of the next non-whitespace token at or after `from`.
    u32 _nextReal(Array* toks, u32 from)
        {
        u32 j = from;
        while (j < toks.count() && Preprocessor._isSpaceToken((String*)toks.get(j)))
            j = j + (u32)1;
        return j;
        }

    String* substituteInBody(String* body, Map* rawArgs, Map* expandedArgs)
        {
        Array* toks = tokenizeMacroBody(body);
        Array* out = new Array();
        u32 i = (u32)0;
        u32 n = toks.count();
        bool pendingPaste = false;
        u32 argCount = (rawArgs == 0) ? (u32)0 : rawArgs.count();

        while (i < n)
            {
            String* tok = (String*)toks.get(i);

            if (Preprocessor._isSpaceToken(tok))
                {
                // Whitespace beside `##` is not part of the pasted spelling.
                u32 j = _nextReal(toks, i);
                bool nextIsPaste = (j < n) && Preprocessor._sameCString((String*)toks.get(j), "##");
                if (pendingPaste || nextIsPaste)
                    {
                    i = i + (u32)1;
                    continue;
                    }
                out.add((Object*)tok);
                i = i + (u32)1;
                continue;
                }

            if (Preprocessor._sameCString(tok, "##"))
                {
                pendingPaste = true;
                i = _nextReal(toks, i + (u32)1);
                continue;
                }

            String* piece = (String*)0;
            bool rhsIsVaArgs = false;

            if (Preprocessor._sameCString(tok, "#") && argCount > (u32)0)
                {
                u32 j = _nextReal(toks, i + (u32)1);
                if (j < n)
                    {
                    String* operand = (String*)toks.get(j);
                    String* raw = (String* ?)rawArgs.get((Hashable*)operand);
                    if (raw != 0)
                        {
                        piece = stringizeArgument(raw);
                        i = j + (u32)1;
                        }
                    }
                }

            if (piece == 0)
                {
                String* raw = (rawArgs == 0) ? (String*)0 : (String* ?)rawArgs.get((Hashable*)tok);
                if (raw != 0)
                    {
                    u32 j = _nextReal(toks, i + (u32)1);
                    bool nextIsPaste = (j < n) && Preprocessor._sameCString((String*)toks.get(j), "##");
                    if (pendingPaste || nextIsPaste)
                        piece = raw;
                    else
                        piece = (String*)expandedArgs.get((Hashable*)tok);
                    rhsIsVaArgs = Preprocessor._sameCString(tok, "__VA_ARGS__");
                    }
                else
                    {
                    piece = tok;
                    }
                i = i + (u32)1;
                }

            if (pendingPaste)
                {
                while (out.count() > (u32)0 && Preprocessor._isSpaceToken((String*)out.last()))
                    out.removeLast();

                bool droppedComma = false;
                if (piece.byteLength() == (u32)0 && rhsIsVaArgs && out.count() > (u32)0)
                    {
                    // GNU `, ## __VA_ARGS__` with no variadic tail: the comma goes.
                    String* lastTok = (String*)out.last();
                    if (Preprocessor._sameCString(lastTok, ","))
                        {
                        out.removeLast();
                        droppedComma = true;
                        }
                    }
                if (!droppedComma)
                    {
                    if (out.count() > (u32)0)
                        {
                        String* merged = String.withString((String*)out.last());
                        merged.append(piece);
                        out.removeLast();
                        out.add((Object*)merged);
                        }
                    else if (piece.byteLength() > (u32)0)
                        {
                        out.add((Object*)piece);
                        }
                    }
                pendingPaste = false;
                }
            else
                {
                out.add((Object*)piece);
                }
            }

        String* joined = String.withCString("");
        for (u32 k = (u32)0; k < out.count(); k = k + (u32)1)
            joined.append((String*)out.get(k));
        return joined;
        }

    // ── Small string helpers ─────────────────────────────────────
    // Comparisons against literals that allocate nothing — these run on every
    // token of every macro body.
    static bool _sameCString(String* s, string lit)
        {
        u8* a = s.cString();
        u8* b = (u8*)lit;
        u32 i = (u32)0;
        while (b[i] != (u8)0)
            {
            if (i >= s.byteLength())
                return false;
            if (a[i] != b[i])
                return false;
            i = i + (u32)1;
            }
        return i == s.byteLength();
        }

    static bool _hasCPrefix(String* s, string lit)
        {
        u8* a = s.cString();
        u8* b = (u8*)lit;
        u32 i = (u32)0;
        while (b[i] != (u8)0)
            {
            if (i >= s.byteLength())
                return false;
            if (a[i] != b[i])
                return false;
            i = i + (u32)1;
            }
        return true;
        }
    }
