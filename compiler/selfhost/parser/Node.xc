// Node.xc — one AST node.
// =================================================================
//
// self-hosting M5. The Objective-C compiler has ~47 AST node CLASSES
// (src/xtc/ast/); this port has one, carrying a kind and a handful of general
// fields. That is a deliberate design choice, not a shortcut:
//
//   * the tree is compared against the original's by dumping both as
//     S-expressions (XTASTDumper defines the format), so what matters is the
//     SHAPE, not how many classes the shape is spread across;
//   * xtc has no generics, so 47 classes would mean 47 downcasts at every
//     visitor site — the erasure the design doc warns about, paid 47 times;
//   * a compiler that later walks this tree wants one dispatch on `kind`, which
//     is what a switch over a small enum gives it.
//
// The fields are a superset of what any one node needs, and the dumper prints
// only the ones that node kind uses. `name` covers identifiers, member names,
// callee names, type spellings; `op` covers operator spellings; `num` covers
// literal integers and character codes; `flags` covers the boolean qualifiers
// (static / varargs / throws / …), one bit each.

#import "Foundation.xc"
#import "FileTable.xc"

// Node kinds. The names match the Objective-C XTASTNodeKind enumerators, and
// the DUMP prints these names — so unlike the token types there is no numeric
// contract to keep in step, and this list can be reordered freely.
enum NodeKind = {
    nkProgram = 0,
    nkFunctionDecl,
    nkMethodDecl,
    nkVariableDecl,
    nkStructDecl,
    nkTypedefDecl,
    nkEnumDecl,
    nkEnumMember,
    nkClassDecl,
    nkProtocolDecl,
    nkUseDecl,
    nkParam,

    nkBlock,
    nkIf,
    nkWhile,
    nkForCStyle,
    nkForIn,
    nkReturn,
    nkBreak,
    nkContinue,
    nkGoto,
    nkGotoLabel,
    nkSwitch,
    nkCase,
    nkLabel,
    nkAsmBlock,
    nkAsmLine,
    nkExprStatement,
    nkTupleAssign,
    nkDelete,
    nkDefer,
    nkThrow,
    nkTry,
    nkCatch,

    nkBinary,
    nkUnary,
    nkPostfix,
    nkAssign,
    nkCall,
    nkMethodCall,
    nkSubscript,
    nkSlice,
    nkRange,
    nkMember,
    nkTernary,
    nkCast,
    nkIdent,
    nkInt,
    nkFloat,
    nkStr,
    nkChar,
    nkBool,
    nkNew,
    nkSizeof,

    // Structural markers the dump prints as bare lines, so a for-loop's three
    // optional clauses stay distinguishable when some are missing.
    nkMarkerInit,
    nkMarkerCond,
    nkMarkerStep};

// Flag bits, one per boolean qualifier a declaration can carry.
#define NF_STATIC $0001
#define NF_VARARGS $0002
#define NF_THROWS $0004
#define NF_OPTIONAL $0008
#define NF_FINAL $0010
#define NF_GLOBAL $0020
#define NF_EXTERN $0040
#define NF_VOLATILE $0080
#define NF_REGISTER $0100
#define NF_ARROW $0200
#define NF_INCLUSIVE $0400
#define NF_FAILABLE $0800
#define NF_DEFAULT $1000
#define NF_RANGE $2000
// `case ..hi:` and `case lo..:` both carry ONE bound, and nothing about the
// node says which — so the open-low form says so itself.
#define NF_RANGE_HI $20000
// A Block that is really a DECL-LIST — `Block a, b, c;` wraps its declarators
// in one. It is not a scope: the original marks it `isDeclList` and the
// analyser has to know, or every declarator after the first is defined in a
// scope that pops immediately. The dump does not print it (neither does the
// original's), so this costs the M5 comparison nothing.
#define NF_DECLLIST $4000
// Placement qualifiers on a signature — `void f(void) :banked`. They do NOT
// appear in the AST dump (neither does the original's), but the IR needs them:
// a banked callee is reached through a different call opcode.
#define NF_BANKED $8000
#define NF_CLOAKED $10000
// `:irq` / `:vbi` — an interrupt handler's prologue and epilogue are not a
// function's, so the symbol has to carry which kind it is.
#define NF_IRQ $40000
#define NF_VBI $80000
// `:xtcStack` / `:hwStack` — the xt6502 calling convention a function asks for,
// overriding the --xtc-stack default. The flag word is full, so :hwStack shares
// its bit with NF_RANGE_HI, which only a `case` label ever carries.
#define NF_XTCSTACK $80000000
#define NF_HWSTACK $20000
// A declaration that came from a C interface, so it uses the C ABI. Set by the
// TOOL on everything it reads out of an interface stub, exactly as the driver
// sets it on what it reads out of DWARF — there is no source syntax for it,
// and adding one would make the port a different language.
#define NF_CABI $200000
// The call carries a literal `...` — the vararg forwarding form — or, on a
// DECLARATION, its body contains one. Only arm9 acts on it: its varargs travel
// in registers, so a forwarder has to relay its own homed tail into the
// callee's slots. private:docs/bugs/047.
#define NF_VAFWD $400000

// `struct X :packed { … }` — size is the raw field sum, no tail rounding.
#define NF_PACKED $800000
// A METHOD CALL that is really a call through a FIELD holding something
// callable — `w.onChange(7)`, `s.fn(6)`. The parser cannot tell (it has no
// types); sema marks it and hangs the rewritten call on the node as one extra
// kid, past the receiver and arguments. The dump does not print that kid —
// neither does the original, which keeps the node as it was written — so the
// M5 comparison is unaffected. private:docs/bugs/074.
#define NF_FIELDCALL $1000000
// A method the ANALYSER made up rather than one the source declared. It is a
// real method — it is called, and it has a symbol — but it did not exist when
// the vtable slots were numbered, so it never fills one.
#define NF_SYNTH $100000
// A declaration reconstructed from a `.xtc.iface` — the class/function lives
// in ANOTHER module; register externs, lower no bodies (stage 3 of
// separate-compilation, mirrored from XTInterfaceImporter's isExternal).
#define NF_EXTERNAL $2000000
// §4.3b: a chain-dispatched category method, round-tripped through the iface
// so an importer refuses to override it (the iface has no chain shape).
#define NF_CHAINM $4000000

// uxkit/026: the designable surface. `outlet` on a field and `:action` on a
// method are markers the DRIVER reads — a class carrying either auto-conforms
// to the binding protocol and has its setOutlet/wireAction bodies synthesised.
// Neither appears in the AST dump (the original does not print them either),
// so they cost the comparison nothing; they exist so the port can synthesise
// the same bodies rather than silently emitting a class with no binding.
// A load-time constructor: its pointer goes into the target's constructor list
// (Mach-O __mod_init_func / ELF .init_array), so it runs before main with no
// call site anywhere. Set by the designable synthesis on the registrar.
// `for (...) : unroll` asked for this loop to be unrolled. A HINT, carried on
// the for node and read by lowering, which records the loop's header block so
// the IR optimiser can raise its trip/body BUDGETS for that loop alone. Like
// the markers above it this never appears in the AST dump — the original does
// not print forceUnroll either, so it costs the comparison nothing.
#define NF_UNROLL $08000000
#define NF_MODINIT $40000000
#define NF_OUTLET $10000000
#define NF_ACTION $20000000

// §6 (tasks #31/#33): `extern` + initialiser on a global = an EXPORTED
// definition — the original stores isExported (never dumped) and leaves
// its dumped extern flag CLEAR; only a bodyless extern global keeps it.
#define NF_EXPORTED $8000000

class Node
    {
    // Strip a collection's ELEMENT annotation: `Array<String>*` -> `Array*`.
    //
    // The ObjC compiler keeps the element type on the type OBJECT and leaves the
    // display name bare, so it prints `Array*`. Types here are strings and have
    // nowhere else to carry it, so it rides in the spelling and comes back off
    // wherever a class is resolved from one — and wherever a type is PRINTED,
    // or the two compilers' dumps would differ on every line mentioning it.
    static String* stripElem(String* t)
        {
        if (t == 0)
            return t;
        u32 lt = (u32)$FFFFFFFF;
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            if (t.byteAt(i) == (u8)'<')
                {
                lt = i;
                i = t.byteLength();
                }
        if (lt == (u32)$FFFFFFFF)
            return t;
        u32 gt = (u32)$FFFFFFFF;
        for (u32 i = t.byteLength(); i > lt; i = i - (u32)1)
            if (t.byteAt(i - (u32)1) == (u8)'>')
                {
                gt = i - (u32)1;
                i = lt;
                }
        if (gt == (u32)$FFFFFFFF)
            return t;
        String* out = t.substringBytes((u32)0, lt);
        out.append(t.substringBytes(gt + (u32)1, t.byteLength() - gt - (u32)1));
        return out;
        }

    // The ELEMENT (or, in `Map<K,V>`, the VALUE) type, or 0 when the spelling
    // carries none. With two arguments it is the one after the comma — the
    // original's rule, where `Object*` takes the last type argument.
    static String* elemOf(String* t)
        {
        String* inner = argsOf(t);
        if (inner == 0)
            return (String*)0;
        u32 c = topLevelComma(inner);
        if (c == (u32)$FFFFFFFF)
            return inner;
        return inner.substringBytes(c + (u32)1, inner.byteLength() - c - (u32)1);
        }

    // The KEY type — the `K` in `Map<K, V>` — or 0 when only one argument was
    // written. `Map<V>` and `Set<T>` therefore leave their key positions
    // unchecked exactly as before. private:docs/bugs/049.
    static String* keyOf(String* t)
        {
        String* inner = argsOf(t);
        if (inner == 0)
            return (String*)0;
        u32 c = topLevelComma(inner);
        if (c == (u32)$FFFFFFFF)
            return (String*)0;
        return inner.substringBytes((u32)0, c);
        }

    // The text between the OUTERMOST `<` and its matching `>`.
    static String* argsOf(String* t)
        {
        if (t == 0)
            return (String*)0;
        u32 lt = (u32)$FFFFFFFF;
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            if (t.byteAt(i) == (u8)'<')
                {
                lt = i;
                i = t.byteLength();
                }
        if (lt == (u32)$FFFFFFFF)
            return (String*)0;
        u32 gt = (u32)$FFFFFFFF;
        for (u32 i = t.byteLength(); i > lt; i = i - (u32)1)
            if (t.byteAt(i - (u32)1) == (u8)'>')
                {
                gt = i - (u32)1;
                i = lt;
                }
        if (gt == (u32)$FFFFFFFF)
            return (String*)0;
        return t.substringBytes(lt + (u32)1, gt - lt - (u32)1);
        }

    // Index of the comma separating the two type arguments, or $FFFFFFFF.
    // DEPTH-AWARE: `Map<String, Array<i32>>` has one top-level comma, and a
    // nested `Map<String, Map<u16, Point>>` must not split on the inner one.
    static u32 topLevelComma(String* inner)
        {
        u32 depth = (u32)0;
        for (u32 i = (u32)0; i < inner.byteLength(); i = i + (u32)1)
            {
            u8 c = inner.byteAt(i);
            if (c == (u8)'<')
                depth = depth + (u32)1;
            else if (c == (u8)'>')
                {
                if (depth > (u32)0)
                    depth = depth - (u32)1;
                }
            else if (c == (u8)',' && depth == (u32)0)
                return i;
            }
        return (u32)$FFFFFFFF;
        }

    u16 _kind;

    // Where this node was written. `_line`/`_col` were already here; the FILE
    // was not, so a diagnostic could not name one — every error read
    // `xc-fe: <input>: error: …` whatever file the construct was actually in.
    //
    // An interned ID, not a String: see FileTable. A name retained once per
    // node wraps the runtime's u16 refcount on a large file and frees a live
    // string.
    u32 _fileId;
    String* _name;  // identifier / member / callee / type spelling
    String* _op;    // operator spelling, or a type spelling on a declaration
    String* _extra; // one more string, for the kinds that need three
    // A literal's VALUE, and — on the kinds that have no literal — a small
    // count (call args, a `delete` opcode). 64 bits because the first of those
    // must hold anything `i64`/`u64` can spell; the counts are unaffected.
    i64 _num;
    u32 _flags;
    Array* _kids; // of Node@
    u32 _line;
    // The wasm PACKAGE a declaration reconstructed from a library interface
    // resolves through: `libX.wasm` -> "X". Its own slot rather than `extra`,
    // which a class already uses for its protocol list — one field, two
    // meanings, is how a class silently lost either its package or its
    // conformances depending on which writer ran last.
    String* _pkg;
    // The slot map an INTERFACE publishes: the root-loop answer, before the
    // protocol loop rewrites a requirement's name to the PROTOCOL slot. A
    // client dispatching on the class itself uses the class slot; publishing
    // the protocol one sent `p.ping()` off the end of the table.
    Map* _islots;
    Map* _isyms;          // ifaceSlots keyed by impl symbol
    u32 _col;

    // ── What the ANALYSER stamps (M6) ───────────────────────────────────
    // Empty on a tree straight from the parser, which is why the M5 dump can
    // ignore them entirely. `_ty` is the resolved type SPELLING — the oracle
    // prints XTType.displayName, so a spelling is exactly what has to match,
    // and carrying spellings rather than a type graph is a deliberate saving:
    // the analyser only needs structure where it reasons (widening, deref),
    // not to attribute every expression.
    String* _ty;         // resolved type spelling
    String* _sym;        // mangled symbol a call resolved to / a decl defines
    String* _cls;        // the class that owns the resolved method
    i32 _vslot;          // virtual slot, or -1
    bool _autoSuper;     // an `init` that gets `super.init()` injected
    bool _indirect;      // a call through a variable, not to a symbol
    bool _boundCall;     // …and specifically through a bound method
    String* _setter;     // a property WRITE: the setter the assignment became…
    String* _setterCls;  // …and the class that declared it
    String* _getter;     // a property READ: the getter it became…
    String* _getterCls;  // …and the class that declared it
    String* _bound;      // `&obj.method`: the method it resolved to…
    String* _boundCls;   // …and the class that owns it
    i32 _boundSlot;      // a bound method's slot, when it goes through a protocol
    String* _boundProto; // …the protocol it belongs to…
    i32 _boundPIdx;      // …and its index within that protocol
    String* _proto;      // the protocol a call dispatches through…
    i32 _protoIdx;       // …and the method's index within it
    Map* _slots;         // methodName -> slot, for a class with a vtable
    Map* _symSlots;      // impl symbol (`<Class>$<mangled>`) -> slot: what a
                         // call reads, since each overload owns its own slot
    Array* _slotSyms;    // slot -> the impl symbol this class puts there ("")
    u32 _vslots;         // the table's width (the program-wide total)
    String* _since;      // since("V") on a member: version that introduced it
    String* _category;   // category/extension marker (see setCategory)
    String* _catHost;    // §4.2: on a METHOD a category added to an
                         // EXTERNAL class — the extended class's name.
                         // Mirrors importedCategoryHost; nil elsewhere.
    bool _usedByNew;     // a class the program instantiates
    bool _heapRecv;      // a method reached through a heap receiver…
    bool _stackRecv;     // …and one reached through a stack instance

    void init(void)
        {
        _kind = (u16)0;
        _name = (String*)0;
        _since = (String*)0;
        _op = (String*)0;
        _extra = (String*)0;
        _num = (i64)0;
        _flags = (u32)0;
        _kids = new Array();
        _line = (u32)0;
        _pkg = (String*)0;
        _islots = (Map*)0;
        _isyms = (Map*)0;
        _col = (u32)0;
        _fileId = (u32)0;
        _ty = (String*)0;
        _sym = (String*)0;
        _cls = (String*)0;
        _vslot = (i32)-1;
        _autoSuper = false;
        _indirect = false;
        _boundCall = false;
        _setter = (String*)0;
        _setterCls = (String*)0;
        _getter = (String*)0;
        _getterCls = (String*)0;
        _bound = (String*)0;
        _boundCls = (String*)0;
        _boundSlot = (i32)-1;
        _boundProto = (String*)0;
        _boundPIdx = (i32)-1;
        _proto = (String*)0;
        _protoIdx = (i32)-1;
        _slots = (Map*)0;
        _symSlots = (Map*)0;
        _slotSyms = (Array*)0;
        _vslots = (u32)0;
        _usedByNew = false;
        _heapRecv = false;
        _stackRecv = false;
        }

    bool autoSuperInit(void)
        {
        return _autoSuper;
        }
    void setAutoSuperInit(void)
        {
        _autoSuper = true;
        }
    bool indirect(void)
        {
        return _indirect;
        }
    bool boundCall(void)
        {
        return _boundCall;
        }
    void setIndirect(bool bound)
        {
        _indirect = true;
        _boundCall = bound;
        }
    String* setter(void)
        {
        return _setter;
        }
    String* setterCls(void)
        {
        return _setterCls;
        }
    void setSetter(String* m, String* c)
        {
        _setter = m;
        _setterCls = c;
        }
    String* getter(void)
        {
        return _getter;
        }
    String* getterCls(void)
        {
        return _getterCls;
        }
    void setGetter(String* m, String* c)
        {
        _getter = m;
        _getterCls = c;
        }
    String* bound(void)
        {
        return _bound;
        }
    String* boundCls(void)
        {
        return _boundCls;
        }
    void setBound(String* m, String* c)
        {
        _bound = m;
        _boundCls = c;
        }
    i32 boundSlot(void)
        {
        return _boundSlot;
        }
    String* boundProto(void)
        {
        return _boundProto;
        }
    i32 boundPIdx(void)
        {
        return _boundPIdx;
        }
    void setBoundProto(i32 slot, String* p, i32 idx)
        {
        _boundSlot = slot;
        _boundProto = p;
        _boundPIdx = idx;
        }
    String* proto(void)
        {
        return _proto;
        }
    i32 protoIdx(void)
        {
        return _protoIdx;
        }
    void setProto(String* p, i32 idx)
        {
        _proto = p;
        _protoIdx = idx;
        }
    Map* slots(void)
        {
        return _slots;
        }
    u32 vslots(void)
        {
        return _vslots;
        }
    void setSlots(Map* m, u32 total)
        {
        _slots = m;
        _vslots = total;
        }
    Map* symSlots(void)
        {
        return _symSlots;
        }
    void setSymSlots(Map* m)
        {
        _symSlots = m;
        }
    Array* slotSyms(void)
        {
        return _slotSyms;
        }
    void setSlotSyms(Array* a)
        {
        _slotSyms = a;
        }

    // §4.2/§4.3b, on a CLASS in a chain-extended family: the extended class,
    // the owner-anchor symbol (`<Host>$cat$<names>`), method name -> chain
    // slot, and the host's slot COUNT (every family table is sized to it).
    // All nil/zero outside such a family; the impl SYMBOL per slot resolves
    // in the lowering, exactly as vtable slots do. Mirrors
    // categoryChainHost / -Anchor / -MethodSlots on XTClassDeclNode.
    String* _chainHost;
    String* _chainAnchor;
    Map* _chainSlots;
    u32 _chainCount;
    String* chainHost(void)
        {
        return _chainHost;
        }
    String* chainAnchor(void)
        {
        return _chainAnchor;
        }
    Map* chainSlots(void)
        {
        return _chainSlots;
        }
    u32 chainCount(void)
        {
        return _chainCount;
        }
    void setChain(String* host, String* anchor, Map* slots, u32 count)
        {
        _chainHost = host;
        _chainAnchor = anchor;
        _chainSlots = slots;
        _chainCount = count;
        }
    bool usedByNew(void)
        {
        return _usedByNew;
        }
    bool heapRecv(void)
        {
        return _heapRecv;
        }
    bool stackRecv(void)
        {
        return _stackRecv;
        }
    // Category / extension marker on a ClassDecl. "" is an extension `()`; a
    // name is a category `(Name)`; 0 means an ordinary class. Deliberately NOT
    // printed by the AST dump — the reference does not print it either, so a
    // category file dumps identically in both compilers.
    // private:docs/Design/separate-compilation.md 4.
    String* category(void)
        {
        return _category;
        }
    void setCategory(String* c)
        {
        _category = c;
        }
    bool isCategory(void)
        {
        return _category != (String*)0;
        }
    String* importedCatHost(void)
        {
        return _catHost;
        }
    void setImportedCatHost(String* h)
        {
        _catHost = h;
        }

    void setUsedByNew(void)
        {
        _usedByNew = true;
        }
    void setHeapRecv(void)
        {
        _heapRecv = true;
        }
    void setStackRecv(void)
        {
        _stackRecv = true;
        }

    String* ty(void)
        {
        return _ty;
        }
    String* sym(void)
        {
        return _sym;
        }
    String* cls(void)
        {
        return _cls;
        }
    i32 vslot(void)
        {
        return _vslot;
        }
    void setTy(String* t)
        {
        _ty = t;
        }
    void setSym(String* s)
        {
        _sym = s;
        }
    void setCls(String* c)
        {
        _cls = c;
        }
    void setVslot(i32 v)
        {
        _vslot = v;
        }

    static Node* with(u16 kind)
        {
        Node* n = new Node();
        n._kind = kind;
        return n;
        }

    static Node* withName(u16 kind, String* name)
        {
        Node* n = Node.with(kind);
        n._name = name;
        return n;
        }

    u16 kind(void)
        {
        return _kind;
        }
    String* file(void)
        {
        return FileTable.name(_fileId);
        }
    void setPos(u32 fileId, u32 l, u32 c)
        {
        _fileId = fileId;
        _line = l;
        _col = c;
        }
    String* name(void)
        {
        return _name;
        }
    String* op(void)
        {
        return _op;
        }
    String* extra(void)
        {
        return _extra;
        }
    i64 num(void)
        {
        return _num;
        }
    u32 flags(void)
        {
        return _flags;
        }
    Array* kids(void)
        {
        return _kids;
        }
    u32 line(void)
        {
        return _line;
        }
    u32 col(void)
        {
        return _col;
        }

    void setName(String* s)
        {
        _name = s;
        }
    void setOp(String* s)
        {
        _op = s;
        }
    void setExtra(String* s)
        {
        _extra = s;
        }
    Map* ifaceSlots(void)
        {
        return _islots;
        }
    void setIfaceSlots(Map* m)
        {
        _islots = m;
        }
    // The same snapshot keyed by impl symbol (`<Class>$<mangled>`), which
    // tells overloads of one name apart.
    Map* ifaceSymSlots(void)
        {
        return _isyms;
        }
    void setIfaceSymSlots(Map* m)
        {
        _isyms = m;
        }
    String* pkg(void)
        {
        return _pkg;
        }
    void setPkg(String* s)
        {
        _pkg = s;
        }
    String* since(void)
        {
        return _since;
        }
    void setSince(String* s)
        {
        _since = s;
        }
    void setNum(i64 v)
        {
        _num = v;
        }
    void setFlags(u32 f)
        {
        _flags = f;
        }
    void addFlag(u32 f)
        {
        _flags = _flags | f;
        }
    bool hasFlag(u32 f)
        {
        return (_flags & f) != (u32)0;
        }
    void setAt(u32 line, u32 col)
        {
        _line = line;
        _col = col;
        }

    // A null child is DROPPED rather than stored: an optional clause that is
    // absent must not become a hole the dumper has to describe.
    void add(Node* kid)
        {
        if (kid == 0)
            return;
        _kids.add((Object*)kid);
        }

    // Replace a child in place — sema rewrites `a.p += x` into `a.p = a.p + x`,
    // which means swapping the right-hand side for a synthesised binary.
    void setKid(u32 i, Node* n)
        {
        _kids.set(i, (Object*)n);
        }

    // Drop a child. Sema uses it to remove a category/extension node once its
    // members have been merged into the class: the part is spent, and leaving
    // it in the program would dump a second ClassDecl and lower its methods a
    // second time.
    void dropKid(u32 i)
        {
        if (i < _kids.count())
            _kids.removeAt(i);
        }

    // Insert a child at a position. The iface importer PREPENDS a module's
    // reconstructed declarations, as the reference driver does — imported
    // decls go in FRONT of the program's own.
    void insertKid(u32 i, Node* n)
        {
        if (n == 0)
            return;
        if (i > _kids.count())
            i = _kids.count();
        _kids.insert(i, (Object*)n);
        }

    // Insert BEFORE the first method. A class node keeps ivars and methods in
    // ONE child list, ivars first — the reference keeps two lists, so appending
    // an extension's ivar there lands it correctly while appending here would
    // put it after the methods and reorder the dump.
    void addIvarBeforeMethods(Node* iv)
        {
        u32 at = _kids.count();
        for (u32 i = (u32)0; i < _kids.count(); i = i + (u32)1)
            {
            if (((Node*)_kids.get(i)).kind() == (u16)nkMethodDecl)
                {
                at = i;
                break;
                }
            }
        _kids.insert(at, (Object*)iv);
        }

    Node* kid(u32 i)
        {
        if (i >= _kids.count())
            return (Node*)0;
        return (Node*)_kids.get(i);
        }

    u32 kidCount(void)
        {
        return _kids.count();
        }
    }
