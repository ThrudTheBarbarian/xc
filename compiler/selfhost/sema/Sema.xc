// Sema.xc — the semantic analyser, in xtc.
// =================================================================
//
// self-hosting M6. The port of src/xtc/sema/ (8,405 lines of Objective-C across
// five files), proved the same way its three predecessors were: against a dump
// mode on the original — `xtc-fe --dump-sema` — compared byte for byte by
// selfhost/tools/sema-diff.sh.
//
// It is built in passes, and each pass is landed and measured before the next
// one starts, because the harness turns "how much of sema exists" into a
// number instead of a feeling.
//
//   1. DECLARATIONS  — collect classes, functions, globals; mangle names.
//   2. TYPES         — walk bodies, resolve identifiers, type expressions.
//   3. DISPATCH      — overload resolution, virtual slots, properties.
//   4. LIFETIME      — ARC, reachability.
//
// This file is pass 1. What it stamps is already comparable: a mangled name is
// what a call site resolves to and what the linker sees, so getting it wrong is
// not a cosmetic difference.
//
// A NOTE ON TYPES. The analyser works from type SPELLINGS — the strings the
// parser recorded — not from a type graph. That is not a shortcut taken to
// save effort: the oracle prints XTType.displayName, so a spelling is exactly
// what has to match, and the places that need structure (widening, pointer
// depth, class ancestry) ask about it explicitly. If a later pass needs a real
// type table, it can grow one behind these same queries.

#import "Foundation.xc"
#import <Node>
#import "NodeDefs.xc"
#import <Mangle>
#import <Types>
#import <Overload>
#import <Vtable>
#import <FileTable>

class Sema
    {
    Map* _classes;      // class name  -> ClassDecl node
    Map* _fmtWrappers;  // function name or `Class.method` -> its format index (see fmtWrapperIndex)
    Map* _protocols;    // protocol name -> ProtocolDecl node
    Array* _classDecls; // EVERY class/protocol declaration node, duplicates
                        // included — a double import parses the same class
                        // twice, the map keeps one, and the other's methods
                        // still have to be mangled because the dump prints
                        // every node in the tree
    Map* _functions;    // fn name     -> Array of FunctionDecl nodes
    // private:docs/bugs/050: within ONE function, a call that PACKS variadic arguments
    // and a `...` forward cannot both happen — they share one argument buffer.
    // --migrate=<base>:<to>: a member marked since("V") with V NEWER than the
    // base is hidden, so a call whose MEANING changed between the two releases
    // fails loudly instead of resolving to the new one.
    String* _migrateBase;
    String* _fnPackingCallee; // the first packing call seen, or 0
    Node* _fnPackingCall;     // …and the call, where the clash is reported
    bool _fnForwardsVarargs;  // a `...` forward was seen
    // The variadic non-reentrance check (checkVariadicReentrance). A variadic
    // that runs va_start reads its arguments from the ONE shared pack buffer,
    // so on a target that packs, another variadic reached from it overwrites
    // that buffer mid-read. The call graph is recorded as bodies are walked,
    // by the same `_fn_<sym>` / `_cls_<Class>_<sym>` labels the original uses.
    bool _nativeVarargs;      // arm64 / arm9: arguments ride the C ABI, no buffer
    String* _curLabel;        // the label of the body being walked, or 0
    Map* _callEdges;          // label -> Array of callee labels, first-seen order
    Map* _labelDisplay;       // label -> the name a message shows for it
    Map* _variadicLabels;     // labels of the variadics defined in this unit
    Map* _usesVaList;         // labels of the variadics that run va_start
    Array* _variadicDecls;    // their declarations, in program order
    Array* _variadicDeclLabels;
    Array* _variadicDeclNames;
    // The :cloaked check (checkCloaked). A body that pushes to the xtc stack
    // (new, delete/retain/release, a large local, a struct returned by value,
    // inline asm naming the stack pointer) is a LOCAL user; anything that
    // calls one becomes a user too; a :cloaked function that ends up a user
    // is refused with the chain that reaches the stack.
    Map* _stackUsing;          // label -> reason (locally) or "" (by a call)
    Map* _stackLocal;          // the locally-using labels, before propagation
    Array* _cloakedLabels;     // the :cloaked declarations, in program order
    Array* _cloakedNames;
    Array* _cloakedDecls;
    bool _cloakedWarn;         // -Wno-cloaked-transitive: a warning, not an error
    bool _usesClassNames;      // a call resolved to Object.className() or Object.newInstanceOfClass()
    bool _usesAtFormat;        // a printf-family format literal holds `%@`
    // The escape walk (escWalkStmt), per body: stack class locals by the
    // block depth that declared them, and pointer locals by the stack local
    // whose address they hold.
    Map* _escDepth;
    Map* _escAlias;
    u32 _escBlock;
    // A call to a `throws` callee must be inside a try's guarded block or in a
    // `throws` function (checkThrowsCall).
    u32 _tryDepth;
    bool _curThrows;
    bool _rangeIsInitialiser; // inside an ARRAY declaration's initialiser,
                              // the one position a range survives the parser
    Array* _errors;           // of String@
    Array* _warnings;         // of String@ — "<cat>\t<file:line:col: warning: text>"
    Array* _scopes;           // of Map@ (name -> type spelling); innermost last
    Map* _globals;            // file-scope variables
    Map* _structs;            // struct name -> StructDecl node
    Node* _curMethod;         // the declaration whose body is being walked
    Node* _curClass;          // the class whose body is being walked, or 0
    u32 _fnScopeAt;           // the index in _scopes of that callable's own scope
    String* _getterOwner;     // …and the same for a getter
    String* _setterOwner;     // where propertySetter found it — see the note there
    String* _curReturn;       // the return type of the function being walked
    String* _expected;        // the type the CONTEXT wants, propagated into an
                              // initialiser or an assignment's right-hand side.
                              // `Math.rand()` has five zero-argument overloads
                              // that differ only in return type, so the context
                              // is the only thing that can choose between them.
    Node* _opForced;          // the method an operator resolved to, for the call typed next
    Node* _opPick;            // …while that call picks its method (methodOverload)
    bool _anyOps;             // some class defines an operator: until one does, none resolves
    bool _opAmbig;            // the last opPick reported a tie
    // Choosing between the two readings of an expression (an operator a class
    // defines whose characters also read the old way): for each choice being
    // made, innermost last, what each such operator in it found, as
    // [Number(1 when an operand's class defines it), its spelling, that
    // class, the node].
    Array* _readingCollect;
    Node* _opIndexTarget;     // the subscript on the left of the assignment being typed
    bool _tieToFloat;         // pickOverload may settle a return-type tie on
                              // the float form (explicit and free calls only)
    Array* _used;             // classes named by `use X;` — their statics are
                              // reachable by bare name for the rest of the file
    Vtable* _vt;              // program-wide virtual slot numbering
    Map* _cyclic;             // classes whose parent chain loops — `class A : A`
    Map* _typedefTargets;     // alias -> the spelling it stands for (ident typing)
                              // is a sema ERROR, but the analyser still has to
                              // walk the tree without hanging, and every walk
                              // here follows parents
    // §4.2/§4.3b category-chain state, mirroring the reference's:
    // host -> Array of category names (for the anchor symbol);
    // host -> the anchor `<Host>$cat$<names sorted>`;
    // root label -> chain slot / host; host -> slot count.
    Map* _catNamesByHost;
    Map* _chainAnchorByHost;
    Map* _chainSlotByLabel;
    Map* _chainHostByLabel;
    Map* _chainCountByHost;
    bool _chainCapable; // multi-module target (the chain word exists)
    // The TARGET's pointer width, for ptrdiff only. DEFAULTS TO 8, never 0:
    // a caller that forgets setPointerWidth used to fall through the
    // >=8 / >=4 ladder to the narrowest branch and get an i16 pointer
    // difference on a 64-bit host — which is how sema-diff went red, because
    // the xtsema tool builds a Sema directly and never called the setter. A
    // zero width must not be able to mean "16-bit"; the common host width is
    // the only safe thing an unset field can mean.
    u32 _ptrW; // the TARGET's pointer width, for ptrdiff only.
    u32 _cntW; // the allocation header's COUNT width, for `.length` only.
               // Deliberately NOT routed through Types.byteWidth,
               // which hardcodes 8 for pointers and is the width
               // table behind every widen decision — changing it
               // would ripple through the whole corpus. This is
               // read at exactly one site.

    void init(void)
        {
        _classes = new Map();
        _fmtWrappers = new Map();
        _protocols = new Map();
        _classDecls = new Array();
        _functions = new Map();
        _errors = new Array();
        _warnings = new Array();
        _rangeIsInitialiser = false;
        _migrateBase = (String*)0;
        _fnPackingCallee = (String*)0;
        _fnForwardsVarargs = false;
        _nativeVarargs = false;
        _curLabel = (String*)0;
        _callEdges = new Map();
        _labelDisplay = new Map();
        _variadicLabels = new Map();
        _usesVaList = new Map();
        _variadicDecls = new Array();
        _variadicDeclLabels = new Array();
        _variadicDeclNames = new Array();
        _stackUsing = new Map();
        _stackLocal = new Map();
        _cloakedLabels = new Array();
        _cloakedNames = new Array();
        _cloakedDecls = new Array();
        _cloakedWarn = false;
        _usesClassNames = false;
        _usesAtFormat = false;
        _scopes = new Array();
        _globals = new Map();
        _structs = new Map();
        _curClass = (Node*)0;
        _curMethod = (Node*)0;
        _fnScopeAt = (u32)0;
        _getterOwner = (String*)0;
        _setterOwner = (String*)0;
        _curReturn = (String*)0;
        _expected = (String*)0;
        _tieToFloat = false;
        _opForced = (Node*)0;
        _opPick = (Node*)0;
        _anyOps = false;
        _readingCollect = (Array*)0;
        _opAmbig = false;
        _opIndexTarget = (Node*)0;
        _used = new Array();
        _vt = new Vtable();
        _cyclic = new Map();
        _typedefTargets = new Map();
        _catNamesByHost = new Map();
        _chainAnchorByHost = new Map();
        _chainSlotByLabel = new Map();
        _chainHostByLabel = new Map();
        _chainCountByHost = new Map();
        _chainCapable = false;
        }

    static Sema* make(void)
        {
        Sema* s = new Sema();
        // Matches Lower's own default (Lower.xc: _ptrW = 3). The two halves of
        // the port MUST start from the same number: sema picks the ptrdiff
        // TYPE and lowering builds the VALUE, and a tool that sets neither
        // gets both from these defaults. Briefly this defaulted to 8 while
        // Lower defaulted to 3, so xtir's sema said i64 while its lowering
        // emitted I16 — and the `(i32)` cast, chosen from sema's type but
        // applied to lowering's value, came out as `Trunc I16 -> I32`, which
        // is incoherent. Whatever this value is, it has to equal Lower's.
        s.setPointerWidth((u32)3);
        s.setCountWidth((u32)2);
        return s;
        }

    Vtable* vtable(void)
        {
        return _vt;
        }
    Array* errors(void)
        {
        return _errors;
        }
    Array* warnings(void)
        {
        return _warnings;
        }
    // Did a call resolve to Object.className() or Object.newInstanceOfClass()?
    // Those read the per-module class-name table, which the front end emits
    // only for a program that calls one (Frontend.injectClassNames).
    bool usesClassNames(void)
        {
        return _usesClassNames;
        }
    // Did a printf-family format (or a format wrapper's) hold `%@`? Stdio's
    // `%@` support pulls in the Object root and is compiled in only for a
    // program that passes one (HAS_ATFMT, Frontend.lower).
    bool usesAtFormat(void)
        {
        return _usesAtFormat;
        }
    // A method call has resolved to `m`, declared by the class `owner`.
    void noteClassNameUse(String* owner, Node* m)
        {
        if (_isOp(owner, "Object") && (_isOp(m.name(), "className") || _isOp(m.name(), "newInstanceOfClass")))
            _usesClassNames = true;
        }
    void setChainCapable(bool c)
        {
        _chainCapable = c;
        }
    void setCountWidth(u32 w)
        {
        _cntW = w;
        }
    void setPointerWidth(u32 w)
        {
        _ptrW = w;
        }
    void setMigrateBase(String* v)
        {
        _migrateBase = v;
        }
    void setNativeVarargs(bool v)
        {
        _nativeVarargs = v;
        }

    void setCloakedTransitiveWarns(bool v)
        {
        _cloakedWarn = v;
        }

    // §4.3b: record a category name on an external host — the sorted names
    // become the anchor symbol, the extender's identity at the linker.
    void noteCatName(String* host, String* cat)
        {
        Array* names = (Array*)_catNamesByHost.get((Hashable*)host);
        if (names == 0)
            {
            names = new Array();
            _catNamesByHost.set((Hashable*)host, (Object*)names);
            }
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            if (((String*)names.get(i)).equals(cat))
                return;
        names.add((Object*)cat);
        }
    // A diagnostic with no position carries the word `error:` itself, so the
    // driver can print every message the same way whether or not it is placed.
    // `(T* ?)x`, the checked cast: it must name a class pointer, and — because
    // the check reads the operand's class out of its object header — the
    // operand has to BE an object (bug 588). A raw `pointer` need not be, and
    // was let through with no check at all, so the cast always "succeeded".
    // An unchecked `(T*)p` stays legal: it never claimed to check.
    void checkFailableCast(Node* n)
        {
        String* tc = classNameOf(n.name());
        // A PROTOCOL pointer is a valid target too: `(Pingable* ?)o` asks
        // whether o conforms, as the reference has always accepted.
        if (tc == 0 || (_classes.get((Hashable*)tc) == 0 && _protocols.get((Hashable*)tc) == 0))
            {
            _errorAt(String.withCString("'?' failable-cast modifier is only valid on class-pointer casts"), n);
            return;
            }
        if (n.kidCount() == (u32)0)
            return;
        String* opT = n.kid((u32)0).ty();
        String* oc = opT == 0 ? (String*)0 : classNameOf(opT);
        if (oc != 0 && (_classes.get((Hashable*)oc) != 0 || _protocols.get((Hashable*)oc) != 0))
            return;
        String* e = String.withCString("a checked cast needs an object, but the operand is '");
        e.append(opT == 0 ? String.withCString("?") : opT);
        e.appendCString("' — if it holds one, say so: (T* ?)(Object*)value");
        _errorAt(e, n);
        }

    // A cast from a class pointer to a PROTOCOL pointer. Where the vtable
    // carries the conformance list (the chain-capable targets) the object's
    // dynamic class is checked at run time. The 6502 and m68k carry no such
    // list, so there the class must declare the protocol, as the reference
    // requires; letting it through lowered a check nothing could make.
    // Whether class `a` is `b` or inherits from it.
    bool classInheritsOrEquals(String* a, String* b)
        {
        Object* d = _classes.get((Hashable*)a);
        for (Node* c = (Node*)d; c != 0; c = parentOf(c))
            if (c.name().equals(b))
                return true;
        return false;
        }

    void checkProtocolCast(Node* n)
        {
        if (n.kidCount() == (u32)0)
            return;
        String* tc = classNameOf(n.name());
        // A cast between two classes of this unit that are not on one line
        // of descent can never succeed, as the reference refuses it: `(B*)a`
        // where neither is the other's ancestor.
        if (tc != 0 && _classes.get((Hashable*)tc) != 0 && Types.isPointer(n.name()))
            {
            String* opT = n.kid((u32)0).ty();
            String* oc = opT == 0 ? (String*)0 : (Types.isPointer(opT) ? classNameOf(opT) : (String*)0);
            if (oc != 0 && _classes.get((Hashable*)oc) != 0
                && !classInheritsOrEquals(oc, tc) && !classInheritsOrEquals(tc, oc))
                {
                String* e = String.withCString("'");
                e.append(oc);
                e.appendCString("' and '");
                e.append(tc);
                e.appendCString("' are unrelated classes — the cast can never succeed");
                _errorAt(e, n);
                return;
                }
            }
        if (_chainCapable)
            return;
        if (tc == 0 || _protocols.get((Hashable*)tc) == 0)
            return;
        String* opT = n.kid((u32)0).ty();
        String* oc = opT == 0 ? (String*)0 : classNameOf(opT);
        if (oc == 0 || oc.equals(tc))
            return;
        if (_classes.get((Hashable*)oc) == 0 && _protocols.get((Hashable*)oc) == 0)
            return;
        if (Overload.declaresConformance(oc, tc))
            return;
        String* e = String.withCString("Class '");
        e.append(oc);
        e.appendCString("' does not conform to protocol '");
        e.append(tc);
        e.appendCString("' — declare it as `class ");
        e.append(oc);
        e.appendCString(" <");
        e.append(tc);
        e.appendCString(">`");
        _errorAt(e, n);
        }

    // The declaration-order reading of an overload clash (bug 557), or 0.
    String* declOrderClash(Node* ext, Node* fn)
        {
        Array* ep = new Array();
        Array* fp = new Array();
        for (u32 k = (u32)0; k < ext.kidCount(); k = k + (u32)1)
            if (ext.kid(k).kind() == (u16)nkParam)
                ep.add((Object*)ext.kid(k));
        for (u32 k = (u32)0; k < fn.kidCount(); k = k + (u32)1)
            if (fn.kid(k).kind() == (u16)nkParam)
                fp.add((Object*)fn.kid(k));
        if (ep.count() != fp.count())
            return (String*)0;
        for (u32 k = (u32)0; k < ep.count(); k = k + (u32)1)
            {
            String* et = ((Node*)ep.get(k)).op();
            String* ft = ((Node*)fp.get(k)).op();
            if (et == 0 || ft == 0 || !et.equals(String.withCString("void*")) || !ft.hasSuffix(String.withCString("*")) || ft.equals(et))
                continue;
            String* tn = ft.substringBytes((u32)0, ft.byteLength() - (u32)1);
            if (_structs.get((Hashable*)tn) == 0 && _classes.get((Hashable*)tn) == 0)
                continue;
            String* m = String.withCString("'");
            m.append(fn.name());
            m.appendCString("' is declared at ");
            m.append(ext.file() != 0 ? ext.file().lastPathComponent() : String.withCString("?"));
            m.appendByte((u8)':');
            m.append(String.withU32(ext.line()));
            m.appendCString(" taking 'void*' where this takes '");
            m.append(ft);
            m.appendCString("': at that line '");
            m.append(tn);
            m.appendCString("' was not declared yet, so it was read as an opaque pointer. Declare '");
            m.append(tn);
            m.appendCString("' above the first declaration of '");
            m.append(fn.name());
            m.appendCString("'");
            return m;
            }
        return (String*)0;
        }

    void _error(String* msg)
        {
        String* out = String.withCString("error: ");
        out.append(msg);
        _errors.add((Object*)out);
        }

    // The same, with a POSITION taken from the node the diagnostic is about —
    // `file:line:col: message`, which is the shape the reference prints and
    // the shape an editor can jump to. A node with no position (nothing
    // stamped it, or it was synthesised) degrades to the bare message rather
    // than inventing a line.
    // `nil` is the literal 0 to the type checker, so a null pointer lowers as
    // it always has, but it names a pointer: a declaration, assignment, return
    // or argument that gives it to anything else (`u32 n = nil`) is refused.
    // Called at those four sites with the expression and the type the site
    // wants; a site that wants nothing in particular lets it through, and `==`
    // / `!=` check their other operand in typeBinary. The check is made at the
    // site, not where the literal is typed, because the expected type an
    // operand or argument inherits from further out is not the type IT is
    // given. The message is the reference's, word for word.
    void checkNil(Node* e, String* want)
        {
        if (e == 0 || want == 0 || e.kind() != (u16)nkInt || !e.nilLit())
            return;
        if (Types.isPointer(want))
            return;
        String* m = String.withCString("nil is a pointer: it cannot be a '");
        m.append(want);
        m.appendCString("'");
        _errorAt(m, e);
        }

    // A tuple's values are taken apart from one aggregate in registers, and a
    // struct is not a value that can be bound that way: the lowering bound it
    // as an SSA name, so a member access found no slot and was refused, but
    // a use that passed or assigned the whole struct built silently and read
    // the wrong bytes (#452). Refused here, for every target and every use.
    void checkTupleTarget(Node* t, String* ty)
        {
        String* r = ty;
        for (u32 hop = (u32)0; r != 0 && hop < (u32)8; hop = hop + (u32)1)
            {
            if (_structs.get((Hashable*)r) != 0)
                {
                String* m = String.withCString("a tuple cannot hold the struct '");
                m.append(t.name());
                m.appendCString("'; pass a pointer to it instead");
                _errorAt(m, t);
                return;
                }
            r = (String*)_typedefTargets.get((Hashable*)r);
            }
        }

    void _errorAt(String* msg, Node* n)
        {
        // A node with no position degrades to the bare message rather than
        // inventing a line — but it still has to READ as an error. This added
        // the raw text, so an unpositioned diagnostic printed with no
        // "error: " prefix at all and anything grepping for one missed it
        // entirely (bug 209).
        if (n == 0 || n.line() == (u32)0)
            {
            String* bare = String.withCString("error: ");
            bare.append(msg);
            _errors.add((Object*)bare);
            return;
            }
        String* out = String.withCString("");
        if (n.file() != 0)
            {
            out.append(n.file());
            }
        else
            {
            out.appendCString("?");
            }
        // A statement (a declaration, a return, a member) is reported where
        // it starts — its type, its keyword — as the reference reports it;
        // the node's own position is the name or the value.
        bool atStmt = Sema.reportsAtStatement(n);
        out.appendByte((u8)':');
        out.append(String.withU32(atStmt ? n.stmtLine() : n.line()));
        out.appendByte((u8)':');
        out.append(String.withU32(atStmt ? n.stmtCol() : n.col()));
        out.appendCString(": error: ");
        out.append(msg);
        _errors.add((Object*)out);
        }

    // A declaration, a return or a member is reported where it starts (its
    // type, its keyword), as the reference reports one; the node's own
    // position is its name or its value. Everything else at the node.
    static bool reportsAtStatement(Node* n)
        {
        if (n.stmtLine() == (u32)0)
            return false;
        u16 k = n.kind();
        return k == (u16)nkVariableDecl || k == (u16)nkReturn || k == (u16)nkMethodDecl || k == (u16)nkFunctionDecl;
        }

    // A WARNING from sema, positioned and CATEGORISED. Same wire shape as the
    // parser's warnAt — "<category>\t<file:line:col: warning: text>" — so the
    // driver prints it, and drops it under `-Wno-<category>`, without knowing
    // which pass produced it (bug 553).
    void _warnAt(String* cat, String* msg, Node* n)
        {
        String* out = String.withString(cat);
        out.appendByte((u8)'\t');
        if (n != 0 && n.line() != (u32)0)
            {
            out.append(n.file() != 0 ? n.file() : String.withCString("?"));
            out.appendByte((u8)':');
            bool atStmt = Sema.reportsAtStatement(n);
            out.append(String.withU32(atStmt ? n.stmtLine() : n.line()));
            out.appendByte((u8)':');
            out.append(String.withU32(atStmt ? n.stmtCol() : n.col()));
            out.appendCString(": ");
            }
        out.appendCString("warning: ");
        out.append(msg);
        _warnings.add((Object*)out);
        }

    // ── Control reaching the end of a non-void function ──────────────────
    // A non-void body that can reach its closing brace lowers to `Unreachable`
    // and the program TRAPS at run time with no message (finishFunction in
    // Lower.xc). The missing `return` is a source mistake, so it is named at
    // compile time: statementCanFallThrough answers whether the body can fall
    // off, and finishFunction's own trap stays as the backstop.
    //
    // CONSERVATIVE, in ONE direction: a construct we do not model answers
    // "can fall through" (so we warn), while a construct that merely MIGHT
    // not fall through answers the other way (so we stay quiet). Firing on
    // code that is fine is worse than staying silent, so only these are
    // treated as unable to fall through:
    //   - `return` / `throw`
    //   - a block containing a terminating statement (the rest is unreachable)
    //   - an `if` with an `else` where BOTH arms terminate
    //   - an unbounded loop (`for (;;)` or `while (1)`) whose body has no
    //     `break` at its own level
    // `break`/`continue` are NOT terminating — they leave a loop, not the
    // function. `switch`, `for-in`, inline asm and every expression statement
    // answer "can fall through" (the last even for a call to exit).
    bool statementCanFallThrough(Node* s)
        {
        if (s == 0)
            return true;
        u16 k = s.kind();
        if (k == (u16)nkReturn || k == (u16)nkThrow)
            return false;
        if (k == (u16)nkBlock)
            {
            for (u32 i = (u32)0; i < s.kidCount(); i = i + (u32)1)
                if (!statementCanFallThrough(s.kid(i)))
                    return false;
            return true;
            }
        if (k == (u16)nkIf)
            {
            if (s.kidCount() < (u32)3)
                return true;
            if (statementCanFallThrough(s.kid((u32)1)))
                return true;
            if (statementCanFallThrough(s.kid((u32)2)))
                return true;
            return false;
            }
        if (k == (u16)nkWhile)
            {
            if (s.kidCount() >= (u32)2 && conditionConstTrue(s.kid((u32)0))
                && !bodyBreaksOwnLoop(s.kid((u32)1)))
                return false;
            return true;
            }
        if (k == (u16)nkForCStyle)
            {
            Node* body = 0;
            bool unbounded = false;
            for (u32 i = (u32)0; i < s.kidCount(); i = i + (u32)1)
                {
                Node* kid = s.kid(i);
                u16 kk = kid.kind();
                if (kk == (u16)nkMarkerCond)
                    unbounded = (kid.kidCount() == (u32)0)
                             || conditionConstTrue(kid.kid((u32)0));
                else if (kk != (u16)nkMarkerInit && kk != (u16)nkMarkerStep)
                    body = kid;
                }
            if (unbounded && !bodyBreaksOwnLoop(body))
                return false;
            return true;
            }
        return true;
        }

    // A loop condition that is certainly true: the integer literal 1 (any
    // nonzero constant). `true` is not a keyword, so an identifier answers
    // false and only a literal counts.
    bool conditionConstTrue(Node* c)
        {
        return c != 0 && c.kind() == (u16)nkInt && c.num() != (i64)0;
        }

    // YES if `body` holds a `break` that would leave THIS loop — one not
    // inside a nested loop or switch, where it would target the inner
    // construct instead.
    bool bodyBreaksOwnLoop(Node* b)
        {
        if (b == 0)
            return false;
        u16 k = b.kind();
        if (k == (u16)nkBreak)
            return true;
        if (k == (u16)nkWhile || k == (u16)nkForCStyle || k == (u16)nkForIn
            || k == (u16)nkSwitch)
            return false;
        if (k == (u16)nkBlock)
            {
            for (u32 i = (u32)0; i < b.kidCount(); i = i + (u32)1)
                if (bodyBreaksOwnLoop(b.kid(i)))
                    return true;
            return false;
            }
        if (k == (u16)nkIf)
            {
            for (u32 i = (u32)0; i < b.kidCount(); i = i + (u32)1)
                if (bodyBreaksOwnLoop(b.kid(i)))
                    return true;
            return false;
            }
        if (k == (u16)nkDefer)
            {
            for (u32 i = (u32)0; i < b.kidCount(); i = i + (u32)1)
                if (bodyBreaksOwnLoop(b.kid(i)))
                    return true;
            return false;
            }
        return false;
        }

    // ── Pass 1: declarations ────────────────────────────────────────────
    // Is this member visible under --migrate? A member marked since("V") newer
    // than the base is hidden from the program being migrated — that is the
    // whole point: a REUSED name whose meaning changed has to fail rather than
    // silently resolve to the new one.
    //
    // Three things stay visible, and each is load-bearing:
    //   - a member of the class currently being compiled: a class may call its
    //     own new surface;
    //   - a caller that is ITSELF annotated newer than the base: new code
    //     calling new code is not a migration hazard.
    //
    // Is this path inside the shipped library tree? `support/...` in the source
    // checkout, `lib/xc/...` in an install — the two spellings the support root
    // resolver already accepts.
    bool underSupportTree(String* path)
        {
        if (path == 0)
            return false;
        if (path.byteIndexOf(String.withCString("support/")) != String.notFound())
            return true;
        if (path.byteIndexOf(String.withCString("lib/xc/")) != String.notFound())
            return true;
        return false;
        }

    bool memberVisibleUnderMigrate(Node* m, Node* owner, Node* site)
        {
        if (_migrateBase == 0 || m == 0)
            return true;
        if (m.since() == 0 || m.since().byteLength() == (u32)0)
            return true;
        if (!versionGreater(m.since(), _migrateBase))
            return true;
        if (_curClass != 0 && owner != 0 && _curClass == owner)
            return true;
        // The CALL SITE's file, not the callee's: the standard library is not
        // being migrated — it already was, in the release the flag names as its
        // target — so a call made FROM the support tree sees the whole surface.
        // Gating it there made every client of an already-migrated stdlib class
        // unable to use the flag at all, which is precisely the program that
        // needs it.
        if (site != 0 && underSupportTree(site.file()))
            return true;
        if (_curMethod != 0 && _curMethod.since() != 0 && _curMethod.since().byteLength() > (u32)0 && versionGreater(_curMethod.since(), _migrateBase))
            return true;
        return false;
        }

    // `0.4` > `0.3`, field by field. Absent fields read as zero, so `0.4` and
    // `0.4.0` compare equal rather than one being newer than the other.
    bool versionGreater(String* a, String* b)
        {
        u32 ai = (u32)0;
        u32 bi = (u32)0;
        while (ai < a.byteLength() || bi < b.byteLength())
            {
            u32 av = (u32)0;
            while (ai < a.byteLength() && a.byteAt(ai) != (u8)'.')
                {
                av = av * (u32)10 + (u32)(a.byteAt(ai) - (u8)'0');
                ai = ai + (u32)1;
                }
            if (ai < a.byteLength())
                ai = ai + (u32)1;
            u32 bv = (u32)0;
            while (bi < b.byteLength() && b.byteAt(bi) != (u8)'.')
                {
                bv = bv * (u32)10 + (u32)(b.byteAt(bi) - (u8)'0');
                bi = bi + (u32)1;
                }
            if (bi < b.byteLength())
                bi = bi + (u32)1;
            if (av > bv)
                return true;
            if (av < bv)
                return false;
            }
        return false;
        }

    // Record the two halves of private:docs/bugs/050 as they are seen. `decl` is the
    // resolved callee; `ownerName` is its class, for the message.
    void notePackOrForward(Node* call, Node* decl, String* ownerName)
        {
        if (call.hasFlag((u32)NF_VAFWD))
            _fnForwardsVarargs = true;
        if (decl == 0 || !decl.hasFlag((u32)NF_VARARGS))
            return;
        if (call.hasFlag((u32)NF_VAFWD))
            return; // forwarding is not packing
        u32 fixed = (u32)0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            if (decl.kid(i).kind() == (u16)nkParam)
                fixed = fixed + (u32)1;
        if ((u32)call.num() <= fixed)
            return; // nothing in the tail
        if (_fnPackingCallee != 0)
            return; // the first one reports
        String* nm = String.withCString("");
        if (ownerName != 0)
            {
            nm.append(ownerName);
            nm.appendByte((u8)'.');
            }
        nm.append(call.name());
        _fnPackingCallee = nm;
        _fnPackingCall = call;
        }

    // A class-pointer assignment is CHECKED. One function, six sites (an
    // initialiser, a return, an assignment, a call argument, a collection
    // element, a Map key) — the shipped compiler had none of them, so every
    // rule below was silently accepted (private:docs/bugs/078).
    //
    // `site` names the context and leads the message, matching the reference
    // word for word: the two compilers must not disagree about what is legal
    // OR about how they say so.
    void checkClassPointerAssign(String* lhs, String* rhs, Node* rhsNode, string site)
        {
        checkClassPointerAssignAt(lhs, rhs, rhsNode, site, rhsNode);
        }

    // The same, reported at `at`: a call argument is placed at the CALL, and
    // an initialiser, assignment or return at its STATEMENT, as the reference
    // places them.
    void checkClassPointerAssignAt(String* lhs, String* rhs, Node* rhsNode, string site, Node* at)
        {
        if (lhs == 0 || rhs == 0)
            return;

        // A string literal is a pointer, not a number, and no pointer has a
        // floating value: both compiled silently and stored the address
        // (#669). A cast still says the address is really meant.
        if (checkPointerToNumber(lhs, rhs, rhsNode, site, at))
            return;

        // A `simd:` pointer may hold only what `new[]` returned or what
        // another `simd:` pointer holds: the qualifier promises a page-aligned
        // block the runtime can find (the reference explains). nil and 0 are
        // fine, and a cast says it is meant; the argument form has its own
        // check (checkPtrArgWidth).
        String* siteName = String.withCString(site);
        if ((siteName.equals(String.withCString("initialiser")) || siteName.equals(String.withCString("assignment"))
             || siteName.equals(String.withCString("return")))
            && Types.isPointer(lhs) && Overload._isSimd(lhs) && Types.isPointer(rhs) && !Overload._isSimd(rhs)
            && rhsNode != 0 && rhsNode.kind() != (u16)nkNew && rhsNode.kind() != (u16)nkInt)
            {
            String* e = String.withCString(site);
            e.appendCString(": a plain pointer cannot be stored in a simd: pointer — simd: ");
            e.appendCString("promises page-aligned storage (a new[] into a simd: pointer, or ");
            e.appendCString("another simd: pointer), and a par block that captures it is sized ");
            e.appendCString("from that block. Cast if that is really meant");
            _errorAt(e, at);
            return;
            }

        bool lBound = isBoundSignature(lhs);
        bool rBound = isBoundSignature(rhs);
        String* lp = classNameOf(lhs);
        String* rp = classNameOf(rhs);
        bool lBlk = lp != 0 && lp.hasPrefix(String.withCString("Blk$"));
        bool rBlk = rp != 0 && rp.hasPrefix(String.withCString("Blk$"));

        // A BLOCK is not a bound method, and the refusal goes BOTH ways — it is
        // a non-goal, not a missing feature (private:docs/Design/bound-methods.md §7).
        // Stored either way it type-checked and then failed silently: the slot
        // read back false and the call never happened, or it read true and took
        // SIGBUS inside the callee.
        if (!rBound && lBound && rBlk)
            {
            String* e = String.withCString(site);
            e.appendCString(": a block cannot be stored in a bound-method ('^') slot — ");
            e.appendCString("a block is a class reference and a '^' is a (receiver, code) ");
            e.appendCString("pair, so the value would be read back as null or called as ");
            e.appendCString("garbage. Pass '&obj.method' where a '^' is expected, or make ");
            e.appendCString("the slot a block type.");
            _errorAt(e, at);
            return;
            }
        if (rBound && !lBound && lBlk)
            {
            String* e = String.withCString(site);
            e.appendCString(": a bound method cannot be stored in a block slot — a block ");
            e.appendCString("OWNS what it captures and a callback never owns its receiver, ");
            e.appendCString("so the conversion would either retain the receiver (closing a ");
            e.appendCString("reference cycle) or give you a block with no owner. It is a ");
            e.appendCString("non-goal, not a missing feature. Declare the slot as ");
            e.appendCString("'callback <name> RET(params)' instead.");
            _errorAt(e, at);
            return;
            }
        if (lBound || rBound)
            return;

        // A by-value argument is checked once, with the call's other
        // stack-instance rules (checkStackStrongArgs).
        if (!Types.isPointer(lhs) && !Types.isPointer(rhs))
            {
            if (siteName.equals(String.withCString("initialiser")) || siteName.equals(String.withCString("assignment"))
                || siteName.equals(String.withCString("return")))
                checkSliceByValue(lhs, rhs, site, at);
            return;
            }
        if (!Types.isPointer(lhs) || !Types.isPointer(rhs))
            return;
        bool lCls = lp != 0 && _classes.get((Hashable*)lp) != 0;
        bool rCls = rp != 0 && _classes.get((Hashable*)rp) != 0;
        bool lProto = lp != 0 && _protocols.get((Hashable*)lp) != 0;
        bool rProto = rp != 0 && _protocols.get((Hashable*)rp) != 0;
        if (!lCls && !rCls && !lProto && !rProto)
            return;

        // The null idiom stays legal in both directions.
        if (rhsNode != 0 && rhsNode.kind() == (u16)nkInt && rhsNode.num() == (i64)0)
            return;

        // Exactly ONE side is a class reference: a raw pointer is not one, and
        // letting it through silently is how `String* x = buf;` compiled,
        // dispatched through byte-soup and killed a worker before anything
        // complained. An explicit cast retypes the value before this sees it,
        // so the deliberate out survives.
        if ((lCls || lProto) != (rCls || rProto))
            {
            String* e = String.withCString(site);
            if (lCls || lProto)
                {
                e.appendCString(": a raw '");
                e.append(rhs);
                e.appendCString("' is not a class reference '");
                e.append(lp);
                e.appendCString("*' — build one (e.g. ");
                e.append(lp);
                e.appendCString(".withBytes / a constructor), or cast explicitly if ");
                e.appendCString("the pointer really holds an instance");
                }
            else
                {
                e.appendCString(": a class reference '");
                e.append(rp);
                e.appendCString("*' is not a raw '");
                e.append(lhs);
                e.appendCString("' — take the bytes you mean (e.g. cString()/bytes()), ");
                e.appendCString("or cast explicitly");
                }
            _errorAt(e, at);
            return;
            }

        if (lp.equals(rp))
            return;
        // A protocol destination takes any class that conforms to it.
        if (lProto)
            {
            if (rProto && rp.equals(lp))
                return;
            if (rCls && Overload.conformsTo(rp, lp))
                return;
            String* e = String.withCString(site);
            e.appendCString(": '");
            e.append(rp);
            e.appendCString("' does not conform to protocol '");
            e.append(lp);
            e.appendByte((u8)0x27);
            _errorAt(e, at);
            return;
            }
        // Every class that conforms to a protocol descends from Object, so a
        // protocol reference is always a valid `Object*`.
        if (rProto && lp.equals(String.withCString("Object")))
            return;
        if (lCls && rCls && Overload.descendsFrom(rp, lp))
            return;
        String* e = String.withCString(site);
        e.appendCString(": '");
        e.append(rp);
        e.appendCString("' is not a subclass of '");
        e.append(lp);
        e.appendByte((u8)0x27);
        _errorAt(e, at);
        }

    // A string literal stored in a number, or any pointer stored in a float
    // or double, is refused with what was probably meant. True when it was.
    bool checkPointerToNumber(String* lhs, String* rhs, Node* rhsNode, string site, Node* at)
        {
        if (!Types.isPointer(rhs) || Types.isPointer(lhs))
            return false;
        bool num = Types.isInteger(lhs) || Types.isFloating(lhs) || Types.isEnumName(lhs);
        if (!num)
            return false;
        if (rhsNode != 0 && rhsNode.kind() == (u16)nkStr)
            {
            String* e = String.withCString(site);
            e.appendCString(": a string literal is a pointer, not a '");
            e.append(lhs);
            e.appendCString("' — for one character write 'x' (or s[0]); for a number in text, ");
            e.appendCString("parse it (NumberFormatter's parse); cast explicitly if the address ");
            e.appendCString("is really meant");
            _errorAt(e, at);
            return true;
            }
        // A class reference can unbox (a Number* into a double), so only a
        // raw pointer is refused.
        String* rc = classNameOf(rhs);
        bool classRef = rc != 0 && (_classes.get((Hashable*)rc) != 0 || _protocols.get((Hashable*)rc) != 0);
        if (Types.isFloating(lhs) && !classRef)
            {
            String* e = String.withCString(site);
            e.appendCString(": a pointer '");
            e.append(rhs);
            e.appendCString("' has no '");
            e.append(lhs);
            e.appendCString("' value — dereference it (*p) for the value it points at");
            _errorAt(e, at);
            return true;
            }
        return false;
        }

    // A stack instance copied BY VALUE into a slot of one of its ancestors —
    // a return, an initialiser, an assignment or an argument — would be cut
    // down to the ancestor's ivars while keeping its own class, so a virtual
    // call on the copy runs the subclass's method on fields that are not
    // there (#552). Refused. The same class copies as before, and a reference
    // to the subclass instance is a pointer and never reaches here.
    void checkSliceByValue(String* lhs, String* rhs, string site, Node* at)
        {
        if (lhs.equals(rhs) || _classes.get((Hashable*)lhs) == 0 || _classes.get((Hashable*)rhs) == 0)
            return;
        if (!Overload.descendsFrom(rhs, lhs))
            return;
        String* s = String.withCString(site);
        String* e = String.withCString("");
        if (s.equals(String.withCString("return")))
            {
            e.appendCString("returning a '");
            e.append(rhs);
            e.appendCString("' by value as a '");
            e.append(lhs);
            e.appendCString("' would slice it; return a '");
            e.append(rhs);
            }
        else if (s.equals(String.withCString("initialiser")))
            {
            e.appendCString("initialising a '");
            e.append(lhs);
            e.appendCString("' by value from a '");
            e.append(rhs);
            e.appendCString("' would slice it; declare a '");
            e.append(rhs);
            }
        else if (s.equals(String.withCString("assignment")))
            {
            e.appendCString("assigning a '");
            e.append(rhs);
            e.appendCString("' by value to a '");
            e.append(lhs);
            e.appendCString("' would slice it; assign it to a '");
            e.append(rhs);
            }
        else
            {
            e.append(s);
            e.appendCString(": passing a '");
            e.append(rhs);
            e.appendCString("' by value as a '");
            e.append(lhs);
            e.appendCString("' would slice it; take a '");
            e.append(rhs);
            }
        e.appendCString("', or a reference ('");
        e.append(lhs);
        e.appendCString("*')");
        _errorAt(e, at);
        }

    // A call ARGUMENT into a class-pointer or protocol parameter (bug 320),
    // the same rule for a method and a free function. It is refused only when
    // no object could be both what the argument is typed as and what the
    // parameter wants:
    //   class -> class        neither the parameter's class, a subclass nor
    //                         an ancestor of it.
    //   class -> protocol     neither the class nor any known subclass of it
    //                         conforms (`Object` always may).
    //   protocol -> class     neither the parameter's class nor any known
    //                         subclass of it conforms.
    //   protocol -> protocol  different protocols no known class conforms to
    //                         both.
    // An ancestor is the implicit downcast collection code is written against
    // (`Object*` from `Array.get`), so it stays legal in a call. Everything
    // else is the assignment rule, in its words.
    void checkClassPointerArgAt(String* lhs, String* rhs, Node* rhsNode, string site, Node* at)
        {
        if (classPointerArgMayBe(rhs, lhs))
            return;
        checkClassPointerAssignAt(lhs, rhs, rhsNode, site, at);
        }

    bool classPointerArgMayBe(String* arg, String* par)
        {
        if (arg == 0 || par == 0)
            return false;
        if (isBoundSignature(arg) || isBoundSignature(par))
            return false;
        if (!Types.isPointer(arg) || !Types.isPointer(par))
            return false;
        String* ap = classNameOf(arg);
        String* pp = classNameOf(par);
        if (ap == 0 || pp == 0)
            return false;
        bool aProto = _protocols.get((Hashable*)ap) != 0;
        bool pProto = _protocols.get((Hashable*)pp) != 0;
        bool aCls = !aProto && _classes.get((Hashable*)ap) != 0;
        bool pCls = !pProto && _classes.get((Hashable*)pp) != 0;
        if (aCls && pCls)
            return Overload.descendsFrom(pp, ap);
        if (aCls && pProto)
            return classMayConform(ap, pp);
        if (aProto && pCls)
            return classMayConform(pp, ap);
        if (aProto && pProto)
            {
            if (ap.equals(pp))
                return true;
            Array* names = conformers(ap);
            for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
                if (Overload.conformsTo((String*)names.get(i), pp))
                    return true;
            }
        return false;
        }

    // Does `cls` or some known subclass of it conform to `proto`? `Object` is
    // taken to: a conforming class may come from another module.
    bool classMayConform(String* cls, String* proto)
        {
        if (_isOp(cls, "Object"))
            return true;
        Array* names = conformers(proto);
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            if (Overload.descendsFrom((String*)names.get(i), cls))
                return true;
        return false;
        }

    // The known classes that conform to `proto`, found once per protocol
    // (#335): each pointer-argument check walked every class. The cache is
    // dropped when a class is added or the hierarchy is set again.
    Map* _conformers;
    u32 _conformersClasses;
    u32 _conformersGen;
    Array* conformers(String* proto)
        {
        if (_conformers == (Map*)0 || _conformersClasses != _classes.count()
            || _conformersGen != Overload.generation())
            {
            _conformers = new Map();
            _conformersClasses = _classes.count();
            _conformersGen = Overload.generation();
            }
        Array* out = (Array*)_conformers.get((Hashable*)proto);
        if (out != (Array*)0)
            return out;
        out = new Array();
        Array* names = _classes.allKeys();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            if (Overload.conformsTo((String*)names.get(i), proto))
                out.add(names.get(i));
        _conformers.set((Hashable*)proto, (Object*)out);
        return out;
        }

    // Enforce `final`. Without both halves it is an unsound promise — a way to
    // silently devirtualise a method that IS overridden.
    //
    //  1. A subclass may not override a final method.
    //  2. A final method may not satisfy a protocol requirement: a protocol
    //     call dispatches through a vtable slot, and `final` is precisely a
    //     request for no slot, so the call would have nothing to land on.
    //
    // Both were missing here, so the shipped compiler accepted what the
    // reference rejects (private:docs/bugs/078).
    //
    // Walked in PROGRAM order, not over the class map: a map walk is hash
    // ordered, and diagnostics that come out in a different order on different
    // runs are the shape of bug this tree has been bitten by before.
    // A class that lists a protocol must implement every method the protocol
    // does not mark `optional` (its own or inherited); an unknown protocol name
    // is an error too. The reference makes this check while it fills protocol
    // slots (computeVirtualMethodTables); without it the shipped compiler built
    // the class, and the empty slot was a call through null at run time
    // (bug 622). Same order as the reference — classes by name, then each
    // class's protocols as listed, then each protocol's methods — so the two
    // report the same errors in the same order.
    void checkConformance()
        {
        if (_vt.total() == (u32)0)
            return; // nothing virtual: the reference fills no slots and checks nothing
        Array* names = _classes.allKeys();
        Vtable.sortStrings(names);
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)_classes.get((Hashable*)names.get(i));
            // `-` is the parser's "no protocols"
            if (cls == 0 || cls.extra() == 0 || cls.extra().equals(String.withCString("-")))
                continue;
            Array* protos = commaSplit(cls.extra());
            for (u32 pi = (u32)0; pi < protos.count(); pi = pi + (u32)1)
                {
                String* pn = (String*)protos.get(pi);
                if (pn.byteLength() == (u32)0)
                    continue;
                Node* proto = (Node*)_protocols.get((Hashable*)pn);
                if (proto == 0)
                    {
                    String* e = String.withCString("Unknown protocol '");
                    e.append(pn);
                    e.appendCString("' on class '");
                    e.append(cls.name());
                    e.appendCString("'");
                    _errorAt(e, cls);
                    continue;
                    }
                for (u32 mi = (u32)0; mi < proto.kidCount(); mi = mi + (u32)1)
                    {
                    Node* req = proto.kid(mi);
                    if (req.kind() != (u16)nkMethodDecl || req.hasFlag((u32)NF_OPTIONAL))
                        continue;
                    bool found = false;
                    for (Node* c = cls; c != 0 && !found; c = parentOf(c))
                        found = Vtable.matching(c, req) != 0;
                    if (found)
                        continue;
                    String* e = String.withCString("Class '");
                    e.append(cls.name());
                    e.appendCString("' claims conformance to protocol '");
                    e.append(pn);
                    e.appendCString("' but doesn't implement '");
                    e.append(req.name());
                    e.appendCString("'");
                    _errorAt(e, cls);
                    }
                }
            }
        }

    void checkFinalMethods(Node* program)
        {
        for (u32 ci = (u32)0; ci < program.kidCount(); ci = ci + (u32)1)
            {
            Node* cls = program.kid(ci);
            if (cls.kind() != (u16)nkClassDecl)
                continue;
            for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
                {
                Node* m = cls.kid(j);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;

                // (1) does this method override a `final` one in an ancestor?
                for (Node* a = parentOf(cls); a != 0; a = parentOf(a))
                    {
                    Node* am = Vtable.matching(a, m);
                    if (am == 0)
                        continue;
                    if (!am.hasFlag((u32)NF_FINAL))
                        continue;
                    String* e = String.withCString("'");
                    e.append(cls.name());
                    e.appendCString("' cannot override '");
                    e.append(a.name());
                    e.appendByte((u8)'.');
                    e.append(am.name());
                    e.appendCString("' — it is declared 'final'");
                    _errorAt(e, m);
                    }
                if (!m.hasFlag((u32)NF_FINAL))
                    continue;

                // (2) does this final method satisfy a protocol the class adopts?
                for (Node* c = cls; c != 0; c = parentOf(c))
                    {
                    if (c.extra() == 0)
                        continue;
                    Array* protos = commaSplit(c.extra());
                    for (u32 pi = (u32)0; pi < protos.count(); pi = pi + (u32)1)
                        {
                        String* pn = (String*)protos.get(pi);
                        Node* proto = (Node*)_protocols.get((Hashable*)pn);
                        if (proto == 0)
                            continue;
                        if (Vtable.matching(proto, m) == 0)
                            continue;
                        String* e = String.withCString("'");
                        e.append(cls.name());
                        e.appendByte((u8)'.');
                        e.append(m.name());
                        e.appendCString("' cannot be 'final' — it implements protocol '");
                        e.append(pn);
                        e.appendCString("', and a protocol call dispatches through a ");
                        e.appendCString("vtable slot that 'final' removes");
                        _errorAt(e, m);
                        }
                    }
                }
            }
        }

    // `A,B,C` -> the three names. A class's adopted protocols are held as one
    // comma-joined spelling.
    Array* commaSplit(String* list)
        {
        Array* out = new Array();
        String* cur = String.withCString("");
        for (u32 i = (u32)0; i < list.byteLength(); i = i + (u32)1)
            {
            u8 ch = list.byteAt(i);
            if (ch == (u8)',')
                {
                if (cur.byteLength() > (u32)0)
                    out.add((Object*)cur);
                cur = String.withCString("");
                continue;
                }
            cur.appendByte(ch);
            }
        if (cur.byteLength() > (u32)0)
            out.add((Object*)cur);
        return out;
        }

    void analyse(Node* program)
        {
        if (program == 0)
            return;
        collectDeclarations(program);
        checkParents();
        findCycles();
        findValueRings();
        _vt.setCyclic(_cyclic);
        synthesiseDescriptions();
        Mangle.setTables(_classes, _structs);
        Overload.setHierarchy(parentMap(), conformanceMap());
        mangleFunctions();
        mangleMethods();
        // Slots need the mangled names (a label carries one) and nothing from
        // the body walk, so they are settled between the two. Chain slots
        // (§4.2) come FIRST: a category method on an external class must not
        // take a vtable slot, so its labels are excluded from the assignment.
        computeChainSlots();
        _vt.assign(_classes, _protocols);
        stampClassSlots();
        stampChainSlots();
        // AFTER the numbering, deliberately: a synthesised init must not become
        // an override root. The original synthesises them past that point too,
        // and running it earlier gave `Gfx.init` a slot the original never
        // allocates — every later slot then shifted.
        synthesiseInits();
        markAutoSuperInit();
        checkFinalMethods(program);
        checkConformance();
        collectFormatWrappers(program);
        // `:operator(pattern)` against its method, before any expression can
        // resolve to one.
        checkOperatorMethods(program);
        typeProgram(program);
        checkCloaked();
        checkVariadicReentrance();
        checkRetainCycles(program);
        }

    // ── retain cycles ───────────────────────────────────────────────────
    // As the reference's checkRetainCycles: every class a root in declaration
    // order, strong class-pointer fields (its own, then its ancestors') as
    // edges, edges only into classes declared at or after the root, each
    // class expanded once per root; a cycle is reported at the field that
    // closes it. A field of the class's own type is not a cycle; `weak:`
    // fields are not edges; typed collections are not either.
    Array* _rcClasses;
    Array* _rcPath;
    Map* _rcVisited;
    u32 rcIndexOf(String* name)
        {
        for (u32 i = (u32)0; i < _rcClasses.count(); i = i + (u32)1)
            if (((Node*)_rcClasses.get(i)).name().equals(name))
                return i;
        return (u32)$FFFFFFFF;
        }
    void checkRetainCycles(Node* program)
        {
        _rcClasses = new Array();
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            {
            Node* cls = program.kid(i);
            if (cls.kind() != (u16)nkClassDecl || cls.name() == 0)
                continue;
            if (rcIndexOf(cls.name()) != (u32)$FFFFFFFF)
                continue;
            _rcClasses.add((Object*)cls);
            }
        for (u32 r = (u32)0; r < _rcClasses.count(); r = r + (u32)1)
            {
            _rcPath = new Array();
            _rcVisited = new Map();
            retainCycleFrom((Node*)_rcClasses.get(r), r);
            }
        }
    // `weak:` is for class pointers alone — a scalar or a function pointer
    // has no reference count to watch — as the reference's
    // validateWeakQualifierOnType says at every declaration: a local, an
    // ivar, a parameter. An array of weak pointers is judged by its element.
    void checkWeakSpelling(String* t, Node* at)
        {
        if (t == 0 || t.byteIndexOf(String.withCString("weak:")) == (u32)$FFFFFFFF)
            return;
        String* e = t;
        u32 lb = e.indexOfByte((u8)'[');
        if (lb != String.notFound())
            e = e.substringBytes((u32)0, lb);
        String* q = Overload._unqualify(e);
        bool ok = false;
        u32 n = q.byteLength();
        if (n >= (u32)2 && (q.byteAt(n - (u32)1) == (u8)'*' || q.byteAt(n - (u32)1) == (u8)'@'))
            {
            String* name = q.substringBytes((u32)0, n - (u32)1);
            ok = _classes.get((Hashable*)name) != 0 || _protocols.get((Hashable*)name) != 0;
            }
        if (!ok)
            {
            String* m = String.withCString("`weak:` requires a class pointer, not `");
            m.append(t);
            m.appendCString("`");
            _errorAt(m, at);
            }
        }

    // The class a strong field's spelling points at, or 0: a pointer, not
    // weak:, one sigil, and a class of this unit.
    String* rcTargetOf(String* t)
        {
        if (t == 0 || !Types.isPointer(t))
            return (String*)0;
        if (t.byteIndexOf(String.withCString("weak:")) != (u32)$FFFFFFFF)
            return (String*)0;
        String* q = Overload._unqualify(t);
        u32 n = q.byteLength();
        if (n < (u32)2)
            return (String*)0;
        u8 last = q.byteAt(n - (u32)1);
        if (last != (u8)'*' && last != (u8)'@')
            return (String*)0;
        String* name = q.substringBytes((u32)0, n - (u32)1);
        if (_classes.get((Hashable*)name) == 0)
            return (String*)0;
        return name;
        }
    void retainCycleFrom(Node* cls, u32 rootIndex)
        {
        _rcVisited.set((Hashable*)cls.name(), (Object*)cls);
        String* rootName = ((Node*)_rcClasses.get(rootIndex)).name();
        // each ancestor once: an inheritance cycle is an error reported
        // elsewhere, and the walk must not follow it round and round
        Map* seen = new Map();
        for (Node* c = cls; c != 0 && seen.get((Hashable*)c.name()) == 0; c = parentOf(c))
            {
            seen.set((Hashable*)c.name(), (Object*)c);
            for (u32 j = (u32)0; j < c.kidCount(); j = j + (u32)1)
                {
                Node* f = c.kid(j);
                if (f.kind() == (u16)nkMethodDecl || f.name() == 0)
                    continue;
                String* target = rcTargetOf(f.op());
                if (target == 0)
                    continue;
                u32 ti = rcIndexOf(target);
                if (ti == (u32)$FFFFFFFF || ti < rootIndex)
                    continue;
                String* part = String.withString(c.name());
                part.appendByte((u8)'.');
                part.append(f.name());
                part.appendCString(" holds ");
                part.append(target);
                if (target.equals(rootName))
                    {
                    // A field of the class's own type is a list or a tree,
                    // not a cycle: only loops through two or more classes.
                    if (_rcPath.count() == (u32)0)
                        continue;
                    u32 n = _rcPath.count() + (u32)1;
                    String* chain = new String();
                    for (u32 i = (u32)0; i < _rcPath.count(); i = i + (u32)1)
                        {
                        if (i > (u32)0)
                            chain.appendCString(", ");
                        chain.append((String*)_rcPath.get(i));
                        }
                    if (n > (u32)1)
                        chain.appendCString(" and ");
                    chain.append(part);
                    String* msg = String.withCString("a strong reference cycle: ");
                    msg.append(chain);
                    if (n == (u32)2)
                        msg.appendCString(", so ARC can free neither; mark one side weak:");
                    else
                        msg.appendCString(", so ARC can free none of them; mark one side weak:");
                    _warnAt(String.withCString("retain-cycle"), msg, f);
                    continue;
                    }
                if (_rcVisited.get((Hashable*)target) != 0)
                    continue;
                Node* next = (Node*)_classes.get((Hashable*)target);
                if (next == 0)
                    continue;
                _rcPath.add((Object*)part);
                retainCycleFrom(next, rootIndex);
                _rcPath.removeLast();
                }
            }
        }

    // ── Pass 2: types ───────────────────────────────────────────────────
    // Bodies are walked with a scope chain, and every expression gets the
    // spelling of its resolved type. What is NOT here yet — calls, members,
    // subscripts, `auto` — is left unstamped rather than guessed: an absent
    // annotation is a visible difference in the harness, a wrong one is a lie
    // that later passes would build on.
    // Move a category/extension's members onto the class it names. The part's
    // children are ivars and methods in source order, exactly as the class's
    // own are, so appending preserves both. The ivar order that results is the
    // merge order, which the caller fixes by walking declarations in order.
    // A class node's children are its ivars and its methods; anything that is
    // not a method is an ivar.
    bool categoryAddsIvars(Node* part)
        {
        for (u32 i = (u32)0; i < part.kidCount(); i = i + (u32)1)
            if (part.kid(i).kind() != (u16)nkMethodDecl)
                return true;
        return false;
        }

    void mergeCategory(Node* host, Node* part)
        {
        for (u32 i = (u32)0; i < part.kidCount(); i = i + (u32)1)
            {
            Node* m = part.kid(i);
            // Ivars go before the methods, methods at the end — the reference
            // keeps two lists and this node keeps one, so the position has to
            // be chosen here or the merged dump reorders.
            if (m.kind() == (u16)nkMethodDecl)
                host.add(m);
            else
                host.addIvarBeforeMethods(m);
            }
        }

    void typeProgram(Node* program)
        {
        // Category/extension nodes merged below; removed from the program once
        // the walk is done, so no later pass sees a spent part.
        Array* spentParts = new Array();
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            {
            Node* d = program.kid(i);
            u16 k = d.kind();
            if (k == (u16)nkVariableDecl)
                {
                // A global's INITIALISER is an expression like any other and
                // gets typed like one — `u8 g = 0;` types that 0.
                //
                // `u8 g_buf[10] = 0..10;` included: a range is legal in an
                // array initialiser at FILE scope exactly as it is inside a
                // function, so the same gate has to be set here. The local
                // walk set it and this one did not, so the global form
                // recorded "range outside an array initialiser" — invisible
                // only because nothing read sema's errors.
                bool saveRange = _rangeIsInitialiser;
                _rangeIsInitialiser = isArrayLike(d.op());
                pushScope();
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    typeExpr(d.kid(j));
                popScope();
                _rangeIsInitialiser = saveRange;
                // `auto g = expr;` — the type is the initialiser's, now that
                // the initialiser HAS one. The declaration is stamped and
                // registered here rather than in the forward-reference
                // pre-pass, which runs before any expression is typed and so
                // has nothing to infer from (see the pre-pass). The reference
                // does the same: an auto global skips that pre-pass, is given
                // its initialiser's type, and is defined under it. Before this
                // the word "auto" stayed in the tree and lowering refused the
                // declaration outright — `unsupported: type auto` — where the
                // reference compiled and ran it.
                if (_isOp(d.op(), "auto") && d.kidCount() > (u32)0)
                    {
                    String* inferred = d.kid((u32)0).ty();
                    // The initialiser's own type, or — with no type on the
                    // node, as for a literal the walk left alone — the same
                    // capped ladder the reference's inferTypeFromLiteral:
                    // walks, then u8 for anything else.
                    if (inferred == 0 && d.kid((u32)0).kind() == (u16)nkInt)
                        inferred = Types.forFoldedValue(d.kid((u32)0).num());
                    if (inferred == 0)
                        inferred = String.withCString("u8");
                    d.setOp(inferred);
                    if (d.name() != 0)
                        _globals.set((Hashable*)d.name(), (Object*)inferred);
                    }
                d.setTy(d.op());
                }
            else if (k == (u16)nkFunctionDecl)
                {
                typeCallable(d, (Node*)0);
                }
            else if (k == (u16)nkClassDecl)
                {
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    {
                    Node* m = d.kid(j);
                    if (m.kind() == (u16)nkMethodDecl)
                        typeCallable(m, d);
                    else if (m.kind() == (u16)nkVariableDecl)
                        {
                        checkWeakSpelling(m.op(), m);
                        // An ivar with an inherited name is refused, as the
                        // reference refuses it: two slots one name, and a
                        // method of either class reading the wrong one.
                        bool shadowed = false;
                        for (Node* c = parentOf(d); c != 0 && !shadowed; c = parentOf(c))
                            for (u32 q = (u32)0; q < c.kidCount() && !shadowed; q = q + (u32)1)
                                {
                                Node* a = c.kid(q);
                                if (a.kind() == (u16)nkVariableDecl && a.name().equals(m.name()))
                                    {
                                    _errorAt(String.withFormat("Subclass '%s' redeclares ivar '%s' inherited from '%s'",
                                                               d.name().cString(), m.name().cString(), c.name().cString()), m);
                                    shadowed = true;
                                    }
                                }
                        // An ivar named like a method an ANCESTOR declares:
                        // `s.hash` resolves to the method, so a load calls
                        // Object.hash() while a store writes the ivar.
                        bool clash = false;
                        u32 hops = (u32)0;
                        for (Node* c = parentOf(d); c != 0 && c != d && !clash && hops <= _classes.count(); c = parentOf(c))
                            {
                            hops = hops + (u32)1;
                            for (u32 q = (u32)0; q < c.kidCount() && !clash; q = q + (u32)1)
                                {
                                Node* a = c.kid(q);
                                if (a.kind() == (u16)nkMethodDecl && a.name() != 0 && a.name().equals(m.name()))
                                    {
                                    _errorAt(String.withFormat("ivar '%s' of '%s' has the name of a method of '%s' — 'x.%s' would call the method; rename the ivar",
                                                               m.name().cString(), d.name().cString(), c.name().cString(), m.name().cString()), m);
                                    clash = true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

    // One function or method: parameters (and, for a method, the class's
    // ivars) go into a fresh scope, then the body is walked.
    // Propagate the parser's per-CALL forwarding flag up to the enclosing
    // declaration, so lowering can stamp `vaforward` on its symbol. The
    // original does the same thing from checkVarargForwardAt:. private:docs/bugs/047.
    void markVaForward(Node* n, Node* decl)
        {
        if (n == 0 || decl == 0)
            return;
        if ((n.kind() == (u16)nkCall || n.kind() == (u16)nkMethodCall) && n.hasFlag((u32)NF_VAFWD))
            decl.addFlag((u32)NF_VAFWD);
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            markVaForward(n.kid(i), decl);
        }

    void typeCallable(Node* decl, Node* owner)
        {
        _curClass = owner;
        _curMethod = decl;
        _curReturn = decl.op();
        _curLabel = callableLabel(decl, owner);
        _curThrows = decl.hasFlag((u32)NF_THROWS);
        _tryDepth = (u32)0;
        pushScope();
        _fnScopeAt = _scopes.count() - (u32)1;
        // `self` is the receiver: a pointer to the class whose method this is.
        if (owner != 0 && owner.name() != 0)
            {
            String* selfTy = String.withString(owner.name());
            selfTy.appendByte((u8)'*');
            define(String.withCString("self"), selfTy);
            }
        // A class NAME can be declared twice in one unit — two include paths
        // both supplying a `Gfx15`, say. Only one of them is the registered
        // class; the other keeps its own ivars but is never linked into the
        // hierarchy, so its methods do NOT see the parent's fields. Matching
        // that is what makes the four Gfx files agree.
        bool orphan = false;
        if (owner != 0 && owner.name() != 0)
            {
            Node* reg = (Node*)_classes.get((Hashable*)owner.name());
            if (reg != 0 && reg != owner)
                orphan = true;
            }
        // INHERITED ivars are in scope too — a subclass's method reads its
        // parent's fields by bare name, static ones included.
        for (Node* c = owner; c != 0; c = parentOf(c))
            {
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                {
                Node* iv = c.kid(i);
                if (iv.kind() == (u16)nkVariableDecl)
                    define(iv.name(), iv.op());
                }
            if (orphan)
                break;
            }
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* p = decl.kid(i);
            if (p.kind() == (u16)nkParam)
                {
                checkWeakSpelling(p.op(), p);
                define(p.name(), p.op());
                }
            }
        // A C-ABI callee (a C import, or a bodyless variadic — the two forms
        // XTFnIsCABI recognises) cannot take a `callback`. A callback is a
        // two-word {recv, code} pair with no C representation — a bound method
        // is not a C function pointer — and marshalling both words shifts every
        // following argument into the wrong register, silently (bug 165d: the
        // arg after a non-last callback was corrupted). Use `pointer` for a C
        // function pointer, casting a widened free function to it where meant.
        // Free functions only (owner == 0), matching the original.
        if (owner == 0)
            {
            bool cbHasBody = false;
            for (u32 bi = (u32)0; bi < decl.kidCount(); bi = bi + (u32)1)
                if (decl.kid(bi).kind() == (u16)nkBlock)
                    cbHasBody = true;
            if (decl.hasFlag((u32)NF_CABI) || (decl.hasFlag((u32)NF_VARARGS) && !cbHasBody))
                {
                for (u32 pi = (u32)0; pi < decl.kidCount(); pi = pi + (u32)1)
                    {
                    Node* cbp = decl.kid(pi);
                    if (cbp.kind() == (u16)nkParam && isBoundSignature(cbp.op()))
                        {
                        String* em = String.withCString("a C-ABI function cannot take a `callback` parameter ('");
                        em.append(cbp.name());
                        em.appendCString("') — a callback is a two-word pair with no C representation; use `pointer`");
                        _errorAt(em, decl);
                        }
                    }
                }
            }
        _fnPackingCallee = (String*)0;
        _fnForwardsVarargs = false;
        Node* fnBody = (Node*)0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* b = decl.kid(i);
            if (b.kind() == (u16)nkBlock)
                {
                typeStmt(b);
                markVaForward(b, decl);
                fnBody = b;
                }
            }
        // A non-void FREE function whose body can reach its closing brace
        // lowers to `Unreachable` and traps at run time; name it here, where
        // the reader can still write the `return` (bug 553). `main` is exempt:
        // a fall-off there is normalised to `return 0`. Methods are left for
        // the reference to lead with.
        if (owner == 0 && fnBody != 0 && decl.name() != 0
            && !decl.name().equals(String.withCString("main")))
            {
            bool isVoid = decl.op() == 0 || _isOp(decl.op(), "void");
            if (!isVoid && statementCanFallThrough(fnBody))
                {
                String* wmsg = String.withCString("control reaches the end of non-void function '");
                wmsg.append(decl.name());
                wmsg.appendCString("' without returning a value");
                _warnAt(String.withCString("return-type"), wmsg, decl);
                }
            }
        // On every target but arm9 a variadic's arguments live in ONE shared
        // buffer filled by the caller. A forwarder works precisely because it
        // does not touch that buffer; calling anything variadic WITH arguments
        // overwrites it, and what gets overwritten is the pending caller's
        // pack. Either order is wrong, so this asks at the end of the body.
        if (_fnPackingCallee != 0 && _fnForwardsVarargs)
            {
            String* e = String.withCString("'");
            e.append(_fnPackingCallee);
            e.appendCString("' packs its own variadic arguments, and this function also ");
            e.appendCString("forwards with '...' — they share one argument buffer, so the packing ");
            e.appendCString("call overwrites the arguments being forwarded. Move the packing call ");
            e.appendCString("into a separate function, or build the text with String.withFormat ");
            e.appendCString("and print that");
            _errorAt(e, _fnPackingCall);
            }
        if (fnBody != 0)
            escapeWalkBody(fnBody);
        if (fnBody != 0 && _cntW >= (u32)8)
            lengthWalk(fnBody, decl.op() != 0 ? firstReturn(decl.op()) : (String*)0);
        if (fnBody != 0)
            gcWalkStmt(fnBody, new Map());
        noteStackUse(decl, owner, fnBody);
        noteCallable(decl, owner);
        popScope();
        _curLabel = (String*)0;
        _curClass = (Node*)0;
        _getterOwner = (String*)0;
        _setterOwner = (String*)0;
        _curReturn = (String*)0;
        }

    // ── `-Wunguarded-action`: a callback called without a test ───────────
    // The reference's GuardCheck, walk for walk. A stored `^` empties when its
    // receiver dies, so `if (f) f()` is the contract; a binding is GUARDED
    // once tested and until assigned. Joins intersect; a diverging arm
    // (return, break, continue) contributes nothing, which is how
    // `if (!f) return;` guards what follows; only local bindings are tracked.
    // The guarded set is a Map used as a set of names.
    String* gcBinding(Node* n)
        {
        if (n == 0 || n.kind() != (u16)nkIdent || n.ty() == 0 || !isBoundSignature(n.ty()))
            return (String*)0;
        return n.name();
        }

    bool gcIsNull(Node* n)
        {
        if (n == 0)
            return false;
        if (n.kind() == (u16)nkCast)
            return n.kidCount() > (u32)0 && gcIsNull(n.kid((u32)0));
        return n.kind() == (u16)nkInt && n.num() == (i64)0;
        }

    // The binding a condition proves set when taken: `f`, `f != 0`, `f && x`.
    String* gcTruthy(Node* c)
        {
        if (c == 0)
            return (String*)0;
        if (c.kind() == (u16)nkCast)
            return c.kidCount() > (u32)0 ? gcTruthy(c.kid((u32)0)) : (String*)0;
        String* d = gcBinding(c);
        if (d != 0)
            return d;
        if (c.kind() == (u16)nkBinary && c.kidCount() >= (u32)2)
            {
            if (_isOp(c.op(), "!="))
                {
                String* l = gcBinding(c.kid((u32)0));
                if (l != 0 && gcIsNull(c.kid((u32)1)))
                    return l;
                String* r = gcBinding(c.kid((u32)1));
                if (r != 0 && gcIsNull(c.kid((u32)0)))
                    return r;
                }
            if (_isOp(c.op(), "&&"))
                {
                String* l = gcTruthy(c.kid((u32)0));
                if (l != 0)
                    return l;
                return gcTruthy(c.kid((u32)1));
                }
            }
        return (String*)0;
        }

    // The binding a condition proves EMPTY when taken (`!f`, `f == 0`), so
    // set when not taken; `!f || x` too, both halves false there.
    String* gcFalsy(Node* c)
        {
        if (c == 0)
            return (String*)0;
        if (c.kind() == (u16)nkCast)
            return c.kidCount() > (u32)0 ? gcFalsy(c.kid((u32)0)) : (String*)0;
        if (c.kind() == (u16)nkUnary && _isOp(c.op(), "!") && c.kidCount() > (u32)0)
            return gcTruthy(c.kid((u32)0));
        if (c.kind() == (u16)nkBinary && c.kidCount() >= (u32)2)
            {
            if (_isOp(c.op(), "||"))
                {
                String* l = gcFalsy(c.kid((u32)0));
                if (l != 0)
                    return l;
                return gcFalsy(c.kid((u32)1));
                }
            if (_isOp(c.op(), "=="))
                {
                String* l = gcBinding(c.kid((u32)0));
                if (l != 0 && gcIsNull(c.kid((u32)1)))
                    return l;
                String* r = gcBinding(c.kid((u32)1));
                if (r != 0 && gcIsNull(c.kid((u32)0)))
                    return r;
                }
            }
        return (String*)0;
        }

    static Map* gcCopy(Map* g)
        {
        Map* c = new Map();
        Array* ks = g.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            c.set((Hashable*)ks.get(i), ks.get(i));
        return c;
        }

    // g becomes what is in both g's copy a and b.
    static void gcSetTo(Map* g, Map* a, Map* b)
        {
        Array* old = g.allKeys();
        for (u32 i = (u32)0; i < old.count(); i = i + (u32)1)
            g.remove((Hashable*)old.get(i));
        Array* ks = a.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            if (b == (Map*)0 || b.get((Hashable*)ks.get(i)) != (Object*)0)
                g.set((Hashable*)ks.get(i), ks.get(i));
        }

    void gcWalkExpr(Node* n, Map* g)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        if (k == (u16)nkCall)
            {
            for (u32 i = (u32)0; i < (u32)n.num() && i < n.kidCount(); i = i + (u32)1)
                gcWalkExpr(n.kid(i), g);
            // A call through a callback VARIABLE (a callee expression has no name to track).
            if (n.boundCall() && n.kidCount() <= (u32)n.num() && n.name() != 0 && n.name().byteLength() > (u32)0
                && g.get((Hashable*)n.name()) == (Object*)0)
                {
                String* w = String.withCString("`");
                w.append(n.name());
                w.appendCString("` is a callback and is called without being checked \u2014 it empties when its "
                                "receiver dies, and calling it then dispatches through a dead object. Guard it: `if (");
                w.append(n.name());
                w.appendCString(") { ");
                w.append(n.name());
                w.appendCString("(\u2026); }`");
                _warnAt(String.withCString("unguarded-action"), w, n);
                }
            return;
            }
        if (k == (u16)nkAssign && n.kidCount() >= (u32)2)
            {
            gcWalkExpr(n.kid((u32)1), g);
            String* dst = gcBinding(n.kid((u32)0));
            if (dst != 0)
                g.remove((Hashable*)dst);
            else
                gcWalkExpr(n.kid((u32)0), g);
            return;
            }
        if (k == (u16)nkBinary && n.kidCount() >= (u32)2)
            {
            gcWalkExpr(n.kid((u32)0), g);
            if (_isOp(n.op(), "&&"))
                {
                String* t = gcTruthy(n.kid((u32)0));
                if (t != 0)
                    {
                    Map* inner = Sema.gcCopy(g);
                    inner.set((Hashable*)t, (Object*)t);
                    gcWalkExpr(n.kid((u32)1), inner);
                    return;
                    }
                }
            gcWalkExpr(n.kid((u32)1), g);
            return;
            }
        if (k == (u16)nkTernary && n.kidCount() >= (u32)3)
            {
            gcWalkExpr(n.kid((u32)0), g);
            String* tb = gcTruthy(n.kid((u32)0));
            Map* thenG = g;
            if (tb != 0)
                {
                thenG = Sema.gcCopy(g);
                thenG.set((Hashable*)tb, (Object*)tb);
                }
            gcWalkExpr(n.kid((u32)1), thenG);
            gcWalkExpr(n.kid((u32)2), g);
            return;
            }
        if ((k == (u16)nkUnary || k == (u16)nkCast) && n.kidCount() > (u32)0)
            {
            gcWalkExpr(n.kid((u32)0), g);
            return;
            }
        if (k == (u16)nkMethodCall)
            {
            for (u32 i = (u32)0; i <= (u32)n.num() && i < n.kidCount(); i = i + (u32)1)
                gcWalkExpr(n.kid(i), g);
            return;
            }
        }

    // A statement; true when control cannot fall out of it.
    bool gcWalkStmt(Node* n, Map* g)
        {
        if (n == 0)
            return false;
        u16 k = n.kind();
        if (k == (u16)nkBlock)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                if (gcWalkStmt(n.kid(i), g))
                    return true;
            return false;
            }
        if (k == (u16)nkReturn)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                gcWalkExpr(n.kid(i), g);
            return true;
            }
        if (k == (u16)nkBreak || k == (u16)nkContinue)
            return true;
        if (k == (u16)nkIf && n.kidCount() >= (u32)2)
            {
            Node* cond = n.kid((u32)0);
            gcWalkExpr(cond, g);
            String* truthy = gcTruthy(cond);
            String* falsy = gcFalsy(cond);
            Map* thenG = Sema.gcCopy(g);
            if (truthy != 0)
                thenG.set((Hashable*)truthy, (Object*)truthy);
            bool thenDiverges = gcWalkStmt(n.kid((u32)1), thenG);
            Map* elseG = Sema.gcCopy(g);
            if (falsy != 0)
                elseG.set((Hashable*)falsy, (Object*)falsy);
            bool elseDiverges = n.kidCount() > (u32)2 ? gcWalkStmt(n.kid((u32)2), elseG) : false;
            if (thenDiverges && elseDiverges)
                return true;
            if (thenDiverges)
                Sema.gcSetTo(g, elseG, (Map*)0);
            else if (elseDiverges)
                Sema.gcSetTo(g, thenG, (Map*)0);
            else
                Sema.gcSetTo(g, thenG, elseG);
            return false;
            }
        if (k == (u16)nkWhile && n.kidCount() >= (u32)2)
            {
            gcWalkExpr(n.kid((u32)0), g);
            String* truthy = gcTruthy(n.kid((u32)0));
            Map* bodyG = Sema.gcCopy(g);
            if (truthy != 0)
                bodyG.set((Hashable*)truthy, (Object*)truthy);
            gcWalkStmt(n.kid((u32)1), bodyG);
            return false;
            }
        if (k == (u16)nkExprStatement)
            {
            if (n.kidCount() > (u32)0)
                gcWalkExpr(n.kid((u32)0), g);
            return false;
            }
        if (k == (u16)nkForCStyle)
            {
            Node* body = (Node*)0;
            Node* step = (Node*)0;
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                Node* c = n.kid(i);
                if (c.kind() == (u16)nkMarkerInit)
                    {
                    for (u32 j = (u32)0; j < c.kidCount(); j = j + (u32)1)
                        gcWalkStmt(c.kid(j), g);
                    }
                else if (c.kind() == (u16)nkMarkerCond)
                    {
                    for (u32 j = (u32)0; j < c.kidCount(); j = j + (u32)1)
                        gcWalkExpr(c.kid(j), g);
                    }
                else if (c.kind() == (u16)nkMarkerStep)
                    step = c;
                else
                    body = c;
                }
            Map* bodyG = Sema.gcCopy(g);
            gcWalkStmt(body, bodyG);
            for (u32 j = (u32)0; step != 0 && j < step.kidCount(); j = j + (u32)1)
                gcWalkExpr(step.kid(j), bodyG);
            return false;
            }
        if (k == (u16)nkForIn)
            {
            if (n.kidCount() > (u32)0)
                gcWalkStmt(n.kid(n.kidCount() - (u32)1), Sema.gcCopy(g));
            return false;
            }
        if (k == (u16)nkVariableDecl)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                gcWalkExpr(n.kid(i), g);
            if (n.name() != 0)
                g.remove((Hashable*)n.name());
            return false;
            }
        return false;
        }

    // ── `.length` by destination (#321) ──────────────────────────────────
    // On the 64-bit rows a built-in `.length` (an array's or a heap pointer's)
    // is u64, unless where it is used wants 32 bits or fewer: assigned or
    // initialising such an integer, returned as one, cast to one, or passed
    // to a parameter of one. There it is the u32 form, which Lower checks: a
    // count past 2^32-1 stops the program rather than wrap. A call resolves
    // with it as u32, so every overload set picks what it always did.
    bool dualLength(Node* e)
        {
        if (_cntW < (u32)8 || e == 0 || e.kind() != (u16)nkMember || !_isOp(e.name(), "length"))
            return false;
        if (e.ty() == 0 || !_isOp(e.ty(), "u64") || e.kidCount() == (u32)0)
            return false;
        String* recv = e.kid((u32)0).ty();
        if (recv == 0)
            return false;
        return isArrayLike(recv) || (Types.isPointer(recv) && _classes.get((Hashable*)classNameOf(recv)) == 0
                                     && _protocols.get((Hashable*)classNameOf(recv)) == 0);
        }

    // The type a call scores an argument at.
    String* scoreTy(Node* a)
        {
        return dualLength(a) ? String.withCString("u32") : a.ty();
        }

    void narrowLength(Node* e, String* want)
        {
        if (want == 0 || !dualLength(e))
            return;
        String* w = Overload._unqualify(want);
        if (w != 0 && Types.isInteger(w) && Types.byteWidth(w) <= (u32)4)
            e.setTy(String.withCString("u32"));
        }

    void narrowLengthArgs(Node* decl, Node* call, u32 argBase)
        {
        if (_cntW < (u32)8 || decl == 0)
            return;
        u32 pi = (u32)0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* p = decl.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            u32 ai = argBase + pi;
            if (ai < call.kidCount())
                narrowLength(call.kid(ai), p.op());
            pi = pi + (u32)1;
            }
        }

    // After a body is typed: the declarations, assignments, returns and casts
    // whose destination is narrower than 64 bits take the u32 form.
    void lengthWalk(Node* n, String* ret)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        if (k == (u16)nkMethodDecl || k == (u16)nkFunctionDecl)
            return; // a nested body is walked with its own return type
        if (k == (u16)nkVariableDecl && n.kidCount() > (u32)0)
            narrowLength(n.kid((u32)0), n.op());
        else if (k == (u16)nkAssign && n.kidCount() >= (u32)2 && _isOp(n.op(), "="))
            narrowLength(n.kid((u32)1), n.kid((u32)0).ty());
        else if (k == (u16)nkReturn && n.kidCount() > (u32)0)
            narrowLength(n.kid((u32)0), ret);
        else if (k == (u16)nkCast && n.kidCount() > (u32)0)
            narrowLength(n.kid((u32)0), n.name());   // a cast names its type
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            lengthWalk(n.kid(i), ret);
        }

    // ── Stack instances whose address escapes ────────────────────────────
    // As the reference's escWalk*: a stack class local dies at its block's
    // closing brace, so returning its address (or a pointer local holding it)
    // is refused, and storing it in a global, a heap object's field or an
    // OUTER stack instance's field is warned about. Only `&p`, `&p.f` and a
    // pointer local tagged as an alias carry the origin; `p.x` is a value.
    void escapeWalkBody(Node* body)
        {
        _escDepth = new Map();
        _escAlias = new Map();
        _escBlock = (u32)0;
        escWalk(body);
        _escDepth = (Map*)0;
        _escAlias = (Map*)0;
        }

    bool isStackClassType(String* t)
        {
        if (t == 0 || Types.isPointer(t) || isArrayLike(t))
            return false;
        return _classes.get((Hashable*)t) != 0;
        }

    String* escOrigin(Node* e)
        {
        if (e == 0)
            return (String*)0;
        u16 k = e.kind();
        if (k == (u16)nkUnary)
            {
            // `&p` of the whole instance moves p to the heap (#604), so only
            // a pointer into it (`&p.x`) can outlive it.
            if (_isOp(e.op(), "&") && e.kidCount() > (u32)0 && e.kid((u32)0).kind() != (u16)nkIdent)
                return escRootOf(e.kid((u32)0));
            return (String*)0;
            }
        if (k == (u16)nkIdent)
            return e.name() != 0 ? (String*)_escAlias.get((Hashable*)e.name()) : (String*)0;
        if (k == (u16)nkCast && e.kidCount() > (u32)0)
            return escOrigin(e.kid((u32)0));
        return (String*)0;
        }

    // `&c`, `&c.x`, `&c.x.y` all root at `c`; an arrow leaves the stack.
    String* escRootOf(Node* e)
        {
        if (e == 0)
            return (String*)0;
        if (e.kind() == (u16)nkIdent)
            {
            if (e.name() != 0 && _escDepth.get((Hashable*)e.name()) != 0)
                return e.name();
            return (String*)0;
            }
        if (e.kind() == (u16)nkMember && !e.hasFlag((u32)NF_ARROW) && e.kidCount() > (u32)0)
            return escRootOf(e.kid((u32)0));
        return (String*)0;
        }

    void escWalk(Node* n)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        // The reference walks neither a switch nor a try/defer body.
        if (k == (u16)nkSwitch || k == (u16)nkTry || k == (u16)nkDefer)
            return;
        if (k == (u16)nkBlock && !n.hasFlag((u32)NF_DECLLIST))
            {
            _escBlock = _escBlock + (u32)1;
            u32 depth = _escBlock;
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                escWalk(n.kid(i));
            // Drop the stack locals this block declared, and every alias of one.
            Array* dk = _escDepth.allKeys();
            for (u32 i = (u32)0; i < dk.count(); i = i + (u32)1)
                {
                Number* d = (Number*)_escDepth.get((Hashable*)dk.get(i));
                if (d != 0 && d.asU32() == depth)
                    _escDepth.remove((Hashable*)dk.get(i));
                }
            Array* ak = _escAlias.allKeys();
            for (u32 i = (u32)0; i < ak.count(); i = i + (u32)1)
                {
                String* orig = (String*)_escAlias.get((Hashable*)ak.get(i));
                if (orig != 0 && _escDepth.get((Hashable*)orig) == 0)
                    _escAlias.remove((Hashable*)ak.get(i));
                }
            _escBlock = _escBlock - (u32)1;
            return;
            }
        if (k == (u16)nkVariableDecl)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                escWalk(n.kid(i));
            String* t = n.op();
            if (n.name() == 0)
                return;
            if (isStackClassType(t))
                {
                _escDepth.set((Hashable*)n.name(), (Object*)Number.with(_escBlock));
                return;
                }
            if (t != 0 && Types.isPointer(t) && isStackClassType(pointeeOf(t)) && n.kidCount() > (u32)0)
                {
                String* origin = escOrigin(n.kid((u32)0));
                if (origin != 0)
                    _escAlias.set((Hashable*)n.name(), (Object*)origin);
                }
            return;
            }
        if (k == (u16)nkReturn)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                escWalk(n.kid(i));
                String* origin = escOrigin(n.kid(i));
                // `return &y.inner;` into a strong class pointer has its own
                // message (checkStackAddrStrong); one error is enough.
                if (origin != 0 && _curReturn != 0)
                    {
                    Array* rets = commaSplit(_curReturn);
                    if (i < rets.count() && isStackAddrStrong((String*)rets.get(i), n.kid(i)))
                        origin = (String*)0;
                    }
                if (origin != 0)
                    {
                    String* m = String.withCString("cannot return address or value derived from stack-allocated instance '");
                    m.append(origin);
                    m.appendCString("' — its storage dies when the enclosing block ends");
                    _errorAt(m, n);
                    }
                }
            return;
            }
        if (k == (u16)nkAssign && n.kidCount() >= (u32)2)
            {
            escWalk(n.kid((u32)1));
            if (_isOp(n.op(), "="))
                {
                String* origin = escOrigin(n.kid((u32)1));
                if (origin != 0)
                    escAssignTarget(n.kid((u32)0), origin, n);
                }
            escWalk(n.kid((u32)0));
            return;
            }
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            escWalk(n.kid(i));
        }

    void escAssignTarget(Node* lhs, String* origin, Node* at)
        {
        if (lhs.kind() == (u16)nkIdent && lhs.name() != 0)
            {
            String* nm = lhs.name();
            // A tracked local takes the alias; a local is no diagnostic.
            if (_escDepth.get((Hashable*)nm) != 0 || _escAlias.get((Hashable*)nm) != 0)
                {
                _escAlias.set((Hashable*)nm, (Object*)origin);
                return;
                }
            // The walk runs after the body's own scopes are gone, so what the
            // name can still reach is a parameter or a global — and only a
            // global outlives the instance.
            Map* fnScope = _scopes.count() > (u32)0 ? (Map*)_scopes.get(_scopes.count() - (u32)1) : (Map*)0;
            if (fnScope != 0 && fnScope.get((Hashable*)nm) != 0)
                return;
            if (_globals.get((Hashable*)nm) != 0)
                {
                String* w = String.withCString("storing address of stack-allocated '");
                w.append(origin);
                w.appendCString("' in global '");
                w.append(nm);
                w.appendCString("' may outlive its storage");
                _warnAt(String.withCString("escape"), w, at);
                }
            return;
            }
        if (lhs.kind() == (u16)nkMember && lhs.kidCount() > (u32)0)
            {
            if (lhs.hasFlag((u32)NF_ARROW))
                {
                String* w = String.withCString("storing address of stack-allocated '");
                w.append(origin);
                w.appendCString("' in heap-reachable field '");
                w.append(lhs.name());
                w.appendCString("' may outlive its storage");
                _warnAt(String.withCString("escape"), w, at);
                return;
                }
            String* baseOrigin = escOrigin(lhs.kid((u32)0));
            if (baseOrigin != 0 && !baseOrigin.equals(origin))
                {
                Number* bd = (Number*)_escDepth.get((Hashable*)baseOrigin);
                Number* od = (Number*)_escDepth.get((Hashable*)origin);
                if (bd != 0 && od != 0 && bd.asU32() < od.asU32())
                    {
                    String* w = String.withCString("storing address of inner stack-allocated '");
                    w.append(origin);
                    w.appendCString("' into outer stack-instance field '");
                    w.append(baseOrigin);
                    w.appendByte((u8)'.');
                    w.append(lhs.name());
                    w.appendCString("' — outer outlives inner");
                    _warnAt(String.withCString("escape"), w, at);
                    }
                }
            }
        }

    // `sink(&p)` where `sink` takes a strong class pointer: the callee would
    // retain an address that is not on the heap. As the reference's
    // checkStackInstanceStrongParamArgs, at the same call shapes.
    void checkStackStrongArgs(Node* call, Node* decl, u32 argBase, String* desc)
        {
        u32 pi = (u32)0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* p = decl.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            u32 ai = argBase + pi;
            pi = pi + (u32)1;
            if (ai >= call.kidCount())
                return;
            String* pt = p.op();
            Node* a = call.kid(ai);
            // A subclass instance passed by value into a superclass parameter
            // would be sliced (checkSliceByValue).
            if (pt != 0 && a.ty() != 0 && !Types.isPointer(pt) && !Types.isPointer(a.ty()))
                {
                String* site = String.withCString("argument ");
                site.append(String.withU32(pi));
                site.appendCString(" of ");
                site.append(desc);
                checkSliceByValue(pt, a.ty(), site.cString(), call);
                continue;
                }
            if (pt == 0 || !Types.isPointer(pt) || _classes.get((Hashable*)classNameOf(pt)) == 0)
                continue;
            if (a.kind() != (u16)nkUnary || !_isOp(a.op(), "&") || a.kidCount() == (u32)0)
                continue;
            Node* operand = a.kid((u32)0);
            if (!isStackClassType(operand.ty()))
                continue;
            // A local moves to the heap (#604); the other forms are refused
            // where they are stored (checkStackAddrStrong).
            if (isPromotableAddr(a))
                continue;
            String* inst = operand.kind() == (u16)nkIdent ? operand.name() : String.withCString("<stack instance>");
            String* m = String.withCString("cannot pass stack-allocated instance '");
            m.append(inst);
            m.appendCString("' as strong pointer parameter of ");
            m.append(desc);
            m.appendCString(" — the callee would retain a non-heap address; use `new ");
            m.append(classNameOf(pt));
            m.appendCString("(...)` or `");
            m.append(inst);
            m.appendCString(".clone()` instead");
            _errorAt(m, call);
            }
        }

    // What a name is where it is used: 1 a local or a parameter, 2 a field
    // (an ivar, read by bare name in a method), 3 a global. The callable's own
    // scope holds its parameters, `self` and the ivars; the blocks above it
    // hold locals.
    u32 nameKindOf(String* name)
        {
        u32 i = _scopes.count();
        while (i > (u32)0)
            {
            i = i - (u32)1;
            Map* sc = (Map*)_scopes.get(i);
            if (sc.get((Hashable*)name) == 0)
                continue;
            if (_curMethod == 0 || i != _fnScopeAt || _isOp(name, "self"))
                return (u32)1;
            for (u32 p = (u32)0; p < _curMethod.kidCount(); p = p + (u32)1)
                {
                Node* pn = _curMethod.kid(p);
                if (pn.kind() == (u16)nkParam && pn.name() != 0 && pn.name().equals(name))
                    return (u32)1;
                }
            return (u32)2;
            }
        if (_globals.get((Hashable*)name) != 0)
            return (u32)3;
        return (u32)2;
        }

    // The source spelling of an lvalue for a diagnostic: `y`, `q.inner`, `g[1]`.
    String* stackAddrText(Node* e)
        {
        if (e.kind() == (u16)nkIdent && e.name() != 0)
            return e.name();
        if (e.kind() == (u16)nkMember && e.kidCount() > (u32)0)
            {
            String* s = String.withString(stackAddrText(e.kid((u32)0)));
            s.appendCString(e.hasFlag((u32)NF_ARROW) ? "->" : ".");
            s.append(e.name());
            return s;
            }
        if (e.kind() == (u16)nkSubscript && e.kidCount() > (u32)1)
            {
            String* s = String.withString(stackAddrText(e.kid((u32)0)));
            s.appendByte((u8)'[');
            Node* ix = e.kid((u32)1);
            if (ix.kind() == (u16)nkIdent && ix.name() != 0)
                s.append(ix.name());
            else if (ix.kind() == (u16)nkInt)
                s.append(String.withI64(ix.num()));
            else
                s.appendCString("...");
            s.appendByte((u8)']');
            return s;
            }
        return String.withCString("...");
        }

    // Is `name`, where it is used, a parameter of the callable being walked?
    bool isParamName(String* name)
        {
        u32 i = _scopes.count();
        while (i > (u32)0)
            {
            i = i - (u32)1;
            Map* sc = (Map*)_scopes.get(i);
            if (sc.get((Hashable*)name) == 0)
                continue;
            if (_curMethod == 0 || i != _fnScopeAt)
                return false;
            for (u32 p = (u32)0; p < _curMethod.kidCount(); p = p + (u32)1)
                {
                Node* pn = _curMethod.kid(p);
                if (pn.kind() == (u16)nkParam && pn.name() != 0 && pn.name().equals(name))
                    return true;
                }
            return false;
            }
        return false;
        }

    // `&y` of a LOCAL stack instance, which moves to the heap (#604): a
    // parameter, a member, an element or a global does not.
    bool isPromotableAddr(Node* value)
        {
        if (value == 0 || value.kind() != (u16)nkUnary || !_isOp(value.op(), "&") || value.kidCount() == (u32)0)
            return false;
        Node* operand = value.kid((u32)0);
        if (operand.kind() != (u16)nkIdent || operand.name() == 0 || !isStackClassType(operand.ty()))
            return false;
        return nameKindOf(operand.name()) == (u32)1 && !isParamName(operand.name());
        }

    // `&x` of an instance held by value, stored where a strong class pointer
    // would retain it: the store checkStackAddrStrong refuses.
    bool isStackAddrStrong(String* slot, Node* value)
        {
        if (slot == 0 || value == 0 || !Types.isPointer(slot)
            || slot.byteIndexOf(String.withCString("weak:")) != (u32)$FFFFFFFF)
            return false;
        if (_classes.get((Hashable*)classNameOf(slot)) == 0)
            return false;
        if (value.kind() != (u16)nkUnary || !_isOp(value.op(), "&") || value.kidCount() == (u32)0)
            return false;
        return isStackClassType(value.kid((u32)0).ty()) && !isPromotableAddr(value);
        }

    // `&x` of an instance held by value, stored where a strong class pointer
    // would retain it (#604), as the reference's
    // checkStackAddressInStrongSlot. A local stack instance moves to the heap
    // instead (isPromotableAddr); what is left has no header and so no
    // reference count: a member or an element, which point inside an instance
    // or an array, a by-value parameter, and a global instance. An
    // initialiser, an assignment or a return; the argument form is
    // checkStackStrongArgs.
    void checkStackAddrStrong(String* slot, Node* value, Node* at)
        {
        if (!isStackAddrStrong(slot, value))
            return;
        Node* operand = value.kid((u32)0);
        String* obj = stackAddrText(operand);
        String* cls = operand.ty();
        String* m = String.withCString("'&");
        m.append(obj);
        if (operand.kind() == (u16)nkSubscript && operand.kidCount() > (u32)0)
            {
            m.appendCString("' points inside the array ");
            m.append(stackAddrText(operand.kid((u32)0)));
            m.appendCString(", and a pointer into an array cannot be counted; copy the element out (");
            }
        else if (operand.kind() == (u16)nkMember && operand.kidCount() > (u32)0)
            {
            m.appendCString("' points inside ");
            m.append(stackAddrText(operand.kid((u32)0)));
            m.appendCString(", and a pointer into an instance cannot be counted; copy the member out (");
            }
        else
            {
            u32 nk = operand.kind() == (u16)nkIdent && operand.name() != 0 ? nameKindOf(operand.name()) : (u32)2;
            if (nk == (u32)1)
                {
                m.appendCString("' is the address of the parameter ");
                m.append(obj);
                m.appendCString(", which holds its instance by value and cannot move to the heap; copy it into a local (");
                m.append(cls);
                m.appendCString(" c = ");
                m.append(obj);
                m.appendCString(";) and take the local's address");
                _errorAt(m, at);
                return;
                }
            if (nk == (u32)3)
                {
                m.appendCString("' is the address of a global instance, which has no reference count; declare the global as a reference (");
                m.append(cls);
                m.appendCString("* ");
                m.append(obj);
                m.appendCString(" = new ");
                m.append(cls);
                m.appendCString("();)");
                _errorAt(m, at);
                return;
                }
            m.appendCString("' points inside self, and a pointer into an instance cannot be counted; copy the member out (");
            }
        m.append(cls);
        m.appendCString(" c = ");
        m.append(obj);
        m.appendCString(";), or allocate it with new");
        _errorAt(m, at);
        }

    // A callee declared `throws`, called outside a try's guarded block from a
    // function that is not `throws` itself. The reference refuses it in sema;
    // left to the lowering it read "unsupported: raising call".
    void checkThrowsCall(Node* callee, Node* call, String* name)
        {
        if (callee == 0 || !callee.hasFlag((u32)NF_THROWS) || _tryDepth != (u32)0 || _curThrows)
            return;
        String* m = String.withCString("'");
        m.append(name);
        m.appendCString("' is declared 'throws' — wrap the call in try { } catch (e) { }, or declare the caller 'throws' to propagate");
        _errorAt(m, call);
        }

    String* quotedName(String* owner, String* name, string tail)
        {
        String* d = String.withCString("'");
        if (owner != 0)
            {
            d.append(owner);
            d.appendByte((u8)'.');
            }
        d.append(name);
        d.appendCString("'");
        d.appendCString(tail);
        return d;
        }

    // ── :cloaked and the xtc software stack ──────────────────────────────
    // Pass A: what this body does that pushes to the xtc stack, if anything.
    // The first reason found, in walk order, as the reference's
    // bodyStackSignalReason.
    String* stackSignal(Node* n)
        {
        if (n == 0)
            return (String*)0;
        u16 k = n.kind();
        if (k == (u16)nkNew)
            return String.withCString("allocates with 'new' (heap helper pushes to xtc stack)");
        if (k == (u16)nkDelete)
            {
            String* r = String.withCString("uses '");
            r.append(n.op() != 0 ? n.op() : String.withCString("delete"));
            r.appendCString("' (refcount helper pushes to xtc stack)");
            return r;
            }
        if (k == (u16)nkAsmBlock)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                if (asmLineTouchesStack(n.kid(i).name()))
                    return String.withCString("inline asm references the xtc software-stack pointer");
            return (String*)0;
            }
        if (k == (u16)nkVariableDecl)
            {
            u32 w = semaWidth(n.op());
            if (w > (u32)16)
                {
                String* r = String.withCString("declares local '");
                r.append(n.name());
                r.appendCString("' of ");
                r.append(String.withU32(w));
                r.appendCString(" bytes (spills past the ZP budget)");
                return r;
                }
            }
        if (k == (u16)nkTry || k == (u16)nkDefer)
            return (String*)0;
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            {
            String* r = stackSignal(n.kid(i));
            if (r != 0)
                return r;
            }
        return (String*)0;
        }

    // `$82`/`$83` (xl, xe), `$89`/`$8A` (xt) or an XTC_SP macro, outside a
    // `;` comment.
    bool asmLineTouchesStack(String* raw)
        {
        if (raw == 0)
            return false;
        u32 end = (u32)0;
        while (end < raw.byteLength() && raw.byteAt(end) != (u8)';')
            end = end + (u32)1;
        String* line = raw.substringBytes((u32)0, end).lowercased();
        return line.contains(String.withCString("$82")) || line.contains(String.withCString("$83"))
            || line.contains(String.withCString("$89")) || line.contains(String.withCString("$8a"))
            || line.contains(String.withCString("xtc_sp"));
        }

    // The front end's width of a local: scalars, arrays of them, structs by
    // their fields. A class instance has no width here.
    u32 semaWidth(String* t)
        {
        if (t == 0)
            return (u32)0;
        if (isArrayLike(t))
            {
            u32 open = (u32)0;
            while (open < t.byteLength() && t.byteAt(open) != (u8)'[')
                open = open + (u32)1;
            u32 count = (u32)0;
            for (u32 i = open + (u32)1; i < t.byteLength(); i = i + (u32)1)
                {
                u8 c = t.byteAt(i);
                if (c < (u8)'0' || c > (u8)'9')
                    break;
                count = count * (u32)10 + (u32)(c - (u8)'0');
                }
            return semaWidth(t.substringBytes((u32)0, open)) * count;
            }
        Node* st = (Node*)_structs.get((Hashable*)t);
        if (st != 0)
            {
            u32 total = (u32)0;
            for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
                total = total + semaWidth(st.kid(i).op());
            return total;
            }
        return Types.byteWidth(t);
        }

    void noteStackUse(Node* decl, Node* owner, Node* body)
        {
        if (_curLabel == 0)
            return;
        if (decl.hasFlag((u32)NF_CLOAKED))
            {
            String* shown = String.withCString("");
            if (owner != 0)
                {
                shown.append(owner.name() != 0 ? owner.name() : String.withCString("?"));
                shown.appendByte((u8)'.');
                }
            shown.append(decl.name());
            if (body != 0)
                scanCloaked(body, shown);
            _cloakedLabels.add((Object*)_curLabel);
            _cloakedNames.add((Object*)shown);
            _cloakedDecls.add((Object*)decl);
            }
        String* reason = (String*)0;
        if (decl.op() != 0)
            {
            Node* st = (Node*)_structs.get((Hashable*)firstReturn(decl.op()));
            u32 w = st != 0 ? semaWidth(firstReturn(decl.op())) : (u32)0;
            if (w > (u32)4)
                {
                reason = String.withCString("returns a ");
                reason.append(String.withU32(w));
                reason.appendCString("-byte struct by value (retbuf pointer pushed to xtc stack)");
                }
            }
        if (reason == 0 && body != 0)
            reason = stackSignal(body);
        if (reason != 0)
            {
            _stackUsing.set((Hashable*)_curLabel, (Object*)reason);
            _stackLocal.set((Hashable*)_curLabel, (Object*)reason);
            }
        }

    // The direct violations, reported where they are written.
    void scanCloaked(Node* n, String* name)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        if (k == (u16)nkNew)
            {
            String* m = String.withCString(":cloaked '");
            m.append(name);
            m.appendCString("' cannot use 'new' (heap allocation needs the xtc stack, hidden while PORTB = $30)");
            _errorAt(m, n);
            return;
            }
        if (k == (u16)nkDelete)
            {
            String* m = String.withCString(":cloaked '");
            m.append(name);
            m.appendCString("' cannot use '");
            m.append(n.op() != 0 ? n.op() : String.withCString("delete"));
            m.appendCString("' (refcount helpers push to the xtc stack)");
            _errorAt(m, n);
            return;
            }
        if (k == (u16)nkTry || k == (u16)nkDefer)
            return;
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            scanCloaked(n.kid(i), name);
        }

    // Pass B and C: callers of a stack user become users, to a fixed point;
    // then every :cloaked declaration that became one is refused, with the
    // shortest chain (five calls at most) to a local user.
    void checkCloaked(void)
        {
        if (_cloakedLabels.count() == (u32)0)
            return;
        Map* callers = new Map();
        Array* from = _callEdges.allKeys();
        Vtable.sortStrings(from);
        for (u32 i = (u32)0; i < from.count(); i = i + (u32)1)
            {
            String* caller = (String*)from.get(i);
            Array* edges = (Array*)_callEdges.get((Hashable*)caller);
            for (u32 j = (u32)0; j < edges.count(); j = j + (u32)1)
                {
                Array* up = (Array*)callers.get((Hashable*)edges.get(j));
                if (up == 0)
                    {
                    up = new Array();
                    callers.set((Hashable*)edges.get(j), (Object*)up);
                    }
                Vtable.addUnique(up, caller);
                }
            }
        Array* work = _stackUsing.allKeys();
        while (work.count() > (u32)0)
            {
            String* victim = (String*)work.get(work.count() - (u32)1);
            work.removeAt(work.count() - (u32)1);
            Array* up = (Array*)callers.get((Hashable*)victim);
            if (up == 0)
                continue;
            for (u32 i = (u32)0; i < up.count(); i = i + (u32)1)
                {
                String* c = (String*)up.get(i);
                if (_stackUsing.get((Hashable*)c) == 0)
                    {
                    _stackUsing.set((Hashable*)c, (Object*)String.withCString(""));
                    work.add((Object*)c);
                    }
                }
            }
        for (u32 d = (u32)0; d < _cloakedLabels.count(); d = d + (u32)1)
            {
            String* label = (String*)_cloakedLabels.get(d);
            if (_stackUsing.get((Hashable*)label) == 0)
                continue;
            Array* chain = stackChain(label, (u32)5);
            if (chain.count() == (u32)0)
                continue;
            String* own = (String*)_stackLocal.get((Hashable*)label);
            // The body's own new/delete was reported where it is written.
            if (chain.count() == (u32)1 && own != 0
                && (own.hasPrefix(String.withCString("allocates with 'new'")) || own.hasPrefix(String.withCString("uses '"))))
                continue;
            String* msg = String.withCString(":cloaked '");
            msg.append((String*)_cloakedNames.get(d));
            msg.appendCString("' transitively uses the xtc software stack");
            for (u32 i = (u32)1; i < chain.count(); i = i + (u32)1)
                {
                String* step = (String*)chain.get(i);
                msg.appendCString("\n  note: calls '");
                msg.append(displayOf(step));
                msg.appendCString("' which");
                if (i == chain.count() - (u32)1)
                    {
                    String* why = (String*)_stackLocal.get((Hashable*)step);
                    msg.appendByte((u8)' ');
                    msg.append(why != 0 ? why : String.withCString("reaches the xtc stack"));
                    }
                }
            if (chain.count() == (u32)1 && own != 0)
                {
                msg.appendCString("\n  note: ");
                msg.append(own);
                }
            if (_stackLocal.get((Hashable*)chain.get(chain.count() - (u32)1)) == 0)
                msg.appendCString("\n  note: (chain continues)");
            if (_cloakedWarn)
                _warnAt(String.withCString(""), msg, (Node*)_cloakedDecls.get(d));
            else
                _errorAt(msg, (Node*)_cloakedDecls.get(d));
            }
        }

    // Breadth first over stack-using callees, in sorted order, to the nearest
    // local user; the chain runs start..leaf, or to the deepest frontier when
    // the cap is reached first.
    Array* stackChain(String* start, u32 cap)
        {
        Array* chain = new Array();
        if (_stackLocal.get((Hashable*)start) != 0)
            {
            chain.add((Object*)start);
            return chain;
            }
        Map* parent = new Map();
        parent.set((Hashable*)start, (Object*)String.withCString(""));
        Array* frontier = new Array();
        frontier.add((Object*)start);
        String* leaf = (String*)0;
        String* last = start;
        for (u32 h = (u32)0; h < cap && leaf == 0 && frontier.count() > (u32)0; h = h + (u32)1)
            {
            Array* next = new Array();
            for (u32 f = (u32)0; f < frontier.count() && leaf == 0; f = f + (u32)1)
                {
                Array* edges = (Array*)_callEdges.get((Hashable*)frontier.get(f));
                if (edges == 0)
                    continue;
                Array* callees = new Array();
                for (u32 c = (u32)0; c < edges.count(); c = c + (u32)1)
                    callees.add(edges.get(c));
                Vtable.sortStrings(callees);
                for (u32 c = (u32)0; c < callees.count(); c = c + (u32)1)
                    {
                    String* callee = (String*)callees.get(c);
                    if (_stackUsing.get((Hashable*)callee) == 0 || parent.get((Hashable*)callee) != 0)
                        continue;
                    parent.set((Hashable*)callee, frontier.get(f));
                    if (_stackLocal.get((Hashable*)callee) != 0)
                        {
                        leaf = callee;
                        break;
                        }
                    next.add((Object*)callee);
                    }
                }
            if (next.count() > (u32)0)
                last = (String*)next.get(next.count() - (u32)1);
            frontier = next;
            }
        String* cur = leaf != 0 ? leaf : last;
        Array* rev = new Array();
        while (cur != 0 && cur.byteLength() > (u32)0)
            {
            rev.add((Object*)cur);
            if (cur.equals(start))
                break;
            cur = (String*)parent.get((Hashable*)cur);
            }
        u32 k = rev.count();
        while (k > (u32)0)
            {
            k = k - (u32)1;
            chain.add(rev.get(k));
            }
        return chain;
        }

    // ── The variadic non-reentrance check ────────────────────────────────
    // `_fn_<sym>` for a free function, `_cls_<Class>_<sym>` for a method: the
    // labels the original's call graph uses, so a walk over the two graphs
    // visits the same names in the same order.
    String* callableLabel(Node* decl, Node* owner)
        {
        String* key = decl.sym() != 0 ? decl.sym() : decl.name();
        if (owner == 0)
            return fnLabel(key);
        return clsLabel(owner.name(), key);
        }

    String* fnLabel(String* key)
        {
        String* l = String.withCString("_fn_");
        if (key != 0)
            l.append(key);
        return l;
        }

    String* clsLabel(String* cls, String* key)
        {
        String* l = String.withCString("_cls_");
        l.append(cls != 0 ? cls : String.withCString("?"));
        l.appendByte((u8)'_');
        if (key != 0)
            l.append(key);
        return l;
        }

    // A call from the body being walked. File scope has no caller to record.
    void noteCallEdge(String* callee)
        {
        if (_curLabel == 0 || callee == 0)
            return;
        Array* out = (Array*)_callEdges.get((Hashable*)_curLabel);
        if (out == 0)
            {
            out = new Array();
            _callEdges.set((Hashable*)_curLabel, (Object*)out);
            }
        Vtable.addUnique(out, callee);
        }

    // After a body: the name its label shows in a message, and — for a
    // variadic defined here — its place among the check's starting points. A
    // C import, or a free variadic with no body, passes its arguments by the C
    // ABI or lives in another unit, so it can clobber nothing of this unit's;
    // a METHOD counts whatever its body, as in the original.
    void noteCallable(Node* decl, Node* owner)
        {
        if (_curLabel == 0)
            return;
        String* shown = String.withCString("");
        if (owner != 0)
            {
            shown.append(owner.name() != 0 ? owner.name() : String.withCString("?"));
            shown.appendByte((u8)'.');
            }
        shown.append(decl.name());
        _labelDisplay.set((Hashable*)_curLabel, (Object*)shown);
        if (!decl.hasFlag((u32)NF_VARARGS))
            return;
        if (owner == 0)
            {
            if (decl.hasFlag((u32)NF_CABI))
                return;
            bool hasBody = false;
            for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
                if (decl.kid(i).kind() == (u16)nkBlock)
                    hasBody = true;
            if (!hasBody)
                return;
            }
        _variadicLabels.set((Hashable*)_curLabel, (Object*)Number.with((u32)1));
        _variadicDecls.add((Object*)decl);
        _variadicDeclLabels.add((Object*)_curLabel);
        _variadicDeclNames.add((Object*)shown);
        }

    // A variadic that runs va_start reads its arguments out of the ONE shared
    // pack buffer while it runs, and any variadic it reaches — directly or
    // through ordinary functions — packs its own arguments into that same
    // buffer. So a variadic that consumes its va_list must not reach another
    // variadic, nor itself. A pure forwarder (no va_start) is exempt: it never
    // reads the buffer, which is how Stdio.printfAt hands its arguments on.
    //
    // arm64 and arm9 pass variadic arguments by the C ABI and have no shared
    // buffer, so the check does not apply there.
    //
    // The route is the SHORTEST one within five calls, found breadth first
    // over callees in sorted order, so both compilers name the same chain.
    void checkVariadicReentrance(void)
        {
        if (_nativeVarargs)
            return;
        for (u32 d = (u32)0; d < _variadicDecls.count(); d = d + (u32)1)
            {
            String* start = (String*)_variadicDeclLabels.get(d);
            if (_usesVaList.get((Hashable*)start) == 0)
                continue;
            Array* chain = shortestVariadicPath(start, (u32)5);
            if (chain.count() < (u32)2)
                continue;
            String* name = (String*)_variadicDeclNames.get(d);
            String* leaf = (String*)chain.get(chain.count() - (u32)1);
            bool selfOrMutual = leaf.equals(start);
            String* msg = String.withCString("variadic '");
            msg.append(name);
            if (selfOrMutual)
                {
                msg.appendCString("' is transitively recursive — the shared varargs buffer cannot hold two live va_lists at once");
                }
            else
                {
                msg.appendCString("' transitively calls variadic '");
                msg.append(displayOf(leaf));
                msg.appendCString("' — both use the shared varargs buffer and would clobber each other");
                }
            for (u32 i = (u32)1; i < chain.count(); i = i + (u32)1)
                {
                String* step = (String*)chain.get(i);
                bool last = i == chain.count() - (u32)1;
                String* shown = (last && selfOrMutual) ? name : displayOf(step);
                msg.appendCString("\n  note: calls '");
                msg.append(shown);
                if (last)
                    msg.appendCString("' (variadic)");
                else
                    msg.appendCString("' which");
                }
            _errorAt(msg, (Node*)_variadicDecls.get(d));
            }
        }

    String* displayOf(String* label)
        {
        String* s = (String*)_labelDisplay.get((Hashable*)label);
        return s != 0 ? s : label;
        }

    // Breadth first from `start` to the nearest variadic, or back to `start`
    // itself (recursion). The chain runs start..leaf; empty when nothing is
    // reachable within `cap` calls.
    Array* shortestVariadicPath(String* start, u32 cap)
        {
        Array* none = new Array();
        if (_callEdges.get((Hashable*)start) == 0)
            return none;
        Map* parent = new Map();
        String* selfReturn = String.withCString("__self_return");
        parent.set((Hashable*)start, (Object*)String.withCString(""));
        Array* frontier = new Array();
        frontier.add((Object*)start);
        String* leaf = (String*)0;
        for (u32 h = (u32)0; h < cap && leaf == 0; h = h + (u32)1)
            {
            Array* next = new Array();
            for (u32 f = (u32)0; f < frontier.count() && leaf == 0; f = f + (u32)1)
                {
                String* caller = (String*)frontier.get(f);
                Array* edges = (Array*)_callEdges.get((Hashable*)caller);
                if (edges == 0)
                    continue;
                Array* callees = new Array();
                for (u32 c = (u32)0; c < edges.count(); c = c + (u32)1)
                    callees.add(edges.get(c));
                Vtable.sortStrings(callees);
                for (u32 c = (u32)0; c < callees.count(); c = c + (u32)1)
                    {
                    String* callee = (String*)callees.get(c);
                    if (callee.equals(start))
                        {
                        parent.set((Hashable*)selfReturn, (Object*)caller);
                        leaf = selfReturn;
                        break;
                        }
                    if (parent.get((Hashable*)callee) != 0)
                        continue;
                    parent.set((Hashable*)callee, (Object*)caller);
                    if (_variadicLabels.get((Hashable*)callee) != 0)
                        {
                        leaf = callee;
                        break;
                        }
                    next.add((Object*)callee);
                    }
                }
            frontier = next;
            }
        if (leaf == 0)
            return none;
        // Walk back from the leaf; the start's parent is the empty string.
        Array* rev = new Array();
        String* cur = leaf;
        u32 guard = (u32)0;
        while (cur != 0 && guard < cap + (u32)2)
            {
            guard = guard + (u32)1;
            rev.add((Object*)(cur.equals(selfReturn) ? start : cur));
            String* p = (String*)parent.get((Hashable*)cur);
            if (p == 0 || p.byteLength() == (u32)0)
                break;
            cur = p;
            }
        Array* chain = new Array();
        u32 k = rev.count();
        while (k > (u32)0)
            {
            k = k - (u32)1;
            chain.add(rev.get(k));
            }
        return chain;
        }

    void typeStmt(Node* n)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        if (k == (u16)nkDelete)
            {
            // `delete` / `retain` / `release` on a CLASS instance: ARC already
            // owns that refcount, so a hand-written one frees an object that
            // is still aliased. The reference refuses it; this port typed the
            // operand and said nothing, so `delete p` compiled and ran the
            // double free. Struct and primitive arrays are not ARC-managed,
            // and `delete` stays the only way to free them.
            if (n.kidCount() > (u32)0)
                {
                typeExpr(n.kid(0));
                String* t = n.kid(0).ty();
                String* cls = (t != 0 && Types.isPointer(t)) ? classNameOf(t) : (String*)0;
                if (cls != 0 && _classes.get((Hashable*)cls) != 0)
                    {
                    String* w = String.withCString("`");
                    w.append(n.op());
                    w.appendCString("` is not allowed on a class instance under ARC — ");
                    w.appendCString(n.num() == (i64)0 ? "let the scope exit release it"
                                                      : "the compiler manages class refcounts automatically");
                    _errorAt(w, n);
                    }
                }
            return;
            }
        if (k == (u16)nkBlock)
            {
            // A DECL-LIST block is not a scope — `Block a, b, c;` is three
            // declarations in the ENCLOSING scope, and scoping it made every
            // one of them invisible the moment the list ended.
            if (n.hasFlag((u32)NF_DECLLIST))
                {
                for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                    typeStmt(n.kid(i));
                return;
                }
            pushScope();
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                typeStmt(n.kid(i));
            popScope();
            return;
            }
        if (k == (u16)nkVariableDecl)
            {
            checkWeakSpelling(n.op(), n);
            // `auto` is INFERRED from the initialiser, and the inference is
            // written back onto the declaration — the dump prints `type=u16`
            // where the source said `auto`, because by then that is what the
            // declaration means.
            String* save = _expected;
            _expected = _isOp(n.op(), "auto") ? (String*)0 : n.op();
            // `u8 buf[10] = 0..9;` is the one position where a range survives
            // the parser — the `for … in` form is desugared where it is parsed
            // — so it is the one position where a range must not be diagnosed.
            bool saveRange = _rangeIsInitialiser;
            _rangeIsInitialiser = isArrayLike(n.op());
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                typeExpr(n.kid(i));
            _rangeIsInitialiser = saveRange;
            // `u32 n = nil`: nil is a pointer, and this is the declaration's
            // type to say so against (an `auto` declaration has none yet).
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                checkNil(n.kid(i), _expected);
            _expected = save;
            // `String* s = arr;` / `act_t^ a = someBlock;` — an initialiser is
            // an assignment and is checked as one.
            if (n.kidCount() > (u32)0 && !_isOp(n.op(), "auto"))
                checkClassPointerAssignAt(n.op(), n.kid((u32)0).ty(),
                                          n.kid((u32)0), "initialiser", n);
            if (_isOp(n.op(), "auto") && n.kidCount() > (u32)0)
                {
                // `auto p = nil` has no type to infer: nil is a pointer of
                // every type and so of none in particular. Refused, rather
                // than quietly making the carrier type a `u8`.
                Node* init = n.kid((u32)0);
                if (init.kind() == (u16)nkInt && init.nilLit())
                    {
                    _errorAt(String.withCString("nil is a pointer of no particular type: 'auto' cannot take it, name the pointer type"), init);
                    n.setOp(String.withCString("pointer"));
                    }
                else
                    {
                    String* inferred = init.ty();
                    if (inferred != 0)
                        n.setOp(inferred);
                    }
                }
            // `P* r = &y;` of a stack instance (#604). After the inference
            // above, as `auto r = &y;` is a strong `P*` too.
            if (n.kidCount() > (u32)0)
                checkStackAddrStrong(n.op(), n.kid((u32)0), n);
            // `u16 v = a.get(0)` — a boxed value arriving in a primitive
            // slot unboxes on the way in.
            if (n.kidCount() > (u32)0 && canUnboxType(n.kid((u32)0).ty(), n.op()))
                {
                Node* u = unboxedNode(n.kid((u32)0), n.op());
                if (u != 0)
                    n.setKid((u32)0, u);
                }
            define(n.name(), n.op());
            n.setTy(n.op()); // a DECLARATION carries its own type; an
                             // ivar does not — it is never visited as a
                             // statement, which is why the two differ
            return;
            }
        if (k == (u16)nkForIn)
            {
            // The COLLECTION is typed first, because the loop variable's type
            // may have to come from it. The grammar makes that type optional —
            // `for (v in a)`, which the parser leaves as "-" — and nothing used
            // to fill it in, so lowering found no element type and emitted no
            // loop at all: the body silently never ran (bug 036).
            //
            // Ordering matters and is the whole fix. Walking the kids in order,
            // as the generic path below does, defines the loop variable before
            // the collection has a type to give it.
            if (n.kidCount() < (u32)2)
                return;
            pushScope();
            typeExpr(n.kid((u32)1));
            // A range index through an operator is a call's result, not a
            // slice of the base to step through.
            if (n.kid(1).kind() == (u16)nkSlice && n.kid(1).hasFlag((u32)NF_OPCALL))
                _errorAt(String.withCString("'for ... in' cannot iterate a range index made by an operator; assign it to a variable first"), n.kid(1));
            Node* lv = n.kid((u32)0);
            if (lv.kind() == (u16)nkVariableDecl && (lv.op() == 0 || _isOp(lv.op(), "-") || _isOp(lv.op(), "auto")))
                {
                String* elem = elementOf(n.kid((u32)1).ty());
                if (elem != 0)
                    lv.setOp(elem);
                }
            // A collection with a PRIMITIVE element type hands back a BOXED
            // value — the container really holds Numbers. `i32 v = a.get(i)`
            // unboxes because that is an assignment context; `for (i32 v in a)`
            // did not, and the loop variable got the pointer reinterpreted as
            // an integer (bug 039).
            //
            // Instead of a second unboxing rule here, bind the element under a
            // HIDDEN name typed `Number*` and give the body a declaration of
            // the name the user wrote, initialised from it. That declaration is
            // an ordinary assignment context, so the existing unbox fires on it.
            if (lv.kind() == (u16)nkVariableDecl && lv.op() != 0 && numberAccessorFor(lv.op()) != 0 && _classes.get((Hashable*)String.withCString("Number")) != 0)
                {
                String* elem = Node.elemOf(n.kid((u32)1).ty());
                // Base name for the lookup: a NESTED generic element
                // ("Array<String>") is still a class. Same rule as the
                // method-call substitution below.
                String* elemBase = Node.stripElem(elem);
                bool elemIsClass = elem != 0 && (_classes.get((Hashable*)elemBase) != 0 || _protocols.get((Hashable*)elemBase) != 0);
                if (elem != 0 && !elemIsClass)
                    {
                    String* hidden = String.withCString("__forin_boxed_");
                    hidden.append(lv.name());
                    String* want = String.withString(lv.op());

                    Node* unboxed = Node.withName((u16)nkVariableDecl, lv.name());
                    unboxed.setOp(want);
                    Node* ref = Node.withName((u16)nkIdent, hidden);
                    ref.setTy(String.withCString("Number*"));
                    unboxed.add(ref);

                    Node* body = n.kid((u32)2);
                    Node* blk = Node.with((u16)nkBlock);
                    blk.add(unboxed);
                    if (body != 0)
                        {
                        if (body.kind() == (u16)nkBlock)
                            for (u32 i = (u32)0; i < body.kidCount(); i = i + (u32)1)
                                blk.add(body.kid(i));
                        else
                            blk.add(body);
                        }
                    lv.setName(hidden);
                    lv.setOp(String.withCString("Number*"));
                    n.setKid((u32)2, blk);
                    }
                }
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                if (i == (u32)1)
                    continue; // already typed
                typeStmt(n.kid(i));
                }
            popScope();
            return;
            }
        if (k == (u16)nkStructDecl)
            {
            // A struct declared INSIDE a function is still a type, not a run of
            // statements: walking into it defined every FIELD as a local, so
            // `struct { u32 a; … }` quietly bound `a` in the enclosing scope
            // and every later mention of `a` took the field's type.
            _structs.set((Hashable*)n.name(), (Object*)n);
            return;
            }
        if (k == (u16)nkTypedefDecl)
            {
            if (n.name() != 0 && n.op() != 0)
                _typedefTargets.set((Hashable*)n.name(), (Object*)n.op());
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                Node* st = n.kid(i);
                if (st.kind() == (u16)nkStructDecl)
                    _structs.set((Hashable*)n.name(), (Object*)st);
                }
            return;
            }
        if (k == (u16)nkTry)
            {
            // The guarded block may call what throws; the arms may not.
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                bool guarded = n.kid(i).kind() != (u16)nkCatch;
                if (guarded)
                    _tryDepth = _tryDepth + (u32)1;
                typeStmt(n.kid(i));
                if (guarded)
                    _tryDepth = _tryDepth - (u32)1;
                }
            return;
            }
        if (k == (u16)nkCatch)
            {
            // `catch (e)` binds `e` for the arm's body. An untyped arm catches
            // anything, so the binding is Object@; a typed arm names its class.
            pushScope();
            String* ct = String.withCString("Object*");
            if (n.op() != 0 && !_isOp(n.op(), "-"))
                {
                // A typed arm names a CLASS; the binding is a pointer to it.
                ct = String.withString(n.op());
                if (!Types.isPointer(ct))
                    ct.appendByte((u8)'*');
                }
            define(n.name(), ct);
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                typeStmt(n.kid(i));
            popScope();
            return;
            }
        if (k == (u16)nkTupleAssign)
            {
            // `(a, b) = f()` — an EXISTING name as a target is not an
            // expression being typed, it is a name being bound, and the
            // original leaves it alone. Only the call on the right is walked.
            //
            // A target that is a NEW DECLARATION is different, and skipping it
            // was wrong: `(u16 a, u16 b, bool c) = f()` declares three
            // variables, and if they are never defined in scope nor given
            // their type, the dump prints them without a `ty=` and every later
            // use falls back to u8. Declare them exactly as a plain local
            // declaration does — define() then setTy() — which is what the
            // reference's own targets carry.
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                Node* k2 = n.kid(i);
                if (k2.kind() == (u16)nkVariableDecl)
                    {
                    define(k2.name(), k2.op());
                    k2.setTy(k2.op());
                    checkTupleTarget(k2, k2.op());
                    // A weak slot has to be linked to its referent where it
                    // lives, which a target declared in the tuple has nowhere
                    // to do (#507). As the reference.
                    if (k2.op() != 0 && k2.op().byteIndexOf(String.withCString("weak:")) != (u32)$FFFFFFFF)
                        {
                        String* m = String.withCString("a tuple target cannot be declared weak ('");
                        m.append(k2.name());
                        m.appendCString("'); declare it before the assignment");
                        _errorAt(m, k2);
                        }
                    continue;
                    }
                if (k2.kind() == (u16)nkIdent && i + (u32)1 < n.kidCount())
                    {
                    checkTupleTarget(k2, lookup(k2.name()));
                    continue;
                    }
                if (k2.kind() == (u16)nkCall || k2.kind() == (u16)nkMethodCall)
                    typeExpr(k2);
                }
            return;
            }
        if (k == (u16)nkReturn)
            {
            // `return f();` wants the function's own return type — the same
            // choice a declaration makes.
            String* save = _expected;
            _expected = _curReturn;
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                typeExpr(n.kid(i));
            // `return nil` from a function that does not return a pointer. A
            // void function has no return type to check against (its value is
            // refused elsewhere), as in the reference.
            if (_curReturn != 0 && !Types._is(_curReturn, "void"))
                for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                    checkNil(n.kid(i), _curReturn);
            _expected = save;
            // `return a.get(0)` from a u16 function unboxes at the return.
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                if (!canUnboxType(n.kid(i).ty(), _curReturn))
                    continue;
                Node* u = unboxedNode(n.kid(i), _curReturn);
                if (u != 0)
                    n.setKid(i, u);
                }
                // A returned class pointer is checked against the declared return
                // type — `return buf;` from a `String*` function is how a raw
                // pointer got dispatched through as an instance.
                //
                // MULTI-RETURN is per position: the declared type is the whole
                // `Tracker*,Tracker*` list, and checking one value against the
                // list said "a class reference is not a raw 'Tracker*,Tracker*'",
                // which is true and useless.
                {
                Array* rets = commaSplit(_curReturn);
                for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                    {
                    String* want = i < rets.count() ? (String*)rets.get(i)
                                                    : (rets.count() == (u32)1 ? (String*)rets.get((u32)0)
                                                                              : (String*)0);
                    if (want == 0)
                        continue;
                    checkStackAddrStrong(want, n.kid(i), n);
                    checkClassPointerAssignAt(want, n.kid(i).ty(), n.kid(i), "return", n);
                    }
                }
            return;
            }
        if (k == (u16)nkForCStyle)
            {
            // The INIT variable scopes to the loop — `for (u32 t ...)` after
            // a `String* t` shadows it only for the statement (finding #16).
            // The body block pushes its own scope; this frame covers the
            // init / cond / step head.
            pushScope();
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                typeStmt(n.kid(i));
            popScope();
            return;
            }
        if (k >= (u16)nkBinary)
            {
            typeExpr(n);
            return;
            }
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            typeStmt(n.kid(i));
        }

    // Bottom-up: children first, then the node's own rule.
    void typeExpr(Node* n)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        if (k < (u16)nkBinary)
            {
            typeStmt(n);
            return;
            }
        // Read two ways (an operator a class defines, `a**b`): choose by the
        // operands' types, and type the reading kept.
        if ((k == (u16)nkBinary || k == (u16)nkUnary) && n.alt() != 0)
            {
            Node* alt = n.alt();
            n.setAlt((Node*)0);
            chooseReading(n, alt);
            return;
            }

        // An assignment's RHS is typed with the LHS as its expected type, so a
        // return-type-only overload can be chosen there too.
        if (k == (u16)nkAssign && n.kidCount() >= (u32)2)
            {
            // Already made a call or rewrite by an operator.
            if (n.hasFlag((u32)NF_OPCALL) || n.hasFlag((u32)NF_OPFALLBACK))
                return;
            // A subscript on the left is the target of an index operator's set
            // form, if its base's class has one, and is not read.
            Node* prevTarget = _opIndexTarget;
            _opIndexTarget = n.kid(0);
            typeExpr(n.kid((u32)0));
            _opIndexTarget = prevTarget;
            // A compound assignment on a class that defines the operator (in
            // place, or as `a = a op b`) is decided before a property write.
            if (opCompoundApplies(n))
                {
                Node* tgt = n.kid(0);
                // The target is written, not read: no getter, as the reference
                // types a left side.
                if (tgt.kind() == (u16)nkMember)
                    tgt.setGetter((String*)0, (String*)0);
                String* csave = _expected;
                _expected = tgt.ty();
                typeExpr(n.kid(1));
                _expected = csave;
                checkNil(n.kid(1), tgt.ty());
                if (tgt.ty() != 0)
                    n.setTy(tgt.ty());
                resolveOpAssign(n);
                return;
                }
            // Assigning to a member with no ivar behind it is a PROPERTY WRITE:
            // it becomes `recv.set<Name>(rhs)`, so the ASSIGNMENT carries the
            // setter and takes ITS return type — and the member on the left is
            // not a getter call, so the stamp typeMember left there comes off.
            // Gated on the member having no IVAR behind it, not on it having a
            // getter: a write-only property (a class with `setN` and no `n()`)
            // is still a property write.
            Node* lv = n.kid((u32)0);
            if (lv.kind() == (u16)nkMember)
                {
                // `propertySetter` used to match on NAME and arity alone, so a
                // class with both an ivar `x` and an ordinary method
                // `setX(Object*)` had every direct `m.x = v` rewritten into
                // `m.setX(v)` — an i32 passed where an `Object*` was expected,
                // dereferenced by the setter as a null read at +8, several
                // statements after the last thing the reader would suspect
                // (uxkit bug 034-B).
                //
                // The gate for that was "no IVAR behind the member", and it was
                // WRONG — see 118. A property backed by an ivar of the SAME
                // name is the ordinary case (`n` with `setN(u8)`), and gating
                // on the ivar's existence turned every one of those into a
                // direct store, silently skipping the setter's body.
                // `propertySetter` now checks the TYPE, which is the thing that
                // actually distinguishes the two.
                Node* setter = propertySetter(lv);
                if (setter != 0)
                    {
                    // The left side is being WRITTEN, so it is not a getter
                    // call — whatever typeMember stamped there comes off.
                    lv.setGetter((String*)0, (String*)0);
                    typeExpr(n.kid((u32)1));
                    n.setSetter(setter.sym(), _setterOwner);
                    n.setTy(firstReturn(setter.op()));
                    // `b.v += x` through a property becomes `b.v = b.v + x`:
                    // one setter call whose argument reads the getter first.
                    // The rewrite is in the TREE, so the dump shows the
                    // synthesised binary and its getter read.
                    if (n.op() != 0 && n.op().byteLength() > (u32)1 && !_isOp(n.op(), "=="))
                        {
                        String* bop = n.op().substringBytes((u32)0, n.op().byteLength() - (u32)1);
                        Node* read = Node.withName((u16)nkMember, lv.name());
                        read.add(lv.kid((u32)0));
                        read.setTy(lv.ty());
                        read.setGetter(getterSymbolFor(lv), getterClassFor(lv));
                        Node* bin = Node.with((u16)nkBinary);
                        bin.setOp(bop);
                        bin.add(read);
                        bin.add(n.kid((u32)1));
                        bin.setTy(lv.ty());
                        n.setKid((u32)1, bin);
                        n.setOp(String.withCString("="));
                        }
                    return;
                    }
                // No setter: an ordinary ivar store, and again not a read.
                if (memberIsIvar(lv))
                    lv.setGetter((String*)0, (String*)0);
                }
            String* save = _expected;
            _expected = n.kid((u32)0).ty();
            typeExpr(n.kid((u32)1));
            _expected = save;
            // `n = nil` into anything but a pointer.
            checkNil(n.kid((u32)1), n.kid((u32)0).ty());
            // An index operator's set form: the assignment is the call it
            // becomes.
            if (resolveOpAssign(n))
                return;
            // A boxed value assigned into a primitive unboxes, exactly as it
            // does at a declaration. Only a plain `=`: a compound assignment
            // needs the whole read-modify-write, which the original leaves
            // alone.
            if (_isOp(n.op(), "=") && canUnboxType(n.kid((u32)1).ty(), n.kid((u32)0).ty()))
                {
                Node* u = unboxedNode(n.kid((u32)1), n.kid((u32)0).ty());
                if (u != 0)
                    n.setKid((u32)1, u);
                }
            if (n.kid((u32)0).ty() != 0)
                n.setTy(n.kid((u32)0).ty());
            // The class-pointer rule applies to a plain store. A compound
            // assignment is a read-modify-write on a value that already has
            // the slot's type, so there is nothing to check there.
            if (_isOp(n.op(), "="))
                {
                checkStackAddrStrong(n.kid((u32)0).ty(), n.kid((u32)1), n);
                checkClassPointerAssignAt(n.kid((u32)0).ty(), n.kid((u32)1).ty(),
                                          n.kid((u32)1), "assignment", n);
                }
            return;
            }
        // A printf VARARG is typed with the format's expectation in hand:
        // `Math.PI()` has a float and a double overload and nothing but the
        // conversion can choose between them, so a floating conversion picks
        // the double. Only the float conversions hint.
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            {
            String* hint = printfHint(n, i);
            if (hint == 0)
                hint = paramHint(n, i);
            // A cast's type is its operand's context, as in the reference:
            // `(double)Math.E()` is the double `E`.
            if (hint == 0 && k == (u16)nkCast && i == (u32)0)
                hint = n.name();
            if (hint == 0)
                {
                typeExpr(n.kid(i));
                continue;
                }
            String* save = _expected;
            _expected = hint;
            typeExpr(n.kid(i));
            _expected = save;
            // `f(nil)` where every candidate's parameter is not a pointer.
            checkNil(n.kid(i), hint);
            }

        if (k == (u16)nkInt)
            {
            n.setTy(Types.forIntLiteral(n.num()));
            return;
            }
        if (k == (u16)nkChar)
            {
            n.setTy(String.withCString("u8"));
            return;
            }
        if (k == (u16)nkFloat)
            {
            // The `d` suffix is the only thing that separates the two, and the
            // parser recorded it in `num`.
            n.setTy(n.num() != (i64)0 ? String.withCString("double")
                                      : String.withCString("float"));
            return;
            }
        if (k == (u16)nkBool)
            {
            n.setTy(String.withCString("bool"));
            return;
            }
        if (k == (u16)nkStr)
            {
            n.setTy(String.withCString("u8*"));
            return;
            }
        if (k == (u16)nkIdent)
            {
            String* t = lookup(n.name());
            if (t != 0)
                {
                n.setTy(t);
                return;
                }
            // A bare CLASS name — the receiver of a static call — is typed as
            // the class itself.
            if (_classes.get((Hashable*)n.name()) != 0)
                {
                n.setTy(n.name());
                return;
                }
            // A bare TYPEDEF name is typed as the alias's TARGET — the
            // original's "is not found but IS a type" arm reads the type
            // table, where an alias stands for what it names. Only reachable
            // in erroneous expressions (a use before the typedef parses), but
            // the dumps must agree on those too (task #36).
            String* tdef = _typedefTargets == 0 ? (String*)0
                                                : (String*)_typedefTargets.get((Hashable*)n.name());
            if (tdef != 0)
                {
                n.setTy(tdef);
                return;
                }
            // A bare FUNCTION name — `&f` takes its address — is typed as the
            // function's signature: `u8 f(u8)` is `u8(u8)`.
            Array* g = (Array*)_functions.get((Hashable*)n.name());
            if (g != 0 && g.count() > (u32)0)
                {
                n.setTy(signatureOf((Node*)g.get((u32)0), false));
                return;
                }
            // `super` is a KEYWORD wearing an identifier's clothes — it names
            // no value and carries no type, so the fallback must not fire.
            if (_isOp(n.name(), "super"))
                return;
            // Nothing declares it. That is an error, and an error still leaves
            // a type — u8 — behind for the passes that walk the tree next.
            // Reported here, as the reference does: left to the lowering it
            // came out as "unsupported: unbound identifier" or, for an
            // undeclared TYPE (`Data* d = …` parses as a product), as
            // "unsupported: assignment target".
            String* um = String.withCString("Undefined identifier '");
            um.append(n.name());
            um.appendCString("'");
            _errorAt(um, n);
            n.setTy(String.withCString("u8"));
            return;
            }
        if (k == (u16)nkCast)
            {
            // `(u16)a.get(i)` converts the VALUE, so a boxed element read
            // unboxes first. Only for a cast to a PRIMITIVE: a cast to a class
            // pointer is how the unbox rewrite itself is spelled, and unboxing
            // there would recurse. private:docs/bugs/046.
            if (n.kidCount() > (u32)0 && numberAccessorFor(n.name()) != 0)
                n.setKid((u32)0, unboxCollectionElement(n.kid((u32)0)));
            n.setTy(n.name());
            if (n.hasFlag((u32)NF_FAILABLE))
                checkFailableCast(n);
            checkProtocolCast(n);
            return;
            }
        if (k == (u16)nkBinary)
            {
            typeBinary(n);
            return;
            }
        if (k == (u16)nkUnary)
            {
            typeUnary(n);
            return;
            }
        if (k == (u16)nkPostfix)
            {
            if (n.kidCount() > (u32)0)
                n.setTy(n.kid((u32)0).ty());
            // An element an index operator reads is a call's result, with no
            // slot to step.
            if (n.kidCount() > 0 && Sema.isOpIndex(n.kid(0)))
                _errorAt(String.withCString("'++' and '--' cannot step an element read through an index operator; use '+= 1' or '-= 1'"), n.kid(0));
            return;
            }
        if (k == (u16)nkTernary)
            {
            // The two ARMS decide the type; the condition does not. Each is a
            // value this expression yields, so a boxed element read has to
            // become the element type BEFORE the arms are widened together.
            if (n.kidCount() >= (u32)3)
                {
                n.setKid((u32)1, unboxCollectionElement(n.kid((u32)1)));
                n.setKid((u32)2, unboxCollectionElement(n.kid((u32)2)));
                n.setTy(Types.widen(n.kid((u32)1).ty(), n.kid((u32)2).ty()));
                }
            return;
            }
        if (k == (u16)nkRange)
            {
            // A range is SYNTAX, not a value. Anywhere but an array
            // initialiser it has nothing to lower to — the original used to
            // abandon with an internal node number. private:docs/bugs/048.
            if (!_rangeIsInitialiser)
                _error(String.withCString("range outside an array initialiser"));
            // A range is not a value with a width — it is a loop or an
            // initialiser shorthand — so it carries the default type rather
            // than the widening of its bounds. `-2..1` is u8 here, which is
            // only sensible once you stop reading it as an expression.
            n.setTy(String.withCString("u8"));
            return;
            }
        if (k == (u16)nkSizeof)
            {
            // The target's size type, C's size_t, as the reference: u64
            // where pointers are 8 bytes, u32 where 4, u16 on the banked 6502.
            n.setTy(_ptrW >= (u32)8   ? String.withCString("u64")
                    : _ptrW >= (u32)4 ? String.withCString("u32")
                                      : String.withCString("u16"));
            return;
            }
        if (k == (u16)nkSubscript || k == (u16)nkSlice)
            {
            // A class with an index operator: `m[i]` is its get call.
            if (resolveIndexOperator(n, _opIndexTarget == n))
                return;
            if (k == (u16)nkSubscript && n.kidCount() > 2)
                _errorAt(String.withCString("only a class with an index operator takes several indices, as in :operator(self[i, j])"), n);
            // A slice yields the same element type as an index does — what
            // differs is how many of them, which is not a type question here.
            if (n.kidCount() > (u32)0)
                n.setTy(elementOf(n.kid((u32)0).ty()));
            return;
            }
        if (k == (u16)nkNew)
            {
            String* t = String.withString(n.name());
            t.appendByte((u8)'*');
            n.setTy(t);
            // `new T` runs T's init; the name it resolved to is what the
            // lowering will call.
            Node* cls = (Node*)_classes.get((Hashable*)n.name());
            if (cls != 0)
                {
                // The flag propagates up the parent chain: instantiating a
                // subclass instantiates every ancestor's storage with it.
                // Up the parent chain — instantiating a subclass instantiates
                // its ancestors' storage with it, and the chain ends at Object
                // (which is why Object itself is marked in any program that
                // instantiates anything).
                for (Node* c = cls; c != 0; c = parentOf(c))
                    c.setUsedByNew();
                // `new T(a, b)` picks the init that TAKES two arguments,
                // searching this class and then its ancestors. A call that
                // matches no init anywhere stamps nothing, so no initialiser
                // runs and every field reads back zero — reported here, since
                // leaving it to the original leaves the SHIPPED compiler
                // accepting it.
                // An array of class (`new T[n]`, a count after the
                // arguments) runs no init, as in the reference (its
                // countExpr == nil test): the port used to resolve one and the
                // lowering called it on the first element with no arguments.
                if (n.kidCount() > (u32)n.num())
                    return;
                Node* ini = initOverload(cls, n);
                if (ini != 0)
                    {
                    narrowLengthArgs(ini, n, (u32)0);
                    n.setSym(ini.sym());
                    noteCallEdge(clsLabel(n.name(), ini.sym() != 0 ? ini.sym() : ini.name()));
                    }
                else
                    reportUnmatchedInit(cls, n);
                }
            return;
            }
        if (k == (u16)nkMember)
            {
            typeMember(n);
            return;
            }
        if (k == (u16)nkCall)
            {
            typeCall(n);
            return;
            }
        if (k == (u16)nkMethodCall)
            {
            typeMethodCall(n);
            return;
            }
        if (k == (u16)nkAssign)
            {
            if (n.kidCount() > (u32)0 && n.kid((u32)0).ty() != 0)
                n.setTy(n.kid((u32)0).ty());
            // `b = &c.m;` where b is a block compiled clean, tested TRUE, and
            // then the call did NOTHING — the button that does nothing.
            if (n.kidCount() >= (u32)2)
                checkClassPointerAssignAt(n.kid((u32)0).ty(), n.kid((u32)1).ty(),
                                          n.kid((u32)1), "assignment", n);
            return;
            }
        }

    // The widened type of the two operands, and nothing more: `u8 + u8` is a
    // u8 and wraps at 8 bits. Bitwise and shifts likewise keep their declared
    // width, and comparisons yield bool.
    // The type of `a <op> b` when both are integer literals, or none when the
    // operator does not fold.
    // Folded in 64 bits, as the original's foldBinaryExpr is: `1000000 *
    // 1000000` is 1000000000000, and folding it at 32 bits wrapped it to
    // 3567587328 — which then typed as u32 rather than u64.
    String* foldedLiteralType(String* op, i64 a, i64 b)
        {
        if (op == 0)
            return (String*)0;
        i64 v = (i64)0;
        if (_isOp(op, "+"))
            v = a + b;
        else if (_isOp(op, "-"))
            v = a - b;
        else if (_isOp(op, "*"))
            v = a * b;
        else if (_isOp(op, "/"))
            {
            if (b == (i64)0)
                return (String*)0;
            v = a / b;
            }
        else if (_isOp(op, "%"))
            {
            if (b == (i64)0)
                return (String*)0;
            v = a % b;
            }
        else if (_isOp(op, "&"))
            v = a & b;
        else if (_isOp(op, "|"))
            v = a | b;
        else if (_isOp(op, "^"))
            v = a ^ b;
        else if (_isOp(op, "<<"))
            v = a << b;
        else if (_isOp(op, ">>"))
            v = a >> b;
        else if (_isOp(op, "<"))
            v = (a < b) ? (i64)1 : (i64)0;
        else if (_isOp(op, ">"))
            v = (a > b) ? (i64)1 : (i64)0;
        else if (_isOp(op, "<="))
            v = (a <= b) ? (i64)1 : (i64)0;
        else if (_isOp(op, ">="))
            v = (a >= b) ? (i64)1 : (i64)0;
        else if (_isOp(op, "=="))
            v = (a == b) ? (i64)1 : (i64)0;
        else if (_isOp(op, "!="))
            v = (a != b) ? (i64)1 : (i64)0;
        else
            return (String*)0;
        // The folded RESULT's type, and so the CAPPED ladder the reference's
        // foldBinaryExpr uses (`inferTypeFromLiteral:`): a folded constant is
        // 32-bit at the widest, whatever the value, so that both compilers put
        // the same type on the node. A literal WRITTEN in the source is typed
        // by forIntLiteral instead, where u64/i64 are reachable.
        return Types.forFoldedValue(v);
        }

    // The full-precision integer value of a wholly-constant expression, true on
    // success. Recurses through nested binary ops so a CHAIN of literals —
    // `CKE * CKR * 16` — is evaluated whole, in 64 bits, not one node at a time.
    // Folding one node at a time truncated the chain: `192 * 128` typed a u16
    // (24576 fits), then `* 16` ran in that u16 width and wrapped to 0, silently
    // (bug 198). A constant has no runtime and no wrapping intent, so it is
    // evaluated at full width; §3.1 wrapping still governs RUNTIME arithmetic,
    // where an operand is a variable and this returns false.
    bool constIntValue(Node* n, i64* out)
        {
        if (n.kind() == (u16)nkInt)
            {
            *out = n.num();
            return true;
            }
        if (n.kind() == (u16)nkBinary)
            {
            i64 a = (i64)0;
            i64 b = (i64)0;
            if (!constIntValue(n.kid((u32)0), &a))
                return false;
            if (!constIntValue(n.kid((u32)1), &b))
                return false;
            String* op = n.op();
            if (op == 0)
                return false;
            if (_isOp(op, "+"))
                {
                *out = a + b;
                return true;
                }
            else if (_isOp(op, "-"))
                {
                *out = a - b;
                return true;
                }
            else if (_isOp(op, "*"))
                {
                *out = a * b;
                return true;
                }
            else if (_isOp(op, "/"))
                {
                if (b == (i64)0)
                    return false;
                *out = a / b;
                return true;
                }
            else if (_isOp(op, "%"))
                {
                if (b == (i64)0)
                    return false;
                *out = a % b;
                return true;
                }
            else if (_isOp(op, "&"))
                {
                *out = a & b;
                return true;
                }
            else if (_isOp(op, "|"))
                {
                *out = a | b;
                return true;
                }
            else if (_isOp(op, "^"))
                {
                *out = a ^ b;
                return true;
                }
            else if (_isOp(op, "<<"))
                {
                *out = a << b;
                return true;
                }
            else if (_isOp(op, ">>"))
                {
                *out = a >> b;
                return true;
                }
            else if (_isOp(op, "<"))
                {
                *out = (a < b) ? (i64)1 : (i64)0;
                return true;
                }
            else if (_isOp(op, ">"))
                {
                *out = (a > b) ? (i64)1 : (i64)0;
                return true;
                }
            else if (_isOp(op, "<="))
                {
                *out = (a <= b) ? (i64)1 : (i64)0;
                return true;
                }
            else if (_isOp(op, ">="))
                {
                *out = (a >= b) ? (i64)1 : (i64)0;
                return true;
                }
            else if (_isOp(op, "=="))
                {
                *out = (a == b) ? (i64)1 : (i64)0;
                return true;
                }
            else if (_isOp(op, "!="))
                {
                *out = (a != b) ? (i64)1 : (i64)0;
                return true;
                }
            return false;
            }
        return false;
        }

    // ── OVERLOADED OPERATORS ──────────────────────────────────────────
    // A method becomes an operator by carrying `:operator(pattern)`; the
    // parser kept the pattern as a shape (`_+_`, `-_`) and the operand names.
    // Here the pattern is checked against its method, and an operator
    // expression whose operand's class defines that operator becomes a call
    // of the chosen method. The rules, word for word with the reference's
    // XTSemanticAnalyzer+Operators.m:
    //
    //   * An operator applies when an operand is a class instance (a pointer
    //     to one, or one by value) whose class or an ancestor defines it. Such
    //     a class gives up the built-in meaning of THAT operator for its
    //     pointers: an unmatched use is an error, never pointer arithmetic.
    //   * Candidates: instance methods of the left operand's class, then
    //     static methods of either operand's class, each class walked up its
    //     parents, a nearer method hiding an ancestor's with the same
    //     parameter types. An override of an instance operator is the
    //     operator, with its pattern or without. Scored as any call's
    //     candidates; a tie between the best is an error naming both.
    //   * The chosen method is called as an ordinary method call, hung on the
    //     operator node past its operands (NF_OPCALL), and lowering lowers it
    //     in the operator's place.

    // The class an operand belongs to: a pointer to a class instance, or an
    // instance by value. 0 for anything else, a protocol-typed pointer too.
    Node* opClassOf(String* t)
        {
        if (t == 0)
            return (Node*)0;
        String* c = Vtable.canonical(t);
        u32 len = c.byteLength();
        if (len > (u32)1 && c.byteAt(len - (u32)1) == (u8)'*')
            {
            String* b = c.substringBytes((u32)0, len - (u32)1);
            if (b.byteAt(b.byteLength() - (u32)1) == (u8)'*')
                return (Node*)0;
            return (Node*)_classes.get((Hashable*)b);
            }
        return (Node*)_classes.get((Hashable*)c);
        }

    // Does the class or an ancestor define an operator of this shape?
    bool opClassDefines(Node* cls, String* shape)
        {
        for (Node* c = cls; c != 0; c = parentOf(c))
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                {
                Node* m = c.kid(i);
                if (m.kind() == (u16)nkMethodDecl && m.opShape() != 0 && m.opShape().equals(shape))
                    return true;
                }
        return false;
        }

    // Does the class or an ancestor define any operator?
    bool opClassHasOperators(Node* cls)
        {
        for (Node* c = cls; c != 0; c = parentOf(c))
            for (u32 i = 0; i < c.kidCount(); i++)
                {
                Node* m = c.kid(i);
                if (m.kind() == (u16)nkMethodDecl && m.opShape() != 0)
                    return true;
                }
        return false;
        }

    // Does the class or an ancestor define an index operator of any shape? One
    // that does gives up the built-in index for its pointers.
    bool opClassDefinesIndex(Node* cls)
        {
        for (Node* c = cls; c != 0; c = parentOf(c))
            for (u32 i = 0; i < c.kidCount(); i++)
                {
                Node* m = c.kid(i);
                if (m.kind() == (u16)nkMethodDecl && opIsIndex(m.opShape()))
                    return true;
                }
        return false;
        }

    // The first thing wrong with one operator method's pattern, or 0.
    String* opPatternFault(Node* m, Node* cls)
        {
        String* name = m.name();
        bool isStatic = m.hasFlag((u32)NF_STATIC);
        if (m.hasFlag((u32)NF_VARARGS))
            return String.withFormat("operator method '%s' cannot take '...'", name.cString());
        String* rt = m.op();
        bool several = false;
        if (rt != 0)
            for (u32 i = (u32)0; i < rt.byteLength(); i = i + (u32)1)
                if (rt.byteAt(i) == (u8)',')
                    several = true;
        // An index set and a compound assignment are statements.
        String* shp = m.opShape();
        bool statement = opIsIndexSet(shp) || opIsCompound(shp);
        bool isVoid = rt == 0 || _isOp(rt, "void");
        if (statement && !isVoid)
            return String.withFormat("operator method '%s' must return void: an index set or compound assignment is a statement", name.cString());
        if (!statement && (several || isVoid))
            return String.withFormat("operator method '%s' must return one value", name.cString());
        Array* names = m.opNames();
        Map* seen = new Map();
        bool usesSelf = false;
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* op = (String*)names.get(i);
            if (seen.get((Hashable*)op) != 0)
                return String.withFormat("'%s' appears twice in the :operator pattern of '%s'", op.cString(), name.cString());
            seen.set((Hashable*)op, (Object*)op);
            if (_isOp(op, "self"))
                {
                if (isStatic)
                    return String.withFormat("the :operator pattern of static method '%s' cannot use self", name.cString());
                usesSelf = true;
                continue;
                }
            bool isParam = false;
            for (u32 j = (u32)0; j < m.kidCount(); j = j + (u32)1)
                if (m.kid(j).kind() == (u16)nkParam && m.kid(j).name().equals(op))
                    isParam = true;
            if (!isParam)
                return String.withFormat("'%s' in the :operator pattern of '%s' is neither self nor one of its parameters", op.cString(), name.cString());
            }
        for (u32 j = (u32)0; j < m.kidCount(); j = j + (u32)1)
            {
            Node* p = m.kid(j);
            if (p.kind() == (u16)nkParam && seen.get((Hashable*)p.name()) == 0)
                return String.withFormat("parameter '%s' of '%s' does not appear in its :operator pattern", p.name().cString(), name.cString());
            }
        if (!isStatic && !usesSelf)
            return String.withFormat("the :operator pattern of instance method '%s' must use self", name.cString());
        if (isStatic)
            {
            bool own = false;
            for (u32 j = (u32)0; j < m.kidCount(); j = j + (u32)1)
                {
                Node* p = m.kid(j);
                if (p.kind() != (u16)nkParam)
                    continue;
                Node* pc = opClassOf(p.op());
                if (pc != 0 && classInheritsOrEquals(pc.name(), cls.name()))
                    own = true;
                }
            if (!own)
                return String.withFormat("static operator '%s' needs an operand of its own class '%s'", name.cString(), cls.name().cString());
            }
        // An index or a compound assignment applies to the receiver.
        if ((opIsIndex(shp) || opIsCompound(shp))
            && (names.count() == 0 || !_isOp((String*)names.get(0), "self")))
            return String.withFormat("the :operator pattern of '%s' must apply its operator to self, as in (self[i]) or (self += o)", name.cString());
        return (String*)0;
        }

    // Compound assignments: `_+=_` and the rest. (`_<=_` and `_>=_` compare.)
    bool opIsCompound(String* shape)
        {
        if (shape == 0)
            return false;
        return _isOp(shape, "_+=_") || _isOp(shape, "_-=_") || _isOp(shape, "_*=_") || _isOp(shape, "_/=_")
            || _isOp(shape, "_%=_") || _isOp(shape, "_&=_") || _isOp(shape, "_|=_") || _isOp(shape, "_^=_")
            || _isOp(shape, "_<<=_") || _isOp(shape, "_>>=_") || _isOp(shape, "_<:=_") || _isOp(shape, "_:>=_");
        }

    // Index operators: `_[_]`, `_[_,_]`, `_[_.._]`, `_[_..._]`, and their set forms.
    bool opIsIndex(String* shape)
        {
        return shape != 0 && shape.byteLength() > 1 && shape.byteAt(0) == (u8)'_' && shape.byteAt(1) == (u8)'[';
        }

    bool opIsIndexSet(String* shape)
        {
        if (!opIsIndex(shape))
            return false;
        u32 len = shape.byteLength();
        return shape.byteAt(len - 1) == (u8)'_' && shape.byteAt(len - 2) == (u8)'=';
        }

    // The shape of an index over `count` indices, or over a range (`..`, `...`).
    static String* indexShape(u32 count, String* range, bool set)
        {
        String* sh = String.withCString("_[");
        if (range != 0)
            {
            sh.appendCString("_");
            sh.append(range);
            sh.appendCString("_");
            }
        else
            for (u32 i = 0; i < count; i++)
                sh.appendCString(i > 0 ? ",_" : "_");
        sh.appendCString(set ? "]=_" : "]");
        return sh;
        }

    // How an index is named in a message: `[]`, `[..]`, `[...]`, then `=`.
    static String* indexSpelling(String* range, bool set)
        {
        String* sp = String.withCString("[");
        if (range != 0)
            sp.append(range);
        sp.appendCString(set ? "]=" : "]");
        return sp;
        }

    // Check every `:operator(pattern)` in the program against its method,
    // refuse it on a free function or a protocol method, and report a pattern
    // the parser could not take.
    // A `:precedence` spec as written: "above *, right" for ">*,right".
    static String* precedenceSpelling(String* spec)
        {
        bool right = spec.hasSuffix(String.withCString(",right"));
        String* body = right ? spec.substringBytes(0, spec.byteLength() - 6) : spec;
        String* op = body.substringFromByte(1);
        u8 rel = body.byteAt(0);
        String* out = String.withCString(rel == (u8)'>' ? "above " : (rel == (u8)'<' ? "below " : ""));
        out.append(op);
        if (right)
            out.appendCString(", right");
        return out;
        }

    // What is wrong with a method's `:precedence(...)`, or 0: a form the
    // parser could not take, no `:operator` beside it, or an operator that is
    // built in or prefix.
    String* opPrecedenceFault(Node* m)
        {
        String* p = m.opPrec();
        if (p == 0)
            return (String*)0;
        if (p.byteLength() >= 2 && p.byteAt(0) == (u8)'?')
            return p.substringFromByte(2);
        if (m.opShape() == 0)
            return String.withFormat("':precedence' on '%s' needs ':operator' on the same method", m.name().cString());
        if (!Node.isUserShape(m.opShape()))
            return String.withFormat("'%s' keeps the precedence of the built-in operator: ':precedence' is for an operator of a class's own shape; remove ':precedence'",
                                     Node.shapeCore(m.opShape()).cString());
        if (Node.shapeIsBracket(m.opShape()))
            return String.withFormat("':precedence' is for an operator between two operands: the bracket operator %s binds as parentheses do; remove ':precedence'",
                                     Node.shapeSpelling(m.opShape()).cString());
        if (!Node.shapeIsInfix(m.opShape()))
            return String.withFormat("':precedence' is for an operator between two operands: the prefix '%s' binds as the built-in prefix operators do; remove ':precedence'",
                                     Node.shapeCore(m.opShape()).cString());
        return (String*)0;
        }

    void checkOperatorMethods(Node* program)
        {
        // Each shape's first `:precedence`, and where it was: [spec, class, method].
        Map* precOf = new Map();
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            {
            Node* d = program.kid(i);
            u16 k = d.kind();
            if (k == (u16)nkFunctionDecl)
                {
                if (d.opPat() != 0 || d.opPrec() != 0)
                    _errorAt(String.withFormat("'%s' is not a method: an operator is defined by a method of one of its operands' classes", d.name().cString()), d);
                }
            else if (k == (u16)nkProtocolDecl)
                {
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    {
                    Node* m = d.kid(j);
                    if (m.kind() == (u16)nkMethodDecl && (m.opPat() != 0 || m.opPrec() != 0))
                        {
                        _errorAt(String.withFormat("protocol method '%s' cannot be an operator yet", m.name().cString()), m);
                        m.setOpPat((String*)0);
                        }
                    }
                }
            else if (k == (u16)nkClassDecl)
                {
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    {
                    Node* m = d.kid(j);
                    if (m.kind() != (u16)nkMethodDecl || (m.opPat() == 0 && m.opPrec() == 0))
                        continue;
                    if (m.opFault() != 0)
                        {
                        _errorAt(m.opFault(), m);
                        continue;
                        }
                    if (m.opShape() == 0)
                        {
                        _errorAt(opPrecedenceFault(m), m);
                        continue;
                        }
                    String* fault = opPatternFault(m, d);
                    if (fault != 0)
                        {
                        _errorAt(fault, m);
                        m.setOpPat((String*)0);
                        continue;
                        }
                    _anyOps = true;
                    String* pf = opPrecedenceFault(m);
                    if (pf != 0)
                        {
                        _errorAt(pf, m);
                        continue;
                        }
                    // One meaning for a bracket in a class: `|M|` is the
                    // determinant or the norm, not both.
                    if (Node.shapeIsBracket(m.opShape()))
                        for (u32 q = (u32)0; q < j; q = q + (u32)1)
                            {
                            Node* o = d.kid(q);
                            if (o.kind() == (u16)nkMethodDecl && o.opShape() != 0 && o.opShape().equals(m.opShape())
                                && o.hasFlag((u32)NF_STATIC) == m.hasFlag((u32)NF_STATIC) && Vtable.sameParams(o, m))
                                {
                                String* msg = String.withCString("'");
                                msg.append(d.name());
                                msg.appendCString(".");
                                msg.append(m.name());
                                msg.appendCString("' gives ");
                                msg.append(Node.shapeSpelling(m.opShape()));
                                msg.appendCString(" a second meaning: '");
                                msg.append(d.name());
                                msg.appendCString(".");
                                msg.append(o.name());
                                msg.appendCString("' defines it already; remove ':operator' from one of them and call it by name");
                                _errorAt(msg, m);
                                break;
                                }
                            }
                    if (m.opPrec() == 0)
                        continue;
                    // One operator, one precedence: the parse reads it before
                    // any type is known.
                    Array* first = (Array*)precOf.get((Hashable*)m.opShape());
                    if (first == 0)
                        {
                        Array* rec = new Array();
                        rec.add((Object*)m.opPrec());
                        rec.add((Object*)d.name());
                        rec.add((Object*)m.name());
                        precOf.set((Hashable*)m.opShape(), (Object*)rec);
                        }
                    else if (!((String*)first.get(0)).equals(m.opPrec()))
                        {
                        String* msg = String.withCString("operator '");
                        msg.append(Node.shapeCore(m.opShape()));
                        msg.appendCString("' has the precedence '");
                        msg.append(Sema.precedenceSpelling((String*)first.get(0)));
                        msg.appendCString("' in '");
                        msg.append((String*)first.get(1));
                        msg.appendCString(".");
                        msg.append((String*)first.get(2));
                        msg.appendCString("' and '");
                        msg.append(Sema.precedenceSpelling(m.opPrec()));
                        msg.appendCString("' in '");
                        msg.append(d.name());
                        msg.appendCString(".");
                        msg.append(m.name());
                        msg.appendCString("': an operator has one precedence; give both the same ':precedence', or leave it off one of them");
                        _errorAt(msg, m);
                        }
                    }
                }
            }
        }

    // Add the operator methods of `cls` and its ancestors — the instance ones
    // or the static ones — to the candidates. A method hides an ancestor's
    // with the same parameter types, and one already present is not added
    // twice (the two operands may share a class).
    void addOpCandidates(Node* cls, String* shape, bool wantStatic, Array* cands, Array* owners)
        {
        u32 first = cands.count();
        for (Node* c = cls; c != 0; c = parentOf(c))
            {
            u32 nearer = cands.count();
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                {
                Node* m = c.kid(i);
                if (m.kind() != (u16)nkMethodDecl || m.opShape() == 0 || !m.opShape().equals(shape))
                    continue;
                if (m.hasFlag((u32)NF_STATIC) != wantStatic)
                    continue;
                // An override in a nearer class is the operator too, written
                // with its pattern or not: the call names it, as `a.plus(b)`
                // would.
                Node* use = m;
                Node* useOwner = c;
                for (Node* nc = cls; !wantStatic && nc != 0 && nc != c && use == m; nc = parentOf(nc))
                    for (u32 q = (u32)0; q < nc.kidCount() && use == m; q = q + (u32)1)
                        {
                        Node* o = nc.kid(q);
                        if (o.kind() == (u16)nkMethodDecl && !o.hasFlag((u32)NF_STATIC) && o.name() != 0
                            && o.name().equals(m.name()) && Vtable.sameParams(o, m))
                            {
                            use = o;
                            useOwner = nc;
                            }
                        }
                bool present = false;
                for (u32 j = (u32)0; j < cands.count(); j = j + (u32)1)
                    if ((Node*)cands.get(j) == use)
                        present = true;
                if (present)
                    continue;
                bool hidden = false;
                for (u32 j = first; j < nearer; j = j + (u32)1)
                    if (Vtable.sameParams((Node*)cands.get(j), use))
                        hidden = true;
                if (hidden)
                    continue;
                cands.add((Object*)use);
                owners.add((Object*)useOwner);
                }
            }
        }

    // The call one candidate makes of the operands: an instance method on the
    // first operand with the rest as arguments; a static one on its class with
    // the operands as arguments, in the order its parameters name them.
    Node* opCallOf(Node* m, Node* owner, Array* ops, Node* at)
        {
        Node* call = Node.withName((u16)nkMethodCall, m.name());
        call.setPos(at.fileId(), at.line(), at.col());
        if (!m.hasFlag((u32)NF_STATIC))
            {
            for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
                call.add((Node*)ops.get(i));
            call.setNum((i64)(ops.count() - (u32)1));
            return call;
            }
        Node* recv = Node.withName((u16)nkIdent, owner.name());
        recv.setPos(at.fileId(), at.line(), at.col());
        call.add(recv);
        Array* names = m.opNames();
        u32 argc = (u32)0;
        for (u32 j = (u32)0; j < m.kidCount(); j = j + (u32)1)
            {
            Node* p = m.kid(j);
            if (p.kind() != (u16)nkParam)
                continue;
            u32 idx = (u32)0;
            for (u32 q = (u32)0; q < names.count(); q = q + (u32)1)
                if (((String*)names.get(q)).equals(p.name()))
                    idx = q;
            call.add((Node*)ops.get(idx < ops.count() ? idx : (u32)0));
            argc = argc + (u32)1;
            }
        call.setNum((i64)argc);
        return call;
        }

    // The argument types of some operands, as a call's are described.
    String* opTypes(Array* ops, u32 from)
        {
        Node* list = Node.with((u16)nkMethodCall);
        for (u32 i = from; i < ops.count(); i = i + (u32)1)
            list.add((Node*)ops.get(i));
        return describeArgTypes(list, (u32)0);
        }

    // Choose among the operator methods of shape `shape` for typed operands:
    // the instance and static ones of `lc` and the static ones of `rc`. The
    // typed call, or 0: with _opAmbig false when nothing matches (nothing is
    // reported), true after reporting a tie between the best.
    Node* opPick(String* shape, String* op, Array* ops, Node* at, Node* lc, Node* rc)
        {
        _opAmbig = false;
        Array* cands = new Array();
        Array* owners = new Array();
        if (lc != 0)
            {
            addOpCandidates(lc, shape, false, cands, owners);
            addOpCandidates(lc, shape, true, cands, owners);
            }
        if (rc != 0)
            addOpCandidates(rc, shape, true, cands, owners);

        u32 best = Overload.noMatch();
        Array* tied = new Array();
        Array* calls = new Array();
        for (u32 i = 0; i < cands.count(); i++)
            {
            Node* call = opCallOf((Node*)cands.get(i), (Node*)owners.get(i), ops, at);
            calls.add((Object*)call);
            u32 sc = scoreCandidate((Node*)cands.get(i), call, 1);
            if (sc == Overload.noMatch())
                continue;
            if (sc < best)
                {
                best = sc;
                tied = new Array();
                }
            if (sc == best)
                tied.add((Object*)Number.with(i));
            }
        if (tied.count() == 0)
            return (Node*)0;
        if (tied.count() > 1)
            {
            u32 a = ((Number*)tied.get(0)).asU32();
            u32 b = ((Number*)tied.get(1)).asU32();
            String* msg = String.withFormat("operator '%s' on (%s) is ambiguous: '%s.%s' and '%s.%s' both match",
                                            op.cString(), opTypes(ops, 0).cString(),
                                            ((Node*)owners.get(a)).name().cString(), ((Node*)cands.get(a)).name().cString(),
                                            ((Node*)owners.get(b)).name().cString(), ((Node*)cands.get(b)).name().cString());
            _errorAt(msg, at);
            _opAmbig = true;
            return (Node*)0;
            }
        u32 w = ((Number*)tied.get(0)).asU32();
        Node* call = (Node*)calls.get(w);
        Node* chosen = (Node*)cands.get(w);
        if (chosen.hasFlag((u32)NF_STATIC))
            typeExpr(call.kid(0));
        _opForced = chosen;
        typeMethodCall(call);
        _opForced = (Node*)0;
        return call;
        }

    // ── OPERATORS OF A CLASS'S OWN SHAPE ─────────────────────────────

    // A binary operator that is none of the built-in ones: one a class defines
    // with a shape of its own (the parser spells it, `**`).
    bool userBinaryOp(String* op)
        {
        return !(_isOp(op, "+") || _isOp(op, "-") || _isOp(op, "*") || _isOp(op, "/") || _isOp(op, "%")
                 || _isOp(op, "&") || _isOp(op, "|") || _isOp(op, "^") || _isOp(op, "<<") || _isOp(op, ">>")
                 || _isOp(op, "<:") || _isOp(op, ":>") || _isOp(op, "&&") || _isOp(op, "||") || _isOp(op, "==")
                 || _isOp(op, "!=") || _isOp(op, "<") || _isOp(op, ">") || _isOp(op, "<=") || _isOp(op, ">="));
        }

    // …and a prefix one.
    bool userUnaryOp(String* op)
        {
        return !(_isOp(op, "-") || _isOp(op, "+") || _isOp(op, "~") || _isOp(op, "!") || _isOp(op, "&")
                 || _isOp(op, "*") || _isOp(op, "++") || _isOp(op, "--") || _isOp(op, "<") || _isOp(op, ">")
                 || _isOp(op, ">>") || _isOp(op, ">>>"));
        }

    // The class of an operand (or an ancestor of it) that defines `shape`: the
    // left operand's, else the right's. 0 when neither does.
    Node* opOwnerOfShape(String* shape, Array* ops)
        {
        Node* lc = opClassOf(((Node*)ops.get(0)).ty());
        if (lc != 0 && opClassDefines(lc, shape))
            return lc;
        Node* rc = ops.count() > 1 ? opClassOf(((Node*)ops.get(1)).ty()) : (Node*)0;
        if (rc != 0 && opClassDefines(rc, shape))
            return rc;
        return (Node*)0;
        }

    // An operator of a class's own shape has no built-in meaning. When no
    // operand's class defines it, that is an error, unless the operator is one
    // of two readings being chosen between (it is then noted, not reported).
    // true when the node is dealt with that way, typed u8.
    bool userOperatorUndefined(Node* n, String* shape, String* op, Array* ops)
        {
        Node* owner = opOwnerOfShape(shape, ops);
        bool noting = n.hasFlag((u32)NF_TWOREAD) && _readingCollect != 0 && _readingCollect.count() > 0;
        if (noting)
            {
            Array* site = new Array();
            site.add((Object*)Number.withU32(owner != 0 ? 1 : 0));
            site.add((Object*)op);
            site.add((Object*)(owner != 0 ? owner.name() : String.withCString("")));
            site.add((Object*)n);
            ((Array*)_readingCollect.last()).add((Object*)site);
            }
        if (owner != 0)
            return false;
        n.setTy(String.withCString("u8"));
        if (!noting && Node.shapeIsBracket(shape))
            {
            String* pat = String.withCString("");
            for (u32 i = 0; i < shape.byteLength(); i++) : serial
                {
                if (shape.byteAt(i) == (u8)'_')
                    pat.appendCString("self");
                else
                    pat.appendByte(shape.byteAt(i));
                }
            String* m = String.withCString("no class defines ");
            m.append(op);
            m.appendCString(" for '");
            m.append(opTypes(ops, 0));
            m.appendCString("'; the operand must be an instance of a class that defines it with :operator(");
            m.append(pat);
            m.appendCString(")");
            _errorAt(m, n);
            }
        else if (!noting)
            {
            String* m = String.withCString(ops.count() == 1 ? "no class defines the prefix operator '" : "no class defines the operator '");
            m.append(op);
            m.appendCString("' for (");
            m.append(opTypes(ops, 0));
            m.appendCString(ops.count() == 1 ? "); the operand must be an instance of a class that defines it with :operator(...)" : "); one operand must be an instance of a class that defines it with :operator(...)");
            _errorAt(m, n);
            }
        return true;
        }

    // The operator nodes of a reading, down through its operators: binary,
    // prefix, postfix, conditional, assignment and cast nodes.
    static void readingOperatorNodes(Node* n, Array* out)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        u32 want = 0;
        if (k == (u16)nkBinary || k == (u16)nkAssign)
            want = 2;
        else if (k == (u16)nkUnary || k == (u16)nkPostfix || k == (u16)nkCast)
            want = 1;
        else if (k == (u16)nkTernary)
            want = 3;
        else
            return;
        out.add((Object*)n);
        for (u32 i = 0; i < want && i < n.kidCount(); i++) : serial
            Sema.readingOperatorNodes(n.kid(i), out);
        }

    // Integers (bool and enums too), numbers, pointers, as the built-in
    // operators take them.
    static bool readingInt(String* t)
        {
        return Types.isInteger(t) || Types.isEnumName(t);
        }
    static bool readingNum(String* t)
        {
        return Sema.readingInt(t) || Types.isFloating(t);
        }
    static bool readingPtr(String* t)
        {
        return Types.isPointer(t) || (t != 0 && t.byteLength() > 0 && t.byteAt(t.byteLength() - 1) == (u8)']');
        }

    // Is a built-in operator of the old reading one the language defines for
    // its operands' types: arithmetic on numbers, pointer arithmetic and
    // comparison, bitwise operators on integers, a dereference of a pointer?
    // Sema types some other uses without complaint (a class value
    // multiplied), so the old reading is held to these. An operator that
    // became a class's method call is defined.
    bool readingOperatorDefined(Node* n)
        {
        u16 k = n.kind();
        String* op = n.op();
        if (k == (u16)nkBinary)
            {
            if (n.hasFlag((u32)NF_OPCALL))
                return true;
            String* l = n.kid(0).ty();
            String* r = n.kid(1).ty();
            if (_isOp(op, "+"))
                return (Sema.readingNum(l) && Sema.readingNum(r)) || (Sema.readingPtr(l) && Sema.readingInt(r)) || (Sema.readingInt(l) && Sema.readingPtr(r));
            if (_isOp(op, "-"))
                return (Sema.readingNum(l) && Sema.readingNum(r)) || (Sema.readingPtr(l) && Sema.readingInt(r)) || (Sema.readingPtr(l) && Sema.readingPtr(r));
            if (_isOp(op, "*") || _isOp(op, "/") || _isOp(op, "%"))
                return Sema.readingNum(l) && Sema.readingNum(r);
            if (_isOp(op, "&") || _isOp(op, "|") || _isOp(op, "^") || _isOp(op, "<<") || _isOp(op, ">>")
                || _isOp(op, "<:") || _isOp(op, ":>"))
                return Sema.readingInt(l) && Sema.readingInt(r);
            if (_isOp(op, "<") || _isOp(op, ">") || _isOp(op, "<=") || _isOp(op, ">=") || _isOp(op, "==") || _isOp(op, "!="))
                return (Sema.readingNum(l) && Sema.readingNum(r)) || (Sema.readingPtr(l) && Sema.readingPtr(r));
            if (_isOp(op, "&&") || _isOp(op, "||"))
                return (Sema.readingNum(l) || Sema.readingPtr(l)) && (Sema.readingNum(r) || Sema.readingPtr(r));
            return false;
            }
        if (k == (u16)nkUnary)
            {
            if (n.hasFlag((u32)NF_OPCALL))
                return true;
            String* t = n.kid(0).ty();
            if (_isOp(op, "-") || _isOp(op, "+"))
                return Sema.readingNum(t);
            if (_isOp(op, "!"))
                return Sema.readingNum(t) || Sema.readingPtr(t);
            if (_isOp(op, "*"))
                return Sema.readingPtr(t);
            if (_isOp(op, "&"))
                return true;
            if (_isOp(op, "~") || _isOp(op, "++") || _isOp(op, "--") || _isOp(op, "<") || _isOp(op, ">")
                || _isOp(op, ">>") || _isOp(op, ">>>"))
                return Sema.readingInt(t);
            return false;
            }
        if (k == (u16)nkPostfix)
            return Sema.readingInt(n.kid(0).ty());
        return true;
        }

    // A spelling's width in columns: UTF-16 units.
    static u32 readingUnits(String* v)
        {
        u32 n = 0;
        for (u32 i = 0; i < v.byteLength(); i++) : serial
            {
            u8 b = v.byteAt(i);
            if ((b & (u8)$C0) == (u8)$80)
                continue;
            n = n + (b >= (u8)$F0 ? 2 : 1);
            }
        return n;
        }

    // Do the old reading's operators where the operators of `sites` are
    // written each have a meaning for their operands (readingOperatorDefined)?
    bool oldReadingDefined(Node* alt, Array* sites)
        {
        Array* nodes = new Array();
        Sema.readingOperatorNodes(alt, nodes);
        for (u32 i = 0; i < nodes.count(); i++) : serial
            {
            Node* n = (Node*)nodes.get(i);
            for (u32 j = 0; j < sites.count(); j++) : serial
                {
                Array* site = (Array*)sites.get(j);
                Node* at = (Node*)site.get(3);
                u32 len = Sema.readingUnits((String*)site.get(1));
                if (n.fileId() == at.fileId() && n.line() == at.line() && n.col() >= at.col()
                    && n.col() < at.col() + len && !readingOperatorDefined(n))
                    return false;
                }
            }
        return true;
        }

    // An expression read two ways (an operator a class defines whose
    // characters also read the old way, `a**b`): `n` holds the new reading,
    // `alt` the old one. The operator reading is kept when an operand's class
    // defines each such operator in it, the old one when none does; both
    // type-checking, or some defined and some not, is an error. `n` is typed
    // as the one kept.
    void chooseReading(Node* n, Node* alt)
        {
        u32 errMark = _errors.count();
        u32 warnMark = _warnings.count();
        if (_readingCollect == 0)
            _readingCollect = new Array();
        Array* sites = new Array();
        _readingCollect.add((Object*)sites);
        typeExpr(n);
        _readingCollect.removeAt(_readingCollect.count() - 1);
        u32 defined = 0;
        Array* firstDefined = (Array*)0;
        for (u32 i = 0; i < sites.count(); i++) : serial
            {
            Array* site = (Array*)sites.get(i);
            if (((Number*)site.get(0)).asU32() != 0)
                {
                if (firstDefined == 0)
                    firstDefined = site;
                defined++;
                }
            }
        if (defined == sites.count())
            {
            // The operator reading. The old one must not type-check as well.
            if (firstDefined != 0)
                {
                u32 e2 = _errors.count();
                u32 w2 = _warnings.count();
                typeExpr(alt);
                bool oldTypes = _errors.count() == e2 && oldReadingDefined(alt, sites);
                while (_errors.count() > e2)
                    _errors.removeAt(_errors.count() - 1);
                while (_warnings.count() > w2)
                    _warnings.removeAt(_warnings.count() - 1);
                if (oldTypes)
                    {
                    String* m = String.withCString("'");
                    m.append((String*)firstDefined.get(1));
                    m.appendCString("' reads two ways here and both type-check: as the operator of '");
                    m.append((String*)firstDefined.get(2));
                    m.appendCString("' and as the built-in operators it is spelt with; write those operators apart, or call the method by name");
                    _errorAt(m, (Node*)firstDefined.get(3));
                    }
                }
            return;
            }
        while (_errors.count() > errMark)
            _errors.removeAt(_errors.count() - 1);
        while (_warnings.count() > warnMark)
            _warnings.removeAt(_warnings.count() - 1);
        if (defined == 0)
            {
            // The old reading, in the new one's place.
            n.adoptReading(alt);
            typeExpr(n);
            return;
            }
        String* m = String.withCString("'");
        m.append((String*)firstDefined.get(1));
        m.appendCString("' is the operator of '");
        m.append((String*)firstDefined.get(2));
        m.appendCString("' in one place in this expression and has its built-in meaning in another; use parentheses");
        _errorAt(m, n);
        }

    // Resolve the operator node `n` (binary or prefix) over its typed operands.
    // false when no operand's class defines the operator: the built-in meaning
    // applies. true when the node now has its call, or an error was reported.
    bool resolveOperator(Node* n)
        {
        bool binary = n.kind() == (u16)nkBinary;
        String* op = n.op();
        if (op == 0)
            return false;
        // An operator a class defines with a shape of its own (`**`, `√`).
        bool user = binary ? userBinaryOp(op) : userUnaryOp(op);
        if (!user && !_anyOps)
            return false;
        bool overloadable = user || (binary
            ? (_isOp(op, "+") || _isOp(op, "-") || _isOp(op, "*") || _isOp(op, "/") || _isOp(op, "%")
               || _isOp(op, "&") || _isOp(op, "|") || _isOp(op, "^") || _isOp(op, "<<") || _isOp(op, ">>")
               || _isOp(op, "<:") || _isOp(op, ":>") || _isOp(op, "<") || _isOp(op, ">")
               || _isOp(op, "<=") || _isOp(op, ">="))
            : (_isOp(op, "-") || _isOp(op, "+") || _isOp(op, "~") || _isOp(op, "!")));
        if (!overloadable)
            return false;
        // A bracket shape is spelt in full (`|_|`), a prefix one by its
        // characters.
        bool bracket = !binary && Node.shapeIsBracket(op);
        String* shape = binary ? String.withCString("_") : String.withString(op);
        if (binary)
            shape.append(op);
        if (!bracket)
            shape.appendCString("_");
        if (bracket)
            op = Node.shapeSpelling(shape);
        Array* ops = new Array();
        ops.add((Object*)n.kid((u32)0));
        if (binary)
            ops.add((Object*)n.kid((u32)1));
        if (user && userOperatorUndefined(n, shape, op, ops))
            return true;
        Node* lc = opClassOf(n.kid((u32)0).ty());
        Node* rc = binary ? opClassOf(n.kid((u32)1).ty()) : (Node*)0;
        bool optL = lc != 0 && opClassDefines(lc, shape);
        bool optR = rc != 0 && opClassDefines(rc, shape);
        if (!optL && !optR)
            return false;

        Node* call = opPick(shape, op, ops, n, lc, rc);
        if (call == 0)
            {
            if (!_opAmbig)
                {
                String* msg = (String*)0;
                if (bracket)
                    msg = String.withFormat("'%s' has no %s taking '%s': pass one of the types its %s methods take", lc.name().cString(), op.cString(), opTypes(ops, 0).cString(), op.cString());
                else if (!binary)
                    msg = String.withFormat("'%s' has no prefix '%s' taking '%s'", lc.name().cString(), op.cString(), opTypes(ops, 0).cString());
                else if (optL)
                    msg = String.withFormat("'%s' has no '%s' taking '%s'", lc.name().cString(), op.cString(), opTypes(ops, 1).cString());
                else
                    {
                    Array* left = new Array();
                    left.add(ops.get(0));
                    msg = String.withFormat("'%s' has no '%s' taking '%s' on the left", rc.name().cString(), op.cString(), opTypes(left, 0).cString());
                    }
                _errorAt(msg, n);
                }
            n.setTy(String.withCString("u8"));
            return true;
            }
        // Hung past the operands; a node typed twice replaces its call.
        u32 slot = binary ? (u32)2 : (u32)1;
        if (n.hasFlag((u32)NF_OPCALL) && n.kidCount() > slot)
            n.setKid(slot, call);
        else
            n.add(call);
        n.addFlag((u32)NF_OPCALL);
        n.setTy(call.ty() != 0 ? call.ty() : String.withCString("u8"));
        return true;
        }

    // ── INDEX OPERATORS AND ASSIGNMENT ───────────────────────────────
    // Mirrors the reference's XTSemanticAnalyzer+Operators.m. A subscript's
    // kids are the base and its indices; a slice's the base and the bounds it
    // has. The call an index operator becomes hangs past them (NF_OPCALL).

    // The indices of a subscript, or the bounds of a slice, without the call.
    Array* opIndexList(Node* n)
        {
        Array* out = new Array();
        u32 end = n.kidCount();
        if (n.hasFlag((u32)NF_OPCALL) && end > 0)
            end--;
        for (u32 i = 1; i < end; i++)
            out.add((Object*)n.kid(i));
        return out;
        }

    // A slice's range spelling, `..` or `...`; 0 for a subscript.
    String* opIndexRange(Node* n)
        {
        if (n.kind() != (u16)nkSlice)
            return (String*)0;
        return String.withCString(n.hasFlag((u32)NF_INCLUSIVE) ? "..." : "..");
        }

    // The class with an index operator that an index node's base belongs to, or 0.
    Node* indexOperatorClassOf(Node* n)
        {
        if (!_anyOps || n == 0 || (n.kind() != (u16)nkSubscript && n.kind() != (u16)nkSlice) || n.kidCount() == 0)
            return (Node*)0;
        Node* cls = opClassOf(n.kid(0).ty());
        if (cls != 0 && opClassDefinesIndex(cls))
            return cls;
        return (Node*)0;
        }

    // The get call of an index node on a class with an index operator, or 0
    // after reporting why there is none.
    Node* indexGetCallOf(Node* n, Node* cls)
        {
        Array* idx = opIndexList(n);
        String* range = opIndexRange(n);
        if (range != 0 && idx.count() != 2)
            {
            _errorAt(String.withFormat("a range index on '%s' needs both bounds", cls.name().cString()), n);
            return (Node*)0;
            }
        String* shape = Sema.indexShape(idx.count(), range, false);
        String* op = Sema.indexSpelling(range, false);
        if (!opClassDefines(cls, shape) && opClassDefines(cls, Sema.indexShape(idx.count(), range, true)))
            {
            _errorAt(String.withFormat("'%s' has '%s=' but no '%s' to read an element with",
                                       cls.name().cString(), op.cString(), op.cString()), n);
            return (Node*)0;
            }
        Array* ops = new Array();
        ops.add((Object*)n.kid(0));
        for (u32 i = 0; i < idx.count(); i++)
            ops.add(idx.get(i));
        Node* call = opPick(shape, op, ops, n, cls, (Node*)0);
        if (call == 0 && !_opAmbig)
            _errorAt(String.withFormat("'%s' has no '%s' taking '%s'", cls.name().cString(), op.cString(),
                                       opTypes(idx, 0).cString()), n);
        return call;
        }

    // `m[i]`, `m[i, j]` or `m[a..b]` on a class with an index operator: the
    // get call, or nothing yet for the target of an assignment. false when the
    // base's class has no index operator, so the built-in index applies.
    bool resolveIndexOperator(Node* n, bool target)
        {
        Node* cls = indexOperatorClassOf(n);
        if (cls == 0)
            return false;
        // The target of an assignment is not read: the assignment resolves it.
        if (target)
            return true;
        Node* call = indexGetCallOf(n, cls);
        if (call == 0)
            {
            n.setTy(String.withCString("u8"));
            return true;
            }
        // Hung past the operands; a node typed twice replaces its call.
        if (n.hasFlag((u32)NF_OPCALL))
            n.setKid(n.kidCount() - 1, call);
        else
            n.add(call);
        n.addFlag((u32)NF_OPCALL);
        n.setTy(call.ty() != 0 ? call.ty() : String.withCString("u8"));
        return true;
        }

    // A subscript or slice an index operator made a call of.
    static bool isOpIndex(Node* n)
        {
        return n != 0 && (n.kind() == (u16)nkSubscript || n.kind() == (u16)nkSlice) && n.hasFlag((u32)NF_OPCALL);
        }

    // An operand read twice is evaluated once, first, unless reading it again
    // costs nothing and changes nothing: a name or a literal.
    static void opSharedRvalue(Node* e, Array* out)
        {
        if (e == 0)
            return;
        u16 k = e.kind();
        if (k == (u16)nkIdent || k == (u16)nkInt || k == (u16)nkFloat || k == (u16)nkStr || k == (u16)nkChar || k == (u16)nkBool)
            return;
        out.add((Object*)e);
        }

    // The operands of an lvalue that its address is computed from: a pointer's
    // value is shared, an inline array or struct is reached through its own
    // lvalue.
    static void opSharedLvalue(Node* lv, Array* out)
        {
        if (lv == 0)
            return;
        u16 k = lv.kind();
        if (k == (u16)nkSubscript && !lv.hasFlag((u32)NF_OPCALL) && lv.kidCount() > 1)
            {
            Node* b = lv.kid(0);
            if (b.ty() != 0 && Types.isPointer(b.ty()))
                Sema.opSharedRvalue(b, out);
            else
                Sema.opSharedLvalue(b, out);
            Sema.opSharedRvalue(lv.kid(1), out);
            }
        else if (k == (u16)nkMember && lv.kidCount() > 0)
            {
            Node* b = lv.kid(0);
            if (lv.hasFlag((u32)NF_ARROW) || (b.ty() != 0 && Types.isPointer(b.ty())))
                Sema.opSharedRvalue(b, out);
            else
                Sema.opSharedLvalue(b, out);
            }
        else if (k == (u16)nkUnary && lv.op() != 0 && lv.op().byteLength() == 1 && lv.op().byteAt(0) == (u8)'*' && lv.kidCount() > 0)
            Sema.opSharedRvalue(lv.kid(0), out);
        }

    // `obj.p` where obj's class (or an ancestor) has a one-parameter `setP`:
    // an assignment to it is a property write. The type of the setter's
    // parameter, or 0 for anything else.
    String* opPropertyType(Node* lv)
        {
        if (lv.kind() != (u16)nkMember || lv.kidCount() == 0 || lv.name() == 0 || lv.name().byteLength() == 0)
            return (String*)0;
        Node* cls = opClassOf(lv.kid(0).ty());
        if (cls == 0)
            return (String*)0;
        String* setter = String.withCString("set");
        u8 c0 = lv.name().byteAt(0);
        if (c0 >= (u8)'a' && c0 <= (u8)'z')
            c0 = c0 - (u8)32;
        setter.appendByte(c0);
        setter.append(lv.name().substringBytes(1, lv.name().byteLength() - 1));
        for (Node* c = cls; c != 0; c = parentOf(c))
            for (u32 i = 0; i < c.kidCount(); i++)
                {
                Node* m = c.kid(i);
                if (m.kind() != (u16)nkMethodDecl || m.name() == 0 || !m.name().equals(setter))
                    continue;
                Node* only = (Node*)0;
                u32 params = 0;
                for (u32 j = 0; j < m.kidCount(); j++)
                    if (m.kid(j).kind() == (u16)nkParam)
                        {
                        params++;
                        only = m.kid(j);
                        }
                if (params == 1)
                    return only.op();
                }
        return (String*)0;
        }

    // `l OP r` over typed operands, typed: an operator's call or the built-in.
    Node* opBinary(String* op, Node* l, Node* r, Node* at)
        {
        Node* bin = Node.with((u16)nkBinary);
        bin.setOp(op);
        bin.add(l);
        bin.add(r);
        bin.setPos(at.fileId(), at.line(), at.col());
        typeBinary(bin);
        return bin;
        }

    // A compound assignment whose target (not through an index operator)
    // belongs to a class that defines the compound operator or its plain one.
    bool opCompoundApplies(Node* n)
        {
        if (!_anyOps || n.op() == 0 || n.op().byteLength() < 2 || _isOp(n.op(), "=="))
            return false;
        Node* lhs = n.kid(0);
        if (indexOperatorClassOf(lhs) != 0)
            return false;
        String* propT = opPropertyType(lhs);
        Node* lc = opClassOf(propT != 0 ? propT : lhs.ty());
        if (lc == 0)
            return false;
        String* cShape = String.withCString("_");
        cShape.append(n.op());
        cShape.appendCString("_");
        String* pShape = String.withCString("_");
        pShape.append(n.op().substringBytes(0, n.op().byteLength() - 1));
        pShape.appendCString("_");
        return opClassDefines(lc, cShape) || opClassDefines(lc, pShape);
        }

    // Does a value of this type hold a pointer or reference, directly or in a
    // by-value member? A struct member counts as one.
    bool opTypeHoldsRef(String* t, u32 depth)
        {
        if (t == 0)
            return false;
        for (u32 i = 0; i < t.byteLength(); i++)
            {
            if (t.byteAt(i) == (u8)'*')
                return true;
            if (t.byteAt(i) == (u8)'[')
                return opTypeHoldsRef(t.substringBytes(0, i), depth);
            }
        if (_isOp(t, "string"))
            return true;
        if (_structs.get((Hashable*)t) != 0)
            return true;
        Node* c = (Node*)_classes.get((Hashable*)t);
        if (c == 0)
            return false;
        return depth > 8 || opClassHoldsRefs(c, depth + 1);
        }

    bool opClassHoldsRefs(Node* cls, u32 depth)
        {
        for (Node* c = cls; c != 0; c = parentOf(c))
            for (u32 i = 0; i < c.kidCount(); i++)
                {
                Node* iv = c.kid(i);
                if (iv.kind() == (u16)nkVariableDecl && opTypeHoldsRef(iv.op(), depth))
                    return true;
                }
        return false;
        }

    // `g[1][0] = 7` where g's `[]` returns a Row by value: the set would write
    // into a temporary copy and be lost. Reports it, and returns true, when
    // `recv` is a call's by-value class result and the class holds no pointer
    // or reference (one that does may be a view into its owner, and passes).
    // Mirrors the reference's refuseOperatorWrite:into:at:.
    bool refuseOpWrite(String* op, Node* recv, Node* at)
        {
        String* t = recv.ty();
        if (t == 0 || t.byteLength() == 0 || t.byteAt(t.byteLength() - 1) == (u8)'*')
            return false;
        Node* cls = (Node*)_classes.get((Hashable*)t);
        if (cls == 0)
            return false;
        String* src = (String*)0;
        String* owner = (String*)0;
        u16 k = recv.kind();
        Node* oc = Node.opCallOf(recv);
        if (oc != 0 && oc.kind() == (u16)nkMethodCall)
            {
            Node* oo = oc.kidCount() > 0 ? opClassOf(oc.kid(0).ty()) : (Node*)0;
            if (oo != 0)
                owner = oo.name();
            if (k == (u16)nkSubscript)
                src = String.withCString("[]");
            else if (k == (u16)nkSlice)
                src = String.withCString(recv.hasFlag((u32)NF_INCLUSIVE) ? "[...]" : "[..]");
            else
                src = recv.op();
            }
        else if (k == (u16)nkMethodCall)
            {
            Node* ro = recv.kidCount() > 0 ? opClassOf(recv.kid(0).ty()) : (Node*)0;
            if (ro != 0)
                owner = ro.name();
            src = recv.name();
            }
        else if (k == (u16)nkCall)
            src = recv.name();
        if (src == 0 || opClassHoldsRefs(cls, 0))
            return false;
        String* tn = cls.name();
        String* msg = (String*)0;
        if (owner != 0)
            msg = String.withFormat("'%s' writes into a temporary copy of %s (%s's '%s' returns %s by value), so the write is lost; store it in a variable first (%s t = ...;) and write through that, or have %s's '%s' return a %s* or a view that points into %s",
                                    op.cString(), tn.cString(), owner.cString(), src.cString(), tn.cString(), tn.cString(),
                                    owner.cString(), src.cString(), tn.cString(), owner.cString());
        else
            msg = String.withFormat("'%s' writes into a temporary copy of %s ('%s' returns %s by value), so the write is lost; store it in a variable first (%s t = ...;) and write through that, or have '%s' return a %s*",
                                    op.cString(), tn.cString(), src.cString(), tn.cString(), tn.cString(), src.cString(), tn.cString());
        _errorAt(msg, at);
        return true;
        }

    // An assignment through an operator: the index set (`m[i] = v`), get, op
    // and set for `m[i] += v`, the compound operator (`a += b`), or `a = a + b`
    // when the class defines `+` and no `+=` that matches. false when none
    // applies. Both sides are typed.
    bool resolveOpAssign(Node* n)
        {
        if (!_anyOps || n.kidCount() < 2)
            return false;
        Node* lhs = n.kid(0);
        String* aop = n.op();
        String* bop = (String*)0;
        if (aop != 0 && aop.byteLength() > 1)
            bop = aop.substringBytes(0, aop.byteLength() - 1);

        // Through an index operator: `m[i] = v`, or `m[i] op= v` as get, op, set.
        Node* icls = indexOperatorClassOf(lhs);
        if (icls != 0)
            {
            Node* base = lhs.kid(0);
            Array* idx = opIndexList(lhs);
            String* range = opIndexRange(lhs);
            n.setTy(String.withCString("void"));
            if (range != 0 && idx.count() != 2)
                {
                _errorAt(String.withFormat("a range index on '%s' needs both bounds", icls.name().cString()), lhs);
                return true;
                }
            String* setShape = Sema.indexShape(idx.count(), range, true);
            String* setOp = Sema.indexSpelling(range, true);
            Node* value = n.kid(1);
            Array* shared = new Array();
            if (bop != 0)
                {
                Node* get = indexGetCallOf(lhs, icls);
                if (get == 0)
                    return true;
                Node* bin = opBinary(bop, get, n.kid(1), n);
                // Built-in arithmetic is done at the element's type, as `x op= y` is.
                if (!bin.hasFlag((u32)NF_OPCALL) && get.ty() != 0)
                    bin.setTy(get.ty());
                value = bin;
                if (base.ty() != 0 && Types.isPointer(base.ty()))
                    Sema.opSharedRvalue(base, shared);
                else
                    Sema.opSharedLvalue(base, shared);
                for (u32 i = 0; i < idx.count(); i++)
                    Sema.opSharedRvalue((Node*)idx.get(i), shared);
                }
            if (!opClassDefines(icls, setShape) && opClassDefines(icls, Sema.indexShape(idx.count(), range, false)))
                {
                _errorAt(String.withFormat("'%s' has '%s' but no '%s' to assign an element with", icls.name().cString(),
                                           Sema.indexSpelling(range, false).cString(), setOp.cString()), lhs);
                return true;
                }
            Array* ops = new Array();
            ops.add((Object*)base);
            for (u32 i = 0; i < idx.count(); i++)
                ops.add(idx.get(i));
            ops.add((Object*)value);
            Node* set = opPick(setShape, setOp, ops, n, icls, (Node*)0);
            if (set == 0)
                {
                if (!_opAmbig)
                    {
                    idx.add((Object*)value);
                    _errorAt(String.withFormat("'%s' has no '%s' taking '%s'", icls.name().cString(), setOp.cString(),
                                               opTypes(idx, 0).cString()), n);
                    }
                return true;
                }
            n.add(set);
            n.addFlag((u32)NF_OPCALL);
            for (u32 i = 0; i < shared.count(); i++)
                n.add((Node*)shared.get(i));
            refuseOpWrite(bop != 0 ? aop : setOp, base, n);
            return true;
            }

        // A compound assignment on a class that defines the operator, in place
        // or in its plain form.
        if (bop == 0)
            return false;
        // A property's class is its setter's parameter's.
        String* propT = opPropertyType(lhs);
        Node* lc = opClassOf(propT != 0 ? propT : lhs.ty());
        if (lc == 0)
            return false;
        String* cShape = String.withCString("_");
        cShape.append(aop);
        cShape.appendCString("_");
        String* pShape = String.withCString("_");
        pShape.append(bop);
        pShape.appendCString("_");
        bool hasC = opClassDefines(lc, cShape);
        bool hasP = opClassDefines(lc, pShape);
        if (!hasC && !hasP)
            {
            // The built-in compound on a class pointer steps it by an integer.
            // A class that defines operators gets no silent `p += q` of two
            // pointers.
            if (opClassHasOperators(lc) && !Types.isInteger(n.kid(1).ty()) && propT == 0)
                {
                Array* rops = new Array();
                rops.add((Object*)n.kid(1));
                _errorAt(String.withFormat("'%s' has no '%s' or '%s' taking '%s'", lc.name().cString(), aop.cString(),
                                           bop.cString(), opTypes(rops, 0).cString()), n);
                n.setTy(String.withCString("void"));
                return true;
                }
            return false;
            }
        if (propT != 0)
            {
            _errorAt(String.withFormat("'%s' through an operator cannot assign to the property '%s'; write the assignment out",
                                       aop.cString(), lhs.name().cString()), n);
            n.setTy(String.withCString("void"));
            return true;
            }
        if (hasC)
            {
            Array* cops = new Array();
            cops.add((Object*)lhs);
            cops.add((Object*)n.kid(1));
            Node* call = opPick(cShape, aop, cops, n, lc, (Node*)0);
            if (call != 0 || _opAmbig || !hasP)
                {
                if (call == 0 && !_opAmbig)
                    _errorAt(String.withFormat("'%s' has no '%s' taking '%s'", lc.name().cString(), aop.cString(),
                                               opTypes(cops, 1).cString()), n);
                n.setTy(String.withCString("void"));
                if (call != 0)
                    {
                    n.add(call);
                    n.addFlag((u32)NF_OPCALL);
                    refuseOpWrite(aop, lhs, n);
                    }
                return true;
                }
            }
        // `a op= b` is `a = a op b`, with what the target's address is computed
        // from evaluated once.
        Node* bin = opBinary(bop, lhs, n.kid(1), n);
        Array* shared = new Array();
        Sema.opSharedLvalue(lhs, shared);
        n.setKid(1, bin);
        n.setOp(String.withCString("="));
        n.addFlag((u32)NF_OPFALLBACK);
        for (u32 i = 0; i < shared.count(); i++)
            n.add((Node*)shared.get(i));
        n.setTy(lhs.ty() != 0 ? lhs.ty() : String.withCString("u8"));
        checkClassPointerAssignAt(lhs.ty(), bin.ty(), bin, "assignment", n);
        return true;
        }

    void typeBinary(Node* n)
        {
        if (n.kidCount() < (u32)2)
            return;
        // `nil` is a pointer: it takes part in `==` and `!=` against a pointer
        // (or another nil), and in nothing else — `nil + 1`, `nil < p` and
        // `n == nil` with an integer `n` are refused. Before the constant fold
        // below, which would otherwise fold `nil + 1` to a number. The literal
        // is the 0 the lowering has always seen, so a comparison's IR is
        // unchanged. The messages are the reference's, word for word.
        bool leftNil = n.kid((u32)0).kind() == (u16)nkInt && n.kid((u32)0).nilLit();
        bool rightNil = n.kid((u32)1).kind() == (u16)nkInt && n.kid((u32)1).nilLit();
        if (leftNil || rightNil)
            {
            String* other = leftNil ? n.kid((u32)1).ty() : n.kid((u32)0).ty();
            if (!_isOp(n.op(), "==") && !_isOp(n.op(), "!="))
                _errorAt(String.withCString("nil is a pointer: it is only compared, with == or !="), n);
            else if (!(leftNil && rightNil) && other != 0 && !Types.isPointer(other))
                {
                String* m = String.withCString("nil is a pointer: it cannot be compared with a '");
                m.append(other);
                m.appendCString("'");
                _errorAt(m, n);
                }
            }
        // An operand that reads a primitive element out of a typed collection
        // is the BOX until it is unboxed, and this node types itself from its
        // operands — so it happens here, ahead of everything below.
        n.setKid((u32)0, unboxCollectionElement(n.kid((u32)0)));
        n.setKid((u32)1, unboxCollectionElement(n.kid((u32)1)));
        // An operand whose class defines this operator makes the operator a
        // call of the method (`:operator(self + o)`), and none of the built-in
        // typing below applies.
        if (resolveOperator(n))
            return;
        // TWO CONSTANTS fold, and the folded VALUE is what types the result:
        // `1000 & $FF` is 232, so it is a u8 — not the u16 the widening of its
        // operands would give. An operand may itself be a constant CHAIN
        // (`192 * 128`), evaluated whole in full precision, so the chain does not
        // truncate at each step (bug 198). A runtime operand (a variable) is not
        // constant and stops the fold, preserving §3.1 wrapping. The
        // short-circuit operators do not fold.
        i64 lcv = (i64)0;
        i64 rcv = (i64)0;
        if (constIntValue(n.kid((u32)0), &lcv) && constIntValue(n.kid((u32)1), &rcv))
            {
            String* ft = foldedLiteralType(n.op(), lcv, rcv);
            if (ft != 0)
                {
                // The folded node must be wide enough for the OPERANDS too, or
                // lowering truncates them (840/56 -> (840 & $FF)/56 = 1, bug 180).
                // Sizing from the operands alone breaks 15*56/56 (u8*u8 wraps),
                // so take the WIDER of the result type and the operand-widened
                // type.
                String* opw = Types.widen(n.kid((u32)0).ty(), n.kid((u32)1).ty());
                if (opw != 0 && Types.byteWidth(opw) > Types.byteWidth(ft))
                    ft = opw;
                n.setTy(ft);
                return;
                }
            }
        String* lt = n.kid((u32)0).ty();
        String* rt = n.kid((u32)1).ty();
        String* op = n.op();
        if (lt == 0 && rt == 0)
            return;
        // Two integer literals FOLD, and the folded value decides the type —
        // `(256 * 7)` is 1792, a u16, not the u32 the promotion rule would give
        // an unfolded multiply. The original folds in place for the same
        // reason: the constant is known, so nothing needs 32-bit width to hold
        // it.
        if (n.kid((u32)0).kind() == (u16)nkInt && n.kid((u32)1).kind() == (u16)nkInt && isArithmetic(op))
            {
            i64 a = n.kid((u32)0).num();
            i64 b = n.kid((u32)1).num();
            bool ok = true;
            i64 v = (i64)0;
            if (_isOp(op, "+"))
                v = a + b;
            else if (_isOp(op, "-"))
                v = a - b;
            else if (_isOp(op, "*"))
                v = a * b;
            else if (_isOp(op, "/"))
                {
                if (b == (i64)0)
                    ok = false;
                else
                    v = a / b;
                }
            else if (_isOp(op, "%"))
                {
                if (b == (i64)0)
                    ok = false;
                else
                    v = a % b;
                }
            if (ok)
                {
                // Same widen-to-operands guard as the block above (bug 180),
                // and the same capped ladder for the folded value.
                String* ft2 = Types.forFoldedValue(v); // folded: may be negative
                String* opw = Types.widen(n.kid((u32)0).ty(), n.kid((u32)1).ty());
                if (opw != 0 && Types.byteWidth(opw) > Types.byteWidth(ft2))
                    ft2 = opw;
                n.setTy(ft2);
                return;
                }
            }
        // `p - q` is a pointer DIFFERENCE, and a difference is not a pointer:
        // it asks how far apart two addresses are, and the answer is a COUNT,
        // in ELEMENTS as C has it. Without this it fell into Types.widen, which
        // sees two equal-width unsigned operands and hands back the POINTER
        // type — so `q - p` typed as `double*`, and lowering then emitted a raw
        // BYTE subtraction while the reference refused it outright (bug 206).
        //
        // The type is C's ptrdiff_t: a signed integer spanning the TARGET's
        // address space — i64 for 8-byte pointers, i32 for 4-byte, i16 for the
        // banked 6502's 3-byte pointer (a 16-bit address plus a bank byte, and
        // one allocation cannot span banks).
        //
        // This was briefly a fixed i32, justified by this sema having no
        // pointer width to consult. Wrong twice: a 32-bit difference across a
        // 64-bit address space is the wrong type, and byte-identity with the
        // reference needs the two to make the SAME choice, not a FIXED one —
        // both asking the target's width agree. The width now arrives the same
        // way lowering's already did, from pointerWidthOf() in the front end.
        //
        // n.op() rather than the `op` local: that one is declared inside the
        // constant-fold block above and is out of scope here.
        //
        // An array operand of `+` or `-` decays first (#516), so `b + 1` is a
        // pointer and `b - p` a pointer difference.
        if (_isOp(n.op(), "+") || _isOp(n.op(), "-"))
            {
            String* lt0 = lt;
            lt = Types.arithmeticDecay(lt, rt);
            rt = Types.arithmeticDecay(rt, lt0);
            }
        String* r = Types.widen(lt, rt);
        if (_isOp(n.op(), "-") && Types.isPointer(lt) && Types.isPointer(rt))
            r = _ptrW >= (u32)8   ? String.withCString("i64")
                : _ptrW >= (u32)4 ? String.withCString("i32")
                                  : String.withCString("i16");
        // A `^` on EITHER side widens to the PAIR, not to whatever the integer
        // table makes of a type it has never heard of — `h == 0` is a pair
        // comparison against the null pair, not a byte comparison. The node
        // type is what lowering reads to decide that, so getting it wrong here
        // is not cosmetic: the comparison came out as a byte compare.
        if (isBoundSignature(lt) || isBoundSignature(rt))
            r = isBoundSignature(lt) ? lt : rt;
        // No C-style promotion: the operator's type is the widening of its
        // operands, so `u8 + u8` is a u8 and wraps. Widening is the
        // ASSIGNMENT's job. Mirrors the reference; see private:docs/bugs/041.
        // `X << C` where C is a constant at least as wide as X: every bit of X
        // would be shifted out at X's width, so the operand must have been
        // meant to widen first. `hi << 8` on a u8 is a u16. A shift that keeps
        // bits (u16 << 8, u8 << 4) is left alone — top-bit loss there is
        // ordinary C, and `(v << 8) | lo` idioms depend on it.
        if (_isOp(op, "<<") && n.kid((u32)1).kind() == (u16)nkInt && lt != 0 && Types.isInteger(lt))
            {
            i64 cnt = n.kid((u32)1).num();
            u32 lhsBits = Types.byteWidth(lt) * (u32)8;
            if (cnt > (i64)0 && (u32)cnt >= lhsBits)
                {
                u32 needed = lhsBits + (u32)cnt;
                u32 bytes = (needed <= (u32)16) ? (u32)2 : (u32)4;
                if (bytes > Types.byteWidth(r))
                    {
                    bool sg = Types.isSigned(r);
                    if (bytes == (u32)2)
                        r = sg ? String.withCString("i16")
                               : String.withCString("u16");
                    else
                        r = sg ? String.withCString("i32")
                               : String.withCString("u32");
                    }
                }
            }
        // A COMPARISON yields bool, whatever it compared. This used to keep the
        // widening of its operands — `a < b` on two i64s was an i64 node — and
        // the wrong type stayed invisible until something CONSUMED it: a
        // ternary widens its arms to the union of their types, so
        //
        //     bool up = k != 0 ? viaCall(k) : ((hi - 4) < (4 - lo));
        //
        // took union(bool, i64) = i64, widened the CALL arm with a ZExt, and
        // left the comparison arm alone because it already believed it was
        // i64 — a phi with an i64 result and a Bool incoming. Only wasm
        // validates types, so only wasm rejected it; native builds ran.
        // Lowering reads the OPERAND types for the compare width, so this
        // changes the node's type only. (Reported from blewit's spike.)
        if (isComparison(op) || _isOp(op, "&&") || _isOp(op, "||"))
            r = String.withCString("bool");
        n.setTy(r);
        }

    // The six relational/equality operators, whose RESULT is bool however wide
    // the things they compared were.
    bool isComparison(String* op)
        {
        return _isOp(op, "==") || _isOp(op, "!=") || _isOp(op, "<") || _isOp(op, ">") || _isOp(op, "<=") || _isOp(op, ">=");
        }

    // `-x` on an unsigned integer yields the SIGNED type of the same width —
    // the value can now be negative and the type has to be able to say so.
    // `!x` is bool, `&x` adds a pointer level, `@p` removes one.
    void typeUnary(Node* n)
        {
        if (n.kidCount() == (u32)0)
            return;
        String* op = n.op();
        if (resolveOperator(n))
            return;
        // An element an index operator reads is a call's result: no address,
        // no slot to step.
        if (Sema.isOpIndex(n.kid(0)))
            {
            if (_isOp(op, "&"))
                _errorAt(String.withCString("'&' cannot take the address of an element read through an index operator"), n);
            else if (_isOp(op, "++") || _isOp(op, "--"))
                _errorAt(String.withCString("'++' and '--' cannot step an element read through an index operator; use '+= 1' or '-= 1'"), n);
            }
        // Prefix `+` has no built-in meaning.
        if (_isOp(op, "+"))
            {
            String* ot = n.kid((u32)0).ty();
            String* pm = String.withCString("prefix '+' is defined only by a class operator, not for '");
            pm.append(ot != 0 ? Node.stripElem(ot) : String.withCString("?"));
            pm.appendCString("'");
            _errorAt(pm, n);
            n.setTy(ot != 0 ? ot : String.withCString("u8"));
            return;
            }
        // `&obj.method` is a BOUND METHOD — the {receiver, code} pair — not the
        // address of a field. Only under `&` does a member access mean this,
        // which is why it is decided here rather than in typeMember.
        if (_isOp(op, "&") && n.kid((u32)0).kind() == (u16)nkMember)
            {
            Node* mem = n.kid((u32)0);
            if (mem.kidCount() > (u32)0)
                {
                String* recv = mem.kid((u32)0).ty();
                if (recv != 0)
                    {
                    // Through a PROTOCOL: the pair carries the protocol-relative
                    // identity as well as the slot, since the concrete class is
                    // not known until runtime.
                    String* pn = classNameOf(recv);
                    Node* pr = (Node*)_protocols.get((Hashable*)pn);
                    if (pr != 0)
                        {
                        u32 pidx = (u32)0;
                        for (u32 i = (u32)0; i < pr.kidCount(); i = i + (u32)1)
                            {
                            Node* pm = pr.kid(i);
                            if (pm.kind() != (u16)nkMethodDecl)
                                continue;
                            if (pm.name() != 0 && pm.name().equals(mem.name()))
                                {
                                String* sig = signatureOf(pm, true);
                                mem.setTy(sig);
                                mem.setGetter((String*)0, (String*)0);
                                mem.setBound(pm.name(), (String*)0);
                                i32 slot = (i32)-1;
                                Map* ps = _vt.protoSlotsFor(pn);
                                if (ps != 0)
                                    {
                                    Object* sl = ps.get((Hashable*)mem.name());
                                    if (sl != 0)
                                        slot = (i32)((Number*)sl).asU32();
                                    }
                                mem.setBoundProto(slot, pn, (i32)pidx);
                                n.setTy(sig);
                                return;
                                }
                            pidx = pidx + (u32)1;
                            }
                        }
                    Node* cls = (Node*)_classes.get((Hashable*)pn);
                    if (cls != 0)
                        {
                        Node* m = findMethodUpChain(cls, mem.name());
                        if (m != 0)
                            {
                            // The symbol belongs to whoever DECLARED it.
                            Node* ownerCls = classDeclaringMethod(cls, mem.name());
                            if (ownerCls == 0)
                                ownerCls = cls;
                            // A STATIC method has no receiver, so `&C.m` is not
                            // a pair at all — it is a plain function pointer,
                            // and it widens into a `^` like a free function
                            // does. The class name in front of it names no
                            // value either, so it is left untyped.
                            if (m.hasFlag((u32)NF_STATIC))
                                {
                                String* fp = signatureOf(m, false);
                                fp.appendByte((u8)'*');
                                mem.setTy(fp);
                                mem.setGetter((String*)0, (String*)0);
                                mem.setBound(m.sym(), ownerCls.name());
                                mem.kid((u32)0).setTy((String*)0);
                                n.setTy(fp);
                                return;
                                }
                            String* sig = signatureOf(m, true);
                            mem.setTy(sig);
                            // A member under `&` is a BOUND METHOD, not a
                            // property read: the children were typed first, so
                            // any getter stamped there has to come back off.
                            mem.setGetter((String*)0, (String*)0);
                            mem.setBound(m.sym(), ownerCls.name());
                            // A virtual method's `^` records the slot it
                            // dispatches through, exactly as a call does.
                            if (cls.slots() != 0)
                                {
                                Object* sl = cls.slots().get((Hashable*)mem.name());
                                if (sl != 0)
                                    mem.setBoundProto((i32)((Number*)sl).asU32(),
                                                      (String*)0, (i32)-1);
                                }
                            n.setTy(sig); // `&` of a `^` is still the `^`
                            return;
                            }
                        }
                    }
                }
            }
        String* t = n.kid((u32)0).ty();
        if (_isOp(op, "!"))
            {
            n.setTy(String.withCString("bool"));
            return;
            }
        if (t == 0)
            return;
        if (_isOp(op, "&"))
            {
            String* p = String.withString(t);
            p.appendByte((u8)'*');
            n.setTy(p);
            return;
            }
        if (_isOp(op, "*"))
            {
            // Dereferencing something that is NOT a pointer is an error, and
            // like every other error it leaves u8 rather than the operand's own
            // type: `@screenPtr`, where screenPtr is a u16, is a u8. The test
            // belongs HERE and not in pointeeOf — classNameOf uses that too,
            // and a class VALUE receiver is not a pointer, so folding the rule
            // in there broke every stack-receiver call in the corpus.
            if (!Types.isPointer(t))
                {
                // …and now it SAYS so. It resolved silently to u8, so the
                // program compiled, read whatever address the value happened
                // to hold, and died. `*p.Real` — C's `(*p).Real` with the
                // parentheses lost — is the shape that found it; `.`
                // auto-dereferences a pointer here, so `p.Real` and
                // `(*p).Real` are both correct and `*p.Real` is neither
                // (bug 214).
                //
                // Scoped to the spellings that can NEVER be dereferenced, so
                // the opaque `pointer` type, arrays, structs, classes,
                // enums and an unresolved `auto` are left exactly as they
                // were.
                // Integers included. Dereferencing one is the 6502
                // absolute-address idiom, but it is a 6502-only idiom: the
                // only sites in the tree were two lines in the near-duplicate
                // 6502 Stdio.xc files, and weakening the rule on all eight
                // targets to carry them was the wrong trade. Those two now
                // spell it `*(main:u8*)screenPtr`, which is already the house
                // style in the same file. An address in an integer is still
                // writable; it just has to be named as a pointer where it is
                // used.
                bool scalar = Types.isInteger(t) || _isOp(t, "bool") || _isOp(t, "float") || _isOp(t, "double");
                if (scalar)
                    {
                    String* w = String.withCString("cannot dereference '");
                    w.append(t);
                    w.appendCString("' — it is not a pointer");
                    _errorAt(w, n);
                    }
                n.setTy(String.withCString("u8"));
                return;
                }
            n.setTy(pointeeOf(t));
            return;
            }
        if (_isOp(op, "-") && Types.isInteger(t) && !Types.isSigned(t))
            {
            // Negating a LITERAL: the narrowest signed type that fits the
            // NEGATED value, not the operand's own width. `-181` types its
            // operand `u8`, and same-width signed is `i8`, where -181 does not
            // fit — the Neg wrapped to 75 and the SExt faithfully preserved
            // the wrong number. UXKit's arc tables are written that way
            // (`-181`, `-237`), so every round cap came out off its circle
            // (uxkit bug 034-C).
            //
            // `Types.forValue` is the same ladder the reference walks, and it
            // has been sitting here unused by this path all along.
            if (n.kid((u32)0).kind() == (u16)nkInt)
                {
                n.setTy(Types.forValue(-(n.kid((u32)0).num())));
                return;
                }
            // Non-literal: same width, signed. An unsigned result would
            // ZExt-widen at the store and drop the sign bit.
            n.setTy(Types.signedOfWidth(Types.byteWidth(t)));
            return;
            }
        n.setTy(t);
        }

    // A struct field, a class ivar, or nothing yet.
    void typeMember(Node* n)
        {
        if (n.kidCount() == (u32)0)
            return;
        String* recv = n.kid((u32)0).ty();
        if (recv == 0)
            return;
        // `arr.length` is a built-in on an array or a slice, not a field of
        // anything — a u16 count.
        // `.length` is a built-in on an ARRAY. On a pointer it is one too —
        // it reads the allocation header — but only where the pointee is not a
        // class, because there `.length` is an ordinary member and the class
        // has to be asked first (that reading cost 97 files).
        if (_isOp(n.name(), "length") && (isArrayLike(recv) || (Types.isPointer(recv) && _classes.get((Hashable*)classNameOf(recv)) == 0 && _protocols.get((Hashable*)classNameOf(recv)) == 0)))
            {
            // The AST width must equal the IR width Lower gives `.length`, or
            // `buf[buf.length - (u16)1]` builds a Sub with mismatched operand
            // types. The type-width invariant, on a count rather than a
            // pointer. Bug 234.
            n.setTy(_cntW >= (u32)8   ? String.withCString("u64")
                    : (_cntW >= (u32)4 ? String.withCString("u32")
                                       : String.withCString("u16")));
            return;
            }
        // A `^` is a PAIR, and its two halves are readable: `.code` is the
        // function pointer and `.recv` the receiver it was taken from. That is
        // how two `^` values are compared for identity.
        if (isBoundSignature(recv))
            {
            if (_isOp(n.name(), "code"))
                {
                String* fp = String.withString(recv);
                if (fp.hasPrefix(String.withCString("$wbound_")))
                    fp = fp.substringFromByte((u32)8);
                else if (fp.hasPrefix(String.withCString("$bound_")))
                    fp = fp.substringFromByte((u32)7);
                fp.appendByte((u8)'*');
                n.setTy(fp);
                return;
                }
            if (_isOp(n.name(), "recv"))
                {
                n.setTy(String.withCString("u8*"));
                return;
                }
            }
        String* owner = classNameOf(recv);
        Node* st = (Node*)_structs.get((Hashable*)owner);
        if (st != 0)
            {
            n.setTy(fieldOrU8At(st, n.name(), n, false));
            return;
            }
        Node* cls = (Node*)_classes.get((Hashable*)owner);
        if (cls != 0)
            {
            // A zero-argument METHOD of the member's name wins over an ivar of
            // that name: `GetOnly` declares both `u8 n` and `u8 n()`, and
            // reading `g.n` calls the getter. The ivar is what the getter
            // reads, not what the reader sees.
            for (Node* c2 = cls; c2 != 0; c2 = parentOf(c2))
                {
                Node* getter = zeroArgMethodNamed(c2, n.name());
                if (getter != 0)
                    {
                    n.setTy(firstReturn(getter.op()));
                    n.setGetter(getter.sym(), c2.name());
                    return;
                    }
                }
            // Otherwise an ivar, inherited ones included.
            for (Node* c = cls; c != 0; c = parentOf(c))
                {
                String* ft = fieldType(c, n.name());
                if (ft != 0)
                    {
                    n.setTy(ft);
                    return;
                    }
                }
            // A member naming a METHOD is not a missing member. `&c.tap` is a
            // bound method, and the kids are typed before the `&` handler
            // rewrites them, so reporting here fired on every `&obj.method` in
            // valid code. Quietly typed; the `&` path re-types it properly.
            // (The original intercepts `&` before the operand is analysed and
            // so never reaches this at all.)
            for (Node* c = cls; c != 0; c = parentOf(c))
                if (findMethodUpChain(c, n.name()) != 0)
                    {
                    n.setTy(String.withCString("u8"));
                    return;
                    }
            n.setTy(fieldOrU8At(cls, n.name(), n, true));
            return;
            }
        // Neither a struct nor a class: the receiver did not resolve, so the
        // member cannot either. The original stamps its unknown type rather
        // than leaving the node bare, and the difference is visible.
        n.setTy(String.withCString("u8"));
        }

    // A free call resolves against the function groups collected in pass 1.
    // A single candidate needs no argument matching; an overloaded name is
    // left for the dispatch pass rather than guessed at.
    void typeCall(Node* n)
        {
        if (typeIntrinsic(n))
            return;
        // A bare call inside a class body reaches that class's own methods
        // first — the implicit-self call. `print(x)` inside Stdio means
        // `Stdio.print(x)`, and the method it lands on learns it was reached
        // through the class's static storage.
        if (_curClass != 0)
            {
            Node* m = (Node*)0;
            Node* mOwner = (Node*)0;
            for (Node* c = _curClass; c != 0 && m == 0; c = parentOf(c))
                {
                m = methodOverload(c, n, (u32)0);
                mOwner = c;
                }
            // A call that would resolve to the very method being compiled means
            // the FREE function of that name, if there is one: `Math.sqrt`
            // calls the extern `sqrt`, it does not recurse into itself. Only
            // that one case defers.
            //
            // The test is the NAME of the method being walked, not "is there a
            // matching overload on the current class". The looser test let a
            // GLOBAL capture an ordinary sibling call — `Bag.twice` calling
            // `add` where the program also declares a free `add` — which is
            // bug 040 in the reference compiler, silent when the global's
            // signature happened to fit. It is also not enough to compare
            // method IDENTITY: a wrapper with sibling overloads (`sqrt(float)`
            // beside `sqrt(double)`) still finds a candidate that is not
            // itself, and captures the call straight back into the class.
            if (m != 0 && wrapsFree(n.name()))
                m = (Node*)0;
            if (m != 0)
                {
                // A single candidate is taken without scoring, so its count
                // is checked here (bug 271).
                if (!checkArity(m, n, (u32)0, n.name()))
                    return;
                checkMisfitArgs(m, n, (u32)0, n.name());
                // A call yields its FIRST value, as an explicit receiver's
                // does (below) and as the reference types it.
                n.setTy(firstReturn(m.op()));
                narrowLengthArgs(m, n, (u32)0);
                n.setSym(m.sym());
                noteCallEdge(clsLabel(mOwner.name(), m.sym() != 0 ? m.sym() : m.name()));
                noteClassNameUse(mOwner.name(), m);
                // An implicit-self call DOES reach the method through the
                // class's own storage, so it counts as a stack receiver. A
                // `use`-promoted bare call (below) does not — measured, not
                // assumed: marking both cost 81 files.
                m.setStackRecv();
                checkStackStrongArgs(n, m, (u32)0, quotedName(mOwner.name(), m.name(), ""));
                checkThrowsCall(m, n, m.name());
                applyBoxing(n, m, (u32)0);
                return;
                }
            }
        // A callee written as an EXPRESSION rather than a name — `tbl[0](5)`,
        // `mk()(6)`. The parser leaves it as one extra kid after the
        // arguments; the KIND of call comes from its type, exactly as it comes
        // from the variable's type just below. private:docs/bugs/074.
        if (n.kidCount() > (u32)n.num())
            {
            Node* ck = n.kid((u32)n.num());
            String* ct = ck.ty();
            if (ct != 0 && isSignature(ct))
                {
                // No candidate to choose, but the signature fixes the count
                // (bug 271). A field callback is named by its field.
                String* lbl = (ck.kind() == (u16)nkMember && ck.name() != 0)
                                  ? ck.name()
                                  : String.withCString(isBoundSignature(ct) ? "<bound method>" : "<function pointer>");
                if (!checkSignatureArity(ct, n, lbl))
                    return;
                n.setTy(returnOfSignature(ct));
                n.setIndirect(isBoundSignature(ct));
                n.setCalleeTy(ct);
                return;
                }
            // A BLOCK is a pointer to its `Blk$…` impl class, and a block call
            // is `.invoke` dispatch — the rewrite the parser performs for a
            // block LOCAL, which a callee EXPRESSION never reached. The
            // rewritten call rides as one more kid, past the callee.
            String* cn = ct != 0 ? classNameOf(ct) : (String*)0;
            if (cn != 0 && cn.hasPrefix(String.withCString("Blk$")))
                {
                Node* inv = Node.withName((u16)nkMethodCall, String.withCString("invoke"));
                inv.add(ck);
                for (u32 i = (u32)0; i < (u32)n.num(); i = i + (u32)1)
                    inv.add(n.kid(i));
                inv.setNum(n.num());
                typeExpr(inv);
                n.setTy(inv.ty());
                n.addFlag((u32)NF_FIELDCALL);
                n.add(inv);
                return;
                }
            String* w = String.withCString("this expression is not callable");
            if (ct != 0)
                {
                w.appendCString(" (it is `");
                w.append(ct);
                w.appendCString("`)");
                }
            _error(w);
            return;
            }
        // A call through a VARIABLE — a function pointer or a bound method —
        // is indirect: there is no symbol, and the type comes from the
        // variable's own signature.
        String* vt = lookup(n.name());
        if (vt != 0 && isSignature(vt))
            {
            if (!checkSignatureArity(vt, n, n.name()))
                return;
            n.setTy(returnOfSignature(vt));
            n.setIndirect(isBoundSignature(vt));
            n.setCalleeTy(vt);
            return;
            }
        Array* group = (Array*)_functions.get((Hashable*)n.name());
        bool demotedC = false;
        if (group != 0)
            {
            _tieToFloat = true;
            Node* fn = pickOverload(group, n, (u32)0);
            _tieToFloat = false;
            // With a SINGLE candidate the call resolves even when the argument
            // does not convert — the original resolves it and diagnoses the
            // argument separately, which is how `render(v)` still names
            // `render` while reporting that Vehicle does not conform to
            // Drawable. A `new`, by contrast, stays strict.
            // libc and free functions are the LOWEST-precedence layer for a
            // bare call: the single-candidate rule must not let the imported
            // `rand(void)` claim `rand(100)` when `use Math;` promotes a
            // `Math.rand(u8)` that genuinely matches.
            bool single = false;
            if (fn == 0 && group.count() == (u32)1 && !usePromotedMatch(n))
                {
                fn = (Node*)group.get((u32)0);
                single = true;
                }
            // That single candidate is taken UNSCORED, so the count and the
            // class-pointer arguments are checked here instead (bug 271).
            if (single)
                {
                if (!checkArity(fn, n, (u32)0, n.name()))
                    return;
                checkMisfitArgs(fn, n, (u32)0, n.name());
                }
            // …and that holds when the libc proto MATCHES too: libc's
            // variadic `printf` fits any argument list, so on arm9 (libc
            // auto-imported) `#use Stdio` + bare `printf` called libc where
            // the reference calls Stdio.printf. An auto-imported C proto
            // defers to a matching `use`-promoted static, as there.
            if (fn != 0 && fn.hasFlag((u32)NF_CABI)
                && (fn.sym() == 0 || fn.sym().equals(n.name())) && usePromotedMatch(n))
                {
                fn = (Node*)0;
                demotedC = true;
                }
            if (fn != 0)
                {
                n.setTy(firstReturn(fn.op()));
                narrowLengthArgs(fn, n, (u32)0);
                n.setSym(fn.sym());
                noteCallEdge(fnLabel(fn.sym() != 0 ? fn.sym() : n.name()));
                checkStackStrongArgs(n, fn, (u32)0, quotedName((String*)0, n.name(), ""));
                checkThrowsCall(fn, n, n.name());
                applyBoxing(n, fn, (u32)0);
                if (fn.hasFlag((u32)NF_VARARGS))
                    {
                    u32 wk = fmtWrapperFor(n.name());
                    if (wk != (u32)0)
                        formatCallAt(n, wk - (u32)1, n.name());
                    }
                return;
                }
            }
        // `use Stdio;` promotes a class's static methods into the bare-call
        // space for the rest of the file, which is how `printf(…)` resolves.
        for (u32 i = (u32)0; i < _used.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)_classes.get((Hashable*)(String*)_used.get(i));
            if (cls == 0)
                continue;
            Node* m = methodOverload(cls, n, (u32)0);
            if (m == 0)
                continue;
            // A promoted static must FIT: the single-candidate courtesy is
            // for a name the call spells in full, not for one it reaches
            // through `use`, where the reference scores every candidate and
            // a misfit is no candidate at all (bug 271).
            if (!arityFits(m, callArgc(n, (u32)0)) || scoreCandidate(m, n, (u32)0) == Overload.noMatch())
                continue;
            n.setTy(firstReturn(m.op()));
            narrowLengthArgs(m, n, (u32)0);
            n.setSym(m.sym());
            noteCallEdge(clsLabel(cls.name(), m.sym() != 0 ? m.sym() : m.name()));
            noteClassNameUse(cls.name(), m);
            // The static and the demoted C proto can share a symbol name
            // (`printf`), so the lowering is told which class answered.
            if (demotedC)
                n.setCls(cls.name());
            checkStackStrongArgs(n, m, (u32)0, quotedName(cls.name(), m.name(), " (via use)"));
            checkThrowsCall(m, n, m.name());
            applyBoxing(n, m, (u32)0);
            // The bare spelling gets the SAME format treatment as the explicit
            // one (finding #8) — no receiver kid, so the format sits one
            // position earlier.
            if (_isOp(cls.name(), "Stdio"))
                {
                if (_isOp(n.name(), "printf"))
                    {
                    rewriteFormatAt(n, (u32)0);
                    checkFormatAt(n, (u32)0, useFormatCallName(n.name(), "printf"));
                    promoteFormatAt(n, (u32)0);
                    }
                else if (_isOp(n.name(), "printfAt"))
                    {
                    rewriteFormatAt(n, (u32)2);
                    checkFormatAt(n, (u32)2, useFormatCallName(n.name(), "printfAt"));
                    promoteFormatAt(n, (u32)2);
                    }
                }
            // Log's format methods the same (#336): bare `error("%d", v)`
            // under `use Log` printed an i64's low 32 bits and was not
            // checked, where Log.error fitted the format to it.
            else if (_isOp(cls.name(), "Log")
                     && (_isOp(n.name(), "error") || _isOp(n.name(), "warning") || _isOp(n.name(), "info")))
                {
                rewriteFormatAt(n, (u32)0);
                checkFormatAt(n, (u32)0, useFormatCallNameIn(n.name(), "Log", n.name()));
                promoteFormatAt(n, (u32)0);
                }
            return;
            }
        // Nothing matched. An unresolved call is an ERROR, and an error still
        // leaves a type behind — u8, the original's fallback — with no symbol.
        // The diagnostic is what stops the compile.
        //
        // NAME the callee and give it a position. This said a bare
        // "unresolved call" — no symbol, no file, no line — while the
        // reference had always printed `file:line:col: error: Call to
        // undeclared function 'f'`. A framework build lost a diagnosis to
        // it: a link failure whose real cause was a missing -L read, from a
        // message with nothing in it, as a bad include path. The wording here
        // is the REFERENCE's, exactly, because byte-identical diagnostics are
        // the invariant (bug 209).
        //
        // A name that IS declared, as overloads none of which fits, says so
        // instead: "undeclared" sent the reader looking for a missing import.
        if (group != 0 && !demotedC && group.count() > (u32)1)
            {
            u32 argc = callArgc(n, (u32)0);
            u32 fitting = (u32)0;
            for (u32 i = (u32)0; i < group.count(); i = i + (u32)1)
                {
                Node* d = (Node*)group.get(i);
                if (arityFits(d, argc) && scoreCandidate(d, n, (u32)0) != Overload.noMatch())
                    fitting = fitting + (u32)1;
                }
            String* e = String.withCString("");
            if (fitting > (u32)1)
                {
                e.appendCString("Call to '");
                e.append(n.name());
                e.appendByte((u8)'(');
                e.append(describeArgTypes(n, (u32)0));
                e.appendCString(")' is ambiguous among ");
                e.append(String.withU32(group.count()));
                e.appendCString(" overloads");
                }
            else
                {
                e.appendCString("No overload of '");
                e.append(n.name());
                e.appendCString("' matches argument types (");
                e.append(describeArgTypes(n, (u32)0));
                e.appendByte((u8)')');
                }
            _errorAt(e, n);
            n.setTy(String.withCString("u8"));
            return;
            }
        _errorAt(String.withFormat("Call to undeclared function '%s'",
                                   n.name().cString()),
                 n);
        n.setTy(String.withCString("u8"));
        }

    // `u8(u8,u16)` / `$bound_u16()` — a signature spelling rather than a type
    // name. Its return is everything before the first `(`, minus the prefix.
    bool isSignature(String* t)
        {
        if (t == 0)
            return false;
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            if (t.byteAt(i) == (u8)'(')
                return true;
        return false;
        }

    // `$bound_` and `$wbound_` are the same thing to a CALL — one is the weak
    // form of the slot, which changes its lifetime, not its signature.
    bool isBoundSignature(String* t)
        {
        if (t == 0)
            return false;
        return t.hasPrefix(String.withCString("$bound_")) || t.hasPrefix(String.withCString("$wbound_"));
        }

    String* returnOfSignature(String* t)
        {
        String* s2 = t;
        if (s2.hasPrefix(String.withCString("$wbound_")))
            s2 = s2.substringFromByte((u32)8);
        else if (s2.hasPrefix(String.withCString("$bound_")))
            s2 = s2.substringFromByte((u32)7);
        for (u32 i = (u32)0; i < s2.byteLength(); i = i + (u32)1)
            if (s2.byteAt(i) == (u8)'(')
                return s2.substringBytes((u32)0, i);
        return s2;
        }

    // The varargs and ARC builtins. They are not declared anywhere — sema
    // recognises the NAME — and they resolve to `__intrinsic_<name>` so the
    // lowering can tell them from a call to a function someone happened to name
    // `va_end`. `va_arg_<suffix>` is typed by its suffix, which is the whole
    // point of having nine of them rather than one `va_arg`.
    bool typeIntrinsic(Node* n)
        {
        String* nm = n.name();
        if (nm == 0)
            return false;
        String* ty = (String*)0;
        if (_isOp(nm, "va_start") || _isOp(nm, "va_end"))
            {
            ty = String.withCString("void");
            // A variadic that runs va_start CONSUMES its arguments, so it is
            // one the non-reentrance check has to look at.
            if (_isOp(nm, "va_start") && _curLabel != 0 && _curMethod != 0 && _curMethod.hasFlag((u32)NF_VARARGS))
                _usesVaList.set((Hashable*)_curLabel, (Object*)Number.with((u32)1));
            }
        else if (_isOp(nm, "va_arg_u8"))
            ty = String.withCString("u8");
        else if (_isOp(nm, "va_arg_i8"))
            ty = String.withCString("i8");
        else if (_isOp(nm, "va_arg_u16"))
            ty = String.withCString("u16");
        else if (_isOp(nm, "va_arg_i16"))
            ty = String.withCString("i16");
        else if (_isOp(nm, "va_arg_u32"))
            ty = String.withCString("u32");
        else if (_isOp(nm, "va_arg_i32"))
            ty = String.withCString("i32");
        // The 64-bit widths; `va_arg_double` already proves the 8-byte slot.
        else if (_isOp(nm, "va_arg_u64"))
            ty = String.withCString("u64");
        else if (_isOp(nm, "va_arg_i64"))
            ty = String.withCString("i64");
        else if (_isOp(nm, "va_arg_float"))
            ty = String.withCString("float");
        else if (_isOp(nm, "va_arg_double"))
            ty = String.withCString("double");
        else if (_isOp(nm, "va_arg_string"))
            ty = String.withCString("u8*");
        else if (_isOp(nm, "va_arg_ptr"))
            {
            // A CLASS pointee keeps the type the user asked for —
            // `va_arg(ap, Object*)` is an Object reference, not bytes. The
            // reference stamps the pointee on the call node for exactly this;
            // here the parser kept the whole spelling in `extra`. Anything
            // else (u8*, string, an unknown name) stays the bare pointer.
            ty = String.withCString("u8*");
            if (n.extra() != 0 && n.extra().byteLength() > (u32)1 && n.extra().byteAt(n.extra().byteLength() - (u32)1) == (u8)'*')
                {
                String* pe = n.extra().substringBytes((u32)0, n.extra().byteLength() - (u32)1);
                if (_classes.get((Hashable*)pe) != 0)
                    ty = n.extra();
                }
            }
        // `va_arg_struct_ptr(ap)` yields a pointer to the STRUCT the parser
        // stamped on the call — the whole reason it is a separate intrinsic.
        else if (_isOp(nm, "va_arg_struct_ptr"))
            {
            // The parser kept the spelling the user wrote — already a pointer.
            ty = (n.extra() != 0) ? n.extra() : String.withCString("u8*");
            }
        // The ARC primitives the libraries call by hand — see
        // support/*/lib: `self` plus __arc_retain / __arc_release is how a
        // container takes ownership without inline asm.
        else if (_isOp(nm, "__arc_retain") || _isOp(nm, "__arc_release"))
            ty = String.withCString("void");
        // `bank(n, addr)` yields a RAW pointer — the bank byte is part of it,
        // so it is not an ordinary `u8@`.
        else if (_isOp(nm, "bank"))
            ty = String.withCString("raw:u8*");
        else
            return false;
        n.setTy(ty);
        String* sym = String.withCString("__intrinsic_");
        sym.append(nm);
        n.setSym(sym);
        return true;
        }

    // Choose among same-named declarations. `argBase` is the index of the first
    // ARGUMENT among the call's children — a method call's first child is its
    // receiver.
    //
    // The original scores candidates (XTSemanticAnalyzer+Overload); this takes
    // the two rungs that decide almost every real call — arity, then an exact
    // match on the argument type spellings — and declines to guess when they
    // leave more than one standing. Declining shows up as a missing annotation
    // in the harness, which is the honest failure.
    // #643: the call goes to today's choice; where today's rule leaves a tie
    // it cannot break (an ambiguous call), the candidate that converts each
    // argument no worse than every other tied candidate, and one argument
    // better (the smaller widening: `(u32, u32)` over `(u64, u64)` for a
    // `(u32, u16)` call), wins. So no call that resolves today changes; only
    // calls that were ambiguous resolve.
    Node* pickOverload(Array* group, Node* call, u32 argBase)
        {
        Node* today = pickOverloadToday(group, call, argBase);
        if (today != (Node*)0)
            return today;
        return dominator(bestTied(group, call, argBase), call, argBase);
        }

    // The candidates of the right arity whose every argument converts.
    Array* viable(Array* group, Node* call, u32 argBase)
        {
        u32 argc = (call.kidCount() > argBase) ? call.kidCount() - argBase : (u32)0;
        Array* out = new Array();
        for (u32 i = (u32)0; i < group.count(); i = i + (u32)1)
            {
            Node* d = (Node*)group.get(i);
            u32 pc = paramCount(d);
            if (!(d.hasFlag((u32)NF_VARARGS) ? (argc >= pc) : (argc == pc)))
                continue;
            if (scoreCandidate(d, call, argBase) != Overload.noMatch())
                out.add((Object*)d);
            }
        return out;
        }

    // Of those, the ones at the best (lowest) score: today's tie.
    Array* bestTied(Array* group, Node* call, u32 argBase)
        {
        Array* v = viable(group, call, argBase);
        u32 best = Overload.noMatch();
        for (u32 i = (u32)0; i < v.count(); i = i + (u32)1)
            {
            u32 sc = scoreCandidate((Node*)v.get(i), call, argBase);
            if (sc < best)
                best = sc;
            }
        Array* out = new Array();
        for (u32 i = (u32)0; i < v.count(); i = i + (u32)1)
            if (scoreCandidate((Node*)v.get(i), call, argBase) == best)
                out.add(v.get(i));
        return out;
        }

    // The candidate whose every argument's (rank, widening distance) is no
    // worse than each other candidate's and better on at least one, as C++
    // ranks conversions; 0 when no candidate is (or there is none).
    Node* dominator(Array* cands, Node* call, u32 argBase)
        {
        if (cands.count() == (u32)0)
            return (Node*)0;
        if (cands.count() == (u32)1)
            return (Node*)cands.get((u32)0);
        Array* keys = new Array();
        for (u32 i = (u32)0; i < cands.count(); i = i + (u32)1)
            keys.add((Object*)paramKeys((Node*)cands.get(i), call, argBase));
        for (u32 c = (u32)0; c < cands.count(); c = c + (u32)1)
            {
            Array* kc = (Array*)keys.get(c);
            bool beatsAll = kc != (Array*)0;
            for (u32 o = (u32)0; o < cands.count() && beatsAll; o = o + (u32)1)
                {
                if (o == c)
                    continue;
                Array* ko = (Array*)keys.get(o);
                if (ko == (Array*)0 || ko.count() != kc.count())
                    {
                    beatsAll = false;
                    continue;
                    }
                bool better = false;
                for (u32 i = (u32)0; i < kc.count(); i = i + (u32)1)
                    {
                    u32 a = ((Number*)kc.get(i)).asU32();
                    u32 b = ((Number*)ko.get(i)).asU32();
                    if (a > b)
                        beatsAll = false;
                    if (a < b)
                        better = true;
                    }
                if (!better)
                    beatsAll = false;
                }
            if (beatsAll)
                return (Node*)cands.get(c);
            }
        return (Node*)0;
        }

    Node* pickOverloadToday(Array* group, Node* call, u32 argBase)
        {
        u32 argc = (call.kidCount() > argBase) ? call.kidCount() - argBase : (u32)0;
        Array* arity = new Array();
        for (u32 i = (u32)0; i < group.count(); i = i + (u32)1)
            {
            Node* d = (Node*)group.get(i);
            u32 pc = paramCount(d);
            // A `...` function takes AT LEAST its declared parameters — the
            // rest are the varargs, and they are not part of the match.
            if (d.hasFlag((u32)NF_VARARGS) ? (argc >= pc) : (argc == pc))
                arity.add((Object*)d);
            }
        if (arity.count() == (u32)0)
            return (Node*)0;

        // Score each survivor and take the single best. A TIE is an ambiguous
        // call — the original diagnoses it, and this declines to stamp rather
        // than pick one arbitrarily.
        Node* best = (Node*)0;
        u32 bestScore = Overload.noMatch();
        u32 ties = (u32)0;
        for (u32 i = (u32)0; i < arity.count(); i = i + (u32)1)
            {
            Node* d = (Node*)arity.get(i);
            u32 sc = scoreCandidate(d, call, argBase);
            if (sc == Overload.noMatch())
                continue;
            if (best == 0 || sc < bestScore)
                {
                best = d;
                bestScore = sc;
                ties = (u32)1;
                }
            else if (sc == bestScore)
                ties = ties + (u32)1;
            }
        if (ties == (u32)1)
            return best;
        // No candidate converts at all: nothing TIES, and the tie-breakers
        // below must not choose one. With bestScore still noMatch every
        // candidate "tied" with it, so `i32 r = f(b)` took the i32-returning
        // f by its return type alone and its arguments were never checked
        // (a B* passed for an A*, a float* for a float).
        if (best == (Node*)0)
            return (Node*)0;
        // Candidates that tie with identical parameters AND an identical
        // RETURN type are the same function declared twice — a prototype and
        // its definition — not an ambiguity. The return type has to be part of
        // that test: `value()` exists as i8, i16 and u32 overloads whose
        // parameter lists are all empty, and those are genuinely different
        // functions that only the context can choose between.
        if (best != 0)
            {
            bool allSame = true;
            for (u32 i = (u32)0; i < arity.count(); i = i + (u32)1)
                {
                Node* d = (Node*)arity.get(i);
                if (scoreCandidate(d, call, argBase) != bestScore)
                    continue;
                if (!Vtable.sameParams(d, best))
                    allSame = false;
                if (d.op() == 0 || best.op() == 0 || !d.op().equals(best.op()))
                    allSame = false;
                }
            if (allSame)
                return best;
            }
        // A TIE — several candidates convert equally well. That happens when
        // overloads differ only in RETURN type (`Math.rand()` has five), and
        // the context is what chooses: `float f = Math.rand()` wants the float
        // one. Without an expected type there is nothing to choose on, and the
        // original diagnoses an ambiguous call.
        if (_expected != 0)
            {
            for (u32 i = (u32)0; i < arity.count(); i = i + (u32)1)
                {
                Node* d = (Node*)arity.get(i);
                if (scoreCandidate(d, call, argBase) != bestScore)
                    continue;
                if (d.op() != 0 && d.op().equals(_expected))
                    return d;
                }
            }
        // No context, or none of the tied forms returns what it wants: an
        // explicit `Class.m()` or a free call takes the FLOAT-returning form,
        // as the original does (its "printf defaults to float" rule). Other
        // call shapes leave the tie unresolved there too.
        if (_tieToFloat)
            {
            for (u32 i = (u32)0; i < arity.count(); i = i + (u32)1)
                {
                Node* d = (Node*)arity.get(i);
                if (scoreCandidate(d, call, argBase) != bestScore)
                    continue;
                String* rt = d.op() != 0 ? firstReturn(d.op()) : (String*)0;
                if (rt != 0 && _isOp(rt, "float"))
                    return d;
                }
            }
        return (Node*)0;
        }

    // The worst rank across the candidate's parameters.
    u32 scoreCandidate(Node* decl, Node* call, u32 argBase)
        {
        Array* keys = paramKeys(decl, call, argBase);
        if (keys == (Array*)0)
            return Overload.noMatch();
        u32 worst = (u32)0;
        for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
            worst = Overload.worstOf(worst, ((Number*)keys.get(i)).asU32() >> (u32)4);
        return worst;
        }

    // Each declared parameter's conversion as a key, rank * 16 plus the
    // widening distance in bytes for an integer widening (#643; 0 for any
    // other conversion), so a smaller key converts better; null when an
    // argument cannot convert at all. scoreCandidate's score is the worst
    // rank among them.
    Array* paramKeys(Node* decl, Node* call, u32 argBase)
        {
        Array* keys = new Array();
        u32 pi = (u32)0;
        // Only the DECLARED parameters are scored; a vararg has no parameter
        // to be converted to.
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* p = decl.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            u32 ai = argBase + pi;
            if (ai >= call.kidCount())
                return (Array*)0;
            Node* a = call.kid(ai);
            bool isLit = a.kind() == (u16)nkInt;
            // nil is the null pointer of any pointer type and nothing else:
            // it satisfies every pointer parameter alike (two of them tie,
            // which is an ambiguous call) and no integer one, whatever its
            // carrier type says.
            if (isLit && a.nilLit())
                {
                if (!Types.isPointer(Overload._unqualify(p.op())))
                    return (Array*)0;
                keys.add((Object*)Number.with((u32)0));
                pi = pi + (u32)1;
                continue;
                }
            u32 r = Overload.rank(scoreTy(a), p.op(), isLit, a.num());
            // BOXING is the last resort, below every direct conversion: a
            // primitive can box into a Foundation wrapper (rank 8) and a
            // class pointer can unbox into a primitive (rank 9), so an
            // overload that needs neither always wins the tie.
            if (r == Overload.noMatch() && autoboxClassFor(a.ty(), p.op()) != 0)
                r = (u32)8;
            if (r == Overload.noMatch() && canUnboxType(a.ty(), p.op()))
                r = (u32)9;
            if (r == Overload.noMatch())
                return (Array*)0;
            // An integer widening's distance (u16 into u32: 2 bytes, into
            // u64: 6): the smaller widening converts better (#643).
            u32 dist = (u32)0;
            String* at = Overload._decay(Overload._unqualify(a.ty()));
            String* pt = Overload._unqualify(p.op());
            if (!isLit && Types.isInteger(at) && Types.isInteger(pt) && Types.byteWidth(pt) > Types.byteWidth(at))
                dist = Types.byteWidth(pt) - Types.byteWidth(at);
            keys.add((Object*)Number.with(r * (u32)16 + dist));
            pi = pi + (u32)1;
            }
        return keys;
        }

    u32 paramCount(Node* decl)
        {
        u32 c = (u32)0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            if (decl.kid(i).kind() == (u16)nkParam)
                c = c + (u32)1;
        return c;
        }

    bool argsMatchExactly(Node* decl, Node* call, u32 argBase)
        {
        u32 pi = (u32)0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* p = decl.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            u32 ai = argBase + pi;
            if (ai >= call.kidCount())
                return false;
            String* at = scoreTy(call.kid(ai));
            if (at == 0 || p.op() == 0)
                return false;
            if (!at.equals(p.op()))
                return false;
            pi = pi + (u32)1;
            }
        return true;
        }

    // `recv.m(...)`: the receiver's type names the class, and the class (or an
    // ancestor) names the method.
    // `w.onChange(7)` / `s.fn(6)`: the member named here is a FIELD holding
    // something callable, not a method. Rewrite into the call it really is and
    // hang that on the node as one extra kid, past the receiver and the
    // arguments; lowering reads it from there. The dump does not print it.
    //
    // The field's type is obtained by typing a member node through the normal
    // path rather than by a second field lookup — the same reason the original
    // builds a member access here: one lookup, one set of rules.
    //
    // A real METHOD of that name always wins, so no existing program changes
    // meaning. private:docs/bugs/074.
    bool rewriteFieldCall(Node* n)
        {
        if (n.kidCount() == (u32)0)
            return false;
        String* recv = n.kid((u32)0).ty();
        if (recv == 0)
            return false;
        String* owner = classNameOf(recv);
        Node* cls = (Node*)_classes.get((Hashable*)owner);
        if (cls != 0 && findMethodUpChain(cls, n.name()) != 0)
            return false;
        if (cls == 0 && _structs.get((Hashable*)owner) == 0)
            return false;

        // The field's type is looked up DIRECTLY, not by typing a member node.
        // Typing one would run the full member path, which RECORDS "no such
        // member" when the name is not a field — and every ordinary method
        // call comes through here first. That produced a spurious error on
        // valid code, invisible only because the front end was dropping
        // sema's errors on the floor at the time.
        String* ft = (String*)0;
        Node* holder = cls != 0 ? cls : (Node*)_structs.get((Hashable*)owner);
        for (Node* c = holder; c != 0 && ft == 0; c = parentOf(c))
            ft = fieldType(c, n.name());
        if (ft == 0)
            return false;

        Node* ma = Node.withName((u16)nkMember, n.name());
        ma.add(n.kid((u32)0));
        ma.setTy(ft);

        u32 nargs = (u32)n.num();
        // A BLOCK field is a pointer to its `Blk$…` impl class, and a block
        // call is `.invoke` dispatch — the same rewrite the parser performs
        // for a block LOCAL, which through a field it never reached.
        String* cn = classNameOf(ft);
        if (cn != 0 && cn.hasPrefix(String.withCString("Blk$")))
            {
            Node* inv = Node.withName((u16)nkMethodCall, String.withCString("invoke"));
            inv.add(ma);
            for (u32 i = (u32)0; i < nargs; i = i + (u32)1)
                inv.add(n.kid(i + (u32)1));
            inv.setNum((i64)nargs);
            typeExpr(inv);
            n.setTy(inv.ty());
            n.addFlag((u32)NF_FIELDCALL);
            n.add(inv);
            return true;
            }
        if (!isSignature(ft))
            return false;

        Node* call = Node.withName((u16)nkCall, String.withCString("<indirect>"));
        // The call is where the user wrote it, so a diagnostic on it (a wrong
        // argument count, bug 271) is placed there.
        call.setPos(n.fileId(), n.line(), n.col());
        for (u32 i = (u32)0; i < nargs; i = i + (u32)1)
            call.add(n.kid(i + (u32)1));
        call.setNum((i64)nargs);
        call.add(ma);
        typeExpr(call);
        n.setTy(call.ty());
        n.addFlag((u32)NF_FIELDCALL);
        n.add(call);
        return true;
        }

    void typeMethodCall(Node* n)
        {
        if (n.kidCount() == (u32)0)
            return;
        // The call an overloaded operator became: one method is a candidate.
        // Taken at once, so no call typed below this one sees it.
        Node* opForced = _opForced;
        _opForced = (Node*)0;
        // Not a method call at all — the member is a field holding a callback,
        // a function pointer or a block. private:docs/bugs/074.
        if (opForced == 0 && rewriteFieldCall(n))
            return;
        String* recv = n.kid((u32)0).ty();
        String* owner = (String*)0;
        if (recv != 0)
            owner = classNameOf(recv);
        // A PROTOCOL-typed receiver keeps the protocol's name — checked before
        // the static-call fallback below, which would otherwise replace it with
        // the RECEIVER VARIABLE's name and lose the dispatch entirely.
        if (owner != 0 && _protocols.get((Hashable*)owner) != 0)
            {
            // fall through to the protocol path
            }
        else if (owner == 0 || _classes.get((Hashable*)owner) == 0)
            {
            Node* r = n.kid((u32)0);
            if (r.kind() == (u16)nkIdent)
                owner = r.name();
            }
        // `super.m()` starts the lookup at the PARENT, and the call records
        // which class it landed in — that is the whole point of `super`.
        Node* r0 = n.kid((u32)0);
        if (r0.kind() == (u16)nkIdent && r0.name() != 0 && _isOp(r0.name(), "super") && _curClass != 0)
            {
            // The candidates come from the NEAREST ancestor that declares the
            // name, and they must FIT: `super` has no single-candidate
            // courtesy, so a wrong count or an argument that does not convert
            // is refused rather than passed to the parent's body (bug 271).
            // Among fitting ones the first with the best score wins, as in the
            // reference.
            Node* p = parentOf(_curClass);
            while (p != 0)
                {
                Node* best = (Node*)0;
                u32 bestScore = Overload.noMatch();
                bool named = false;
                u32 argc = callArgc(n, (u32)1);
                for (u32 i = (u32)0; i < p.kidCount(); i = i + (u32)1)
                    {
                    Node* m = p.kid(i);
                    if (m.kind() != (u16)nkMethodDecl || m.name() == 0 || !m.name().equals(n.name()))
                        continue;
                    named = true;
                    if (!arityFits(m, argc))
                        continue;
                    u32 sc = scoreCandidate(m, n, (u32)1);
                    if (sc == Overload.noMatch())
                        continue;
                    if (best == 0 || sc < bestScore)
                        {
                        best = m;
                        bestScore = sc;
                        }
                    }
                if (named)
                    {
                    if (best == 0)
                        {
                        String* w = String.withCString("No overload of 'super.");
                        w.append(n.name());
                        w.appendCString("' matches (");
                        w.append(describeArgTypes(n, (u32)1));
                        w.appendCString(")");
                        _errorAt(w, n);
                        n.setTy(String.withCString("u8"));
                        return;
                        }
                    n.setTy(best.op());
                    narrowLengthArgs(best, n, (u32)1);
                    n.setSym(best.sym());
                    n.setCls(p.name());
                    noteCallEdge(clsLabel(p.name(), best.sym() != 0 ? best.sym() : best.name()));
                    noteClassNameUse(p.name(), best);
                    checkThrowsCall(best, n, n.name());
                    return;
                    }
                p = parentOf(p);
                }
            // Nothing on the super-chain answers to that name. This fell out
            // with a bare `return`, leaving the call untyped and its class
            // unset — and LOWERING then reported "super outside a method",
            // which is flatly false: it IS inside one. The reference diagnoses
            // it here, where the fact is known, and says which name and which
            // class (bug 213). `Object` declares no `init`, so
            // `class T : Object { void init() { super.init(); } }` is the
            // common way to meet this.
            String* w = String.withCString("No method '");
            w.append(n.name());
            w.appendCString("' on super-chain of '");
            w.append(_curClass.name());
            w.appendCString("'");
            _errorAt(w, n);
            n.setTy(String.withCString("u8"));
            return;
            }
        if (owner == 0)
            {
            n.setTy(String.withCString("u8"));
            return;
            }
        // A PROTOCOL-typed receiver dispatches through the protocol, not
        // through a class: the slot comes from the protocol's numbering, and
        // the call also carries the protocol-relative identity (name + the
        // method's index in declaration order), which needs no cross-module
        // agreement about slot numbers.
        Node* proto = (Node*)_protocols.get((Hashable*)owner);
        if (proto != 0)
            {
            u32 idx = (u32)0;
            for (u32 i = (u32)0; i < proto.kidCount(); i = i + (u32)1)
                {
                Node* pm = proto.kid(i);
                if (pm.kind() != (u16)nkMethodDecl)
                    continue;
                if (pm.name() != 0 && pm.name().equals(n.name()))
                    {
                    // A protocol method is the only candidate there is, and
                    // dispatch reaches whichever class implements it — so a
                    // wrong count lands in a body that reads parameters that
                    // were never passed (bug 271).
                    String* plbl = String.withString(owner);
                    plbl.appendByte((u8)'.');
                    plbl.append(n.name());
                    if (!checkArity(pm, n, (u32)1, plbl))
                        return;
                    checkMisfitArgs(pm, n, (u32)1, plbl);
                    // A requirement returning several values types the call by
                    // its first, as a class receiver's (the tuple assignment
                    // reads them all from the requirement). As the reference.
                    n.setTy(firstReturn(pm.op()));
                    Map* ps = _vt.protoSlotsFor(owner);
                    if (ps != 0)
                        {
                        Object* sl = ps.get((Hashable*)n.name());
                        if (sl != 0)
                            n.setVslot((i32)((Number*)sl).asU32());
                        }
                    n.setProto(owner, (i32)idx);
                    return;
                    }
                idx = idx + (u32)1;
                }
            return;
            }
        Node* cls = (Node*)_classes.get((Hashable*)owner);
        if (cls == 0)
            {
            n.setTy(String.withCString("u8"));
            return;
            }
        // `clone()` is auto-recognised on ANY class — no declaration needed,
        // the compiler emits the byte copy at the call site — and it yields a
        // class VALUE, not a pointer. A class that declares its own zero-arg
        // clone keeps it, and falls through to ordinary resolution.
        if (_isOp(n.name(), "clone") && n.kidCount() == (u32)1 && zeroArgMethodNamed(cls, n.name()) == 0)
            {
            n.setTy(String.withString(owner));
            return;
            }
        // Found on the receiver's own class, or inherited — and if inherited,
        // the call records WHICH class it came from.
        Node* owner2 = cls;
        _tieToFloat = true;
        _opPick = opForced;
        Node* m = methodOverload(cls, n, (u32)1);
        while (m == 0 && owner2 != 0)
            {
            owner2 = parentOf(owner2);
            if (owner2 == 0)
                break;
            m = methodOverload(owner2, n, (u32)1);
            }
        _opPick = (Node*)0;
        _tieToFloat = false;
        if (m == 0)
            {
            // An unresolved method call is an ERROR — and it was silent, so
            // `k.noSuchMethod(1)` compiled clean and produced a binary. The
            // comment here already said "is an error"; nothing emitted one.
            //
            // It is also what makes --migrate work: hiding a member newer than
            // the base leaves the call unresolved, and unresolved has to report
            // or the flag does nothing at all.
            //
            // A name that IS declared, with overloads none of which fits, is
            // a different complaint, and says so in the reference's words.
            u32 named = (u32)0;
            u32 fitting = (u32)0;
            u32 argc = callArgc(n, (u32)1);
            for (Node* c = cls; c != 0 && named == (u32)0; c = parentOf(c))
                for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                    {
                    Node* d = c.kid(i);
                    if (d.kind() != (u16)nkMethodDecl || d.name() == 0 || !d.name().equals(n.name()))
                        continue;
                    if (!memberVisibleUnderMigrate(d, c, n))
                        continue;
                    named = named + (u32)1;
                    if (arityFits(d, argc) && scoreCandidate(d, n, (u32)1) != Overload.noMatch())
                        fitting = fitting + (u32)1;
                    }
            String* e = String.withCString("");
            if (named == (u32)0)
                {
                e.appendCString("No method '");
                e.append(n.name());
                e.appendCString("' on class '");
                e.append(owner);
                e.appendByte((u8)0x27);
                }
            else if (fitting > (u32)1)
                {
                e.appendCString("Call to '");
                e.append(owner);
                e.appendByte((u8)'.');
                e.append(n.name());
                e.appendByte((u8)'(');
                e.append(describeArgTypes(n, (u32)1));
                e.appendCString(")' is ambiguous");
                }
            else
                {
                e.appendCString("No overload of '");
                e.append(owner);
                e.appendByte((u8)'.');
                e.append(n.name());
                e.appendCString("' matches argument types (");
                e.append(describeArgTypes(n, (u32)1));
                e.appendByte((u8)')');
                }
            _errorAt(e, n);
            n.setTy(String.withCString("u8"));
            return;
            }
        // One candidate by name is taken without scoring, so its count is
        // checked here, named as the receiver's class spells it (bug 271).
        String* mlbl = String.withString(owner);
        mlbl.appendByte((u8)'.');
        mlbl.append(n.name());
        if (!checkArity(m, n, (u32)1, mlbl))
            return;
        checkMisfitArgs(m, n, (u32)1, mlbl);
        if (owner2 != 0 && owner2 != cls)
            n.setCls(owner2.name());
        n.setTy(firstReturn(m.op()));
            // Typed collection: a call on an `Array<String>*` reads its own element
            // type back rather than the erased `Object*`. Substitution, not
            // instantiation — there is still one Array holding Object*. Lowering
            // spots the same mismatch and bridges it with a Bitcast.
            {
            // Only a CLASS element substitutes. A primitive one still comes
            // back boxed — the value really is a Number, and the existing
            // unbox turns `i32 v = a.get(i)` into `.asI32()`. Rewriting the
            // return to `i32*` would describe a pointer to an integer.
            //
            // The element may itself be generic — `Array<Array<String>>`
            // yields the element "Array<String>" — so the class is resolved
            // by the BASE name while the FULL spelling goes into the
            // substituted type, exactly as the original's element XTType
            // keeps its own annotation. The dump strips it (stripElem), and
            // a get on the RESULT reads the inner argument back off it.
            String* elem = Node.elemOf(recv);
            String* elemBase = Node.stripElem(elem);
            bool elemIsClass = elem != 0 && (_classes.get((Hashable*)elemBase) != 0 || _protocols.get((Hashable*)elemBase) != 0);
            if (elemIsClass && n.ty() != 0 && _isOp(Vtable.canonical(n.ty()), "Object*"))
                {
                String* sub = String.withCString("");
                sub.append(elem);
                sub.appendByte((u8)'*');
                n.setTy(sub);
                }
            }
            // A typed collection checks what goes IN, not only what comes out.
            // `Array<String>` erases its element to `Object*` and its key to
            // `Hashable*`, so without this the parameter accepted anything at all
            // and half of a two-argument Map went unchecked.
            {
            // A method declared on the ROOT takes its `Object*` because it
            // compares OBJECTS, not because the parameter is the collection's
            // element: `Array<String>.equals(Object* other)` is Object's own
            // method and accepts anything. Only a method on the collection
            // itself has an erased element.
            bool fromRoot = owner2 != 0 && owner2.name() != 0 && _isOp(owner2.name(), "Object");
            String* elem = fromRoot ? (String*)0 : Node.elemOf(recv);
            String* key = fromRoot ? (String*)0 : Node.keyOf(recv);
            u32 ai = (u32)0; // index among the arguments
            for (u32 pi = (u32)0; pi < m.kidCount(); pi = pi + (u32)1)
                {
                Node* prm = m.kid(pi);
                if (prm.kind() != (u16)nkParam)
                    continue;
                Node* arg = (ai + (u32)1) < n.kidCount() ? n.kid(ai + (u32)1) : (Node*)0;
                ai = ai + (u32)1;
                if (arg == 0 || prm.op() == 0)
                    continue;
                String* pc = Vtable.canonical(prm.op());
                if (elem != 0 && _isOp(pc, "Object*"))
                    {
                    String* site = String.withCString("'");
                    site.append(owner);
                    site.appendByte((u8)'.');
                    site.append(n.name());
                    site.appendCString("' element");
                    String* want = String.withString(Node.stripElem(elem));
                    want.appendByte((u8)'*');
                    if (_classes.get((Hashable*)Node.stripElem(elem)) != 0 || _protocols.get((Hashable*)Node.stripElem(elem)) != 0)
                        checkClassPointerAssignAt(want, arg.ty(), arg, site.cString(), n);
                    }
                else if (key != 0 && _isOp(pc, "Hashable*"))
                    {
                    String* site = String.withCString("'");
                    site.append(owner);
                    site.appendByte((u8)'.');
                    site.append(n.name());
                    site.appendCString("' key");
                    String* want = String.withString(Node.stripElem(key));
                    want.appendByte((u8)'*');
                    if (_classes.get((Hashable*)Node.stripElem(key)) != 0 || _protocols.get((Hashable*)Node.stripElem(key)) != 0)
                        checkClassPointerAssignAt(want, arg.ty(), arg, site.cString(), n);
                    }
                }
            }
        notePackOrForward(n, m, owner);
        narrowLengthArgs(m, n, (u32)1);
        n.setSym(m.sym());
        noteCallEdge(clsLabel(owner2 != 0 ? owner2.name() : owner, m.sym() != 0 ? m.sym() : m.name()));
        noteClassNameUse(owner2 != 0 ? owner2.name() : owner, m);
        rewriteFormat(n, owner);
        checkFormat(n, owner);
        promoteFormat(n, owner);
        // A call to a format WRAPPER, keyed by the class that declares it.
        if (formatIndex(n, owner) == (u32)0 && m.hasFlag((u32)NF_VARARGS))
            {
            String* wkey = String.withString(owner2 != 0 ? owner2.name() : owner);
            wkey.appendByte((u8)'.');
            wkey.append(n.name());
            u32 wk = fmtWrapperFor(wkey);
            if (wk != (u32)0)
                {
                String* cname = String.withString(owner);
                cname.appendByte((u8)'.');
                cname.append(n.name());
                formatCallAt(n, wk, cname);
                }
            }
        // Which KIND of receiver reached this method decides whether its
        // prologue retains self. Only an EXPLICIT receiver counts: a bare call
        // promoted by `use`, or an implicit-self call inside the class, leaves
        // the method unmarked — the original stamps this where a receiver
        // expression was actually written. A heap pointer and a stack instance can both
        // reach the same method in one program, so these are cumulative facts
        // about the method, not about this call.
        if (recv != 0 && Types.isPointer(recv))
            m.setHeapRecv();
        else
            m.setStackRecv();
        checkStackStrongArgs(n, m, (u32)1, quotedName(owner, m.name(), ""));
        checkThrowsCall(m, n, m.name());
        applyBoxing(n, m, (u32)1);
        }

    // ── BOXING ────────────────────────────────────────────────────────────
    // A primitive can travel as an object and an object can arrive as a
    // primitive; sema is what splices the conversion in. `a.add((u16)100)`
    // against `add(Object@)` becomes `a.add(Number.with((u16)100))`, and
    // `u16 v = a.get(0)` becomes `u16 v = ((Number@)a.get(0)).asU16()`. Both
    // rewrites happen in the TREE, after overload resolution has chosen the
    // candidate that needs them, so the dump shows the synthesised calls.

    // The Number accessor whose return type is exactly `t`, or none. This is
    // also the test for "can a primitive of this type come out of a Number".
    String* numberAccessorFor(String* t)
        {
        if (t == 0)
            return (String*)0;
        if (_isOp(t, "i8"))
            return String.withCString("asI8");
        if (_isOp(t, "u8"))
            return String.withCString("asU8");
        if (_isOp(t, "i16"))
            return String.withCString("asI16");
        if (_isOp(t, "u16"))
            return String.withCString("asU16");
        if (_isOp(t, "i32"))
            return String.withCString("asI32");
        if (_isOp(t, "u32"))
            return String.withCString("asU32");
        // The 64-bit widths and double: a box that cannot be read back is not
        // a box, so `Array<i64>` could not unbox through any path until these
        // existed. Mirrors the reference.
        if (_isOp(t, "i64"))
            return String.withCString("asI64");
        if (_isOp(t, "u64"))
            return String.withCString("asU64");
        if (_isOp(t, "float"))
            return String.withCString("asFloat");
        if (_isOp(t, "double"))
            return String.withCString("asDouble");
        return (String*)0;
        }

    // Can a `box` instance stand in where `want` (a pointer spelling) is
    // asked for — the wrapper IS the pointee, inherits from it, or conforms
    // to the protocol it names.
    bool boxSatisfies(String* box, String* want)
        {
        if (want == 0 || want.byteLength() < (u32)2)
            return false;
        if (want.byteAt(want.byteLength() - (u32)1) != (u8)'*')
            return false;
        String* pointee = classNameOf(want);
        if (_protocols.get((Hashable*)pointee) != 0)
            return Overload.conformsTo(box, pointee);
        if (_classes.get((Hashable*)pointee) == 0)
            return false;
        return Overload.descendsFrom(box, pointee);
        }

    // The wrapper class an argument of type `argT` boxes into to satisfy a
    // parameter of type `parT` — "Number" for a numeric primitive, "String"
    // for a `u8@` — or none. A value that is ALREADY a pointer to the
    // wrapper is not boxed; the ordinary upcast handles it.
    String* autoboxClassFor(String* argT, String* parT)
        {
        if (argT == 0 || parT == 0)
            return (String*)0;
        String* box = (String*)0;
        if (_isOp(argT, "bool"))
            return (String*)0;
        // isInteger already covers i64/u64; `double` had to be added beside
        // `float` or an `Array<double>` stored the raw eight bytes where a
        // pointer belonged. Boxing and unboxing grow together.
        if (Types.isInteger(argT) || Types.isFloating(argT))
            box = String.withCString("Number");
        else if (_isOp(argT, "u8*") || _isOp(argT, "string"))
            box = String.withCString("String");
        if (box == 0)
            return (String*)0;
        if (_classes.get((Hashable*)box) == 0)
            return (String*)0;
        if (_isOp(classNameOf(argT), box.cString()))
            return (String*)0;
        if (!boxSatisfies(box, parT))
            return (String*)0;
        return box;
        }

    // The symmetric test: a class pointer carrying a Number arriving where a
    // primitive is wanted.
    bool canUnboxType(String* rhsT, String* lhsT)
        {
        if (numberAccessorFor(lhsT) == 0)
            return false;
        if (rhsT == 0 || rhsT.byteLength() < (u32)2)
            return false;
        if (rhsT.byteAt(rhsT.byteLength() - (u32)1) != (u8)'*')
            return false;
        if (_classes.get((Hashable*)String.withCString("Number")) == 0)
            return false;
        String* pointee = classNameOf(rhsT);
        if (_protocols.get((Hashable*)pointee) != 0)
            return Overload.conformsTo(String.withCString("Number"), pointee);
        if (_classes.get((Hashable*)pointee) == 0)
            return false;
        return Overload.descendsFrom(String.withCString("Number"), pointee);
        }

    // `Number.with(e)` / `String.withCString(e)`, typed by the ordinary path
    // so the factory's own overload resolution and receiver marks happen.
    Node* boxedNode(Node* e, String* box)
        {
        Node* call = Node.withName((u16)nkMethodCall,
                                   _isOp(box, "String") ? String.withCString("withCString")
                                                        : String.withCString("with"));
        call.setNum((i64)1);
        call.add(Node.withName((u16)nkIdent, box));
        call.add(e);
        typeExpr(call);
        return call;
        }

    // `((Number@)e).asXXX()`. The cast is skipped when `e` is already a
    // Number@ — there is nothing to convert.
    Node* unboxedNode(Node* e, String* lhsT)
        {
        String* acc = numberAccessorFor(lhsT);
        if (acc == 0)
            return (Node*)0;
        Node* recv = e;
        if (!_isOp(classNameOf(e.ty()), "Number"))
            {
            Node* cast = Node.withName((u16)nkCast, String.withCString("Number*"));
            cast.add(e);
            recv = cast;
            }
        Node* call = Node.withName((u16)nkMethodCall, acc);
        call.setNum((i64)0);
        call.add(recv);
        typeExpr(call);
        return call;
        }

    // Unbox an expression that READS AN ELEMENT out of a typed collection
    // whose element type is a PRIMITIVE. `Array<i32>* a` holds boxed Numbers,
    // so `a.get(i)` comes back as a pointer; that was unboxed in the four
    // contexts that happened to have a site (declaration, assignment, return,
    // typed argument) and nowhere else, so `a.get(i) + 1` added to the POINTER
    // and `a.get(i) == 70` compared one and answered false. The element type is
    // decided by the COLLECTION, not by the context the read appears in, so
    // this needs no target type. Returns `e` unchanged when it does not apply.
    // private:docs/bugs/046.
    // The type unboxCollectionElement would give `e`, without building the
    // unboxing: its element type when it is a typed collection's primitive
    // element, else its own type.
    String* unboxedTypeOf(Node* e)
        {
        if (e == 0)
            return (String*)0;
        if (e.kind() != (u16)nkMethodCall || e.ty() == 0 || !_isOp(Vtable.canonical(e.ty()), "Object*"))
            return e.ty();
        if (_isOp(e.name(), "copy") || e.kidCount() == (u32)0)
            return e.ty();
        String* elem = Node.elemOf(e.kid((u32)0).ty());
        if (elem == 0 || numberAccessorFor(elem) == 0)
            return e.ty();
        // Without the Number class the element is not unboxed (that is
        // refused, unboxCollectionElement), so the format keeps its spelling,
        // as the reference's does.
        if (_classes.get((Hashable*)String.withCString("Number")) == 0)
            return e.ty();
        return elem;
        }

    Node* unboxCollectionElement(Node* e)
        {
        if (e == 0)
            return e;
        if (e.kind() != (u16)nkMethodCall)
            return e;
        if (e.ty() == 0 || !_isOp(Vtable.canonical(e.ty()), "Object*"))
            return e;
        // `Copying` declares `Object* copy(void)`, so a collection's own copy is
        // spelled exactly like one of its elements. Excluded by name — see the
        // original's note, and bug 051.
        if (_isOp(e.name(), "copy"))
            return e;
        if (e.kidCount() == (u32)0)
            return e;
        String* elem = Node.elemOf(e.kid((u32)0).ty());
        if (elem == 0)
            return e;
        if (numberAccessorFor(elem) == 0)
            return e;
        // A typed collection of primitives holds Number boxes, so reading one
        // back needs the class. Without it this built a call on a class that
        // was never declared, refused later as "method call on a non-class"
        // (bug 595).
        if (_classes.get((Hashable*)String.withCString("Number")) == 0)
            {
            String* m = String.withCString("a collection of '");
            m.append(elem);
            m.appendCString("' keeps its elements as Number: #import \"Number.xc\" (Foundation.xc imports it)");
            _errorAt(m, e);
            return e;
            }
        Node* u = unboxedNode(e, elem);
        if (u == 0)
            return e;
        return u;
        }

    // After a call has chosen its candidate, every argument that needs a
    // conversion gets one.
    // A pointer argument whose POINTEE WIDTH differs from the parameter's is a
    // refusal, not a conversion. `i32*` where `i64*` is declared lets the callee
    // write eight bytes into four; `i64*` where `i32*` is declared leaves the
    // caller's high half untouched, which is how a `delta < 0` guard in the
    // vectoriser came to be unfirable — the sign never reached it.
    //
    // NOT refused: void* (the escape hatch), function pointers, structs and
    // classes (layout, not width — a different question), and same-width
    // differences, which are sign only. Measured across the whole tree, this
    // fires on nothing once the one real victim is fixed.
    // private:docs/bugs/244.
    // `i64*` -> `i64`. The declared spelling ends in the sigil; anything else
    // is not a pointer this check has an opinion about.
    String* ptrPointee(String* t)
        {
        if (t == 0 || t.byteLength() == (u32)0)
            return (String*)0;
        if (t.byteAt(t.byteLength() - (u32)1) != (u8)'*')
            return (String*)0;
        return t.substringToByte(t.byteLength() - (u32)1);
        }

    void checkPtrArgWidth(Node* a, String* pty, String* callee, u32 argNo)
        {
        if (a == 0 || pty == 0 || a.ty() == 0)
            return;
        if (!Types.isPointer(pty) || !Types.isPointer(a.ty()))
            return;
        // `simd:` is part of the parameter's identity (unlike placement or
        // weak): a pointer that does not promise page-aligned storage cannot
        // satisfy it, or the callee's no-copy GPU wrap would read unaligned
        // memory — this is how a library's `simd:` par-block parameter holds
        // every caller (par-blocks.md). The other direction only drops the
        // guarantee and is fine. An explicit per-argument check, not an
        // overload-rank refusal: a lone candidate is never ranked, and the two
        // compilers must say the same thing.
        if (Overload._isSimd(pty) && !Overload._isSimd(a.ty()))
            {
            String* m = String.withCString("argument ");
            m.append(String.withU32(argNo));
            m.appendCString(" of '");
            m.append(callee);
            m.appendCString("' is not a simd: pointer where a simd: pointer is declared — simd: "
                            "promises page-aligned storage (a new[] into a simd: pointer, or "
                            "another simd: pointer), and the callee may hand it to a GPU with no "
                            "copy. Cast if that is really meant");
            _errorAt(m, a);
            return;
            }
        String* pp = ptrPointee(pty);
        String* ap = ptrPointee(a.ty());
        if (pp == 0 || ap == 0)
            return;
        // void* is the escape hatch; a pointer-to-pointer is a width the
        // target decides, not a scalar one; an aggregate is layout, not width.
        if (_isOp(pp, "void") || _isOp(ap, "void"))
            return;
        if (Types.isPointer(pp) || Types.isPointer(ap))
            return;
        if (!Types.isInteger(pp) && !Types.isFloating(pp))
            return;
        if (!Types.isInteger(ap) && !Types.isFloating(ap))
            return;
        u32 pw = Types.byteWidth(pp);
        u32 aw = Types.byteWidth(ap);
        if (pw == (u32)0 || aw == (u32)0 || pw == aw)
            return;
        String* m = String.withCString("argument ");
        m.append(String.withU32(argNo));
        m.appendCString(" of '");
        m.append(callee);
        m.appendCString("' is a ");
        m.append(ap);
        m.appendCString("* where a ");
        m.append(pp);
        m.appendCString("* is declared — the pointee widths differ (");
        m.append(String.withU32(aw));
        m.appendCString(" vs ");
        m.append(String.withU32(pw));
        m.appendCString("), so the callee would read or write the wrong number "
                        "of bytes. Cast if that is really meant");
        _errorAt(m, a);
        }

    void applyBoxing(Node* call, Node* decl, u32 argBase)
        {
        u32 pi = (u32)0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* p = decl.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            u32 ai = argBase + pi;
            pi = pi + (u32)1;
            if (ai >= call.kidCount())
                return;
            Node* a = call.kid(ai);
            checkPtrArgWidth(a, p.op(), decl.name(), pi);
            String* box = autoboxClassFor(a.ty(), p.op());
            if (box != 0)
                {
                call.setKid(ai, boxedNode(a, box));
                continue;
                }
            if (canUnboxType(a.ty(), p.op()))
                {
                Node* u = unboxedNode(a, p.op());
                if (u != 0)
                    call.setKid(ai, u);
                }
            }
        // Arguments PAST the declared parameters are varargs: no parameter
        // type to key an unbox off, so `printf("%ld", a.get(i))` packed the box
        // and printed a pointer.
        u32 first = argBase + pi;
        for (u32 j = first; j < call.kidCount(); j = j + (u32)1)
            call.setKid(j, unboxCollectionElement(call.kid(j)));
        }

    // The parameter type every candidate agrees on for the argument at kid
    // `kidIdx`, or none. An argument is assigned to its parameter, so the
    // parameter's type is the context that picks a return-type-only overload
    // in the argument: `check(Math.E())` with `check(double)` wants the double
    // `E`. When the candidates disagree (`Math.ln` has a float and a double
    // form) there is no single type to want, and the context already in hand
    // stays. The candidate set is the one resolution scores: for a bare call
    // the enclosing class chain's methods when it declares the name (except a
    // method calling its own name), otherwise the free functions; for
    // `recv.m()` the methods of that name on the nearest class up the chain
    // that declares it. `super`, protocols, callee expressions and variables
    // holding a function have none.
    String* paramHint(Node* call, u32 kidIdx)
        {
        u16 k = call.kind();
        if (call.name() == 0)
            return (String*)0;
        if (k == (u16)nkCall)
            {
            if (kidIdx >= (u32)call.num() || call.kidCount() > (u32)call.num())
                return (String*)0;
            u32 argc = (u32)call.num();
            if (_curClass != 0 && !wrapsFree(call.name()))
                {
                Array* ms = methodsNamedNearest(_curClass, call.name());
                if (ms.count() > (u32)0)
                    return agreedParam(ms, kidIdx, argc);
                }
            if (lookup(call.name()) != 0)
                return (String*)0;
            Array* group = (Array*)_functions.get((Hashable*)call.name());
            if (group == 0)
                return (String*)0;
            return agreedParam(group, kidIdx, argc);
            }
        if (k != (u16)nkMethodCall || kidIdx == (u32)0 || call.kidCount() == (u32)0)
            return (String*)0;
        Node* r = call.kid((u32)0);
        Node* cls = (Node*)0;
        if (r.kind() == (u16)nkIdent && r.name() != 0)
            {
            if (_isOp(r.name(), "super"))
                return (String*)0;
            cls = (Node*)_classes.get((Hashable*)r.name());
            }
        if (cls == 0 && r.ty() != 0)
            {
            String* cn = classNameOf(r.ty());
            if (cn != 0)
                cls = (Node*)_classes.get((Hashable*)cn);
            }
        if (cls == 0)
            return (String*)0;
        return agreedParam(methodsNamedNearest(cls, call.name()), kidIdx - (u32)1,
                           call.kidCount() - (u32)1);
        }

    // Every method called `name` on the nearest class from `cls` up that
    // declares one.
    Array* methodsNamedNearest(Node* cls, String* name)
        {
        Array* out = new Array();
        for (Node* c = cls; c != 0 && out.count() == (u32)0; c = parentOf(c))
            {
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                {
                Node* m = c.kid(i);
                if (m.kind() == (u16)nkMethodDecl && m.name() != 0 && m.name().equals(name))
                    out.add((Object*)m);
                }
            }
        return out;
        }

    // The type of parameter `idx` when every candidate that takes `argc`
    // arguments declares the same one there.
    String* agreedParam(Array* cands, u32 idx, u32 argc)
        {
        String* agreed = (String*)0;
        for (u32 i = (u32)0; i < cands.count(); i = i + (u32)1)
            {
            Node* d = (Node*)cands.get(i);
            u32 pc = paramCount(d);
            bool fits = d.hasFlag((u32)NF_VARARGS) ? (argc >= pc) : (argc == pc);
            if (!fits || idx >= pc)
                continue;
            String* t = (String*)0;
            u32 pi = (u32)0;
            for (u32 j = (u32)0; j < d.kidCount() && t == 0; j = j + (u32)1)
                {
                Node* p = d.kid(j);
                if (p.kind() != (u16)nkParam)
                    continue;
                if (pi == idx)
                    {
                    t = p.op();
                    if (t == 0 || t.byteLength() == (u32)0)
                        return (String*)0;
                    }
                pi = pi + (u32)1;
                }
            if (t == 0)
                return (String*)0;
            if (agreed == 0)
                agreed = t;
            else if (!agreed.equals(t))
                return (String*)0;
            }
        return agreed;
        }

    // ── C PRINTF FORMATS ──────────────────────────────────────────────────
    // One scanner walks a format the way C's printf does:
    //     % flags* (width | *) (. (digits | *))? length? conversion
    // with the length one of hh h l ll j z t L q. A `*` width or precision
    // reads an argument of its own, ahead of the conversion's. `%%` reads
    // nothing. The next conversion from sp[6] onward fills sp[0..5] — the
    // '%', the length's first byte, the conversion's position, one past it,
    // the conversion, and how many `*` arguments it reads — and moves sp[6]
    // past it. False when there are no more.
    bool fmtNext(String* f, u32* sp)
        {
        u32 n = f.byteLength();
        u32 i = sp[6];
        while (i < n && f.byteAt(i) != (u8)'%')
            i = i + (u32)1;
        if (i + (u32)1 >= n)
            {
            sp[6] = n;
            return false;
            }
        sp[0] = i;
        sp[5] = (u32)0;
        i = i + (u32)1;
        while (i < n)
            {
            u8 fl = f.byteAt(i);
            if (fl != (u8)'-' && fl != (u8)'+' && fl != (u8)' ' && fl != (u8)'#' && fl != (u8)'0')
                break;
            i = i + (u32)1;
            }
        if (i < n && f.byteAt(i) == (u8)'*')
            {
            sp[5] = sp[5] + (u32)1;
            i = i + (u32)1;
            }
        else
            while (i < n && f.byteAt(i) >= (u8)'0' && f.byteAt(i) <= (u8)'9')
                i = i + (u32)1;
        if (i < n && f.byteAt(i) == (u8)'.')
            {
            i = i + (u32)1;
            if (i < n && f.byteAt(i) == (u8)'*')
                {
                sp[5] = sp[5] + (u32)1;
                i = i + (u32)1;
                }
            else
                while (i < n && f.byteAt(i) >= (u8)'0' && f.byteAt(i) <= (u8)'9')
                    i = i + (u32)1;
            }
        sp[1] = i;
        if (i < n)
            {
            u8 c = f.byteAt(i);
            if ((c == (u8)'h' || c == (u8)'l') && i + (u32)1 < n && f.byteAt(i + (u32)1) == c)
                i = i + (u32)2;
            else if (c == (u8)'h' || c == (u8)'l' || c == (u8)'j' || c == (u8)'z' || c == (u8)'t'
                     || c == (u8)'L' || c == (u8)'q')
                i = i + (u32)1;
            }
        if (i >= n)
            {
            sp[6] = n;
            return false;
            }
        sp[2] = i;
        sp[4] = (u32)f.byteAt(i);
        sp[3] = i + (u32)1;
        sp[6] = sp[3];
        return true;
        }

    // 0 `%%`, 1 d i u x X o, 2 c, 3 f F e E g G a A, 4 s, 5 @, 6 p n, 7 unknown.
    u32 fmtKind(u32 c)
        {
        if (c == (u32)'%')
            return (u32)0;
        if (c == (u32)'d' || c == (u32)'i' || c == (u32)'u' || c == (u32)'x' || c == (u32)'X' || c == (u32)'o')
            return (u32)1;
        if (c == (u32)'c')
            return (u32)2;
        if (c == (u32)'f' || c == (u32)'F' || c == (u32)'e' || c == (u32)'E' || c == (u32)'g' || c == (u32)'G'
            || c == (u32)'a' || c == (u32)'A')
            return (u32)3;
        if (c == (u32)'s')
            return (u32)4;
        if (c == (u32)'@')
            return (u32)5;
        if (c == (u32)'p' || c == (u32)'n')
            return (u32)6;
        return (u32)7;
        }

    // `int` is 16 bits where a pointer is narrower than 4 bytes (xt6502), and
    // 32 everywhere else.
    u32 fmtIntWidth(void)
        {
        return _ptrW < (u32)4 ? (u32)2 : (u32)4;
        }

    // An enum is an integer here, as it is in the reference's type table.
    bool fmtIsInt(String* t)
        {
        return Types.isInteger(t) || Types.isEnumName(t);
        }

    // How many arguments a format reads.
    u32 fmtArgCount(String* f)
        {
        u32 sp[7];
        sp[6] = (u32)0;
        u32 want = (u32)0;
        while (fmtNext(f, &sp[0]))
            if (fmtKind(sp[4]) != (u32)0)
                want = want + sp[5] + (u32)1;
        return want;
        }

    // Where the format sits among a call's kids (the receiver is kid 0), or 0
    // when this is not a format function: Stdio.printf/printfAt,
    // String.withFormat/appendFormat, Log.error/warning/info.
    u32 formatIndex(Node* call, String* owner)
        {
        if (_isOp(owner, "Stdio"))
            {
            if (_isOp(call.name(), "printf"))
                return (u32)1;
            if (_isOp(call.name(), "printfAt"))
                return (u32)3;
            }
        else if (_isOp(owner, "String"))
            {
            if (_isOp(call.name(), "withFormat") || _isOp(call.name(), "appendFormat"))
                return (u32)1;
            }
        else if (_isOp(owner, "Log"))
            {
            if (_isOp(call.name(), "error") || _isOp(call.name(), "warning") || _isOp(call.name(), "info"))
                return (u32)1;
            }
        return (u32)0;
        }

    // The type a LITERAL format wants for the argument at `argIdx`, or none:
    // `double` for a floating conversion, so `Math.PI()` — a float and a
    // double overload that differ only in their return type — picks the
    // double. Asked while the kids are typed, so the receiver already is.
    String* printfHint(Node* call, u32 argIdx)
        {
        if (call.kind() != (u16)nkMethodCall || call.kidCount() == (u32)0)
            return (String*)0;
        Node* recv = call.kid((u32)0);
        u32 fmtIdx = (u32)0;
        if (_isOp(call.name(), "appendFormat"))
            {
            if (recv.ty() != 0 && (_isOp(Node.stripElem(recv.ty()), "String*")
                                   || _isOp(Node.stripElem(recv.ty()), "String")))
                fmtIdx = (u32)1;
            }
        else if (recv.kind() == (u16)nkIdent && (_isOp(recv.name(), "Stdio") || _isOp(recv.name(), "String")
                                                 || _isOp(recv.name(), "Log")))
            fmtIdx = formatIndex(call, recv.name());
        if (fmtIdx == (u32)0 || argIdx <= fmtIdx || call.kidCount() <= fmtIdx)
            return (String*)0;
        Node* lit = call.kid(fmtIdx);
        if (lit.kind() != (u16)nkStr || lit.name() == 0)
            return (String*)0;
        String* f = lit.name();
        u32 want = argIdx - fmtIdx - (u32)1; // 0-based position in the tail
        u32 seen = (u32)0;
        u32 sp[7];
        sp[6] = (u32)0;
        while (fmtNext(f, &sp[0]))
            {
            u32 kind = fmtKind(sp[4]);
            if (kind == (u32)0)
                continue;
            seen = seen + sp[5];
            if (seen == want)
                return kind == (u32)3 ? String.withCString("double") : (String*)0;
            if (seen > want)
                return (String*)0;
            seen = seen + (u32)1;
            }
        return (String*)0;
        }

    void rewriteFormat(Node* call, String* owner)
        {
        u32 fmtIdx = formatIndex(call, owner);
        if (fmtIdx != (u32)0)
            rewriteFormatAt(call, fmtIdx);
        }

    // A LITERAL format's integer conversions are fitted to the arguments
    // actually passed: the length modifier is replaced by the one that reads
    // the argument's real size — none for up to an `int`, `l` for 32 bits
    // where `int` is 16, `ll` for 64. So `%d` prints an i64 whole and `%lld`
    // on an i32 does not read past it. An argument that is not an integer
    // keeps the conversion as written (the check reports it). The arguments
    // running out leaves the format alone.
    void rewriteFormatAt(Node* call, u32 fmtIdx)
        {
        if (call.kidCount() <= fmtIdx)
            return;
        Node* lit = call.kid(fmtIdx);
        if (lit.kind() != (u16)nkStr || lit.name() == 0)
            return;
        String* f = lit.name();
        // Every literal format passes here first, before an enum's `%@` is
        // respelled `%e` below.
        if (f.byteIndexOf(String.withCString("%@")) != String.notFound())
            _usesAtFormat = true;
        String* out = String.withCString("");
        u32 intW = fmtIntWidth();
        u32 copied = (u32)0;
        u32 va = fmtIdx + (u32)1;
        u32 sp[7];
        sp[6] = (u32)0;
        while (fmtNext(f, &sp[0]))
            {
            u32 kind = fmtKind(sp[4]);
            if (kind == (u32)0)
                continue;
            va = va + sp[5];
            if (va >= call.kidCount())
                return;
            // The type the argument WILL have: a typed collection's element is
            // unboxed later (applyBoxing), and fitting `%ld` to the box left a
            // 32-bit element printed through a 64-bit conversion, so -5 came
            // out as 4294967291 (bug 590).
            String* at = unboxedTypeOf(call.kid(va));
            va = va + (u32)1;
            // An enum's name is printed by the lowering's `%e` rewrite, so
            // `%@` given an enum is spelled that way.
            if (kind == (u32)5 && at != 0 && Types.isEnumName(at))
                {
                out.append(f.substringBytes(copied, sp[2] - copied));
                out.appendByte((u8)'e');
                copied = sp[3];
                continue;
                }
            if (kind != (u32)1 || at == 0 || !fmtIsInt(at))
                continue;
            u32 w = Types.byteWidth(at);
            out.append(f.substringBytes(copied, sp[1] - copied));
            if (w >= (u32)8)
                out.appendCString("ll");
            else if (w > intW)
                out.appendByte((u8)'l');
            copied = sp[2];
            }
        out.append(f.substringBytes(copied, f.byteLength() - copied));
        if (!out.equals(f))
            lit.setName(out);
        }

    // The reference names a `use`-promoted bare call in the diagnostic
    // differently from an explicit one: `printf (Stdio.printf via use)`, so
    // that a reader can tell which spelling they wrote. Built here so the
    // two `use` call sites cannot drift from the reference's wording.
    String* useFormatCallName(String* callee, string method)
        {
        String* s = String.withString(callee);
        s.appendCString(" (Stdio.");
        s.appendCString(method);
        s.appendCString(" via use)");
        return s;
        }

    // "error (Log.error via use)"
    String* useFormatCallNameIn(String* callee, string owner, String* method)
        {
        String* s = String.withString(callee);
        s.appendCString(" (");
        s.appendCString(owner);
        s.appendCString(".");
        s.append(method);
        s.appendCString(" via use)");
        return s;
        }

    // ── FORMAT-STRING CHECKER ─────────────────────────────────────────────
    // With each conversion's length fitted to its argument, the mistakes left
    // to report are a wrong KIND of argument — a double for `%d`, an integer
    // for `%s` — and a count that does not match. A format that is not a
    // literal is not checked.
    void checkFormat(Node* call, String* owner)
        {
        u32 fmtIdx = formatIndex(call, owner);
        if (fmtIdx == (u32)0)
            return;
        String* name = String.withString(owner);
        name.appendByte((u8)'.');
        name.append(call.name());
        checkFormatAt(call, fmtIdx, name);
        }

    bool isAggType(String* t)
        {
        if (t == 0)
            return false;
        String* bare = Node.stripElem(t);
        return _classes.get((Hashable*)bare) != 0 || _protocols.get((Hashable*)bare) != 0;
        }

    void checkFormatAt(Node* call, u32 fmtIdx, String* callName)
        {
        if (call.kidCount() <= fmtIdx)
            return;
        Node* lit = call.kid(fmtIdx);
        // `printf(text)`: a format that is not a literal, with nothing after
        // it, is text printed AS a format, and text that holds a `%x` or a
        // `%p` reads the stack (the security review, 2026-10-21).
        // Only a C string (a String object goes to the message overload),
        // and not a call that forwards its own `...` tail.
        String* fty = lit.kind() != (u16)nkStr ? Node.stripElem(unboxedTypeOf(lit)) : (String*)0;
        if (lit.kind() != (u16)nkStr && call.kidCount() == fmtIdx + (u32)1 && !call.hasFlag((u32)NF_VAFWD)
            && fty != (String*)0 && (fty.equals(String.withCString("u8*")) || fty.equals(String.withCString("u8@"))
                                      || fty.equals(String.withCString("string"))))
            {
            String* msg = String.withString(callName);
            msg.appendCString(": the format is not a string literal and takes no arguments; to print text, use \"%s\" and pass it");
            _warnAt(String.withCString("printf-format"), msg, call);
            return;
            }
        if (lit.kind() != (u16)nkStr || lit.name() == 0)
            return;
        String* f = lit.name();

        u32 argCount = call.kidCount() > fmtIdx + (u32)1 ? call.kidCount() - (fmtIdx + (u32)1) : (u32)0;
        u32 want = fmtArgCount(f);
        if (argCount != want)
            {
            String* msg = String.withString(callName);
            msg.appendCString(": format string expects ");
            msg.append(String.withU32(want));
            msg.appendCString(want == (u32)1 ? " argument, " : " arguments, ");
            msg.append(String.withU32(argCount));
            msg.appendCString(" supplied");
            _warnAt(String.withCString("printf-format"), msg, call);
            }

        u32 next = (u32)0;
        u32 sp[7];
        sp[6] = (u32)0;
        while (fmtNext(f, &sp[0]))
            {
            u32 kind = fmtKind(sp[4]);
            if (kind == (u32)0)
                continue;
            u32 ai = next + sp[5];
            next = ai + (u32)1;
            if (ai >= argCount)
                continue;
            String* at = call.kid(fmtIdx + (u32)1 + ai).ty();
            if (at == 0)
                continue;
            bool isP = Types.isPointer(at);
            // An enum given to %@ or %e prints its member's name.
            if (Types.isEnumName(at) && (sp[4] == (u32)'@' || sp[4] == (u32)'e'))
                continue;
            string expects = (string)0;
            if (kind == (u32)1 || kind == (u32)2)
                {
                if (!fmtIsInt(at))
                    expects = "an integer";
                }
            else if (kind == (u32)3)
                {
                if (!Types.isFloating(at))
                    expects = "a floating-point value";
                }
            else if (kind == (u32)4)
                {
                if (!isP)
                    expects = "a string";
                }
            else if (kind == (u32)5)
                {
                if (!isP && !isAggType(at))
                    expects = "an object";
                }
            else if (kind == (u32)6)
                {
                if (!isP)
                    expects = "a pointer";
                }
            if (expects == (string)0)
                continue;
            String* msg = String.withString(callName);
            msg.appendCString(": '");
            msg.append(f.substringBytes(sp[0], sp[3] - sp[0]));
            msg.appendCString("' expects ");
            msg.appendCString(expects);
            msg.appendCString(" but argument ");
            msg.append(String.withU32(ai + (u32)1));
            msg.appendCString(" is ");
            // The reference keeps an element annotation on the type OBJECT
            // and prints only the bare name (`Array*`, not `Array<String>*`),
            // so printing the port's spelled type here would diverge on any
            // aggregate argument that warns.
            msg.append(Node.stripElem(at));
            _warnAt(String.withCString("printf-format"), msg, call);
            }
        }

    // A FORMAT WRAPPER is a variadic function or method that hands its own
    // last named parameter, followed by `...`, to a format function:
    //     void say(string fmt, ...) { s.appendFormat(fmt, ...); }
    // Its callers then get what a format function's callers get — lengths
    // fitted, the check, the promotions — or a `%d` given a u8 would read an
    // int the caller never passed. Found by a scan of the body for such a
    // call: through blocks, ifs, loops, expression statements, declarations
    // and returns, and into the arguments (and receiver) of calls — the same
    // shapes the reference walks.
    bool fmtIsFormatName(String* n)
        {
        return _isOp(n, "printf") || _isOp(n, "printfAt") || _isOp(n, "withFormat")
               || _isOp(n, "appendFormat") || _isOp(n, "error") || _isOp(n, "warning")
               || _isOp(n, "info");
        }

    bool fmtForwards(Node* n, String* param)
        {
        if (n == 0)
            return false;
        u16 k = n.kind();
        if (k == (u16)nkCall || k == (u16)nkMethodCall)
            {
            u32 first = k == (u16)nkMethodCall ? (u32)1 : (u32)0;
            if (n.hasFlag((u32)NF_VAFWD) && fmtIsFormatName(n.name()) && n.kidCount() > first)
                {
                Node* last = n.kid(n.kidCount() - (u32)1);
                if (last.kind() == (u16)nkIdent && last.name() != 0 && last.name().equals(param))
                    return true;
                }
            }
        else if (k != (u16)nkBlock && k != (u16)nkIf && k != (u16)nkWhile && k != (u16)nkForCStyle
                 && k != (u16)nkForIn && k != (u16)nkExprStatement && k != (u16)nkVariableDecl
                 && k != (u16)nkReturn && k != (u16)nkMarkerInit && k != (u16)nkMarkerCond
                 && k != (u16)nkMarkerStep)
            return false;
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            if (fmtForwards(n.kid(i), param))
                return true;
        return false;
        }

    // The index of a wrapper's format parameter plus one, or 0.
    u32 fmtWrapperIndex(Node* decl)
        {
        if (!decl.hasFlag((u32)NF_VARARGS))
            return (u32)0;
        u32 params = (u32)0;
        Node* last = 0;
        Node* body = 0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* c = decl.kid(i);
            if (c.kind() == (u16)nkParam)
                {
                params = params + (u32)1;
                last = c;
                }
            else if (c.kind() == (u16)nkBlock)
                body = c;
            }
        if (last == 0 || body == 0 || last.name() == 0)
            return (u32)0;
        return fmtForwards(body, last.name()) ? params : (u32)0;
        }

    // Every format wrapper in the program, before any body is typed, so a
    // call ahead of the wrapper's definition is treated like one after it.
    void collectFormatWrappers(Node* program)
        {
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            {
            Node* d = program.kid(i);
            if (d.kind() == (u16)nkFunctionDecl)
                {
                u32 k = fmtWrapperIndex(d);
                if (k != (u32)0)
                    _fmtWrappers.set((Hashable*)d.name(), (Object*)String.withU32(k));
                }
            else if (d.kind() == (u16)nkClassDecl)
                {
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    {
                    Node* m = d.kid(j);
                    if (m.kind() != (u16)nkMethodDecl)
                        continue;
                    u32 k = fmtWrapperIndex(m);
                    if (k == (u32)0)
                        continue;
                    String* key = String.withString(d.name());
                    key.appendByte((u8)'.');
                    key.append(m.name());
                    _fmtWrappers.set((Hashable*)key, (Object*)String.withU32(k));
                    }
                }
            }
        }

    // The format index a wrapper was recorded with (plus one), or 0.
    u32 fmtWrapperFor(String* key)
        {
        String* v = (String*)_fmtWrappers.get((Hashable*)key);
        if (v == 0)
            return (u32)0;
        u32 k = (u32)0;
        for (u32 i = (u32)0; i < v.byteLength(); i = i + (u32)1)
            k = k * (u32)10 + (u32)(v.byteAt(i) - (u8)'0');
        return k;
        }

    // Everything a format call gets, for a call whose format is kid `fmtIdx`.
    void formatCallAt(Node* call, u32 fmtIdx, String* callName)
        {
        checkFormatAt(call, fmtIdx, callName);
        rewriteFormatAt(call, fmtIdx);
        promoteFormatAt(call, fmtIdx);
        }

    void promoteFormat(Node* call, String* owner)
        {
        u32 fmtIdx = formatIndex(call, owner);
        if (fmtIdx != (u32)0)
            promoteFormatAt(call, fmtIdx);
        }

    // C's default argument promotions for a format call's variadic tail, on
    // every call, literal format or not: an integer narrower than `int` is
    // passed as an `int`, and a float as a double. The formatter reads
    // exactly those.
    void promoteFormatAt(Node* call, u32 fmtIdx)
        {
        u32 intW = fmtIntWidth();
        // A literal format's `%e` given an enum prints the member's name,
        // which the lowering finds by the argument's enum type — so that one
        // stays. Marked by kid index.
        Map* names = new Map();
        Node* lit = call.kidCount() > fmtIdx ? call.kid(fmtIdx) : (Node*)0;
        if (lit != 0 && lit.kind() == (u16)nkStr && lit.name() != 0)
            {
            u32 va = fmtIdx + (u32)1;
            u32 sp[7];
            sp[6] = (u32)0;
            while (fmtNext(lit.name(), &sp[0]))
                {
                if (fmtKind(sp[4]) == (u32)0)
                    continue;
                va = va + sp[5];
                if (sp[4] == (u32)'e')
                    names.set((Hashable*)String.withU32(va), (Object*)String.withU32(va));
                va = va + (u32)1;
                }
            }
        for (u32 i = fmtIdx + (u32)1; i < call.kidCount(); i = i + (u32)1)
            {
            Node* a = call.kid(i);
            String* at = a.ty();
            String* to = 0;
            if (at != 0 && Types.isEnumName(at) && names.get((Hashable*)String.withU32(i)) != 0)
                continue;
            if (at != 0 && fmtIsInt(at) && Types.byteWidth(at) < intW)
                to = String.withCString(intW == (u32)2 ? "i16" : "i32");
            else if (at != 0 && _isOp(at, "float"))
                to = String.withCString("double");
            if (to == 0)
                continue;
            Node* c = castTo(to, a);
            c.setTy(to);
            call.setKid(i, c);
            }
        }

    // `u8 f(u8 a, u16 b)` is `u8(u8,u16)`; as a BOUND method the same shape
    // wears a `$bound_` prefix, which is how the type table names the
    // {receiver, code} pair.
    String* signatureOf(Node* decl, bool bound)
        {
        String* s = String.withCString(bound ? "$bound_" : "");
        s.append(decl.op() == 0 ? String.withCString("void") : decl.op());
        s.appendByte((u8)'(');
        u32 k = (u32)0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* p = decl.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            if (k > (u32)0)
                s.appendByte((u8)',');
            s.append(p.op());
            k = k + (u32)1;
            }
        // A variadic function carries `...` in its PLAIN type spelling
        // (`void(u8*,...)`) — the reference does, and `&emit` renders it in the
        // sema dump. A BOUND type never does: a `^` is a fixed-arity pair (bug
        // 165c), so only the non-bound spelling takes the marker. IR is
        // unaffected — a function type lowers to Ptr(Void) either way.
        if (!bound && decl.hasFlag((u32)NF_VARARGS))
            {
            if (k > (u32)0)
                s.appendByte((u8)',');
            s.appendCString("...");
            }
        s.appendByte((u8)')');
        return s;
        }

    // A MULTI-RETURN function's type, at a call site, is its FIRST return
    // type — `(A@, B@) f()` used as a value is an A@. The tuple as a whole
    // only exists at the unpacking site, which is a statement, not an
    // expression.
    // Only a comma outside <>, () and [] separates two: `Map<String, Map>*`
    // is one type.
    String* firstReturn(String* spelling)
        {
        if (spelling == 0)
            return spelling;
        i32 depth = (i32)0;
        for (u32 i = (u32)0; i < spelling.byteLength(); i = i + (u32)1)
            {
            u8 b = spelling.byteAt(i);
            if (b == (u8)'<' || b == (u8)'(' || b == (u8)'[')
                depth = depth + (i32)1;
            else if ((b == (u8)'>' || b == (u8)')' || b == (u8)']') && depth > (i32)0)
                depth = depth - (i32)1;
            else if (b == (u8)',' && depth == (i32)0)
                return spelling.substringBytes((u32)0, i);
            }
        return spelling;
        }

    // ── Type-shape helpers ──────────────────────────────────────────────
    bool isArrayLike(String* t)
        {
        if (t == 0)
            return false;
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            if (t.byteAt(i) == (u8)'[')
                return true;
        return false;
        }

    // `T@` -> `T`; anything else unchanged (a bare `pointer` has no pointee).
    String* pointeeOf(String* t)
        {
        if (t == 0 || t.byteLength() == (u32)0)
            return t;
        if (t.byteAt(t.byteLength() - (u32)1) == (u8)'*')
            {
            String* inner = t.substringBytes((u32)0, t.byteLength() - (u32)1);
            // The qualifier described the POINTER — where it pointed — so what
            // comes out of a dereference does not carry it: `@(banked:u16@)` is
            // a plain u16.
            if (!Types.isPointer(inner))
                return Vtable.canonical(inner);
            return inner;
            }
        return t;
        }

    // `T[N]` -> `T`, `T@` -> `T`: indexing an array and indexing through a
    // pointer are the same question.
    String* elementOf(String* t)
        {
        if (t == 0)
            return t;
        String* raw = t;
        for (u32 i = (u32)0; i < raw.byteLength(); i = i + (u32)1)
            {
            if (raw.byteAt(i) == (u8)'[')
                {
                String* e = raw.substringBytes((u32)0, i);
                // A placement qualifier belongs to a POINTER, not to a scalar:
                // `banked:Leaf@[]` yields a `banked:Leaf@` (the qualifier is
                // part of the pointer's identity), while `banked:u8[]` yields a
                // plain `u8` (the qualifier described where the ARRAY lives).
                if (Types.isPointer(e))
                    return e;
                return Vtable.canonical(e);
                }
            }
        return pointeeOf(Vtable.canonical(raw));
        }

    // The class or struct a receiver spelling names: `K@` -> `K`, `K` -> `K`.
    String* classNameOf(String* t)
        {
        String* base = pointeeOf(t);
        for (u32 i = (u32)0; i < base.byteLength(); i = i + (u32)1)
            if (base.byteAt(i) == (u8)':')
                return base.substringBytes(i + (u32)1, base.byteLength() - i - (u32)1);
        return base;
        }

    // A member that does not resolve still gets a type: u8, the original's
    // fallback. It reads like sloppiness and is not — the diagnostic is what
    // stops the compile (a misspelled ivar used to resolve silently to u8 and
    // the store was dropped, which is the bug tests/fixtures/member_typo_ivar
    // exists for), and the tree still has to be typed for the passes that walk
    // it afterwards.
    String* fieldOrU8(Node* owner, String* field)
        {
        return fieldOrU8At(owner, field, (Node*)0, false);
        }

    // The same, but NAMING the owner, the member and the members that do
    // exist, positioned at the access. This said a bare "no such member" — no
    // type, no member, no file, no line — while the reference had always
    // printed `struct 'P' has no field 'zzz' (has: x)` / `class 'K' has no
    // ivar 'zzz' (has: a)`. diag-diff never noticed because it only ever asked
    // whether the PORT rejected the file, never what either compiler said
    // (bug 209). A class lists inherited ivars too, as the reference does.
    String* fieldOrU8At(Node* owner, String* field, Node* at, bool isClass)
        {
        String* t = fieldType(owner, field);
        if (t != 0)
            return t;
        String* known = String.withCString("");
        u32 n = (u32)0;
        for (Node* c = owner; c != 0; c = isClass ? parentOf(c) : (Node*)0)
            {
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                {
                Node* f = c.kid(i);
                if (f.kind() != (u16)nkVariableDecl || f.name() == 0)
                    continue;
                if (n > (u32)0)
                    known.appendCString(", ");
                known.append(f.name());
                n = n + (u32)1;
                }
            }
        String* tail = String.withCString("");
        if (n > (u32)0)
            {
            tail.appendCString(" (has: ");
            tail.append(known);
            tail.appendCString(")");
            }
        String* msg = isClass
                          ? String.withFormat("class '%s' has no ivar '%s'%s",
                                              owner.name().cString(), field.cString(), tail.cString())
                          : String.withFormat("struct '%s' has no field '%s'%s",
                                              owner.name().cString(), field.cString(), tail.cString());
        if (at != 0)
            _errorAt(msg, at);
        else
            _error(msg);
        return String.withCString("u8");
        }

    String* fieldType(Node* owner, String* field)
        {
        for (u32 i = (u32)0; i < owner.kidCount(); i = i + (u32)1)
            {
            Node* f = owner.kid(i);
            if (f.kind() != (u16)nkVariableDecl)
                continue;
            if (f.name() != 0 && f.name().equals(field))
                return f.op();
            }
        return (String*)0;
        }

    // Would a `use`-promoted static method resolve this bare call — with a
    // real conversion, not the single-candidate courtesy? Side-effect free.
    // It applies inside a class body too, as the use list does (bug 145): a
    // block literal is a method of a synthesised class, and gating this on
    // being outside one let libc's auto-imported `printf` claim a bare
    // `printf` in a block or method on arm9 (bug 361). A name the enclosing
    // class chain declares is member scope, not a use-promoted call (bug 147).
    bool usePromotedMatch(Node* call)
        {
        if (classChainDeclares(call.name()))
            return false;
        for (u32 i = (u32)0; i < _used.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)_classes.get((Hashable*)(String*)_used.get(i));
            if (cls == 0)
                continue;
            Array* group = new Array();
            for (u32 k = (u32)0; k < cls.kidCount(); k = k + (u32)1)
                {
                Node* m = cls.kid(k);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.name() != 0 && m.name().equals(call.name()))
                    group.add((Object*)m);
                }
            if (group.count() == (u32)0)
                continue;
            if (pickOverload(group, call, (u32)0) != 0)
                return true;
            }
        return false;
        }

    // Is a call of this name, in the method being compiled, the free function
    // it wraps? Only when the method calls its OWN name and a free function of
    // that name can be what it wraps: one with no body (a C function, an
    // extern) or one defined in the method's own file. A program's own
    // `i32 compare(i32, i32, i32)` captured `String.compare(Object*)`'s call to
    // its sibling `compare(String*)`, and building the standard library failed
    // inside it (2026-10-24). As the reference.
    bool wrapsFree(String* name)
        {
        if (name == 0 || _curMethod == 0 || _curMethod.name() == 0 || !name.equals(_curMethod.name()))
            return false;
        Array* group = (Array*)_functions.get((Hashable*)name);
        if (group == 0)
            return false;
        String* here = _curMethod.file();
        for (u32 i = (u32)0; i < group.count(); i = i + (u32)1)
            {
            Node* fn = (Node*)group.get(i);
            bool body = false;
            for (u32 k = (u32)0; k < fn.kidCount(); k = k + (u32)1)
                if (fn.kid(k).kind() == (u16)nkBlock)
                    body = true;
            bool beside = here != (String*)0 && fn.file() != (String*)0 && fn.file().equals(here);
            if (!body || beside)
                return true;
            }
        return false;
        }

    // Does the class being compiled, or an ancestor, declare a method of this
    // name? A method naming ITSELF does not count when that is how a wrapper
    // reaches the free function it wraps (`Math.sqrt` calling `sqrt`).
    bool classChainDeclares(String* name)
        {
        if (name == 0 || _curClass == 0)
            return false;
        if (wrapsFree(name))
            return false;
        for (Node* c = _curClass; c != 0; c = parentOf(c))
            for (u32 k = (u32)0; k < c.kidCount(); k = k + (u32)1)
                {
                Node* m = c.kid(k);
                if (m.kind() == (u16)nkMethodDecl && m.name() != 0 && m.name().equals(name))
                    return true;
                }
        return false;
        }

    // The arguments a call supplies. A method call's first child is its
    // receiver, so `argBase` is 1 there and 0 for a free call.
    u32 callArgc(Node* call, u32 argBase)
        {
        return call.kidCount() > argBase ? call.kidCount() - argBase : (u32)0;
        }

    // A `...` declaration takes AT LEAST its fixed parameters; any other
    // takes exactly them.
    bool arityFits(Node* decl, u32 argc)
        {
        u32 pc = paramCount(decl);
        return decl.hasFlag((u32)NF_VARARGS) ? (argc >= pc) : (argc == pc);
        }

    // `'K.m' takes 1 argument; 0 given` — the reference's wording. A call
    // whose count does not match its only candidate is refused: accepted, it
    // passes the wrong number of values and the callee reads its parameters
    // from whatever the registers or the stack hold.
    void reportArity(String* label, bool varargs, u32 fixed, u32 given, Node* at)
        {
        String* msg = String.withCString("'");
        msg.append(label);
        msg.appendCString("' takes ");
        if (varargs)
            msg.appendCString("at least ");
        msg.appendFormat("%lu", fixed);
        msg.appendCString(fixed == (u32)1 ? " argument; " : " arguments; ");
        msg.appendFormat("%lu", given);
        msg.appendCString(" given");
        _errorAt(msg, at);
        }

    // The same test on a resolved candidate. False (and reported) when the
    // count does not fit; the call is then typed u8, the reference's fallback.
    bool checkArity(Node* decl, Node* call, u32 argBase, String* label)
        {
        u32 argc = callArgc(call, argBase);
        if (arityFits(decl, argc))
            return true;
        reportArity(label, decl.hasFlag((u32)NF_VARARGS), paramCount(decl), argc, call);
        call.setTy(String.withCString("u8"));
        return false;
        }

    // A single candidate taken although it scored as a misfit — a free
    // function, a method, an implicit-self or a protocol call — still has its
    // class-pointer arguments checked: a width or scalar-kind difference is a
    // conversion, but a `B*` where an unrelated `A*` is declared is not, and
    // the callee would read B's fields at A's offsets (bug 320). An ancestor
    // stays legal (checkClassPointerArgAt). Positioned at the call, as the
    // reference places it.
    void checkMisfitArgs(Node* decl, Node* call, u32 argBase, String* callee)
        {
        if (scoreCandidate(decl, call, argBase) != Overload.noMatch())
            return;
        u32 pi = (u32)0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* p = decl.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            u32 ai = argBase + pi;
            pi = pi + (u32)1;
            if (ai >= call.kidCount())
                break;
            Node* a = call.kid(ai);
            if (a.ty() == 0 || p.op() == 0)
                continue;
            // A bound method is TWO words and has no single-word slot to
            // arrive in — a C function in particular cannot take one.
            if (isBoundSignature(a.ty()) && !isBoundSignature(p.op()))
                {
                String* e = String.withCString("argument ");
                e.append(String.withU32(pi));
                e.appendCString(" of '");
                e.append(callee);
                e.appendCString("': cannot pass a bound method ('^') where '");
                e.append(p.op());
                e.appendCString("' is expected — a '^' is two words and has no "
                                "equivalent there (a C function cannot take one). "
                                "Pass a plain function pointer ('@').");
                _errorAt(e, call);
                continue;
                }
            String* site = String.withCString("argument ");
            site.append(String.withU32(pi));
            site.appendCString(" of '");
            site.append(callee);
            site.appendByte((u8)0x27);
            checkClassPointerArgAt(p.op(), a.ty(), a, site.cString(), call);
            }
        }

    // `C*, u8` — the argument types as a diagnostic lists them.
    String* describeArgTypes(Node* call, u32 argBase)
        {
        String* s = String.withCString("");
        for (u32 i = argBase; i < call.kidCount(); i = i + (u32)1)
            {
            if (i > argBase)
                s.appendCString(", ");
            Node* a = call.kid(i);
            String* t = scoreTy(a);
            if (a.kind() == (u16)nkInt && a.nilLit())
                s.appendCString("nil");
            else
                s.append(t != 0 ? t : String.withCString("?"));
            }
        return s;
        }

    // The parameter spellings of a signature — `void(i32,u8*)` gives two,
    // `void()` and `void(void)` none, and a trailing `...` is kept as one.
    // Commas inside a nested signature or a generic argument list do not
    // separate.
    Array* signatureParams(String* sig)
        {
        Array* out = new Array();
        String* s = sig;
        if (s.hasPrefix(String.withCString("$wbound_")))
            s = s.substringFromByte((u32)8);
        else if (s.hasPrefix(String.withCString("$bound_")))
            s = s.substringFromByte((u32)7);
        u32 open = String.notFound();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (s.byteAt(i) == (u8)'(')
                {
                open = i;
                break;
                }
        if (open == String.notFound())
            return out;
        u32 depth = (u32)0;
        u32 start = open + (u32)1;
        for (u32 i = start; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)'(' || c == (u8)'<')
                depth = depth + (u32)1;
            else if ((c == (u8)')' || c == (u8)'>') && depth > (u32)0)
                depth = depth - (u32)1;
            else if ((c == (u8)',' || c == (u8)')') && depth == (u32)0)
                {
                String* p = s.substringBytes(start, i - start).trimmed();
                if (p.byteLength() > (u32)0 && !_isOp(p, "void"))
                    out.add((Object*)p);
                start = i + (u32)1;
                if (c == (u8)')')
                    break;
                }
            }
        return out;
        }

    // A call through a function pointer or a bound method has no candidate
    // to choose, but its signature still fixes the count.
    bool checkSignatureArity(String* sig, Node* call, String* label)
        {
        Array* ps = signatureParams(sig);
        u32 fixed = ps.count();
        bool va = fixed > (u32)0 && _isOp((String*)ps.get(fixed - (u32)1), "...");
        if (va)
            fixed = fixed - (u32)1;
        u32 argc = (u32)call.num();
        if (va ? (argc >= fixed) : (argc == fixed))
            return true;
        reportArity(label, va, fixed, argc, call);
        call.setTy(String.withCString("u8"));
        return false;
        }

    // Every method of `cls` with the call's name, then the same choice a free
    // call makes.
    Node* methodOverload(Node* cls, Node* call, u32 argBase)
        {
        Array* group = new Array();
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* m = cls.kid(i);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (m.name() == 0 || !m.name().equals(call.name()))
                continue;
            // An operator resolved to one method; only it is a candidate.
            if (_opPick != 0 && m != _opPick)
                continue;
            // --migrate: a member newer than the base is not in scope at all,
            // so a REUSED name resolves to nothing and reports, instead of
            // silently meaning something different than it did.
            if (!memberVisibleUnderMigrate(m, cls, call))
                continue;
            group.add((Object*)m);
            }
        if (group.count() == (u32)0)
            return (Node*)0;
        if (group.count() == (u32)1)
            return (Node*)group.get((u32)0);
        return pickOverload(group, call, argBase);
        }

    // A `new` whose arguments match no init. The lowering runs an init ONLY
    // when sema stamped a symbol, so an unmatched `new` allocates and runs
    // nothing: every field reads back zero while the program compiles clean.
    // That is bug 218, and leaving the diagnostic to the original left the
    // SHIPPED compiler still accepting it (diag-diff: new_init_arity_refused
    // ACCEPTED, exit 0).
    void reportUnmatchedInit(Node* cls, Node* newExpr)
        {
        // `new T[N]` parks the COUNT in a kid and never calls setNum, where
        // `new T(a, b)` sets it to the argument count. So the arguments are
        // num(), not kidCount(), and an array allocation — which runs the init
        // per element and passes it nothing — has kids with num() still zero.
        // Reading kidCount here reported the array LENGTH as an argument and
        // refused `new Tracker[6]`.
        bool arrayForm = newExpr.kidCount() > (u32)0 && newExpr.num() == (i64)0;
        if (arrayForm)
            return;
        u32 argc = (u32)newExpr.num();
        // ZERO arguments is the allocate-and-zero form and is always legal,
        // whatever inits the class declares — code here uses it deliberately
        // before initialising by hand:
        //     Rect* r = new Rect();  r.init(10, 20, 30, 40);
        if (argc == (u32)0)
            return;
        Node* owner = (Node*)0;
        for (Node* c = cls; c != 0 && owner == 0; c = parentOf(c))
            {
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                {
                Node* m = c.kid(i);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.name() != 0 && _isOp(m.name(), "init"))
                    {
                    owner = c;
                    break;
                    }
                }
            }
        // Only an argument list that matches no init BY ARITY is an error.
        // When the arity matches and the port still stamps nothing, the cause
        // is pickOverload declining to choose between candidates on type score
        // — `new Gfx8(4)` against init(u8) and init(u8*) — where the original
        // scores them and picks one. That is a pre-existing difference in
        // overload resolution, not a bad `new`, and reporting it here said
        // "supplies 1 argument, but 'Gfx8.init' takes 1".
        if (owner != 0)
            {
            for (u32 i = (u32)0; i < owner.kidCount(); i = i + (u32)1)
                {
                Node* m = owner.kid(i);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.name() == 0 || !_isOp(m.name(), "init"))
                    continue;
                u32 pc = paramCount(m);
                if (m.hasFlag((u32)NF_VARARGS) ? (argc >= pc) : (argc == pc))
                    return;
                }
            }
        String* cn = cls.name() != 0 ? cls.name() : String.withCString("?");
        String* msg = String.withCString("`new ");
        msg.append(cn);
        msg.appendCString("(...)` supplies ");
        msg.appendFormat("%lu", argc);
        msg.appendCString(argc == (u32)1 ? " argument" : " arguments");
        if (owner != 0)
            {
            msg.appendCString(", but '");
            msg.append(owner.name() != 0 ? owner.name() : cn);
            msg.appendCString(".init' takes ");
            bool first = true;
            for (u32 i = (u32)0; i < owner.kidCount(); i = i + (u32)1)
                {
                Node* m = owner.kid(i);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.name() == 0 || !_isOp(m.name(), "init"))
                    continue;
                if (!first)
                    msg.appendCString(" or ");
                msg.appendFormat("%lu", paramCount(m));
                first = false;
                }
            msg.appendCString(". An allocation that matches no init would leave "
                              "every field uninitialised.");
            _errorAt(msg, newExpr);
            return;
            }
        msg.appendCString(", but '");
        msg.append(cn);
        msg.appendCString("' declares no init. Add one, or write `new ");
        msg.append(cn);
        msg.appendCString("()`.");
        _errorAt(msg, newExpr);
        }

    Node* initOverload(Node* cls, Node* newExpr)
        {
        // A class that declares any init owns its construction interface; one
        // that declares none inherits its parent's, the way it inherits every
        // other method. So take the candidates from the nearest class in the
        // chain that declares an init.
        //
        // Scanning this class alone left `new Sub(7)` with nothing stamped,
        // and the lowering runs an init ONLY when a symbol was stamped
        // (Lower.xc, `if (n.sym() != 0) runInit(...)`). So no initialiser ran
        // and every field read back zero. runInit walks the parents itself to
        // turn the stamped mangled name into the declaring class's symbol, so
        // the lowering needs nothing.
        //
        // synthesiseInits() covers only the case where an ancestor has a
        // NO-ARG init; a parent init that takes arguments has no synthesised
        // forwarder and reaches construction through here.
        Node* owner = (Node*)0;
        for (Node* c = cls; c != 0 && owner == 0; c = parentOf(c))
            {
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                {
                Node* m = c.kid(i);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.name() != 0 && _isOp(m.name(), "init"))
                    {
                    owner = c;
                    break;
                    }
                }
            }
        if (owner == 0)
            return (Node*)0;
        Array* group = new Array();
        for (u32 i = (u32)0; i < owner.kidCount(); i = i + (u32)1)
            {
            Node* m = owner.kid(i);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (m.name() != 0 && _isOp(m.name(), "init"))
                group.add((Object*)m);
            }
        if (group.count() == (u32)0)
            return (Node*)0;
        return pickOverload(group, newExpr, (u32)0);
        }

    Node* methodNamed(Node* cls, String* name)
        {
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* m = cls.kid(i);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (m.name() != 0 && m.name().equals(name))
                return m;
            }
        return (Node*)0;
        }

    bool isArithmetic(String* op)
        {
        return _isOp(op, "+") || _isOp(op, "-") || _isOp(op, "*") || _isOp(op, "/") || _isOp(op, "%");
        }

    bool _isOp(String* s, string lit)
        {
        if (s == 0)
            return false;
        u32 i = (u32)0;
        while (lit[i] != (u8)0)
            {
            if (i >= s.byteLength())
                return false;
            if (s.byteAt(i) != lit[i])
                return false;
            i = i + (u32)1;
            }
        return i == s.byteLength();
        }

    // ── Scopes ──────────────────────────────────────────────────────────
    void pushScope(void)
        {
        _scopes.add((Object*)new Map());
        }
    void popScope(void)
        {
        if (_scopes.count() > (u32)0)
            _scopes.removeLast();
        }

    void define(String* name, String* spelling)
        {
        if (name == 0 || spelling == 0 || _scopes.count() == (u32)0)
            return;
        Map* top = (Map*)_scopes.get(_scopes.count() - (u32)1);
        top.set((Hashable*)name, (Object*)spelling);
        }

    String* lookup(String* name)
        {
        if (name == 0)
            return (String*)0;
        u32 i = _scopes.count();
        while (i > (u32)0)
            {
            i = i - (u32)1;
            Map* sc = (Map*)_scopes.get(i);
            String* t = (String*)sc.get((Hashable*)name);
            if (t != 0)
                return t;
            }
        return (String*)_globals.get((Hashable*)name);
        }

    // Every class that does not write its own `description()` gets one built
    // for it, because Stdio.printf's `%@` dispatches through it. Unlike the
    // synthesised init this one has a REAL body, so the port has to build the
    // same statements node for node:
    //
    //     String@ description(void) {
    //         u16@ vals = new u16[(u16)N];
    //         vals[0] = (u16)ivar0;  …
    //         return String._classDescribe("Name", vals, (u8)N, (u8)signedMask);
    //     }
    //
    // Only integer ivars are included (a pointer or a float has no u16 slot),
    // a class with none gets nothing, and the whole thing is skipped unless
    // String is in scope — there would be nothing to call. Object and String
    // are excluded: one IS the root, the other would call back into itself.
    void synthesiseDescriptions(void)
        {
        if (_classes.get((Hashable*)String.withCString("String")) == 0)
            return;
        Array* names = _classes.allKeys();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* cn = (String*)names.get(i);
            if (_isOp(cn, "Object") || _isOp(cn, "String"))
                continue;
            Node* cls = (Node*)_classes.get((Hashable*)cn);
            if (Vtable.zeroArgNamed(cls, "description") != 0)
                continue;

            Array* ivars = new Array();
            u32 mask = (u32)0;
            for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
                {
                Node* iv = cls.kid(j);
                if (iv.kind() != (u16)nkVariableDecl)
                    continue;
                if (iv.hasFlag((u32)NF_STATIC))
                    continue;
                // An enum is an integer type (an unsigned byte), as it is to
                // the original's isInteger; leaving it out gave a class whose
                // only integer ivar is an enum no description (bug 523).
                if (!Types.isInteger(iv.op()) && !Types.isEnumName(iv.op()))
                    continue;
                if (ivars.count() < (u32)8 && Types.isSigned(iv.op()))
                    mask = mask | ((u32)1 << ivars.count());
                ivars.add((Object*)iv);
                }
            if (ivars.count() == (u32)0)
                continue;
            cls.add(descriptionBody(cn, ivars, mask));
            }
        }

    Node* descriptionBody(String* clsName, Array* ivars, u32 mask)
        {
        // A SYNTHESISED method has no source file, and anything that reports a
        // position for it — a diagnostic, or -fbounds-check naming a site —
        // needs something to print. The reference calls it
        // `<synth-description>`; saying `?` instead made every such site
        // string differ between the two compilers.
        u32 synthFile = FileTable.idFor(String.withCString("<synth-description>"));
        Node* m = Node.withName((u16)nkMethodDecl, String.withCString("description"));
        m.setPos(synthFile, (u32)0, (u32)0);
        m.setOp(String.withCString("String*"));
        m.setSym(String.withCString("description"));
        Node* body = Node.with((u16)nkBlock);
        body.setPos(synthFile, (u32)0, (u32)0);

        // `u16@ vals = new u16[(u16)N];`
        Node* decl = Node.withName((u16)nkVariableDecl, String.withCString("vals"));
        decl.setOp(String.withCString("u16*"));
        Node* nw = Node.withName((u16)nkNew, String.withCString("u16"));
        nw.add(castTo(String.withCString("u16"), intLit((i64)ivars.count())));
        decl.add(nw);
        body.add(decl);

        // `vals[i] = (u16)ivar;`
        for (u32 i = (u32)0; i < ivars.count(); i = i + (u32)1)
            {
            Node* sub = Node.with((u16)nkSubscript);
            sub.setPos(synthFile, (u32)0, (u32)0);
            sub.add(identNode(String.withCString("vals")));
            sub.add(intLit((i64)i));
            Node* asn = Node.with((u16)nkAssign);
            asn.setPos(synthFile, (u32)0, (u32)0);
            asn.setOp(String.withCString("="));
            asn.add(sub);
            asn.add(castTo(String.withCString("u16"),
                           identNode(((Node*)ivars.get(i)).name())));
            Node* st = Node.with((u16)nkExprStatement);
            st.setPos(synthFile, (u32)0, (u32)0);
            st.add(asn);
            body.add(st);
            }

        // `return String._classDescribe(name, vals, (u8)N, (u8)mask);`
        Node* call = Node.withName((u16)nkMethodCall, String.withCString("_classDescribe"));
        call.setNum((i64)4);
        call.add(identNode(String.withCString("String")));
        Node* lit = Node.withName((u16)nkStr, clsName);
        call.add(lit);
        call.add(identNode(String.withCString("vals")));
        call.add(castTo(String.withCString("u8"), intLit((i64)ivars.count())));
        call.add(castTo(String.withCString("u8"), intLit((i64)mask)));
        Node* ret = Node.with((u16)nkReturn);
        ret.setPos(synthFile, (u32)0, (u32)0);
        ret.add(call);
        body.add(ret);

        m.add(body);
        return m;
        }

    Node* identNode(String* name)
        {
        return Node.withName((u16)nkIdent, name);
        }

    Node* intLit(i64 v)
        {
        Node* n = Node.with((u16)nkInt);
        n.setNum(v);
        return n;
        }

    Node* castTo(String* ty, Node* operand)
        {
        Node* c = Node.withName((u16)nkCast, ty);
        c.add(operand);
        return c;
        }

    // A class that declares NO init at all, but has an ancestor with a no-arg
    // one, gets an empty init synthesised — its body IS the chain to the
    // ancestor, which is why it is born with autoSuperInit set. The node goes
    // into the tree, so the dump shows it; that is the point, since the
    // lowering has to emit it.
    void synthesiseInits(void)
        {
        Array* names = _classes.allKeys();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)_classes.get((Hashable*)names.get(i));
            bool declares = false;
            for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
                {
                Node* m = cls.kid(j);
                if (m.kind() == (u16)nkMethodDecl && m.name() != 0 && _isOp(m.name(), "init"))
                    declares = true;
                }
            if (declares)
                continue;
            bool inherited = false;
            for (Node* a = parentOf(cls); a != 0; a = parentOf(a))
                if (Vtable.zeroArgNamed(a, "init") != 0)
                    inherited = true;
            if (!inherited)
                continue;
            Node* synth = Node.withName((u16)nkMethodDecl, String.withCString("init"));
            synth.setOp(String.withCString("void"));
            synth.setSym(String.withCString("init"));
            synth.setAutoSuperInit();
            synth.addFlag((u32)NF_SYNTH);
            // At the class's position, method and body both, as the
            // reference builds them — -g attributes the init to it.
            synth.setPos(cls.fileId(), cls.line(), cls.col());
            Node* sbody = Node.with((u16)nkBlock);
            sbody.setPos(cls.fileId(), cls.line(), cls.col());
            synth.add(sbody);
            cls.add(synth);
            }
        }

    // An `init` that does not call `super.init()` itself gets the call
    // injected, provided an ancestor HAS a no-argument init to call. The flag
    // is what tells the lowering to inject it.
    void markAutoSuperInit(void)
        {
        Array* names = _classes.allKeys();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)_classes.get((Hashable*)names.get(i));
            Node* parent = parentOf(cls);
            if (parent == 0)
                continue;
            // Whether the nearest ancestor that has an init at all has one
            // with no arguments: that is the one the chain can run unasked.
            // The reference stops at that ancestor; a no-arg init further up
            // is not reachable through an init that takes arguments.
            bool anyAncestorInit = false;
            bool noArgInit = false;
            for (Node* a = parent; a != 0 && !anyAncestorInit; a = parentOf(a))
                for (u32 q = (u32)0; q < a.kidCount(); q = q + (u32)1)
                    {
                    Node* pm = a.kid(q);
                    if (pm.kind() != (u16)nkMethodDecl || pm.name() == 0 || !_isOp(pm.name(), "init") || pm.hasFlag((u32)NF_STATIC))
                        continue;
                    anyAncestorInit = true;
                    if (Vtable.zeroArgNamed(a, "init") == pm)
                        noArgInit = true;
                    }
            for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
                {
                Node* m = cls.kid(j);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.hasFlag((u32)NF_STATIC))
                    continue;
                // dealloc: one super.dealloc at most (the runtime adds the
                // chain where the author wrote none).
                if (m.name() != 0 && _isOp(m.name(), "dealloc"))
                    {
                    if (countSuperCalls(m, "dealloc") > (u32)1)
                        _errorAt(String.withFormat("duplicate super.dealloc call in '%s.dealloc'", cls.name().cString()), m);
                    continue;
                    }
                if (m.name() == 0 || !_isOp(m.name(), "init"))
                    continue;
                u32 calls = countSuperCalls(m, "init");
                if (calls > (u32)1)
                    {
                    _errorAt(String.withFormat("duplicate super.init call in '%s.init'", cls.name().cString()), m);
                    continue;
                    }
                if (calls == (u32)1)
                    continue;
                if (noArgInit)
                    m.setAutoSuperInit();
                else if (anyAncestorInit)
                    _errorAt(String.withFormat("init on '%s' must call super.init(...) — parent chain has no no-arg init", cls.name().cString()), m);
                }
            }
        }

    // How many `super.<name>(...)` calls a body holds, at any depth.
    u32 countSuperCalls(Node* n, string name)
        {
        if (n == 0)
            return (u32)0;
        u32 c = (u32)0;
        if (n.kind() == (u16)nkMethodCall && n.name() != 0 && _isOp(n.name(), name) && n.kidCount() > (u32)0)
            {
            Node* r = n.kid((u32)0);
            if (r.kind() == (u16)nkIdent && r.name() != 0 && _isOp(r.name(), "super"))
                c = c + (u32)1;
            }
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            c = c + countSuperCalls(n.kid(i), name);
        return c;
        }

    bool callsSuperInit(Node* n)
        {
        if (n == 0)
            return false;
        if (n.kind() == (u16)nkMethodCall && n.name() != 0 && _isOp(n.name(), "init") && n.kidCount() > (u32)0)
            {
            Node* r = n.kid((u32)0);
            if (r.kind() == (u16)nkIdent && r.name() != 0 && _isOp(r.name(), "super"))
                return true;
            }
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            if (callsSuperInit(n.kid(i)))
                return true;
        return false;
        }

    // A class's own table: every protocol it lists contributes its methods'
    // slots (when the class actually provides the method), and every override
    // root it participates in contributes its own. A class with no entries gets
    // no table at all — saying `vslots=0` would be a different claim from
    // saying nothing, and the original says nothing.
    // `_cls_<Class>_<key>` -> the class (and *key). A class name may hold
    // underscores (`_HttpJob`), so the split is the first underscore at which
    // the prefix is a class with a method of that key; with none, the first
    // underscore. 0 when the label is not a class label. The reference's
    // XTSplitClassLabel is the same rule.
    String* labelSplit(String* label, String** key)
        {
        if (!label.hasPrefix(String.withCString("_cls_")))
            return (String*)0;
        String* tail = label.substringFromByte((u32)5);
        u32 first = String.notFound();
        for (u32 i = (u32)0; i < tail.byteLength(); i = i + (u32)1)
            {
            if (tail.byteAt(i) != (u8)'_')
                continue;
            if (first == String.notFound())
                first = i;
            if (i == (u32)0)
                continue;
            String* c = tail.substringBytes((u32)0, i);
            String* k = tail.substringFromByte(i + (u32)1);
            Node* cls = (Node*)_classes.get((Hashable*)c);
            if (cls == 0)
                continue;
            for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
                {
                Node* m = cls.kid(j);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                String* mk = m.sym() == 0 ? m.name() : m.sym();
                if (mk != 0 && mk.equals(k))
                    {
                    *key = k;
                    return c;
                    }
                }
            }
        if (first == String.notFound())
            return (String*)0;
        *key = tail.substringFromByte(first + (u32)1);
        return tail.substringBytes((u32)0, first);
        }

    void stampClassSlots(void)
        {
        // A faithful mirror of the original's per-class fill (task #36, the
        // pristine-snapshot form): the ROOT loop walks the sorted root
        // labels — for a root this class descends from, the nearest
        // signature-matching impl claims the root's slot — then the PROTOCOL
        // loop walks the class chain in order, each class's protocol list in
        // DECLARATION order, filling only still-empty requirement slots. The
        // name map keeps a name the ROOT loop gave a slot (`equals` answers
        // at Object's root slot on every class); a name only a protocol
        // provides records the last protocol slot the sequence filled.
        // In SORTED label order, as the reference walks them: a library
        // build collects its roots parent-first, and the name map keeps the
        // last root to claim a name (`equals` is Number's own
        // `equals(Number@)` root and Object's), so the order decides it.
        Array* rlabs = new Array();
        Array* rl0 = _vt.rootLabels();
        for (u32 q = (u32)0; q < rl0.count(); q = q + (u32)1)
            rlabs.add(rl0.get(q));
        Vtable.sortStrings(rlabs);
        Array* names = _classes.allKeys();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)_classes.get((Hashable*)names.get(i));
            Map* mine = new Map();
            // The slot a call that RESOLVED to an impl symbol dispatches
            // through. `mine` cannot say it once a name is overloaded:
            // `f(i32)` and `f(double)` own two slots and one name remembers
            // only the last, so `a.f(1.5)` ran `f(i32)`'s body (bug 265).
            Map* msyms = new Map();
            // slot -> the impl symbol this class puts there, "" for none: the
            // table itself, as the reference fills it.
            Array* ssyms = new Array();
            for (u32 q = (u32)0; q < _vt.total(); q = q + (u32)1)
                ssyms.add((Object*)String.withCString(""));
            Map* filled = new Map(); // slot -> true, this class
            for (u32 li = (u32)0; li < rlabs.count(); li = li + (u32)1)
                {
                String* L = (String*)rlabs.get(li);
                if (_vt.isChainLabel(L))
                    continue;
                Object* slObj = _vt.slotForLabel(L);
                if (slObj == 0)
                    continue;
                String* rootKey = (String*)0;
                String* rootClsName = labelSplit(L, &rootKey);
                if (rootClsName == 0)
                    continue;
                Node* rootCls = (Node*)_classes.get((Hashable*)rootClsName);
                if (rootCls == 0)
                    continue;
                Node* rootMethod = (Node*)0;
                for (u32 k = (u32)0; k < rootCls.kidCount(); k = k + (u32)1)
                    {
                    Node* m = rootCls.kid(k);
                    if (m.kind() != (u16)nkMethodDecl)
                        continue;
                    String* key = m.sym() == 0 ? m.name() : m.sym();
                    if (key.equals(rootKey))
                        {
                        rootMethod = m;
                        k = rootCls.kidCount();
                        }
                    }
                if (rootMethod == 0)
                    continue;
                bool descends = false;
                Node* dc = cls;
                while (dc != 0)
                    {
                    if (dc == rootCls)
                        {
                        descends = true;
                        dc = (Node*)0;
                        }
                    else
                        {
                        dc = parentOf(dc);
                        }
                    }
                if (!descends)
                    continue;
                Node* impl = (Node*)0;
                Node* implCls = (Node*)0;
                Node* c2 = cls;
                while (c2 != 0)
                    {
                    Node* m2 = Vtable.matching(c2, rootMethod);
                    // A method returning what a SIBLING overload of the root
                    // returns overrides that sibling, not this root (bug 265).
                    if (m2 != 0 && c2 != rootCls && Vtable.overridesSibling(rootCls, rootMethod, m2))
                        m2 = (Node*)0;
                    if (m2 != 0)
                        {
                        impl = m2;
                        implCls = c2;
                        c2 = (Node*)0;
                        }
                    else if (c2 == rootCls)
                        {
                        c2 = (Node*)0;
                        }
                    else
                        {
                        c2 = parentOf(c2);
                        }
                    }
                if (impl == 0)
                    continue;
                mine.set((Hashable*)rootMethod.name(), slObj);
                msyms.set((Hashable*)implSymbol(implCls, impl), slObj);
                u32 sl = ((Number*)slObj).asU32();
                if (sl < ssyms.count())
                    ssyms.set(sl, (Object*)implSymbol(implCls, impl));
                filled.set((Hashable*)slObj, (Object*)Number.with((u32)1));
                }
            // Snapshot for the INTERFACE, taken between the two loops: what a
            // client needs is where a method dispatches ON THE CLASS, and the
            // protocol loop below rewrites a requirement's entry to the
            // PROTOCOL's slot — a different number, in a table the client's
            // class-typed call never indexes.
            Map* isnap = new Map();
            Array* mk0 = mine.allKeys();
            for (u32 q = (u32)0; q < mk0.count(); q = q + (u32)1)
                isnap.set((Hashable*)mk0.get(q), mine.get((Hashable*)mk0.get(q)));
            cls.setIfaceSlots(isnap);
            Map* rootSyms = new Map();
            Array* sk0 = msyms.allKeys();
            for (u32 q = (u32)0; q < sk0.count(); q = q + (u32)1)
                rootSyms.set((Hashable*)sk0.get(q), msyms.get((Hashable*)sk0.get(q)));
            cls.setIfaceSymSlots(rootSyms);
            // The ANCESTOR CHAIN, class first, each class's protocol list in
            // declaration order — NOT the class's own list alone.
            //
            // The reference has TWO protocol loops per class, and they walk
            // differently. The conformance pass
            // (XTSemanticAnalyzer+Analysis.m:1745) reads `cls.protocolNames`
            // only and writes the LABEL map — the number an interface
            // publishes. The vtable FILL (:1962) walks `c = cls; c = c.parent`
            // and writes `slots[]` and `nameSlot[]` — the table a class-typed
            // dispatch indexes. `mine` mirrors the FILL, so it walks the chain.
            //
            // A commit on 2026-09-02 (a9f40696) cut this to the own list,
            // citing the 1745 loop. It could not have moved bug 117's number —
            // IfaceWrite never reads `slots()` — and it cost the dispatch
            // side: `Box` lists nothing and inherits Object's Hashable and
            // Comparable, so the reference sends `box.equals(b)` through
            // Comparable's slot (3) and `box.hash()` through Hashable's (8),
            // while the own-list port kept the class roots (1, 2). Three
            // fixtures diverged in irwide-diff (`array_mutate`,
            // `collection_root_methods`, `foundation_object_default`) and the
            // same three end to end in xcc-diff on every target.
            //
            // Since bug 253 both compilers keep the class roots (1, 2) for a
            // class-typed call; the chain walk still decides which protocol
            // slots this class fills.
            //
            // The itable walk below keeps its own chain; table PRESENCE
            // (`listsProto`) is the one place the own list is right.
            for (Node* c3 = cls; c3 != 0; c3 = parentOf(c3))
                {
                String* protosStr = c3.extra();
                if (protosStr == 0)
                    continue;
                Array* list = protosStr.splitOnByte((u8)',');
                for (u32 j = (u32)0; j < list.count(); j = j + (u32)1)
                    {
                    String* pn = ((String*)list.get(j)).trimmed();
                    Map* ps = _vt.protoSlotsFor(pn);
                    if (ps == 0)
                        continue;
                    Node* proto = (Node*)_protocols.get((Hashable*)pn);
                    if (proto == 0)
                        continue;
                    for (u32 t = (u32)0; t < proto.kidCount(); t = t + (u32)1)
                        {
                        Node* reqM = proto.kid(t);
                        if (reqM.kind() != (u16)nkMethodDecl)
                            continue;
                        Object* pslot = ps.get((Hashable*)reqM.name());
                        if (pslot == 0)
                            continue;
                        if (filled.get((Hashable*)pslot) != 0)
                            continue;
                        if (!providesMatching(cls, reqM, reqM.name()))
                            continue;
                        // A CLASS-typed call keeps the class's own root slot
                        // (`isnap` is the root loop's map). A prelude
                        // protocol's slot number is not in a library's
                        // interface, so a client's subclass has something
                        // else at it (bug 253). The reference does the same.
                        if (isnap.get((Hashable*)reqM.name()) == 0)
                            mine.set((Hashable*)reqM.name(), pslot);
                        String* psym = nearestImplSymbol(cls, reqM);
                        if (psym != 0 && rootSyms.get((Hashable*)psym) == 0)
                            msyms.set((Hashable*)psym, pslot);
                        u32 psl = ((Number*)pslot).asU32();
                        if (psym != 0 && psl < ssyms.count())
                            ssyms.set(psl, (Object*)psym);
                        filled.set((Hashable*)pslot, (Object*)Number.with((u32)1));
                        }
                    }
                }
            // A class carries a table when it fills a slot, or when it LISTS a
            // protocol — a class that lists one it does not implement still has
            // the (empty) table. A class outside dispatch entirely has none.
            // Its OWN list, not an ancestor's: everything inherits from Object,
            // which lists Hashable and Comparable, so an inherited list would
            // give every class in every program a table.
            bool listsProto = cls.extra() != 0;
            if (_vt.total() == (u32)0)
                continue;
            if (mine.count() == (u32)0 && !listsProto)
                continue;
            cls.setSlots(mine, _vt.total());
            cls.setSymSlots(msyms);
            cls.setSlotSyms(ssyms);
            }
        }

    // `<Class>$<mangled>`, the symbol a method's body is emitted under.
    String* implSymbol(Node* cls, Node* m)
        {
        String* s = String.withString(cls.name());
        s.appendByte((u8)'$');
        s.append(m.sym() == 0 ? m.name() : m.sym());
        return s;
        }

    // The symbol of the nearest method from `cls` up whose signature matches
    // `want` — the body a protocol slot on `cls` holds — or null.
    String* nearestImplSymbol(Node* cls, Node* want)
        {
        for (Node* c = cls; c != 0; c = parentOf(c))
            {
            Node* m = Vtable.matching(c, want);
            if (m != 0)
                return implSymbol(c, m);
            }
        return (String*)0;
        }

    // ── §4.2/§4.3b: category-chain slot numbering ────────────────────────
    // A method a category added to a class from ANOTHER module cannot take a
    // vtable slot: that vtable is emitted inside someone else's image, and a
    // slot past its end reads into whatever follows. Such a method is numbered
    // in a CHAIN slot space of its own — per extended class, 0-based — and
    // only override roots need it at all. Mirrors the reference pass exactly,
    // including the ancestry walk ("keying off the label alone left a root
    // whose name sorts before its base in the vtable space").
    void computeChainSlots(void)
        {
        if (!_chainCapable)
            return;
        if (_catNamesByHost.count() == (u32)0)
            return;
        Map* slotOfHost = new Map(); // host -> Map(mangled -> Number)
        Array* hosts = _catNamesByHost.allKeys();
        Vtable.sortStrings(hosts);
        for (u32 hi = (u32)0; hi < hosts.count(); hi = hi + (u32)1)
            {
            String* host = (String*)hosts.get(hi);
            Node* hc = (Node*)_classes.get((Hashable*)host);
            if (hc == (Node*)0)
                continue;
            Array* names = new Array();
            for (u32 i = (u32)0; i < hc.kidCount(); i = i + (u32)1)
                {
                Node* m = hc.kid(i);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.importedCatHost() == 0)
                    continue;
                names.add((Object*)(m.sym() != 0 ? m.sym() : m.name()));
                }
            Vtable.sortStrings(names);
            Map* sl = new Map();
            for (u32 k = (u32)0; k < names.count(); k = k + (u32)1)
                sl.set((Hashable*)(String*)names.get(k), (Object*)Number.withU32(k));
            slotOfHost.set((Hashable*)host, (Object*)sl);
            _chainCountByHost.set((Hashable*)host, (Object*)Number.withU32(names.count()));
            // The §4.3b owner anchor: the fallback table's symbol, from the
            // sorted category names — the extender's identity at the linker.
            Array* cats = (Array*)_catNamesByHost.get((Hashable*)host);
            Vtable.sortStrings(cats);
            String* anchor = String.withString(host);
            anchor.appendCString("$cat");
            for (u32 c = (u32)0; c < cats.count(); c = c + (u32)1)
                {
                anchor.appendByte((u8)'$');
                anchor.append((String*)cats.get(c));
                }
            _chainAnchorByHost.set((Hashable*)host, (Object*)anchor);
            }
        // Every override root that IS such a method, or overrides one in an
        // ancestor: the ancestry walk decides, never the label's spelling.
        Array* roots = new Array();
        _vt.collectRoots(_classes, roots);
        for (u32 i = (u32)0; i < roots.count(); i = i + (u32)1)
            {
            String* rootLabel = (String*)roots.get(i);
            String* mangled = (String*)0;
            String* rootCls = labelSplit(rootLabel, &mangled);
            if (rootCls == 0)
                continue;
            for (Node* c = (Node*)_classes.get((Hashable*)rootCls); c != 0; c = parentOf(c))
                {
                Map* sl = (Map*)slotOfHost.get((Hashable*)c.name());
                if (sl == 0)
                    continue;
                Object* k = sl.get((Hashable*)mangled);
                if (k == 0)
                    continue;
                _chainSlotByLabel.set((Hashable*)rootLabel, k);
                _chainHostByLabel.set((Hashable*)rootLabel, (Object*)c.name());
                break;
                }
            }
        _vt.setChainLabels(_chainSlotByLabel);
        }

    // Per-class chain stamping for the lowering: the host in the ancestry, the
    // anchor, and method name -> chain slot (the impl symbol per slot resolves
    // in Lower, exactly as vtable slots do). An EXTERNAL family member other
    // than the host gets NO table — its vtable lives in its own module with a
    // null chain word, and two extenders would collide on the dead symbol.
    void stampChainSlots(void)
        {
        if (_chainSlotByLabel.count() == (u32)0)
            return;
        Array* names = _classes.allKeys();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)_classes.get((Hashable*)names.get(i));
            String* chainHost = (String*)0;
            Map* mine = new Map();
            Array* chain = new Array();
            for (Node* c = cls; c != 0; c = parentOf(c))
                chain.add((Object*)c);
            u32 ci = chain.count();
            while (ci > (u32)0)
                {
                ci = ci - (u32)1;
                Node* c = (Node*)chain.get(ci);
                for (u32 j = (u32)0; j < c.kidCount(); j = j + (u32)1)
                    {
                    Node* m = c.kid(j);
                    if (m.kind() != (u16)nkMethodDecl)
                        continue;
                    String* lbl = Vtable.label(c.name(), m);
                    Object* k = _chainSlotByLabel.get((Hashable*)lbl);
                    if (k == 0)
                        continue;
                    String* newHost = (String*)_chainHostByLabel.get((Hashable*)lbl);
                    if (chainHost != 0 && newHost != 0 && !chainHost.equals(newHost))
                        {
                        String* msg = String.withCString("Class '");
                        msg.append(cls.name());
                        msg.appendCString("' descends from two chain-extended classes");
                        _error(msg);
                        continue;
                        }
                    chainHost = newHost;
                    if (mine.get((Hashable*)m.name()) != 0)
                        continue;
                    mine.set((Hashable*)m.name(), k);
                    }
                }
            if (chainHost == 0)
                continue;
            if (cls.hasFlag((u32)NF_EXTERNAL) && !cls.name().equals(chainHost))
                continue;
            u32 n = ((Number*)_chainCountByHost.get((Hashable*)chainHost)).asU32();
            cls.setChain(chainHost,
                         (String*)_chainAnchorByHost.get((Hashable*)chainHost),
                         mine, n);
            }
        }

    Node* parentOf(Node* cls)
        {
        if (cls.name() != 0 && _cyclic.get((Hashable*)cls.name()) != 0)
            return (Node*)0;
        String* pn = Vtable.parentName(cls);
        if (pn == 0)
            return (Node*)0;
        if (cls.name() != 0 && pn.equals(cls.name()))
            return (Node*)0; // `class A : A`
        return (Node*)_classes.get((Hashable*)pn);
        }

    // Walk each class's parents with a step limit; anything still walking past
    // the number of classes in the program is in a loop.
    // className -> parent name, for the overload ranker's upcast rule.
    Map* parentMap(void)
        {
        Map* m = new Map();
        Array* names = _classes.allKeys();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Node* c = (Node*)_classes.get((Hashable*)names.get(i));
            Node* p = parentOf(c);
            if (p != 0 && p.name() != 0)
                m.set((Hashable*)(String*)names.get(i), (Object*)p.name());
            }
        return m;
        }

    // className -> every protocol it lists, its ancestors' included.
    Map* conformanceMap(void)
        {
        Map* m = new Map();
        Array* names = _classes.allKeys();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Node* c = (Node*)_classes.get((Hashable*)names.get(i));
            String* all = String.withCString("");
            for (Node* a = c; a != 0; a = parentOf(a))
                {
                if (a.extra() == 0)
                    continue;
                if (all.byteLength() > (u32)0)
                    all.appendByte((u8)',');
                all.append(a.extra());
                }
            if (all.byteLength() > (u32)0)
                m.set((Hashable*)(String*)names.get(i), (Object*)all);
            }
        return m;
        }

    // A class whose parent names no class is refused, as the reference
    // refuses it: its layout and dispatch start from the parent's, so there is
    // nothing to build it from (bug 442). That includes an IMPORTED class
    // whose parent lives in a library the program did not import.
    void checkParents(void)
        {
        Array* names = new Array();
        Array* raw = _classes.allKeys();
        for (u32 i = (u32)0; i < raw.count(); i = i + (u32)1)
            names.add(raw.get(i));
        Vtable.sortStrings(names);
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)_classes.get((Hashable*)names.get(i));
            if (cls == 0)
                continue;
            String* pn = Vtable.parentName(cls);
            if (pn == 0 || _classes.get((Hashable*)pn) != 0)
                continue;
            String* msg = String.withCString("Unknown parent class '");
            msg.append(pn);
            msg.appendCString("' for class '");
            msg.append((String*)names.get(i));
            msg.appendCString("'");
            // An imported class has no source position; the reference reports
            // it at `<imported>:0:0`, and so does this.
            if (cls.hasFlag((u32)NF_EXTERNAL) && cls.line() == (u32)0)
                {
                String* at = String.withCString("<imported>:0:0: error: ");
                at.append(msg);
                _errors.add((Object*)at);
                }
            else
                _errorAt(msg, cls);
            }
        }

    void findCycles(void)
        {
        // Mirrors the original (task #36): classes in SORTED order, each
        // walking its parent chain with a seen-set; the FIRST class whose
        // walk revisits a name is severed — and because the walk goes
        // through parentOf (which consults _cyclic), every later walk stops
        // at the severed link. Exactly one class per cycle loses its parent,
        // and it is the same one in both compilers.
        Array* names = new Array();
        Array* raw = _classes.allKeys();
        for (u32 i = (u32)0; i < raw.count(); i = i + (u32)1)
            names.add(raw.get(i));
        Vtable.sortStrings(names);
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* n = (String*)names.get(i);
            Node* cls = (Node*)_classes.get((Hashable*)n);
            if (cls == 0)
                continue;
            Map* seen = new Map();
            seen.set((Hashable*)n, (Object*)String.withCString("y"));
            // `class A : A`: parentOf already answers 0 for it, so the walk
            // below would never see the cycle; the reference reports it.
            String* ownParent = Vtable.parentName(cls);
            if (ownParent != 0 && ownParent.equals(n))
                {
                String* m = String.withCString("Circular inheritance: '");
                m.append(n);
                m.appendCString("' eventually inherits from itself via '");
                m.append(n);
                m.appendCString("'");
                _errorAt(m, cls);
                _cyclic.set((Hashable*)n, (Object*)String.withCString("y"));
                continue;
                }
            Node* cur = parentOf(cls);
            while (cur != 0)
                {
                String* cn = cur.name();
                if (cn != 0 && seen.get((Hashable*)cn) != 0)
                    {
                    // The reference's error, at the severed class: without
                    // it the driver went on to lower the cycle and the
                    // layout scan recursed off the stack.
                    String* m = String.withCString("Circular inheritance: '");
                    m.append(n);
                    m.appendCString("' eventually inherits from itself via '");
                    m.append(cn);
                    m.appendCString("'");
                    _errorAt(m, cls);
                    _cyclic.set((Hashable*)n, (Object*)String.withCString("y"));
                    cur = (Node*)0;
                    }
                else
                    {
                    if (cn != 0)
                        seen.set((Hashable*)cn, (Object*)String.withCString("y"));
                    cur = parentOf(cur);
                    }
                }
            }
        }

    // A class that holds an instance of itself by value (#564), directly or
    // through the classes it holds or inherits from, has no size. Each class
    // whose ivar leads into such a ring is refused there.
    void findValueRings(void)
        {
        Array* names = new Array();
        Array* raw = _classes.allKeys();
        for (u32 i = (u32)0; i < raw.count(); i = i + (u32)1)
            names.add(raw.get(i));
        Vtable.sortStrings(names);
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* n = (String*)names.get(i);
            Node* cls = (Node*)_classes.get((Hashable*)n);
            if (cls == 0)
                continue;
            for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
                {
                Node* iv = cls.kid(j);
                if (iv.kind() != (u16)nkVariableDecl || iv.hasFlag((u32)NF_STATIC))
                    continue;
                Node* held = heldByValue(iv.op());
                if (held == 0 || !holdsByValue(held, n, new Map()))
                    continue;
                _errorAt(String.withFormat("class '%s' holds an instance of itself by value through ivar '%s': declare it '%s* %s;'",
                                           n.cString(), iv.name().cString(), held.name().cString(), iv.name().cString()), iv);
                break;
                }
            }
        }

    // The class an ivar of this type holds by value, or 0.
    Node* heldByValue(String* ty)
        {
        if (ty == 0 || ty.byteLength() == (u32)0 || ty.byteAt(ty.byteLength() - (u32)1) == (u8)'*')
            return (Node*)0;
        for (u32 i = (u32)0; i < ty.byteLength(); i = i + (u32)1)
            if (ty.byteAt(i) == (u8)'[' || ty.byteAt(i) == (u8)':')
                return (Node*)0;
        return (Node*)_classes.get((Hashable*)ty);
        }

    // Does an instance of `c` contain one of `target`?
    bool holdsByValue(Node* c, String* target, Map* seen)
        {
        if (c.name().equals(target))
            return true;
        if (seen.get((Hashable*)c.name()) != 0)
            return false;
        seen.set((Hashable*)c.name(), (Object*)c.name());
        Node* p = parentOf(c);
        if (p != 0 && holdsByValue(p, target, seen))
            return true;
        for (u32 j = (u32)0; j < c.kidCount(); j = j + (u32)1)
            {
            Node* iv = c.kid(j);
            if (iv.kind() != (u16)nkVariableDecl || iv.hasFlag((u32)NF_STATIC))
                continue;
            Node* held = heldByValue(iv.op());
            if (held != 0 && holdsByValue(held, target, seen))
                return true;
            }
        return false;
        }

    bool providesMatching(Node* cls, Node* want, String* meth)
        {
        for (Node* c = cls; c != 0; c = parentOf(c))
            {
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                {
                Node* m = c.kid(i);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.name() == 0 || !m.name().equals(meth))
                    continue;
                if (want == 0)
                    return true; // no declaration to match
                if (Vtable.sameParams(m, want))
                    return true;
                }
            }
        return false;
        }

    // `full` -> `setFull`, searched up the chain. The owning class comes back
    // in `_setterOwner` rather than being stamped on the method declaration:
    // writing it there would put a `cls=` on the MethodDecl in the dump, which
    // is a different claim entirely.
    // The getter a property READ of this member would resolve to. Used by the
    // compound-assignment rewrite, which needs the read it is synthesising to
    // carry the same stamps a written-out read would have.
    String* getterSymbolFor(Node* member)
        {
        Node* g = propertyGetter(member);
        return (g == 0) ? (String*)0 : g.sym();
        }

    String* getterClassFor(Node* member)
        {
        propertyGetter(member);
        return _getterOwner;
        }

    Node* propertyGetter(Node* member)
        {
        _getterOwner = (String*)0;
        if (member.kidCount() == (u32)0)
            return (Node*)0;
        String* rt = member.kid((u32)0).ty();
        if (rt == 0)
            return (Node*)0;
        Node* cls = (Node*)_classes.get((Hashable*)classNameOf(rt));
        for (Node* c = cls; c != 0; c = parentOf(c))
            {
            Node* g = zeroArgMethodNamed(c, member.name());
            if (g != 0)
                {
                _getterOwner = c.name();
                return g;
                }
            }
        return (Node*)0;
        }

    bool memberIsIvar(Node* member)
        {
        if (member.kidCount() == (u32)0)
            return false;
        String* rt = member.kid((u32)0).ty();
        if (rt == 0)
            return false;
        String* owner = classNameOf(rt);
        Node* st = (Node*)_structs.get((Hashable*)owner);
        if (st != 0)
            return fieldType(st, member.name()) != 0;
        Node* cls = (Node*)_classes.get((Hashable*)owner);
        if (cls == 0)
            return false;
        return fieldTypeUpChain(cls, member.name()) != 0;
        }

    String* fieldTypeUpChain(Node* cls, String* name)
        {
        if (cls == 0 || name == 0)
            return (String*)0;
        for (Node* c = cls; c != 0; c = parentOf(c))
            {
            String* t = fieldType(c, name);
            if (t != 0)
                return t;
            }
        return (String*)0;
        }

    Node* propertySetter(Node* member)
        {
        if (member.kidCount() == (u32)0)
            return (Node*)0;
        String* rt = member.kid((u32)0).ty();
        if (rt == 0)
            return (Node*)0;
        Node* cls = (Node*)_classes.get((Hashable*)classNameOf(rt));
        if (cls == 0)
            return (Node*)0;
        String* prop = member.name();
        if (prop == 0 || prop.byteLength() == (u32)0)
            return (Node*)0;
        String* want = String.withCString("set");
        u8 c0 = prop.byteAt((u32)0);
        if (c0 >= (u8)'a' && c0 <= (u8)'z')
            c0 = (u8)(c0 - (u8)32);
        want.appendByte(c0);
        if (prop.byteLength() > (u32)1)
            want.append(prop.substringFromByte((u32)1));
        // The IVAR this property is backed by, if any. A write-only property
        // has none, and then any single-argument setter of the right name is
        // it. When there IS one, the setter has to take THAT TYPE — a method
        // that merely spells `set<Name>` and takes something else is an
        // ordinary method that happens to be named that way, and rewriting a
        // direct store into a call to it passes a value of the wrong type
        // (uxkit 034-B: an i32 into an `Object*`, dereferenced at +8).
        //
        // The reference decides this by ranking the assigned VALUE against the
        // parameter (`setterMethodNamed:…acceptingValue:`). The port cannot:
        // the right-hand side is not typed until after this decision. Matching
        // the ivar's type is the same question asked one step earlier, and it
        // separates both known cases — `setN(u8)` over a `u8 n` is a property,
        // `setX(Object*)` over an `i32 x` is not. If the two ever disagree it
        // will be on a widening setter (`setN(u16)` over a `u8 n`), which the
        // reference accepts and this does not; no file in the corpus has one,
        // and the differentials are what would say otherwise.
        String* ivarTy = fieldTypeUpChain(cls, prop);
        for (Node* c = cls; c != 0; c = parentOf(c))
            {
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                {
                Node* m = c.kid(i);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.name() == 0 || !m.name().equals(want))
                    continue;
                if (paramCount(m) != (u32)1)
                    continue;
                if (ivarTy != (String*)0)
                    {
                    String* pt = (String*)0;
                    for (u32 j = (u32)0; j < m.kidCount(); j = j + (u32)1)
                        if (m.kid(j).kind() == (u16)nkParam)
                            {
                            pt = m.kid(j).op();
                            break;
                            }
                    if (pt == (String*)0 || !pt.equals(ivarTy))
                        continue;
                    }
                _setterOwner = c.name();
                return m;
                }
            }
        return (Node*)0;
        }

    Node* zeroArgMethodNamed(Node* cls, String* name)
        {
        if (cls == 0 || name == 0)
            return (Node*)0;
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* m = cls.kid(i);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (m.name() == 0)
                continue;
            if (!m.name().equals(name))
                continue;
            if (paramCount(m) == (u32)0)
                return m;
            }
        return (Node*)0;
        }

    Node* findMethodUpChain(Node* cls, String* name)
        {
        for (Node* c = cls; c != 0; c = parentOf(c))
            {
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                {
                Node* m = c.kid(i);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.name() != 0 && m.name().equals(name))
                    return m;
                }
            }
        return (Node*)0;
        }

    // The class that DECLARES `name` — not the one it was reached THROUGH.
    // findMethodUpChain walks the same chain and returns the METHOD; a bound
    // method needs the owning class too, because its symbol is `<owner>$<m>`
    // and an inherited method has no symbol under the derived class's name.
    // `&d.inheritedMethod` linked against `Derived$add`, which does not exist:
    // an undefined symbol at link time, from a program that compiled clean.
    Node* classDeclaringMethod(Node* cls, String* name)
        {
        for (Node* c = cls; c != 0; c = parentOf(c))
            {
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
                {
                Node* m = c.kid(i);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.name() != 0 && m.name().equals(name))
                    return c;
                }
            }
        return (Node*)0;
        }

    void collectDeclarations(Node* program)
        {
        // Category/extension nodes merged below; removed from the program once
        // the walk is done, so no later pass sees a spent part.
        Array* spentParts = new Array();
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            {
            Node* d = program.kid(i);
            u16 k = d.kind();
            if (k == (u16)nkClassDecl)
                {
                // A CATEGORY / EXTENSION merges into the class of that name
                // rather than colliding with it. Methods always; ivars only
                // from an extension `()`, and only where the class itself is
                // being compiled — a class reached through an interface has had
                // its instance size baked into everything that allocates it.
                // The part is then SPENT and must not be walked again, or its
                // methods lower twice. private:docs/Design/separate-compilation.md 4.
                if (d.isCategory())
                    {
                    Node* host = (Node*)_classes.get((Hashable*)d.name());
                    if (host == (Node*)0)
                        {
                        String* msg = String.withCString("Category extends unknown class '");
                        msg.append(d.name());
                        msg.appendCString("'");
                        _error(msg);
                        }
                    else if (categoryAddsIvars(d) && d.category().byteLength() > (u32)0)
                        {
                        String* msg = String.withCString("Category on '");
                        msg.append(d.name());
                        msg.appendCString("' cannot add instance variables");
                        _error(msg);
                        }
                    else if (host.hasFlag((u32)NF_EXTERNAL))
                        {
                        // §4.2/§4.3b: extending a class from ANOTHER module.
                        // Ivars cannot cross (the instance size is baked into
                        // everything that allocates it), a category may not
                        // REPLACE a method the class already has, nor add a
                        // protocol conformance (the itable is emitted with the
                        // library's vtable). What survives is methods-only,
                        // each marked with its host so the chain-slot pass
                        // numbers it OUTSIDE the vtable slot space.
                        if (categoryAddsIvars(d))
                            {
                            String* msg = String.withCString("Extension cannot add instance variables to '");
                            msg.append(d.name());
                            msg.appendCString("': it is defined in another module, whose instance "
                                              "size is already fixed. Methods are fine; ivars need "
                                              "the class's own build");
                            _error(msg);
                            spentParts.add((Object*)d);
                            continue;
                            }
                        if (d.extra() != 0 && !d.extra().equals(String.withCString("-")))
                            {
                            String* msg = String.withCString("Category cannot add protocol conformance to '");
                            msg.append(d.name());
                            msg.appendCString("': it is defined in another module, whose instance "
                                              "size is already fixed. Methods are fine; ivars need "
                                              "the class's own build");
                            _error(msg);
                            spentParts.add((Object*)d);
                            continue;
                            }
                        bool clash = false;
                        for (u32 mj = (u32)0; mj < d.kidCount(); mj = mj + (u32)1)
                            {
                            Node* nm = d.kid(mj);
                            if (nm.kind() != (u16)nkMethodDecl)
                                continue;
                            for (u32 hk = (u32)0; hk < host.kidCount(); hk = hk + (u32)1)
                                {
                                Node* hm = host.kid(hk);
                                if (hm.kind() != (u16)nkMethodDecl)
                                    continue;
                                if (hm.name().equals(nm.name()))
                                    {
                                    String* msg = String.withCString("Category cannot replace '");
                                    msg.append(d.name());
                                    msg.appendCString(".");
                                    msg.append(nm.name());
                                    msg.appendCString("': the class comes from another module");
                                    _error(msg);
                                    clash = true;
                                    }
                                }
                            }
                        if (clash)
                            {
                            spentParts.add((Object*)d);
                            continue;
                            }
                        // A category that arrived through an INTERFACE is another
                        // module's (2026-11-01: its final methods, called
                        // directly): nothing of it is this compilation's to number
                        // or anchor. As the reference.
                        if (d.hasFlag((u32)NF_EXTERNAL))
                            {
                            mergeCategory(host, d);
                            spentParts.add((Object*)d);
                            continue;
                            }
                        for (u32 mj = (u32)0; mj < d.kidCount(); mj = mj + (u32)1)
                            {
                            Node* nm = d.kid(mj);
                            if (nm.kind() == (u16)nkMethodDecl)
                                {
                                nm.setImportedCatHost(d.name());
                                noteCatName(d.name(),
                                            d.category().byteLength() > (u32)0
                                                ? d.category()
                                                : String.withCString("_ext"));
                                }
                            }
                        mergeCategory(host, d);
                        spentParts.add((Object*)d);
                        }
                    else
                        {
                        mergeCategory(host, d);
                        spentParts.add((Object*)d);
                        }
                    continue;
                    }
                // A second definition of the same class is an ERROR, not an
                // overwrite — mirrors the reference sema. The FIRST definition
                // stays registered; the duplicate node is still walked (the
                // reference visits every class decl in the program, so its
                // methods still resolve against the surviving registration —
                // the dump's sym= annotations depend on that).
                if (_classes.get((Hashable*)d.name()) != 0)
                    {
                    String* msg = String.withCString("Redefinition of class '");
                    msg.append(d.name());
                    msg.appendCString("'");
                    _error(msg);
                    }
                else
                    {
                    _classes.set((Hashable*)d.name(), (Object*)d);
                    }
                _classDecls.add((Object*)d);
                }
            else if (k == (u16)nkProtocolDecl)
                {
                // A PROTOCOL's methods are mangled by the same rule as a
                // class's — they are what a conforming class's slots are
                // matched against — but a protocol is not a class: calls do not
                // resolve to it and `new` never names it, so it is kept apart
                // from the class table those two consult.
                _protocols.set((Hashable*)d.name(), (Object*)d);
                _classDecls.add((Object*)d);
                }
            else if (k == (u16)nkUseDecl)
                {
                _used.add((Object*)d.name());
                }
            else if (k == (u16)nkVariableDecl)
                {
                // Globals are collected UP FRONT: a function declared before
                // the global it reads still sees it, and the file order is not
                // the visibility order.
                // ONE global name, ONE type, across the whole unit. A second
                // declaration used to overwrite the first in silence, so
                // `u32 gX;` in one file and `u32 gX[64];` in another — both
                // reaching one unit — became one object seen two ways: the
                // scalar's write landed in the array's element 0. Identical
                // redeclarations still merge (a header imported down two
                // paths is ordinary); only a DIFFERENT type is refused.
                //
                // `auto` is not a type — it is FILLED IN from the initialiser
                // — and the initialiser has no type yet, so an auto global
                // cannot be registered here. It is inferred and registered
                // where the declaration is typed (typeProgram), which is what
                // the reference does with the same pre-pass: an auto global is
                // left out of it and defined on the ordinary path. Registering
                // it here put the word "auto" in the global table and every
                // use of it lowered as an unsupported type.
                if (d.op() == (String*)0 || !_isOp(d.op(), "auto"))
                    {
                    String* priorTy = (String*)_globals.get((Hashable*)d.name());
                    if (priorTy != (String*)0 && d.op() != (String*)0
                        && !priorTy.equals(d.op()))
                        {
                        String* m = String.withCString("global '");
                        m.append(d.name());
                        m.appendCString("' is declared twice in this unit with different types: '");
                        m.append(priorTy);
                        m.appendCString("' and '");
                        m.append(d.op());
                        m.appendCString("' — they would share one object, and a write through one would be read through the other");
                        _errorAt(m, d);
                        }
                    _globals.set((Hashable*)d.name(), (Object*)d.op());
                    }
                }
            else if (k == (u16)nkEnumDecl)
                {
                // An enum's members are u8 constants visible by bare name; the
                // enum NAME registers with Types so widening knows its width.
                Types.noteEnum(d.name());
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    {
                    Node* m = d.kid(j);
                    if (m.kind() == (u16)nkEnumMember)
                        _globals.set((Hashable*)m.name(), (Object*)String.withCString("u8"));
                    }
                }
            else if (k == (u16)nkStructDecl)
                {
                _structs.set((Hashable*)d.name(), (Object*)d);
                }
            else if (k == (u16)nkTypedefDecl)
                {
                if (d.name() != 0 && d.op() != 0)
                    _typedefTargets.set((Hashable*)d.name(), (Object*)d.op());
                // `typedef struct { … } Cursor;` keeps the struct as a CHILD of
                // the typedef — the dump does not print it (neither does the
                // original's), but the fields are there and member typing
                // needs them. Registered under the ALIAS, which is the name
                // every use site spells.
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    {
                    Node* st = d.kid(j);
                    if (st.kind() == (u16)nkStructDecl)
                        _structs.set((Hashable*)d.name(), (Object*)st);
                    }
                }
            else if (k == (u16)nkFunctionDecl)
                {
                Array* g = (Array*)_functions.get((Hashable*)d.name());
                if (g == 0)
                    {
                    g = new Array();
                    _functions.set((Hashable*)d.name(), (Object*)g);
                    }
                g.add((Object*)d);
                }
            }
        // The merged parts leave the program now — walking backwards so each
        // removal cannot shift an index still to be visited.
        for (u32 si = spentParts.count(); si > (u32)0; si = si - (u32)1)
            {
            Node* sp = (Node*)spentParts.get(si - (u32)1);
            for (u32 pi = program.kidCount(); pi > (u32)0; pi = pi - (u32)1)
                if (program.kid(pi - (u32)1) == sp)
                    {
                    program.dropKid(pi - (u32)1);
                    }
            }
        }

    // A free function is mangled ONLY when its name is overloaded. An
    // unambiguous name keeps its own spelling, which is why most of a program's
    // symbols are readable — and why a difference here is visible immediately
    // rather than buried in a suffix nobody reads.
    void mangleFunctions(void)
        {
        Array* names = _functions.allKeys();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Array* group = (Array*)_functions.get((Hashable*)names.get(i));
            // Every node's symbol defaults to its own name, so a declaration
            // dropped by the merge below still dumps `sym=<name>`, exactly as
            // the original's unregistered duplicate does.
            for (u32 j = (u32)0; j < group.count(); j = j + (u32)1)
                ((Node*)group.get(j)).setSym(((Node*)group.get(j)).name());
            // Repeated IDENTICAL body-less declarations MERGE, as C prototypes
            // do — the original's rule (blewit item 1: Stdio declares `write`,
            // the program declares it again). A body-less decl has no nkBlock
            // kid; identity is the mangled signature. The MAP is updated too,
            // so call resolution sees one candidate, not two copies.
            if (group.count() > (u32)1)
                {
                // Signatures that have a real DEFINITION (an nkBlock body) here.
                Array* definedSigs = new Array();
                for (u32 j = (u32)0; j < group.count(); j = j + (u32)1)
                    {
                    Node* fn = (Node*)group.get(j);
                    bool hasBody = false;
                    for (u32 b = (u32)0; b < fn.kidCount(); b = b + (u32)1)
                        if (fn.kid(b).kind() == (u16)nkBlock)
                            hasBody = true;
                    if (hasBody)
                        definedSigs.add((Object*)mangledFor(fn));
                    }
                Array* kept = new Array();
                Array* seen = new Array();
                for (u32 j = (u32)0; j < group.count(); j = j + (u32)1)
                    {
                    Node* fn = (Node*)group.get(j);
                    bool hasBody = false;
                    for (u32 b = (u32)0; b < fn.kidCount(); b = b + (u32)1)
                        if (fn.kid(b).kind() == (u16)nkBlock)
                            hasBody = true;
                    if (!hasBody)
                        {
                        String* s = mangledFor(fn);
                        // rule 1a: a prototype whose signature is DEFINED here
                        // is redundant with the definition -- drop it, so a
                        // prototype plus its definition is ONE function, not a
                        // spuriously "overloaded" pair. Otherwise the pair
                        // mangles here (`foo__pCString_i32`) while a TU that sees
                        // only the lone prototype emits the unmangled `foo`, and
                        // the two never meet at link (blewit's `gzipBody`).
                        bool isDefined = false;
                        for (u32 x = (u32)0; x < definedSigs.count(); x = x + (u32)1)
                            if (((String*)definedSigs.get(x)).equals(s))
                                isDefined = true;
                        if (isDefined)
                            continue;
                        bool dup = false;
                        for (u32 x = (u32)0; x < seen.count(); x = x + (u32)1)
                            if (((String*)seen.get(x)).equals(s))
                                dup = true;
                        if (dup)
                            continue;
                        seen.add((Object*)s);
                        }
                    kept.add((Object*)fn);
                    }
                group = kept;
                _functions.set((Hashable*)names.get(i), (Object*)group);
                }
            // Two DEFINITIONS with the same parameter types are an error,
            // wherever they come from: the program and a file it imports
            // (#418), or one file twice. The second is reported, naming where
            // the first is; both stay in the group, so the names mangle as the
            // reference's do (the build stops at the error either way).
            // Without this -O0 failed at assembly ("duplicate label") and -O2
            // kept the import's body without a word. As the reference.
            if (group.count() > (u32)1)
                {
                Array* firstSigs = new Array();
                Array* firstNodes = new Array();
                for (u32 j = (u32)0; j < group.count(); j = j + (u32)1)
                    {
                    Node* fn = (Node*)group.get(j);
                    bool hasBody = false;
                    for (u32 b = (u32)0; b < fn.kidCount(); b = b + (u32)1)
                        if (fn.kid(b).kind() == (u16)nkBlock)
                            hasBody = true;
                    if (!hasBody)
                        continue;
                    String* sg = mangledFor(fn);
                    Node* first = (Node*)0;
                    for (u32 x = (u32)0; x < firstSigs.count(); x = x + (u32)1)
                        if (((String*)firstSigs.get(x)).equals(sg))
                            first = (Node*)firstNodes.get(x);
                    if (first == (Node*)0)
                        {
                        firstSigs.add((Object*)sg);
                        firstNodes.add((Object*)fn);
                        continue;
                        }
                    String* m = String.withCString("Redefinition of '");
                    m.append(fn.name());
                    m.appendCString("' with same parameter types");
                    if (first.line() != (u32)0)
                        {
                        m.appendCString(" (previously defined at ");
                        m.append(first.file() != 0 ? first.file() : String.withCString("<input>"));
                        m.appendFormat(":%u)", first.line());
                        }
                    _errorAt(m, fn);
                    }
                }
            // Mirror of the original's C-linkage rule: a body-less member is
            // an external C function, and a DIFFERENT-signature member cannot
            // overload it — overloading would mangle the C symbol away. The
            // offenders are diagnosed and dropped from the group (keeping
            // their default sym), exactly the original's survivor set, so the
            // two dumps agree even on the erroring program.
            // SOURCE MASKS THE PROBE (#1077). A library's metadata and the
            // program's own header routinely declare the same C function — a
            // binding header hand-declares what it calls, and the library's
            // DWARF describes it too. The two spellings need not match
            // (`pointer` against `OBJECT*`, named parameters against
            // anonymous), and treating that as an overload of a C symbol
            // rejected the program outright. What the program WROTE wins; the
            // imported declaration is dropped without comment, because it is
            // not a diagnosis, it is the merge working.
            if (group.count() > (u32)1)
                {
                bool haveLocal = false;
                for (u32 j = (u32)0; j < group.count(); j = j + (u32)1)
                    if (!((Node*)group.get(j)).hasFlag((u32)NF_EXTERNAL))
                        haveLocal = true;
                if (haveLocal)
                    {
                    Array* local = new Array();
                    for (u32 j = (u32)0; j < group.count(); j = j + (u32)1)
                        {
                        Node* fn = (Node*)group.get(j);
                        if (!fn.hasFlag((u32)NF_EXTERNAL))
                            local.add((Object*)fn);
                        }
                    if (local.count() < group.count())
                        {
                        group = local;
                        _functions.set((Hashable*)names.get(i), (Object*)group);
                        }
                    }
                }
            if (group.count() > (u32)1)
                {
                Node* ext = (Node*)0;
                for (u32 j = (u32)0; j < group.count(); j = j + (u32)1)
                    {
                    Node* fn = (Node*)group.get(j);
                    bool hasBody = false;
                    for (u32 b = (u32)0; b < fn.kidCount(); b = b + (u32)1)
                        if (fn.kid(b).kind() == (u16)nkBlock)
                            hasBody = true;
                    if (!hasBody)
                        {
                        ext = fn;
                        j = group.count();
                        }
                    }
                if (ext != 0)
                    {
                    String* es = mangledFor(ext);
                    Array* surv = new Array();
                    for (u32 j = (u32)0; j < group.count(); j = j + (u32)1)
                        {
                        Node* fn = (Node*)group.get(j);
                        if (fn == ext || mangledFor(fn).equals(es))
                            {
                            surv.add((Object*)fn);
                            }
                        else
                            {
                            // Name the clash, the way the reference does: which
                            // function, and where the one-and-only C signature
                            // was declared, with a way out (c2xc 08). A bare
                            // "cannot overload an external C function" named
                            // neither and pointed nowhere.
                            // Bug 557: a forward declaration ABOVE its parameter's
                            // type read `T*` as an opaque `void*`, so it and the
                            // definition below the type look like two signatures.
                            // Say so, instead of blaming a stray C symbol.
                            String* order = declOrderClash(ext, fn);
                            if (order != (String*)0)
                                {
                                _errorAt(order, fn);
                                continue;
                                }
                            String* em = String.withCString("Cannot overload '");
                            em.append(fn.name());
                            em.appendCString("' \u2014 it is an external C function (declared without a body at ");
                            em.append(ext.file() != 0 ? ext.file().lastPathComponent() : String.withCString("?"));
                            em.appendByte((u8)':');
                            em.append(String.withU32(ext.line()));
                            em.appendCString("), and a C symbol has exactly one signature. Use that signature, or wrap the call under a different name");
                            _errorAt(em, fn);
                            }
                        }
                    if (surv.count() < group.count())
                        {
                        group = surv;
                        _functions.set((Hashable*)names.get(i), (Object*)group);
                        }
                    }
                }
                // §6's other face (task #31): `extern` on a definition promises
                // the SPELLED name to non-xtc consumers, and two extern
                // definitions of one name would have to share that label — the
                // second is an error. Mirrors the original's grouping-pass check
                // (error emitted, the pass continues).
                {
                Node* firstExp = (Node*)0;
                for (u32 j = (u32)0; j < group.count(); j = j + (u32)1)
                    {
                    Node* fn = (Node*)group.get(j);
                    if (!fn.hasFlag((u32)NF_EXTERN))
                        continue;
                    bool hasBody = false;
                    for (u32 b = (u32)0; b < fn.kidCount(); b = b + (u32)1)
                        if (fn.kid(b).kind() == (u16)nkBlock)
                            hasBody = true;
                    if (!hasBody)
                        continue;
                    if (firstExp == 0)
                        {
                        firstExp = fn;
                        continue;
                        }
                    _errorAt(String.withFormat("Cannot export two overloads of '%s' — `extern` promises the name itself to the outside, and both cannot own it. Keep `extern` on one overload", fn.name().cString()), fn);
                    }
                }
            bool overloaded = group.count() > (u32)1;
            for (u32 j = (u32)0; j < group.count(); j = j + (u32)1)
                {
                Node* fn = (Node*)group.get(j);
                if (overloaded)
                    fn.setSym(mangledFor(fn));
                else
                    fn.setSym(fn.name());
                }
            }
        }

    // Methods are grouped PER CLASS: two classes may each declare `get` without
    // either being an overload of the other.
    void mangleMethods(void)
        {
        // Every method's symbol DEFAULTS to its own name — that is what the
        // original's nodes carry before anything mangles them, and it is why a
        // duplicate declaration (a double import parses the same class twice)
        // shows plain names: only the node the class TABLE holds gets mangled,
        // and the other keeps the default.
        for (u32 i = (u32)0; i < _classDecls.count(); i = i + (u32)1)
            {
            Node* decl = (Node*)_classDecls.get(i);
            for (u32 j = (u32)0; j < decl.kidCount(); j = j + (u32)1)
                {
                Node* m = decl.kid(j);
                if (m.kind() == (u16)nkMethodDecl)
                    m.setSym(m.name());
                }
            }
        Array* owners = new Array();
        Array* cn = _classes.allKeys();
        for (u32 i = (u32)0; i < cn.count(); i = i + (u32)1)
            owners.add(_classes.get((Hashable*)cn.get(i)));
        Array* pn2 = _protocols.allKeys();
        for (u32 i = (u32)0; i < pn2.count(); i = i + (u32)1)
            owners.add(_protocols.get((Hashable*)pn2.get(i)));
        for (u32 i = (u32)0; i < owners.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)owners.get(i);
            Map* groups = new Map();
            for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
                {
                Node* m = cls.kid(j);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                Array* g = (Array*)groups.get((Hashable*)m.name());
                if (g == 0)
                    {
                    g = new Array();
                    groups.set((Hashable*)m.name(), (Object*)g);
                    }
                g.add((Object*)m);
                }
            Array* mnames = groups.allKeys();
            for (u32 j = (u32)0; j < mnames.count(); j = j + (u32)1)
                {
                Array* group = (Array*)groups.get((Hashable*)mnames.get(j));
                bool overloaded = group.count() > (u32)1;
                for (u32 t = (u32)0; t < group.count(); t = t + (u32)1)
                    {
                    Node* m = (Node*)group.get(t);
                    if (overloaded)
                        m.setSym(mangledFor(m));
                    else
                        m.setSym(m.name());
                    }
                }
            }
        }

    // The parameter spellings live on the decl's Param children; the return
    // type is the decl's `op`. A zero-parameter function takes its return type
    // as a disambiguator, so `PI() -> float` and `PI() -> double` differ.
    String* mangledFor(Node* decl)
        {
        Array* params = new Array();
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* p = decl.kid(i);
            if (p.kind() == (u16)nkParam)
                params.add((Object*)p.op());
            }
        String* ret = (params.count() == (u32)0) ? decl.op() : (String*)0;
        return Mangle.name(decl.name(), params, ret);
        }
    }
