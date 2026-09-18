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
#import "Node.xc"
#import "Mangle.xc"
#import "Types.xc"
#import "Overload.xc"
#import "Vtable.xc"

class Sema
    {
    Map* _classes;      // class name  -> ClassDecl node
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
    bool _fnForwardsVarargs;  // a `...` forward was seen
    bool _rangeIsInitialiser; // inside an ARRAY declaration's initialiser,
                              // the one position a range survives the parser
    Array* _errors;           // of String@
    Array* _scopes;           // of Map@ (name -> type spelling); innermost last
    Map* _globals;            // file-scope variables
    Map* _structs;            // struct name -> StructDecl node
    Node* _curMethod;         // the declaration whose body is being walked
    Node* _curClass;          // the class whose body is being walked, or 0
    String* _getterOwner;     // …and the same for a getter
    String* _setterOwner;     // where propertySetter found it — see the note there
    String* _curReturn;       // the return type of the function being walked
    String* _expected;        // the type the CONTEXT wants, propagated into an
                              // initialiser or an assignment's right-hand side.
                              // `Math.rand()` has five zero-argument overloads
                              // that differ only in return type, so the context
                              // is the only thing that can choose between them.
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
               // Deliberately NOT routed through Types.byteWidth,
               // which hardcodes 8 for pointers and is the width
               // table behind every widen decision — changing it
               // would ripple through the whole corpus. This is
               // read at exactly one site.

    void init(void)
        {
        _classes = new Map();
        _protocols = new Map();
        _classDecls = new Array();
        _functions = new Map();
        _errors = new Array();
        _rangeIsInitialiser = false;
        _migrateBase = (String*)0;
        _fnPackingCallee = (String*)0;
        _fnForwardsVarargs = false;
        _scopes = new Array();
        _globals = new Map();
        _structs = new Map();
        _curClass = (Node*)0;
        _curMethod = (Node*)0;
        _getterOwner = (String*)0;
        _setterOwner = (String*)0;
        _curReturn = (String*)0;
        _expected = (String*)0;
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
    void setChainCapable(bool c)
        {
        _chainCapable = c;
        }
    void setPointerWidth(u32 w)
        {
        _ptrW = w;
        }
    void setMigrateBase(String* v)
        {
        _migrateBase = v;
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
        out.appendByte((u8)':');
        out.append(String.withU32(n.line()));
        out.appendByte((u8)':');
        out.append(String.withU32(n.col()));
        out.appendCString(": error: ");
        out.append(msg);
        _errors.add((Object*)out);
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
        if (lhs == 0 || rhs == 0)
            return;

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
            _errorAt(e, rhsNode);
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
            _errorAt(e, rhsNode);
            return;
            }
        if (lBound || rBound)
            return;

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
            _errorAt(e, rhsNode);
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
            _errorAt(e, rhsNode);
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
        _errorAt(e, rhsNode);
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
                    _error(e);
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
                        _error(e);
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
        findCycles();
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
        typeProgram(program);
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
                d.setTy(d.op());
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
        pushScope();
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
                define(p.name(), p.op());
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
                        _errorAt(em, cbp);
                        }
                    }
                }
            }
        _fnPackingCallee = (String*)0;
        _fnForwardsVarargs = false;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* b = decl.kid(i);
            if (b.kind() == (u16)nkBlock)
                {
                typeStmt(b);
                markVaForward(b, decl);
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
            _error(e);
            }
        popScope();
        _curClass = (Node*)0;
        _getterOwner = (String*)0;
        _setterOwner = (String*)0;
        _curReturn = (String*)0;
        }

    void typeStmt(Node* n)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
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
            _expected = save;
            // `String* s = arr;` / `act_t^ a = someBlock;` — an initialiser is
            // an assignment and is checked as one.
            if (n.kidCount() > (u32)0 && !_isOp(n.op(), "auto"))
                checkClassPointerAssign(n.op(), n.kid((u32)0).ty(),
                                        n.kid((u32)0), "initialiser");
            if (_isOp(n.op(), "auto") && n.kidCount() > (u32)0)
                {
                String* inferred = n.kid((u32)0).ty();
                if (inferred != 0)
                    n.setOp(inferred);
                }
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
                    checkClassPointerAssign(want, n.kid(i).ty(), n.kid(i), "return");
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

        // An assignment's RHS is typed with the LHS as its expected type, so a
        // return-type-only overload can be chosen there too.
        if (k == (u16)nkAssign && n.kidCount() >= (u32)2)
            {
            typeExpr(n.kid((u32)0));
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
                checkClassPointerAssign(n.kid((u32)0).ty(), n.kid((u32)1).ty(),
                                        n.kid((u32)1), "assignment");
            return;
            }
        // A printf VARARG is typed with the format's expectation in hand:
        // `Math.PI()` has a float and a double overload and nothing but the
        // conversion can choose between them, so `%f` picks float and `%lf`
        // picks double. Only the float conversions hint — the integer ones
        // would start choosing where the original does not.
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            {
            String* hint = printfHint(n, i);
            if (hint == 0)
                {
                typeExpr(n.kid(i));
                continue;
                }
            String* save = _expected;
            _expected = hint;
            typeExpr(n.kid(i));
            _expected = save;
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
            n.setTy(String.withCString("u16"));
            return;
            }
        if (k == (u16)nkSubscript || k == (u16)nkSlice)
            {
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
                Node* ini = initOverload(cls, n);
                if (ini != 0)
                    n.setSym(ini.sym());
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
                checkClassPointerAssign(n.kid((u32)0).ty(), n.kid((u32)1).ty(),
                                        n.kid((u32)1), "assignment");
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
        return Types.forIntLiteral(v);
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

    void typeBinary(Node* n)
        {
        if (n.kidCount() < (u32)2)
            return;
        // An operand that reads a primitive element out of a typed collection
        // is the BOX until it is unboxed, and this node types itself from its
        // operands — so it happens here, ahead of everything below.
        n.setKid((u32)0, unboxCollectionElement(n.kid((u32)0)));
        n.setKid((u32)1, unboxCollectionElement(n.kid((u32)1)));
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
                // Same widen-to-operands guard as the block above (bug 180).
                String* ft2 = Types.forValue(v); // folded: may be negative
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
            n.setTy(String.withCString("u16"));
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
            for (Node* c = _curClass; c != 0 && m == 0; c = parentOf(c))
                m = methodOverload(c, n, (u32)0);
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
            if (m != 0 && _functions.get((Hashable*)n.name()) != 0 && _curMethod != 0 && n.name().equals(_curMethod.name()))
                m = (Node*)0;
            if (m != 0)
                {
                n.setTy(m.op());
                n.setSym(m.sym());
                // An implicit-self call DOES reach the method through the
                // class's own storage, so it counts as a stack receiver. A
                // `use`-promoted bare call (below) does not — measured, not
                // assumed: marking both cost 81 files.
                m.setStackRecv();
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
                n.setTy(returnOfSignature(ct));
                n.setIndirect(isBoundSignature(ct));
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
            n.setTy(returnOfSignature(vt));
            n.setIndirect(isBoundSignature(vt));
            return;
            }
        Array* group = (Array*)_functions.get((Hashable*)n.name());
        if (group != 0)
            {
            Node* fn = pickOverload(group, n, (u32)0);
            // With a SINGLE candidate the call resolves even when the argument
            // does not convert — the original resolves it and diagnoses the
            // argument separately, which is how `render(v)` still names
            // `render` while reporting that Vehicle does not conform to
            // Drawable. A `new`, by contrast, stays strict.
            // libc and free functions are the LOWEST-precedence layer for a
            // bare call: the single-candidate rule must not let the imported
            // `rand(void)` claim `rand(100)` when `use Math;` promotes a
            // `Math.rand(u8)` that genuinely matches.
            if (fn == 0 && group.count() == (u32)1 && !usePromotedMatch(n))
                fn = (Node*)group.get((u32)0);
            if (fn != 0)
                {
                n.setTy(firstReturn(fn.op()));
                n.setSym(fn.sym());
                applyBoxing(n, fn, (u32)0);
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
            n.setTy(m.op());
            n.setSym(m.sym());
            applyBoxing(n, m, (u32)0);
            // The bare spelling gets the SAME type-directed format upgrade as
            // the explicit one (finding #8) — no receiver kid, so the format
            // sits one position earlier.
            if (_isOp(cls.name(), "Stdio"))
                {
                if (_isOp(n.name(), "printf"))
                    rewriteFormatAt(n, (u32)0);
                else if (_isOp(n.name(), "printfAt"))
                    rewriteFormatAt(n, (u32)2);
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
            ty = String.withCString("void");
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
    Node* pickOverload(Array* group, Node* call, u32 argBase)
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
        return (Node*)0;
        }

    // The worst rank across the candidate's parameters.
    u32 scoreCandidate(Node* decl, Node* call, u32 argBase)
        {
        u32 worst = (u32)0;
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
                return Overload.noMatch();
            Node* a = call.kid(ai);
            bool isLit = a.kind() == (u16)nkInt;
            u32 r = Overload.rank(a.ty(), p.op(), isLit, a.num());
            // BOXING is the last resort, below every direct conversion: a
            // primitive can box into a Foundation wrapper (rank 8) and a
            // class pointer can unbox into a primitive (rank 9), so an
            // overload that needs neither always wins the tie.
            if (r == Overload.noMatch() && autoboxClassFor(a.ty(), p.op()) != 0)
                r = (u32)8;
            if (r == Overload.noMatch() && canUnboxType(a.ty(), p.op()))
                r = (u32)9;
            worst = Overload.worstOf(worst, r);
            if (worst == Overload.noMatch())
                return worst;
            pi = pi + (u32)1;
            }
        return worst;
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
            String* at = call.kid(ai).ty();
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
        // Not a method call at all — the member is a field holding a callback,
        // a function pointer or a block. private:docs/bugs/074.
        if (rewriteFieldCall(n))
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
            Node* p = parentOf(_curClass);
            while (p != 0)
                {
                Node* m = methodOverload(p, n, (u32)1);
                if (m != 0)
                    {
                    n.setTy(m.op());
                    n.setSym(m.sym());
                    n.setCls(p.name());
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
                    n.setTy(pm.op());
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
        Node* m = methodOverload(cls, n, (u32)1);
        while (m == 0 && owner2 != 0)
            {
            owner2 = parentOf(owner2);
            if (owner2 == 0)
                break;
            m = methodOverload(owner2, n, (u32)1);
            }
        if (m == 0)
            {
            // An unresolved method call is an ERROR — and it was silent, so
            // `k.noSuchMethod(1)` compiled clean and produced a binary. The
            // comment here already said "is an error"; nothing emitted one.
            //
            // It is also what makes --migrate work: hiding a member newer than
            // the base leaves the call unresolved, and unresolved has to report
            // or the flag does nothing at all.
            String* e = String.withCString("No method '");
            e.append(n.name());
            e.appendCString("' on class '");
            e.append(owner);
            e.appendByte((u8)0x27);
            _errorAt(e, n);
            n.setTy(String.withCString("u8"));
            return;
            }
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
                        checkClassPointerAssign(want, arg.ty(), arg, site.cString());
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
                        checkClassPointerAssign(want, arg.ty(), arg, site.cString());
                    }
                }
            }
        notePackOrForward(n, m, owner);
        n.setSym(m.sym());
        rewriteFormat(n, owner);
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
        Node* u = unboxedNode(e, elem);
        if (u == 0)
            return e;
        return u;
        }

    // After a call has chosen its candidate, every argument that needs a
    // conversion gets one.
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

    // The type the format string wants for the argument at `argIdx`, or none.
    // The conversions are walked in order; `%%` consumes no argument. Only
    // `%f`/`%e`/`%g` answer, since those are the only ones where the choice
    // is otherwise unmakeable — a zero-argument overload set that differs
    // only in its return type.
    String* printfHint(Node* call, u32 argIdx)
        {
        if (call.kind() != (u16)nkMethodCall)
            return (String*)0;
        u32 fmtIdx = (u32)0;
        if (_isOp(call.name(), "printf"))
            fmtIdx = (u32)1;
        else if (_isOp(call.name(), "printfAt"))
            fmtIdx = (u32)3;
        else
            return (String*)0;
        if (argIdx <= fmtIdx || call.kidCount() <= fmtIdx)
            return (String*)0;
        Node* recv = call.kid((u32)0);
        if (recv.kind() != (u16)nkIdent || !_isOp(recv.name(), "Stdio"))
            return (String*)0;
        Node* lit = call.kid(fmtIdx);
        if (lit.kind() != (u16)nkStr || lit.name() == 0)
            return (String*)0;

        String* f = lit.name();
        u32 want = argIdx - fmtIdx; // 1-based position in the vararg list
        u32 seen = (u32)0;
        u32 i = (u32)0;
        while (i < f.byteLength())
            {
            if (f.byteAt(i) != (u8)'%')
                {
                i = i + (u32)1;
                continue;
                }
            i = i + (u32)1;
            while (i < f.byteLength() && (f.byteAt(i) == (u8)'.' || f.byteAt(i) == (u8)'-' || (f.byteAt(i) >= (u8)'0' && f.byteAt(i) <= (u8)'9')))
                i = i + (u32)1;
            if (i >= f.byteLength())
                return (String*)0;
            bool lng = false;
            if (f.byteAt(i) == (u8)'l')
                {
                lng = true;
                i = i + (u32)1;
                if (i >= f.byteLength())
                    return (String*)0;
                }
            u8 sp = f.byteAt(i);
            i = i + (u32)1;
            if (sp == (u8)'%')
                continue;
            seen = seen + (u32)1;
            if (seen != want)
                continue;
            if (sp == (u8)'f' || sp == (u8)'e' || sp == (u8)'g')
                {
                if (lng)
                    return String.withCString("double");
                return String.withCString("float");
                }
            return (String*)0;
            }
        return (String*)0;
        }

    // TYPE-DIRECTED FORMAT UPGRADE. `Stdio.printf("%d", w * h)` prints the
    // full promoted product rather than its low 16 bits, because sema widens
    // the conversion to its `l` form when the matching argument is statically
    // 32-bit — arithmetic promotion having made `w * h` a u32.
    //
    // It rewrites the LITERAL, so the tree carries `%ld` where the source said
    // `%d`, and the dump shows it. Conservative like the original: anything
    // unrecognised, or the arguments running out, abandons the rewrite rather
    // than risk desynchronising the argument stream.
    void rewriteFormat(Node* call, String* owner)
        {
        // The four formatters share one width contract, so they share one
        // upgrade (finding #8: they used to disagree — String.withFormat
        // truncated a u32 where Stdio.printf upgraded).
        u32 fmtIdx = (u32)0;
        if (_isOp(owner, "Stdio"))
            {
            if (_isOp(call.name(), "printf"))
                fmtIdx = (u32)1; // after the receiver
            else if (_isOp(call.name(), "printfAt"))
                fmtIdx = (u32)3;
            else
                return;
            }
        else if (_isOp(owner, "String"))
            {
            if (_isOp(call.name(), "withFormat") || _isOp(call.name(), "appendFormat"))
                fmtIdx = (u32)1;
            else
                return;
            }
        else
            return;
        rewriteFormatAt(call, fmtIdx);
        }

    // The BARE spelling (`use Stdio;` + `printf(…)`) has no receiver kid, so
    // its format sits one position earlier — same upgrade, same contract.
    void rewriteFormatAt(Node* call, u32 fmtIdx)
        {
        if (call.kidCount() <= fmtIdx)
            return;
        Node* lit = call.kid(fmtIdx);
        if (lit.kind() != (u16)nkStr || lit.name() == 0)
            return;

        String* f = lit.name();
        String* out = String.withCString("");
        u32 i = (u32)0;
        u32 va = fmtIdx + (u32)1;
        bool changed = false;
        while (i < f.byteLength())
            {
            u8 c = f.byteAt(i);
            if (c != (u8)'%')
                {
                out.appendByte(c);
                i = i + (u32)1;
                continue;
                }
            out.appendByte((u8)'%');
            i = i + (u32)1;
            if (i >= f.byteLength())
                return;
            u8 sp = f.byteAt(i);
            if (sp == (u8)'.')
                {
                out.appendByte((u8)'.');
                i = i + (u32)1;
                while (i < f.byteLength() && f.byteAt(i) >= (u8)'0' && f.byteAt(i) <= (u8)'9')
                    {
                    out.appendByte(f.byteAt(i));
                    i = i + (u32)1;
                    }
                if (i >= f.byteLength())
                    return;
                sp = f.byteAt(i);
                }
            if (sp == (u8)'%')
                {
                out.appendByte((u8)'%');
                i = i + (u32)1;
                continue;
                }
            if (sp == (u8)'d' || sp == (u8)'u' || sp == (u8)'x')
                {
                if (va >= call.kidCount())
                    return;
                String* at = call.kid(va).ty();
                // 8 bytes upgrades TWICE — `%d` on an i64 becomes `%lld`, not
                // the `%ld` that would still truncate. Same rule, one more
                // width.
                if (at != 0 && Types.isInteger(at) && Types.byteWidth(at) >= (u32)8)
                    {
                    out.appendCString("ll");
                    changed = true;
                    }
                else if (at != 0 && Types.isInteger(at) && Types.byteWidth(at) >= (u32)4)
                    {
                    out.appendByte((u8)'l');
                    changed = true;
                    }
                out.appendByte(sp);
                i = i + (u32)1;
                va = va + (u32)1;
                continue;
                }
            // Everything else consumes one argument and is copied verbatim;
            // an unrecognised specifier abandons the rewrite.
            if (sp == (u8)'l' || sp == (u8)'s' || sp == (u8)'c' || sp == (u8)'f' || sp == (u8)'e' || sp == (u8)'g' || sp == (u8)'@' || sp == (u8)'p')
                {
                out.appendByte(sp);
                i = i + (u32)1;
                if (sp == (u8)'l')
                    {
                    if (i >= f.byteLength())
                        return;
                    u8 sub = f.byteAt(i);
                    // an explicit `%ll<spec>`
                    if (sub == (u8)'l')
                        {
                        out.appendByte(sub);
                        i = i + (u32)1;
                        if (i >= f.byteLength())
                            return;
                        out.appendByte(f.byteAt(i));
                        i = i + (u32)1;
                        va = va + (u32)1;
                        continue;
                        }
                    // `%ld` on a 64-bit argument still truncates, so widen it.
                    if (sub == (u8)'d' || sub == (u8)'u' || sub == (u8)'x')
                        {
                        String* lat = (va < call.kidCount()) ? call.kid(va).ty() : (String*)0;
                        if (lat != 0 && Types.isInteger(lat) && Types.byteWidth(lat) >= (u32)8)
                            {
                            out.appendByte((u8)'l');
                            changed = true;
                            }
                        }
                    out.appendByte(sub);
                    i = i + (u32)1;
                    }
                va = va + (u32)1;
                continue;
                }
            return;
            }
        if (changed)
            lit.setName(out);
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
    String* firstReturn(String* spelling)
        {
        if (spelling == 0)
            return spelling;
        for (u32 i = (u32)0; i < spelling.byteLength(); i = i + (u32)1)
            if (spelling.byteAt(i) == (u8)',')
                return spelling.substringBytes((u32)0, i);
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
    // real conversion, not the single-candidate courtesy? Side-effect free;
    // gated on being outside a class body, where use-promotion applies at all.
    bool usePromotedMatch(Node* call)
        {
        if (_curClass != 0)
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
                if (!Types.isInteger(iv.op()))
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
        Node* m = Node.withName((u16)nkMethodDecl, String.withCString("description"));
        m.setOp(String.withCString("String*"));
        m.setSym(String.withCString("description"));
        Node* body = Node.with((u16)nkBlock);

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
            sub.add(identNode(String.withCString("vals")));
            sub.add(intLit((i64)i));
            Node* asn = Node.with((u16)nkAssign);
            asn.setOp(String.withCString("="));
            asn.add(sub);
            asn.add(castTo(String.withCString("u16"),
                           identNode(((Node*)ivars.get(i)).name())));
            Node* st = Node.with((u16)nkExprStatement);
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
            synth.add(Node.with((u16)nkBlock));
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
            bool ancestorInit = false;
            for (Node* a = parent; a != 0; a = parentOf(a))
                {
                Node* ai = Vtable.zeroArgNamed(a, "init");
                if (ai != 0)
                    {
                    ancestorInit = true;
                    }
                }
            if (!ancestorInit)
                continue;
            for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
                {
                Node* m = cls.kid(j);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                if (m.name() == 0 || !_isOp(m.name(), "init"))
                    continue;
                if (m.hasFlag((u32)NF_STATIC))
                    continue;
                if (callsSuperInit(m))
                    continue;
                m.setAutoSuperInit();
                }
            }
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
    void stampClassSlots(void)
        {
        // A faithful mirror of the original's per-class fill (task #36, the
        // pristine-snapshot form): the ROOT loop walks the sorted root
        // labels — for a root this class descends from, the nearest
        // signature-matching impl claims the root's slot — then the PROTOCOL
        // loop walks the class chain in order, each class's protocol list in
        // DECLARATION order, filling only still-empty requirement slots. The
        // name map records a name at the LAST slot the sequence filled for
        // it, which is why `Object : Hashable, Comparable` answers `equals`
        // at Comparable's slot while `String : Comparable, Hashable, …`
        // answers at Hashable's.
        Array* names = _classes.allKeys();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            Node* cls = (Node*)_classes.get((Hashable*)names.get(i));
            Map* mine = new Map();
            Map* filled = new Map(); // slot -> true, this class
            Array* rlabs = _vt.rootLabels();
            for (u32 li = (u32)0; li < rlabs.count(); li = li + (u32)1)
                {
                String* L = (String*)rlabs.get(li);
                if (_vt.isChainLabel(L))
                    continue;
                Object* slObj = _vt.slotForLabel(L);
                if (slObj == 0)
                    continue;
                if (!L.hasPrefix(String.withCString("_cls_")))
                    continue;
                String* tail = L.substringFromByte((u32)5);
                u32 us = tail.indexOfByte((u8)'_');
                if (us == String.notFound())
                    continue;
                String* rootClsName = tail.substringBytes((u32)0, us);
                String* rootKey = tail.substringFromByte(us + (u32)1);
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
                Node* c2 = cls;
                while (c2 != 0)
                    {
                    Node* m2 = Vtable.matching(c2, rootMethod);
                    if (m2 != 0)
                        {
                        impl = m2;
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
                        mine.set((Hashable*)reqM.name(), pslot);
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
            }
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
            if (!rootLabel.hasPrefix(String.withCString("_cls_")))
                continue;
            String* tail = rootLabel.substringFromByte((u32)5);
            u32 us = tail.indexOfByte((u8)'_');
            if (us == String.notFound())
                continue;
            String* rootCls = tail.substringBytes((u32)0, us);
            String* mangled = tail.substringFromByte(us + (u32)1);
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
            Node* cur = parentOf(cls);
            while (cur != 0)
                {
                String* cn = cur.name();
                if (cn != 0 && seen.get((Hashable*)cn) != 0)
                    {
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
                _globals.set((Hashable*)d.name(), (Object*)d.op());
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
                    _error(String.withFormat("Cannot export two overloads of '%s' — `extern` promises the name itself to the outside, and both cannot own it. Keep `extern` on one overload", fn.name().cString()));
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
