// Parser.xc — the xtc parser, written in xtc.
// =================================================================
//
// self-hosting M5, third module. A recursive-descent parser with a
// precedence-climbing expression parser, mirroring src/xtc/parser/XTParser.m
// and XTParser+ExprParser.m. It builds the generic Node tree (Node.xc) and the
// tree is compared against the Objective-C parser's by dumping both as
// S-expressions — selfhost/tools/ast-diff.sh, oracle `xtc-fe --dump-ast`.
//
// The precedence table, the associativity rules and the postfix chain are
// copied exactly, because a parser that disagrees about `a - b - c` or about
// whether `x.y(z)` is a method call is not a port of this language.
//
// TYPES are recorded as their SOURCE SPELLING — "u16", "u16@", "u8[10]",
// "weak:Foo@" — not resolved through a type table. Two consequences, both
// deliberate:
//
//   * the parser needs no type table, no forward prescan and no notion of
//     which names exist, which removes a whole layer from this module;
//   * an array size that is not an integer literal cannot be folded here, so
//     `u8 buf[SIZE]` records "u8[SIZE]" where the original records "u8[16]".
//     Sema is where a name becomes a number, and sema is not this module.
//
// Known gaps, listed rather than hidden — each one is a construct the dump
// will disagree on, and the harness reports exactly which files hit them:
//
//   * bound-method types (`action_t^`) record "action_t^" rather than the
//     original's expanded function-type spelling;
//   * placement qualifiers are recorded verbatim in the order written;
//   * a `use` promotion, `#import` handling and library metadata are the
//     preprocessor's business and never reach here.

#import "Foundation.xc"
#import "TokenType.xc"
#import "Token.xc"
#import "Node.xc"

class Parser
{
    Array*  _tokens;        // of Token@
    u32     _pos;
    Array*  _errors;        // of String@
    Array*  _warnings;      // of String@ — "<cat>\t<file:line:col: warning: text>"
                            // The category is a leading field so the driver can
                            // drop a suppressed one without re-parsing the text.
    bool    _fatal;         // a diagnostic the original treats as end-of-parse
    Set*    _typeNames;     // class / struct / enum / protocol / typedef names
    Set*    _structNames;   // just the structs — `va_arg(ap, T@)` needs the split
    Array*  _pendingMembers;// extra declarators from `u8 r,g,b;` in a class body
    bool    _sawVarargForward;  // parseArgList saw a trailing `...` (private:docs/bugs/047)
    Map*    _typedefs;      // typedef name → the spelling it stands for

    // ── Blocks v1 (task #26) — parse-time desugaring, the reference's
    //    XTParser+Blocks.m mirrored. See private:docs/Design/blocks.md §5.
    Array*  _blkScopes;     // of Map: name -> Map{"ty": spelling, "params": Array<Node>?}
    Array*  _blkFrames;     // capture frames for literals being parsed
    Array*  _blkClasses;    // synthesised impl ClassDecl nodes, creation order
    Map*    _blkBases;      // mangled -> Map{"ret": spelling, "params": Array<Node nkParam>}
    Map*    _blkImplBase;   // impl name -> base name
    Map*    _blkFnRet;      // function name -> return spelling
    Set*    _blkIvarNames;  // current class's ivars (capture-error message)
    u32     _blkCounter;
    String* _lastBlkName;
    // The `#package` in force, for bodyless declarations. 0 = default.
    String* _currentPackage;   // side channel: declared name from the type header
    String* _lastBlkBase;
    Array*  _lastBlkParams; // of Node nkParam
    String* _lastBlkRet;
    bool    _lastBlkWb;     // v2: the declaration carried `block:`
    // uxkit/026: the `outlet` qualifier leaves no mark on the type spelling, so
    // the declarator parser reads it off here (the original's _lastTypeIsOutlet).
    bool    _lastTypeIsOutlet;
    Set*    _blkWbImpls;    // impl classes carrying write-back captures

    void init(void)
    {
        _tokens    = (Array*)0;
        _pos       = (u32)0;
        _errors    = new Array();
        _warnings  = new Array();
        _fatal     = false;
        _typeNames = new Set();
        _structNames = new Set();
        _typedefs  = new Map();
        _pendingMembers = new Array();
        _blkScopes  = new Array();
        _blkFrames  = new Array();
        _blkClasses = new Array();
        _blkBases   = new Map();
        _blkImplBase = new Map();
        _blkFnRet   = new Map();
        _blkIvarNames = new Set();
        _blkCounter = (u32)0;
        _lastBlkName = (String*)0;
        _currentPackage = (String*)0;
        _lastBlkBase = (String*)0;
        _lastBlkParams = (Array*)0;
        _lastBlkRet = (String*)0;
        _lastBlkWb = false;
        _lastTypeIsOutlet = false;
        _blkWbImpls = new Set();
    }

    // v2 (task #29): `block:T` — the write-back qualifier. Consumed, never
    // stored on the type; the mark lives on the parser binding alone.
    bool blkWbAhead(void)
    {
        return check((u16)tokIdentifier) && Parser._same(cur().value(), "block")
            && checkAt((u32)1, (u16)tokColon);
    }

    void blkMarkWb(String* name)
    {
        Map* info = blkLookup(name, (u32*)0);
        if (info != 0) info.set((Hashable*)String.withCString("wb"),
                                (Object*)Number.with((u32)1));
    }

    // Does this expression yield a block CARRYING write-back captures?
    bool blkIsWbValue(Node* e)
    {
        if (e == 0) return false;
        if (e.kind() == (u16)nkIdent) {
            Map* info = blkLookup(e.name(), (u32*)0);
            if (info == 0) return false;
            return info.get((Hashable*)String.withCString("holdswb")) != 0;
        }
        if (e.kind() == (u16)nkMethodCall && Parser._same(e.name(), "mk")
            && e.kidCount() > (u32)0 && e.kid((u32)0).kind() == (u16)nkIdent) {
            return _blkWbImpls.contains((Hashable*)e.kid((u32)0).name());
        }
        return false;
    }

    void blkMarkHoldsWb(String* name, Node* init)
    {
        if (!blkIsWbValue(init)) return;
        Map* info = blkLookup(name, (u32*)0);
        if (info != 0) info.set((Hashable*)String.withCString("holdswb"),
                                (Object*)Number.with((u32)1));
    }

    // ── Blocks: scope tracking ───────────────────────────────────
    void blkPushScope(void) { _blkScopes.add((Object*)new Map()); }
    void blkPopScope(void)  { if (_blkScopes.count() > (u32)0) _blkScopes.removeAt(_blkScopes.count() - (u32)1); }

    void blkBind(String* name, String* ty, Array* params)
    {
        if (name == 0 || name.byteLength() == (u32)0) return;
        if (_blkScopes.count() == (u32)0) return;
        Map* info = new Map();
        info.set((Hashable*)String.withCString("ty"),
                 (Object*)(ty != 0 ? ty : String.withCString("auto")));
        if (params != 0) info.set((Hashable*)String.withCString("params"), (Object*)params);
        ((Map*)_blkScopes.get(_blkScopes.count() - (u32)1)).set((Hashable*)name, (Object*)info);
    }

    // Innermost binding, or 0. `outDepth` receives the scope index.
    Map* blkLookup(String* name, u32* outDepth)
    {
        u32 i = _blkScopes.count();
        while (i > (u32)0) {
            i = i - (u32)1;
            Object* o = ((Map*)_blkScopes.get(i)).get((Hashable*)name);
            if (o != 0) { if (outDepth != (u32*)0) *outDepth = i; return (Map*)o; }
        }
        return (Map*)0;
    }

    String* blkTyOf(Map* info)
    {
        if (info == 0) return (String*)0;
        return (String*)info.get((Hashable*)String.withCString("ty"));
    }

    // A binding whose spelling is `Blk$…*` is a block value; its base class
    // is the spelling minus the star.
    String* blkBaseOf(Map* info)
    {
        String* ty = blkTyOf(info);
        if (ty == 0) return (String*)0;
        if (!ty.hasPrefix(String.withCString("Blk$"))) return (String*)0;
        if (ty.byteLength() < (u32)2 || ty.byteAt(ty.byteLength() - (u32)1) != (u8)'*') return (String*)0;
        return ty.substringBytes((u32)0, ty.byteLength() - (u32)1);
    }

    // Identifier-use hook: inside a literal body, a name resolving OUTSIDE
    // the literal's own scopes is a capture, first-use order.
    void blkNoteUse(String* name)
    {
        if (_blkFrames.count() == (u32)0) return;
        Map* frame = (Map*)_blkFrames.get(_blkFrames.count() - (u32)1);
        u32 literalDepth = ((Number*)frame.get((Hashable*)String.withCString("depth"))).asU32();
        u32 foundDepth = (u32)0;
        Map* info = blkLookup(name, &foundDepth);
        if (info == 0) {
            if (Parser._same(name, "self") || _blkIvarNames.contains((Hashable*)name)) {
                _error(String.withFormat("a block cannot capture '%s' (v1 captures locals and parameters only) — copy it into a local first, e.g. `auto me = self;` outside the block", name.cString()));
            }
            return;
        }
        if (foundDepth >= literalDepth) return;
        Array* names = (Array*)frame.get((Hashable*)String.withCString("names"));
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            if (((String*)names.get(i)).equals(name)) return;
        String* ty = blkTyOf(info);
        if (Parser._same(ty, "auto")) {
            _error(String.withFormat("cannot capture '%s': it was declared `auto`, and a capture needs the declared type at this point — give it an explicit type", name.cString()));
            return;
        }
        // v2 (task #29): write-back captures reach the enclosing FRAME, so
        // they do not compose through nested literals.
        if (info.get((Hashable*)String.withCString("wb")) != 0) {
            if (_blkFrames.count() > (u32)1) {
                _error(String.withFormat("a `block:` capture of '%s' inside a nested block is not supported (v2) — write-back reaches the enclosing FRAME, and here the enclosing scope is itself a block", name.cString()));
                return;
            }
            ((Array*)frame.get((Hashable*)String.withCString("wbnames"))).add((Object*)name);
        }
        names.add((Object*)name);
        ((Map*)frame.get((Hashable*)String.withCString("types"))).set((Hashable*)name, (Object*)ty);
    }

    // ── Blocks: the gate + the type header ───────────────────────
    bool blkAhead(void)
    {
        if (!check((u16)tokIdentifier)) return false;
        if (!Parser._same(cur().value(), "block")) return false;
        Token* t1 = peek((u32)1);
        bool t1Type = isTypeKeywordToken(t1.type()) || isTypeName(t1.value());
        if (t1Type) return true;
        if (t1.type() != (u16)tokIdentifier) return false;
        Token* t2 = peek((u32)2);
        // `block t[2] u32(u32)` — the array declarator sits between the name
        // and the signature. private:docs/bugs/074.
        if (t2.type() == (u16)tokLBracket) return true;
        return isTypeKeywordToken(t2.type()) || isTypeName(t2.value());
    }

    // `callback` — the named spelling of a bound method (0.5). Contextual, and
    // as narrow as blkAhead for the same reason: a program already using
    // `callback` as an ordinary identifier must keep working.
    bool cbAhead(void)
    {
        if (!check((u16)tokIdentifier)) return false;
        if (!Parser._same(cur().value(), "callback")) return false;
        Token* t1 = peek((u32)1);
        bool t1Type = isTypeKeywordToken(t1.type()) || isTypeName(t1.value());
        if (t1Type) return true;
        if (t1.type() != (u16)tokIdentifier) return false;
        Token* t2 = peek((u32)2);
        // `callback tbl[2] i32(i32)` — see blkAhead. private:docs/bugs/074.
        if (t2.type() == (u16)tokLBracket) return true;
        return isTypeKeywordToken(t2.type()) || isTypeName(t2.value());
    }

    // `callback [name] RET ( params )` -> the interned `$bound_<signature>`
    // spelling, which is EXACTLY what `sig^` produces. The two spellings are
    // one type; the original proves it by interning on the same name, and this
    // must agree character for character or the differentials diverge.
    //
    // The signature is spelled the way a function TYPEDEF is spelled here —
    // return type, '(', comma-separated parameter types, ')' — because that is
    // what XTFunctionType's display name is.
    String* cbParseHeader(void)
    {
        advance();                                  // consume `callback`
        _lastBlkName = (String*)0;
        String* declName = (String*)0;
        if (check((u16)tokIdentifier) && !isTypeName(cur().value())
            && !isTypeKeywordToken(cur().type())) {
            declName = cur().value();
            advance();
        }
        // `callback tbl[2] i32(i32 n)` — an ARRAY of callbacks. The suffix is
        // held until the signature is built, then appended to the spelling,
        // because the element type is what the header is still parsing.
        String* arrSuffix = (String*)0;
        if (declName != 0 && match((u16)tokLBracket)) {
            arrSuffix = String.withCString("[");
            if (!check((u16)tokRBracket)) appendArraySize(arrSuffix);
            expect((u16)tokRBracket);
            arrSuffix.appendByte((u8)']');
        }
        String* ret = parseTypeSpelling();
        String* sig = String.withString(ret);
        expect((u16)tokLParen);
        sig.appendByte((u8)'(');
        bool first = true;
        while (!check((u16)tokRParen) && !check((u16)tokEOF)) {
            if (check((u16)tokVoid) && checkAt((u32)1, (u16)tokRParen)) { advance(); break; }
            // A trailing `...` — a VARIADIC callback (`callback void(u8* a0, ...)`).
            // A callback is erased to a 2-word bound PAIR whatever its signature,
            // and the xc side only stores/forwards the handle, so the marker adds
            // nothing to the stored type: it types like its non-variadic prefix.
            // Consume it and stop (`...` is always last) — WITHOUT it the loop hit
            // parseTypeSpelling on `...`, which errored and left the whole
            // enclosing declaration silently dropped. Mirrors the reference.
            if (match((u16)tokEllipsis)) break;
            if (!first) sig.appendByte((u8)',');
            first = false;
            sig.append(parseTypeSpelling());
            if (check((u16)tokIdentifier)) advance();       // an optional name
            if (!match((u16)tokComma)) break;
        }
        expect((u16)tokRParen);
        sig.appendByte((u8)')');
        String* out = String.withCString("$bound_");
        out.append(sig);
        if (arrSuffix != 0) out.append(arrSuffix);
        _lastBlkName = declName;
        return out;
    }

    String* blkMangleFragment(String* sp)
    {
        String* s = sp.replacing(String.withCString("*"), String.withCString("$P"));
        s = s.replacing(String.withCString("@"), String.withCString("$P"));
        s = s.replacing(String.withCString(" "), String.withCString(""));
        s = s.replacing(String.withCString(":"), String.withCString("$q"));
        return s;
    }

    // `block [name] RET ( params )` — returns the variable TYPE spelling
    // (`Blk$…*`), stashing name / params / ret / base for the caller.
    // A COMMITTED type position inside a block header: the original routes
    // these through parseType, which errors on a name its prescan never
    // registered and falls back to u8 (keeping the pointer suffix) so later
    // errors still surface. Mirror both halves or an error file's dumps
    // diverge (platform_neutral.xc under the preludeless dump modes).
    String* blkTypeSpellingChecked(void)
    {
        bool unknown = check((u16)tokIdentifier) && !isTypeName(cur().value());
        String* uname = unknown ? cur().value() : (String*)0;
        if (unknown)
            _error(String.withFormat("Unknown type '%s'", uname.cString()));
        String* t = parseTypeSpelling();
        if (unknown) {
            String* fixed = String.withCString("u8");
            fixed.append(t.substringFromByte(uname.byteLength()));
            return fixed;
        }
        return t;
    }

    String* blkParseHeader(void)
    {
        advance();                                   // `block`
        _lastBlkName = (String*)0;
        _lastBlkBase = (String*)0;
        _lastBlkParams = (Array*)0;
        _lastBlkRet = (String*)0;

        // Held locally: the nested parseTypeSpelling calls clear the stash.
        String* declName = (String*)0;
        if (check((u16)tokIdentifier) && !isTypeName(cur().value())
            && !isTypeKeywordToken(curType())) {
            declName = advance().value();
        }
        // `block t[2] u32(u32 n)` — an ARRAY of blocks, held until the element
        // spelling is built. Same addition as the callback header's, made at
        // the same time: the two headers are one grammar. private:docs/bugs/074.
        String* arrSuffix = (String*)0;
        if (declName != 0 && match((u16)tokLBracket)) {
            arrSuffix = String.withCString("[");
            if (!check((u16)tokRBracket)) appendArraySize(arrSuffix);
            expect((u16)tokRBracket);
            arrSuffix.appendByte((u8)']');
        }
        String* ret = (String*)0;
        if (check((u16)tokVoid) && checkAt((u32)1, (u16)tokLParen)) {
            advance();
            ret = String.withCString("void");
        } else {
            ret = blkTypeSpellingChecked();
        }
        expect((u16)tokLParen);
        Array* params = new Array();
        if (check((u16)tokVoid) && checkAt((u32)1, (u16)tokRParen)) {
            advance();
        } else if (!check((u16)tokRParen)) {
            u32 idx = (u32)0;
            while (!check((u16)tokRParen) && !check((u16)tokEOF)) {
                String* pt = blkTypeSpellingChecked();
                String* pn = String.withCString("p");
                pn.append(String.withU32(idx));
                if (check((u16)tokIdentifier)) pn = advance().value();
                Node* p = mkNamed((u16)nkParam, pn);
                p.setOp(pt);
                params.add((Object*)p);
                idx = idx + (u32)1;
                if (!match((u16)tokComma)) break;
            }
        }
        expect((u16)tokRParen);

        String* mangled = String.withCString("Blk");
        mangled.appendByte((u8)'$');
        mangled.append(blkMangleFragment(ret));
        for (u32 i = (u32)0; i < params.count(); i = i + (u32)1) {
            mangled.appendByte((u8)'$');
            mangled.append(blkMangleFragment(((Node*)params.get(i)).op()));
        }
        _typeNames.add((Hashable*)String.withString(mangled));
        if (_blkBases.get((Hashable*)mangled) == 0) {
            Map* sig = new Map();
            sig.set((Hashable*)String.withCString("ret"), (Object*)ret);
            sig.set((Hashable*)String.withCString("params"), (Object*)params);
            _blkBases.set((Hashable*)String.withString(mangled), (Object*)sig);
        }
        _lastBlkName = declName;
        _lastBlkBase = mangled;
        _lastBlkParams = params;
        _lastBlkRet = ret;
        String* out = String.withString(mangled);
        out.appendByte((u8)'*');
        if (arrSuffix != 0) out.append(arrSuffix);
        return out;
    }

    // ── Blocks: synthesis ────────────────────────────────────────
    // Positional copies of a param list (the base class shares one signature
    // across every literal, so the user's names cannot appear there).
    Array* blkPositionalParams(Array* declared)
    {
        Array* out = new Array();
        for (u32 i = (u32)0; i < declared.count(); i = i + (u32)1) {
            String* pn = String.withCString("p");
            pn.append(String.withU32(i));
            Node* p = mkNamed((u16)nkParam, pn);
            p.setOp(((Node*)declared.get(i)).op());
            out.add((Object*)p);
        }
        return out;
    }

    // `{ return (RET)0; }` — the base placeholder; void gets an empty block.
    Node* blkDefaultBody(String* ret)
    {
        Node* b = mk((u16)nkBlock);
        if (Parser._same(ret, "void")) return b;
        Node* zero = mk((u16)nkInt);
        zero.setNum((i64)0);
        Node* cast = mkNamed((u16)nkCast, ret);
        cast.add(zero);
        Node* r = mk((u16)nkReturn);
        r.add(cast);
        b.add(r);
        return b;
    }

    // Append the per-signature base classes (name order) and the impl
    // classes (creation order) to the program — called from parse()'s end.
    void blkAppendSynthesised(Node* program)
    {
        Array* names = _blkBases.allKeys();
        // insertion-sort the key list: the emitted order must be a function
        // of the program text alone, and Map iteration order is not.
        for (u32 i = (u32)1; i < names.count(); i = i + (u32)1) {
            u32 j = i;
            while (j > (u32)0
                   && ((String*)names.get(j - (u32)1)).compare((String*)names.get(j)) > (i8)0) {
                Object* tmp = names.get(j);
                names.set(j, names.get(j - (u32)1));
                names.set(j - (u32)1, tmp);
                j = j - (u32)1;
            }
        }
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1) {
            String* name = (String*)names.get(i);
            Map* sig = (Map*)_blkBases.get((Hashable*)name);
            String* ret = (String*)sig.get((Hashable*)String.withCString("ret"));
            Array* declared = (Array*)sig.get((Hashable*)String.withCString("params"));
            Node* invoke = mkNamed((u16)nkMethodDecl, String.withCString("invoke"));
            invoke.setOp(ret);
            Array* pp = blkPositionalParams(declared);
            for (u32 k = (u32)0; k < pp.count(); k = k + (u32)1) invoke.add((Node*)pp.get(k));
            invoke.add(blkDefaultBody(ret));
            Node* cls = mkNamed((u16)nkClassDecl, name);
            cls.add(invoke);
            program.add(cls);
        }
        for (u32 i = (u32)0; i < _blkClasses.count(); i = i + (u32)1)
            program.add((Node*)_blkClasses.get(i));
    }

    // Parse a literal's body (cursor on `{`) and synthesise its impl class.
    // Returns the replacement expression: `BlkImpl$N.mk(captures…)`.
    Node* blkParseLiteralBody(String* baseName, String* ret, Array* params, String* selfName)
    {
        u32 counter = _blkCounter;
        _blkCounter = _blkCounter + (u32)1;
        String* implName = String.withCString("BlkImpl$");
        implName.append(String.withU32(counter));
        _typeNames.add((Hashable*)String.withString(implName));
        _blkImplBase.set((Hashable*)String.withString(implName), (Object*)baseName);

        Map* frame = new Map();
        frame.set((Hashable*)String.withCString("depth"), (Object*)Number.with(_blkScopes.count()));
        frame.set((Hashable*)String.withCString("names"), (Object*)new Array());
        frame.set((Hashable*)String.withCString("types"), (Object*)new Map());
        frame.set((Hashable*)String.withCString("wbnames"), (Object*)new Array());
        if (selfName != 0)
            frame.set((Hashable*)String.withCString("selfName"), (Object*)selfName);
        _blkFrames.add((Object*)frame);
        blkPushScope();
        for (u32 i = (u32)0; i < params.count(); i = i + (u32)1) {
            Node* p = (Node*)params.get(i);
            blkBind(p.name(), p.op(), (Array*)0);
        }

        Node* body = parseBlock();

        blkPopScope();
        _blkFrames.removeAt(_blkFrames.count() - (u32)1);

        Array* capNames = (Array*)frame.get((Hashable*)String.withCString("names"));
        Map* capTypes = (Map*)frame.get((Hashable*)String.withCString("types"));
        Array* wbAll = (Array*)frame.get((Hashable*)String.withCString("wbnames"));
        // capture order, like the reference
        Array* wbNames = new Array();
        for (u32 i = (u32)0; i < capNames.count(); i = i + (u32)1) {
            String* cn = (String*)capNames.get(i);
            for (u32 j = (u32)0; j < wbAll.count(); j = j + (u32)1)
                if (((String*)wbAll.get(j)).equals(cn)) { wbNames.add((Object*)cn); break; }
        }

        Node* cls = mkNamed((u16)nkClassDecl, implName);
        cls.setOp(baseName);
        for (u32 i = (u32)0; i < capNames.count(); i = i + (u32)1) {
            String* cn = (String*)capNames.get(i);
            Node* iv = mkNamed((u16)nkVariableDecl, cn);
            iv.setOp((String*)capTypes.get((Hashable*)cn));
            cls.add(iv);
        }
        for (u32 i = (u32)0; i < wbNames.count(); i = i + (u32)1) {
            String* wn = (String*)wbNames.get(i);
            String* ivn = String.withString(wn);
            ivn.appendCString("$wb");
            Node* iv = mkNamed((u16)nkVariableDecl, ivn);
            String* pty = String.withString((String*)capTypes.get((Hashable*)wn));
            pty.appendByte((u8)'*');
            iv.setOp(pty);
            cls.add(iv);
        }
        if (capNames.count() > (u32)0) {
            Node* setM = mkNamed((u16)nkMethodDecl, String.withCString("_set"));
            setM.setOp(String.withCString("void"));
            Node* setBody = mk((u16)nkBlock);
            for (u32 i = (u32)0; i < capNames.count(); i = i + (u32)1) {
                String* cn = (String*)capNames.get(i);
                String* vn = String.withCString("v");
                vn.append(String.withU32(i));
                Node* p = mkNamed((u16)nkParam, vn);
                p.setOp((String*)capTypes.get((Hashable*)cn));
                setM.add(p);
                Node* a = mk((u16)nkAssign);
                a.setOp(String.withCString("="));
                a.add(mkNamed((u16)nkIdent, cn));
                a.add(mkNamed((u16)nkIdent, String.withString(vn)));
                Node* es = mk((u16)nkExprStatement);
                es.add(a);
                setBody.add(es);
            }
            for (u32 i = (u32)0; i < wbNames.count(); i = i + (u32)1) {
                String* wn = (String*)wbNames.get(i);
                String* pn = String.withCString("w");
                pn.append(String.withU32(i));
                Node* p = mkNamed((u16)nkParam, String.withString(pn));
                String* pty = String.withString((String*)capTypes.get((Hashable*)wn));
                pty.appendByte((u8)'*');
                p.setOp(pty);
                setM.add(p);
                String* ivn = String.withString(wn);
                ivn.appendCString("$wb");
                Node* a = mk((u16)nkAssign);
                a.setOp(String.withCString("="));
                a.add(mkNamed((u16)nkIdent, ivn));
                a.add(mkNamed((u16)nkIdent, String.withString(pn)));
                Node* es = mk((u16)nkExprStatement);
                es.add(a);
                setBody.add(es);
            }
            setM.add(setBody);
            cls.add(setM);
        }
        Node* invoke = mkNamed((u16)nkMethodDecl, String.withCString("invoke"));
        invoke.setOp(ret);
        for (u32 i = (u32)0; i < params.count(); i = i + (u32)1)
            invoke.add((Node*)params.get(i));
        Node* invokeBody = body;
        if (wbNames.count() > (u32)0) {
            // ONE synthesised defer stores every working copy back through
            // its pointer — on every exit, the throw path included (§4).
            Node* dBody = mk((u16)nkBlock);
            for (u32 i = (u32)0; i < wbNames.count(); i = i + (u32)1) {
                String* wn = (String*)wbNames.get(i);
                String* ivn = String.withString(wn);
                ivn.appendCString("$wb");
                Node* deref = mkNamed((u16)nkUnary, String.withCString("*"));
                deref.setOp(String.withCString("*"));
                deref.add(mkNamed((u16)nkIdent, ivn));
                Node* a = mk((u16)nkAssign);
                a.setOp(String.withCString("="));
                a.add(deref);
                a.add(mkNamed((u16)nkIdent, wn));
                Node* es = mk((u16)nkExprStatement);
                es.add(a);
                dBody.add(es);
            }
            Node* d = mk((u16)nkDefer);
            d.add(dBody);
            Node* wrapped = mk((u16)nkBlock);
            wrapped.add(d);
            for (u32 i = (u32)0; i < body.kidCount(); i = i + (u32)1)
                wrapped.add(body.kid(i));
            invokeBody = wrapped;
        }
        invoke.add(invokeBody);
        cls.add(invoke);
        {
            Node* mk = mkNamed((u16)nkMethodDecl, String.withCString("mk"));
            String* basePtr = String.withString(baseName);
            basePtr.appendByte((u8)'*');
            mk.setOp(basePtr);
            mk.addFlag((u32)NF_STATIC);
            Array* mkArgs = new Array();
            for (u32 i = (u32)0; i < capNames.count(); i = i + (u32)1) {
                String* cn = (String*)capNames.get(i);
                String* an = String.withCString("c");
                an.append(String.withU32(i));
                Node* p = mkNamed((u16)nkParam, String.withString(an));
                p.setOp((String*)capTypes.get((Hashable*)cn));
                mk.add(p);
                mkArgs.add((Object*)mkNamed((u16)nkIdent, String.withString(an)));
            }
            for (u32 i = (u32)0; i < wbNames.count(); i = i + (u32)1) {
                String* wn = (String*)wbNames.get(i);
                String* an = String.withCString("p");
                an.append(String.withU32(i));
                Node* p = mkNamed((u16)nkParam, String.withString(an));
                String* pty = String.withString((String*)capTypes.get((Hashable*)wn));
                pty.appendByte((u8)'*');
                p.setOp(pty);
                mk.add(p);
                mkArgs.add((Object*)mkNamed((u16)nkIdent, String.withString(an)));
            }
            Node* mkBody = mk((u16)nkBlock);
            Node* t = mkNamed((u16)nkVariableDecl, String.withCString("t"));
            String* implPtr = String.withString(implName);
            implPtr.appendByte((u8)'*');
            t.setOp(implPtr);
            Node* newE = mkNamed((u16)nkNew, implName);
            newE.setNum((i64)0);
            t.add(newE);
            mkBody.add(t);
            if (capNames.count() > (u32)0) {
                Node* call = mkNamed((u16)nkMethodCall, String.withCString("_set"));
                call.add(mkNamed((u16)nkIdent, String.withCString("t")));
                for (u32 i = (u32)0; i < mkArgs.count(); i = i + (u32)1)
                    call.add((Node*)mkArgs.get(i));
                call.setNum((i64)mkArgs.count());
                Node* es = mk((u16)nkExprStatement);
                es.add(call);
                mkBody.add(es);
            }
            Node* r = mk((u16)nkReturn);
            r.add(mkNamed((u16)nkIdent, String.withCString("t")));
            mkBody.add(r);
            mk.add(mkBody);
            cls.add(mk);
        }
        _blkClasses.add((Object*)cls);

        // Replacement: BlkImpl$N.mk(captures) — the capture-arg USES must
        // register with an enclosing literal frame too.
        Node* mkCall = mkNamed((u16)nkMethodCall, String.withCString("mk"));
        mkCall.add(mkNamed((u16)nkIdent, String.withString(implName)));
        for (u32 i = (u32)0; i < capNames.count(); i = i + (u32)1) {
            String* cn = (String*)capNames.get(i);
            mkCall.add(mkNamed((u16)nkIdent, cn));
            blkNoteUse(cn);
        }
        for (u32 i = (u32)0; i < wbNames.count(); i = i + (u32)1) {
            String* wn = (String*)wbNames.get(i);
            Node* addr = mkNamed((u16)nkUnary, String.withCString("&"));
            addr.setOp(String.withCString("&"));
            addr.add(mkNamed((u16)nkIdent, wn));
            mkCall.add(addr);
        }
        mkCall.setNum((i64)(capNames.count() + wbNames.count()));
        if (wbNames.count() > (u32)0)
            _blkWbImpls.add((Hashable*)String.withString(implName));
        return mkCall;
    }

    // A full literal in expression position: `block [name] RET(params) { … }`.
    Node* blkParseLiteralExpression(void)
    {
        // The spelling is not needed here — the header's job is the stash.
        // (During blocks v1 an assigned-but-unused local HERE exposed a
        // one-instruction ref-vs-port m68k homing divergence — task #28.
        // Not reproducible since v2 reshaped this function: the trigger
        // restored in place and a 60-case pressure sweep both come back
        // byte-identical. If it re-fires, all-diff is what catches it.)
        blkParseHeader();
        String* name = _lastBlkName;
        String* base = _lastBlkBase;
        Array* params = _lastBlkParams;
        String* ret = _lastBlkRet;
        if (!checkBlockOpen()) {
            _error(String.withCString("expected '{' to open the block's body (a bare block type is not an expression)"));
            return (Node*)0;
        }
        return blkParseLiteralBody(base, ret, params, name);
    }

    // `auto e = <block expr>;` — propagate the binding from the initialiser.
    void blkBindAuto(String* name, Node* init)
    {
        if (init == 0 || name == 0 || _blkScopes.count() == (u32)0) return;
        if (init.kind() == (u16)nkIdent) {
            Map* src = blkLookup(init.name(), (u32*)0);
            if (src == 0 || blkBaseOf(src) == 0) return;
            ((Map*)_blkScopes.get(_blkScopes.count() - (u32)1)).set((Hashable*)name, (Object*)src);
            return;
        }
        String* base = (String*)0;
        Array* params = (Array*)0;
        if (init.kind() == (u16)nkCall) {
            String* rt = (String*)_blkFnRet.get((Hashable*)init.name());
            if (rt == 0 || !rt.hasPrefix(String.withCString("Blk$"))) return;
            if (rt.byteAt(rt.byteLength() - (u32)1) != (u8)'*') return;
            base = rt.substringBytes((u32)0, rt.byteLength() - (u32)1);
        } else if (init.kind() == (u16)nkMethodCall && Parser._same(init.name(), "mk")
                   && init.kidCount() > (u32)0 && init.kid((u32)0).kind() == (u16)nkIdent) {
            base = (String*)_blkImplBase.get((Hashable*)init.kid((u32)0).name());
        }
        if (base == 0) return;
        Map* sig = (Map*)_blkBases.get((Hashable*)base);
        if (sig != 0) params = (Array*)sig.get((Hashable*)String.withCString("params"));
        Map* info = new Map();
        String* ty = String.withString(base);
        ty.appendByte((u8)'*');
        info.set((Hashable*)String.withCString("ty"), (Object*)ty);
        if (params != 0) info.set((Hashable*)String.withCString("params"), (Object*)params);
        ((Map*)_blkScopes.get(_blkScopes.count() - (u32)1)).set((Hashable*)name, (Object*)info);
    }

    static Parser* with(Array* tokens)
    {
        Parser* p = new Parser();
        p._tokens = tokens;
        p.prescanTypeNames();
        return p;
    }

    // Every type NAME the unit declares, collected before parsing starts —
    // the same forward pre-scan the original does. Without it `(Colour)99`
    // reads as a parenthesised identifier rather than a cast, and a variable
    // declared with a user type reads as an expression statement.
    void prescanTypeNames(void)
    {
        // `Object` is the built-in root class: no unit declares it, but
        // `(Object@)0` is a cast in every one of them.
        _typeNames.add((Hashable*)String.withCString("Object"));

        u32 i = (u32)0;
        while (i + (u32)1 < _tokens.count()) {
            Token* t = (Token*)_tokens.get(i);
            u16 ty = t.type();
            if (ty == (u16)tokClass || ty == (u16)tokStruct
                || ty == (u16)tokEnum || ty == (u16)tokProtocol) {
                Token* n = (Token*)_tokens.get(i + (u32)1);
                if (n.type() == (u16)tokIdentifier) {
                    _typeNames.add((Hashable*)n.value());
                    if (ty == (u16)tokStruct) _structNames.add((Hashable*)n.value());
                }
            }
            // Typedefs are NOT prescanned — the original registers an alias
            // when the typedef PARSES, so a use before its declaration reads
            // as an expression. That order-sensitivity became visible when
            // the dump modes gained the prelude: dumping a prelude-member
            // file defers its own content past its dependents (the entry-
            // file dedup), and the two parsers disagreed on `cmp1_t^ f`
            // (task #36). parseTypedef registers instead.
            i = i + (u32)1;
        }
    }

    bool isTypeName(String* w)
    {
        if (w == 0) return false;
        return _typeNames.contains((Hashable*)w);
    }

    // Pre-registration for metadata-imported names (xtfe reads .xtc.iface
    // declarations BEFORE the parse, the original's ordering) — task #36.
    void addTypeName(String* w)   { if (w != 0) _typeNames.add((Hashable*)String.withString(w)); }
    void addStructName(String* w) { if (w != 0) _structNames.add((Hashable*)String.withString(w)); }

    Array* errors(void) { return _errors; }
    Array* warnings(void) { return _warnings; }

    // A WARNING from the parser, positioned and CATEGORISED. The parser had no
    // warning channel at all — only `_errors` — so anything it noticed but did
    // not want to reject had nowhere to go, and the only honest option left was
    // to say nothing. That is how an unknown loop annotation came to be
    // swallowed silently while the reference warned about it (bug 211).
    //
    // The category is carried as a leading tab-separated field, matching the
    // reference's XTWarningCategory names, so `-Wno-<category>` can drop it in
    // the driver without having to re-parse the message.
    void warnAt(String* cat, String* msg, Token* tok)
    {
        String* out = String.withString(cat);
        out.appendByte((u8)'\t');
        if (tok != (Token*)0 && tok.line() != (u32)0) {
            out.append(tok.file() != (String*)0 ? tok.file() : String.withCString("?"));
            out.appendByte((u8)':');
            out.append(String.withU32(tok.line()));
            out.appendByte((u8)':');
            out.append(String.withU32(tok.col()));
            out.appendCString(": ");
        }
        out.appendCString("warning: ");
        out.append(msg);
        _warnings.add((Object*)out);
    }

    // The original's emitError: ALWAYS sets the diagnostic engine's fatal
    // flag, and its decl loop stops on it — so after any parse error the
    // reference dumps a TRUNCATED program (everything before the error,
    // plus the synthesised block classes). Mirror that exactly: an error
    // here is end-of-parse, not a note. blocks_wb_escape.xc is the fixture
    // that caught the divergence (task #29 follow-up).
    // Every parser diagnostic carries `file:line:col: error: ` from the token
    // it stopped at — the shape the reference prints and an editor can jump
    // to. Until task #78 the shipped compiler said `line 4: unexpected token
    // 11 (wanted 85)`: no column, the NEXT token's line, and raw enum numbers.
    void _error(String* msg)
    {
        String* out = String.withCString("");
        Token* t = cur();
        if (t != (Token*)0 && t.line() != (u32)0) {
            if (t.file() != (String*)0) { out.append(t.file()); } else { out.appendCString("?"); }
            out.appendByte((u8)':');
            out.append(String.withU32(t.line()));
            out.appendByte((u8)':');
            out.append(String.withU32(t.col()));
            out.appendCString(": ");
        }
        out.appendCString("error: ");
        out.append(msg);
        _errors.add((Object*)out);
        _fatal = true;
    }

    // The token's own text when it has one (an identifier, a literal, an
    // operator), else its kind's name — so `Expected ';' but found 'return'`.
    String* tokenText(Token* t)
    {
        if (t == (Token*)0) return String.withCString("EOF");
        if (t.value() != (String*)0 && t.value().byteLength() > (u32)0) return t.value();
        return String.withCString(TokenNames.of(t.type()));
    }

    // A declarator's array size that is not an integer literal. The original
    // rejects it — `u8 buf[someUndeclaredName];` used to compile as zero-byte
    // storage — and its diagnostic engine treats the error as FATAL, so the
    // top-level loop stops and the program it returns holds only what was
    // parsed before the bad declaration. Matching that is the difference
    // between the two ASTs on tests/fixtures/negative/array_size_undefined.xc:
    // this parser used to sail on and parse the `main` that follows.
    // Fold a parse-time constant integer expression — the mirror of the
    // original's foldIntConstExpr. Literals through the arithmetic and bit
    // operators and unary -/~; identifiers do NOT fold (the parser holds no
    // symbol values — a macro-built bound arrives as pure literals after
    // preprocessing). Returns false when the tree does not fold; a folded
    // division by zero refuses rather than trapping.
    bool foldIntConst(Node* e, i64* v)
    {
        if (e == 0) return false;
        if (e.kind() == (u16)nkInt) { *v = (i64)e.num(); return true; }
        if (e.kind() == (u16)nkUnary) {
            i64 a = (i64)0;
            if (!foldIntConst(e.kid((u32)0), &a)) return false;
            if (Parser._same(e.op(), "-")) { *v = (i64)0 - a; return true; }
            if (Parser._same(e.op(), "~")) { *v = ~a; return true; }
            return false;
        }
        if (e.kind() == (u16)nkBinary) {
            i64 a = (i64)0;
            i64 b = (i64)0;
            if (!foldIntConst(e.kid((u32)0), &a)) return false;
            if (!foldIntConst(e.kid((u32)1), &b)) return false;
            if (Parser._same(e.op(), "+"))  { *v = a + b; return true; }
            if (Parser._same(e.op(), "-"))  { *v = a - b; return true; }
            if (Parser._same(e.op(), "*"))  { *v = a * b; return true; }
            if (Parser._same(e.op(), "/"))  { if (b == (i64)0) return false; *v = a / b; return true; }
            if (Parser._same(e.op(), "%"))  { if (b == (i64)0) return false; *v = a % b; return true; }
            if (Parser._same(e.op(), "<<")) { *v = (i64)((u64)a << ((u64)b & (u64)63)); return true; }
            if (Parser._same(e.op(), ">>")) { *v = (i64)((u64)a >> ((u64)b & (u64)63)); return true; }
            if (Parser._same(e.op(), "&"))  { *v = a & b; return true; }
            if (Parser._same(e.op(), "|"))  { *v = a | b; return true; }
            if (Parser._same(e.op(), "^"))  { *v = a ^ b; return true; }
            return false;
        }
        return false;
    }

    // The array-size position: parse the expression, fold it, append the
    // folded count to `ty` — or diagnose. One helper so every declarator
    // site (ivar, param, local, global) folds identically.
    void appendArraySize(String* ty)
    {
        i64 v = (i64)0;
        Node* sz = parseExpression();
        if (foldIntConst(sz, &v) && v >= (i64)0)
            ty.append(String.withU32((u32)v));
        else
            _badArraySize(sz);
    }

    // The message says FOLD, not "literal". It used to say "must be a
    // compile-time integer literal", which stopped being true when the folder
    // arrived: `u8 buf[EVSZ * MAXEV]` is not a literal and is perfectly legal.
    // A diagnostic that describes a rule the compiler no longer enforces sends
    // the reader to rewrite working code.
    //
    // An identifier that did not fold is named, because that is the case this
    // fires on in practice — a typo or a missing #define — and naming it turns
    // "why is this rejected" into "ah, that macro is not defined here".
    void _badArraySize(Node* sz)
    {
        String* m = String.withCString(
            "Array size must constant-fold to a non-negative integer");
        if (sz != (Node*)0 && sz.kind() == (u16)nkIdent && sz.name() != (String*)0) {
            m.appendCString(" ('");
            m.append(sz.name());
            m.appendCString("' does not fold — check for typos or a missing #define)");
        }
        _error(m);
        _fatal = true;
    }

    // ── Token access ─────────────────────────────────────────────
    // A node with the CURRENT token's position. Only eleven of sixty-one node
    // constructions set one by hand, so most of the tree carried no position
    // at all: the driver's diagnostics printed a file and nothing else, and
    // -fbounds-check could not name the site of a failed check. Taking it from
    // the token the parser is looking at is right for every node that starts
    // where it is being built.
    Node* mk(u16 kind)
        {
        Node* n = Node.with(kind);
        Token* t = cur();
        if (t != 0)
            n.setPos(t.fileId(), t.line(), t.col());
        return n;
        }

    // The named form, same reason. Identifier nodes go through this one, and
    // an identifier is what most diagnostics point at.
    Node* mkNamed(u16 kind, String* name)
        {
        Node* n = Node.withName(kind, name);
        // The token JUST CONSUMED, not the one the parser is looking at: a
        // named node is built after taking its own token, so `cur()` is
        // already the token after it and the position landed a word to the
        // right — `undefinedThing` reported at the semicolon.
        Token* t = _pos > (u32)0 ? (Token*)_tokens.get(_pos - (u32)1) : cur();
        if (t != 0)
            n.setPos(t.fileId(), t.line(), t.col());
        return n;
        }

    Token* cur(void)
    {
        if (_pos >= _tokens.count()) return (Token*)_tokens.last();
        return (Token*)_tokens.get(_pos);
    }

    Token* peek(u32 offset)
    {
        u32 i = _pos + offset;
        if (i >= _tokens.count()) return (Token*)_tokens.last();
        return (Token*)_tokens.get(i);
    }

    u16 curType(void)          { return cur().type(); }
    bool checkAt(u32 off, u16 t) { return peek(off).type() == t; }

    bool check(u16 t)
    {
        return curType() == t;
    }

    Token* advance(void)
    {
        Token* t = cur();
        if (_pos < _tokens.count() - (u32)1) _pos = _pos + (u32)1;
        return t;
    }

    bool match(u16 t)
    {
        if (!check(t)) return false;
        advance();
        return true;
    }

    // Consume `t` or record an error. The parser keeps going either way: one
    // missing semicolon should not turn into a hundred cascading complaints.
    Token* expect(u16 t)
    {
        if (check(t)) return advance();
        // The reference's words exactly: `Expected ';' but found 'return'`.
        String* msg = String.withCString("Expected '");
        msg.appendCString(TokenNames.of(t));
        msg.appendCString("' but found '");
        msg.append(tokenText(cur()));
        msg.appendByte((u8)'\'');
        _error(msg);
        return (Token*)0;
    }

    // ── Program ──────────────────────────────────────────────────
    Node* parse(void)
    {
        Node* program = mk((u16)nkProgram);
        while (!check((u16)tokEOF) && !_fatal) {
            u32 before = _pos;
            Node* decl = parseTopLevel();
            if (decl != 0) program.add(decl);
            // Never spin: if a production consumed nothing, step over the
            // token so a malformed file still terminates.
            if (_pos == before) advance();
        }
        blkAppendSynthesised(program);               // task #26
        return program;
    }

    Node* parseTopLevel(void)
    {
        // `package <ns>;` — the preprocessor's rewrite of `#package <ns>`, the
        // host import namespace for subsequent BODYLESS declarations. Not a
        // keyword: it arrives as two identifiers and a semicolon, so it is
        // recognised by shape, exactly as the original does.
        if (check((u16)tokIdentifier) && Parser._same(cur().value(), "package")
            && checkAt((u32)1, (u16)tokIdentifier)
            && checkAt((u32)2, (u16)tokSemicolon)) {
            advance();
            String* ns = advance().value();
            advance();                              // `;`
            _currentPackage = Parser._same(ns, "__none") ? (String*)0 : ns;
            return (Node*)0;
        }
        if (check((u16)tokUse))      return parseUseDecl();
        if (check((u16)tokTypedef))  return parseTypedef();
        if (check((u16)tokStruct))   return parseStruct(true);
        if (check((u16)tokEnum))     return parseEnum();
        if (check((u16)tokClass))    return parseClass();
        if (check((u16)tokProtocol)) return parseProtocol();
        if (check((u16)tokSemicolon)) { advance(); return (Node*)0; }
        return parseFunctionOrVar();
    }

    Node* parseUseDecl(void)
    {
        advance();                                  // `use`
        Token* name = expect((u16)tokIdentifier);
        expect((u16)tokSemicolon);
        if (name == 0) return (Node*)0;
        return mkNamed((u16)nkUseDecl, name.value());
    }

    // ── Types ────────────────────────────────────────────────────
    // A type is recorded as the spelling the source used, assembled here in the
    // same order XTType.displayName assembles it: qualifiers, base, pointer
    // stars, array suffix.
    bool isTypeKeywordToken(u16 t)
    {
        return t == (u16)tokI8  || t == (u16)tokU8  || t == (u16)tokI16
            || t == (u16)tokU16 || t == (u16)tokI32 || t == (u16)tokU32
            || t == (u16)tokI64 || t == (u16)tokU64
            || t == (u16)tokBool  || t == (u16)tokFloat || t == (u16)tokDouble
            || t == (u16)tokVoid  || t == (u16)tokPointer || t == (u16)tokString
            || t == (u16)tokAuto;
    }

    bool isQualifierWord(String* w)
    {
        return Parser._same(w, "main") || Parser._same(w, "shadow")
            || Parser._same(w, "banked") || Parser._same(w, "raw")
            || Parser._same(w, "weak") || Parser._same(w, "outlet");
    }

    // Does the current position begin a type? Used to tell a declaration from
    // an expression statement.
    bool looksLikeType(void)
    {
        if (isTypeKeywordToken(curType())) return true;
        if (!check((u16)tokIdentifier)) return false;
        // A declared type name — but only when what FOLLOWS could begin a
        // declarator. A program may name a variable the same as a type, and
        // `a = {…};` is then an assignment, not a declaration. `Stdio.printf(…)`
        // is a static call for the same reason.
        if (isTypeName(cur().value())) {
            u16 nx = peek((u32)1).type();
            if (nx == (u16)tokIdentifier || isPointerSigil(nx) || nx == (u16)tokCaret)
                return true;
            // `Array<String>* a;` — a KNOWN type name followed by `<` starts a
            // typed collection. Gated on isTypeName, so `a < b` between two
            // ordinary variables is still a comparison; a type name is not a
            // value, so there is nothing it could sensibly be compared to.
            if (nx == (u16)tokLess) return true;
        }
        // `Foo bar` / `Foo@ bar` — an identifier followed by another
        // identifier or a pointer star — but ONLY for a KNOWN type name,
        // exactly as the original's type table gates it. The untyped
        // fallback ("any Ident Ident/Ident@/Ident^ shape is a decl") existed
        // to compensate for metadata-imported classes the prescan cannot
        // see; those names are now pre-registered before the parse
        // (xtfe reads the .xtc.iface first — the original's "imported
        // library's types are registered before the parse begins"), and the
        // fallback's looseness had become a real divergence: an unknown
        // `cmp1_t^ f = …` must read as an expression, as the original reads
        // it (task #36).
        // A qualifier run: `weak Foo@ p` / `banked:Foo@ p`.
        u16 n1 = peek((u32)1).type();
        if (isQualifierWord(cur().value())) {
            u16 n2 = (n1 == (u16)tokColon) ? peek((u32)2).type() : n1;
            if (n2 == (u16)tokIdentifier || isTypeKeywordToken(n2)) return true;
        }
        return false;
    }

    String* parseTypeSpelling(void)
    {
        _lastBlkName = (String*)0;                   // no stale stash (task #26)
        if (blkWbAhead()) {                          // v2 (task #29)
            advance(); advance();
            String* inner = parseTypeSpelling();
            _lastBlkWb = true;
            return inner;
        }
        // `weak: callback …` / `weak: block …`. Rejected — a stored callback
        // ALWAYS auto-zeroes, so the qualifier is implied and there is nothing
        // else to ask for — but rejected with a message that SAYS so, instead
        // of reading as an unqualified type named `weak` and reporting
        // "Unknown type 'weak'" followed by two more from the leftover colon.
        // Every field written against the older `weak:act_t^` spelling hits
        // this, so the diagnostic is the whole experience of migrating one.
        if (check((u16)tokIdentifier) && Parser._same(cur().value(), "weak")) {
            u32 j = checkAt((u32)1, (u16)tokColon) ? (u32)2 : (u32)1;
            Token* nx = peek(j);
            if (nx.type() == (u16)tokIdentifier
                && (Parser._same(nx.value(), "callback")
                    || Parser._same(nx.value(), "block"))) {
                String* m = String.withCString("`weak:` is implied on a ");
                m.append(nx.value());
                m.appendCString(" and cannot be written — a stored ");
                m.append(nx.value());
                m.appendCString(" always auto-zeroes when its receiver dies. ");
                m.appendCString("Remove the qualifier.");
                _error(m);
                advance();                                   // `weak`
                if (check((u16)tokColon)) advance();          // `:`
            }
        }
        if (blkAhead()) return blkParseHeader();     // blocks (task #26)
        if (cbAhead())  return cbParseHeader();      // callback (0.5)
        String* out = String.withCString("");
        bool sawWeak = false;
        bool sawOutlet = false;
        String* placement = (String*)0;
        _lastTypeIsOutlet = false;

        // Qualifier run — `weak:`, `banked:`, `outlet` … colons optional. The
        // qualifiers belong to the POINTER, not to the base type: XTPointerType
        // builds its display name as weak-prefix + placement-prefix + pointee +
        // "@", and a qualifier written on a type with no `@` is ignored
        // entirely. Both rules are reproduced below.
        while (check((u16)tokIdentifier) && isQualifierWord(cur().value())) {
            String* q = advance().value();
            if (Parser._same(q, "weak")) sawWeak = true;
            // `main:` IS the default placement, so it adds no prefix — the
            // display name only carries a non-default one. `outlet` is a
            // marker, not a placement.
            else if (Parser._same(q, "outlet")) sawOutlet = true;
            else if (!Parser._same(q, "main")) placement = q;
            match((u16)tokColon);
        }

        if (check((u16)tokString)) {
            advance();
            out.appendCString("u8*");            // `string` IS u8@
        } else if (isTypeKeywordToken(curType())) {
            out.append(advance().value());
        } else if (check((u16)tokIdentifier)) {
            String* word = advance().value();
            // A typedef stands for its target: the original resolves through
            // the type table, so `op_t@` prints as `u8(u8)@`, not as `op_t@`.
            String* expansion = (String* ?)_typedefs.get((Hashable*)word);
            // An undefined type name used AS A POINTER TARGET is an opaque
            // handle — C's incomplete-type idiom (`iop*`). It names no type this
            // unit knows, so it collapses to `void*` (Ptr(Void)) exactly as the
            // reference's parseType does at parse time; keeping the name would
            // leave the AST/sema dumps diverging from `void*` while the code is
            // already identical. Gated to a following pointer sigil — a by-value
            // unknown name stays itself and is rejected later.
            if (expansion == 0 && !isTypeName(word) && isPointerSigil(cur().type())) {
                out.appendCString("void");
            } else {
                out.append((expansion != 0) ? expansion : word);
            }
            // `C<E>` — a typed collection. The element rides in the spelling
            // because a type here IS its spelling; Vtable.stripElem takes it
            // back off wherever a class is resolved or a type is printed.
            if (check((u16)tokLess)) {
                advance();
                // One argument or two: `Array<T>` / `Set<T>` / `Map<V>` against
                // `Map<K, V>`. Both ride in the SPELLING, comma and all, and
                // Node.keyOf / Node.elemOf split it back out — depth-aware, so
                // a nested `Map<String, Array<i32>>` keeps its inner comma.
                String* elem = parseTypeSpelling();
                u32 nargs = (u32)1;
                while (match((u16)tokComma)) {
                    String* more = parseTypeSpelling();
                    elem.appendByte((u8)',');
                    elem.append(more);
                    nargs = nargs + (u32)1;
                }
                if (nargs > (u32)2)
                    _error(String.withCString("a collection takes at most two type arguments"));
                // `Array<Array<i32>>` closes on a single `>>` token. Split it
                // by rewriting the token in place, leaving a `>` for the outer
                // list — confined to this loop, never a lexer rule.
                if (check((u16)tokShiftRight)) {
                    Token* sh = cur();
                    _tokens.replaceAt(_pos, (Object*)Token.with((u16)tokGreater,
                                      String.withCString(">"), sh.line(), sh.col()));
                } else if (!match((u16)tokGreater)) {
                    _error(String.withCString("Expected '>' to close a type argument list"));
                }
                out.appendByte((u8)'<');
                out.append(elem);
                out.appendByte((u8)'>');
            }
        } else {
            _error(String.withCString("expected a type"));
            return out;
        }

        // `sig^` is a BOUND METHOD — the {receiver, code} fat pointer, interned
        // as `$bound_<signature>` or `$wbound_<signature>`.
        if (match((u16)tokCaret)) {
            String* bound = String.withCString(sawWeak ? "$wbound_" : "$bound_");
            bound.append(out);
            out = bound;
            sawWeak = false;                    // consumed by the bound type
        }

        bool firstPointer = true;
        while (matchPointerSigil()) {
            if (firstPointer) {
                // Only the OUTERMOST pointer carries the qualifiers.
                String* pfx = String.withCString("");
                if (sawWeak) pfx.appendCString("weak:");
                if (placement != 0) { pfx.append(placement); pfx.appendByte((u8)':'); }
                pfx.append(out);
                out = pfx;
                firstPointer = false;
            }
            out.appendByte((u8)'*');
        }

        if (match((u16)tokLBracket)) {
            String* dims = String.withCString("[");
            if (!check((u16)tokRBracket)) {
                // Only an integer literal folds here; anything else is
                // recorded verbatim (see the header note).
                if (check((u16)tokIntLiteral)) {
                    Token* t = advance();
                    dims.append(String.withU32((u32)t.intValue()));
                } else {
                    Node* e = parseExpression();
                    dims.append((e != 0 && e.name() != 0) ? e.name()
                                                          : String.withCString("?"));
                }
            }
            expect((u16)tokRBracket);
            dims.appendByte((u8)']');
            out.append(dims);
        }
        // uxkit/026: `outlet` qualifies the DECLARATION, not the type spelling
        // — it leaves no mark on the spelling at all, so the declarator parser
        // that builds the ivar node reads it off this side-channel, exactly as
        // the original's `_lastTypeIsOutlet` does.
        _lastTypeIsOutlet = sawOutlet;
        return out;
    }

    // ── Declarations ─────────────────────────────────────────────
    Node* parseTypedef(void)
    {
        // As for an enum: a declaration with no position reads as
        // compiler-GENERATED to the interface writer, and gets dropped.
        Token* declTok = peek((u32)0);
        advance();                                  // `typedef`
        // `typedef struct { … } Name;`
        if (check((u16)tokStruct)) {
            Node* st = parseStruct(false);
            Token* name = expect((u16)tokIdentifier);
            expect((u16)tokSemicolon);
            String* alias = (name == 0) ? String.withCString("?") : name.value();
            _typeNames.add((Hashable*)String.withString(alias));
            _structNames.add((Hashable*)String.withString(alias));
            Node* n = mkNamed((u16)nkTypedefDecl, alias);
            // An anonymous struct takes the alias as its own name, so the
            // typedef's target type spells the same word.
            n.setOp(alias);
            n.add(st);
            if (declTok != 0) n.setPos(declTok.fileId(), declTok.line(), declTok.col());
            return n;
        }
        String* ty = parseTypeSpelling();
        Token* name = expect((u16)tokIdentifier);
        // A FUNCTION typedef — `typedef i8 cmp_t(Object@);` — spells as the
        // return type followed by the parameter types in parens, which is what
        // XTFunctionType's display name is.
        if (check((u16)tokLParen)) {
            match((u16)tokLParen);
            String* sig = String.withString(ty);
            sig.appendByte((u8)'(');
            bool first = true;
            while (!check((u16)tokRParen) && !check((u16)tokEOF)) {
                if (check((u16)tokVoid) && checkAt((u32)1, (u16)tokRParen)) { advance(); break; }
                if (!first) sig.appendByte((u8)',');
                first = false;
                sig.append(parseTypeSpelling());
                if (check((u16)tokIdentifier)) advance();      // an optional name
                if (!match((u16)tokComma)) break;
            }
            expect((u16)tokRParen);
            sig.appendByte((u8)')');
            ty = sig;
        }
        expect((u16)tokSemicolon);
        Node* n = mkNamed((u16)nkTypedefDecl,
                                (name == 0) ? String.withCString("?") : name.value());
        n.setOp(ty);
        if (declTok != 0) n.setPos(declTok.fileId(), declTok.line(), declTok.col());
        if (name != 0) {
            _typedefs.set((Hashable*)name.value(), (Object*)ty);
            _typeNames.add((Hashable*)name.value());   // parse-time, as the original
        }
        return n;
    }

    Node* parseStruct(bool consumeSemicolon)
    {
        // …and a struct, for the same reason an enum and a typedef need one:
        // no position reads as compiler-generated, and the interface writer
        // drops it. A library that took a `Point` in a signature published the
        // NAME everywhere and the TYPE nowhere.
        Token* declTok = peek((u32)0);
        advance();                                  // `struct`
        String* name = String.withCString("-");
        if (check((u16)tokIdentifier)) name = advance().value();
        Node* n = mkNamed((u16)nkStructDecl, name);
        if (declTok != 0) n.setPos(declTok.fileId(), declTok.line(), declTok.col());

        // `:packed` — contextual word in the annotation position, exactly the
        // original: size becomes the raw field sum, no tail rounding.
        if (check((u16)tokColon) && checkAt((u32)1, (u16)tokIdentifier)
            && Parser._same(peek((u32)1).value(), "packed")) {
            advance(); advance();
            n.addFlag((u32)NF_PACKED);
        }

        if (openBlock()) {
            while (!closeBlockAhead() && !check((u16)tokEOF)) {
                u32 loopStart = _pos;
                String* ty = parseTypeSpelling();
                // A callback/block field carries its NAME inside the type header
                // (`callback fn i32(i32 a, i32 b)`), stashed in _lastBlkName —
                // take it rather than demanding a second identifier, the way the
                // reference's var-decl path does (c2xc 05).
                String* blkName = _lastBlkName;
                _lastBlkName = (String*)0;
                bool firstDecl = true;
                while (true) {
                    String* fieldName;
                    if (firstDecl && blkName != (String*)0 && !check((u16)tokIdentifier)) {
                        fieldName = blkName;
                    } else {
                        Token* fname = expect((u16)tokIdentifier);
                        fieldName = (fname == 0) ? String.withCString("?") : fname.value();
                    }
                    firstDecl = false;
                    Node* f = mkNamed((u16)nkVariableDecl, fieldName);
                    String* fieldTy = String.withString(ty);
                    if (match((u16)tokLBracket)) {
                        fieldTy.appendByte((u8)'[');
                        if (check((u16)tokIntLiteral)) fieldTy.append(String.withU32((u32)advance().intValue()));
                        else if (!check((u16)tokRBracket)) parseExpression();
                        expect((u16)tokRBracket);
                        fieldTy.appendByte((u8)']');
                    }
                    f.setOp(fieldTy);
                    n.add(f);
                    if (!match((u16)tokComma)) break;
                }
                expect((u16)tokSemicolon);
                // Progress guard: a malformed field (`callback fn: …`, c2xc 06)
                // can leave the cursor where it started — the failed expects
                // consume nothing — and the body loop would spin forever. Force
                // past one token so the parse ENDS with an error, never hangs.
                if (_pos == loopStart) advance();
            }
            closeBlock();
        }
        if (consumeSemicolon) match((u16)tokSemicolon);
        return n;
    }

    Node* parseEnum(void)
    {
        // The `enum` keyword's own position. An enum had none at all, and a
        // declaration with no file reads as compiler-GENERATED — which is how
        // every enum fell out of the module interface: the export filter drops
        // position-less nodes because a `Blk$…` shim is exactly that, and an
        // enum was indistinguishable from one.
        Token* declTok = peek((u32)0);
        advance();                                  // `enum`
        String* name = String.withCString("-");
        if (check((u16)tokIdentifier)) name = advance().value();
        Node* n = mkNamed((u16)nkEnumDecl, name);
        if (declTok != 0) n.setPos(declTok.fileId(), declTok.line(), declTok.col());

        match((u16)tokAssign);
        // `{ }` only — see parseInitialiser for why `[ ]` went.
        bool brace = openBlock();

        // Members auto-number from 0, and an explicit `= k` resets the run —
        // the dump prints the RESOLVED value, not just the written one.
        i32 next = (i32)0;
        while (!check((u16)tokEOF)) {
            if (brace && closeBlockAhead()) break;
            if (!check((u16)tokIdentifier)) break;
            Token* m = advance();
            Node* member = mkNamed((u16)nkEnumMember, m.value());
            if (match((u16)tokAssign)) {
                if (check((u16)tokIntLiteral)) next = (i32)advance().intValue();
                else                           parseExpression();
            }
            member.setNum((i64)next);
            member.setOp(String.withCString("v"));
            next = next + (i32)1;
            n.add(member);
            if (!match((u16)tokComma)) break;
        }
        if (brace) closeBlock();
        match((u16)tokSemicolon);
        return n;
    }

    Node* parseClass(void)
    {
        // A DECLARATION carries a position too. Expressions and statements were
        // stamped and declarations were not, so a class knew nothing about
        // where it came from — which is fine for a diagnostic that names the
        // member, and not fine for `--emit-lib`, where "did this arrive with
        // the prelude?" is a question about the FILE.
        Token* declTok = cur();
        advance();                                  // `class`
        Token* nameTok = expect((u16)tokIdentifier);
        Node* n = mkNamed((u16)nkClassDecl,
                                (nameTok == 0) ? String.withCString("?") : nameTok.value());
        String* parent = String.withCString("-");
        String* protos = String.withCString("-");

        // `class Shape (Drawing)` / `class Shape ()` — category or extension.
        // `(` after a class name is unambiguous here (a name is otherwise
        // followed by `:`, `<` or the body), so no new token is needed and the
        // lexer's numbering — a contract with the reference — is untouched.
        if (match((u16)tokLParen)) {
            if (check((u16)tokIdentifier)) n.setCategory(advance().value());
            else                           n.setCategory(String.withCString(""));
            expect((u16)tokRParen);
        }

        if (match((u16)tokColon)) {
            Token* p = expect((u16)tokIdentifier);
            if (p != 0) parent = p.value();
        }
        if (match((u16)tokLess)) {
            String* list = String.withCString("");
            while (!check((u16)tokGreater) && !check((u16)tokEOF)) {
                if (check((u16)tokIdentifier)) {
                    if (list.byteLength() > (u32)0) list.appendByte((u8)',');
                    list.append(advance().value());
                } else {
                    advance();
                }
            }
            expect((u16)tokGreater);
            if (list.byteLength() > (u32)0) protos = list;
        }
        n.setOp(parent);
        n.setExtra(protos);

        // Ivars are printed before methods, matching the original's ordering,
        // so they are collected separately and appended in that order.
        Array* ivars = new Array();
        Array* methods = new Array();
        if (openBlock()) {
            blkPushScope();                          // class scope (task #26)
            while (!closeBlockAhead() && !check((u16)tokEOF)) {
                if (match((u16)tokSemicolon)) continue;
                u32 before = _pos;
                Node* m = parseMember();
                if (m != 0) {
                    if (m.kind() == (u16)nkMethodDecl) methods.add((Object*)m);
                    else                                ivars.add((Object*)m);
                }
                while (_pendingMembers.count() > (u32)0) {
                    ivars.add(_pendingMembers.get((u32)0));
                    _pendingMembers.removeAt((u32)0);
                }
                if (_pos == before) advance();
            }
            blkPopScope();                           // task #26
            closeBlock();
        }
        match((u16)tokSemicolon);

        for (u32 i = (u32)0; i < ivars.count(); i = i + (u32)1)
            n.add((Node*)ivars.get(i));
        for (u32 i = (u32)0; i < methods.count(); i = i + (u32)1)
            n.add((Node*)methods.get(i));
        if (declTok != 0) n.setPos(declTok.fileId(), declTok.line(), declTok.col());
        return n;
    }

    Node* parseProtocol(void)
    {
        Token* declTok = cur();
        advance();                                  // `protocol`
        Token* nameTok = expect((u16)tokIdentifier);
        Node* n = mkNamed((u16)nkProtocolDecl,
                                (nameTok == 0) ? String.withCString("?") : nameTok.value());
        if (openBlock()) {
            while (!closeBlockAhead() && !check((u16)tokEOF)) {
                if (match((u16)tokSemicolon)) continue;
                Node* m = parseMember();
                if (m != 0) n.add(m);
                while (_pendingMembers.count() > (u32)0) {
                    n.add((Node*)_pendingMembers.get((u32)0));
                    _pendingMembers.removeAt((u32)0);
                }
            }
            closeBlock();
        }
        match((u16)tokSemicolon);
        if (declTok != 0) n.setPos(declTok.fileId(), declTok.line(), declTok.col());
        return n;
    }

    // One class or protocol member: an ivar or a method.
    Node* parseMember(void)
    {
        u32 flags = (u32)0;
        String* sinceVersion = (String*)0;
        while (true) {
            if (match((u16)tokStatic))   { flags = flags | (u32)NF_STATIC;   continue; }
            if (match((u16)tokOptional)) { flags = flags | (u32)NF_OPTIONAL; continue; }
            if (match((u16)tokFinal))    { flags = flags | (u32)NF_FINAL;    continue; }
            if (match((u16)tokInline))   { continue; }
            // `since("0.4")` — CONTEXTUAL: an identifier here, a plain name
            // anywhere else, so `u32 since;` stays a legal ivar.
            if (check((u16)tokIdentifier) && checkAt((u32)1, (u16)tokLParen)
                && peek((u32)0).value().equals(String.withCString("since"))) {
                advance();                      // since
                advance();                      // (
                if (check((u16)tokStringLiteral)) {
                    sinceVersion = advance().value();
                } else {
                    _error(String.withCString(
                        "since(...) takes a version string, e.g. since(\"0.4\")"));
                }
                expect((u16)tokRParen);
                continue;
            }
            break;
        }

        String* ty = parseTypeSpelling();
        // A method may be NAMED `release` / `retain` / `delete`: the class's own
        // override of the reference-op it will be called through. The lexer
        // hands those back as keywords, so they are accepted here by hand.
        String* name = (String*)0;
        if (_lastBlkName != 0 && !check((u16)tokIdentifier)) {
            name = _lastBlkName;                     // block ivar (task #26)
            _lastBlkName = (String*)0;
        } else {
            Token* nameTok = (check((u16)tokRelease) || check((u16)tokRetain)
                              || check((u16)tokDelete))
                           ? advance() : expect((u16)tokIdentifier);
            name = (nameTok == 0) ? String.withCString("?") : nameTok.value();
        }

        if (check((u16)tokLParen)) {
            ty = stripWeakFromReturnList(ty);   // bug 171 Leak B — methods too
            Node* m = mkNamed((u16)nkMethodDecl, name);
            m.setOp(ty);
            m.setFlags(flags);
            if (sinceVersion != (String*)0) m.setSince(sinceVersion);
            parseParamList(m);
            if (match((u16)tokThrows)) m.addFlag((u32)NF_THROWS);
            match((u16)tokColon);           // optional `:` before the body
            skipAnnotations(m);
            if (checkBlockOpen()) {
                blkPushScope();                      // params visible (task #26)
                for (u32 bi = (u32)0; bi < m.kidCount(); bi = bi + (u32)1) {
                    Node* pk = m.kid(bi);
                    if (pk.kind() == (u16)nkParam) blkBind(pk.name(), pk.op(), (Array*)0);
                }
                m.add(parseBlock());
                blkPopScope();
            }
            else                  match((u16)tokSemicolon);
            return m;
        }

        // An ivar, possibly with an array suffix — and `u8 r,g,b;` declares
        // three of them off one type, so the extra declarators are collected
        // into `_pendingMembers` for the class body to pick up.
        //
        // `static` on an IVAR IS carried on the node: it means one copy for
        // the class rather than one per instance (Task #831). It used to be
        // masked off here because the original dropped it too — the same bug,
        // faithfully ported.
        u32 ivarFlags = flags;
        if (_lastTypeIsOutlet) ivarFlags = ivarFlags | (u32)NF_OUTLET;
        Node* v = mkNamed((u16)nkVariableDecl, name);
        v.setOp(memberTypeSuffix(ty));
        v.setFlags(ivarFlags);
        blkBind(name, v.op(), _lastBlkParams);       // class scope (task #26)
        _blkIvarNames.add((Hashable*)String.withString(name));
        if (match((u16)tokAssign)) v.add(parseExpression());
        while (match((u16)tokComma)) {
            Token* more = expect((u16)tokIdentifier);
            if (more == 0) break;
            Node* extra = mkNamed((u16)nkVariableDecl, more.value());
            extra.setOp(memberTypeSuffix(ty));
            extra.setFlags(ivarFlags);
            if (match((u16)tokAssign)) extra.add(parseExpression());
            _pendingMembers.add((Object*)extra);
        }
        expect((u16)tokSemicolon);
        return v;
    }

    // The array suffix that may follow a declarator name, appended to `ty`.
    String* memberTypeSuffix(String* ty)
    {
        String* out = String.withString(ty);
        if (match((u16)tokLBracket)) {
            out.appendByte((u8)'[');
            if (!check((u16)tokRBracket)) appendArraySize(out);
            expect((u16)tokRBracket);
            out.appendByte((u8)']');
        }
        return out;
    }

    // `(` params `)` — the parameter list of a function or method.
    void parseParamList(Node* owner)
    {
        expect((u16)tokLParen);     // splits a merged `((`

        if (check((u16)tokVoid) && checkAt((u32)1, (u16)tokRParen)) {
            advance();
            expect((u16)tokRParen);
            return;
        }
        if (match((u16)tokRParen)) return;

        while (!check((u16)tokEOF)) {
            if (match((u16)tokEllipsis)) {
                owner.addFlag((u32)NF_VARARGS);
                break;
            }
            String* ty = parseTypeSpelling();
            String* pname = String.withCString("-");
            if (_lastBlkName != 0) {                 // blocks (task #26)
                pname = _lastBlkName;
                _lastBlkName = (String*)0;
            } else if (check((u16)tokIdentifier)) pname = advance().value();
            if (match((u16)tokLBracket)) {
                ty.appendByte((u8)'[');
                if (!check((u16)tokRBracket)) appendArraySize(ty);
                expect((u16)tokRBracket);
                ty.appendByte((u8)']');
            }
            Node* p = mkNamed((u16)nkParam, pname);
            p.setOp(ty);
            owner.add(p);
            if (!match((u16)tokComma)) break;
        }
        expect((u16)tokRParen);
    }

    // `(T, T) name(` — a parenthesised type list followed by an identifier and
    // an opening paren is a multi-return signature, not an expression.
    bool looksLikeReturnTypeList(void)
    {
        u32 i = (u32)1;
        u32 depth = (u32)1;
        while (i < (u32)64) {
            u16 t = peek(i).type();
            if (t == (u16)tokEOF) return false;
            if (t == (u16)tokLParen) depth = depth + (u32)1;
            if (t == (u16)tokRParen) {
                depth = depth - (u32)1;
                if (depth == (u32)0) break;
            }
            if (t == (u16)tokSemicolon || t == (u16)tokLBrace) return false;
            i = i + (u32)1;
        }
        // After the closing paren: an identifier, then `(`.
        return peek(i + (u32)1).type() == (u16)tokIdentifier
            && peek(i + (u32)2).type() == (u16)tokLParen;
    }

    // `void hello(void) : cloaked` — a signature annotation. The annotation
    // words sit between the `:` and the body and do not appear in the dumped
    // node, so they are consumed and dropped here.
    void skipAnnotations(Node* owner)
    {
        // Any run of bare words between the signature and the body is an
        // annotation set — `:cloaked`, `:banked`, and whatever is added next.
        // They do not appear in the dumped node, so they are consumed here
        // rather than enumerated: a new annotation must not break the parse.
        // PLACEMENT is recorded on the node even so — invisible to the dump,
        // but the IR needs it, because a banked callee is reached through a
        // different call opcode than an ordinary one.
        while (check((u16)tokIdentifier) && !checkBlockOpen()) {
            String* w = cur().value();
            if (owner != 0) {
                if (Parser._same(w, "banked"))  owner.addFlag((u32)NF_BANKED);
                if (Parser._same(w, "cloaked")) owner.addFlag((u32)NF_CLOAKED);
                if (Parser._same(w, "irq"))     owner.addFlag((u32)NF_IRQ);
                if (Parser._same(w, "vbi"))     owner.addFlag((u32)NF_VBI);
                // uxkit/026: `:action` marks a nib target/action method.
                if (Parser._same(w, "action"))  owner.addFlag((u32)NF_ACTION);
            }
            advance();
            // `:cloaked(ext1)` — an annotation may take a parenthesised
            // argument naming the region it pins the declaration into.
            if (match((u16)tokLParen)) {
                while (!check((u16)tokRParen) && !check((u16)tokEOF)) advance();
                expect((u16)tokRParen);
            }
            match((u16)tokColon);
        }
    }

    // A top-level function or variable declaration. Both start with a type.
    // Normalise a `weak:` class-pointer RETURN type to strong (bug 171, Leak
    // B). A value RETURNED is a strong (+1) value whatever the return type is
    // spelled — declaring it `weak:T@` made the caller treat the result as
    // borrowed and skip the balancing release, leaking the +1. `weak:` is a
    // property of a STORAGE SLOT, not of a transient return value, so we strip
    // it from each comma-joined return component. A weak BOUND method spells
    // `$wbound_` and is untouched; only a plain `weak:T@` carries the prefix.
    String* stripWeakFromReturnList(String* ty)
    {
        if (ty == 0) return ty;
        String* weakPfx = String.withCString("weak:");
        String* result = String.withCString("");
        String* part = String.withCString("");
        u32 n = ty.byteLength();
        for (u32 i = (u32)0; i <= n; i = i + (u32)1) {
            if (i == n || ty.byteAt(i) == (u8)',') {
                if (part.hasPrefix(weakPfx))
                    part = part.substringBytes((u32)5, part.byteLength() - (u32)5);
                if (result.byteLength() > (u32)0) result.appendByte((u8)',');
                result.append(part);
                part = String.withCString("");
            } else {
                part.appendByte(ty.byteAt(i));
            }
        }
        return result;
    }

    Node* parseFunctionOrVar(void)
    {
        Token* declTok = cur();
        u32 flags = (u32)0;
        while (true) {
            if (match((u16)tokStatic))   { flags = flags | (u32)NF_STATIC;   continue; }
            if (match((u16)tokGlobal))   { flags = flags | (u32)NF_GLOBAL;   continue; }
            if (match((u16)tokExtern))   { flags = flags | (u32)NF_EXTERN;   continue; }
            if (match((u16)tokVolatile)) { flags = flags | (u32)NF_VOLATILE; continue; }
            if (match((u16)tokRegister)) { flags = flags | (u32)NF_REGISTER; continue; }
            if (match((u16)tokInline))   { continue; }
            break;
        }

        // `(i32, i32) mr(void)` — a parenthesised list of return types. The
        // dump joins them with commas, which is what the original prints.
        String* ty = (String*)0;
        if (check((u16)tokLParen) && looksLikeReturnTypeList()) {
            match((u16)tokLParen);
            ty = String.withCString("");
            while (!check((u16)tokRParen) && !check((u16)tokEOF)) {
                if (ty.byteLength() > (u32)0) ty.appendByte((u8)',');
                ty.append(parseTypeSpelling());
                if (!match((u16)tokComma)) break;
            }
            expect((u16)tokRParen);
        } else {
            ty = parseTypeSpelling();
            // `i32, i32 mr(i32 x)` — a bare comma-separated return-type list.
            // A comma HERE, before any declarator name, can only be that: a
            // variable list (`u16 x, y;`) puts its comma after the name.
            while (check((u16)tokComma) && (isTypeKeywordToken(peek((u32)1).type())
                                            || (peek((u32)1).type() == (u16)tokIdentifier
                                                && isTypeName(peek((u32)1).value())))) {
                advance();
                ty.appendByte((u8)',');
                ty.append(parseTypeSpelling());
            }
        }
        // A free function may be NAMED `delete` / `retain` / `release` too —
        // the keywords are only statements in statement position.
        // Blocks (task #26): a block DECLARATION carries its name inside the
        // type header; a name spelled in a block RETURN type is documentation.
        String* blkDeclName = _lastBlkName;
        String* blkDeclBase = _lastBlkBase;
        Array*  blkDeclParams = _lastBlkParams;
        String* blkDeclRet = _lastBlkRet;
        _lastBlkName = (String*)0;
        Token* nameTok = (Token*)0;
        String* name = (String*)0;
        if (blkDeclName != 0 && !check((u16)tokIdentifier)) {
            name = blkDeclName;
        } else {
            nameTok = (check((u16)tokRelease) || check((u16)tokRetain)
                       || check((u16)tokDelete))
                    ? advance() : expect((u16)tokIdentifier);
            name = (nameTok == 0) ? String.withCString("?") : nameTok.value();
        }

        if (check((u16)tokLParen)) {
            ty = stripWeakFromReturnList(ty);   // bug 171 Leak B
            Node* f = mkNamed((u16)nkFunctionDecl, name);
            f.setOp(ty);
            f.setFlags(flags);
            _blkFnRet.set((Hashable*)String.withString(name), (Object*)ty);
            parseParamList(f);
            if (match((u16)tokThrows)) f.addFlag((u32)NF_THROWS);
            match((u16)tokColon);           // optional `:` before the body
            skipAnnotations(f);
            if (checkBlockOpen()) {
                blkPushScope();                      // params visible (task #26)
                for (u32 bi = (u32)0; bi < f.kidCount(); bi = bi + (u32)1) {
                    Node* pk = f.kid(bi);
                    if (pk.kind() == (u16)nkParam) blkBind(pk.name(), pk.op(), (Array*)0);
                }
                f.add(parseBlock());
                blkPopScope();
            }
            else {
                match((u16)tokSemicolon);
                // BODYLESS = an import. It rides in the `#package` in force,
                // which the wasm back end turns into the import's module name.
                // Without this every extern lands in `env`, and a loader that
                // supplies them under their real package hands back a stub
                // that throws when called.
                if (_currentPackage != 0) f.setExtra(_currentPackage);
            }
            if (declTok != 0) f.setPos(declTok.fileId(), declTok.line(), declTok.col());
            return f;
        }

        Node* v = mkNamed((u16)nkVariableDecl, name);
        String* vty = String.withString(ty);
        if (match((u16)tokLBracket)) {
            vty.appendByte((u8)'[');
            if (!check((u16)tokRBracket)) appendArraySize(vty);
            expect((u16)tokRBracket);
            vty.appendByte((u8)']');
        }
        v.setOp(vty);
        // A variable at FILE SCOPE is global by definition — the `global`
        // keyword only adds cross-module visibility on top.
        v.setFlags(flags | (u32)NF_GLOBAL);
        if (match((u16)tokAssign)) {
            v.add(parseInitialiser());
            // §6: `extern` + initialiser = exported DEFINITION. The original
            // sets isExported (never dumped) and its dumped extern flag
            // stays 0 — swap the bits to match (tasks #31/#33).
            if ((flags & (u32)NF_EXTERN) != (u32)0)
                v.setFlags(((flags | (u32)NF_GLOBAL) & ~(u32)NF_EXTERN)
                           | (u32)NF_EXPORTED);
        }
        expect((u16)tokSemicolon);
        if (declTok != 0) v.setPos(declTok.fileId(), declTok.line(), declTok.col());
        return v;
    }

    // ── Statements ───────────────────────────────────────────────
    // A block opens with `{` or `((` and closes with `}` or `))`.
    // `((` opens a block — unless it is the two parens of `((T@)p).f`, which
    // the lexer merged into ONE token. The statement path already asks; a
    // BRACE-LESS `if` / `while` / `for` body comes through here instead, and
    // without the same question `if (c) ((Array@)a.get(0)).add(x);` reads as a
    // block and the cast becomes a declaration of a variable with no name.
    bool checkBlockOpen(void)
    {
        return check((u16)tokLBrace);
    }

    bool openBlock(void)
    {
        return match((u16)tokLBrace);
    }

    bool closeBlockAhead(void)
    {
        return check((u16)tokRBrace);
    }

    void closeBlock(void)
    {
        if (match((u16)tokRBrace)) return;
        expect((u16)tokRBrace);
    }

    Node* parseBlock(void)
    {
        Node* b = mk((u16)nkBlock);
        openBlock();
        blkPushScope();                              // blocks (task #26)
        // !_fatal mirrors the original's hasFatalError guard: after a parse
        // error the statement loop stops consuming, so an error file's dump
        // truncates at the same statement in both compilers (task #36).
        while (!closeBlockAhead() && !check((u16)tokEOF) && !_fatal) {
            u32 before = _pos;
            Node* s = parseStatement();
            if (s != 0) b.add(s);
            if (_pos == before) advance();
        }
        blkPopScope();                               // blocks (task #26)
        closeBlock();
        return b;
    }

    Node* parseStatement(void)
    {
        Token* stmtTok = cur();
        Node* stmtNode = parseStatementInner();
        if (stmtNode != 0 && stmtNode.line() == (u32)0)
            stmtNode.setPos(stmtTok.fileId(), stmtTok.line(), stmtTok.col());
        return stmtNode;
    }

    Node* parseStatementInner(void)
    {
        if (check((u16)tokIf))       return parseIf();
        if (check((u16)tokWhile))    return parseWhile();
        if (check((u16)tokFor))      return parseFor();
        if (check((u16)tokSwitch))   return parseSwitch();
        if (check((u16)tokReturn))   return parseReturn();
        if (check((u16)tokDefer))    { advance(); Node* d = mk((u16)nkDefer); d.add(parseBlockOrStatement()); return d; }
        if (check((u16)tokThrow))    { advance(); Node* t = mk((u16)nkThrow); t.add(parseExpression()); expect((u16)tokSemicolon); return t; }
        if (check((u16)tokTry))      return parseTry();
        if (check((u16)tokAsm))      return parseAsmBlock();
        if (check((u16)tokTypedef))  return parseTypedef();
        if (check((u16)tokStruct))   return parseStruct(true);
        if (check((u16)tokEnum))     return parseEnum();
        if (check((u16)tokBreak))    { advance(); expect((u16)tokSemicolon); return mk((u16)nkBreak); }
        if (check((u16)tokContinue)) { advance(); expect((u16)tokSemicolon); return mk((u16)nkContinue); }
        if (check((u16)tokGoto)) {
            // `goto <label>;` — a C-porting aid (undocumented as a language feature).
            advance();
            Token* lbl = expect((u16)tokIdentifier);
            expect((u16)tokSemicolon);
            return lbl != 0 ? mkNamed((u16)nkGoto, lbl.value()) : (Node*)0;
        }
        if (check((u16)tokDelete) || check((u16)tokRetain) || check((u16)tokRelease)) {
            // `delete p;` is a statement; `delete(x, y)` is a call to a user
            // function of that name. The original tells them apart by looking
            // for an empty argument list or a TOP-LEVEL COMMA inside the
            // parens — so `release (Tracker@)0;` stays a statement, since a
            // cast has neither.
            if (!looksLikeRefopCall()) {
                // XTRefOp: delete = 0, retain = 1, release = 2 — the numbering
                // the dump prints.
                u16 kwType = curType();
                Token* kw = advance();
                Node* d = mk((u16)nkDelete);
                d.setOp(kw.value());
                if      (kwType == (u16)tokRetain)  d.setNum((i64)1);
                else if (kwType == (u16)tokRelease) d.setNum((i64)2);
                else                                d.setNum((i64)0);
                d.add(parseExpression());
                expect((u16)tokSemicolon);
                return d;
            }
        }
        if (check((u16)tokLBrace)) return parseBlock();

        // `(a, b) = f();` — tuple unpacking. Told from a parenthesised
        // expression by the `=` that follows the closing paren.
        if (check((u16)tokLParen) && looksLikeTupleAssign()) return parseTupleAssign();

        if (looksLikeType() || blkAhead() || cbAhead() || blkWbAhead() || check((u16)tokStatic) || check((u16)tokVolatile)
            || check((u16)tokRegister) || check((u16)tokGlobal)) {
            return parseVarDeclStatement();
        }

        // `<name>:` at statement position is a LABEL (goto target). After the
        // var-decl / qualifier handling above, so a contextual `weak:`/`main:`
        // type prefix is already consumed and only a real label remains.
        if (check((u16)tokIdentifier) && checkAt((u32)1, (u16)tokColon)) {
            String* nm = cur().value();
            advance(); advance();
            return mkNamed((u16)nkGotoLabel, nm);
        }

        Node* e = parseExpression();
        expect((u16)tokSemicolon);
        if (e == 0) return (Node*)0;
        Node* st = mk((u16)nkExprStatement);
        st.add(e);
        return st;
    }

    bool looksLikeTupleAssign(void)
    {
        u32 i = (u32)1;
        u32 depth = (u32)1;
        bool sawComma = false;
        while (i < (u32)64) {
            u16 t = peek(i).type();
            if (t == (u16)tokEOF || t == (u16)tokSemicolon) return false;
            if (t == (u16)tokLParen) depth = depth + (u32)1;
            if (t == (u16)tokRParen) {
                depth = depth - (u32)1;
                if (depth == (u32)0) break;
            }
            if (t == (u16)tokComma && depth == (u32)1) sawComma = true;
            i = i + (u32)1;
        }
        return sawComma && peek(i + (u32)1).type() == (u16)tokAssign;
    }

    Node* parseTupleAssign(void)
    {
        Node* n = mk((u16)nkTupleAssign);
        match((u16)tokLParen);
        while (!check((u16)tokRParen) && !check((u16)tokEOF)) {
            // A target is either an EXISTING identifier or a NEW declaration
            // carrying its type: `(a, b) = f()` and
            // `(u16 lo, u16 hi, bool ord) = f()` are both legal, and the two
            // may be mixed. This parsed every target as an expression, so the
            // bare form worked and anything with a type in it failed at the
            // first one with `Expected ')' but found '<name>'` — multiple
            // return values are a documented language feature and the shipped
            // compiler could not unpack them into new variables.
            if (looksLikeType()) {
                String* ty = parseTypeSpelling();
                Token* nameTok = expect((u16)tokIdentifier);
                if (nameTok == (Token*)0) break;
                Node* v = mkNamed((u16)nkVariableDecl, nameTok.value());
                v.setOp(ty);
                n.add(v);
            } else {
                n.add(parseExpression());
            }
            if (!match((u16)tokComma)) break;
        }
        expect((u16)tokRParen);
        expect((u16)tokAssign);
        n.add(parseExpression());
        expect((u16)tokSemicolon);
        return n;
    }

    bool looksLikeRefopCall(void)
    {
        if (!checkAt((u32)1, (u16)tokLParen)) return false;
        if (checkAt((u32)2, (u16)tokRParen)) return true;   // `f()` — a call
        u32 depth = (u32)1;
        u32 i = (u32)2;
        bool sawTopComma = false;
        while (i < (u32)256) {
            u16 t = peek(i).type();
            if (t == (u16)tokLParen) depth = depth + (u32)1;
            else if (t == (u16)tokRParen) {
                depth = depth - (u32)1;
                if (depth == (u32)0) break;
            } else if (t == (u16)tokComma && depth == (u32)1) sawTopComma = true;
            else if (t == (u16)tokSemicolon || t == (u16)tokEOF) return false;
            i = i + (u32)1;
        }
        return sawTopComma;
    }

    Node* parseBlockOrStatement(void)
    {
        if (checkBlockOpen()) return parseBlock();
        return parseStatement();
    }

    Node* parseVarDeclStatement(void)
    {
        u32 flags = (u32)0;
        bool blockBodyInit = false;                   // `= { body }` of a block literal
        while (true) {
            if (match((u16)tokStatic))   { flags = flags | (u32)NF_STATIC;   continue; }
            if (match((u16)tokGlobal))   { flags = flags | (u32)NF_GLOBAL;   continue; }
            if (match((u16)tokVolatile)) { flags = flags | (u32)NF_VOLATILE; continue; }
            if (match((u16)tokRegister)) { flags = flags | (u32)NF_REGISTER; continue; }
            break;
        }
        _lastBlkWb = false;
        String* ty = parseTypeSpelling();
        bool declIsBlkWb = _lastBlkWb;               // v2 (task #29)
        _lastBlkWb = false;
        if (declIsBlkWb
            && (ty.byteLength() == (u32)0
                || ty.byteAt(ty.byteLength() - (u32)1) == (u8)']'
                || _structNames.contains((Hashable*)ty))) {
            _error(String.withCString("`block:` write-back captures are scalars and pointers in v2 — an array or struct cannot copy back through the hidden pointer"));
            declIsBlkWb = false;
        }
        // Blocks (task #26): the declared name arrived inside the header.
        String* blkDeclName = _lastBlkName;
        String* blkDeclBase = _lastBlkBase;
        Array*  blkDeclParams = _lastBlkParams;
        String* blkDeclRet = _lastBlkRet;
        _lastBlkName = (String*)0;

        Node* first = (Node*)0;
        Array* decls = new Array();
        Array* ctorArgs = (Array*)0;        // `Myclass c(a, b);`
        String* ctorName = (String*)0;
        while (!check((u16)tokEOF)) {
            String* name = (String*)0;
            bool fromBlockHeader = false;
            if (blkDeclName != 0) {
                name = blkDeclName;
                blkDeclName = (String*)0;
                fromBlockHeader = true;
            } else {
                Token* nameTok = expect((u16)tokIdentifier);
                name = (nameTok == 0) ? String.withCString("?") : nameTok.value();
            }
            Node* v = mkNamed((u16)nkVariableDecl, name);
            String* vty = String.withString(ty);
            if (match((u16)tokLBracket)) {
                vty.appendByte((u8)'[');
                if (!check((u16)tokRBracket)) appendArraySize(vty);
                expect((u16)tokRBracket);
                vty.appendByte((u8)']');
            }
            v.setOp(vty);
            v.setFlags(flags);
            // Gated on the NAME stash, exactly as the original gates on
            // blockDeclName: the BASE stash survives across unrelated
            // declarations (nothing clears it on a scalar parseTypeSpelling),
            // and with the ambient prelude every unit parses block headers —
            // `u8 arr[2] = { 10, 20 }` then read its array initialiser as a
            // block BODY off the stale base (task #36; the 430e8c3e stale-
            // stash bug's second face).
            if (fromBlockHeader && blkDeclBase != 0
                && check((u16)tokAssign) && checkAt((u32)1, (u16)tokLBrace)) {
                // `block b u32(…) = { body }` — the braces are the BODY, the
                // signature (names included) comes from the declaration.
                advance();                              // `=`
                Node* lit = blkParseLiteralBody(blkDeclBase, blkDeclRet,
                                                blkDeclParams, name);
                if (lit != 0) v.add(lit);
                blockBodyInit = true;
            } else if (match((u16)tokAssign)) {
                v.add(parseInitialiser());
            } else if (check((u16)tokLParen)) {
                // `Myclass c(a, b);` — a stack instance with constructor args.
                // The original expands this into a two-statement block: the
                // declaration (carrying the args) plus an explicit `c.init(…)`
                // call, so ordinary method-call codegen does the work.
                match((u16)tokLParen);
                ctorArgs = new Array();
                while (!check((u16)tokRParen) && !check((u16)tokEOF)) {
                    Node* a = parseExpression();
                    if (a != 0) { v.add(a); ctorArgs.add((Object*)a); }
                    if (!match((u16)tokComma)) break;
                }
                expect((u16)tokRParen);
                ctorName = name;
            }
            if (first == 0) first = v;
            decls.add((Object*)v);
            blkBind(name, vty, blkDeclParams);           // task #26
            if (declIsBlkWb) blkMarkWb(name);            // task #29
            if (Parser._same(vty, "auto") && v.kidCount() > (u32)0)
                blkBindAuto(name, v.kid((u32)0));        // task #26
            if (v.kidCount() > (u32)0)
                blkMarkHoldsWb(name, v.kid((u32)0));     // task #29
            if (!match((u16)tokComma)) break;
        }
        // Mirrors the reference: a block-body initialiser is closed by its `}`
        // and the `;` is optional after it; everywhere else a missing `;` is an
        // error. This was `match` for every declaration, so the shipped compiler
        // accepted `i32 y = (i32)1` with no semicolon and built it (bug 130).
        if (blockBodyInit) match((u16)tokSemicolon);
        else               expect((u16)tokSemicolon);

        // `first` is a strong local held ALONGSIDE the array, not fetched back
        // out of it: returning `array.get(0)` hands back a reference the array
        // owns, and the array dies at scope exit — the caller is then holding
        // freed memory. (That is a compiler ARC gap in its own right; see
        // tests/fixtures/arc_return_container_element.xc.)
        if (ctorArgs != 0) {
            // The wrapper is a DECL-LIST block, not a scope: `Gadget g(42);`
            // declares `g` in the ENCLOSING block and the synthesised
            // `g.init(42)` rides along beside it.
            Node* b = mk((u16)nkBlock);
            b.addFlag((u32)NF_DECLLIST);
            for (u32 i = (u32)0; i < decls.count(); i = i + (u32)1) b.add((Node*)decls.get(i));
            Node* call = mkNamed((u16)nkMethodCall, String.withCString("init"));
            call.add(mkNamed((u16)nkIdent, ctorName));       // the receiver
            for (u32 i = (u32)0; i < ctorArgs.count(); i = i + (u32)1)
                call.add((Node*)ctorArgs.get(i));
            call.setNum((i64)ctorArgs.count());
            Node* st = mk((u16)nkExprStatement);
            st.add(call);
            b.add(st);
            return b;
        }

        if (decls.count() == (u32)1) return first;
        // Several declarators share one type: the original wraps them in a
        // block marked isDeclList, and so does this.
        Node* b = mk((u16)nkBlock);
        b.addFlag((u32)NF_DECLLIST);
        for (u32 i = (u32)0; i < decls.count(); i = i + (u32)1) b.add((Node*)decls.get(i));
        return b;
    }

    // `= { … }` / `= [ … ]` initialiser lists, or a plain expression.
    Node* parseInitialiser(void)
    {
        // `u8 buf[10] = 0..10;` — a RANGE as an initialiser value, which the
        // codegen unrolls into a run of stores.
        // `{ }` only. `[ ]` was accepted here for the same reason `(( ))` was
        // accepted as a block — an Atari 8-bit keyboard has no brace keys —
        // and went with it, so initialisers, struct bodies and enum bodies all
        // read the way C reads them.
        if (!check((u16)tokLBrace)) {
            Node* e = parseExpression();
            if (check((u16)tokDotDot) || check((u16)tokEllipsis)) {
                bool inclusive = check((u16)tokEllipsis);
                advance();
                Node* r = mk((u16)nkRange);
                if (inclusive) r.addFlag((u32)NF_INCLUSIVE);
                r.add(e);
                r.add(parseExpression());
                return r;
            }
            return e;
        }
        if (check((u16)tokLBrace)) {
            u16 closer = (u16)tokRBrace;
            advance();
            Node* list = mk((u16)nkBlock);
            while (!check(closer) && !check((u16)tokEOF)) {
                list.add(parseInitialiser());
                if (!match((u16)tokComma)) break;
            }
            expect(closer);
            return list;
        }
        return parseExpression();
    }

    Node* parseIf(void)
    {
        advance();                                  // `if`
        Node* n = mk((u16)nkIf);
        expect((u16)tokLParen);
        n.add(parseExpression());
        expect((u16)tokRParen);
        n.add(parseBlockOrStatement());
        if (match((u16)tokElse)) n.add(parseBlockOrStatement());
        return n;
    }

    Node* parseWhile(void)
    {
        advance();
        Node* n = mk((u16)nkWhile);
        expect((u16)tokLParen);
        n.add(parseExpression());
        expect((u16)tokRParen);
        n.add(parseBlockOrStatement());
        return n;
    }

    // Both loop forms: `for (v in coll)` and the C-style triple.
    Node* parseFor(void)
    {
        advance();
        expect((u16)tokLParen);

        // for-in: an optional type, a name, then `in`.
        u32 save = _pos;
        bool isForIn = false;
        if (check((u16)tokIdentifier) && checkAt((u32)1, (u16)tokIn)) isForIn = true;
        if (!isForIn && looksLikeType()) {
            // Skip the type and see whether `in` follows the name.
            parseTypeSpelling();
            if (check((u16)tokIdentifier) && checkAt((u32)1, (u16)tokIn)) isForIn = true;
            _pos = save;
        }

        if (isForIn) {
            String* ty = String.withCString("-");
            if (looksLikeType() && !checkAt((u32)1, (u16)tokIn)) ty = parseTypeSpelling();
            Token* v = expect((u16)tokIdentifier);
            String* vname = (v == 0) ? String.withCString("_") : v.value();
            expect((u16)tokIn);
            Node* collection = parseExpression();

            // `for (u8 i in 0..5)` is a RANGE loop, and the original DESUGARS
            // it into the C-style form right here — `for (u8 i = 0; i < 5;
            // i += 1)`. Inclusive `...` uses `<=`; descending bounds flip the
            // comparison and subtract. Nothing downstream ever sees a range.
            if (check((u16)tokDotDot) || check((u16)tokEllipsis)) {
                bool inclusive = check((u16)tokEllipsis);
                advance();
                Node* endExpr = parseExpression();

                // `step <signed int literal>` — an explicit stride, and a
                // negative one means the loop counts down.
                i32 stepValue = (i32)0;
                bool stepExplicit = false;
                if (check((u16)tokIdentifier) && Parser._same(cur().value(), "step")) {
                    advance();
                    bool negStep = match((u16)tokMinus);
                    if (check((u16)tokIntLiteral)) {
                        stepValue = (i32)advance().intValue();
                        if (negStep) stepValue = (i32)0 - stepValue;
                        stepExplicit = true;
                    }
                }

                // Both bounds literal and start > end → descending, step -1.
                bool descending = false;
                if (stepExplicit) descending = (stepValue < (i32)0);
                else if (collection != 0 && endExpr != 0
                    && collection.kind() == (u16)nkInt && endExpr.kind() == (u16)nkInt
                    && collection.num() > endExpr.num()) descending = true;

                // An untyped loop variable defaults to u8 when both bounds are
                // u8-valued literals — the same surface-level rule.
                if (Parser._same(ty, "-")) ty = String.withCString("u8");

                expect((u16)tokRParen);
                Node* body = parseBlockOrStatement();

                Node* n = mk((u16)nkForCStyle);
                Node* initMark = mk((u16)nkMarkerInit);
                Node* decl = mkNamed((u16)nkVariableDecl, vname);
                decl.setOp(ty);
                decl.add(collection);                    // the start bound
                initMark.add(decl);
                n.add(initMark);

                Node* condMark = mk((u16)nkMarkerCond);
                Node* cmp = mk((u16)nkBinary);
                if (descending) cmp.setOp(String.withCString(inclusive ? ">=" : ">"));
                else            cmp.setOp(String.withCString(inclusive ? "<=" : "<"));
                cmp.add(mkNamed((u16)nkIdent, vname));
                cmp.add(endExpr);
                condMark.add(cmp);
                n.add(condMark);

                Node* stepMark = mk((u16)nkMarkerStep);
                Node* step = mk((u16)nkAssign);
                step.setOp(String.withCString(descending ? "-=" : "+="));
                step.add(mkNamed((u16)nkIdent, vname));
                Node* one = mk((u16)nkInt);
                i32 mag = stepExplicit ? stepValue : (i32)1;
                if (mag < (i32)0) mag = (i32)0 - mag;
                one.setNum((i64)mag);
                step.add(one);
                stepMark.add(step);
                n.add(stepMark);

                n.add(body);
                return n;
            }

            Node* n = mk((u16)nkForIn);
            Node* loopVar = mkNamed((u16)nkVariableDecl, vname);
            loopVar.setOp(ty);
            n.add(loopVar);
            n.add(collection);
            expect((u16)tokRParen);
            n.add(parseBlockOrStatement());
            return n;
        }

        Node* n = mk((u16)nkForCStyle);
        Node* initMark = mk((u16)nkMarkerInit);
        if (!check((u16)tokSemicolon)) {
            if (looksLikeType()) initMark.add(parseVarDeclStatement());
            else {
                // The original stores the bare expression as the loop's init
                // clause — no ExprStatement wrapper.
                Node* e = parseExpression();
                expect((u16)tokSemicolon);
                initMark.add(e);
            }
        } else {
            advance();
        }
        n.add(initMark);

        Node* condMark = mk((u16)nkMarkerCond);
        if (!check((u16)tokSemicolon)) condMark.add(parseExpression());
        expect((u16)tokSemicolon);
        n.add(condMark);

        Node* stepMark = mk((u16)nkMarkerStep);
        if (!check((u16)tokRParen)) stepMark.add(parseExpression());
        expect((u16)tokRParen);
        n.add(stepMark);

        if (parseLoopAnnotations()) n.addFlag((u32)NF_UNROLL);
        n.add(parseBlockOrStatement());
        return n;
    }

    // `for (...) : unroll` — the optional loop annotations. The reference
    // parses them, stores forceUnroll on the AST node, and NOTHING ever reads
    // it: six references in the whole tree, all parse-or-declare. It was a hook
    // for the AST optimiser, removed in phase-323. So the annotation is
    // ACCEPTED AND INERT there, and this makes the port agree.
    //
    // The port had no notion of it at all, so `for (...) : unroll` — a
    // documented syntax, with a worked example on the website — did not parse
    // in the shipped compiler while it parsed fine in the reference.
    //
    // An unrecognised annotation WARNS — it is not swallowed. Silently
    // accepting any identifier would let a typo mean nothing, which is the
    // wrong direction: better too loud and silenceable with
    // `-Wno-unknown-annotation` than quietly wrong. Same category and same
    // wording as the reference.
    bool parseLoopAnnotations(void)
    {
        bool forced = false;
        if (!match((u16)tokColon)) return forced;
        while (check((u16)tokIdentifier)) {
            Token* tok = advance();
            if (tok != (Token*)0 && Parser._same(tok.value(), "unroll")) {
                forced = true;
            } else if (tok != (Token*)0) {
                String* w = String.withCString("Unknown loop annotation '");
                w.append(tok.value());
                w.appendCString("'");
                warnAt(String.withCString("unknown-annotation"), w, tok);
            }
            if (!match((u16)tokComma)) break;
        }
        return forced;
    }

    Node* parseReturn(void)
    {
        // v2 (task #29): returning a block that carries `block:` captures
        // hands the caller a write into this (dead) frame — checked below
        // after each value parses.
        advance();
        Node* n = mk((u16)nkReturn);
        if (!check((u16)tokSemicolon)) {
            n.add(parseExpression());
            while (match((u16)tokComma)) n.add(parseExpression());
        }
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1) {
            if (blkIsWbValue(n.kid(i)))
                _error(String.withCString("a block with `block:` captures cannot be returned — its write-back targets this frame. Write results into an object (an ivar, a box) instead"));
        }
        expect((u16)tokSemicolon);
        return n;
    }

    Node* parseTry(void)
    {
        advance();
        Node* n = mk((u16)nkTry);
        n.add(parseBlockOrStatement());
        while (check((u16)tokCatch)) {
            advance();
            Node* c = mk((u16)nkCatch);
            String* ty = String.withCString("-");
            String* var = String.withCString("-");
            if (match((u16)tokLParen)) {
                if (looksLikeType()) ty = parseTypeSpelling();
                if (check((u16)tokIdentifier)) var = advance().value();
                expect((u16)tokRParen);
            }
            c.setOp(ty);
            c.setName(var);
            c.add(parseBlockOrStatement());
            n.add(c);
        }
        return n;
    }

    Node* parseSwitch(void)
    {
        advance();
        Node* n = mk((u16)nkSwitch);
        expect((u16)tokLParen);
        n.add(parseExpression());
        expect((u16)tokRParen);

        if (openBlock()) {
            Node* current = (Node*)0;
            bool caseHasBody = false;
            while (!closeBlockAhead() && !check((u16)tokEOF) && !_fatal) {
                if (check((u16)tokCase) || check((u16)tokDefault)) {
                    bool isDefault = check((u16)tokDefault);
                    advance();
                    // `case 1: case 2: body` is ONE case with two labels —
                    // consecutive labels with nothing between them share a
                    // body, which is what C fallthrough means here.
                    if (current == 0 || caseHasBody) {
                        current = mk((u16)nkCase);
                        n.add(current);
                        caseHasBody = false;
                    }
                    if (isDefault) current.addFlag((u32)NF_DEFAULT);
                    if (!isDefault) {
                        while (true) {
                            Node* label = mk((u16)nkLabel);
                            // Open-ended ranges: `case ..5:` and `case 5..:`
                            // carry only one bound, and `case a..b:` carries
                            // both. The missing side is simply absent.
                            if (check((u16)tokDotDot) || check((u16)tokEllipsis)) {
                                advance();
                                label.addFlag((u32)NF_RANGE);
                                label.addFlag((u32)NF_RANGE_HI);
                                if (!check((u16)tokColon) && !check((u16)tokComma))
                                    label.add(parseExpression());
                            } else {
                                Node* lo = parseExpression();
                                if (check((u16)tokDotDot) || check((u16)tokEllipsis)) {
                                    advance();
                                    label.addFlag((u32)NF_RANGE);
                                    label.add(lo);
                                    if (!check((u16)tokColon) && !check((u16)tokComma))
                                        label.add(parseExpression());
                                } else {
                                    label.add(lo);
                                }
                            }
                            current.add(label);
                            if (!match((u16)tokComma)) break;
                        }
                    }
                    expect((u16)tokColon);
                    continue;
                }
                u32 before = _pos;
                Node* s = parseStatement();
                if (s != 0) {
                    if (current != 0) { current.add(s); caseHasBody = true; }
                    else                n.add(s);
                }
                if (_pos == before) advance();
            }
            closeBlock();
        }
        return n;
    }

    // `asm { … }` — the body is kept as raw lines, reconstructed from tokens
    // the way the original does, since the lexer has already split it.
    Node* parseAsmBlock(void)
    {
        advance();                                  // `asm`
        Node* n = mk((u16)nkAsmBlock);
        if (!openBlock()) return n;
        u32 depth = (u32)1;
        String* line = String.withCString("");
        u32 lastLine = cur().line();
        while (!check((u16)tokEOF)) {
            if (check((u16)tokLBrace)) depth = depth + (u32)1;
            if (closeBlockAhead()) {
                depth = depth - (u32)1;
                if (depth == (u32)0) break;
            }
            Token* t = advance();
            if (t.line() != lastLine && line.byteLength() > (u32)0) {
                n.add(mkNamed((u16)nkAsmLine, line));
                line = String.withCString("");
            }
            // Spacing rules, copied exactly: no space after `#` (the 6502
            // immediate prefix), after `.` (so `.loop` stays one label), after
            // `,` or `+`, and none BEFORE a `,` or `+`. xta's symbol parser
            // absorbs a trailing space and comma into the symbol name, so
            // `LDA tab,Y` reconstructed as `LDA tab , Y` no longer resolves.
            bool suppress = false;
            if (line.byteLength() > (u32)0) {
                u8 lastCh = line.byteAt(line.byteLength() - (u32)1);
                if (lastCh == (u8)'#' || lastCh == (u8)'.' || lastCh == (u8)','
                    || lastCh == (u8)'+') suppress = true;
            }
            if (t.value().byteLength() > (u32)0) {
                u8 firstCh = t.value().byteAt((u32)0);
                if (firstCh == (u8)',' || firstCh == (u8)'+') suppress = true;
            }
            if (line.byteLength() > (u32)0 && !suppress) line.appendByte((u8)32);
            line.append(t.value());
            lastLine = t.line();
        }
        if (line.byteLength() > (u32)0) n.add(mkNamed((u16)nkAsmLine, line));
        closeBlock();
        return n;
    }

    // ── Expressions ──────────────────────────────────────────────
    // Precedence-climbing, with the ObjC parser's table copied verbatim:
    // assignment 1 (right), ternary 2 (right), || 3, && 4, | 5, ^ 6, & 7,
    // ==/!= 8, relational 9, shifts 10, rotates 11, +/- 12, */ /% 13.
    i16 precOf(u16 t)
    {
        if (t == (u16)tokAssign || t == (u16)tokPlusAssign || t == (u16)tokMinusAssign
            || t == (u16)tokStarAssign || t == (u16)tokSlashAssign
            || t == (u16)tokPercentAssign || t == (u16)tokAmpAssign
            || t == (u16)tokPipeAssign || t == (u16)tokCaretAssign
            || t == (u16)tokShlAssign || t == (u16)tokShrAssign
            || t == (u16)tokRolAssign || t == (u16)tokRorAssign) return (i16)1;
        if (t == (u16)tokQuestion)    return (i16)2;
        if (t == (u16)tokLogicalOr)   return (i16)3;
        if (t == (u16)tokLogicalAnd)  return (i16)4;
        if (t == (u16)tokPipe)        return (i16)5;
        if (t == (u16)tokCaret)       return (i16)6;
        if (t == (u16)tokAmpersand)   return (i16)7;
        if (t == (u16)tokEqual || t == (u16)tokNotEqual) return (i16)8;
        if (t == (u16)tokLess || t == (u16)tokGreater
            || t == (u16)tokLessEq || t == (u16)tokGreaterEq) return (i16)9;
        if (t == (u16)tokShiftLeft || t == (u16)tokShiftRight) return (i16)10;
        if (t == (u16)tokRotateLeft || t == (u16)tokRotateRight) return (i16)11;
        if (t == (u16)tokPlus || t == (u16)tokMinus) return (i16)12;
        if (t == (u16)tokStar || t == (u16)tokSlash || t == (u16)tokPercent) return (i16)13;
        return (i16)-1;
    }

    bool isAssignTok(u16 t) { return precOf(t) == (i16)1; }

    // Every expression carries the position of its FIRST token. Stamped here,
    // at the one entry point, rather than at the ~90 places a node is built:
    // an expression's position is where it starts, so one rule covers all of
    // them, and a sub-expression that was stamped deeper keeps its own.
    Node* parseExpression(void)
    {
        Token* t0 = cur();
        Node* n = parseExprMinPrec((i16)0);
        if (n != 0 && n.line() == (u32)0) n.setPos(t0.fileId(), t0.line(), t0.col());
        return n;
    }

    Node* parseExprMinPrec(i16 minPrec)
    {
        Node* lhs = parseUnary();
        if (lhs == 0) return (Node*)0;

        while (true) {
            u16 opType = curType();
            i16 prec = precOf(opType);

            if (opType == (u16)tokQuestion && prec >= minPrec) {
                advance();
                Node* t = mk((u16)nkTernary);
                Node* thenE = parseExpression();
                expect((u16)tokColon);
                Node* elseE = parseExprMinPrec(prec);
                t.add(lhs); t.add(thenE); t.add(elseE);
                lhs = t;
                continue;
            }

            if (prec < minPrec || prec < (i16)0) break;
            Token* opTok = advance();

            if (isAssignTok(opType)) {
                Node* a = mk((u16)nkAssign);
                a.setOp(opTok.value());
                Node* rhs = (Node*)0;
                // Blocks (task #26): `b = { body };` re-binds a block variable;
                // the bare braces inherit the DECLARED signature, names
                // included. Only for a known block binding — a struct
                // initialiser list keeps its meaning everywhere else.
                Map* blkInfo = (Map*)0;
                if (Parser._same(opTok.value(), "=") && check((u16)tokLBrace)
                    && lhs.kind() == (u16)nkIdent) {
                    blkInfo = blkLookup(lhs.name(), (u32*)0);
                    if (blkInfo != 0 && blkBaseOf(blkInfo) == 0) blkInfo = (Map*)0;
                }
                if (blkInfo != 0) {
                    String* base = blkBaseOf(blkInfo);
                    Map* sig = (Map*)_blkBases.get((Hashable*)base);
                    Array* declParams = (Array*)blkInfo.get((Hashable*)String.withCString("params"));
                    if (declParams == 0 && sig != 0)
                        declParams = (Array*)sig.get((Hashable*)String.withCString("params"));
                    String* ret = (sig != 0)
                        ? (String*)sig.get((Hashable*)String.withCString("ret"))
                        : String.withCString("void");
                    rhs = blkParseLiteralBody(base, ret, declParams, (String*)0);
                    if (rhs != 0) blkMarkHoldsWb(lhs.name(), rhs);
                } else {
                    rhs = check((u16)tokLBrace)
                        ? parseInitialiser() : parseExprMinPrec(prec);
                }
                // v2 (task #29): a write-back block stored through a member
                // or subscript outlives its frame — reject; a plain local
                // binding is tracked instead.
                if (blkIsWbValue(rhs)) {
                    if (lhs.kind() == (u16)nkIdent) blkMarkHoldsWb(lhs.name(), rhs);
                    else _error(String.withCString("a block with `block:` captures cannot be stored beyond its frame — its write-back targets a local slot. Write results into an object instead"));
                }
                a.add(lhs); a.add(rhs);
                lhs = a;
                continue;
            }

            Node* b = mk((u16)nkBinary);
            // The OPERATOR's position. mk() takes the token the parser is
            // looking at, which by here is the start of the right-hand side —
            // `s + 1` reported the `1` where the reference reports the `+`.
            if (opTok != 0)
                b.setPos(opTok.fileId(), opTok.line(), opTok.col());
            b.setOp(opTok.value());
            b.add(lhs);
            b.add(parseExprMinPrec(prec + (i16)1));
            lhs = b;
        }
        return lhs;
    }

    // The language is moving from `@` to `*` (`u8@` -> `u8*`, `@p` -> `*p`), so
    // both spellings are accepted while the tree converts. `*` is unambiguous
    // despite also being multiply: a sigil is a suffix in a TYPE or a prefix in
    // an expression, and multiply is infix, so the two never share a position.
    bool isPointerSigil(u16 t)
    {
        return t == (u16)tokAt || t == (u16)tokStar;
    }

    bool matchPointerSigil(void)
    {
        if (!isPointerSigil(curType())) return false;
        advance();
        return true;
    }

    Node* parseUnary(void)
    {
        u16 t = curType();
        if (t == (u16)tokMinus || t == (u16)tokTilde || t == (u16)tokBang
            || t == (u16)tokAmpersand || isPointerSigil(t)
            || t == (u16)tokPlusPlus || t == (u16)tokMinusMinus
            || t == (u16)tokLess || t == (u16)tokByte3) {
            Token* op = advance();
            // The OPERATOR's position. mk() takes the token the parser is
            // looking at, which by here is the operand — so `&x` reported the
            // `x`, one column right of where the reference points. Same rule
            // as the binary node and the subscript bracket.
            Node* n = mk((u16)nkUnary);
            n.setPos(op.fileId(), op.line(), op.col());
            // A dereference is recorded under ONE spelling whichever sigil the
            // source used, because the ObjC parser stores the operator KIND and
            // prints it canonically. Carrying the source text instead made
            // `*p` and `@p` dump differently for the same tree — a divergence
            // in the dump, not in the parse.
            if (isPointerSigil(op.type())) n.setOp(String.withCString("*"));
            else                           n.setOp(op.value());
            n.add(parseUnary());
            return n;
        }
        return parsePostfixFrom(parsePrimary());
    }

    Node* parsePostfixFrom(Node* base)
    {
        if (base == 0) return (Node*)0;
        // The running value lives in a LOCAL, not in the parameter. That was
        // once required: a parameter is a borrowed slot, and assigning a
        // freshly built node into one and returning it handed the caller an
        // object nothing owned — released at scope exit, so the caller's `e`
        // and its next `new Node()` became the SAME object. The compiler now
        // returns every class pointer at +1 (Task #829,
        // tests/fixtures/arc_return_borrowed.xc T2), so this is style rather
        // than necessity — and still the clearer way to write it.
        Node* node = base;
        while (true) {
            u16 t = curType();
            if (t == (u16)tokPlusPlus || t == (u16)tokMinusMinus) {
                Token* op = advance();
                Node* n = mk((u16)nkPostfix);
                n.setOp(op.value());
                n.add(node);
                node = n;
            } else if (t == (u16)tokLBracket) {
                Token* lbTok = advance();
                Node* startE = (Node*)0;
                Node* endE = (Node*)0;
                bool isSlice = false;
                bool inclusive = false;
                if (check((u16)tokDotDot) || check((u16)tokEllipsis)) {
                    inclusive = check((u16)tokEllipsis);
                    advance();
                    isSlice = true;
                    if (!check((u16)tokRBracket)) endE = parseExpression();
                } else {
                    startE = parseExpression();
                    if (check((u16)tokDotDot) || check((u16)tokEllipsis)) {
                        inclusive = check((u16)tokEllipsis);
                        advance();
                        isSlice = true;
                        if (!check((u16)tokRBracket)) endE = parseExpression();
                    }
                }
                expect((u16)tokRBracket);
                Node* n = mk(isSlice ? (u16)nkSlice : (u16)nkSubscript);
                // A subscript node carried NO position. It did not matter until
                // -fbounds-check began naming the site of a failed check: a
                // subscript READ inherited one from the expression around it,
                // while a subscript on the LEFT of an assignment had nothing to
                // inherit and every out-of-bounds store reported `?:0:0`. The
                // bracket is the right place to point at either way.
                if (lbTok != 0) n.setPos(lbTok.fileId(), lbTok.line(), lbTok.col());
                if (inclusive) n.addFlag((u32)NF_INCLUSIVE);
                // `a[..hi]` and `a[lo..]` both carry ONE bound and a missing
                // child is simply absent, so the open-LOW form says so itself.
                if (isSlice && startE == 0) n.addFlag((u32)NF_RANGE_HI);
                n.add(node);
                n.add(startE);
                n.add(endE);
                node = n;
            } else if (t == (u16)tokDot || t == (u16)tokArrow) {
                bool arrow = (t == (u16)tokArrow);
                advance();
                String* member = String.withCString("?");
                if (check((u16)tokIdentifier) || check((u16)tokRelease)
                    || check((u16)tokRetain) || check((u16)tokDelete)) {
                    member = advance().value();
                } else {
                    expect((u16)tokIdentifier);
                }
                Node* n = mkNamed((u16)nkMember, member);
                if (arrow) n.addFlag((u32)NF_ARROW);
                n.add(node);
                node = n;
            } else if (t == (u16)tokLParen) {
                match((u16)tokLParen);          // splits a merged `((`
                Array* args = parseArgList();
                expect((u16)tokRParen);
                Node* n = (Node*)0;
                if (node.kind() == (u16)nkMember) {
                    n = mkNamed((u16)nkMethodCall, node.name());
                    n.add(node.kid((u32)0));           // receiver
                } else if (node.kind() == (u16)nkIdent) {
                    // Blocks (task #26): a call through a block binding is
                    // `.invoke` dispatch; a named literal calling itself
                    // dispatches on `self` (it IS the impl instance).
                    bool isSelfName = false;
                    if (_blkFrames.count() > (u32)0) {
                        Map* fr = (Map*)_blkFrames.get(_blkFrames.count() - (u32)1);
                        Object* sn = fr.get((Hashable*)String.withCString("selfName"));
                        if (sn != 0 && ((String*)sn).equals(node.name())) isSelfName = true;
                    }
                    Map* bInfo = blkLookup(node.name(), (u32*)0);
                    if (isSelfName) {
                        n = mkNamed((u16)nkMethodCall, String.withCString("invoke"));
                        n.add(mkNamed((u16)nkIdent, String.withCString("self")));
                    } else if (bInfo != 0 && blkBaseOf(bInfo) != 0) {
                        blkNoteUse(node.name());
                        n = mkNamed((u16)nkMethodCall, String.withCString("invoke"));
                        n.add(mkNamed((u16)nkIdent, node.name()));
                    } else {
                        n = mkNamed((u16)nkCall, node.name());
                    }
                } else {
                    n = mkNamed((u16)nkCall, String.withCString("<indirect>"));
                }
                for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
                    n.add((Node*)args.get(i));
                n.setNum((i64)args.count());
                // A callee that is not a name — `tbl[0](5)`, `mk()(6)` — rides
                // as the LAST kid, after the arguments, so every existing index
                // (args are 0..num-1) is unchanged and the dump matches the
                // reference's. Sema decides what kind of call it is from the
                // expression's TYPE. private:docs/bugs/074.
                if (n.kind() == (u16)nkCall && Parser._same(n.name(), "<indirect>"))
                    n.add(node);
                if (_sawVarargForward) { n.addFlag((u32)NF_VAFWD); _sawVarargForward = false; }
                node = n;
            } else {
                break;
            }
        }
        return node;
    }

    Array* parseArgList(void)
    {
        Array* args = new Array();
        _sawVarargForward = false;
        if (check((u16)tokRParen)) return args;
        while (!check((u16)tokEOF)) {
            // A literal `...` in the ARGUMENT position is the forwarding form —
            // `printf(fmt, ...)`. It contributes NO argument: on every target
            // but arm9 the values were packed by the original caller and never
            // left that buffer, so forwarding is the absence of a repack. The
            // AST is identical to the same call without it, which is what keeps
            // ast-diff comparing the same thing. private:docs/bugs/047.
            if (match((u16)tokEllipsis)) {
                _sawVarargForward = true;
                if (!match((u16)tokComma)) break;
                continue;
            }
            Node* a = (check((u16)tokLBrace)) ? parseInitialiser() : parseExpression();
            if (a != 0) args.add((Object*)a);
            if (!match((u16)tokComma)) break;
        }
        return args;
    }

    Node* parsePrimary(void)
    {
        u16 t = curType();

        if (t == (u16)tokIntLiteral) {
            Token* tok = advance();
            Node* n = mk((u16)nkInt);
            n.setNum(tok.intValue());
            return n;
        }
        if (t == (u16)tokCharLiteral) {
            Token* tok = advance();
            Node* n = mk((u16)nkChar);
            n.setNum(tok.intValue());
            return n;
        }
        if (t == (u16)tokFloatLiteral) {
            Token* tok = advance();
            Node* n = mkNamed((u16)nkFloat, tok.value());
            n.setNum(tok.intValue());       // 1 when the literal said `d`
            return n;
        }
        if (t == (u16)tokStringLiteral) {
            Token* tok = advance();
            // ADJACENT STRING LITERALS CONCATENATE, as in C: `"ab" "cd"` is
            // `"abcd"`, and a newline between them makes no difference. Done in
            // the PARSER, not the lexer, so the token stream is unchanged and
            // `lexer-diff` still compares the same thing.
            String* joined = String.withCString("");
            joined.append(tok.value());
            while (check((u16)tokStringLiteral)) {
                Token* more = advance();
                joined.append(more.value());
            }
            return mkNamed((u16)nkStr, joined);
        }
        if (t == (u16)tokTrue || t == (u16)tokFalse) {
            advance();
            Node* n = mk((u16)nkBool);
            n.setNum((t == (u16)tokTrue) ? (i64)1 : (i64)0);
            return n;
        }
        if (t == (u16)tokNew) {
            advance();
            String* ty = String.withCString("?");
            if (check((u16)tokIdentifier) || isTypeKeywordToken(curType()))
                ty = advance().value();
            Node* n = mkNamed((u16)nkNew, ty);
            if (match((u16)tokLBracket)) {
                n.add(parseExpression());
                expect((u16)tokRBracket);
            } else if (check((u16)tokLParen)) {
                match((u16)tokLParen);          // splits a merged `((`
                Array* args = parseArgList();
                expect((u16)tokRParen);
                for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
                    n.add((Node*)args.get(i));
                n.setNum((i64)args.count());
            }
            return n;
        }
        if (t == (u16)tokSizeof) {
            advance();
            Node* n = mk((u16)nkSizeof);
            bool paren = match((u16)tokLParen);
            // `sizeof(P)` where P names a type reads as a TYPE, not as an
            // expression: inside the parens, an identifier followed by `)` or
            // by a pointer star can only be a type name.
            bool bareTypeName = check((u16)tokIdentifier)
                             && (checkAt((u32)1, (u16)tokRParen)
                                 || isPointerSigil(peek((u32)1).type())
                                 || checkAt((u32)1, (u16)tokLBracket));
            if (looksLikeType() || isTypeKeywordToken(curType()) || bareTypeName) {
                n.setName(parseTypeSpelling());
            } else {
                n.setName(String.withCString("-"));
                n.add(parseExpression());
            }
            if (paren) expect((u16)tokRParen);
            return n;
        }
        if (t == (u16)tokIdentifier) {
            // Blocks (task #26): `block [name] RET(params) { body }` in
            // expression position is a literal, desugared to `BlkImpl$N.mk(…)`.
            if (blkAhead()) return blkParseLiteralExpression();
            // `va_arg(ap, TYPE)` is SUGAR: the second argument is a type, and
            // the original rewrites the call to the typed intrinsic
            // (`va_arg_u16`, `va_arg_ptr`, …) so nothing downstream has to know
            // about the sugar. One argument survives — the cursor.
            if (Parser._same(cur().value(), "va_arg")
                && checkAt((u32)1, (u16)tokLParen)) {
                advance();
                match((u16)tokLParen);
                Node* call = mkNamed((u16)nkCall, String.withCString("va_arg"));
                Node* cursor = parseExpression();
                call.add(cursor);
                call.setNum((i64)1);
                if (match((u16)tokComma)) {
                    String* ty = parseTypeSpelling();
                    call.setName(vaArgIntrinsic(ty));
                    // Keep the type the user wrote: `va_arg(ap, RGB@)` reads a
                    // STRUCT's bytes, and the analyser has to give the call
                    // back an `RGB@` rather than a bare pointer. Nothing prints
                    // `extra` for a call, so the dump is unchanged.
                    call.setExtra(ty);
                }
                expect((u16)tokRParen);
                return call;
            }
            Token* tok = advance();
            blkNoteUse(tok.value());                    // task #26
            return mkNamed((u16)nkIdent, tok.value());
        }
        // `delete(40, 2)` in EXPRESSION position is a call to a user function
        // of that name — the statement forms are handled in parseStatement.
        if (t == (u16)tokDelete || t == (u16)tokRetain || t == (u16)tokRelease) {
            Token* tok = advance();
            return mkNamed((u16)nkIdent, tok.value());
        }
        if (isTypeKeywordToken(t)) {
            // A bare type keyword in expression position is a static-call
            // receiver (`u16.max`) in the original's grammar; record it as an
            // identifier so the shape matches.
            Token* tok = advance();
            return mkNamed((u16)nkIdent, tok.value());
        }
        if (t == (u16)tokLParen) {
            match((u16)tokLParen);              // splits a merged `((`
            // A cast: `(T)expr` / `(T@ ?)expr`.
            if (looksLikeCast()) {
                String* ty = parseTypeSpelling();
                bool failable = match((u16)tokQuestion);
                expect((u16)tokRParen);
                Node* n = mkNamed((u16)nkCast, ty);
                if (failable) n.addFlag((u32)NF_FAILABLE);
                n.add(parseUnary());
                return n;
            }
            Node* e = parseExpression();
            expect((u16)tokRParen);
            return e;
        }
        if (t == (u16)tokInline && checkAt((u32)1, (u16)tokColon)) {
            advance(); advance();
            return parsePrimary();
        }

        {
            // The reference's words: `Unexpected token ';' in expression`.
            String* msg = String.withCString("Unexpected token '");
            msg.append(tokenText(cur()));
            msg.appendCString("' in expression");
            _error(msg);
        }
        advance();
        return (Node*)0;
    }

    // `(T)` and `(T@ ?)` are casts; `(a + b)` is not. A cast is a type
    // spelling followed immediately by `)` — or by `?)` for the failable form.
    bool looksLikeCast(void)
    {
        // Blocks (task #26): `(block [name] RET(params))expr` is a cast to a
        // block type — the null idiom `(block u32(u32))0`. `callback` (0.5)
        // takes the SAME branch: the two headers have identical shape, so a
        // parallel copy of this scan would be a second thing to keep in step.
        bool castKw = check((u16)tokIdentifier)
                   && (Parser._same(cur().value(), "block")
                       || Parser._same(cur().value(), "callback"));
        if (castKw) {
            u32 j = (u32)1;
            Token* t1 = peek(j);
            if (t1.type() == (u16)tokIdentifier && !isTypeKeywordToken(t1.type())
                && !isTypeName(t1.value())) { j = j + (u32)1; t1 = peek(j); }
            if (!(isTypeKeywordToken(t1.type()) || t1.type() == (u16)tokVoid
                  || isTypeName(t1.value()))) return false;
            j = j + (u32)1;
            while (isPointerSigil(peek(j).type())) j = j + (u32)1;
            if (peek(j).type() != (u16)tokLParen) return false;
            u32 depth = (u32)0;
            while (j < (u32)4096) {
                u16 tt = peek(j).type();
                if (tt == (u16)tokLParen) depth = depth + (u32)1;
                if (tt == (u16)tokRParen) {
                    depth = depth - (u32)1;
                    if (depth == (u32)0) { j = j + (u32)1; break; }
                }
                if (tt == (u16)tokEOF) return false;
                j = j + (u32)1;
            }
            return peek(j).type() == (u16)tokRParen;
        }
        u32 i = (u32)0;
        bool sawQualifier = false;

        // A qualifier run first: `main:`, `weak:`, `banked:` … each optionally
        // followed by a colon. `(main:u8@)p` is a cast, and missing that made
        // the whole expression parse as an identifier.
        while (peek(i).type() == (u16)tokIdentifier && isQualifierWord(peek(i).value())) {
            sawQualifier = true;
            i = i + (u32)1;
            if (peek(i).type() == (u16)tokColon) i = i + (u32)1;
        }

        // Then the type itself: a keyword, or a name the unit declared.
        bool named = false;
        if (isTypeKeywordToken(peek(i).type())) {
            i = i + (u32)1;
            named = true;
        } else if (peek(i).type() == (u16)tokIdentifier && isTypeName(peek(i).value())) {
            i = i + (u32)1;
            named = true;
        } else if (peek(i).type() == (u16)tokIdentifier && sawQualifier) {
            // A qualifier run guarantees a type follows, even an unknown name.
            i = i + (u32)1;
            named = true;
        } else if (peek(i).type() == (u16)tokIdentifier
                   && isPointerSigil(peek(i + (u32)1).type())) {
            // An undefined identifier directly followed by a pointer sigil is
            // an opaque-pointer cast — `(iop*)p`, the incomplete-type idiom
            // (mirrors the reference's looksLikeCastAhead). Guarded tight to
            // the sigil so `(a * b)` — a multiply, where `b` follows the `*`,
            // not `)` — still fails the RParen check below.
            i = i + (u32)1;
            named = true;
        } else {
            return false;
        }

        u32 beforeStars = i;
        if (peek(i).type() == (u16)tokCaret) i = i + (u32)1;   // `sig^` — bound method
        while (isPointerSigil(peek(i).type())) i = i + (u32)1;
        bool hasStar = (i > beforeStars);

        // `(p)` is a parenthesised identifier; `(T@)` is a cast whatever T is;
        // `(T)` is a cast only when T is a keyword or a declared name.
        if (!hasStar && !named && !sawQualifier) return false;

        u16 after = peek(i).type();
        return after == (u16)tokRParen || after == (u16)tokQuestion;
    }

    // The typed va_arg intrinsic for a type spelling. Pointers all collapse to
    // `va_arg_ptr` (a pointer is one packed value on the wire), except a
    // pointer to a STRUCT, which reads the struct's own bytes and so has its
    // own form.
    String* vaArgIntrinsic(String* ty)
    {
        if (ty.byteLength() > (u32)0 && ty.byteAt(ty.byteLength() - (u32)1) == (u8)'*') {
            String* pointee = ty.substringBytes((u32)0, ty.byteLength() - (u32)1);
            // `string` is u8@; the original keeps its own tag for diagnostics.
            if (Parser._same(ty, "u8*")) return String.withCString("va_arg_ptr");
            if (!_structNames.contains((Hashable*)pointee))
                return String.withCString("va_arg_ptr");
            return String.withCString("va_arg_struct_ptr");
        }
        String* out = String.withCString("va_arg_");
        out.append(ty);
        return out;
    }

    static bool _isScalarSpelling(String* ty)
    {
        return Parser._same(ty, "u8")  || Parser._same(ty, "i8")
            || Parser._same(ty, "u16") || Parser._same(ty, "i16")
            || Parser._same(ty, "u32") || Parser._same(ty, "i32")
            || Parser._same(ty, "u64") || Parser._same(ty, "i64")
            || Parser._same(ty, "bool") || Parser._same(ty, "float")
            || Parser._same(ty, "double") || Parser._same(ty, "void")
            || Parser._same(ty, "pointer");
    }

    // Compare a String to a literal without allocating one.
    static bool _same(String* s, string lit)
    {
        u8* a = s.cString();
        u8* b = (u8*)lit;
        u32 i = (u32)0;
        while (b[i] != (u8)0) {
            if (i >= s.byteLength()) return false;
            if (a[i] != b[i]) return false;
            i = i + (u32)1;
        }
        return i == s.byteLength();
    }
}
