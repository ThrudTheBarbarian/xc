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
#import <TokenType>
#import "TokenTypeDefs.xc"
#import <Token>
#import <Node>
#import "NodeDefs.xc"
#import <Lexer>
#import <FloatEncoding>

class Parser
{
    Array*  _tokens;        // of Token@
    // Protocols' static members (bundles step 2), as the reference's
    // blkState pstatics / pstaticOrder / pversion: per protocol, in order, an
    // Array of [ret, name, params, args] Strings; and [major, minor].
    Array*  _pStaticOrder;
    Map*    _pStatics;
    Map*    _pVersion;
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
    u32     _parCounter;    // ParImpl$N numbering (par blocks)
    bool    _parAuto;       // --par-style=auto: a plain loop becomes a par block where its shape allows
    u32     _parAutoCounter; // lifted loops so far
    Map*    _parAutoLabels;  // a lifted loop's file:line -> how many had it
    bool    _parAutoWantsRuntime; // --par-style=auto found a loop to wrap, but Par.xc was not imported
    u32     _loopDepth;     // loops open in the code being parsed (an auto par wraps an outermost one)
    u32     _parAutoDepthReads; // decisions made on _loopDepth so far (parAutoFor)
    u32     _parAutoNest;   // parAutoFor calls open
    Array*  _parAutoLabelLog; // the names _parAutoLabels counted, in order, for parAutoRollback
    String* _parFn;         // the top-level function whose body is being parsed, or 0
    u32     _goalDefault;   // the unit's default goal: 0 built-in, 1 speed, 2 accuracy (#goal, else -fgoal=)
    u32     _scanSeq;       // :scan blocks rewritten so far (#144): their generated names' suffix
    u32     _scanInside;    // parsing what parScanExpand made: its own loops (the short-range one) are not scans again
    bool    _scanQuiet;     // a :scan for --par-style=auto: a loop that does not fit stays a loop, unreported
    String* _parScanAcc;    // the recogniser found a running total (#144): its variable…
    String* _parScanOp;     // …and its operator
    u32     _goalNow;       // the goal of the loop or block being parsed: 0 none yet, 1 speed, 2 accuracy
    u32     _parDeviceDefault; // --par-style's device for a block with no :device (1 cpu, 2 gpu), or 0
    Set*    _libFiles;      // the standard library's and prelude's files, which --par-style=auto leaves alone
    Token*  _parTok;        // the `par` being desugared: where its errors point
    // While set, every node mk/mkNamed builds takes THIS token's position: a
    // block literal's synthesised class is built at the literal, as the
    // reference builds it, not wherever the parse has got to (0 otherwise).
    Token*  _mkAt;
    Map*    _parTopVars;    // the program's globals so far: name -> type spelling
    Map*    _blkBases;      // mangled -> Map{"ret": spelling, "params": Array<Node nkParam>}
    Map*    _blkImplBase;   // impl name -> base name
    Map*    _blkFnRet;      // function name -> return spelling
    Map*    _blkClassIvars; // class -> Set of its own ivar names (capture error)
    Map*    _blkClassParent; // class -> parent class
    Map*    _blkClassMethods; // class -> Set of its method names (bare-call error)
    Map*    _blkClassIvarNames; // class -> Set of the ivar names its body declares (blkScanMethods)
    Map*    _blkClassIvarAt; // class -> ivar name -> [its member's first token, its name's, the name] (blkLaterIvarType)
    String* _blkCurClass;   // the class being parsed, or 0
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
        _parCounter = (u32)0;
        _blkBases   = new Map();
        _blkImplBase = new Map();
        _blkFnRet   = new Map();
        _blkClassIvars = new Map();
        _blkClassParent = new Map();
        _blkClassMethods = new Map();
        _blkClassIvarNames = new Map();
        _blkClassIvarAt = new Map();
        _blkCurClass = (String*)0;
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

    // The ivar names a block in the class being parsed cannot capture: that
    // class's own and its parents' (as far as this parse has seen them). A
    // class's names stay with the class, so a global or a local in code
    // outside it (`u32 key[n];` in main, after a library class with a `key`
    // ivar) is captured like any other name. As the reference.
    void blkAddIvar(String* name)
    {
        if (_blkCurClass == (String*)0) return;
        Set* own = (Set*)_blkClassIvars.get((Hashable*)_blkCurClass);
        if (own == (Set*)0) {
            own = new Set();
            _blkClassIvars.set((Hashable*)String.withString(_blkCurClass), (Object*)own);
        }
        own.add((Hashable*)String.withString(name));
    }

    bool blkIsIvar(String* name)
    {
        // Bounded by the number of classes, which a cycle cannot outrun, not
        // by 64 hops (#334: an ivar 70 classes up was "undefined").
        String* cls = _blkCurClass;
        for (u32 hop = (u32)0; cls != (String*)0 && hop <= _blkClassParent.count(); hop = hop + (u32)1) {
            Set* own = (Set*)_blkClassIvars.get((Hashable*)cls);
            if (own != (Set*)0 && own.contains((Hashable*)name)) return true;
            cls = (String*)_blkClassParent.get((Hashable*)cls);
        }
        return false;
    }

    // The method names of the class whose body starts at the current token
    // (just past its `{`), read from the tokens so a method declared after
    // the one being parsed counts too: at the body's own level, a name
    // followed by `(` that is not in an ivar's initialiser, not after `.` or
    // `:`, and not `since`. As the reference (blkScanMethodNames).
    // The same walk reads the names of the class's ivars, those declared
    // after the method being parsed among them (blkIsLaterIvar): at the body's
    // own level, outside type arguments and initialisers, a name that is not a
    // type, not after `.`, `:` or `<`, and followed by `;`, `,`, `=` or `[`;
    // with where its member starts and where the name is, for its type
    // (blkLaterIvarType).
    void blkScanMethods(void)
    {
        if (_blkCurClass == (String*)0) return;
        Set* own = (Set*)_blkClassMethods.get((Hashable*)_blkCurClass);
        if (own == (Set*)0) {
            own = new Set();
            _blkClassMethods.set((Hashable*)String.withString(_blkCurClass), (Object*)own);
        }
        Set* ivars = (Set*)_blkClassIvarNames.get((Hashable*)_blkCurClass);
        if (ivars == (Set*)0) {
            ivars = new Set();
            _blkClassIvarNames.set((Hashable*)String.withString(_blkCurClass), (Object*)ivars);
        }
        Map* at = (Map*)_blkClassIvarAt.get((Hashable*)_blkCurClass);
        if (at == (Map*)0) {
            at = new Map();
            _blkClassIvarAt.set((Hashable*)String.withString(_blkCurClass), (Object*)at);
        }
        u32 member = 0;
        u32 braces = 0;
        u32 parens = 0;
        u32 angles = 0;
        bool inInit = false;
        bool ivInit = false;
        u16 prev = (u16)tokEOF;
        u32 i = 0;
        while (true) {
            Token* t = peek(i);
            u16 ty = t.type();
            if (ty == (u16)tokEOF) break;
            if (ty == (u16)tokLBrace) {
                braces = braces + 1;
            } else if (ty == (u16)tokRBrace) {
                if (braces == 0) break;
                braces = braces - 1;
                if (braces == 0) {
                    inInit = false;
                    ivInit = false;
                    member = i + 1;
                }
            } else if (braces == 0) {
                if (parens == 0 && !ivInit) {
                    if (ty == tokLess) angles = angles + 1;
                    else if (ty == tokGreater && angles > 0) angles = angles - 1;
                    else if (ty == tokShiftRight) angles = angles > 2 ? angles - 2 : 0;
                    else if (ty == tokSemicolon) angles = 0;
                }
                if (parens == 0 && ty == tokComma && angles == 0) ivInit = false;
                if (ty == (u16)tokLParen) {
                    parens = parens + 1;
                } else if (ty == (u16)tokRParen && parens > 0) {
                    parens = parens - 1;
                } else if (parens == 0 && ty == (u16)tokAssign) {
                    inInit = true;
                    ivInit = true;
                } else if (parens == 0 && ty == (u16)tokSemicolon) {
                    inInit = false;
                    ivInit = false;
                    member = i + 1;
                } else if (parens == 0 && ty == (u16)tokIdentifier && !inInit
                           && prev != (u16)tokDot && prev != (u16)tokColon
                           && peek(i + 1).type() == (u16)tokLParen && !Parser._same(t.value(), "since")) {
                    own.add((Hashable*)String.withString(t.value()));
                }
                if (parens == 0 && angles == 0 && !ivInit && ty == tokIdentifier
                    && prev != tokDot && prev != tokColon && prev != tokLess && !isTypeName(t.value())) {
                    u16 nx = peek(i + 1).type();
                    if (nx == tokSemicolon || nx == tokComma || nx == tokAssign || nx == tokLBracket) {
                        ivars.add((Hashable*)String.withString(t.value()));
                        if (at.get((Hashable*)t.value()) == (Object*)0) {
                            Array* where = new Array();
                            where.add((Object*)Number.with(_pos + member));
                            where.add((Object*)Number.with(_pos + i));
                            where.add((Object*)t);
                            at.set((Hashable*)String.withString(t.value()), (Object*)where);
                        }
                    }
                }
            }
            prev = ty;
            i = i + 1;
        }
    }

    // An ivar of the class being parsed that the parse has not reached yet:
    // its body declares it (blkScanMethods), and no binding names it.
    bool blkIsLaterIvar(String* name)
    {
        if (_blkCurClass == (String*)0) return false;
        Set* ivars = (Set*)_blkClassIvarNames.get((Hashable*)_blkCurClass);
        return ivars != (Set*)0 && ivars.contains((Hashable*)name) && blkLookup(name, (u32*)0) == (Map*)0;
    }

    // The type of an ivar the class declares further down (blkIsLaterIvar),
    // read from its declaration's tokens as the class body will read them:
    // the member's modifiers, its type (a list of them for a tuple), and an
    // array suffix after its name. 0 when the tokens are not the ones the
    // class body was read from. A written par block captures the ivar with
    // it (#513). As the reference.
    String* blkLaterIvarType(String* name)
    {
        if (!blkIsLaterIvar(name)) return (String*)0;
        Map* all = (Map*)_blkClassIvarAt.get((Hashable*)_blkCurClass);
        Array* where = all != (Map*)0 ? (Array*)all.get((Hashable*)name) : (Array*)0;
        if (where == (Array*)0) return (String*)0;
        u32 from = ((Number*)where.get(0)).asU32();
        u32 nameAt = ((Number*)where.get(1)).asU32();
        if (nameAt >= _tokens.count() || _tokens.get(nameAt) != where.get(2)) return (String*)0;
        u32 saved = _pos;
        bool outlet = _lastTypeIsOutlet;
        bool wb = _lastBlkWb;
        String* blkName = _lastBlkName;
        String* blkBase = _lastBlkBase;
        Array* blkParams = _lastBlkParams;
        String* blkRet = _lastBlkRet;
        _pos = from;
        while (true) {
            u16 ty = curType();
            if (ty == tokStatic || ty == tokFinal || ty == tokOptional || ty == tokInline
                || ty == tokVolatile || ty == tokRegister || ty == tokGlobal)
                advance();
            else if (ty == tokIdentifier && Parser._same(cur().value(), "since") && checkAt(1, tokLParen)) {
                while (!check(tokRParen) && !check(tokEOF))
                    advance();
                advance();
            } else
                break;
        }
        String* t = parseTypeSpelling();
        while (check(tokComma) && (isTypeKeywordToken(peek(1).type())
                                   || (peek(1).type() == tokIdentifier && isTypeName(peek(1).value())))) {
            advance();
            t.appendByte(',');
            t.append(parseTypeSpelling());
        }
        _pos = nameAt + 1;
        t = memberTypeSuffix(t);
        _pos = saved;
        _lastTypeIsOutlet = outlet;
        _lastBlkWb = wb;
        _lastBlkName = blkName;
        _lastBlkBase = blkBase;
        _lastBlkParams = blkParams;
        _lastBlkRet = blkRet;
        return t;
    }

    // A method of the class being parsed or of a parent (blkScanMethods).
    bool blkIsMethod(String* name)
    {
        String* cls = _blkCurClass;
        for (u32 hop = (u32)0; cls != (String*)0 && hop <= _blkClassParent.count(); hop = hop + (u32)1) {
            Set* own = (Set*)_blkClassMethods.get((Hashable*)cls);
            if (own != (Set*)0 && own.contains((Hashable*)name)) return true;
            cls = (String*)_blkClassParent.get((Hashable*)cls);
        }
        return false;
    }

    // A bare call `m(…)` in a block or par body, `m` a method of the
    // enclosing class and no local or parameter: it means `self.m(…)`, and a
    // block cannot capture self. Said here, as `self.m(…)` is, rather than
    // left to sema, which reads the body outside the class and reports `m`
    // undeclared; under --par-style=auto the error takes the block form back
    // and the loop stays a loop. As the reference (blkNoteBareCall).
    void blkNoteBareCall(Node* callee)
    {
        if (_blkFrames.count() == 0) return;
        blkBareCallCheck(callee);
    }

    // blkNoteBareCall's test and error, inside a frame.
    void blkBareCallCheck(Node* callee)
    {
        String* name = callee.name();
        if (blkLookup(name, (u32*)0) != 0 || !blkIsMethod(name)) return;
        _errorAt(String.withFormat("a block cannot call the method '%s': it needs 'self', and a block cannot capture 'self' (v1 captures locals and parameters only) — copy it into a local first, e.g. `auto me = self;` outside the block", name.cString()), callee);
    }

    // In a par body, `self.f` (not a call) where `f` resolves to this class's
    // own ivar binding is read as that ivar: what a bare `f` already means
    // there, a capture of its value, which a GPU can take. Writing it then
    // gets par's own-copy error (auto keeps the loop), and `self.m()` or a
    // bare `self` stay refused: a block cannot hold the object, and running
    // methods in parallel is not safe to do automatically. A local or
    // parameter named `f` binds in an inner scope without the ivar mark, so
    // `self.f` is left alone there. The field's name, or 0.
    String* parSelfIvar(void)
    {
        if (_blkFrames.count() == (u32)0) return (String*)0;
        Map* fr = (Map*)_blkFrames.get(_blkFrames.count() - (u32)1);
        if (fr.get((Hashable*)String.withCString("par")) == (Object*)0) return (String*)0;
        if (!Parser._same(peek((u32)0).value(), "self")) return (String*)0;
        if (peek((u32)1).type() != (u16)tokDot || peek((u32)2).type() != (u16)tokIdentifier) return (String*)0;
        if (peek((u32)3).type() == (u16)tokLParen) return (String*)0;
        String* f = peek((u32)2).value();
        Map* info = blkLookup(f, (u32*)0);
        if (info == 0 || info.get((Hashable*)String.withCString("ivar")) == (Object*)0) return (String*)0;
        return f;
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
    // the literal's own scopes is a capture, first-use order. A `par` body's
    // frame is computed from its tree once it is parsed (parFrameWalk); for
    // one, this only says at once what cannot be captured, where the error
    // belongs among the parse's others.
    void blkNoteUse(String* name)
    {
        if (_blkFrames.count() == (u32)0) return;
        Map* frame = (Map*)_blkFrames.get(_blkFrames.count() - (u32)1);
        bool isPar = frame.get((Hashable*)String.withCString("par")) != (Object*)0;
        u32 literalDepth = ((Number*)frame.get((Hashable*)String.withCString("depth"))).asU32();
        u32 foundDepth = (u32)0;
        Map* info = blkLookup(name, &foundDepth);
        if (info == 0) {
            if (Parser._same(name, "self") || blkIsIvar(name))
                _error(Parser.blkSelfMsg(name));
            return;
        }
        if (foundDepth >= literalDepth) return;
        Array* names = (Array*)frame.get((Hashable*)String.withCString("names"));
        if (!isPar)
            for (u32 i = 0; i < names.count(); i++)
                if (((String*)names.get(i)).equals(name)) return;
        String* ty = blkTyOf(info);
        if (Parser._same(ty, "auto")) {
            _error(Parser.blkAutoMsg(name));
            return;
        }
        // v2 (task #29): write-back captures reach the enclosing FRAME, so
        // they do not compose through nested literals.
        if (info.get((Hashable*)String.withCString("wb")) != 0) {
            if (_blkFrames.count() > (u32)1) {
                _error(Parser.blkWbMsg(name));
                return;
            }
            if (isPar) return;
            ((Array*)frame.get((Hashable*)String.withCString("wbnames"))).add((Object*)name);
        }
        if (isPar) return;
        names.add((Object*)name);
        ((Map*)frame.get((Hashable*)String.withCString("types"))).set((Hashable*)name, (Object*)ty);
    }

    // blkNoteUse's errors, which the walk of a lifted loop's copy also says
    // (pfwUse).
    static String* blkSelfMsg(String* name)
    {
        return String.withFormat("a block cannot capture '%s' (v1 captures locals and parameters only) — copy it into a local first, e.g. `auto me = self;` outside the block", name.cString());
    }
    static String* blkAutoMsg(String* name)
    {
        return String.withFormat("cannot capture '%s': it was declared `auto`, and a capture needs the declared type at this point — give it an explicit type", name.cString());
    }
    static String* blkLaterIvarMsg(String* name)
    {
        return String.withFormat("a block cannot capture '%s' here: the class declares it further down, and a capture needs its declaration first — declare it above this method", name.cString());
    }
    static String* blkWbMsg(String* name)
    {
        return String.withFormat("a `block:` capture of '%s' inside a nested block is not supported (v2) — write-back reaches the enclosing FRAME, and here the enclosing scope is itself a block", name.cString());
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
            // The reference builds these at the PROGRAM's position (its first
            // token), not where the parse ended; -g gives the invoke body it.
            restampTree(cls, program);
            program.add(cls);
        }
        for (u32 i = (u32)0; i < _blkClasses.count(); i = i + (u32)1)
            program.add((Node*)_blkClasses.get(i));
    }

    // `n` and everything under it at `at`'s position.
    void restampTree(Node* n, Node* at)
    {
        if (n == 0) return;
        n.setPos(at.fileId(), at.line(), at.col());
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1) restampTree(n.kid(i), at);
    }

    // Parse a literal's body (cursor on `{`) and synthesise its impl class.
    // Returns the replacement expression: `BlkImpl$N.mk(captures…)`.
    // `at` is where the reference builds the impl class and the replacement
    // call: the literal's start, the `=` of a re-binding, or the declaration.
    Node* blkParseLiteralBody(String* baseName, String* ret, Array* params, String* selfName, Token* at)
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
        // Everything from here on is synthesised, and placed at `at`.
        Token* savedMkAt = _mkAt;
        _mkAt = at;
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
        Node* implRef = mkNamed(nkIdent, String.withString(implName));
        implRef.addSrc(SRC_SYNTH);
        mkCall.add(implRef);
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
            addr.addSrc(SRC_SYNTH);
            mkCall.add(addr);
        }
        mkCall.setNum((i64)(capNames.count() + wbNames.count()));
        if (wbNames.count() > (u32)0)
            _blkWbImpls.add((Hashable*)String.withString(implName));
        _mkAt = savedMkAt;
        pfwRegister(mkCall, body, params, (Array*)0, 0, (Node*)0);
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
        Token* at = cur();
        blkParseHeader();
        String* name = _lastBlkName;
        String* base = _lastBlkBase;
        Array* params = _lastBlkParams;
        String* ret = _lastBlkRet;
        if (!checkBlockOpen()) {
            _error(String.withCString("expected '{' to open the block's body (a bare block type is not an expression)"));
            return (Node*)0;
        }
        return blkParseLiteralBody(base, ret, params, name, at);
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
    // An imported `typedef <target> <alias>;`: the alias is substituted at
    // parse time like a source typedef, so it needs its target here too.
    void addTypedef(String* alias, String* target)
    {
        if (alias == 0 || target == 0) return;
        _typedefs.set((Hashable*)String.withString(alias), (Object*)String.withString(target));
        _typeNames.add((Hashable*)String.withString(alias));
    }

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
    void setParAuto(bool b) { _parAuto = b; }
    // The front end then parses again with the runtime imported.
    bool parAutoWantsRuntime(void) { return _parAutoWantsRuntime; }
    // XC_PAR_AUTO_TRACE: one line for each loop --par-style=auto looks at,
    // which the front end prints once the parse is final (parAutoTraceLine).
    bool    _parAutoTraceOn;
    Array*  _parAutoTrace;     // its lines; a trace line's `#n` is given when they are read (parAutoTrace)
    String* _parAutoWhy;       // the rule that kept the loop the recogniser last read serial
    u32     _parAutoGridCap;   // the grid levels its nest may take (parAutoGridCap)
    bool    _parAutoFromWhile; // parAutoFor's loop was a `while` (parAutoWhileShape)
    void setParAutoTrace(bool b) { _parAutoTraceOn = b; }
    // The lines in order. A trace line is kept as `file:line`, a tab and the
    // rest, and the n-th line at a place (n > 1) is named `file:line#n` here,
    // so a loop's line can go where the loop starts after the lines of the
    // loops inside it (parAutoFor).
    Array* parAutoTrace(void)
    {
        if (_parAutoTrace == (Array*)0) return (Array*)0;
        Array* out = new Array();
        Map* seen = new Map();
        String* pre = String.withCString("par-auto-trace: ");
        for (u32 i = 0; i < _parAutoTrace.count(); i++) : serial {
            String* l = (String*)_parAutoTrace.get(i);
            u32 tab = l.byteIndexOf(String.withCString("\t"));
            if (!l.hasPrefix(pre) || tab == String.notFound()) {
                out.add((Object*)l);
                continue;
            }
            String* pos = l.substringBytes(pre.byteLength(), tab - pre.byteLength());
            Number* n = (Number*)seen.get((Hashable*)pos);
            u32 nth = n != (Number*)0 ? n.asU32() + 1 : 1;
            seen.set((Hashable*)pos, (Object*)Number.with(nth));
            String* o = String.withString(pre);
            o.append(pos);
            if (nth > 1) {
                o.appendByte('#');
                o.append(String.withU32(nth));
            }
            o.appendByte(' ');
            o.append(l.substringFromByte(tab + 1));
            out.add((Object*)o);
        }
        return out;
    }
    // wasm32: a module's memory is its own, so a protocol's static members
    // are calls BETWEEN modules and may pass only numbers, or a buffer and its
    // length (the reference's webModules).
    bool _webModules;
    void setWebModules(bool b) { _webModules = b; }
    String* _webBad;
    void setGoalDefault(u32 g) { _goalDefault = g; }
    void setParDeviceDefault(u32 d) { _parDeviceDefault = d; }
    void setLibraryFiles(Set* files) { _libFiles = files; }

    void _error(String* msg)
    {
        _errorAtTok(msg, cur());
    }

    // As `_error`, at a given token: the statement's own keyword, say, where
    // the reference reports it rather than where parsing stopped.
    void _errorAtTok(String* msg, Token* t)
    {
        String* out = String.withCString("");
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

    // As `_error`, at a node's own position rather than the token the parser
    // stopped at. The reference reports an array size that does not fold at
    // the size expression (the operator of `Q + 1`), not after it. The node
    // is in the current token's file.
    void _errorAt(String* msg, Node* n)
    {
        Token* t = cur();
        if (n == (Node*)0 || n.line() == (u32)0 || t == (Token*)0) {
            _error(msg);
            return;
        }
        String* out = String.withCString("");
        if (t.file() != (String*)0) { out.append(t.file()); } else { out.appendCString("?"); }
        out.appendByte((u8)':');
        out.append(String.withU32(n.line()));
        out.appendByte((u8)':');
        out.append(String.withU32(n.col()));
        out.appendCString(": error: ");
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
        if (foldIntConst(sz, &v) && v >= (i64)0 && v > (i64)$FFFFFFFF)
            {
            // Past 32 bits the count wrapped, and the array with it (#293).
            String* m = String.withCString("an array of ");
            m.appendFormat("%lld", v);
            m.appendCString(" elements is past 4 GB; allocate it with new T[n] (heap arrays take any size on the 64-bit targets)");
            _errorAt(m, sz);
            _fatal = true;
            }
        else if (foldIntConst(sz, &v) && v >= (i64)0)
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
        _errorAt(m, sz);
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
        Token* t = _mkAt != (Token*)0 ? _mkAt : cur();
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
        if (_mkAt != (Token*)0)
            t = _mkAt;
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
        rewriteProtocolStaticReceivers();
        Node* program = mk((u16)nkProgram);
        while (!check((u16)tokEOF) && !_fatal) {
            u32 before = _pos;
            Node* decl = parseTopLevel();
            if (decl != 0) program.add(decl);
            // The program's globals so far, by name: a `par` body that uses
            // one gets it on the GPU as a buffer (gpuGlobal, parDesugar).
            if (decl != 0 && decl.kind() == (u16)nkVariableDecl && decl.op() != 0 && decl.name() != 0) {
                if (_parTopVars == (Map*)0) _parTopVars = new Map();
                _parTopVars.set((Hashable*)decl.name(), (Object*)decl.op());
            }
            // Never spin: if a production consumed nothing, step over the
            // token so a malformed file still terminates.
            if (_pos == before) advance();
        }
        blkAppendSynthesised(program);               // task #26
        protocolCompanions(program);                 // bundles step 2
        return program;
    }

    // Static members of a protocol (bundles-and-plugins.md §3): `P.f(args)`
    // goes to the companion class `_XtP_P`, synthesised after the program —
    // forwarding to the class that conforms to P and defines every member
    // (the host), else calling through the table bind() was given (a
    // plugin). As the reference's rewriteProtocolStaticReceivers /
    // protocolCompanionsFor, text for text.
    void rewriteProtocolStaticReceivers(void)
    {
        u32 n = _tokens.count();
        Map* withStatics = new Map();
        for (u32 i = (u32)0; i + (u32)1 < n; i = i + (u32)1) {
            Token* t = (Token*)_tokens.get(i);
            Token* nt = (Token*)_tokens.get(i + (u32)1);
            if (t.type() != (u16)tokProtocol || nt.type() != (u16)tokIdentifier) continue;
            u32 j = i + (u32)2;
            while (j < n && ((Token*)_tokens.get(j)).type() != (u16)tokLBrace) j = j + (u32)1;
            i32 depth = (i32)0;
            while (j < n) {
                u16 ty = ((Token*)_tokens.get(j)).type();
                if (ty == (u16)tokLBrace) depth = depth + (i32)1;
                else if (ty == (u16)tokRBrace) {
                    depth = depth - (i32)1;
                    if (depth == (i32)0) break;
                } else if (ty == (u16)tokStatic && depth == (i32)1) {
                    withStatics.set((Hashable*)nt.value(), (Object*)nt.value());
                }
                j = j + (u32)1;
            }
        }
        if (withStatics.count() == (u32)0) return;
        for (u32 i = (u32)0; i + (u32)1 < n; i = i + (u32)1) {
            Token* t = (Token*)_tokens.get(i);
            if (t.type() != (u16)tokIdentifier || ((Token*)_tokens.get(i + (u32)1)).type() != (u16)tokDot) continue;
            if (withStatics.get((Hashable*)t.value()) == (Object*)0) continue;
            if (i > (u32)0) {
                u16 pt = ((Token*)_tokens.get(i - (u32)1)).type();
                if (pt == (u16)tokDot || pt == (u16)tokProtocol) continue;
            }
            String* nm = String.withCString("_XtP_");
            nm.append(t.value());
            _tokens.replaceAt(i, (Object*)Token.with((u16)tokIdentifier, nm, t.line(), t.col()));
        }
    }

    // Whether the comma list `list` names p.
    static bool listHas(String* list, String* p)
    {
        u32 at = (u32)0;
        while (at <= list.byteLength()) {
            u32 e = at;
            while (e < list.byteLength() && list.byteAt(e) != (u8)',') e = e + (u32)1;
            if (list.substringBytes(at, e - at).equals(p)) return true;
            at = e + (u32)1;
        }
        return false;
    }

    // What the last parse's protocols with static members were: name ->
    // ["M.m", "provides" | "requires"], for `xcc --bundle`'s manifest.
    static Map* _protocolsSeen;
    static Map* protocolsSeen(void) { return _protocolsSeen; }

    void protocolCompanions(Node* program)
    {
        if (_pStaticOrder == (Array*)0 || _pStaticOrder.count() == (u32)0) return;
        if (_protocolsSeen == (Map*)0) _protocolsSeen = new Map();
        String* src = new String();
        bool webBind = false;
        for (u32 pi = (u32)0; pi < _pStaticOrder.count(); pi = pi + (u32)1) {
            String* P = (String*)_pStaticOrder.get(pi);
            Array* ms = (Array*)_pStatics.get((Hashable*)P);
            String* provider = (String*)0;
            for (u32 d = (u32)0; d < program.kidCount() && provider == (String*)0; d = d + (u32)1) {
                Node* c = program.kid(d);
                if (c.kind() != (u16)nkClassDecl || c.extra() == (String*)0 || !Parser.listHas(c.extra(), P)) continue;
                bool all = true;
                for (u32 m = (u32)0; m < ms.count(); m = m + (u32)1) {
                    String* want = (String*)((Array*)ms.get(m)).get((u32)1);
                    bool found = false;
                    for (u32 k = (u32)0; k < c.kidCount(); k = k + (u32)1) {
                        Node* cm = c.kid(k);
                        if (cm.kind() == (u16)nkMethodDecl && (cm.flags() & (u32)NF_STATIC) != (u32)0 && cm.name().equals(want))
                            found = true;
                    }
                    if (!found) all = false;
                }
                if (all) provider = c.name();
            }
            Array* v = _pVersion == (Map*)0 ? (Array*)0 : (Array*)_pVersion.get((Hashable*)P);
            Array* rec = new Array();
            String* vs = String.withString(v == (Array*)0 ? String.withCString("0") : (String*)v.get((u32)0));
            vs.appendByte((u8)'.');
            vs.append(v == (Array*)0 ? String.withCString("0") : (String*)v.get((u32)1));
            rec.add((Object*)vs);
            rec.add((Object*)String.withCString(provider != (String*)0 ? "provides" : "requires"));
            _protocolsSeen.set((Hashable*)P, (Object*)rec);
            String* C = String.withCString("_XtP_");
            C.append(P);
            // wasm32: the provider's members are exports (with their shape and
            // scratch memory for the loader's bridge); with no provider, each is
            // an import of namespace P and bind(t) names the plugin answering it.
            if (_webModules && provider != (String*)0) {
                String* shape = new String();
                for (u32 m = (u32)0; m < ms.count(); m = m + (u32)1) {
                    Array* e = (Array*)ms.get(m);
                    String* ret = (String*)e.get((u32)0);
                    bool isVoid = ret.equals(String.withCString("void"));
                    src.appendFormat("extern %s %s__%s(%s) { %s%s.%s(%s); }\n", ret.cString(), C.cString(),
                                     ((String*)e.get((u32)1)).cString(), ((String*)e.get((u32)2)).cString(),
                                     isVoid ? "" : "return ", provider.cString(), ((String*)e.get((u32)1)).cString(),
                                     ((String*)e.get((u32)3)).cString());
                    if (shape.byteLength() > (u32)0) shape.appendByte((u8)';');
                    shape.append((String*)e.get((u32)1));
                    shape.appendByte((u8)':');
                    shape.append((String*)e.get((u32)4));
                }
                src.appendFormat("extern u8* %s__shape(void) { return \"%s\"; }\n", C.cString(), shape.cString());
                src.appendFormat("extern u8* %s__alloc(u32 n) { return new u8[n]; }\n", C.cString());
                src.appendFormat("extern void %s__free(u8* p) { delete p; }\n", C.cString());
            }
            if (_webModules && provider == (String*)0) {
                if (!webBind) {
                    src.appendCString("package xcplugin;\nvoid _xt_proto_bind(u8* ns, u32 n, pointer t);\npackage __none;\n");
                    webBind = true;
                }
                src.appendFormat("package %s;\n", P.cString());
                for (u32 m = (u32)0; m < ms.count(); m = m + (u32)1) {
                    Array* e = (Array*)ms.get(m);
                    src.appendFormat("%s %s__%s(%s);\n", ((String*)e.get((u32)0)).cString(), C.cString(),
                                     ((String*)e.get((u32)1)).cString(), ((String*)e.get((u32)2)).cString());
                }
                src.appendCString("package __none;\n");
            }
            if (provider == (String*)0 && !_webModules)
                for (u32 m = (u32)0; m < ms.count(); m = m + (u32)1) {
                    Array* e = (Array*)ms.get(m);
                    src.appendFormat("typedef %s %s_%s_t(%s);\n", ((String*)e.get((u32)0)).cString(), C.cString(),
                                     ((String*)e.get((u32)1)).cString(), ((String*)e.get((u32)2)).cString());
                }
            src.appendFormat("class %s\n{\n", C.cString());
            if (provider != (String*)0)
                src.appendCString("static pointer* _impl;\n");
            else if (_webModules)
                src.appendFormat("static pointer _table;\nstatic void bind(pointer t) { _table = t; _xt_proto_bind(\"%s\", (u32)%lu, t); }\n"
                                 "static pointer table(void) { return _table; }\n", P.cString(), P.byteLength());
            else
                src.appendCString("static pointer _table;\nstatic void bind(pointer t) { _table = t; }\n"
                                  "static pointer table(void) { return _table; }\n");
            for (u32 m = (u32)0; m < ms.count(); m = m + (u32)1) {
                Array* e = (Array*)ms.get(m);
                String* ret = (String*)e.get((u32)0);
                String* nm = (String*)e.get((u32)1);
                String* params = (String*)e.get((u32)2);
                String* args = (String*)e.get((u32)3);
                bool isVoid = ret.equals(String.withCString("void"));
                if (provider == (String*)0 && _webModules)
                    src.appendFormat("static %s %s(%s) { %s%s__%s(%s); }\n", ret.cString(), nm.cString(), params.cString(),
                                     isVoid ? "" : "return ", C.cString(), nm.cString(), args.cString());
                else if (provider != (String*)0)
                    src.appendFormat("static %s %s(%s) { %s%s.%s(%s); }\n", ret.cString(), nm.cString(), params.cString(),
                                     isVoid ? "" : "return ", provider.cString(), nm.cString(), args.cString());
                else
                    src.appendFormat("static %s %s(%s) { %s_%s_t* fn = (%s_%s_t*)((pointer*)_table)[%lu]; %sfn(%s); }\n",
                                     ret.cString(), nm.cString(), params.cString(), C.cString(), nm.cString(),
                                     C.cString(), nm.cString(), m, isVoid ? "" : "return ", args.cString());
            }
            if (provider != (String*)0) {
                src.appendFormat("static pointer table(void)\n{\nif (_impl == (pointer*)0) { _impl = new pointer[%lu];", ms.count());
                for (u32 m = (u32)0; m < ms.count(); m = m + (u32)1)
                    src.appendFormat(" _impl[%lu] = (pointer)&%s.%s;", m, provider.cString(),
                                     ((String*)((Array*)ms.get(m)).get((u32)1)).cString());
                src.appendCString(" }\nreturn (pointer)_impl;\n}\n");
            }
            src.appendFormat("static u32 versionMajor(void) { return (u32)%s; }\nstatic u32 versionMinor(void) { return (u32)%s; }\n}\n",
                             v == (Array*)0 ? "0" : ((String*)v.get((u32)0)).cString(),
                             v == (Array*)0 ? "0" : ((String*)v.get((u32)1)).cString());
        }
        Lexer* lx = Lexer.with(src, String.withCString("<protocol-companions>"));
        Parser* sub = Parser.with(lx.tokenise());
        Node* prog = sub.parse();
        if (prog == (Node*)0) return;
        for (u32 i = (u32)0; i < prog.kidCount(); i = i + (u32)1)
            program.add(prog.kid(i));
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
        // `use Klass;` — `use` is CONTEXTUAL (an identifier everywhere else,
        // so a parameter may be called use): the directive is exactly
        // `use NAME ;` at the top level of a file. As the reference.
        if (check((u16)tokIdentifier) && peek((u32)0).value().equals(String.withCString("use"))
            && checkAt((u32)1, (u16)tokIdentifier) && checkAt((u32)2, (u16)tokSemicolon))
            return parseUseDecl();
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
            || Parser._same(w, "weak") || Parser._same(w, "outlet")
            || Parser._same(w, "simd");
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
        bool sawSimd = false;
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
            // `simd`: the pointee's storage is page-aligned and GPU-reachable
            // (par-blocks.md); like `weak`, a qualifier on the pointer.
            else if (Parser._same(q, "simd")) sawSimd = true;
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
                    // In a copy: a stream that is parsed again (the copy of a
                    // loop --par-style=auto lifts) still reads `>>` there.
                    _tokens = _tokens.subarray(0, _tokens.count());
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
                if (sawSimd) pfx.appendCString("simd:");
                pfx.append(out);
                out = pfx;
                firstPointer = false;
            }
            out.appendByte((u8)'*');
        }

        if (match((u16)tokLBracket)) {
            String* dims = String.withCString("[");
            if (!check((u16)tokRBracket)) {
                // A bound that folds (`[4 + 1]` once a macro has expanded)
                // is its count; anything else is recorded verbatim (see the
                // header note).
                i64 v = (i64)0;
                Node* e = parseExpression();
                if (foldIntConst(e, &v) && v >= (i64)0)
                    dims.append(String.withU32((u32)v));
                else
                    dims.append((e != 0 && e.name() != 0) ? e.name()
                                                          : String.withCString("?"));
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
                // A variadic signature — `typedef void log_t(i32 n, ...);` —
                // ends in `...`, spelled as XTFunctionType spells it.
                if (match((u16)tokEllipsis)) { sig.appendCString("..."); break; }
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
                        if (!check((u16)tokRBracket)) appendArraySize(fieldTy);
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
        // The class's ivars are its own: a block in it cannot capture them
        // (nor its parents'), and code outside it captures those names.
        String* savedCls = _blkCurClass;
        _blkCurClass = nameTok == 0 ? (String*)0 : nameTok.value();
        if (_blkCurClass != (String*)0 && !Parser._same(parent, "-"))
            _blkClassParent.set((Hashable*)String.withString(_blkCurClass), (Object*)String.withString(parent));

        // Ivars are printed before methods, matching the original's ordering,
        // so they are collected separately and appended in that order.
        Array* ivars = new Array();
        Array* methods = new Array();
        if (openBlock()) {
            blkPushScope();                          // class scope (task #26)
            blkScanMethods();
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
        _blkCurClass = savedCls;
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
        // `:version(major.minor)` (bundles step 2).
        if (nameTok != 0 && check((u16)tokColon) && checkAt((u32)1, (u16)tokIdentifier)
            && peek((u32)1).value().equals(String.withCString("version"))) {
            advance();
            advance();
            expect((u16)tokLParen);
            String* vt = advance().value();
            u32 dot = vt.indexOfByte((u8)'.');
            Array* v = new Array();
            if (dot == String.notFound()) {
                v.add((Object*)String.withI64(Parser.decimal(vt)));
                v.add((Object*)String.withCString("0"));
            } else {
                v.add((Object*)String.withI64(Parser.decimal(vt.substringBytes((u32)0, dot))));
                v.add((Object*)String.withI64(Parser.decimal(vt.substringFromByte(dot + (u32)1))));
            }
            if (_pVersion == (Map*)0) _pVersion = new Map();
            _pVersion.set((Hashable*)nameTok.value(), (Object*)v);
            expect((u16)tokRParen);
        }
        if (openBlock()) {
            while (!closeBlockAhead() && !check((u16)tokEOF)) {
                if (match((u16)tokSemicolon)) continue;
                // A static member: the companion's, kept as text (as the reference).
                if (nameTok != 0 && check((u16)tokStatic)) {
                    u32 from = _pos + (u32)1;
                    Node* sm = parseMember();
                    u32 to = _pos;
                    if (sm == (Node*)0 || sm.kind() != (u16)nkMethodDecl) continue;
                    protocolStatic(nameTok.value(), sm, from, to);
                    while (_pendingMembers.count() > (u32)0) _pendingMembers.removeAt((u32)0);
                    continue;
                }
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

    // The leading decimal digits of s.
    static i64 decimal(String* s)
    {
        i64 v = (i64)0;
        for (u32 i = (u32)0; i < s.byteLength() && s.byteAt(i) >= (u8)'0' && s.byteAt(i) <= (u8)'9'; i = i + (u32)1)
            v = v * (i64)10 + (i64)(s.byteAt(i) - (u8)'0');
        return v;
    }

    // Record a protocol's static member: its return type's tokens (before the
    // name), its parameters' tokens, and its parameter names.
    // A static member's shape between web modules, from its tokens: one
    // letter a parameter (v a number, p a pointer to numbers whose count is
    // the next parameter, n that count), then ':' and the result (v, or -
    // for none). _webBad names the first type that is none of these.
    static bool isWebNumber(String* t)
    {
        return Parser._same(t, "i8") || Parser._same(t, "u8") || Parser._same(t, "i16") || Parser._same(t, "u16")
            || Parser._same(t, "i32") || Parser._same(t, "u32") || Parser._same(t, "i64") || Parser._same(t, "u64")
            || Parser._same(t, "float") || Parser._same(t, "double") || Parser._same(t, "bool");
    }

    static String* joinToks(Array* a, u32 n)
    {
        String* r = new String();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            r.append((String*)a.get(i));
        return r;
    }

    String* webKinds(Array* params, Array* ret)
    {
        Array* ps = new Array();
        Array* cur = new Array();
        for (u32 i = (u32)0; i < params.count(); i = i + (u32)1) {
            String* t = (String*)params.get(i);
            if (Parser._same(t, ",")) {
                ps.add((Object*)cur);
                cur = new Array();
                continue;
            }
            cur.add((Object*)t);
        }
        if (cur.count() > (u32)0 && !(cur.count() == (u32)1 && Parser._same((String*)cur.get((u32)0), "void")))
            ps.add((Object*)cur);
        String* k = new String();
        for (u32 i = (u32)0; i < ps.count(); i = i + (u32)1) {
            Array* p = (Array*)ps.get(i);
            u32 stars = (u32)0;
            for (u32 j = (u32)0; j + (u32)1 < p.count(); j = j + (u32)1)
                if (Parser._same((String*)p.get(j), "*")) stars = stars + (u32)1;
            String* base = p.count() > (u32)1 ? (String*)p.get((u32)0) : String.withCString("");
            String* type = Parser.joinToks(p, p.count() > (u32)0 ? p.count() - (u32)1 : (u32)0);
            if (k.byteLength() > (u32)0 && k.byteAt(k.byteLength() - (u32)1) == (u8)'p') {
                if (stars == (u32)0 && Parser.isWebNumber(base) && !Parser._same(base, "float")
                    && !Parser._same(base, "double") && !Parser._same(base, "bool")) {
                    k.appendByte((u8)'n');
                    continue;
                }
                if (_webBad == (String*)0) {
                    _webBad = String.withString(type);
                    _webBad.appendCString(" (the buffer's count)");
                }
                k.appendByte((u8)'?');
                continue;
            }
            if (stars == (u32)0 && Parser.isWebNumber(base))
                k.appendByte((u8)'v');
            else if (stars == (u32)1 && Parser.isWebNumber(base) && i + (u32)1 < ps.count())
                k.appendByte((u8)'p');
            else {
                if (_webBad == (String*)0) _webBad = type;
                k.appendByte((u8)'?');
            }
        }
        String* r = Parser.joinToks(ret, ret.count());
        if (Parser._same(r, "void"))
            k.appendCString(":-");
        else if (ret.count() == (u32)1 && Parser.isWebNumber(r))
            k.appendCString(":v");
        else {
            if (_webBad == (String*)0) _webBad = r;
            k.appendCString(":?");
        }
        return k;
    }

    void protocolStatic(String* P, Node* m, u32 from, u32 to)
    {
        String* ret = new String();
        Array* retToks = new Array();
        Array* paramToks = new Array();
        u32 q = from;
        while (q < to) {
            Token* t = (Token*)_tokens.get(q);
            if (t.type() == (u16)tokIdentifier && t.value().equals(m.name()) && q + (u32)1 < to
                && ((Token*)_tokens.get(q + (u32)1)).type() == (u16)tokLParen)
                break;
            if (ret.byteLength() > (u32)0) ret.appendByte((u8)' ');
            ret.append(t.value());
            retToks.add((Object*)t.value());
            q = q + (u32)1;
        }
        String* params = new String();
        i32 depth = (i32)0;
        q = q + (u32)1;
        while (q < to) {
            Token* t = (Token*)_tokens.get(q);
            if (t.type() == (u16)tokLParen) {
                depth = depth + (i32)1;
                if (depth == (i32)1) { q = q + (u32)1; continue; }
            }
            if (t.type() == (u16)tokRParen) {
                depth = depth - (i32)1;
                if (depth == (i32)0) break;
            }
            if (params.byteLength() > (u32)0) params.appendByte((u8)' ');
            params.append(t.value());
            paramToks.add((Object*)t.value());
            q = q + (u32)1;
        }
        _webBad = (String*)0;
        String* kinds = webKinds(paramToks, retToks);
        if (_webModules && _webBad != (String*)0) {
            String* msg = String.withFormat("%s.%s: a protocol's static member called between "
                                            "web modules passes numbers, or a pointer to numbers "
                                            "followed by their count; '%s' is neither",
                                            P.cString(), m.name().cString(), _webBad.cString());
            _errorAt(msg, m);
        }
        String* args = new String();
        for (u32 k = (u32)0; k < m.kidCount(); k = k + (u32)1) {
            Node* pn = m.kid(k);
            if (pn.kind() != (u16)nkParam) continue;
            if (args.byteLength() > (u32)0) args.appendCString(", ");
            args.append(pn.name());
        }
        Array* e = new Array();
        e.add((Object*)ret);
        e.add((Object*)m.name());
        e.add((Object*)params);
        e.add((Object*)args);
        e.add((Object*)kinds);
        if (_pStatics == (Map*)0) {
            _pStatics = new Map();
            _pStaticOrder = new Array();
        }
        Array* list = (Array*)_pStatics.get((Hashable*)P);
        if (list == (Array*)0) {
            list = new Array();
            _pStatics.set((Hashable*)P, (Object*)list);
            _pStaticOrder.add((Object*)P);
        }
        list.add((Object*)e);
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

        // Where the member starts (its type): where a diagnostic about it is
        // reported, as the reference reports one.
        Token* memberTok = cur();
        // A METHOD may return several values, as a free function may:
        // `u8, u16 m(void)`. A comma straight after the type, before any name,
        // can only be that (an ivar list puts its comma after the name:
        // `u16 x, y;`). The reference reads members with the free-function
        // path, which always took the list.
        String* ty = parseTypeSpelling();
        while (check((u16)tokComma) && (isTypeKeywordToken(peek((u32)1).type())
                                        || (peek((u32)1).type() == (u16)tokIdentifier
                                            && isTypeName(peek((u32)1).value())))) {
            advance();
            ty.appendByte((u8)',');
            ty.append(parseTypeSpelling());
        }
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
            m.setStmtPos(memberTok.fileId(), memberTok.line(), memberTok.col());
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
        v.setStmtPos(memberTok.fileId(), memberTok.line(), memberTok.col());
        blkBind(name, v.op(), _lastBlkParams);       // class scope (task #26)
        // Marked as the class's own, so a par body's `self.<name>` can be
        // read as this binding (parSelfIvar). A local of the same name binds
        // in an inner scope, without the mark.
        if (_blkScopes.count() > (u32)0) {
            Object* bi = ((Map*)_blkScopes.get(_blkScopes.count() - (u32)1)).get((Hashable*)name);
            if (bi != 0) ((Map*)bi).set((Hashable*)String.withCString("ivar"), (Object*)Number.with((u32)1));
        }
        blkAddIvar(name);
        if (match((u16)tokAssign)) v.add(parseExpression());
        while (match((u16)tokComma)) {
            Token* more = expect((u16)tokIdentifier);
            if (more == 0) break;
            Node* extra = mkNamed((u16)nkVariableDecl, more.value());
            extra.setOp(memberTypeSuffix(ty));
            extra.setFlags(ivarFlags);
            // Bound and marked like the first: `u32 a, b;` made only `a`
            // visible to the capture analysis, so a bare `b` in a par body
            // was refused here and captured by the reference.
            blkBind(more.value(), extra.op(), _lastBlkParams);
            if (_blkScopes.count() > (u32)0) {
                Object* bi = ((Map*)_blkScopes.get(_blkScopes.count() - (u32)1)).get((Hashable*)more.value());
                if (bi != 0) ((Map*)bi).set((Hashable*)String.withCString("ivar"), (Object*)Number.with((u32)1));
            }
            blkAddIvar(more.value());
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
        while (true) {
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
            // `:operator(pattern)` is read here, not skipped: the pattern is
            // part of the declaration.
            if (owner != 0 && Parser._same(w.lowercased(), "operator")) {
                advance();
                parseOperatorPattern(owner);
                match((u16)tokColon);
                continue;
            }
            if (owner != 0) {
                // Spelled `:xtcStack` / `:hwStack`; annotations are
                // case-insensitive, as the original's are.
                String* lw = w.lowercased();
                // The placement words are one choice, and the last one written
                // wins, as in the original: each clears the others.
                u32 place = (u32)NF_BANKED | (u32)NF_CLOAKED | (u32)NF_MAINRAM;
                if (Parser._same(w, "banked") || Parser._same(w, "cloaked")
                    || Parser._same(lw, "main") || Parser._same(lw, "shadow"))
                    owner.setFlags(owner.flags() & ~place);
                if (Parser._same(w, "banked"))  owner.addFlag((u32)NF_BANKED);
                if (Parser._same(w, "cloaked")) owner.addFlag((u32)NF_CLOAKED);
                if (Parser._same(lw, "main"))   owner.addFlag((u32)NF_MAINRAM);
                if (Parser._same(w, "irq"))     owner.addFlag((u32)NF_IRQ);
                if (Parser._same(w, "vbi"))     owner.addFlag((u32)NF_VBI);
                if (Parser._same(lw, "xtcstack")) owner.addFlag((u32)NF_XTCSTACK);
                if (Parser._same(lw, "hwstack"))  owner.addFlag((u32)NF_HWSTACK);
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

    // `:operator(pattern)`: the operator written out with the method's own
    // names as its operands — `self + o`, `-self`, `k * v`. Read as tokens,
    // not as an expression, so each shape is recognised exactly and the
    // operators that keep their fixed meaning are named in the refusal.
    // Whether each name is `self` or a parameter is sema's to check: it knows
    // whether the method is static. Mirrors the reference's
    // parseOperatorPatternAt:.
    //
    // The pattern is kept on the node as "<shape> <name> <name>": the shape
    // has `_` for each operand (`_+_`, `-_`), the names follow in pattern
    // order. An index spells its indices out (`_[_]`, `_[_,_]`, `_[_.._]`, and
    // `=_` after a set form); a compound one is `_+=_`.
    // A pattern that is not one of them is not a parse error: the parse goes
    // on, and the node keeps "? <what is wrong>" for sema to report with the
    // method's other faults, at the method.
    void parseOperatorPattern(Node* owner)
    {
        if (expect((u16)tokLParen) == 0) return;
        Array* t = new Array();
        u32 depth = (u32)0;
        while (!check((u16)tokEOF)) {
            u16 ty = curType();
            if (ty == (u16)tokRParen && depth == (u32)0) break;
            if (ty == (u16)tokLParen || ty == (u16)tokLBracket) depth = depth + (u32)1;
            else if ((ty == (u16)tokRParen || ty == (u16)tokRBracket) && depth > (u32)0) depth = depth - (u32)1;
            t.add((Object*)advance());
        }
        expect((u16)tokRParen);

        u32 n = t.count();
        String* refused = (String*)0;   // an operator with a fixed meaning
        bool noIndex = false;           // `self[]`
        bool noValue = false;           // `self[i] =` with nothing to assign
        String* pat = (String*)0;
        bool name0 = n > (u32)0 && ((Token*)t.get((u32)0)).type() == (u16)tokIdentifier;
        bool name1 = n > (u32)1 && ((Token*)t.get((u32)1)).type() == (u16)tokIdentifier;
        if (n == (u32)3 && name0 && ((Token*)t.get((u32)2)).type() == (u16)tokIdentifier) {
            Token* o = (Token*)t.get((u32)1);
            u16 ot = o.type();
            if (ot == (u16)tokPlus || ot == (u16)tokMinus || ot == (u16)tokStar || ot == (u16)tokSlash
                || ot == (u16)tokPercent || ot == (u16)tokAmpersand || ot == (u16)tokPipe || ot == (u16)tokCaret
                || ot == (u16)tokShiftLeft || ot == (u16)tokShiftRight || ot == (u16)tokRotateLeft
                || ot == (u16)tokRotateRight || ot == (u16)tokLess || ot == (u16)tokLessEq
                || ot == (u16)tokGreater || ot == (u16)tokGreaterEq) {
                pat = String.withCString("_");
                pat.append(o.value());
                pat.appendCString("_ ");
                pat.append(((Token*)t.get((u32)0)).value());
                pat.appendByte((u8)' ');
                pat.append(((Token*)t.get((u32)2)).value());
            } else if (ot == (u16)tokEqual || ot == (u16)tokNotEqual || ot == (u16)tokLogicalAnd
                       || ot == (u16)tokLogicalOr || ot == (u16)tokAssign || ot == (u16)tokDot
                       || ot == (u16)tokArrow || ot == (u16)tokComma) {
                refused = o.value();
            } else if (ot == (u16)tokPlusAssign || ot == (u16)tokMinusAssign || ot == (u16)tokStarAssign
                       || ot == (u16)tokSlashAssign || ot == (u16)tokPercentAssign || ot == (u16)tokAmpAssign
                       || ot == (u16)tokPipeAssign || ot == (u16)tokCaretAssign || ot == (u16)tokShlAssign
                       || ot == (u16)tokShrAssign || ot == (u16)tokRolAssign || ot == (u16)tokRorAssign) {
                pat = String.withCString("_");
                pat.append(o.value());
                pat.appendCString("_ ");
                pat.append(((Token*)t.get((u32)0)).value());
                pat.appendByte((u8)' ');
                pat.append(((Token*)t.get((u32)2)).value());
            }
        } else if (n == (u32)2 && name1) {
            Token* o = (Token*)t.get((u32)0);
            u16 ot = o.type();
            if (ot == (u16)tokMinus || ot == (u16)tokPlus || ot == (u16)tokTilde || ot == (u16)tokBang) {
                pat = String.withString(o.value());
                pat.appendCString("_ ");
                pat.append(((Token*)t.get((u32)1)).value());
            } else if (ot == (u16)tokAmpersand || ot == (u16)tokStar || ot == (u16)tokAt
                       || ot == (u16)tokPlusPlus || ot == (u16)tokMinusMinus || ot == (u16)tokLess
                       || ot == (u16)tokGreater || ot == (u16)tokShiftRight || ot == (u16)tokByte3) {
                refused = o.value();
            }
        } else if (n == (u32)2 && name0 && (((Token*)t.get((u32)1)).type() == (u16)tokPlusPlus
                                           || ((Token*)t.get((u32)1)).type() == (u16)tokMinusMinus)) {
            refused = ((Token*)t.get((u32)1)).value();
        } else if (n >= (u32)2 && name0 && ((Token*)t.get((u32)1)).type() == (u16)tokLBracket) {
            // An index: `self[i]`, `self[i, j]`, `self[lo..hi]` or
            // `self[lo...hi]`, then `= v` for the set form. The shape spells
            // the indices out: `_[_]`, `_[_,_]`, `_[_.._]`, with `=_` after a
            // set.
            String* sh = String.withCString("_[");
            String* nm = String.withString(((Token*)t.get((u32)0)).value());
            u32 i = 2;
            bool ok = true;
            if (i < n && ((Token*)t.get(i)).type() == (u16)tokRBracket) {
                noIndex = true;
            } else if (i + 2 < n && ((Token*)t.get(i)).type() == (u16)tokIdentifier
                       && (((Token*)t.get(i + 1)).type() == (u16)tokDotDot
                           || ((Token*)t.get(i + 1)).type() == (u16)tokEllipsis)
                       && ((Token*)t.get(i + 2)).type() == (u16)tokIdentifier) {
                sh.appendCString("_");
                sh.append(((Token*)t.get(i + 1)).value());
                sh.appendCString("_");
                nm.appendByte((u8)' ');
                nm.append(((Token*)t.get(i)).value());
                nm.appendByte((u8)' ');
                nm.append(((Token*)t.get(i + 2)).value());
                i = i + 3;
            } else {
                while (ok) {
                    if (i >= n || ((Token*)t.get(i)).type() != (u16)tokIdentifier) {
                        ok = false;
                    } else {
                        sh.appendCString("_");
                        nm.appendByte((u8)' ');
                        nm.append(((Token*)t.get(i)).value());
                        i = i + 1;
                        if (i < n && ((Token*)t.get(i)).type() == (u16)tokComma) {
                            sh.appendCString(",");
                            i = i + 1;
                        } else {
                            break;
                        }
                    }
                }
            }
            if (!noIndex && ok && i < n && ((Token*)t.get(i)).type() == (u16)tokRBracket) {
                sh.appendCString("]");
                i = i + 1;
                if (i == n) {
                    pat = sh;
                } else if (((Token*)t.get(i)).type() == (u16)tokAssign && i + 1 == n) {
                    noValue = true;
                } else if (((Token*)t.get(i)).type() == (u16)tokAssign && i + 2 == n
                           && ((Token*)t.get(i + 1)).type() == (u16)tokIdentifier) {
                    sh.appendCString("=_");
                    nm.appendByte((u8)' ');
                    nm.append(((Token*)t.get(i + 1)).value());
                    pat = sh;
                }
                if (pat != 0) {
                    pat.appendByte((u8)' ');
                    pat.append(nm);
                }
            }
        } else if (n >= (u32)2 && name0 && ((Token*)t.get((u32)1)).type() == (u16)tokLParen) {
            refused = String.withCString("()");
        } else if (n == (u32)5 && ((Token*)t.get((u32)1)).type() == (u16)tokQuestion
                   && ((Token*)t.get((u32)3)).type() == (u16)tokColon) {
            refused = String.withCString("?:");
        }

        if (pat != 0) {
            owner.setOpPat(pat);
            return;
        }
        String* msg = (String*)0;
        if (noIndex)
            msg = String.withCString("an index operator needs an index, such as (self[i])");
        else if (noValue)
            msg = String.withCString("an index-set operator needs a value after '=', such as (self[i] = v)");
        else if (refused != 0 && (Parser._same(refused, "==") || Parser._same(refused, "!="))) {
            msg = String.withCString("'");
            msg.append(refused);
            msg.appendCString("' cannot be overloaded: it compares identity (equals compares values)");
        } else if (refused != 0) {
            msg = String.withCString("'");
            msg.append(refused);
            msg.appendCString("' cannot be overloaded");
        } else
            msg = String.withCString("':operator' takes one operator applied to the method's own names, such as (self + o) or (-self)");
        String* fault = String.withCString("? ");
        fault.append(msg);
        owner.setOpPat(fault);
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
        i32 depth = (i32)0;   // a comma inside <>, () or [] is part of one type
        for (u32 i = (u32)0; i <= n; i = i + (u32)1) {
            if (i < n) {
                u8 b = ty.byteAt(i);
                if (b == (u8)'<' || b == (u8)'(' || b == (u8)'[') depth = depth + (i32)1;
                else if ((b == (u8)'>' || b == (u8)')' || b == (u8)']') && depth > (i32)0) depth = depth - (i32)1;
            }
            if (i == n || (ty.byteAt(i) == (u8)',' && depth == (i32)0)) {
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
            // The reference takes `extern` before the declaration begins, so
            // the declaration's position is the token after it.
            if (match((u16)tokExtern))   { flags = flags | (u32)NF_EXTERN; declTok = cur(); continue; }
            if (match((u16)tokVolatile)) { flags = flags | (u32)NF_VOLATILE; continue; }
            if (match((u16)tokRegister)) { flags = flags | (u32)NF_REGISTER; continue; }
            if (match((u16)tokInline))   { continue; }
            break;
        }

        // `(i32, i32) mr(void)` is not a declaration: a return list is
        // written bare (`i32, i32 mr(void)`, functions.md). The reference's
        // words; this one parsed it, undocumented (2026-10-24).
        String* ty = (String*)0;
        if (check((u16)tokLParen) && looksLikeReturnTypeList()) {
            _error(String.withCString("Expected type in declaration"));
            return (Node*)0;
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
            f.setStmtPos(declTok.fileId(), declTok.line(), declTok.col());
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
                String* outerFn = _parFn;
                _parFn = name;
                f.add(parseBlock());
                _parFn = outerFn;
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
            v.add(stringInitForArray(vty, parseInitialiser()));
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

    // The reference's own wording for a missing `}`, not `expect`'s
    // "Expected '}' but found …".
    void closeBlock(void)
    {
        if (match((u16)tokRBrace)) return;
        _error(String.withCString("Expected '}' to end block"));
    }

    Node* parseBlock(void)
    {
        Node* b = mk((u16)nkBlock);
        openBlock();
        blkPushScope();                              // blocks (task #26)
        // !_fatal mirrors the original's hasFatalError guard: after a parse
        // error the statement loop stops consuming, so an error file's dump
        // truncates at the same statement in both compilers (task #36).
        while ((_pwPending || (!closeBlockAhead() && !check(tokEOF))) && !_fatal) {
            u32 before = _pos;
            bool made = _pwPending;
            if (_scanSplice != (Map*)0 && !made && check(tokIdentifier) && scSplice(b)) continue;
            Node* s = parseListStatement();
            if (s != 0) b.add(s);
            if (_pos == before && !made) advance();
        }
        blkPopScope();                               // blocks (task #26)
        closeBlock();
        return b;
    }

    // A statement of a braced block or a case body: a counted `while` there
    // leaves its `if (v < B) v = B;` as the statement after it
    // (parseStatementInner).
    bool _pwInList;
    Node* parseListStatement(void)
    {
        _pwInList = true;
        return parseStatement();
    }

    Node* parseStatement(void)
    {
        bool inList = _pwInList;
        _pwInList = false;
        if (_pwPending) return pwTakePending();
        Token* stmtTok = cur();
        Node* stmtNode = parseStatementInner(inList);
        if (stmtNode != 0 && stmtNode.line() == (u32)0)
            stmtNode.setPos(stmtTok.fileId(), stmtTok.line(), stmtTok.col());
        // -g: the statement's own start, where the reference puts it.
        if (stmtNode != 0)
            stmtNode.setStmtPos(stmtTok.fileId(), stmtTok.line(), stmtTok.col());
        return stmtNode;
    }

    // `par [name] (:reduce(op var))* [:goal(speed|accuracy)] { body }`, the data-parallel block.
    // --par-style=auto: a `for` loop in plain code becomes a `par` block when its
    // shape allows — `for (T i in a..b) { … }` whose body writes only its
    // own locals, array elements, and integer reductions (`acc = acc + e` or
    // `acc += e`, with acc used nowhere else in the body), with no break of
    // its own, return, goto, label, and no outer name incremented, taken by
    // address or written through a member. The decision is made on the
    // TOKENS, before parsing, so both parsers decide alike without a trial
    // parse; a loop that qualifies is parsed inside a par frame, as
    // `par <file:line> :reduce(op acc) { for … }` would be. What the tokens
    // cannot tell — a dependence between items, a call the GPU cannot make —
    // par-check decides after lowering, and demotes an auto block to a
    // serial run rather than refusing it. Mirrors the reference's parAutoFor.
    // An expression made of literals, casts, arithmetic and names other than
    // `avoid`: an inner bound that does not depend on the outer index.
    static bool parAutoBoundFree(Node* e, String* avoid)
    {
        if (e == (Node*)0) return false;
        if (e.kind() == (u16)nkInt) return true;
        if (e.kind() == (u16)nkIdent) return !e.name().equals(avoid);
        if (e.kind() == (u16)nkCast) return e.kidCount() > (u32)0 && Parser.parAutoBoundFree(e.kid((u32)0), avoid);
        if (e.kind() == (u16)nkBinary)
            return e.kidCount() == (u32)2 && Parser.parAutoBoundFree(e.kid((u32)0), avoid) && Parser.parAutoBoundFree(e.kid((u32)1), avoid);
        return false;
    }
    // The ascending-loop shape the desugaring takes (`for (T v = a; v < b | v <= b; v++)`):
    // fills the declaration and the condition, or returns false.
    static bool parAutoAscending(Node* node, Node** ivOut, Node** condOut)
    {
        if (node == (Node*)0 || node.kind() != (u16)nkForCStyle || node.kidCount() != (u32)4) return false;
        Node* iv = node.kid((u32)0).kidCount() > (u32)0 ? node.kid((u32)0).kid((u32)0) : (Node*)0;
        Node* cond = node.kid((u32)1).kidCount() > (u32)0 ? node.kid((u32)1).kid((u32)0) : (Node*)0;
        Node* step = node.kid((u32)2).kidCount() > (u32)0 ? node.kid((u32)2).kid((u32)0) : (Node*)0;
        if (iv == (Node*)0 || iv.kind() != (u16)nkVariableDecl || iv.kidCount() == (u32)0 || iv.op() == (String*)0) return false;
        if (cond == (Node*)0 || cond.kind() != (u16)nkBinary || !(Parser._same(cond.op(), "<") || Parser._same(cond.op(), "<="))
            || cond.kid((u32)0).kind() != (u16)nkIdent || !cond.kid((u32)0).name().equals(iv.name())) return false;
        bool stepOk = false;
        if (step != (Node*)0) {
            if (step.kind() == (u16)nkAssign && Parser._same(step.op(), "+=")
                && step.kid((u32)1).kind() == (u16)nkInt && step.kid((u32)1).num() == (i64)1)
                stepOk = true;
            else if (step.kind() == (u16)nkAssign && Parser._same(step.op(), "=")
                && step.kid((u32)1).kind() == (u16)nkBinary && Parser._same(step.kid((u32)1).op(), "+")
                && step.kid((u32)1).kid((u32)0).kind() == (u16)nkIdent && step.kid((u32)1).kid((u32)0).name().equals(iv.name())
                && step.kid((u32)1).kid((u32)1).kind() == (u16)nkInt && step.kid((u32)1).kid((u32)1).num() == (i64)1)
                stepOk = true;
            else if ((step.kind() == (u16)nkPostfix || step.kind() == (u16)nkUnary) && Parser._same(step.op(), "++"))
                stepOk = true;
        }
        if (!stepOk) return false;
        *ivOut = iv;
        *condOut = cond;
        return true;
    }
    // A perfect two-deep nest as a grid block's body: the two indices from the
    // point (`par$y` the outer, `par$x` the inner), then the inner body; the
    // frame gets the grid's W and H. 0 when the loop is not such a nest.
    // A nest level's extent, hi - lo (+ 1 for <=), in i64.
    Node* parAutoExtent(Node* iv, Node* cond)
    {
        String* i64T = String.withCString("i64");
        Node* e = parBin("-", parCast(i64T, cond.kid((u32)1)), parCast(i64T, iv.kid((u32)0)));
        if (Parser._same(cond.op(), "<=")) e = parBin("+", e, parInt((i64)1));
        return e;
    }

    // `T i = (T)((T)lo + (T)par$x)`: a nest level's index from its grid coordinate.
    Node* parAutoCoordDecl(Node* iv, u8* coord)
    {
        Node* d = mkNamed((u16)nkVariableDecl, iv.name());
        d.setOp(iv.op());
        d.add(parCast(iv.op(), parBin("+", parCast(iv.op(), iv.kid((u32)0)), parCast(iv.op(), parIdent(String.withCString(coord))))));
        return d;
    }

    // `cap` is the grid levels the nest may take (parAutoGridCap).
    Node* parAutoGridNest(Node* node, Map* frame, u32 cap)
    {
        Node* iv1 = (Node*)0;
        Node* cond1 = (Node*)0;
        if (cap < 2 || !Parser.parAutoAscending(node, &iv1, &cond1)) return (Node*)0;
        // The inner loop: the outer body's one statement, braced or not.
        Node* inner = node.kid((u32)3);
        if (inner.kind() == (u16)nkBlock) {
            if (inner.kidCount() != (u32)1) return (Node*)0;
            inner = inner.kid((u32)0);
        }
        Node* iv2 = (Node*)0;
        Node* cond2 = (Node*)0;
        if (!Parser.parAutoAscending(inner, &iv2, &cond2)) return (Node*)0;
        if (!Parser.parAutoBoundFree(iv2.kid((u32)0), iv1.name()) || !Parser.parAutoBoundFree(cond2.kid((u32)1), iv1.name())) return (Node*)0;
        // A perfect THREE-deep nest is one 3-D grid (the reference explains).
        Node* thirdNode = inner.kid((u32)3);
        if (thirdNode.kind() == (u16)nkBlock)
            thirdNode = thirdNode.kidCount() == (u32)1 ? thirdNode.kid((u32)0) : (Node*)0;
        Node* iv3 = (Node*)0;
        Node* cond3 = (Node*)0;
        bool three = cap >= 3 && thirdNode != (Node*)0 && Parser.parAutoAscending(thirdNode, &iv3, &cond3);
        if (three && !(Parser.parAutoBoundFree(iv3.kid((u32)0), iv1.name()) && Parser.parAutoBoundFree(cond3.kid((u32)1), iv1.name())
                       && Parser.parAutoBoundFree(iv3.kid((u32)0), iv2.name()) && Parser.parAutoBoundFree(cond3.kid((u32)1), iv2.name())))
            three = false;
        String* i64T = String.withCString("i64");
        Array* grid = new Array();
        if (three) grid.add((Object*)parAutoExtent(iv3, cond3));
        grid.add((Object*)parAutoExtent(iv2, cond2));
        grid.add((Object*)parAutoExtent(iv1, cond1));
        frame.set((Hashable*)String.withCString("grid"), (Object*)grid);
        Set* used = new Set();
        used.add((Hashable*)String.withCString("par$x"));
        used.add((Hashable*)String.withCString("par$y"));
        if (three) used.add((Hashable*)String.withCString("par$z"));
        frame.set((Hashable*)String.withCString("gridUsed"), (Object*)used);
        Node* body = mk((u16)nkBlock);
        body.add(parAutoCoordDecl(iv1, three ? "par$z" : "par$y"));
        body.add(parAutoCoordDecl(iv2, three ? "par$y" : "par$x"));
        if (three) body.add(parAutoCoordDecl(iv3, "par$x"));
        Node* innerBody = three ? thirdNode.kid((u32)3) : inner.kid((u32)3);
        if (innerBody.kind() == (u16)nkBlock) {
            for (u32 i = (u32)0; i < innerBody.kidCount(); i = i + (u32)1)
                body.add(innerBody.kid(i));
        } else
            body.add(innerBody);
        return body;
    }

    // --par-style=auto's `while` form (the reference's parAutoWhileShape explains):
    // `while (v < B) { …; v++; }` is parsed as
    //     for (T __autopar_w = v; __autopar_w < B; __autopar_w += 1)
    //         { T v = __autopar_w; …the body without the increment… }
    //     if (v < B) v = B;            (<= B: v = B + 1)
    // Whether the `while` at _pos has that shape; it notes where its parts
    // are (_pwAt…) for parseAutoWhile.
    u32     _pwAt;          // the `while`
    u32     _pwPe;          // the `)` closing its condition
    u32     _pwInc;         // the increment's first token
    String* _pwVt;          // v's type
    String* _pwV;           // the counter
    bool parAutoWhileShape(void)
    {
        u32 at = _pos;
        u32 n = _tokens.count();
        if (parTokType(at + (u32)1) != (u16)tokLParen || parTokType(at + (u32)2) != (u16)tokIdentifier) return false;
        String* v = parTokValue(at + (u32)2);
        u16 cmp = parTokType(at + (u32)3);
        if (cmp != (u16)tokLess && cmp != (u16)tokLessEq) return false;
        // The bound: names, integer literals, + - * /, casts and parentheses,
        // up to the `)` that closes the condition.
        u32 pe = at + (u32)4;
        u32 pd = (u32)0;
        while (pe < n) {
            u16 t = parTokType(pe);
            if (t == (u16)tokRParen && pd == (u32)0) break;
            if (t == (u16)tokLParen) pd = pd + (u32)1;
            else if (t == (u16)tokRParen) pd = pd - (u32)1;
            else if (t != (u16)tokIdentifier && t != (u16)tokIntLiteral && t != (u16)tokPlus && t != (u16)tokMinus
                && t != (u16)tokStar && t != (u16)tokSlash && !Parser.parIntTypeTok(t)) return false;
            if (t == (u16)tokIdentifier && parTokValue(pe).equals(v)) return false;
            pe = pe + (u32)1;
        }
        if (pe >= n || pe == at + (u32)4 || parTokType(pe + (u32)1) != (u16)tokLBrace) return false;
        u32 be = (u32)0;
        u32 depth = (u32)0;
        for (u32 i = pe + (u32)1; i < n; i = i + (u32)1) {
            u16 t = parTokType(i);
            if (t == (u16)tokLBrace) depth = depth + (u32)1;
            else if (t == (u16)tokRBrace) {
                depth = depth - (u32)1;
                if (depth == (u32)0) { be = i; break; }
            }
        }
        if (be == (u32)0) return false;
        u32 inc = (u32)0;
        if (parTokType(be - (u32)1) != (u16)tokSemicolon) return false;
        if (be >= pe + (u32)5 && parTokType(be - (u32)3) == (u16)tokIdentifier && parTokValue(be - (u32)3).equals(v)
            && parTokType(be - (u32)2) == (u16)tokPlusPlus)
            inc = be - (u32)3;
        else if (be >= pe + (u32)5 && parTokType(be - (u32)3) == (u16)tokPlusPlus && parTokType(be - (u32)2) == (u16)tokIdentifier
                 && parTokValue(be - (u32)2).equals(v))
            inc = be - (u32)3;
        else if (be >= pe + (u32)6 && parTokType(be - (u32)4) == (u16)tokIdentifier && parTokValue(be - (u32)4).equals(v)
                 && parTokType(be - (u32)3) == (u16)tokPlusAssign && parTokType(be - (u32)2) == (u16)tokIntLiteral
                 && Parser._same(parTokValue(be - (u32)2), "1"))
            inc = be - (u32)4;
        else if (be >= pe + (u32)8 && parTokType(be - (u32)6) == (u16)tokIdentifier && parTokValue(be - (u32)6).equals(v)
                 && parTokType(be - (u32)5) == (u16)tokAssign && parTokType(be - (u32)4) == (u16)tokIdentifier
                 && parTokValue(be - (u32)4).equals(v) && parTokType(be - (u32)3) == (u16)tokPlus
                 && parTokType(be - (u32)2) == (u16)tokIntLiteral && Parser._same(parTokValue(be - (u32)2), "1"))
            inc = be - (u32)6;
        if (inc == (u32)0 || inc <= pe + (u32)1) return false;
        u32 incForm = inc == be - 3 ? (parTokType(inc) == tokPlusPlus ? 2 : 1) : inc == be - 4 ? 3 : 4;
        u16 before = parTokType(inc - (u32)1);
        if (before != (u16)tokSemicolon && before != (u16)tokRBrace && before != (u16)tokLBrace) return false;
        for (u32 i = pe + (u32)2; i < inc; i = i + (u32)1) {
            u16 t = parTokType(i);
            if (t == (u16)tokBreak || t == (u16)tokContinue || t == (u16)tokReturn || t == (u16)tokGoto) return false;
            if (t == (u16)tokIdentifier && parTokValue(i).equals(v)) {
                u16 nx = parTokType(i + (u32)1);
                u16 pv = parTokType(i - (u32)1);
                if (Parser.parAutoAnyAssignOp(nx) || nx == (u16)tokPlusPlus || nx == (u16)tokMinusMinus
                    || pv == (u16)tokPlusPlus || pv == (u16)tokMinusMinus || pv == (u16)tokAmpersand) return false;
            }
        }
        // #416: a bound the body changes. The `for` reads it once when it is
        // a block, and `v = B` after it would read the changed one.
        String* bw = parAutoBoundWritten(at + 4, pe, pe + 2, inc, v);
        if (bw != (String*)0) {
            parAutoWarnSerial(bw);
            return false;
        }
        // v: a local of an integer type, spelt as its keyword. #463: a field
        // (the class scope's ivar binding) or a global (no binding) is not
        // one: the rewrite's fresh variable and its `v = B` after the loop
        // hold for a local only.
        u32 d = 0;
        Map* vinfo = blkLookup(v, &d);
        if (vinfo == 0 || vinfo.get((Hashable*)String.withCString("ivar")) != (Object*)0) {
            String* m = String.withCString("its counter '");
            m.append(v);
            m.appendCString("' is not a local variable");
            parAutoWarnSerial(m);
            return false;
        }
        String* vt = blkTyOf(vinfo);
        bool known = vt != (String*)0 && Parser.scIntType(vt);
        if (!known) return false;
        _pwAt = at;
        _pwPe = pe;
        _pwInc = inc;
        _pwVt = vt;
        _pwV = v;
        _plWhileInc = incForm;
        return true;
    }

    // The `while` at _pos, which parAutoWhileShape took (`v`, `vt` its
    // counter and type, `incTok` and `incLen` its increment statement),
    // parsed as the `for`
    //     for (T __autopar_w = v; __autopar_w < B; __autopar_w += 1)
    //         { T v = __autopar_w; …the body without the increment… }
    // with the nodes, positions and bindings those tokens would give, the
    // made parts at the `while`. The
    // `if` after it is the next statement of the block, or goes with it in a
    // block where the `while` was a lone statement (_pwPending,
    // parseStatementInner).
    Node* parseAutoWhile(String* v, String* vt, Token* incTok, u32 incLen)
    {
        Token* w0 = cur();
        Token* realAt = _mkAt;
        Token* madeAt = realAt != (Token*)0 ? realAt : w0;
        String* w = String.withCString("__autopar_w");
        advance();                                  // `while`
        expect(tokLParen);
        advance();                                  // v
        _mkAt = madeAt;
        _lastBlkName = (String*)0;
        _lastTypeIsOutlet = false;
        Node* n = mk(nkForCStyle);
        Node* initMark = mk(nkMarkerInit);
        // T __autopar_w = v;
        Node* iv = pwDecl(w, vt, v, w0);
        initMark.add(iv);
        n.add(initMark);
        Node* condMark = mk(nkMarkerCond);
        Node* lhs = pwIdent(w);
        Token* opTok = advance();
        Node* c = mk(nkBinary);
        c.setPos(opTok.fileId(), opTok.line(), opTok.col());
        c.setOp(opTok.value());
        c.add(lhs);
        _mkAt = realAt;
        c.add(parseExprMinPrec(precOf(opTok.type()) + 1));
        _mkAt = madeAt;
        condMark.add(c);
        n.add(condMark);
        expect(tokRParen);
        // __autopar_w += 1
        Node* stepMark = mk(nkMarkerStep);
        Node* step = mk(nkAssign);
        step.setPos(w0.fileId(), w0.line(), w0.col());
        step.setOp(String.withCString("+="));
        step.add(pwIdent(w));
        step.add(pwOne());
        stepMark.add(step);
        n.add(stepMark);
        u32 goal = loopGoal(0);
        loopAnnotationFlags(n, 0, goal);
        u32 savedGoal = _goalNow;
        _goalNow = goal;
        // { T v = __autopar_w; …the body up to the increment… }
        Node* b = mk(nkBlock);
        openBlock();
        blkPushScope();
        _lastBlkName = (String*)0;
        _lastTypeIsOutlet = false;
        b.add(pwDecl(v, vt, w, w0));
        _mkAt = realAt;
        while ((_pwPending || (cur() != incTok && !closeBlockAhead() && !check(tokEOF))) && !_fatal) {
            u32 before = _pos;
            bool made = _pwPending;
            Node* st = parseListStatement();
            if (st != 0) b.add(st);
            if (_pos == before && !made) advance();
        }
        if (cur() == incTok)
            for (u32 i = 0; i < incLen; i++) advance();
        blkPopScope();
        closeBlock();
        n.add(b);
        _goalNow = savedGoal;
        return n;
    }

    // A name read at a made token: as parsePrimary reads one.
    Node* pwIdent(String* name)
    {
        blkNoteUse(name);
        return mkNamed(nkIdent, name);
    }
    // The literal 1 at a made token.
    Node* pwOne(void)
    {
        Node* one = mk(nkInt);
        one.setNum(1);
        one.addSrc(SRC_PLAIN);
        return one;
    }
    // `T name = from;` made at `at`, as parseVarDeclStatement and
    // parseStatement build and bind it.
    Node* pwDecl(String* name, String* ty, String* from, Token* at)
    {
        _lastBlkWb = false;
        Array* params = _lastBlkParams;
        Node* d = mkNamed(nkVariableDecl, name);
        String* dty = String.withString(ty);
        d.setOp(dty);
        d.setFlags(0);
        d.add(pwIdent(from));
        blkBind(name, dty, params);
        blkMarkHoldsWb(name, d.kid(0));
        d.setStmtPos(at.fileId(), at.line(), at.col());
        return d;
    }

    // The `if (v < B) v = B;` (`<= B`: `v = B + 1`) a counted `while` leaves
    // after its `for` (parseAutoWhile), with B read again from its own
    // tokens: the next statement of the block, or the second statement of the
    // block parseStatementInner makes for a lone `while`.
    bool    _pwPending;
    String* _pwPendV;
    Array*  _pwPendBound;   // B's tokens and the `)` after them
    Token*  _pwPendCmp;     // the `<` or `<=`
    Token*  _pwPendAt;      // the `while`

    void pwSetPending(String* v, Array* bound, Token* cmp, Token* at)
    {
        _pwPending = true;
        _pwPendV = v;
        _pwPendBound = bound;
        _pwPendCmp = cmp;
        _pwPendAt = at;
    }

    // B, parsed from its tokens at `minPrec`.
    Node* pwBound(i16 minPrec)
    {
        Array* savedToks = _tokens;
        u32 savedPos = _pos;
        _tokens = _pwPendBound;
        _pos = 0;
        Node* e = parseExprMinPrec(minPrec);
        _tokens = savedToks;
        _pos = savedPos;
        return e;
    }

    Node* pwTakePending(void)
    {
        _pwPending = false;
        Token* w0 = _pwPendAt;
        String* v = _pwPendV;
        Token* realAt = _mkAt;
        Token* madeAt = realAt != (Token*)0 ? realAt : w0;
        _mkAt = madeAt;
        Node* n = mk(nkIf);
        Node* c = mk(nkBinary);
        Node* lhs = pwIdent(v);
        c.setPos(_pwPendCmp.fileId(), _pwPendCmp.line(), _pwPendCmp.col());
        c.setOp(_pwPendCmp.value());
        c.add(lhs);
        _mkAt = realAt;
        c.add(pwBound(precOf(_pwPendCmp.type()) + 1));
        _mkAt = madeAt;
        n.add(c);
        Node* a = mk(nkAssign);
        Node* to = pwIdent(v);
        a.setPos(w0.fileId(), w0.line(), w0.col());
        a.setOp(String.withCString("="));
        _mkAt = realAt;
        Node* rhs = pwBound(precOf(tokAssign));
        _mkAt = madeAt;
        if (_pwPendCmp.type() == tokLessEq) {
            Node* sum = mk(nkBinary);
            sum.setPos(w0.fileId(), w0.line(), w0.col());
            sum.setOp(String.withCString("+"));
            sum.add(rhs);
            sum.add(pwOne());
            rhs = sum;
        }
        if (blkIsWbValue(rhs)) blkMarkHoldsWb(v, rhs);
        a.add(to);
        a.add(rhs);
        // The statement node sits at the token after its `;`: the one after
        // the loop.
        _mkAt = realAt;
        Node* st = mk(nkExprStatement);
        st.add(a);
        if (st.line() == 0) st.setPos(w0.fileId(), w0.line(), w0.col());
        st.setStmtPos(w0.fileId(), w0.line(), w0.col());
        n.add(st);
        n.setStmtPos(w0.fileId(), w0.line(), w0.col());
        return n;
    }

    // A type keyword a cast in a bound may name (the reference asks the
    // token isTypeKeyword).
    static bool parIntTypeTok(u16 t)
    {
        return t == (u16)tokU8 || t == (u16)tokI8 || t == (u16)tokU16 || t == (u16)tokI16 || t == (u16)tokU32
            || t == (u16)tokI32 || t == (u16)tokU64 || t == (u16)tokI64 || t == (u16)tokBool || t == (u16)tokFloat
            || t == (u16)tokDouble || t == (u16)tokVoid || t == (u16)tokPointer || t == (u16)tokString || t == (u16)tokAuto;
    }

    // A token made by a rewrite, at the place of `at`.
    Token* parSynTok(u16 type, String* value, Token* at)
    {
        Token* t = Token.with(type, String.withString(value), at.line(), at.col());
        t.setFileId(at.fileId());
        return t;
    }
    Token* parSynInt(i64 v, Token* at)
    {
        Token* t = Token.withInt((u16)tokIntLiteral, String.withI64(v), v, at.line(), at.col());
        t.setFileId(at.fileId());
        return t;
    }

    // A loop threads cannot pay for: a constant count of under 65536
    // iterations whose tokens (from..to) hold no loop, goto, `new` or call.
    // Waking the threads costs more than the work (4096 element stores took
    // 923 us as a block, a few as a loop), and the block's code in the
    // function crowds the loops after it. As the reference.
    bool parAutoSmall(Node* loop, u32 from, u32 to)
    {
        Node* iv = (Node*)0;
        Node* cond = (Node*)0;
        if (!Parser.parAutoAscending(loop, &iv, &cond)) return false;
        i64 lo = Parser.parAutoConst(iv.kid((u32)0));
        i64 hi = Parser.parAutoConst(cond.kid((u32)1));
        if (lo < (i64)0 || hi < (i64)0 || hi - lo >= (i64)65536) return false;
        // The `for` itself is the first token.
        for (u32 i = from + (u32)1; i < to; i = i + (u32)1) {
            u16 t = parTokType(i);
            if (t == (u16)tokFor || t == (u16)tokWhile || t == (u16)tokGoto || t == (u16)tokNew) return false;
            if (t == (u16)tokIdentifier && parTokType(i + (u32)1) == (u16)tokLParen) return false;
        }
        return true;
    }

    // A constant bound (literals, casts, + - *): its value, or -1.
    static i64 parAutoConst(Node* e)
    {
        bool ok = false;
        i64 v = Parser.parFoldConstant(e, &ok);
        return ok && v >= (i64)0 ? v : (i64)-1;
    }

    // --par-style=auto on the loop at the cursor (the reference explains).
    // The site table the recogniser reads holds the sites of the outermost
    // loop being parsed.
    Node* parAutoFor(void)
    {
        if (_parAutoNest == 0) _plSites = (Array*)0;
        _parAutoNest = _parAutoNest + 1;
        Node* out = parAutoForAt();
        _parAutoNest = _parAutoNest - 1;
        return out;
    }

    // The loop is parsed as it stands, with each loop inside it looked at on
    // its own, and the recogniser reads its tree (plRecogniseFor). A loop that
    // stays a loop keeps that parse; its trace line and its -Wpar-auto
    // warnings go where it starts, before those of the loops inside it. A
    // loop that becomes a block is parsed as the block's loop, nothing in it
    // lifted: the parse is taken back and the loop parsed again where the
    // first parse looked at a loop inside it or read the loop depth, so the
    // block, its numbers and its diagnostics are those of the one parse.
    Node* parAutoForAt(void)
    {
        bool fromWhile = _parAutoFromWhile;
        _parAutoFromWhile = false;
        Token* traceAt = cur();
        // A counted `while` (parAutoWhileShape): the parses below build its
        // `for` from the `while` (parseAutoWhile).
        String* wv = (String*)0;
        String* wvt = (String*)0;
        Token* wInc = (Token*)0;
        u32 wIncLen = 0;
        u32 whileInc = _plWhileInc;
        if (fromWhile) {
            wv = _pwV;
            wvt = _pwVt;
            wInc = (Token*)_tokens.get(_pwInc);
            wIncLen = whileInc == 4 ? 6 : whileInc == 3 ? 4 : 3;
        }
        Map* mark = parAutoMark();
        u32 forPos = _pos;
        u32 blkAt = _blkCounter;
        u32 parAt = _parCounter;
        u32 seqAt = _scanSeq;
        u32 plainErr = _errors.count();
        u32 plainWarn = _warnings.count();
        u32 traceMark = _parAutoTrace != (Array*)0 ? _parAutoTrace.count() : 0;
        u32 depthReads = _parAutoDepthReads;
        parGridEnter("loops", true);
        Node* plain = fromWhile ? parseAutoWhile(wv, wvt, wInc, wIncLen) : parseFor();
        parGridEnter("loops", false);
        // The verdict, with the -Wpar-auto warnings of a loop that stays a
        // loop before the warnings of its parse.
        u32 recWarn = _warnings.count();
        Map* v = plRecogniseFor(plain, traceAt);
        Parser.parAutoMoveTail(_warnings, recWarn, plainWarn);
        bool lift = Parser._same((String*)pfwGet(v, "lift"), "1");
        String* form = fromWhile ? String.withCString("while") : (String*)pfwGet(v, "form");
        // Without the par runtime the loop stays a loop, and the front end is
        // told: it parses again with Par.xc imported (--par-style=auto imports it).
        bool haveRuntime = isTypeName(String.withCString("ParChunk"));
        if (lift && !haveRuntime)
            _parAutoWantsRuntime = true;
        if (!lift || !haveRuntime) {
            u32 tm = _parAutoTrace != (Array*)0 ? _parAutoTrace.count() : 0;
            parAutoTraceLine(traceAt, "serial", lift ? String.withCString("no-runtime") : (String*)pfwGet(v, "rule"), form, (String*)0, (String*)0, 0, (String*)0);
            if (_parAutoTrace != (Array*)0) Parser.parAutoMoveTail(_parAutoTrace, tm, traceMark);
            if (fromWhile) plRegister(plain, 3, plain, (Array*)0, whileInc);
            return plain;
        }
        // The block's loop, parsed as --par-style=cpu parses it (nothing in it
        // lifted): the site falls back to it when par-check demotes the block,
        // and a small loop stays that loop.
        if (_parAutoDepthReads != depthReads) {
            parAutoRollback(mark);
            parGridEnter("loops", true);
            _loopDepth = _loopDepth + 1;
            plain = fromWhile ? parseAutoWhile(wv, wvt, wInc, wIncLen) : parseFor();
            _loopDepth = _loopDepth - 1;
            parGridEnter("loops", false);
        }
        Array* reds = (Array*)pfwGet(v, "redNodes");
        u32 goal = ((Number*)pfwGet(v, "goalN")).asU32();
        u32 gridCap = ((Number*)pfwGet(v, "gridN")).asU32();
        _parScanAcc = (String*)pfwGet(v, "scanAcc");
        _parScanOp = (String*)pfwGet(v, "scanOp");
        // The site the walk reads in place of what this returns (_plSites):
        // the loop as written, or the `while` it was.
        u32 plKind = fromWhile ? 3 : 2;
        if (plain == (Node*)0 || Parser._same((String*)pfwGet(v, "small"), "1")) {
            parAutoTraceLine(traceAt, "serial", String.withCString(plain == (Node*)0 ? "parse" : "small"), form, (String*)0, (String*)0, 0, (String*)0);
            if (fromWhile) plRegister(plain, 3, plain, (Array*)0, whileInc);
            return plain;
        }
        // A loop whose body holds a block literal or a written par block
        // stays the loop. As the reference.
        u32 plainEnd = _pos;
        Token* forTok = (Token*)_tokens.get(forPos);
        bool holdsBlock = _blkCounter != blkAt || _parCounter != parAt || _scanSeq != seqAt;
        // A running total (#144): the loop's tree becomes a `par :scan(op acc)`
        // block (parAutoScanFor); a loop the scan does not take stays the loop.
        if (_parScanAcc != (String*)0 && !holdsBlock) {
            String* sreds = String.withString(_parScanOp);
            sreds.appendByte(':');
            sreds.append(_parScanAcc);
            u32 implFrom = _parCounter;
            Node* sc = parAutoScanFor(plain, forTok, forPos, plainEnd, plainErr, plainWarn);
            if (sc != plain || fromWhile) plRegister(sc, plKind, plain, (Array*)0, whileInc);
            if (sc == plain)
                parAutoTraceLine(traceAt, "serial", String.withCString("scan-refused"), form, (String*)0, (String*)0, 0, (String*)0);
            else
                parAutoTraceLine(traceAt, "lifted", String.withCString("scan"), form, (String*)0, sreds, 0, Parser.parAutoImplSpan(implFrom, _parCounter));
            return sc;
        }
        if (holdsBlock) {
            warnAt(String.withCString("par-auto"), String.withCString("this loop runs serially, not as a 'par' block (--par-style): its body holds a block"), forTok);
            parAutoTraceLine(traceAt, "serial", String.withCString("body-block"), form, (String*)0, (String*)0, 0, (String*)0);
            if (fromWhile) plRegister(plain, 3, plain, (Array*)0, whileInc);
            return plain;
        }
        // A loop the block form refuses stays the loop: an error the loop's
        // parse, the walk of its copy or its desugaring reports (a capture of
        // self or of an ivar, say) is taken back, and the loop as parsed above
        // is the statement. A loop of a method that reads self.n failed to
        // compile (UXKit had 25). As the reference.
        u32 errMark = _errors.count();
        u32 warnMark = _warnings.count();
        bool fatalMark = _fatal;
        if (errMark > plainErr) {
            parAutoRefusedWhy((String*)_errors.get(plainErr), forTok);
            parAutoTraceLine(traceAt, "serial", String.withCString("block-refused"), form, (String*)0, (String*)0, 0, (String*)0);
            if (fromWhile) plRegister(plain, 3, plain, (Array*)0, whileInc);
            return plain;
        }
        Map* frame = new Map();
        frame.set((Hashable*)String.withCString("plain"), (Object*)plain);
        frame.set((Hashable*)String.withCString("depth"), (Object*)Number.with(_blkScopes.count()));
        frame.set((Hashable*)String.withCString("names"), (Object*)new Array());
        frame.set((Hashable*)String.withCString("types"), (Object*)new Map());
        frame.set((Hashable*)String.withCString("wbnames"), (Object*)new Array());
        frame.set((Hashable*)String.withCString("par"), (Object*)Number.with((u32)1));
        frame.set((Hashable*)String.withCString("written"), (Object*)new Set());
        // In main, outside every loop and block literal: it runs once per
        // program run (runsOnce, for the probe's report). As the reference.
        if (_parFn != (String*)0 && _parFn.equals(String.withCString("main")) && _loopDepth == (u32)0 && _blkFrames.count() == (u32)0)
            frame.set((Hashable*)String.withCString("once"), (Object*)Number.with((u32)1));
        // The block's goal: the loop's own, else the goal of the loop or block
        // it sits in, else the file's or the build's, else speed, as a written
        // block's. A float sum still lifts only under an explicit speed goal
        // (parAutoScanBodyAfter). As the reference.
        if (goal != (u32)2)
            frame.set((Hashable*)String.withCString("fast"), (Object*)Number.with((u32)1));
        frame.set((Hashable*)String.withCString("auto"), (Object*)Number.with((u32)1));
        Token* savedParTok = _parTok;
        _parTok = forTok;
        // The block's loop: a copy of the loop as parsed, with the goals the
        // block's own gives it, and its frame from the walk of the copy, which
        // also says what the block cannot capture and reads `self.f` as the
        // ivar (pfwSelfIvar), as a parse in the block's frame did.
        Node* loop = plain.deepCopy();
        parAutoGoals(loop, goal == 2 ? 2 : 1);
        _pfwAuto = true;
        _pfwToks = _tokens;
        _pfwTokFrom = forPos;
        _pfwTokTo = plainEnd;
        parFrameFill(frame, loop);
        _pfwAuto = false;
        if (_errors.count() > errMark) {
            parAutoRefused(errMark, warnMark, fatalMark, plainEnd, forTok);
            _parTok = savedParTok;
            parAutoTraceLine(traceAt, "serial", String.withCString("block-refused"), form, (String*)0, (String*)0, 0, (String*)0);
            if (fromWhile) plRegister(plain, 3, plain, (Array*)0, whileInc);
            return plain;
        }
        // The warnings the loop's parse gave, again: the block's parse gave
        // them a second time.
        for (u32 i = plainWarn; i < warnMark; i++) : serial
            _warnings.add(_warnings.get(i));
        // A perfect two-deep nest becomes one block over the W*H grid (the
        // reference explains).
        Token* savedMkAt0 = _mkAt;
        _mkAt = forTok;
        Node* body = parAutoGridNest(loop, frame, gridCap);
        _mkAt = savedMkAt0;
        if (body == (Node*)0) {
            body = mk((u16)nkBlock);
            body.add(loop);
        }
        // Named where the loop is, file:line (a second one on the line #2,
        // as the C path names its blocks), so a program can ask where a
        // lifted loop ran (Par.ranOn) and XC_PAR_REPORT says which loop it is.
        _parAutoCounter = _parAutoCounter + (u32)1;
        String* lf = (forTok != (Token*)0 && forTok.file() != (String*)0) ? forTok.file() : String.withCString("?");
        u32 lcut = (u32)0;
        for (u32 q = (u32)0; q < lf.byteLength(); q = q + (u32)1)
            if (lf.byteAt(q) == (u8)'/') lcut = q + (u32)1;
        String* name = lf.substringBytes(lcut, lf.byteLength() - lcut);
        name.appendByte((u8)':');
        name.append(String.withU32(forTok != (Token*)0 ? forTok.line() : (u32)0));
        if (_parAutoLabels == (Map*)0)
            _parAutoLabels = new Map();
        Number* lseen = (Number*)_parAutoLabels.get((Hashable*)name);
        u32 lnth = lseen != (Number*)0 ? lseen.asU32() + (u32)1 : (u32)1;
        _parAutoLabels.set((Hashable*)String.withString(name), (Object*)Number.with(lnth));
        if (_parAutoLabelLog == (Array*)0) _parAutoLabelLog = new Array();
        _parAutoLabelLog.add((Object*)String.withString(name));
        if (lnth > (u32)1) {
            name.appendByte((u8)'#');
            name.append(String.withU32(lnth));
        }
        Token* savedMkAt = _mkAt;
        _mkAt = forTok;
        Array* savedNoted = _pfwNoted;
        _pfwNoted = new Array();
        Node* out = parDesugar(body, frame, name, reds);
        pfwRegister(out, loop, (Array*)0, _pfwNoted, 2, plain);
        _pfwNoted = savedNoted;
        _mkAt = savedMkAt;
        _parTok = savedParTok;
        if (out == (Node*)0 || _errors.count() > errMark) {
            parAutoRefused(errMark, warnMark, fatalMark, plainEnd, forTok);
            parAutoTraceLine(traceAt, "serial", String.withCString("block-refused"), form, (String*)0, (String*)0, 0, (String*)0);
            if (fromWhile) plRegister(plain, 3, plain, (Array*)0, whileInc);
            return plain;
        }
        plRegister(out, plKind, plain, (Array*)0, whileInc);
        if (_parAutoTraceOn) {
            Array* grid = (Array*)frame.get((Hashable*)String.withCString("grid"));
            String* rl = (String*)0;
            for (u32 q = 0; q < reds.count(); q++) {
                Node* r = (Node*)reds.get(q);
                if (rl == (String*)0) rl = String.withCString("");
                else rl.appendByte(',');
                rl.append(r.op());
                rl.appendByte(':');
                rl.append(r.name());
                if (r.num() == 1) rl.appendCString("[]");
            }
            parAutoTraceLine(traceAt, "lifted", String.withCString("block"), form, name, rl, grid != (Array*)0 ? grid.count() : 1,
                             Parser.parAutoImplSpan(_parCounter - 1, _parCounter));
        }
        return out;
    }

    // Drop a's entries after the first n.
    static void parAutoCut(Array* a, u32 n)
    {
        if (a != (Array*)0 && a.count() > n) a.removeRange(n, a.count() - n);
    }

    // Move a's entries from `from` on to index `to` (to <= from).
    static void parAutoMoveTail(Array* a, u32 from, u32 to)
    {
        if (a == (Array*)0 || from >= a.count() || to >= from) return;
        Array* tail = a.subarray(from, a.count() - from);
        a.removeRange(from, a.count() - from);
        a.insertAll(to, tail);
    }

    static void parAutoMarkSet(Map* m, string k, Object* v)
    {
        if (v != (Object*)0) m.set((Hashable*)String.withCString(k), v);
    }
    static u32 parAutoMarkN(Map* m, string k)
    {
        Number* n = (Number*)m.get((Hashable*)String.withCString(k));
        return n != (Number*)0 ? n.asU32() : 0;
    }

    // What a parse of a loop changes that parAutoRollback puts back: the
    // cursor and the tokens (a rewrite copies them), the diagnostics and the
    // trace, the block, ParImpl, :scan and lifted-loop numbers, the classes
    // made, the sites, the runtime request, the `if` a counted `while`
    // leaves, and what the last declaration noted.
    Map* parAutoMark(void)
    {
        Map* m = new Map();
        Parser.parAutoMarkSet(m, "tokens", (Object*)_tokens);
        Parser.parAutoMarkSet(m, "pos", (Object*)Number.withU32(_pos));
        Parser.parAutoMarkSet(m, "errors", (Object*)Number.withU32(_errors.count()));
        Parser.parAutoMarkSet(m, "warnings", (Object*)Number.withU32(_warnings.count()));
        Parser.parAutoMarkSet(m, "fatal", (Object*)Number.withU32(_fatal ? 1 : 0));
        Parser.parAutoMarkSet(m, "trace", (Object*)Number.withU32(_parAutoTrace != (Array*)0 ? _parAutoTrace.count() : 0));
        Parser.parAutoMarkSet(m, "wants", (Object*)Number.withU32(_parAutoWantsRuntime ? 1 : 0));
        Parser.parAutoMarkSet(m, "blk", (Object*)Number.withU32(_blkCounter));
        Parser.parAutoMarkSet(m, "par", (Object*)Number.withU32(_parCounter));
        Parser.parAutoMarkSet(m, "seq", (Object*)Number.withU32(_scanSeq));
        Parser.parAutoMarkSet(m, "auto", (Object*)Number.withU32(_parAutoCounter));
        Parser.parAutoMarkSet(m, "labels", (Object*)Number.withU32(_parAutoLabelLog != (Array*)0 ? _parAutoLabelLog.count() : 0));
        Parser.parAutoMarkSet(m, "classes", (Object*)Number.withU32(_blkClasses.count()));
        Parser.parAutoMarkSet(m, "sites", (Object*)Number.withU32(_plSites != (Array*)0 ? _plSites.count() : 0));
        Parser.parAutoMarkSet(m, "pfw", (Object*)Number.withU32(_pfwSites != (Array*)0 ? _pfwSites.count() : 0));
        Parser.parAutoMarkSet(m, "pw", (Object*)Number.withU32(_pwPending ? 1 : 0));
        Parser.parAutoMarkSet(m, "pwV", (Object*)_pwPendV);
        Parser.parAutoMarkSet(m, "pwBound", (Object*)_pwPendBound);
        Parser.parAutoMarkSet(m, "pwCmp", (Object*)_pwPendCmp);
        Parser.parAutoMarkSet(m, "pwAt", (Object*)_pwPendAt);
        Parser.parAutoMarkSet(m, "lastName", (Object*)_lastBlkName);
        Parser.parAutoMarkSet(m, "lastBase", (Object*)_lastBlkBase);
        Parser.parAutoMarkSet(m, "lastParams", (Object*)_lastBlkParams);
        Parser.parAutoMarkSet(m, "lastRet", (Object*)_lastBlkRet);
        Parser.parAutoMarkSet(m, "lastWb", (Object*)Number.withU32(_lastBlkWb ? 1 : 0));
        Parser.parAutoMarkSet(m, "outlet", (Object*)Number.withU32(_lastTypeIsOutlet ? 1 : 0));
        Parser.parAutoMarkSet(m, "vararg", (Object*)Number.withU32(_sawVarargForward ? 1 : 0));
        return m;
    }

    void parAutoRollback(Map* m)
    {
        _tokens = (Array*)pfwGet(m, "tokens");
        _pos = Parser.parAutoMarkN(m, "pos");
        Parser.parAutoCut(_errors, Parser.parAutoMarkN(m, "errors"));
        Parser.parAutoCut(_warnings, Parser.parAutoMarkN(m, "warnings"));
        _fatal = Parser.parAutoMarkN(m, "fatal") != 0;
        Parser.parAutoCut(_parAutoTrace, Parser.parAutoMarkN(m, "trace"));
        _parAutoWantsRuntime = Parser.parAutoMarkN(m, "wants") != 0;
        _blkCounter = Parser.parAutoMarkN(m, "blk");
        _parCounter = Parser.parAutoMarkN(m, "par");
        _scanSeq = Parser.parAutoMarkN(m, "seq");
        _parAutoCounter = Parser.parAutoMarkN(m, "auto");
        u32 labels = Parser.parAutoMarkN(m, "labels");
        while (_parAutoLabelLog != (Array*)0 && _parAutoLabelLog.count() > labels) {
            String* name = (String*)_parAutoLabelLog.get(_parAutoLabelLog.count() - 1);
            _parAutoLabelLog.removeAt(_parAutoLabelLog.count() - 1);
            Number* n = (Number*)_parAutoLabels.get((Hashable*)name);
            _parAutoLabels.set((Hashable*)name, (Object*)Number.with(n.asU32() - 1));
        }
        Parser.parAutoCut(_blkClasses, Parser.parAutoMarkN(m, "classes"));
        Parser.parAutoCut(_plSites, Parser.parAutoMarkN(m, "sites"));
        Parser.parAutoCut(_pfwSites, Parser.parAutoMarkN(m, "pfw"));
        _pwPending = Parser.parAutoMarkN(m, "pw") != 0;
        _pwPendV = (String*)pfwGet(m, "pwV");
        _pwPendBound = (Array*)pfwGet(m, "pwBound");
        _pwPendCmp = (Token*)pfwGet(m, "pwCmp");
        _pwPendAt = (Token*)pfwGet(m, "pwAt");
        _lastBlkName = (String*)pfwGet(m, "lastName");
        _lastBlkBase = (String*)pfwGet(m, "lastBase");
        _lastBlkParams = (Array*)pfwGet(m, "lastParams");
        _lastBlkRet = (String*)pfwGet(m, "lastRet");
        _lastBlkWb = Parser.parAutoMarkN(m, "lastWb") != 0;
        _lastTypeIsOutlet = Parser.parAutoMarkN(m, "outlet") != 0;
        _sawVarargForward = Parser.parAutoMarkN(m, "vararg") != 0;
    }

    // ParImpl numbers [from, to) for XC_PAR_AUTO_TRACE: `n`, `a..b`, or 0.
    static String* parAutoImplSpan(u32 from, u32 to)
    {
        if (to <= from) return (String*)0;
        String* s = String.withU32(from);
        if (to - from > 1) {
            s.appendCString("..");
            s.append(String.withU32(to - 1));
        }
        return s;
    }

    // A running total under --par-style=auto (#144): the loop's tree as the
    // `par :scan(op acc) { loop }` block the scan expansion makes of it
    // (parScanExpand), with the tests a written :scan's tokens get, read
    // from the tree: a range `for` with a type, no step or annotation, and a
    // braced body (SRC_SCANFORM), acc a local of an integer or floating type
    // (a floating one with +), and a body that only updates and stores acc
    // (scBodyOk). The loop's parse said its diagnostics once; the expansion
    // takes its body twice, and says them again for each. A loop the scan
    // does not take, or whose expansion reports an error, stays the loop,
    // and the expansion's errors go.
    Node* parAutoScanFor(Node* plain, Token* ft, u32 forPos, u32 plainEnd, u32 errFrom, u32 warnFrom)
    {
        String* op = _parScanOp;
        String* acc = _parScanAcc;
        _parScanAcc = (String*)0;
        Node* d = plain.kind() == nkForCStyle && plain.kidCount() == 4 ? Parser.pacKid0(plain.kid(0)) : (Node*)0;
        Node* c = d != (Node*)0 ? Parser.pacKid0(plain.kid(1)) : (Node*)0;
        Node* body = d != (Node*)0 ? plain.kid(3) : (Node*)0;
        if (!plain.hasSrc(SRC_SCANFORM) || d == (Node*)0 || d.kind() != nkVariableDecl || d.kidCount() == 0
            || c == (Node*)0 || c.kidCount() != 2 || body == (Node*)0 || body.kind() != nkBlock || !Parser.scIntType(d.op()))
            return plain;
        u32 dd = 0;
        String* aty = blkTyOf(blkLookup(acc, &dd));
        bool isFloat = aty != (String*)0 && (Parser._same(aty, "float") || Parser._same(aty, "double"));
        if (aty == (String*)0 || (!isFloat && !Parser.scIntType(aty)) || (isFloat && !Parser._same(op, "+")))
            return plain;
        Array* outs = new Array();
        _scanQuiet = true;
        bool ok = scBodyOk(body, ft, acc, op, d.name(), ft, outs);
        _scanQuiet = false;
        u32 inherited = _goalNow != 0 ? _goalNow : _goalDefault;
        if (!ok || (isFloat && inherited == 2)) return plain;
        Map* s = new Map();
        Parser.parAutoMarkSet(s, "op", (Object*)op);
        Parser.parAutoMarkSet(s, "acc", (Object*)acc);
        Parser.parAutoMarkSet(s, "aty", (Object*)aty);
        Parser.parAutoMarkSet(s, "ity", (Object*)d.op());
        Parser.parAutoMarkSet(s, "iv", (Object*)d.name());
        Parser.parAutoMarkSet(s, "incl", (Object*)Number.withU32(Parser._same(c.op(), "<=") ? 1 : 0));
        Parser.parAutoMarkSet(s, "A", (Object*)d.kid(0));
        Parser.parAutoMarkSet(s, "B", (Object*)c.kid(1));
        Parser.parAutoMarkSet(s, "BODY", (Object*)body);
        Parser.parAutoMarkSet(s, "outs", (Object*)outs);
        Parser.parAutoMarkSet(s, "goals", (Object*)new Array());
        Parser.parAutoMarkSet(s, "pt", (Object*)ft);
        Parser.parAutoMarkSet(s, "toks", (Object*)_tokens);
        Parser.parAutoMarkSet(s, "from", (Object*)Number.withU32(forPos));
        Parser.parAutoMarkSet(s, "to", (Object*)Number.withU32(plainEnd));
        Parser.parAutoMarkSet(s, "bo", (Object*)Number.withU32(parScanBrace(body, forPos, plainEnd)));
        Parser.parAutoMarkSet(s, "errs", (Object*)_errors.subarray(errFrom, _errors.count() - errFrom));
        Parser.parAutoMarkSet(s, "warns", (Object*)_warnings.subarray(warnFrom, _warnings.count() - warnFrom));
        u32 errMark = _errors.count();
        bool fatalMark = _fatal;
        Node* out = parScanExpand(s);
        if (out != (Node*)0 && _errors.count() == errMark)
            return out;
        parAutoTakeBack(errMark, fatalMark, plainEnd);
        return plain;
    }

    void parAutoTakeBack(u32 errMark, bool fatalMark, u32 plainEnd)
    {
        while (_errors.count() > errMark)
            _errors.removeAt(_errors.count() - (u32)1);
        _fatal = fatalMark;
        _pos = plainEnd;
    }

    // As parAutoTakeBack, for the block form of a loop under --par-style=auto:
    // its warnings go too, and -Wpar-auto says why the loop stays a loop, with
    // the first error the block form reported. As the reference.
    void parAutoRefused(u32 errMark, u32 warnMark, bool fatalMark, u32 plainEnd, Token* forTok)
    {
        String* e = _errors.count() > errMark ? (String*)_errors.get(errMark) : (String*)0;
        while (_warnings.count() > warnMark)
            _warnings.removeAt(_warnings.count() - (u32)1);
        parAutoTakeBack(errMark, fatalMark, plainEnd);
        parAutoRefusedWhy(e, forTok);
    }

    // -Wpar-auto's line for a block form refused with the error `e`.
    void parAutoRefusedWhy(String* e, Token* forTok)
    {
        if (e == (String*)0) return;
        u32 at = e.byteIndexOf(String.withCString("error: "));
        if (at == String.notFound()) return;
        String* w = String.withCString("this loop runs serially, not as a 'par' block (--par-style): its block form is refused: ");
        w.append(e.substringFromByte(at + 7));
        warnAt(String.withCString("par-auto"), w, forTok);
    }

    // The goals of a lifted loop's copy, as a parse in the block's frame read
    // them: a loop without a goal of its own takes `g`, the goal around it,
    // the block's for the lifted loop, and a C-style loop with one of its
    // own passes that on to its body (parseFor, parseWhile).
    void parAutoGoals(Node* n, u32 g)
    {
        u16 k = n.kind();
        if (k == nkForCStyle && n.hasSrc(SRC_GOAL) && (n.hasFlag(NF_GOAL_SPEED) || n.hasFlag(NF_GOAL_ACCURACY)))
            g = n.hasFlag(NF_GOAL_SPEED) ? 1 : 2;
        else if (k == nkForCStyle || k == nkWhile || k == nkForIn) {
            n.setFlags(n.flags() & $FFF3FFFF);
            goalFlags(n, g);
        }
        for (u32 i = 0; i < n.kidCount(); i++) parAutoGoals(n.kid(i), g);
    }

    u16 parTokType(u32 i)
    {
        if (i >= _tokens.count()) return (u16)tokEOF;
        return ((Token*)_tokens.get(i)).type();
    }
    // An integer literal's value, decimal or 0x hex, as strtoull reads it.
    static u64 parLiteralValue(String* t)
        {
        u64 v = (u64)0;
        u32 i = (u32)0;
        u32 base = (u32)10;
        if (t.byteLength() > (u32)2 && t.byteAt((u32)0) == (u8)'0' && (t.byteAt((u32)1) == (u8)'x' || t.byteAt((u32)1) == (u8)'X'))
            {
            base = (u32)16;
            i = (u32)2;
            }
        for (; i < t.byteLength(); i = i + (u32)1)
            {
            u8 c = t.byteAt(i);
            u32 d = c >= (u8)'0' && c <= (u8)'9' ? (u32)(c - (u8)'0')
                  : c >= (u8)'a' && c <= (u8)'f' ? (u32)(c - (u8)'a') + (u32)10
                  : c >= (u8)'A' && c <= (u8)'F' ? (u32)(c - (u8)'A') + (u32)10 : (u32)99;
            if (d >= base)
                break;
            v = v * (u64)base + (u64)d;
            }
        return v;
        }

    String* parTokValue(u32 i)
    {
        if (i >= _tokens.count()) return String.withCString("");
        return ((Token*)_tokens.get(i)).value();
    }
    // At `acc = E;` (token i is acc, at a statement's start): "min" or "max"
    // when the statement is the whole body of `if (E cmp acc)` or
    // `if (acc cmp E)` with the same E and no else, else 0 (as the
    // reference's parAutoMinMaxAt).
    String* parAutoMinMax(u32 i, String* name, u32 be)
    {
        if (i < (u32)4 || parTokType(i - (u32)1) != (u16)tokRParen) return (String*)0;
        u32 p = i - (u32)1;
        i32 d = (i32)0;
        while (p > (u32)0) {
            u16 t = parTokType(p);
            if (t == (u16)tokRParen) d = d + (i32)1;
            if (t == (u16)tokLParen) d = d - (i32)1;
            if (d == (i32)0) break;
            p = p - (u32)1;
        }
        if (d != (i32)0 || p == (u32)0 || parTokType(p - (u32)1) != (u16)tokIf) return (String*)0;
        u32 cmp = (u32)0;
        d = (i32)0;
        for (u32 j = p + (u32)1; j < i - (u32)1; j = j + (u32)1) {
            u16 t = parTokType(j);
            if (t == (u16)tokLParen || t == (u16)tokLBracket) d = d + (i32)1;
            if (t == (u16)tokRParen || t == (u16)tokRBracket) d = d - (i32)1;
            if (d == (i32)0 && (t == (u16)tokLess || t == (u16)tokGreater || t == (u16)tokLessEq || t == (u16)tokGreaterEq)) {
                if (cmp != (u32)0) return (String*)0;
                cmp = j;
            }
        }
        if (cmp == (u32)0) return (String*)0;
        bool accLeft = cmp == p + (u32)2 && parTokType(p + (u32)1) == (u16)tokIdentifier && parTokValue(p + (u32)1).equals(name);
        bool accRight = cmp + (u32)2 == i - (u32)1 && parTokType(cmp + (u32)1) == (u16)tokIdentifier && parTokValue(cmp + (u32)1).equals(name);
        if (accLeft == accRight) return (String*)0;
        u32 es = accLeft ? cmp + (u32)1 : p + (u32)1;
        u32 ee = accLeft ? i - (u32)1 : cmp;
        u32 r = i + (u32)2;
        for (u32 j = es; j < ee; j = j + (u32)1) {
            if (r >= be || parTokType(r) != parTokType(j)) return (String*)0;   // (a bare body's range ends AT its semicolon, below)
            String* vj = parTokValue(j);
            String* vr = parTokValue(r);
            u32 lj = vj == (String*)0 ? (u32)0 : vj.byteLength();
            u32 lr = vr == (String*)0 ? (u32)0 : vr.byteLength();
            if ((lj > (u32)0 || lr > (u32)0) && (vj == (String*)0 || vr == (String*)0 || !vj.equals(vr))) return (String*)0;
            r = r + (u32)1;
        }
        if (r > be || parTokType(r) != (u16)tokSemicolon || parTokType(r + (u32)1) == (u16)tokElse) return (String*)0;
        u16 c = parTokType(cmp);
        bool less = c == (u16)tokLess || c == (u16)tokLessEq;
        return String.withCString(less != accLeft ? "min" : "max");
    }

    static bool parAutoAssignOp(u16 t)
    {
        return t == (u16)tokAssign || t == (u16)tokPlusAssign || t == (u16)tokStarAssign
            || t == (u16)tokAmpAssign || t == (u16)tokPipeAssign || t == (u16)tokCaretAssign;
    }
    static bool parAutoAnyAssignOp(u16 t)
    {
        return t >= (u16)tokAssign && t <= (u16)tokCaretAssign;
    }

    // The index just past the statement that starts at `from`: a block, an
    // `if` with its `else`, a `for`, `while` or `switch` and its body, else
    // the `;` at depth 0; 0 when the tokens run out. As the reference.
    u32 parAutoStatementEnd(u32 from, u32 n)
    {
        u16 t = parTokType(from);
        if (t == (u16)tokLBrace) {
            u32 d = (u32)0;
            for (u32 i = from; i < n; i = i + (u32)1) {
                u16 ty = parTokType(i);
                if (ty == (u16)tokLBrace) d = d + (u32)1;
                else if (ty == (u16)tokRBrace) { d = d - (u32)1; if (d == (u32)0) return i; }
            }
            return (u32)0;
        }
        if (t == (u16)tokIf || t == (u16)tokFor || t == (u16)tokWhile || t == (u16)tokSwitch) {
            if (parTokType(from + (u32)1) != (u16)tokLParen) return (u32)0;
            u32 d = (u32)0;
            u32 i = from + (u32)1;
            while (i < n) {
                u16 ty = parTokType(i);
                if (ty == (u16)tokLParen) d = d + (u32)1;
                else if (ty == (u16)tokRParen) { d = d - (u32)1; if (d == (u32)0) break; }
                i = i + (u32)1;
            }
            if (i >= n) return (u32)0;
            u32 e = parAutoStatementEnd(i + (u32)1, n);
            if (e == (u32)0) return (u32)0;
            if (t == (u16)tokIf && parTokType(e + (u32)1) == (u16)tokElse) return parAutoStatementEnd(e + (u32)2, n);
            return e;
        }
        u32 d = (u32)0;
        for (u32 i = from; i < n; i = i + (u32)1) {
            u16 ty = parTokType(i);
            if (ty == (u16)tokLParen || ty == (u16)tokLBracket || ty == (u16)tokLBrace) d = d + (u32)1;
            else if (ty == (u16)tokRParen || ty == (u16)tokRBracket || ty == (u16)tokRBrace) d = d - (u32)1;
            else if (ty == (u16)tokSemicolon && d == (u32)0) return i;
        }
        return (u32)0;
    }

    // The recogniser's refusal: the rule, for XC_PAR_AUTO_TRACE.
    bool parAutoNo(u8* rule)
    {
        _parAutoWhy = String.withCString(rule);
        return false;
    }

    // -Wpar-auto, at the loop the cursor is on: why it stays a loop.
    void parAutoWarnSerial(String* why)
    {
        String* w = String.withCString("this loop runs serially, not as a 'par' block (--par-style): ");
        w.append(why);
        warnAt(String.withCString("par-auto"), w, cur());
    }

    // Token i is a variable's name: an identifier not after `.` or `->`.
    bool parAutoIsVarTok(u32 i)
    {
        u16 p = parTokType(i - 1);
        return parTokType(i) == tokIdentifier && p != tokDot && p != tokArrow;
    }

    // The variable at token i is written there: assigned, or stepped by ++ or
    // --. A declaration of the name (a type before it) is not a write, nor is
    // a store through it.
    bool parAutoWritesAt(u32 i)
    {
        u16 nx = parTokType(i + 1);
        u16 pv = parTokType(i - 1);
        if (isTypeKeywordToken(pv) || (pv == tokIdentifier && isTypeName(parTokValue(i - 1)))) return false;
        // `*p = …` writes what p points at, not p.
        if (pv == tokStar && Parser.parAutoAnyAssignOp(nx)) return false;
        return Parser.parAutoAnyAssignOp(nx) || nx == tokPlusPlus || nx == tokMinusMinus
            || pv == tokPlusPlus || pv == tokMinusMinus;
    }

    // #415: the body [bs, be) writes the loop's own variable (`i++`, `i += 2`,
    // `i = …`). A block's work items each have their own copy, and the loop
    // as written skips or repeats iterations.
    bool parAutoIVWritten(u32 bs, u32 be, String* var)
    {
        for (u32 i = bs; i < be; i++)
            if (parAutoIsVarTok(i) && parTokValue(i).equals(var) && parAutoWritesAt(i))
                return true;
        return false;
    }

    // #416: a block reads the loop's bound [b0, b1) once, before its items run;
    // the loop as written reads it before every iteration. A bound that names
    // the loop's variable or a variable the body [bs, be) writes, or that
    // reads memory (a subscript, a member, a call, `*p`) through a name the
    // body stores through, keeps the loop serial. A call in the body is not
    // taken as a store, as elsewhere in the scan. The reason for -Wpar-auto
    // (and the rule in _parAutoWhy), else 0.
    String* parAutoBoundWritten(u32 b0, u32 b1, u32 bs, u32 be, String* var)
    {
        Array* names = new Array();
        bool mem = false;
        for (u32 i = b0; i < b1; i++) {
            u16 t = parTokType(i);
            if (t == tokLBracket || t == tokDot || t == tokArrow) mem = true;
            if (t == tokStar) {
                u16 p = parTokType(i - 1);
                if (i == b0 || !(p == tokIdentifier || p == tokIntLiteral || p == tokRParen || p == tokRBracket))
                    mem = true;
            }
            if (!parAutoIsVarTok(i)) continue;
            if (parTokType(i + 1) == tokLParen) {
                mem = true;
                continue;
            }
            String* nm = parTokValue(i);
            if (isTypeName(nm)) continue;
            if (nm.equals(var)) {
                _parAutoWhy = String.withCString("bound-write");
                String* m = String.withCString("its bound reads its loop variable '");
                m.append(nm);
                m.appendCString("'");
                return m;
            }
            names.add((Object*)nm);
        }
        for (u32 i = bs; i < be; i++) {
            if (!parAutoIsVarTok(i)) continue;
            String* nm = parTokValue(i);
            bool listed = false;
            for (u32 k = 0; k < names.count(); k++)
                if (((String*)names.get(k)).equals(nm)) listed = true;
            if (!listed) continue;
            if (parAutoWritesAt(i)) {
                _parAutoWhy = String.withCString("bound-write");
                String* m = String.withCString("its bound reads '");
                m.append(nm);
                m.appendCString("', which its body writes");
                return m;
            }
            if (!mem) continue;
            // Through the name: a store at the end of its subscripts and
            // members (a method call ends them), or `*p = …`.
            u32 j = i + 1;
            bool chained = false;
            while (j < be) {
                u16 t = parTokType(j);
                if (t == tokLBracket) {
                    u32 d = 0;
                    while (j < be) {
                        u16 tj = parTokType(j);
                        if (tj == tokLBracket) d++;
                        if (tj == tokRBracket) {
                            d--;
                            if (d == 0) break;
                        }
                        j++;
                    }
                    j++;
                    chained = true;
                    continue;
                }
                if ((t == tokDot || t == tokArrow) && parTokType(j + 1) == tokIdentifier && parTokType(j + 2) != tokLParen) {
                    j = j + 2;
                    chained = true;
                    continue;
                }
                break;
            }
            u16 at = parTokType(j);
            u16 pv = parTokType(i - 1);
            bool stored = chained && (Parser.parAutoAnyAssignOp(at) || at == tokPlusPlus || at == tokMinusMinus
                                      || pv == tokPlusPlus || pv == tokMinusMinus);
            if (pv == tokStar && Parser.parAutoAnyAssignOp(parTokType(i + 1))) stored = true;
            if (stored) {
                _parAutoWhy = String.withCString("bound-memory");
                String* m = String.withCString("its bound reads memory through '");
                m.append(nm);
                m.appendCString("', which its body may write");
                return m;
            }
        }
        return (String*)0;
    }

    // The grid levels (3, 2, or 1 for none) a perfect nest may take, the body
    // of its level `level - 1` being [bs, be): a level whose body writes its
    // own variable or a name in its header runs as written inside the block,
    // for the reasons of #415 and #416 one level in.
    u32 parAutoGridCap(u32 bs, u32 be, u32 level)
    {
        if (level > 3 || parTokType(bs) != tokFor || parTokType(bs + 1) != tokLParen) return 3;
        u32 n = _tokens.count();
        u32 e = parAutoStatementEnd(bs, n);
        if (e == 0 || (e + 1 != be && e != be)) return 3;
        u32 he = 0;
        u32 d = 0;
        String* iv = (String*)0;
        String* ivEq = (String*)0;
        for (u32 i = bs + 1; i < e; i++) {
            u16 t = parTokType(i);
            if (t == tokLParen) d++;
            else if (t == tokRParen) {
                d--;
                if (d == 0) {
                    he = i;
                    break;
                }
            } else if (d == 1 && t == tokIn && parTokType(i - 1) == tokIdentifier && iv == (String*)0)
                iv = parTokValue(i - 1);
            else if (d == 1 && t == tokAssign && parTokType(i - 1) == tokIdentifier && ivEq == (String*)0)
                ivEq = parTokValue(i - 1);
        }
        if (iv == (String*)0) iv = ivEq;
        if (he == 0 || iv == (String*)0) return 3;
        Array* names = new Array();
        names.add((Object*)iv);
        // In order, one name at a time (:serial keeps --par-style=auto off it).
        for (u32 i = bs + 2; i < he; i++) : serial {
            if (!parAutoIsVarTok(i) || parTokType(i + 1) == tokLParen) continue;
            String* nm = parTokValue(i);
            if (isTypeName(nm) || nm.equals(iv) || Parser._same(nm, "step")) continue;
            names.add((Object*)nm);
        }
        // The level's annotations, then its body.
        u32 k = he + 1;
        if (parTokType(k) == tokColon) {
            k++;
            while (parTokType(k) == tokIdentifier) {
                k++;
                if (parTokType(k) == tokLParen) {
                    u32 pd = 0;
                    while (k < e) {
                        u16 t = parTokType(k);
                        if (t == tokLParen) pd++;
                        if (t == tokRParen) {
                            pd--;
                            if (pd == 0) break;
                        }
                        k++;
                    }
                    k++;
                }
                if (parTokType(k) != tokComma) break;
                k++;
            }
        }
        u32 ibs = k;
        u32 ibe = e;
        if (parTokType(k) == tokLBrace) ibs = k + 1;
        for (u32 i = ibs; i < ibe; i++) {
            if (!parAutoIsVarTok(i) || !parAutoWritesAt(i)) continue;
            String* nm = parTokValue(i);
            for (u32 q = 0; q < names.count(); q++)
                if (((String*)names.get(q)).equals(nm)) return level - 1;
        }
        return parAutoGridCap(ibs, ibe, level + 1);
    }

    // The scan expansion's state: its parts while its made code is parsed
    // (parScanExpand), the bodies it has put in, and the last refusal.
    Map*    _scanSplice;
    u32     _scanSpliced;
    String* _scFailMsg;
    Token*  _scFailTok;

    // XC_PAR_AUTO_TRACE: the line for a loop --par-style=auto looked at, at
    // `at`: where (file:line, #n for the n-th on the line), the verdict and
    // the rule that decided it, the loop's form, and for a block its name,
    // reductions, grid rank and ParImpl number ("-" where there is none). A
    // loop of the standard library or the prelude is not listed.
    void parAutoTraceLine(Token* at, u8* verdict, String* rule, String* form, String* name, String* reds, u32 grid, String* impl)
    {
        if (!_parAutoTraceOn) return;
        String* lf = (at != (Token*)0 && at.file() != (String*)0) ? at.file() : String.withCString("?");
        if (_libFiles != (Set*)0 && _libFiles.contains((Hashable*)lf)) return;
        u32 cut = 0;
        for (u32 q = 0; q < lf.byteLength(); q++)
            if (lf.byteAt(q) == '/') cut = q + 1;
        String* pos = lf.substringBytes(cut, lf.byteLength() - cut);
        pos.appendByte(':');
        pos.append(String.withU32(at != (Token*)0 ? at.line() : 0));
        if (_parAutoTrace == (Array*)0) _parAutoTrace = new Array();
        String* l = String.withCString("par-auto-trace: ");
        l.append(pos);
        l.appendByte(9);
        l.appendCString(verdict);
        l.appendCString(" rule=");
        l.append(rule != (String*)0 ? rule : String.withCString("?"));
        l.appendCString(" form=");
        l.append(form);
        l.appendCString(" name=");
        l.append(name != (String*)0 ? name : String.withCString("-"));
        l.appendCString(" reds=");
        l.append(reds != (String*)0 ? reds : String.withCString("-"));
        l.appendCString(" grid=");
        if (grid == 0) l.appendByte('-');
        else l.append(String.withU32(grid));
        l.appendCString(" impl=");
        l.append(impl != (String*)0 ? impl : String.withCString("-"));
        _parAutoTrace.add((Object*)l);
    }

    // ── The par frame walk (#338) ────────────────────────────────
    // A par body's frame, computed from its tree once it is parsed: the
    // captures and their types in first-use order (which sets the block's
    // field layout), the globals the body names, the names it assigns, and
    // its uses of each name, as subscript bases and as array updates, whether
    // it can leave an iteration early, and which `par.x` names a grid body
    // reads. The walk visits the tree in the order the parser read it, and
    // binds the body's declarations as the parser did, in scopes pushed on
    // _blkScopes above the frame's depth, so a name resolves as it did where
    // it was used. A block literal or a nested par block in the body is read
    // through the site the parser registered for it (pfwRegister): its body
    // counts toward the uses, and the names its site passes in are uses at
    // the site. What cannot be captured is still said where it is used
    // (blkNoteUse, blkNoteBareCall), among the parse's other errors.
    //
    // A lifted loop's block is built from a copy of the loop as parsed
    // (parAutoFor), not from a second parse in the block's frame, so the walk
    // of that copy (_pfwAuto) does what the frame did to the parse: it says
    // what the block cannot capture, in the order the parse said it, and
    // reads `self.f` as the ivar f (pfwSelfIvar).
    Map*   _pfw;        // the frame the walk fills
    bool   _pfwTop;     // at the body's own level, not in a literal or nested block
    Array* _pfwSites;   // pfwRegister's entries
    Array* _pfwNoted;   // the names parDesugar's site notes, for pfwRegister
    bool   _pfwAuto;    // walking a lifted loop's copy
    Array* _pfwToks;    // …whose tokens are [_pfwTokFrom, _pfwTokTo) of these
    u32    _pfwTokFrom;
    u32    _pfwTokTo;

    static Object* pfwGet(Map* m, string k)
    {
        return m.get((Hashable*)String.withCString(k));
    }

    // A literal's mk call (kind 0), or a nested written (1) or automatic (2)
    // par block's site, with the body the parser read for it, the literal's
    // parameters, the names the site noted, and for an automatic block the
    // loop as written. Only inside a par body, whose walk reads it.
    void pfwRegister(Node* site, Node* body, Array* params, Array* noted, u32 kind, Node* plain)
    {
        if (site == (Node*)0 || body == (Node*)0) return;
        if (kind == 0) plRegister(site, kind, body, params, 0);
        bool inPar = false;
        for (u32 i = 0; i < _blkFrames.count(); i++)
            if (((Map*)_blkFrames.get(i)).get((Hashable*)String.withCString("par")) != (Object*)0) inPar = true;
        if (!inPar) return;
        if (_pfwSites == (Array*)0) _pfwSites = new Array();
        Array* e = new Array();
        e.add((Object*)site);
        e.add((Object*)body);
        e.add((Object*)(params != (Array*)0 ? params : new Array()));
        e.add((Object*)(noted != (Array*)0 ? noted : new Array()));
        e.add((Object*)Number.with(kind));
        e.add((Object*)(plain != (Node*)0 ? plain : site));
        _pfwSites.add((Object*)e);
    }

    Array* pfwSite(Node* n)
    {
        for (u32 i = 0; i < _pfwSites.count(); i++) {
            Array* e = (Array*)_pfwSites.get(i);
            if ((Object*)e.get(0) == (Object*)n) return e;
        }
        return (Array*)0;
    }

    // The frame of `body`, a par body (a block) or a lifted loop, parsed in
    // `frame`: names, types, wbnames, outer, written, refs, subBase,
    // memWritten, updates, exits and gridUsed.
    Map* parFrameWalk(Node* body, Map* frame)
    {
        Map* w = new Map();
        w.set((Hashable*)String.withCString("depth"), pfwGet(frame, "depth"));
        w.set((Hashable*)String.withCString("names"), (Object*)new Array());
        w.set((Hashable*)String.withCString("types"), (Object*)new Map());
        w.set((Hashable*)String.withCString("wbnames"), (Object*)new Array());
        w.set((Hashable*)String.withCString("written"), (Object*)new Set());
        if (pfwGet(frame, "grid") != (Object*)0)
            w.set((Hashable*)String.withCString("gridUsed"), (Object*)new Set());
        Map* savedW = _pfw;
        bool savedTop = _pfwTop;
        _pfw = w;
        _pfwTop = true;
        blkPushScope();
        pfwNode(body);
        blkPopScope();
        _pfw = savedW;
        _pfwTop = savedTop;
        return w;
    }

    void pfwKids(Node* n)
    {
        for (u32 i = 0; i < n.kidCount(); i++) pfwNode(n.kid(i));
    }

    void pfwNode(Node* n)
    {
        if (n == (Node*)0) return;
        u16 k = n.kind();
        if (k == nkIdent) {
            if (n.hasSrc(SRC_SYNTH)) pfwGridName(n.name());
            else pfwUse(n.name());
            return;
        }
        if (n.hasSrc(SRC_SYNTH)) return;
        if (k == nkMember && _pfwAuto && pfwSelfIvar(n)) {
            pfwUse(n.name());
            return;
        }
        if (_pfwSites != (Array*)0 && (k == nkMethodCall || k == nkBlock)) {
            Array* site = pfwSite(n);
            if (site != (Array*)0) {
                pfwSiteWalk(n, site);
                return;
            }
        }
        if (k == nkBlock) {
            if (n.hasFlag(NF_DECLLIST)) {
                pfwKids(n);
                return;
            }
            blkPushScope();
            pfwKids(n);
            blkPopScope();
            return;
        }
        if (k == nkVariableDecl) {
            // Bound once its initialiser is read, as parseVarDeclStatement does.
            pfwKids(n);
            blkBind(n.name(), n.op(), (Array*)0);
            if (Parser._same(n.op(), "auto") && n.kidCount() > 0) blkBindAuto(n.name(), n.kid(0));
            return;
        }
        if (k == nkForCStyle && n.hasSrc(SRC_RANGE) && n.kidCount() == 4) {
            // A range: its bounds, then the body with the variable bound; the
            // condition's and the step's use of the variable are the parser's.
            Node* d = Parser.pacKid0(n.kid(0));
            Node* c = Parser.pacKid0(n.kid(1));
            if (d != (Node*)0) pfwKids(d);
            if (c != (Node*)0 && c.kidCount() > 1) pfwNode(c.kid(1));
            blkPushScope();
            if (d != (Node*)0) blkBind(d.name(), d.op(), (Array*)0);
            pfwNode(n.kid(3));
            blkPopScope();
            return;
        }
        if (k == nkForIn && n.kidCount() == 3) {
            Node* v = n.kid(0);
            pfwNode(n.kid(1));
            blkPushScope();
            blkBind(v.name(), Parser._same(v.op(), "-") ? (String*)0 : v.op(), (Array*)0);
            pfwNode(n.kid(2));
            blkPopScope();
            return;
        }
        if (k == nkTupleAssign && n.kidCount() > 0) {
            // The targets, the value, then the declared targets are bound.
            u32 last = n.kidCount() - 1;
            for (u32 i = 0; i < last; i++)
                if (n.kid(i).kind() != nkVariableDecl) pfwNode(n.kid(i));
            pfwNode(n.kid(last));
            for (u32 i = 0; i < last; i++)
                if (n.kid(i).kind() == nkVariableDecl) blkBind(n.kid(i).name(), n.kid(i).op(), (Array*)0);
            return;
        }
        if (k == nkAssign && n.kidCount() == 2) {
            pfwNode(n.kid(0));
            pfwNode(n.kid(1));
            pfwWrite(n.kid(0));
            pfwUpdate(n.kid(0), n.op(), n.kid(1));
            return;
        }
        if (k == nkUnary && n.kidCount() > 0) {
            pfwNode(n.kid(0));
            if (Parser._same(n.op(), "&")) pfwMemWrite(n.kid(0));
            if (Parser._same(n.op(), "++") || Parser._same(n.op(), "--")) pfwWrite(n.kid(0));
            return;
        }
        if (k == nkPostfix && n.kidCount() > 0) {
            pfwNode(n.kid(0));
            pfwWrite(n.kid(0));
            if (Parser._same(n.op(), "++")) pfwUpdate(n.kid(0), String.withCString("+="), (Node*)0);
            return;
        }
        if (k == nkSubscript && n.kidCount() > 0) {
            pfwKids(n);
            pfwSubBase(n.kid(0));
            return;
        }
        if (k == nkCall) {
            // A callee that is not a name rides last but was read first; a
            // name is a use after the arguments when it is a local or a
            // parameter (#437), and before them too when it was written in
            // parentheses, `(f)(x)`, which read it as a name.
            u32 argc = n.kidCount();
            bool named = !Parser._same(n.name(), "<indirect>");
            if (!named && argc > 0) {
                argc = argc - 1;
                pfwNode(n.kid(argc));
            }
            if (named && n.hasSrc(SRC_PARENCALLEE)) pfwUse(n.name());
            for (u32 i = 0; i < argc; i++) pfwNode(n.kid(i));
            if (named && blkLookup(n.name(), (u32*)0) != (Map*)0) pfwUse(n.name());
            else if (named && _pfwAuto && _pfwTop) blkBareCallCheck(n);
            return;
        }
        if (k == nkMethodCall && n.hasSrc(SRC_CALLED) && n.kidCount() > 0) {
            // `b(…)` through a block binding: a use of b after the arguments
            // (and before them when written `(b)(…)`). A named literal
            // calling itself is `self.invoke(…)`, no use.
            if (n.hasSrc(SRC_PARENCALLEE)) pfwUse(n.kid(0).name());
            for (u32 i = 1; i < n.kidCount(); i++) pfwNode(n.kid(i));
            Node* r = n.kid(0);
            if (r.kind() == nkIdent && !Parser._same(r.name(), "self")) pfwUse(r.name());
            return;
        }
        if (k == nkReturn || k == nkBreak || k == nkContinue)
            _pfw.set((Hashable*)String.withCString("exits"), (Object*)Number.withU32(1));
        pfwKids(n);
    }

    // A literal or a nested block, read as the parser read it: an automatic
    // block's loop as written first (parsed before the block), the body in
    // its own frame, then the names its site passes in.
    void pfwSiteWalk(Node* n, Array* e)
    {
        Node* body = (Node*)e.get(1);
        Array* params = (Array*)e.get(2);
        Array* noted = (Array*)e.get(3);
        u32 kind = ((Number*)e.get(4)).asU32();
        if (kind == 2) pfwNode((Node*)e.get(5));
        bool savedTop = _pfwTop;
        _pfwTop = false;
        blkPushScope();
        for (u32 i = 0; i < params.count(); i++) {
            Node* p = (Node*)params.get(i);
            blkBind(p.name(), p.op(), (Array*)0);
        }
        pfwNode(body);
        blkPopScope();
        _pfwTop = savedTop;
        if (kind == 0) {
            pfwKids(n);
            return;
        }
        for (u32 i = 0; i < noted.count(); i++) pfwUse((String*)noted.get(i));
    }

    void pfwCount(string key, String* name, u32 by)
    {
        Map* m = (Map*)pfwGet(_pfw, key);
        if (m == (Map*)0) {
            m = new Map();
            _pfw.set((Hashable*)String.withCString(key), (Object*)m);
        }
        Number* had = (Number*)m.get((Hashable*)name);
        u32 c = had == (Number*)0 ? 0 : had.asU32();
        m.set((Hashable*)String.withString(name), (Object*)Number.withU32(c + by));
    }

    // A use of a name: counted, and at the body's own level a capture when it
    // resolves outside the body, or a global when it resolves nowhere.
    void pfwUse(String* name)
    {
        pfwCount("refs", name, 1);
        if (!_pfwTop) return;
        u32 foundDepth = 0;
        Map* info = blkLookup(name, &foundDepth);
        if (info == (Map*)0) {
            if (_pfwAuto && (Parser._same(name, "self") || blkIsIvar(name)))
                _error(Parser.blkSelfMsg(name));
            else if (_pfwAuto && blkIsLaterIvar(name))
                _error(Parser.blkLaterIvarMsg(name));
            // A written block captures an ivar the class declares further
            // down as one declared above, with the type its declaration
            // gives it (#513). A lifted loop stays a loop instead (above).
            String* later = _pfwAuto ? (String*)0 : blkLaterIvarType(name);
            if (later != (String*)0) {
                Array* names = (Array*)pfwGet(_pfw, "names");
                for (u32 i = 0; i < names.count(); i++)
                    if (((String*)names.get(i)).equals(name)) return;
                names.add((Object*)name);
                ((Map*)pfwGet(_pfw, "types")).set((Hashable*)name, (Object*)later);
                return;
            }
            Array* outer = (Array*)pfwGet(_pfw, "outer");
            if (outer == (Array*)0) {
                outer = new Array();
                _pfw.set((Hashable*)String.withCString("outer"), (Object*)outer);
            }
            for (u32 i = 0; i < outer.count(); i++)
                if (((String*)outer.get(i)).equals(name)) return;
            outer.add((Object*)String.withString(name));
            return;
        }
        if (foundDepth >= ((Number*)pfwGet(_pfw, "depth")).asU32()) return;
        String* ty = blkTyOf(info);
        if (_pfwAuto && Parser._same(ty, "auto")) {
            _error(Parser.blkAutoMsg(name));
            return;
        }
        // The frame is not on the stack: any frame there is one the loop
        // sits in.
        if (_pfwAuto && info.get((Hashable*)String.withCString("wb")) != (Object*)0 && _blkFrames.count() > 0) {
            _error(Parser.blkWbMsg(name));
            return;
        }
        Array* names = (Array*)pfwGet(_pfw, "names");
        for (u32 i = 0; i < names.count(); i++)
            if (((String*)names.get(i)).equals(name)) return;
        if (Parser._same(ty, "auto")) return;
        if (info.get((Hashable*)String.withCString("wb")) != (Object*)0) {
            // The frame itself is off the stack by now: any frame left is
            // one the block sits in.
            if (_blkFrames.count() > 0) return;
            ((Array*)pfwGet(_pfw, "wbnames")).add((Object*)name);
        }
        names.add((Object*)name);
        ((Map*)pfwGet(_pfw, "types")).set((Hashable*)name, (Object*)ty);
    }

    // `self.f` in a lifted loop's copy, `f` this class's own ivar binding
    // where it is read: made the name f, at the token after the `.`, as the
    // parse in the block's frame read it (parSelfIvar). Whether it was.
    bool pfwSelfIvar(Node* n)
    {
        if (n.hasFlag(NF_ARROW) || n.kidCount() != 1) return false;
        Node* b = n.kid(0);
        if (b.kind() != nkIdent || !Parser._same(b.name(), "self") || b.hasSrc(SRC_PAREN)) return false;
        String* f = n.name();
        if (Parser._same(f, "release") || Parser._same(f, "retain") || Parser._same(f, "delete")) return false;
        Map* info = blkLookup(f, (u32*)0);
        if (info == (Map*)0 || info.get((Hashable*)String.withCString("ivar")) == (Object*)0) return false;
        u32 fileId = n.fileId();
        u32 line = n.line();
        u32 col = n.col();
        for (u32 i = _pfwTokFrom; i + 1 < _pfwTokTo; i++) {
            Token* t = (Token*)_pfwToks.get(i);
            if (t.type() == tokDot && t.fileId() == n.fileId() && t.line() == n.line() && t.col() == n.col()) {
                Token* ft = (Token*)_pfwToks.get(i + 1);
                fileId = ft.fileId();
                line = ft.line();
                col = ft.col();
                break;
            }
        }
        n.becomeNamed(nkIdent, f);
        n.setPos(fileId, line, col);
        return true;
    }

    // `par.x` … in a `par :grid` body, which the parser reads as these names.
    void pfwGridName(String* name)
    {
        Set* used = (Set*)pfwGet(_pfw, "gridUsed");
        if (!_pfwTop || used == (Set*)0) return;
        if (Parser._same(name, "par$x") || Parser._same(name, "par$y") || Parser._same(name, "par$z")
            || Parser._same(name, "par$w") || Parser._same(name, "par$h") || Parser._same(name, "par$d"))
            used.add((Hashable*)name);
    }

    // An assignment's target: a name the body writes, or an element or field
    // of the array or struct it is rooted at (memWritten).
    void pfwWrite(Node* t)
    {
        pfwMemWrite(t);
        if (_pfwTop && t != (Node*)0 && t.kind() == nkIdent)
            ((Set*)pfwGet(_pfw, "written")).add((Hashable*)t.name());
    }

    void pfwMemWrite(Node* t)
    {
        if (t == (Node*)0 || t.kind() == nkIdent) return;
        String* root = Parser.parRootName(t);
        if (root == (String*)0) return;
        Set* mw = (Set*)pfwGet(_pfw, "memWritten");
        if (mw == (Set*)0) {
            mw = new Set();
            _pfw.set((Hashable*)String.withCString("memWritten"), (Object*)mw);
        }
        mw.add((Hashable*)String.withString(root));
    }

    void pfwUpdate(Node* t, String* op, Node* rhs)
    {
        u32 uses = 0;
        String* key = Parser.parUpdateKey(t, op, rhs, &uses);
        if (key != (String*)0) pfwCount("updates", key, uses);
    }

    void pfwSubBase(Node* base)
    {
        if (base != (Node*)0 && base.kind() == nkIdent) pfwCount("subBase", base.name(), 1);
    }

    // The frame of a par body or a lifted loop parsed in `frame`, from its
    // tree, into `frame`, which parDesugar then reads.
    void parFrameFill(Map* frame, Node* body)
    {
        if (body == (Node*)0) return;
        Map* w = parFrameWalk(body, frame);
        Array* ks = w.allKeys();
        for (u32 i = 0; i < ks.count(); i++) {
            String* k = (String*)ks.get(i);
            if (!Parser._same(k, "depth")) frame.set((Hashable*)k, w.get((Hashable*)k));
        }
    }

    // ── The --par-style=auto recogniser (#338) ───────────────────
    // Whether a loop becomes a par block, decided from its tree once it is
    // parsed (parAutoFor): the verdict, the rule that kept a loop serial,
    // the loop's form, its reductions, a running total, the grid levels a
    // nest may take, and the small-loop test. Its decisions are those the
    // token scan made before it.
    //
    // The header is read from the tree and the source facts the parser put
    // on it (SRC_RANGE, SRC_SERIAL, SRC_GOAL, SRC_STEPBAD, SRC_DESC, and
    // SRC_PAREN and SRC_PLAIN for the condition and the step). The body's
    // rules read the token before or after a name, so a walk of the tree
    // rebuilds the loop's tokens in source order (plStmt, plExpr), with the
    // parentheses SRC_PAREN records and each declaration's names, and the
    // body's rules run on them (parAutoScanBodyAfter).
    // A block literal, a nested par block, a loop lifted inside the loop and
    // a counted `while` the parser rewrote are read through the sites the
    // parser recorded for them, as they were written. An integer literal not
    // spelled as its decimal value is equal to no other. As the reference
    // (XTParser+ParLift.m).
    Array*  _plToks;        // the walk's tokens
    Map*    _plDecls;       // the index of a declaration's first token -> its names
    Map*    _plAddrs;       // the index of an address-of's `&` -> the variable it names, or ""
    Map*    _plArgs;        // the index of a call argument's first token -> the variables it may pass a pointer from
    Token*  _plAt;          // the place the walk's tokens carry
    bool    _plStream;      // the scan's body rules are reading the walk's tokens
    Array*  _plSites;       // [site, kind, plain or body, params, increment]
    u32     _plWhileInc;    // parAutoWhileShape's last increment: 1 v++, 2 ++v, 3 v += 1, 4 v = v + 1
    bool    _plSkipWhileIf; // the next statement is the `if` a rewritten `while` left
    u32     _plLits;        // literals not spelled as their value, so far
    bool    _plExact;       // names, break, return and goto at their place, literals as spelt (scBodyToks)

    // A token at node n's place: its statement's for a statement.
    void plTokAt(u16 t, String* v, Node* n, bool stmt)
    {
        Token* k = Token.with(t, String.withString(v), stmt ? n.stmtLine() : n.line(), stmt ? n.stmtCol() : n.col());
        k.setFileId(stmt ? n.stmtFileId() : n.fileId());
        _plToks.add((Object*)k);
    }

    void plTok(u16 t, string v)
    {
        _plToks.add((Object*)parSynTok(t, String.withCString(v), _plAt));
    }
    void plTokS(u16 t, String* v)
    {
        _plToks.add((Object*)parSynTok(t, v, _plAt));
    }

    // A type keyword's token type, or tokEOF.
    static u16 plKeyword(String* w)
    {
        if (Parser._same(w, "u8")) return tokU8;
        if (Parser._same(w, "i8")) return tokI8;
        if (Parser._same(w, "u16")) return tokU16;
        if (Parser._same(w, "i16")) return tokI16;
        if (Parser._same(w, "u32")) return tokU32;
        if (Parser._same(w, "i32")) return tokI32;
        if (Parser._same(w, "u64")) return tokU64;
        if (Parser._same(w, "i64")) return tokI64;
        if (Parser._same(w, "bool")) return tokBool;
        if (Parser._same(w, "float")) return tokFloat;
        if (Parser._same(w, "double")) return tokDouble;
        if (Parser._same(w, "void")) return tokVoid;
        if (Parser._same(w, "pointer")) return tokPointer;
        if (Parser._same(w, "string")) return tokString;
        if (Parser._same(w, "auto")) return tokAuto;
        return tokEOF;
    }

    static bool plWordByte(u8 c)
    {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$';
    }

    // A type's spelling as tokens: its words (a type keyword as one), its
    // pointer sigils as `*`, and its brackets and commas. With `dims` false
    // an array's dimensions are left for after the declarator's name.
    void plTypeSpelling(String* s, bool dims)
    {
        if (s == (String*)0) return;
        u32 n = s.byteLength();
        for (u32 i = 0; i < n;) {
            u8 c = s.byteAt(i);
            if (Parser.plWordByte(c)) {
                u32 j = i;
                while (j < n && Parser.plWordByte(s.byteAt(j)))
                    j++;
                String* w = s.substringBytes(i, j - i);
                u16 k = Parser.plKeyword(w);
                if (k != tokEOF) plTokS(k, w);
                else if (c >= '0' && c <= '9') plTokS(tokIntLiteral, w);
                else plTokS(tokIdentifier, w);
                i = j;
                continue;
            }
            if (c == '[' && !dims) return;
            if (c == '*' || c == '@') plTok(tokStar, "*");
            else if (c == '<') plTok(tokLess, "<");
            else if (c == '>') plTok(tokGreater, ">");
            else if (c == ',') plTok(tokComma, ",");
            else if (c == '(') plTok(tokLParen, "(");
            else if (c == ')') plTok(tokRParen, ")");
            else if (c == '[') plTok(tokLBracket, "[");
            else if (c == ']') plTok(tokRBracket, "]");
            else if (c == '^') plTok(tokCaret, "^");
            else if (c == '?') plTok(tokQuestion, "?");
            i++;
        }
    }

    // A declaration's array dimensions, after its name.
    void plDims(String* s)
    {
        if (s == (String*)0) return;
        u32 lb = s.indexOfByte('[');
        if (lb == String.notFound()) return;
        plTypeSpelling(s.substringBytes(lb, s.byteLength() - lb), true);
    }

    // An operator's token type.
    static u16 plOpTok(String* op)
    {
        if (Parser._same(op, "+")) return tokPlus;
        if (Parser._same(op, "-")) return tokMinus;
        if (Parser._same(op, "*")) return tokStar;
        if (Parser._same(op, "/")) return tokSlash;
        if (Parser._same(op, "%")) return tokPercent;
        if (Parser._same(op, "&")) return tokAmpersand;
        if (Parser._same(op, "|")) return tokPipe;
        if (Parser._same(op, "^")) return tokCaret;
        if (Parser._same(op, "~")) return tokTilde;
        if (Parser._same(op, "<<")) return tokShiftLeft;
        if (Parser._same(op, ">>")) return tokShiftRight;
        if (Parser._same(op, "<:")) return tokRotateLeft;
        if (Parser._same(op, ":>")) return tokRotateRight;
        if (Parser._same(op, "&&")) return tokLogicalAnd;
        if (Parser._same(op, "||")) return tokLogicalOr;
        if (Parser._same(op, "!")) return tokBang;
        if (Parser._same(op, "==")) return tokEqual;
        if (Parser._same(op, "!=")) return tokNotEqual;
        if (Parser._same(op, "<")) return tokLess;
        if (Parser._same(op, ">")) return tokGreater;
        if (Parser._same(op, "<=")) return tokLessEq;
        if (Parser._same(op, ">=")) return tokGreaterEq;
        if (Parser._same(op, "=")) return tokAssign;
        if (Parser._same(op, "+=")) return tokPlusAssign;
        if (Parser._same(op, "-=")) return tokMinusAssign;
        if (Parser._same(op, "*=")) return tokStarAssign;
        if (Parser._same(op, "/=")) return tokSlashAssign;
        if (Parser._same(op, "%=")) return tokPercentAssign;
        if (Parser._same(op, "&=")) return tokAmpAssign;
        if (Parser._same(op, "|=")) return tokPipeAssign;
        if (Parser._same(op, "^=")) return tokCaretAssign;
        if (Parser._same(op, "<<=")) return tokShlAssign;
        if (Parser._same(op, ">>=")) return tokShrAssign;
        if (Parser._same(op, "<:=")) return tokRolAssign;
        if (Parser._same(op, ":>=")) return tokRorAssign;
        if (Parser._same(op, "++")) return tokPlusPlus;
        if (Parser._same(op, "--")) return tokMinusMinus;
        if (Parser._same(op, ">>>")) return tokByte3;
        return tokIdentifier;
    }

    // The arguments [from, to) of a call, comma-separated.
    void plArgs(Node* n, u32 from, u32 to)
    {
        for (u32 i = from; i < to; i++) {
            if (i > from) plTok(tokComma, ",");
            plExpr(n.kid(i));
        }
    }

    // A name as its token: the parser reads a type keyword, `delete`,
    // `retain` and `release` as names in places, and `par.x` in a grid as
    // `par$x`.
    void plName(String* name, bool synth)
    {
        if (synth && name.hasPrefix(String.withCString("par$"))) {
            plTok(tokIdentifier, "par");
            plTok(tokDot, ".");
            plTokS(tokIdentifier, name.substringFromByte(4));
            return;
        }
        u16 k = Parser.plKeyword(name);
        if (synth && k != tokEOF) plTokS(k, name);
        else if (synth && Parser._same(name, "delete")) plTokS(tokDelete, name);
        else if (synth && Parser._same(name, "retain")) plTokS(tokRetain, name);
        else if (synth && Parser._same(name, "release")) plTokS(tokRelease, name);
        else plTokS(tokIdentifier, name);
    }

    // The site the parser recorded for `n`, or 0.
    Array* plSite(Node* n)
    {
        if (_plSites == (Array*)0 || n == (Node*)0) return (Array*)0;
        for (u32 i = 0; i < _plSites.count(); i++) {
            Array* e = (Array*)_plSites.get(i);
            if ((Object*)e.get(0) == (Object*)n) return e;
        }
        return (Array*)0;
    }

    // The variable an address-of takes the address of, or of an element or
    // member of: through subscripts, members, casts and `*` to a name; else "".
    static String* plAddrRoot(Node* e)
    {
        while (e != (Node*)0) {
            u16 k = e.kind();
            if (k == nkIdent) return e.name();
            bool through = k == nkSubscript || k == nkMember || k == nkCast || (k == nkUnary && Parser._same(e.op(), "*"));
            if (!through || e.kidCount() == 0) break;
            e = e.kid(0);
        }
        return String.withCString("");
    }

    // Each of a comma-separated list of roots with `suffix` after it.
    static String* plArgEach(String* r, string suffix)
    {
        Array* parts = r.splitOnByte(',');
        String* out = String.withCString("");
        for (u32 j = 0; j < parts.count(); j++) : serial {
            if (j > 0) out.appendByte(',');
            out.append((String*)parts.get(j));
            out.appendCString(suffix);
        }
        return out;
    }

    // The variables a call argument may pass a pointer from, comma-separated:
    // the name itself, through a `+` or `-` offset and either arm of `?:`,
    // with `[]` for each subscript or `*` it reads an element through, `.`
    // for each member (whose type the parser does not know) and `!` for a
    // cast to a pointer. A member of no name is `.` alone, and a call's
    // result `()` after the function's name, if it has one; one of Math's
    // built-ins, which return numbers, a literal or anything else gives none.
    String* plArgRoots(Node* e)
    {
        if (e == (Node*)0) return String.withCString("");
        u16 k = e.kind();
        if (k == nkIdent) return e.name();
        if (k == nkCall) {
            if (Parser._same(e.name(), "<indirect>") || e.name().byteLength() == 0) return String.withCString("()");
            String* c = String.withString(e.name());
            c.appendCString("()");
            return c;
        }
        if (k == nkMethodCall) {
            Node* r = e.kid(0);
            String* m = e.name();
            bool maths = Parser._same(m, "sqrt") || Parser._same(m, "sin") || Parser._same(m, "cos") || Parser._same(m, "exp")
                || Parser._same(m, "ln") || Parser._same(m, "pow") || Parser._same(m, "min") || Parser._same(m, "max")
                || Parser._same(m, "abs") || Parser._same(m, "floor") || Parser._same(m, "fma");
            if (maths && r != (Node*)0 && r.kind() == nkIdent && Parser._same(r.name(), "Math")) return String.withCString("");
            return String.withCString("()");
        }
        if (k == nkCast) {
            String* r = plArgRoots(e.kid(0));
            if (r.byteLength() > 0 && parAutoPointsToData(e.name(), 0)) return Parser.plArgEach(r, "!");
            return r;
        }
        if (k == nkMember) {
            String* r = plArgRoots(e.kid(0));
            if (r.byteLength() == 0) return String.withCString(".");
            return Parser.plArgEach(r, ".");
        }
        if (k == nkSubscript || k == nkUnary && Parser._same(e.op(), "*")) {
            String* r = plArgRoots(e.kid(0));
            if (r.byteLength() == 0) return r;
            return Parser.plArgEach(r, "[]");
        }
        String* l = String.withCString("");
        String* r = String.withCString("");
        if (k == nkBinary) {
            if (Parser._same(e.op(), "+") || Parser._same(e.op(), "-")) l = plArgRoots(e.kid(0));
            if (Parser._same(e.op(), "+")) r = plArgRoots(e.kid(1));
        } else if (k == nkTernary) {
            l = plArgRoots(e.kid(1));
            r = plArgRoots(e.kid(2));
        }
        if (l.byteLength() == 0) return r;
        if (r.byteLength() == 0) return l;
        String* both = String.withString(l);
        both.appendByte(',');
        both.append(r);
        return both;
    }

    // A call's arguments [from, to), comma-separated, each recorded at its
    // first token with the variables it may pass a pointer from (_plArgs).
    void plCallArgs(Node* n, u32 from, u32 to)
    {
        for (u32 i = from; i < to; i++) : serial {
            if (i > from) plTok(tokComma, ",");
            String* roots = plArgRoots(n.kid(i));
            if (roots.byteLength() > 0) _plArgs.set((Hashable*)String.withU32(_plToks.count()), (Object*)roots);
            plExpr(n.kid(i));
        }
    }

    void plExpr(Node* e)
    {
        if (e == (Node*)0) return;
        Array* site = plSite(e);
        if (site != (Array*)0) {
            plSiteWalk(site);
            return;
        }
        bool paren = e.hasSrc(SRC_PAREN);
        if (paren) plTok(tokLParen, "(");
        plExprInner(e);
        if (paren) plTok(tokRParen, ")");
    }

    void plExprInner(Node* e)
    {
        u16 k = e.kind();
        if (k == nkIdent) {
            u32 at = _plToks.count();
            plName(e.name(), e.hasSrc(SRC_SYNTH));
            if (_plExact && _plToks.count() == at + 1) {
                Token* t = (Token*)_plToks.get(at);
                _plToks.removeAt(at);
                plTokAt(t.type(), t.value(), e, false);
            }
            return;
        }
        if (k == nkInt) {
            if (e.nilLit()) plTok(tokNil, "nil");
            else if (e.hasSrc(SRC_PLAIN)) plTokS(tokIntLiteral, String.withI64(e.num()));
            else if (_plExact) {
                String* w = String.withCString("#=");
                w.append(String.withI64(e.num()));
                plTokS(tokIntLiteral, w);
            }
            else {
                _plLits++;
                String* w = String.withCString("#");
                w.append(String.withU32(_plLits));
                plTokS(tokIntLiteral, w);
            }
            return;
        }
        if (k == nkFloat) {
            if (_plExact) plTokS(tokFloatLiteral, FloatEncoding.hexForLiteral(e.name(), e.num() != 0));
            else plTok(tokFloatLiteral, "0.0");
            return;
        }
        if (k == nkStr) {
            plTokS(tokStringLiteral, e.name());
            return;
        }
        if (k == nkChar) {
            plTokS(tokCharLiteral, String.withI64(e.num()));
            return;
        }
        if (k == nkBool) {
            if (e.num() != 0) plTok(tokTrue, "true");
            else plTok(tokFalse, "false");
            return;
        }
        if (k == nkBinary || k == nkAssign) {
            plExpr(e.kid(0));
            plTokS(Parser.plOpTok(e.op()), e.op());
            plExpr(e.kid(1));
            return;
        }
        if (k == nkUnary) {
            String* op = e.op();
            if (Parser._same(op, "&")) _plAddrs.set((Hashable*)String.withU32(_plToks.count()), (Object*)Parser.plAddrRoot(e.kid(0)));
            if (Parser._same(op, "<")) plTok(tokLess, "<");
            else plTokS(Parser.plOpTok(op), op);
            plExpr(e.kid(0));
            return;
        }
        if (k == nkPostfix) {
            plExpr(e.kid(0));
            plTokS(Parser.plOpTok(e.op()), e.op());
            return;
        }
        if (k == nkCall) {
            u32 argc = e.kidCount();
            if (Parser._same(e.name(), "<indirect>")) {
                if (argc > 0) argc = argc - 1;
                plExpr(e.kid(argc));
            } else if (e.hasSrc(SRC_PARENCALLEE)) {
                plTok(tokLParen, "(");
                plName(e.name(), false);
                plTok(tokRParen, ")");
            } else
                plName(e.name(), false);
            plTok(tokLParen, "(");
            plCallArgs(e, 0, argc);
            if (e.hasFlag(NF_VAFWD)) {
                if (argc > 0) plTok(tokComma, ",");
                plTok(tokEllipsis, "...");
            }
            plTok(tokRParen, ")");
            return;
        }
        if (k == nkMethodCall) {
            Node* r = e.kid(0);
            if (e.hasSrc(SRC_CALLED) && r != (Node*)0 && r.kind() == nkIdent)
                plTokS(tokIdentifier, r.name());
            else {
                plExpr(r);
                plTok(tokDot, ".");
                if (e.hasSrc(SRC_PARENCALLEE)) {
                    plTok(tokLParen, "(");
                    plTokS(tokIdentifier, e.name());
                    plTok(tokRParen, ")");
                } else
                    plTokS(tokIdentifier, e.name());
            }
            plTok(tokLParen, "(");
            plCallArgs(e, 1, e.kidCount());
            if (e.hasFlag(NF_VAFWD)) {
                if (e.kidCount() > 1) plTok(tokComma, ",");
                plTok(tokEllipsis, "...");
            }
            plTok(tokRParen, ")");
            return;
        }
        if (k == nkSubscript) {
            plExpr(e.kid(0));
            plTok(tokLBracket, "[");
            plExpr(e.kid(1));
            // `m[i, j]`: the indices after the first.
            for (u32 xi = 2; xi < e.kidCount(); xi++) {
                plTok(tokComma, ",");
                plExpr(e.kid(xi));
            }
            plTok(tokRBracket, "]");
            return;
        }
        if (k == nkSlice) {
            plExpr(e.kid(0));
            plTok(tokLBracket, "[");
            plExpr(e.kid(1));
            if (e.hasFlag(NF_INCLUSIVE)) plTok(tokEllipsis, "...");
            else plTok(tokDotDot, "..");
            plExpr(e.kid(2));
            plTok(tokRBracket, "]");
            return;
        }
        if (k == nkRange) {
            plExpr(e.kid(0));
            if (e.hasFlag(NF_INCLUSIVE)) plTok(tokEllipsis, "...");
            else plTok(tokDotDot, "..");
            plExpr(e.kid(1));
            return;
        }
        if (k == nkMember) {
            plExpr(e.kid(0));
            if (e.hasFlag(NF_ARROW)) plTok(tokArrow, "->");
            else plTok(tokDot, ".");
            plTokS(tokIdentifier, e.name());
            return;
        }
        if (k == nkTernary) {
            plExpr(e.kid(0));
            plTok(tokQuestion, "?");
            plExpr(e.kid(1));
            plTok(tokColon, ":");
            plExpr(e.kid(2));
            return;
        }
        if (k == nkCast) {
            plTok(tokLParen, "(");
            plTypeSpelling(e.name(), true);
            if (e.hasFlag(NF_FAILABLE)) plTok(tokQuestion, "?");
            plTok(tokRParen, ")");
            plExpr(e.kid(0));
            return;
        }
        if (k == nkNew) {
            plTok(tokNew, "new");
            plTypeSpelling(e.name(), true);
            if (e.kidCount() > 0 && e.num() == 0) {
                plTok(tokLBracket, "[");
                plExpr(e.kid(0));
                plTok(tokRBracket, "]");
            } else {
                plTok(tokLParen, "(");
                plCallArgs(e, 0, e.kidCount());
                plTok(tokRParen, ")");
            }
            return;
        }
        if (k == nkSizeof) {
            plTok(tokSizeof, "sizeof");
            plTok(tokLParen, "(");
            if (Parser._same(e.name(), "-")) plExpr(e.kid(0));
            else plTypeSpelling(e.name(), true);
            plTok(tokRParen, ")");
            return;
        }
        if (k == nkBlock) {
            // An initialiser list.
            plTok(tokLBrace, "{");
            plArgs(e, 0, e.kidCount());
            plTok(tokRBrace, "}");
            return;
        }
    }

    // A declaration statement: its qualifiers, its type, each declarator,
    // `;`. The declarators' names are recorded at the type's first token
    // (_plDecls). A constructor's arguments are the kids of a declaration
    // whose statement has the init call the parser added (SRC_SYNTH).
    void plDecls(Array* ds, bool ctor)
    {
        if (ds.count() == 0) return;
        Node* d0 = (Node*)ds.get(0);
        if (d0.hasFlag(NF_STATIC)) plTok(tokStatic, "static");
        if (d0.hasFlag(NF_GLOBAL)) plTok(tokGlobal, "global");
        if (d0.hasFlag(NF_VOLATILE)) plTok(tokVolatile, "volatile");
        if (d0.hasFlag(NF_REGISTER)) plTok(tokRegister, "register");
        u32 typeAt = _plToks.count();
        plTypeSpelling(d0.op(), false);
        Array* names = new Array();
        for (u32 i = 0; i < ds.count(); i++) {
            Node* d = (Node*)ds.get(i);
            if (i > 0) plTok(tokComma, ",");
            names.add((Object*)d.name());
            plTokS(tokIdentifier, d.name());
            plDims(d.op());
            if (ctor && i + 1 == ds.count()) {
                plTok(tokLParen, "(");
                plCallArgs(d, 0, d.kidCount());
                plTok(tokRParen, ")");
            } else if (d.kidCount() > 0) {
                plTok(tokAssign, "=");
                plExpr(d.kid(0));
            }
        }
        if (typeAt < _plToks.count())
            _plDecls.set((Hashable*)String.withU32(typeAt), (Object*)names);
        plTok(tokSemicolon, ";");
    }

    // The statements of `n` from kid `from` on.
    void plStmts(Node* n, u32 from)
    {
        for (u32 i = from; i < n.kidCount(); i++) {
            if (_plSkipWhileIf) {
                // The `if (v < B) v = B;` a rewritten `while` left after it.
                _plSkipWhileIf = false;
                continue;
            }
            plStmt(n.kid(i));
        }
    }

    // A loop's annotations, `: unroll, serial, goal(speed)`.
    void plAnnotations(Node* n)
    {
        bool unroll = n.hasFlag(NF_UNROLL);
        bool serial = n.hasSrc(SRC_SERIAL);
        bool ownGoal = n.hasSrc(SRC_GOAL);
        bool other = n.hasSrc(SRC_ANNOT);
        if (!unroll && !serial && !ownGoal && !other) return;
        plTok(tokColon, ":");
        // An annotation the parser does not know (its word is not kept).
        if (other) plTok(tokIdentifier, "_");
        if (unroll) {
            if (other) plTok(tokComma, ",");
            plTok(tokIdentifier, "unroll");
        }
        if (serial) {
            if (other || unroll) plTok(tokComma, ",");
            plTok(tokIdentifier, "serial");
        }
        if (ownGoal) {
            if (other || unroll || serial) plTok(tokComma, ",");
            plTok(tokIdentifier, "goal");
            plTok(tokLParen, "(");
            if (n.hasFlag(NF_GOAL_SPEED)) plTok(tokIdentifier, "speed");
            else plTok(tokIdentifier, "accuracy");
            plTok(tokRParen, ")");
        }
    }

    static void plMark(Map* marks, string k, u32 v)
    {
        if (marks != (Map*)0) marks.set((Hashable*)String.withCString(k), (Object*)Number.withU32(v));
    }
    static u32 plMarkAt(Map* marks, string k)
    {
        Number* v = (Number*)marks.get((Hashable*)String.withCString(k));
        return v != (Number*)0 ? v.asU32() : 0;
    }

    // A `for`: its header, recording where its parts start for the
    // recogniser (marks) when it is the loop being read, then its
    // annotations and body.
    void plFor(Node* f, Map* marks)
    {
        plTok(tokFor, "for");
        plTok(tokLParen, "(");
        Node* init = Parser.pacKid0(f.kid(0));
        Node* d = init != (Node*)0 && init.kind() == nkVariableDecl ? init : (Node*)0;
        Node* c = Parser.pacKid0(f.kid(1));
        Node* st = Parser.pacKid0(f.kid(2));
        if (f.hasSrc(SRC_RANGE)) {
            // `T v in a .. b [step s]`, from the C-style form it became.
            if (d != (Node*)0) plTypeSpelling(d.op(), true);
            plTokS(tokIdentifier, d != (Node*)0 ? d.name() : String.withCString("_"));
            plTok(tokIn, "in");
            if (d != (Node*)0) plExpr(d.kid(0));
            bool incl = c != (Node*)0 && (Parser._same(c.op(), "<=") || Parser._same(c.op(), ">="));
            if (incl) plTok(tokEllipsis, "...");
            else plTok(tokDotDot, "..");
            Parser.plMark(marks, "bndFrom", _plToks.count());
            if (c != (Node*)0) plExpr(c.kid(1));
            Parser.plMark(marks, "bndTo", _plToks.count());
            i64 mag = st != (Node*)0 && st.kid(1) != (Node*)0 && st.kid(1).kind() == nkInt ? st.kid(1).num() : 1;
            bool down = st != (Node*)0 && Parser._same(st.op(), "-=");
            bool lits = d != (Node*)0 && d.kid(0) != (Node*)0 && d.kid(0).kind() == nkInt
                     && c != (Node*)0 && c.kid(1) != (Node*)0 && c.kid(1).kind() == nkInt;
            if (f.hasSrc(SRC_STEPBAD)) {
                plTok(tokIdentifier, "step");
                plTok(tokIdentifier, "_");
            } else if (mag != 1 || (down && !lits)) {
                plTok(tokIdentifier, "step");
                if (down) plTok(tokMinus, "-");
                plTokS(tokIntLiteral, String.withI64(mag));
            }
        } else {
            Parser.plMark(marks, "initFrom", _plToks.count());
            if (d != (Node*)0) plDecls(Array.with((Object*)d), false);
            else if (init != (Node*)0 && init.kind() == nkBlock && init.hasFlag(NF_DECLLIST)) plStmt(init);
            else {
                plExpr(init);
                plTok(tokSemicolon, ";");
            }
            Parser.plMark(marks, "initTo", _plToks.count() - 1);
            Parser.plMark(marks, "condFrom", _plToks.count());
            plExpr(c);
            Parser.plMark(marks, "condTo", _plToks.count());
            plTok(tokSemicolon, ";");
            plExpr(st);
        }
        plTok(tokRParen, ")");
        plAnnotations(f);
        Parser.plMark(marks, "pe", _plToks.count() - 1);
        plStmt(f.kid(3));
    }

    // A site the parser recorded: a block literal (0), a written par block
    // (1), a lifted loop (2), a counted `while` it rewrote to a `for` (3), or
    // the block of that `for` and its `if` where the `while` stood alone
    // (4), as written.
    void plSiteWalk(Array* e)
    {
        u32 kind = ((Number*)e.get(1)).asU32();
        Node* body = (Node*)e.get(2);
        if (kind == 2) {
            plStmt(body);
            return;
        }
        if (kind == 3 || kind == 4) {
            plWhileFrom(body, ((Number*)e.get(4)).asU32());
            _plSkipWhileIf = kind == 3;
            return;
        }
        if (kind == 1) {
            // A written par block: its header, then its body.
            plParHead((Array*)e.get(3));
            plStmt(body);
            return;
        }
        plTok(tokIdentifier, "block");
        plTok(tokVoid, "void");
        plTok(tokLParen, "(");
        Array* params = (Array*)e.get(3);
        for (u32 i = 0; i < params.count(); i++) {
            Node* p = (Node*)params.get(i);
            if (i > 0) plTok(tokComma, ",");
            plTypeSpelling(p.op(), true);
            plTokS(tokIdentifier, p.name());
        }
        plTok(tokRParen, ")");
        plStmt(body);
    }

    // A written par block's header from what parsePar read: `par`, its name,
    // and each decorator with what it took: a :reduce's operator, name and
    // `[]` (from its reduction), a :grid's sizes, and the words of the rest.
    void plParHead(Array* head)
    {
        plTok(tokIdentifier, "par");
        String* name = (String*)head.get(0);
        if (name.byteLength() > 0) plTokS(tokIdentifier, name);
        for (u32 i = 1; i < head.count(); i++) {
            Array* d = (Array*)head.get(i);
            String* dec = (String*)d.get(0);
            plTok(tokColon, ":");
            plTokS(tokIdentifier, dec);
            if (Parser._same(dec, "__scanpass")) continue;
            plTok(tokLParen, "(");
            if (Parser._same(dec, "reduce")) {
                Node* r = (Node*)d.get(1);
                plTokS(Parser.plOpTok(r.op()), r.op());
                plTokS(tokIdentifier, r.name());
                if (r.num() == 1) {
                    plTok(tokLBracket, "[");
                    plTok(tokRBracket, "]");
                }
            } else if (Parser._same(dec, "grid")) {
                for (u32 j = 1; j < d.count(); j++) {
                    if (j > 1) plTok(tokComma, ",");
                    plExpr((Node*)d.get(j));
                }
            } else {
                for (u32 j = 1; j < d.count(); j++) {
                    if (j > 1) plTok(tokComma, ",");
                    plTokS(tokIdentifier, (String*)d.get(j));
                }
            }
            plTok(tokRParen, ")");
        }
    }

    // `while (v < B) { …; v++; }` from the `for` the parser made of it:
    // `for (T __autopar_w = v; __autopar_w < B; __autopar_w += 1) { T v =
    // __autopar_w; … }`, with the increment as it was spelt.
    void plWhileFrom(Node* f, u32 inc)
    {
        Node* d = f != (Node*)0 && f.kind() == nkForCStyle ? Parser.pacKid0(f.kid(0)) : (Node*)0;
        Node* c = d != (Node*)0 ? Parser.pacKid0(f.kid(1)) : (Node*)0;
        if (d == (Node*)0 || d.kind() != nkVariableDecl || c == (Node*)0 || d.kid(0) == (Node*)0 || d.kid(0).kind() != nkIdent) {
            plStmt(f);
            return;
        }
        String* v = d.kid(0).name();
        plTok(tokWhile, "while");
        plTok(tokLParen, "(");
        plTokS(tokIdentifier, v);
        if (Parser._same(c.op(), "<=")) plTok(tokLessEq, "<=");
        else plTok(tokLess, "<");
        plExpr(c.kid(1));
        plTok(tokRParen, ")");
        plTok(tokLBrace, "{");
        Node* b = f.kid(3);
        if (b != (Node*)0 && b.kind() == nkBlock) plStmts(b, 1);
        if (inc == 2) {
            plTok(tokPlusPlus, "++");
            plTokS(tokIdentifier, v);
        } else if (inc == 3) {
            plTokS(tokIdentifier, v);
            plTok(tokPlusAssign, "+=");
            plTok(tokIntLiteral, "1");
        } else if (inc == 4) {
            plTokS(tokIdentifier, v);
            plTok(tokAssign, "=");
            plTokS(tokIdentifier, v);
            plTok(tokPlus, "+");
            plTok(tokIntLiteral, "1");
        } else {
            plTokS(tokIdentifier, v);
            plTok(tokPlusPlus, "++");
        }
        plTok(tokSemicolon, ";");
        plTok(tokRBrace, "}");
    }

    void plStmt(Node* n)
    {
        if (n == (Node*)0 || n.hasSrc(SRC_SYNTH)) return;
        Array* site = plSite(n);
        if (site != (Array*)0) {
            plSiteWalk(site);
            return;
        }
        u16 k = n.kind();
        if (k == nkBlock) {
            if (n.hasFlag(NF_DECLLIST)) {
                Array* ds = new Array();
                bool ctor = false;
                for (u32 i = 0; i < n.kidCount(); i++) {
                    Node* s = n.kid(i);
                    if (s.kind() == nkVariableDecl) ds.add((Object*)s);
                    else if (s.hasSrc(SRC_SYNTH)) ctor = true;
                }
                plDecls(ds, ctor);
                return;
            }
            plTok(tokLBrace, "{");
            plStmts(n, 0);
            plTok(tokRBrace, "}");
            return;
        }
        if (k == nkVariableDecl) {
            plDecls(Array.with((Object*)n), false);
            return;
        }
        if (k == nkExprStatement) {
            plExpr(n.kid(0));
            plTok(tokSemicolon, ";");
            return;
        }
        if (k == nkIf) {
            plTok(tokIf, "if");
            plTok(tokLParen, "(");
            plExpr(n.kid(0));
            plTok(tokRParen, ")");
            plStmt(n.kid(1));
            if (n.kidCount() > 2) {
                plTok(tokElse, "else");
                plStmt(n.kid(2));
            }
            return;
        }
        if (k == nkWhile) {
            plTok(tokWhile, "while");
            plTok(tokLParen, "(");
            plExpr(n.kid(0));
            plTok(tokRParen, ")");
            plStmt(n.kid(1));
            return;
        }
        if (k == nkForCStyle && n.kidCount() == 4) {
            plFor(n, (Map*)0);
            return;
        }
        if (k == nkForIn && n.kidCount() == 3) {
            Node* v = n.kid(0);
            plTok(tokFor, "for");
            plTok(tokLParen, "(");
            if (!Parser._same(v.op(), "-")) plTypeSpelling(v.op(), true);
            plTokS(tokIdentifier, v.name());
            plTok(tokIn, "in");
            plExpr(n.kid(1));
            plTok(tokRParen, ")");
            plStmt(n.kid(2));
            return;
        }
        if (k == nkReturn) {
            if (_plExact) plTokAt(tokReturn, String.withCString("return"), n, true);
            else plTok(tokReturn, "return");
            plArgs(n, 0, n.kidCount());
            plTok(tokSemicolon, ";");
            return;
        }
        if (k == nkBreak) {
            if (_plExact) plTokAt(tokBreak, String.withCString("break"), n, true);
            else plTok(tokBreak, "break");
            plTok(tokSemicolon, ";");
            return;
        }
        if (k == nkContinue) {
            plTok(tokContinue, "continue");
            plTok(tokSemicolon, ";");
            return;
        }
        if (k == nkGoto) {
            if (_plExact) plTokAt(tokGoto, String.withCString("goto"), n, true);
            else plTok(tokGoto, "goto");
            plTokS(tokIdentifier, n.name());
            plTok(tokSemicolon, ";");
            return;
        }
        if (k == nkGotoLabel) {
            plTokS(tokIdentifier, n.name());
            plTok(tokColon, ":");
            return;
        }
        if (k == nkSwitch) {
            plTok(tokSwitch, "switch");
            plTok(tokLParen, "(");
            plExpr(n.kid(0));
            plTok(tokRParen, ")");
            plTok(tokLBrace, "{");
            for (u32 i = 1; i < n.kidCount(); i++) {
                Node* c = n.kid(i);
                if (c == (Node*)0 || c.kind() != nkCase) {
                    plStmt(c);
                    continue;
                }
                bool labels = false;
                for (u32 j = 0; j < c.kidCount(); j++) {
                    Node* l = c.kid(j);
                    if (l == (Node*)0 || l.kind() != nkLabel) continue;
                    labels = true;
                    plTok(tokCase, "case");
                    if (l.hasFlag(NF_RANGE)) {
                        if (!l.hasFlag(NF_RANGE_HI)) plExpr(l.kid(0));
                        plTok(tokDotDot, "..");
                        if (l.hasFlag(NF_RANGE_HI)) plExpr(l.kid(0));
                        else plExpr(l.kid(1));
                    } else
                        plExpr(l.kid(0));
                    plTok(tokColon, ":");
                }
                if (c.hasFlag(NF_DEFAULT)) {
                    plTok(tokDefault, "default");
                    plTok(tokColon, ":");
                }
                for (u32 j = 0; j < c.kidCount(); j++) {
                    Node* s = c.kid(j);
                    if (s != (Node*)0 && s.kind() == nkLabel) continue;
                    if (_plSkipWhileIf) {
                        _plSkipWhileIf = false;
                        continue;
                    }
                    plStmt(s);
                }
            }
            plTok(tokRBrace, "}");
            return;
        }
        if (k == nkDefer) {
            plTok(tokDefer, "defer");
            plStmt(n.kid(0));
            return;
        }
        if (k == nkThrow) {
            plTok(tokThrow, "throw");
            plExpr(n.kid(0));
            plTok(tokSemicolon, ";");
            return;
        }
        if (k == nkTry) {
            plTok(tokTry, "try");
            plStmt(n.kid(0));
            for (u32 i = 1; i < n.kidCount(); i++) {
                Node* c = n.kid(i);
                plTok(tokCatch, "catch");
                plTok(tokLParen, "(");
                if (!Parser._same(c.op(), "-")) plTypeSpelling(c.op(), true);
                plTokS(tokIdentifier, c.name());
                plTok(tokRParen, ")");
                plStmt(c.kid(0));
            }
            return;
        }
        if (k == nkDelete) {
            if (n.num() == 1) plTok(tokRetain, "retain");
            else if (n.num() == 2) plTok(tokRelease, "release");
            else plTok(tokDelete, "delete");
            plExpr(n.kid(0));
            plTok(tokSemicolon, ";");
            return;
        }
        if (k == nkAsmBlock) {
            plTok(tokAsm, "asm");
            plTok(tokLBrace, "{");
            plTok(tokRBrace, "}");
            return;
        }
        if (k == nkTupleAssign && n.kidCount() > 0) {
            u32 last = n.kidCount() - 1;
            plTok(tokLParen, "(");
            for (u32 i = 0; i < last; i++) {
                Node* t = n.kid(i);
                if (i > 0) plTok(tokComma, ",");
                if (t != (Node*)0 && t.kind() == nkVariableDecl) {
                    plTypeSpelling(t.op(), true);
                    plTokS(tokIdentifier, t.name());
                } else
                    plExpr(t);
            }
            plTok(tokRParen, ")");
            plTok(tokAssign, "=");
            plExpr(n.kid(last));
            plTok(tokSemicolon, ";");
            return;
        }
        // An expression where a statement goes (a `for`'s init clause).
        plExpr(n);
    }

    // The C-style condition the recogniser takes: its first two tokens are
    // `var` and `<` or `<=`.
    static bool plCondOk(Node* n, String* var)
    {
        while (n != (Node*)0 && !n.hasSrc(SRC_PAREN)) {
            u16 k = n.kind();
            if (!(k == nkBinary || k == nkAssign || k == nkTernary || k == nkPostfix || k == nkMember
                  || k == nkSubscript || k == nkMethodCall) || n.kidCount() == 0) return false;
            Node* first = n.kid(0);
            if (first != (Node*)0 && first.kind() == nkIdent)
                return !first.hasSrc(SRC_PAREN) && first.name().equals(var) && k == nkBinary
                    && (Parser._same(n.op(), "<") || Parser._same(n.op(), "<="));
            n = first;
        }
        return false;
    }

    // The C-style step the recogniser takes: `var++`, `++var`, `var += 1` or
    // `var = var + 1`, the 1 spelled so, nothing in parentheses.
    static bool plStepOk(Node* st, String* var)
    {
        if (st == (Node*)0 || st.hasSrc(SRC_PAREN) || st.kidCount() == 0) return false;
        if (!Parser.pacIsVar(st.kid(0), var)) return false;
        u16 k = st.kind();
        if (k == nkPostfix || k == nkUnary) return Parser._same(st.op(), "++");
        if (k != nkAssign || st.kidCount() < 2) return false;
        Node* rhs = st.kid(1);
        if (Parser._same(st.op(), "+=")) return Parser.pacIsOne(rhs);
        if (!Parser._same(st.op(), "=") || rhs == (Node*)0 || rhs.kind() != nkBinary || rhs.hasSrc(SRC_PAREN)
            || !Parser._same(rhs.op(), "+")) return false;
        return Parser.pacIsVar(rhs.kid(0), var) && Parser.pacIsOne(rhs.kid(1));
    }

    // What the recogniser sets aside while the scan's rules read its tokens.
    Map* plStateSave(void)
    {
        Map* s = new Map();
        s.set((Hashable*)String.withCString("tokens"), (Object*)_tokens);
        s.set((Hashable*)String.withCString("pos"), (Object*)Number.withU32(_pos));
        if (_parAutoWhy != (String*)0) s.set((Hashable*)String.withCString("why"), (Object*)_parAutoWhy);
        s.set((Hashable*)String.withCString("cap"), (Object*)Number.withU32(_parAutoGridCap));
        if (_parScanAcc != (String*)0) s.set((Hashable*)String.withCString("acc"), (Object*)_parScanAcc);
        if (_parScanOp != (String*)0) s.set((Hashable*)String.withCString("op"), (Object*)_parScanOp);
        return s;
    }

    void plStateRestore(Map* s)
    {
        _tokens = (Array*)pfwGet(s, "tokens");
        _pos = ((Number*)pfwGet(s, "pos")).asU32();
        _parAutoWhy = (String*)pfwGet(s, "why");
        _parAutoGridCap = ((Number*)pfwGet(s, "cap")).asU32();
        _parScanAcc = (String*)pfwGet(s, "acc");
        _parScanOp = (String*)pfwGet(s, "op");
        _plStream = false;
        _plToks = (Array*)0;
        _plDecls = (Map*)0;
        _plAddrs = (Map*)0;
        _plArgs = (Map*)0;
    }

    void plBegin(Token* at)
    {
        _plAt = at;
        _plToks = new Array();
        _plDecls = new Map();
        _plAddrs = new Map();
        _plArgs = new Map();
        _plLits = 0;
        _plSkipWhileIf = false;
    }

    static void plSet(Map* v, string k, String* x)
    {
        v.set((Hashable*)String.withCString(k), (Object*)x);
    }

    // The recogniser's verdict on `loop`, a `for` as parsed (the loop as
    // written, or the `for` a counted `while` became): lift, rule, form,
    // reds, grid, scan, goal and small, and for a loop it lifts what
    // parAutoFor builds the block from.
    Map* plRecogniseFor(Node* loop, Token* at)
    {
        Map* v = new Map();
        Parser.plSet(v, "lift", String.withCString("0"));
        Parser.plSet(v, "form", String.withCString("for"));
        u32 goal = _goalNow != 0 ? _goalNow : _goalDefault;
        if (_libFiles != (Set*)0 && at != (Token*)0 && _libFiles.contains((Hashable*)at.file())) {
            Parser.plSet(v, "rule", String.withCString("library"));
            return v;
        }
        if (loop != (Node*)0 && loop.kind() == nkForIn) {
            Parser.plSet(v, "form", String.withCString("range"));
            Parser.plSet(v, "rule", String.withCString("header"));
            return v;
        }
        if (loop == (Node*)0 || loop.kind() != nkForCStyle || loop.kidCount() != 4) {
            Parser.plSet(v, "rule", String.withCString("header"));
            return v;
        }
        Node* init = Parser.pacKid0(loop.kid(0));
        Node* d = init != (Node*)0 && init.kind() == nkVariableDecl ? init : (Node*)0;
        bool range = loop.hasSrc(SRC_RANGE);
        if (!range && d != (Node*)0 && Parser._same(d.name(), "__autopar_w"))
            Parser.plSet(v, "form", String.withCString("while"));
        // The loop's tokens, from its tree.
        Map* saved = plStateSave();
        plBegin(at);
        Map* marks = new Map();
        plFor(loop, marks);
        Array* toks = _plToks;
        Map* decls = _plDecls;
        Map* addrs = _plAddrs;
        Map* args = _plArgs;
        String* var = (String*)0;
        u32 bndFrom = 0;
        u32 bndTo = 0;
        String* rule = (String*)0;
        Node* c = Parser.pacKid0(loop.kid(1));
        if (range) {
            if (!Parser._same((String*)pfwGet(v, "form"), "while"))
                Parser.plSet(v, "form", String.withCString("range"));
            var = d != (Node*)0 ? d.name() : String.withCString("_");
            // A `step` with no literal stops the scan before it names the form.
            if (loop.hasSrc(SRC_STEPBAD) || (c != (Node*)0 && c.kidCount() == 2 && Parser.pacStepInBound(c.kid(1)))) {
                rule = String.withCString("step");
                Parser.plSet(v, "form", String.withCString("for"));
            } else if (loop.hasSrc(SRC_DESC))
                rule = String.withCString("descending");
            bndFrom = Parser.plMarkAt(marks, "bndFrom");
            bndTo = Parser.plMarkAt(marks, "bndTo");
        } else {
            // The init clause, as the scan reads its tokens: the first `=`, a
            // name before it, and a type before the name. The scan's token
            // numbers count from the `for` (0) and its `(` (1).
            u32 i0 = Parser.plMarkAt(marks, "initFrom");
            u32 semi1 = Parser.plMarkAt(marks, "initTo");
            u32 eq = 0;
            for (u32 i = i0; i < semi1 && eq == 0; i++)
                if (((Token*)toks.get(i)).type() == tokAssign) eq = i;
            if (semi1 == i0 || ((Token*)toks.get(semi1 - 1)).type() == tokAssign)
                rule = String.withCString("header");
            else if (eq == 0 || ((Token*)toks.get(eq - 1)).type() != tokIdentifier)
                rule = String.withCString("header");
            else if (eq < 4)
                rule = String.withCString("outer-variable");
            else {
                var = ((Token*)toks.get(eq - 1)).value();
                if (!Parser.plCondOk(c, var))
                    rule = String.withCString("condition");
                else if (!Parser.plStepOk(Parser.pacKid0(loop.kid(2)), var))
                    rule = String.withCString("step");
                bndFrom = Parser.plMarkAt(marks, "condFrom") + 2;
                bndTo = Parser.plMarkAt(marks, "condTo");
            }
        }
        if (rule == (String*)0 && loop.hasSrc(SRC_SERIAL))
            rule = String.withCString("serial");
        if (rule == (String*)0 && loop.hasSrc(SRC_GOAL))
            goal = loop.hasFlag(NF_GOAL_SPEED) ? 1 : 2;
        if (rule != (String*)0) {
            Parser.plSet(v, "rule", rule);
            plStateRestore(saved);
            return v;
        }
        // The body, on the walk's tokens.
        _tokens = toks;
        _pos = 0;
        _plStream = true;
        _plDecls = decls;
        _plAddrs = addrs;
        _plArgs = args;
        _parAutoWhy = (String*)0;
        _parAutoGridCap = 3;
        _parScanAcc = (String*)0;
        _parScanOp = (String*)0;
        Array* reds = new Array();
        bool lift = parAutoScanBodyAfter(Parser.plMarkAt(marks, "pe"), var, bndFrom, bndTo, reds, &goal);
        if (!lift)
            Parser.plSet(v, "rule", _parAutoWhy != (String*)0 ? _parAutoWhy : String.withCString("?"));
        else {
            Parser.plSet(v, "lift", String.withCString("1"));
            Parser.plSet(v, "goal", String.withU32(goal));
            Parser.plSet(v, "grid", String.withU32(_parAutoGridCap));
            Parser.plSet(v, "reds", Parser.plReds(reds));
            if (_parScanAcc != (String*)0) Parser.plSet(v, "scan", Parser.plScan(_parScanOp, _parScanAcc));
            Parser.plSet(v, "small", String.withCString(parAutoSmall(loop, 0, toks.count()) ? "1" : "0"));
            // What parAutoFor builds the block from.
            v.set((Hashable*)String.withCString("redNodes"), (Object*)reds);
            v.set((Hashable*)String.withCString("goalN"), (Object*)Number.withU32(goal));
            v.set((Hashable*)String.withCString("gridN"), (Object*)Number.withU32(_parAutoGridCap));
            if (_parScanAcc != (String*)0) {
                v.set((Hashable*)String.withCString("scanAcc"), (Object*)_parScanAcc);
                v.set((Hashable*)String.withCString("scanOp"), (Object*)_parScanOp);
            }
        }
        plStateRestore(saved);
        return v;
    }

    // The reductions as the trace spells them, `op:name[,…]`.
    static String* plReds(Array* reds)
    {
        String* rl = String.withCString("");
        for (u32 q = 0; q < reds.count(); q++) {
            Node* r = (Node*)reds.get(q);
            if (q > 0) rl.appendByte(',');
            rl.append(r.op());
            rl.appendByte(':');
            rl.append(r.name());
            if (r.num() == 1) rl.appendCString("[]");
        }
        return rl;
    }
    static String* plScan(String* op, String* acc)
    {
        String* s = String.withString(op);
        s.appendByte(':');
        s.append(acc);
        return s;
    }

    // A site for the walk: kind as plSiteWalk reads it.
    void plRegister(Node* site, u32 kind, Node* body, Array* params, u32 inc)
    {
        if (site == (Node*)0 || body == (Node*)0 || !_parAuto) return;
        if (_plSites == (Array*)0) _plSites = new Array();
        Array* e = new Array();
        e.add((Object*)site);
        e.add((Object*)Number.withU32(kind));
        e.add((Object*)body);
        e.add((Object*)(params != (Array*)0 ? params : new Array()));
        e.add((Object*)Number.withU32(inc));
        _plSites.add((Object*)e);
    }

    // A marker's expression, or 0.
    static Node* pacKid0(Node* m)
    {
        if (m == (Node*)0 || m.kidCount() == 0) return (Node*)0;
        return m.kid(0);
    }

    // Whether a range's end bound holds the name `step` (a variable, callee
    // or member) outside parentheses and brackets, where the scan reads it as
    // a `step` with no literal after it.
    static bool pacStepInBound(Node* e)
    {
        if (e == (Node*)0 || e.hasSrc(SRC_PAREN)) return false;
        u16 k = e.kind();
        bool named = (k == nkIdent || k == nkCall || k == nkMember || k == nkMethodCall)
                  && Parser._same(e.name(), "step") && !e.hasSrc(SRC_PARENCALLEE);
        if (named) return true;
        if (k == nkBinary || k == nkAssign) return Parser.pacStepInBound(e.kid(0)) || Parser.pacStepInBound(e.kid(1));
        if (k == nkTernary)
            return Parser.pacStepInBound(e.kid(0)) || Parser.pacStepInBound(e.kid(1)) || Parser.pacStepInBound(e.kid(2));
        if (k == nkUnary || k == nkPostfix || k == nkCast || k == nkMember || k == nkSubscript || k == nkMethodCall)
            return e.kidCount() > 0 && Parser.pacStepInBound(e.kid(0));
        return false;
    }

    static bool pacIsVar(Node* e, String* v)
    {
        return e != (Node*)0 && e.kind() == nkIdent && !e.hasSrc(SRC_PAREN) && e.name().equals(v);
    }
    static bool pacIsOne(Node* e)
    {
        return e != (Node*)0 && e.kind() == nkInt && !e.hasSrc(SRC_PAREN) && e.hasSrc(SRC_PLAIN) && e.num() == 1;
    }

    // An integer literal's token spelled as its decimal value: digits, and
    // no leading 0 unless it is `0`.
    static bool parPlainDecimal(String* t)
    {
        u32 n = t.byteLength();
        if (n == 0 || (n > 1 && t.byteAt(0) == '0')) return false;
        for (u32 q = 0; q < n; q++) : serial
            if (t.byteAt(q) < '0' || t.byteAt(q) > '9') return false;
        return true;
    }

    // A range `for` with `in` at token `inAt`: its bounds are two integer
    // literals that descend, as the parser reads them (parLiteralValue).
    bool parAutoDescends(u32 inAt)
    {
        u16 dots = parTokType(inAt + 2);
        return parTokType(inAt) == tokIn && parTokType(inAt + 1) == tokIntLiteral
            && (dots == tokDotDot || dots == tokEllipsis) && parTokType(inAt + 3) == tokIntLiteral
            && Parser.parLiteralValue(parTokValue(inAt + 1)) > Parser.parLiteralValue(parTokValue(inAt + 3));
    }

    // The body of the loop whose header ends at token pe, for the recogniser
    // on the tokens its walk rebuilt (plRecogniseFor):
    // the body's tokens, its names and their uses, its reductions, and the
    // tests of #415 and #416 against the bound [bndFrom, bndTo). As the
    // reference.
    // A pointer to numbers or to structs, or an array of them, once `strip`
    // elements are read through it: what a call may write through. A class
    // instance, collection, block or function pointer is none (a block that
    // captures one is refused on its own). As the reference.
    bool parAutoPointsToData(String* ty, u32 strip)
    {
        if (ty == (String*)0) return false;
        String* t = ty;
        for (u32 k = 0; k < strip; k++) : serial {
            u32 n = t.byteLength();
            if (n == 0) return false;
            u8 last = t.byteAt(n - 1);
            if (last == ']') t = t.substringBytes(0, t.lastIndexOfByte('['));
            else if (last == '*' || last == '@') t = t.substringBytes(0, n - 1);
            else return false;
        }
        // The base word, after any `simd:`-style qualifiers: a pointer or an
        // array when a sigil or a bracket follows it.
        u32 n = t.byteLength();
        u32 from = 0;
        for (u32 q = 0; q < n; q++) : serial {
            u8 c = t.byteAt(q);
            if (c == '<' || c == '(' || c == '*' || c == '@' || c == '[') break;
            if (c == ':') from = q + 1;
        }
        u32 to = from;
        for (; to < n && Parser.plWordByte(t.byteAt(to)); to++) : serial {
        }
        if (to == from || to >= n) return false;
        u8 after = t.byteAt(to);
        if (after != '*' && after != '@' && after != '[') return false;
        String* b = t.substringBytes(from, to - from);
        return Parser._same(b, "u8") || Parser._same(b, "i8") || Parser._same(b, "u16") || Parser._same(b, "i16")
            || Parser._same(b, "u32") || Parser._same(b, "i32") || Parser._same(b, "u64") || Parser._same(b, "i64")
            || Parser._same(b, "bool") || Parser._same(b, "float") || Parser._same(b, "double") || Parser._same(b, "void")
            || _structNames.contains((Hashable*)b);
    }

    // A value whose pointer-ness the parser cannot tell, once `strip`
    // elements are read through it: a type it does not know (`auto`, none) or
    // a struct passed by value, which may hold a pointer. As the reference.
    bool parAutoTypeUnknown(String* ty, u32 strip)
    {
        if (ty == (String*)0) return true;
        String* t = ty;
        for (u32 k = 0; k < strip; k++) : serial {
            u32 n = t.byteLength();
            if (n == 0) return false;
            u8 last = t.byteAt(n - 1);
            if (last == ']') t = t.substringBytes(0, t.lastIndexOfByte('['));
            else if (last == '*' || last == '@') t = t.substringBytes(0, n - 1);
            else return false;
        }
        u32 from = 0;
        for (u32 q = 0; q < t.byteLength(); q++) : serial
            if (t.byteAt(q) == ':') from = q + 1;
        String* b = t.substringBytes(from, t.byteLength() - from);
        return Parser._same(b, "auto") || _structNames.contains((Hashable*)b);
    }

    // The outer variable a call argument may pass a pointer from (_plArgs: its
    // roots, each marked with `[]` per element, `.` per member and `!` for a
    // cast to a pointer, `()` for a call's result), "" for a member of no
    // name, "()" for a call's result, else 0: a pointer to numbers or structs,
    // a member, a cast to a pointer, a call's result or a name whose type the
    // parser cannot see. An element's value, a number and the body's own
    // names are none. As the reference.
    String* parAutoPointerArg(String* roots, Set* declared)
    {
        Array* parts = roots.splitOnByte(',');
        for (u32 j = 0; j < parts.count(); j++) : serial {
            String* r = (String*)parts.get(j);
            u32 m = r.byteLength();
            for (u32 q = 0; q < r.byteLength(); q++) : serial {
                u8 c = r.byteAt(q);
                if (c == '[' || c == '.' || c == '!' || c == '(') { m = q; break; }
            }
            String* name = r.substringBytes(0, m);
            String* tail = r.substringBytes(m, r.byteLength() - m);
            bool call = tail.indexOfByte('(') != String.notFound();
            if (name.byteLength() > 0 && !call && declared.contains((Hashable*)name)) continue;
            // A call's result: a top-level function's declared result when
            // it is known and no pointer, else what the call may hand back.
            if (call) {
                // A name the scopes bind (a local, a parameter, a capture or
                // an ivar) is no top-level function, whatever its spelling.
                bool bound = declared.contains((Hashable*)name) || blkLookup(name, (u32*)0) != (Map*)0;
                String* rt = name.byteLength() > 0 && !bound && Parser._same(tail, "()") ? (String*)_blkFnRet.get((Hashable*)name) : (String*)0;
                if (rt == (String*)0 || parAutoPointsToData(rt, 0) || parAutoTypeUnknown(rt, 0)) return String.withCString("()");
                continue;
            }
            if (tail.indexOfByte('.') != String.notFound() || tail.indexOfByte('!') != String.notFound()) return name;
            u32 strip = tail.byteLength() / 2;
            Map* info = blkLookup(name, (u32*)0);
            String* ty = info != (Map*)0 ? blkTyOf(info) : (String*)0;
            if (info == (Map*)0 && _parTopVars != (Map*)0) ty = (String*)_parTopVars.get((Hashable*)name);
            if (parAutoPointsToData(ty, strip) || parAutoTypeUnknown(ty, strip)) return name;
        }
        return (String*)0;
    }

    bool parAutoScanBodyAfter(u32 pe, String* var, u32 bndFrom, u32 bndTo, Array* reds, u32* goalOut)
    {
        u32 n = _tokens.count();
        // The body: a block, to its `}`; or one plain statement, to its `;`
        // (a bare `if`, loop or switch as the body is left alone).
        u32 bs = 0;
        u32 be = 0;
        u32 depth = 0;
        if (parTokType(pe + (u32)1) == (u16)tokLBrace) {
            bs = pe + (u32)2;
            for (u32 i = pe + (u32)1; i < n; i = i + (u32)1) {
                u16 ty = parTokType(i);
                if (ty == (u16)tokLBrace) depth = depth + (u32)1;
                else if (ty == (u16)tokRBrace) {
                    depth = depth - (u32)1;
                    if (depth == (u32)0) { be = i; break; }
                }
            }
        } else {
            // One statement, to its end (the reference explains).
            u16 first = parTokType(pe + (u32)1);
            if (first == tokSemicolon || first == tokEOF) return parAutoNo("body");
            bs = pe + (u32)1;
            u32 end = parAutoStatementEnd(pe + (u32)1, n);
            if (end == 0) return parAutoNo("body");
            be = end;
        }
        if (be == 0) return parAutoNo("body");
        // A body that reads its function's variadic arguments (va_arg_…,
        // va_start, va_end) stays where it is: a block's body runs in a frame of
        // its own, where the function's va_list is not. As the reference.
        for (u32 t = bs; t < be; t = t + (u32)1)
            if (parTokType(t) == (u16)tokIdentifier && parTokValue(t).hasPrefix(String.withCString("va_")))
                return parAutoNo("varargs");
        Set* declared = new Set();
        declared.add((Hashable*)var);
        Map* accOps = new Map();
        Map* accWant = new Map();
        Map* uses = new Map();
        Array* names = new Array();
        Map* arrOps = new Map();
        Map* arrWant = new Map();
        Array* arrNames = new Array();
        Array* innerAt = new Array();
        bool pendingInner = false;
        u32 bd = (u32)0;
        u32 pd = (u32)0;
        for (u32 i = bs; i < be; i = i + (u32)1) {
            u16 ty = parTokType(i);
            u16 prev = parTokType(i - (u32)1);
            bool stmtStart = prev == (u16)tokSemicolon || prev == (u16)tokLBrace || prev == (u16)tokRBrace
                          || prev == (u16)tokRParen || prev == (u16)tokElse;
            if (ty == (u16)tokLBrace) {
                bd = bd + (u32)1;
                if (pendingInner) { innerAt.add((Object*)Number.with(bd)); pendingInner = false; }
                continue;
            }
            if (ty == (u16)tokRBrace) {
                if (innerAt.count() > (u32)0 && ((Number*)innerAt.last()).asU32() == bd) innerAt.removeAt(innerAt.count() - (u32)1);
                bd = bd - (u32)1;
                continue;
            }
            if (ty == (u16)tokLParen || ty == (u16)tokLBracket) pd = pd + (u32)1;
            if (ty == (u16)tokRParen || ty == (u16)tokRBracket) pd = pd - (u32)1;
            if (ty == (u16)tokFor || ty == (u16)tokWhile || ty == (u16)tokSwitch) pendingInner = true;
            if (ty == tokReturn) return parAutoNo("return");
            if (ty == tokGoto) return parAutoNo("goto");
            if (ty == tokBreak && innerAt.count() == 0) return parAutoNo("break");
            // Taking the address of an outer variable, or of an element or
            // member of one (`&c`, `&c[k]`, `&s.f`, `&*p`): what the address
            // reaches may be written, by a call say, from every item at once.
            // A bitwise `&` is no address-of.
            String* addrOf = ty == tokAmpersand && _plAddrs != (Map*)0 ? (String*)_plAddrs.get((Hashable*)String.withU32(i)) : (String*)0;
            if (addrOf != (String*)0 && !declared.contains((Hashable*)addrOf)) {
                String* w = String.withCString("its body takes an address");
                if (addrOf.byteLength() > 0) {
                    w = String.withCString("its body takes the address of '");
                    w.append(addrOf);
                    w.appendCString("'");
                }
                parAutoWarnSerial(w);
                _parScanAcc = (String*)0;
                return parAutoNo("address");
            }
            // An outer array or pointer passed to a call, as itself, at an
            // offset, or as a pointer element of one (`f(c)`, `f(p + k)`,
            // `f(rows[i])`), or a value the parser cannot tell from one
            // (`f(s.p)`, `f(g())`, a name of no known type, a struct): the
            // call may write through it from every item at once. An element's
            // value is no pointer.
            String* argRoots = _plArgs != (Map*)0 ? (String*)_plArgs.get((Hashable*)String.withU32(i)) : (String*)0;
            String* passed = argRoots != (String*)0 ? parAutoPointerArg(argRoots, declared) : (String*)0;
            if (passed != (String*)0) {
                String* w = String.withCString("its body passes a member to a call, which may write through it");
                if (Parser._same(passed, "()")) w = String.withCString("its body passes a call's result to a call, which may write through it");
                else if (passed.byteLength() > 0) {
                    w = String.withCString("its body passes '");
                    w.append(passed);
                    w.appendCString("' to a call, which may write through it");
                }
                parAutoWarnSerial(w);
                _parScanAcc = (String*)0;
                return parAutoNo("pointer-arg");
            }
            // A declaration: its declarators are the body's own names.
            bool declStart = stmtStart || (prev == (u16)tokLParen && parTokType(i - (u32)2) == (u16)tokFor);
            if (declStart && ty != (u16)tokIdentifier || declStart && ty == (u16)tokIdentifier && isTypeName(parTokValue(i))) {
                // On the tokens the recogniser's walk rebuilt, the declarators
                // its declaration statement names (_plDecls).
                Array* walked = _plStream ? (Array*)_plDecls.get((Hashable*)String.withU32(i)) : (Array*)0;
                if (walked != (Array*)0 && (isTypeKeywordToken(ty) || isTypeName(parTokValue(i))))
                    for (u32 w = 0; w < walked.count(); w++)
                        declared.add((Hashable*)walked.get(w));
                u32 save = _pos;
                Array* saveToks = _tokens;
                _pos = i;
                // The reference's test: a type keyword, or a declared type name.
                if (!_plStream && (isTypeKeywordToken(curType()) || (check(tokIdentifier) && isTypeName(cur().value())))) {
                    parseTypeSpelling();
                    u32 j = _pos;
                    while (j < be && parTokType(j) == (u16)tokIdentifier) {
                        declared.add((Hashable*)parTokValue(j));
                        // To the next declarator after a top-level comma, or stop.
                        u32 d2 = (u32)0;
                        while (j < be && !(d2 == (u32)0 && (parTokType(j) == (u16)tokComma || parTokType(j) == (u16)tokSemicolon))) {
                            u16 tj = parTokType(j);
                            if (tj == (u16)tokLParen || tj == (u16)tokLBracket || tj == (u16)tokLBrace) d2 = d2 + (u32)1;
                            if (tj == (u16)tokRParen || tj == (u16)tokRBracket || tj == (u16)tokRBrace) d2 = d2 - (u32)1;
                            j = j + (u32)1;
                        }
                        if (parTokType(j) != (u16)tokComma) break;
                        j = j + (u32)1;
                    }
                }
                // The parse reads the loop's tokens as written: a `>>` the
                // type spelling split stays one token there (#499).
                _tokens = saveToks;
                _pos = save;
            }
            if (ty != (u16)tokIdentifier) continue;
            String* name = parTokValue(i);
            Number* c = (Number*)uses.get((Hashable*)name);
            uses.set((Hashable*)name, (Object*)Number.with(c == (Number*)0 ? (u32)1 : c.asU32() + (u32)1));
            u16 next = parTokType(i + (u32)1);
            if (next == (u16)tokIn) { declared.add((Hashable*)name); continue; }
            if (stmtStart && next == tokColon) return parAutoNo("label");
            bool own = declared.contains((Hashable*)name);
            // `acc++;` as a statement of its own: a `+` reduction.
            if (stmtStart && next == (u16)tokPlusPlus && parTokType(i + (u32)2) == (u16)tokSemicolon && !own
                && !name.equals(var) && accOps.get((Hashable*)name) == (Object*)0) {
                accOps.set((Hashable*)name, (Object*)String.withCString("+"));
                accWant.set((Hashable*)name, (Object*)Number.with((u32)1));
                names.add((Object*)name);
                continue;
            }
            if ((next == tokPlusPlus || next == tokMinusMinus || prev == tokPlusPlus || prev == tokMinusMinus) && !own) return parAutoNo("outer-step");
            // `h[k] op= e`, `h[k]++` or `h[k] = h[k] op e`, op one of + | & ^,
            // on an outer name: an array reduction (:reduce(op h[])) when
            // every use of h in the loop is such an update with the one op,
            // and h is an array of integers of a size known when the program
            // is built (both checked after the walk). As the reference.
            if (stmtStart && next == (u16)tokLBracket && !own && !name.equals(var)) {
                u32 want = (u32)0;
                String* sym = parAutoArrUpdate(i, be, name, &want);
                if (sym != (String*)0) {
                    String* had = (String*)arrOps.get((Hashable*)name);
                    if (had == (String*)0) {
                        arrOps.set((Hashable*)name, (Object*)sym);
                        arrNames.add((Object*)name);
                    } else if (!had.equals(sym))
                        arrOps.set((Hashable*)name, (Object*)String.withCString("?"));
                    Number* w = (Number*)arrWant.get((Hashable*)name);
                    arrWant.set((Hashable*)name, (Object*)Number.with((w == (Number*)0 ? (u32)0 : w.asU32()) + want));
                }
                continue;
            }
            if (stmtStart && parAutoAnyAssignOp(next)) {
                if (name.equals(var)) return parAutoNo("iv-write");
                if (own) continue;
                if (accOps.get((Hashable*)name) != (Object*)0) return parAutoNo("outer-write");
                String* sym = (String*)0;
                u32 want = (u32)1;
                if (next == (u16)tokPlusAssign) sym = String.withCString("+");
                else if (next == (u16)tokStarAssign) sym = String.withCString("*");
                else if (next == (u16)tokAmpAssign) sym = String.withCString("&");
                else if (next == (u16)tokPipeAssign) sym = String.withCString("|");
                else if (next == (u16)tokCaretAssign) sym = String.withCString("^");
                else if (next == (u16)tokAssign && parTokType(i + (u32)2) == (u16)tokIdentifier && parTokValue(i + (u32)2).equals(name)) {
                    u16 o = parTokType(i + (u32)3);
                    if (o == (u16)tokPlus) sym = String.withCString("+");
                    else if (o == (u16)tokStar) sym = String.withCString("*");
                    else if (o == (u16)tokAmpersand) sym = String.withCString("&");
                    else if (o == (u16)tokPipe) sym = String.withCString("|");
                    else if (o == (u16)tokCaret) sym = String.withCString("^");
                    // `acc = acc op e` only when op joins all of e: in
                    // `h = h * C + x` the + binds outside the *, and the
                    // iterations depend on each other (a Horner hash came
                    // out 0 under --par-style=auto, par_gpu_wide, 2026-10-17).
                    if (sym != (String*)0 && !parAutoTailIsOp(i + (u32)4, be, o, true)) sym = (String*)0;
                    want = (u32)2;
                }
                // `if (x < acc) acc = x;`: a min (or max) reduction (as the reference).
                if (sym == (String*)0 && next == (u16)tokAssign) {
                    sym = parAutoMinMax(i, name, be);
                    want = (u32)2;
                }
                if (sym == (String*)0) return parAutoNo("outer-write");
                accOps.set((Hashable*)name, (Object*)sym);
                accWant.set((Hashable*)name, (Object*)Number.with(want));
                names.add((Object*)name);
                continue;
            }
            if (stmtStart && (next == (u16)tokDot || next == (u16)tokArrow) && !own) {
                // A member written through an outer name.
                u32 d2 = (u32)0;
                for (u32 j = i + (u32)1; j < be; j = j + (u32)1) {
                    u16 tj = parTokType(j);
                    if (tj == (u16)tokLParen || tj == (u16)tokLBracket) d2 = d2 + (u32)1;
                    if (tj == (u16)tokRParen || tj == (u16)tokRBracket) d2 = d2 - (u32)1;
                    if (d2 == (u32)0 && tj == (u16)tokSemicolon) break;
                    if (d2 == 0 && parAutoAnyAssignOp(tj)) return parAutoNo("member-write");
                }
            }
        }
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1) {
            String* acc = (String*)names.get(i);
            // A local of an integer type: a float reduction reassociates (not
            // the default), and a global is not a reduction.
            u32 depth2 = (u32)0;
            Map* info = blkLookup(acc, &depth2);
            String* ty = blkTyOf(info);
            if (ty == (String*)0) return parAutoNo("reduction-type");
            bool isInt = Parser._same(ty, "u8") || Parser._same(ty, "i8") || Parser._same(ty, "u16") || Parser._same(ty, "i16")
                  || Parser._same(ty, "u32") || Parser._same(ty, "i32") || Parser._same(ty, "u64") || Parser._same(ty, "i64");
            // A float reduction only under an EXPLICIT speed goal, and only +.
            bool isFloat = (Parser._same(ty, "float") || Parser._same(ty, "double")) && *goalOut == (u32)1
                  && Parser._same((String*)accOps.get((Hashable*)acc), "+");
            if (!isInt && !isFloat) return parAutoNo("reduction-type");
            Number* want = (Number*)accWant.get((Hashable*)acc);
            Number* have = (Number*)uses.get((Hashable*)acc);
            if (have == (Number*)0 || want == (Number*)0) return parAutoNo("reduction-uses");
            if (have.asU32() != want.asU32()) {
                // A running total (#144): the other uses are stores
                // `X[i] = acc;`, X an outer array used for nothing else. The
                // loop becomes a :scan, alone (no other reduction with it).
                String* op = (String*)accOps.get((Hashable*)acc);
                if (_scanInside != 0 || _parScanAcc != (String*)0 || Parser._same(op, "*")) return parAutoNo("reduction-uses");
                u32 stores = parAutoScanStores(bs, be, acc, var, uses, declared);
                if (stores == 0 || have.asU32() != want.asU32() + stores) return parAutoNo("reduction-uses");
                _parScanAcc = acc;
                _parScanOp = op;
                continue;
            }
            Node* r = mk((u16)nkParReduce);
            r.setOp((String*)accOps.get((Hashable*)acc));
            r.setName(acc);
            reds.add((Object*)r);
        }
        if (_parScanAcc != (String*)0 && (names.count() != (u32)1 || arrNames.count() != (u32)0)) {
            _parScanAcc = (String*)0;
            return parAutoNo("scan-alone");
        }
        // The array reductions, after the scalar ones. An array that fails a
        // test is no reduction, and the loop goes on as it would without one.
        for (u32 i = (u32)0; i < arrNames.count(); i = i + (u32)1) {
            String* h = (String*)arrNames.get(i);
            String* sym = (String*)arrOps.get((Hashable*)h);
            Number* want = (Number*)arrWant.get((Hashable*)h);
            Number* have = (Number*)uses.get((Hashable*)h);
            if (have == (Number*)0 || want == (Number*)0 || have.asU32() != want.asU32()) continue;
            u32 depth2 = (u32)0;
            String* ty = blkTyOf(blkLookup(h, &depth2));
            if (ty == (String*)0 && _parTopVars != (Map*)0) ty = (String*)_parTopVars.get((Hashable*)h);
            if (Parser.parArrCode(ty, sym) == (i64)0) continue;
            Node* r = mk((u16)nkParReduce);
            r.setOp(sym);
            r.setName(h);
            r.setNum((i64)1);
            reds.add((Object*)r);
        }
        // A loop that qualifies so far, but whose body writes its variable
        // (#415) or changes what its bound reads (#416), stays a loop.
        if (parAutoIVWritten(bs, be, var)) {
            String* w = String.withCString("its body writes its loop variable '");
            w.append(var);
            w.appendCString("'");
            parAutoWarnSerial(w);
            _parScanAcc = (String*)0;
            return parAutoNo("iv-write");
        }
        String* bw = parAutoBoundWritten(bndFrom, bndTo, bs, be, var);
        if (bw != (String*)0) {
            parAutoWarnSerial(bw);
            _parScanAcc = (String*)0;
            return false;
        }
        // A perfect nest's inner levels, for parAutoGridNest.
        _parAutoGridCap = parAutoGridCap(bs, be, 2);
        return true;
    }

    // For a running total in [bs, be): the stores `X[var] = acc;` at a
    // statement's start, X an outer name whose every use is such a store;
    // their number, else 0. Mirrors the reference's parAutoScanStores.
    u32 parAutoScanStores(u32 bs, u32 be, String* acc, String* var, Map* uses, Set* declared)
    {
        Map* per = new Map();
        u32 total = (u32)0;
        for (u32 i = bs; i < be; i = i + (u32)1) {
            if (parTokType(i) != (u16)tokIdentifier || !parTokValue(i).equals(acc)) continue;
            u16 pv = parTokType(i - (u32)1);
            if (pv == (u16)tokDot || pv == (u16)tokArrow) continue;
            if (i < bs + (u32)5 || pv != (u16)tokAssign || parTokType(i - (u32)2) != (u16)tokRBracket
                || parTokType(i - (u32)3) != (u16)tokIdentifier || !parTokValue(i - (u32)3).equals(var)
                || parTokType(i - (u32)4) != (u16)tokLBracket || parTokType(i - (u32)5) != (u16)tokIdentifier
                || parTokType(i + (u32)1) != (u16)tokSemicolon)
                continue;
            u16 st = parTokType(i - (u32)6);
            if (i - (u32)5 != bs && st != (u16)tokSemicolon && st != (u16)tokLBrace && st != (u16)tokRBrace) continue;
            String* x = parTokValue(i - (u32)5);
            if (x.equals(acc) || x.equals(var) || declared.contains((Hashable*)x)) return (u32)0;
            Number* c = (Number*)per.get((Hashable*)x);
            per.set((Hashable*)x, (Object*)Number.with(c == (Number*)0 ? (u32)1 : c.asU32() + (u32)1));
            total = total + (u32)1;
        }
        Array* xs = per.allKeys();
        for (u32 j = (u32)0; j < xs.count(); j = j + (u32)1) {
            String* x = (String*)xs.get(j);
            Number* u = (Number*)uses.get((Hashable*)x);
            if (u == (Number*)0 || u.asU32() != ((Number*)per.get((Hashable*)x)).asU32()) return (u32)0;
        }
        return total;
    }

    // At token i, a name followed by `[` at a statement's start: the
    // operator of `h[k] op= e` (op one of + | & ^), of `h[k]++;` (+), or of
    // `h[k] = h[k] op e` with the same index token for token and op binding
    // all of e, else 0. *wantOut is the uses of h the statement makes.
    String* parAutoArrUpdate(u32 i, u32 be, String* name, u32* wantOut)
    {
        u32 d = (u32)0;
        u32 rb = (u32)0;
        for (u32 j = i + (u32)1; j < be; j = j + (u32)1) {
            u16 t = parTokType(j);
            if (t == (u16)tokLBracket || t == (u16)tokLParen) d = d + (u32)1;
            else if (t == (u16)tokRBracket || t == (u16)tokRParen) {
                d = d - (u32)1;
                if (d == (u32)0) { rb = j; break; }
            }
        }
        if (rb == (u32)0) return (String*)0;
        u16 t = parTokType(rb + (u32)1);
        *wantOut = (u32)1;
        if (t == (u16)tokPlusAssign) return String.withCString("+");
        if (t == (u16)tokPipeAssign) return String.withCString("|");
        if (t == (u16)tokAmpAssign) return String.withCString("&");
        if (t == (u16)tokCaretAssign) return String.withCString("^");
        if (t == (u16)tokPlusPlus && parTokType(rb + (u32)2) == (u16)tokSemicolon) return String.withCString("+");
        if (t != (u16)tokAssign || parTokType(rb + (u32)2) != (u16)tokIdentifier || !parTokValue(rb + (u32)2).equals(name))
            return (String*)0;
        // The same index on the right, token for token, with no call or
        // member in it (the parser compares the two as trees, parSameIndex).
        u32 at = rb + (u32)2;
        for (u32 q = (u32)1; q <= rb - i; q = q + (u32)1) {
            u16 ta = parTokType(i + q);
            if (ta != parTokType(at + q) || !parTokValue(i + q).equals(parTokValue(at + q))) return (String*)0;
            if (ta == (u16)tokDot || ta == (u16)tokArrow) return (String*)0;
            if (ta == (u16)tokIdentifier && parTokType(i + q + (u32)1) == (u16)tokLParen) return (String*)0;
        }
        u32 o = at + (rb - i) + (u32)1;
        u16 ot = parTokType(o);
        String* sym = ot == (u16)tokPlus ? String.withCString("+") : ot == (u16)tokPipe ? String.withCString("|")
                    : ot == (u16)tokAmpersand ? String.withCString("&") : ot == (u16)tokCaret ? String.withCString("^") : (String*)0;
        if (sym == (String*)0 || !parAutoTailIsOp(o + (u32)1, be, ot, false)) return (String*)0;
        *wantOut = (u32)2;
        return sym;
    }

    // Whether the statement's tail, from token `from` to its `;`, is one
    // operand of `op`: every binary operator at its top level is `op` (when
    // `again`) or binds more tightly (unary ones, after an operator or an
    // opening bracket, do not count).
    bool parAutoTailIsOp(u32 from, u32 be, u16 op, bool again)
    {
        u32 depth = (u32)0;
        for (u32 j = from; j < be; j = j + (u32)1) {
            u16 t = parTokType(j);
            if (t == (u16)tokLParen || t == (u16)tokLBracket || t == (u16)tokLBrace) { depth = depth + (u32)1; continue; }
            if (t == (u16)tokRParen || t == (u16)tokRBracket || t == (u16)tokRBrace) {
                if (depth == (u32)0) return true;
                depth = depth - (u32)1;
                continue;
            }
            if (depth > (u32)0) continue;
            if (t == (u16)tokSemicolon || t == (u16)tokComma) return true;
            bool binop = t == (u16)tokPlus || t == (u16)tokMinus || t == (u16)tokStar || t == (u16)tokSlash || t == (u16)tokPercent || t == (u16)tokShiftLeft || t == (u16)tokShiftRight || t == (u16)tokLess || t == (u16)tokLessEq || t == (u16)tokGreater || t == (u16)tokGreaterEq || t == (u16)tokEqual || t == (u16)tokNotEqual || t == (u16)tokAmpersand || t == (u16)tokPipe || t == (u16)tokCaret || t == (u16)tokLogicalAnd || t == (u16)tokLogicalOr || t == (u16)tokQuestion;
            if (!binop) continue;
            u16 pt = j > from ? parTokType(j - (u32)1) : (u16)tokLParen;
            bool unary = j == from || pt == (u16)tokLParen || pt == (u16)tokLBracket || pt == (u16)tokComma
                || pt == (u16)tokAssign || parAutoIsBinOp(pt);
            if (unary) continue;
            // `op` again, or an operator that binds more tightly (part of the
            // operand): anything else takes `acc op …` as its own operand.
            if ((t != op || !again) && parAutoPrec(t) <= parAutoPrec(op)) return false;
        }
        return true;
    }
    // C's binary-operator precedence, higher binding more tightly.
    u32 parAutoPrec(u16 t)
    {
        if (t == (u16)tokStar || t == (u16)tokSlash || t == (u16)tokPercent) return (u32)10;
        if (t == (u16)tokPlus || t == (u16)tokMinus) return (u32)9;
        if (t == (u16)tokShiftLeft || t == (u16)tokShiftRight) return (u32)8;
        if (t == (u16)tokLess || t == (u16)tokLessEq || t == (u16)tokGreater || t == (u16)tokGreaterEq) return (u32)7;
        if (t == (u16)tokEqual || t == (u16)tokNotEqual) return (u32)6;
        if (t == (u16)tokAmpersand) return (u32)5;
        if (t == (u16)tokCaret) return (u32)4;
        if (t == (u16)tokPipe) return (u32)3;
        if (t == (u16)tokLogicalAnd) return (u32)2;
        if (t == (u16)tokLogicalOr) return (u32)1;
        if (t == (u16)tokQuestion) return (u32)0;
        return (u32)0;
    }
    bool parAutoIsBinOp(u16 t)
    {
        return t == (u16)tokPlus || t == (u16)tokMinus || t == (u16)tokStar || t == (u16)tokSlash || t == (u16)tokPercent || t == (u16)tokShiftLeft || t == (u16)tokShiftRight || t == (u16)tokLess || t == (u16)tokLessEq || t == (u16)tokGreater || t == (u16)tokGreaterEq || t == (u16)tokEqual || t == (u16)tokNotEqual || t == (u16)tokAmpersand || t == (u16)tokPipe || t == (u16)tokCaret || t == (u16)tokLogicalAnd || t == (u16)tokLogicalOr || t == (u16)tokQuestion;
    }

    // ---- :scan (#144) -------------------------------------------------
    // `par [name] :scan(op acc) [:goal(…)] { for (T i in a..b) { … } }`: a
    // running total, written (parScanWritten) or a loop --par-style=auto
    // takes as one (parAutoScanFor), made into blocks from the loop's tree
    // (parScanExpand). In the body acc may only be updated and stored, the
    // output arrays used nowhere else (scBodyOk). The two made blocks carry
    // `:__scanpass`: their chunks own disjoint slices, so par-check takes
    // them as they are, and they stay on the CPU. A float scan under the
    // accuracy goal stays a serial loop. Mirrored in the reference.
    u16 scT(u32 i)
    {
        if (i >= _tokens.count()) return (u16)tokEOF;
        return ((Token*)_tokens.get(i)).type();
    }
    String* scV(u32 i)
    {
        return ((Token*)_tokens.get(i)).value();
    }
    // The token that closes the bracket opened at i, or 0.
    u32 scClose(u32 i)
    {
        u16 o = scT(i);
        u16 c = o == (u16)tokLParen ? (u16)tokRParen : o == (u16)tokLBrace ? (u16)tokRBrace : (u16)tokRBracket;
        i32 d = (i32)0;
        for (u32 k = i; k < _tokens.count(); k = k + (u32)1) {
            u16 t = scT(k);
            if (t == o) d = d + (i32)1;
            else if (t == c) {
                d = d - (i32)1;
                if (d == (i32)0) return k;
            }
        }
        return (u32)0;
    }
    bool scStmtStart(u32 p, u32 bo)
    {
        u16 t = scT(p);
        return p == bo || t == (u16)tokSemicolon || t == (u16)tokLBrace || t == (u16)tokRBrace;
    }
    // The `;` that ends the expression starting at q (depth 0), or 0; with
    // `acc` in it, 0 too.
    u32 scExprEnd(u32 q, u32 lim, String* acc)
    {
        i32 d = (i32)0;
        for (u32 k = q; k < lim; k = k + (u32)1) {
            u16 t = scT(k);
            if (t == (u16)tokLParen || t == (u16)tokLBracket) d = d + (i32)1;
            else if (t == (u16)tokRParen || t == (u16)tokRBracket) d = d - (i32)1;
            else if (t == (u16)tokSemicolon && d == (i32)0) return k == q ? (u32)0 : k;
            else if (t == (u16)tokIdentifier && scV(k).equals(acc)) return (u32)0;
        }
        return (u32)0;
    }
    bool scSameToks(u32 a, u32 b, u32 n)
    {
        for (u32 k = (u32)0; k < n; k = k + (u32)1)
            if (scT(a + k) != scT(b + k) || !scV(a + k).equals(scV(b + k))) return false;
        return true;
    }
    static bool scIntType(String* t)
    {
        return Parser._same(t, "u8") || Parser._same(t, "i8") || Parser._same(t, "u16") || Parser._same(t, "i16")
            || Parser._same(t, "u32") || Parser._same(t, "i32") || Parser._same(t, "u64") || Parser._same(t, "i64");
    }
    static bool scSigned(String* t)
    {
        return Parser._same(t, "i8") || Parser._same(t, "i16") || Parser._same(t, "i32") || Parser._same(t, "i64");
    }
    // The operator's identity for type t, as source.
    static String* scIdentity(String* op, String* t)
    {
        String* s = new String();
        if (Parser._same(op, "&") || (Parser._same(op, "min") && !Parser.scSigned(t) && Parser.scIntType(t))) {
            s.appendFormat("~(%s)0", t.cString());
            return s;
        }
        if (Parser._same(op, "min") || Parser._same(op, "max")) {
            String* big = (String*)0;
            if (Parser._same(t, "i8")) big = String.withCString("127");
            else if (Parser._same(t, "i16")) big = String.withCString("32767");
            else if (Parser._same(t, "i32")) big = String.withCString("2147483647");
            else big = String.withCString("9223372036854775807");
            if (Parser._same(op, "min")) s.appendFormat("(%s)%s", t.cString(), big.cString());
            else if (Parser.scSigned(t)) s.appendFormat("((%s)0 - (%s)%s - (%s)1)", t.cString(), t.cString(), big.cString(), t.cString());
            else s.appendFormat("(%s)0", t.cString());
            return s;
        }
        s.appendFormat("(%s)0", t.cString());
        return s;
    }
    // `r = r op v;` (or the min/max form), as source.
    static String* scCombine(String* op, String* r, String* v)
    {
        String* s = new String();
        if (Parser._same(op, "min")) s.appendFormat("if (%s < %s) %s = %s;", v.cString(), r.cString(), r.cString(), v.cString());
        else if (Parser._same(op, "max")) s.appendFormat("if (%s > %s) %s = %s;", v.cString(), r.cString(), r.cString(), v.cString());
        else s.appendFormat("%s = %s %s %s;", r.cString(), r.cString(), op.cString(), v.cString());
        return s;
    }
    void scFail(String* msg, Token* t, u32 from, u32 to)
    {
        // The block then parses on as written, its :scan(…) skipped; for
        // --par-style=auto (quiet) the loop stays a loop.
        _scFailMsg = msg;
        _scFailTok = t;
        if (!_scanQuiet) _errorAtTok(msg, t);
    }
    // A written `par [name] :scan(op acc) [:goal(…)] { for (T i in a..b) { … } }`
    // at `par`: its header read, the loop parsed (as a block's loop is,
    // nothing in it lifted) and its body checked from the tree (scBodyOk),
    // then expanded (parScanExpand). *handled is false, with the cursor
    // still at `par`, when there is no :scan or it is refused: the error is
    // said (scFail), and parsePar parses the block as written, its :scan
    // skipped. The loop's parse is taken back first, so the refusal comes
    // before what that parse says. A loop whose body holds a block literal
    // or a par block is refused: the expansion takes the body twice.
    Node* parScanWritten(bool* handled)
    {
        *handled = false;
        u32 at = _pos;
        Token* pt = (Token*)_tokens.get(at);
        u32 k = at + 1;
        String* name = (String*)0;
        if (scT(k) == tokIdentifier && scT(k + 1) != tokAssign) {
            name = scV(k);
            k++;
        }
        String* op = (String*)0;
        String* acc = (String*)0;
        u32 s0 = 0;
        u32 s1 = 0;
        Array* goals = new Array();
        bool goalsOk = true;
        bool other = false;
        while (scT(k) == tokColon && scT(k + 1) == tokIdentifier) {
            u32 d0 = k;
            u32 dEnd = k + 2;
            if (scT(dEnd) == tokLParen) {
                u32 c = scClose(dEnd);
                if (c == 0) return (Node*)0;
                dEnd = c + 1;
            }
            String* dn = scV(d0 + 1);
            if (Parser._same(dn, "scan")) {
                s0 = d0;
                s1 = dEnd;
                u32 q = d0 + 3;
                u16 t = scT(q);
                if (t == tokPlus) op = String.withCString("+");
                else if (t == tokPipe) op = String.withCString("|");
                else if (t == tokAmpersand) op = String.withCString("&");
                else if (t == tokCaret) op = String.withCString("^");
                else if (t == tokIdentifier && (Parser._same(scV(q), "min") || Parser._same(scV(q), "max"))) op = scV(q);
                if (op != (String*)0 && scT(q + 1) == tokIdentifier && dEnd == q + 3)
                    acc = scV(q + 1);
            } else if (Parser._same(dn, "goal")) {
                // `:goal(speed)` or `:goal(accuracy)`; anything else is
                // parsePar's to report.
                String* g = dEnd == d0 + 5 && scT(d0 + 3) == tokIdentifier ? scV(d0 + 3) : (String*)0;
                if (g != (String*)0 && (Parser._same(g, "speed") || Parser._same(g, "accuracy"))) goals.add((Object*)g);
                else goalsOk = false;
            }
            else other = true;
            k = dEnd;
        }
        if (s1 == 0) return (Node*)0;
        Token* st = (Token*)_tokens.get(s0 + 1);
        if (acc == (String*)0) {
            scFail(String.withCString("':scan' wants an operator (+ | & ^ min max) and a variable: :scan(+ total)"), st, s0, s1);
            return (Node*)0;
        }
        if (other) {
            scFail(String.withCString("':scan' combines only with ':goal'"), st, s0, s1);
            return (Node*)0;
        }
        String* shape = String.withCString("a ':scan' block is one loop: par :scan(+ acc) { for (T i in a..b) { … } }");
        if (scT(k) != tokLBrace) { scFail(shape, st, s0, s1); return (Node*)0; }
        u32 be = scClose(k);
        u32 f = k + 1;
        bool ok = be != 0 && scT(f) == tokFor && scT(f + 1) == tokLParen
            && scT(f + 3) == tokIdentifier && scT(f + 4) == tokIn
            && Parser.scIntType(scV(f + 2));
        u32 fc = ok ? scClose(f + 1) : 0;
        u32 rg = 0;
        if (fc != 0) {
            i32 d = 0;
            for (u32 q = f + 5; q < fc; q++) {
                u16 t = scT(q);
                if (t == tokLParen || t == tokLBracket) d++;
                else if (t == tokRParen || t == tokRBracket) d--;
                else if (d == 0 && (t == tokDotDot || t == tokEllipsis)) {
                    rg = q;
                    break;
                }
            }
        }
        u32 bo = fc + 1;
        u32 bc = rg != 0 && scT(bo) == tokLBrace ? scClose(bo) : 0;
        if (rg == 0 || rg == f + 5 || rg + 1 == fc || bc == 0 || bc + 1 != be) {
            scFail(shape, st, s0, s1);
            return (Node*)0;
        }
        // acc: a local of an integer or floating type.
        u32 dd = 0;
        String* aty = blkTyOf(blkLookup(acc, &dd));
        bool isFloat = aty != (String*)0 && (Parser._same(aty, "float") || Parser._same(aty, "double"));
        if (aty == (String*)0 || (!isFloat && !Parser.scIntType(aty))) {
            String* m = String.withCString("':scan' wants '");
            m.append(acc);
            m.appendCString("' to be a local variable of an integer or floating type");
            scFail(m, st, s0, s1);
            return (Node*)0;
        }
        if (isFloat && !Parser._same(op, "+")) {
            scFail(String.withCString("a floating-point ':scan' takes only +"), st, s0, s1);
            return (Node*)0;
        }
        if (!goalsOk) return (Node*)0;
        // The loop, parsed as a block's loop is.
        Map* mark = parAutoMark();
        u32 e0 = _errors.count();
        u32 w0 = _warnings.count();
        u32 blkAt = _blkCounter;
        u32 parAt = _parCounter;
        u32 seqAt = _scanSeq;
        _pos = f;
        parGridEnter("loops", true);
        _loopDepth++;
        Node* loop = parseFor();
        _loopDepth--;
        parGridEnter("loops", false);
        u32 e1 = _errors.count();
        u32 w1 = _warnings.count();
        Node* d = loop != (Node*)0 && loop.kind() == nkForCStyle && loop.kidCount() == 4 ? Parser.pacKid0(loop.kid(0)) : (Node*)0;
        Node* c = d != (Node*)0 ? Parser.pacKid0(loop.kid(1)) : (Node*)0;
        Node* body = d != (Node*)0 ? loop.kid(3) : (Node*)0;
        if (d == (Node*)0 || d.kind() != nkVariableDecl || d.kidCount() == 0 || c == (Node*)0 || c.kidCount() != 2
            || body == (Node*)0 || body.kind() != nkBlock) {
            // The loop did not parse: parsePar parses the block as written.
            parAutoRollback(mark);
            return (Node*)0;
        }
        // The body: acc updated and stored only.
        Array* outs = new Array();
        _scFailMsg = (String*)0;
        bool refused = !scBodyOk(body, pt, acc, op, d.name(), st, outs);
        if (!refused && (_blkCounter != blkAt || _parCounter != parAt || _scanSeq != seqAt)) {
            scFail(String.withCString("a ':scan' loop's body holds no block literal or 'par' block"), st, s0, s1);
            refused = true;
        }
        if (refused) {
            String* msg = _scFailMsg;
            Token* tok = _scFailTok;
            parAutoRollback(mark);
            if (msg != (String*)0) _errorAtTok(msg, tok);
            return (Node*)0;
        }
        *handled = true;
        // The loop's parse is taken back: the expansion parses the body as
        // written where it runs as the loop, and its diagnostics are said
        // again where it is put in as the chunks' body (scSplice).
        Array* errs = _errors.subarray(e0, e1 - e0);
        Array* warns = _warnings.subarray(w0, w1 - w0);
        parAutoRollback(mark);
        // The goal: the block's own :goal, else the inherited one.
        u32 inherited = _goalNow != 0 ? _goalNow : _goalDefault;
        bool accuracy = inherited == 2;
        for (u32 j = 0; j < goals.count(); j++)
            accuracy = Parser._same((String*)goals.get(j), "accuracy");
        if (isFloat && accuracy) {
            // Serial: the loop as written, in a block of its own at `par`,
            // parsed where it is.
            _pos = f;
            Node* b = mk(nkBlock);
            b.setPos(pt.fileId(), pt.line(), pt.col());
            blkPushScope();
            _scanInside++;
            Node* one = parseListStatement();
            _scanInside--;
            blkPopScope();
            if (one != (Node*)0) b.add(one);
            b.setStmtPos(pt.fileId(), pt.line(), pt.col());
            _pos = be + 1;
            return b;
        }
        Map* s = new Map();
        Parser.parAutoMarkSet(s, "name", (Object*)name);
        Parser.parAutoMarkSet(s, "op", (Object*)op);
        Parser.parAutoMarkSet(s, "acc", (Object*)acc);
        Parser.parAutoMarkSet(s, "aty", (Object*)aty);
        Parser.parAutoMarkSet(s, "ity", (Object*)d.op());
        Parser.parAutoMarkSet(s, "iv", (Object*)d.name());
        Parser.parAutoMarkSet(s, "incl", (Object*)Number.withU32(Parser._same(c.op(), "<=") ? 1 : 0));
        Parser.parAutoMarkSet(s, "A", (Object*)d.kid(0));
        Parser.parAutoMarkSet(s, "B", (Object*)c.kid(1));
        Parser.parAutoMarkSet(s, "BODY", (Object*)body);
        Parser.parAutoMarkSet(s, "outs", (Object*)outs);
        Parser.parAutoMarkSet(s, "goals", (Object*)goals);
        Parser.parAutoMarkSet(s, "pt", (Object*)pt);
        Parser.parAutoMarkSet(s, "toks", (Object*)_tokens);
        Parser.parAutoMarkSet(s, "from", (Object*)Number.withU32(f));
        Parser.parAutoMarkSet(s, "to", (Object*)Number.withU32(be));
        Parser.parAutoMarkSet(s, "bo", (Object*)Number.withU32(bo));
        Parser.parAutoMarkSet(s, "errs", (Object*)errs);
        Parser.parAutoMarkSet(s, "warns", (Object*)warns);
        Node* out = parScanExpand(s);
        _pos = be + 1;
        return out;
    }

    // The body of a :scan loop as tokens, from its tree (plStmt): each name
    // and each break, return and goto at its place in the source, and each
    // literal as spelt. scBodyOk reads them as the scan read the source.
    Array* scBodyToks(Node* body, Token* at)
    {
        Map* saved = plStateSave();
        plBegin(at);
        _plExact = true;
        plStmt(body);
        _plExact = false;
        Array* toks = _plToks;
        plStateRestore(saved);
        return toks;
    }

    // In a :scan loop's body, from its tree: acc only updated (acc += e,
    // acc = acc + e, acc++, and the `if (e < acc) acc = e;` and
    // `if (e > acc) acc = e;` forms for min and max) and stored (a[i] =
    // acc;), the output arrays (outs) used nowhere else, and no break,
    // return or goto. The refusal is said at the name or keyword it is
    // about (scFail).
    bool scBodyOk(Node* tree, Token* at, String* acc, String* op, String* iv, Token* st, Array* outs)
    {
        Array* toks = scBodyToks(tree, at);
        Array* saved = _tokens;
        _tokens = toks;
        bool ok = scBodyCheck(0, toks.count() - 1, acc, op, iv, st, outs);
        _tokens = saved;
        return ok;
    }

    bool scBodyCheck(u32 bo, u32 bc, String* acc, String* op, String* iv, Token* st, Array* outs)
    {
        u32 s0 = 0;
        u32 s1 = 0;
        u32 updates = 0;
        for (u32 q = bo + 1; q < bc; q++) {
            u16 t = scT(q);
            if (t == tokBreak || t == tokReturn || t == tokGoto) {
                scFail(String.withCString("a ':scan' loop has no break, return or goto"), (Token*)_tokens.get(q), s0, s1);
                return false;
            }
            if (t != tokIdentifier || !scV(q).equals(acc)) continue;
            u16 pv = scT(q - 1);
            if (pv == tokDot || pv == tokArrow) continue;
            // a[i] = acc;
            if (q >= bo + 6 && pv == tokAssign && scT(q - 2) == tokRBracket
                && scT(q - 3) == tokIdentifier && scV(q - 3).equals(iv)
                && scT(q - 4) == tokLBracket && scT(q - 5) == tokIdentifier
                && scT(q + 1) == tokSemicolon && scStmtStart(q - 6, bo)) {
                bool seen = false;
                for (u32 j = 0; j < outs.count(); j++)
                    if (((String*)outs.get(j)).equals(scV(q - 5))) seen = true;
                if (!seen) outs.add((Object*)scV(q - 5));
                q++;
                continue;
            }
            u32 e = 0;
            if (scStmtStart(q - 1, bo)) {
                u16 t1 = scT(q + 1);
                bool opAssign = (Parser._same(op, "+") && t1 == tokPlusAssign) || (Parser._same(op, "|") && t1 == tokPipeAssign)
                    || (Parser._same(op, "&") && t1 == tokAmpAssign) || (Parser._same(op, "^") && t1 == tokCaretAssign);
                if (opAssign)
                    e = scExprEnd(q + 2, bc, acc);
                else if (Parser._same(op, "+") && t1 == tokPlusPlus && scT(q + 2) == tokSemicolon)
                    e = q + 2;
                else if (t1 == tokAssign && scT(q + 2) == tokIdentifier && scV(q + 2).equals(acc)
                         && !Parser._same(op, "min") && !Parser._same(op, "max")) {
                    u16 t3 = scT(q + 3);
                    bool same = (Parser._same(op, "+") && t3 == tokPlus) || (Parser._same(op, "|") && t3 == tokPipe)
                        || (Parser._same(op, "&") && t3 == tokAmpersand) || (Parser._same(op, "^") && t3 == tokCaret);
                    if (same) e = scExprEnd(q + 4, bc, acc);
                }
            }
            // ++acc;
            if (e == 0 && Parser._same(op, "+") && pv == tokPlusPlus && scStmtStart(q - 2, bo)
                && scT(q + 1) == tokSemicolon)
                e = q + 1;
            // if (E < acc) acc = E;   (min; > for max)
            if (e == 0 && (Parser._same(op, "min") || Parser._same(op, "max"))
                && pv == (Parser._same(op, "min") ? tokLess : tokGreater)
                && scT(q + 1) == tokRParen && scT(q + 2) == tokIdentifier && scV(q + 2).equals(acc)
                && scT(q + 3) == tokAssign) {
                u32 p = 0;
                for (u32 j = q - 2; j > bo; j--)
                    if (scT(j) == tokLParen && scClose(j) == q + 1) { p = j; break; }
                u32 e2 = scExprEnd(q + 4, bc, acc);
                if (p != 0 && scT(p - 1) == tokIf && scStmtStart(p - 2, bo) && e2 != 0
                    && q - 1 - (p + 1) == e2 - (q + 4) && q - 1 > p + 1
                    && scSameToks(p + 1, q + 4, e2 - (q + 4))) {
                    bool clean = true;
                    for (u32 j = p + 1; j < q - 1; j++)
                        if (scT(j) == tokIdentifier && scV(j).equals(acc)) clean = false;
                    if (clean) e = e2;
                }
            }
            if (e == 0) {
                String* m = String.withCString("in a ':scan' loop '");
                m.append(acc);
                m.appendCString("' may only be updated (");
                m.append(acc);
                if (Parser._same(op, "min") || Parser._same(op, "max")) {
                    m.appendFormat(": if (e %s %s) %s = e;", Parser._same(op, "min") ? "<" : ">", acc.cString(), acc.cString());
                } else {
                    m.appendFormat(" %s= e", op.cString());
                }
                m.appendCString(") and stored (a[i] = ");
                m.append(acc);
                m.appendCString(";)");
                scFail(m, (Token*)_tokens.get(q), s0, s1);
                return false;
            }
            updates++;
            q = e;
        }
        if (updates == 0 || outs.count() == 0) {
            String* m = String.withCString(updates == 0 ? "a ':scan' loop updates its variable" : "a ':scan' loop stores its running value (a[i] = ");
            if (updates != 0) { m.append(acc); m.appendCString(";); with no store it is a :reduce"); }
            scFail(m, st, s0, s1);
            return false;
        }
        // The output arrays: used only by those stores.
        for (u32 q = bo + 1; q < bc; q++) {
            if (scT(q) != tokIdentifier) continue;
            bool isOut = false;
            for (u32 j = 0; j < outs.count(); j++)
                if (((String*)outs.get(j)).equals(scV(q))) isOut = true;
            if (!isOut || scT(q - 1) == tokDot || scT(q - 1) == tokArrow) continue;
            if (scT(q + 1) == tokLBracket && scT(q + 2) == tokIdentifier && scV(q + 2).equals(iv)
                && scT(q + 3) == tokRBracket && scT(q + 4) == tokAssign && scT(q + 5) == tokIdentifier
                && scV(q + 5).equals(acc) && scT(q + 6) == tokSemicolon)
                continue;
            String* m = String.withCString("a ':scan' loop's output array '");
            m.append(scV(q));
            m.appendCString("' is only stored, by ");
            m.append(scV(q));
            m.appendCString("[i] = ");
            m.append(acc);
            m.appendCString(";");
            scFail(m, (Token*)_tokens.get(q), s0, s1);
            return false;
        }
        return true;
    }

    // The blocks of a running total, from its parts (s: the loop's type,
    // variable, bounds and body as trees, the operator, acc and its type,
    // the output arrays, the block's name and goals, and the token at which
    // everything made stands), as pieces a par block already has, so no
    // runtime or back-end change:
    //   1. a block over 256 chunks; each runs its slice serially with its own
    //      accumulator starting at the operator's identity, stores the
    //      per-item values, and records the chunk's total;
    //   2. a serial scan of the totals from acc (acc ends as the overall total);
    //   3. a block over the chunks that combines each chunk's offset into its
    //      slice of every array the loop stored acc into.
    // A range under 65536 items runs as the loop instead, over the same
    // bounds. The made code is parsed from source, every token at the
    // `par`, with the loop's own parts put in as trees where its markers
    // stand (scSplice, parsePrimary): the bounds, the body as written
    // (__XC_SCAN_PLAIN__), and the body with acc as the chunk's own
    // accumulator and the block's goal (__XC_SCAN_BODY__).
    Node* parScanExpand(Map* s)
    {
        String* name = (String*)pfwGet(s, "name");
        String* op = (String*)pfwGet(s, "op");
        String* acc = (String*)pfwGet(s, "acc");
        String* aty = (String*)pfwGet(s, "aty");
        String* ity = (String*)pfwGet(s, "ity");
        String* iv = (String*)pfwGet(s, "iv");
        Array* outs = (Array*)pfwGet(s, "outs");
        Array* goals = (Array*)pfwGet(s, "goals");
        Token* pt = (Token*)pfwGet(s, "pt");
        bool incl = Parser.parAutoMarkN(s, "incl") != 0;
        String* goal = new String();
        for (u32 j = 0; j < goals.count(); j++) {
            goal.appendCString(":goal(");
            goal.append((String*)goals.get(j));
            goal.appendCString(") ");
        }
        _scanSeq++;
        u32 n = _scanSeq;
        u8* T = ity.cString();
        u8* A = aty.cString();
        String* src = new String();
        src.appendFormat("{ %s __xs_a%u = (__XC_SCAN_A__); %s __xs_e%u = (__XC_SCAN_B__)%s;\n", T, n, T, n, incl ? " + 1" : "");
        src.appendFormat("u64 __xs_n%u = __xs_e%u > __xs_a%u ? (u64)(__xs_e%u - __xs_a%u) : (u64)0;\n", n, n, n, n, n);
        // Short ranges run as the loop (waking the threads costs more).
        src.appendFormat("if (__xs_n%u < (u64)65536) { for (%s %s in __xs_a%u..__xs_e%u) { __XC_SCAN_PLAIN__ } } else {\n", n, T, iv.cString(), n, n);
        src.appendFormat("%s __xs_t%u[256];\n", A, n);
        String* lohi = new String();
        lohi.appendFormat("%s __xs_lo = __xs_a%u + (%s)(__xs_n%u * (u64)__xs_c / (u64)256); ", T, n, T, n);
        lohi.appendFormat("%s __xs_hi = __xs_a%u + (%s)(__xs_n%u * (u64)(__xs_c + (u32)1) / (u64)256);\n", T, n, T, n);
        src.appendFormat("par %s :device(cpu) :__scanpass %s{ for (u32 __xs_c in 0..256) {\n", name != (String*)0 ? name.cString() : "", goal.cString());
        src.append(lohi);
        src.appendFormat("%s __xs_s = %s;\n", A, Parser.scIdentity(op, aty).cString());
        src.appendFormat("for (%s %s in __xs_lo..__xs_hi) { __XC_SCAN_BODY__ }\n", T, iv.cString());
        src.appendFormat("__xs_t%u[__xs_c] = __xs_s; } }\n", n);
        src.appendFormat("%s __xs_r%u = %s;\n", A, n, acc.cString());
        String* rn = new String();
        rn.appendFormat("__xs_r%u", n);
        src.appendFormat("for (u32 __xs_c in 0..256) { %s __xs_v = __xs_t%u[__xs_c]; __xs_t%u[__xs_c] = __xs_r%u; %s }\n",
                         A, n, n, n, Parser.scCombine(op, rn, String.withCString("__xs_v")).cString());
        String* name2 = new String();
        if (name != (String*)0) { name2.append(name); name2.appendCString("_offsets"); }
        src.appendFormat("par %s :device(cpu) :__scanpass %s{ for (u32 __xs_c in 0..256) {\n", name2.cString(), goal.cString());
        src.append(lohi);
        src.appendFormat("%s __xs_o = __xs_t%u[__xs_c];\n", A, n);
        src.appendFormat("for (%s %s in __xs_lo..__xs_hi) {", T, iv.cString());
        for (u32 j = 0; j < outs.count(); j++) {
            u8* X = ((String*)outs.get(j)).cString();
            if (Parser._same(op, "min") || Parser._same(op, "max"))
                src.appendFormat(" if (__xs_o %s (%s)%s[%s]) %s[%s] = __xs_o;", Parser._same(op, "min") ? "<" : ">", A, X, iv.cString(), X, iv.cString());
            else
                src.appendFormat(" %s[%s] = (%s)(__xs_o %s (%s)%s[%s]);", X, iv.cString(), A, op.cString(), A, X, iv.cString());
        }
        src.appendCString(" } } }\n");
        src.appendFormat("%s = __xs_r%u; } }\n", acc.cString(), n);
        // Lexed, every token at the `par`.
        Lexer* lx = Lexer.with(src, String.withCString("<scan>"));
        Array* gen = lx.tokenise();
        Array* out = new Array();
        for (u32 j = 0; j < gen.count(); j++) {
            Token* g = (Token*)gen.get(j);
            Token* r = Token.withInt(g.type(), g.value(), g.intValue(), pt.line(), pt.col());
            r.setFileId(pt.fileId());
            out.add((Object*)r);
            if (g.type() == tokEOF) break;
        }
        Array* savedToks = _tokens;
        u32 savedPos = _pos;
        Map* savedSplice = _scanSplice;
        _scanSplice = s;
        _tokens = out;
        _pos = 0;
        _scanInside++;
        Node* made = parseStatement();
        _scanInside--;
        _tokens = savedToks;
        _pos = savedPos;
        _scanSplice = savedSplice;
        return made;
    }

    // At a marker of the scan's made code where statements go, into the
    // block `b`: the loop's body parsed where it is written, as the loop
    // the short range runs (__XC_SCAN_PLAIN__: the loops in it are looked at
    // by --par-style=auto there); or a copy of the body as parsed, with acc
    // as `__xs_s` and the block's goal on its loops (parAutoGoals), as the
    // chunks' body (__XC_SCAN_BODY__), whose parse's diagnostics are said
    // again. Whether there was one.
    bool scSplice(Node* b)
    {
        String* v = cur().value();
        bool chunk = Parser._same(v, "__XC_SCAN_BODY__");
        if (!chunk && !Parser._same(v, "__XC_SCAN_PLAIN__")) return false;
        advance();
        Map* s = _scanSplice;
        if (!chunk) {
            Array* savedToks = _tokens;
            u32 savedPos = _pos;
            _tokens = (Array*)pfwGet(s, "toks");
            _pos = Parser.parAutoMarkN(s, "bo") + 1;
            while ((_pwPending || (!closeBlockAhead() && !check(tokEOF))) && !_fatal) {
                u32 before = _pos;
                bool made = _pwPending;
                Node* st = parseListStatement();
                if (st != (Node*)0) b.add(st);
                if (_pos == before && !made) advance();
            }
            _tokens = savedToks;
            _pos = savedPos;
            return true;
        }
        Node* c = ((Node*)pfwGet(s, "BODY")).deepCopy();
        Parser.scRename(c, (String*)pfwGet(s, "acc"), String.withCString("__xs_s"));
        parAutoGoals(c, _goalNow == 2 ? 2 : 1);
        _scanSpliced++;
        for (u32 i = 0; i < c.kidCount(); i++) b.add(c.kid(i));
        Array* errs = (Array*)pfwGet(s, "errs");
        for (u32 i = 0; i < errs.count(); i++) : serial {
            _errors.add(errs.get(i));
            _fatal = true;
        }
        _warnings.addAll((Array*)pfwGet(s, "warns"));
        return true;
    }

    // The token index of the `{` that opens a loop's braced body, in the
    // loop's tokens [from, to).
    u32 parScanBrace(Node* body, u32 from, u32 to)
    {
        for (u32 i = from; i < to; i++) {
            Token* t = (Token*)_tokens.get(i);
            if (t.type() == tokLBrace && t.fileId() == body.fileId() && t.line() == body.line() && t.col() == body.col())
                return i;
        }
        return to;
    }

    // Each name `from` in the tree made `to`.
    static void scRename(Node* n, String* from, String* to)
    {
        if (n == (Node*)0) return;
        if (n.kind() == nkIdent && n.name() != (String*)0 && n.name().equals(from)) n.setName(to);
        for (u32 i = 0; i < n.kidCount(); i++) Parser.scRename(n.kid(i), from, to);
    }

    Node* parsePar(void)
    {
        // :scan (#144): made into plain blocks (parScanWritten).
        bool scanned = false;
        Node* sc = parScanWritten(&scanned);
        if (scanned) return sc;
        _parTok = cur();
        Token* parAt = _parTok; // a nested `par` in the body moves _parTok
        advance(); // 'par'
        Node* p = mk((u16)nkPar);
        if (check((u16)tokIdentifier)) {
            p.setName(cur().value());
            advance();
        }
        // The header as parsed, for the recogniser's walk (plSiteWalk): the
        // name, then each decorator with what it took.
        Array* head = (Array*)0;
        if (_parAuto) head = Array.with((Object*)(p.name() != (String*)0 ? p.name() : String.withCString("")));
        // The block's goal: its own, else the goal of the loop or block it
        // sits in, else the file's #goal or -fgoal=, else speed.
        u32 inherited = _goalNow != (u32)0 ? _goalNow : _goalDefault;
        u32 flags = inherited == (u32)2 ? (u32)1 : (u32)0;
        // :grid(w, h[, d]): the work items are the points of a 2-D or 3-D
        // grid, and the body is any code, run once per point.
        Array* grid = (Array*)0;
        i32 device = (i32)-1;   // :device(…): ParDevice's code, auto 0; -1 when absent
        // :constant(a, b): captured arrays the GPU reads as constants.
        Array* constants = new Array();
        bool scanPass = false;
        while (check((u16)tokColon)) {
            advance();
            if (!check((u16)tokIdentifier)) {
                _error(String.withCString("expected a decorator name after ':'"));
                return (Node*)0;
            }
            String* dec = cur().value();
            Token* decTok = cur();
            advance();
            if (dec.equals(String.withCString("grid"))) {
                if (grid != (Array*)0) {
                    _errorAt(String.withCString("'par' takes one ':grid'"), parTokNode(decTok));
                    return (Node*)0;
                }
                if (expect((u16)tokLParen) == (Token*)0) return (Node*)0;
                grid = new Array();
                grid.add((Object*)parseExpression());
                while (match((u16)tokComma)) grid.add((Object*)parseExpression());
                if (expect((u16)tokRParen) == (Token*)0) return (Node*)0;
                if (grid.count() < (u32)2 || grid.count() > (u32)3) {
                    _errorAt(String.withCString("':grid' takes a width and a height, and optionally a depth: :grid(w, h) or :grid(w, h, d)"), parTokNode(decTok));
                    return (Node*)0;
                }
                if (head != (Array*)0) {
                    Array* d = Array.with((Object*)dec);
                    d.addAll(grid);
                    head.add((Object*)d);
                }
                continue;
            }
            // :device(cpu|gpu|gpus|all|auto): the developer's DEFAULT device
            // (ParDevice's codes, auto 0). As the reference.
            if (dec.equals(String.withCString("device"))) {
                if (device >= (i32)0) {
                    _errorAt(String.withCString("'par' takes one ':device'"), parTokNode(decTok));
                    return (Node*)0;
                }
                if (expect((u16)tokLParen) == (Token*)0) return (Node*)0;
                if (!check((u16)tokIdentifier)) {
                    _error(String.withCString("':device' takes cpu, gpu, gpus, all or auto"));
                    return (Node*)0;
                }
                String* dv = cur().value();
                i32 code = (i32)-1;
                if (dv.equals(String.withCString("auto"))) code = (i32)0;
                else if (dv.equals(String.withCString("cpu"))) code = (i32)1;
                else if (dv.equals(String.withCString("gpu"))) code = (i32)2;
                else if (dv.equals(String.withCString("gpus"))) code = (i32)3;
                else if (dv.equals(String.withCString("all"))) code = (i32)4;
                if (code < (i32)0) {
                    String* m = String.withCString("':device' takes cpu, gpu, gpus, all or auto, not '");
                    m.append(dv);
                    m.appendCString("'");
                    _error(m);
                    return (Node*)0;
                }
                advance();
                device = code;
                if (expect((u16)tokRParen) == (Token*)0) return (Node*)0;
                if (head != (Array*)0) head.add((Object*)Array.with((Object*)dec, (Object*)dv));
                continue;
            }
            // :goal(speed) (the default) or :goal(accuracy): what the
            // block's GPU version favours.
            if (dec.equals(String.withCString("goal"))) {
                expect((u16)tokLParen);
                if (!check((u16)tokIdentifier)) {
                    _error(String.withCString("':goal' takes speed or accuracy"));
                    return (Node*)0;
                }
                String* g = cur().value();
                if (!g.equals(String.withCString("speed")) && !g.equals(String.withCString("accuracy"))) {
                    String* m = String.withCString("':goal' takes speed or accuracy, not '");
                    m.append(g);
                    m.appendCString("'");
                    _error(m);
                    return (Node*)0;
                }
                advance();
                if (g.equals(String.withCString("accuracy"))) flags = flags | (u32)1;
                else flags = flags & ~(u32)1;
                expect((u16)tokRParen);
                if (head != (Array*)0) head.add((Object*)Array.with((Object*)dec, (Object*)g));
                continue;
            }
            // :constant(a, b): a hint, never a change of meaning (the
            // reference explains); the CPU path ignores it.
            if (dec.equals(String.withCString("constant"))) {
                expect((u16)tokLParen);
                u32 from = constants.count();
                for (;;) {
                    if (!check((u16)tokIdentifier)) {
                        _error(String.withCString("Expected identifier"));
                        return (Node*)0;
                    }
                    constants.add((Object*)cur().value());
                    advance();
                    if (!check((u16)tokComma)) break;
                    advance();
                }
                expect((u16)tokRParen);
                if (head != (Array*)0) {
                    Array* d = Array.with((Object*)dec);
                    d.addAll(constants.subarray(from, constants.count() - from));
                    head.add((Object*)d);
                }
                continue;
            }
            // :__scanpass: a block a :scan was made into (parScanExpand);
            // its chunks own disjoint slices.
            if (dec.equals(String.withCString("__scanpass"))) {
                scanPass = true;
                if (head != (Array*)0) head.add((Object*)Array.with((Object*)dec));
                continue;
            }
            // :scan(…) here: parScanWritten has already said what is wrong.
            if (dec.equals(String.withCString("scan"))) {
                if (head != (Array*)0) head.add((Object*)Array.with((Object*)dec));
                if (check((u16)tokLParen)) {
                    i32 d = (i32)1;
                    advance();
                    while (d > (i32)0 && !check((u16)tokEOF)) {
                        if (check((u16)tokLParen)) d = d + (i32)1;
                        else if (check((u16)tokRParen)) d = d - (i32)1;
                        advance();
                    }
                }
                continue;
            }
            if (!dec.equals(String.withCString("reduce"))) {
                String* m = String.withCString("'par' has no decorator ':");
                m.append(dec);
                m.appendCString("' (it takes :reduce(op var), :scan(op var), :grid(w, h[, d]), :goal(speed|accuracy), :constant(a, b) and :device(cpu|gpu|gpus|all|auto))");
                _error(m);
                return (Node*)0;
            }
            expect((u16)tokLParen);
            String* op = (String*)0;
            if (check((u16)tokPlus)) op = String.withCString("+");
            else if (check((u16)tokStar)) op = String.withCString("*");
            else if (check((u16)tokAmpersand)) op = String.withCString("&");
            else if (check((u16)tokPipe)) op = String.withCString("|");
            else if (check((u16)tokCaret)) op = String.withCString("^");
            else if (check((u16)tokIdentifier)
                     && (cur().value().equals(String.withCString("min"))
                         || cur().value().equals(String.withCString("max"))))
                op = cur().value();
            if (op == (String*)0) {
                _error(String.withCString("':reduce' wants an operator (+ * & | ^ min max) and a variable: :reduce(+ sum)"));
                return (Node*)0;
            }
            advance();
            if (!check((u16)tokIdentifier)) {
                _error(String.withCString("':reduce' wants an operator (+ * & | ^ min max) and a variable: :reduce(+ sum)"));
                return (Node*)0;
            }
            Node* r = mk((u16)nkParReduce);
            r.setOp(op);
            r.setName(cur().value());
            advance();
            // `:reduce(+ h[])`: an array reduction, each chunk updating a
            // private copy of the array h. As the reference.
            if (match((u16)tokLBracket)) {
                if (expect((u16)tokRBracket) == (Token*)0) return (Node*)0;
                r.setNum((i64)1);
            }
            expect((u16)tokRParen);
            p.add(r);
            if (head != (Array*)0) head.add((Object*)Array.with((Object*)dec, (Object*)r));
        }
        p.setFlags(flags);
        if (!check((u16)tokLBrace)) {
            _error(String.withCString("'par' wants a block: par { ... }"));
            return (Node*)0;
        }
        // The body is parsed inside a capture frame, as a block literal's is,
        // and its frame computed from its tree (parFrameFill). As the reference.
        Map* frame = new Map();
        frame.set((Hashable*)String.withCString("depth"), (Object*)Number.with(_blkScopes.count()));
        frame.set((Hashable*)String.withCString("names"), (Object*)new Array());
        frame.set((Hashable*)String.withCString("types"), (Object*)new Map());
        frame.set((Hashable*)String.withCString("wbnames"), (Object*)new Array());
        frame.set((Hashable*)String.withCString("par"), (Object*)Number.with((u32)1));
        frame.set((Hashable*)String.withCString("written"), (Object*)new Set());
        // In main, outside every loop and block literal: it runs once per
        // program run (runsOnce, for the probe's report). As the reference.
        _parAutoDepthReads = _parAutoDepthReads + 1;
        if (_parFn != (String*)0 && _parFn.equals(String.withCString("main")) && _loopDepth == (u32)0 && _blkFrames.count() == (u32)0)
            frame.set((Hashable*)String.withCString("once"), (Object*)Number.with((u32)1));
        if (grid != (Array*)0) {
            frame.set((Hashable*)String.withCString("grid"), (Object*)grid);
            frame.set((Hashable*)String.withCString("gridUsed"), (Object*)new Set());
            frame.set((Hashable*)String.withCString("loops"), (Object*)Number.with((u32)0));
            frame.set((Hashable*)String.withCString("switches"), (Object*)Number.with((u32)0));
        }
        // The speed goal lets the GPU use its fast maths; the desugaring
        // marks the block's GPU placeholder with it.
        if ((flags & (u32)1) == (u32)0)
            frame.set((Hashable*)String.withCString("fast"), (Object*)Number.with((u32)1));
        if (constants.count() > (u32)0)
            frame.set((Hashable*)String.withCString("constant"), (Object*)constants);
        if (scanPass)
            frame.set((Hashable*)String.withCString("scanpass"), (Object*)Number.with((u32)1));
        if (device > (i32)0)
            frame.set((Hashable*)String.withCString("device"), (Object*)Number.with((u32)device));
        _blkFrames.add((Object*)frame);
        blkPushScope();
        u32 savedGoal = _goalNow;
        _goalNow = (flags & (u32)1) != (u32)0 ? (u32)2 : (u32)1;
        u32 spliced = _scanSpliced;
        Node* body = parseBlock();
        _goalNow = savedGoal;
        blkPopScope();
        _blkFrames.removeAt(_blkFrames.count() - (u32)1);
        if (body == 0) return (Node*)0;
        // The block's frame, from the body's tree. A running total's body
        // put in by the scan expansion (scSplice) was parsed outside the
        // frame: the walk says what it cannot capture and reads `self.f` as
        // the ivar, as for a lifted loop's copy.
        bool pfwAuto = _pfwAuto;
        if (_scanSpliced != spliced) {
            _pfwAuto = true;
            _pfwToks = (Array*)pfwGet(_scanSplice, "toks");
            _pfwTokFrom = Parser.parAutoMarkN(_scanSplice, "from");
            _pfwTokTo = Parser.parAutoMarkN(_scanSplice, "to");
        }
        parFrameFill(frame, body);
        _pfwAuto = pfwAuto;
        Array* reds = new Array();
        for (u32 i = (u32)0; i < p.kidCount(); i = i + (u32)1) reds.add((Object*)p.kid(i));
        // Everything the desugaring builds is at the `par`, as the
        // reference builds it; the body's own statements keep theirs.
        Token* savedMkAt = _mkAt;
        _mkAt = parAt;
        Array* savedNoted = _pfwNoted;
        _pfwNoted = new Array();
        Node* out = parDesugar(body, frame, p.name(), reds);
        pfwRegister(out, body, (Array*)0, _pfwNoted, 1, (Node*)0);
        if (head != (Array*)0) plRegister(out, 1, body, head, 0);
        _pfwNoted = savedNoted;
        _mkAt = savedMkAt;
        return out;
    }

    // The name an element access is rooted at: `a` for a[i], a[i][j], a[i].f.
    static String* parRootName(Node* n)
    {
        while (n != (Node*)0) {
            if (n.kind() == (u16)nkIdent) return n.name();
            if (n.kind() == (u16)nkSubscript && n.kidCount() > (u32)0) n = n.kid((u32)0);
            else if (n.kind() == (u16)nkMember && !n.hasFlag((u32)NF_ARROW) && n.kidCount() > (u32)0) n = n.kid((u32)0);
            else return (String*)0;
        }
        return (String*)0;
    }

    // Only read by the body: every use an element read (the reference).
    // A captured `simd:` pointer's element type (`simd:float*` -> `float`),
    // or null for any other spelling. Such a capture is a GPU buffer whose
    // size the heap header gives (par-blocks.md §3); a plain pointer is not.
    // The value of an expression of integer literals, casts and + - *, else
    // *ok stays false. As the reference.
    static i64 parFoldConstant(Node* e, bool* ok)
    {
        if (e == (Node*)0) { *ok = false; return (i64)0; }
        if (e.kind() == (u16)nkInt) { *ok = true; return e.num(); }
        if (e.kind() == (u16)nkCast && e.kidCount() > (u32)0) return Parser.parFoldConstant(e.kid((u32)0), ok);
        if (e.kind() == (u16)nkBinary && e.kidCount() == (u32)2) {
            bool okl = false;
            bool okr = false;
            i64 l = Parser.parFoldConstant(e.kid((u32)0), &okl);
            i64 r = Parser.parFoldConstant(e.kid((u32)1), &okr);
            if (okl && okr && (Parser._same(e.op(), "+") || Parser._same(e.op(), "-") || Parser._same(e.op(), "*"))) {
                *ok = true;
                return Parser._same(e.op(), "+") ? l + r : Parser._same(e.op(), "-") ? l - r : l * r;
            }
        }
        *ok = false;
        return (i64)0;
    }
    static String* parSimdPointee(String* t)
    {
        if (t == (String*)0 || t.byteLength() < (u32)7 || t.byteAt(t.byteLength() - (u32)1) != (u8)'*')
            return (String*)0;
        for (u32 i = (u32)0; i + (u32)5 <= t.byteLength(); i = i + (u32)1) {
            if (t.byteAt(i) == (u8)'s' && t.byteAt(i + (u32)1) == (u8)'i' && t.byteAt(i + (u32)2) == (u8)'m'
                && t.byteAt(i + (u32)3) == (u8)'d' && t.byteAt(i + (u32)4) == (u8)':') {
                u32 from = i + (u32)5;
                u32 to = t.byteLength() - (u32)1;
                if (to <= from) return (String*)0;
                return t.substringBytes(from, to - from);
            }
        }
        return (String*)0;
    }
    // The element type when t is a pointer to numbers (an integer, float,
    // double or bool; not an enum, known by name only), `simd:` or plain,
    // else none. Such a capture is a GPU buffer sized at run time by the
    // block it points into (par-blocks.md §3). As the reference.
    static String* parPrimPointee(String* t)
    {
        if (t == (String*)0 || t.byteLength() < (u32)3 || t.byteAt(t.byteLength() - (u32)1) != (u8)'*')
            return (String*)0;
        u32 from = (u32)0;
        for (u32 i = (u32)0; i + (u32)1 < t.byteLength(); i = i + (u32)1)
            if (t.byteAt(i) == (u8)':')
                from = i + (u32)1;
        u32 to = t.byteLength() - (u32)1;
        if (to <= from)
            return (String*)0;
        String* e = t.substringBytes(from, to - from);
        if (Parser._same(e, "i8") || Parser._same(e, "u8") || Parser._same(e, "i16") || Parser._same(e, "u16")
            || Parser._same(e, "i32") || Parser._same(e, "u32") || Parser._same(e, "i64") || Parser._same(e, "u64")
            || Parser._same(e, "float") || Parser._same(e, "double") || Parser._same(e, "bool"))
            return e;
        return (String*)0;
    }
    // The struct when t is a pointer to one (#113): a heap array of structs
    // (`new P[n]`), sized at run time like a pointer to numbers once its block
    // is page-aligned and registered (the struct allocators do that from
    // 64 KB). The kernels hold it as words (#37). As the reference.
    String* parStructPointee(String* t)
    {
        if (t == (String*)0 || t.byteLength() < (u32)2 || t.byteAt(t.byteLength() - (u32)1) != (u8)'*')
            return (String*)0;
        u32 from = (u32)0;
        for (u32 i = (u32)0; i + (u32)1 < t.byteLength(); i = i + (u32)1)
            if (t.byteAt(i) == (u8)':')
                from = i + (u32)1;
        u32 to = t.byteLength() - (u32)1;
        if (to <= from)
            return (String*)0;
        String* e = t.substringBytes(from, to - from);
        return _structNames.contains((Hashable*)e) ? e : (String*)0;
    }
    static bool parReadsOnly(Map* frame, String* n)
    {
        Map* refs = (Map*)frame.get((Hashable*)String.withCString("refs"));
        Map* sb = (Map*)frame.get((Hashable*)String.withCString("subBase"));
        Set* mw = (Set*)frame.get((Hashable*)String.withCString("memWritten"));
        Number* r = refs != (Map*)0 ? (Number*)refs.get((Hashable*)n) : (Number*)0;
        Number* b = sb != (Map*)0 ? (Number*)sb.get((Hashable*)n) : (Number*)0;
        if (r == (Number*)0 || b == (Number*)0 || r.asU32() == (u32)0 || r.asU32() != b.asU32()) return false;
        return mw == (Set*)0 || !mw.contains((Hashable*)n);
    }

    // `a[k] op= x`, `a[k]++`, or `a[k] = a[k] op x` with the same index, op
    // one of + | & ^, in a `par` body is counted under "<op><a>", once per use
    // of a, so an array reduction (:reduce(+ a[])) can check that the body
    // uses a in no other way (pfwUpdate). The key, with the uses of a it
    // makes in *uses; 0 when the assignment is no such update.
    static String* parUpdateKey(Node* t, String* op, Node* rhs, u32* uses)
    {
        if (t == (Node*)0 || t.kind() != nkSubscript || t.kidCount() < 2 || op == (String*)0) return (String*)0;
        Node* base = t.kid(0);
        if (base.kind() != nkIdent || base.name() == (String*)0) return (String*)0;
        u8 c = 0;
        *uses = 1;
        if (op.byteLength() == 2 && op.byteAt(1) == '=')
            c = op.byteAt(0);
        else if (Parser._same(op, "=") && rhs != (Node*)0 && rhs.kind() == nkBinary && rhs.kidCount() == 2
                 && rhs.op() != (String*)0 && rhs.op().byteLength() == 1) {
            Node* l = rhs.kid(0);
            if (l.kind() == nkSubscript && l.kidCount() >= 2 && l.kid(0).kind() == nkIdent
                && l.kid(0).name() != (String*)0 && l.kid(0).name().equals(base.name())
                && Parser.parSameIndex(l.kid(1), t.kid(1))) {
                c = rhs.op().byteAt(0);
                *uses = 2;
            }
        }
        if (c != '+' && c != '|' && c != '&' && c != '^') return (String*)0;
        String* key = new String();
        key.appendByte(c);
        key.append(base.name());
        return key;
    }

    // Two index expressions alike: names, integer literals, casts, binary
    // operators and element reads, of the same shape. As the reference's
    // parSameIndex.
    static bool parSameIndex(Node* a, Node* b)
    {
        if (a == (Node*)0 || b == (Node*)0 || a.kind() != b.kind()) return false;
        if (a.kind() == (u16)nkIdent)
            return a.name() != (String*)0 && b.name() != (String*)0 && a.name().equals(b.name());
        if (a.kind() == (u16)nkInt)
            return a.num() == b.num();
        if (a.kind() == (u16)nkCast)
            return a.name() != (String*)0 && b.name() != (String*)0 && a.name().equals(b.name())
                && a.kidCount() == (u32)1 && b.kidCount() == (u32)1 && Parser.parSameIndex(a.kid((u32)0), b.kid((u32)0));
        if (a.kind() == (u16)nkBinary)
            return a.op() != (String*)0 && b.op() != (String*)0 && a.op().equals(b.op())
                && a.kidCount() == (u32)2 && b.kidCount() == (u32)2
                && Parser.parSameIndex(a.kid((u32)0), b.kid((u32)0)) && Parser.parSameIndex(a.kid((u32)1), b.kid((u32)1));
        if (a.kind() == (u16)nkSubscript)
            return a.kidCount() == (u32)2 && b.kidCount() == (u32)2
                && Parser.parSameIndex(a.kid((u32)0), b.kid((u32)0)) && Parser.parSameIndex(a.kid((u32)1), b.kid((u32)1));
        return false;
    }

    // A node at a token, for an error reported there.
    Node* parTokNode(Token* t)
    {
        Node* n = mk((u16)nkPar);
        if (t != (Token*)0)
            n.setPos(t.fileId(), t.line(), t.col());
        return n;
    }

    // The innermost capture frame when it is a `par :grid` body's, else 0. A
    // block literal inside the body has its own frame. As the reference.
    Map* parGridFrame(void)
    {
        if (_blkFrames.count() == (u32)0) return (Map*)0;
        Map* frame = (Map*)_blkFrames.get(_blkFrames.count() - (u32)1);
        if (frame.get((Hashable*)String.withCString("grid")) == 0) return (Map*)0;
        return frame;
    }

    u32 parGridCount(Map* frame, string key)
    {
        return ((Number*)frame.get((Hashable*)String.withCString(key))).asU32();
    }

    // `par.x` … `par.depth` in a `par :grid` body, at the current token:
    // consumed and returned as the name the desugaring declares; else 0.
    Node* parGridMember(void)
    {
        Map* frame = parGridFrame();
        if (frame == (Map*)0 || !cur().value().equals(String.withCString("par"))
            || !checkAt((u32)1, (u16)tokDot) || !checkAt((u32)2, (u16)tokIdentifier))
            return (Node*)0;
        Token* at = cur();
        String* m = peek((u32)2).value();
        String* n = (String*)0;
        if (Parser._same(m, "x")) n = String.withCString("par$x");
        else if (Parser._same(m, "y")) n = String.withCString("par$y");
        else if (Parser._same(m, "z")) n = String.withCString("par$z");
        else if (Parser._same(m, "width")) n = String.withCString("par$w");
        else if (Parser._same(m, "height")) n = String.withCString("par$h");
        else if (Parser._same(m, "depth")) n = String.withCString("par$d");
        if (n == (String*)0) {
            String* msg = String.withCString("a 'par :grid' body has par.x, par.y, par.z, par.width, par.height and par.depth, not par.");
            msg.append(m);
            _errorAt(msg, parTokNode(at));
            n = String.withCString("par$x"); // parsing goes on as if it were par.x
        }
        advance();
        advance();
        advance();
        Node* id = mkNamed((u16)nkIdent, n);
        id.setPos(at.fileId(), at.line(), at.col());
        id.addSrc(SRC_SYNTH);
        return id;
    }

    // Loops and switches entered inside a `par :grid` body.
    void parGridEnter(string key, bool enter)
    {
        Map* frame = parGridFrame();
        if (frame == (Map*)0) return;
        u32 n = parGridCount(frame, key);
        n = enter ? n + (u32)1 : n - (u32)1;
        frame.set((Hashable*)String.withCString(key), (Object*)Number.with(n));
    }

    // A `break` outside every loop and switch of a `par :grid` body would end
    // the whole chunk of work items; `return` ends a work item.
    void parGridBreak(Token* at)
    {
        Map* frame = parGridFrame();
        if (frame != (Map*)0 && parGridCount(frame, "loops") == (u32)0 && parGridCount(frame, "switches") == (u32)0)
            _errorAt(String.withCString("'break' would leave the 'par :grid' body; 'return' ends a work item"), parTokNode(at));
    }

    // `return;` in a `par :grid` body ends the work item: `continue` of the
    // loop over the grid's points. Refused inside a loop of the body's own.
    Node* parGridReturn(Node* ret, Token* at)
    {
        Map* frame = parGridFrame();
        if (frame == (Map*)0 || ret == (Node*)0) return ret;
        if (ret.kidCount() > (u32)0) {
            _errorAt(String.withCString("a 'par :grid' body returns no value: 'return;' ends the work item"), parTokNode(at));
            return ret;
        }
        if (parGridCount(frame, "loops") > (u32)0) {
            _errorAt(String.withCString("'return' inside a loop of a 'par :grid' body: 'break' out of the loop and return after it"), parTokNode(at));
            return ret;
        }
        Node* c = mk((u16)nkContinue);
        c.setPos(at.fileId(), at.line(), at.col());
        return c;
    }

    Node* parGridDecl(String* n, Node* e)
    {
        Node* d = mkNamed((u16)nkVariableDecl, n);
        d.setOp(String.withCString("u32"));
        d.add(e);
        return d;
    }

    // A `par :grid(w, h[, d])` body as the loop form: one loop over the w*h*d
    // points, x fastest, with the point and the grid's size declared at the
    // top of each work item (only those the body uses). The sizes are
    // evaluated once, before the block, into locals the body captures: their
    // declarations are returned for the site, and the new body is left in the
    // frame as "gridBody". As the reference's parGridLoopFor.
    Array* parGridLoop(Node* body, Map* frame)
    {
        Array* decls = new Array();
        Array* grid = (Array*)frame.get((Hashable*)String.withCString("grid"));
        if (grid == (Array*)0) return decls;
        Set* used = (Set*)frame.get((Hashable*)String.withCString("gridUsed"));
        String* u32T = String.withCString("u32");
        String* i64T = String.withCString("i64");
        bool hasD = grid.count() == (u32)3;
        Array* sizes = new Array();
        decls.add((Object*)parGridDecl(String.withCString("par$w"), parCast(u32T, (Node*)grid.get((u32)0))));
        decls.add((Object*)parGridDecl(String.withCString("par$h"), parCast(u32T, (Node*)grid.get((u32)1))));
        sizes.add((Object*)String.withCString("par$w"));
        sizes.add((Object*)String.withCString("par$h"));
        // A 3-D grid captures its depth; a 2-D one's is 1, declared in the
        // work item, so a par$d capture means 3-D.
        if (hasD) {
            decls.add((Object*)parGridDecl(String.withCString("par$d"), parCast(u32T, (Node*)grid.get((u32)2))));
            sizes.add((Object*)String.withCString("par$d"));
        }
        Array* names = (Array*)frame.get((Hashable*)String.withCString("names"));
        Map* types = (Map*)frame.get((Hashable*)String.withCString("types"));
        for (u32 i = (u32)0; i < sizes.count(); i = i + (u32)1) {
            String* n = (String*)sizes.get(i);
            bool have = false;
            for (u32 j = (u32)0; j < names.count(); j = j + (u32)1)
                if (((String*)names.get(j)).equals(n)) have = true;
            if (!have) names.add((Object*)n);
            types.set((Hashable*)n, (Object*)String.withCString("u32"));
        }

        Node* item = mk((u16)nkBlock);
        if (used.contains((Hashable*)String.withCString("par$x")))
            item.add(parGridDecl(String.withCString("par$x"),
                                 parBin("%", parIdent(String.withCString("par$i")), parIdent(String.withCString("par$w")))));
        if (used.contains((Hashable*)String.withCString("par$y")))
            item.add(parGridDecl(String.withCString("par$y"),
                                 parBin("%", parBin("/", parIdent(String.withCString("par$i")), parIdent(String.withCString("par$w"))),
                                        parIdent(String.withCString("par$h")))));
        if (!hasD && used.contains((Hashable*)String.withCString("par$d")))
            item.add(parGridDecl(String.withCString("par$d"), parCast(u32T, parInt((i64)1))));
        if (used.contains((Hashable*)String.withCString("par$z")))
            item.add(parGridDecl(String.withCString("par$z"),
                                 parBin("/", parIdent(String.withCString("par$i")),
                                        parBin("*", parIdent(String.withCString("par$w")), parIdent(String.withCString("par$h"))))));
        for (u32 i = (u32)0; i < body.kidCount(); i = i + (u32)1) item.add(body.kid(i));

        // for (u32 par$i in 0..w*h[*d]), counted in i64 at the site.
        Node* count = parBin("*", parCast(i64T, parIdent(String.withCString("par$w"))),
                             parCast(i64T, parIdent(String.withCString("par$h"))));
        if (hasD) count = parBin("*", count, parCast(i64T, parIdent(String.withCString("par$d"))));
        Node* f = mk((u16)nkForCStyle);
        Node* im = mk((u16)nkMarkerInit);
        im.add(parGridDecl(String.withCString("par$i"), parCast(u32T, parInt((i64)0))));
        f.add(im);
        Node* cm = mk((u16)nkMarkerCond);
        cm.add(parBin("<", parIdent(String.withCString("par$i")), count));
        f.add(cm);
        Node* sm = mk((u16)nkMarkerStep);
        Node* step = mk((u16)nkAssign);
        step.setOp(String.withCString("+="));
        step.add(parIdent(String.withCString("par$i")));
        step.add(parInt((i64)1));
        sm.add(step);
        f.add(sm);
        f.add(item);
        Node* nb = mk((u16)nkBlock);
        nb.add(f);
        frame.set((Hashable*)String.withCString("gridBody"), (Object*)nb);
        return decls;
    }

    // A `par` loop with a stride, `for (T i in a..b step s)` (s a literal
    // above 1, ascending): the work items are its iterations, counted from 0
    // — a loop over par$k in 0..par$n with `T i = par$a + par$k * s` at the
    // top of each. The start, end and count are declared before the block
    // (par$a and par$n captured), returned for the site as the grid's sizes
    // are; the new body goes back through frame.gridBody. As the
    // reference's parStepLoopFor.
    Array* parStepLoop(Node* body, Map* frame)
    {
        Array* decls = new Array();
        Node* loop = (body.kidCount() == (u32)1 && body.kid((u32)0).kind() == (u16)nkForCStyle) ? body.kid((u32)0) : (Node*)0;
        if (loop == (Node*)0 || loop.kidCount() != (u32)4) return decls;
        Node* iv = loop.kid((u32)0).kidCount() > (u32)0 ? loop.kid((u32)0).kid((u32)0) : (Node*)0;
        Node* cond = loop.kid((u32)1).kidCount() > (u32)0 ? loop.kid((u32)1).kid((u32)0) : (Node*)0;
        Node* inc = loop.kid((u32)2).kidCount() > (u32)0 ? loop.kid((u32)2).kid((u32)0) : (Node*)0;
        Node* lbody = loop.kid((u32)3);
        if (iv == (Node*)0 || iv.kind() != (u16)nkVariableDecl || iv.kidCount() == (u32)0 || iv.op() == (String*)0) return decls;
        if (cond == (Node*)0 || cond.kind() != (u16)nkBinary || (!Parser._same(cond.op(), "<") && !Parser._same(cond.op(), "<="))) return decls;
        if (cond.kid((u32)0).kind() != (u16)nkIdent || !cond.kid((u32)0).name().equals(iv.name())) return decls;
        if (inc == (Node*)0 || inc.kind() != (u16)nkAssign || !Parser._same(inc.op(), "+=")
            || inc.kid((u32)0).kind() != (u16)nkIdent || !inc.kid((u32)0).name().equals(iv.name())
            || inc.kid((u32)1).kind() != (u16)nkInt || inc.kid((u32)1).num() < (i64)2) return decls;
        i64 st = inc.kid((u32)1).num();
        String* T = iv.op();
        // par$n: none when the range is empty, else ceil((b - a) / s) for `<`
        // and (b - a) / s + 1 for `<=`.
        bool incl = Parser._same(cond.op(), "<=");
        Node* span = parBin("-", parIdent(String.withCString("par$b")), parIdent(String.withCString("par$a")));
        Node* count = incl ? parBin("+", parBin("/", span, parInt(st)), parInt((i64)1))
                           : parBin("/", parBin("+", span, parInt(st - (i64)1)), parInt(st));
        Node* some = parBin(incl ? ">=" : ">", parIdent(String.withCString("par$b")), parIdent(String.withCString("par$a")));
        Node* tern = mk((u16)nkTernary);
        tern.add(some);
        tern.add(count);
        tern.add(parCast(T, parInt((i64)0)));
        decls.add((Object*)parTypedDecl(String.withCString("par$a"), T, parCast(T, iv.kid((u32)0))));
        decls.add((Object*)parTypedDecl(String.withCString("par$b"), T, parCast(T, cond.kid((u32)1))));
        decls.add((Object*)parTypedDecl(String.withCString("par$n"), T, tern));
        Array* names = (Array*)frame.get((Hashable*)String.withCString("names"));
        Map* types = (Map*)frame.get((Hashable*)String.withCString("types"));
        Array* caps = new Array();
        caps.add((Object*)String.withCString("par$a"));
        caps.add((Object*)String.withCString("par$n"));
        for (u32 i = (u32)0; i < caps.count(); i = i + (u32)1) {
            String* n = (String*)caps.get(i);
            bool have = false;
            for (u32 j = (u32)0; j < names.count(); j = j + (u32)1)
                if (((String*)names.get(j)).equals(n)) have = true;
            if (!have) names.add((Object*)n);
            types.set((Hashable*)n, (Object*)String.withString(T));
        }
        Node* item = mk((u16)nkBlock);
        item.add(parTypedDecl(iv.name(), T, parBin("+", parIdent(String.withCString("par$a")),
                                                     parBin("*", parIdent(String.withCString("par$k")), parInt(st)))));
        if (lbody.kind() == (u16)nkBlock) {
            for (u32 i = (u32)0; i < lbody.kidCount(); i = i + (u32)1) item.add(lbody.kid(i));
        } else
            item.add(lbody);
        Node* f = mk((u16)nkForCStyle);
        Node* im = mk((u16)nkMarkerInit);
        im.add(parTypedDecl(String.withCString("par$k"), T, parCast(T, parInt((i64)0))));
        f.add(im);
        Node* cm = mk((u16)nkMarkerCond);
        cm.add(parBin("<", parIdent(String.withCString("par$k")), parIdent(String.withCString("par$n"))));
        f.add(cm);
        Node* sm = mk((u16)nkMarkerStep);
        Node* step = mk((u16)nkAssign);
        step.setOp(String.withCString("+="));
        step.add(parIdent(String.withCString("par$k")));
        step.add(parInt((i64)1));
        sm.add(step);
        f.add(sm);
        f.add(item);
        Node* nb = mk((u16)nkBlock);
        nb.add(f);
        frame.set((Hashable*)String.withCString("gridBody"), (Object*)nb);
        return decls;
    }

    Node* parTypedDecl(String* n, String* t, Node* e)
    {
        Node* d = mkNamed((u16)nkVariableDecl, String.withString(n));
        d.setOp(String.withString(t));
        d.add(e);
        return d;
    }

    // ── par → ParChunk subclass + run (the reference's parDesugarBody) ──
    Node* parIdent(String* n) { return mkNamed((u16)nkIdent, String.withString(n)); }
    Node* parMember(String* b, String* m)
    {
        Node* n = mkNamed((u16)nkMember, String.withString(m));
        n.add(parIdent(b));
        return n;
    }
    Node* parStmt(Node* e) { Node* s = mk((u16)nkExprStatement); s.add(e); return s; }
    Node* parAssign(Node* l, Node* r)
    {
        Node* a = mk((u16)nkAssign);
        a.setOp(String.withCString("="));
        a.add(l); a.add(r);
        return parStmt(a);
    }
    Node* parCast(String* t, Node* e) { Node* c = mkNamed((u16)nkCast, String.withString(t)); c.add(e); return c; }
    Node* parInt(i64 v) { Node* n = mk((u16)nkInt); n.setNum(v); return n; }
    // `parSameName(name, "<g>")`: the test gpuGlobal() makes per global.
    Node* parSameNameCall(String* g)
    {
        Node* c = mkNamed((u16)nkCall, String.withCString("parSameName"));
        c.add(parIdent(String.withCString("__par_name")));
        c.add(mkNamed((u16)nkStr, String.withString(g)));
        c.setNum((i64)2);
        return c;
    }
    Node* parBin(string op, Node* l, Node* r)
    {
        Node* b = mk((u16)nkBinary);
        b.setOp(String.withCString(op));
        b.add(l); b.add(r);
        return b;
    }
    bool parIdem(String* op)
    {
        return Parser._same(op, "&") || Parser._same(op, "|") || Parser._same(op, "min") || Parser._same(op, "max");
    }
    // A reduction's starting value: the identity for + * ^, else the
    // variable's current value (the idempotent & | min max).
    Node* parStart(String* op, String* ty, Node* cur)
    {
        if (Parser._same(op, "+") || Parser._same(op, "^")) return parCast(ty, parInt((i64)0));
        if (Parser._same(op, "*")) return parCast(ty, parInt((i64)1));
        return cur;
    }

    // An array reduction's code for ParFnChunk.arrMerge: the array's bytes
    // << 8, the operator << 4 (1 +, 2 |, 3 &, 4 ^), the element's width in
    // bytes. 0 when ty is no one-dimensional array of integers of a size
    // known when the program is built, or op is none of + | & ^. As the
    // reference's parArrCode.
    static i64 parArrCode(String* ty, String* op)
    {
        if (ty == (String*)0) return (i64)0;
        u32 lb = ty.indexOfByte((u8)'[');
        if (lb == (u32)$FFFFFFFF) return (i64)0;
        String* e = ty.substringBytes((u32)0, lb);
        i64 w = (i64)0;
        if (Parser._same(e, "u8") || Parser._same(e, "i8")) w = (i64)1;
        else if (Parser._same(e, "u16") || Parser._same(e, "i16")) w = (i64)2;
        else if (Parser._same(e, "u32") || Parser._same(e, "i32")) w = (i64)4;
        else if (Parser._same(e, "u64") || Parser._same(e, "i64")) w = (i64)8;
        if (w == (i64)0) return (i64)0;
        i64 count = (i64)0;
        u32 q = lb + (u32)1;
        while (q < ty.byteLength() && ty.byteAt(q) >= (u8)'0' && ty.byteAt(q) <= (u8)'9') {
            count = count * (i64)10 + (i64)(ty.byteAt(q) - (u8)'0');
            q = q + (u32)1;
        }
        if (count <= (i64)0 || q + (u32)1 != ty.byteLength() || ty.byteAt(q) != (u8)']') return (i64)0;
        i64 o = Parser._same(op, "+") ? (i64)1 : Parser._same(op, "|") ? (i64)2
              : Parser._same(op, "&") ? (i64)3 : Parser._same(op, "^") ? (i64)4 : (i64)0;
        if (o == (i64)0) return (i64)0;
        return ((count * w) << (i64)8) | (o << (i64)4) | w;
    }
    // An array reduction's element type: `u32` for `u32[256]`.
    static String* parArrElem(String* ty)
    {
        return ty.substringBytes((u32)0, ty.indexOfByte((u8)'['));
    }
    // A chunk's private copy of an array reduction's array, every element
    // the operator's identity: `(T*)ParFnChunk.arrNew(bytes, fill)`.
    Node* parArrNew(String* op, String* ty)
    {
        i64 code = Parser.parArrCode(ty, op);
        Node* call = mkNamed((u16)nkMethodCall, String.withCString("arrNew"));
        call.add(parIdent(String.withCString("ParFnChunk")));
        call.add(parCast(String.withCString("i64"), parInt(code >> (i64)8)));
        call.add(parCast(String.withCString("u32"), parInt(Parser._same(op, "&") ? (i64)255 : (i64)0)));
        call.setNum((i64)2);
        String* pt = Parser.parArrElem(ty);
        pt.appendByte((u8)'*');
        return parCast(pt, call);
    }

    // A capture named as one of the block's own members keeps its name in
    // the body (a local of run()), and its ivar is `__par_<name>`. As the
    // reference's reservedCapture / fieldOf / fieldRef.
    static bool parReservedCapture(String* n)
    {
        return Parser._same(n, "run") || Parser._same(n, "go") || Parser._same(n, "lo") || Parser._same(n, "hi")
            || Parser._same(n, "merge") || Parser._same(n, "copyChunk") || Parser._same(n, "parName")
            || Parser._same(n, "defaultDevice") || Parser._same(n, "runsOnce")
            || Parser._same(n, "gpuSource") || Parser._same(n, "gpuLength") || Parser._same(n, "gpuGlobal")
            || Parser._same(n, "gpuGlobalBytes") || Parser._same(n, "gpuReadsOnly")
            || Parser._same(n, "gpuReadsOnlyGlobal") || Parser._same(n, "gpuWritesAll")
            || Parser._same(n, "gpuWritesAllOwn");
    }
    static String* parFieldOf(String* n)
    {
        if (!Parser.parReservedCapture(n)) return n;
        String* f = String.withCString("__par_");
        f.append(n);
        return f;
    }
    // The ivar, from a method of the block: by its plain name as before, and
    // as self.__par_<name> when it was renamed.
    Node* parFieldRef(String* n)
    {
        if (Parser.parReservedCapture(n)) return parMember(String.withCString("self"), Parser.parFieldOf(n));
        return parIdent(n);
    }
    // The chunk's own lo / hi, from run(): self.<n> when a capture is so
    // named (its local would shadow it), else the plain name as before.
    Node* parRangeRef(Array* frameNames, string n)
    {
        for (u32 i = (u32)0; i < frameNames.count(); i = i + (u32)1)
            if (Parser._same((String*)frameNames.get(i), n))
                return parMember(String.withCString("self"), String.withCString(n));
        return parIdent(String.withCString(n));
    }
    // Whether run() reads a capture of this type into a local (a pointer or a
    // scalar; an array as its pointer): the local is what makes the body's
    // name mean the capture.
    static bool parHasLocal(String* ty)
    {
        String* t = String.withString(ty);
        u32 lb = t.indexOfByte((u8)'[');
        if (lb != (u32)$FFFFFFFF) { t = t.substringBytes((u32)0, lb); t.appendByte((u8)'*'); }
        bool isPtr = t.byteLength() > (u32)0 && t.byteAt(t.byteLength() - (u32)1) == (u8)'*';
        bool isScalar = Parser._same(t, "i8") || Parser._same(t, "u8") || Parser._same(t, "i16")
            || Parser._same(t, "u16") || Parser._same(t, "i32") || Parser._same(t, "u32")
            || Parser._same(t, "i64") || Parser._same(t, "u64") || Parser._same(t, "float")
            || Parser._same(t, "double") || Parser._same(t, "bool") || Parser._same(t, "pointer")
            || Parser._same(t, "string");
        return isPtr || isScalar;
    }
    // A node at the `par` keyword, for an error about the whole block: the
    // reference reports those there, not where parsing had got to (bug 617).
    Node* parKeywordNode(void)
    {
        Node* n = mk((u16)nkPar);
        if (_parTok != (Token*)0)
            n.setPos(_parTok.fileId(), _parTok.line(), _parTok.col());
        return n;
    }

    // `dst = dst OP src`, or for min / max `if (src < dst) dst = src`.
    Node* parFold(String* op, Node* dst, Node* dst2, Node* src)
    {
        if (Parser._same(op, "min") || Parser._same(op, "max")) {
            Node* n = mk((u16)nkIf);
            n.add(parBin(Parser._same(op, "min") ? "<" : ">", src, dst2));
            Node* then = mk((u16)nkBlock);
            then.add(parAssign(dst, src));
            n.add(then);
            return n;
        }
        Node* b = mk((u16)nkBinary);
        b.setOp(String.withString(op));
        b.add(dst2); b.add(src);
        return parAssign(dst, b);
    }

    Node* parDesugar(Node* body, Map* frame, String* parName, Array* reds)
    {
        String* label = String.withCString("par");
        if (parName != 0) { label.appendCString(" "); label.append(parName); }
        Array* gridDecls = parGridLoop(body, frame);
        if (gridDecls.count() == (u32)0)
            gridDecls = parStepLoop(body, frame);
        if (frame.get((Hashable*)String.withCString("gridBody")) != 0)
            body = (Node*)frame.get((Hashable*)String.withCString("gridBody"));
        // The loop form: exactly one ascending `for (T i in a..b)`.
        Node* loop = (body.kidCount() == (u32)1 && body.kid((u32)0).kind() == (u16)nkForCStyle) ? body.kid((u32)0) : (Node*)0;
        Node* iv = (Node*)0;
        Node* cond = (Node*)0;
        Node* step = (Node*)0;
        if (loop != 0 && loop.kidCount() == (u32)4) {
            if (loop.kid((u32)0).kidCount() > (u32)0) iv = loop.kid((u32)0).kid((u32)0);
            if (loop.kid((u32)1).kidCount() > (u32)0) cond = loop.kid((u32)1).kid((u32)0);
            if (loop.kid((u32)2).kidCount() > (u32)0) step = loop.kid((u32)2).kid((u32)0);
        }
        // The step: `i += 1` (a range loop's), and the C-style spellings too —
        // `i++`, `++i`, `i = i + 1` — as the reference takes them.
        bool stepOk = false;
        // Only a loop that declares its variable: `for (i = 0; …)` on an
        // outer `i` has no name to compare with (the reference's nil compare
        // is false; here it crashed --par-style=auto, arc_inert_elide, 2026-10-17).
        if (step != 0 && iv != 0 && iv.kind() == (u16)nkVariableDecl && iv.name() != 0) {
            if (step.kind() == (u16)nkAssign && Parser._same(step.op(), "+=")
                && step.kid((u32)1).kind() == (u16)nkInt && step.kid((u32)1).num() == (i64)1)
                stepOk = true;
            else if (step.kind() == (u16)nkAssign && Parser._same(step.op(), "=")
                && step.kid((u32)0).kind() == (u16)nkIdent && step.kid((u32)0).name().equals(iv.name())
                && step.kid((u32)1).kind() == (u16)nkBinary && Parser._same(step.kid((u32)1).op(), "+")
                && step.kid((u32)1).kid((u32)0).kind() == (u16)nkIdent && step.kid((u32)1).kid((u32)0).name().equals(iv.name())
                && step.kid((u32)1).kid((u32)1).kind() == (u16)nkInt && step.kid((u32)1).kid((u32)1).num() == (i64)1)
                stepOk = true;
            else if ((step.kind() == (u16)nkPostfix || step.kind() == (u16)nkUnary) && Parser._same(step.op(), "++")
                && step.kidCount() > (u32)0 && step.kid((u32)0).kind() == (u16)nkIdent && step.kid((u32)0).name().equals(iv.name()))
                stepOk = true;
        }
        bool ok = iv != 0 && iv.kind() == (u16)nkVariableDecl && iv.kidCount() > (u32)0 && iv.op() != 0
            && cond != 0 && cond.kind() == (u16)nkBinary
            && (Parser._same(cond.op(), "<") || Parser._same(cond.op(), "<="))
            && cond.kid((u32)0).kind() == (u16)nkIdent && cond.kid((u32)0).name().equals(iv.name())
            && stepOk;
        if (!ok) {
            _errorAt(String.withFormat("a '%s' block's body is one ascending loop: par { for (T i in a..b) { ... } }", label.cString()), parKeywordNode());
            return (Node*)0;
        }
        if (!isTypeName(String.withCString("ParChunk"))) {
            _errorAt(String.withCString("a 'par' block needs its runtime: #import \"Par.xc\""), parKeywordNode());
            return (Node*)0;
        }
        String* ivT = iv.op();
        Array* frameNames = (Array*)frame.get((Hashable*)String.withCString("names"));
        Map* frameTypes = (Map*)frame.get((Hashable*)String.withCString("types"));
        Set* written = (Set*)frame.get((Hashable*)String.withCString("written"));
        Map* redTypes = new Map();
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1) {
            Node* r = (Node*)reds.get(i);
            Object* t = frameTypes.get((Hashable*)r.name());
            if (t == 0) t = (Object*)blkTyOf(blkLookup(r.name(), (u32*)0));
            // An array reduction's array may be a global as well.
            if (t == 0 && r.num() != (i64)0 && _parTopVars != (Map*)0) t = _parTopVars.get((Hashable*)r.name());
            if (t == 0) {
                if (r.num() != (i64)0)
                    _errorAt(String.withFormat("':reduce(%s %s[])': '%s' is not an array declared before the '%s' block",
                                               r.op().cString(), r.name().cString(), r.name().cString(), label.cString()), parKeywordNode());
                else
                    _errorAt(String.withFormat("':reduce(%s %s)': '%s' is not a local declared before the '%s' block",
                                               r.op().cString(), r.name().cString(), r.name().cString(), label.cString()), parKeywordNode());
                return (Node*)0;
            }
            // `:reduce(+ h[])`: + | & or ^ over an array of integers of a
            // size known when the program is built, which the body only
            // updates, as h[k] op= x or h[k] = h[k] op x. As the reference.
            if (r.num() != (i64)0) {
                if (!Parser._same(r.op(), "+") && !Parser._same(r.op(), "|") && !Parser._same(r.op(), "&") && !Parser._same(r.op(), "^")) {
                    _errorAt(String.withFormat("':reduce(%s %s[])': an array reduction takes + | & or ^",
                                               r.op().cString(), r.name().cString()), parKeywordNode());
                    return (Node*)0;
                }
                if (Parser.parArrCode((String*)t, r.op()) == (i64)0) {
                    _errorAt(String.withFormat("':reduce(%s %s[])': '%s' is not an array of integers (u8 to u64, i8 to i64) of a size known when the program is built",
                                               r.op().cString(), r.name().cString(), r.name().cString()), parKeywordNode());
                    return (Node*)0;
                }
                String* key = String.withString(r.op());
                key.append(r.name());
                Map* refs = (Map*)frame.get((Hashable*)String.withCString("refs"));
                Map* ups = (Map*)frame.get((Hashable*)String.withCString("updates"));
                Number* nr = refs != (Map*)0 ? (Number*)refs.get((Hashable*)r.name()) : (Number*)0;
                Number* nu = ups != (Map*)0 ? (Number*)ups.get((Hashable*)key) : (Number*)0;
                if (nr == (Number*)0 || nu == (Number*)0 || nr.asU32() != nu.asU32()) {
                    _errorAt(String.withFormat("':reduce(%s %s[])': the '%s' block uses '%s' other than as %s[k] %s= x or %s[k] = %s[k] %s x",
                                               r.op().cString(), r.name().cString(), label.cString(), r.name().cString(),
                                               r.name().cString(), r.op().cString(), r.name().cString(), r.name().cString(),
                                               r.op().cString()), parKeywordNode());
                    return (Node*)0;
                }
            }
            redTypes.set((Hashable*)r.name(), t);
        }
        Array* caps = new Array();
        for (u32 i = (u32)0; i < frameNames.count(); i = i + (u32)1) {
            String* cn = (String*)frameNames.get(i);
            if (redTypes.get((Hashable*)cn) == 0) caps.add((Object*)cn);
        }
        for (u32 i = (u32)0; i < caps.count(); i = i + (u32)1) {
            String* cn = (String*)caps.get(i);
            String* t = (String*)frameTypes.get((Hashable*)cn);
            if (written.contains((Hashable*)cn) && t.indexOfByte((u8)'[') == (u32)$FFFFFFFF) {
                _errorAt(String.withFormat("a '%s' block cannot assign to '%s': every work item has its own copy of it. Make it a reduction (:reduce(+ %s)) or write into an array",
                                           label.cString(), cn.cString(), cn.cString()), parKeywordNode());
                return (Node*)0;
            }
        }
        // A capture becomes an ivar of the block's class, whose own methods
        // and range fields are named below. One with such a name keeps it in
        // the body, a local of run(), and its ivar is `__par_<name>`
        // (parFieldOf); a capture with no local (a struct) is still refused by
        // those names, as is any name beginning `__par_`. As the reference.
        for (u32 i = (u32)0; i < frameNames.count(); i = i + (u32)1) {
            String* cn = (String*)frameNames.get(i);
            bool own = cn.hasPrefix(String.withCString("__par_"));
            if (own || (Parser.parReservedCapture(cn) && redTypes.get((Hashable*)cn) == 0
                        && !Parser.parHasLocal((String*)frameTypes.get((Hashable*)cn)))) {
                _errorAt(String.withFormat("a '%s' block cannot capture '%s': the name is one of the block's own (%s). Rename the variable",
                                           label.cString(), cn.cString(), own ? "names beginning __par_"
                                               : "run, go, lo, hi, merge, copyChunk, parName, defaultDevice, runsOnce, gpuSource, gpuLength, gpuGlobal, gpuGlobalBytes, gpuReadsOnly, gpuReadsOnlyGlobal, gpuWritesAll, for a struct"), parKeywordNode());
                return (Node*)0;
            }
        }
        // A global the body names is reached by that name from the block's
        // run(), where the block's range fields lo and hi, and its __par_
        // names, are found first. As the reference.
        Array* outerG = (Array*)frame.get((Hashable*)String.withCString("outer"));
        if (outerG != (Array*)0 && _parTopVars != (Map*)0)
            for (u32 i = (u32)0; i < outerG.count(); i = i + (u32)1) {
                String* gn = (String*)outerG.get(i);
                if (_parTopVars.get((Hashable*)gn) == (Object*)0 || redTypes.get((Hashable*)gn) != 0) continue;
                bool own = gn.hasPrefix(String.withCString("__par_"));
                if (own || Parser._same(gn, "lo") || Parser._same(gn, "hi")) {
                    _errorAt(String.withFormat("a '%s' block cannot capture '%s': the name is one of the block's own (%s). Rename the variable",
                                               label.cString(), gn.cString(), own ? "names beginning __par_" : "lo, hi, for a global"), parKeywordNode());
                    return (Node*)0;
                }
            }
        // :constant(a, b): each name a captured array, or pointer to numbers,
        // the body only reads. As the reference.
        Array* constants = (Array*)frame.get((Hashable*)String.withCString("constant"));
        if (constants == (Array*)0) constants = new Array();
        for (u32 i = (u32)0; i < constants.count(); i = i + (u32)1) {
            String* cn = (String*)constants.get(i);
            String* ct = (String*)frameTypes.get((Hashable*)cn);
            bool isCap = false;
            for (u32 q = (u32)0; q < caps.count(); q = q + (u32)1)
                if (((String*)caps.get(q)).equals(cn)) isCap = true;
            bool isArr = isCap && ct != (String*)0 && (ct.indexOfByte((u8)'[') != (u32)$FFFFFFFF || Parser.parPrimPointee(ct) != (String*)0);
            if (!isArr || !Parser.parReadsOnly(frame, cn)) {
                _errorAt(String.withFormat("':constant(%s)': '%s' is not an array the '%s' block only reads (a captured array or pointer to numbers, indexed and never written)",
                                           cn.cString(), cn.cString(), label.cString()), parKeywordNode());
                return (Node*)0;
            }
        }

        u32 counter = _parCounter;
        _parCounter = _parCounter + (u32)1;
        String* implName = String.withCString("ParImpl$");
        implName.append(String.withU32(counter));
        _typeNames.add((Hashable*)String.withString(implName));
        String* implPtr = String.withString(implName); implPtr.appendByte((u8)'*');

        Node* cls = mkNamed((u16)nkClassDecl, implName);
        // At the `par`, as the reference has it, so an error about the block
        // (the subset check after lowering) points at the block, not past it.
        if (_parTok != (Token*)0)
            cls.setPos(_parTok.fileId(), _parTok.line(), _parTok.col());
        cls.setOp(String.withCString("ParChunk"));
        // The block's class: its run is the kernel (lowering marks it).
        cls.addFlag((u32)NF_PARBLOCK);
        for (u32 i = (u32)0; i < caps.count(); i = i + (u32)1) {
            String* cn = (String*)caps.get(i);
            String* t = String.withString((String*)frameTypes.get((Hashable*)cn));
            u32 lb = t.indexOfByte((u8)'[');
            if (lb != (u32)$FFFFFFFF) { t = t.substringBytes((u32)0, lb); t.appendByte((u8)'*'); }
            Node* ivn = mkNamed((u16)nkVariableDecl, Parser.parFieldOf(cn));
            ivn.setOp(t);
            cls.add(ivn);
        }
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1) {
            Node* r = (Node*)reds.get(i);
            Node* ivn = mkNamed((u16)nkVariableDecl, Parser.parFieldOf(r.name()));
            // An array reduction's ivar points at the array the chunk
            // updates: the real one in the block's own chunk, a private
            // copy in every other.
            if (r.num() != (i64)0) {
                String* pt = Parser.parArrElem((String*)redTypes.get((Hashable*)r.name()));
                pt.appendByte((u8)'*');
                ivn.setOp(pt);
            } else
                ivn.setOp((String*)redTypes.get((Hashable*)r.name()));
            cls.add(ivn);
        }
        // run(): the loop over [lo, hi), the body verbatim.
        {
            Node* m = mkNamed((u16)nkMethodDecl, String.withCString("run"));
            m.setOp(String.withCString("void"));
            Node* f = mk((u16)nkForCStyle);
            Node* im = mk((u16)nkMarkerInit);
            Node* decl = mkNamed((u16)nkVariableDecl, iv.name());
            decl.setOp(ivT);
            // The chunk's own range: self.lo when a capture's local is lo.
            decl.add(parCast(ivT, parRangeRef(frameNames, "lo")));
            im.add(decl);
            f.add(im);
            Node* cm = mk((u16)nkMarkerCond);
            cm.add(parBin("<", parIdent(iv.name()), parCast(ivT, parIdent(String.withCString("__par_hi")))));
            f.add(cm);
            f.add(loop.kid((u32)2));
            f.add(loop.kid((u32)3));
            // The block's goal holds for the CPU path too. As the reference.
            f.addFlag(frame.get((Hashable*)String.withCString("fast")) != 0 ? (u32)NF_GOAL_SPEED : (u32)NF_GOAL_ACCURACY);
            Node* rb = mk((u16)nkBlock);
            // The loop's UPPER BOUND is hoisted into a local. `i < self.hi` reads
            // the ivar in the loop HEADER every iteration, so the header carries
            // a memory op: the vectoriser requires a pure header, so every par
            // loop was refused and stayed scalar. Reading `hi` once, before the
            // loop, makes the header the guard alone. As the reference.
            {
                Node* h = mkNamed((u16)nkVariableDecl, String.withCString("__par_hi"));
                h.setOp(ivT);
                h.add(parCast(ivT, parRangeRef(frameNames, "hi")));
                rb.add(h);
            }
            // Every capture is read into a local of run() once: the body
            // named it as the ivar, a load inside the loop for every use,
            // which a store in the loop keeps the hoister from moving. The
            // local shadows the ivar, so the body is unchanged. Pointers and
            // scalars only, as the reference (a struct local is an aggregate
            // copy the GPU printers cannot express).
            for (u32 i = (u32)0; i < caps.count(); i = i + (u32)1) {
                String* cn = (String*)caps.get(i);
                String* t = String.withString((String*)frameTypes.get((Hashable*)cn));
                u32 lb = t.indexOfByte((u8)'[');
                if (lb != (u32)$FFFFFFFF) { t = t.substringBytes((u32)0, lb); t.appendByte((u8)'*'); }
                bool isPtr = t.byteLength() > (u32)0 && t.byteAt(t.byteLength() - (u32)1) == (u8)'*';
                bool isScalar = Parser._same(t, "i8") || Parser._same(t, "u8") || Parser._same(t, "i16")
                    || Parser._same(t, "u16") || Parser._same(t, "i32") || Parser._same(t, "u32")
                    || Parser._same(t, "i64") || Parser._same(t, "u64") || Parser._same(t, "float")
                    || Parser._same(t, "double") || Parser._same(t, "bool") || Parser._same(t, "pointer")
                    || Parser._same(t, "string");
                if (!isPtr && !isScalar)
                    continue;
                Node* d = mkNamed((u16)nkVariableDecl, cn);
                d.setOp(t);
                d.add(parMember(String.withCString("self"), Parser.parFieldOf(cn)));
                rb.add(d);
            }
            for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1) {
                Node* r = (Node*)reds.get(i);
                Node* d = mkNamed((u16)nkVariableDecl, r.name());
                // An array reduction's local is the pointer the body indexes
                // (it shadows a global of that name); nothing is stored back.
                if (r.num() != (i64)0) {
                    String* pt = Parser.parArrElem((String*)redTypes.get((Hashable*)r.name()));
                    pt.appendByte((u8)'*');
                    d.setOp(pt);
                } else
                    d.setOp((String*)redTypes.get((Hashable*)r.name()));
                d.add(parMember(String.withCString("self"), Parser.parFieldOf(r.name())));
                rb.add(d);
            }
            rb.add(f);
            for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1) {
                Node* r = (Node*)reds.get(i);
                if (r.num() != (i64)0) continue;
                rb.add(parAssign(parMember(String.withCString("self"), Parser.parFieldOf(r.name())), parIdent(r.name())));
            }
            m.add(rb);
            cls.add(m);
        }
        // copyChunk(): a fresh chunk with the same captures, reductions at their start.
        {
            Node* m = mkNamed((u16)nkMethodDecl, String.withCString("copyChunk"));
            m.setOp(String.withCString("ParChunk*"));
            Node* b = mk((u16)nkBlock);
            // The new chunk is `__par_t` (refused as a capture, as __par_hi is):
            // as `t` it shadowed a capture called t, and `t.t = t` copied the
            // chunk into itself.
            Node* t = mkNamed((u16)nkVariableDecl, String.withCString("__par_t"));
            t.setOp(implPtr);
            Node* nw = mkNamed((u16)nkNew, implName);
            nw.setNum((i64)0);
            t.add(nw);
            b.add(t);
            for (u32 i = (u32)0; i < caps.count(); i = i + (u32)1) {
                String* cn = (String*)caps.get(i);
                b.add(parAssign(parMember(String.withCString("__par_t"), Parser.parFieldOf(cn)), parFieldRef(cn)));
            }
            for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1) {
                Node* r = (Node*)reds.get(i);
                if (r.num() != (i64)0) {
                    b.add(parAssign(parMember(String.withCString("__par_t"), Parser.parFieldOf(r.name())),
                                    parArrNew(r.op(), (String*)redTypes.get((Hashable*)r.name()))));
                    continue;
                }
                b.add(parAssign(parMember(String.withCString("__par_t"), Parser.parFieldOf(r.name())),
                                parStart(r.op(), (String*)redTypes.get((Hashable*)r.name()), parFieldRef(r.name()))));
            }
            Node* ret = mk((u16)nkReturn);
            ret.add(parIdent(String.withCString("__par_t")));
            b.add(ret);
            m.add(b);
            cls.add(m);
        }
        // gpuLength(k): the byte length of own ivar k when it is a captured
        // array (a GPU buffer), else -1. The GPU runtime sizes its buffers
        // from this.
        {
            Node* m = mkNamed((u16)nkMethodDecl, String.withCString("gpuLength"));
            m.setOp(String.withCString("i64"));
            Node* p = mkNamed((u16)nkParam, String.withCString("__par_k"));
            p.setOp(String.withCString("i32"));
            m.add(p);
            Node* b = mk((u16)nkBlock);
            for (u32 i = (u32)0; i < caps.count(); i = i + (u32)1) {
                String* cn = (String*)caps.get(i);
                String* t = (String*)frameTypes.get((Hashable*)cn);
                u32 lb = t.indexOfByte((u8)'[');
                Node* bytes = (Node*)0;
                if (lb != (u32)$FFFFFFFF) {
                    String* elem = t.substringBytes((u32)0, lb);
                    i64 count = (i64)0;
                    for (u32 q = lb + (u32)1; q < t.byteLength() && t.byteAt(q) >= (u8)'0' && t.byteAt(q) <= (u8)'9'; q = q + (u32)1)
                        count = count * (i64)10 + (i64)(t.byteAt(q) - (u8)'0');
                    if (count <= (i64)0)
                        continue;
                    Node* sz = mk((u16)nkSizeof);
                    sz.setName(elem);
                    bytes = parBin("*", parCast(String.withCString("i64"), parInt(count)),
                                   parCast(String.withCString("i64"), sz));
                } else if (Parser.parPrimPointee(t) != (String*)0) {
                    // A pointer to numbers, `simd:` or plain: its length is
                    // asked of the runtime, which knows every page-aligned
                    // block and the bytes from the pointer to its end (the
                    // reference explains).
                    Node* sz = mk((u16)nkSizeof);
                    sz.setName(Parser.parPrimPointee(t));
                    Node* call = mkNamed((u16)nkMethodCall, String.withCString("spanOf"));
                    call.add(parIdent(String.withCString("Par")));
                    call.add(parCast(String.withCString("pointer"), parFieldRef(cn)));
                    call.add(parCast(String.withCString("i64"), sz));
                    Node* simd = mk((u16)nkBool);
                    simd.setNum(Parser.parSimdPointee(t) != (String*)0 ? (i64)1 : (i64)0);
                    call.add(simd);
                    call.setNum((i64)3);
                    bytes = call;
                } else if (parStructPointee(t) != (String*)0) {
                    // A pointer to structs (#113): asked of the runtime the
                    // same way, in the struct's size (the reference explains).
                    Node* sz = mk((u16)nkSizeof);
                    sz.setName(parStructPointee(t));
                    Node* call = mkNamed((u16)nkMethodCall, String.withCString("spanOf"));
                    call.add(parIdent(String.withCString("Par")));
                    call.add(parCast(String.withCString("pointer"), parFieldRef(cn)));
                    call.add(parCast(String.withCString("i64"), sz));
                    Node* nos = mk((u16)nkBool);
                    nos.setNum((i64)0);
                    call.add(nos);
                    call.setNum((i64)3);
                    bytes = call;
                } else
                    continue;
                Node* n = mk((u16)nkIf);
                n.add(parBin("==", parIdent(String.withCString("__par_k")),
                             parCast(String.withCString("i32"), parInt((i64)i))));
                Node* then = mk((u16)nkBlock);
                Node* ret = mk((u16)nkReturn);
                ret.add(bytes);
                then.add(ret);
                n.add(then);
                b.add(n);
            }
            Node* none = mk((u16)nkReturn);
            none.add(parBin("-", parCast(String.withCString("i64"), parInt((i64)0)),
                            parCast(String.withCString("i64"), parInt((i64)1))));
            b.add(none);
            m.add(b);
            cls.add(m);
            // gpuReadsOnly(k): own ivar k is a captured array the body only
            // reads (the reference explains; bug 645).
            Node* bro = mk((u16)nkBlock);
            u32 nro = (u32)0;
            for (u32 i = (u32)0; i < caps.count(); i = i + (u32)1) {
                String* cn = (String*)caps.get(i);
                String* t = (String*)frameTypes.get((Hashable*)cn);
                if (t == (String*)0 || (t.indexOfByte((u8)'[') == (u32)$FFFFFFFF && Parser.parPrimPointee(t) == (String*)0
                                        && parStructPointee(t) == (String*)0)
                    || !Parser.parReadsOnly(frame, cn))
                    continue;
                Node* n = mk((u16)nkIf);
                n.add(parBin("==", parIdent(String.withCString("__par_k")),
                             parCast(String.withCString("i32"), parInt((i64)i))));
                Node* then = mk((u16)nkBlock);
                Node* ret = mk((u16)nkReturn);
                Node* tv = mk((u16)nkBool);
                tv.setNum((i64)1);
                ret.add(tv);
                then.add(ret);
                n.add(then);
                bro.add(n);
                nro = nro + (u32)1;
            }
            if (nro > (u32)0) {
                Node* rf = mk((u16)nkReturn);
                Node* fv = mk((u16)nkBool);
                fv.setNum((i64)0);
                rf.add(fv);
                bro.add(rf);
                Node* mr = mkNamed((u16)nkMethodDecl, String.withCString("gpuReadsOnly"));
                mr.setOp(String.withCString("bool"));
                Node* pr = mkNamed((u16)nkParam, String.withCString("__par_k"));
                pr.setOp(String.withCString("i32"));
                mr.add(pr);
                mr.add(bro);
                cls.add(mr);
            }
            // gpuWritesAllOwn(k): own ivar k is a captured array (or a
            // pointer to one) the body overwrites whole in its range, the
            // shape gpuWritesAll takes for a global (the reference explains).
            Map* wrefs = (Map*)frame.get((Hashable*)String.withCString("refs"));
            bool mayWallOwn = gridDecls.count() == (u32)0 && frame.get((Hashable*)String.withCString("exits")) == (Object*)0
                && !written.contains((Hashable*)iv.name()) && wrefs != (Map*)0;
            Node* woBody = loop.kid((u32)3);
            Node* bwo = mk((u16)nkBlock);
            u32 nwo = (u32)0;
            for (u32 i = (u32)0; i < caps.count(); i = i + (u32)1) {
                String* cn = (String*)caps.get(i);
                String* t = (String*)frameTypes.get((Hashable*)cn);
                Number* cr = wrefs != (Map*)0 ? (Number*)wrefs.get((Hashable*)cn) : (Number*)0;
                bool wall = false;
                // The loop's statements: its block's, or the one statement of
                // a loop written without braces (as the reference).
                bool woBlock = woBody != (Node*)0 && woBody.kind() == (u16)nkBlock;
                u32 woCount = woBody == (Node*)0 ? (u32)0 : (woBlock ? woBody.kidCount() : (u32)1);
                if (mayWallOwn && t != (String*)0
                    && (t.indexOfByte((u8)'[') != (u32)$FFFFFFFF || Parser.parPrimPointee(t) != (String*)0) && cr != (Number*)0
                    && cr.asU32() == (u32)1)
                    for (u32 si = (u32)0; si < woCount; si = si + (u32)1) {
                        Node* st = woBlock ? woBody.kid(si) : woBody;
                        if (st == (Node*)0 || st.kind() != (u16)nkExprStatement || st.kidCount() == (u32)0) continue;
                        Node* as = st.kid((u32)0);
                        if (as.kind() != (u16)nkAssign || !Parser._same(as.op(), "=")) continue;
                        Node* sub = as.kid((u32)0);
                        if (sub.kind() != (u16)nkSubscript || sub.kidCount() < (u32)2) continue;
                        if (sub.kid((u32)0).kind() == (u16)nkIdent && sub.kid((u32)0).name().equals(cn)
                            && sub.kid((u32)1).kind() == (u16)nkIdent && sub.kid((u32)1).name().equals(iv.name()))
                            wall = true;
                    }
                if (!wall)
                    continue;
                Node* n = mk((u16)nkIf);
                n.add(parBin("==", parIdent(String.withCString("__par_k")),
                             parCast(String.withCString("i32"), parInt((i64)i))));
                Node* then = mk((u16)nkBlock);
                Node* ret = mk((u16)nkReturn);
                Node* tv = mk((u16)nkBool);
                tv.setNum((i64)1);
                ret.add(tv);
                then.add(ret);
                n.add(then);
                bwo.add(n);
                nwo = nwo + (u32)1;
            }
            if (nwo > (u32)0) {
                Node* rf = mk((u16)nkReturn);
                Node* fv = mk((u16)nkBool);
                fv.setNum((i64)0);
                rf.add(fv);
                bwo.add(rf);
                Node* mw = mkNamed((u16)nkMethodDecl, String.withCString("gpuWritesAllOwn"));
                mw.setOp(String.withCString("bool"));
                Node* pw = mkNamed((u16)nkParam, String.withCString("__par_k"));
                pw.setOp(String.withCString("i32"));
                mw.add(pw);
                mw.add(bwo);
                cls.add(mw);
            }
        }
        // gpuGlobal(name) / gpuGlobalBytes(name): where each global the body
        // uses lives and how big it is, by the name the Metal kernel's header
        // gives it. The runtime copies each one in and back, as a buffer.
        {
            Array* globs = new Array();
            Array* outer = (Array*)frame.get((Hashable*)String.withCString("outer"));
            if (outer != (Array*)0 && _parTopVars != (Map*)0)
                for (u32 i = (u32)0; i < outer.count(); i = i + (u32)1) {
                    if (_parTopVars.get((Hashable*)outer.get(i)) == (Object*)0)
                        continue;
                    // An array reduction's global: the body reaches it
                    // through the chunk's pointer, never by name.
                    bool arr = false;
                    for (u32 q = (u32)0; q < reds.count(); q = q + (u32)1)
                        if (((Node*)reds.get(q)).num() != (i64)0 && ((Node*)reds.get(q)).name().equals((String*)outer.get(i)))
                            arr = true;
                    if (!arr)
                        globs.add(outer.get(i));
                }
            Node* ma = mkNamed((u16)nkMethodDecl, String.withCString("gpuGlobal"));
            ma.setOp(String.withCString("pointer"));
            Node* pa = mkNamed((u16)nkParam, String.withCString("__par_name"));
            pa.setOp(String.withCString("u8*"));
            ma.add(pa);
            Node* ba = mk((u16)nkBlock);
            Node* mb = mkNamed((u16)nkMethodDecl, String.withCString("gpuGlobalBytes"));
            mb.setOp(String.withCString("i64"));
            Node* pb = mkNamed((u16)nkParam, String.withCString("__par_name"));
            pb.setOp(String.withCString("u8*"));
            mb.add(pb);
            Node* bb = mk((u16)nkBlock);
            Node* bw = mk((u16)nkBlock);
            u32 nwall = (u32)0;
            Node* brg = mk((u16)nkBlock);
            u32 nrg = (u32)0;
            Map* refs = (Map*)frame.get((Hashable*)String.withCString("refs"));
            bool mayWall = gridDecls.count() == (u32)0 && frame.get((Hashable*)String.withCString("exits")) == (Object*)0
                && !written.contains((Hashable*)iv.name()) && refs != (Map*)0;
            Node* loopBody = loop.kid((u32)3);
            for (u32 i = (u32)0; i < globs.count(); i = i + (u32)1) {
                String* g = (String*)globs.get(i);
                String* gt = (String*)_parTopVars.get((Hashable*)g);
                // gpuWritesAll(name): the body overwrites every element of this
                // array in its range (the reference explains; bug 645).
                Number* gr = refs != (Map*)0 ? (Number*)refs.get((Hashable*)g) : (Number*)0;
                bool wall = false;
                if (mayWall && gt.indexOfByte((u8)'[') != (u32)$FFFFFFFF && gr != (Number*)0 && gr.asU32() == (u32)1
                    && loopBody != (Node*)0 && loopBody.kind() == (u16)nkBlock)
                    for (u32 si = (u32)0; si < loopBody.kidCount(); si = si + (u32)1) {
                        Node* st = loopBody.kid(si);
                        if (st == (Node*)0 || st.kind() != (u16)nkExprStatement || st.kidCount() == (u32)0) continue;
                        Node* as = st.kid((u32)0);
                        if (as.kind() != (u16)nkAssign || !Parser._same(as.op(), "=")) continue;
                        Node* sub = as.kid((u32)0);
                        if (sub.kind() != (u16)nkSubscript || sub.kidCount() < (u32)2) continue;
                        if (sub.kid((u32)0).kind() == (u16)nkIdent && sub.kid((u32)0).name().equals(g)
                            && sub.kid((u32)1).kind() == (u16)nkIdent && sub.kid((u32)1).name().equals(iv.name()))
                            wall = true;
                    }
                if (gt.indexOfByte((u8)'[') != (u32)$FFFFFFFF && Parser.parReadsOnly(frame, g)) {
                    Node* ifR = mk((u16)nkIf);
                    ifR.add(parSameNameCall(g));
                    Node* thenR = mk((u16)nkBlock);
                    Node* retR = mk((u16)nkReturn);
                    Node* rv = mk((u16)nkBool);
                    rv.setNum((i64)1);
                    retR.add(rv);
                    thenR.add(retR);
                    ifR.add(thenR);
                    brg.add(ifR);
                    nrg = nrg + (u32)1;
                }
                if (wall) {
                    Node* ifW = mk((u16)nkIf);
                    ifW.add(parSameNameCall(g));
                    Node* thenW = mk((u16)nkBlock);
                    Node* retW = mk((u16)nkReturn);
                    Node* tv = mk((u16)nkBool);
                    tv.setNum((i64)1);
                    retW.add(tv);
                    thenW.add(retW);
                    ifW.add(thenW);
                    bw.add(ifW);
                    nwall = nwall + (u32)1;
                }
                Node* target = parIdent(g);
                if (gt.indexOfByte((u8)'[') != (u32)$FFFFFFFF) {
                    Node* sub = mk((u16)nkSubscript);
                    sub.add(parIdent(g));
                    sub.add(parInt((i64)0));
                    target = sub;
                }
                Node* addr = mkNamed((u16)nkUnary, String.withCString("&"));
                addr.setOp(String.withCString("&"));
                addr.add(target);
                Node* ifA = mk((u16)nkIf);
                ifA.add(parSameNameCall(g));
                Node* thenA = mk((u16)nkBlock);
                Node* retA = mk((u16)nkReturn);
                retA.add(parCast(String.withCString("pointer"), addr));
                thenA.add(retA);
                ifA.add(thenA);
                ba.add(ifA);
                // count * sizeof(element), not sizeof(g): sizeof is a u16, so
                // a global over 64 KB would come out wrapped (bug 615).
                Node* sz = mk((u16)nkSizeof);
                sz.setName(String.withCString("-"));
                sz.add(parIdent(g));
                Node* bytes = parCast(String.withCString("i64"), sz);
                u32 lb = gt.indexOfByte((u8)'[');
                if (lb != (u32)$FFFFFFFF) {
                    i64 count = (i64)0;
                    for (u32 q = lb + (u32)1; q < gt.byteLength() && gt.byteAt(q) >= (u8)'0' && gt.byteAt(q) <= (u8)'9'; q = q + (u32)1)
                        count = count * (i64)10 + (i64)(gt.byteAt(q) - (u8)'0');
                    if (count > (i64)0) {
                        Node* esz = mk((u16)nkSizeof);
                        esz.setName(gt.substringBytes((u32)0, lb));
                        bytes = parBin("*", parCast(String.withCString("i64"), parInt(count)),
                                       parCast(String.withCString("i64"), esz));
                    }
                }
                Node* ifB = mk((u16)nkIf);
                ifB.add(parSameNameCall(g));
                Node* thenB = mk((u16)nkBlock);
                Node* retB = mk((u16)nkReturn);
                retB.add(bytes);
                thenB.add(retB);
                ifB.add(thenB);
                bb.add(ifB);
            }
            Node* noneA = mk((u16)nkReturn);
            noneA.add(parCast(String.withCString("pointer"), parInt((i64)0)));
            ba.add(noneA);
            ma.add(ba);
            cls.add(ma);
            Node* noneB = mk((u16)nkReturn);
            noneB.add(parBin("-", parCast(String.withCString("i64"), parInt((i64)0)),
                             parCast(String.withCString("i64"), parInt((i64)1))));
            bb.add(noneB);
            mb.add(bb);
            cls.add(mb);
            if (nrg > (u32)0) {
                Node* noneR = mk((u16)nkReturn);
                Node* fr = mk((u16)nkBool);
                fr.setNum((i64)0);
                noneR.add(fr);
                brg.add(noneR);
                Node* mg = mkNamed((u16)nkMethodDecl, String.withCString("gpuReadsOnlyGlobal"));
                mg.setOp(String.withCString("bool"));
                Node* pg = mkNamed((u16)nkParam, String.withCString("__par_name"));
                pg.setOp(String.withCString("u8*"));
                mg.add(pg);
                mg.add(brg);
                cls.add(mg);
            }
            if (nwall > (u32)0) {
                Node* noneW = mk((u16)nkReturn);
                Node* fv = mk((u16)nkBool);
                fv.setNum((i64)0);
                noneW.add(fv);
                bw.add(noneW);
                Node* mw = mkNamed((u16)nkMethodDecl, String.withCString("gpuWritesAll"));
                mw.setOp(String.withCString("bool"));
                Node* pw = mkNamed((u16)nkParam, String.withCString("__par_name"));
                pw.setOp(String.withCString("u8*"));
                mw.add(pw);
                mw.add(bw);
                cls.add(mw);
            }
        }
        // parName(): what the block is called at run time (its device
        // setting, reports): its source name, or file:line when unnamed.
        {
            Node* m = mkNamed((u16)nkMethodDecl, String.withCString("parName"));
            m.setOp(String.withCString("u8*"));
            Node* b = mk((u16)nkBlock);
            String* nm = (String*)0;
            if (parName != (String*)0)
                nm = String.withString(parName);
            else {
                String* file = (_parTok != (Token*)0 && _parTok.file() != (String*)0) ? _parTok.file() : String.withCString("?");
                u32 cut = (u32)0;
                for (u32 q = (u32)0; q < file.byteLength(); q = q + (u32)1)
                    if (file.byteAt(q) == (u8)'/') cut = q + (u32)1;
                nm = file.substringBytes(cut, file.byteLength() - cut);
                nm.appendByte((u8)':');
                nm.append(String.withU32(_parTok != (Token*)0 ? _parTok.line() : (u32)0));
            }
            Node* ret = mk((u16)nkReturn);
            ret.add(mkNamed((u16)nkStr, nm));
            b.add(ret);
            m.add(b);
            cls.add(m);
        }
        // defaultDevice(): the block's :device(…), only when it has one;
        // ParChunk's own returns 0. As the reference.
        {
            Number* dv = (Number*)frame.get((Hashable*)String.withCString("device"));
            // A block with no :device takes --par-style's (threads: the CPU, gpu: the GPU).
            u32 dcode = dv != (Number*)0 ? dv.asU32() : _parDeviceDefault;
            if (dcode != (u32)0) {
                Node* m = mkNamed((u16)nkMethodDecl, String.withCString("defaultDevice"));
                m.setOp(String.withCString("i32"));
                Node* b = mk((u16)nkBlock);
                Node* ret = mk((u16)nkReturn);
                ret.add(parInt((i64)dcode));
                b.add(ret);
                m.add(b);
                cls.add(m);
            }
        }
        // runsOnce(): true for a block that runs once per program run; only
        // for those. As the reference.
        if (frame.get((Hashable*)String.withCString("once")) != (Object*)0) {
            Node* m = mkNamed((u16)nkMethodDecl, String.withCString("runsOnce"));
            m.setOp(String.withCString("bool"));
            Node* b = mk((u16)nkBlock);
            Node* ret = mk((u16)nkReturn);
            Node* t = mk((u16)nkBool);
            t.setNum((i64)1);
            ret.add(t);
            b.add(ret);
            m.add(b);
            cls.add(m);
        }
        // gpuSource(): the kernel's GPU source. A placeholder string, unique
        // per block, that the lowering replaces with the printed kernel (or
        // with "" when the block cannot run on the GPU); `__XC_PAR_FAST_<n>__`
        // for a block whose goal is speed (the default), whose kernel may use
        // fast maths.
        {
            Node* m = mkNamed((u16)nkMethodDecl, String.withCString("gpuSource"));
            m.setOp(String.withCString("u8*"));
            Node* b = mk((u16)nkBlock);
            String* tag = String.withCString(frame.get((Hashable*)String.withCString("fast")) != 0 ? "__XC_PAR_FAST_" : "__XC_PAR_MSL_");
            tag.append(String.withU32(counter));
            tag.appendCString("__");
            // …then each reduction as `<field>=<op>;` (bug 645), so the kernel
            // can combine them on the device: field 0 is the object header, 1
            // and 2 lo and hi, then the captures, then the reductions in order.
            // …and `auto;` for a block --par-style=auto made from a plain loop:
            // par-check then demotes it to a serial run where it would have
            // refused a written one.
            if (frame.get((Hashable*)String.withCString("auto")) != 0)
                tag.appendCString("auto;");
            // …and `scan;` for a pass of a rewritten :scan (#144): par-check
            // takes its chunks as apart, and it stays on the CPU.
            if (frame.get((Hashable*)String.withCString("scanpass")) != 0)
                tag.appendCString("scan;");
            // An array reduction is `a<field>=<op>:<elements>;`: the Metal
            // printer sizes the kernel's threadgroup copy of the array from it.
            for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1) {
                Node* r = (Node*)reds.get(i);
                if (r.num() != (i64)0) tag.appendCString("a");
                tag.append(String.withU32((u32)3 + caps.count() + i));
                tag.appendCString("=");
                tag.append(r.op());
                if (r.num() != (i64)0) {
                    i64 code = Parser.parArrCode((String*)redTypes.get((Hashable*)r.name()), r.op());
                    tag.appendCString(":");
                    tag.append(String.withI64((code >> (i64)8) / (code & (i64)15)));
                }
                tag.appendCString(";");
            }
            // …and `c<field>;` for each :constant capture (the Metal printer
            // binds it in the constant address space).
            for (u32 i = (u32)0; i < constants.count(); i = i + (u32)1) {
                String* cn = (String*)constants.get(i);
                for (u32 q = (u32)0; q < caps.count(); q = q + (u32)1)
                    if (((String*)caps.get(q)).equals(cn)) {
                        tag.appendCString("c");
                        tag.append(String.withU32((u32)3 + q));
                        tag.appendCString(";");
                    }
            }
            // …and a grid's width and height when they are constants (the
            // reference explains).
            Array* gridExprs = (Array*)frame.get((Hashable*)String.withCString("grid"));
            if (gridExprs != (Array*)0 && gridExprs.count() >= (u32)2) {
                bool okW = false;
                bool okH = false;
                i64 gw = Parser.parFoldConstant((Node*)gridExprs.get((u32)0), &okW);
                i64 gh = Parser.parFoldConstant((Node*)gridExprs.get((u32)1), &okH);
                if (okW && okH && gw > (i64)0 && gh > (i64)0) {
                    tag.appendCString("gw=");
                    tag.append(String.withI64(gw));
                    tag.appendCString(";gh=");
                    tag.append(String.withI64(gh));
                    tag.appendCString(";");
                }
            }
            Node* ret = mk((u16)nkReturn);
            ret.add(mkNamed((u16)nkStr, tag));
            b.add(ret);
            m.add(b);
            cls.add(m);
        }
        // merge(other): fold another chunk's reductions into this one's.
        {
            Node* m = mkNamed((u16)nkMethodDecl, String.withCString("merge"));
            m.setOp(String.withCString("void"));
            Node* p = mkNamed((u16)nkParam, String.withCString("__par_other"));
            p.setOp(String.withCString("ParChunk*"));
            m.add(p);
            Node* b = mk((u16)nkBlock);
            // The downcast only when there is something to fold: an unused
            // `o` reads as a never-used local to the analyser (-Wanalyze).
            if (reds.count() > (u32)0) {
                Node* o = mkNamed((u16)nkVariableDecl, String.withCString("__par_o"));
                o.setOp(implPtr);
                o.add(parCast(implPtr, parIdent(String.withCString("__par_other"))));
                b.add(o);
            }
            for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1) {
                Node* r = (Node*)reds.get(i);
                // An array reduction: the other chunk's copy folded into
                // this one's array, and freed.
                if (r.num() != (i64)0) {
                    String* u8p = String.withCString("u8*");
                    Node* call = mkNamed((u16)nkMethodCall, String.withCString("arrMerge"));
                    call.add(parIdent(String.withCString("ParFnChunk")));
                    call.add(parCast(u8p, parMember(String.withCString("self"), Parser.parFieldOf(r.name()))));
                    call.add(parCast(u8p, parMember(String.withCString("__par_o"), Parser.parFieldOf(r.name()))));
                    call.add(parCast(String.withCString("i64"), parInt(Parser.parArrCode((String*)redTypes.get((Hashable*)r.name()), r.op()))));
                    call.setNum((i64)3);
                    b.add(parStmt(call));
                    continue;
                }
                b.add(parFold(r.op(), parFieldRef(r.name()), parFieldRef(r.name()),
                              parMember(String.withCString("__par_o"), Parser.parFieldOf(r.name()))));
            }
            m.add(b);
            cls.add(m);
        }
        _blkClasses.add((Object*)cls);

        // The site.
        String* pv = String.withCString("$par");
        pv.append(String.withU32(counter));
        Node* site = mk((u16)nkBlock);
        for (u32 i = (u32)0; i < gridDecls.count(); i = i + (u32)1) site.add((Node*)gridDecls.get(i));
        // A loop --par-style made a block of keeps the loop as written beside
        // it: the site runs `if (Par.kept(n)) { the block } else { the loop }`,
        // and par-check, which decides, puts its answer in place of the call,
        // so a demoted block costs nothing and its loop is built as
        // --par-style=cpu builds it. A grid of more points than its u32 index
        // counts runs the loop too. As the reference.
        Node* plain = (Node*)frame.get((Hashable*)String.withCString("plain"));
        Node* outer = site;
        if (plain != (Node*)0)
            site = mk((u16)nkBlock);
        Node* pd = mkNamed((u16)nkVariableDecl, pv);
        pd.setOp(implPtr);
        Node* nw = mkNamed((u16)nkNew, implName);
        nw.setNum((i64)0);
        pd.add(nw);
        site.add(pd);
        for (u32 i = (u32)0; i < caps.count(); i = i + (u32)1) {
            String* cn = (String*)caps.get(i);
            String* t = (String*)frameTypes.get((Hashable*)cn);
            Node* v = parIdent(cn);
            if (t.indexOfByte((u8)'[') != (u32)$FFFFFFFF) {
                Node* sub = mk((u16)nkSubscript);
                sub.add(parIdent(cn));
                sub.add(parInt((i64)0));
                Node* addr = mkNamed((u16)nkUnary, String.withCString("&"));
                addr.setOp(String.withCString("&"));
                addr.add(sub);
                v = addr;
            }
            site.add(parAssign(parMember(pv, Parser.parFieldOf(cn)), v));
            blkNoteUse(cn);
            if (_pfwNoted != (Array*)0) _pfwNoted.add((Object*)cn);
        }
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1) {
            Node* r = (Node*)reds.get(i);
            // An array reduction's own chunk updates the array itself.
            if (r.num() != (i64)0) {
                Node* sub = mk((u16)nkSubscript);
                sub.add(parIdent(r.name()));
                sub.add(parInt((i64)0));
                Node* addr = mkNamed((u16)nkUnary, String.withCString("&"));
                addr.setOp(String.withCString("&"));
                addr.add(sub);
                site.add(parAssign(parMember(pv, Parser.parFieldOf(r.name())), addr));
                blkNoteUse(r.name());
                if (_pfwNoted != (Array*)0) _pfwNoted.add((Object*)r.name());
                continue;
            }
            site.add(parAssign(parMember(pv, Parser.parFieldOf(r.name())),
                               parStart(r.op(), (String*)redTypes.get((Hashable*)r.name()), parIdent(r.name()))));
            blkNoteUse(r.name());
            if (_pfwNoted != (Array*)0) _pfwNoted.add((Object*)r.name());
        }
        Node* hi = cond.kid((u32)1);
        if (Parser._same(cond.op(), "<=")) hi = parBin("+", parCast(String.withCString("i64"), hi), parInt((i64)1));
        Node* call = mkNamed((u16)nkMethodCall, String.withCString("run"));
        call.add(parIdent(String.withCString("Par")));
        call.add(parIdent(pv));
        call.add(parCast(String.withCString("i64"), iv.kid((u32)0)));
        call.add(parCast(String.withCString("i64"), hi));
        call.setNum((i64)3);
        site.add(parStmt(call));
        for (u32 i = (u32)0; i < reds.count(); i = i + (u32)1) {
            Node* r = (Node*)reds.get(i);
            if (r.num() != (i64)0) continue;
            if (parIdem(r.op())) site.add(parAssign(parIdent(r.name()), parMember(pv, Parser.parFieldOf(r.name()))));
            else site.add(parFold(r.op(), parIdent(r.name()), parIdent(r.name()), parMember(pv, Parser.parFieldOf(r.name()))));
        }
        if (plain == (Node*)0)
            return site;
        Node* kept = mkNamed((u16)nkMethodCall, String.withCString("kept"));
        kept.add(parIdent(String.withCString("Par")));
        kept.add(parCast(String.withCString("u32"), parInt((i64)counter)));
        kept.setNum((i64)1);
        Array* grid = (Array*)frame.get((Hashable*)String.withCString("grid"));
        if (grid != (Array*)0) {
            String* i64T = String.withCString("i64");
            Node* points = parBin("*", parCast(i64T, parIdent(String.withCString("par$w"))),
                                  parCast(i64T, parIdent(String.withCString("par$h"))));
            if (grid.count() == (u32)3)
                points = parBin("*", points, parCast(i64T, parIdent(String.withCString("par$d"))));
            kept = parBin("&&", kept, parBin("<=", points, parInt((i64)4294967295)));
        }
        Node* pick = mk((u16)nkIf);
        pick.add(kept);
        pick.add(site);
        pick.add(plain);
        outer.add(pick);
        return outer;
    }

    Node* parseStatementInner(bool inList)
    {
        // `par` is a CONTEXTUAL keyword — library code uses it as a name
        // (`u32* par = …; par[i] = …`) — so it starts a block only when what
        // follows can only be one: `{`, a decorator `:`, or a name and then
        // either. As the reference.
        if (check((u16)tokIdentifier) && cur().value().equals(String.withCString("par"))
            && (checkAt((u32)1, (u16)tokLBrace) || checkAt((u32)1, (u16)tokColon)
                || (checkAt((u32)1, (u16)tokIdentifier)
                    && (checkAt((u32)2, (u16)tokLBrace) || checkAt((u32)2, (u16)tokColon)))))
            return parsePar();
        if (check((u16)tokIf))       return parseIf();
        // A loop that --par-style=auto looks at because no loop is open: the
        // loop around it, parsed again as a block's, would see one (parAutoFor).
        if ((check(tokWhile) || check(tokFor)) && _parAuto && _loopDepth == 0)
            _parAutoDepthReads = _parAutoDepthReads + 1;
        // --par-style=auto: a counted while loop becomes the `for` it amounts to,
        // which parAutoFor then takes or leaves (parAutoWhileShape).
        // Without the par runtime parAutoFor leaves the loop and asks for
        // Par.xc to be imported (the front end parses again).
        if (check((u16)tokWhile) && _parAuto && _loopDepth == (u32)0
            && (_blkFrames.count() == (u32)0
                || ((Map*)_blkFrames.get(_blkFrames.count() - 1)).get((Hashable*)String.withCString("par")) == (Object*)0)) {
            Token* wt = cur();
            _parAutoWhy = (String*)0;
            if (parAutoWhileShape()) {
                _parAutoFromWhile = true;
                Array* bound = _tokens.subarray(_pwAt + 4, _pwPe + 1 - (_pwAt + 4));
                String* v = _pwV;
                Token* cmp = (Token*)_tokens.get(_pwAt + 3);
                Node* f = parAutoFor();
                pwSetPending(v, bound, cmp, wt);
                if (inList) return f;
                // The body of an if, else or loop: the `for` and its `if`
                // are one statement, a block, which the walk reads as the
                // `while` (plSiteWalk).
                Node* g = pwTakePending();
                Node* one = mk(nkBlock);
                one.setPos(wt.fileId(), wt.line(), wt.col());
                if (f != (Node*)0) one.add(f);
                one.add(g);
                Array* site = plSite(f);
                if (site != (Array*)0)
                    plRegister(one, 4, (Node*)site.get(2), (Array*)0, ((Number*)site.get(4)).asU32());
                return one;
            }
            String* wwhy = _parAutoWhy != (String*)0 ? _parAutoWhy : String.withCString("while-shape");
            parAutoTraceLine(wt, "serial", wwhy, String.withCString("while"), (String*)0, (String*)0, 0, (String*)0);
            parGridEnter("loops", true);
            _loopDepth = _loopDepth + 1;
            Node* wn = parseWhile();
            _loopDepth = _loopDepth - 1;
            parGridEnter("loops", false);
            return wn;
        }
        if (check((u16)tokWhile))    { parGridEnter("loops", true); _loopDepth = _loopDepth + (u32)1; Node* n = parseWhile(); _loopDepth = _loopDepth - (u32)1; parGridEnter("loops", false); return n; }
        if (check((u16)tokFor)) {
            // --par-style=auto: an outermost loop in plain code may become a par block —
            // inside a block literal too, but not inside a par body (the reference explains).
            if (_parAuto && _loopDepth == (u32)0
                && (_blkFrames.count() == (u32)0
                    || ((Map*)_blkFrames.get(_blkFrames.count() - (u32)1)).get((Hashable*)String.withCString("par")) == (Object*)0))
                return parAutoFor();
            parGridEnter("loops", true); _loopDepth = _loopDepth + (u32)1; Node* n = parseFor(); _loopDepth = _loopDepth - (u32)1; parGridEnter("loops", false); return n;
        }
        if (check((u16)tokSwitch))   { parGridEnter("switches", true); Node* n = parseSwitch(); parGridEnter("switches", false); return n; }
        if (check(tokReturn))   { Token* rt = cur(); return parGridReturn(parseReturn(), rt); }
        // `defer` takes a BLOCK, as the reference requires: braces keep what
        // is deferred unambiguous, and leave `defer <statement>` free to mean
        // something later. A bare statement was accepted here (bug 596).
        if (check((u16)tokDefer)) {
            advance();
            if (!check((u16)tokLBrace)) {
                _error(String.withCString("'defer' wants a block: defer { ... }"));
                return (Node*)0;
            }
            Node* d = mk((u16)nkDefer);
            d.add(parseBlockOrStatement());
            return d;
        }
        if (check((u16)tokThrow))    { advance(); Node* t = mk((u16)nkThrow); t.add(parseExpression()); expect((u16)tokSemicolon); return t; }
        if (check((u16)tokTry))      return parseTry();
        if (check((u16)tokAsm))      return parseAsmBlock();
        if (check((u16)tokTypedef))  return parseTypedef();
        if (check((u16)tokStruct))   return parseStruct(true);
        if (check((u16)tokEnum))     return parseEnum();
        if (check(tokBreak))    { Token* bt = cur(); advance(); expect(tokSemicolon); parGridBreak(bt); return mk(nkBreak); }
        if (check(tokContinue)) { advance(); expect(tokSemicolon); return mk(nkContinue); }
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
                // Positioned at the keyword, as the reference reports it.
                d.setPos(kw.fileId(), kw.line(), kw.col());
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
        // To the closing paren, however many targets (#334: 33 or more were
        // refused), as the reference.
        while (true) {
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
        // A declared target is a local of the enclosing block from here on, as
        // a plain declaration is once its initialiser has been parsed: a block
        // or `par` body that reads it captures it, which needs the binding.
        for (u32 i = (u32)0; i + (u32)1 < n.kidCount(); i = i + (u32)1) {
            Node* t = n.kid(i);
            if (t != (Node*)0 && t.kind() == (u16)nkVariableDecl) blkBind(t.name(), t.op(), (Array*)0);
        }
        return n;
    }

    bool looksLikeRefopCall(void)
    {
        if (!checkAt((u32)1, (u16)tokLParen)) return false;
        if (checkAt((u32)2, (u16)tokRParen)) return true;   // `f()` — a call
        u32 depth = (u32)1;
        u32 i = (u32)2;
        bool sawTopComma = false;
        while (true) {
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
        // The reference builds the FIRST declarator (and a constructor's
        // init call, and the wrapper) at the statement's start; -g reads it.
        Token* startTok = cur();
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
                                                blkDeclParams, name, startTok);
                if (lit != 0) v.add(lit);
                blockBodyInit = true;
            } else if (match((u16)tokAssign)) {
                v.add(stringInitForArray(vty, parseInitialiser()));
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
        if (first != 0) first.setStmtPos(startTok.fileId(), startTok.line(), startTok.col());

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
            st.setStmtPos(startTok.fileId(), startTok.line(), startTok.col());
            st.addSrc(SRC_SYNTH);
            b.add(st);
            b.setStmtPos(startTok.fileId(), startTok.line(), startTok.col());
            return b;
        }

        if (decls.count() == (u32)1) return first;
        // Several declarators share one type: the original wraps them in a
        // block marked isDeclList, and so does this.
        Node* b = mk((u16)nkBlock);
        b.addFlag((u32)NF_DECLLIST);
        for (u32 i = (u32)0; i < decls.count(); i = i + (u32)1) b.add((Node*)decls.get(i));
        b.setStmtPos(startTok.fileId(), startTok.line(), startTok.col());
        return b;
    }

    // `u8 name[8] = "ABCDEFG";` — a string literal initialising an array of
    // bytes is the list of its bytes and a NUL, as C reads it. Left as the
    // literal it stored the POINTER's bytes into the array (both compilers,
    // the Base64 alphabet), so it is rewritten here, where the declared
    // type is known; an unsized array then takes its size from the list.
    Node* stringInitForArray(String* vty, Node* init)
    {
        if (init == (Node*)0 || init.kind() != (u16)nkStr) return init;
        u32 lb = vty.indexOfByte((u8)'[');
        if (lb == String.notFound() || !vty.hasSuffix(String.withCString("]"))) return init;
        String* elem = vty.substringBytes((u32)0, lb);
        if (!Parser._same(elem, "u8") && !Parser._same(elem, "i8")) return init;
        Node* list = mk((u16)nkBlock);
        String* s = init.name();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            list.add(parInt((i64)s.byteAt(i)));
        list.add(parInt((i64)0));
        return list;
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
        if (match(tokElse)) n.add(parseBlockOrStatement());
        return n;
    }

    Node* parseWhile(void)
    {
        advance();
        Node* n = mk((u16)nkWhile);
        // The goal of the loop or block around it, else the file's or the
        // build's: a while loop has no annotation of its own.
        goalFlags(n, loopGoal((u32)0));
        expect((u16)tokLParen);
        n.add(parseExpression());
        expect((u16)tokRParen);
        n.add(parseBlockOrStatement());
        return n;
    }

    // Both loop forms: `for (v in coll)` and the C-style triple.
    Node* parseFor(void)
    {
        // -g: the reference builds a declared loop variable at the `for`.
        Token* forTok = cur();
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
            bool typed = looksLikeType() && !checkAt(1, tokIn);
            if (typed) ty = parseTypeSpelling();
            Token* v = expect((u16)tokIdentifier);
            String* vname = (v == 0) ? String.withCString("_") : v.value();
            u32 inAt = _pos;
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
                bool stepBad = false;
                bool stepped = check(tokIdentifier) && Parser._same(cur().value(), "step");
                if (stepped) {
                    advance();
                    stepBad = !check((u16)tokIntLiteral) || Parser._same(cur().value(), "0");
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
                bool annotated = check(tokColon);
                u32 rangeAnnots = parseLoopAnnotations();
                u32 rangeGoal = loopGoal(rangeAnnots);
                // The loop variable is a local of the body: a block literal or
                // a `par` inside it captures it like any other.
                blkPushScope();
                blkBind(vname, ty.equals(String.withCString("-")) ? (String*)0 : ty, (Array*)0);
                u32 savedGoal = _goalNow;
                _goalNow = rangeGoal;
                bool braced = check(tokLBrace);
                Node* body = parseBlockOrStatement();
                _goalNow = savedGoal;
                blkPopScope();

                Node* n = mk((u16)nkForCStyle);
                Node* initMark = mk((u16)nkMarkerInit);
                Node* decl = mkNamed((u16)nkVariableDecl, vname);
                decl.setOp(ty);
                decl.add(collection);                    // the start bound
                decl.setStmtPos(forTok.fileId(), forTok.line(), forTok.col());
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
                loopAnnotationFlags(n, rangeAnnots, rangeGoal);
                n.addSrc(SRC_RANGE);
                if (stepBad) n.addSrc(SRC_STEPBAD);
                if (parAutoDescends(inAt)) n.addSrc(SRC_DESC);
                if (typed && !stepped && !annotated && braced) n.addSrc(SRC_SCANFORM);
                return n;
            }

            Node* n = mk((u16)nkForIn);
            goalFlags(n, loopGoal((u32)0));
            Node* loopVar = mkNamed((u16)nkVariableDecl, vname);
            loopVar.setOp(ty);
            n.add(loopVar);
            n.add(collection);
            expect((u16)tokRParen);
            blkPushScope();
            blkBind(vname, ty.equals(String.withCString("-")) ? (String*)0 : ty, (Array*)0);
            n.add(parseBlockOrStatement());
            blkPopScope();
            return n;
        }

        Node* n = mk((u16)nkForCStyle);
        Node* initMark = mk((u16)nkMarkerInit);
        if (!check((u16)tokSemicolon)) {
            if (looksLikeType()) {
                Node* iv = parseVarDeclStatement();
                if (iv != 0) iv.setStmtPos(forTok.fileId(), forTok.line(), forTok.col());
                initMark.add(iv);
            } else {
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

        u32 annots = parseLoopAnnotations();
        u32 goal = loopGoal(annots);
        loopAnnotationFlags(n, annots, goal);
        u32 savedGoal = _goalNow;
        _goalNow = goal;
        n.add(parseBlockOrStatement());
        _goalNow = savedGoal;
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
    //
    // From 0.72 also `: goal(speed)` / `: goal(accuracy)`,
    // on both loop forms. Returns 1 for unroll, 2 speed, 4 accuracy, or'd.
    u32 parseLoopAnnotations(void)
    {
        u32 annots = (u32)0;
        if (!match((u16)tokColon)) return annots;
        while (check((u16)tokIdentifier)) {
            Token* tok = advance();
            if (tok != (Token*)0 && Parser._same(tok.value(), "unroll")) {
                annots = annots | (u32)1;
            } else if (tok != (Token*)0 && Parser._same(tok.value(), "serial")) {
                annots = annots | (u32)8;    // --par-style=auto leaves the loop alone (SRC_SERIAL)
            } else if (tok != (Token*)0 && Parser._same(tok.value(), "goal")) {
                annots = annots | 16;    // written on the loop (SRC_GOAL)
                expect((u16)tokLParen);
                Token* g = check((u16)tokIdentifier) ? advance() : (Token*)0;
                if (g != (Token*)0 && Parser._same(g.value(), "speed"))
                    annots = (annots & (u32)$FFFFFFFB) | (u32)2;
                else if (g != (Token*)0 && Parser._same(g.value(), "accuracy"))
                    annots = (annots & (u32)$FFFFFFFD) | (u32)4;
                else {
                    String* m = String.withCString("':goal' takes speed or accuracy, not '");
                    if (g != (Token*)0) m.append(g.value());
                    m.appendCString("'");
                    _errorAt(m, parTokNode(g != (Token*)0 ? g : tok));
                }
                expect((u16)tokRParen);
            } else if (tok != (Token*)0) {
                annots = annots | 32;    // SRC_ANNOT
                String* w = String.withCString("Unknown loop annotation '");
                w.append(tok.value());
                w.appendCString("'");
                warnAt(String.withCString("unknown-annotation"), w, tok);
            }
            if (!match((u16)tokComma)) break;
        }
        return annots;
    }

    // A loop's goal: its own, else the goal of the loop or block it sits in,
    // else the file's #goal, else -fgoal=; 0 for none (the built-in default,
    // accuracy). As the reference.
    u32 loopGoal(u32 annots)
    {
        if ((annots & (u32)2) != (u32)0) return (u32)1;
        if ((annots & (u32)4) != (u32)0) return (u32)2;
        return _goalNow != (u32)0 ? _goalNow : _goalDefault;
    }

    void loopAnnotationFlags(Node* n, u32 annots, u32 goal)
    {
        if ((annots & (u32)1) != (u32)0) n.addFlag((u32)NF_UNROLL);
        if ((annots & 8) != 0) n.addSrc(SRC_SERIAL);
        if ((annots & 16) != 0) n.addSrc(SRC_GOAL);
        if ((annots & 32) != 0) n.addSrc(SRC_ANNOT);
        goalFlags(n, goal);
    }

    void goalFlags(Node* n, u32 goal)
    {
        if (goal == (u32)1) n.addFlag((u32)NF_GOAL_SPEED);
        else if (goal == (u32)2) n.addFlag((u32)NF_GOAL_ACCURACY);
    }

    Node* parseReturn(void)
    {
        // v2 (task #29): returning a block that carries `block:` captures
        // hands the caller a write into this (dead) frame — checked below
        // after each value parses.
        Token* retTok = advance();
        Node* n = mk((u16)nkReturn);
        if (!check((u16)tokSemicolon)) {
            n.add(parseExpression());
            while (match((u16)tokComma)) n.add(parseExpression());
        }
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1) {
            if (blkIsWbValue(n.kid(i)))
                _errorAtTok(String.withCString("a block with `block:` captures cannot be returned — its write-back targets this frame. Write results into an object (an ivar, a box) instead"), retTok);
        }
        expect((u16)tokSemicolon);
        return n;
    }

    // `try { ... } catch (T e) { ... }` or `catch (e)`, as the reference
    // takes it: blocks only, at least one catch, and the binder one or two
    // identifiers (a type and a name, or a name) — `catch (Error* e)` and a
    // catch without parentheses were accepted here and refused there.
    Node* parseTry(void)
    {
        advance();
        Node* n = mk((u16)nkTry);
        if (!check((u16)tokLBrace)) {
            _error(String.withCString("'try' wants a block: try { ... } catch (e) { ... }"));
            return (Node*)0;
        }
        n.add(parseBlockOrStatement());
        if (!check((u16)tokCatch)) {
            _error(String.withCString("'try' must be followed by 'catch (name) { ... }'"));
            return (Node*)0;
        }
        while (check((u16)tokCatch)) {
            advance();
            Node* c = mk((u16)nkCatch);
            String* ty = String.withCString("-");
            expect((u16)tokLParen);
            if (!check((u16)tokIdentifier)) {
                _error(String.withCString("'catch' wants a binding name: catch (e) or catch (T e)"));
                return (Node*)0;
            }
            String* var = advance().value();
            if (check((u16)tokIdentifier)) {
                ty = var;
                var = advance().value();
            }
            expect((u16)tokRParen);
            if (!check((u16)tokLBrace)) {
                _error(String.withCString("'catch' wants a block"));
                return (Node*)0;
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
            while ((_pwPending || (!closeBlockAhead() && !check(tokEOF))) && !_fatal) {
                if (!_pwPending && (check(tokCase) || check(tokDefault))) {
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
                bool made = _pwPending;
                Node* s = parseListStatement();
                if (s != 0) {
                    if (current != 0) { current.add(s); caseHasBody = true; }
                    else                n.add(s);
                }
                if (_pos == before && !made) advance();
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
                // At its operator, where the reference puts an assignment
                // (a diagnostic about it points at the `=`).
                a.setPos(opTok.fileId(), opTok.line(), opTok.col());
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
                    rhs = blkParseLiteralBody(base, ret, declParams, (String*)0, opTok);
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

    // `*` is the pointer sigil. It is unambiguous despite also being multiply:
    // a sigil is a suffix in a TYPE or a prefix in an expression, and multiply
    // is infix, so the two never share a position. `@`, the old spelling, is
    // retired (#549): it still parses as a sigil, so the rest of the file reads
    // as meant, but each use is an error.
    bool isPointerSigil(u16 t)
    {
        return t == (u16)tokAt || t == (u16)tokStar;
    }

    void refuseAtSigil(Token* t)
    {
        if (t != (Token*)0 && t.type() == (u16)tokAt)
            _errorAtTok(String.withCString("'@' is no longer a pointer sigil: use * for pointers"), t);
    }

    bool matchPointerSigil(void)
    {
        if (!isPointerSigil(curType())) return false;
        refuseAtSigil(cur());
        advance();
        return true;
    }

    Node* parseUnary(void)
    {
        u16 t = curType();
        if (t == (u16)tokMinus || t == (u16)tokTilde || t == (u16)tokBang
            || t == (u16)tokAmpersand || isPointerSigil(t)
            || t == (u16)tokPlusPlus || t == (u16)tokMinusMinus
            || t == (u16)tokLess || t == (u16)tokByte3
            // Prefix `+` has no built-in meaning: it exists for a class that
            // defines `:operator(+self)`, and sema refuses it on anything else.
            || t == (u16)tokPlus) {
            Token* op = advance();
            refuseAtSigil(op);
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
            Node* opnd = parseUnary();
            n.add(opnd);
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
                Array* extra = (Array*)0;
                if (check((u16)tokDotDot) || check((u16)tokEllipsis)) {
                    inclusive = check((u16)tokEllipsis);
                    advance();
                    isSlice = true;
                    if (!check((u16)tokRBracket)) endE = parseExpression();
                } else {
                    startE = parseExpression();
                    // `m[i, j]`: more indices, for a class with an index
                    // operator taking several (`:operator(self[i, j])`).
                    while (check((u16)tokComma)) {
                        advance();
                        Node* more = parseExpression();
                        if (more == 0) break;
                        if (extra == 0) extra = new Array();
                        extra.add((Object*)more);
                    }
                    if (extra == 0 && (check((u16)tokDotDot) || check((u16)tokEllipsis))) {
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
                if (extra != 0)
                    for (u32 xi = 0; xi < extra.count(); xi++)
                        n.add((Node*)extra.get(xi));
                node = n;
            } else if (t == (u16)tokDot || t == (u16)tokArrow) {
                bool arrow = (t == (u16)tokArrow);
                Token* dotTok = advance();
                String* member = String.withCString("?");
                if (check((u16)tokIdentifier) || check((u16)tokRelease)
                    || check((u16)tokRetain) || check((u16)tokDelete)) {
                    member = advance().value();
                } else {
                    expect((u16)tokIdentifier);
                }
                Node* n = mkNamed((u16)nkMember, member);
                // At its `.`, where the reference puts a member access.
                n.setPos(dotTok.fileId(), dotTok.line(), dotTok.col());
                if (arrow) n.addFlag((u32)NF_ARROW);
                n.add(node);
                node = n;
            } else if (t == (u16)tokLParen) {
                // A call is placed where the reference places it: a call on
                // a NAME at the name, any other at its `(`. It was placed at
                // the `)`, so a diagnostic about the call pointed past it.
                Token* lpTok = cur();
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
                        n.addSrc(SRC_CALLED);
                    } else if (bInfo != 0 && blkBaseOf(bInfo) != 0) {
                        blkNoteUse(node.name());
                        n = mkNamed((u16)nkMethodCall, String.withCString("invoke"));
                        n.add(mkNamed((u16)nkIdent, node.name()));
                        n.addSrc(SRC_CALLED);
                    } else {
                        // A call through a function pointer that is a local or
                        // a parameter: a block body captures the pointer like
                        // any other name it reads (#437). As the reference.
                        if (bInfo != 0)
                            blkNoteUse(node.name());
                        blkNoteBareCall(node);
                        n = mkNamed((u16)nkCall, node.name());
                    }
                } else {
                    n = mkNamed((u16)nkCall, String.withCString("<indirect>"));
                }
                if (node.kind() == (u16)nkIdent)
                    n.setPos(node.fileId(), node.line(), node.col());
                else if (lpTok != 0)
                    n.setPos(lpTok.fileId(), lpTok.line(), lpTok.col());
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
                if (node.hasSrc(SRC_PAREN) && (node.kind() == nkIdent || node.kind() == nkMember)) n.addSrc(SRC_PARENCALLEE);
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
            if (Parser.parPlainDecimal(tok.value())) n.addSrc(SRC_PLAIN);
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
        if (t == (u16)tokNil) {
            // The null pointer: an integer literal 0 to everything downstream,
            // flagged so sema can refuse it where the context is not a pointer.
            // Positioned at the keyword, where the reference puts it (mk() after
            // advance() would stamp the token after it).
            Token* nilTok = advance();
            Node* n = mk((u16)nkInt);
            n.setNum((i64)0);
            n.setNilLit();
            n.setPos(nilTok.fileId(), nilTok.line(), nilTok.col());
            return n;
        }
        if (t == (u16)tokNew) {
            Token* newTok = advance();
            String* ty = String.withCString("?");
            if (check((u16)tokIdentifier) || isTypeKeywordToken(curType()))
                ty = advance().value();
            Node* n = mkNamed((u16)nkNew, ty);
            // At `new`, where the reference places it, not at the type name.
            n.setPos(newTok.fileId(), newTok.line(), newTok.col());
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
            // At the keyword, as the reference places it: an error about the
            // size points there.
            Node* n = mk((u16)nkSizeof);
            advance();
            bool paren = match((u16)tokLParen);
            // `sizeof(T)` where T names a type is a size query; `sizeof(x)`
            // where x is a variable is a size-of-an-expression. Same test as a
            // cast, and for the same reason: a bare identifier is a type only
            // when the unit declared it as one. The old local rule here read
            // ANY identifier followed by `)` as a type, so `sizeof(k)` parsed
            // `k` as a type name, no such type resolved, and the size came out
            // 0 — for every variable and every array (bug 560). The reference
            // has no local rule; it calls its cast predicate, which is what
            // `looksLikeCast` mirrors.
            if (looksLikeCast()) {
                n.setName(parseTypeSpelling());
            } else {
                n.setName(String.withCString("-"));
                n.add(parseExpression());
            }
            if (paren) expect((u16)tokRParen);
            return n;
        }
        if (t == (u16)tokIdentifier) {
            // A bound of a running total, where the scan's made code has its
            // marker (parScanExpand).
            if (_scanSplice != (Map*)0 && (Parser._same(cur().value(), "__XC_SCAN_A__") || Parser._same(cur().value(), "__XC_SCAN_B__")))
                return ((Node*)pfwGet(_scanSplice, Parser._same(advance().value(), "__XC_SCAN_A__") ? "A" : "B")).deepCopy();
            // Blocks (task #26): `block [name] RET(params) { body }` in
            // expression position is a literal, desugared to `BlkImpl$N.mk(…)`.
            if (blkAhead()) return blkParseLiteralExpression();
            // `par.x` … `par.depth` inside a `par :grid` body.
            Node* gridName = parGridMember();
            if (gridName != (Node*)0) return gridName;
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
            String* selfIvar = parSelfIvar();
            if (selfIvar != 0) {
                advance(); advance(); advance();        // self . f
                blkNoteUse(selfIvar);
                return mkNamed((u16)nkIdent, selfIvar);
            }
            Token* tok = advance();
            // A name about to be CALLED is noted by the call, after its
            // arguments and only when it is a block binding — the reference's
            // order, which decides the order of a literal's captures.
            if (!check((u16)tokLParen))
                blkNoteUse(tok.value());                // task #26
            return mkNamed((u16)nkIdent, tok.value());
        }
        // `delete(40, 2)` in EXPRESSION position is a call to a user function
        // of that name — the statement forms are handled in parseStatement.
        if (t == (u16)tokDelete || t == (u16)tokRetain || t == (u16)tokRelease) {
            Token* tok = advance();
            Node* rn = mkNamed(nkIdent, tok.value());
            rn.addSrc(SRC_SYNTH);
            return rn;
        }
        if (isTypeKeywordToken(t)) {
            // A bare type keyword in expression position is a static-call
            // receiver (`u16.max`) in the original's grammar; record it as an
            // identifier so the shape matches.
            Token* tok = advance();
            Node* tn = mkNamed(nkIdent, tok.value());
            tn.addSrc(SRC_SYNTH);
            return tn;
        }
        if (t == (u16)tokLParen) {
            match((u16)tokLParen);              // splits a merged `((`
            // A cast: `(T)expr` / `(T@ ?)expr`.
            if (looksLikeCast()) {
                // The cast sits at its `(`, as in the reference, not at the
                // `)` mkNamed would give it: a cast's errors point there.
                Token* lp = (Token*)_tokens.get(_pos - (u32)1);
                String* ty = parseTypeSpelling();
                bool failable = match((u16)tokQuestion);
                expect((u16)tokRParen);
                Node* n = mkNamed((u16)nkCast, ty);
                n.setPos(lp.fileId(), lp.line(), lp.col());
                if (failable) n.addFlag((u32)NF_FAILABLE);
                n.add(parseUnary());
                return n;
            }
            Node* e = parseExpression();
            expect((u16)tokRParen);
            if (e != (Node*)0) e.addSrc(SRC_PAREN);
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
            while (true) {
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

        // A typed collection's argument list, `(Array<AMSkyPoint>*)0`, as a
        // declaration takes it (astronomancy, 2026-10-25: the cast failed at
        // the `*)`). Only type words, commas, sigils and nested lists may
        // stand inside, so `(font < limit)` with a type called font stays a
        // comparison; `>>` closes two lists. As the reference.
        if (i > (u32)0 && isTypeName(peek(i - (u32)1).value()) && peek(i).type() == (u16)tokLess) {
            i32 depth = (i32)0;
            while (true) {
                Token* g = peek(i);
                u16 gt = g.type();
                if (gt == (u16)tokLess) depth = depth + (i32)1;
                else if (gt == (u16)tokGreater) depth = depth - (i32)1;
                else if (gt == (u16)tokShiftRight) depth = depth - (i32)2;
                else if (!(gt == (u16)tokIdentifier || isTypeKeywordToken(gt) || gt == (u16)tokComma
                           || isPointerSigil(gt) || gt == (u16)tokCaret)) return false;
                i = i + (u32)1;
                if (depth < (i32)0) return false;
                if (depth == (i32)0) break;
            }
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
