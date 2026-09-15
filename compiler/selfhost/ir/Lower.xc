// Lower.xc — the analysed AST becomes IR.
// =================================================================
//
// self-hosting M6b. The port of XTIRLowering (13,425 lines, the largest file
// in the tree). This is the first slice: whole functions, but only the
// straight-line shapes — parameters, locals, integer arithmetic, casts,
// calls, globals, return. Control flow (the phi placement at joins and loop
// headers) is the next slice and is where the real complexity is.
//
// The oracle is `xtc-fe` itself — its ordinary output IS this text — so
// `selfhost/tools/ir-diff.sh` needs no new dump mode on the original.
//
// Two invariants worth stating because everything else follows from them:
//
//   * EVERY value carries its AST type spelling alongside its IR type, and a
//     value only ever changes type through `coerce`. The original threads
//     XTType through the same places; carrying the spelling is the same
//     shortcut the parser and analyser ports took.
//   * The memory token is a single-threaded chain. Every instruction that
//     touches memory consumes `_mem` and produces the next one, and the
//     Return names the last. Losing the chain does not fail loudly — it
//     produces IR that reads correctly and orders wrongly.

#import "Foundation.xc"
#import "Node.xc"
#import "Types.xc"
#import "Vtable.xc"
#import "Ir.xc"
#import "FloatEncoding.xc"

// What the lowering knows about one class: where its instance keeps things,
// which slot each method dispatches through, and the shape a pointer to it has.
// Built once per class, parent first, because a subclass's ivars sit after the
// parent's and its vtable inherits the parent's slot numbering.
class ClassInfo
    {
    String* _name;
    ClassInfo* _parent;
    Node* _decl;
    u32 _classId;
    bool _needsVtable;
    String* _agg;     // `Agg(N)` — the instance layout
    String* _selfPtr; // `Ptr(Agg(N), unbanked)` — what a reference is
    u32 _instSize;
    Map* _ivarIndex;     // ivar name -> its FIELD index in the instance
    Map* _ivarType;      // ivar name -> its declared type spelling
    Map* _methodSlot;    // method name -> its vtable slot
    Map* _methodMangled; // method name -> the symbol suffix it compiles to
    Array* _vtblEntries; // slot -> the symbol that fills it ("" = none)
    Map* _catSlot;       // §4.2: method name -> its CHAIN slot
    String* _catAnchor;  // §4.3b: the owner-anchor symbol, or nil

    void init(void)
        {
        _classId = (u32)0;
        _needsVtable = false;
        _instSize = (u32)0;
        _ivarIndex = new Map();
        _ivarType = new Map();
        _methodSlot = new Map();
        _methodMangled = new Map();
        _vtblEntries = new Array();
        }

    String* name(void)
        {
        return _name;
        }
    ClassInfo* parent(void)
        {
        return _parent;
        }
    Node* decl(void)
        {
        return _decl;
        }
    u32 classId(void)
        {
        return _classId;
        }
    bool needsVtable(void)
        {
        return _needsVtable;
        }
    String* agg(void)
        {
        return _agg;
        }
    String* selfPtr(void)
        {
        return _selfPtr;
        }
    u32 instSize(void)
        {
        return _instSize;
        }
    Map* ivarIndex(void)
        {
        return _ivarIndex;
        }
    Map* ivarType(void)
        {
        return _ivarType;
        }
    Map* methodSlot(void)
        {
        return _methodSlot;
        }
    Map* methodMangled(void)
        {
        return _methodMangled;
        }
    Array* vtblEntries(void)
        {
        return _vtblEntries;
        }
    Map* catSlot(void)
        {
        return _catSlot;
        }
    String* catAnchor(void)
        {
        return _catAnchor;
        }
    void setCat(Map* slots, String* anchor)
        {
        _catSlot = slots;
        _catAnchor = anchor;
        }

    void setName(String* n)
        {
        _name = n;
        }
    void setParent(ClassInfo* p)
        {
        _parent = p;
        }
    void setDecl(Node* d)
        {
        _decl = d;
        }
    void setClassId(u32 v)
        {
        _classId = v;
        }
    void setNeedsVtable(bool v)
        {
        _needsVtable = v;
        }
    void setAgg(String* a, String* p)
        {
        _agg = a;
        _selfPtr = p;
        }
    void setInstSize(u32 v)
        {
        _instSize = v;
        }
    }

    // One shadowed binding's saved state (the reference's shadow-save entry):
    // everything the name-keyed tables held for `name` at the moment a nested
    // declaration rebound it, restored verbatim when the shadowing scope pops.
    // Object* fields hold the map entries (0 = the table had none); the bools
    // are the membership lists.
    class ShadowSave
    {
    String* _name;
    Object* _local;        // _locals value
    Object* _localTy;      // _localTypes spelling
    bool _strong;          // in _strongLocals
    bool _weakPinned;      // in _weakLocals
    Object* _strongArr;    // _strongArray entry
    Object* _weakArr;      // _weakArray entry
    Object* _strongStruct; // _strongStruct entry
    Object* _pins;         // _pins entry
    Object* _pinAst;       // _pinAst entry
    Object* _heapLen;      // _heapArrayLen entry
    Object* _arrElem;      // _arrayElem entry

    void init(void)
        {
        _name = (String*)0;
        _local = (Object*)0;
        _localTy = (Object*)0;
        _strong = false;
        _weakPinned = false;
        _strongArr = (Object*)0;
        _weakArr = (Object*)0;
        _strongStruct = (Object*)0;
        _pins = (Object*)0;
        _pinAst = (Object*)0;
        _heapLen = (Object*)0;
        _arrElem = (Object*)0;
        }
    String* name(void)
        {
        return _name;
        }
    void setName(String* n)
        {
        _name = n;
        }
    Object* local(void)
        {
        return _local;
        }
    void setLocal(Object* v)
        {
        _local = v;
        }
    Object* localTy(void)
        {
        return _localTy;
        }
    void setLocalTy(Object* v)
        {
        _localTy = v;
        }
    bool strong(void)
        {
        return _strong;
        }
    void setStrong(bool v)
        {
        _strong = v;
        }
    bool weakPinned(void)
        {
        return _weakPinned;
        }
    void setWeakPinned(bool v)
        {
        _weakPinned = v;
        }
    Object* strongArr(void)
        {
        return _strongArr;
        }
    void setStrongArr(Object* v)
        {
        _strongArr = v;
        }
    Object* weakArr(void)
        {
        return _weakArr;
        }
    void setWeakArr(Object* v)
        {
        _weakArr = v;
        }
    Object* strongStruct(void)
        {
        return _strongStruct;
        }
    void setStrongStruct(Object* v)
        {
        _strongStruct = v;
        }
    Object* pins(void)
        {
        return _pins;
        }
    void setPins(Object* v)
        {
        _pins = v;
        }
    Object* pinAst(void)
        {
        return _pinAst;
        }
    void setPinAst(Object* v)
        {
        _pinAst = v;
        }
    Object* heapLen(void)
        {
        return _heapLen;
        }
    void setHeapLen(Object* v)
        {
        _heapLen = v;
        }
    Object* arrElem(void)
        {
        return _arrElem;
        }
    void setArrElem(Object* v)
        {
        _arrElem = v;
        }
    }

    class Lower
    {
    // The target's pointer width, as the FRONT END sees it — 3 on the banked
    // 6502 ([addr-lo, addr-hi, bank]), 8 on a 64-bit host, 4 on m68k/arm9. It
    // is the width every SIZE is summed from: struct offsets, array strides,
    // the vtable slot, a weak slot's two hidden link words. The IR type of a
    // pointer carries no width at all, so this is the only place it is known,
    // and a value that disagrees with the backend's own reads as a loop
    // miscompile rather than a layout error (private:docs/Design/type-width-invariant.md).
    u32 _ptrW;
    u32 _fieldCap; // struct FIELD alignment cap (blewit #5): 8 register targets, 2 m68k, 1 xt6502
    u32 _tailCap;  // sizeof tail-rounding cap: 2 m68k, 8 everywhere else (xt6502 keeps pow2 tail)
    // Runtime-ancestry vtables: entry 0 is the PARENT class's vtable, and the
    // class downcast walks the chain — so a subclass defined in ANOTHER module
    // is still recognised as its base. ON for the backends that link separate
    // shared objects (arm64/x86_64/win64/arm9), OFF for xt6502 and m68k, which
    // keep the compile-time-subtree downcast and a parent-free vtable.
    bool _vtAncestry;
    // Conformance itable: each class carries a (protoId, &table) list so a
    // runtime `(P@ ?)obj` downcast can search the protocol ids. It reserves a
    // vtable entry in EVERY class — a search site has to find it at the same
    // offset whatever the receiver turns out to be.
    bool _vtItable;
    // Itable DISPATCH: a protocol-bound call goes through the object's itable
    // (protocol id + the requirement's index in the protocol's own
    // declaration) rather than a program-global vtable slot. ON for arm9, the
    // one target that can be linked as several modules, where a
    // program-global slot number is unachievable — nobody is there to hand it
    // out. Everywhere else the flat slot is the faster answer.
    bool _itableDispatch;
    IRLayout* _pendingCatLay; // §4.2 clay, emitted between play and vt (task #36)
    IRSymbol* _pendingCatSym; // …and the $cat symbol rides with it
    // Native va_list target (arm9): a variadic callee reads its tail from the
    // AAPCS register save area, so the tail is C default-promoted and passed
    // as real arguments instead of packed into `__xtc_va_buf`. That is what
    // lets an xtc `printf` hand a REAL va_list on to libc.
    bool _nativeVarargs;
    // Race-free static-init once (private:docs/Design/threading.md §9.5). -1 = decide
    // per module, 0/1 = forced by -f[no-]thread-safe-arc. Mirrors
    // XTIRLowering's sThreadSafeStatics; the two lowerings must agree
    // instruction for instruction.
    i32 _tssMode;
    // -fbounds-check: every subscript is checked against its allocation's own
    // header before the address is used. Off by default; an ordinary build emits
    // none of this and links none of the runtime.
    bool _boundsCheck;
    bool _threadSafeStatics;
    // Globals whose initialiser could not constant-fold: run as ordinary
    // stores at the top of main (mirror of pendingGlobalInits).
    Array* _pendingGlobalInits;
    IRModule* _m;
    IRFunc* _fn;
    IRBlock* _blk;
    IRValue* _mem;
    Map* _locals;     // name -> IRValue@, the SSA value each name holds
    Map* _localTypes; // name -> its AST type spelling
    Map* _globals;    // name -> its AST type spelling
    Map* _funcs;      // name -> its FunctionDecl node
    bool _failed;     // a shape this slice does not lower yet

    // ── aggregates and frame slots ───────────────────────────────────────
    // A struct or an array has no SSA value: the storage IS the answer. Both
    // are described by a module LAYOUT (referred to as `Agg(N)`), and a local
    // of either type gets a frame slot — a PINNED local — that every access
    // goes through. So does any local whose address is taken, for the same
    // reason: `&x` has to name something that outlives the expression.
    Map* _structs;         // struct / typedef name -> its StructDecl node
    Map* _layoutIds;       // an aggregate spelling -> its module layout index
    Map* _layoutPending;   // a spelling being laid out -> its placeholder
    u32 _layoutTick;       // makes each placeholder distinct
    Map* _pins;            // name -> IRPinned@, the slot it lives in
    Map* _pinnedParamInit; // &-taken scalar param name -> its incoming value (bug 202)
    Map* _gotoLabelBlocks; // goto label name -> IRBlock@ (C-porting aid)
    Map* _gotoLabelDepths; // goto label name -> arc-scope depth at the label
    Map* _pinAst;          // name -> the AST spelling that slot holds
    // Every declaration's slot, in order, for a name declared more than once —
    // and how many of them the lowering has walked past.
    Map* _pinDeclTys;
    Map* _pinSeq;
    Map* _pinNext;
    Map* _arrayElem;    // name -> element spelling, for the array locals
    Array* _ampTaken;   // names an `&` was applied to
    Array* _vaCursors;  // names handed to a va_* intrinsic as its cursor
    Array* _asmNamed;   // names an inline-asm body mentions
    Array* _weakLocals; // pinned names that are AUTO-ZEROING slots
    Map* _boundPair;    // a `^` spelling -> its {recv, code} layout
    Map* _tramps;       // a `^` signature -> its trampoline symbol name
    Array* _pendingFns; // functions synthesised while another was lowering

    // ── classes and ARC ──────────────────────────────────────────────────
    Map* _classDecls;   // class name -> its ClassDecl node
    Map* _classes;      // class name -> its ClassInfo
    Map* _scanBusy;     // class names whose preScanLayout is on the stack
    Map* _scanRestDone; // class names whose phase-2 pre-scan has run
    Map* _classIds;     // class name -> its RTTI id, 1..N in NAME order
    Map* _protocols;    // protocol name -> its ProtocolDecl node
    Map* _sdata;        // class name -> its static-storage symbol
    Map* _enumConsts;   // enum member name -> its value
    Map* _enums;        // enum TYPE name -> its declaration
    Map* _methodRetIr;  // method symbol -> the IR return type its symbol got
    Map* _methodParIr;  // …and the IR parameter types, frozen with it
    // Classes whose user `dealloc` explicitly calls `super.dealloc()`: the
    // teardown must not append a second one.
    Array* _deallocCallsSuper;
    Array* _usedClasses; // classes named by `use X;` — their statics answer
                         // a bare call
    Map* _tupleAgg;      // an IR function name -> its `Agg(N)` return
    u32 _staticLocals;   // how many function-local statics have been made
    // …and, for the function being lowered, the module symbol each one's name
    // stands for. Per-function: the name is a LOCAL one and must not be
    // visible to the next function that happens to reuse it.
    Map* _staticLocalName;
    String* _staticSelfClass; // set while lowering a STATIC method's body
    Map* _funcsBySym;         // mangled name -> the declaration it names
    Map* _heapArrayLen;       // a local bound to `new T[N]` -> that N
    Array* _shadowScopes;     // per arc scope: ShadowSave@ for names it shadowed
    Map* _staticIvar;         // "<Class>.<ivar>" -> its module global's name
    Map* _staticIvarTy;       // …and its declared type
    Vtable* _vt;              // the analyser's slot assignment, for protocol fills
    Map* _valueClass;         // local name -> the class whose INSTANCE it is
    Node* _objectDecl;        // the implicit root every parentless class gets
    ClassInfo* _curClass;     // the class whose method is being lowered
    String* _curMethodName;   // …and its NAME, for the self-wrapper carve-out
    IRValue* _self;           // …and its receiver
    IRValue* _retainedSelf;   // …and the retain to undo at every exit, if any
    Array* _arcScopes;        // Array@ per scope of the strong names it owns
    Array* _tryHandlers;      // the enclosing `catch` blocks, innermost last
    bool _fnThrows;           // the function being lowered is declared `throws`
    Array* _deferScopes;      // per open scope, the `defer` bodies it registered
    Array* _strongLocals;     // every name currently holding an owned reference
    Array* _assignedNames;    // names the body assigns whose slot is a class ptr
    Array* _strongParams;     // params those made strong, awaiting enrolment
    Array* _synthDealloc;     // classes given a generated destructor
    Map* _weakArray;          // a local ARRAY of auto-zeroing slots -> its type
    Map* _strongArray;        // a local ARRAY of class pointers -> its type
    Map* _strongStruct;       // struct local -> its type, when it owns a class ref
    Array* _bcTo;             // Bitcast result …
    Array* _bcFrom;           // …and what it was cast FROM

    void init(void)
        {
        _ptrW = (u32)3;
        _fieldCap = (u32)1;
        _tailCap = (u32)8;
        _vtAncestry = false;
        _vtItable = false;
        _itableDispatch = false;
        _pendingCatLay = (IRLayout*)0;
        _pendingCatSym = (IRSymbol*)0;
        _nativeVarargs = false;
        _tssMode = (i32)-1;
        _boundsCheck = false;
        _threadSafeStatics = false;
        _locals = new Map();
        _localTypes = new Map();
        _globals = new Map();
        _funcs = new Map();
        _structs = new Map();
        _layoutIds = new Map();
        _layoutPending = new Map();
        _layoutTick = (u32)0;
        _pins = new Map();
        _pinAst = new Map();
        _pinDeclTys = new Map();
        _pinSeq = new Map();
        _pinNext = new Map();
        _arrayElem = new Map();
        _ampTaken = new Array();
        _assignedNames = new Array();
        _vaCursors = new Array();
        _asmNamed = new Array();
        _weakLocals = new Array();
        _boundPair = new Map();
        _tramps = new Map();
        _pendingFns = new Array();
        _classDecls = new Map();
        _classes = new Map();
        _scanBusy = new Map();
        _scanRestDone = new Map();
        _classIds = new Map();
        _protocols = new Map();
        _sdata = new Map();
        _enumConsts = new Map();
        _enums = new Map();
        _methodRetIr = new Map();
        _methodParIr = new Map();
        _deallocCallsSuper = new Array();
        _usedClasses = new Array();
        _tupleAgg = new Map();
        _staticLocals = (u32)0;
        _staticLocalName = new Map();
        _funcsBySym = new Map();
        _heapArrayLen = new Map();
        _shadowScopes = new Array();
        _staticIvar = new Map();
        _staticIvarTy = new Map();
        _valueClass = new Map();
        _arcScopes = new Array();
        _deferScopes = new Array();
        _strongLocals = new Array();
        _synthDealloc = new Array();
        _strongStruct = new Map();
        _bcTo = new Array();
        _bcFrom = new Array();
        _failed = false;
        }

    static Lower* make(void)
        {
        return new Lower();
        }

    // The analyser's slot table. A class's own `slots` map says which slot
    // each of ITS method names occupies; the protocol tables say which slot a
    // protocol REQUIREMENT occupies, and one method can fill both — `equals`
    // is Comparable's requirement AND Hashable's, at two different slots.
    void setPointerWidth(u32 w)
        {
        _ptrW = w;
        }
    void setAlignCaps(u32 f, u32 t)
        {
        _fieldCap = f;
        _tailCap = t;
        }
    void setVtableAncestry(bool v)
        {
        _vtAncestry = v;
        }
    void setVtableItable(bool v)
        {
        _vtItable = v;
        }
    void setItableDispatch(bool v)
        {
        _itableDispatch = v;
        }
    void setNativeVarargs(bool v)
        {
        _nativeVarargs = v;
        }
    void setThreadSafeStatics(i32 mode)
        {
        _tssMode = mode;
        }
    void setBoundsCheck(bool b)
        {
        _boundsCheck = b;
        }

    void setVtable(Vtable* v)
        {
        _vt = v;
        }

    bool failed(void)
        {
        return _failed;
        }
    String* why(void)
        {
        return _why;
        }

    // WHAT stopped it, not just that something did. A slice that fails
    // silently tells you nothing about which slice to write next.
    String* _why;
    void giveUp(String* what)
        {
        if (!_failed)
            _why = what;
        _failed = true;
        }

    // The same, placed at the node the complaint is about. Worth the extra
    // argument: the report that led to this said the only diagnostic named the
    // enclosing FUNCTION, which was several hundred lines, so there was nothing
    // to bisect towards but deleting code.
    void giveUpAt(String* what, Node* n)
        {
        if (n == 0 || n.line() == (u32)0)
            {
            giveUp(what);
            return;
            }
        String* out = String.withCString("");
        out.append(n.file() != 0 ? n.file() : String.withCString("?"));
        out.appendByte((u8)':');
        out.append(String.withU32(n.line()));
        out.appendByte((u8)':');
        out.append(String.withU32(n.col()));
        out.appendCString(": ");
        out.append(what);
        giveUp(out);
        }

    // A phi's incomings must ALL have the phi's own type. When they do not the
    // IR is malformed on every target — but a machine with untyped registers
    // runs it anyway, so the mismatch survives codegen and surfaces as a wasm
    // module that will not instantiate, reported against a whole function by a
    // validator that has never heard of the source. That was bug 092 (a
    // comparison typed as its operands, unioned with a bool arm in a ternary).
    // Refusing here turns the same mistake into a compile error at the line.
    // `Ptr(Void)` -> `Ptr`, `I64` -> `I64`: everything up to the first '('.
    String* irKindOf(String* t)
        {
        u32 i = (u32)0;
        while (i < t.byteLength() && t.byteAt(i) != (u8)'(')
            i = i + (u32)1;
        return t.substringBytes((u32)0, i);
        }

    void checkPhiIncoming(IRValue* res, IRValue* v, Node* n)
        {
        if (_failed || res == 0 || v == 0)
            return;
        if (res.ty() == 0 || v.ty() == 0)
            return;
        // KIND, not the whole spelling: two `Ptr(...)` with different pointees
        // are the same machine value and meet at a phi legitimately, so
        // comparing spellings would reject working code. What cannot be merged
        // is a Bool where an I64 is expected — a difference of kind.
        if (irKindOf(res.ty()).equals(irKindOf(v.ty())))
            return;
        String* w = String.withCString("internal: this expression's branches produce different types (");
        w.append(res.ty());
        w.appendCString(" and ");
        w.append(v.ty());
        w.appendCString(") — the two would meet in a value that cannot hold both");
        giveUpAt(w, n);
        }

    // ── types ────────────────────────────────────────────────────────────
    // An AST type spelling becomes an IR type spelling. Qualifiers are
    // placement, not identity, and never reach the IR.
    String* irType(String* t)
        {
        if (t == 0)
            return String.withCString("Void");
        String* s = stripQual(t);
        // A class REFERENCE is a pointer to the instance, and both spellings
        // say the same thing: `Foo` and `Foo@` are the same IR type, because a
        // class value IS a reference. Nesting a pointer around it — which the
        // generic `@` rule below would do for `Foo@` — would describe a
        // pointer to a pointer, and every field access would be off by an
        // indirection.
        if (s.byteLength() > (u32)0 && s.byteAt(s.byteLength() - (u32)1) == (u8)'*')
            {
            ClassInfo* pc = classResolving(s.substringBytes((u32)0, s.byteLength() - (u32)1));
            if (pc != 0)
                return pc.selfPtr();
            }
        if (isBoundSig(s))
            return boundPairAgg(s);
        ClassInfo* ci = classResolving(s);
        if (ci != 0)
            return ci.selfPtr();
        // A PROTOCOL reference names no layout — which class is behind it is
        // not known until run time — so it is an opaque pointer, and every
        // call through it goes to the object's own vtable.
        //
        // A pointer to a class that has not been REGISTERED yet is
        // pre-scanned ON DEMAND by classResolving above (task #20 — a cyclic
        // #import puts a class's user ahead of the class itself, and the
        // collapsed Ptr(Void) fed the inliner FieldAddrs whose offsets all
        // folded to 0). Only the one unresolvable case still collapses: two
        // classes whose IVARS point at each other, where the one mid-scan
        // cannot be entered again. The field is still a pointer, still the
        // right width.
        if (isOpaqueRef(s))
            return ptrTo(String.withCString("Void"));
        if (s.byteLength() > (u32)0 && s.byteAt(s.byteLength() - (u32)1) == (u8)'*' && isOpaqueRef(s.substringBytes((u32)0, s.byteLength() - (u32)1)))
            return ptrTo(String.withCString("Void"));
        // A FUNCTION type — `u8(u8)`, or a pointer to one — is an opaque code
        // address. The IR carries no signature for it: an indirect call names
        // its own argument list, and the backend jumps through the value.
        //
        // An ARRAY is excluded, because `$bound_u16()[2]` contains a
        // parenthesis and is not a function type at all: reading it as one
        // made an array of `^` a single opaque pointer.
        if (!isArrayLike(s))
            {
            for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
                {
                if (s.byteAt(i) == (u8)'(')
                    return ptrTo(String.withCString("Void"));
                }
            }
        if (s.byteLength() > (u32)0 && s.byteAt(s.byteLength() - (u32)1) == (u8)'*')
            {
            // A pointer to a name this unit never declared — `Object@` in a
            // module that imports nothing — is an OPAQUE pointer, the same as
            // a protocol reference. The original resolves it the same way: it
            // is a pointer either way, and what it points at is a question
            // only the caller can answer.
            String* base = s.substringBytes((u32)0, s.byteLength() - (u32)1);
            if (unknownName(base))
                return ptrTo(String.withCString("Void"));
            String* pointee = irType(base);
            String* out = String.withCString("Ptr(");
            out.append(pointee);
            out.appendCString(", unbanked)");
            return out;
            }
        if (isName(s, "u8"))
            return String.withCString("U8");
        if (isName(s, "i8"))
            return String.withCString("I8");
        if (isName(s, "u16"))
            return String.withCString("U16");
        if (isName(s, "i16"))
            return String.withCString("I16");
        if (isName(s, "u32"))
            return String.withCString("U32");
        if (isName(s, "i32"))
            return String.withCString("I32");
        if (isName(s, "u64"))
            return String.withCString("U64");
        if (isName(s, "i64"))
            return String.withCString("I64");
        if (isName(s, "float"))
            return String.withCString("F32");
        if (isName(s, "double"))
            return String.withCString("F64");
        if (isName(s, "bool"))
            return String.withCString("Bool");
        if (isName(s, "void"))
            return String.withCString("Void");
        if (isName(s, "string"))
            return String.withCString("Ptr(U8, unbanked)");
        if (isName(s, "pointer"))
            return String.withCString("Ptr(Void, unbanked)");
        // An AGGREGATE — a struct or an array — is `Agg(N)`, N being its index
        // in the module's layout table. The layout is built on first use.
        if (isArrayLike(s) || structDeclFor(s) != 0)
            {
            // An ARRAY keeps its UNSTRIPPED spelling: `weak:Leaf@[3]` is an
            // array of auto-zeroing SLOTS and `Leaf@[3]` is an array of
            // pointers, and stripping the qualifier before the layout is built
            // loses the only thing that says which.
            return aggRefFor(isArrayLike(t) ? t : s);
            }
        // An ENUM is its members' width — the type itself never reaches the
        // IR, only the integer wide enough to hold every value it names.
        String* eb = enumBase(s);
        if (eb != 0)
            return irType(eb);
        // Anything else — a class — is not in this slice.
        String* w = String.withCString("type ");
        w.append(s);
        giveUp(w);
        return String.withCString("Void");
        }

    // A pointer to something, spelled the way the IR prints it. Every address
    // in this file is built here.
    String* ptrTo(String* pointee)
        {
        String* out = String.withCString("Ptr(");
        out.append(pointee);
        out.appendCString(", unbanked)");
        return out;
        }

    // ── aggregate shapes ─────────────────────────────────────────────────
    // The spelling carries the shape: `u8[4]` is an array, `Point` is a struct
    // if the struct table says so. Same reading the analyser takes.
    bool isArrayLike(String* t)
        {
        if (t == 0)
            return false;
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            if (t.byteAt(i) == (u8)'[')
                return true;
        return false;
        }

    // Everything before the FIRST `[` — which is what the analyser's elementOf
    // does, so a multi-dimensional spelling would disagree with the original's
    // nested array type. Reported rather than mis-lowered.
    String* elementOf(String* t)
        {
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            if (t.byteAt(i) == (u8)'[')
                return t.substringBytes((u32)0, i);
        return t;
        }

    u32 arrayCount(String* t)
        {
        u32 i = (u32)0;
        while (i < t.byteLength() && t.byteAt(i) != (u8)'[')
            i = i + (u32)1;
        i = i + (u32)1;
        u32 n = (u32)0;
        bool any = false;
        while (i < t.byteLength() && t.byteAt(i) != (u8)']')
            {
            u8 c = t.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return (u32)0;
            n = n * (u32)10 + (u32)(c - (u8)'0');
            any = true;
            i = i + (u32)1;
            }
        // A second `[` means a nested array type this slice does not model.
        while (i < t.byteLength())
            {
            if (t.byteAt(i) == (u8)'[')
                {
                giveUp(String.withCString("type multi-dimensional array"));
                return (u32)0;
                }
            i = i + (u32)1;
            }
        return any ? n : (u32)0;
        }

    // ── auto-zeroing slots ───────────────────────────────────────────────
    // A `weak:T@` reference and a `^` bound method are the same KIND of thing:
    // neither owns its referent, and both must read as null the moment the
    // referent dies. That is done by threading the slot onto a list the
    // referent's dealloc walks — so the slot is not just the value, it is
    // [prev, next, payload], and the payload sits two words in.
    //
    // The links must be REAL fields rather than a gap: the backends recompute
    // FieldAddr offsets by summing their own field widths and never read the
    // layout's byteOffset, so a gap is invisible to them and the payload would
    // land back on top of the links.
    bool isWeakSlot(String* t)
        {
        if (t == 0)
            return false;
        if (isBoundSig(t))
            return true;
        if (!hasQual(t, "weak"))
            return false;
        String* base = stripQual(t);
        if (base.byteLength() == (u32)0 || base.byteAt(base.byteLength() - (u32)1) != (u8)'*')
            return false;
        // "Is the pointee a CLASS" must come from what is DECLARED, not what
        // is registered so far: the two-phase pre-scan can ask mid-recursion,
        // before the pointee's own phase 1 has run, and the original answers
        // from the type system (pointeeType.kind == Class), which never
        // depended on scan order. classFor still covers imported classes
        // that are registered without a local declaration.
        String* pn = base.substringBytes((u32)0, base.byteLength() - (u32)1);
        if (_classDecls.get((Hashable*)pn) != 0)
            return true;
        return classFor(pn) != 0;
        }

    // A `^` is a PAIR: the receiver it was taken from, and the code to run.
    // Two words, and the reason it is a value rather than a pointer — copying
    // one copies both halves, and there is nothing to allocate.
    String* boundPairAgg(String* spelling)
        {
        // Keyed by the SIGNATURE, and by WEAKNESS: `act_t^` and the sema's
        // `$bound_u16()` name one type and must share a layout, but
        // `$wbound_u16()` is a different one — the same two words, and
        // auto-zeroing — so the original registers a layout for each.
        String* key = boundSignatureOf(spelling);
        if (spelling.hasPrefix(String.withCString("$wbound_")))
            {
            String* wk = String.withCString("w:");
            wk.append(key);
            key = wk;
            }
        Object* have = _boundPair.get((Hashable*)key);
        if (have != 0)
            return (String*)have;

        IRLayout* L = IRLayout.with((u32)2 * _ptrW, (u32)1);
        L.addField((u32)0, ptrTo(String.withCString("U8")));  // recv
        L.addField(_ptrW, ptrTo(String.withCString("Void"))); // code
        u32 id = _m.addLayout(L);
        String* agg = String.withCString("Agg(");
        agg.appendFormat("%ld", (i32)id);
        agg.appendCString(")");
        _boundPair.set((Hashable*)key, (Object*)agg);
        return agg;
        }

    // `$bound_u8(u8)` names the signature `u8(u8)`.
    String* boundSignatureOf(String* t)
        {
        if (t.hasPrefix(String.withCString("$wbound_")))
            return t.substringFromByte((u32)8);
        return t.substringFromByte((u32)7);
        }

    // `$bound_u16()` names a pair; `$bound_u16()[2]` names an ARRAY of them,
    // which is an aggregate of its own and not a pair at all. Reading the
    // array as a pair registered a second identical pair layout and made every
    // element the size of one slot instead of the size of the array.
    bool isBoundSig(String* t)
        {
        if (t == 0)
            return false;
        if (isArrayLike(t))
            return false;
        return t.hasPrefix(String.withCString("$bound_")) || t.hasPrefix(String.withCString("$wbound_"));
        }

    bool hasQual(String* t, string want)
        {
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            {
            if (t.byteAt(i) != (u8)':')
                continue;
            return isName(t.substringBytes((u32)0, i), want);
            }
        return false;
        }

    // The slot type that wraps a payload. NOT cached: the original registers a
    // fresh layout per use, and the table's contents are part of the output.
    String* weakSlotAgg(String* payloadIr)
        {
        String* link = ptrTo(String.withCString("Void"));
        u32 w = _ptrW; // a link is a pointer
        u32 pw = irWidth(payloadIr);
        if (pw == (u32)0)
            pw = w; // a Ptr payload declares no width
        IRLayout* L = IRLayout.with((u32)2 * w + pw, (u32)1);
        L.addField((u32)0, link);
        L.addField(w, link);
        L.addField((u32)2 * w, payloadIr);
        u32 id = _m.addLayout(L);
        String* agg = String.withCString("Agg(");
        agg.appendFormat("%ld", (i32)id);
        agg.appendCString(")");
        return agg;
        }

    Node* structDeclFor(String* t)
        {
        if (t == 0)
            return (Node*)0;
        Object* o = _structs.get((Hashable*)stripQual(t));
        if (o == 0)
            return (Node*)0;
        return (Node*)o;
        }

    // A POINTER is the target's native width — three bytes on the banked 6502
    // ([lo, hi, bank]), eight on a 64-bit host. The analyser never has to know
    // (widening a pointer against an integer yields the pointer, no width
    // involved), which is why `Types.byteWidth` can say something else and
    // sema still agrees with its own oracle.
    //
    // A `banked:` or `raw:` pointer is the exception: it is three bytes on
    // EVERY target, because what it holds is a bank selector and an address in
    // that bank, which is the same shape wherever the compiler is running.
    u32 astWidth(String* t)
        {
        // A `^` is a PAIR — receiver and code — so it is two pointers wide, the
        // same answer sizeOf gives. Falling through to the scalar table returned
        // ZERO, and a zero-width source makes every conversion FROM a `^` a
        // widening: `Assert.isTrue(p == q)` came out as ZExt where the original
        // narrows the pair to a bool with Trunc (bug 033).
        if (isBoundSig(stripQual(t)))
            return _ptrW * (u32)2;
        // A banked/raw pointer is 3 bytes on the banked target; on a FLAT
        // host the bank byte means nothing and the backend stores it like
        // any other pointer, so the width is the native one there (the
        // mirror of XTPointerType.byteWidth's MAX — blewit #5 exposed the
        // old unconditional 3 as a mis-placed-field segfault).
        if (Types.isPointer(t))
            {
            if (isBankedPtr(t))
                return _ptrW > (u32)3 ? _ptrW : (u32)3;
            return _ptrW;
            }
        String* eb = enumBase(stripQual(t));
        if (eb != 0)
            return Types.byteWidth(eb);
        return Types.byteWidth(t);
        }

    // `banked:T@` / `raw:T@` — a pointer that names its own bank.
    // The qualifier can sit behind another one — `weak:banked:X@` is a weak
    // slot holding a banked pointer — so the whole prefix chain is searched,
    // not just its head.
    bool isBankedPtr(String* t)
        {
        if (t == 0)
            return false;
        return t.byteIndexOf(String.withCString("banked:")) != String.notFound() || t.byteIndexOf(String.withCString("raw:")) != String.notFound();
        }

    // The integer an enum's values fit in. Widest member decides: `[LOW = 10,
    // HIGH = 300]` cannot be a byte, and nothing about the declaration says so
    // except its numbers.
    String* enumBase(String* name)
        {
        Object* d = _enums.get((Hashable*)name);
        if (d == 0)
            return (String*)0;
        Node* e = (Node*)d;
        i32 hi = (i32)0;
        for (u32 i = (u32)0; i < e.kidCount(); i = i + (u32)1)
            {
            Node* m = e.kid(i);
            if (m.kind() != (u16)nkEnumMember)
                continue;
            if (m.num() > hi)
                hi = m.num();
            }
        if (hi > (i32)65535)
            return String.withCString("u32");
        if (hi > (i32)255)
            return String.withCString("u16");
        return String.withCString("u8");
        }

    // What a value of this IR type costs in the FRAME. Not the same question
    // as `sizeOf`: a pointer's storage is the target's business, so the IR
    // type declines to name a width and the frame accounting reads 0 — which
    // is why two pinned locals can share byte offset 0 and the printed size
    // still balances. An aggregate is its layout.
    u32 irWidth(String* ir)
        {
        if (ir == 0)
            return (u32)0;
        if (ir.hasPrefix(String.withCString("Agg(")))
            return layoutSizeOf(ir);
        if (ir.hasPrefix(String.withCString("Ptr(")))
            return (u32)0;
        if (ir.equals(String.withCString("U8")) || ir.equals(String.withCString("I8")) || ir.equals(String.withCString("Bool")))
            return (u32)1;
        if (ir.equals(String.withCString("U16")) || ir.equals(String.withCString("I16")))
            return (u32)2;
        if (ir.equals(String.withCString("U32")) || ir.equals(String.withCString("I32")) || ir.equals(String.withCString("F32")))
            return (u32)4;
        if (ir.equals(String.withCString("F64")) || ir.equals(String.withCString("U64")) || ir.equals(String.withCString("I64")))
            return (u32)8;
        return (u32)0;
        }

    // Is this element spelling a PRIMITIVE? The answer decides the SHAPE of the
    // `_xtc_new_<T>` call — one argument or two — and the driver's stub
    // generator answers the same question from the symbol name alone, with no
    // types available. The two lists must agree; the original keeps its copy in
    // src/xtc/ir/XTIRElemKind.h. Bug 027 is what a disagreement looks like.
    bool isPrimElemName(String* nm)
        {
        if (nm == 0)
            return false;
        return nm.equals(String.withCString("pointer")) || nm.equals(String.withCString("bool")) || nm.equals(String.withCString("i8")) || nm.equals(String.withCString("u8")) || nm.equals(String.withCString("i16")) || nm.equals(String.withCString("u16")) || nm.equals(String.withCString("i32")) || nm.equals(String.withCString("u32")) || nm.equals(String.withCString("i64")) || nm.equals(String.withCString("u64")) || nm.equals(String.withCString("float")) || nm.equals(String.withCString("double")) || nm.equals(String.withCString("string"));
        }

    // `Agg(N)` -> the size the table records for layout N.
    u32 layoutSizeOf(String* agg)
        {
        u32 id = (u32)0;
        for (u32 i = (u32)4; i < agg.byteLength(); i = i + (u32)1)
            {
            u8 c = agg.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                break;
            id = id * (u32)10 + (u32)(c - (u8)'0');
            }
        if (id >= _m.layouts().count())
            return (u32)0;
        return ((IRLayout*)_m.layouts().get(id)).size();
        }

    // A type's size, and the alignment its size is rounded up to. Struct fields
    // are naturally aligned per target (min(natural, the field cap) — blewit
    // #5; :packed keeps them tight), and the padding at the END means an
    // array of the struct strides the way the target's C compiler says.
    u32 sizeOf(String* t)
        {
        if (t == 0)
            return (u32)0;
        // A `^` is a PAIR — receiver and code — so it costs two pointers, not
        // one. Sizing it as a scalar leaves every ivar after it overlapping.
        if (isBoundSig(stripQual(t)))
            return astWidth(String.withCString("u8*")) * (u32)2;
        if (isArrayLike(t))
            return sizeOf(elementOf(t)) * arrayCount(t);
        Node* st = structDeclFor(t);
        if (st != 0)
            {
            bool pk = st.hasFlag((u32)NF_PACKED);
            u32 total = (u32)0;
            for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
                {
                String* ft = st.kid(i).op();
                u32 fa = pk ? (u32)1 : fieldAlignFor(ft);
                // An auto-zeroing FIELD (`callback`, `weak:T@`, `^`) carries two
                // hidden link words before its payload — the PAYLOAD is what
                // aligns. The IR layout builder (layoutFor) and the reference's
                // XTLayoutStructFields both reserve them; sizeOf did NOT, so
                // sizeof(S) and the array STRIDE (which is sizeOf(elem)) came
                // out 12 for a struct whose real IR layout is 16, and an array
                // of them overlapped every element after the first (bug 26, the
                // port half — the reference was already fixed).
                if (isWeakSlot(ft))
                    total = ((total + _ptrW + _ptrW) + fa - (u32)1) & ~(fa - (u32)1);
                else
                    total = (total + fa - (u32)1) & ~(fa - (u32)1);
                total = total + sizeOf(ft);
                }
            u32 a = alignOf(t);
            return (total + a - (u32)1) & ~(a - (u32)1);
            }
        return astWidth(t);
        }

    // Alignment a field of this type gets inside an UNPACKED aggregate: its
    // natural alignment capped at the target's field cap. One rule, shared by
    // struct layout, class instance layout and the tuple-return layout — the
    // mirror of the original's XTStructType.fieldAlignmentForType:.
    u32 fieldAlignFor(String* t)
        {
        u32 a = alignOf(t);
        if (a > _fieldCap)
            a = _fieldCap;
        if (a == (u32)0)
            a = (u32)1;
        return a;
        }

    u32 alignOf(String* t)
        {
        if (isArrayLike(t))
            return alignOf(elementOf(t));
        Node* st = structDeclFor(t);
        if (st != 0)
            {
            // `:packed` — no alignment, so the size rounding above is a
            // no-op and a packed struct nested in a normal one contributes
            // alignment 1. The mirror of the original's XTStructAlignment.
            if (st.hasFlag((u32)NF_PACKED))
                return (u32)1;
            u32 a = (u32)1;
            for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
                {
                u32 fa = alignOf(st.kid(i).op());
                if (fa > a)
                    a = fa;
                }
            // The TAIL cap: m68k rounds sizeof to 2 (its C ABI); xt6502
            // keeps the pow2 rounding (cap 8) even though its fields pack.
            if (a > _tailCap)
                a = _tailCap;
            return a;
            }
        // A power-of-two width aligns to itself; anything else (a 3-byte
        // pointer, a 5-byte float) imposes nothing.
        u32 w = astWidth(t);
        if (w != (u32)0 && (w & (w - (u32)1)) == (u32)0)
            return w;
        return (u32)1;
        }

    // The layout index for an aggregate spelling. The FIELD types are resolved
    // before the layout is added, so a nested struct's layout lands in the
    // table first — the order the original produces.
    u32 layoutFor(String* spelling)
        {
        // An array of AUTO-ZEROING elements names its element's SLOT before
        // the cache is consulted, so a cache HIT still registers one. That
        // reads as a waste and is — but the layout table's contents are the
        // output, and the original leaves the orphan behind.
        String* preElem = (String*)0;
        if (isArrayLike(spelling) && isWeakSlot(elementOf(spelling)))
            preElem = weakSlotAggOf(elementOf(spelling));
        Object* have = _layoutIds.get((Hashable*)spelling);
        if (have != 0)
            return ((Number*)have).asU32();
        // A struct that reaches ITSELF — `struct _reent { __sFILE@ _stdin; }`
        // where `__sFILE` points back — has no index yet when the field that
        // needs it is spelled. It gets a placeholder, and completing the layout
        // rewrites every field that took one. (The index cannot simply be
        // reserved up front: the original adds a layout to the table AFTER its
        // fields, so the nested ones come first and the cycle's own index is
        // not known until its fields are done.)
        String* token = String.withCString("Agg(?");
        token.appendFormat("%ld", (i32)_layoutTick);
        token.appendCString(")");
        _layoutTick = _layoutTick + (u32)1;
        _layoutPending.set((Hashable*)spelling, (Object*)token);

        Array* offs = new Array();
        Array* tys = new Array();
        u32 size = (u32)0;
        if (isArrayLike(spelling))
            {
            // Every element is a field, packed at `i * elementWidth`. This is
            // the array's STORAGE; a subscript decays to a pointer and strides
            // by the element, so it never reads the per-field info.
            String* elem = elementOf(spelling);
            u32 n = arrayCount(spelling);
            // An array of AUTO-ZEROING elements is an array of SLOTS: each
            // element carries its own two link words, because each is
            // independently threaded onto a referent's chain.
            bool weakElem = isWeakSlot(elem);
            String* eIr = weakElem ? preElem : irType(elem);
            u32 w = weakElem ? layoutSizeOf(eIr) : sizeOf(elem);
            for (u32 i = (u32)0; i < n; i = i + (u32)1)
                {
                offs.add((Object*)Number.with(i * w));
                tys.add((Object*)eIr);
                }
            size = w * n;
            }
        else
            {
            Node* st = structDeclFor(spelling);
            bool pk = st.hasFlag((u32)NF_PACKED);
            u32 off = (u32)0;
            bool anyWeak = false;
            for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
                {
                String* ft = st.kid(i).op();
                u32 fa = pk ? (u32)1 : fieldAlignFor(ft);
                // An auto-zeroing FIELD carries the same two hidden link words
                // an ivar or a local's slot does — the runtime walks a chain
                // to zero it, and the chain has to live in real fields with
                // recorded offsets IMMEDIATELY before the payload. The PAYLOAD
                // is what aligns (mirror of XTLayoutStructFields: payload =
                // alignUp(off + links, fa)), so the links stay contiguous and
                // any pad falls before them.
                if (isWeakSlot(ft))
                    {
                    String* link = ptrTo(String.withCString("Void"));
                    u32 payload = ((off + _ptrW + _ptrW) + fa - (u32)1) & ~(fa - (u32)1);
                    offs.add((Object*)Number.with(payload - _ptrW - _ptrW));
                    tys.add((Object*)link);
                    offs.add((Object*)Number.with(payload - _ptrW));
                    tys.add((Object*)link);
                    off = payload;
                    anyWeak = true;
                    }
                else
                    {
                    off = (off + fa - (u32)1) & ~(fa - (u32)1);
                    }
                offs.add((Object*)Number.with(off));
                tys.add((Object*)irType(ft));
                off = off + sizeOf(ft);
                }
            // The declared size when nothing is auto-zeroing — which rounds
            // to the struct's alignment — and the summed one when something is,
            // because the link words are not in the declaration. The summed
            // total must ALSO be rounded to the struct's alignment, exactly as
            // the reference's XTStructType.byteWidth does, or an array of a
            // weak-holding struct whose last field leaves a sub-alignment tail
            // (S2 ends at 23, aligns to 24) strides one byte short (bug 26).
            if (anyWeak)
                {
                u32 a = alignOf(spelling);
                size = (off + a - (u32)1) & ~(a - (u32)1);
                }
            else
                {
                size = sizeOf(spelling);
                }
            }
        if (_failed)
            return (u32)0;

        IRLayout* L = IRLayout.with(size, (u32)1);
        for (u32 i = (u32)0; i < offs.count(); i = i + (u32)1)
            L.addField(((Number*)offs.get(i)).asU32(), (String*)tys.get(i));
        u32 id = _m.addLayout(L);
        _layoutIds.set((Hashable*)spelling, (Object*)Number.with(id));
        _layoutPending.remove((Hashable*)spelling);
        patchPendingAgg(token, id);
        return id;
        }

    // `Agg(N)` for an aggregate spelling — or the placeholder, when the
    // spelling is one whose layout is still being built further up the stack.
    String* aggRefFor(String* spelling)
        {
        Object* pend = _layoutPending.get((Hashable*)spelling);
        if (pend != 0)
            return String.withString((String*)pend);
        u32 id = layoutFor(spelling);
        if (_failed)
            return String.withCString("Void");
        String* agg = String.withCString("Agg(");
        agg.appendFormat("%ld", (i32)id);
        agg.appendCString(")");
        return agg;
        }

    // Now that the cycle's layout has an index, every field spelled while it
    // did not gets it. Only layouts can hold one: a field type is the only
    // thing built during the fill.
    void patchPendingAgg(String* token, u32 id)
        {
        String* real = String.withCString("Agg(");
        real.appendFormat("%ld", (i32)id);
        real.appendCString(")");
        Array* ls = _m.layouts();
        for (u32 i = (u32)0; i < ls.count(); i = i + (u32)1)
            {
            IRLayout* L = (IRLayout*)ls.get(i);
            for (u32 k = (u32)0; k < L.fieldCount(); k = k + (u32)1)
                {
                String* t = L.typeAt(k);
                if (t == 0)
                    continue;
                String* copy = String.withString(t);
                if (copy.replaceOccurrences(token, real) != (u32)0)
                    L.setTypeAt(k, copy);
                }
            }
        }

    // The index of a struct's field, and its declared type. -1 when the struct
    // has no such field.
    // The DECLARED type of a named field. Looked up by name rather than by
    // the layout index, which an auto-zeroing field in front of it has moved.
    String* fieldTypeOf(Node* st, String* member)
        {
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            if (st.kid(i).name().equals(member))
                return st.kid(i).op();
        return (String*)0;
        }

    // The FIELD index a member has in the laid-out struct, which is not its
    // position among the declarations: an auto-zeroing field in front of it
    // occupies three, not one.
    i32 fieldIndexOf(Node* st, String* member)
        {
        u32 idx = (u32)0;
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            {
            if (isWeakSlot(st.kid(i).op()))
                idx = idx + (u32)2;
            if (st.kid(i).name().equals(member))
                return (i32)idx;
            idx = idx + (u32)1;
            }
        return (i32)-1;
        }

    String* stripQual(String* s)
        {
        // A collection's ELEMENT annotation comes off here too: `Array<String>*`
        // is an `Array*` as far as IR is concerned, because typed collections
        // are erased. The element type only ever mattered to sema.
        String* t = Node.stripElem(s);
        while (true)
            {
            u32 c = String.notFound();
            for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
                if (t.byteAt(i) == (u8)':')
                    c = i;
            if (c == String.notFound())
                return t;
            t = t.substringFromByte(c + (u32)1);
            }
        return t;
        }

    bool isName(String* s, string lit)
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

    // ── emission ─────────────────────────────────────────────────────────
    IRValue* emit(String* mnemonic, String* resultTy, Array* operands)
        {
        IRInsn* i = IRInsn.with(mnemonic);
        // A VOID result is no result: `(void)p` is a conversion whose value
        // nothing can name, and giving it a number would print a definition
        // of a value of no type.
        IRValue* r = (IRValue*)0;
        if (!isName(resultTy, "Void"))
            {
            r = new IRValue(resultTy);
            i.setRes(r);
            }
        for (u32 k = (u32)0; k < operands.count(); k = k + (u32)1)
            i.add((IROperand*)operands.get(k));
        _blk.add(i);
        return r;
        }

    // The value is an i64: this was the LAST 32-bit narrowing in the literal
    // path, and with the token and AST payloads widened it was the only reason
    // `1000000000000` still arrived as its low half.
    IRValue* constOf(i64 v, String* astTy)
        {
        Array* ops = new Array();
        String* ty = irType(astTy);
        // A negative value in an UNSIGNED slot is not negative: it is a
        // literal that overflowed the parser's signed range — `$FFFFFFFF` is
        // written as a large positive and read back as one. A source-level
        // minus never arrives here, because `-5` parses as a unary operator
        // applied to 5. With a 64-bit payload this only bites at the 64-bit
        // boundary now, not the 32-bit one.
        if (v < (i64)0 && !Types.isSigned(astTy))
            ops.add((Object*)IROperand.immU64((u64)v, ty));
        else
            ops.add((Object*)IROperand.immI(v, ty));
        return emit(String.withCString("Const"), ty, ops);
        }

    bool isFloatIr(String* t)
        {
        if (t == 0)
            return false;
        return t.equals(String.withCString("F32")) || t.equals(String.withCString("F64"));
        }

    bool isPtrIr(String* t)
        {
        if (t == 0)
            return false;
        return t.hasPrefix(String.withCString("Ptr("));
        }

    // ── coercion ─────────────────────────────────────────────────────────
    // The one place a value changes type. Widening is ZExt or SExt by the
    // SOURCE's signedness — a signed narrow value keeps its sign — and
    // narrowing is always a Trunc.
    // Ownership follows the value THROUGH a coercion. A +1 temporary coerced
    // to another type — an upcast to `Object@`, a crossing into a banked
    // pointer — becomes a NEW IR value, and the pending registration has to
    // move onto it. Left behind, the original stays pending and is released
    // while the value that is actually live is not.
    IRValue* coerce(IRValue* v, String* from, String* to)
        {
        IRValue* r = coerceImpl(v, from, to);
        if (r != v)
            retargetOwnedTemp(v, r);
        return r;
        }

    IRValue* coerceImpl(IRValue* v, String* from, String* to)
        {
        if (v == 0 || from == 0 || to == 0)
            return v;
        // A plain function pointer reaching a `^` WIDENS into the pair: the
        // recv word carries the code address and the code word a trampoline
        // that jumps through it. Same rule wherever it lands — a parameter, a
        // local, an ivar — which is what lets a free function and a bound
        // method share one type with no second ABI.
        if (isBoundSig(stripQual(to)) && isFnPointer(from))
            return widenToBound(v, to);
        // `(callback SIG)(p)` where p is a raw CODE address — a function pointer
        // received from C (signal()'s old handler, dlsym). Build a REAL
        // {recv=p, code=trampoline} pair, using the DESTINATION signature's
        // trampoline, so it can be called — instead of the null pair below
        // (c2xc 14). recv is the code address, as for a widened free function.
        if (isBoundSig(stripQual(to)) && !isBoundSig(stripQual(from)) && !isFnPointer(from) && Types.isPointer(from))
            return widenToBound(v, to);
        // A callback VALUE to a pointer/integer — its code address is the recv
        // word (field 0). `(pointer)f` on a callback variable (c2xc 13). Extract
        // it and let the normal path coerce the pointer to `to`; without this the
        // 16-byte pair was reinterpreted whole.
        // Guard on the VALUE being an Agg, not just the spelling: a `^`-typed
        // expression can already have lowered to a scalar (`!(f == 0)` is a
        // Bool), and AggExtract on that is nonsense — it made the whole file
        // give up.
        if (isBoundSig(stripQual(from)) && !isBoundSig(stripQual(to)) && isAggIr(v.ty()))
            {
            String* pv = ptrTo(String.withCString("Void"));
            Array* eops = new Array();
            eops.add((Object*)IROperand.useVal(v));
            eops.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
            v = emit(String.withCString("AggExtract"), pv, eops);
            from = String.withCString("pointer");
            }
        // An INTEGER reaching a `^` is the null pair: `a = 0` clears both
        // words. There is no scalar zero of a pair type, so the value in hand
        // is discarded and two null pointers are built instead.
        if (isBoundSig(stripQual(to)) && !isBoundSig(stripQual(from)) && !isFnPointer(from) && !Types.isPointer(from))
            {
            String* ptrT = ptrTo(String.withCString("Void"));
            Array* zo = new Array();
            zo.add((Object*)IROperand.immI((i32)0, ptrT));
            IRValue* z = emit(String.withCString("Const"), ptrT, zo);
            Array* bops = new Array();
            bops.add((Object*)IROperand.useVal(z));
            bops.add((Object*)IROperand.useVal(z));
            return emit(String.withCString("AggBuild"), irType(to), bops);
            }
        String* b = irType(to);
        // Nothing to do when the two types are the same SHAPE — same domain,
        // same width, same signedness. Same-IR-type is not the test: `Foo@`
        // and `Foo` both lower to Ptr(Agg(N)), and the original still marks
        // the crossing with a Bitcast, because one is a pointer type and the
        // other is a class.
        if (Types.isFloating(from) == Types.isFloating(to) && Types.isPointer(from) == Types.isPointer(to) && astWidth(from) == astWidth(to) && Types.isSigned(from) == Types.isSigned(to))
            return v;
        // A pointer is never RESIZED, it is re-interpreted. Crossing into or
        // out of the integer domain names the crossing — `(u16)p` is a
        // PtrToInt, not a truncation. Pointer to pointer is a Bitcast: the
        // bits do not move, but what they are said to point at does. A CLASS
        // counts as a pointer here even though its AST type is not one, which
        // is why `(Foo)fooPtr` marks the crossing rather than passing through.
        // An ARRAY is not a pointer, however it lowers. Its bare name DECAYS
        // to an address, so the VALUE is a pointer while the TYPE is not —
        // and `(u16)arr` is a narrowing of that address (Trunc via the width
        // path below), not a crossing out of the pointer domain.
        bool aPtr = Types.isPointer(from) || (isPtrIr(v.ty()) && !isArrayLike(from));
        bool bPtr = Types.isPointer(to) || isPtrIr(b);
        if (aPtr || bPtr)
            {
            Array* pops = new Array();
            pops.add((Object*)IROperand.useVal(v));
            if (aPtr && bPtr)
                return emit(String.withCString("Bitcast"), b, pops);
            // A decayed array (the value is ALREADY a pointer) reaching a
            // POINTER target is a reinterpret — Bitcast, never IntToPtr. An
            // IntToPtr treats the operand as an integer and mangles the live
            // pointer, so `i32* p = arr;` dereferenced garbage (c2xc 03). This
            // is the one case aPtr is false (array-like source) yet the target
            // and the value in hand are both pointers.
            if (bPtr && isPtrIr(v.ty()))
                return emit(String.withCString("Bitcast"), b, pops);
            if (aPtr)
                return emit(String.withCString("PtrToInt"), b, pops);
            return emit(String.withCString("IntToPtr"), b, pops);
            }
        // Whether this is a FLOAT conversion is decided by the value in hand,
        // not by what the analyser called the expression. A comparison's AST
        // type is its OPERAND type — `gA < gB` says `float` — while the value
        // it produced is a one-byte Bool. Asking the AST emitted an FpToUI on
        // a boolean.
        bool aF = isFloatIr(v.ty());
        bool bF = isFloatIr(b);
        // Crossing between the integer and float domains is a conversion, not
        // a resize: the bit pattern changes completely.
        if (aF || bF)
            {
            Array* fops = new Array();
            fops.add((Object*)IROperand.useVal(v));
            if (aF && bF)
                {
                bool wider = astWidth(to) > astWidth(from);
                return emit(String.withCString(wider ? "FpExt" : "FpTrunc"), b, fops);
                }
            if (bF)
                return emit(String.withCString(Types.isSigned(from) ? "SIToFp" : "UIToFp"), b, fops);
            return emit(String.withCString(Types.isSigned(to) ? "FpToSI" : "FpToUI"), b, fops);
            }
        // Same reasoning as the float gate: the WIDTH is the value's, not the
        // spelling's. A Bool is one unsigned byte whatever the analyser called
        // the expression that produced it.
        bool srcBool = v.ty().equals(String.withCString("Bool"));
        // astWidth, not Types.byteWidth: an ENUM's width is its members', and
        // the scalar table has never heard of the name. An ARRAY's is the
        // whole array — which is what makes `(u16)arr` a narrowing.
        u32 aw = srcBool ? (u32)1 : (isArrayLike(from) ? sizeOf(from) : astWidth(from));
        u32 bw = isArrayLike(to) ? sizeOf(to) : astWidth(to);
        Array* ops = new Array();
        ops.add((Object*)IROperand.useVal(v));
        if (bw > aw)
            {
            bool sgnSrc = !srcBool && Types.isSigned(from);
            return emit(String.withCString(sgnSrc ? "SExt" : "ZExt"), b, ops);
            }
        if (bw < aw)
            return emit(String.withCString("Trunc"), b, ops);
        // Same width, different signedness. The bits do not move, but the
        // TYPE does, and the IR says so: `(i16)u16val` is a Bitcast. Leaving
        // the value alone would hand the next instruction an operand whose
        // printed type contradicts its use.
        return emit(String.withCString("Bitcast"), b, ops);
        }

    // ── expressions ──────────────────────────────────────────────────────
    // `a && b` evaluates b only when a was true, so it is control flow: the
    // false answer is materialised on the way in and the phi at the join
    // picks whichever edge arrived.
    IRValue* lowerShortCircuit(Node* n)
        {
        bool isAnd = isName(n.op(), "&&");
        IRValue* l = lowerExpr(n.kid((u32)0));
        if (_failed)
            return (IRValue*)0;

        String* prefix = blockPrefix();
        String* rn = String.withString(prefix);
        rn.appendCString(isAnd ? "_and_rhs" : "_or_rhs");
        String* jn = String.withString(prefix);
        jn.appendCString(isAnd ? "_and_join" : "_or_join");
        IRBlock* rhsB = addBlock(rn);
        IRBlock* joinB = addBlock(jn);

        // The short-circuit ANSWER — false for `&&`, true for `||` — is
        // computed before the branch, on the edge that skips the right side.
        Array* cops = new Array();
        cops.add((Object*)IROperand.immI(isAnd ? (i32)0 : (i32)1, String.withCString("Bool")));
        IRValue* shortAns = emit(String.withCString("Const"), String.withCString("Bool"), cops);
        IRBlock* entryB = _blk;

        IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
        cb.add(IROperand.useVal(l));
        cb.add(IROperand.block(isAnd ? rhsB : joinB));
        cb.add(IROperand.block(isAnd ? joinB : rhsB));
        _blk.setTerm(cb);

        _blk = rhsB;
        _condDepth = _condDepth + (u32)1;
        IRValue* r = lowerExpr(n.kid((u32)1));

        _condDepth = _condDepth - (u32)1;
        if (_failed)
            return (IRValue*)0;
        // The right side becomes the answer, so it has to BE a boolean — but
        // a comparison already is one, and forcing a cast onto it emits an
        // instruction the original does not.
        IRValue* rb = coerce(r, n.kid((u32)1).ty(), String.withCString("bool"));
        // The `+1` temps born in THIS arm are released before it branches away.
        // They are live on this path only, and a short-circuit arm's value is a
        // Bool — so unlike a ternary arm, none of them can BE the result. Left
        // pending they would leak, and the runtime's refcount is a u16 that
        // WRAPS (private:docs/bugs/025).
        releaseOwnedTempsAtDepth(_condDepth + (u32)1);
        IRBlock* rhsExit = _blk;
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(joinB));
        rhsExit.setTerm(br);

        _blk = joinB;
        IRInsn* phi = IRInsn.with(String.withCString("Phi"));
        IRValue* res = new IRValue(String.withCString("Bool"));
        phi.setRes(res);
        bool entryFirst = blockIndex(entryB) <= blockIndex(rhsExit);
        phi.add(IROperand.block(entryFirst ? entryB : rhsExit));
        phi.add(IROperand.useVal(entryFirst ? shortAns : rb));
        phi.add(IROperand.block(entryFirst ? rhsExit : entryB));
        phi.add(IROperand.useVal(entryFirst ? rb : shortAns));
        joinB.addPhi(phi);
        return res;
        }

    // `c ? a : b` is an `if` that yields a value: an arm each, and a phi.
    IRValue* lowerTernary(Node* n)
        {
        IRValue* cond = lowerCondition(n.kid((u32)0));
        if (_failed)
            return (IRValue*)0;
        String* prefix = blockPrefix();
        String* tn = String.withString(prefix);
        tn.appendCString("_tern_then");
        String* en = String.withString(prefix);
        en.appendCString("_tern_else");
        String* jn = String.withString(prefix);
        jn.appendCString("_tern_join");
        IRBlock* thenB = addBlock(tn);
        IRBlock* elseB = addBlock(en);
        IRBlock* joinB = addBlock(jn);

        IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
        cb.add(IROperand.useVal(cond));
        cb.add(IROperand.block(thenB));
        cb.add(IROperand.block(elseB));
        _blk.setTerm(cb);

        String* ty = n.ty();
        _blk = thenB;
        _condDepth = _condDepth + (u32)1;
        IRValue* a = lowerExpr(n.kid((u32)1));
        _condDepth = _condDepth - (u32)1;
        if (_failed)
            return (IRValue*)0;
        a = coerce(a, n.kid((u32)1).ty(), ty);
        IRBlock* thenExit = _blk;
        IRInsn* b1 = IRInsn.with(String.withCString("Branch"));
        b1.add(IROperand.block(joinB));
        thenExit.setTerm(b1);

        _blk = elseB;
        _condDepth = _condDepth + (u32)1;
        IRValue* b = lowerExpr(n.kid((u32)2));
        _condDepth = _condDepth - (u32)1;
        if (_failed)
            return (IRValue*)0;
        b = coerce(b, n.kid((u32)2).ty(), ty);
        IRBlock* elseExit = _blk;

        // OWNERSHIP OF THE ARMS (private:docs/bugs/081).
        //
        // An arm that produced a `+1` temp registered it at the arm's
        // conditional depth, and flushOwnedTemps only releases temps recorded
        // at the CURRENT depth — rightly, since at the join it cannot know
        // which arm ran. So the temp was never released by anyone:
        // `p = c ? new Probe() : new Probe();` leaked every object.
        //
        // The fix is to make the ternary's RESULT the owned thing. Each arm's
        // temp stops being independently pending, and the phi is registered at
        // the OUTER depth, where the enclosing statement's flush (or whatever
        // binding adopts it) can see it.
        //
        // When only ONE arm is owned the paths disagree — +1 down one, +0 down
        // the other — and releasing the join would over-release the borrowed
        // side. So the borrowed arm is RETAINED in its own block, making both
        // paths +1 and the single release at the join correct either way.
        bool ownA = isOwnedTemp(a);
        bool ownB = isOwnedTemp(b);
        bool armOwned = (ownA || ownB) && isClassPointer(ty);
        if (armOwned)
            {
            IRBlock* save = _blk;
            if (ownA)
                {
                consumeOwnedTemp(a);
                }
            else
                {
                _blk = thenExit;
                refOp(String.withCString("Retain"), a);
                }
            if (ownB)
                {
                consumeOwnedTemp(b);
                }
            else
                {
                _blk = elseExit;
                refOp(String.withCString("Retain"), b);
                }
            _blk = save;
            }

        IRInsn* b2 = IRInsn.with(String.withCString("Branch"));
        b2.add(IROperand.block(joinB));
        elseExit.setTerm(b2);

        _blk = joinB;
        IRInsn* phi = IRInsn.with(String.withCString("Phi"));
        IRValue* res = new IRValue(irType(ty));
        phi.setRes(res);
        // Ordered by the PREDECESSOR's index, not by which arm was written
        // first — an arm that grew blocks of its own (a static-init guard,
        // say) exits from a later block than the other arm's, and the phi has
        // to read in the order the verifier walks predecessors.
        Array* tb = new Array();
        Array* tv = new Array();
        tb.add((Object*)thenExit);
        tv.add((Object*)a);
        tb.add((Object*)elseExit);
        tv.add((Object*)b);
        sortEdgesByBlock(tb, tv);
        rebuildPhi(phi, tb, tv);
        checkPhiIncoming(res, a, n.kid((u32)1));
        checkPhiIncoming(res, b, n.kid((u32)2));
        joinB.addPhi(phi);
        // Registered HERE, at the outer depth, so the enclosing statement can
        // release it — or a binding can adopt it and consume the registration.
        if (armOwned)
            noteOwnedTemp(res, ty);
        return res;
        }

    // `-x` is a Neg, `~x` a Not, and `!x` a comparison against false —
    // there is no boolean-negate instruction, and there does not need to be.
    IRValue* lowerUnary(Node* n)
        {
        String* op = n.op();
        IRValue* v = lowerExpr(n.kid((u32)0));
        if (_failed)
            return (IRValue*)0;
        String* opTy = n.kid((u32)0).ty();
        if (isName(op, "+"))
            return v;
        if (isName(op, "-") || isName(op, "~"))
            {
            // The operand is NOT converted first. `-1` negates the u8 one and
            // says the answer is an i8; inserting a cast to the result type
            // ahead of the operation adds an instruction and changes nothing.
            Array* ops = new Array();
            ops.add((Object*)IROperand.useVal(v));
            // Negating a FLOAT is its own opcode. An integer Neg on a float
            // value would two's-complement the bit pattern rather than flip
            // the sign bit, which is a different number entirely.
            String* mn = isName(op, "~") ? String.withCString("Not")
                                         : (Types.isFloating(n.ty()) ? String.withCString("FNeg")
                                                                     : String.withCString("Neg"));
            return emit(mn, irType(n.ty()), ops);
            }
        if (isName(op, "!"))
            {
            // A `^` is a PAIR, and its truth is its RECEIVER. Testing the
            // aggregate itself is meaningless; testing the code word would
            // report an unimplemented optional method as present, because the
            // code stays valid and only the receiver is nulled.
            // Guarded on what is IN HAND, not on the AST type: `!(f == 0)` is
            // typed `^` by sema (a comparison takes the widening of its
            // operands) but has already lowered to a Bool, and extracting a
            // field from a Bool is the XG-022 shape. Same rule as
            // lowerCondition.
            if (isBoundSig(stripQual(opTy)) && isAggIr(v.ty()))
                {
                Array* eops = new Array();
                eops.add((Object*)IROperand.useVal(v));
                eops.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
                IRValue* recvW = emit(String.withCString("AggExtract"),
                                      ptrTo(String.withCString("Void")), eops);
                Array* pops = new Array();
                pops.add((Object*)IROperand.useVal(recvW));
                IRValue* asInt = emit(String.withCString("PtrToInt"),
                                      String.withCString("U16"), pops);
                Array* zo = new Array();
                zo.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
                IRValue* z0 = emit(String.withCString("Const"), String.withCString("U16"), zo);
                IRInsn* ic = IRInsn.with(String.withCString("ICmp"));
                ic.setRes(new IRValue(String.withCString("Bool")));
                ic.setPred(String.withCString("EQ"));
                ic.add(IROperand.useVal(asInt));
                ic.add(IROperand.useVal(z0));
                _blk.add(ic);
                return ic.res();
                }
            // A float operand: `!f` is `f == 0.0` (bug 181). FCmp OEQ against a
            // zero-bits const, exactly as the binary `f == 0` path does — an
            // ICmp on a float register is bad codegen (cmp s8, #0).
            if (isFloatIr(v.ty()))
                {
                Array* zo = new Array();
                // 0.0 is the 64-bit double bit pattern 0, rendered as 16 hex
                // digits — the same #fp form the reference's rawBytes:0 prints.
                zo.add((Object*)IROperand.immF(String.withCString("0000000000000000"), v.ty()));
                IRValue* fz = emit(String.withCString("Const"), v.ty(), zo);
                IRInsn* fc = IRInsn.with(String.withCString("FCmp"));
                fc.setRes(new IRValue(String.withCString("Bool")));
                fc.setPred(String.withCString("OEQ"));
                fc.add(IROperand.useVal(v));
                fc.add(IROperand.useVal(fz));
                _blk.add(fc);
                return fc.res();
                }
            // The zero is at the VALUE's type — `!z` on a u16 compares
            // against a u16 zero, and `!(a || b)` against a Bool one. The
            // operand's DECLARED type is not the question: a short-circuit's
            // is the type of its terms, while what it produced is a Bool.
            // There is no boolean-negate instruction and no need for one.
            String* zt = v.ty();
            Array* cops = new Array();
            cops.add((Object*)IROperand.immI((i32)0, zt));
            IRValue* zero = emit(String.withCString("Const"), zt, cops);
            IRInsn* i = IRInsn.with(String.withCString("ICmp"));
            i.setRes(new IRValue(String.withCString("Bool")));
            i.setPred(String.withCString("EQ"));
            i.add(IROperand.useVal(v));
            i.add(IROperand.useVal(zero));
            _blk.add(i);
            return i.res();
            }
        String* w = String.withCString("unary ");
        w.append(op);
        giveUp(w);
        return (IRValue*)0;
        }

    // `&x` — the address of a place. A pinned local's slot, a global's symbol,
    // a field within either, or an array element. The result is never a Load:
    // the address IS the answer.
    IRValue* lowerAddrOf(Node* n)
        {
        Node* target = n.kid((u32)0);
        if (target.kind() == (u16)nkIdent)
            {
            IRPinned* p = pinOf(target.name());
            if (p != 0)
                {
                // A weak / auto-zeroing local (a `weak:` slot or a callback,
                // which auto-zeroes when its receiver dies) sits past two hidden
                // link words, so its ADDRESS is the payload, not the slot base —
                // as reads/writes route through pinAddrNamed's FieldAddr(base, 2).
                // The bare AddrOf handed `&cb` the link region, so word[0] read
                // the null prev link, not the pair's recv (bug 168).
                if (hasName(_weakLocals, target.name()))
                    return pinAddrNamed(p, target.name());
                Array* ops = new Array();
                ops.add((Object*)IROperand.useVal(p.val()));
                return emit(String.withCString("AddrOf"), irType(n.ty()), ops);
                }
            Object* g = _globals.get((Hashable*)target.name());
            if (g != 0)
                {
                Array* ops = new Array();
                // globalSymName, not the raw name: a function-local `static`
                // is a global under a MANGLED symbol, and `&buf` / `buf[i]`
                // must reach it too, or the static array's storage is a
                // different symbol from its reads (bug 174).
                ops.add((Object*)IROperand.sym(globalSymName(target.name())));
                return emit(String.withCString("AddrOf"), irType(n.ty()), ops);
                }
            // `&function` — the name is a module function, so its address is
            // a code pointer: the same value an indirect call dispatches
            // through.
            if (_funcs.get((Hashable*)target.name()) != 0)
                {
                Array* ops = new Array();
                ops.add((Object*)IROperand.sym(target.name()));
                return emit(String.withCString("AddrOf"), irType(n.ty()), ops);
                }
            // `&ted` inside a method, where `ted` is an IVAR: the implicit
            // self makes it `&self.ted`, and the address is the field's.
            if (ivarIndexOf(target.name()) >= (i32)0)
                return ivarAddr(target.name());
            String* w = String.withCString("& on ");
            w.append(target.name());
            w.appendCString(" (not pinned)");
            giveUpAt(w, target); // carry file:line:col (bug 17)
            return (IRValue*)0;
            }
        // `&obj.method` is not an address at all: it is the {recv, code} PAIR
        // built from the receiver read BY VALUE and the method's code address.
        if (target.kind() == (u16)nkMember && target.bound() != 0)
            return lowerBoundMethodRef(target, n);
        if (target.kind() == (u16)nkMember)
            return memberAddr(target);
        if (target.kind() == (u16)nkSubscript)
            return elementAddr(target);
        // `&*e` cancels — the address IS the very pointer `e` was about to
        // dereference. The cast form `&(*(T*)p)` (bug 18) otherwise reached
        // the catch-all below with no location.
        if (target.kind() == (u16)nkUnary && isName(target.op(), "*"))
            return lowerExpr(target.kid((u32)0));
        giveUpAt(String.withCString("unary & on this shape"), n); // bug 17
        return (IRValue*)0;
        }

    bool isAncestorOf(ClassInfo* maybeAncestor, ClassInfo* c)
        {
        for (ClassInfo* p = c; p != 0; p = p.parent())
            if (p == maybeAncestor)
                return true;
        return false;
        }

    IRValue* lowerDowncast(Node* n, IRValue* src, bool failable)
        {
        ClassInfo* ci = classFor(pointeeOf(n.name()));
        String* dstIr = ci.selfPtr();

        Array* bops = new Array();
        bops.add((Object*)IROperand.useVal(src));
        IRValue* asT = emit(String.withCString("Bitcast"), dstIr, bops);
        IRValue* nullT = nullPtrOf(dstIr);
        IRValue* isNull = cmpPtrZero(src);
        // The vtable read happens on ONE arm, so the token it produces does
        // not reach the join — the IR carries no memory phi, and the token
        // that flows out of the whole cast is the one that flowed in.
        IRValue* memIn = _mem;

        String* prefix = blockPrefix();
        String* cn = String.withString(prefix);
        cn.appendCString("_downcast_check");
        String* mn = String.withString(prefix);
        mn.appendCString("_downcast_miss");
        String* jn = String.withString(prefix);
        jn.appendCString("_downcast_join");
        IRBlock* checkB = addBlock(cn);
        IRBlock* missB = addBlock(mn);
        IRBlock* joinB = addBlock(jn);
        IRBlock* entryB = _blk;
        IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
        cb.add(IROperand.useVal(isNull));
        cb.add(IROperand.block(joinB));
        cb.add(IROperand.block(checkB));
        _blk.setTerm(cb);

        _blk = checkB;
        IRBlock* matchEdge = checkB;
        if (_vtAncestry && ci.needsVtable())
            matchEdge = emitAncestryWalk(src, ci, prefix, checkB, joinB, missB);
        else
            emitVtableIdentityBranch(src, ci, joinB, missB);

        // A miss on a PLAIN cast is a program error, not a value: the code
        // asserted the type and was wrong, so there is nowhere to go. A
        // failable one answers null and rejoins.
        _blk = missB;
        if (failable)
            {
            IRInsn* toJoin = IRInsn.with(String.withCString("Branch"));
            toJoin.add(IROperand.block(joinB));
            _blk.setTerm(toJoin);
            }
        else
            {
            _blk.setTerm(IRInsn.with(String.withCString("Unreachable")));
            }

        _blk = joinB;
        _mem = memIn;
        IRInsn* phi = IRInsn.with(String.withCString("Phi"));
        IRValue* res = new IRValue(dstIr);
        phi.setRes(res);
        Array* pb = new Array();
        Array* pv = new Array();
        pb.add((Object*)entryB);
        pv.add((Object*)nullT);
        pb.add((Object*)matchEdge);
        pv.add((Object*)asT);
        if (failable)
            {
            pb.add((Object*)missB);
            pv.add((Object*)nullT);
            }
        sortEdgesByBlock(pb, pv);
        rebuildPhi(phi, pb, pv);
        joinB.addPhi(phi);
        // Ownership follows the cast: the sweep must release the LIVE value.
        retargetOwnedTemp(src, res);
        return res;
        }

    // WALK the object's vtable-parent chain. Slot 0 of the object is its own
    // vtable; entry 0 of each vtable is its parent's, null at a root. Climbing
    // it recognises a subclass defined in ANY module — the compile-time subtree
    // cannot list a client's subclass, but that subclass's vtable links up to
    // this shared base. Returns the block whose join edge yields the match.
    IRBlock* emitAncestryWalk(IRValue* src, ClassInfo* ci, String* prefix,
                              IRBlock* checkB, IRBlock* joinB, IRBlock* missB)
        {
        String* voidP = ptrTo(String.withCString("Void"));
        String* vpp = ptrTo(voidP);
        Array* b2 = new Array();
        b2.add((Object*)IROperand.useVal(src));
        IRValue* slotP = emit(String.withCString("Bitcast"), vpp, b2);
        IRValue* vtbl0 = loadThroughIr(slotP, voidP);
        String* vn = String.withString(ci.name());
        vn.appendCString("$vtbl");
        Array* vo = new Array();
        vo.add((Object*)IROperand.sym(vn));
        IRValue* target = emit(String.withCString("AddrOf"), voidP, vo);
        IRValue* zeroP = nullPtrOf(voidP);

        String* ln = String.withString(prefix);
        ln.appendCString("_downcast_loop");
        String* en = String.withString(prefix);
        en.appendCString("_downcast_end");
        String* an = String.withString(prefix);
        an.appendCString("_downcast_adv");
        IRBlock* loopB = addBlock(ln);
        IRBlock* endB = addBlock(en);
        IRBlock* advB = addBlock(an);

        IRInsn* toLoop = IRInsn.with(String.withCString("Branch"));
        toLoop.add(IROperand.block(loopB));
        _blk.setTerm(toLoop);

        // The chain cursor: obj's own vtable on the way in, the parent link on
        // the way round.
        IRValue* p = new IRValue(voidP);

        _blk = advB;
        IRValue* pParent = walkAdvance(p, vpp, voidP, loopB);
        walkTest(p, target, loopB, joinB, endB);
        walkEnd(p, zeroP, endB, missB, advB);

        IRInsn* phi = IRInsn.with(String.withCString("Phi"));
        phi.setRes(p);
        phi.add(IROperand.block(checkB));
        phi.add(IROperand.useVal(vtbl0));
        phi.add(IROperand.block(advB));
        phi.add(IROperand.useVal(pParent));
        loopB.addPhi(phi);
        return loopB;
        }

    // advBlock: parent = *p, then round again.
    IRValue* walkAdvance(IRValue* p, String* vpp, String* voidP, IRBlock* loopB)
        {
        Array* ops = new Array();
        ops.add((Object*)IROperand.useVal(p));
        IRValue* pAsPP = emit(String.withCString("Bitcast"), vpp, ops);
        IRValue* parent = loadThroughIr(pAsPP, voidP);
        IRInsn* t = IRInsn.with(String.withCString("Branch"));
        t.add(IROperand.block(loopB));
        _blk.setTerm(t);
        return parent;
        }

    // loopBlock: p == target -> the cast succeeded.
    void walkTest(IRValue* p, IRValue* target, IRBlock* loopB, IRBlock* joinB, IRBlock* endB)
        {
        _blk = loopB;
        IRInsn* c = IRInsn.with(String.withCString("ICmp"));
        c.setRes(new IRValue(String.withCString("Bool")));
        c.setPred(String.withCString("EQ"));
        c.add(IROperand.useVal(p));
        c.add(IROperand.useVal(target));
        _blk.add(c);
        IRInsn* t = IRInsn.with(String.withCString("CondBranch"));
        t.add(IROperand.useVal(c.res()));
        t.add(IROperand.block(joinB));
        t.add(IROperand.block(endB));
        _blk.setTerm(t);
        }

    // The chain is exhausted when the link is null: no ancestor matched.
    void walkEnd(IRValue* p, IRValue* zeroP, IRBlock* endB, IRBlock* missB, IRBlock* advB)
        {
        _blk = endB;
        IRInsn* c = IRInsn.with(String.withCString("ICmp"));
        c.setRes(new IRValue(String.withCString("Bool")));
        c.setPred(String.withCString("EQ"));
        c.add(IROperand.useVal(p));
        c.add(IROperand.useVal(zeroP));
        _blk.add(c);
        IRInsn* t = IRInsn.with(String.withCString("CondBranch"));
        t.add(IROperand.useVal(c.res()));
        t.add(IROperand.block(missB));
        t.add(IROperand.block(advB));
        _blk.setTerm(t);
        }

    // Does the operand's STATIC class already say it conforms? Then the cast
    // is a plain upcast and there is nothing to test.
    bool staticallyConforms(ClassInfo* src, String* proto)
        {
        if (src == 0)
            return false; // unknown operand: ask at run time
        for (ClassInfo* c = src; c != 0; c = c.parent())
            {
            Array* ps = splitList(c.decl().extra());
            for (u32 i = (u32)0; i < ps.count(); i = i + (u32)1)
                if (((String*)ps.get(i)).equals(proto))
                    return true;
            }
        return false;
        }

    // `(P@ ?)obj` / `(P@)obj` — the runtime conformance downcast. The helper
    // takes an ALREADY-VALIDATED vtable pointer, so the caller reads obj[0]
    // and passes null when the object is null or when slot 0 holds a
    // non-vtable class's small class-id. That full-width compare cannot be
    // written in the language — pointer compares there are 16-bit — which is
    // why the test lives here and the helper takes what it takes.
    IRValue* lowerProtoDowncast(Node* n, IRValue* src, String* proto, bool failable)
        {
        String* voidP = ptrTo(String.withCString("Void"));
        String* dstIr = irType(n.name());
        Array* bops = new Array();
        bops.add((Object*)IROperand.useVal(src));
        IRValue* asP = emit(String.withCString("Bitcast"), dstIr, bops);
        IRValue* nullP = nullPtrOf(dstIr);
        IRValue* srcNull = nullPtrOf(src.ty());
        IRInsn* isNull = IRInsn.with(String.withCString("ICmp"));
        isNull.setRes(new IRValue(String.withCString("Bool")));
        isNull.setPred(String.withCString("EQ"));
        isNull.add(IROperand.useVal(src));
        isNull.add(IROperand.useVal(srcNull));
        _blk.add(isNull);
        IRValue* falseC = boolConst(false);

        String* prefix = blockPrefix();
        prefix.appendCString("_protocast");
        String* rn = String.withString(prefix);
        rn.appendCString("_read");
        String* jn = String.withString(prefix);
        jn.appendCString("_join");
        IRBlock* entryB = _blk;
        IRBlock* readB = addBlock(rn);
        IRBlock* joinB = addBlock(jn);
        IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
        cb.add(IROperand.useVal(isNull.res()));
        cb.add(IROperand.block(joinB));
        cb.add(IROperand.block(readB));
        _blk.setTerm(cb);

        _blk = readB;
        IRValue* okRead = emitConformsCall(src, proto, voidP);
        IRBlock* readEnd = _blk;
        IRInsn* toJoin = IRInsn.with(String.withCString("Branch"));
        toJoin.add(IROperand.block(joinB));
        _blk.setTerm(toJoin);

        _blk = joinB;
        IRInsn* phi = IRInsn.with(String.withCString("Phi"));
        IRValue* ok = new IRValue(String.withCString("Bool"));
        phi.setRes(ok);
        Array* pb = new Array();
        Array* pv = new Array();
        pb.add((Object*)entryB);
        pv.add((Object*)falseC);
        pb.add((Object*)readEnd);
        pv.add((Object*)okRead);
        sortEdgesByBlock(pb, pv);
        rebuildPhi(phi, pb, pv);
        joinB.addPhi(phi);

        if (failable)
            {
            Array* sops = new Array();
            sops.add((Object*)IROperand.useVal(ok));
            sops.add((Object*)IROperand.useVal(asP));
            sops.add((Object*)IROperand.useVal(nullP));
            IRValue* sel = emit(String.withCString("Select"), dstIr, sops);
            retargetOwnedTemp(src, sel);
            return sel;
            }
        protoTrapOnMiss(ok, prefix);
        retargetOwnedTemp(src, asP);
        return asP;
        }

    // A plain `(P@)obj` that does not conform is a program error, the same
    // contract the class downcast has.
    void protoTrapOnMiss(IRValue* ok, String* prefix)
        {
        String* cn = String.withString(prefix);
        cn.appendCString("_ok");
        String* mn = String.withString(prefix);
        mn.appendCString("_miss");
        IRBlock* contB = addBlock(cn);
        IRBlock* trapB = addBlock(mn);
        IRInsn* t = IRInsn.with(String.withCString("CondBranch"));
        t.add(IROperand.useVal(ok));
        t.add(IROperand.block(contB));
        t.add(IROperand.block(trapB));
        _blk.setTerm(t);
        _blk = trapB;
        _blk.setTerm(IRInsn.with(String.withCString("Unreachable")));
        _blk = contB;
        }

    // Read obj[0] and hand the helper a vtable pointer or null. A value below
    // 0xFFFF is a non-vtable class's id, never an address — and the threshold
    // is 0xFFFF rather than 0x10000 because IntToPtr narrows to the front
    // end's pointer width, which would truncate 0x10000 to zero.
    IRValue* emitConformsCall(IRValue* src, String* proto, String* voidP)
        {
        Array* bops = new Array();
        bops.add((Object*)IROperand.useVal(src));
        IRValue* objPP = emit(String.withCString("Bitcast"), ptrTo(voidP), bops);
        IRValue* vtbl = loadThroughIr(objPP, voidP);
        Array* tops = new Array();
        tops.add((Object*)IROperand.immI((i32)65535, String.withCString("U16")));
        IRValue* thrI = emit(String.withCString("Const"), String.withCString("U16"), tops);
        Array* tp = new Array();
        tp.add((Object*)IROperand.useVal(thrI));
        IRValue* thrP = emit(String.withCString("IntToPtr"), voidP, tp);
        IRInsn* isSmall = IRInsn.with(String.withCString("ICmp"));
        isSmall.setRes(new IRValue(String.withCString("Bool")));
        isSmall.setPred(String.withCString("ULT"));
        isSmall.add(IROperand.useVal(vtbl));
        isSmall.add(IROperand.useVal(thrP));
        _blk.add(isSmall);
        IRValue* nullVtbl = nullPtrOf(voidP);
        Array* sops = new Array();
        sops.add((Object*)IROperand.useVal(isSmall.res()));
        sops.add((Object*)IROperand.useVal(nullVtbl));
        sops.add((Object*)IROperand.useVal(vtbl));
        IRValue* safeVtbl = emit(String.withCString("Select"), voidP, sops);
        Array* pops = new Array();
        pops.add((Object*)IROperand.immU(protocolId(proto), String.withCString("U32")));
        IRValue* pidV = emit(String.withCString("Const"), String.withCString("U32"), pops);
        Array* args = new Array();
        args.add((Object*)safeVtbl);
        args.add((Object*)pidV);
        return emitMethodCall(String.withCString("_xtc_obj_conforms"), (IRValue*)0,
                              args, String.withCString("bool"), true);
        }

    IRValue* boolConst(bool v)
        {
        Array* ops = new Array();
        ops.add((Object*)IROperand.immI(v ? (i32)1 : (i32)0, String.withCString("Bool")));
        return emit(String.withCString("Const"), String.withCString("Bool"), ops);
        }

    IRValue* nullPtrOf(String* ptrTy)
        {
        Array* zops = new Array();
        zops.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
        IRValue* z = emit(String.withCString("Const"), String.withCString("U16"), zops);
        Array* nops = new Array();
        nops.add((Object*)IROperand.useVal(z));
        return emit(String.withCString("IntToPtr"), ptrTy, nops);
        }

    // Is this pointer null? On the banked 6502 a pointer is three bytes and an
    // object is identified by its two-byte ADDRESS, so the bank byte is dropped
    // and the test is on the address. On a flat target the WHOLE pointer is
    // compared — narrowing to 16 bits there reads a 64 KB-aligned object as
    // null.
    IRValue* cmpPtrZero(IRValue* p)
        {
        if (_ptrW != (u32)3)
            {
            IRValue* nullP = nullPtrOf(p.ty());
            IRInsn* fc = IRInsn.with(String.withCString("ICmp"));
            fc.setRes(new IRValue(String.withCString("Bool")));
            fc.setPred(String.withCString("EQ"));
            fc.add(IROperand.useVal(p));
            fc.add(IROperand.useVal(nullP));
            _blk.add(fc);
            return fc.res();
            }
        Array* pops = new Array();
        pops.add((Object*)IROperand.useVal(p));
        IRValue* asInt = emit(String.withCString("PtrToInt"), String.withCString("U16"), pops);
        Array* zo = new Array();
        zo.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
        IRValue* zero = emit(String.withCString("Const"), String.withCString("U16"), zo);
        IRInsn* c = IRInsn.with(String.withCString("ICmp"));
        c.setRes(new IRValue(String.withCString("Bool")));
        c.setPred(String.withCString("EQ"));
        c.add(IROperand.useVal(asInt));
        c.add(IROperand.useVal(zero));
        _blk.add(c);
        return c.res();
        }

    // The instance's slot 0 IS its class's vtable address, so one load and one
    // compare answers "is this really one of those".
    void emitVtableIdentityBranch(IRValue* src, ClassInfo* ci, IRBlock* hitB, IRBlock* missB)
        {
        // A class that DISPATCHES puts its vtable address in slot 0; one that
        // does not puts its RTTI class ID in the same word. Either way slot 0
        // says what the instance is — but only one of the two is a pointer,
        // and comparing an id against an address would never match.
        if (!ci.needsVtable())
            {
            emitClassIdIdentityBranch(src, ci, hitB, missB);
            return;
            }
        String* vpp = ptrTo(ptrTo(String.withCString("Void")));
        Array* b2 = new Array();
        b2.add((Object*)IROperand.useVal(src));
        IRValue* slotP = emit(String.withCString("Bitcast"), vpp, b2);
        IRValue* slot0 = loadThrough(slotP, String.withCString("pointer"));
        // On the banked 6502 a pointer is three bytes and every vtable lives in
        // the data window, so the identity is its two-byte ADDRESS and the bank
        // byte is dropped. A flat target compares the WHOLE pointer — narrowing
        // there would make two vtables 64 KB apart compare equal.
        IRValue* gotInt = slot0;
        if (_ptrW == (u32)3)
            {
            Array* p2 = new Array();
            p2.add((Object*)IROperand.useVal(slot0));
            gotInt = emit(String.withCString("PtrToInt"), String.withCString("U16"), p2);
            }
        // A downcast to T accepts T *and every class below it*: a Puppy IS a
        // Dog, and testing only Dog's own vtable would reject it. The subtree
        // is walked in class-NAME order, which is a property of the program
        // rather than of a table's iteration order.
        IRValue* matched = (IRValue*)0;
        Array* sub = subtreeOf(ci);
        for (u32 si = (u32)0; si < sub.count(); si = si + (u32)1)
            {
            ClassInfo* c = (ClassInfo*)sub.get(si);
            if (!c.needsVtable())
                continue;
            String* vn = String.withString(c.name());
            vn.appendCString("$vtbl");
            Array* vo = new Array();
            vo.add((Object*)IROperand.sym(vn));
            IRValue* vtbl = emit(String.withCString("AddrOf"),
                                 ptrTo(String.withCString("Void")), vo);
            IRValue* wantInt = vtbl;
            if (_ptrW == (u32)3)
                {
                Array* p3 = new Array();
                p3.add((Object*)IROperand.useVal(vtbl));
                wantInt = emit(String.withCString("PtrToInt"),
                               String.withCString("U16"), p3);
                }
            IRInsn* hit = IRInsn.with(String.withCString("ICmp"));
            hit.setRes(new IRValue(String.withCString("Bool")));
            hit.setPred(String.withCString("EQ"));
            hit.add(IROperand.useVal(gotInt));
            hit.add(IROperand.useVal(wantInt));
            _blk.add(hit);
            if (matched == 0)
                {
                matched = hit.res();
                continue;
                }
            Array* oo = new Array();
            oo.add((Object*)IROperand.useVal(matched));
            oo.add((Object*)IROperand.useVal(hit.res()));
            matched = emit(String.withCString("Or"), String.withCString("Bool"), oo);
            }
        IRInsn* cb2 = IRInsn.with(String.withCString("CondBranch"));
        cb2.add(IROperand.useVal(matched));
        cb2.add(IROperand.block(hitB));
        cb2.add(IROperand.block(missB));
        _blk.setTerm(cb2);
        }

    // `&Klass.staticMethod` has NO receiver: the class name is not a value. It
    // is a plain function being widened, and it widens the same way one does —
    // the code address rides in the receiver word and the signature's
    // trampoline jumps through it.
    bool namesAClass(Node* recvNode)
        {
        if (recvNode.kind() != (u16)nkIdent)
            return false;
        if (classFor(recvNode.name()) == 0)
            return false;
        if (_locals.get((Hashable*)recvNode.name()) != 0)
            return false;
        return pinOf(recvNode.name()) == (IRPinned*)0;
        }

    IRValue* boundStaticRef(Node* ma, Node* n, String* owner)
        {
        String* ssym = String.withString(owner);
        ssym.appendByte((u8)'$');
        ssym.append(ma.bound());
        Array* sops = new Array();
        sops.add((Object*)IROperand.sym(ssym));
        // Just the code ADDRESS: the pair is built where it is needed, by the
        // same widening any plain function goes through when it reaches a `^`.
        return emit(String.withCString("AddrOf"),
                    ptrTo(String.withCString("Void")), sops);
        }

    // The implementation behind a `&obj.method` — read out of the receiver's
    // own table. Through the ITABLE where dispatch goes that way (protocol id
    // + the requirement's index), through the flat vtable slot otherwise.
    IRValue* emitBoundLoad(Node* ma, IRValue* recv, String* fnPtr)
        {
        // The analyser stamped both when it resolved the reference to a
        // protocol REQUIREMENT: which protocol, and the requirement's position
        // in it.
        String* pn = ma.boundProto();
        i32 idx = (_itableDispatch && pn != 0) ? ma.boundPIdx() : (i32)-1;
        IRInsn* vl = IRInsn.with(String.withCString(idx >= (i32)0 ? "ProtoLoad"
                                                                  : "VTblLoad"));
        IRValue* code = new IRValue(fnPtr);
        vl.setRes(code);
        IRValue* nm = new IRValue(String.withCString("Mem"));
        vl.setMemRes(nm);
        vl.add(IROperand.useVal(recv));
        if (idx >= (i32)0)
            {
            vl.add(IROperand.immU(protocolId(pn), String.withCString("U32")));
            vl.add(IROperand.immI(idx, String.withCString("U16")));
            }
        else
            {
            vl.add(IROperand.immI(ma.boundSlot() + (i32)vtblSlotBias(),
                                  String.withCString("U16")));
            }
        vl.add(IROperand.useVal(_mem));
        _blk.add(vl);
        _mem = nm;
        return code;
        }

    IRValue* lowerBoundMethodRef(Node* ma, Node* n)
        {
        String* fnPtr = ptrTo(String.withCString("Void"));
        Node* recvNode = ma.kid((u32)0);
        String* owner = ma.boundCls();
        if (namesAClass(recvNode) && owner != 0)
            return boundStaticRef(ma, n, owner);
        IRValue* recv = lowerExpr(recvNode);
        if (_failed)
            return (IRValue*)0;
        // Virtual or protocol dispatch reads the implementation out of the
        // receiver's own table; a concrete method binds its symbol directly.
        IRValue* code = (IRValue*)0;
        if (ma.boundSlot() >= (i32)0)
            {
            code = emitBoundLoad(ma, recv, fnPtr);
            }
        else
            {
            // A concrete method binds its symbol directly — which needs to
            // know which class owns it. A protocol-bound one took the branch
            // above and never asks.
            if (owner == 0)
                {
                giveUp(String.withCString("bound method with no owner"));
                return (IRValue*)0;
                }
            String* sym = String.withString(owner);
            sym.appendByte((u8)'$');
            sym.append(ma.bound());
            Array* cops = new Array();
            cops.add((Object*)IROperand.sym(sym));
            code = emit(String.withCString("AddrOf"), fnPtr, cops);
            }
        // Truthiness tests the RECV word, so an UNIMPLEMENTED optional method
        // — which has a null code word and a perfectly good receiver — has to
        // force recv to null as well, or `if (h)` reports it as present and
        // the call jumps to zero. Only a slot LOAD can produce a null code;
        // for a concrete symbol the compare folds away.
        if (ma.boundSlot() >= (i32)0)
            {
            Array* zops = new Array();
            zops.add((Object*)IROperand.immI((i32)0, fnPtr));
            IRValue* zeroP = emit(String.withCString("Const"), fnPtr, zops);
            IRInsn* cmp = IRInsn.with(String.withCString("ICmp"));
            cmp.setRes(new IRValue(String.withCString("Bool")));
            cmp.setPred(String.withCString("EQ"));
            cmp.add(IROperand.useVal(code));
            cmp.add(IROperand.useVal(zeroP));
            _blk.add(cmp);
            Array* sops = new Array();
            sops.add((Object*)IROperand.useVal(cmp.res()));
            sops.add((Object*)IROperand.useVal(zeroP));
            sops.add((Object*)IROperand.useVal(recv));
            // The RECEIVER's own type, not the code pointer's: the value being
            // chosen between is a receiver either way.
            recv = emit(String.withCString("Select"), recv.ty(), sops);
            }
        Array* bops = new Array();
        bops.add((Object*)IROperand.useVal(recv));
        bops.add((Object*)IROperand.useVal(code));
        return emit(String.withCString("AggBuild"), irType(n.ty()), bops);
        }

    // The target class and everything below it, in class-NAME order.
    Array* subtreeOf(ClassInfo* target)
        {
        Array* out = new Array();
        Array* names = sortedNames(_classDecls.allKeys());
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            ClassInfo* ci = classFor((String*)names.get(i));
            for (ClassInfo* c = ci; c != 0; c = c.parent())
                if (c == target)
                    {
                    out.add((Object*)ci);
                    break;
                    }
            }
        return out;
        }

    void emitClassIdIdentityBranch(IRValue* src, ClassInfo* ci, IRBlock* hitB, IRBlock* missB)
        {
        Array* b2 = new Array();
        b2.add((Object*)IROperand.useVal(src));
        IRValue* slotP = emit(String.withCString("Bitcast"),
                              ptrTo(String.withCString("U16")), b2);
        IRValue* got = loadThrough(slotP, String.withCString("u16"));
        Array* wo = new Array();
        wo.add((Object*)IROperand.immI((i32)ci.classId(), String.withCString("U16")));
        IRValue* want = emit(String.withCString("Const"), String.withCString("U16"), wo);
        IRInsn* hit = IRInsn.with(String.withCString("ICmp"));
        hit.setRes(new IRValue(String.withCString("Bool")));
        hit.setPred(String.withCString("EQ"));
        hit.add(IROperand.useVal(got));
        hit.add(IROperand.useVal(want));
        _blk.add(hit);
        IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
        cb.add(IROperand.useVal(hit.res()));
        cb.add(IROperand.block(hitB));
        cb.add(IROperand.block(missB));
        _blk.setTerm(cb);
        }

    // A `^` of signature S can only ever carry ONE trampoline, so its name is
    // derived from the signature and a single compare settles whether a given
    // `^` is a widened plain function. The body is the widening: take the
    // receiver word as the code address and jump through it.
    String* boundTrampoline(String* boundSpelling)
        {
        String* sig = boundSignatureOf(boundSpelling);
        Object* have = _tramps.get((Hashable*)sig);
        if (have != 0)
            return (String*)have;
        String* name = String.withCString("__bm_tramp_");
        for (u32 i = (u32)0; i < sig.byteLength(); i = i + (u32)1)
            {
            u8 c = sig.byteAt(i);
            bool ok = (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9');
            name.appendByte(ok ? c : (u8)'_');
            }
        Array* ptys = sigParamTypes(sig);
        String* ret = sigReturnType(sig);

        String* ssig = String.withCString("(");
        ssig.append(ptrTo(String.withCString("Void")));
        for (u32 i = (u32)0; i < ptys.count(); i = i + (u32)1)
            {
            ssig.appendCString(", ");
            ssig.append(irType((String*)ptys.get(i)));
            }
        ssig.appendCString(") -> ");
        ssig.append(irType(ret));
        _m.addSym(IRSymbol.func(name, ssig, false, false));
        _tramps.set((Hashable*)sig, (Object*)name);
        emitTrampolineBody(name, ptys, ret);
        return name;
        }

    void emitTrampolineBody(String* name, Array* ptys, String* ret)
        {
        IRFunc* saveFn = _fn;
        IRBlock* saveBlk = _blk;
        IRValue* saveMem = _mem;
        _fn = new IRFunc();
        _fn.setName(name);
        _fn.setRet(irType(ret));
        IRValue* codeP = new IRValue(ptrTo(String.withCString("Void")));
        _fn.addParam(codeP);
        Array* args = new Array();
        for (u32 i = (u32)0; i < ptys.count(); i = i + (u32)1)
            {
            IRValue* v = new IRValue(irType((String*)ptys.get(i)));
            _fn.addParam(v);
            args.add((Object*)v);
            }
        _mem = new IRValue(String.withCString("Mem"));
        _fn.addParam(_mem);
        _blk = new IRBlock(String.withCString("bb_entry"));
        _fn.addBlock(_blk);

        IRInsn* c = IRInsn.with(String.withCString("CallIndirect"));
        c.add(IROperand.useVal(codeP));
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            c.add(IROperand.useVal((IRValue*)args.get(i)));
        c.add(IROperand.useVal(_mem));
        IRValue* r = (IRValue*)0;
        if (!isName(irType(ret), "Void"))
            {
            r = new IRValue(irType(ret));
            c.setRes(r);
            }
        IRValue* nm = new IRValue(String.withCString("Mem"));
        c.setMemRes(nm);
        c.setCc(String.withCString("CallConv::Standard"));
        _blk.add(c);
        _mem = nm;
        IRInsn* rt = IRInsn.with(String.withCString("Return"));
        if (r != 0)
            rt.add(IROperand.useVal(r));
        rt.add(IROperand.useVal(_mem));
        _blk.setTerm(rt);
        _pendingFns.add((Object*)_fn);
        _fn = saveFn;
        _blk = saveBlk;
        _mem = saveMem;
        }

    // `u8(u8, u16)` -> the parameter spellings, and the return spelling.
    Array* sigParamTypes(String* sig)
        {
        Array* out = new Array();
        u32 open = String.notFound();
        for (u32 i = (u32)0; i < sig.byteLength(); i = i + (u32)1)
            if (sig.byteAt(i) == (u8)'(')
                {
                open = i;
                break;
                }
        if (open == String.notFound())
            return out;
        u32 start = open + (u32)1;
        u32 depth = (u32)0;
        for (u32 i = start; i < sig.byteLength(); i = i + (u32)1)
            {
            u8 c = sig.byteAt(i);
            if (c == (u8)'(')
                depth = depth + (u32)1;
            else if (c == (u8)')' && depth > (u32)0)
                depth = depth - (u32)1;
            else if ((c == (u8)',' || c == (u8)')') && depth == (u32)0)
                {
                if (i > start)
                    {
                    String* p = sig.substringBytes(start, i - start).trimmed();
                    if (p.byteLength() > (u32)0 && !isName(p, "void"))
                        out.add((Object*)p);
                    }
                start = i + (u32)1;
                if (c == (u8)')')
                    break;
                }
            }
        return out;
        }

    String* sigReturnType(String* sig)
        {
        for (u32 i = (u32)0; i < sig.byteLength(); i = i + (u32)1)
            if (sig.byteAt(i) == (u8)'(')
                return sig.substringBytes((u32)0, i);
        return sig;
        }

    // `x++` / `++x` / `x--`. The constant is emitted at the VARIABLE's type,
    // not at the literal width a `+ 1` would have used, and the result is
    // rebound. A postfix yields the value from BEFORE the step.
    // A GLOBAL — or a class's own static — has no SSA name to rebind: it is
    // memory, so stepping it is a load, an add and a store, and the address is
    // formed for each half rather than shared between them.
    IRValue* stepGlobal(Node* n, String* who, bool postfix)
        {
        String* gname = who;
        Object* gt = _globals.get((Hashable*)gname);
        if (gt == 0 && _curClass != 0)
            {
            String* sg = staticIvarFor(_curClass, who);
            if (sg != 0)
                {
                gname = sg;
                gt = (Object*)staticIvarTypeFor(_curClass, who);
                }
            }
        if (gt == 0)
            return (IRValue*)0;
        String* gty = (String*)gt;
        IRValue* old = loadGlobal(gname, gty);
        Array* gone = new Array();
        gone.add((Object*)IROperand.immI((i32)1, irType(gty)));
        IRValue* one3 = emit(String.withCString("Const"), irType(gty), gone);
        Array* gops = new Array();
        gops.add((Object*)IROperand.useVal(old));
        gops.add((Object*)IROperand.useVal(one3));
        IRValue* nxt3 = emit(String.withCString(isName(n.op(), "++") ? "Add" : "Sub"),
                             irType(gty), gops);
        storeGlobalARC(gname, gty, nxt3, (Node*)0);
        return postfix ? old : nxt3;
        }

    IRValue* lowerStep(Node* n, bool postfix)
        {
        Node* target = n.kid((u32)0);
        // `p[i]++` is a read-modify-write of a PLACE. The address is formed
        // once and used for both halves — recomputing it would evaluate the
        // index twice, and a stepping index would then write somewhere else.
        if (target.kind() == (u16)nkSubscript || (target.kind() == (u16)nkUnary && isName(target.op(), "*")))
            {
            IRValue* addr = (target.kind() == (u16)nkSubscript)
                                ? elementAddr(target)
                                : lowerExpr(target.kid((u32)0));
            if (_failed)
                return (IRValue*)0;
            String* ety = target.ty();
            IRValue* old = loadThrough(addr, ety);
            Array* sone = new Array();
            sone.add((Object*)IROperand.immI((i32)1, irType(ety)));
            IRValue* one2 = emit(String.withCString("Const"), irType(ety), sone);
            Array* sops = new Array();
            sops.add((Object*)IROperand.useVal(old));
            sops.add((Object*)IROperand.useVal(one2));
            IRValue* nxt2 = emit(String.withCString(isName(n.op(), "++") ? "Add" : "Sub"),
                                 irType(ety), sops);
            storeThrough(addr, nxt2);
            return postfix ? old : nxt2;
            }
        // `s.n++` / `p->m++` — a read-modify-write of a struct/class FIELD.
        // The 0.5 ++/-- rework dropped this lvalue shape (c2xc bug 35);
        // memberAddr forms the field address once, exactly as the subscript
        // case forms an element address.
        if (target.kind() == (u16)nkMember)
            {
            IRValue* maddr = memberAddr(target);
            if (_failed)
                return (IRValue*)0;
            String* mety = target.ty();
            IRValue* mold = loadThrough(maddr, mety);
            Array* mone = new Array();
            mone.add((Object*)IROperand.immI((i32)1, irType(mety)));
            IRValue* mo = emit(String.withCString("Const"), irType(mety), mone);
            Array* mops = new Array();
            mops.add((Object*)IROperand.useVal(mold));
            mops.add((Object*)IROperand.useVal(mo));
            IRValue* mnxt = emit(String.withCString(isName(n.op(), "++") ? "Add" : "Sub"),
                                 irType(mety), mops);
            storeThrough(maddr, mnxt);
            return postfix ? mold : mnxt;
            }
        if (target.kind() != (u16)nkIdent)
            {
            giveUpAt(String.withCString("step of a non-local"), n); // located (bug 35)
            return (IRValue*)0;
            }
        // A pinned local's step is a read-modify-write of the SLOT: rebinding
        // an SSA name would lose the increment the moment anything reads
        // through the address again.
        IRPinned* pin = pinOf(target.name());
        if (pin != 0)
            {
            String* pty = (String*)_pinAst.get((Hashable*)target.name());
            IRValue* old = loadThrough(pinAddr(pin), pty);
            Array* pone = new Array();
            pone.add((Object*)IROperand.immI((i32)1, irType(pty)));
            IRValue* one1 = emit(String.withCString("Const"), irType(pty), pone);
            Array* pops = new Array();
            pops.add((Object*)IROperand.useVal(old));
            pops.add((Object*)IROperand.useVal(one1));
            IRValue* nxt = emit(String.withCString(isName(n.op(), "++") ? "Add" : "Sub"),
                                irType(pty), pops);
            storeThrough(pinAddr(pin), nxt);
            return postfix ? old : nxt;
            }
        Object* tyo = _localTypes.get((Hashable*)target.name());
        if (tyo == 0)
            {
            IRValue* gv = stepGlobal(n, target.name(), postfix);
            if (gv != 0 || _failed)
                return gv;
            // A bare IVAR (`outstanding++` inside a method — implicit self) is
            // a read-modify-write of the ivar SLOT, exactly like
            // `self.outstanding++`. Without it the increment was rejected as a
            // "step of a non-local" (c2xc bug 35, the implicit-this half; the
            // reference silently lost it instead).
            if (_curClass != 0 && ivarIndexOf(target.name()) >= (i32)0)
                {
                IRValue* iaddr = ivarAddr(target.name());
                String* ity = (String*)_curClass.ivarType().get((Hashable*)target.name());
                IRValue* iold = loadThrough(iaddr, ity);
                Array* ione = new Array();
                ione.add((Object*)IROperand.immI((i32)1, irType(ity)));
                IRValue* io = emit(String.withCString("Const"), irType(ity), ione);
                Array* iops = new Array();
                iops.add((Object*)IROperand.useVal(iold));
                iops.add((Object*)IROperand.useVal(io));
                IRValue* inxt = emit(String.withCString(isName(n.op(), "++") ? "Add" : "Sub"),
                                     irType(ity), iops);
                storeThrough(iaddr, inxt);
                return postfix ? iold : inxt;
                }
            giveUpAt(String.withCString("step of a non-local"), n); // located (bug 35)
            return (IRValue*)0;
            }
        String* ty = (String*)tyo;
        IRValue* cur = (IRValue*)_locals.get((Hashable*)target.name());
        Array* cops = new Array();
        cops.add((Object*)IROperand.immI((i32)1, irType(ty)));
        IRValue* one = emit(String.withCString("Const"), irType(ty), cops);
        Array* ops = new Array();
        ops.add((Object*)IROperand.useVal(cur));
        ops.add((Object*)IROperand.useVal(one));
        IRValue* next = emit(String.withCString(isName(n.op(), "++") ? "Add" : "Sub"),
                             irType(ty), ops);
        _locals.set((Hashable*)target.name(), (Object*)next);
        return postfix ? cur : next;
        }

    // A string LITERAL is a symbol of its bytes — NUL included, because the
    // pointer that reaches the program has to be usable as a C string — and
    // the expression is that symbol's address.
    Array* _strBytes;
    u32 _strCount;

    Map* _strByText;

    IRValue* stringAddr(String* text)
        {
        // Identical literals SHARE a symbol. Two `""`s are the same bytes and
        // the same address, and emitting one symbol each both bloats the data
        // and renumbers every literal after them.
        if (_strByText == 0)
            {
            _strByText = new Map();
            _strCount = (u32)0;
            }
        Object* have = _strByText.get((Hashable*)text);
        if (have != 0)
            {
            Array* hops = new Array();
            hops.add((Object*)IROperand.sym((String*)have));
            return emit(String.withCString("AddrOf"),
                        String.withCString("Ptr(U8, unbanked)"), hops);
            }
        Array* bytes = new Array();
        for (u32 i = (u32)0; i < text.byteLength(); i = i + (u32)1)
            bytes.add((Object*)Number.with((u32)text.byteAt(i)));
        bytes.add((Object*)Number.with((u32)0));
        String* name = String.withCString("str_");
        name.appendFormat("%ld", (i32)_strCount);
        _strCount = _strCount + (u32)1;
        _strByText.set((Hashable*)text, (Object*)name);
        _m.addSym(IRSymbol.stringLit(name, bytes));
        Array* ops = new Array();
        ops.add((Object*)IROperand.sym(name));
        return emit(String.withCString("AddrOf"), String.withCString("Ptr(U8, unbanked)"), ops);
        }

    // A Load takes an address and the memory token and hands back the value
    // and the next token. Every read of memory in this file goes through it.
    IRValue* loadThrough(IRValue* addr, String* astTy)
        {
        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        IRValue* res = new IRValue(irType(astTy));
        IRValue* nextMem = new IRValue(String.withCString("Mem"));
        ld.setRes(res);
        ld.setMemRes(nextMem);
        ld.add(IROperand.useVal(addr));
        ld.add(IROperand.useVal(_mem));
        _blk.add(ld);
        _mem = nextMem;
        return res;
        }

    // …the same load, but with the pointee named as an IR type already. The
    // error channel has no AST type to spell: it holds "some Error@", which is
    // an opaque pointer and nothing narrower.
    IRValue* loadThroughIr(IRValue* addr, String* irTy)
        {
        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        IRValue* res = new IRValue(irTy);
        IRValue* nextMem = new IRValue(String.withCString("Mem"));
        ld.setRes(res);
        ld.setMemRes(nextMem);
        ld.add(IROperand.useVal(addr));
        ld.add(IROperand.useVal(_mem));
        _blk.add(ld);
        _mem = nextMem;
        return res;
        }

    void storeThrough(IRValue* addr, IRValue* v)
        {
        storeThrough(addr, v, true);
        }

    // `consumes` says whether the SLOT takes ownership of a +1 temp. Every real
    // slot does. The vararg marshalling area does NOT: `__xtc_va_buf` is a
    // scratch buffer nobody owns, so consuming there dropped the release and
    // leaked — `printf("%@", obj.child())` never freed the child (bug 037).
    //
    // The comment this replaces reasoned that consuming into a non-owning slot
    // "only leaks (the safe side), never over-releases". That was true, and the
    // outcome was exactly as predicted: it leaked.
    void storeThrough(IRValue* addr, IRValue* v, bool consumes)
        {
        // Storing a +1 into memory transfers ownership to that slot.
        if (consumes)
            consumeOwnedTemp(v);
        IRInsn* st = IRInsn.with(String.withCString("Store"));
        IRValue* nextMem = new IRValue(String.withCString("Mem"));
        st.setMemRes(nextMem);
        st.add(IROperand.useVal(addr));
        st.add(IROperand.useVal(v));
        st.add(IROperand.useVal(_mem));
        _blk.add(st);
        _mem = nextMem;
        }

    // ── pinned locals ────────────────────────────────────────────────────
    // A pinned local is not a value, it is a place. `p` names the SLOT, and
    // every read is AddrOf + Load, every write AddrOf + Store — which is
    // exactly what makes an aliased write through `&p` observable.

    // Reaching a declaration selects the slot for the type it declares. The
    // same name declared four times as `u8` and once as `u16` has TWO slots,
    // not five: the type is what tells them apart, not the count.
    void advancePinSlot(Node* decl)
        {
        String* name = decl.name();
        if (name == 0 || decl.op() == 0)
            return;
        Object* seq = _pinSeq.get((Hashable*)name);
        if (seq == 0)
            return;
        Array* all = (Array*)seq;
        Array* tys = (Array*)_pinDeclTys.get((Hashable*)name);
        if (tys == 0)
            return;
        for (u32 i = (u32)0; i < tys.count() && i < all.count(); i = i + (u32)1)
            {
            if (!((String*)tys.get(i)).equals(decl.op()))
                continue;
            _pins.set((Hashable*)name, all.get(i));
            _pinAst.set((Hashable*)name, tys.get(i));
            // Rebind ARRAY-NESS to THIS declaration too. _arrayElem is keyed by
            // NAME, so an array declaration anywhere in the function made every
            // bare-name use of that name decay to the array's address — a
            // sibling block's scalar of the same name included. The scope
            // save/restore already unwinds it on pop, so setting it per
            // declaration is all that was missing.
            if (all.count() > (u32)1)
                {
                if (isArrayLike(decl.op()))
                    _arrayElem.set((Hashable*)name, (Object*)elementOf(decl.op()));
                else
                    _arrayElem.remove((Hashable*)name);
                }
            return;
            }
        }

    IRPinned* pinOf(String* name)
        {
        if (name == 0)
            return (IRPinned*)0;
        Object* o = _pins.get((Hashable*)name);
        if (o == 0)
            return (IRPinned*)0;
        return (IRPinned*)o;
        }

    // The address a read or write of the local uses. For an auto-zeroing slot
    // that is the PAYLOAD, two words in — the links are the runtime's, not the
    // program's, and every load and store stays unchanged because of it.
    IRValue* pinAddr(IRPinned* p)
        {
        return pinAddrNamed(p, (String*)0);
        }

    IRValue* pinAddrNamed(IRPinned* p, String* name)
        {
        IRValue* base = pinSlotAddr(p);
        if (name == 0 || !hasName(_weakLocals, name))
            return base;
        String* payload = (String*)_pinAst.get((Hashable*)name);
        return fieldAddr(base, (u32)2, ptrTo(irType(payload)));
        }

    // The slot's own address — the whole [prev, next, payload] for a weak one.
    IRValue* pinSlotAddr(IRPinned* p)
        {
        Array* ops = new Array();
        ops.add((Object*)IROperand.useVal(p.val()));
        return emit(String.withCString("AddrOf"), ptrTo(p.ty()), ops);
        }

    // Copy each `&`-taken scalar/pointer parameter into its own frame slot,
    // once, before any user statement (bug 202) — see preScanPinned's param
    // branch. From here reads/writes of the name route through the pinned slot,
    // so the param value is read exactly here and `AddrOf name` targets the
    // slot, not the param value; that is what makes such a function safe to
    // inline. Sorted by name for a deterministic prologue order.
    void emitPinnedParamCopies()
        {
        if (_pinnedParamInit.count() == (u32)0)
            return;
        Array* pnames = sortedNames(_pinnedParamInit.allKeys());
        for (u32 pi = (u32)0; pi < pnames.count(); pi = pi + (u32)1)
            {
            String* pn = (String*)pnames.get(pi);
            IRPinned* p = pinOf(pn);
            IRValue* pv = (IRValue*)_pinnedParamInit.get((Hashable*)pn);
            if (p == (IRPinned*)0 || pv == (IRValue*)0)
                continue;
            storeThrough(pinAddrNamed(p, pn), pv);
            }
        }

    // A `^` goes falsy the instant its receiver dies, so its RECV word — the
    // same word truthiness tests, and the same word a `weak:T@` slot holds — is
    // what goes in the side table. That uniformity is the point: the runtime
    // zeroes word 0 whatever kind of slot it is, with no tag per node.
    //
    // A WIDENED plain function is the exception. Its recv is a code address:
    // nothing ever frees it, so the entry could never fire and would just burn
    // one of the table's bounded slots forever. A `^` of one signature can only
    // carry one trampoline, so one compare settles it — branchless, by
    // registering a null object, which the runtime already ignores.
    // A right-hand side that is STATICALLY a plain function being widened
    // needs no entry at all: its recv word is a code address, nothing ever
    // frees it, and the entry could never fire.
    bool isWidenedFn(Node* rhs)
        {
        if (rhs == 0 || rhs.ty() == 0)
            return false;
        String* t = stripQual(rhs.ty());
        if (isBoundSig(t))
            return false;
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            if (t.byteAt(i) == (u8)'(')
                return true;
        return false;
        }

    void registerBoundPair(IRValue* fatAddr, IRValue* fatVal, String* boundTy)
        {
        String* ptrT = ptrTo(String.withCString("Void"));
        IRValue* recvAddr = fieldAddr(fatAddr, (u32)0, ptrTo(ptrT));
        Array* r0 = new Array();
        r0.add((Object*)IROperand.useVal(fatVal));
        r0.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
        IRValue* recv = emit(String.withCString("AggExtract"), ptrT, r0);
        Array* r1 = new Array();
        r1.add((Object*)IROperand.useVal(fatVal));
        r1.add((Object*)IROperand.immI((i32)1, String.withCString("U16")));
        IRValue* code = emit(String.withCString("AggExtract"), ptrT, r1);

        Array* tops = new Array();
        tops.add((Object*)IROperand.sym(boundTrampoline(stripQual(boundTy))));
        IRValue* tramp = emit(String.withCString("AddrOf"), ptrT, tops);
        IRInsn* cmp = IRInsn.with(String.withCString("ICmp"));
        cmp.setRes(new IRValue(String.withCString("Bool")));
        cmp.setPred(String.withCString("EQ"));
        cmp.add(IROperand.useVal(code));
        cmp.add(IROperand.useVal(tramp));
        _blk.add(cmp);
        Array* zops = new Array();
        zops.add((Object*)IROperand.immI((i32)0, ptrT));
        IRValue* zero = emit(String.withCString("Const"), ptrT, zops);
        Array* sops = new Array();
        sops.add((Object*)IROperand.useVal(cmp.res()));
        sops.add((Object*)IROperand.useVal(zero));
        sops.add((Object*)IROperand.useVal(recv));
        IRValue* obj = emit(String.withCString("Select"), ptrT, sops);

        weakOp(String.withCString("WeakUnregister"), recvAddr, (IRValue*)0);
        weakOp(String.withCString("WeakRegister"), recvAddr, obj);
        }

    // A local's two link words start as whatever the frame last held, so they
    // are zeroed at the declaration. An object's ivars get this for free from
    // `new`; a frame slot does not, and the first unregister would otherwise
    // follow a garbage `pprev` and write through it.
    void weakLinkInit(String* name)
        {
        IRPinned* p = pinOf(name);
        if (p == 0)
            return;
        IRValue* base = pinSlotAddr(p);
        String* link = ptrTo(String.withCString("Void"));
        Array* zops = new Array();
        zops.add((Object*)IROperand.immI((i32)0, link));
        IRValue* z = emit(String.withCString("Const"), link, zops);
        storeThrough(fieldAddr(base, (u32)0, ptrTo(link)), z);
        storeThrough(fieldAddr(base, (u32)1, ptrTo(link)), z);
        }

    // Zero the hidden LINK words of every auto-zeroing field in a STRUCT LOCAL,
    // at its declaration.
    //
    // A frame slot holds whatever the last call left there, so the links start
    // as garbage and the first unregister would follow a garbage `pprev` and
    // write through it. An object's ivars get zeroed by `new`; a frame slot does
    // not. Same lesson as a plain weak local (weakLinkInit) — it was simply
    // never extended to a struct that CONTAINS such fields.
    void structWeakLinkInit(String* name, String* astTy)
        {
        IRPinned* p = pinOf(name);
        if (p == (IRPinned*)0 || astTy == (String*)0)
            return;
        Node* st = (Node*)_structs.get((Hashable*)stripQual(astTy));
        if (st == (Node*)0)
            return;

        String* link = ptrTo(String.withCString("Void"));
        IRValue* z = (IRValue*)0;
        u32 idx = (u32)0;
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            {
            String* ft = st.kid(i).op();
            if (!isWeakSlot(ft))
                {
                idx = idx + (u32)1;
                continue;
                }
            // One Const for the whole struct, but the base address is formed
            // again per field — the order the instructions come out in is the
            // order they are compared in.
            if (z == (IRValue*)0)
                {
                Array* zops = new Array();
                zops.add((Object*)IROperand.immI((i32)0, link));
                z = emit(String.withCString("Const"), link, zops);
                }
            IRValue* base = pinSlotAddr(p);
            storeThrough(fieldAddr(base, idx, ptrTo(link)), z);
            storeThrough(fieldAddr(base, idx + (u32)1, ptrTo(link)), z);
            idx = idx + (u32)3;
            }
        }

    // Re-link every auto-zeroing slot in a struct that was just COPIED whole
    // into `dstAddr`.
    //
    // An aggregate copy is a Load+Store of the entire struct, so it duplicates
    // the payload AND the two hidden link words — but linking is a side effect
    // the copy never performs. The destination LOOKED registered and was not:
    // when the referent died the runtime walked its chain, found only the
    // source slot and zeroed that, while the copy kept its stale pointer and
    // `if (h.p)` still tested true. Both slot kinds ride the same links, so
    // `weak:T@` and `^` were both affected.
    //
    // Zeroing the copied links FIRST is mandatory: _xtc_weak_register opens
    // with an unregister that follows the slot's CURRENT links, and a fresh
    // copy's pprev still points into the SOURCE's chain — registering blind
    // would splice the destination into the source's neighbours and write
    // through them.
    void relinkWeakSlotsAfterCopy(IRValue* dstAddr, String* astTy)
        {
        if (dstAddr == (IRValue*)0 || astTy == (String*)0)
            return;
        Node* st = (Node*)_structs.get((Hashable*)stripQual(astTy));
        if (st == (Node*)0)
            return;

        String* link = ptrTo(String.withCString("Void"));
        u32 idx = (u32)0;
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            {
            Node* f = st.kid(i);
            String* ft = f.op();
            if (!isWeakSlot(ft))
                {
                idx = idx + (u32)1;
                continue;
                }

            // The link words are real IR fields immediately before the payload
            // — idx and idx+1, payload at idx+2.
            Array* zops = new Array();
            zops.add((Object*)IROperand.immI((i32)0, link));
            IRValue* z = emit(String.withCString("Const"), link, zops);
            storeThrough(fieldAddr(dstAddr, idx, ptrTo(link)), z);
            storeThrough(fieldAddr(dstAddr, idx + (u32)1, ptrTo(link)), z);

            IRValue* slotA = fieldAddr(dstAddr, idx + (u32)2, ptrTo(irType(ft)));
            IRValue* pv = loadThrough(slotA, ft);
            if (isBoundSig(stripQual(ft)))
                registerBoundPair(slotA, pv, ft);
            else
                {
                weakOp(String.withCString("WeakRegister"), slotA, pv);
                }
            idx = idx + (u32)3;
            }
        }

    // An ARRAY local decays at every bare-name use: `a` is `&a[0]`, not the
    // aggregate's contents. So its address comes out typed as a pointer to the
    // ELEMENT, and the caller's ElementAddr strides by one element rather than
    // by the whole array.
    IRValue* arrayDecayAddr(String* name, IRPinned* p)
        {
        String* elem = (String*)_arrayElem.get((Hashable*)name);
        Array* ops = new Array();
        ops.add((Object*)IROperand.useVal(p.val()));
        return emit(String.withCString("AddrOf"), ptrTo(irType(elem)), ops);
        }

    IRValue* fieldAddr(IRValue* base, u32 index, String* fieldTy)
        {
        Array* ops = new Array();
        ops.add((Object*)IROperand.useVal(base));
        ops.add((Object*)IROperand.immI((i32)index, String.withCString("U8")));
        return emit(String.withCString("FieldAddr"), fieldTy, ops);
        }

    // The ADDRESS of an aggregate lvalue — the thing a member access indexes
    // into. A name resolves to its slot or its global; a nested member or a
    // subscript resolves through the enclosing address.
    IRValue* aggregateAddr(Node* e)
        {
        if (e == 0)
            {
            giveUp(String.withCString("null aggregate lvalue"));
            return (IRValue*)0;
            }
        if (e.kind() == (u16)nkIdent)
            {
            IRPinned* p = pinOf(e.name());
            // The PAYLOAD's address for an auto-zeroing slot: the two link
            // words in front of it are the runtime's, not the program's.
            if (p != 0)
                return pinAddrNamed(p, e.name());
            if (ivarIndexOf(e.name()) >= (i32)0)
                return ivarAddr(e.name());
            Object* g = _globals.get((Hashable*)e.name());
            if (g != 0)
                {
                Array* ops = new Array();
                ops.add((Object*)IROperand.sym(globalSymName(e.name())));
                return emit(String.withCString("AddrOf"), ptrTo(irType((String*)g)), ops);
                }
            String* w = String.withCString("aggregate lvalue ");
            w.append(e.name());
            giveUp(w);
            return (IRValue*)0;
            }
        if (e.kind() == (u16)nkMember)
            return memberAddr(e);
        if (e.kind() == (u16)nkSubscript)
            return elementAddr(e);
        // `(@p).x` — the deref's OPERAND is already the address, and reading
        // through it first only to take the address again would be one
        // indirection too many. This is what makes the dot form and `p->x`
        // the same access.
        if (e.kind() == (u16)nkUnary && isName(e.op(), "*"))
            return lowerExpr(e.kid((u32)0));
        giveUp(String.withCString("aggregate lvalue shape"));
        return (IRValue*)0;
        }

    // `base.field` / `base->field` as an ADDRESS. The field's index is what the
    // IR carries — the byte offset is the layout's business, not the
    // instruction's.
    IRValue* memberAddr(Node* n)
        {
        Node* base = n.kid((u32)0);
        String* bt = base.ty();
        // The two words of a `^`, addressed inside the pair the slot holds.
        if (isBoundSig(stripQual(bt)) && (isName(n.name(), "recv") || isName(n.name(), "code")))
            {
            IRValue* pairAddr = aggregateAddr(base);
            if (_failed)
                return (IRValue*)0;
            return fieldAddr(pairAddr, isName(n.name(), "recv") ? (u32)0 : (u32)1,
                             ptrTo(irType(n.ty())));
            }
        // A CLASS receiver: the reference IS the address, and the member is an
        // ivar rather than a struct field, so the field index comes from the
        // class's own map (which already carries the inherited ones).
        ClassInfo* ci = classFor(pointeeOf(bt));
        if (ci != 0)
            {
            Object* idx = ci.ivarIndex().get((Hashable*)n.name());
            if (idx == 0)
                {
                String* w = String.withCString("no ivar ");
                w.append(n.name());
                giveUp(w);
                return (IRValue*)0;
                }
            IRValue* recv = lowerExpr(base);
            if (_failed)
                return (IRValue*)0;
            String* ft = (String*)ci.ivarType().get((Hashable*)n.name());
            return fieldAddr(recv, ((Number*)idx).asU32(), ptrTo(irType(ft)));
            }
        Node* st = structDeclFor(pointeeOf(bt));
        if (st == 0)
            {
            String* gg = String.withCString("member of a non-struct A ");
            gg.append(bt);
            gg.appendCString(" .");
            gg.append(n.name());
            giveUp(gg);
            return (IRValue*)0;
            }
        i32 idx = fieldIndexOf(st, n.name());
        if (idx < (i32)0)
            {
            String* w = String.withCString("no field ");
            w.append(n.name());
            giveUp(w);
            return (IRValue*)0;
            }
        String* fieldTy = fieldTypeOf(st, n.name());
        // `->`, or a base that is already a pointer to the struct: the base
        // VALUE is the address. Otherwise the base is an lvalue to address.
        IRValue* baseAddr = (n.hasFlag((u32)NF_ARROW) || Types.isPointer(bt))
                                ? lowerExpr(base)
                                : aggregateAddr(base);
        if (_failed)
            return (IRValue*)0;
        return fieldAddr(baseAddr, (u32)idx, ptrTo(irType(fieldTy)));
        }

    // The type a member access reads — the declared type of the field it names.
    String* memberFieldType(Node* n)
        {
        // A `^` has exactly two members and they are not fields of any struct:
        // `.recv` is the receiver word, `.code` the entry point. They exist so
        // two `^`s can be compared for identity.
        if (isBoundSig(stripQual(n.kid((u32)0).ty())) && (isName(n.name(), "recv") || isName(n.name(), "code")))
            return n.ty();
        ClassInfo* ci = classFor(pointeeOf(n.kid((u32)0).ty()));
        if (ci != 0)
            {
            Object* t = ci.ivarType().get((Hashable*)n.name());
            return t == 0 ? (String*)0 : (String*)t;
            }
        Node* st = structDeclFor(pointeeOf(n.kid((u32)0).ty()));
        if (st == 0)
            return (String*)0;
        return fieldTypeOf(st, n.name());
        }

    String* pointeeOf(String* t)
        {
        if (t == 0 || t.byteLength() == (u32)0)
            return t;
        if (t.byteAt(t.byteLength() - (u32)1) == (u8)'*')
            return t.substringBytes((u32)0, t.byteLength() - (u32)1);
        return t;
        }

    // An array lvalue's address, typed as a pointer to its ELEMENT so the
    // caller's ElementAddr strides by one element and not by the whole array.
    // The storage address is the same whatever the pointee type says, so the
    // AddrOf / FieldAddr is emitted with the element-pointer result directly
    // and no cast is needed.
    IRValue* decayArrayBase(Node* base, String* elemPtr)
        {
        if (base.kind() == (u16)nkSubscript)
            return elementAddr(base);
        if (base.kind() == (u16)nkMember)
            {
            Node* owner = base.kid((u32)0);
            String* bt = owner.ty();
            ClassInfo* ci = classFor(pointeeOf(bt));
            if (ci != 0)
                {
                Object* idx = ci.ivarIndex().get((Hashable*)base.name());
                if (idx == 0)
                    {
                    giveUp(String.withCString("no array ivar"));
                    return (IRValue*)0;
                    }
                IRValue* recv = lowerExpr(owner);
                if (_failed)
                    return (IRValue*)0;
                return fieldAddr(recv, ((Number*)idx).asU32(), elemPtr);
                }
            Node* st = structDeclFor(pointeeOf(bt));
            if (st == 0)
                {
                giveUp(String.withCString("array member of a non-struct"));
                return (IRValue*)0;
                }
            i32 fi = fieldIndexOf(st, base.name());
            if (fi < (i32)0)
                {
                giveUp(String.withCString("no array field"));
                return (IRValue*)0;
                }
            IRValue* baseAddr = (base.hasFlag((u32)NF_ARROW) || Types.isPointer(bt))
                                    ? lowerExpr(owner)
                                    : aggregateAddr(owner);
            if (_failed)
                return (IRValue*)0;
            return fieldAddr(baseAddr, (u32)fi, elemPtr);
            }
        if (base.kind() != (u16)nkIdent)
            {
            giveUp(String.withCString("array base shape"));
            return (IRValue*)0;
            }
        IRPinned* p = pinOf(base.name());
        if (p != 0)
            {
            Array* ops = new Array();
            ops.add((Object*)IROperand.useVal(p.val()));
            return emit(String.withCString("AddrOf"), elemPtr, ops);
            }
        if (_globals.get((Hashable*)base.name()) != 0)
            {
            Array* ops = new Array();
            // globalSymName: a static-local array is global-backed under a
            // mangled symbol (bug 174).
            ops.add((Object*)IROperand.sym(globalSymName(base.name())));
            return emit(String.withCString("AddrOf"), elemPtr, ops);
            }
        i32 iv = ivarIndexOf(base.name());
        if (iv >= (i32)0)
            return fieldAddr(_self, (u32)iv, elemPtr);
        // A HEAP array is an SSA value, not storage: `u8@ buf = new u8[10]`
        // binds the pointer itself, and that pointer IS the base. There is
        // nothing to take the address of.
        Object* lv = _locals.get((Hashable*)base.name());
        if (lv != 0)
            return (IRValue*)lv;
        String* w = String.withCString("array ");
        w.append(base.name());
        w.appendCString(" is neither a local, a global, nor an ivar");
        giveUp(w);
        return (IRValue*)0;
        }

    // `base[i]` — the base's own address if it is an array, the pointer value
    // itself if it is a pointer, and the index widened to the u16 the address
    // arithmetic uses.
    // -fbounds-check: `_xt_check_bounds(ptr, idx, "file:line:col")` before the
    // address is used. The runtime reads the allocation's own header, so the
    // bound is the real one rather than a guess, and the site string is what
    // lets the report name the line — which is only expressible now that nodes
    // carry positions.
    void emitBoundsCheck(IRValue* ptr, IRValue* idx, Node* at)
        {
        if (!_boundsCheck || ptr == 0 || idx == 0)
            return;
        String* site = String.withCString("");
        if (at != 0 && at.file() != 0)
            site.append(baseName(at.file()));
        else
            site.appendCString("?");
        site.appendByte((u8)':');
        site.append(String.withU32(at == 0 ? (u32)0 : at.line()));
        site.appendByte((u8)':');
        site.append(String.withU32(at == 0 ? (u32)0 : at.col()));
        IRValue* sv = stringAddr(site);
        if (sv == 0)
            return;
        Array* cops = new Array();
        cops.add((Object*)IROperand.sym(runtimeHelper(String.withCString("_xt_check_bounds"))));
        cops.add((Object*)IROperand.useVal(ptr));
        cops.add((Object*)IROperand.useVal(idx));
        cops.add((Object*)IROperand.useVal(sv));
        cops.add((Object*)IROperand.useVal(_mem));
        IRInsn* c = IRInsn.with(String.withCString("Call"));
        for (u32 i = (u32)0; i < cops.count(); i = i + (u32)1)
            c.add((IROperand*)cops.get(i));
        IRValue* nm = new IRValue(String.withCString("Mem"));
        c.setMemRes(nm);
        c.setCc(String.withCString("CallConv::Standard"));
        _blk.add(c);
        _mem = nm;
        }

    // `a/b/c.xc` -> `c.xc`. The report names the file the user wrote, not the
    // path the compiler happened to resolve it through.
    String* baseName(String* path)
        {
        u32 cut = (u32)0;
        for (u32 i = (u32)0; i < path.byteLength(); i = i + (u32)1)
            if (path.byteAt(i) == (u8)'/')
                cut = i + (u32)1;
        if (cut == (u32)0)
            return path;
        return path.substringBytes(cut, path.byteLength() - cut);
        }

    IRValue* elementAddr(Node* n)
        {
        Node* baseNode = n.kid((u32)0);
        // An AUTO-ZEROING element is a SLOT, so the array strides by the slot
        // and the element's payload sits two words into it. A fresh slot
        // layout per mention, which is what the original does.
        bool weakElem = isWeakSlot(n.ty());
        String* slotAgg = weakElem ? weakSlotAggOf(n.ty()) : (String*)0;
        // A class INSTANCE element is already addressed by the class's own
        // reference type — wrapping another pointer round it would describe a
        // pointer to a pointer and stride by the wrong width.
        bool instElem = !weakElem && classFor(stripQual(n.ty())) != 0 && !Types.isPointer(n.ty());
        String* pty0 = instElem ? irType(n.ty()) : String.withCString("Ptr(");
        if (!instElem)
            {
            pty0.append(weakElem ? slotAgg : irType(n.ty()));
            pty0.appendCString(", unbanked)");
            }
        // An ARRAY base DECAYS to a pointer to its first element, wherever it
        // lives — a local's slot, a global's symbol, an ivar of the receiver,
        // or a field of something else. Loading it as a value would push the
        // whole aggregate; what the index wants is its address.
        IRValue* base = isArrayLike(baseNode.ty())
                            ? decayArrayBase(baseNode, pty0)
                            : lowerExpr(baseNode);
        if (_failed)
            return (IRValue*)0;
        IRValue* idx = lowerExpr(n.kid((u32)1));
        if (_failed)
            return (IRValue*)0;
        // A NARROW index is widened to the u16 address arithmetic uses. A wide
        // one is left alone — narrowing it would silently cap the reach of the
        // subscript at 64K, which is exactly what a u32 index is asking not to
        // happen. Only the declared width decides; the value's own IR type is
        // not the question here.
        if (astWidth(n.kid((u32)1).ty()) < (u32)2)
            idx = coerce(idx, n.kid((u32)1).ty(), String.withCString("u16"));
        String* pty = instElem ? irType(n.ty()) : String.withCString("Ptr(");
        if (!instElem)
            {
            pty.append(weakElem ? slotAgg : irType(n.ty()));
            pty.appendCString(", unbanked)");
            }
        // Checked BEFORE the address is formed: the point is to catch the bad
        // index, not to compute an address from it first.
        emitBoundsCheck(base, idx, n);
        Array* ops = new Array();
        ops.add((Object*)IROperand.useVal(base));
        ops.add((Object*)IROperand.useVal(idx));
        IRValue* ea = emit(String.withCString("ElementAddr"), pty, ops);
        // The PAYLOAD, past the links — every load and store of the element is
        // unchanged and only the layout knows.
        if (!weakElem)
            return ea;
        return fieldAddr(ea, (u32)2, ptrTo(irType(n.ty())));
        }

    IRValue* lowerExpr(Node* n)
        {
        if (n == 0 || _failed)
            {
            giveUp(String.withCString("null expression"));
            return (IRValue*)0;
            }
        u16 k = n.kind();

        if (k == (u16)nkFloat)
            {
            // The literal reaches the IR as the 64 bits of its DOUBLE value,
            // whatever type the slot it lands in has. Its `float` spelling
            // only decides the Const's TYPE — the payload is the same either
            // way, and the backend narrows.
            // The payload is the literal ROUNDED TO THE SLOT and widened
            // back: a `float` keeps only what a float can hold, so 2.718281828
            // in an F32 is the double nearest the f32 nearest it, not the
            // double nearest the text. Writing the full-precision double would
            // give the IR a value the target can never produce.
            String* fty = irType(n.ty());
            Array* fops = new Array();
            fops.add((Object*)IROperand.immF(
                fpBitsOfBytes(bytesOfData(FloatEncoding.ieeeBytes(
                    n.name(), fty.equals(String.withCString("F64"))))),
                fty));
            return emit(String.withCString("Const"), fty, fops);
            }
        if (k == (u16)nkInt)
            return constOf(n.num(), n.ty());
        if (k == (u16)nkChar)
            return constOf(n.num(), String.withCString("u8"));
        if (k == (u16)nkBool)
            return constOf(n.num(), String.withCString("bool"));

        if (k == (u16)nkIdent)
            return lowerIdentifier(n);

        if (k == (u16)nkCast)
            {
            IRValue* v = lowerExpr(n.kid((u32)0));
            if (_failed)
                return (IRValue*)0;
            // An explicit pointer-to-pointer CAST always marks the crossing,
            // even where a coercion between the same two types would emit
            // nothing: the widths agree, but what the bits are said to point
            // at does not, and the IR records that the program asked.
            String* st = n.kid((u32)0).ty();
            // `(T@ ?)obj` — a FAILABLE downcast. It is not a reinterpretation:
            // the answer is the value when the object really is a T, and null
            // when it is not, so the test has to run at run time and the two
            // outcomes meet in a phi. A null input skips the test entirely —
            // there is nothing to read a vtable out of.
            // A cast DOWN the hierarchy is checked; a cast UP is not. Going up
            // is always true by construction — every Node is an Object — so
            // there is nothing to test and the bits are simply relabelled.
            ClassInfo* tgt = classFor(pointeeOf(n.name()));
            ClassInfo* src = classFor(pointeeOf(st));
            if (tgt != 0 && src != 0 && !isAncestorOf(tgt, src))
                return lowerDowncast(n, v, n.hasFlag((u32)NF_FAILABLE));
            // `(P@ ?)obj` where the operand is not KNOWN to conform. On a
            // backend that carries the conformance itable the object itself
            // answers at run time: the helper walks its vtable's itable
            // looking for the protocol's id. Where there is no itable the
            // analyser has already refused the cast, so this never fires.
            String* tproto = pointeeOf(n.name());
            if (_vtItable && _protocols.get((Hashable*)tproto) != 0 && Types.isPointer(st) && !staticallyConforms(src, tproto) && symbolNamed(String.withCString("_xtc_obj_conforms")) != 0)
                return lowerProtoDowncast(n, v, tproto, n.hasFlag((u32)NF_FAILABLE));
            if (Types.isPointer(st) && Types.isPointer(n.name()))
                {
                Array* bops = new Array();
                bops.add((Object*)IROperand.useVal(v));
                IRValue* bc = emit(String.withCString("Bitcast"), irType(n.name()), bops);
                // A cast is transparent to ownership, so the sweep has to be
                // able to walk back through it: `return (Object@)local` still
                // returns the LOCAL, and releasing that local would hand the
                // caller a dead object.
                _bcTo.add((Object*)bc);
                _bcFrom.add((Object*)v);
                // Ownership follows the cast: `(P@)new C()` must have the
                // scope-exit sweep release the LIVE value, not the pre-cast
                // temporary, or the object is freed through the upcast and
                // every later dispatch through it reads a dead vtable.
                retargetOwnedTemp(v, bc);
                return bc;
                }
            return coerce(v, st, n.name());
            }

        if (k == (u16)nkNew)
            return lowerNew(n);
        if (k == (u16)nkMethodCall)
            return lowerMethodCall(n);
        if (k == (u16)nkBinary)
            return lowerBinary(n);
        if (k == (u16)nkAssign)
            return lowerAssign(n);
        if (k == (u16)nkCall)
            return lowerCall(n);
        if (k == (u16)nkTernary)
            return lowerTernary(n);
        // `sizeof` measures the OPERAND, not the expression: it is a
        // compile-time constant of the operand's width, and reading the width
        // off the sizeof node's own type would answer 2 for everything.
        if (k == (u16)nkSizeof)
            return lowerSizeof(n);
        // `.length` on an ARRAY is a compile-time constant: the declared
        // element count. It is not a field of anything, and the declaration is
        // the only thing that knows the number.
        if (k == (u16)nkMember && isName(n.name(), "length"))
            {
            String* bt = declaredTypeOf(n.kid((u32)0));
            if (isArrayLike(bt))
                return u16Const(arrayCount(bt));
            Object* hl = n.kid((u32)0).kind() == (u16)nkIdent
                             ? _heapArrayLen.get((Hashable*)n.kid((u32)0).name())
                             : (Object*)0;
            // `T@ p = new T[N]` recorded N where it was bound — the fast
            // path: a compile-time constant.
            if (hl != 0)
                return u16Const(((Number*)hl).asU32());
            // Runtime-sized: a REAL header read via the per-runtime
            // `_xtc_count`, on every target whose allocator writes a count
            // (pointer width >= 4 — the 6502 family is 2/3 and keeps the
            // compile-time-only diagnostic). Mirror of the original.
            // private:docs/bugs/045.
            String* pbt = n.kid((u32)0).ty();
            if (pbt != 0 && Types.isPointer(pbt) && _ptrW >= (u32)4)
                {
                IRValue* pv = lowerExpr(n.kid((u32)0));
                if (_failed)
                    return (IRValue*)0;
                Array* cargs = new Array();
                cargs.add((Object*)pv);
                return emitMethodCall(runtimeHelper(String.withCString("_xtc_count")),
                                      (IRValue*)0, cargs,
                                      String.withCString("u16"), true);
                }
            }
        if (k == (u16)nkMember)
            {
            // A PROPERTY read is a method call. The analyser chose the getter
            // — the ivar and the accessor can share a name, and which one a
            // mention means is its decision, not this one's.
            if (n.getter() != 0)
                return lowerPropertyGet(n);
            String* ft = memberFieldType(n);
            if (ft == 0)
                {
                giveUp(String.withCString("member of a non-struct"));
                return (IRValue*)0;
                }
            // A struct RVALUE — `makePoint().x` — has no lvalue to take the
            // address of. The call already handed back the whole aggregate,
            // so the field comes out of the VALUE.
            Node* mb = n.kid((u32)0);
            if ((mb.kind() == (u16)nkCall || mb.kind() == (u16)nkMethodCall) && mb.ty() != 0 && !mb.ty().hasSuffix(String.withCString("*")))
                {
                Node* mst = structDeclFor(pointeeOf(mb.ty()));
                if (mst != 0)
                    {
                    IRValue* av = lowerExpr(mb);
                    if (_failed)
                        return (IRValue*)0;
                    Array* xops = new Array();
                    xops.add((Object*)IROperand.useVal(av));
                    xops.add((Object*)IROperand.immI(fieldIndexOf(mst, n.name()),
                                                     String.withCString("U16")));
                    return emit(String.withCString("AggExtract"), irType(ft), xops);
                    }
                }
            // An ARRAY field DECAYS to a pointer-to-element (C array decay),
            // exactly as a bare array does — it must NOT Load the whole
            // aggregate. `len(s.name)` passes &s.name[0]; loading the array as
            // a value and handing it to a `u8*` parameter dereferenced the
            // array's own bytes as an address and segfaulted (bug 182). The
            // field's address IS its element 0, so the FieldAddr typed as
            // Ptr(element) is the decayed pointer — matching the reference.
            if (isArrayLike(ft))
                {
                Node* mbase = n.kid((u32)0);
                String* mbt = mbase.ty();
                String* eptr = ptrTo(irType(elementOf(ft)));
                ClassInfo* mci = classFor(pointeeOf(mbt));
                if (mci != 0)
                    {
                    Object* midx = mci.ivarIndex().get((Hashable*)n.name());
                    if (midx != 0)
                        {
                        IRValue* recv = lowerExpr(mbase);
                        if (_failed)
                            return (IRValue*)0;
                        return fieldAddr(recv, ((Number*)midx).asU32(), eptr);
                        }
                    }
                Node* mst = structDeclFor(pointeeOf(mbt));
                if (mst != 0)
                    {
                    i32 midx = fieldIndexOf(mst, n.name());
                    IRValue* mba = (n.hasFlag((u32)NF_ARROW) || Types.isPointer(mbt))
                                       ? lowerExpr(mbase)
                                       : aggregateAddr(mbase);
                    if (_failed)
                        return (IRValue*)0;
                    return fieldAddr(mba, (u32)midx, eptr);
                    }
                }
            IRValue* fa = memberAddr(n);
            if (_failed)
                return (IRValue*)0;
            return loadThrough(fa, ft);
            }
        if (k == (u16)nkUnary)
            {
            if (isName(n.op(), "++") || isName(n.op(), "--"))
                return lowerStep(n, false);
            // `&x` does not READ x — it names where x lives. It has to fire
            // before the operand is lowered or the read emits a spurious Load.
            if (isName(n.op(), "&"))
                return lowerAddrOf(n);
            // A DEREFERENCE is a read of memory, not an arithmetic unary, so
            // it is answered here rather than in lowerUnary.
            if (isName(n.op(), "*"))
                {
                IRValue* addr = lowerExpr(n.kid((u32)0));
                if (_failed)
                    return (IRValue*)0;
                return loadThrough(addr, n.ty());
                }
            return lowerUnary(n);
            }
        if (k == (u16)nkPostfix)
            return lowerStep(n, true);
        if (k == (u16)nkStr)
            return stringAddr(n.name());
        if (k == (u16)nkSubscript)
            {
            IRValue* addr = elementAddr(n);
            if (_failed)
                return (IRValue*)0;
            // An element that IS a class instance — `new Cell[6]` lays six of
            // them out end to end — is reached by its ADDRESS. A reference IS
            // the address, so there is nothing to load: loading would read the
            // first field and treat it as the object.
            if (classFor(stripQual(n.ty())) != 0 && !Types.isPointer(n.ty()))
                return addr;
            return loadThrough(addr, n.ty());
            }

        giveUp(kindName(k, String.withCString("expression")));
        return (IRValue*)0;
        }

    IRValue* globalArrayAddr(Node* n, String* ty)
        {
        Array* ops = new Array();
        ops.add((Object*)IROperand.sym(globalSymName(n.name())));
        return emit(String.withCString("AddrOf"), ptrTo(irType(ty)), ops);
        }

    IRValue* loadGlobal(String* name, String* astTy)
        {
        String* ity = irType(astTy);
        String* pty = String.withCString("Ptr(");
        pty.append(ity);
        pty.appendCString(", unbanked)");
        Array* ops = new Array();
        ops.add((Object*)IROperand.sym(globalSymName(name)));
        IRValue* addr = globalPayloadAddr(name, astTy, ops, pty);
        // A Load takes the address and the current memory token, and hands
        // back both the value and the next token.
        IRInsn* ld = IRInsn.with(String.withCString("Load"));
        IRValue* res = new IRValue(ity);
        IRValue* nextMem = new IRValue(String.withCString("Mem"));
        ld.setRes(res);
        ld.setMemRes(nextMem);
        ld.add(IROperand.useVal(addr));
        ld.add(IROperand.useVal(_mem));
        _blk.add(ld);
        _mem = nextMem;
        return res;
        }

    void storeGlobal(String* name, String* astTy, IRValue* v)
        {
        storeGlobalARC(name, astTy, v, (Node*)0);
        }

    // A strong GLOBAL owns its referent exactly as a strong local does, and
    // the dance is the same: read what is there, retain the newcomer, release
    // the incumbent, then store. Reading first matters — `g = g` must not free
    // the object it is about to keep.
    void storeGlobalARC(String* name, String* astTy, IRValue* v, Node* rhs)
        {
        String* ity = irType(astTy);
        String* pty = String.withCString("Ptr(");
        pty.append(ity);
        pty.appendCString(", unbanked)");
        Array* ops = new Array();
        ops.add((Object*)IROperand.sym(globalSymName(name)));
        IRValue* addr = globalPayloadAddr(name, astTy, ops, pty);
        if (isWeakClassPtr(astTy))
            {
            // A weak global owns nothing, so nothing is released — but the
            // side table has to learn the new referent, and the old entry must
            // come out first.
            storeThrough(addr, v);
            weakOp(String.withCString("WeakUnregister"), addr, (IRValue*)0);
            weakOp(String.withCString("WeakRegister"), addr, v);
            // Balance a +1 RHS the weak slot doesn't own (bug 170, global
            // sibling of 153). Borrowed owns nothing.
            if (rhs != 0 && !rhsIsBorrowed(rhs))
                refOp(String.withCString("Release"), v);
            return;
            }
        // A `^` GLOBAL is auto-zeroing too, and threads onto the chain the
        // same way — off the address the store already formed.
        if (isBoundSig(stripQual(astTy)))
            {
            storeThrough(addr, v);
            if (!isWidenedFn(rhs))
                registerBoundPair(addr, v, astTy);
            return;
            }
        if (isClassPointer(astTy))
            {
            IRValue* old = loadThrough(addr, astTy);
            // A `new` on the right is already +1 and the global adopts it;
            // anything else is a loan and needs a claim of its own.
            if (rhs == 0 || rhsIsBorrowed(rhs))
                {
                if (rhs == 0 || isAnyClassPointer(rhs.ty()))
                    refOp(String.withCString("Retain"), v);
                }
            else
                {
                consumeOwnedTemp(v);
                }
            refOp(String.withCString("Release"), old);
            }
        IRInsn* st = IRInsn.with(String.withCString("Store"));
        IRValue* nextMem = new IRValue(String.withCString("Mem"));
        st.setMemRes(nextMem);
        st.add(IROperand.useVal(addr));
        st.add(IROperand.useVal(v));
        st.add(IROperand.useVal(_mem));
        _blk.add(st);
        _mem = nextMem;
        }

    // The address a read or write of a global uses. For an auto-zeroing one
    // that is the PAYLOAD, past the two hidden link words — the same shape a
    // pinned weak local's slot has, and for the same reason.
    IRValue* globalPayloadAddr(String* name, String* astTy, Array* ops, String* pty)
        {
        if (!isWeakSlot(astTy))
            return emit(String.withCString("AddrOf"), pty, ops);
        // The slot type the SYMBOL was declared with, not a fresh one: every
        // read and write of the global would otherwise register another
        // identical layout and renumber the table.
        IRSymbol* gs = symbolNamed(globalSymName(name));
        String* slotAgg = gs != 0 && gs.dataType() != 0
                              ? gs.dataType()
                              : weakSlotAggOf(astTy);
        IRValue* base = emit(String.withCString("AddrOf"), ptrTo(slotAgg), ops);
        return fieldAddr(base, (u32)2, pty);
        }

    // A fresh slot layout per MENTION, not one per type. They are identical,
    // and caching would be the obvious thing — but the original builds one
    // each time, so the layout table carries a run of them and every layout
    // after depends on the count.
    String* weakSlotAggOf(String* astTy)
        {
        return weakSlotAgg(irType(astTy));
        }

    // The mnemonic for an arithmetic or bitwise operator at a given operand
    // type; division and remainder pick their signed or unsigned form.
    String* arithOp(String* op, String* ty)
        {
        // FLOAT arithmetic is its own opcode set — an FAdd is not an Add with
        // float operands, it is a different instruction to every backend.
        if (Types.isFloating(ty))
            {
            if (isName(op, "+"))
                return String.withCString("FAdd");
            if (isName(op, "-"))
                return String.withCString("FSub");
            if (isName(op, "*"))
                return String.withCString("FMul");
            if (isName(op, "/"))
                return String.withCString("FDiv");
            return (String*)0;
            }
        bool sgn = Types.isSigned(ty);
        if (isName(op, "+"))
            return String.withCString("Add");
        if (isName(op, "-"))
            return String.withCString("Sub");
        if (isName(op, "*"))
            return String.withCString("Mul");
        if (isName(op, "/"))
            return String.withCString(sgn ? "SDiv" : "UDiv");
        if (isName(op, "%"))
            return String.withCString(sgn ? "SRem" : "URem");
        if (isName(op, "&"))
            return String.withCString("And");
        if (isName(op, "|"))
            return String.withCString("Or");
        if (isName(op, "^"))
            return String.withCString("Xor");
        if (isName(op, "<<"))
            return String.withCString("Shl");
        if (isName(op, ">>"))
            return String.withCString(sgn ? "AShr" : "LShr");
        return (String*)0;
        }

    // The comparison predicate, which is where signedness shows up. A FLOAT
    // comparison is a different instruction with a different predicate set:
    // the `O` is ORDERED — the answer is false when either side is a NaN,
    // which is a question integers never have to ask.
    String* cmpPred(String* op, String* ty)
        {
        if (Types.isFloating(ty))
            {
            if (isName(op, "=="))
                return String.withCString("OEQ");
            if (isName(op, "!="))
                return String.withCString("ONE");
            if (isName(op, "<"))
                return String.withCString("OLT");
            if (isName(op, ">"))
                return String.withCString("OGT");
            if (isName(op, "<="))
                return String.withCString("OLE");
            if (isName(op, ">="))
                return String.withCString("OGE");
            return (String*)0;
            }
        bool sgn = Types.isSigned(ty);
        if (isName(op, "=="))
            return String.withCString("EQ");
        if (isName(op, "!="))
            return String.withCString("NE");
        if (isName(op, "<"))
            return String.withCString(sgn ? "SLT" : "ULT");
        if (isName(op, ">"))
            return String.withCString(sgn ? "SGT" : "UGT");
        if (isName(op, "<="))
            return String.withCString(sgn ? "SLE" : "ULE");
        if (isName(op, ">="))
            return String.withCString(sgn ? "SGE" : "UGE");
        return (String*)0;
        }

    IRValue* emitRotate(String* op, IRValue* l, IRValue* r, String* ty)
        {
        String* T = irType(ty);
        String* u8T = String.withCString("U8");
        u32 w = astWidth(ty) * (u32)8;
        Array* mo = new Array();
        mo.add((Object*)IROperand.immI((i32)(w - (u32)1), u8T));
        IRValue* wMask = emit(String.withCString("Const"), u8T, mo);
        Array* wo = new Array();
        wo.add((Object*)IROperand.immI((i32)w, u8T));
        IRValue* wConst = emit(String.withCString("Const"), u8T, wo);
        IRValue* rn = emitBin(String.withCString("And"), u8T, r, wMask);
        IRValue* wMinus = emitBin(String.withCString("Sub"), u8T, wConst, rn);
        IRValue* rev = emitBin(String.withCString("And"), u8T, wMinus, wMask);
        bool rol = isName(op, "<:");
        IRValue* p1 = emitBin(String.withCString(rol ? "Shl" : "LShr"), T, l, rn);
        IRValue* p2 = emitBin(String.withCString(rol ? "LShr" : "Shl"), T, l, rev);
        return emitBin(String.withCString("Or"), T, p1, p2);
        }

    IRValue* emitBin(String* mn, String* ir, IRValue* a, IRValue* b)
        {
        Array* ops = new Array();
        ops.add((Object*)IROperand.useVal(a));
        ops.add((Object*)IROperand.useVal(b));
        return emit(mn, ir, ops);
        }

    IRValue* lowerIdentifier(Node* n)
        {

        // A PINNED local is a place, so reading it is a Load — and an
        // ARRAY one decays to the address of its first element instead,
        // because a bare `a` means `&a[0]` and never the contents.
        IRPinned* p = pinOf(n.name());
        if (p != 0)
            {
            // A stack INSTANCE evaluates to its address, typed as the
            // class's self-pointer — which is what lets member access and
            // method dispatch reuse the class-pointer paths unchanged.
            Object* vco = _valueClass.get((Hashable*)n.name());
            if (vco != 0)
                {
                Array* vops = new Array();
                vops.add((Object*)IROperand.useVal(p.val()));
                return emit(String.withCString("AddrOf"), ((ClassInfo*)vco).selfPtr(), vops);
                }
            if (_arrayElem.get((Hashable*)n.name()) != 0)
                return arrayDecayAddr(n.name(), p);
            return loadThrough(pinAddrNamed(p, n.name()), (String*)_pinAst.get((Hashable*)n.name()));
            }
        Object* v = _locals.get((Hashable*)n.name());
        if (v != 0)
            return (IRValue*)v;
        // A STATIC ivar is a module global, reached by name rather than
        // through the receiver — there is one of it however many
        // instances there are.
        if (_curClass != 0)
            {
            String* sg = staticIvarFor(_curClass, n.name());
            if (sg != 0)
                return loadGlobal(sg, staticIvarTypeFor(_curClass, n.name()));
            }
        // An IVAR named bare inside a method: `_n` is `self._n`.
        if (ivarIndexOf(n.name()) >= (i32)0)
            {
            String* ity = (String*)_curClass.ivarType().get((Hashable*)n.name());
            return loadThrough(ivarAddr(n.name()), ity);
            }
        Object* ec = _enumConsts.get((Hashable*)n.name());
        if (ec != 0)
            return constOf((i64)((Number*)ec).asU32(), n.ty());
        Object* g = _globals.get((Hashable*)n.name());
        // A global ARRAY named bare DECAYS: `dlist8` is its address, not
        // its contents — there is no register wide enough to hold ten
        // bytes, and every use of the name means the address anyway.
        if (g != 0 && isArrayLike((String*)g))
            return globalArrayAddr(n, (String*)g);
        if (g != 0)
            return loadGlobal(n.name(), (String*)g);
        String* w = String.withCString("unbound identifier ");
        w.append(n.name());
        giveUp(w);
        return (IRValue*)0;
        }

    IRValue* lowerSizeof(Node* n)
        {
        // The width comes from the AST TYPE, never from an IR layout: a type
        // only ever measured is a type the module never lays out, and building
        // its layout here would leave a spare one behind and renumber every
        // layout after it.
        String* what = isName(n.name(), "-") ? n.kid((u32)0).ty() : n.name();
        u32 w = sizeOf(what);
        Array* zops = new Array();
        zops.add((Object*)IROperand.immI((i32)w, String.withCString("U16")));
        return emit(String.withCString("Const"), String.withCString("U16"), zops);
        }

    IRValue* lowerBinary(Node* n)
        {
        String* op = n.op();
        String* ty = n.ty(); // the analyser's widened operand type
        // …except for a COMPARISON, whose node type is its RESULT — bool — and
        // says nothing about the width the two sides must meet at. Take that
        // from the operands. This is not an optimisation: `ty` is what both
        // operands are coerced to below AND what picks the signed-vs-unsigned
        // predicate, so reading bool here would compare two i64s as one-byte
        // unsigned. Mirrors the reference, which has always computed the
        // comparison operand type from left/right rather than from the node.
        if (isName(op, "==") || isName(op, "!=") || isName(op, "<") || isName(op, ">") || isName(op, "<=") || isName(op, ">="))
            ty = Types.widen(n.kid((u32)0).ty(), n.kid((u32)1).ty());
        if (isName(op, "&&") || isName(op, "||"))
            return lowerShortCircuit(n);
        // POINTER ± integer is an ElementAddr, not an Add: the IR says which
        // element, and the backend knows how wide one is. Subtraction is the
        // same instruction with a NEGATED index — signed, because `p - 2` is
        // an offset of -2 and a U16 would make that +65534 and walk off into
        // a wild address.
        bool lptr = Types.isPointer(n.kid((u32)0).ty());
        bool rptr = Types.isPointer(n.kid((u32)1).ty());
        // `p - q` — pointer DIFFERENCE, in ELEMENTS as C has it. This fell
        // through the XOR guard below into generic arithmetic and emitted a raw
        // BYTE `Sub` typed as a POINTER, so `q - p` on a double* answered 40
        // where C says 5 — while the reference refused the construct outright.
        // One implementation was wrong, the other absent (bug 206).
        //
        // PtrToInt both sides, Sub, divide by the element size; the divide is
        // skipped for a 1-byte element, where it is an identity. Sema types the
        // result i32, so the whole computation runs at i32 and needs no fitting
        // afterwards. SIGNED divide: `p - q` is as legal as `q - p`, and one of
        // them is negative.
        if (isName(op, "-") && lptr && rptr)
            {
            IRValue* lv = lowerExpr(n.kid((u32)0));
            if (_failed)
                return (IRValue*)0;
            IRValue* rv = lowerExpr(n.kid((u32)1));
            if (_failed)
                return (IRValue*)0;
            // The ptrdiff type, and it must match the one SEMA chose —
            // pointer-width, not a fixed I32. Hardcoding I32 truncated the
            // ADDRESS: on a 64-bit target the PtrToInt narrowed the pointer to
            // 32 bits before the subtract, so two pointers straddling a 4GB
            // boundary differed by a wrong amount, not merely a narrow one.
            // Arithmetic width and result width are one question.
            String* dt = _ptrW >= (u32)8   ? String.withCString("I64")
                         : _ptrW >= (u32)4 ? String.withCString("I32")
                                           : String.withCString("I16");
            String* dtAst = _ptrW >= (u32)8   ? String.withCString("i64")
                            : _ptrW >= (u32)4 ? String.withCString("i32")
                                              : String.withCString("i16");
            Array* lo = new Array();
            lo.add((Object*)IROperand.useVal(lv));
            IRValue* li = emit(String.withCString("PtrToInt"), dt, lo);
            Array* ro = new Array();
            ro.add((Object*)IROperand.useVal(rv));
            IRValue* ri = emit(String.withCString("PtrToInt"), dt, ro);
            Array* so = new Array();
            so.add((Object*)IROperand.useVal(li));
            so.add((Object*)IROperand.useVal(ri));
            IRValue* diff = emit(String.withCString("Sub"), dt, so);
            // The element size. irWidth answers 0 for a pointer pointee, where
            // the element is an address and the width is the target's own —
            // which is what the reference's pointee.byteWidth returns there.
            String* pe = pointeeOf(n.kid((u32)0).ty());
            u32 esz = irWidth(irType(pe));
            if (esz == (u32)0)
                esz = Types.isPointer(pe) ? _ptrW : (u32)1;
            if (esz <= (u32)1)
                return diff;
            IRValue* k = constOf((i64)esz, dtAst);
            Array* dops = new Array();
            dops.add((Object*)IROperand.useVal(diff));
            dops.add((Object*)IROperand.useVal(k));
            return emit(String.withCString("SDiv"), dt, dops);
            }
        if ((isName(op, "+") || isName(op, "-")) && (lptr != rptr))
            {
            Node* ptrSide = lptr ? n.kid((u32)0) : n.kid((u32)1);
            Node* idxSide = lptr ? n.kid((u32)1) : n.kid((u32)0);
            IRValue* base = lowerExpr(ptrSide);
            if (_failed)
                return (IRValue*)0;
            IRValue* idx = lowerExpr(idxSide);
            if (_failed)
                return (IRValue*)0;
            if (idx.ty().equals(String.withCString("U8")) || idx.ty().equals(String.withCString("I8")))
                {
                Array* zops = new Array();
                zops.add((Object*)IROperand.useVal(idx));
                idx = emit(String.withCString(idx.ty().equals(String.withCString("I8")) ? "SExt" : "ZExt"),
                           String.withCString("U16"), zops);
                }
            // The Neg must be typed at the index's OWN width, not a fixed
            // I16. Hard-coding I16 emitted `%n:I16 = Neg %idx:I64` for
            // `p - (i64)n`: the arm64 in-house assembler refused the result
            // (`neg w10, x27` — w and x cannot be mixed) and the wasm writer
            // asks the Neg RESULT's type to decide whether to `i32.wrap_i64`,
            // so it skipped the wrap and handed an i64 to i32.sub. The `+`
            // path has no Neg, which is why only `-` broke (bug 39).
            if (isName(op, "-"))
                {
                Array* nops = new Array();
                nops.add((Object*)IROperand.useVal(idx));
                u32 iw = irWidth(idx.ty());
                String* nty = String.withCString("I16");
                if (iw >= (u32)8)
                    nty = String.withCString("I64");
                else if (iw >= (u32)4)
                    nty = String.withCString("I32");
                idx = emit(String.withCString("Neg"), nty, nops);
                }
            Array* ops = new Array();
            ops.add((Object*)IROperand.useVal(base));
            ops.add((Object*)IROperand.useVal(idx));
            return emit(String.withCString("ElementAddr"), base.ty(), ops);
            }
        IRValue* l = lowerExpr(n.kid((u32)0));
        IRValue* r = lowerExpr(n.kid((u32)1));
        if (_failed)
            return (IRValue*)0;
        // A `^` compared with == / != — see boundCompare. Checked BEFORE the
        // operands are coerced to the analyser's widened type: that type for
        // `h == 0` is the literal's, so a coerce would have already narrowed
        // the pair to a byte and there would be nothing left to compare.
        if ((isName(op, "==") || isName(op, "!=")) && !_failed && (isBoundSig(stripQual(n.kid((u32)0).ty())) || isBoundSig(stripQual(n.kid((u32)1).ty()))))
            {
            String* bty = isBoundSig(stripQual(n.kid((u32)0).ty()))
                              ? stripQual(n.kid((u32)0).ty())
                              : stripQual(n.kid((u32)1).ty());
            // Coerce each side TO the pair type rather than assuming a non-pair
            // operand is the literal 0: a function pointer (`f == &dbl`) must be
            // WIDENED to (code, trampoline), not nulled, or the compare reads
            // unequal against a callback that holds exactly that (c2xc 04). The
            // general coerce routes a fn pointer through widenToBound, an integer
            // 0 to the null pair, and an existing pair straight through — which
            // is what the reference does for these operands.
            IRValue* lp = coerce(l, n.kid((u32)0).ty(), bty);
            IRValue* rp = coerce(r, n.kid((u32)1).ty(), bty);
            return boundCompare(op, lp, rp);
            }
        // A SHIFT is not a two-term operation. It happens at the LEFT
        // operand's type, and its right operand is a COUNT — one byte, never
        // widened to match the left.
        //
        // Which type exactly takes care: the analyser's type for the node is
        // widen(left, right), so a wide COUNT can make it wider than the left
        // and a narrow assignment context can make it narrower. Take the WIDER
        // of the two. Extending the left is required so an arithmetic shift
        // sign-extends; truncating it below its own width first is not — it
        // would turn `(1000 >> 8)` into `(232 >> 8)` and yield zero. The
        // narrowing happens AFTER the shift, in the result type.
        bool isRot = isName(op, "<:") || isName(op, ":>");
        bool isShift = isName(op, "<<") || isName(op, ">>") || isRot;
        if (isShift)
            {
            String* lt = n.kid((u32)0).ty();
            u32 lw = astWidth(lt);
            if (lw == (u32)0)
                lw = (u32)1;
            u32 rw = astWidth(ty);
            if (rw == (u32)0)
                rw = lw;
            u32 w = lw > rw ? lw : rw;
            bool lsgn = Types.isSigned(lt);
            // The ceiling is 8, not 4: capped at 4 this emitted a Trunc to
            // U32 BEFORE a 64-bit shift. It stays driven by the OPERAND width,
            // so a u8 shift is still u8 and a narrow target does not start
            // doing 64-bit arithmetic because this exists.
            ty = w >= (u32)8 ? String.withCString(lsgn ? "i64" : "u64")
                             : (w >= (u32)4 ? String.withCString(lsgn ? "i32" : "u32")
                                            : (w == (u32)2 ? String.withCString(lsgn ? "i16" : "u16")
                                                           : String.withCString(lsgn ? "i8" : "u8")));
            l = coerce(l, lt, ty);
            r = coerce(r, n.kid((u32)1).ty(), String.withCString("u8"));
            }
        else
            {
            l = coerce(l, n.kid((u32)0).ty(), ty);
            r = coerce(r, n.kid((u32)1).ty(), ty);
            }
        // A ROTATE is built from two shifts and an Or: no backend has a
        // rotate instruction to lower to, and one that emitted a call to a
        // runtime routine that was never written is worse than none. Both
        // counts are masked with (w-1), which is what makes a count of 0 and a
        // count of w correct without ever shifting BY the width — undefined
        // on every backend — since (w-0)&(w-1) is 0 for a power-of-two w.
        if (isRot)
            return emitRotate(op, l, r, ty);

        Array* ops = new Array();
        ops.add((Object*)IROperand.useVal(l));
        ops.add((Object*)IROperand.useVal(r));

        String* pred = cmpPred(op, ty);
        // A `^` is a PAIR, and comparing one compares BOTH words — the receiver
        // and the code. A single-word compare is not a cheaper version of that,
        // it is a different question: after a receiver dies the auto-zero clears
        // recv and leaves code, so one word says "equal to zero" and two say
        // "not equal". The back ends disagreed (arm64 one word, xt6502 two),
        // which was bug 031, so the comparison is expanded HERE and every
        // backend gets the same answer:
        //   (a.recv == b.recv) && (a.code == b.code)   for ==
        //   (a.recv != b.recv) || (a.code != b.code)   for !=
        // `if (h)` stays the LIVENESS test, reading the receiver word alone.
        if (pred != 0)
            {
            IRInsn* i = IRInsn.with(String.withCString(Types.isFloating(ty) ? "FCmp" : "ICmp"));
            i.setRes(new IRValue(String.withCString("Bool")));
            i.setPred(pred);
            i.add((IROperand*)ops.get((u32)0));
            i.add((IROperand*)ops.get((u32)1));
            _blk.add(i);
            return i.res();
            }
        String* mn = arithOp(op, ty);
        if (mn == 0)
            {
            String* w = String.withCString("binary op ");
            w.append(op);
            giveUp(w);
            return (IRValue*)0;
            }
        // The RESULT is the node's own type. For everything but a shift that
        // IS the operand type; a shift operates at the wider of its operand
        // and its context and narrows on the way out, so `(1000 >> 8) & $FF`
        // shifts a u16 and yields a u8.
        return emit(mn, irType(n.ty()), ops);
        }

    // A `^` is a PAIR, and comparing one compares BOTH words — the receiver and
    // the code. A single-word compare is not a cheaper version of that, it is a
    // different question: after a receiver dies the auto-zero clears recv and
    // leaves code, so one word says "equal to zero" and two say "not equal".
    // The back ends disagreed (arm64 one word, xt6502 two) — bug 031 — so the
    // comparison is expanded here and every backend gets the same answer:
    //   (a.recv == b.recv) && (a.code == b.code)   for ==
    //   (a.recv != b.recv) || (a.code != b.code)   for !=
    // `if (h)` stays the LIVENESS test, reading the receiver word alone.
    // The other side of a `^` comparison is usually the literal 0, which
    // arrives as a plain integer. Compare like with like: an operand that is
    // not already the pair becomes the NULL pair.
    IRValue* asBoundPair(IRValue* v, String* agg)
        {
        if (v != (IRValue*)0 && v.ty() != (String*)0 && v.ty().equals(agg))
            return v;
        Array* zo = new Array();
        zo.add((Object*)IROperand.immI((i32)0, ptrTo(String.withCString("Void"))));
        IRValue* z = emit(String.withCString("Const"), ptrTo(String.withCString("Void")), zo);
        Array* bo = new Array();
        bo.add((Object*)IROperand.useVal(z));
        bo.add((Object*)IROperand.useVal(z));
        return emit(String.withCString("AggBuild"), agg, bo);
        }

    IRValue* boundCompare(String* op, IRValue* l, IRValue* r)
        {
        bool wantEq = isName(op, "==");
        String* pv = ptrTo(String.withCString("Void"));
        Array* parts = new Array();
        for (u32 w = (u32)0; w < (u32)2; w = w + (u32)1)
            {
            Array* le = new Array();
            le.add((Object*)IROperand.useVal(l));
            le.add((Object*)IROperand.immU(w, String.withCString("U16")));
            IRValue* lw = emit(String.withCString("AggExtract"), pv, le);
            Array* re = new Array();
            re.add((Object*)IROperand.useVal(r));
            re.add((Object*)IROperand.immU(w, String.withCString("U16")));
            IRValue* rw = emit(String.withCString("AggExtract"), pv, re);
            IRInsn* ci = IRInsn.with(String.withCString("ICmp"));
            ci.setRes(new IRValue(String.withCString("Bool")));
            ci.setPred(String.withCString(wantEq ? "EQ" : "NE"));
            ci.add(IROperand.useVal(lw));
            ci.add(IROperand.useVal(rw));
            _blk.add(ci);
            parts.add((Object*)ci.res());
            }
        Array* jo = new Array();
        jo.add((Object*)IROperand.useVal((IRValue*)parts.get((u32)0)));
        jo.add((Object*)IROperand.useVal((IRValue*)parts.get((u32)1)));
        return emit(String.withCString(wantEq ? "And" : "Or"),
                    String.withCString("Bool"), jo);
        }

    IRValue* lowerStoreThrough(Node* n, Node* lhs)
        {
        IRValue* addr = (lhs.kind() == (u16)nkSubscript)
                            ? elementAddr(lhs)
                            : lowerExpr(lhs.kid((u32)0));
        if (_failed)
            return (IRValue*)0;
        // An element of a strong ARRAY owns what it holds. The old
        // occupant is read BEFORE the right-hand side — a maker may write
        // its result straight into the slot — and released after the
        // store, so `arr[i] = arr[i]` cannot free what it is keeping.
        bool strongElem = lhs.kind() == (u16)nkSubscript && lhs.kid((u32)0).kind() == (u16)nkIdent && _strongArray.get((Hashable*)lhs.kid((u32)0).name()) != 0;
        // A GLOBAL array of class pointers -- `Tag* g[N];` in BSS -- owns its
        // elements too. The test above asks whether the base is a tracked
        // strong array LOCAL, and a global is not one, so this used to fall
        // through to a plain store: `g[i] = t` kept the pointer without
        // retaining, t was freed at scope exit, and the slot dangled. The
        // scalar global never had the hole because it gates on the TYPE.
        //
        // Only a real fixed-size array qualifies. A global POINTER (a heap
        // `new T[N]`, or a borrowed T**) keeps the plain store, as the local
        // gate intends -- those elements are owned elsewhere.
        if (!strongElem && lhs.kind() == (u16)nkSubscript && lhs.kid((u32)0).kind() == (u16)nkIdent)
            {
            String* bn = lhs.kid((u32)0).name();
            Object* gt = _globals.get((Hashable*)bn);
            if (gt != (Object*)0 && _locals.get((Hashable*)bn) == (Object*)0 && isArrayLike((String*)gt) && isClassPointer(lhs.ty()))
                strongElem = true;
            }
        IRValue* oldElem = strongElem ? loadThrough(addr, lhs.ty()) : (IRValue*)0;
        // An element of a struct ARRAY taking an OWNED struct: its prior
        // occupants come out and the slots are nulled BEFORE the value
        // arrives, for the same reason a whole strong struct local does it
        // — the callee may write its result straight into the element.
        structElemAdoptARC(lhs, addr, n.kid((u32)1));
        IRValue* rv = lowerExpr(n.kid((u32)1));
        if (_failed)
            return (IRValue*)0;
        rv = coerce(rv, n.kid((u32)1).ty(), lhs.ty());
        if (strongElem)
            {
            if (rhsIsBorrowed(n.kid((u32)1)) && isAnyClassPointer(n.kid((u32)1).ty()))
                refOp(String.withCString("Retain"), rv);
            else
                consumeOwnedTemp(rv);
            }
        // `@p = v` into a strong slot is the same contract as a store to a
        // strong local or ivar: Retain the new, Release what was there.
        // Without it every `T@@` out-parameter dangled — the callee's owned
        // local went out on return and the caller held a freed block, which
        // still READ correctly until something reused it (bug 034). The old
        // value comes out AFTER the retain, so `@p = @p` cannot free what it
        // is keeping. Releasing it at all is safe because class-pointer
        // slots start null.
        if (lhs.kind() == (u16)nkUnary && isClassPointer(lhs.ty()))
            {
            IRValue* oldSlot = loadThrough(addr, lhs.ty());
            if (rhsIsBorrowed(n.kid((u32)1)) && isAnyClassPointer(n.kid((u32)1).ty()))
                refOp(String.withCString("Retain"), rv);
            else
                consumeOwnedTemp(rv);
            refOp(String.withCString("Release"), oldSlot);
            }
        storeThrough(addr, rv);
        if (oldElem != 0)
            refOp(String.withCString("Release"), oldElem);
        // An AUTO-ZEROING element is threaded onto its referent's chain
        // exactly as a local or an ivar is — each element independently,
        // because each holds its own reference.
        if (lhs.kind() == (u16)nkSubscript && isWeakSlot(lhs.ty()))
            {
            // Off the address the store already formed — the element was
            // reached once and there is nothing to reach again.
            IRValue* slotA = addr;
            if (isBoundSig(stripQual(lhs.ty())))
                {
                if (!isWidenedFn(n.kid((u32)1)))
                    registerBoundPair(slotA, rv, lhs.ty());
                }
            else
                {
                weakOp(String.withCString("WeakUnregister"), slotA, (IRValue*)0);
                weakOp(String.withCString("WeakRegister"), slotA, rv);
                // A weak slot owns nothing: a +1 RHS the store adopted must
                // be released after the register, or it leaks (bug 170, the
                // element sibling of 153). Borrowed owns nothing.
                if (!rhsIsBorrowed(n.kid((u32)1)))
                    refOp(String.withCString("Release"), rv);
                }
            }
        return rv;
        }

    IRValue* lowerAssign(Node* n)
        {
        Node* lhs = n.kid((u32)0);
        // A PROPERTY write is a method call, and the value it stores is the
        // one handed to the setter — not whatever the setter chose to keep.
        if (n.setter() != 0 && lhs.kind() == (u16)nkMember)
            return lowerPropertySet(n, lhs);
        // `a = { … }` on an AGGREGATE is a field-by-field write, not a value
        // assignment: there is no aggregate rvalue to build and store, and the
        // list is a shape rather than an expression.
        if (isName(n.op(), "=") && n.kid((u32)1).kind() == (u16)nkBlock && lhs.ty() != 0 && (isArrayLike(lhs.ty()) || structDeclFor(lhs.ty()) != 0))
            {
            IRValue* dst = aggregateAddr(lhs);
            if (_failed)
                return (IRValue*)0;
            lowerAggregateByteList(dst, lhs.ty(), n.kid((u32)1));
            return (IRValue*)0;
            }
        // A store THROUGH something — `@p = v`, `a[i] = v` — is the same
        // shape as a store to a global once the address is in hand.
        if (isName(n.op(), "=") && (lhs.kind() == (u16)nkSubscript || (lhs.kind() == (u16)nkUnary && isName(lhs.op(), "*"))))
            return lowerStoreThrough(n, lhs);
        // `obj.field = v` — the field's ADDRESS is formed first, then the
        // value, then the store. (A pinned identifier goes the other way
        // round; both orders are the original's, and both are printed.)
        if (isName(n.op(), "=") && lhs.kind() == (u16)nkMember)
            {
            String* ft = memberFieldType(lhs);
            if (ft == 0)
                {
                String* gg = String.withCString("member of a non-struct C ");
                gg.append(lhs.kid((u32)0).ty());
                gg.appendCString(" .");
                gg.append(lhs.name());
                giveUp(gg);
                return (IRValue*)0;
                }
            Node* base = lhs.kid((u32)0);
            String* bt = base.ty();
            ClassInfo* ci = classFor(pointeeOf(bt));
            i32 fidx = (i32)0;
            IRValue* baseAddr = (IRValue*)0;
            if (ci != 0)
                {
                // A class reference IS the address; the ivar's index comes
                // from the class map, which already carries inherited slots.
                fidx = (i32)((Number*)ci.ivarIndex().get((Hashable*)lhs.name())).asU32();
                baseAddr = lowerExpr(base);
                }
            else
                {
                fidx = fieldIndexOf(structDeclFor(pointeeOf(bt)), lhs.name());
                baseAddr = (lhs.hasFlag((u32)NF_ARROW) || Types.isPointer(bt))
                               ? lowerExpr(base)
                               : aggregateAddr(base);
                }
            if (_failed)
                return (IRValue*)0;
            IRValue* mv = lowerExpr(n.kid((u32)1));
            if (_failed)
                return (IRValue*)0;
            mv = coerce(mv, n.kid((u32)1).ty(), ft);
            IRValue* fa = fieldAddr(baseAddr, (u32)fidx, ptrTo(irType(ft)));
            // A struct FIELD does the strong-slot dance only when the struct it
            // belongs to is a tracked local — one whose fields were zeroed on
            // the way in and are released on the way out. Anywhere else (a
            // parameter's struct, a struct reached through an ivar) there is
            // nothing that owns the old value, and a release-of-old would free
            // something this code never took a claim on.
            if (ci != 0 || structFieldBaseIsTracked(base))
                storeStrongSlot(fa, mv, ft, n.kid((u32)1));
            else
                storeThrough(fa, mv);
            // A weak STRUCT FIELD is an auto-zeroing slot like any other, so
            // long as the struct it belongs to is one the teardown tracks.
            if ((ci != 0 || structFieldBaseIsTracked(base)) && isWeakClassPtr(ft))
                {
                weakOp(String.withCString("WeakUnregister"), fa, (IRValue*)0);
                weakOp(String.withCString("WeakRegister"), fa, mv);
                // Balance a +1 RHS the weak slot doesn't own (bug 170, the ivar
                // sibling of 153). Borrowed owns nothing.
                if (!rhsIsBorrowed(n.kid((u32)1)))
                    refOp(String.withCString("Release"), mv);
                }
            // The tracked-local gate is DROPPED for a `^`: a bound method in
            // any struct lvalue must be linked, or `if (h.action)` stays true
            // after its receiver has died.
            if (isBoundSig(stripQual(ft)) && !isWidenedFn(n.kid((u32)1)))
                registerBoundPair(fa, mv, ft);
            return mv;
            }
        // `s.n += k` / `p->m += k` — compound-assign on a struct/class FIELD.
        // The reference rewrites `member op= rhs` to `member = member op rhs`:
        // it forms the STORE base address first, then reads the member, then
        // the op, then stores. Mirrored here so the port stops rejecting a
        // member LHS with "assignment target" (c2xc bug 35). Identifier
        // compound-assign is handled below.
        if (!isName(n.op(), "=") && lhs.kind() == (u16)nkMember)
            {
            String* mft = memberFieldType(lhs);
            if (mft == 0)
                {
                giveUpAt(String.withCString("assignment target"), n);
                return (IRValue*)0;
                }
            String* mbop = n.op().substringBytes((u32)0, n.op().byteLength() - (u32)1);
            Node* mbase = lhs.kid((u32)0);
            String* mbt = mbase.ty();
            ClassInfo* mci = classFor(pointeeOf(mbt));
            // (1) STORE base address first — matches the reference's ordering.
            IRValue* sbase = (IRValue*)0;
            u32 mfidx = (u32)0;
            if (mci != 0)
                {
                mfidx = ((Number*)mci.ivarIndex().get((Hashable*)lhs.name())).asU32();
                sbase = lowerExpr(mbase);
                }
            else
                {
                mfidx = (u32)fieldIndexOf(structDeclFor(pointeeOf(mbt)), lhs.name());
                sbase = (lhs.hasFlag((u32)NF_ARROW) || Types.isPointer(mbt))
                            ? lowerExpr(mbase)
                            : aggregateAddr(mbase);
                }
            if (_failed)
                return (IRValue*)0;
            // (2) read the current member value (its own base addr + Load).
            IRValue* cold = lowerExpr(lhs);
            if (_failed)
                return (IRValue*)0;
            // (3) the right-hand side, coerced (shift keeps its own width).
            IRValue* crhs = lowerExpr(n.kid((u32)1));
            if (_failed)
                return (IRValue*)0;
            bool cshift = isName(mbop, "<<") || isName(mbop, ">>");
            if (!cshift)
                crhs = coerce(crhs, n.kid((u32)1).ty(), mft);
            String* cmn = arithOp(mbop, mft);
            if (cmn == 0)
                {
                String* w = String.withCString("compound op ");
                w.append(mbop);
                giveUpAt(w, n);
                return (IRValue*)0;
                }
            Array* cops = new Array();
            cops.add((Object*)IROperand.useVal(cold));
            cops.add((Object*)IROperand.useVal(crhs));
            IRValue* cres = emit(cmn, irType(mft), cops);
            // (4) store to the pre-formed base's field.
            IRValue* cfa = fieldAddr(sbase, mfidx, ptrTo(irType(mft)));
            storeThrough(cfa, cres);
            return cres;
            }
        if (lhs.kind() != (u16)nkIdent)
            {
            giveUpAt(String.withCString("assignment target"), n); // located (bug 35)
            return (IRValue*)0;
            }
        // `x op= y` computes at the LEFT side's type — not at the promoted
        // width a plain `x op y` would use, because the result has to land
        // back in x either way. The LEFT side is read FIRST: the original
        // desugars to `x = x op y`, and a global's Load has to land before
        // anything the right side does.
        if (!isName(n.op(), "="))
            {
            String* bop = n.op().substringBytes((u32)0, n.op().byteLength() - (u32)1);
            IRPinned* cpin = pinOf(lhs.name());
            Object* cty = cpin != 0 ? _pinAst.get((Hashable*)lhs.name())
                                    : _localTypes.get((Hashable*)lhs.name());
            if (cty == 0)
                cty = _globals.get((Hashable*)lhs.name());
            if (cty == 0 && _curClass != 0)
                {
                String* sg = staticIvarFor(_curClass, lhs.name());
                if (sg != 0)
                    {
                    _globals.set((Hashable*)sg,
                                 (Object*)staticIvarTypeFor(_curClass, lhs.name()));
                    lhs.setName(sg);
                    cty = _globals.get((Hashable*)sg);
                    }
                }
            // located (bug 35)
            if (cty == 0)
                {
                giveUpAt(String.withCString("compound assign target"), n);
                return (IRValue*)0;
                }
            String* ty = (String*)cty;
            IRValue* cur = (IRValue*)0;
            Object* lv = _locals.get((Hashable*)lhs.name());
            if (cpin != 0)
                cur = loadThrough(pinAddr(cpin), ty);
            else if (lv != 0)
                cur = (IRValue*)lv;
            else
                cur = loadGlobal(lhs.name(), ty);
            IRValue* v = lowerExpr(n.kid((u32)1));
            if (_failed)
                return (IRValue*)0;
            bool isShift = isName(bop, "<<") || isName(bop, ">>");
            if (!isShift)
                v = coerce(v, n.kid((u32)1).ty(), ty);
            String* mn = arithOp(bop, ty);
            if (mn == 0)
                {
                String* w = String.withCString("compound op ");
                w.append(bop);
                giveUp(w);
                return (IRValue*)0;
                }
            Array* ops = new Array();
            ops.add((Object*)IROperand.useVal(cur));
            ops.add((Object*)IROperand.useVal(v));
            IRValue* res = emit(mn, irType(ty), ops);
            if (cpin != 0)
                storeThrough(pinAddr(cpin), res);
            else if (lv != 0)
                _locals.set((Hashable*)lhs.name(), (Object*)res);
            else
                storeGlobal(lhs.name(), ty, res);
            return res;
            }
        // A strong STRUCT taking an OWNED value — a maker's result, already
        // +1 — is classified BEFORE the right-hand side is evaluated. The
        // callee may write its result straight into `dst`, so a
        // release-of-old emitted afterwards would free the NEW value and
        // leak the old. Its prior occupants come out and the slots are
        // nulled, and the store then hands it the +1 fields.
        // `b = recv.m()` into a value-class SLOT is a copy INTO the bytes the
        // slot already is, not a rebinding of it — the same field-by-field
        // copy a decl-init does. Storing the returned pointer here would put
        // an address where the ivars live.
        if (valueClassAssign(lhs.name(), n.kid((u32)1)))
            return (IRValue*)0;
        if (_failed)
            return (IRValue*)0;
        structAdoptARC(lhs, n.kid((u32)1));
        IRValue* v = lowerExpr(n.kid((u32)1));
        if (_failed)
            return (IRValue*)0;
        // An IVAR is memory, so its write is a Store — the name has no SSA
        // binding to rebind.
        if (_curClass != 0 && staticIvarFor(_curClass, lhs.name()) != 0)
            {
            String* sty = staticIvarTypeFor(_curClass, lhs.name());
            IRValue* sv = coerce(v, n.kid((u32)1).ty(), sty);
            storeGlobalARC(staticIvarFor(_curClass, lhs.name()), sty, sv, n.kid((u32)1));
            return sv;
            }
        if (ivarIndexOf(lhs.name()) >= (i32)0)
            {
            String* ity = (String*)_curClass.ivarType().get((Hashable*)lhs.name());
            IRValue* iv = coerce(v, n.kid((u32)1).ty(), ity);
            IRValue* fa = ivarAddr(lhs.name());
            storeStrongSlot(fa, iv, ity, n.kid((u32)1));
            // A bare `wf = x` inside a method reaches the ivar through the
            // implicit self, and it must register+balance a `weak:T@` exactly
            // as the `obj.field =` path does — the two spellings of the same
            // assignment have to behave identically. This path used to emit
            // nothing for a plain `weak:T@` (only a `^`), so `wf = new Item()`
            // linked nothing and released nothing: the slot never auto-zeroed
            // and the +1 leaked (bug 170, Leak A).
            if (isWeakClassPtr(ity))
                {
                weakOp(String.withCString("WeakUnregister"), fa, (IRValue*)0);
                weakOp(String.withCString("WeakRegister"), fa, iv);
                if (!rhsIsBorrowed(n.kid((u32)1)))
                    refOp(String.withCString("Release"), iv);
                }
            // A `^` IVAR — a control's target/action — auto-zeroes when its
            // receiver dies, so the side table has to learn the new referent.
            // Re-pointing one drops the old entry first.
            if (isBoundSig(stripQual(ity)) && !isWidenedFn(n.kid((u32)1)))
                registerBoundPair(fa, iv, ity);
            return iv;
            }
        // A pinned local is written through its slot: the value never becomes
        // the name's SSA binding, because the name has no SSA binding.
        IRPinned* pin = pinOf(lhs.name());
        if (pin != 0)
            {
            String* pty = (String*)_pinAst.get((Hashable*)lhs.name());
            IRValue* pv = coerce(v, n.kid((u32)1).ty(), pty);
            // A STRUCT copy refcounts what the struct holds. Which way round
            // depends on where the right-hand side came from, and it has to be
            // decided BEFORE the value is in hand: an owned struct-returning
            // call may write its result straight into `dst`, so a
            // release-of-old emitted afterwards would free the NEW value and
            // leak the old.
            //   BORROWED (`dst = src`): dst gains a second reference to src's
            // strong fields — retain them FIRST, so `s = s` is safe, then
            // release dst's own.
            //   OWNED: dst adopts the +1 fields the store brings, so its prior
            // occupants are released and nulled before the value arrives.
            // The destination's own address is formed FIRST, before the
            // refcounting: it is where the value is going, and the order the
            // instructions come out in is the order they are compared in.
            IRValue* dstAddr = pinAddrNamed(pin, lhs.name());
            structCopyARC(lhs.name(), n.kid((u32)1));
            if (_failed)
                return (IRValue*)0;
            storeThrough(dstAddr, pv);
            // `b = a;` between structs is the same wholesale copy as
            // `S b = a;` — link words included, destination linked to nothing.
            relinkWeakSlotsAfterCopy(dstAddr, pty);
            // Re-POINTING an auto-zeroing local moves its side-table entry to
            // the new referent. The slot's address is formed again — the
            // register runs as its own step and reads the slot the way any
            // later access would.
            if (isBoundSig(stripQual(pty)) && !isWidenedFn(n.kid((u32)1)))
                registerBoundPair(pinAddrNamed(pin, lhs.name()), pv, pty);
            else if (isWeakClassPtr(pty))
                {
                IRValue* slotA = pinAddrNamed(pin, lhs.name());
                weakOp(String.withCString("WeakUnregister"), slotA, (IRValue*)0);
                weakOp(String.withCString("WeakRegister"), slotA, pv);
                // Same as the weak DECL (bug 153): a +1 RHS the store adopted
                // must be released after the re-register. Borrowed owns nothing.
                if (!rhsIsBorrowed(n.kid((u32)1)))
                    refOp(String.withCString("Release"), pv);
                }
            return pv;
            }
        Object* lt = _localTypes.get((Hashable*)lhs.name());
        if (lt != 0)
            {
            IRValue* c = coerce(v, n.kid((u32)1).ty(), (String*)lt);
            // Assigning to a STRONG slot changes what it owns. A borrowed
            // right-hand side has to be retained; a `new` is already +1 and
            // the slot adopts it. Either way the OLD occupant is released —
            // after the retain, so `p = p` cannot free the object it is about
            // to keep.
            if (hasName(_strongLocals, lhs.name()))
                {
                if (rhsIsBorrowed(n.kid((u32)1)) && isAnyClassPointer(n.kid((u32)1).ty()))
                    refOp(String.withCString("Retain"), c);
                else
                    consumeOwnedTemp(c);
                Object* old = _locals.get((Hashable*)lhs.name());
                if (old != 0)
                    refOp(String.withCString("Release"), (IRValue*)old);
                }
            // Binding a +1 to ANY local — a non-strong slot, a reassigned
            // PARAMETER — means the local now references it, so the
            // end-of-statement sweep must leave it alone. A parameter's slot
            // is borrowed and owns nothing, which is exactly why the sweep
            // used to free it while the parameter still pointed at it. Worst
            // case the other way is a leak.
            consumeOwnedTemp(c);
            _locals.set((Hashable*)lhs.name(), (Object*)c);
            return c;
            }
        Object* gt = _globals.get((Hashable*)lhs.name());
        if (gt != 0)
            {
            IRValue* c = coerce(v, n.kid((u32)1).ty(), (String*)gt);
            storeGlobalARC(lhs.name(), (String*)gt, c, n.kid((u32)1));
            return c;
            }
        _failed = true;
        return (IRValue*)0;
        }

    // va_start / va_arg_<T> / va_end. The front end does NOT expand the buffer
    // access: it emits an abstract op carrying the cursor's SLOT, and a
    // per-target pass unfolds it later — a native AAPCS va_list on one backend,
    // indexed reads out of a pack buffer on another. `va_end` is nothing at
    // all: no value, no memory, no cursor change.
    IRValue* lowerVaIntrinsic(Node* n, String* sym)
        {
        if (sym.equals(String.withCString("__intrinsic_va_end")))
            return (IRValue*)0;
        String* cursor = (String*)0;
        if (n.kidCount() > (u32)0 && n.kid((u32)0).kind() == (u16)nkIdent)
            cursor = n.kid((u32)0).name();
        IRPinned* pin = pinOf(cursor);
        if (pin == 0)
            {
            giveUp(String.withCString("va_* cursor is not a pinned local"));
            return (IRValue*)0;
            }
        IRValue* addr = pinAddr(pin);
        bool isStart = sym.equals(String.withCString("__intrinsic_va_start"));
        IRInsn* i = IRInsn.with(String.withCString(isStart ? "VaStart" : "VaArg"));
        IRValue* res = (IRValue*)0;
        String* wantTy = (String*)0;
        if (!isStart)
            {
            wantTy = irType(n.ty());
            // A CLASS-pointer read must not put Ptr(Agg) on the abstract
            // VaArg: that shape is the expander's ONLY marker for
            // struct-BY-VALUE (typed pointer into the buffer, advance by
            // sizeof), and a class reference given that treatment dispatches
            // through buffer bytes. Read a plain pointer VALUE and Bitcast
            // after — the reference does exactly this. va_arg_struct_ptr
            // keeps its Agg type: there the buffer pointer IS the contract.
            bool aggRes = wantTy.hasPrefix(String.withCString("Ptr(Agg"));
            bool structForm = sym.equals(String.withCString("__intrinsic_va_arg_struct_ptr"));
            if (aggRes && !structForm)
                {
                res = new IRValue(String.withCString("Ptr(U8, unbanked)"));
                }
            else
                {
                res = new IRValue(wantTy);
                wantTy = (String*)0;
                }
            i.setRes(res);
            }
        IRValue* nextMem = new IRValue(String.withCString("Mem"));
        i.setMemRes(nextMem);
        i.add(IROperand.useVal(addr));
        i.add(IROperand.useVal(_mem));
        _blk.add(i);
        _mem = nextMem;
        if (res != 0 && wantTy != 0 && wantTy.hasPrefix(String.withCString("Ptr(Agg")))
            {
            Array* bops = new Array();
            bops.add((Object*)IROperand.useVal(res));
            return emit(String.withCString("Bitcast"), wantTy, bops);
            }
        return res;
        }

    IRValue* lowerCall(Node* n)
        {
        if (n.sym() != 0 && n.sym().hasPrefix(String.withCString("__intrinsic_va_")))
            return lowerVaIntrinsic(n, n.sym());
        // `bank(type, idx)` is a raw pointer to byte 0 of a window in a given
        // bank — a thing no expression can name, because the bank byte is part
        // of the address. It goes to one runtime helper each backend supplies:
        // the address arithmetic is the target's, not the IR's.
        if (n.sym() != 0 && n.sym().equals(String.withCString("__intrinsic_bank")))
            {
            if (n.kidCount() != (u32)2)
                {
                giveUp(String.withCString("bank expects two arguments"));
                return (IRValue*)0;
                }
            String* u8T = String.withCString("u8");
            IRValue* tv = lowerExpr(n.kid((u32)0));
            if (_failed)
                return (IRValue*)0;
            tv = coerce(tv, n.kid((u32)0).ty(), u8T);
            IRValue* iv = lowerExpr(n.kid((u32)1));
            if (_failed)
                return (IRValue*)0;
            iv = coerce(iv, n.kid((u32)1).ty(), u8T);
            Array* bargs = new Array();
            bargs.add((Object*)tv);
            bargs.add((Object*)iv);
            return emitMethodCall(runtimeHelper(String.withCString("_xtc_bank")),
                                  (IRValue*)0, bargs,
                                  String.withCString("u8*"), true);
            }
        // The ARC primitives, spelled out. Container code refcounts its
        // type-erased `pointer` slots by hand, and these are the same two
        // opcodes the compiler inserts for a typed strong reference — which is
        // what lets the libraries drop their inline-asm helpers.
        if (n.sym() != 0 && (n.sym().equals(String.withCString("__intrinsic___arc_retain")) || n.sym().equals(String.withCString("__intrinsic___arc_release"))))
            {
            if (n.kidCount() != (u32)1)
                return (IRValue*)0;
            IRValue* p = lowerExpr(n.kid((u32)0));
            if (_failed)
                return (IRValue*)0;
            refOp(String.withCString(
                      n.sym().equals(String.withCString("__intrinsic___arc_retain"))
                          ? "Retain"
                          : "Release"),
                  p);
            return (IRValue*)0;
            }
        // Sema rewrote a block-typed callee into `.invoke` dispatch and hung
        // it on the node, past the arguments and the callee. private:docs/bugs/074.
        if (n.hasFlag((u32)NF_FIELDCALL))
            {
            u32 rw = (u32)n.num() + (u32)1;
            if (n.kidCount() > rw)
                return lowerExpr(n.kid(rw));
            }
        // A call through a VALUE rather than to a symbol. The callee is
        // whatever the name holds; the backend jumps through it.
        if (n.indirect())
            return lowerIndirectCall(n);
        // A bare call inside a method may be a SIBLING method reached through
        // the implicit self. The parser cannot tell it from a free call, so
        // the receiver is supplied here or the call goes to nothing.
        //
        // "No free function of that name" is NOT the precondition, though it
        // used to be: a global named `add` then stopped every class's own `add`
        // from being reachable (bug 040).
        //
        // Sema's stamp cannot settle it here, which is the trap. A method's
        // mangled name is UNQUALIFIED, so a same-named free function mangles
        // identically and methodDeclFor — which matches on that symbol —
        // answers "yes, a method" for a call sema resolved to the global. So
        // lowering re-applies sema's own rule instead of trusting the stamp:
        // a method calling its OWN name means the free function (the
        // `sqrt(double v) { return sqrt(v); }` wrapper), anything else means
        // the member.
        bool selfWrapper = _curMethodName != 0 && n.name().equals(_curMethodName) && _funcs.get((Hashable*)n.name()) != 0;
        if (_curClass != 0 && _self != 0 && !selfWrapper && methodDeclFor(_curClass, n) != 0)
            {
            Node* decl = methodDeclFor(_curClass, n);
            // An implicit-self call is a METHOD call, so it evaluates every
            // argument before adjusting any of them — unlike a free call,
            // which adjusts each as it goes.
            Array* args = new Array();
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                IRValue* a = lowerExpr(n.kid(i));
                if (_failed)
                    return (IRValue*)0;
                args.add((Object*)a);
                }
            for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
                {
                String* want = paramTypeAt(decl, i);
                if (want == 0)
                    continue;
                args.set(i, (Object*)coerceArg((IRValue*)args.get(i),
                                               n.kid(i).ty(), want));
                }
            String* ret = n.ty();
            bool hasRes = ret != 0 && !isName(stripQual(ret), "void");
            // A sibling STATIC method takes no receiver — not even the class's
            // own storage block, which is what `self` is inside one.
            bool st = decl.hasFlag((u32)NF_STATIC);
            // An implicit-self call to a method with a SLOT still dispatches
            // virtually. Resolving it statically would pick the authoring
            // class's body — `Gfx.plot` where the receiver is really a `Gfx8`
            // — and the override would never run. §4.2 first: a category
            // method on an imported class has a CHAIN slot, never a vtable one.
            if (!st && catSlotFor(_curClass, n) >= (i32)0)
                return emitCatDispatch(_self, _curClass.catAnchor(),
                                       (u32)catSlotFor(_curClass, n), args, ret);
            if (!st && selfSlotFor(_curClass, n) >= (i32)0)
                return emitDispatch(_self, (u32)selfSlotFor(_curClass, n), args, ret);
            return emitMethodCall(methodSymbolFor(_curClass, n), st ? (IRValue*)0 : _self,
                                  args, ret, hasRes);
            }
        Object* d = n.sym() == 0 ? (Object*)0 : _funcsBySym.get((Hashable*)n.sym());
        if (d == 0)
            {
            Object* byName = _funcs.get((Hashable*)n.name());
            // libc and free functions are the LOWEST-precedence layer: when the
            // analyser resolved this call to a DIFFERENT symbol — a `use`-
            // promoted static method, `Math.rand(u8)` against the imported
            // `rand(void)` — the same-named free function must not claim it
            // back. The original expresses this as "no bare-name fallback once
            // sema stamped a class"; here the stamp is the symbol itself.
            if (byName != 0 && n.sym() != 0)
                {
                String* ds = ((Node*)byName).sym();
                if (ds != 0 && !ds.equals(n.sym()))
                    byName = (Object*)0;
                }
            d = byName;
            }
        if (d == 0)
            {
            // `use Stdio;` promotes a class's STATIC methods into the
            // bare-call space, so `printf(…)` is `Stdio.printf(…)` with the
            // receiver left unsaid — and it lowers as one, static-init guard
            // and all.
            ClassInfo* uc = usedClassFor(n);
            if (uc != 0)
                return lowerUsedStaticCall(uc, n);
            String* w = String.withCString("call to ");
            w.append(n.name());
            giveUp(w);
            return (IRValue*)0;
            }
        Node* decl = (Node*)d;
        // A FREE call adjusts each argument as it is lowered; a METHOD call
        // evaluates them all and adjusts afterwards. The two really do differ,
        // and the printed order says so.
        Array* cargs = new Array();
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            {
            IRValue* a = lowerExpr(n.kid(i));
            if (_failed)
                return (IRValue*)0;
            String* want = paramTypeAt(decl, i);
            if (want != 0)
                a = coerceArg(a, n.kid(i).ty(), want);
            cargs.add((Object*)a);
            }
        if (decl.hasFlag((u32)NF_VARARGS))
            cargs = packVarargs(cargs, fixedParamCount(decl), decl);
        IRInsn* call = IRInsn.with(String.withCString("Call"));
        call.add(IROperand.sym(decl.sym() == 0 ? n.name() : decl.sym()));
        for (u32 i = (u32)0; i < cargs.count(); i = i + (u32)1)
            call.add(IROperand.useVal((IRValue*)cargs.get(i)));
        call.add(IROperand.useVal(_mem));
        IRValue* nextMem = new IRValue(String.withCString("Mem"));
        call.setMemRes(nextMem);
        String* ret = firstReturn(decl.op());
        IRValue* res = (IRValue*)0;
        if (!isName(stripQual(ret), "void"))
            {
            res = new IRValue(irType(ret));
            call.setRes(res);
            }
        call.setCc(String.withCString("CallConv::Standard"));
        _blk.add(call);
        _mem = nextMem;
        noteOwnedTemp(res, ret);
        // A call to a `throws` function may have raised. Checked here, at the
        // one point every direct call passes through, rather than at each of
        // the several return sites — one of which would eventually be missed.
        if (decl.hasFlag((u32)NF_THROWS))
            emitErrorCheckAfterCall();
        return res;
        }

    // For a call, the ARGUMENTS are kids 0..num-1. A callee written as an
    // EXPRESSION rather than a name rides as one extra kid after them, so
    // "there is one more kid than there are arguments" is the marker.
    // private:docs/bugs/074.
    Node* calleeKid(Node* n)
        {
        if (n.kidCount() > (u32)n.num())
            return n.kid((u32)n.num());
        return (Node*)0;
        }

    IRValue* lowerIndirectCall(Node* n)
        {
        // A call through a `^` unpacks the pair: the code word is what is
        // jumped to, and the receiver rides in front of the written arguments
        // exactly as it would in a direct method call.
        if (n.boundCall())
            return lowerBoundCall(n);
        // The callee is lowered as an IDENTIFIER EXPRESSION, not looked up in
        // _locals. A function pointer is not always an SSA local: it can be a
        // static local (a module global under the hood), a global, a static
        // ivar. `static UXFactory* f0; ... f0(name);` — the nib factory in
        // uxkit/026 — is exactly that, and a _locals lookup could only refuse
        // it. lowerIdentifier resolves all of those, and for a plain local it
        // returns the same SSA value the lookup did, so nothing else moves.
        Node* ck = calleeKid(n);
        IRValue* fv = ck != 0 ? lowerExpr(ck)
                              : lowerIdentifier(Node.withName((u16)nkIdent, n.name()));
        if (_failed)
            return (IRValue*)0;
        if (fv == (IRValue*)0)
            {
            String* w = String.withCString("indirect call through ");
            w.append(n.name());
            giveUp(w);
            return (IRValue*)0;
            }
        IRInsn* c = IRInsn.with(String.withCString("CallIndirect"));
        c.add(IROperand.useVal(fv));
        for (u32 i = (u32)0; i < (u32)n.num(); i = i + (u32)1)
            {
            IRValue* a = lowerExpr(n.kid(i));
            if (_failed)
                return (IRValue*)0;
            c.add(IROperand.useVal(a));
            }
        c.add(IROperand.useVal(_mem));
        String* ret = n.ty();
        IRValue* res = (IRValue*)0;
        if (ret != 0 && !isName(stripQual(ret), "void"))
            {
            res = new IRValue(irType(ret));
            c.setRes(res);
            }
        IRValue* nm = new IRValue(String.withCString("Mem"));
        c.setMemRes(nm);
        c.setCc(String.withCString("CallConv::Standard"));
        _blk.add(c);
        _mem = nm;
        // A call THROUGH A POINTER owns its result exactly as a direct call
        // does: the original's rule is "the call's type is a class pointer,
        // therefore +1", with no lookup of the callee involved — and there is
        // no name to look up here anyway. Without this the result counted as
        // BORROWED, so returning it emitted a Retain on top of the +1 the call
        // already handed back: an over-retain, i.e. a leak, and 3 lines of IR
        // the original does not emit.
        noteOwnedTemp(res, ret);
        return res;
        }

    IRValue* lowerBoundCall(Node* n)
        {
        IRValue* pair = (IRValue*)0;
        // CALLING through a `^` parameter uses the pair it already has; only a
        // STORED one is read out of a slot. (Testing one for truth does go
        // through the slot — the two paths really do differ, because a call
        // wants the value and a guard wants what the slot currently holds,
        // which auto-zeroing can have changed underneath it.)
        // A callee written as an EXPRESSION — `tbl[0](5)`, `w.onChange(7)` —
        // is evaluated here; everything below works from the resulting pair,
        // so both callee forms share the dispatch. private:docs/bugs/074.
        Node* ck = calleeKid(n);
        if (ck != 0)
            {
            pair = lowerExpr(ck);
            if (_failed)
                return (IRValue*)0;
            }
        IRPinned* p = (ck != 0 || _locals.get((Hashable*)n.name()) != 0)
                          ? (IRPinned*)0
                          : pinOf(n.name());
        if (p != 0)
            {
            pair = loadThrough(pinAddrNamed(p, n.name()),
                               (String*)_pinAst.get((Hashable*)n.name()));
            }
        else if (ck == 0)
            {
            Object* v = _locals.get((Hashable*)n.name());
            if (v == 0)
                {
                // A `^` held in an IVAR — a target/action outlet — is read
                // through the receiver like any other field. Its slot is the
                // whole [prev, next, pair], and what comes out is the pair.
                if (ivarIndexOf(n.name()) >= (i32)0)
                    {
                    String* ivt = (String*)_curClass.ivarType().get((Hashable*)n.name());
                    pair = loadThrough(ivarAddr(n.name()), ivt);
                    }
                else
                    {
                    // Neither an SSA local nor an ivar — a GLOBAL, a static
                    // local, or a static ivar. lowerIdentifier resolves all of
                    // those, and giving up here meant a file-scope callback
                    // could be declared and assigned but never CALLED:
                    // `unsupported: bound call through gTap`. The indirect-call
                    // path next door already had this fallback; the bound one
                    // did not, which is the same omission in a second place.
                    pair = lowerIdentifier(Node.withName((u16)nkIdent, n.name()));
                    if (_failed)
                        return (IRValue*)0;
                    if (pair == (IRValue*)0)
                        {
                        String* w = String.withCString("bound call through ");
                        w.append(n.name());
                        giveUp(w);
                        return (IRValue*)0;
                        }
                    }
                }
            else
                {
                pair = (IRValue*)v;
                }
            }
        String* ptrT = ptrTo(String.withCString("Void"));
        Array* r0 = new Array();
        r0.add((Object*)IROperand.useVal(pair));
        r0.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
        IRValue* recv = emit(String.withCString("AggExtract"), ptrT, r0);
        Array* r1 = new Array();
        r1.add((Object*)IROperand.useVal(pair));
        r1.add((Object*)IROperand.immI((i32)1, String.withCString("U16")));
        IRValue* code = emit(String.withCString("AggExtract"), ptrT, r1);

        IRInsn* c = IRInsn.with(String.withCString("CallIndirect"));
        c.add(IROperand.useVal(code));
        c.add(IROperand.useVal(recv));
        for (u32 i = (u32)0; i < (u32)n.num(); i = i + (u32)1)
            {
            IRValue* a = lowerExpr(n.kid(i));
            if (_failed)
                return (IRValue*)0;
            c.add(IROperand.useVal(a));
            }
        c.add(IROperand.useVal(_mem));
        String* ret = n.ty();
        IRValue* res = (IRValue*)0;
        if (ret != 0 && !isName(stripQual(ret), "void"))
            {
            res = new IRValue(irType(ret));
            c.setRes(res);
            }
        IRValue* nm = new IRValue(String.withCString("Mem"));
        c.setMemRes(nm);
        c.setCc(String.withCString("CallConv::Standard"));
        _blk.add(c);
        _mem = nm;
        return res;
        }

    // An ARGUMENT is adjusted to the callee's parameter, and this is NOT the
    // ordinary coercion: it compares the argument's declared width against the
    // PARAMETER's IR width. The difference is visible — a comparison's declared
    // type is its operand type, so `isTrue(a == b)` on u16 operands truncates
    // into the `bool` parameter, while the same call on bool operands does
    // nothing. Getting it wrong left a narrow literal's high bytes stale on the
    // callee's stack.
    //
    // A pointer or void destination is left alone, and so is an aggregate: a
    // `^` parameter is an Agg, and integer-extending one from the argument's
    // pointer width would be nonsense.
    IRValue* coerceArg(IRValue* v, String* srcAst, String* dstAst)
        {
        if (v == 0 || srcAst == 0 || dstAst == 0)
            return v;
        String* dstIr = irType(dstAst);
        if (dstIr.equals(String.withCString("Void")) || isPtrIr(dstIr))
            return v;
        // A plain function pointer reaching a `^` parameter WIDENS into one:
        // the pair's recv word carries the code address and its code word a
        // trampoline that jumps through it. That is what lets a free function
        // and a bound method share one parameter type with no second ABI.
        if (dstIr.hasPrefix(String.withCString("Agg(")))
            {
            if (isBoundSig(stripQual(dstAst)) && isFnPointer(srcAst))
                return widenToBound(v, dstAst);
            return v;
            }
        // Crossing between the integer and float domains is a CONVERSION,
        // not a resize: the bit pattern changes completely, so a widening
        // ZExt would hand the callee an integer where it reads a float.
        bool aF = isFloatIr(v.ty());
        bool bF = isFloatIr(dstIr);
        if (aF != bF)
            {
            Array* fops = new Array();
            fops.add((Object*)IROperand.useVal(v));
            if (bF)
                return emit(String.withCString(Types.isSigned(srcAst) ? "SIToFp" : "UIToFp"),
                            dstIr, fops);
            return emit(String.withCString(Types.isSigned(dstAst) ? "FpToSI" : "FpToUI"),
                        dstIr, fops);
            }
        if (aF && bF)
            {
            if (astWidth(srcAst) == astWidth(dstAst))
                return v;
            Array* fops = new Array();
            fops.add((Object*)IROperand.useVal(v));
            return emit(String.withCString(astWidth(dstAst) > astWidth(srcAst)
                                               ? "FpExt"
                                               : "FpTrunc"),
                        dstIr, fops);
            }
        u32 srcW = astWidth(srcAst);
        u32 dstW = irWidth(dstIr);
        bool srcSgn = Types.isSigned(srcAst);
        bool dstSgn = dstIr.equals(String.withCString("I8")) || dstIr.equals(String.withCString("I16")) || dstIr.equals(String.withCString("I32")) || dstIr.equals(String.withCString("I64"));
        if (srcW == dstW && srcSgn == dstSgn)
            return v;
        Array* ops = new Array();
        ops.add((Object*)IROperand.useVal(v));
        String* op = dstW > srcW ? String.withCString(srcSgn ? "SExt" : "ZExt")
                                 : (dstW < srcW ? String.withCString("Trunc")
                                                : String.withCString("Bitcast"));
        return emit(op, dstIr, ops);
        }

    // A plain function pointer — `u8(u8)@` — as opposed to a `^`, which is
    // already a pair.
    bool isFnPointer(String* t)
        {
        if (t == 0 || isBoundSig(stripQual(t)))
            return false;
        String* s = stripQual(t);
        if (s.byteLength() == (u32)0 || s.byteAt(s.byteLength() - (u32)1) != (u8)'*')
            return false;
        String* pointee = s.substringBytes((u32)0, s.byteLength() - (u32)1);
        for (u32 i = (u32)0; i < pointee.byteLength(); i = i + (u32)1)
            if (pointee.byteAt(i) == (u8)'(')
                return true;
        return false;
        }

    IRValue* widenToBound(IRValue* fnPtr, String* boundAst)
        {
        String* tramp = boundTrampoline(stripQual(boundAst));
        Array* cops = new Array();
        cops.add((Object*)IROperand.sym(tramp));
        IRValue* code = emit(String.withCString("AddrOf"),
                             ptrTo(String.withCString("Void")), cops);
        Array* bops = new Array();
        bops.add((Object*)IROperand.useVal(fnPtr));
        bops.add((Object*)IROperand.useVal(code));
        return emit(String.withCString("AggBuild"), irType(boundAst), bops);
        }

    u32 fixedParamCount(Node* decl)
        {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            if (decl.kid(i).kind() == (u16)nkParam)
                n = n + (u32)1;
        return n;
        }

    String* paramTypeAt(Node* decl, u32 index)
        {
        u32 seen = (u32)0;
        for (u32 i = (u32)0; i < decl.kidCount(); i = i + (u32)1)
            {
            Node* p = decl.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            if (seen == index)
                return p.op();
            seen = seen + (u32)1;
            }
        return (String*)0;
        }

    // A declaration's return spelling is everything before the first comma —
    // a multiple-return function's first result is what a call yields here.
    String* firstReturn(String* t)
        {
        if (t == 0)
            return String.withCString("void");
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            if (t.byteAt(i) == (u8)',')
                return t.substringBytes((u32)0, i);
        return t;
        }

    // ── constant folding for initialisers ────────────────────────────────
    // Enough of it for what an initialiser can be: a literal, a negation, and
    // the binary operators. `_constOk` goes false the moment something is not
    // foldable, so a caller never mistakes a zero for a value.
    bool _constOk;

    i32 constEval(Node* n)
        {
        if (n == 0)
            {
            _constOk = false;
            return (i32)0;
            }
        u16 k = n.kind();
        if (k == (u16)nkInt || k == (u16)nkChar || k == (u16)nkBool)
            return n.num();
        if (k == (u16)nkCast)
            return constEval(n.kid((u32)0));
        if (k == (u16)nkUnary)
            {
            i32 v = constEval(n.kid((u32)0));
            if (isName(n.op(), "-"))
                return (i32)0 - v;
            if (isName(n.op(), "~"))
                return ~v;
            if (isName(n.op(), "!"))
                return v == (i32)0 ? (i32)1 : (i32)0;
            _constOk = false;
            return (i32)0;
            }
        if (k == (u16)nkBinary)
            {
            i32 a = constEval(n.kid((u32)0));
            i32 b = constEval(n.kid((u32)1));
            if (!_constOk)
                return (i32)0;
            if (isName(n.op(), "+"))
                return a + b;
            if (isName(n.op(), "-"))
                return a - b;
            if (isName(n.op(), "*"))
                return a * b;
            if (isName(n.op(), "/"))
                {
                if (b == (i32)0)
                    {
                    _constOk = false;
                    return (i32)0;
                    }
                return a / b;
                }
            if (isName(n.op(), "%"))
                {
                if (b == (i32)0)
                    {
                    _constOk = false;
                    return (i32)0;
                    }
                return a % b;
                }
            if (isName(n.op(), "&"))
                return a & b;
            if (isName(n.op(), "|"))
                return a | b;
            if (isName(n.op(), "^"))
                return a ^ b;
            if (isName(n.op(), "<<"))
                return a << b;
            if (isName(n.op(), ">>"))
                return a >> b;
            }
        _constOk = false;
        return (i32)0;
        }

    // A float literal's 64 bits, most significant digit first — the order the
    // number is WRITTEN, which is the reverse of the order it is stored.
    String* fpBits(String* text)
        {
        string digits = "0123456789abcdef";
        Data* d = FloatEncoding.ieeeBytes(text, true);
        String* out = String.withCString("");
        u32 i = d.length();
        while (i > (u32)0)
            {
            i = i - (u32)1;
            u8 v = d.byteAt(i);
            out.appendByte(digits[(u32)(v >> (u8)4)]);
            out.appendByte(digits[(u32)(v & (u8)$0F)]);
            }
        return out;
        }

    // The bytes an aggregate initialiser bakes into the image: element by
    // element for an array, field by field for a struct, recursing through a
    // nested brace-list, and zero-filling whatever the list does not reach.
    // A non-constant entry means there are no compile-time bytes at all.
    Array* aggregateInitBytes(Node* list, String* ty)
        {
        if (list.kind() != (u16)nkBlock)
            return (Array*)0;
        Array* out = new Array();
        if (isArrayLike(ty))
            {
            String* elem = elementOf(ty);
            u32 n = arrayCount(ty);
            u32 w = sizeOf(elem);
            for (u32 i = (u32)0; i < n; i = i + (u32)1)
                {
                Array* b = (Array*)0;
                if (i < list.kidCount())
                    b = entryBytes(list.kid(i), elem, w);
                else
                    b = zeroBytes(w);
                if (b == 0)
                    return (Array*)0;
                appendAll(out, b);
                }
            return out;
            }
        Node* st = structDeclFor(ty);
        if (st == 0)
            return (Array*)0;
        bool pk = st.hasFlag((u32)NF_PACKED);
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            {
            String* ft = st.kid(i).op();
            // Inter-field PADDING: the image must carry the same zero bytes
            // the aligned layout reserves, or every field after the first
            // pad lands early. Mirror of foldInitialiser writing at the
            // recorded byteOffset into a zeroed buffer.
            u32 fa = pk ? (u32)1 : fieldAlignFor(ft);
            u32 tgt = (out.count() + fa - (u32)1) & ~(fa - (u32)1);
            for (u32 p = out.count(); p < tgt; p = p + (u32)1)
                out.add((Object*)Number.with((u32)0));
            u32 w = sizeOf(ft);
            Array* b = (Array*)0;
            if (i < list.kidCount())
                b = entryBytes(list.kid(i), ft, w);
            else
                b = zeroBytes(w);
            if (b == 0)
                return (Array*)0;
            appendAll(out, b);
            }
        // Tail PADDING. A struct's size is rounded up to its alignment so an
        // array of it strides the way C says; the baked image has to carry
        // those bytes or every element after the first lands short.
        for (u32 p = out.count(); p < sizeOf(ty); p = p + (u32)1)
            out.add((Object*)Number.with((u32)0));
        return out;
        }

    Array* entryBytes(Node* e, String* ty, u32 width)
        {
        if (e.kind() == (u16)nkBlock)
            {
            Array* nested = aggregateInitBytes(e, ty);
            if (nested == 0)
                return nested;
            for (u32 p = nested.count(); p < width; p = p + (u32)1)
                nested.add((Object*)Number.with((u32)0));
            return nested;
            }
        if (Types.isFloating(ty))
            {
            // A NEGATIVE literal is a unary minus over a positive one — the
            // lexer never produces a signed float token — so the sign is
            // carried in the spelling handed to the encoder.
            Node* lit = e;
            String* text = (String*)0;
            if (lit.kind() == (u16)nkUnary && isName(lit.op(), "-") && lit.kidCount() > (u32)0 && lit.kid((u32)0).kind() == (u16)nkFloat)
                {
                text = String.withCString("-");
                text.append(lit.kid((u32)0).name());
                }
            else if (lit.kind() == (u16)nkFloat)
                {
                text = lit.name();
                }
            else
                {
                return (Array*)0;
                }
            Data* d = FloatEncoding.ieeeBytes(text, astWidth(ty) == (u32)8);
            return bytesOfData(d);
            }
        _constOk = true;
        i32 v = constEval(e);
        if (!_constOk)
            return (Array*)0;
        return leBytes(v, width);
        }

    Array* zeroBytes(u32 n)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            out.add((Object*)Number.with((u32)0));
        return out;
        }

    void appendAll(Array* dst, Array* src)
        {
        for (u32 i = (u32)0; i < src.count(); i = i + (u32)1)
            dst.add(src.get(i));
        }

    Array* bytesOfData(Data* d)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < d.length(); i = i + (u32)1)
            out.add((Object*)Number.with((u32)d.byteAt(i)));
        return out;
        }

    // ── byte-list initialisers ───────────────────────────────────────────
    // `u32 v = {$78, $56, $34, $12}` sets a scalar's raw byte pattern, and
    // `u8 a[3] = { base, 20, 30 }` an aggregate's elements. Four shapes, and
    // which one applies is decided by two questions: is the TARGET a scalar
    // or an aggregate, and does every ENTRY fold to a compile-time integer.
    //
    // An all-constant scalar list assembles into a single Const and needs no
    // storage at all. One with a runtime entry has no single Const, so the
    // slot becomes a byte buffer written a byte at a time — which is why the
    // pre-scan pins exactly those.

    bool byteListAllConstant(Node* list)
        {
        for (u32 i = (u32)0; i < list.kidCount(); i = i + (u32)1)
            {
            _constOk = true;
            constEval(list.kid(i));
            if (!_constOk)
                return false;
            }
        return true;
        }

    // A scalar a byte-list can be assembled into: any integer or float from
    // one to eight bytes wide.
    bool byteListStorable(String* ty)
        {
        if (ty == 0)
            return false;
        if (!Types.isInteger(ty) && !Types.isFloating(ty))
            return false;
        u32 w = Types.byteWidth(ty);
        return w >= (u32)1 && w <= (u32)8;
        }

    // The list's constant bytes, zero-filled to the scalar's width; entries
    // past the width are dropped.
    Array* byteListBytes(Node* list, u32 width)
        {
        Array* buf = new Array();
        for (u32 i = (u32)0; i < width; i = i + (u32)1)
            buf.add((Object*)Number.with((u32)0));
        for (u32 i = (u32)0; i < list.kidCount(); i = i + (u32)1)
            {
            _constOk = true;
            i32 v = constEval(list.kid(i));
            if (!_constOk)
                {
                giveUp(String.withCString("byte-list entry is not constant"));
                return buf;
                }
            if (i < width)
                buf.set(i, (Object*)Number.with((u32)v & (u32)$FF));
            }
        return buf;
        }

    // The whole list as ONE Const. A float target reads its bytes as the IEEE
    // pattern they are and re-expresses them as the double every float
    // immediate carries; an integer target packs them little-endian.
    IRValue* lowerScalarByteList(Node* list, String* astTy)
        {
        if (!byteListStorable(astTy) && !Types.isPointer(astTy))
            {
            giveUp(String.withCString("byte-list initialiser needs a sized scalar"));
            return (IRValue*)0;
            }
        String* ity = irType(astTy);
        u32 width = Types.byteWidth(astTy);
        Array* buf = byteListBytes(list, width);
        if (_failed)
            return (IRValue*)0;
        if (Types.isFloating(astTy))
            {
            Array* fops = new Array();
            fops.add((Object*)IROperand.immF(fpBitsOfBytes(buf), ity));
            return emit(String.withCString("Const"), ity, fops);
            }
        u32 packed = (u32)0;
        for (u32 b = (u32)0; b < width; b = b + (u32)1)
            packed = packed | (((Number*)buf.get(b)).asU32() << (b * (u32)8));
        // A POINTER is built from an integer and cast: a Const of pointer type
        // is mis-sized on the native backends, so the bytes become an integer
        // of the pointer's width and an IntToPtr carries them across.
        if (Types.isPointer(astTy))
            {
            String* intTy = width <= (u32)1 ? String.withCString("U8")
                                            : (width <= (u32)2 ? String.withCString("U16")
                                                               : String.withCString("U32"));
            Array* cops = new Array();
            cops.add((Object*)IROperand.immU(packed, intTy));
            IRValue* c = emit(String.withCString("Const"), intTy, cops);
            Array* iops = new Array();
            iops.add((Object*)IROperand.useVal(c));
            return emit(String.withCString("IntToPtr"), ity, iops);
            }
        Array* ops = new Array();
        ops.add((Object*)IROperand.immU(packed, ity));
        return emit(String.withCString("Const"), ity, ops);
        }

    // A scalar built from RUNTIME bytes has no single Const, so its slot is
    // treated as a byte buffer: take the address as `u8@` and store each byte
    // in turn. The count is the scalar's width — bytes past the list zero-fill
    // and entries past the width are dropped.
    // `u8 buf[10] = 0..10;` is a byte LIST written the short way — the
    // language's only counted initialiser. Expanding it here rather than in a
    // path of its own means the local's stores and the global's baked bytes
    // both come out of the machinery that already exists for `{ … }`.
    // `..` stops before its upper bound; `...` includes it.
    Node* expandRange(Node* ini, String* astTy)
        {
        if (ini == 0 || ini.kind() != (u16)nkRange)
            return ini;
        _constOk = true;
        i32 lo = constEval(ini.kid((u32)0));
        i32 hi = constEval(ini.kid((u32)1));
        if (!_constOk)
            {
            giveUp(String.withCString("range bounds are not constant"));
            return ini;
            }
        if (ini.hasFlag((u32)NF_INCLUSIVE))
            hi = hi + (i32)1;
        String* elem = isArrayLike(astTy) ? elementOf(astTy) : astTy;
        Node* list = Node.with((u16)nkBlock);
        for (i32 v = lo; v < hi; v = v + (i32)1)
            {
            Node* k = Node.with((u16)nkInt);
            k.setNum(v);
            k.setTy(elem);
            list.add(k);
            }
        return list;
        }

    void lowerScalarByteListStores(Node* list, IRPinned* pin, String* astTy)
        {
        u32 width = Types.byteWidth(astTy);
        if (width == (u32)0 || width > (u32)8)
            {
            giveUp(String.withCString("byte-list initialiser target has unsupported width"));
            return;
            }
        String* u8Ptr = ptrTo(String.withCString("U8"));
        Array* bops = new Array();
        bops.add((Object*)IROperand.useVal(pin.val()));
        IRValue* base = emit(String.withCString("AddrOf"), u8Ptr, bops);
        for (u32 i = (u32)0; i < width; i = i + (u32)1)
            {
            IRValue* addr = byteSlotAddr(base, i, u8Ptr);
            IRValue* bv = (IRValue*)0;
            if (i < list.kidCount())
                {
                bv = lowerExpr(list.kid(i));
                if (_failed)
                    return;
                bv = coerce(bv, list.kid(i).ty(), String.withCString("u8"));
                }
            else
                {
                Array* zops = new Array();
                zops.add((Object*)IROperand.immI((i32)0, String.withCString("U8")));
                bv = emit(String.withCString("Const"), String.withCString("U8"), zops);
                }
            storeThrough(addr, bv);
            }
        }

    IRValue* byteSlotAddr(IRValue* base, u32 index, String* ptrTy)
        {
        Array* iops = new Array();
        iops.add((Object*)IROperand.immI((i32)index, String.withCString("U16")));
        IRValue* idx = emit(String.withCString("Const"), String.withCString("U16"), iops);
        Array* eops = new Array();
        eops.add((Object*)IROperand.useVal(base));
        eops.add((Object*)IROperand.useVal(idx));
        return emit(String.withCString("ElementAddr"), ptrTy, eops);
        }

    // An AGGREGATE's list writes elements or fields, each entry lowered as an
    // ordinary expression and coerced to what it lands in. A nested `{ … }`
    // recurses on the element's own address, which is how `{30, 40, {5, 6}}`
    // reaches the inner struct.
    void lowerAggregateByteList(IRValue* base, String* astTy, Node* list)
        {
        if (isArrayLike(astTy))
            {
            String* elem = elementOf(astTy);
            String* elemIr = irType(elem);
            String* elemPtr = ptrTo(elemIr);
            u32 count = arrayCount(astTy);
            if (count == (u32)0)
                count = list.kidCount();
            // The base arrived as a Ptr(Agg) — re-cast once so ElementAddr
            // strides by the ELEMENT and not by the whole aggregate.
            IRValue* eBase = base;
            if (!base.ty().equals(elemPtr))
                {
                Array* cops = new Array();
                cops.add((Object*)IROperand.useVal(base));
                eBase = emit(String.withCString("Bitcast"), elemPtr, cops);
                }
            for (u32 i = (u32)0; i < count; i = i + (u32)1)
                {
                IRValue* addr = byteSlotAddr(eBase, i, elemPtr);
                if (i < list.kidCount())
                    {
                    Node* entry = list.kid(i);
                    if (entry.kind() == (u16)nkBlock)
                        {
                        lowerAggregateByteList(addr, elem, entry);
                        if (_failed)
                            return;
                        continue;
                        }
                    IRValue* v = lowerExpr(entry);
                    if (_failed)
                        return;
                    storeThrough(addr, coerce(v, entry.ty(), elem));
                    }
                else
                    {
                    Array* zops = new Array();
                    zops.add((Object*)IROperand.immI((i32)0, elemIr));
                    storeThrough(addr, emit(String.withCString("Const"), elemIr, zops));
                    }
                }
            return;
            }
        Node* st = structDeclFor(astTy);
        if (st == 0)
            {
            giveUp(String.withCString("byte-list target is not an aggregate"));
            return;
            }
        u32 n = st.kidCount() < list.kidCount() ? st.kidCount() : list.kidCount();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            String* ft = st.kid(i).op();
            IRValue* fa = fieldAddr(base, i, ptrTo(irType(ft)));
            Node* entry = list.kid(i);
            if (entry.kind() == (u16)nkBlock)
                {
                lowerAggregateByteList(fa, ft, entry);
                if (_failed)
                    return;
                continue;
                }
            IRValue* v = lowerExpr(entry);
            if (_failed)
                return;
            storeThrough(fa, coerce(v, entry.ty(), ft));
            }
        }

    // The 64 bits of the double these IEEE bytes denote. Eight bytes ARE a
    // double; four are a float, and widening one is pure bit-shuffling —
    // an 8-bit exponent biased by 127 becomes an 11-bit one biased by 1023,
    // and a 23-bit significand moves up 29 places.
    String* fpBitsOfBytes(Array* buf)
        {
        if (buf.count() >= (u32)8)
            {
            u32 lo = (u32)0;
            u32 hi = (u32)0;
            for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
                lo = lo | (((Number*)buf.get(i)).asU32() << (i * (u32)8));
            for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
                hi = hi | (((Number*)buf.get(i + (u32)4)).asU32() << (i * (u32)8));
            String* out = hex8(hi);
            out.append(hex8(lo));
            return out;
            }
        u32 bits = (u32)0;
        for (u32 i = (u32)0; i < (u32)4 && i < buf.count(); i = i + (u32)1)
            bits = bits | (((Number*)buf.get(i)).asU32() << (i * (u32)8));
        u32 s = (bits >> 31) & (u32)1;
        u32 e = (bits >> 23) & (u32)$FF;
        u32 m = bits & (u32)$7FFFFF;
        u32 hi = (u32)0;
        u32 lo = (u32)0;
        if (e == (u32)0 && m == (u32)0)
            {
            hi = s << 31;
            }
        else
            {
            u32 be = (u32)0;
            if (e == (u32)$FF)
                {
                be = (u32)2047; // infinity or NaN, kept as one
                }
            else if (e == (u32)0)
                {
                // A float DENORMAL is a normal double: shift the significand up
                // until its hidden bit appears, paying one exponent per shift.
                i32 exp = (i32)-126;
                while ((m & (u32)$800000) == (u32)0)
                    {
                    m = m << 1;
                    exp = exp - (i32)1;
                    }
                m = m & (u32)$7FFFFF;
                be = (u32)(exp + (i32)1023);
                }
            else
                {
                be = e - (u32)127 + (u32)1023;
                }
            hi = (s << 31) | (be << 20) | (m >> 3);
            lo = m << 29;
            }
        String* out = hex8(hi);
        out.append(hex8(lo));
        return out;
        }

    String* hex8(u32 v)
        {
        string digits = "0123456789abcdef";
        String* out = String.withCString("");
        u32 shift = (u32)32;
        while (shift > (u32)0)
            {
            shift = shift - (u32)4;
            out.appendByte(digits[(v >> shift) & (u32)$F]);
            }
        return out;
        }

    Array* leBytes(i32 v, u32 width)
        {
        Array* out = new Array();
        u32 u = (u32)v;
        for (u32 i = (u32)0; i < width; i = i + (u32)1)
            {
            out.add((Object*)Number.with((u32)(u & (u32)$FF)));
            u = u >> 8;
            }
        return out;
        }

    // ── locals: snapshot, restore, merge ─────────────────────────────────
    // A local is an SSA VALUE, not a slot, so control flow is entirely a
    // question of which value a name holds on each incoming edge. Every join
    // and every loop header is that question asked once per name.

    Map* snapshot(void)
        {
        Map* out = new Map();
        Array* ks = _locals.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            {
            String* k = (String*)ks.get(i);
            out.set((Hashable*)k, _locals.get((Hashable*)k));
            }
        return out;
        }

    void restore(Map* snap)
        {
        _locals = new Map();
        Array* ks = snap.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            {
            String* k = (String*)ks.get(i);
            _locals.set((Hashable*)k, snap.get((Hashable*)k));
            }
        }

    // Names in SORTED order. Both implementations sort, for the same reason:
    // the phi ORDER is printed, so it has to be a property of the program and
    // not of a hash table.
    Array* sortedNames(Array* names)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* n = (String*)names.get(i);
            u32 at = out.count();
            for (u32 j = (u32)0; j < out.count(); j = j + (u32)1)
                {
                if (n.compare((String*)out.get(j)) < (i8)0)
                    {
                    at = j;
                    break;
                    }
                }
            out.insert(at, (Object*)n);
            }
        return out;
        }

    u32 blockIndex(IRBlock* b)
        {
        for (u32 i = (u32)0; i < _fn.blocks().count(); i = i + (u32)1)
            if ((IRBlock*)_fn.blocks().get(i) == b)
                return i;
        return (u32)$FFFFFFFF;
        }

    IRBlock* addBlock(String* name)
        {
        IRBlock* b = new IRBlock(name);
        _fn.addBlock(b);
        return b;
        }

    String* blockPrefix(void)
        {
        String* p = String.withCString("bb_");
        p.appendFormat("%ld", (i32)_fn.blocks().count());
        return p;
        }

    // Which locals a subtree ASSIGNS. A loop header needs a phi for each of
    // them before its body is lowered, because the body's value is not known
    // until afterwards.
    void collectAssigned(Node* n, Array* out)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        if (k == (u16)nkAssign && n.kidCount() > (u32)0 && n.kid((u32)0).kind() == (u16)nkIdent)
            {
            addUnique(out, n.kid((u32)0).name());
            }
        if ((k == (u16)nkPostfix || k == (u16)nkUnary) && n.kidCount() > (u32)0 && n.kid((u32)0).kind() == (u16)nkIdent && (isName(n.op(), "++") || isName(n.op(), "--")))
            {
            addUnique(out, n.kid((u32)0).name());
            }
        // A DECLARATION inside the body counts as an assignment: the name is
        // rebound every iteration, and if an outer scope already had one the
        // header needs a phi or the outer binding survives across the back
        // edge and the body reads the wrong value.
        if (k == (u16)nkVariableDecl)
            addUnique(out, n.name());
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            collectAssigned(n.kid(i), out);
        }

    void addUnique(Array* out, String* name)
        {
        if (name == 0)
            return;
        for (u32 i = (u32)0; i < out.count(); i = i + (u32)1)
            if (((String*)out.get(i)).equals(name))
                return;
        out.add((Object*)name);
        }

    // Merge N predecessor snapshots into `join`.
    //
    // The two-way form below is this with two entries, so `if`/`else` keeps
    // byte-identical output. A `try` needs the general one: its join is reached
    // from the guarded block, from every catch arm, and from the
    // no-arm-matched edge — at least three predecessors, which is why it
    // merged NOTHING before (private:docs/bugs/052).
    //
    // `base` is the binding set BEFORE the region. Every edge descends from it,
    // so every name in `base` has a value on each edge — which is what makes an
    // N-way phi well-formed. A name introduced INSIDE the region is out of
    // scope after it and is dropped rather than merged.
    void mergeAtJoinN(IRBlock* join, Array* snaps, Array* blocks, Map* base)
        {
        if (snaps.count() != blocks.count() || snaps.count() == (u32)0)
            return;
        Map* merged = new Map();
        Array* bk = base.allKeys();
        for (u32 i = (u32)0; i < bk.count(); i = i + (u32)1)
            {
            String* nm = (String*)bk.get(i);
            merged.set((Hashable*)nm, base.get((Hashable*)nm));
            }
        Array* names = new Array();
        for (u32 i = (u32)0; i < bk.count(); i = i + (u32)1)
            addUnique(names, (String*)bk.get(i));
        names = sortedNames(names);

        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* name = (String*)names.get(i);
            IRValue* first = (IRValue*)0;
            bool allSame = true;
            bool anyMissing = false;
            Array* perEdge = new Array();
            for (u32 e = (u32)0; e < snaps.count(); e = e + (u32)1)
                {
                Map* sn = (Map*)snaps.get(e);
                IRValue* v = (IRValue*)sn.get((Hashable*)name);
                if (v == (IRValue*)0)
                    v = (IRValue*)base.get((Hashable*)name);
                if (v == (IRValue*)0)
                    {
                    anyMissing = true;
                    e = snaps.count();
                    continue;
                    }
                perEdge.add((Object*)v);
                if (first == (IRValue*)0)
                    first = v;
                else if (v != first)
                    allSame = false;
                }
            if (anyMissing || allSame)
                continue;

            // Phi pairs follow each predecessor's index in the function — the
            // order the verifier walks predecessors in.
            Array* order = new Array();
            for (u32 e = (u32)0; e < blocks.count(); e = e + (u32)1)
                order.add((Object*)Number.withU32(e));
            for (u32 a = (u32)0; a + (u32)1 < order.count(); a = a + (u32)1)
                {
                for (u32 b2 = (u32)0; b2 + (u32)1 < order.count() - a; b2 = b2 + (u32)1)
                    {
                    u32 x = ((Number*)order.get(b2)).asU32();
                    u32 y = ((Number*)order.get(b2 + (u32)1)).asU32();
                    if (blockIndex((IRBlock*)blocks.get(x)) > blockIndex((IRBlock*)blocks.get(y)))
                        {
                        order.set(b2, (Object*)Number.withU32(y));
                        order.set(b2 + (u32)1, (Object*)Number.withU32(x));
                        }
                    }
                }

            IRInsn* phi = IRInsn.with(String.withCString("Phi"));
            IRValue* res = new IRValue(first.ty());
            phi.setRes(res);
            for (u32 o = (u32)0; o < order.count(); o = o + (u32)1)
                {
                u32 idx = ((Number*)order.get(o)).asU32();
                phi.add(IROperand.block((IRBlock*)blocks.get(idx)));
                phi.add(IROperand.useVal((IRValue*)perEdge.get(idx)));
                }
            join.addPhi(phi);
            merged.set((Hashable*)name, (Object*)res);
            }
        _locals = merged;
        }

    // The two arms of an `if` meet here. A name both sides agree on needs no
    // phi; one they disagree on gets a phi whose pairs are ordered by the
    // predecessor's index in the function, which is the order the verifier
    // walks predecessors in.
    void mergeAtJoin(IRBlock* join, Map* snapA, IRBlock* blockA,
                     Map* snapB, IRBlock* blockB, Map* base)
        {
        // Only the names bound BEFORE the region — what mergeAtJoinN already
        // does. Walking the union of both arms' names merged a local declared
        // inside an arm, out of scope at the join: two sibling-scope `bits`
        // (u64 and u32) became one dead phi of the wrong type and wasm32
        // refused the module (private:docs/bugs/132). Mirrors the reference.
        Array* names = new Array();
        Array* kb0 = base.allKeys();
        for (u32 i = (u32)0; i < kb0.count(); i = i + (u32)1)
            addUnique(names, (String*)kb0.get(i));
        names = sortedNames(names);
        Map* merged = new Map();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* name = (String*)names.get(i);
            IRValue* vA = (IRValue*)snapA.get((Hashable*)name);
            if (vA == (IRValue*)0)
                vA = (IRValue*)base.get((Hashable*)name);
            IRValue* vB = (IRValue*)snapB.get((Hashable*)name);
            if (vB == (IRValue*)0)
                vB = (IRValue*)base.get((Hashable*)name);
            if (vA == vB)
                {
                if (vA != 0)
                    merged.set((Hashable*)name, (Object*)vA);
                continue;
                }
            if (vA == 0 || vB == 0)
                {
                merged.set((Hashable*)name, (Object*)(vA == 0 ? vB : vA));
                continue;
                }
            bool aFirst = blockIndex(blockA) <= blockIndex(blockB);
            IRInsn* phi = IRInsn.with(String.withCString("Phi"));
            IRValue* res = new IRValue(vA.ty());
            phi.setRes(res);
            phi.add(IROperand.block(aFirst ? blockA : blockB));
            phi.add(IROperand.useVal(aFirst ? vA : vB));
            phi.add(IROperand.block(aFirst ? blockB : blockA));
            phi.add(IROperand.useVal(aFirst ? vB : vA));
            join.addPhi(phi);
            merged.set((Hashable*)name, (Object*)res);
            }
        _locals = merged;
        }

    // The truth of a `^` is its RECEIVER, not the pair and not the code word.
    // Every case falls out of that one choice: bound-and-alive is the object,
    // a dead target is a weak-zeroed 0, an unimplemented `optional` is a
    // forced 0, and a widened plain function is a `.text` address that never
    // dies. Testing CODE would have made the runtime zero TWO words for a `^`
    // and one for a `weak:T@`, which needs a kind tag on every side-table node.
    // A value whose IR type is a LAYOUT — `Agg(N)`. Its own function, not an
    // inline `hasPrefix`, because building the literal costs a frame slot at
    // every call site and `lowerUnary` is already within 100 bytes of the
    // 16 KB arm64 frame budget: inlining it there took the function over.
    bool isAggIr(String* t)
        {
        if (t == 0)
            return false;
        return t.hasPrefix(String.withCString("Agg("));
        }

    IRValue* lowerCondition(Node* e)
        {
        IRValue* v = lowerExpr(e);
        if (_failed || v == 0)
            return v;
        if (e.ty() == 0 || !isBoundSig(stripQual(e.ty())))
            return v;
        // The AST type is not enough on its own. Sema types a comparison as the
        // WIDENING OF ITS OPERANDS, not as bool — so `f == (Sink^)0` is itself
        // typed `^`, and this extracted a field from the Bool the comparison
        // had already produced. The result was garbage, which is why `==` and
        // `!=` were BOTH true on win64 (XG bug 022); arm64 tolerated the
        // malformed instruction and answered correctly, which is exactly what
        // made it look like a back-end bug. Extract only from a real aggregate.
        if (!isAggIr(v.ty()))
            return v;
        Array* eops = new Array();
        eops.add((Object*)IROperand.useVal(v));
        eops.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
        return emit(String.withCString("AggExtract"),
                    ptrTo(String.withCString("Void")), eops);
        }

    void lowerIf(Node* n)
        {
        IRValue* cond = lowerCondition(n.kid((u32)0));
        if (_failed)
            return;
        // The CONDITION is a full expression of its own, so whatever owned
        // temporaries it produced are released here — before the branch, while
        // control is still straight-line and they are certainly live.
        flushOwnedTemps();
        bool hasElse = n.kidCount() > (u32)2;

        String* prefix = blockPrefix();
        String* thenName = String.withString(prefix);
        thenName.appendCString("_then");
        IRBlock* thenB = addBlock(thenName);
        IRBlock* elseB = (IRBlock*)0;
        if (hasElse)
            {
            String* elseName = String.withString(prefix);
            elseName.appendCString("_else");
            elseB = addBlock(elseName);
            }
        String* joinName = String.withString(prefix);
        joinName.appendCString("_join");
        IRBlock* joinB = addBlock(joinName);

        IRBlock* predBlock = _blk;
        Map* entrySnap = snapshot();

        IRInsn* br = IRInsn.with(String.withCString("CondBranch"));
        br.add(IROperand.useVal(cond));
        br.add(IROperand.block(thenB));
        br.add(IROperand.block(hasElse ? elseB : joinB));
        _blk.setTerm(br);

        _blk = thenB;
        restore(entrySnap);
        _condDepth = _condDepth + (u32)1;
        lowerStmt(n.kid((u32)1));
        _condDepth = _condDepth - (u32)1;
        if (_failed)
            return;
        IRBlock* thenExit = _blk;
        Map* thenSnap = (Map*)0;
        if (thenExit.term() == 0)
            {
            thenSnap = snapshot();
            IRInsn* b = IRInsn.with(String.withCString("Branch"));
            b.add(IROperand.block(joinB));
            thenExit.setTerm(b);
            }

        Map* elseSnap = (Map*)0;
        IRBlock* elseExit = (IRBlock*)0;
        if (hasElse)
            {
            _blk = elseB;
            restore(entrySnap);
            _condDepth = _condDepth + (u32)1;
            lowerStmt(n.kid((u32)2));
            _condDepth = _condDepth - (u32)1;
            if (_failed)
                return;
            elseExit = _blk;
            if (elseExit.term() == 0)
                {
                elseSnap = snapshot();
                IRInsn* b = IRInsn.with(String.withCString("Branch"));
                b.add(IROperand.block(joinB));
                elseExit.setTerm(b);
                }
            }
        else
            {
            // No else: the fall-through edge into the join carries the entry
            // snapshot, because nothing on that side ran.
            elseSnap = entrySnap;
            elseExit = predBlock;
            }

        _blk = joinB;
        if (thenSnap != 0 && elseSnap != 0)
            mergeAtJoin(joinB, thenSnap, thenExit, elseSnap, elseExit, entrySnap);
        else if (thenSnap != 0)
            restore(thenSnap);
        else if (elseSnap != 0)
            restore(elseSnap);
        else
            {
            // Both arms diverged, so nothing branches here. The block SAYS it
            // is unreachable rather than being dropped — removing it orphans
            // the current block and an enclosing `if` then reports the orphan
            // as a live exit.
            joinB.setTerm(IRInsn.with(String.withCString("Unreachable")));
            }
        }

    // ── loops ────────────────────────────────────────────────────────────
    // `while` and the C-style `for` are the same shape: a header that tests,
    // a body that may fall through or jump, and an exit. The phis go in
    // before the body is lowered and their back-edge operand is patched in
    // afterwards — the body's value for a name is not knowable until then.
    Array* _loopHeaders;
    Array* _loopExits;
    Array* _loopSteps;       // Node@ or 0 — a `continue` re-runs it
    Array* _loopBreakBlocks; // Array@ per frame of IRBlock@
    Array* _loopBreakLocals; // Array@ per frame of Map@
    Array* _loopContBlocks;
    Array* _loopContLocals;
    Array* _loopArcDepth; // the scope depth each loop was entered at
    Array* _loopIdx;      // a for-in's index phi result, or 0
    Array* _loopIdxNext;  // …and the stepped value on each continue edge

    void lowerLoop(Node* n, bool isFor)
        {
        Node* initClause = (Node*)0;
        Node* condClause = (Node*)0;
        Node* stepClause = (Node*)0;
        Node* body = (Node*)0;
        if (isFor)
            {
            if (n.kid((u32)0).kidCount() > (u32)0)
                initClause = n.kid((u32)0).kid((u32)0);
            if (n.kid((u32)1).kidCount() > (u32)0)
                condClause = n.kid((u32)1).kid((u32)0);
            if (n.kid((u32)2).kidCount() > (u32)0)
                stepClause = n.kid((u32)2).kid((u32)0);
            body = n.kid((u32)3);
            // The statement's own scope frame, pushed BEFORE the init so the
            // init variable scopes to the loop (it may shadow an outer local
            // — finding #16) and a strong init local releases at the exit.
            pushArcScope();
            if (initClause != 0)
                {
                if (initClause.kind() == (u16)nkVariableDecl)
                    lowerStmt(initClause);
                else
                    lowerExpr(initClause);
                if (_failed)
                    {
                    popArcScope();
                    return;
                    }
                }
            }
        else
            {
            condClause = n.kid((u32)0);
            body = n.kid((u32)1);
            }

        String* prefix = blockPrefix();
        String* hn = String.withString(prefix);
        hn.appendCString(isFor ? "_for_header" : "_header");
        String* bn = String.withString(prefix);
        bn.appendCString(isFor ? "_for_body" : "_body");
        String* xn = String.withString(prefix);
        xn.appendCString(isFor ? "_for_exit" : "_exit");
        IRBlock* header = addBlock(hn);
        IRBlock* bodyB = addBlock(bn);
        IRBlock* exitB = addBlock(xn);
        // `for (...) : unroll` — record the HEADER so the IR unroller can raise
        // its budgets for this loop. The annotation was parsed and read by
        // nothing: it was a hook for the AST optimiser, and when that was
        // removed in phase-323 nobody reconnected it to the IR unroller that
        // replaced it. Only the C-style form carries it; `for … in` has no
        // annotation syntax, which is why this sits under isFor's blocks.
        if (isFor && n.hasFlag((u32)NF_UNROLL))
            _fn.addUnrollHeader(hn);

        IRBlock* preheader = _blk;
        Map* preSnap = snapshot();
        IRInsn* toHeader = IRInsn.with(String.withCString("Branch"));
        toHeader.add(IROperand.block(header));
        preheader.setTerm(toHeader);

        Array* assigned = new Array();
        collectAssigned(body, assigned);
        if (stepClause != 0)
            collectAssigned(stepClause, assigned);
        // Scan the CONDITION too: a side-effecting condition (`while (n-- > 0)`)
        // modifies a local that must be loop-carried, else it keeps its entry
        // value and the loop never terminates (bug 02). collectAssigned recurses
        // into the condition tree, so the postfix inside the compare is found.
        if (condClause != 0)
            collectAssigned(condClause, assigned);
        assigned = sortedNames(assigned);

        Array* phiNames = new Array();
        Array* phiInsns = new Array();
        Map* headerLocals = snapshot();
        seedHeaderPhis(assigned, preSnap, header, preheader, bodyB,
                       phiNames, phiInsns, headerLocals);

        _blk = header;
        restore(headerLocals);
        if (condClause != 0)
            {
            IRValue* cond = lowerCondition(condClause);
            if (_failed)
                {
                if (isFor)
                    popArcScope();
                return;
                }
            // A loop's CONDITION is a full expression, re-evaluated every
            // iteration, so whatever it owns is released each time round —
            // not accumulated until the loop exits.
            flushOwnedTemps();
            IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
            cb.add(IROperand.useVal(cond));
            cb.add(IROperand.block(bodyB));
            cb.add(IROperand.block(exitB));
            _blk.setTerm(cb);
            }
        else
            {
            IRInsn* b = IRInsn.with(String.withCString("Branch"));
            b.add(IROperand.block(bodyB));
            _blk.setTerm(b);
            }
        // The condition is lowered with _locals aliasing headerLocals in the
        // reference; a side-effecting condition (`while (n-- > 0)`) rebinds a
        // loop-carried local there, and the body must start from — and the back
        // edge must carry — that post-condition value, or the variable never
        // advances and the loop runs forever (bug 02). restore() copies rather
        // than aliases, so fold the post-condition bindings back into
        // headerLocals explicitly.
        headerLocals = snapshot();
        IRBlock* condExit = _blk;

        pushLoop(header, exitB, stepClause);
        _blk = bodyB;
        restore(headerLocals);
        _condDepth = _condDepth + (u32)1;
        lowerStmt(body);
        _condDepth = _condDepth - (u32)1;
        if (_failed)
            {
            popLoop();
            if (isFor)
                popArcScope();
            return;
            }
        if (_blk.term() == 0 && stepClause != 0)
            {
            lowerExpr(stepClause);
            if (_failed)
                {
                popLoop();
                if (isFor)
                    popArcScope();
                return;
                }
            }
        IRBlock* bodyExit = _blk;
        bool fellThrough = bodyExit.term() == 0;
        if (fellThrough)
            {
            IRInsn* b = IRInsn.with(String.withCString("Branch"));
            b.add(IROperand.block(header));
            bodyExit.setTerm(b);
            }

        rebuildHeaderPhis(phiNames, phiInsns, preSnap, preheader, bodyExit, fellThrough);

        Array* brkBlocks = (Array*)_loopBreakBlocks.get(_loopBreakBlocks.count() - (u32)1);
        Array* brkLocals = (Array*)_loopBreakLocals.get(_loopBreakLocals.count() - (u32)1);
        popLoop();

        _blk = exitB;
        bindLoopExit(exitB, condExit, condClause != 0, headerLocals, brkBlocks, brkLocals);
        if (isFor)
            {
            // Close the statement's scope: releases an init-declared strong
            // local here in the exit block (fall-out and breaks both land
            // here), and restores any binding the init shadowed.
            releaseTopScope();
            popArcScope();
            }
        }

    // `for (T v in arr)` over a fixed array. The count is known at compile
    // time, so this is an ordinary counted loop: an index phi, a bounds test,
    // and a load of the element at the top of the body.
    //
    // The base address is re-formed INSIDE the body rather than hoisted. That
    // keeps the array's own value live across whatever the body calls, which
    // is what lets a caller-save backend preserve the slot correctly.
    //
    // Any other collection — a slice, a heap pointer, a class that enumerates
    // itself — is SKIPPED, emitting nothing and letting the rest of the
    // function lower. That is what the original does with the shapes it does
    // not handle, and a port that stopped instead would disagree with it
    // about every function containing one.
    void lowerForIn(Node* n)
        {
        // The statement's own scope frame (the reference's wrapper): the loop
        // VARIABLE scopes to the loop — it may shadow an outer local (finding
        // #16) — and the retained Enumerable subject enrols here so it is
        // released at loop exit. A wrapper because the body soft-skips through
        // a dozen early returns, every one of which must still pop the frame.
        if (_failed)
            return;
        pushArcScope();
        Node* lv = n.kid((u32)0);
        saveShadow(lv.name());
        lowerForInInner(n);
        if (!_failed)
            releaseTopScope();
        popArcScope();
        }

    void lowerForInInner(Node* n)
        {
        Node* loopVar = n.kid((u32)0);
        Node* coll = n.kid((u32)1);
        if (loopVar.ty() == 0)
            return;
        // A class that ENUMERATES ITSELF answers two questions at run time —
        // how many, and which one — so the loop asks it, through its own
        // vtable. The counter is as wide as the count it reports: a 32-bit
        // library says u32, and assuming u16 would stop enumerating at 65536
        // without a word of complaint.
        ClassInfo* ci = classFor(pointeeOf(coll.ty()));
        if (ci != 0)
            {
            emitEnumerableForIn(loopVar, coll, n.kid((u32)2), ci);
            return;
            }
        // `for (v in arr[lo..hi])` — the same counted loop over a WINDOW,
        // over a fixed array or a heap allocation alike.
        if (coll.kind() == (u16)nkSlice)
            {
            emitSliceForIn(loopVar, coll, n.kid((u32)2));
            return;
            }
        // `for (v in buf)` where `buf = new T[N]`. A heap pointer carries no
        // length in its TYPE, so the count comes from the allocation that bound
        // the name — the same map the slice form already consults. Without this
        // the loop was dropped in silence: not lowered, not diagnosed, just
        // absent from the IR.
        if (coll.kind() == (u16)nkIdent && !isArrayLike(coll.ty()))
            {
            Object* hl = _heapArrayLen.get((Hashable*)coll.name());
            if (hl != 0)
                {
                String* eIr = irType(loopVar.ty());
                if (_failed)
                    return;
                IRValue* saved = _sliceLow;
                _sliceLow = (IRValue*)0;
                emitForInLoop(loopVar, n.kid((u32)2),
                              u16Const(((Number*)hl).asU32()), u16Const((u32)0),
                              String.withCString("u16"),
                              (IRValue*)0, (ClassInfo*)0, (u32)0, coll);
                _sliceLow = saved;
                return;
                }
            // Runtime-sized heap pointer: the count comes from the allocation
            // header via `_xtc_count`, same rule as `.length` (private:docs/bugs/045).
            // The CLASS case belongs to the Enumerable dispatch, not here.
            if (Types.isPointer(coll.ty()) && classFor(pointeeOf(coll.ty())) == 0 && _ptrW >= (u32)4)
                {
                IRValue* hv = lowerExpr(coll);
                if (_failed)
                    return;
                Array* cargs = new Array();
                cargs.add((Object*)hv);
                IRValue* cnt = emitMethodCall(runtimeHelper(String.withCString("_xtc_count")),
                                              (IRValue*)0, cargs,
                                              String.withCString("u16"), true);
                IRValue* saved = _sliceLow;
                _sliceLow = (IRValue*)0;
                emitForInLoop(loopVar, n.kid((u32)2), cnt, u16Const((u32)0),
                              String.withCString("u16"),
                              (IRValue*)0, (ClassInfo*)0, (u32)0, coll);
                _sliceLow = saved;
                return;
                }
            }
        if (coll.kind() != (u16)nkIdent || !isArrayLike(coll.ty()))
            return;
        String* elemIr = irType(loopVar.ty());
        if (_failed)
            return;
        emitCountedForIn(loopVar, coll, n.kid((u32)2), elemIr);
        }

    // The bound a slice counts from, live only while its loop is being
    // lowered. Zero for every other for-in, which is what makes the offset
    // disappear rather than being added as a zero.
    IRValue* _sliceLow;

    void emitSliceForIn(Node* loopVar, Node* slice, Node* body)
        {
        Node* coll = slice.kid((u32)0);
        String* u16T = String.withCString("u16");
        // A missing bound is ABSENT, not null, so `a[..hi]` carries its one
        // bound in the same place `a[lo..]` carries its one — and only the
        // flag says which end it is.
        bool openLow = slice.hasFlag((u32)NF_RANGE_HI);
        Node* loN = (Node*)0;
        Node* hiN = (Node*)0;
        if (slice.kidCount() > (u32)2)
            {
            loN = slice.kid((u32)1);
            hiN = slice.kid((u32)2);
            }
        else if (slice.kidCount() > (u32)1)
            {
            if (openLow)
                hiN = slice.kid((u32)1);
            else
                loN = slice.kid((u32)1);
            }
        IRValue* lo = (IRValue*)0;
        if (loN != 0)
            {
            lo = coerce(lowerExpr(loN), loN.ty(), u16T);
            if (_failed)
                return;
            }
        else
            {
            lo = u16Const((u32)0);
            }
        IRValue* hi = (IRValue*)0;
        if (hiN != 0)
            {
            hi = coerce(lowerExpr(hiN), hiN.ty(), u16T);
            if (_failed)
                return;
            }
        else
            {
            // An open END runs to the array's own length — which for a HEAP
            // allocation is the N the binding was made with, remembered where
            // `T@ p = new T[N]` was lowered.
            String* dt = declaredTypeOf(coll);
            u32 n = arrayCount(dt);
            if (n == (u32)0 && coll.kind() == (u16)nkIdent)
                {
                Object* hl = _heapArrayLen.get((Hashable*)coll.name());
                if (hl != 0)
                    n = ((Number*)hl).asU32();
                }
            hi = u16Const(n);
            }
        // `..` stops before its upper bound; `...` includes it, so the bound
        // moves up one BEFORE the subtraction rather than the count moving up
        // one after it.
        if (slice.hasFlag((u32)NF_INCLUSIVE))
            {
            Array* oo = new Array();
            oo.add((Object*)IROperand.useVal(hi));
            oo.add((Object*)IROperand.useVal(u16Const((u32)1)));
            hi = emit(String.withCString("Add"), String.withCString("U16"), oo);
            }
        Array* so = new Array();
        so.add((Object*)IROperand.useVal(hi));
        so.add((Object*)IROperand.useVal(lo));
        IRValue* count = emit(String.withCString("Sub"), String.withCString("U16"), so);
        IRValue* saved = _sliceLow;
        _sliceLow = lo;
        emitForInLoop(loopVar, body, count, u16Const((u32)0), u16T,
                      (IRValue*)0, (ClassInfo*)0, (u32)0, coll);
        _sliceLow = saved;
        }

    void emitEnumerableForIn(Node* loopVar, Node* coll, Node* body, ClassInfo* ci)
        {
        Node* lenM = methodNamed(ci.decl(), String.withCString("enumLength"));
        Node* atM = methodNamed(ci.decl(), String.withCString("enumAt"));
        Object* lenSlot = ci.methodSlot().get((Hashable*)String.withCString("enumLength"));
        Object* atSlot = ci.methodSlot().get((Hashable*)String.withCString("enumAt"));
        if (lenM == 0 || atM == 0 || lenSlot == 0 || atSlot == 0)
            return;
        String* idxTy = firstReturn(lenM.op());

        IRValue* recv = lowerExpr(coll);
        if (_failed)
            return;
        IRValue* count = emitDispatch(recv, ((Number*)lenSlot).asU32(), new Array(), idxTy);
        // A CALL as the subject hands back a +1 owned temp (private:docs/bugs/057).
        // This port used to leave it in _ownedTemps, and emitForInLoop's
        // in-body flush then released it EVERY ITERATION — an over-release
        // where the original merely leaked. Adopt it as the original now
        // does: consume the temp and bind a hidden strong local, so the
        // enclosing scope's teardown releases it once, an early `return`
        // releases it with the other enrolled locals, and the body flush is
        // left with its real job of releasing the element. An identifier
        // subject is borrowed and never in _ownedTemps.
        if (isOwnedTemp(recv))
            {
            consumeOwnedTemp(recv);
            String* subjName = String.withCString("__forin_subj_");
            subjName.append(String.withU32(_fn.blocks().count()));
            noteStrongLocal(subjName);
            _locals.set((Hashable*)subjName, (Object*)recv);
            }
        Array* zops = new Array();
        zops.add((Object*)IROperand.immI((i32)0, irType(idxTy)));
        IRValue* zero = emit(String.withCString("Const"), irType(idxTy), zops);
        emitForInLoop(loopVar, body, count, zero, idxTy, recv, ci,
                      ((Number*)atSlot).asU32(), (Node*)0);
        }

    String* declaredTypeOf(Node* e)
        {
        if (e.kind() == (u16)nkIdent)
            {
            Object* p = _pinAst.get((Hashable*)e.name());
            if (p != 0)
                return (String*)p;
            Object* l = _localTypes.get((Hashable*)e.name());
            if (l != 0)
                return (String*)l;
            Object* g = _globals.get((Hashable*)e.name());
            if (g != 0)
                return (String*)g;
            }
        return e.ty();
        }

    void emitCountedForIn(Node* loopVar, Node* coll, Node* body, String* elemIr)
        {
        IRValue* saved = _sliceLow;
        _sliceLow = (IRValue*)0;
        // The DECLARED type, not the mention's: `u8 a[] = { … }` is sized by
        // its initialiser, and only the declaration knows the number.
        IRValue* count = u16Const(arrayCount(declaredTypeOf(coll)));
        IRValue* zero = u16Const((u32)0);
        emitForInLoop(loopVar, body, count, zero, String.withCString("u16"),
                      (IRValue*)0, (ClassInfo*)0, (u32)0, coll);
        _sliceLow = saved;
        }

    void emitForInLoop(Node* loopVar, Node* body, IRValue* count, IRValue* zero,
                       String* idxTy, IRValue* recv, ClassInfo* ci, u32 atSlot,
                       Node* coll)
        {
        String* prefix = blockPrefix();
        String* hn = String.withString(prefix);
        hn.appendCString("_forin_header");
        String* bn = String.withString(prefix);
        bn.appendCString("_forin_body");
        String* xn = String.withString(prefix);
        xn.appendCString("_forin_exit");
        IRBlock* header = addBlock(hn);
        IRBlock* bodyB = addBlock(bn);
        IRBlock* exitB = addBlock(xn);

        IRBlock* preheader = _blk;
        Map* preSnap = snapshot();
        IRInsn* toHeader = IRInsn.with(String.withCString("Branch"));
        toHeader.add(IROperand.block(header));
        preheader.setTerm(toHeader);

        // The INDEX phi comes first — it is the loop's own state — and the
        // names the body assigns follow it in sorted order.
        IRInsn* idxPhi = IRInsn.with(String.withCString("Phi"));
        IRValue* idx = new IRValue(irType(idxTy));
        idxPhi.setRes(idx);
        idxPhi.add(IROperand.block(preheader));
        idxPhi.add(IROperand.useVal(zero));
        idxPhi.add(IROperand.block(bodyB));
        idxPhi.add(IROperand.useVal(zero));
        header.addPhi(idxPhi);

        Array* assigned = new Array();
        collectAssigned(body, assigned);
        assigned = sortedNames(assigned);
        Array* phiNames = new Array();
        Array* phiInsns = new Array();
        Map* headerLocals = snapshot();
        seedHeaderPhis(assigned, preSnap, header, preheader, bodyB,
                       phiNames, phiInsns, headerLocals);

        _blk = header;
        restore(headerLocals);
        IRInsn* cmp = IRInsn.with(String.withCString("ICmp"));
        cmp.setRes(new IRValue(String.withCString("Bool")));
        cmp.setPred(String.withCString("ULT"));
        cmp.add(IROperand.useVal(idx));
        cmp.add(IROperand.useVal(count));
        _blk.add(cmp);
        IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
        cb.add(IROperand.useVal(cmp.res()));
        cb.add(IROperand.block(bodyB));
        cb.add(IROperand.block(exitB));
        _blk.setTerm(cb);
        IRBlock* condExit = _blk;

        pushLoop(header, exitB, (Node*)0);
        _loopIdx.set(_loopIdx.count() - (u32)1, (Object*)idx);
        _blk = bodyB;
        restore(headerLocals);
        if (ci != 0)
            {
            Array* ea = new Array();
            ea.add((Object*)idx);
            IRValue* e = emitDispatch(recv, atSlot, ea, loopVar.ty());
            _locals.set((Hashable*)loopVar.name(), (Object*)e);
            _localTypes.set((Hashable*)loopVar.name(), (Object*)loopVar.ty());
            flushOwnedTemps();
            }
        else
            {
            // A SLICE starts part-way in, so the element index is the loop's
            // own counter plus the slice's lower bound. The counter still
            // starts at zero: the count is what shrank, not where it began.
            bindLoopElement(loopVar, coll, idx, irType(loopVar.ty()));
            }
        if (_failed)
            {
            popLoop();
            return;
            }
        lowerStmt(body);
        if (_failed)
            {
            popLoop();
            return;
            }

        Array* contIdx = (Array*)_loopIdxNext.get(_loopIdxNext.count() - (u32)1);
        Array* contBlk = (Array*)_loopContBlocks.get(_loopContBlocks.count() - (u32)1);
        closeCountedForIn(idxPhi, idx, zero, header, preheader, exitB, condExit,
                          phiNames, phiInsns, preSnap, headerLocals, contIdx, contBlk);
        }

    // Step the index, patch both sets of phis, and bind the exit.
    void closeCountedForIn(IRInsn* idxPhi, IRValue* idx, IRValue* zero,
                           IRBlock* header, IRBlock* preheader, IRBlock* exitB,
                           IRBlock* condExit, Array* phiNames, Array* phiInsns,
                           Map* preSnap, Map* headerLocals,
                           Array* contIdx, Array* contBlk)
        {
        IRValue* next = idx;
        bool fellThrough = _blk.term() == (IRInsn*)0;
        if (fellThrough)
            {
            Array* oo = new Array();
            oo.add((Object*)IROperand.immI((i32)1, idx.ty()));
            IRValue* one = emit(String.withCString("Const"), idx.ty(), oo);
            Array* aops = new Array();
            aops.add((Object*)IROperand.useVal(idx));
            aops.add((Object*)IROperand.useVal(one));
            next = emit(String.withCString("Add"), idx.ty(), aops);
            IRInsn* back = IRInsn.with(String.withCString("Branch"));
            back.add(IROperand.block(header));
            _blk.setTerm(back);
            }
        IRBlock* bodyExit = _blk;
        Array* ib = new Array();
        Array* iv = new Array();
        ib.add((Object*)preheader);
        iv.add((Object*)zero);
        if (fellThrough)
            {
            ib.add((Object*)bodyExit);
            iv.add((Object*)next);
            }
        for (u32 c = (u32)0; c < contIdx.count() && c < contBlk.count(); c = c + (u32)1)
            {
            ib.add(contBlk.get(c));
            iv.add(contIdx.get(c));
            }
        sortEdgesByBlock(ib, iv);
        rebuildPhi(idxPhi, ib, iv);
        rebuildHeaderPhis(phiNames, phiInsns, preSnap, preheader, bodyExit, fellThrough);

        Array* brkBlocks = (Array*)_loopBreakBlocks.get(_loopBreakBlocks.count() - (u32)1);
        Array* brkLocals = (Array*)_loopBreakLocals.get(_loopBreakLocals.count() - (u32)1);
        popLoop();
        _blk = exitB;
        bindLoopExit(exitB, condExit, true, headerLocals, brkBlocks, brkLocals);
        }

    // The base address is re-formed INSIDE the body rather than hoisted, which
    // keeps the array's own value live across whatever the body calls — what
    // lets a caller-save backend preserve the slot correctly.
    // A SLICE starts part-way in, so the element index is the loop's own
    // counter plus the slice's lower bound. The counter still starts at zero:
    // the count is what shrank, not where it began.
    IRValue* sliceIndex(IRValue* idx)
        {
        if (_sliceLow == 0)
            return idx;
        Array* ao = new Array();
        ao.add((Object*)IROperand.useVal(idx));
        ao.add((Object*)IROperand.useVal(_sliceLow));
        return emit(String.withCString("Add"), String.withCString("U16"), ao);
        }

    void bindLoopElement(Node* loopVar, Node* coll, IRValue* rawIdx, String* elemIr)
        {
        String* elemPtr = ptrTo(elemIr);
        // The BASE first, then the slice offset: the address is formed the way
        // any element access forms it, and the offset is part of the index.
        // A HEAP pointer is already the address — decaying it would take the
        // address of the SLOT holding the pointer instead, and index off that.
        // Same distinction every subscript makes.
        IRValue* base = isArrayLike(coll.ty())
                            ? decayArrayBase(coll, elemPtr)
                            : lowerExpr(coll);
        if (_failed)
            return;
        IRValue* idx = sliceIndex(rawIdx);
        Array* eops = new Array();
        eops.add((Object*)IROperand.useVal(base));
        eops.add((Object*)IROperand.useVal(idx));
        IRValue* ea = emit(String.withCString("ElementAddr"), elemPtr, eops);
        _locals.set((Hashable*)loopVar.name(), (Object*)loadThrough(ea, loopVar.ty()));
        _localTypes.set((Hashable*)loopVar.name(), (Object*)loopVar.ty());
        }

    // A phi per name the body assigns, placed BEFORE the body is lowered —
    // the header has to be able to name the loop-carried value while the body
    // that produces it is still being read. The back edge starts as a
    // placeholder and is patched once the body's value is known.
    void seedHeaderPhis(Array* assigned, Map* preSnap, IRBlock* header,
                        IRBlock* preheader, IRBlock* bodyB,
                        Array* phiNames, Array* phiInsns, Map* headerLocals)
        {
        for (u32 i = (u32)0; i < assigned.count(); i = i + (u32)1)
            {
            String* name = (String*)assigned.get(i);
            IRValue* entryVal = (IRValue*)preSnap.get((Hashable*)name);
            if (entryVal == 0)
                continue;
            IRInsn* phi = IRInsn.with(String.withCString("Phi"));
            IRValue* res = new IRValue(entryVal.ty());
            phi.setRes(res);
            phi.add(IROperand.block(preheader));
            phi.add(IROperand.useVal(entryVal));
            phi.add(IROperand.block(bodyB));
            phi.add(IROperand.useVal(entryVal));
            header.addPhi(phi);
            phiNames.add((Object*)name);
            phiInsns.add((Object*)phi);
            headerLocals.set((Hashable*)name, (Object*)res);
            }
        }

    // A header phi's operands are not knowable until the body has been
    // lowered: one edge from the preheader, one from the fall-through back
    // edge if the body reaches it, and one per `continue`. Ordered by block
    // index, which is the order the verifier walks predecessors in.
    void rebuildHeaderPhis(Array* phiNames, Array* phiInsns, Map* preSnap,
                           IRBlock* preheader, IRBlock* bodyExit, bool fellThrough)
        {
        Array* contBlocks = (Array*)_loopContBlocks.get(_loopContBlocks.count() - (u32)1);
        Array* contLocals = (Array*)_loopContLocals.get(_loopContLocals.count() - (u32)1);
        for (u32 i = (u32)0; i < phiNames.count(); i = i + (u32)1)
            {
            String* name = (String*)phiNames.get(i);
            IRInsn* phi = (IRInsn*)phiInsns.get(i);
            IRValue* entryVal = (IRValue*)preSnap.get((Hashable*)name);
            Array* blks = new Array();
            Array* vals = new Array();
            blks.add((Object*)preheader);
            vals.add((Object*)entryVal);
            if (fellThrough)
                {
                Object* v = _locals.get((Hashable*)name);
                blks.add((Object*)bodyExit);
                vals.add((Object*)(v == 0 ? (Object*)entryVal : v));
                }
            for (u32 c = (u32)0; c < contBlocks.count(); c = c + (u32)1)
                {
                Map* cl = (Map*)contLocals.get(c);
                Object* v = cl.get((Hashable*)name);
                blks.add(contBlocks.get(c));
                vals.add((Object*)(v == 0 ? (Object*)entryVal : v));
                }
            sortEdgesByBlock(blks, vals);
            rebuildPhi(phi, blks, vals);
            }
        }

    // The exit's locals come from the header, unless a `break` disagreed —
    // then the exit needs a phi of its own.
    void bindLoopExit(IRBlock* exitB, IRBlock* condExit, bool headerReachesExit,
                      Map* headerLocals, Array* brkBlocks, Array* brkLocals)
        {
        restore(headerLocals);
        if (brkBlocks.count() == (u32)0)
            return;
        Array* names = sortedNames(headerLocals.allKeys());
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* name = (String*)names.get(i);
            IRValue* headerVal = (IRValue*)headerLocals.get((Hashable*)name);
            Array* blks = new Array();
            Array* vals = new Array();
            if (headerReachesExit)
                {
                blks.add((Object*)condExit);
                vals.add((Object*)headerVal);
                }
            for (u32 b = (u32)0; b < brkBlocks.count(); b = b + (u32)1)
                {
                Map* bl = (Map*)brkLocals.get(b);
                Object* v = bl.get((Hashable*)name);
                blks.add(brkBlocks.get(b));
                vals.add((Object*)(v == 0 ? (Object*)headerVal : v));
                }
            if (vals.count() == (u32)0)
                continue;
            // Every edge agreeing means the value dominates the exit and no
            // phi is needed.
            bool allSame = true;
            IRValue* first = (IRValue*)vals.get((u32)0);
            for (u32 v = (u32)0; v < vals.count(); v = v + (u32)1)
                if ((IRValue*)vals.get(v) != first)
                    allSame = false;
            if (vals.count() <= (u32)1 || allSame)
                {
                if (first != 0)
                    _locals.set((Hashable*)name, (Object*)first);
                continue;
                }
            sortEdgesByBlock(blks, vals);
            IRInsn* phi = IRInsn.with(String.withCString("Phi"));
            IRValue* res = new IRValue(((IRValue*)vals.get((u32)0)).ty());
            phi.setRes(res);
            rebuildPhi(phi, blks, vals);
            exitB.addPhi(phi);
            _locals.set((Hashable*)name, (Object*)res);
            }
        }

    void sortEdgesByBlock(Array* blks, Array* vals)
        {
        for (u32 i = (u32)1; i < blks.count(); i = i + (u32)1)
            {
            u32 j = i;
            while (j > (u32)0 && blockIndex((IRBlock*)blks.get(j - (u32)1)) > blockIndex((IRBlock*)blks.get(j)))
                {
                Object* tb = blks.get(j - (u32)1);
                blks.set(j - (u32)1, blks.get(j));
                blks.set(j, tb);
                Object* tv = vals.get(j - (u32)1);
                vals.set(j - (u32)1, vals.get(j));
                vals.set(j, tv);
                j = j - (u32)1;
                }
            }
        }

    void rebuildPhi(IRInsn* phi, Array* blks, Array* vals)
        {
        phi.ops().removeAll();
        for (u32 i = (u32)0; i < blks.count(); i = i + (u32)1)
            {
            phi.add(IROperand.block((IRBlock*)blks.get(i)));
            phi.add(IROperand.useVal((IRValue*)vals.get(i)));
            }
        }

    // The in-flight error CHANNEL: one module-level slot holding the Error@
    // currently propagating, or null. The design called for a hidden trailing
    // out-parameter, but this IR has no alloca and locals are SSA values — a
    // caller has nowhere to put a slot whose address it would pass. The channel
    // has to be addressable storage, and a data global is the addressable
    // storage the IR has. It costs one load and a not-taken branch per checked
    // call, and no ABI change at all: a `throws` function keeps its signature.
    IRValue* errChannelAddr(void)
        {
        String* nm = String.withCString("__xtc_inflight_err");
        String* slotTy = String.withCString("Ptr(Void, unbanked)");
        if (!symbolExists(nm))
            _m.addSym(IRSymbol.dataGlobal(nm, slotTy));
        Array* ops = new Array();
        ops.add((Object*)IROperand.sym(nm));
        return emit(String.withCString("AddrOf"), slotTy, ops);
        }

    String* errSlotTy(void)
        {
        return String.withCString("Ptr(Void, unbanked)");
        }

    // `void main` became an I32 at the signature, so every exit from it —
    // including the ones that carry no value of their own — still has to hand
    // the process a status.
    bool fnIsIntMain(void)
        {
        return isName(_fn.name(), "main") && !isName(irType(_fnReturn), "Void");
        }

    // After a call to a `throws` function: read the channel and branch. Inside
    // a `try` a raised error goes to its handler; otherwise it PROPAGATES,
    // which means running this function's own teardown and returning with the
    // channel still set — the caller's own check then sees it.
    void emitErrorCheckAfterCall(void)
        {
        IRValue* slot = errChannelAddr();
        IRValue* cur = loadThroughIr(slot, errSlotTy());
        String* prefix = blockPrefix();
        String* rn = String.withString(prefix);
        rn.appendCString("_err_raised");
        String* on = String.withString(prefix);
        on.appendCString("_err_ok");
        IRBlock* raised = addBlock(rn);
        IRBlock* cont = addBlock(on);
        IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
        cb.add(IROperand.useVal(cur));
        cb.add(IROperand.block(raised));
        cb.add(IROperand.block(cont));
        _blk.setTerm(cb);
        _blk = raised;
        emitPropagate((IRValue*)0);
        _blk = cont;
        }

    // The raising path out of the current block: into the enclosing handler if
    // there is one, otherwise out of the function with the channel still set.
    void emitPropagate(IRValue* exempt)
        {
        if (_tryHandlers.count() > (u32)0)
            {
            IRInsn* b = IRInsn.with(String.withCString("Branch"));
            b.add(IROperand.block((IRBlock*)_tryHandlers.get(_tryHandlers.count() - (u32)1)));
            _blk.setTerm(b);
            return;
            }
        if (!_fnThrows)
            {
            giveUp(String.withCString("raising call with no try and no throws"));
            return;
            }
        // NOT flushOwnedTemps: an owned temporary the guarded statement made
        // is released by the statement that made it, on the path that reaches
        // its end. This path does not.
        _returning = exempt;
        releaseAlongExit();
        _returning = (IRValue*)0;
        IRInsn* r = IRInsn.with(String.withCString("Return"));
        // The returned VALUE is indeterminate on the raising path — the
        // caller's own check guarantees it is never read.
        if (fnIsIntMain())
            {
            Array* zops = new Array();
            zops.add((Object*)IROperand.immI((i32)0, String.withCString("I32")));
            r.add(IROperand.useVal(emit(String.withCString("Const"),
                                        String.withCString("I32"), zops)));
            }
        r.add(IROperand.useVal(_mem));
        _blk.setTerm(r);
        }

    void lowerThrow(Node* n)
        {
        if (!_fnThrows)
            {
            giveUp(String.withCString("throw in a function not declared throws"));
            return;
            }
        IRValue* err = lowerExpr(n.kid((u32)0));
        if (_failed)
            return;
        IRValue* slot = errChannelAddr();
        // Stored BEFORE the teardown: the error was built out of locals the
        // teardown is about to release.
        storeThrough(slot, err);
        emitPropagate(err);
        }

    // `try { … } catch (e) { … }`. The handler is an ordinary block that any
    // raising call in the guarded body branches to; it reads the channel into
    // the binder and CLEARS it, because the error has been handled and must
    // not keep propagating.
    void lowerTry(Node* n)
        {
        String* prefix = blockPrefix();
        String* hn = String.withString(prefix);
        hn.appendCString("_catch");
        String* jn = String.withString(prefix);
        jn.appendCString("_try_join");
        IRBlock* handler = new IRBlock(hn);
        IRBlock* join = new IRBlock(jn);

        // The handler is reachable from ANY raising call in the body, so the
        // memory token live there is the one from BEFORE the body — not
        // whatever the body happened to end on, which would not dominate it.
        IRValue* memAtTry = _mem;
        // private:docs/bugs/052: every edge into the join has to bring its bindings
        // with it. `base` is what was live before the guarded block — the
        // default for an edge that did not touch a name — and each exit
        // contributes a snapshot. Without this the join merged nothing and both
        // `v = f()` (success) and `v = d` (catch) were dropped.
        Map* baseSnap = snapshot();
        Array* edgeSnaps = new Array();
        Array* edgeBlocks = new Array();

        _tryHandlers.add((Object*)handler);
        lowerStmt(n.kid((u32)0));
        _tryHandlers.removeAt(_tryHandlers.count() - (u32)1);
        if (_failed)
            return;
        if (_blk.term() == (IRInsn*)0)
            {
            edgeSnaps.add((Object*)snapshot());
            edgeBlocks.add((Object*)_blk);
            IRInsn* b = IRInsn.with(String.withCString("Branch"));
            b.add(IROperand.block(join));
            _blk.setTerm(b);
            }

        _fn.addBlock(handler);
        _blk = handler;
        _mem = memAtTry;
        // The handler runs from the state BEFORE the guarded block: it is
        // reachable from any raising call inside it, so nothing the body bound
        // can be assumed.
        restore(baseSnap);
        IRValue* slot = errChannelAddr();
        IRValue* errVal = loadThroughIr(slot, errSlotTy());
        Array* nops = new Array();
        nops.add((Object*)IROperand.immI((i32)0, errSlotTy()));
        storeThrough(slot, emit(String.withCString("Const"), errSlotTy(), nops));

        for (u32 i = (u32)1; i < n.kidCount(); i = i + (u32)1)
            {
            Node* c = n.kid(i);
            if (c.kind() != (u16)nkCatch)
                continue;
            if (_failed)
                return;
            IRBlock* nextBlk = (IRBlock*)0;
            ClassInfo* ci = isName(c.op(), "-")
                                ? (ClassInfo*)0
                                : classFor(pointeeOf(c.op()));
            if (ci != 0)
                {
                // A TYPED arm runs only when the error really is that class,
                // and the failable downcast is the same RTTI check `(T@ ?)obj`
                // uses — so it works across a module boundary for free.
                Node* probe = Node.with((u16)nkCast);
                probe.setName(c.op());
                IRValue* cast = lowerDowncast(probe, errVal, true);
                if (_failed)
                    return;
                String* apfx = blockPrefix();
                String* an = String.withString(apfx);
                an.appendCString("_arm");
                String* nn = String.withString(apfx);
                nn.appendCString("_arm_next");
                IRBlock* armBlk = addBlock(an);
                nextBlk = addBlock(nn);
                IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
                cb.add(IROperand.useVal(cast));
                cb.add(IROperand.block(armBlk));
                cb.add(IROperand.block(nextBlk));
                _blk.setTerm(cb);
                _blk = armBlk;
                if (!isName(c.name(), "-"))
                    _locals.set((Hashable*)c.name(), (Object*)cast);
                }
            else
                {
                // An UNTYPED arm catches everything: no test, and nothing
                // after it can run.
                if (!isName(c.name(), "-"))
                    _locals.set((Hashable*)c.name(), (Object*)errVal);
                }
            pushArcScope();
            lowerStmt(c.kid((u32)0));
            if (_failed)
                return;
            if (_blk.term() == (IRInsn*)0)
                releaseTopScope();
            popArcScope();
            if (_blk.term() == (IRInsn*)0)
                {
                edgeSnaps.add((Object*)snapshot());
                edgeBlocks.add((Object*)_blk);
                IRInsn* b = IRInsn.with(String.withCString("Branch"));
                b.add(IROperand.block(join));
                _blk.setTerm(b);
                }
            if (nextBlk == 0)
                break;
            _blk = nextBlk;
            // The next arm is tested from the pre-try state too — an arm that
            // ran is not on the path to the arm after it.
            restore(baseSnap);
            }

        // Past every arm: the error matched none of them, so it keeps
        // propagating rather than being silently swallowed. Put it back on the
        // channel and take the path a raising call with no handler takes.
        if (_blk.term() == (IRInsn*)0)
            {
            storeThrough(slot, errVal);
            if (_tryHandlers.count() > (u32)0 || _fnThrows)
                {
                emitPropagate(errVal);
                }
            else
                {
                // Nowhere to send it. Rather than swallow it, fall through with
                // the channel set: the next checked call, or the program's end,
                // sees it.
                edgeSnaps.add((Object*)snapshot());
                edgeBlocks.add((Object*)_blk);
                IRInsn* b = IRInsn.with(String.withCString("Branch"));
                b.add(IROperand.block(join));
                _blk.setTerm(b);
                }
            }
        _fn.addBlock(join);
        _blk = join;
        mergeAtJoinN(join, edgeSnaps, edgeBlocks, baseSnap);
        }

    IRValue* lowerPropertyGet(Node* n)
        {
        IRValue* recv = lowerExpr(n.kid((u32)0));
        if (_failed)
            return (IRValue*)0;
        String* sym = String.withString(n.getterCls());
        sym.appendByte((u8)'$');
        sym.append(n.getter());
        return emitMethodCall(sym, recv, new Array(), n.ty(), true);
        }

    IRValue* lowerPropertySet(Node* n, Node* lhs)
        {
        IRValue* recv = lowerExpr(lhs.kid((u32)0));
        if (_failed)
            return (IRValue*)0;
        IRValue* v = lowerExpr(n.kid((u32)1));
        if (_failed)
            return (IRValue*)0;
        v = coerce(v, n.kid((u32)1).ty(), lhs.ty());
        String* sym = String.withString(n.setterCls());
        sym.appendByte((u8)'$');
        sym.append(n.setter());
        Array* args = new Array();
        args.add((Object*)v);
        emitMethodCall(sym, recv, args, String.withCString("void"), false);
        return v;
        }

    // A SWITCH is a chain of tests, not a jump table: one CondBranch per arm,
    // each falling to the next test, and the bodies laid out in source order
    // so a body with no terminator flows into the next one — which is what C
    // fall-through is. `break` leaves the switch; `continue` does not see it
    // at all, because a switch is not a loop.
    void lowerSwitch(Node* n)
        {
        IRValue* subj = lowerExpr(n.kid((u32)0));
        if (_failed)
            return;
        bool sgn = Types.isSigned(n.kid((u32)0).ty());
        Map* entryLocals = snapshot();

        Array* arms = new Array();
        for (u32 i = (u32)1; i < n.kidCount(); i = i + (u32)1)
            if (n.kid(i).kind() == (u16)nkCase)
                arms.add((Object*)n.kid(i));

        String* prefix = blockPrefix();
        Array* bodies = new Array();
        for (u32 i = (u32)0; i < arms.count(); i = i + (u32)1)
            {
            String* bn = String.withString(prefix);
            bn.appendFormat("_sw%ld", (i32)i);
            bodies.add((Object*)addBlock(bn));
            }
        String* xn = String.withString(prefix);
        xn.appendCString("_sw_exit");
        IRBlock* exitB = addBlock(xn);

        // The block that branches INTO each case body along its dispatch edge
        // (the matching test; the no-match branch for a default). A case a
        // preceding case falls through to has this AND a fall-through edge, and
        // the two are merged with phis in the bodies loop (c2xc 01).
        Array* dispatchPreds = new Array();
        for (u32 i = (u32)0; i < arms.count(); i = i + (u32)1)
            dispatchPreds.add((Object*)0);

        i32 defaultIdx = (i32)-1;
        for (u32 i = (u32)0; i < arms.count(); i = i + (u32)1)
            if (((Node*)arms.get(i)).hasFlag((u32)NF_DEFAULT) && defaultIdx < (i32)0)
                defaultIdx = (i32)i;

        pushLoop((IRBlock*)0, exitB, (Node*)0);

        for (u32 i = (u32)0; i < arms.count(); i = i + (u32)1)
            {
            Node* arm = (Node*)arms.get(i);
            if (arm.hasFlag((u32)NF_DEFAULT))
                continue;
            IRValue* match = (IRValue*)0;
            for (u32 li = (u32)0; li < arm.kidCount(); li = li + (u32)1)
                {
                Node* label = arm.kid(li);
                if (label.kind() != (u16)nkLabel)
                    continue;
                IRValue* m = caseLabelMatch(label, subj, sgn);
                if (_failed)
                    {
                    popLoop();
                    return;
                    }
                if (match == 0)
                    {
                    match = m;
                    continue;
                    }
                Array* oops = new Array();
                oops.add((Object*)IROperand.useVal(match));
                oops.add((Object*)IROperand.useVal(m));
                match = emit(String.withCString("Or"), String.withCString("Bool"), oops);
                }
            if (match == 0)
                continue;
            String* tn = String.withString(prefix);
            tn.appendFormat("_swt%ld", (i32)i);
            IRBlock* nextTest = addBlock(tn);
            dispatchPreds.set(i, (Object*)_blk);
            IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
            cb.add(IROperand.useVal(match));
            cb.add(IROperand.block((IRBlock*)bodies.get(i)));
            cb.add(IROperand.block(nextTest));
            _blk.setTerm(cb);
            _blk = nextTest;
            }

        u32 top = _loopHeaders.count() - (u32)1;
        Array* brkBlocks = (Array*)_loopBreakBlocks.get(top);
        Array* brkLocals = (Array*)_loopBreakLocals.get(top);
        IRBlock* noMatch = defaultIdx >= (i32)0 ? (IRBlock*)bodies.get((u32)defaultIdx) : exitB;
        if (noMatch == exitB)
            {
            brkBlocks.add((Object*)_blk);
            brkLocals.add((Object*)snapshot());
            }
        else
            {
            dispatchPreds.set((u32)defaultIdx, (Object*)_blk);
            }
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(noMatch));
        _blk.setTerm(br);

        // A case body has its dispatch edge (pre-switch locals) and, when the
        // previous case fell through, a fall-through edge (that case's exit
        // locals). Merge the two with phis at the body head so a local a
        // fell-through case modified is visible here; otherwise reset to
        // entryLocals (dispatch is the only edge). Without this the modified
        // local reverted to its pre-switch value in the next case (c2xc 01).
        IRBlock* prevExitBlock = (IRBlock*)0;
        Map* prevExitSnap = (Map*)0;
        bool prevFellThrough = false;
        for (u32 i = (u32)0; i < arms.count(); i = i + (u32)1)
            {
            _blk = (IRBlock*)bodies.get(i);
            if (i > (u32)0 && prevFellThrough)
                {
                Array* ftBlocks = new Array();
                ftBlocks.add((Object*)prevExitBlock);
                Array* ftLocals = new Array();
                ftLocals.add((Object*)prevExitSnap);
                bindLoopExit((IRBlock*)bodies.get(i), (IRBlock*)dispatchPreds.get(i),
                             true, entryLocals, ftBlocks, ftLocals);
                }
            else
                {
                restore(entryLocals);
                }
            Node* arm = (Node*)arms.get(i);
            for (u32 si = (u32)0; si < arm.kidCount(); si = si + (u32)1)
                {
                if (arm.kid(si).kind() == (u16)nkLabel)
                    continue;
                lowerStmt(arm.kid(si));
                if (_failed)
                    {
                    popLoop();
                    return;
                    }
                }
            if (_blk.term() != (IRInsn*)0)
                {
                prevFellThrough = false;
                continue;
                }
            IRInsn* f = IRInsn.with(String.withCString("Branch"));
            if (i + (u32)1 < arms.count())
                {
                prevExitBlock = _blk;
                prevExitSnap = snapshot();
                prevFellThrough = true;
                f.add(IROperand.block((IRBlock*)bodies.get(i + (u32)1)));
                }
            else
                {
                brkBlocks.add((Object*)_blk);
                brkLocals.add((Object*)snapshot());
                prevFellThrough = false;
                f.add(IROperand.block(exitB));
                }
            _blk.setTerm(f);
            }

        popLoop();
        _blk = exitB;
        bindLoopExit(exitB, exitB, false, entryLocals, brkBlocks, brkLocals);
        }

    // `case 3:` is an equality; `case 3..7:` is a pair of bounds ANDed, with
    // an open end simply leaving one of them out.
    IRValue* caseLabelMatch(Node* label, IRValue* subj, bool sgn)
        {
        if (!label.hasFlag((u32)NF_RANGE))
            {
            if (label.kidCount() == (u32)0)
                {
                giveUp(String.withCString("empty case label"));
                return (IRValue*)0;
                }
            return caseCmp(subj, String.withCString("EQ"), caseConst(label.kid((u32)0)));
            }
        // `case ..hi:` carries only the upper bound, and it is the FIRST kid —
        // the missing side is absent, not null, so the node itself has to say
        // which end it kept.
        IRValue* geLo = (IRValue*)0;
        IRValue* leHi = (IRValue*)0;
        if (label.kidCount() == (u32)2)
            {
            geLo = caseCmp(subj, String.withCString(sgn ? "SGE" : "UGE"), caseConst(label.kid((u32)0)));
            leHi = caseCmp(subj, String.withCString(sgn ? "SLE" : "ULE"), caseConst(label.kid((u32)1)));
            }
        else if (label.kidCount() == (u32)1)
            {
            if (label.hasFlag((u32)NF_RANGE_HI))
                leHi = caseCmp(subj, String.withCString(sgn ? "SLE" : "ULE"), caseConst(label.kid((u32)0)));
            else
                geLo = caseCmp(subj, String.withCString(sgn ? "SGE" : "UGE"), caseConst(label.kid((u32)0)));
            }
        if (_failed)
            return (IRValue*)0;
        if (geLo != 0 && leHi != 0)
            {
            Array* aops = new Array();
            aops.add((Object*)IROperand.useVal(geLo));
            aops.add((Object*)IROperand.useVal(leHi));
            return emit(String.withCString("And"), String.withCString("Bool"), aops);
            }
        return geLo != 0 ? geLo : leHi;
        }

    i32 caseConst(Node* e)
        {
        if (e.kind() == (u16)nkIdent)
            {
            Object* ev = _enumConsts.get((Hashable*)e.name());
            if (ev != 0)
                return (i32)((Number*)ev).asU32();
            }
        _constOk = true;
        i32 v = constEval(e);
        if (!_constOk)
            giveUp(String.withCString("case label is not a constant"));
        return v;
        }

    IRValue* caseCmp(IRValue* subj, String* pred, i32 k)
        {
        Array* cops = new Array();
        cops.add((Object*)IROperand.immI(k, subj.ty()));
        IRValue* kv = emit(String.withCString("Const"), subj.ty(), cops);
        IRInsn* c = IRInsn.with(String.withCString("ICmp"));
        c.setRes(new IRValue(String.withCString("Bool")));
        c.setPred(pred);
        c.add(IROperand.useVal(subj));
        c.add(IROperand.useVal(kv));
        _blk.add(c);
        return c.res();
        }

    void pushLoop(IRBlock* header, IRBlock* exitB, Node* step)
        {
        if (_loopHeaders == 0)
            {
            _loopHeaders = new Array();
            _loopExits = new Array();
            _loopSteps = new Array();
            _loopBreakBlocks = new Array();
            _loopBreakLocals = new Array();
            _loopContBlocks = new Array();
            _loopContLocals = new Array();
            _loopArcDepth = new Array();
            _loopIdx = new Array();
            _loopIdxNext = new Array();
            }
        _loopHeaders.add((Object*)header);
        _loopExits.add((Object*)exitB);
        _loopSteps.add((Object*)step);
        _loopBreakBlocks.add((Object*)new Array());
        _loopBreakLocals.add((Object*)new Array());
        _loopContBlocks.add((Object*)new Array());
        _loopContLocals.add((Object*)new Array());
        _loopArcDepth.add((Object*)Number.with(_arcScopes.count()));
        _loopIdx.add((Object*)0);
        _loopIdxNext.add((Object*)new Array());
        }

    void popLoop(void)
        {
        u32 n = _loopHeaders.count();
        if (n == (u32)0)
            return;
        _loopHeaders.removeAt(n - (u32)1);
        _loopExits.removeAt(n - (u32)1);
        _loopSteps.removeAt(n - (u32)1);
        _loopBreakBlocks.removeAt(n - (u32)1);
        _loopBreakLocals.removeAt(n - (u32)1);
        _loopContBlocks.removeAt(n - (u32)1);
        _loopContLocals.removeAt(n - (u32)1);
        _loopArcDepth.removeAt(n - (u32)1);
        _loopIdx.removeAt(n - (u32)1);
        _loopIdxNext.removeAt(n - (u32)1);
        }

    // ── statements ───────────────────────────────────────────────────────
    void lowerStmt(Node* n)
        {
        if (n == 0 || _failed)
            return;
        // A statement BOUNDARY. Each full-expression statement releases its own
        // +1 temporaries at its end, so this list is normally empty here.
        // Anything still in it came from a boundary that does not flush — a
        // loop or `if` CONDITION, or a `throw`'s operand — and is dropped
        // UNTRACKED rather than allowed to bleed into the next statement and be
        // released by it. A dropped temp leaks; releasing one that a later
        // statement did not create frees a live object.
        _ownedTemps = new Array();
        _ownedBlocks = new Array();
        u16 k = n.kind();
        if (k == (u16)nkBlock)
            {
            // A BLOCK is an ARC scope. What it owns is released when control
            // leaves it — unless control left by a terminator, which has
            // already run every enclosing scope's teardown on its way out.
            pushArcScope();
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                // Once the current block has a TERMINATOR, the rest of this
                // block cannot run — a `return` or `break` has already left.
                // Lowering it anyway emitted code nothing reaches, and not
                // merely a few dead instructions: a static call in it drags in
                // its init guard and its callee, so a library got linked into a
                // program that could never reach the call. The reference stops
                // here; the port did not, which is what tests/warn's
                // unreachable fixture caught through irwide-diff.
                // Dead code after a terminator (return/break/goto) is not
                // lowered — but a goto label starts a fresh REACHABLE block, so
                // it and code after it still must. Without goto there are no
                // such labels, so this is exactly the old stop-at-terminator.
                if (_blk.term() != 0 && n.kid(i).kind() != (u16)nkGotoLabel)
                    continue;
                lowerStmt(n.kid(i));
                }
            if (!_failed && _blk.term() == 0)
                releaseTopScope();
            popArcScope();
            return;
            }
        if (k == (u16)nkVariableDecl)
            {
            lowerVarDecl(n);
            if (!_failed)
                flushOwnedTemps();
            return;
            }
        // A struct declared inside a function is a TYPE, not a run of
        // statements: it names a shape and emits nothing.
        if (k == (u16)nkStructDecl)
            {
            _structs.set((Hashable*)n.name(), (Object*)n);
            return;
            }
        if (k == (u16)nkTypedefDecl)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                if (n.kid(i).kind() == (u16)nkStructDecl)
                    _structs.set((Hashable*)n.name(), (Object*)n.kid(i));
            return;
            }
        if (k == (u16)nkExprStatement)
            {
            if (n.kidCount() > (u32)0)
                lowerExpr(n.kid((u32)0));
            if (!_failed)
                flushOwnedTemps();
            return;
            }
        if (k == (u16)nkAsmBlock)
            {
            lowerAsm(n);
            return;
            }
        // `delete p` drops one reference. The runtime frees the block when
        // that was the last one, and runs the destructor on the way — so the
        // statement is exactly what a scope exit would have done, said early.
        if (k == (u16)nkDelete)
            {
            if (n.kidCount() == (u32)0)
                return;
            IRValue* p = lowerExpr(n.kid((u32)0));
            if (_failed)
                return;
            refOp(String.withCString("Release"), p);
            flushOwnedTemps();
            return;
            }
        if (k == (u16)nkDefer)
            {
            if (_deferScopes.count() == (u32)0)
                {
                giveUp(String.withCString("defer outside any scope"));
                return;
                }
            ((Array*)_deferScopes.get(_deferScopes.count() - (u32)1)).add((Object*)n);
            return;
            }
        if (k == (u16)nkThrow)
            {
            lowerThrow(n);
            return;
            }
        if (k == (u16)nkTry)
            {
            lowerTry(n);
            return;
            }
        if (k == (u16)nkSwitch)
            {
            lowerSwitch(n);
            return;
            }
        if (k == (u16)nkTupleAssign)
            {
            lowerTupleAssign(n);
            return;
            }
        if (k == (u16)nkForIn)
            {
            lowerForIn(n);
            return;
            }
        if (k == (u16)nkIf)
            {
            lowerIf(n);
            return;
            }
        if (k == (u16)nkWhile)
            {
            lowerLoop(n, false);
            return;
            }
        if (k == (u16)nkForCStyle)
            {
            lowerLoop(n, true);
            return;
            }
        if (k == (u16)nkBreak || k == (u16)nkContinue)
            {
            lowerJump(n, k);
            return;
            }
        if (k == (u16)nkGoto)
            {
            lowerGoto(n);
            return;
            }
        if (k == (u16)nkGotoLabel)
            {
            lowerGotoLabel(n);
            return;
            }
        if (k == (u16)nkReturn)
            {
            IRInsn* r = IRInsn.with(String.withCString("Return"));
            // SEVERAL values leave as ONE aggregate — the caller cannot be
            // handed two results. Each element still leaves at +1, exactly as
            // a lone return value does, and each is exempt from the teardown.
            if (n.kidCount() > (u32)1 && _fnRetAgg != 0)
                {
                Array* vals = new Array();
                for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                    {
                    IRValue* rv = lowerExpr(n.kid(i));
                    if (_failed)
                        return;
                    vals.add((Object*)rv);
                    }
                for (u32 i = (u32)0; i < vals.count(); i = i + (u32)1)
                    {
                    IRValue* rv = (IRValue*)vals.get(i);
                    // A returned weak-field READ is borrowed too and must be
                    // retained into the +1 tuple element (bug 036), so use the
                    // any-class-pointer predicate, not the strong-only one.
                    if (!isOwnedTemp(rv) && isPtrIr(rv.ty()) && isAnyClassPointer(n.kid(i).ty()) && !isStrongLocalValue(rv))
                        refOp(String.withCString("Retain"), rv);
                    }
                for (u32 i = (u32)0; i < vals.count(); i = i + (u32)1)
                    consumeOwnedTemp((IRValue*)vals.get(i));
                _returningMore = vals;
                flushOwnedTemps();
                releaseAlongExit();
                _returningMore = (Array*)0;
                Array* bops = new Array();
                for (u32 i = (u32)0; i < vals.count(); i = i + (u32)1)
                    bops.add((Object*)IROperand.useVal((IRValue*)vals.get(i)));
                r.add(IROperand.useVal(emit(String.withCString("AggBuild"), _fnRetAgg, bops)));
                r.add(IROperand.useVal(_mem));
                _blk.setTerm(r);
                return;
                }
            if (n.kidCount() > (u32)0)
                {
                // The value is computed, then the scope is torn down, and only
                // then is the result coerced — a release can run arbitrary
                // code, so it must not sit between the value and its use.
                IRValue* v = lowerExpr(n.kid((u32)0));
                if (_failed)
                    return;
                // Every class pointer LEAVES at +1. A value that is already
                // owned here — a call's result, or a strong local whose
                // ownership transfers — is one already; anything else was
                // borrowed and has to be retained. Before the teardown, which
                // is about to release whatever owns it.
                // The VALUE has to be a pointer, not merely the expression's
                // declared type: `return self == other` in a bool-returning
                // method has a comparison whose declared type is `Object@` —
                // its operand type — while what it produced is a Bool.
                // A weak-field read (`return weakField;`) is borrowed and the
                // return convention is +1 — retain it exactly like a strong
                // borrowed read (bug 036 / uxkit 036): the strong-only predicate
                // returned a weak field at +0 and the caller's release freed a
                // live object. isAnyClassPointer covers weak as well as strong.
                if (isAnyClassPointer(n.kid((u32)0).ty()) && isPtrIr(v.ty()) && !isOwnedTemp(v) && !isStrongLocalValue(v))
                    refOp(String.withCString("Retain"), v);
                // `return outer.inner;` PROJECTS a sub-struct out of a
                // containing local, so the local is not exempt and its
                // scope-exit teardown will release the projected fields —
                // freeing them out from under the caller. Retaining them
                // first makes the +1 travel and the teardown's release
                // balance back to what it was. A bare-identifier struct
                // return is an exempt move and needs none of this.
                if (n.kid((u32)0).kind() == (u16)nkMember && structDeclFor(n.kid((u32)0).ty()) != 0 && structHasStrongPointer(n.kid((u32)0).ty()))
                    {
                    IRValue* sa = aggregateAddr(n.kid((u32)0));
                    if (_failed)
                        return;
                    structFieldsAt(sa, n.kid((u32)0).ty(), false, true);
                    }
                _returning = v;
                // A struct local that IS the return value keeps its fields:
                // the +1 on each of them travels to the caller with the copy,
                // so releasing them here hands back a struct of dead pointers.
                if (n.kid((u32)0).kind() == (u16)nkIdent && _strongStruct.get((Hashable*)n.kid((u32)0).name()) != 0)
                    _returnExemptStruct = n.kid((u32)0).name();
                flushOwnedTemps();
                releaseAlongExit();
                _returnExemptStruct = (String*)0;
                _returning = (IRValue*)0;
                // A RETURN adjusts its value the way a call adjusts an
                // ARGUMENT — declared width against the return type's IR width
                // — and not the way an assignment coerces one. Same
                // distinction, same reason: a comparison's declared type is
                // its operand type, so returning `n == 0` as a bool truncates.
                v = coerceArg(v, n.kid((u32)0).ty(), _fnReturn);
                r.add(IROperand.useVal(v));
                }
            else
                {
                flushOwnedTemps();
                releaseAlongExit();
                // A bare `return;` in a `void main` still has to hand the
                // process a status, because main's declared void became an
                // i32 at the signature. Every other void function returns
                // nothing at all.
                if (!isName(irType(_fnReturn), "Void"))
                    r.add(IROperand.useVal(constOf((i64)0, _fnReturn)));
                }
            r.add(IROperand.useVal(_mem));
            _blk.setTerm(r);
            return;
            }
        giveUp(kindName(k, String.withCString("statement")));
        }

    // `(x, y) = f(...)` — the call hands back ONE aggregate, so the targets
    // are bound by taking it apart. The values arrive at +1, ownership already
    // transferred, so a strong target releases what it held and adopts this
    // one without a retain.
    void lowerTupleAssign(Node* n)
        {
        if (n.kidCount() < (u32)2)
            return;
        Node* src = n.kid(n.kidCount() - (u32)1);
        if (src.kind() != (u16)nkCall)
            {
            giveUp(String.withCString("tuple assign from a non-call"));
            return;
            }
        Object* d = _funcs.get((Hashable*)src.name());
        if (d == 0 || !isMultiReturn(((Node*)d).op()))
            {
            giveUp(String.withCString("tuple assign source returns one value"));
            return;
            }
        Node* decl = (Node*)d;
        String* agg = irReturnOf(decl);
        Array* parts = splitReturns(decl.op());

        Array* cargs = new Array();
        for (u32 i = (u32)0; i < src.kidCount(); i = i + (u32)1)
            {
            IRValue* a = lowerExpr(src.kid(i));
            if (_failed)
                return;
            cargs.add((Object*)a);
            }
        IRInsn* call = IRInsn.with(String.withCString("Call"));
        call.add(IROperand.sym(decl.sym() == 0 ? src.name() : decl.sym()));
        for (u32 i = (u32)0; i < cargs.count(); i = i + (u32)1)
            call.add(IROperand.useVal((IRValue*)cargs.get(i)));
        call.add(IROperand.useVal(_mem));
        IRValue* res = new IRValue(agg);
        call.setRes(res);
        IRValue* nextMem = new IRValue(String.withCString("Mem"));
        call.setMemRes(nextMem);
        call.setCc(String.withCString("CallConv::Standard"));
        _blk.add(call);
        _mem = nextMem;

        for (u32 i = (u32)0; i < n.kidCount() - (u32)1 && i < parts.count();
             i = i + (u32)1)
            {
            Array* eops = new Array();
            eops.add((Object*)IROperand.useVal(res));
            eops.add((Object*)IROperand.immI((i32)i, String.withCString("U16")));
            IRValue* fv = emit(String.withCString("AggExtract"),
                               irType((String*)parts.get(i)), eops);
            bindTupleTarget(n.kid(i), fv);
            if (_failed)
                return;
            }
        }

    void bindTupleTarget(Node* t, IRValue* fv)
        {
        if (t.kind() == (u16)nkVariableDecl)
            {
            // DECLARE it, then bind. The reference calls lowerVarDecl on the
            // target before binding the extracted field to the name, so a
            // target that is a new variable gets everything an ordinary local
            // declaration gets. Binding alone skipped that, and on xt6502 —
            // which zero-fills a declared local's slot — the reference emitted
            // `LDA #$00 / STA +N,SP` pairs the port did not.
            //
            // The VALUES were identical either way, since the AggExtract
            // overwrites the zero on the next instruction. Only a byte-for-byte
            // gate could see it, and only on a zero-filling target: arm64 was
            // clean throughout.
            lowerVarDecl(t);
            _localTypes.set((Hashable*)t.name(), (Object*)t.op());
            _locals.set((Hashable*)t.name(), (Object*)fv);
            return;
            }
        if (t.kind() != (u16)nkIdent)
            {
            giveUp(String.withCString("tuple target shape"));
            return;
            }
        Object* existing = _locals.get((Hashable*)t.name());
        if (existing == 0)
            {
            // An address-taken local lives in a frame SLOT, not in the SSA
            // map: the extracted field is stored the way a plain assignment
            // would store it.
            IRPinned* p = pinOf(t.name());
            if (p == 0)
                {
                String* w = String.withCString("tuple target ");
                w.append(t.name());
                giveUp(w);
                return;
                }
            IRValue* addr = pinAddrNamed(p, t.name());
            if (hasName(_strongLocals, t.name()))
                refOp(String.withCString("Release"),
                      loadThrough(addr, (String*)_pinAst.get((Hashable*)t.name())));
            storeThrough(addr, fv);
            return;
            }
        if (hasName(_strongLocals, t.name()))
            refOp(String.withCString("Release"), (IRValue*)existing);
        _locals.set((Hashable*)t.name(), (Object*)fv);
        }

    // A declaration either writes a frame slot or binds an SSA name. Which
    // one was settled by the pre-scan, before any of this ran.
    void lowerVarDecl(Node* n)
        {
        // A declaration REBINDS its name: save an outer binding first so the
        // scope's pop can restore it (finding #16), exactly as the reference
        // does at the top of lowerVarDecl:.
        if (!(n.hasFlag((u32)NF_STATIC) && !n.hasFlag((u32)NF_GLOBAL)))
            saveShadow(n.name());
        // A name declared more than once in a function has one slot per
        // declaration. Reaching a declaration moves the name onto the next of
        // them; every mention after it means that one.
        advancePinSlot(n);
        // A function-local `static` is backed by a persistent module GLOBAL,
        // not a frame slot: it keeps its value across calls and its
        // initialiser runs once, at load time, because the global's bytes are
        // written into the image rather than by code on entry. Registering it
        // under the local name routes every read and write through the paths a
        // global already has.
        if (n.hasFlag((u32)NF_STATIC) && !n.hasFlag((u32)NF_GLOBAL))
            {
            lowerStaticLocalDecl(n);
            return;
            }
        // `T@ p = new T[N]` — remember N against the NAME. `.length` reads it
        // back rather than the runtime header: it is what the binding was made
        // with, and a local reassigned since simply drops out.
        if (n.kidCount() > (u32)0 && n.kid((u32)0).kind() == (u16)nkNew)
            {
            Node* ne = n.kid((u32)0);
            if (ne.kidCount() > (u32)ne.num())
                {
                _constOk = true;
                i32 cnt = constEval(ne.kid((u32)0));
                if (_constOk && cnt >= (i32)0)
                    _heapArrayLen.set((Hashable*)n.name(), (Object*)Number.with((u32)cnt));
                }
            }
        // An auto-zeroing local is enrolled in the scope it is DECLARED in,
        // and its links are zeroed before anything can follow them.
        if (hasName(_weakLocals, n.name()))
            {
            weakLinkInit(n.name());
            noteStrongLocal(n.name());
            }
        // A struct local with an auto-zeroing FIELD needs its link words zeroed
        // too. An UNINITIALISED one already gets it for free — the whole-struct
        // zero-init walks every field, links included — so only the initialised
        // case is missing, and it is the one an aggregate COPY lands on.
        if (n.kidCount() > (u32)0)
            structWeakLinkInit(n.name(), n.op());
        // A PINNED declaration writes its slot: the address is formed
        // first, then the initialiser, then the store. There is no SSA
        // binding to make — the name IS the slot from here on.
        IRPinned* pin = pinOf(n.name());
        if (pin != 0)
            {
            // A STACK instance is made into an object here rather than
            // written: there is nothing to store, only a slot to prepare.
            // A STACK instance is made into an object here rather than
            // written — and `Gadget g(42)` is still one: its kids are
            // CONSTRUCTOR ARGUMENTS, which the analyser turns into an
            // explicit `init` call of its own right after. Only a kid that
            // yields the CLASS is a value to store.
            Object* vco = _valueClass.get((Hashable*)n.name());
            if (vco != 0 && (n.kidCount() == (u32)0 || !isName(stripQual(n.kid((u32)0).ty()), n.op().cString())))
                {
                setUpStackInstance(n.name(), (ClassInfo*)vco);
                return;
                }
            if (vco != 0 && n.kidCount() > (u32)0 && n.kid((u32)0).kind() == (u16)nkMethodCall && pin.ty().hasPrefix(String.withCString("Agg(")))
                {
                if (valueClassInit(n.kid((u32)0), pin, (ClassInfo*)vco))
                    return;
                if (_failed)
                    return;
                }
            if (n.kidCount() == (u32)0)
                {
                // An AGGREGATE cannot be zero-initialised by one Const —
                // there is no scalar constant of an Agg — so the slot is
                // simply left unwritten; sema requires a write before any
                // field is read. A scalar slot takes a Const #0.
                // The SLOT's type, not the declared one: an auto-zeroing
                // pointer's slot is the whole [prev, next, payload], and an
                // aggregate has no scalar zero to store.
                if (pin.ty().hasPrefix(String.withCString("Agg(")))
                    {
                    if (isArrayLike(n.op()) && isWeakSlot(elementOf(n.op())))
                        {
                        zeroWeakArrayLinks(pin, n.op());
                        noteStrongLocal(n.name());
                        }
                    if (_strongArray.get((Hashable*)n.name()) != 0)
                        {
                        strongArrayARC(n.name(), true);
                        noteStrongLocal(n.name());
                        }
                    if (_strongStruct.get((Hashable*)n.name()) != 0)
                        {
                        structFieldARC(n.name(), true);
                        noteStrongLocal(n.name());
                        }
                    return;
                    }
                IRValue* a = pinAddr(pin);
                Array* zops = new Array();
                zops.add((Object*)IROperand.immI((i32)0, pin.ty()));
                IRValue* z = emit(String.withCString("Const"), pin.ty(), zops);
                storeThrough(a, z);
                return;
                }
            bool wasRange = n.kid((u32)0).kind() == (u16)nkRange;
            Node* ini = expandRange(n.kid((u32)0), n.op());
            if (_failed)
                return;
            // An AGGREGATE's byte-list writes elements or fields; a scalar's
            // with a runtime entry writes bytes. Both form their own address,
            // so neither goes through the scalar store below.
            if (ini.kind() == (u16)nkBlock && (isArrayLike(n.op()) || structDeclFor(n.op()) != 0))
                {
                // A RANGE names the array by its bare name, which DECAYS —
                // the address comes out typed as a pointer to the element, so
                // there is nothing to re-cast.
                lowerAggregateByteList(
                    wasRange && isArrayLike(n.op()) ? arrayDecayAddr(n.name(), pin)
                                                    : pinAddr(pin),
                    n.op(), ini);
                return;
                }
            if (ini.kind() == (u16)nkBlock && byteListStorable(n.op()) && !byteListAllConstant(ini))
                {
                lowerScalarByteListStores(ini, pin, n.op());
                return;
                }
            // A strong STRUCT is enrolled for teardown whether or not it was
            // initialised here: what it owns at scope exit is the question,
            // and an initialised one owns just as much.
            if (_strongStruct.get((Hashable*)n.name()) != 0)
                noteStrongLocal(n.name());
            IRValue* a = pinAddrNamed(pin, n.name());
            IRValue* pv = (IRValue*)0;
            if (ini.kind() == (u16)nkBlock)
                {
                pv = lowerScalarByteList(ini, n.op());
                }
            else
                {
                pv = lowerExpr(ini);
                if (_failed)
                    return;
                pv = coerce(pv, ini.ty(), n.op());
                }
            if (_failed)
                return;
            storeThrough(a, pv);
            // `S b = a;` copied a whole struct, link words and all, without
            // linking the destination — so the copy tested true after its
            // referent died.
            relinkWeakSlotsAfterCopy(a, n.op());
            // The slot's address is formed again rather than reused: the
            // register runs as its own step, and so reads the slot the same
            // way any later access would.
            //
            // It is NOT formed when nothing is registered. A statically-widened
            // function needs no entry — its recv word is a code address that
            // never dies — and forming the address for a registration that does
            // not happen leaves an AddrOf + FieldAddr nothing consumes. This
            // used to form it regardless, to match the reference, which had the
            // same dead pair; the reference stopped emitting it (bug 087) and
            // this is the matching half.
            if (isBoundSig(stripQual(n.op())))
                {
                if (!isWidenedFn(ini))
                    registerBoundPair(pinAddrNamed(pin, n.name()), pv, n.op());
                }
            else if (isWeakClassPtr(n.op()))
                {
                // A `weak:T@` LOCAL is enrolled the same way an ivar is: the
                // side table learns the (referent → slot) pair so the slot
                // reads null the moment the referent dies. Unregister first,
                // because the slot may already be on a chain.
                IRValue* slotA = pinAddrNamed(pin, n.name());
                weakOp(String.withCString("WeakUnregister"), slotA, (IRValue*)0);
                weakOp(String.withCString("WeakRegister"), slotA, pv);
                // A weak local owns nothing: a +1 initialiser the store adopted
                // must be released here, after the register, or it leaks — the
                // slot is only unregistered at scope exit, never released (bug
                // 153). Release lands after WeakRegister so the auto-zero nils
                // the slot if this was the last strong reference. Borrowed owns
                // nothing.
                if (ini != 0 && !rhsIsBorrowed(ini))
                    refOp(String.withCString("Release"), pv);
                }
            return;
            }
        if (n.kidCount() == (u32)0)
            {
            // No initialiser and no slot: bind the name to a zero of its
            // declared type, so a read before the first write is defined.
            // A pointer's zero is a null it has to be CAST to — an IntToPtr
            // of a u16 zero, not a Const with a pointer type.
            String* dt = n.op();
            IRValue* z = (IRValue*)0;
            if (Types.isPointer(dt))
                {
                Array* cops = new Array();
                cops.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
                IRValue* c = emit(String.withCString("Const"), String.withCString("U16"), cops);
                Array* iops = new Array();
                iops.add((Object*)IROperand.useVal(c));
                z = emit(String.withCString("IntToPtr"), irType(dt), iops);
                }
            else
                {
                Array* cops = new Array();
                cops.add((Object*)IROperand.immI((i32)0, irType(dt)));
                z = emit(String.withCString("Const"), irType(dt), cops);
                }
            if (_failed)
                return;
            // An uninitialised strong slot still OWNS whatever it is later
            // given, so it is enrolled here — and its null start is what makes
            // the first release-of-old a no-op rather than a free of whatever
            // the stack happened to hold.
            if (isClassPointer(dt))
                noteStrongLocal(n.name());
            _locals.set((Hashable*)n.name(), (Object*)z);
            _localTypes.set((Hashable*)n.name(), (Object*)dt);
            return;
            }
        // An all-constant byte-list needs no storage at all: it IS a Const.
        if (n.kid((u32)0).kind() == (u16)nkBlock)
            {
            IRValue* blv = lowerScalarByteList(n.kid((u32)0), n.op());
            if (_failed)
                return;
            _locals.set((Hashable*)n.name(), (Object*)blv);
            _localTypes.set((Hashable*)n.name(), (Object*)n.op());
            return;
            }
        IRValue* v = lowerExpr(n.kid((u32)0));
        if (_failed)
            return;
        v = coerce(v, n.kid((u32)0).ty(), n.op());
        // A strong slot OWNS what it holds. `new T()` transfers a +1 the slot
        // adopts, so it needs no Retain; every other initialiser borrows, and
        // a borrowed reference has to be retained or the slot outlives it.
        if (isClassPointer(n.op()))
            {
            // The retain is on the RIGHT-HAND SIDE's own type, not the slot's.
            // Since task #25, `va_arg(ap, Object*)` types as `Object*` (a
            // borrowed reference from the caller's frame, retained here like
            // any other); only an UNTYPED `va_arg_ptr` still yields `u8@` —
            // bytes, with no reference to take a claim on.
            if (rhsIsBorrowed(n.kid((u32)0)))
                {
                if (isAnyClassPointer(n.kid((u32)0).ty()))
                    refOp(String.withCString("Retain"), v);
                }
            else
                {
                consumeOwnedTemp(v);
                }
            noteStrongLocal(n.name());
            }
        // The local now REFERENCES this value, so it adopts it even when the
        // slot is not a strong class pointer — `Box b = new Box()`, where `b`
        // is declared `Box` and not `Box@`. Releasing it at the end of the
        // statement would free something the next line reads; for a non-strong
        // slot the worst case the other way is a leak.
        consumeOwnedTemp(v);
        _locals.set((Hashable*)n.name(), (Object*)v);
        _localTypes.set((Hashable*)n.name(), (Object*)n.op());
        }

    // The module symbol a global NAME stands for. Ordinarily itself; for a
    // function-local `static` the mangled one that keeps it apart from every
    // other function's local of the same name.
    String* globalSymName(String* name)
        {
        Object* m = _staticLocalName.get((Hashable*)name);
        return m == 0 ? name : (String*)m;
        }

    void clearStaticLocals(void)
        {
        if (_staticLocalName == 0)
            {
            _staticLocalName = new Map();
            return;
            }
        Array* ks = _staticLocalName.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            _globals.remove((Hashable*)(String*)ks.get(i));
        _staticLocalName = new Map();
        }

    void lowerStaticLocalDecl(Node* n)
        {
        String* mangled = String.withCString("__sl_");
        mangled.appendFormat("%lu_", _staticLocals);
        mangled.append(n.name());
        _staticLocals = _staticLocals + (u32)1;
        IRSymbol* g = IRSymbol.dataGlobal(mangled, irType(n.op()));
        if (n.kidCount() > (u32)0)
            {
            _constOk = true;
            i32 v = constEval(n.kid((u32)0));
            if (_constOk)
                g.setBytes(leBytes(v, astWidth(n.op())));
            }
        _m.addSym(g);
        _globals.set((Hashable*)n.name(), (Object*)n.op());
        _staticLocalName.set((Hashable*)n.name(), (Object*)mangled);
        }

    // ── inline assembly ──────────────────────────────────────────────────
    // The body is OPAQUE to the IR: it goes into the module's constant pool as
    // text and the instruction carries a reference to it, so nothing between
    // here and the backend has to understand a word of it. What the lowering
    // DOES have to do is bind names — an identifier naming a pinned local
    // becomes a `{{XTLOCAL:n}}` token the backend resolves to that local's
    // storage. Without it the name leaks as an undefined symbol and assembles
    // to address zero, silently.
    void lowerAsm(Node* n)
        {
        String* joined = String.withCString("");
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            {
            if (i > (u32)0)
                joined.appendByte((u8)10);
            joined.append(n.kid(i).name());
            }
        String* text = bindAsmNames(joined);
        if (_failed)
            return;

        Array* bytes = new Array();
        for (u32 i = (u32)0; i < text.byteLength(); i = i + (u32)1)
            bytes.add((Object*)Number.with((u32)text.byteAt(i)));
        u32 cid = _m.addConst(bytes);

        IRInsn* a = IRInsn.with(String.withCString("Asm"));
        a.add(IROperand.cpool(cid));
        // The clobber mask. -1 is "unstated", which is what a body that does
        // not declare one means, and every body in this slice.
        a.add(IROperand.immI((i32)-1, String.withCString("I16")));
        a.add(IROperand.useVal(_mem));
        IRValue* nm = new IRValue(String.withCString("Mem"));
        a.setMemRes(nm);
        _blk.add(a);
        _mem = nm;
        }

    String* bindAsmNames(String* src)
        {
        String* out = String.withCString("");
        u32 i = (u32)0;
        while (i < src.byteLength())
            {
            u8 c = src.byteAt(i);
            if (c == (u8)';')
                {
                // A comment runs to end of line and is copied verbatim.
                while (i < src.byteLength())
                    {
                    u8 d = src.byteAt(i);
                    out.appendByte(d);
                    i = i + (u32)1;
                    if (d == (u8)10)
                        break;
                    }
                continue;
                }
            if (!isIdentStart(c))
                {
                out.appendByte(c);
                i = i + (u32)1;
                continue;
                }
            u32 start = i;
            while (i < src.byteLength() && isIdentChar(src.byteAt(i)))
                i = i + (u32)1;
            String* ident = src.substringBytes(start, i - start);
            IRPinned* p = pinOf(ident);
            if (p == 0)
                {
                out.append(asmBinding(ident));
                continue;
                }
            // A byte-extraction operator right before a SCALAR local selects
            // one byte of its VALUE, and the token has to say which. An ARRAY
            // local decays to its ADDRESS, so `<buf` is the low byte of that
            // address — the ordinary `#<symbol` immediate the plain token
            // already produces. Treating an array like a scalar hands the
            // pointer buf[0..1] instead of &buf.
            i32 sel = _arrayElem.get((Hashable*)ident) != 0
                          ? (i32)-1
                          : byteSelectAtEnd(out);
            if (sel >= (i32)0)
                {
                // Drop the operator, the whitespace before it and a preceding
                // `#` immediate marker, then re-separate the mnemonic from
                // the token.
                u32 cut = endOfText(out);
                cut = cut - (sel == (i32)3 ? (u32)3 : (sel == (i32)2 ? (u32)2 : (u32)1));
                if (cut > (u32)0 && out.byteAt(cut - (u32)1) == (u8)'#')
                    cut = cut - (u32)1;
                out = out.substringBytes((u32)0, cut);
                if (out.byteLength() > (u32)0 && out.byteAt(out.byteLength() - (u32)1) != (u8)' ' && out.byteAt(out.byteLength() - (u32)1) != (u8)9)
                    out.appendByte((u8)' ');
                out.appendCString("{{XTLOCALB:");
                out.appendFormat("%lu:%ld", printIdOf(p.val()), sel);
                out.appendCString("}}");
                continue;
                }
            out.appendCString("{{XTLOCAL:");
            out.appendFormat("%lu", printIdOf(p.val()));
            out.appendCString("}}");
            }
        return out;
        }

    // A name in an asm body that is NOT a pinned local. Four things it can
    // still be, and each becomes something the assembler can write down:
    //
    //   `__self`          the receiver pointer, staged the way a local is
    //   a bare IVAR       of a STATIC class, whose fields live in the
    //                     class's own `__sdata_` block rather than in an
    //                     instance — the name would otherwise leak as an
    //                     undefined symbol and assemble to $0000
    //   `_ivar_<C>_<F>`   any class's field OFFSET, as a literal
    //   `_sizeof_<C>`     any class's instance SIZE, as a literal
    //
    // Anything else is an opcode, a label or a symbol, and passes through.
    String* asmBinding(String* ident)
        {
        if (isName(ident, "__self") && _self != 0)
            {
            String* t = String.withCString("{{XTLOCAL:");
            t.appendFormat("%lu", printIdOf(_self));
            t.appendCString("}}");
            return t;
            }
        if (_staticSelfClass != 0 && _curClass != 0)
            {
            Object* idx = _curClass.ivarIndex().get((Hashable*)ident);
            if (idx != 0)
                {
                String* t = String.withCString("{{XTIVAR:");
                t.appendFormat("%lu:%lu", symbolIndexOf(staticDataSymbol(_curClass)),
                               ivarByteOffset(_curClass, ((Number*)idx).asU32()));
                t.appendCString("}}");
                return t;
                }
            }
        if (ident.hasPrefix(String.withCString("_sizeof_")))
            {
            ClassInfo* ci = classFor(ident.substringFromByte((u32)8));
            if (ci != 0)
                {
                String* t = String.withCString("");
                t.appendFormat("%lu", layoutSizeOf(ci.agg()));
                return t;
                }
            }
        if (ident.hasPrefix(String.withCString("_ivar_")))
            {
            String* rest = ident.substringFromByte((u32)6);
            // The class name runs to the LAST underscore, so a field whose
            // own name has one still parses when the class name does not.
            for (u32 k = rest.byteLength(); k > (u32)0; k = k - (u32)1)
                {
                if (rest.byteAt(k - (u32)1) != (u8)'_')
                    continue;
                ClassInfo* ci = classFor(rest.substringBytes((u32)0, k - (u32)1));
                if (ci == 0)
                    continue;
                Object* idx = ci.ivarIndex().get((Hashable*)rest.substringFromByte(k));
                if (idx == 0)
                    continue;
                String* t = String.withCString("");
                t.appendFormat("%lu", ivarByteOffset(ci, ((Number*)idx).asU32()));
                return t;
                }
            }
        return ident;
        }

    u32 symbolIndexOf(String* name)
        {
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1)
            if (((IRSymbol*)_m.syms().get(i)).name().equals(name))
                return i;
        return (u32)0;
        }

    u32 ivarByteOffset(ClassInfo* ci, u32 fieldIndex)
        {
        String* agg = ci.agg();
        u32 id = (u32)0;
        for (u32 i = (u32)4; i < agg.byteLength(); i = i + (u32)1)
            {
            u8 c = agg.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                break;
            id = id * (u32)10 + (u32)(c - (u8)'0');
            }
        if (id >= _m.layouts().count())
            return (u32)0;
        return ((IRLayout*)_m.layouts().get(id)).offsetAt(fieldIndex);
        }

    // Which byte a trailing `<` / `>` / `>>` / `>>>` selects, or -1 for none.
    i32 byteSelectAtEnd(String* s)
        {
        u32 e = endOfText(s);
        if (e == (u32)0)
            return (i32)-1;
        if (e >= (u32)3 && s.byteAt(e - (u32)1) == (u8)'>' && s.byteAt(e - (u32)2) == (u8)'>' && s.byteAt(e - (u32)3) == (u8)'>')
            return (i32)3;
        if (e >= (u32)2 && s.byteAt(e - (u32)1) == (u8)'>' && s.byteAt(e - (u32)2) == (u8)'>')
            return (i32)2;
        if (s.byteAt(e - (u32)1) == (u8)'>')
            return (i32)1;
        if (s.byteAt(e - (u32)1) == (u8)'<')
            return (i32)0;
        return (i32)-1;
        }

    u32 endOfText(String* s)
        {
        u32 i = s.byteLength();
        while (i > (u32)0 && (s.byteAt(i - (u32)1) == (u8)' ' || s.byteAt(i - (u32)1) == (u8)9))
            i = i - (u32)1;
        return i;
        }

    // The number the printer will give this value. Params come first, then the
    // pinned locals — so both are known before a single instruction is
    // numbered, which is what lets an asm body name one.
    u32 printIdOf(IRValue* v)
        {
        u32 next = (u32)0;
        for (u32 i = (u32)0; i < _fn.params().count(); i = i + (u32)1)
            {
            if ((IRValue*)_fn.params().get(i) == v)
                return next;
            next = next + (u32)1;
            }
        for (u32 i = (u32)0; i < _fn.pinned().count(); i = i + (u32)1)
            {
            if (((IRPinned*)_fn.pinned().get(i)).val() == v)
                return next;
            next = next + (u32)1;
            }
        // …and an ordinary INSTRUCTION result, which an asm body can also
        // name: a static method's `__self` is the AddrOf of the class's own
        // storage block, and that is an instruction like any other. Counted
        // the way the printer counts, so the number the body carries is the
        // number the text will show.
        for (u32 b = (u32)0; b < _fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)_fn.blocks().get(b);
            for (u32 i = (u32)0; i < blk.phis().count(); i = i + (u32)1)
                {
                IRInsn* ph = (IRInsn*)blk.phis().get(i);
                if (ph.res() == v)
                    return next;
                if (ph.res() != 0)
                    next = next + (u32)1;
                }
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                {
                IRInsn* ins = (IRInsn*)blk.insns().get(i);
                if (ins.res() == v)
                    return next;
                if (ins.res() != 0)
                    next = next + (u32)1;
                if (ins.memRes() == v)
                    return next;
                if (ins.memRes() != 0)
                    next = next + (u32)1;
                }
            }
        return (u32)0;
        }

    // …transitively. A struct that embeds another which owns a reference owns
    // it too, one level removed.
    bool structHasClassField(String* ty)
        {
        return structHasTrackedField(ty);
        }

    // Walk the struct's class-reference fields, in declaration order, doing
    // the same thing to each.
    void structAdoptARC(Node* lhs, Node* rhs)
        {
        if (lhs.kind() != (u16)nkIdent)
            return;
        if (pinOf(lhs.name()) == (IRPinned*)0)
            return;
        if (_strongStruct.get((Hashable*)lhs.name()) == 0)
            return;
        if (isStructCopySource(rhs))
            return;
        structFieldARC(lhs.name(), false);
        structFieldARC(lhs.name(), true);
        }

    void structElemAdoptARC(Node* lhs, IRValue* addr, Node* rhs)
        {
        if (lhs.kind() != (u16)nkSubscript)
            return;
        if (lhs.kid((u32)0).kind() != (u16)nkIdent)
            return;
        Object* ty = _strongStruct.get((Hashable*)lhs.kid((u32)0).name());
        if (ty == 0 || isStructCopySource(rhs))
            return;
        String* elem = elementOf((String*)ty);
        if (structDeclFor(elem) == 0)
            return;
        structFieldsAt(addr, elem, false);
        structFieldsAt(addr, elem, true);
        }

    void structCopyARC(String* dst, Node* src)
        {
        Object* st = _strongStruct.get((Hashable*)dst);
        if (st == 0 || !isStructCopySource(src))
            return;
        IRValue* srcAddr = aggregateAddr(src);
        if (_failed)
            return;
        structFieldsAt(srcAddr, (String*)st, false, true);
        structFieldARC(dst, false);
        }

    // Only a NAME or a member reads as a struct being copied FROM: anything
    // else is a value the callee made, and its fields arrive owned.
    bool isStructCopySource(Node* rhs)
        {
        return rhs != 0 && (rhs.kind() == (u16)nkIdent || rhs.kind() == (u16)nkMember);
        }

    // Every element of a class-pointer array, in order for the zeroing and in
    // REVERSE for the teardown — the same LIFO a scope's locals get, for the
    // same reason: a release can run the referent's dealloc, which may read
    // whatever else is still live. The base address is re-formed per element.
    void strongArrayARC(String* name, bool zero)
        {
        Object* tyo = _strongArray.get((Hashable*)name);
        if (tyo == 0)
            return;
        IRPinned* p = pinOf(name);
        if (p == 0)
            return;
        String* ty = (String*)tyo;
        String* elem = elementOf(ty);
        String* elemPtr = ptrTo(irType(elem));
        u32 count = arrayCount(ty);
        for (u32 k = (u32)0; k < count; k = k + (u32)1)
            {
            u32 e = zero ? k : count - (u32)1 - k;
            Array* bo = new Array();
            bo.add((Object*)IROperand.useVal(p.val()));
            IRValue* base = emit(String.withCString("AddrOf"), elemPtr, bo);
            IRValue* ea = byteSlotAddr(base, e, elemPtr);
            if (zero)
                {
                Array* zo = new Array();
                zo.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
                IRValue* z = emit(String.withCString("Const"), String.withCString("U16"), zo);
                Array* io = new Array();
                io.add((Object*)IROperand.useVal(z));
                storeThrough(ea, emit(String.withCString("IntToPtr"), irType(elem), io));
                }
            else
                {
                refOp(String.withCString("Release"), loadThrough(ea, elem));
                }
            }
        }

    void structFieldARC(String* name, bool zero)
        {
        Object* tyo = _strongStruct.get((Hashable*)name);
        if (tyo == 0)
            return;
        IRPinned* p = pinOf(name);
        if (p == 0)
            return;
        String* ty = (String*)tyo;
        // An ARRAY of them: one pass per element, addressed through the
        // array's own decay, then the same field walk inside each.
        if (isArrayLike(ty))
            {
            String* elem = elementOf(ty);
            String* elemPtr = ptrTo(irType(elem));
            u32 count = arrayCount(ty);
            // The base is taken ONCE and indexed per element — it is the same
            // address every time round, and re-forming it says otherwise.
            Array* bo = new Array();
            bo.add((Object*)IROperand.useVal(p.val()));
            IRValue* ab = emit(String.withCString("AddrOf"), elemPtr, bo);
            for (u32 e = (u32)0; e < count; e = e + (u32)1)
                structFieldsAt(byteSlotAddr(ab, e, elemPtr), elem, zero);
            return;
            }
        // The LINK words are nulled in a pass of their own, before the field
        // walk and off its own address: a frame slot's memory is whatever it
        // last held, and the first unregister would otherwise follow a garbage
        // pointer and write through it.
        if (zero)
            zeroWeakLinks(p, ty);
        // …and the field walk only when there is a field for it to touch.
        // Forming the struct's address for a walk that emits nothing leaves a
        // dangling AddrOf behind.
        if (structFieldsWouldEmit(ty, zero))
            structFieldsAt(pinAddr(p), ty, zero);
        }

    // Does a field walk of this struct emit anything? Zeroing touches only
    // owned pointers; a teardown also unregisters the auto-zeroing ones.
    bool structFieldsWouldEmit(String* ty, bool zero)
        {
        Node* st = structDeclFor(ty);
        if (st == 0)
            return false;
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            {
            String* ft = st.kid(i).op();
            if (isClassPointer(ft))
                return true;
            // A weak class POINTER's payload is nulled too — it is a scalar
            // and has a zero. A `^` payload is a PAIR and has none, so
            // zeroing skips it and only its link words are written.
            if (isWeakClassPtr(ft))
                return true;
            if (structDeclFor(ft) != 0 && structFieldsWouldEmit(ft, zero))
                return true;
            }
        return false;
        }

    // Every element of an array of auto-zeroing slots gets its links nulled:
    // a frame slot's memory is whatever it last held, and the first unregister
    // would otherwise follow a garbage pointer and write through it. The base
    // address is formed per element, each with its own slot layout — which is
    // what the original does.
    // Every element's chain entry comes out at scope exit, in REVERSE order —
    // the same LIFO a scope's locals get, and for the same reason.
    void weakArrayUnregister(String* name)
        {
        Object* tyo = _weakArray.get((Hashable*)name);
        if (tyo == 0)
            return;
        IRPinned* p = pinOf(name);
        if (p == 0)
            return;
        String* ty = (String*)tyo;
        String* elem = elementOf(ty);
        u32 n = arrayCount(ty);
        for (u32 k = (u32)0; k < n; k = k + (u32)1)
            {
            u32 e = n - (u32)1 - k;
            String* slotPtr = ptrTo(weakSlotAggOf(elem));
            Array* bo = new Array();
            bo.add((Object*)IROperand.useVal(p.val()));
            IRValue* base = emit(String.withCString("AddrOf"), slotPtr, bo);
            IRValue* ea = byteSlotAddr(base, e, slotPtr);
            weakOp(String.withCString("WeakUnregister"),
                   fieldAddr(ea, (u32)2, ptrTo(irType(elem))), (IRValue*)0);
            }
        }

    void zeroWeakArrayLinks(IRPinned* p, String* ty)
        {
        String* elem = elementOf(ty);
        u32 n = arrayCount(ty);
        String* link = ptrTo(String.withCString("Void"));
        // ONE null, ahead of every address it is written through.
        Array* zo = new Array();
        zo.add((Object*)IROperand.immI((i32)0, link));
        IRValue* z = emit(String.withCString("Const"), link, zo);
        for (u32 e = (u32)0; e < n; e = e + (u32)1)
            {
            String* slotPtr = ptrTo(weakSlotAggOf(elem));
            Array* bo = new Array();
            bo.add((Object*)IROperand.useVal(p.val()));
            IRValue* base = emit(String.withCString("AddrOf"), slotPtr, bo);
            IRValue* ea = byteSlotAddr(base, e, slotPtr);
            storeThrough(fieldAddr(ea, (u32)0, ptrTo(link)), z);
            storeThrough(fieldAddr(ea, (u32)1, ptrTo(link)), z);
            }
        }

    void zeroWeakLinks(IRPinned* p, String* ty)
        {
        Node* st = structDeclFor(ty);
        if (st == 0)
            return;
        bool any = false;
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            if (isWeakSlot(st.kid(i).op()))
                any = true;
        if (!any)
            return;
        // The null comes FIRST, then the address: one constant serves every
        // link word, and the address is the struct's own.
        String* link = ptrTo(String.withCString("Void"));
        Array* zo = new Array();
        zo.add((Object*)IROperand.immI((i32)0, link));
        IRValue* z = emit(String.withCString("Const"), link, zo);
        IRValue* base = pinAddr(p);
        u32 idx = (u32)0;
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            {
            String* ft = st.kid(i).op();
            if (isWeakSlot(ft))
                {
                storeThrough(fieldAddr(base, idx, ptrTo(link)), z);
                storeThrough(fieldAddr(base, idx + (u32)1, ptrTo(link)), z);
                idx = idx + (u32)2;
                }
            idx = idx + (u32)1;
            }
        }

    // Does this lvalue root at a struct local the scope teardown tracks?
    bool structFieldBaseIsTracked(Node* base)
        {
        for (Node* n = base; n != 0;)
            {
            if (n.kind() == (u16)nkIdent)
                return _strongStruct.get((Hashable*)n.name()) != 0;
            if (n.kind() == (u16)nkMember || n.kind() == (u16)nkSubscript)
                {
                n = n.kid((u32)0);
                continue;
                }
            return false;
            }
        return false;
        }

    bool structHasStrongPointer(String* ty)
        {
        Node* st = structDeclFor(ty);
        if (st == 0)
            return false;
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            {
            String* ft = st.kid(i).op();
            if (isClassPointer(ft))
                return true;
            if (structDeclFor(ft) != 0 && structHasStrongPointer(ft))
                return true;
            }
        return false;
        }

    // …or an AUTO-ZEROING one. It owns nothing, so nothing is released — but
    // its link words still have to be nulled at the declaration and its
    // side-table entry still has to come out at scope exit, so the struct is
    // tracked for the same reason a strong-bearing one is.
    bool structHasTrackedField(String* ty)
        {
        if (structHasStrongPointer(ty))
            return true;
        Node* st = structDeclFor(ty);
        if (st == 0)
            return false;
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            {
            String* ft = st.kid(i).op();
            if (isWeakSlot(ft))
                return true;
            if (structDeclFor(ft) != 0 && structHasTrackedField(ft))
                return true;
            }
        return false;
        }

    void structFieldsAt(IRValue* base, String* ty, bool zero)
        {
        structFieldsAt(base, ty, zero, false);
        }

    void structFieldsAt(IRValue* base, String* ty, bool zero, bool claim)
        {
        Node* st = structDeclFor(ty);
        if (st == 0)
            return;
        u32 idx = (u32)0;
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            {
            String* ft = st.kid(i).op();
            // An auto-zeroing FIELD's two link words come first, and they are
            // nulled at the declaration: a frame slot's memory is whatever it
            // last held, and the first unregister would otherwise follow a
            // garbage pointer and write through it.
            if (isWeakSlot(ft))
                idx = idx + (u32)2;
            u32 here = idx;
            idx = idx + (u32)1;
            // A NESTED struct is walked in turn: the outer one owns it, and it
            // owns whatever pointers it holds. Skipped when it holds none.
            if (structDeclFor(ft) != 0)
                {
                if (!structHasTrackedField(ft))
                    continue;
                structFieldsAt(fieldAddr(base, here, ptrTo(irType(ft))), ft, zero, claim);
                continue;
                }
            if (!isClassPointer(ft) && !isWeakClassPtr(ft))
                continue;
            IRValue* fa = fieldAddr(base, here, ptrTo(irType(ft)));
            if (zero)
                {
                Array* zo = new Array();
                zo.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
                IRValue* z = emit(String.withCString("Const"), String.withCString("U16"), zo);
                Array* io = new Array();
                io.add((Object*)IROperand.useVal(z));
                storeThrough(fa, emit(String.withCString("IntToPtr"), irType(ft), io));
                }
            else if (isWeakClassPtr(ft))
                {
                // Auto-zeroing and owning nothing: there is no release, but
                // the chain entry must come out, or a later dealloc of the
                // still-live referent writes through storage that has since
                // been reused. (A `^` FIELD is left alone — the original does
                // not unregister one at teardown, only a `weak:T@`.)
                if (!claim)
                    weakOp(String.withCString("WeakUnregister"), fa, (IRValue*)0);
                }
            else
                {
                refOp(String.withCString(claim ? "Retain" : "Release"), loadThrough(fa, ft));
                }
            }
        }

    // A stack instance's memory is whatever the frame last held, so the slot
    // has to be made into an object before anything touches it: the ivars
    // zeroed (so a strong field's first assignment releases a null and not a
    // stale pointer), the vtable seeded (init may dispatch), and the class's
    // own zero-argument `init` run if it has one. There is no allocation and
    // nothing to free — the instance IS the frame slot.
    // `<ValueClass> b = recv.m()` — the initialiser yields a CLASS VALUE, and
    // the slot IS the instance, so the answer has to land in the slot's bytes
    // rather than replace them. Two shapes, both a field-by-field copy:
    //
    //  * `recv.clone()` where no class in recv's chain DEFINES clone — the
    //    intrinsic. There is no body to call: copy straight out of recv's own
    //    slot.
    //  * anything else returning the class — the callee returns `Ptr(C)` to
    //    the instance it just built; copy out of that.
    //
    // Storing the returned POINTER into the first bytes of the slot instead
    // would leave every ivar uninitialised, which reads as garbage in b.x.
    // The copy-assign half of [[valueClassInit]] — same shape, reached from
    // `b = recv.m()` rather than a declaration.
    bool valueClassAssign(String* name, Node* rhs)
        {
        if (rhs.kind() != (u16)nkMethodCall)
            return false;
        IRPinned* vpin = pinOf(name);
        if (vpin == 0 || !vpin.ty().hasPrefix(String.withCString("Agg(")))
            return false;
        Object* vco = _valueClass.get((Hashable*)name);
        if (vco == 0)
            return false;
        return valueClassInit(rhs, vpin, (ClassInfo*)vco);
        }

    bool valueClassInit(Node* call, IRPinned* pin, ClassInfo* ci)
        {
        IRValue* src = (IRValue*)0;
        if (isName(call.name(), "clone") && call.kidCount() == (u32)1)
            {
            ClassInfo* rci = classFor(pointeeOf(call.kid((u32)0).ty()));
            bool userClone = false;
            for (ClassInfo* c = rci; c != 0; c = c.parent())
                {
                String* cs = String.withCString(c.name().cString());
                cs.appendCString("$clone");
                if (symbolNamed(cs) != 0)
                    {
                    userClone = true;
                    }
                }
            if (rci != 0 && !userClone)
                {
                src = lowerExpr(call.kid((u32)0));
                if (_failed)
                    return false;
                }
            }
        if (src == 0)
            {
            src = lowerExpr(call);
            if (_failed)
                return false;
            if (src == 0 || !isPtrIr(src.ty()))
                return false;
            }
        Array* aops = new Array();
        aops.add((Object*)IROperand.useVal(pin.val()));
        IRValue* dst = emit(String.withCString("AddrOf"), ci.selfPtr(), aops);
        IRLayout* lay = layoutOfAgg(ci.agg());
        if (lay == 0)
            return false;
        for (u32 i = (u32)0; i < lay.fieldCount(); i = i + (u32)1)
            {
            String* ft = lay.typeAt(i);
            IRValue* sf = fieldAddr(src, i, ptrTo(ft));
            IRValue* sv = loadThroughIr(sf, ft);
            IRValue* df = fieldAddr(dst, i, ptrTo(ft));
            storeThrough(df, sv);
            }
        return true;
        }

    // The module layout an `Agg(N)` spelling names.
    IRLayout* layoutOfAgg(String* agg)
        {
        if (agg == 0 || !agg.hasPrefix(String.withCString("Agg(")))
            return (IRLayout*)0;
        u32 idx = (u32)0;
        u8* cs = agg.cString();
        u32 i = (u32)4;
        while (cs[i] >= (u8)48 && cs[i] <= (u8)57)
            {
            idx = idx * (u32)10 + (u32)(cs[i] - (u8)48);
            i = i + (u32)1;
            }
        if (idx >= _m.layouts().count())
            return (IRLayout*)0;
        return (IRLayout*)_m.layouts().get(idx);
        }

    void setUpStackInstance(String* name, ClassInfo* ci)
        {
        IRPinned* pin = pinOf(name);
        Array* aops = new Array();
        aops.add((Object*)IROperand.useVal(pin.val()));
        IRValue* addr = emit(String.withCString("AddrOf"), ci.selfPtr(), aops);
        zeroInitIvars(addr, ci);
        stampInstanceIdentity(addr, ci);
        Node* init = zeroArgInit(ci);
        if (init != 0)
            emitMethodCall(methodSymbolName(ci.decl(), init), addr,
                           new Array(), (String*)0, false);
        }

    // Every scalar and pointer ivar, in FIELD order. An aggregate ivar is left
    // alone — a partial zero would be worse than none.
    void zeroInitIvars(IRValue* addr, ClassInfo* ci)
        {
        Array* names = sortedNames(ci.ivarIndex().allKeys());
        // FIELD order for BOTH loops below. The link loop used to walk
        // `names` (name order) while the payload loop walked field order,
        // so a class with two auto-zeroing ivars whose names sort
        // differently from their indices emitted its link stores in an
        // order the reference does not use. One ordering, computed once.
        Array* byIndex = new Array();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            byIndex.add(names.get(i));
        for (u32 i = (u32)1; i < byIndex.count(); i = i + (u32)1)
            {
            Object* cur = byIndex.get(i);
            u32 ck = ((Number*)ci.ivarIndex().get((Hashable*)(String*)cur)).asU32();
            u32 j = i;
            while (j > (u32)0 && ((Number*)ci.ivarIndex().get((Hashable*)(String*)byIndex.get(j - (u32)1))).asU32() > ck)
                {
                byIndex.set(j, byIndex.get(j - (u32)1));
                j = j - (u32)1;
                }
            byIndex.set(j, cur);
            }
        // A WEAK/callback ivar's two hidden LINK words first. They are not in
        // `ivarIndex` — which maps a name to its PAYLOAD field — so the payload
        // loop below never sees them, and it skips Agg fields anyway, which is
        // exactly what a callback slot is. Nothing zeroed them.
        //
        // The failure is remote from the cause: the links are a doubly-linked
        // list, so the first unregister follows a garbage `pprev` and writes
        // through it, corrupting a chain that belongs to some other live
        // object. It needs a `new` in a loop to show at all — a fresh block
        // reads as zero — which is why a three-object reduction survives and
        // the real workload dies (uxkit bug 034-B).
        String* linkIr = ptrTo(String.withCString("Void"));
        for (u32 i = (u32)0; i < byIndex.count(); i = i + (u32)1)
            {
            String* nm = (String*)byIndex.get(i);
            String* ty = (String*)ci.ivarType().get((Hashable*)nm);
            if (ty == (String*)0 || !isWeakSlot(ty))
                continue;
            u32 pidx = ((Number*)ci.ivarIndex().get((Hashable*)nm)).asU32();
            if (pidx < (u32)2)
                continue; // the links precede the payload
            for (u32 k = pidx - (u32)2; k < pidx; k = k + (u32)1)
                {
                IRValue* fa = fieldAddr(addr, k, ptrTo(linkIr));
                Array* cops = new Array();
                cops.add((Object*)IROperand.immI((i32)0, linkIr));
                storeThrough(fa, emit(String.withCString("Const"), linkIr, cops));
                }
            }
            // FIELD order, by each name's own index — NOT a scan of slots 1..N.
            // The old bound assumed the payload indices were dense, and they are
            // not: every weak/callback ivar consumes two hidden link indices ahead
            // of its payload, so the real indices run past `count()` and every
            // ivar beyond the first weak one was silently skipped. In UXUndoOp
            // that was the strong class pointer at #4 — left holding the previous
            // tenant's pointer, and released on the first assignment to it.
            {
            for (u32 i = (u32)0; i < byIndex.count(); i = i + (u32)1)
                {
                String* nm = (String*)byIndex.get(i);
                u32 slot = ((Number*)ci.ivarIndex().get((Hashable*)nm)).asU32();
                String* ty = (String*)ci.ivarType().get((Hashable*)nm);
                String* ir = irType(ty);
                if (ir.hasPrefix(String.withCString("Agg(")))
                    continue;
                IRValue* fa = fieldAddr(addr, slot, ptrTo(ir));
                IRValue* z = (IRValue*)0;
                if (isPtrIr(ir))
                    {
                    Array* cops = new Array();
                    cops.add((Object*)IROperand.immI((i32)0, String.withCString("U16")));
                    IRValue* c = emit(String.withCString("Const"), String.withCString("U16"), cops);
                    Array* iops = new Array();
                    iops.add((Object*)IROperand.useVal(c));
                    z = emit(String.withCString("IntToPtr"), ir, iops);
                    }
                else
                    {
                    Array* cops = new Array();
                    cops.add((Object*)IROperand.immI((i32)0, ir));
                    z = emit(String.withCString("Const"), ir, cops);
                    }
                storeThrough(fa, z);
                }
            }
        }

    Node* zeroArgInit(ClassInfo* ci)
        {
        Node* d = ci.decl();
        for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1)
            {
            Node* m = d.kid(i);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (!m.name().equals(String.withCString("init")))
                continue;
            u32 np = (u32)0;
            for (u32 j = (u32)0; j < m.kidCount(); j = j + (u32)1)
                if (m.kid(j).kind() == (u16)nkParam)
                    np = np + (u32)1;
            if (np == (u32)0)
                return m;
            }
        return (Node*)0;
        }

    // `break` and `continue` are the same shape — an edge recorded so the
    // block it jumps to can build a phi from it later. They differ only in
    // where they jump and in whether the loop's step runs first: a `continue`
    // runs it, so its edge carries the POST-step values.
    void lowerJump(Node* n, u16 k)
        {
        if (_loopHeaders == 0 || _loopHeaders.count() == (u32)0)
            {
            giveUp(String.withCString("break/continue outside a loop"));
            return;
            }
        u32 top = _loopHeaders.count() - (u32)1;
        // `continue` targets the nearest enclosing LOOP, stepping over any
        // switch in between: a switch catches `break` and nothing else.
        if (k == (u16)nkContinue)
            {
            while ((IRBlock*)_loopHeaders.get(top) == (IRBlock*)0)
                {
                if (top == (u32)0)
                    {
                    giveUp(String.withCString("continue outside a loop"));
                    return;
                    }
                top = top - (u32)1;
                }
            }
        // A jump LEAVES scopes, so what those scopes own is released on the
        // way out — and so is any owned temporary the statement produced. The
        // loop's own scope is not one of them: its control variable is still
        // live on the other side of the jump.
        flushOwnedTemps();
        releaseScopesDownTo(((Number*)_loopArcDepth.get(top)).asU32());
        if (k == (u16)nkContinue)
            {
            Node* step = (Node*)_loopSteps.get(top);
            if (step != 0)
                {
                lowerExpr(step);
                if (_failed)
                    return;
                }
            // A for-in's step is its INDEX, which is not a program variable —
            // it lives only in the phi — so the increment is emitted here and
            // the stepped value recorded for this edge. Skipping it would
            // rejoin the header with the same index and never terminate.
            Object* ix = _loopIdx.get(top);
            if (ix != 0)
                {
                IRValue* idx = (IRValue*)ix;
                Array* oo = new Array();
                oo.add((Object*)IROperand.immI((i32)1, idx.ty()));
                IRValue* one = emit(String.withCString("Const"), idx.ty(), oo);
                Array* ao = new Array();
                ao.add((Object*)IROperand.useVal(idx));
                ao.add((Object*)IROperand.useVal(one));
                ((Array*)_loopIdxNext.get(top)).add((Object*)emit(String.withCString("Add"), idx.ty(), ao));
                }
            ((Array*)_loopContBlocks.get(top)).add((Object*)_blk);
            ((Array*)_loopContLocals.get(top)).add((Object*)snapshot());
            IRInsn* c = IRInsn.with(String.withCString("Branch"));
            c.add(IROperand.block((IRBlock*)_loopHeaders.get(top)));
            _blk.setTerm(c);
            return;
            }
        ((Array*)_loopBreakBlocks.get(top)).add((Object*)_blk);
        ((Array*)_loopBreakLocals.get(top)).add((Object*)snapshot());
        IRInsn* b = IRInsn.with(String.withCString("Branch"));
        b.add(IROperand.block((IRBlock*)_loopExits.get(top)));
        _blk.setTerm(b);
        }

    // ── goto / label (a C-porting aid; not a promoted language feature) ──────
    // A function with a goto pins ALL its locals (so a jump is a plain branch),
    // and its scalar/pointer-only locals need no ARC teardown — a function that
    // has an ARC-managed local (class ptr / struct / weak / bound) or a
    // defer/try is rejected in the pin pre-scan. goto/label are branches; the
    // teardown call is therefore a no-op here, matching the reference.
    IRBlock* blockForGotoLabel(String* name)
        {
        if (_gotoLabelBlocks == 0)
            _gotoLabelBlocks = new Map();
        Object* b = _gotoLabelBlocks.get((Hashable*)name);
        if (b != 0)
            return (IRBlock*)b;
        String* bn = String.withCString("bb_label_");
        bn.append(name);
        IRBlock* nb = addBlock(bn);
        _gotoLabelBlocks.set((Hashable*)name, (Object*)nb);
        return nb;
        }

    void lowerGotoLabel(Node* n)
        {
        IRBlock* block = blockForGotoLabel(n.name());
        if (_blk != 0 && _blk.term() == 0)
            {
            IRInsn* br = IRInsn.with(String.withCString("Branch"));
            br.add(IROperand.block(block));
            _blk.setTerm(br);
            }
        _blk = block;
        if (_gotoLabelDepths == 0)
            _gotoLabelDepths = new Map();
        _gotoLabelDepths.set((Hashable*)n.name(), (Object*)Number.with(_arcScopes.count()));
        }

    void lowerGoto(Node* n)
        {
        Object* d = _gotoLabelDepths != 0 ? _gotoLabelDepths.get((Hashable*)n.name()) : (Object*)0;
        u32 depth = d != 0 ? ((Number*)d).asU32() : _arcScopes.count();
        if (depth > _arcScopes.count())
            depth = _arcScopes.count();
        flushOwnedTemps();
        releaseScopesDownTo(depth);
        if (_failed)
            return;
        IRBlock* block = blockForGotoLabel(n.name());
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(block));
        _blk.setTerm(br);
        }

    // Does a subtree contain a goto? (→ pin all locals so a jump is a branch.)
    bool astContainsGoto(Node* n)
        {
        if (n == 0)
            return false;
        if (n.kind() == (u16)nkGoto)
            return true;
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            if (astContainsGoto(n.kid(i)))
                return true;
        return false;
        }

    // Every local var-decl name in a subtree (pinned when a goto is present).
    void collectAllLocalNames(Node* n, Array* out)
        {
        if (n == 0)
            return;
        if (n.kind() == (u16)nkVariableDecl && n.name() != 0)
            addUnique(out, n.name());
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            collectAllLocalNames(n.kid(i), out);
        }

    // Names of function-local `static` declarations — backed by a module global
    // (lowerStaticLocalDecl), NOT a frame slot, so the pin pre-scan must skip
    // them. An address-taken static ARRAY would otherwise be pinned as well and
    // the frame slot would shadow the global, losing the static storage across
    // calls (bug 174). A static scalar is never address-taken so was never
    // pinned; restricting to statics leaves every ordinary local pinned.
    void collectStaticLocalNames(Node* n, Array* out)
        {
        if (n == 0)
            return;
        if (n.kind() == (u16)nkVariableDecl && n.name() != 0 && n.hasFlag((u32)NF_STATIC) && !n.hasFlag((u32)NF_GLOBAL))
            addUnique(out, n.name());
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            collectStaticLocalNames(n.kid(i), out);
        }

    // Why a goto function is unsupported today (nil = supported): an ARC-managed
    // local or a defer/try would need the jump to run releases the pinned-local
    // model does not yet thread. The C-porting case has none.
    String* gotoUnsupportedReason(Node* n)
        {
        if (n == 0)
            return (String*)0;
        u16 k = n.kind();
        if (k == (u16)nkDefer)
            return String.withCString("a `defer`");
        if (k == (u16)nkTry)
            return String.withCString("a `try`/`catch`");
        if (k == (u16)nkVariableDecl)
            {
            String* t = n.op();
            if (t != 0 && (isClassPointer(t) || isWeakClassPtr(t) || isBoundSig(stripQual(t)) || structDeclFor(t) != 0))
                return String.withCString("an ARC-managed local (class pointer, struct, weak, or bound method)");
            }
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            {
            String* r = gotoUnsupportedReason(n.kid(i));
            if (r != 0)
                return r;
            }
        return (String*)0;
        }

    // A node kind as text, for the diagnostic. Only the ones a slice is
    // likely to stop on are named; the rest report their number.
    String* kindName(u16 k, String* what)
        {
        String* w = String.withString(what);
        w.appendCString(" ");
        if (k == (u16)nkMember)
            w.appendCString("member");
        else if (k == (u16)nkSubscript)
            w.appendCString("subscript");
        else if (k == (u16)nkMethodCall)
            w.appendCString("methodcall");
        else if (k == (u16)nkUnary)
            w.appendCString("unary");
        else if (k == (u16)nkPostfix)
            w.appendCString("postfix");
        else if (k == (u16)nkTernary)
            w.appendCString("ternary");
        else if (k == (u16)nkStr)
            w.appendCString("string literal");
        else if (k == (u16)nkFloat)
            w.appendCString("float literal");
        else if (k == (u16)nkNew)
            w.appendCString("new");
        else if (k == (u16)nkAsmBlock)
            w.appendCString("asm");
        else if (k == (u16)nkForIn)
            w.appendCString("for-in");
        else if (k == (u16)nkSwitch)
            w.appendCString("switch");
        else if (k == (u16)nkSizeof)
            w.appendCString("sizeof");
        else if (k == (u16)nkTupleAssign)
            w.appendCString("tuple assign");
        else if (k == (u16)nkDelete)
            w.appendCString("delete");
        else
            w.appendFormat("kind %ld", (i32)k);
        return w;
        }

    String* _fnReturn;
    String* _fnRetAgg; // non-null in a function returning a tuple

    // ── objects ──────────────────────────────────────────────────────────
    // `new T()` is three things, not one: allocate, stamp the instance with
    // what it IS, and run the class's init. The allocator is a single generic
    // helper taking (count, stride, dealloc) — one runtime routine rather than
    // one per class, which matters most where code space is scarcest.
    // The non-class half of `new`, lifted out of lowerNew: the arm64 back end
    // refuses a function needing more than 16 KB of frame, and the two branches
    // together crossed it.
    IRValue* lowerNewNonClass(Node* n, bool hasCount)
        {
        // Not a class: a PRIMITIVE array (`new u8[N]`) or a STRUCT one
        // (`new Point[N]`). Both go to a per-type helper rather than the
        // generic allocator, but the two helpers have different SHAPES and
        // the call must match the one the driver will synthesise:
        //
        //   primitive -> _xtc_new_u8(count)          width baked into the
        //                                            stub; it is per-backend
        //                                            (a pointer is 3, 4 or 8
        //                                            bytes) so the shared
        //                                            lowering cannot know it
        //   struct    -> _xtc_new_Point(count, stride)
        //                                            the size IS known here —
        //                                            the IR layout's, the same
        //                                            number the class path uses
        //
        // Passing only the count to the two-argument form left `stride` as
        // whatever the register happened to hold: arm9 then called
        // calloc(1, count*garbage), which failed, and the stub wrote the
        // object header through the NULL it got back. Bug 027.
        String* nm = stripQual(n.name());
        String* helper = String.withCString("_xtc_new_");
        helper.append(nm);
        // The COUNT is materialised either way — one for a scalar `new`
        // — and only PASSED when the source wrote one. The constant is
        // dead on the scalar path, and it is in the original too.
        IRValue* cv = hasCount ? lowerCount(n.kid((u32)0)) : u16Const((u32)1);
        if (_failed)
            return (IRValue*)0;
        // The stride, for an aggregate element only. `Agg(N)` in the IR
        // type names the layout whose size this is.
        IRValue* sv = (IRValue*)0;
        if (!isPrimElemName(nm) && structDeclFor(nm) != 0)
            {
            u32 lid = layoutFor(nm);
            if (lid < _m.layouts().count())
                sv = u16Const(((IRLayout*)_m.layouts().get(lid)).size());
            }
        IRInsn* c = IRInsn.with(String.withCString("Call"));
        c.add(IROperand.sym(runtimeHelper(helper)));
        // The two-argument struct form passes BOTH, even for a scalar
        // `new Point()` where the source wrote no count — the stub needs a
        // count of 1 and the stride, and a lone stride would land in the
        // count register. Only the primitive form may omit the count.
        if (sv != 0)
            {
            c.add(IROperand.useVal(cv));
            c.add(IROperand.useVal(sv));
            }
        else if (hasCount)
            {
            c.add(IROperand.useVal(cv));
            }
        c.add(IROperand.useVal(_mem));
        IRValue* r = new IRValue(irType(n.ty()));
        c.setRes(r);
        IRValue* pm = new IRValue(String.withCString("Mem"));
        c.setMemRes(pm);
        c.setCc(String.withCString("CallConv::Standard"));
        _blk.add(c);
        _mem = pm;
        return r;
        }

    IRValue* lowerNew(Node* n)
        {
        // `new T[N]` carries its COUNT as the only child and no argument
        // count; `new T(a, b)` carries arguments and says how many. The two
        // forms cannot both appear, so which is present tells them apart.
        bool hasCount = n.kidCount() > (u32)n.num();
        ClassInfo* ci = classFor(n.name());

        if (ci == 0)
            return lowerNewNonClass(n, hasCount);

        Array* ctorArgs = new Array();
        _ctorArgAst = new Array();
        if (!hasCount)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                IRValue* a = lowerExpr(n.kid(i));
                if (_failed)
                    return (IRValue*)0;
                ctorArgs.add((Object*)a);
                _ctorArgAst.add((Object*)n.kid(i).ty());
                }
            }
        // The allocator writes the count and the stride into the object
        // header, so `delete` of an array-of-class steps dealloc once per
        // element. A scalar `new T()` is a count of one and the loop runs once.
        IRValue* count = hasCount ? lowerCount(n.kid((u32)0)) : u16Const((u32)1);
        if (_failed)
            return (IRValue*)0;
        IRValue* stride = u16Const(ci.instSize());
        // The dealloc pointer is a runtime ARGUMENT, which is what lets one
        // generic allocator serve every class. It is the class's own
        // destructor where there is one — the runtime writes it into the
        // object header and dispatches through it, so there is no IR-level
        // call edge to a dealloc anywhere — and a null otherwise. A null
        // POINTER is an integer zero cast: a Const of pointer type is
        // mis-sized on the native backends.
        String* dname = String.withString(ci.name());
        dname.appendCString("$dealloc");
        IRValue* deallocPtr = (IRValue*)0;
        if (symbolExists(dname))
            {
            Array* dops = new Array();
            dops.add((Object*)IROperand.sym(dname));
            deallocPtr = emit(String.withCString("AddrOf"),
                              ptrTo(String.withCString("Void")), dops);
            }
        else
            {
            Array* zops = new Array();
            zops.add((Object*)IROperand.useVal(u16Const((u32)0)));
            deallocPtr = emit(String.withCString("IntToPtr"),
                              ptrTo(String.withCString("Void")), zops);
            }

        IRInsn* call = IRInsn.with(String.withCString("Call"));
        call.add(IROperand.sym(runtimeHelper(String.withCString("_xtc_alloc"))));
        call.add(IROperand.useVal(count));
        call.add(IROperand.useVal(stride));
        call.add(IROperand.useVal(deallocPtr));
        call.add(IROperand.useVal(_mem));
        IRValue* inst = new IRValue(ci.selfPtr());
        call.setRes(inst);
        IRValue* nextMem = new IRValue(String.withCString("Mem"));
        call.setMemRes(nextMem);
        call.setCc(String.withCString("CallConv::Standard"));
        _blk.add(call);
        _mem = nextMem;

        stampInstanceIdentity(inst, ci);
        // The allocator hands back a REUSED block without clearing it, so a
        // strong ivar can hold a dangling pointer from the slot's previous
        // tenant. The first assignment to it runs a release-of-old, which must
        // read null — otherwise it frees an unrelated live object.
        if (classHasStrongIvar(ci))
            zeroInitIvars(inst, ci);
        stampClassId(inst, ci);
        // The allocator does not run the constructor: an ivar read before init
        // would see whatever the block last held.
        if (n.sym() != 0)
            runInit(inst, ci, n.sym(), ctorArgs);
        // `new T` on a CLASS hands back a +1: an owned temporary, released at
        // the end of the full expression unless something adopts it. A raw
        // `new u16[N]` buffer is not ARC-managed and gets none of this.
        noteOwnedTemp(inst, n.ty());
        return inst;
        }

    // What the instance IS. A dispatching class says so with its vtable
    // pointer, in slot 0; a class with no vtable puts its RTTI id in the same
    // two bytes — which is why a downcast can read one field and know it is
    // looking at an id when the value is small.
    void stampInstanceIdentity(IRValue* inst, ClassInfo* ci)
        {
        if (ci.needsVtable())
            {
            String* fnPtr = ptrTo(String.withCString("Void"));
            // The field ADDRESS is tagged as data-window so the banked backend
            // selects the instance's own bank before the store; the dispatch
            // reads it back the same way.
            String* slotPtr = String.withCString("Ptr(");
            slotPtr.append(fnPtr);
            slotPtr.appendCString(", xt_data)");
            IRValue* fa = fieldAddr(inst, (u32)0, slotPtr);
            String* vn = String.withString(ci.name());
            vn.appendCString("$vtbl");
            Array* vops = new Array();
            vops.add((Object*)IROperand.sym(vn));
            storeThrough(fa, emit(String.withCString("AddrOf"), fnPtr, vops));
            }
        }

    // A class with no vtable puts its RTTI id in the same two bytes.
    void stampClassId(IRValue* inst, ClassInfo* ci)
        {
        if (ci.needsVtable() || ci.classId() == (u32)0)
            return;
        Array* bops = new Array();
        bops.add((Object*)IROperand.useVal(inst));
        IRValue* idAddr = emit(String.withCString("Bitcast"),
                               ptrTo(String.withCString("U16")), bops);
        storeThrough(idAddr, u16Const(ci.classId()));
        }

    // Does this class, or any ANCESTOR, hold something the allocator must not
    // hand back dirty?
    //
    // Two kinds qualify, and the second was missing entirely. A strong
    // class-pointer ivar needs zeroing because the first assignment to it runs
    // a release-of-old, which must read null rather than a stale pointer left
    // by the block's previous tenant. A WEAK/callback slot needs it because its
    // two hidden link words are a doubly-linked list: the first unregister
    // follows `pprev` and writes through it, so garbage there corrupts another
    // object's chain and the fault lands arbitrarily later (uxkit bug 034-B).
    //
    // The ancestor walk matters as much as the test: a subclass whose own
    // ivars are all scalars still inherits the parent's, and the layout it
    // allocates includes them.
    bool classHasStrongIvar(ClassInfo* ci)
        {
        for (ClassInfo* c = ci; c != (ClassInfo*)0; c = c.parent())
            {
            Array* ks = c.ivarType().allKeys();
            for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
                {
                String* t = (String*)c.ivarType().get((Hashable*)(String*)ks.get(i));
                if (isClassPointer(t))
                    return true;
                if (isWeakSlot(t))
                    return true;
                }
            }
        return false;
        }

    // The declared types of the `new T(a, b)` arguments, alongside the values.
    Array* _ctorArgAst;

    Node* initDeclFor(ClassInfo* ci, String* mangled)
        {
        for (ClassInfo* c = ci; c != 0; c = c.parent())
            {
            Node* d = c.decl();
            for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1)
                {
                Node* m = d.kid(i);
                if (m.kind() != (u16)nkMethodDecl)
                    continue;
                String* ms = m.sym() == 0 ? m.name() : m.sym();
                if (ms.equals(mangled))
                    return m;
                }
            }
        return (Node*)0;
        }

    void runInit(IRValue* inst, ClassInfo* ci, String* mangled, Array* ctorArgs)
        {
        String* initSym = (String*)0;
        for (ClassInfo* c = ci; c != 0 && initSym == 0; c = c.parent())
            {
            String* cand = String.withString(c.name());
            cand.appendByte((u8)'$');
            cand.append(mangled);
            if (symbolExists(cand))
                initSym = cand;
            }
        if (initSym == 0)
            return;
        // Each constructor argument is adjusted to the INIT's parameter — a
        // narrow literal reaching a wider parameter otherwise arrives one slot
        // short and shifts the callee's whole frame, exactly as it would in
        // any other call.
        Node* decl = initDeclFor(ci, mangled);
        if (decl != 0)
            {
            for (u32 i = (u32)0; i < ctorArgs.count() && i < _ctorArgAst.count();
                 i = i + (u32)1)
                {
                String* want = paramTypeAt(decl, i);
                if (want == 0)
                    continue;
                ctorArgs.set(i, (Object*)coerceArg((IRValue*)ctorArgs.get(i),
                                                   (String*)_ctorArgAst.get(i), want));
                }
            }
        emitMethodCall(initSym, inst, ctorArgs, (String*)0, false);
        }

    // An element count reaches the allocator as a u16 whatever it was written
    // as: a narrower one would marshal as a single byte and leave the high
    // half of the count uninitialised.
    //
    // …and it is NARROWED when it is wider than the target's word. The runtime
    // takes `unsigned long count`, 8 bytes on a 64-bit host but 4 on wasm32, so
    // `new u8[n]` with a u64 `n` handed an i64 to an i32 parameter and the
    // module failed validation ("call[0] expected type i32, found local.get of
    // type i64"). Native never noticed: a u64 count already fits its word. Only
    // narrowing happens here, so every count that already fits lowers exactly
    // as it did before (bug 38).
    IRValue* lowerCount(Node* e)
        {
        IRValue* v = lowerExpr(e);
        if (_failed)
            return (IRValue*)0;
        u32 cw = astWidth(e.ty());
        if (cw < (u32)2)
            {
            v = coerce(v, e.ty(), String.withCString("u16"));
            return v;
            }
        String* wordTy = String.withCString("u16");
        if (_ptrW >= (u32)8)
            wordTy = String.withCString("u64");
        else if (_ptrW >= (u32)4)
            wordTy = String.withCString("u32");
        if (cw > astWidth(wordTy))
            v = coerce(v, e.ty(), wordTy);
        return v;
        }

    // Variadic arguments travel in a fixed module BUFFER rather than on the
    // stack: the callee's va_arg reads them back at a running byte offset, and
    // a shared buffer is what lets that work with no ABI change on any target.
    // Only the fixed parameters are actually passed.
    //
    // A narrow integer is WIDENED to two bytes before it is stored. `%d` and
    // `%u` read sixteen bits, so a one-byte store would leave the high half
    // holding whatever the buffer held last — `printf("%d", a == b)` read the
    // neighbouring stale byte. Bool counts as narrow for the same reason,
    // whatever the integer predicate says about it.
    // `%e` prints an ENUM by NAME. The callee only understands `%s`, so the
    // specifier is rewritten and the value replaced, at the call site, by an
    // inline value→name lookup. It is a chain of Selects rather than a table
    // or a call: the enum's members are known here, the chain needs no new
    // blocks, and nothing has to exist at run time for it.
    //
    // Never on a C-ABI import, where `%e` is scientific notation.
    void rewriteEnumPercentE(Array* args, Node* call, u32 argBase, u32 fixedCount)
        {
        if (fixedCount == (u32)0)
            return;
        u32 fmtIdx = fixedCount - (u32)1;
        if (fmtIdx >= args.count())
            return;
        Node* fmtNode = call.kid(fmtIdx + argBase);
        if (fmtNode.kind() != (u16)nkStr)
            return;
        String* fmt = fmtNode.name();

        String* out = String.withCString("");
        Array* eArgs = new Array();
        bool any = false;
        u32 spec = (u32)0; // varargs consumed so far
        u32 i = (u32)0;
        u32 n = fmt.byteLength();
        while (i < n)
            {
            u8 c = fmt.byteAt(i);
            i = i + (u32)1;
            if (c != (u8)'%' || i >= n)
                {
                out.appendByte(c);
                continue;
                }
            // A `.precision` run belongs to the same specifier and consumes
            // no argument of its own.
            String* prec = String.withCString("");
            if (fmt.byteAt(i) == (u8)'.')
                {
                prec.appendByte((u8)'.');
                i = i + (u32)1;
                while (i < n && fmt.byteAt(i) >= (u8)'0' && fmt.byteAt(i) <= (u8)'9')
                    {
                    prec.appendByte(fmt.byteAt(i));
                    i = i + (u32)1;
                    }
                }
            if (i >= n)
                {
                out.appendByte((u8)'%');
                out.append(prec);
                break;
                }
            u8 nx = fmt.byteAt(i);
            if (nx == (u8)'%')
                {
                out.appendByte((u8)'%');
                out.append(prec);
                out.appendByte((u8)'%');
                i = i + (u32)1;
                continue;
                }
            if (nx == (u8)'l')
                {
                i = i + (u32)1;
                out.appendByte((u8)'%');
                out.append(prec);
                out.appendByte((u8)'l');
                if (i < n)
                    {
                    out.appendByte(fmt.byteAt(i));
                    i = i + (u32)1;
                    }
                spec = spec + (u32)1;
                continue;
                }
            if (nx == (u8)'e')
                {
                u32 ai = fmtIdx + (u32)1 + spec;
                if (ai < args.count() && _enums.get((Hashable*)stripQual(call.kid(ai + argBase).ty())) != 0)
                    {
                    out.appendByte((u8)'%');
                    out.append(prec);
                    out.appendByte((u8)'s');
                    eArgs.add((Object*)Number.with(ai));
                    any = true;
                    i = i + (u32)1;
                    spec = spec + (u32)1;
                    continue;
                    }
                }
            out.appendByte((u8)'%');
            out.append(prec);
            out.appendByte(nx);
            i = i + (u32)1;
            spec = spec + (u32)1;
            }
        if (!any)
            return;

        for (u32 e = (u32)0; e < eArgs.count(); e = e + (u32)1)
            {
            u32 ai = ((Number*)eArgs.get(e)).asU32();
            Node* et = (Node*)_enums.get((Hashable*)stripQual(call.kid(ai + argBase).ty()));
            args.set(ai, (Object*)enumNameLookup((IRValue*)args.get(ai), et));
            if (_failed)
                return;
            }
        args.set(fmtIdx, (Object*)stringAddr(out));
        }

    // The chain, in MEMBER-VALUE order so its shape is a property of the enum
    // and not of the order the members were written. A value naming nothing
    // falls through to the "?" the chain starts from.
    IRValue* enumNameLookup(IRValue* val, Node* et)
        {
        IRValue* result = stringAddr(String.withCString("?"));
        Array* ms = new Array();
        for (u32 i = (u32)0; i < et.kidCount(); i = i + (u32)1)
            if (et.kid(i).kind() == (u16)nkEnumMember)
                ms.add((Object*)et.kid(i));
        for (u32 i = (u32)1; i < ms.count(); i = i + (u32)1)
            {
            u32 j = i;
            while (j > (u32)0 && ((Node*)ms.get(j - (u32)1)).num() > ((Node*)ms.get(j)).num())
                {
                Object* t = ms.get(j - (u32)1);
                ms.set(j - (u32)1, ms.get(j));
                ms.set(j, t);
                j = j - (u32)1;
                }
            }
        String* u8Ptr = ptrTo(String.withCString("U8"));
        for (u32 i = (u32)0; i < ms.count(); i = i + (u32)1)
            {
            Node* m = (Node*)ms.get(i);
            Array* cops = new Array();
            cops.add((Object*)IROperand.immI(m.num(), val.ty()));
            IRValue* k = emit(String.withCString("Const"), val.ty(), cops);
            IRInsn* ic = IRInsn.with(String.withCString("ICmp"));
            ic.setRes(new IRValue(String.withCString("Bool")));
            ic.setPred(String.withCString("EQ"));
            ic.add(IROperand.useVal(val));
            ic.add(IROperand.useVal(k));
            _blk.add(ic);
            IRValue* nameStr = stringAddr(m.name());
            Array* sops = new Array();
            sops.add((Object*)IROperand.useVal(ic.res()));
            sops.add((Object*)IROperand.useVal(nameStr));
            sops.add((Object*)IROperand.useVal(result));
            result = emit(String.withCString("Select"), u8Ptr, sops);
            }
        return result;
        }

    // `decl` is the callee: a C import promotes and passes its tail per the C
    // ABI wherever it is called, whatever the target's own convention is.
    Array* packVarargs(Array* args, u32 fixedCount, Node* decl)
        {
        if (args.count() <= fixedCount)
            return args;
        // A C import promotes and passes per the C ABI wherever it is called;
        // a native-va_list target does the same for everything.
        if (_nativeVarargs || (decl != 0 && decl.hasFlag((u32)NF_CABI)))
            return cVarargPromote(args, fixedCount);
        String* u8Ptr = ptrTo(String.withCString("U8"));
        String* bufSym = varargBuffer();
        u32 byteOff = (u32)0;
        for (u32 i = fixedCount; i < args.count(); i = i + (u32)1)
            {
            Array* bops = new Array();
            bops.add((Object*)IROperand.sym(bufSym));
            IRValue* bufPtr = emit(String.withCString("AddrOf"), u8Ptr, bops);
            IRValue* slot = byteSlotAddr(bufPtr, byteOff, u8Ptr);
            IRValue* v = (IRValue*)args.get(i);
            String* vt = v.ty();
            if (irWidth(vt) < (u32)2 && (vt.equals(String.withCString("U8")) || vt.equals(String.withCString("I8")) || vt.equals(String.withCString("Bool"))))
                {
                bool sgn = vt.equals(String.withCString("I8"));
                String* wide = sgn ? String.withCString("I16") : String.withCString("U16");
                Array* wops = new Array();
                wops.add((Object*)IROperand.useVal(v));
                v = emit(String.withCString(sgn ? "SExt" : "ZExt"), wide, wops);
                vt = wide;
                }
            storeThrough(slot, v, false); // the buffer owns nothing
            // A struct by value copies sizeof(T) bytes, so the cursor moves by
            // exactly that; everything else keeps the fixed slot stride.
            if (vt.hasPrefix(String.withCString("Agg(")) && irWidth(vt) > (u32)0)
                byteOff = byteOff + irWidth(vt);
            else
                byteOff = byteOff + (u32)8;
            }
        Array* fixed = new Array();
        for (u32 i = (u32)0; i < fixedCount; i = i + (u32)1)
            fixed.add(args.get(i));
        return fixed;
        }

    // The C default argument promotions: a float widens to double and any
    // narrower INTEGER widens to an int. `Bool` is not one of them — it is its
    // own kind, not an integer kind, and the original passes it through at its
    // natural width; promoting it put a ZExt in front of every `printf("%d",
    // p == null)`. A callee reading its tail
    // out of the register save area finds exactly these widths and nothing
    // else, which is what makes the promotion a rule rather than a choice.
    Array* cVarargPromote(Array* args, u32 fixedCount)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)args.get(i);
            if (i < fixedCount || v == 0 || v.ty() == 0)
                {
                out.add((Object*)v);
                continue;
                }
            String* t = v.ty();
            Array* ops = new Array();
            ops.add((Object*)IROperand.useVal(v));
            if (t.equals(String.withCString("F32")))
                {
                v = emit(String.withCString("FpExt"), String.withCString("F64"), ops);
                }
            else if (t.equals(String.withCString("I8")) || t.equals(String.withCString("I16")))
                {
                v = emit(String.withCString("SExt"), String.withCString("I32"), ops);
                }
            else if (t.equals(String.withCString("U8")) || t.equals(String.withCString("U16")))
                {
                v = emit(String.withCString("ZExt"), String.withCString("I32"), ops);
                }
            out.add((Object*)v);
            }
        return out;
        }

    String* varargBuffer(void)
        {
        String* name = String.withCString("__xtc_va_buf");
        if (symbolExists(name))
            return name;
        IRLayout* L = IRLayout.with((u32)128, (u32)1);
        u32 id = _m.addLayout(L);
        String* agg = String.withCString("Agg(");
        agg.appendFormat("%ld", (i32)id);
        agg.appendCString(")");
        _m.addSym(IRSymbol.dataGlobal(name, agg));
        return name;
        }

    IRValue* u16Const(u32 v)
        {
        Array* ops = new Array();
        ops.add((Object*)IROperand.immI((i32)v, String.withCString("U16")));
        return emit(String.withCString("Const"), String.withCString("U16"), ops);
        }

    bool symbolExists(String* name)
        {
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1)
            if (((IRSymbol*)_m.syms().get(i)).name().equals(name))
                return true;
        return false;
        }

    String* runtimeHelper(String* name)
        {
        if (!symbolExists(name))
            _m.addSym(IRSymbol.runtime(name));
        return name;
        }

    // `recv.m(args)` — a direct Call unless the receiver's class dispatches
    // and the method has a slot, in which case the object itself says which
    // body runs.
    IRValue* lowerMethodCall(Node* n)
        {
        // Sema found the "method" was a FIELD holding something callable and
        // hung the real call on the node, past the receiver and arguments.
        // None of the dispatch below applies. private:docs/bugs/074.
        if (n.hasFlag((u32)NF_FIELDCALL))
            {
            u32 idx = (u32)n.num() + (u32)1;
            if (n.kidCount() > idx)
                return lowerExpr(n.kid(idx));
            }
        Node* recv = n.kid((u32)0);
        // `super.m(...)` names a body, not an object: it is the one call that
        // must NOT dispatch, because dispatching from an override would find
        // the override again and recurse forever. The analyser already said
        // which class the body belongs to; `self` is unchanged.
        if (recv.kind() == (u16)nkIdent && isName(recv.name(), "super"))
            return lowerSuperCall(n);
        ClassInfo* ci = classFor(pointeeOf(recv.ty()));
        // A PROTOCOL receiver has no class behind it at compile time: the
        // analyser stamped the slot, and the object itself says which body
        // runs. This is the whole point of the protocol.
        if (ci == 0 && n.vslot() >= (i32)0)
            {
            IRValue* pv = lowerExpr(recv);
            if (_failed)
                return (IRValue*)0;
            Array* pargs = new Array();
            for (u32 i = (u32)1; i < n.kidCount(); i = i + (u32)1)
                {
                IRValue* a = lowerExpr(n.kid(i));
                if (_failed)
                    return (IRValue*)0;
                pargs.add((Object*)a);
                }
            // Widen each argument to the REQUIREMENT's declared parameter
            // type. The dispatch pushes arguments at their own IR width, so a
            // narrow literal — `p.ping(5)` into an `i32` parameter — reaches
            // the callee one slot short and shifts its whole frame. The direct
            // and implicit-self paths already coerce; this is the same rule
            // for the one receiver whose class is not known here.
            coerceProtocolArgs(pargs, n);
            if (_itableDispatch && n.proto() != 0 && n.protoIdx() >= (i32)0)
                return emitProtoDispatch(pv, n.proto(), (u32)n.protoIdx(),
                                         pargs, n.ty());
            return emitDispatch(pv, (u32)n.vslot(), pargs, n.ty());
            }
        if (ci == 0)
            {
            giveUp(String.withCString("method call on a non-class"));
            return (IRValue*)0;
            }

        Node* decl = methodDeclFor(ci, n);
        // A STATIC method has no receiver at all — `Counter.bump()` names the
        // class, and the class name is not a value. Lowering the receiver here
        // would emit a load of something that does not exist.
        bool isStatic = decl != 0 && decl.hasFlag((u32)NF_STATIC);
        IRValue* recvVal = (IRValue*)0;
        if (!isStatic)
            {
            recvVal = lowerExpr(recv);
            if (_failed)
                return (IRValue*)0;
            }
        else
            {
            emitStaticInitGuard(ci);
            }
        // Every argument is EVALUATED first, and only then are they adjusted
        // to their parameters. Interleaving the two puts the first argument's
        // conversion ahead of the second argument's evaluation, which is a
        // different instruction order for the same program.
        Array* args = new Array();
        for (u32 i = (u32)1; i < n.kidCount(); i = i + (u32)1)
            {
            IRValue* a = lowerExpr(n.kid(i));
            if (_failed)
                return (IRValue*)0;
            args.add((Object*)a);
            }
        if (decl != 0)
            {
            for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
                {
                String* want = paramTypeAt(decl, i);
                if (want == 0)
                    continue;
                args.set(i, (Object*)coerceArg((IRValue*)args.get(i),
                                               n.kid(i + (u32)1).ty(), want));
                }
            }

        // A VARIADIC callee takes only its fixed parameters; the rest travel
        // in the shared buffer the callee's va_arg reads back.
        if (decl != 0 && decl.hasFlag((u32)NF_VARARGS))
            {
            rewriteEnumPercentE(args, n, (u32)1, fixedParamCount(decl));
            if (_failed)
                return (IRValue*)0;
            args = packVarargs(args, fixedParamCount(decl), decl);
            }
        String* retTy = n.ty();
        // Typed collection: sema resolved this call to the ELEMENT type, but the
        // callee still returns the erased `Object*`. The Call has to carry what
        // the callee really returns — typing it with the substituted type makes
        // the IR claim otherwise, and the inliner then pastes the body in
        // against the wrong layout. Bridge the two with a Bitcast, which is
        // what `coerce` emits for pointer-to-pointer.
        String* erasedRet = (String*)0;
        String* recvTy = (n.kidCount() > (u32)0) ? n.kid((u32)0).ty() : (String*)0;
        if (Node.elemOf(recvTy) != 0 && decl != 0 && decl.op() != 0 && retTy != 0)
            {
            String* declRet = firstReturn(decl.op());
            if (declRet != 0 && !declRet.equals(retTy))
                {
                erasedRet = declRet;
                retTy = declRet;
                }
            }
        bool hasRes = retTy != 0 && !isName(stripQual(retTy), "void");
        IRValue* res = (IRValue*)0;
        if (!isStatic && catSlotFor(ci, n) >= (i32)0)
            res = emitCatDispatch(recvVal, ci.catAnchor(),
                                  (u32)catSlotFor(ci, n), args, retTy);
        else if (!isStatic && slotFor(ci, n) >= (i32)0)
            res = emitDispatch(recvVal, (u32)slotFor(ci, n), args, retTy);
        else
            res = emitMethodCall(methodSymbolFor(ci, n), recvVal, args, retTy, hasRes);
        if (erasedRet != 0 && res != 0)
            {
            // Emitted DIRECTLY, not through coerce(): its same-shape early-out
            // treats two pointers of equal width as identical, so an
            // `Object*` -> `String*` crossing would pass straight through. The
            // owned temp moves to the Bitcast result, or the Release at the end
            // of the expression would name the value before the cast.
            Array* bops = new Array();
            bops.add((Object*)IROperand.useVal(res));
            IRValue* cast = emit(String.withCString("Bitcast"), irType(n.ty()), bops);
            retargetOwnedTemp(res, cast);
            res = cast;
            }
        return res;
        }

    // A bare call that names no free function but does name a `use`d class's
    // static method. Nothing distinguishes it at the call site — the receiver
    // was simply not written — so it lowers exactly as `Klass.m(…)` does.
    ClassInfo* usedClassFor(Node* n)
        {
        for (u32 u = (u32)0; u < _usedClasses.count(); u = u + (u32)1)
            {
            ClassInfo* ci = classFor((String*)_usedClasses.get(u));
            if (ci != 0 && methodDeclFor(ci, n) != 0)
                return ci;
            }
        return (ClassInfo*)0;
        }

    IRValue* lowerUsedStaticCall(ClassInfo* ci, Node* n)
        {
        Node* decl = methodDeclFor(ci, n);
        emitStaticInitGuard(ci);
        Array* args = new Array();
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            {
            IRValue* a = lowerExpr(n.kid(i));
            if (_failed)
                return (IRValue*)0;
            args.add((Object*)a);
            }
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            String* want = paramTypeAt(decl, i);
            if (want == 0)
                continue;
            args.set(i, (Object*)coerceArg((IRValue*)args.get(i),
                                           n.kid(i).ty(), want));
            }
        if (decl.hasFlag((u32)NF_VARARGS))
            {
            rewriteEnumPercentE(args, n, (u32)0, fixedParamCount(decl));
            if (_failed)
                return (IRValue*)0;
            args = packVarargs(args, fixedParamCount(decl), decl);
            }
        String* ret = n.ty();
        bool hasRes = ret != 0 && !isName(stripQual(ret), "void");
        return emitMethodCall(methodSymbolFor(ci, n), (IRValue*)0, args, ret, hasRes);
        }

    void coerceProtocolArgs(Array* args, Node* n)
        {
        if (n.proto() == 0)
            return;
        Object* pd = _protocols.get((Hashable*)n.proto());
        if (pd == 0)
            return;
        Node* proto = (Node*)pd;
        Node* req = (Node*)0;
        for (u32 i = (u32)0; i < proto.kidCount(); i = i + (u32)1)
            {
            Node* m = proto.kid(i);
            if (m.kind() != (u16)nkMethodDecl || !m.name().equals(n.name()))
                continue;
            if (fixedParamCount(m) != args.count())
                continue;
            req = m;
            break;
            }
        if (req == 0)
            return;
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            {
            String* want = paramTypeAt(req, i);
            if (want == 0)
                continue;
            args.set(i, (Object*)coerceArg((IRValue*)args.get(i),
                                           n.kid(i + (u32)1).ty(), want));
            }
        }

    IRValue* lowerSuperCall(Node* n)
        {
        if (_self == 0 || n.cls() == 0)
            {
            giveUp(String.withCString("super outside a method"));
            return (IRValue*)0;
            }
        ClassInfo* ci = classFor(n.cls());
        String* mangled = n.sym() == 0 ? n.name() : n.sym();
        String* sym = String.withString(n.cls());
        sym.appendByte((u8)'$');
        sym.append(mangled);
        Node* decl = ci == 0 ? (Node*)0 : methodDeclFor(ci, n);
        Array* args = new Array();
        for (u32 i = (u32)1; i < n.kidCount(); i = i + (u32)1)
            {
            IRValue* a = lowerExpr(n.kid(i));
            if (_failed)
                return (IRValue*)0;
            args.add((Object*)a);
            }
        if (decl != 0)
            {
            for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
                {
                String* want = paramTypeAt(decl, i);
                if (want == 0)
                    continue;
                args.set(i, (Object*)coerceArg((IRValue*)args.get(i),
                                               n.kid(i + (u32)1).ty(), want));
                }
            if (decl.hasFlag((u32)NF_VARARGS))
                args = packVarargs(args, fixedParamCount(decl), decl);
            }
        String* retTy = n.ty();
        bool hasRes = retTy != 0 && !isName(stripQual(retTy), "void");
        return emitMethodCall(sym, _self, args, retTy, hasRes);
        }

    // The slot this call dispatches through, or -1 for a direct call. The
    // slot map is keyed by method NAME, but a name can have several
    // overloads and only one of them occupies the slot: `String.equals` has
    // an `Object@` form that answers Comparable and a `String@` form that does
    // not. So the slot only applies when the symbol IT holds is the symbol
    // this call actually resolved to — otherwise dispatching would run a
    // different function with the same name.
    i32 slotFor(ClassInfo* ci, Node* call)
        {
        if (ci == 0 || !ci.needsVtable())
            return (i32)-1;
        Object* so = ci.methodSlot().get((Hashable*)call.name());
        if (so == 0)
            return (i32)-1;
        return (i32)((Number*)so).asU32();
        }

    // §4.2: the CHAIN slot for a call, or -1 — checked before the vtable slot
    // at both dispatch sites, exactly as the reference orders it.
    i32 catSlotFor(ClassInfo* ci, Node* call)
        {
        if (ci == 0 || !ci.needsVtable())
            return (i32)-1;
        if (ci.catSlot() == 0 || ci.catAnchor() == 0)
            return (i32)-1;
        Object* so = ci.catSlot().get((Hashable*)call.name());
        if (so == 0)
            return (i32)-1;
        return (i32)((Number*)so).asU32();
        }

    // Through an IMPLICIT self the slot is looked up by the MANGLED name,
    // which only matches when the method is not overloaded — the slot table
    // is keyed by plain name. So an overload resolves statically:
    // `String.equals(String@)` is not the `equals` that answers Comparable,
    // and dispatching would run the other one.
    i32 selfSlotFor(ClassInfo* ci, Node* call)
        {
        if (call.sym() != 0 && !call.sym().equals(call.name()))
            return (i32)-1;
        return slotFor(ci, call);
        }

    // Every vtable opens with header words — entry 0 the parent link, entry 1
    // the itable pointer, entry 2 the category chain — so a method's slot sits
    // that many words higher than the number sema gave it. Applied at the two
    // dispatch sites ONLY, so every other place a slot is spoken about stays
    // 0-based.
    //
    // The chain word rides the ancestry switch: it is a category on a class
    // from a module compiled EARLIER that needs it, and the single-module
    // targets merge such a category at compile time (separate-compilation
    // §4.2). It has to be reserved in every vtable on the multi-module
    // targets, a library's own included, or a client reading it off a
    // library-built receiver reads that class's first method pointer instead.
    u32 vtblSlotBias(void)
        {
        return (_vtAncestry ? (u32)2 : (u32)0) + (_vtItable ? (u32)1 : (u32)0);
        }

    IRValue* emitProtoDispatch(IRValue* recvVal, String* proto, u32 index,
                               Array* args, String* retTy)
        {
        IRInsn* d = IRInsn.with(String.withCString("ProtoDispatch"));
        d.add(IROperand.useVal(recvVal));
        d.add(IROperand.immU(protocolId(proto), String.withCString("U32")));
        d.add(IROperand.immI((i32)index, String.withCString("U16")));
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            d.add(IROperand.useVal((IRValue*)args.get(i)));
        d.add(IROperand.useVal(_mem));
        IRValue* r = (IRValue*)0;
        if (retTy != 0 && !isName(stripQual(retTy), "void"))
            {
            r = new IRValue(irType(retTy));
            d.setRes(r);
            }
        IRValue* nm = new IRValue(String.withCString("Mem"));
        d.setMemRes(nm);
        d.setCc(String.withCString("CallConv::Standard"));
        _blk.add(d);
        _mem = nm;
        noteOwnedTemp(r, retTy);
        return r;
        }

    // §4.2/§4.3b: dispatch a category method on a class from another module —
    // through the CATEGORY CHAIN, never a vtable slot (that vtable is already
    // emitted in an image we cannot renumber). The mirror of emitCatDispatch:
    //   vt = obj[0]; chain = vt[2]; t = chain ?: &anchor; own = t[0];
    //   tbl = own == &anchor ? t : &anchor; fn = tbl[1 + k]; fn(obj, args…)
    // The ownership compare is what makes MULTIPLE extenders sound: a table
    // that is not mine has the answer null always had — my own fallback.
    IRValue* emitCatMethodLoad(IRValue* recv, String* anchor, u32 slot)
        {
        String* voidPtr = ptrTo(String.withCString("Void"));
        String* ppVoid = ptrTo(voidPtr);
        Array* o1 = new Array();
        o1.add((Object*)IROperand.useVal(recv));
        IRValue* objPP = emit(String.withCString("Bitcast"), ppVoid, o1);
        IRValue* vtbl = loadThroughIr(objPP, voidPtr);
        Array* o2 = new Array();
        o2.add((Object*)IROperand.useVal(vtbl));
        IRValue* vtPP = emit(String.withCString("Bitcast"), ppVoid, o2);
        IRValue* chIdx = emitConstU16(vtblSlotBias() - (u32)1);
        Array* o3 = new Array();
        o3.add((Object*)IROperand.useVal(vtPP));
        o3.add((Object*)IROperand.useVal(chIdx));
        IRValue* chAddr = emit(String.withCString("ElementAddr"), ppVoid, o3);
        IRValue* chain = loadThroughIr(chAddr, voidPtr);
        return catTableSelect(chain, anchor, slot);
        }

    // The ownership half of emitCatMethodLoad — its own function so neither
    // side crosses the arm64 frame budget.
    IRValue* catTableSelect(IRValue* chain, String* anchor, u32 slot)
        {
        String* voidPtr = ptrTo(String.withCString("Void"));
        String* ppVoid = ptrTo(voidPtr);
        Array* o4 = new Array();
        o4.add((Object*)IROperand.sym(anchor));
        IRValue* fallback = emit(String.withCString("AddrOf"), voidPtr, o4);
        IRValue* zero = emitConstU16((u32)0);
        Array* o5 = new Array();
        o5.add((Object*)IROperand.useVal(zero));
        IRValue* nullP = emit(String.withCString("IntToPtr"), voidPtr, o5);
        IRInsn* ic = IRInsn.with(String.withCString("ICmp"));
        ic.setRes(new IRValue(String.withCString("Bool")));
        ic.setPred(String.withCString("EQ"));
        ic.add(IROperand.useVal(chain));
        ic.add(IROperand.useVal(nullP));
        _blk.add(ic);
        Array* s1 = new Array();
        s1.add((Object*)IROperand.useVal(ic.res()));
        s1.add((Object*)IROperand.useVal(fallback));
        s1.add((Object*)IROperand.useVal(chain));
        IRValue* t = emit(String.withCString("Select"), voidPtr, s1);
        Array* o6 = new Array();
        o6.add((Object*)IROperand.useVal(t));
        IRValue* tPP = emit(String.withCString("Bitcast"), ppVoid, o6);
        IRValue* ownIdx = emitConstU16((u32)0);
        Array* o7 = new Array();
        o7.add((Object*)IROperand.useVal(tPP));
        o7.add((Object*)IROperand.useVal(ownIdx));
        IRValue* ownAddr = emit(String.withCString("ElementAddr"), ppVoid, o7);
        IRValue* own = loadThroughIr(ownAddr, voidPtr);
        return catFnLoad(own, fallback, t, slot);
        }

    // …and the final table pick + code-word load, split once more for the
    // same frame-budget reason.
    IRValue* catFnLoad(IRValue* own, IRValue* fallback, IRValue* t, u32 slot)
        {
        String* voidPtr = ptrTo(String.withCString("Void"));
        String* ppVoid = ptrTo(voidPtr);
        IRInsn* im = IRInsn.with(String.withCString("ICmp"));
        im.setRes(new IRValue(String.withCString("Bool")));
        im.setPred(String.withCString("EQ"));
        im.add(IROperand.useVal(own));
        im.add(IROperand.useVal(fallback));
        _blk.add(im);
        Array* s2 = new Array();
        s2.add((Object*)IROperand.useVal(im.res()));
        s2.add((Object*)IROperand.useVal(t));
        s2.add((Object*)IROperand.useVal(fallback));
        IRValue* tbl = emit(String.withCString("Select"), voidPtr, s2);
        Array* o8 = new Array();
        o8.add((Object*)IROperand.useVal(tbl));
        IRValue* tblPP = emit(String.withCString("Bitcast"), ppVoid, o8);
        IRValue* fnIdx = emitConstU16(slot + (u32)1);
        Array* o9 = new Array();
        o9.add((Object*)IROperand.useVal(tblPP));
        o9.add((Object*)IROperand.useVal(fnIdx));
        IRValue* fnAddr = emit(String.withCString("ElementAddr"), ppVoid, o9);
        return loadThroughIr(fnAddr, voidPtr);
        }

    IRValue* emitConstU16(u32 v)
        {
        Array* ops = new Array();
        ops.add((Object*)IROperand.immI((i32)v, String.withCString("U16")));
        return emit(String.withCString("Const"), String.withCString("U16"), ops);
        }

    IRValue* emitCatDispatch(IRValue* recvVal, String* anchor, u32 slot,
                             Array* args, String* retTy)
        {
        IRValue* fn = emitCatMethodLoad(recvVal, anchor, slot);
        IRInsn* d = IRInsn.with(String.withCString("CallIndirect"));
        d.add(IROperand.useVal(fn));
        d.add(IROperand.useVal(recvVal));
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            d.add(IROperand.useVal((IRValue*)args.get(i)));
        d.add(IROperand.useVal(_mem));
        IRValue* r = (IRValue*)0;
        if (retTy != 0 && !isName(stripQual(retTy), "void"))
            {
            r = new IRValue(irType(retTy));
            d.setRes(r);
            }
        IRValue* nm = new IRValue(String.withCString("Mem"));
        d.setMemRes(nm);
        d.setCc(String.withCString("CallConv::Standard"));
        _blk.add(d);
        _mem = nm;
        noteOwnedTemp(r, retTy);
        return r;
        }

    IRValue* emitDispatch(IRValue* recvVal, u32 slot, Array* args, String* retTy)
        {
        IRInsn* d = IRInsn.with(String.withCString("VTblDispatch"));
        d.add(IROperand.useVal(recvVal));
        d.add(IROperand.immI((i32)slot + (i32)vtblSlotBias(),
                             String.withCString("U16")));
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            d.add(IROperand.useVal((IRValue*)args.get(i)));
        d.add(IROperand.useVal(_mem));
        IRValue* r = (IRValue*)0;
        if (retTy != 0 && !isName(stripQual(retTy), "void"))
            {
            r = new IRValue(irType(retTy));
            d.setRes(r);
            }
        IRValue* nm = new IRValue(String.withCString("Mem"));
        d.setMemRes(nm);
        d.setCc(String.withCString("CallConv::Standard"));
        _blk.add(d);
        _mem = nm;
        noteOwnedTemp(r, retTy);
        return r;
        }

    // The call OPCODE follows the callee's PLACEMENT, not the call site: a
    // banked callee lives in a window that has to be selected before the jump
    // and restored after it, so reaching it is a different instruction.
    IRValue* emitMethodCall(String* sym, IRValue* recvVal, Array* args,
                            String* retTy, bool hasRes)
        {
        String* op = String.withCString("Call");
        String* conv = String.withCString("CallConv::Standard");
        IRSymbol* callee = symbolNamed(sym);
        if (callee != 0 && callee.cloaked())
            {
            op = String.withCString("CallCloaked");
            conv = String.withCString("CallConv::Cloaked");
            }
        else if (callee != 0 && callee.banked())
            {
            op = String.withCString("CallBanked");
            conv = String.withCString("CallConv::Banked");
            }
        IRInsn* c = IRInsn.with(op);
        c.add(IROperand.sym(sym));
        if (recvVal != 0)
            c.add(IROperand.useVal(recvVal));
        for (u32 i = (u32)0; i < args.count(); i = i + (u32)1)
            c.add(IROperand.useVal((IRValue*)args.get(i)));
        c.add(IROperand.useVal(_mem));
        IRValue* r = (IRValue*)0;
        if (hasRes)
            {
            r = new IRValue(irType(retTy));
            c.setRes(r);
            }
        IRValue* nm = new IRValue(String.withCString("Mem"));
        c.setMemRes(nm);
        c.setCc(conv);
        _blk.add(c);
        _mem = nm;
        noteOwnedTemp(r, retTy);
        if (callee != 0 && callee.isThrowing())
            emitErrorCheckAfterCall();
        return r;
        }

    IRSymbol* symbolNamed(String* name)
        {
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* s = (IRSymbol*)_m.syms().get(i);
            if (s.name().equals(name))
                return s;
            }
        return (IRSymbol*)0;
        }

    // The method a call resolved to. The ANALYSER already chose among the
    // overloads and stamped the mangled name it chose; re-deciding here by
    // name alone picks whichever is declared first, which is how a
    // `print(i16)` became a `print(string)` and the argument was reinterpreted
    // as a pointer. So the mangled name is the answer, and the by-name walk is
    // only the fallback for a call the analyser left unstamped.
    Node* methodDeclFor(ClassInfo* ci, Node* call)
        {
        String* mangled = call.sym();
        for (ClassInfo* c = ci; c != 0; c = c.parent())
            {
            Node* d = c.decl();
            for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1)
                {
                Node* m = d.kid(i);
                if (m.kind() != (u16)nkMethodDecl || !m.name().equals(call.name()))
                    continue;
                if (mangled == 0)
                    return m;
                String* ms = m.sym() == 0 ? m.name() : m.sym();
                if (ms.equals(mangled))
                    return m;
                }
            }
        // No overload carried that mangled name — fall back to the name.
        for (ClassInfo* c = ci; c != 0; c = c.parent())
            {
            Node* d = c.decl();
            for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1)
                {
                Node* m = d.kid(i);
                if (m.kind() == (u16)nkMethodDecl && m.name().equals(call.name()))
                    return m;
                }
            }
        return (Node*)0;
        }

    // `<owner>$<mangled>`, with the owner the analyser named where it did and
    // the declaring class otherwise.
    String* methodSymbolFor(ClassInfo* ci, Node* call)
        {
        String* mangled = call.sym() == 0 ? call.name() : call.sym();
        if (call.cls() != 0)
            {
            String* sym = String.withString(call.cls());
            sym.appendByte((u8)'$');
            sym.append(mangled);
            if (symbolExists(sym))
                return sym;
            }
        for (ClassInfo* c = ci; c != 0; c = c.parent())
            {
            String* sym = String.withString(c.name());
            sym.appendByte((u8)'$');
            sym.append(mangled);
            if (symbolExists(sym))
                return sym;
            }
        String* sym = String.withString(ci.name());
        sym.appendByte((u8)'$');
        sym.append(mangled);
        return sym;
        }

    // A strong SLOT in memory owns what it holds, so overwriting it is the
    // same three steps as overwriting a strong local: read what is there,
    // retain a borrowed newcomer, release the incumbent, then store. Reading
    // first is what makes `x.f = x.f` safe.
    void storeStrongSlot(IRValue* addr, IRValue* v, String* slotTy, Node* rhs)
        {
        if (!isClassPointer(slotTy))
            {
            storeThrough(addr, v);
            return;
            }
        IRValue* old = loadThrough(addr, slotTy);
        if (rhsIsBorrowed(rhs))
            {
            if (isAnyClassPointer(rhs.ty()))
                refOp(String.withCString("Retain"), v);
            }
        else
            {
            consumeOwnedTemp(v);
            }
        refOp(String.withCString("Release"), old);
        storeThrough(addr, v);
        }

    // An IVAR is reached through `self`, whether or not the source said so.
    // `_n` inside a method means `self._n`, and the address is the same
    // FieldAddr either way.
    i32 ivarIndexOf(String* name)
        {
        if (_curClass == 0 || _self == 0 || name == 0)
            return (i32)-1;
        Object* o = _curClass.ivarIndex().get((Hashable*)name);
        if (o == 0)
            return (i32)-1;
        return (i32)((Number*)o).asU32();
        }

    IRValue* ivarAddr(String* name)
        {
        String* ty = (String*)_curClass.ivarType().get((Hashable*)name);
        return fieldAddr(_self, (u32)ivarIndexOf(name), ptrTo(irType(ty)));
        }

    // ── ARC ──────────────────────────────────────────────────────────────
    // A reference is OWNED or BORROWED, and the difference is whether anything
    // has to be undone. `new T()` hands over a +1 the slot adopts, so it needs
    // no Retain; every other way of naming an object borrows it, so a strong
    // slot has to take its own. Scope exit releases what the scope owns, in
    // reverse order of acquisition.

    void refOp(String* mnemonic, IRValue* p)
        {
        IRInsn* i = IRInsn.with(mnemonic);
        IRValue* nextMem = new IRValue(String.withCString("Mem"));
        i.setMemRes(nextMem);
        i.add(IROperand.useVal(p));
        i.add(IROperand.useVal(_mem));
        _blk.add(i);
        _mem = nextMem;
        }

    // A strong SLOT is one spelled as a pointer. `Box b = new Box()` names the
    // same object but is not a pointer type, so it owns nothing and nothing is
    // released for it — which is exactly what the original decides, and the
    // difference is visible at every scope exit.
    // A class pointer however it is SPELLED, weak included. The distinction
    // matters exactly once: a weak SLOT is not ARC-tracked storage, but a
    // weak VALUE read into a strong slot is a reference the slot now owns and
    // must claim. Answering NO there let the strong slot hold a pointer whose
    // only other owner could go away.
    bool isAnyClassPointer(String* t)
        {
        if (t == 0)
            return false;
        String* s = stripQual(t);
        if (s.byteLength() == (u32)0 || s.byteAt(s.byteLength() - (u32)1) != (u8)'*')
            return false;
        String* pointee = s.substringBytes((u32)0, s.byteLength() - (u32)1);
        return classFor(pointee) != 0 || _protocols.get((Hashable*)pointee) != 0;
        }

    // A `weak:T@` — auto-zeroing and owning nothing. A `^` is auto-zeroing
    // too but is a PAIR, and registers its recv word rather than its slot.
    bool isWeakClassPtr(String* t)
        {
        return t != 0 && isWeakSlot(t) && !isBoundSig(stripQual(t));
        }

    bool isClassPointer(String* t)
        {
        if (t == 0)
            return false;
        // A WEAK reference does not own — that is the whole of what weak
        // means — so it is never a strong slot however it is spelled.
        if (isWeakSlot(t))
            return false;
        String* s = stripQual(t);
        if (s.byteLength() == (u32)0 || s.byteAt(s.byteLength() - (u32)1) != (u8)'*')
            return false;
        String* pointee = s.substringBytes((u32)0, s.byteLength() - (u32)1);
        // A PROTOCOL pointer owns its referent exactly as a class pointer
        // does — which class is behind it changes nothing about who holds it.
        return classFor(pointee) != 0 || _protocols.get((Hashable*)pointee) != 0;
        }

    // A +1 arrives from `new`, and from any CALL that yields a class pointer:
    // a function handing back a reference hands back a claim on it, and the
    // slot adopts that rather than taking a second. A `^` call counts too —
    // it is dynamic, so there is no name to ask, and the convention is +1.
    //
    // A CAST is transparent to ownership: `(Number@ ?)m.get(k)` is as owned as
    // `m.get(k)`. Everything else is BORROWED, and the default has to say so —
    // getting "borrowed" wrong leaks, getting "owned" wrong frees an object
    // that is still reachable, and the second is much harder to find.
    bool rhsIsBorrowed(Node* rhs)
        {
        if (rhs == 0)
            return true;
        u16 k = rhs.kind();
        if (k == (u16)nkNew)
            return false;
        if (k == (u16)nkCast)
            return rhsIsBorrowed(rhs.kid((u32)0));
        if (k == (u16)nkCall)
            {
            if (rhs.boundCall())
                return false;
            return !isClassPointer(rhs.ty());
            }
        if (k == (u16)nkMethodCall)
            return !isClassPointer(rhs.ty());
        // A TERNARY is owned when EITHER arm is (private:docs/bugs/081). It used to
        // fall through to "borrowed", so `p = c ? new P() : new P()` was
        // retained on top of the +1 its arms had already delivered and leaked
        // one reference per evaluation — the whole object, every time.
        //
        // Either-arm, not both, because lowerTernary balances the paths: when
        // only one arm owns, the other is retained in its own block so the
        // join is +1 whichever way it went. The two rules have to agree, or
        // the binding adopts something that is only sometimes owned.
        if (k == (u16)nkTernary)
            {
            if (rhs.kidCount() < (u32)3)
                return true;
            return rhsIsBorrowed(rhs.kid((u32)1)) && rhsIsBorrowed(rhs.kid((u32)2));
            }
        return true;
        }

    void pushArcScope(void)
        {
        _arcScopes.add((Object*)new Array());
        _deferScopes.add((Object*)new Array());
        _shadowScopes.add((Object*)new Array());
        }

    // A declaration is about to BIND `name` in the current scope. If an outer
    // binding exists, save its state into the current shadow frame so the pop
    // can restore it (the reference's saveShadowedBindingsForName:). Without
    // this the name tables are FLAT: `for (u32 t ...)` after a `String* t`
    // rebound the name for the rest of the function, and the enclosing exit
    // released the loop counter as if it were the String (finding #16).
    void saveShadow(String* name)
        {
        if (name == 0 || name.byteLength() == (u32)0)
            return;
        if (_shadowScopes.count() == (u32)0)
            return;
        Array* frame = (Array*)_shadowScopes.get(_shadowScopes.count() - (u32)1);
        for (u32 i = (u32)0; i < frame.count(); i = i + (u32)1)
            if (((ShadowSave*)frame.get(i)).name().equals(name))
                return;
        Object* lv = _locals.get((Hashable*)name);
        Object* lt = _localTypes.get((Hashable*)name);
        bool st = hasName(_strongLocals, name);
        bool wp = hasName(_weakLocals, name);
        Object* sa = _strongArray.get((Hashable*)name);
        Object* wa = _weakArray.get((Hashable*)name);
        Object* ss = _strongStruct.get((Hashable*)name);
        Object* pn = _pins.get((Hashable*)name);
        Object* pa = _pinAst.get((Hashable*)name);
        Object* hl = _heapArrayLen.get((Hashable*)name);
        Object* ae = _arrayElem.get((Hashable*)name);
        // The TRIGGER must be exactly the reference's bound-set. _localTypes
        // is a port-only table and deliberately NOT part of it: unlike
        // _locals it is never rolled back per if-arm, so a name declared in
        // BOTH arms leaks its spelling from the first arm into the second,
        // and counting that as "bound" manufactured a save whose restore
        // then REMOVED the second arm's live binding (the join phi vanished
        // and irwide-diff caught the drift). It is still SAVED below — when
        // a real shadow triggers, restoring it keeps the port's own typing
        // state consistent.
        if (lv == 0 && !st && !wp && sa == 0 && wa == 0 && ss == 0 && pn == 0 && pa == 0 && hl == 0 && ae == 0)
            return;
        ShadowSave* sv = new ShadowSave();
        sv.setName(String.withString(name));
        sv.setLocal(lv);
        sv.setLocalTy(lt);
        sv.setStrong(st);
        sv.setWeakPinned(wp);
        sv.setStrongArr(sa);
        sv.setWeakArr(wa);
        sv.setStrongStruct(ss);
        sv.setPins(pn);
        sv.setPinAst(pa);
        sv.setHeapLen(hl);
        sv.setArrElem(ae);
        frame.add((Object*)sv);
        }

    // Undo the popped frame's shadows. Pure table surgery, emits nothing.
    void restoreShadows(Array* frame)
        {
        for (u32 i = (u32)0; i < frame.count(); i = i + (u32)1)
            {
            ShadowSave* sv = (ShadowSave*)frame.get(i);
            String* name = sv.name();
            if (sv.local() != 0)
                _locals.set((Hashable*)name, sv.local());
            else
                _locals.remove((Hashable*)name);
            if (sv.localTy() != 0)
                _localTypes.set((Hashable*)name, sv.localTy());
            else
                _localTypes.remove((Hashable*)name);
            if (sv.strong())
                addUnique(_strongLocals, name);
            else
                removeName(_strongLocals, name);
            if (sv.weakPinned())
                addUnique(_weakLocals, name);
            else
                removeName(_weakLocals, name);
            if (sv.strongArr() != 0)
                _strongArray.set((Hashable*)name, sv.strongArr());
            else
                _strongArray.remove((Hashable*)name);
            if (sv.weakArr() != 0)
                _weakArray.set((Hashable*)name, sv.weakArr());
            else
                _weakArray.remove((Hashable*)name);
            if (sv.strongStruct() != 0)
                _strongStruct.set((Hashable*)name, sv.strongStruct());
            else
                _strongStruct.remove((Hashable*)name);
            if (sv.pins() != 0)
                _pins.set((Hashable*)name, sv.pins());
            else
                _pins.remove((Hashable*)name);
            if (sv.pinAst() != 0)
                _pinAst.set((Hashable*)name, sv.pinAst());
            else
                _pinAst.remove((Hashable*)name);
            if (sv.heapLen() != 0)
                _heapArrayLen.set((Hashable*)name, sv.heapLen());
            else
                _heapArrayLen.remove((Hashable*)name);
            if (sv.arrElem() != 0)
                _arrayElem.set((Hashable*)name, sv.arrElem());
            else
                _arrayElem.remove((Hashable*)name);
            }
        }

    // `defer { … }` emits NOTHING where it stands — it registers its body
    // against the innermost scope, and every path out of that scope lowers the
    // body INLINE, last-registered-first. Inline rather than called: a defer is
    // a statement, not a value, so there is nothing to capture and nothing to
    // allocate — which is what lets the language have defer without closures.
    // A scope with several exits therefore emits the body once per exit.
    void emitDefersForScope(u32 idx)
        {
        if (idx >= _deferScopes.count())
            return;
        Array* bodies = (Array*)_deferScopes.get(idx);
        for (u32 i = bodies.count(); i > (u32)0; i = i - (u32)1)
            {
            Node* d = (Node*)bodies.get(i - (u32)1);
            if (d.kidCount() == (u32)0)
                continue;
            lowerStmt(d.kid((u32)0));
            if (_failed)
                return;
            }
        }

    // Enrol a local in the current ARC scope frame, ONCE. The frame is a list
    // of NAMES and the teardown releases the name's current binding for each
    // entry, so the same name twice is the same VALUE released twice. A
    // C-style `for` pushes no scope of its own, so two loops in one function
    // that both declare `Leaf@ c` enrol "c" twice in the enclosing frame — and
    // the victim is a BORROWED object whose real owner still holds it, so
    // nothing goes wrong until the allocator hands the block to someone else.
    // (private:docs/bugs/024.)
    // ARC, private:docs/bugs/064: a class-pointer PARAMETER the body ASSIGNS owns
    // whatever it holds — retained here at entry, released on every exit.
    //
    // Left borrowed, `p = someStrongLocal` bound the local's object into the
    // parameter with no retain: the local was still the owner, and its
    // scope-exit release deallocated the object the parameter was about to be
    // read through. Retaining only AT the assignment does not fix it either —
    // when the assignment is conditional the slot still holds the caller's
    // borrowed argument on the other path, and an unconditional scope-exit
    // release would then over-release it. Owning from entry is the only shape
    // right on both paths, and it is what the `self` retain already does.
    //
    // The count balances however often the parameter is rebound: the first
    // assignment releases this entry retain, each later one releases its
    // predecessor, and the scope exit releases the last.
    void retainAssignedParams(Node* d)
        {
        for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1)
            {
            Node* p = d.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            if (!hasName(_assignedNames, p.name()))
                continue;
            Object* pv = _locals.get((Hashable*)p.name());
            if (pv == (Object*)0)
                continue;
            refOp(String.withCString("Retain"), (IRValue*)pv);
            noteStrongLocal(p.name());
            }
        }

    void noteStrongLocal(String* name)
        {
        addUnique(_strongLocals, name);
        if (_arcScopes.count() == (u32)0)
            return;
        Array* frame = (Array*)_arcScopes.get(_arcScopes.count() - (u32)1);
        if (hasName(frame, name))
            return;
        frame.add((Object*)name);
        }

    // Every scope this exit leaves, innermost first, and within a scope the
    // names in reverse order of acquisition — a release can run the referent's
    // dealloc, which may read whatever it still holds.
    IRValue* _returning;
    // A tuple return has SEVERAL values leaving at once, and every one of them
    // is exempt from the teardown for the same reason a single one is.
    Array* _returningMore;

    bool isReturningValue(IRValue* v)
        {
        if (_returning != 0 && v == _returning)
            return true;
        if (_returningMore == 0)
            return false;
        for (u32 i = (u32)0; i < _returningMore.count(); i = i + (u32)1)
            if ((IRValue*)_returningMore.get(i) == v)
                return true;
        return false;
        }
    String* _returnExemptStruct; // a struct local whose +1 leaves with it
    Array* _ownedTemps;          // +1 results nothing has adopted yet

    // A call that hands back a class pointer hands back a CLAIM on it. If
    // nothing adopts that claim — no strong slot, no store, not the returned
    // value — it has to be released at the end of the full expression, or the
    // object leaks. Passing it as an ARGUMENT does not adopt it: the callee
    // borrows for the duration of the call and the caller still owns it.
    Array* _ownedBlocks; // the conditional DEPTH each pending temp was created at
    u32 _condDepth;      // how many conditional arms we are inside

    void noteOwnedTemp(IRValue* v, String* ty)
        {
        if (v == 0 || !isClassPointer(ty))
            return;
        if (_ownedTemps == 0)
            {
            _ownedTemps = new Array();
            _ownedBlocks = new Array();
            }
        _ownedTemps.add((Object*)v);
        _ownedBlocks.add((Object*)Number.with(_condDepth));
        }

    // Something took ownership: drop it from the pending set.
    void consumeOwnedTemp(IRValue* v)
        {
        if (v == 0 || _ownedTemps == 0)
            return;
        for (u32 i = (u32)0; i < _ownedTemps.count(); i = i + (u32)1)
            if ((IRValue*)_ownedTemps.get(i) == v)
                {
                _ownedTemps.removeAt(i);
                _ownedBlocks.removeAt(i);
                return;
                }
        }

    bool isOwnedTemp(IRValue* v)
        {
        if (_ownedTemps == 0)
            return false;
        for (u32 i = (u32)0; i < _ownedTemps.count(); i = i + (u32)1)
            if ((IRValue*)_ownedTemps.get(i) == v)
                return true;
        return false;
        }

    // Is this value what a STRONG local currently holds? Then its +1 is the
    // local's, and returning it transfers that rather than needing another.
    bool isStrongLocalValue(IRValue* v)
        {
        IRValue* root = bitcastRoot(v);
        for (u32 i = (u32)0; i < _strongLocals.count(); i = i + (u32)1)
            {
            Object* lv = _locals.get((Hashable*)(String*)_strongLocals.get(i));
            if (lv == 0)
                continue;
            if ((IRValue*)lv == v || (IRValue*)lv == root)
                return true;
            }
        return false;
        }

    // What this value was before any casts. A cast changes what the bits are
    // said to be, never who owns them.
    IRValue* bitcastRoot(IRValue* v)
        {
        IRValue* cur = v;
        for (u32 hop = (u32)0; hop < (u32)8; hop = hop + (u32)1)
            {
            bool moved = false;
            for (u32 i = (u32)0; i < _bcTo.count(); i = i + (u32)1)
                if ((IRValue*)_bcTo.get(i) == cur)
                    {
                    cur = (IRValue*)_bcFrom.get(i);
                    moved = true;
                    break;
                    }
            if (!moved)
                return cur;
            }
        return cur;
        }

    void retargetOwnedTemp(IRValue* from, IRValue* to)
        {
        if (_ownedTemps == 0)
            return;
        for (u32 i = (u32)0; i < _ownedTemps.count(); i = i + (u32)1)
            if ((IRValue*)_ownedTemps.get(i) == from)
                {
                _ownedTemps.set(i, (Object*)to);
                return;
                }
        }

    // A temp may only be released where it is DEFINITELY live. One created
    // inside a conditional arm — a ternary's branch, say — is not: control may
    // have taken the other arm and the value was never produced, so releasing
    // it at the join would decrement something that does not exist.
    //
    // The test is conditional DEPTH, not which block we are in. A static-init
    // guard branches and rejoins immediately, so it does not change depth —
    // and a temp created before one is still certainly live after it. Testing
    // block identity instead dropped exactly those, which leaks. Anything at a
    // deeper depth is left alone, which also leaks; that is the right way for
    // a rule that cannot be decided exactly here, because the other error
    // frees a live object.
    // Release (and forget) the pending owned temps recorded at `depth` — the
    // short-circuit arms only, where the arm's own value is a Bool and so
    // cannot be one of them. The ternary arms deliberately do NOT: there the
    // arm's value MAY be the temp.
    void releaseOwnedTempsAtDepth(u32 depth)
        {
        if (_ownedTemps == 0)
            return;
        Array* keepT = new Array();
        Array* keepB = new Array();
        Array* doomed = new Array();
        for (u32 i = (u32)0; i < _ownedTemps.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)_ownedTemps.get(i);
            if (((Number*)_ownedBlocks.get(i)).asU32() != depth)
                {
                keepT.add((Object*)v);
                keepB.add(_ownedBlocks.get(i));
                continue;
                }
            doomed.add((Object*)v);
            }
        // LAST registered, first released — the original walks its pending list
        // backwards, and two temps in one arm come out in that order.
        for (u32 i = doomed.count(); i > (u32)0; i = i - (u32)1)
            refOp(String.withCString("Release"), (IRValue*)doomed.get(i - (u32)1));
        _ownedTemps = keepT;
        _ownedBlocks = keepB;
        }

    void flushOwnedTemps(void)
        {
        if (_ownedTemps == 0)
            return;
        for (u32 i = (u32)0; i < _ownedTemps.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)_ownedTemps.get(i);
            if (isReturningValue(v))
                continue;
            if (((Number*)_ownedBlocks.get(i)).asU32() != _condDepth)
                continue;
            refOp(String.withCString("Release"), v);
            }
        _ownedTemps = new Array();
        _ownedBlocks = new Array();
        }

    void releaseAlongExit(void)
        {
        for (u32 si = _arcScopes.count(); si > (u32)0; si = si - (u32)1)
            {
            emitDefersForScope(si - (u32)1);
            if (_failed)
                return;
            Array* frame = (Array*)_arcScopes.get(si - (u32)1);
            for (u32 i = frame.count(); i > (u32)0; i = i - (u32)1)
                tearDownLocal((String*)frame.get(i - (u32)1));
            }
        // …and the `self` retained on entry, which the body has been holding
        // for the same reason: the caller may have dropped its only reference
        // mid-call.
        if (_retainedSelf != 0)
            refOp(String.withCString("Release"), _retainedSelf);
        // …and, in a `dealloc`, the receiver's own strong ivars. Freeing an
        // object releases the objects it owns, and through their release
        // dispatch their ivars in turn. Emitted at EVERY return path of a
        // dealloc, because each one is a way out of the object's life.
        releaseStrongIvarsForDealloc();
        }

    void releaseStrongIvarsForDealloc(void)
        {
        if (_curClass == 0 || _self == 0 || _fn == 0)
            return;
        if (!_fn.name().hasSuffix(String.withCString("$dealloc")))
            return;
        // In FIELD-INDEX order — the declaration order, which the indices
        // record. Walking 1..count would miss an ivar whose index the hidden
        // link words of an earlier auto-zeroing one pushed past the count.
        Array* names = sortedByIvarIndex(_curClass);
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* nm = (String*)names.get(i);
            // Only the class's OWN ivars: an inherited one is released by the
            // ancestor's dealloc, which the super-chain reaches.
            if (!declaresIvar(_curClass.decl(), nm))
                continue;
            String* ty = (String*)_curClass.ivarType().get((Hashable*)nm);
            u32 slot = ((Number*)_curClass.ivarIndex().get((Hashable*)nm)).asU32();
            // A WEAK ivar is not owned, so there is nothing to release — but
            // its side-table entry must go, or a later dealloc of the
            // still-live referent writes through this freed slot.
            if (isWeakClassPtr(ty))
                {
                weakOp(String.withCString("WeakUnregister"),
                       fieldAddr(_self, slot, ptrTo(irType(ty))), (IRValue*)0);
                continue;
                }
            // A `^` ivar is an auto-zeroing slot too: storing one links it into
            // the RECEIVER's chain so `if (f)` goes false when the receiver
            // dies. Unlink it here for the same reason as the weak case, and at
            // the same address the register site used — the RECV word, which is
            // field 0 of the pair.
            if (isBoundSig(stripQual(ty)))
                {
                IRValue* pairAddr = fieldAddr(_self, slot, ptrTo(irType(ty)));
                String* pp = ptrTo(ptrTo(String.withCString("Void")));
                weakOp(String.withCString("WeakUnregister"),
                       fieldAddr(pairAddr, (u32)0, pp), (IRValue*)0);
                continue;
                }
            // A STRUCT-typed ivar owns whatever strong pointers it holds,
            // however deep — the object owns the struct, and the struct owns
            // them. Skipped when it holds none, so nothing emits a dead
            // FieldAddr for a struct of plain scalars.
            if (structDeclFor(ty) != 0)
                {
                if (!structHasStrongPointer(ty))
                    continue;
                structFieldsAt(fieldAddr(_self, slot, ptrTo(irType(ty))), ty, false);
                continue;
                }
            if (!isClassPointer(ty))
                continue;
            IRValue* fa = fieldAddr(_self, slot, ptrTo(irType(ty)));
            refOp(String.withCString("Release"), loadThrough(fa, ty));
            }
        // The SUPER-CHAIN, after this class's own teardown: child before
        // parent. The ancestor's dealloc releases its own ivars and chains
        // further up, so the whole hierarchy comes apart exactly once — and
        // is skipped when the user body already said `super.dealloc()`, or it
        // would run twice.
        if (hasName(_deallocCallsSuper, _curClass.name()))
            return;
        for (ClassInfo* p = _curClass.parent(); p != 0; p = p.parent())
            {
            String* psym = String.withString(p.name());
            psym.appendCString("$dealloc");
            if (!symbolExists(psym))
                continue;
            Array* sargs = new Array();
            emitMethodCall(psym, _self, sargs, String.withCString("void"), false);
            return;
            }
        }

    // Does this subtree say `super.dealloc()` itself? The teardown appends
    // the chain call only when it does not.
    bool callsSuperDealloc(Node* n)
        {
        if (n == 0)
            return false;
        if (n.kind() == (u16)nkMethodCall && isName(n.name(), "dealloc") && n.kidCount() > (u32)0 && n.kid((u32)0).kind() == (u16)nkIdent && isName(n.kid((u32)0).name(), "super"))
            return true;
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            if (callsSuperDealloc(n.kid(i)))
                return true;
        return false;
        }

    Array* sortedByIvarIndex(ClassInfo* ci)
        {
        Array* names = sortedNames(ci.ivarIndex().allKeys());
        for (u32 i = (u32)1; i < names.count(); i = i + (u32)1)
            {
            u32 j = i;
            while (j > (u32)0 && ((Number*)ci.ivarIndex().get((Hashable*)(String*)names.get(j - (u32)1))).asU32() > ((Number*)ci.ivarIndex().get((Hashable*)(String*)names.get(j))).asU32())
                {
                Object* t = names.get(j - (u32)1);
                names.set(j - (u32)1, names.get(j));
                names.set(j, t);
                j = j - (u32)1;
                }
            }
        return names;
        }

    // The innermost scope only — a `return` uses releaseAlongExit, which walks
    // all of them. Reverse order of acquisition, for the same reason: a release
    // can run the referent's dealloc, which may read whatever it still holds.
    void releaseTopScope(void)
        {
        if (_arcScopes.count() == (u32)0)
            return;
        emitDefersForScope(_arcScopes.count() - (u32)1);
        if (_failed)
            return;
        Array* frame = (Array*)_arcScopes.get(_arcScopes.count() - (u32)1);
        for (u32 i = frame.count(); i > (u32)0; i = i - (u32)1)
            tearDownLocal((String*)frame.get(i - (u32)1));
        }

    // A strong local RELEASES what it owns. An auto-zeroing one owns nothing —
    // but its chain entry must come out, because the frame slot it points at
    // is about to be reused and the next dealloc would write a zero through a
    // stale address.
    void tearDownLocal(String* name)
        {
        if (_weakArray.get((Hashable*)name) != 0)
            {
            weakArrayUnregister(name);
            return;
            }
        if (_strongArray.get((Hashable*)name) != 0)
            {
            strongArrayARC(name, false);
            return;
            }
        if (_strongStruct.get((Hashable*)name) != 0)
            {
            if (_returnExemptStruct == 0 || !_returnExemptStruct.equals(name))
                structFieldARC(name, false);
            return;
            }
        // The value being RETURNED is not released: its +1 transfers to the
        // caller, and freeing it here would hand back a dead object.
        Object* lv = _locals.get((Hashable*)name);
        if (lv != 0 && isReturningValue((IRValue*)lv))
            return;
        if (lv != 0 && _returning != 0 && (IRValue*)lv == bitcastRoot(_returning))
            return;
        if (hasName(_weakLocals, name))
            {
            IRPinned* p = pinOf(name);
            if (p != 0)
                weakOp(String.withCString("WeakUnregister"),
                       pinAddrNamed(p, name), (IRValue*)0);
            return;
            }
        Object* v = _locals.get((Hashable*)name);
        if (v != 0)
            refOp(String.withCString("Release"), (IRValue*)v);
        }

    // WeakRegister takes the slot and the referent; WeakUnregister just the
    // slot. Both thread the memory token and produce nothing else.
    void weakOp(String* mnemonic, IRValue* slot, IRValue* target)
        {
        IRInsn* i = IRInsn.with(mnemonic);
        IRValue* nextMem = new IRValue(String.withCString("Mem"));
        i.setMemRes(nextMem);
        i.add(IROperand.useVal(slot));
        if (target != 0)
            i.add(IROperand.useVal(target));
        i.add(IROperand.useVal(_mem));
        _blk.add(i);
        _mem = nextMem;
        }

    // Release what every scope INSIDE `depth` owns, innermost first, without
    // popping them — the jump leaves them, but the lowering has not.
    void releaseScopesDownTo(u32 depth)
        {
        for (u32 si = _arcScopes.count(); si > depth; si = si - (u32)1)
            {
            emitDefersForScope(si - (u32)1);
            if (_failed)
                return;
            Array* frame = (Array*)_arcScopes.get(si - (u32)1);
            for (u32 i = frame.count(); i > (u32)0; i = i - (u32)1)
                tearDownLocal((String*)frame.get(i - (u32)1));
            }
        }

    void popArcScope(void)
        {
        if (_arcScopes.count() == (u32)0)
            return;
        Array* frame = (Array*)_arcScopes.get(_arcScopes.count() - (u32)1);
        for (u32 i = (u32)0; i < frame.count(); i = i + (u32)1)
            removeName(_strongLocals, (String*)frame.get(i));
        _arcScopes.removeAt(_arcScopes.count() - (u32)1);
        if (_deferScopes.count() > (u32)0)
            _deferScopes.removeAt(_deferScopes.count() - (u32)1);
        if (_shadowScopes.count() > (u32)0)
            {
            restoreShadows((Array*)_shadowScopes.get(_shadowScopes.count() - (u32)1));
            _shadowScopes.removeAt(_shadowScopes.count() - (u32)1);
            }
        }

    void removeName(Array* a, String* n)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(n))
                {
                a.removeAt(i);
                return;
                }
        }

    // ── classes ──────────────────────────────────────────────────────────
    // A class is registered before any body is lowered, parent first, because
    // a subclass's ivars sit after the parent's and its vtable inherits the
    // parent's slot numbering. Registration builds two layouts — the INSTANCE
    // (a vtable pointer, then the ivars root-first) and the VTABLE (one word
    // per slot) — in that order, which is why the module's layout table reads
    // as a class-by-class pairing.

    // A name that denotes a reference but carries no layout here: a protocol,
    // or a class whose own layout has not been built yet.
    // A bare identifier that names NOTHING this unit knows — no scalar, no
    // struct, no enum, no class, no protocol. Only asked about a POINTEE: an
    // unknown value type is still a hard stop, because its size is the
    // question and nothing here can answer it.
    bool unknownName(String* s)
        {
        if (s == 0 || s.byteLength() == (u32)0)
            return false;
        if (isArrayLike(s))
            return false;
        if (s.byteAt(s.byteLength() - (u32)1) == (u8)'*')
            return false;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            bool ok = (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_';
            if (!ok)
                return false;
            }
        if (Types.byteWidth(s) != (u32)0)
            return false;
        if (isName(s, "void") || isName(s, "string") || isName(s, "pointer"))
            return false;
        if (structDeclFor(s) != 0)
            return false;
        if (enumBase(s) != 0)
            return false;
        if (classFor(s) != 0)
            return false;
        return !isOpaqueRef(s);
        }

    bool isOpaqueRef(String* s)
        {
        if (_protocols.get((Hashable*)s) != 0)
            return true;
        return _classDecls.get((Hashable*)s) != 0 && _classes.get((Hashable*)s) == 0;
        }

    ClassInfo* classFor(String* name)
        {
        if (name == 0)
            return (ClassInfo*)0;
        Object* o = _classes.get((Hashable*)stripQual(name));
        if (o == 0)
            return (ClassInfo*)0;
        return (ClassInfo*)o;
        }

    // classFor, but a MISS pre-scans the class on demand (the reference's
    // classInfoResolvingName:). Used only from irType, so a type spelled
    // before its class's pre-scan still gets the real Agg. The busy map
    // breaks mutual-ivar recursion; entries are never removed because the
    // registered-class lookup wins first, which makes a stale entry inert.
    ClassInfo* classResolving(String* name)
        {
        if (name == 0)
            return (ClassInfo*)0;
        String* key = stripQual(name);
        ClassInfo* ci = classFor(key);
        if (ci != 0)
            return ci;
        if (_scanBusy.get((Hashable*)key) != 0)
            return (ClassInfo*)0;
        Object* d = _classDecls.get((Hashable*)key);
        if (d == 0)
            return (ClassInfo*)0;
        // Phase 1 only, as the reference does: running the FULL pre-scan
        // here would nest this class's signature loop inside whichever
        // signature loop triggered us, and a signature met while a third
        // class is mid-layout collapses to Ptr(Void).
        return preScanLayout((Node*)d);
        }

    // Every class with no declared parent is a child of Object. The analyser
    // synthesises one when the program declares none, and so does this — the
    // layouts it registers are the first two in the table, which is visible.
    Node* objectDecl(void)
        {
        if (_objectDecl == 0)
            {
            Object* o = _classDecls.get((Hashable*)String.withCString("Object"));
            if (o != 0)
                _objectDecl = (Node*)o;
            else
                _objectDecl = Node.withName((u16)nkClassDecl, String.withCString("Object"));
            }
        return _objectDecl;
        }

    // TWO phases, as the reference: phase 1 (preScanLayout) builds the
    // instance layout + selfPtr — all a TYPE ever needs — and registers;
    // phase 2 (preScanRest) does vtable/itable/category/method symbols,
    // parent-first, memoized. On-demand type resolution pulls only phase 1.
    ClassInfo* preScanClass(Node* cls)
        {
        ClassInfo* info = preScanLayout(cls);
        preScanRest(cls, info);
        return info;
        }

    ClassInfo* preScanLayout(Node* cls)
        {
        Object* cached = _classes.get((Hashable*)cls.name());
        if (cached != 0)
            return (ClassInfo*)cached;
        _scanBusy.set((Hashable*)cls.name(), (Object*)cls.name());

        // The parser spells "no parent" and "no protocols" as a dash, not as
        // an absent field, so both questions are asked that way here.
        ClassInfo* parent = (ClassInfo*)0;
        if (!absent(cls.op()))
            {
            Object* pd = _classDecls.get((Hashable*)cls.op());
            if (pd != 0)
                parent = preScanLayout((Node*)pd);
            }
        else if (!cls.name().equals(String.withCString("Object")))
            {
            parent = preScanLayout(objectDecl());
            }

        ClassInfo* info = new ClassInfo();
        info.setName(cls.name());
        info.setDecl(cls);
        info.setParent(parent);
        Object* cid = _classIds.get((Hashable*)cls.name());
        if (cid != 0)
            info.setClassId(((Number*)cid).asU32());
        // A class dispatches when it conforms to a protocol, inherits a
        // dispatching parent, or has a slot of its own. Everything else keeps
        // its methods statically bound and pays for no vtable at all.
        info.setNeedsVtable(!absent(cls.extra()) || (parent != 0 && parent.needsVtable()) || (cls.slots() != 0 && cls.slots().allKeys().count() > (u32)0));

        buildInstanceLayout(info, cls, parent);
        if (_failed)
            return info;
        // Register NOW, as the reference does: a type only ever needs the
        // class's selfPtr, and that exists the moment the layout does.
        // Registering after the vtable/signature work made the busy guard
        // fire for signature lookups mid-recursion, collapsing them to
        // Ptr(Void) — the very hole task #20 closes.
        _classes.set((Hashable*)cls.name(), (Object*)info);
        return info;
        }

    // Phase 2 — everything that reads OTHER classes' signatures or the
    // parent's phase-2 output. Parent-first, memoized.
    void preScanRest(Node* cls, ClassInfo* info)
        {
        if (_scanRestDone.get((Hashable*)cls.name()) != 0)
            return;
        _scanRestDone.set((Hashable*)cls.name(), (Object*)cls.name());

        if (!absent(cls.op()))
            {
            Object* pd = _classDecls.get((Hashable*)cls.op());
            if (pd != 0)
                preScanRest((Node*)pd, preScanLayout((Node*)pd));
            }
        else if (!cls.name().equals(String.withCString("Object")))
            {
            preScanRest(objectDecl(), preScanLayout(objectDecl()));
            }
        ClassInfo* parent = info.parent();

        // The method name -> symbol suffix map, inherited then own.
        if (parent != 0)
            copyInto(parent.methodMangled(), info.methodMangled());
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* m = cls.kid(i);
            if (m.kind() != (u16)nkMethodDecl || m.hasFlag((u32)NF_STATIC))
                continue;
            info.methodMangled().set((Hashable*)m.name(),
                                     (Object*)(m.sym() == 0 ? m.name() : m.sym()));
            }

        // §4.2: the chain family's side table — `<Host>$cat$<names>` (the
        // §4.3b owner anchor) for the host, `<Class>$cat` for a local
        // subclass — added BEFORE the vtable, as the reference does. Entry [0]
        // is the anchor (self-referential in the fallback); entries 1.. the
        // impl per chain slot. Its layout precedes the vtable's.
        String* catTblName = (String*)0;
        IRLayout* catLay = (IRLayout*)0;
        if (_vtAncestry && cls.chainHost() != 0 && cls.chainCount() > (u32)0)
            {
            bool isHost = cls.name().equals(cls.chainHost());
            if (isHost)
                {
                catTblName = String.withString(cls.chainAnchor());
                }
            else
                {
                catTblName = String.withString(cls.name());
                catTblName.appendCString("$cat");
                }
            Array* cents = new Array();
            cents.add((Object*)cls.chainAnchor());
            for (u32 s = (u32)0; s < cls.chainCount(); s = s + (u32)1)
                cents.add((Object*)chainSlotSymbolFor(cls, s));
            IRLayout* clay = IRLayout.with(((u32)1 + cls.chainCount()) * (u32)2, (u32)1);
            for (u32 s = (u32)0; s <= cls.chainCount(); s = s + (u32)1)
                clay.addField(s * (u32)2, ptrTo(String.withCString("Void")));
            // The layout ENTRY is emitted between the conformance tables and
            // the vtable layout — the original's order, visible in the
            // printed layout table now that the ambient prelude gives every
            // unit conformances (task #36). The symbol keeps its position;
            // nothing references the layout id.
            catLay = clay;
            _pendingCatSym = IRSymbol.vtable(catTblName, cents);
            info.setCat(cls.chainSlots(), cls.chainAnchor());
            }
        _pendingCatLay = catLay;
        buildVtable(info, cls, parent, catTblName);
        if (_pendingCatSym != 0)
            {
            _m.addSym(_pendingCatSym);
            _pendingCatSym = (IRSymbol*)0;
            }
        _pendingCatLay = (IRLayout*)0;

        // Only a dispatching class gets a vtable SYMBOL — the entries are
        // still built for everyone, so a dispatching subclass can inherit a
        // non-dispatching parent's method symbols. A class from ANOTHER module
        // marks its vtable extern: the table is emitted where the class was
        // compiled, and this module only references it.
        if (info.needsVtable())
            {
            String* vn = String.withString(cls.name());
            vn.appendCString("$vtbl");
            IRSymbol* vs = IRSymbol.vtable(vn, info.vtblEntries());
            if (cls.hasFlag((u32)NF_EXTERNAL))
                {
                vs.setAttr(String.withCString("extern"), true);
                // …and it resolves through the LIBRARY's package on a target
                // where modules import from each other by name.
                if (cls.pkg() != (String*)0 && cls.pkg().byteLength() > (u32)0)
                    vs.setAttr(String.withFormat("pkg_%s", cls.pkg().cString()), true);
                }
            _m.addSym(vs);
            }

        // One symbol per method with a body — and for an EXTERNAL class, per
        // method full stop: its bodies live in its own module, but the symbol
        // must exist here for every call site to name (the reference registers
        // externs the same way; the body lowering skips them naturally, there
        // being no body). Hidden `self` is the first formal of an instance
        // method, and there is no `cabi` on a method.
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* m = cls.kid(i);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (methodBody(m) == 0 && !cls.hasFlag((u32)NF_EXTERNAL))
                continue;
            IRSymbol* msym = IRSymbol.method(methodSymbolName(cls, m), methodSignature(info, m),
                                             m.hasFlag((u32)NF_VARARGS), m.hasFlag((u32)NF_STATIC));
            // An imported class's METHODS live in its library too, and a call
            // to one is an import from that library's package.
            if (cls.hasFlag((u32)NF_EXTERNAL) && cls.pkg() != (String*)0 && cls.pkg().byteLength() > (u32)0)
                msym.setAttr(String.withFormat("pkg_%s", cls.pkg().cString()), true);
            msym.setPlacement(m.hasFlag((u32)NF_BANKED), m.hasFlag((u32)NF_CLOAKED));
            if (m.hasFlag((u32)NF_THROWS))
                msym.setThrows();
            // Methods are a SEPARATE symbol path from free functions, in both
            // compilers — `String.withFormat` is a static method, so setting
            // this only on the function path left every method forwarder
            // without it (private:docs/bugs/047).
            if (m.hasFlag((u32)NF_VAFWD))
                msym.setAttr(String.withCString("vaforward"), true);
            _m.addSym(msym);
            // The return type is FROZEN here, at the moment the symbol is
            // made. A class named in it that has not been registered yet
            // collapses to an opaque pointer, and the body must agree with the
            // signature — resolving it again later, when every class IS
            // registered, would give the function a different type from its
            // own symbol.
            _methodRetIr.set((Hashable*)methodSymbolName(cls, m),
                             (Object*)irType(firstReturn(m.op())));
            Array* pts = new Array();
            for (u32 j = (u32)0; j < m.kidCount(); j = j + (u32)1)
                if (m.kid(j).kind() == (u16)nkParam)
                    pts.add((Object*)irType(m.kid(j).op()));
            _methodParIr.set((Hashable*)methodSymbolName(cls, m), (Object*)pts);
            }
        // After the declared methods, so a generated destructor follows them
        // in the symbol table — and so the check for "does this class already
        // have one" sees every method it declares.
        registerSynthesisedDealloc(info, cls);
        }

    // The instance: a vtable pointer at slot 0, then every ivar in the chain
    // ROOT first — so a base-class pointer finds the base's ivars at the same
    // offsets whatever the dynamic type turns out to be.
    void buildInstanceLayout(ClassInfo* info, Node* cls, ClassInfo* parent)
        {
        Array* offs = new Array();
        Array* tys = new Array();
        offs.add((Object*)Number.with((u32)0));
        tys.add((Object*)ptrTo(String.withCString("Void")));
        u32 off = _ptrW; // the slot is a pointer, so a pointer wide
        u32 fieldIndex = (u32)1;

        Array* chain = new Array(); // ancestors, ROOT first
        for (ClassInfo* a = parent; a != 0; a = a.parent())
            chain.insert((u32)0, (Object*)a);
        for (u32 c = (u32)0; c < chain.count(); c = c + (u32)1)
            {
            Node* anc = ((ClassInfo*)chain.get(c)).decl();
            fieldIndex = addIvarFields(info, anc, offs, tys, fieldIndex);
            }
        off = recomputeOffsets(offs, tys, info, cls, chain);
        IRLayout* inst = IRLayout.with(off, (u32)1);
        for (u32 i = (u32)0; i < offs.count(); i = i + (u32)1)
            inst.addField(((Number*)offs.get(i)).asU32(), (String*)tys.get(i));
        u32 instId = _m.addLayout(inst);
        String* agg = String.withCString("Agg(");
        agg.appendFormat("%ld", (i32)instId);
        agg.appendCString(")");
        info.setAgg(agg, ptrTo(agg));
        info.setInstSize(off);
        }

    u32 addIvarFields(ClassInfo* info, Node* owner, Array* offs, Array* tys, u32 fieldIndex)
        {
        for (u32 i = (u32)0; i < owner.kidCount(); i = i + (u32)1)
            {
            Node* iv = owner.kid(i);
            if (iv.kind() != (u16)nkVariableDecl)
                continue;
            if (iv.hasFlag((u32)NF_STATIC))
                {
                // A `static` ivar is ONE module global for the whole class,
                // not a per-instance slot — so it occupies no field index and
                // does not move the ones after it.
                registerStaticIvar(owner, iv);
                continue;
                }
            // Two hidden LINK words precede an auto-zeroing ivar's payload.
            // The recorded index is the PAYLOAD's, so every load and store of
            // the ivar is unchanged and only the layout knows.
            if (isWeakSlot(iv.op()))
                {
                offs.add((Object*)Number.with((u32)0));
                tys.add((Object*)ptrTo(String.withCString("Void")));
                offs.add((Object*)Number.with((u32)0));
                tys.add((Object*)ptrTo(String.withCString("Void")));
                fieldIndex = fieldIndex + (u32)2;
                }
            offs.add((Object*)Number.with((u32)0));
            tys.add((Object*)irType(iv.op()));
            info.ivarIndex().set((Hashable*)iv.name(), (Object*)Number.with(fieldIndex));
            info.ivarType().set((Hashable*)iv.name(), (Object*)iv.op());
            fieldIndex = fieldIndex + (u32)1;
            }
        return fieldIndex;
        }

    // `__sivar_<Class>_<name>` — the class's own storage for a value that
    // outlives every instance. Zeroed unless the declaration carries a
    // constant-foldable initialiser, exactly as a function-local `static`
    // does, and for the same reason: it has to survive between calls and its
    // initialiser must run once, at load time.
    void registerStaticIvar(Node* cls, Node* iv)
        {
        String* name = String.withCString("__sivar_");
        name.append(cls.name());
        name.appendByte((u8)'_');
        name.append(iv.name());
        String* key = String.withString(cls.name());
        key.appendByte((u8)'.');
        key.append(iv.name());
        _staticIvar.set((Hashable*)key, (Object*)name);
        _staticIvarTy.set((Hashable*)key, (Object*)iv.op());
        if (symbolExists(name))
            return;
        IRSymbol* g = IRSymbol.dataGlobal(name, irType(iv.op()));
        if (iv.kidCount() > (u32)0)
            {
            _constOk = true;
            i32 v = constEval(iv.kid((u32)0));
            if (_constOk)
                g.setBytes(leBytes(v, astWidth(iv.op())));
            }
        _m.addSym(g);
        }

    // The global a static ivar name resolves to inside the class, walking the
    // chain: an inherited static is still one shared slot.
    String* staticIvarFor(ClassInfo* ci, String* name)
        {
        for (ClassInfo* c = ci; c != 0; c = c.parent())
            {
            String* key = String.withString(c.name());
            key.appendByte((u8)'.');
            key.append(name);
            Object* g = _staticIvar.get((Hashable*)key);
            if (g != 0)
                return (String*)g;
            }
        return (String*)0;
        }

    String* staticIvarTypeFor(ClassInfo* ci, String* name)
        {
        for (ClassInfo* c = ci; c != 0; c = c.parent())
            {
            String* key = String.withString(c.name());
            key.appendByte((u8)'.');
            key.append(name);
            Object* t = _staticIvarTy.get((Hashable*)key);
            if (t != 0)
                return (String*)t;
            }
        return (String*)0;
        }

    // Offsets are assigned in one pass at the end because the field TYPES had
    // to be resolved first — resolving one can register a layout of its own,
    // and the table's order is part of the output.
    u32 recomputeOffsets(Array* offs, Array* tys, ClassInfo* info, Node* cls, Array* chain)
        {
        u32 fieldIndex = (u32)offs.count();
        addIvarFields(info, cls, offs, tys, fieldIndex);
        Array* order = new Array();
        for (u32 c = (u32)0; c < chain.count(); c = c + (u32)1)
            collectIvarTypes(((ClassInfo*)chain.get(c)).decl(), order);
        collectIvarTypes(cls, order);
        u32 off = _ptrW;
        offs.set((u32)0, (Object*)Number.with((u32)0));
        u32 fi = (u32)1;
        // Ivars follow the same (capped) natural alignment rule as struct
        // fields, the class's alignment is the max over its slots (vtable
        // pointer included), and the instance size tail-rounds to it so
        // `new T[N]` strides correctly. Cap 1 reproduces the historical
        // packed layout, including the absent tail rounding. The mirror of
        // the original's instance-layout accumulator.
        u32 instAlign = fieldAlignFor(String.withCString("u8*"));
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            String* ty = (String*)order.get(i);
            u32 fa = fieldAlignFor(ty);
            if (fa > instAlign)
                instAlign = fa;
            off = (off + fa - (u32)1) & ~(fa - (u32)1);
            if (isWeakSlot(ty))
                {
                offs.set(fi, (Object*)Number.with(off));
                off = off + _ptrW;
                offs.set(fi + (u32)1, (Object*)Number.with(off));
                off = off + _ptrW;
                fi = fi + (u32)2;
                }
            offs.set(fi, (Object*)Number.with(off));
            off = off + sizeOf(ty);
            fi = fi + (u32)1;
            }
        off = (off + instAlign - (u32)1) & ~(instAlign - (u32)1);
        return off;
        }

    void collectIvarTypes(Node* owner, Array* out)
        {
        for (u32 i = (u32)0; i < owner.kidCount(); i = i + (u32)1)
            {
            Node* iv = owner.kid(i);
            if (iv.kind() != (u16)nkVariableDecl || iv.hasFlag((u32)NF_STATIC))
                continue;
            out.add((Object*)iv.op());
            }
        }

    // The vtable. Two numberings, and which applies is whether the analyser
    // assigned slots: with them, one field per GLOBAL slot and the entries
    // come straight from it (inheritance already resolved); without, the
    // parent's ordering with this class's new methods appended. A class that
    // dispatches nothing still gets a layout, sized by its method count.
    void buildVtable(ClassInfo* info, Node* cls, ClassInfo* parent, String* catTblName)
        {
        u32 vtblOff = (u32)0;
        if (info.needsVtable() && cls.slots() != 0 && cls.vslots() > (u32)0)
            {
            for (u32 s = (u32)0; s < cls.vslots(); s = s + (u32)1)
                {
                info.vtblEntries().add((Object*)slotSymbolFor(cls, s));
                vtblOff = vtblOff + (u32)2;
                }
            fillProtocolSlots(info, cls);
            copyInto(cls.slots(), info.methodSlot());
            // The itable pointer, ahead of the methods. EVERY class reserves
            // it — null when the class conforms to nothing — so a conformance
            // search reaches it at the same offset in any receiver.
            if (_vtItable)
                {
                info.vtblEntries().insert((u32)0, (Object*)buildItable(info, cls));
                vtblOff = vtblOff + (u32)2;
                }
            if (_pendingCatLay != 0)
                {
                _m.addLayout(_pendingCatLay);
                _pendingCatLay = (IRLayout*)0;
                }
            if (_pendingCatSym != 0)
                {
                _m.addSym(_pendingCatSym);
                _pendingCatSym = (IRSymbol*)0;
                }
            // The category-chain word, AFTER the itable so the conformance
            // helper's vtbl[1] is untouched. Null on every class outside a
            // chain family; a family member's names its own `$cat` table
            // (§4.2, the iface importer being what lets a class from another
            // module appear here at all).
            if (_vtAncestry && info.needsVtable())
                {
                info.vtblEntries().insert(_vtItable ? (u32)1 : (u32)0,
                                          (Object*)(catTblName != 0 ? catTblName : String.withCString("")));
                vtblOff = vtblOff + (u32)2;
                }
            }
        else
            {
            vtblOff = buildLegacyVtable(info, cls, parent);
            }
        // The ancestry link goes in front of BOTH numberings, so dispatch's
        // single universal +1 lands every method correctly whichever path
        // assigned the slots. A root, or a parent that does not dispatch,
        // links to null and terminates the walk.
        if (_vtAncestry && info.needsVtable())
            {
            String* pv = String.withCString("");
            if (parent != 0 && parent.needsVtable())
                {
                pv = String.withString(parent.name());
                pv.appendCString("$vtbl");
                }
            info.vtblEntries().insert((u32)0, (Object*)pv);
            vtblOff = vtblOff + (u32)2;
            }
        IRLayout* vt = IRLayout.with(vtblOff, (u32)1);
        for (u32 i = (u32)0; i < vtblOff / (u32)2; i = i + (u32)1)
            vt.addField(i * (u32)2, ptrTo(String.withCString("Void")));
        _m.addLayout(vt);
        }

    // A class's own slot map names each method ONCE, but a method can answer
    // more than one requirement: `equals` is Comparable's and Hashable's, at
    // two different slots. So after the class's own slots are placed, every
    // protocol it conforms to — its own or an ancestor's — has its still-empty
    // requirement slots filled with whichever implementation the chain offers.
    // The conformance itable: one table per protocol this class answers to,
    // laid out in the PROTOCOL's own declaration order — an index every module
    // derives identically, so no agreement between them is needed. The itable
    // itself is (protoId, &table) pairs with a zero id terminating it.
    //
    // Conformance is INHERITED, so the walk is up the ancestor chain, not just
    // this class's own list: every class descends from Object, which conforms
    // to Hashable and Comparable, so a plain `class Box {}` is reachable
    // through `Hashable@` without saying anything.
    String* buildItable(ClassInfo* info, Node* cls)
        {
        Array* names = new Array(); // protocol names, nearest first
        Array* rows = new Array();  // Array@ of impl symbol names
        for (Node* c = cls; c != 0; c = parentDeclOf(c))
            {
            Array* protos = splitList(c.extra());
            for (u32 i = (u32)0; i < protos.count(); i = i + (u32)1)
                {
                String* pn = (String*)protos.get(i);
                if (hasName(names, pn))
                    continue; // nearest declaration wins
                Object* pd = _protocols.get((Hashable*)pn);
                if (pd == 0)
                    continue;
                Node* proto = (Node*)pd;
                Array* row = new Array();
                for (u32 j = (u32)0; j < proto.kidCount(); j = j + (u32)1)
                    {
                    Node* req = proto.kid(j);
                    if (req.kind() != (u16)nkMethodDecl)
                        continue;
                    // "" where an `optional` requirement is unimplemented — a
                    // null entry, which is exactly what `&obj.method` tests.
                    String* sym = implementorOf(cls, req.name(), req);
                    row.add((Object*)(sym == 0 ? String.withCString("") : sym));
                    }
                names.add((Object*)pn);
                rows.add((Object*)row);
                }
            }
        if (names.count() == (u32)0)
            return String.withCString("");

        Array* order = new Array();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            order.add(names.get(i));
        Vtable.sortStrings(order);

        Array* pairs = new Array();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            String* pn = (String*)order.get(i);
            u32 at = (u32)0;
            for (u32 k = (u32)0; k < names.count(); k = k + (u32)1)
                if (((String*)names.get(k)).equals(pn))
                    at = k;
            Array* row = (Array*)rows.get(at);
            String* tab = String.withString(cls.name());
            tab.appendCString("$");
            tab.append(pn);
            tab.appendCString("$itab");
            addTableLayout(row.count());
            _m.addSym(IRSymbol.vtable(tab, row));
            String* pid = String.withCString("__protoid_");
            pid.appendFormat("%lu", (i32)protocolId(pn));
            pairs.add((Object*)pid);
            pairs.add((Object*)tab);
            }
        pairs.add((Object*)String.withCString("__protoid_0"));
        pairs.add((Object*)String.withCString(""));
        String* itbl = String.withString(cls.name());
        itbl.appendCString("$itbl");
        addTableLayout(pairs.count());
        _m.addSym(IRSymbol.vtable(itbl, pairs));
        return itbl;
        }

    // A table of `n` words. Its layout is registered like any other, because
    // the layout table's ORDER is part of the output.
    void addTableLayout(u32 n)
        {
        IRLayout* L = IRLayout.with(n * (u32)2, (u32)1);
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            L.addField(i * (u32)2, ptrTo(String.withCString("Void")));
        _m.addLayout(L);
        }

    // FNV-1a over the protocol's name. It is what makes a protocol id agree
    // across separately compiled modules: nothing is shared but the spelling.
    // Zero terminates the itable, so it is never an id.
    u32 protocolId(String* name)
        {
        u32 h = (u32)2166136261;
        for (u32 i = (u32)0; i < name.byteLength(); i = i + (u32)1)
            {
            h = h ^ (u32)name.byteAt(i);
            h = h * (u32)16777619;
            }
        return h == (u32)0 ? (u32)1 : h;
        }

    void fillProtocolSlots(ClassInfo* info, Node* cls)
        {
        if (_vt == 0)
            return;
        for (Node* c = cls; c != 0; c = parentDeclOf(c))
            {
            Array* protos = splitList(c.extra());
            for (u32 i = (u32)0; i < protos.count(); i = i + (u32)1)
                {
                String* pn = (String*)protos.get(i);
                Map* ps = _vt.protoSlotsFor(pn);
                Object* pd = _protocols.get((Hashable*)pn);
                if (ps == 0 || pd == 0)
                    continue;
                Node* proto = (Node*)pd;
                for (u32 j = (u32)0; j < proto.kidCount(); j = j + (u32)1)
                    {
                    Node* req = proto.kid(j);
                    if (req.kind() != (u16)nkMethodDecl)
                        continue;
                    Object* so = ps.get((Hashable*)req.name());
                    if (so == 0)
                        continue;
                    u32 slot = ((Number*)so).asU32();
                    if (slot >= info.vtblEntries().count())
                        continue;
                    if (((String*)info.vtblEntries().get(slot)).byteLength() > (u32)0)
                        continue;
                    String* sym = implementorOf(cls, req.name(), req);
                    if (sym != 0)
                        info.vtblEntries().set(slot, (Object*)sym);
                    }
                }
            }
        }

    // The nearest class up the chain that declares `name` — and, among that
    // class's overloads of it, the one whose parameters match what the slot
    // expects. Falling back to the first would put `equals(String@)` where
    // `equals(Object@)` was asked for, and every comparison through the
    // protocol would land in the wrong body.
    String* implementorOf(Node* cls, String* name, Node* want)
        {
        for (Node* c = cls; c != 0; c = parentDeclOf(c))
            {
            Node* fallback = (Node*)0;
            for (u32 j = (u32)0; j < c.kidCount(); j = j + (u32)1)
                {
                Node* m = c.kid(j);
                if (m.kind() != (u16)nkMethodDecl || !m.name().equals(name))
                    continue;
                // A SYNTHESISED method fills no slot: it did not exist when the
                // slots were numbered, so the slot still belongs to whichever
                // ancestor's method the numbering saw. `new B()` still calls
                // `B$init` directly — the vtable is a different question.
                if (m.hasFlag((u32)NF_SYNTH))
                    continue;
                if (want != 0 && paramsMatch(m, want))
                    return methodSymbolName(c, m);
                if (fallback == 0)
                    fallback = m;
                }
            if (fallback != 0)
                return methodSymbolName(c, fallback);
            }
        return (String*)0;
        }

    // The protocol requirement that owns slot `s`, looking at every protocol
    // this class or an ancestor conforms to.
    Node* protoReqForSlot(Node* cls, u32 s)
        {
        if (_vt == 0)
            return (Node*)0;
        for (Node* c = cls; c != 0; c = parentDeclOf(c))
            {
            Array* protos = splitList(c.extra());
            for (u32 i = (u32)0; i < protos.count(); i = i + (u32)1)
                {
                String* pn = (String*)protos.get(i);
                Map* ps = _vt.protoSlotsFor(pn);
                Object* pd = _protocols.get((Hashable*)pn);
                if (ps == 0 || pd == 0)
                    continue;
                Node* proto = (Node*)pd;
                for (u32 j = (u32)0; j < proto.kidCount(); j = j + (u32)1)
                    {
                    Node* req = proto.kid(j);
                    if (req.kind() != (u16)nkMethodDecl)
                        continue;
                    Object* so = ps.get((Hashable*)req.name());
                    if (so != 0 && ((Number*)so).asU32() == s)
                        return req;
                    }
                }
            }
        return (Node*)0;
        }

    Node* methodNamed(Node* cls, String* name)
        {
        for (u32 j = (u32)0; j < cls.kidCount(); j = j + (u32)1)
            {
            Node* m = cls.kid(j);
            if (m.kind() == (u16)nkMethodDecl && m.name().equals(name))
                return m;
            }
        return (Node*)0;
        }

    bool paramsMatch(Node* a, Node* b)
        {
        Array* pa = paramSpellings(a);
        Array* pb = paramSpellings(b);
        if (pa.count() != pb.count())
            return false;
        for (u32 i = (u32)0; i < pa.count(); i = i + (u32)1)
            if (!((String*)pa.get(i)).equals((String*)pb.get(i)))
                return false;
        return true;
        }

    Array* paramSpellings(Node* m)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < m.kidCount(); i = i + (u32)1)
            if (m.kid(i).kind() == (u16)nkParam)
                out.add((Object*)m.kid(i).op());
        return out;
        }

    // `Hashable,Comparable` -> the two names. A dash means none.
    Array* splitList(String* s)
        {
        Array* out = new Array();
        if (absent(s))
            return out;
        u32 start = (u32)0;
        for (u32 i = (u32)0; i <= s.byteLength(); i = i + (u32)1)
            {
            if (i < s.byteLength() && s.byteAt(i) != (u8)',')
                continue;
            if (i > start)
                out.add((Object*)s.substringBytes(start, i - start));
            start = i + (u32)1;
            }
        return out;
        }

    u32 buildLegacyVtable(ClassInfo* info, Node* cls, ClassInfo* parent)
        {
        if (parent != 0)
            {
            for (u32 i = (u32)0; i < parent.vtblEntries().count(); i = i + (u32)1)
                info.vtblEntries().add(parent.vtblEntries().get(i));
            copyInto(parent.methodSlot(), info.methodSlot());
            }
        u32 next = (u32)0;
        Array* mk = info.methodSlot().allKeys();
        for (u32 i = (u32)0; i < mk.count(); i = i + (u32)1)
            {
            u32 s = ((Number*)info.methodSlot().get((Hashable*)(String*)mk.get(i))).asU32();
            if (s + (u32)1 > next)
                next = s + (u32)1;
            }
        u32 vtblOff = next * (u32)2;
        while (info.vtblEntries().count() < next)
            info.vtblEntries().add((Object*)String.withCString(""));
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* m = cls.kid(i);
            if (m.kind() != (u16)nkMethodDecl || m.hasFlag((u32)NF_STATIC))
                continue;
            if (info.methodSlot().get((Hashable*)m.name()) == 0)
                {
                info.methodSlot().set((Hashable*)m.name(), (Object*)Number.with(next));
                next = next + (u32)1;
                vtblOff = vtblOff + (u32)2;
                }
            u32 slot = ((Number*)info.methodSlot().get((Hashable*)m.name())).asU32();
            while (info.vtblEntries().count() <= slot)
                info.vtblEntries().add((Object*)String.withCString(""));
            info.vtblEntries().set(slot, (Object*)methodSymbolName(cls, m));
            }
        return vtblOff;
        }

    // A class that OWNS a strong ivar needs a destructor even if it declares
    // none: something has to release what it holds when it is freed. So does a
    // class whose ancestor has one, so a freed instance still runs the
    // inherited teardown through the super-chain. The body is empty — the
    // teardown IS the return path.
    void registerSynthesisedDealloc(ClassInfo* info, Node* cls)
        {
        String* dname = String.withString(cls.name());
        dname.appendCString("$dealloc");
        if (symbolExists(dname))
            return;
        bool ownsStrong = false;
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* iv = cls.kid(i);
            if (iv.kind() != (u16)nkVariableDecl || iv.hasFlag((u32)NF_STATIC))
                continue;
            if (isClassPointer(iv.op()))
                {
                ownsStrong = true;
                break;
                }
            // An auto-zeroing ivar — `weak:T@` or a `^` — owns nothing, but it
            // IS linked into its referent's chain, and that link has to be
            // dropped when the holder dies. With no destructor there is nowhere
            // to drop it from, and the referent's own dealloc later walks a
            // chain entry inside freed memory.
            if (isWeakSlot(iv.op()))
                {
                ownsStrong = true;
                break;
                }
            }
        bool ancestorHas = false;
        for (ClassInfo* p = info.parent(); p != 0 && !ancestorHas; p = p.parent())
            {
            String* pn = String.withString(p.name());
            pn.appendCString("$dealloc");
            if (symbolExists(pn))
                ancestorHas = true;
            }
        if (!ownsStrong && !ancestorHas)
            return;
        String* sig = String.withCString("(");
        sig.append(info.selfPtr());
        sig.appendCString(") -> Void");
        IRSymbol* ds = IRSymbol.func(dname, sig, false, false);
        ds.setPlain();
        _m.addSym(ds);
        addUnique(_synthDealloc, cls.name());
        }

    // The generated body: release each of the class's OWN strong ivars, in
    // field order. Inherited ones belong to the ancestor's destructor, which
    // the super-chain reaches separately.
    void emitSynthDeallocBody(ClassInfo* info, Node* cls)
        {
        String* dname = String.withString(cls.name());
        dname.appendCString("$dealloc");
        beginFunction(dname, String.withCString("void"));
        _curClass = info;
        IRValue* selfV = new IRValue(info.selfPtr());
        _fn.addParam(selfV);
        _self = selfV;
        _mem = new IRValue(String.withCString("Mem"));
        _fn.addParam(_mem);
        _blk = new IRBlock(String.withCString("bb_entry"));
        _fn.addBlock(_blk);
        pushArcScope();
        // The body is EMPTY. Its whole content is the ivar teardown, which
        // every dealloc's exit path emits anyway — writing it here as well
        // released each ivar twice.
        finishFunction();
        }

    bool declaresIvar(Node* cls, String* name)
        {
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* iv = cls.kid(i);
            if (iv.kind() == (u16)nkVariableDecl && iv.name().equals(name))
                return true;
            }
        return false;
        }

    void copyInto(Map* from, Map* to)
        {
        Array* ks = from.allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            {
            String* k = (String*)ks.get(i);
            to.set((Hashable*)k, from.get((Hashable*)k));
            }
        }

    // Which symbol fills slot `s` of this class's table: the method the
    // analyser gave that slot, implemented by the nearest class up the chain
    // that declares it.
    // Which method owns slot `s`, asked of this class and then of every
    // ancestor: a class that overrides nothing still dispatches, and its table
    // has to point at whatever the chain does implement. The IMPLEMENTATION is
    // then the nearest one going back down — so an override wins over the
    // parent's body at the same slot.
    // The impl symbol for CHAIN slot `s` on this class — slotSymbolFor's twin
    // over the chain slot space (§4.2). "" when nothing in the ancestry fills
    // it, exactly as a vtable entry prints `_`.
    String* chainSlotSymbolFor(Node* cls, u32 s)
        {
        for (Node* owner = cls; owner != 0; owner = parentDeclOf(owner))
            {
            if (owner.chainSlots() == 0)
                continue;
            Array* ks = owner.chainSlots().allKeys();
            for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
                {
                String* mn = (String*)ks.get(i);
                if (((Number*)owner.chainSlots().get((Hashable*)mn)).asU32() != s)
                    continue;
                Node* want = methodNamed(owner, mn);
                String* sym = implementorOf(cls, mn, want);
                if (sym != 0)
                    return sym;
                }
            }
        return String.withCString("");
        }

    String* slotSymbolFor(Node* cls, u32 s)
        {
        for (Node* owner = cls; owner != 0; owner = parentDeclOf(owner))
            {
            if (owner.slots() == 0)
                continue;
            Array* ks = owner.slots().allKeys();
            for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
                {
                String* mn = (String*)ks.get(i);
                if (((Number*)owner.slots().get((Hashable*)mn)).asU32() != s)
                    continue;
                // What signature does this slot expect? When it belongs to a
                // protocol, the REQUIREMENT says — and that is the answer that
                // matters, because a class may have several overloads of the
                // name and only one of them answers the protocol.
                // `String.equals(String@)` is not what Comparable asked for.
                Node* want = protoReqForSlot(cls, s);
                // The slot map is keyed by method NAME, so with two OVERLOADS
                // it can only remember one of them — and `methodNamed` then
                // returns whichever was declared FIRST for BOTH their slots.
                // `String.byteIndexOf(needle)` filled the slot belonging to
                // `byteIndexOf(needle, from)` as well, so a virtual call to the
                // two-argument form dispatched to the one-argument body. The
                // analyser's LABEL map names each overload separately and is
                // the authority on which one owns this slot; ask it first.
                if (want == 0)
                    want = overloadForSlot(owner, mn, s);
                if (want == 0)
                    want = methodNamed(owner, mn);
                String* sym = implementorOf(cls, mn, want);
                if (sym != 0)
                    return sym;
                }
            }
        // The slot map is keyed by method NAME, so two OVERLOADS of one name
        // own two slots and it can only remember one of them: `Gfx.lineTo` has
        // a `(SPoint)` form and an `(i16, i16)` form, and the forgotten one
        // came out as an empty vtable entry. Recover it from the analyser's
        // LABEL map, which names each overload separately —
        // `_cls_<Class>_<mangled>`.
        //
        // ONLY for a name the map claims at a DIFFERENT slot. A slot no name
        // claims is legitimately empty — an unimplemented `optional`
        // requirement, or another class's slot in this class's table — and
        // filling those from the label map puts a symbol in every one of them.
        return overloadSlotSymbol(cls, s);
        }

    // The overload of `mn` on `owner` whose own label claims slot `s`, or null
    // when the name has only one form (or none claims that slot).
    Node* overloadForSlot(Node* owner, String* mn, u32 s)
        {
        if (_vt == 0)
            return (Node*)0;
        for (u32 i = (u32)0; i < owner.kidCount(); i = i + (u32)1)
            {
            Node* m = owner.kid(i);
            if (m.kind() != (u16)nkMethodDecl || m.hasFlag((u32)NF_STATIC))
                continue;
            if (!m.name().equals(mn))
                continue;
            Object* sl = _vt.slotForLabel(Vtable.label(owner.name(), m));
            if (sl != 0 && ((Number*)sl).asU32() == s)
                return m;
            }
        return (Node*)0;
        }

    String* overloadSlotSymbol(Node* cls, u32 s)
        {
        if (_vt == 0)
            return String.withCString("");
        for (Node* owner = cls; owner != 0; owner = parentDeclOf(owner))
            {
            for (u32 i = (u32)0; i < owner.kidCount(); i = i + (u32)1)
                {
                Node* m = owner.kid(i);
                if (m.kind() != (u16)nkMethodDecl || m.hasFlag((u32)NF_STATIC))
                    continue;
                Object* sl = _vt.slotForLabel(Vtable.label(owner.name(), m));
                if (sl == 0 || ((Number*)sl).asU32() != s)
                    continue;
                if (!nameClaimsOtherSlot(cls, m.name(), s))
                    continue;
                // (A proto-answering method fills BOTH its root slot and the
                // requirement's: the analyser's fill reads the PRISTINE slot
                // assignment — the participant rebind serves call sites, not
                // later fills — so `Object.equals` lands at its root slot
                // here and at Comparable's through fillProtocolSlots. The
                // guard that skipped these matched an older, iteration-order-
                // dependent fill; task #36.)
                // …and only for a label that is a genuine INDEPENDENT root.
                // A method that overrides an ancestor's is usually a
                // PARTICIPANT — the analyser rebinds its label to the
                // ancestor's slot, and the name map fills that slot — but a
                // mid-chain method can be an override AND a root of its own
                // when a descendant overrode IT: the synthesised description
                // chain is exactly that (Dog roots at Animal, Animal roots
                // at Object, and BOTH slots are real — the original fills
                // both; task #36). The participant case is recognisable by
                // its slot: a rebound label answers the ANCESTOR's slot, an
                // independent root answers its own.
                if (overridesAnAncestor(owner, m))
                    {
                    bool independent = false;
                    Node* a = parentDeclOf(owner);
                    while (a != 0)
                        {
                        Node* am = Vtable.matching(a, m);
                        if (am != 0)
                            {
                            Object* asl = _vt.slotForLabel(Vtable.label(a.name(), am));
                            independent = (asl == 0) || ((Number*)asl).asU32() != s;
                            a = (Node*)0; // nearest ancestor decides
                            }
                        else
                            {
                            a = parentDeclOf(a);
                            }
                        }
                    if (!independent)
                        continue;
                    }
                // A STRICT signature match, with no fall back to "some method
                // of that name": the slot belongs to one overload, and the
                // class that does not implement THAT one leaves it empty.
                // `init()` and `init(i16)` are two slots, and filling the
                // second with the first's body is how a fallback breaks them.
                // Synthesised bodies count: the original's nearest-impl walk
                // has no synth exclusion, and the independent-root fill's
                // nearest impl IS the synthesised description.
                String* sym = strictImplementorOfAllowSynth(cls, m, true);
                if (sym != 0)
                    return sym;
                }
            }
        return String.withCString("");
        }

    // Does an ANCESTOR of `owner` declare the same signature?
    bool overridesAnAncestor(Node* owner, Node* m)
        {
        for (Node* a = parentDeclOf(owner); a != 0; a = parentDeclOf(a))
            if (Vtable.matching(a, m) != 0)
                return true;
        return false;
        }

    // The nearest class up the chain that declares EXACTLY this signature.
    String* strictImplementorOf(Node* cls, Node* want)
        {
        return strictImplementorOfAllowSynth(cls, want, false);
        }

    String* strictImplementorOfAllowSynth(Node* cls, Node* want, bool allowSynth)
        {
        for (Node* c = cls; c != 0; c = parentDeclOf(c))
            {
            Node* m = Vtable.matching(c, want);
            if (m != 0 && (allowSynth || !m.hasFlag((u32)NF_SYNTH)))
                return methodSymbolName(c, m);
            }
        return (String*)0;
        }

    // Does some protocol in this class's chain require exactly this method?
    bool answersAProtocol(Node* cls, Node* m)
        {
        for (Node* c = cls; c != 0; c = parentDeclOf(c))
            {
            Array* protos = splitList(c.extra());
            for (u32 i = (u32)0; i < protos.count(); i = i + (u32)1)
                {
                Object* pd = _protocols.get((Hashable*)(String*)protos.get(i));
                if (pd == 0)
                    continue;
                Node* proto = (Node*)pd;
                if (Vtable.matching(proto, m) != 0)
                    return true;
                }
            }
        return false;
        }

    // Is this method NAME recorded against some OTHER slot? Then the name map
    // is answering for a different overload and this slot is the one it lost.
    bool nameClaimsOtherSlot(Node* cls, String* name, u32 s)
        {
        for (Node* owner = cls; owner != 0; owner = parentDeclOf(owner))
            {
            if (owner.slots() == 0)
                continue;
            Object* o = owner.slots().get((Hashable*)name);
            if (o != 0 && ((Number*)o).asU32() != s)
                return true;
            }
        return false;
        }

    bool absent(String* s)
        {
        if (s == 0 || s.byteLength() == (u32)0)
            return true;
        return s.equals(String.withCString("-"));
        }

    Node* parentDeclOf(Node* cls)
        {
        // A class with no DECLARED parent still has one: every parentless
        // class is a child of Object, and its slots and protocols are as
        // inherited as any other's.
        if (absent(cls.op()))
            {
            if (cls.name().equals(String.withCString("Object")))
                return (Node*)0;
            Node* o = objectDecl();
            return o == cls ? (Node*)0 : o;
            }
        Object* o = _classDecls.get((Hashable*)cls.op());
        if (o == 0)
            return (Node*)0;
        return (Node*)o;
        }

    String* methodSymbolName(Node* cls, Node* m)
        {
        String* s = String.withString(cls.name());
        s.appendByte((u8)'$');
        s.append(m.sym() == 0 ? m.name() : m.sym());
        return s;
        }

    Node* methodBody(Node* m)
        {
        for (u32 i = (u32)0; i < m.kidCount(); i = i + (u32)1)
            if (m.kid(i).kind() == (u16)nkBlock)
                return m.kid(i);
        return (Node*)0;
        }

    String* methodSignature(ClassInfo* info, Node* m)
        {
        String* s = String.withCString("(");
        u32 n = (u32)0;
        if (!m.hasFlag((u32)NF_STATIC))
            {
            s.append(info.selfPtr());
            n = n + (u32)1;
            }
        for (u32 i = (u32)0; i < m.kidCount(); i = i + (u32)1)
            {
            Node* p = m.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            if (n > (u32)0)
                s.appendCString(", ");
            s.append(irType(p.op()));
            n = n + (u32)1;
            }
        s.appendCString(") -> ");
        s.append(irType(firstReturn(m.op())));
        return s;
        }

    // ── the pre-scan ─────────────────────────────────────────────────────
    // Which locals need a frame slot is decided BEFORE a single block is
    // lowered, because the answer changes how every mention of the name is
    // lowered — and because the slots' byte offsets are a property of the
    // whole function, not of the statement that happens to mention one first.
    //
    // A name is pinned when any of these holds:
    //
    //   * its address is `&`-taken — the pointer can escape into a call and be
    //     dereferenced across it, so the storage has to outlive the expression;
    //   * it is a value-typed AGGREGATE (a struct or an array), which cannot
    //     live in an SSA scalar at all: every access goes through the address;
    //   * it is a va_* cursor, whose offset is loop-carried state read between
    //     the calls printf makes per directive, so it is memory-backed rather
    //     than an SSA rebind.
    //
    // The slots are allocated in SORTED name order, so the offsets — which are
    // printed — are a property of the program and not of a hash table.
    // `u8 a[] = { … }` says how big it is by what is in it. The count is
    // filled in ONCE, before anything reads the type — the frame pre-scan, the
    // layout and the element stride all ask, and a sizeless spelling answers
    // zero to every one of them.
    void sizeArrayFromInitialiser(Node* n)
        {
        if (n.kidCount() == (u32)0 || n.op() == 0)
            return;
        String* t = n.op();
        if (t.byteLength() < (u32)2)
            return;
        if (t.byteAt(t.byteLength() - (u32)1) != (u8)']' || t.byteAt(t.byteLength() - (u32)2) != (u8)'[')
            return;
        Node* ini = n.kid((u32)0);
        u32 count = (u32)0;
        if (ini.kind() == (u16)nkBlock)
            count = ini.kidCount();
        else if (ini.kind() == (u16)nkRange)
            count = expandRange(ini, t).kidCount();
        else
            return;
        String* sized = t.substringBytes((u32)0, t.byteLength() - (u32)1);
        sized.appendFormat("%lu]", count);
        n.setOp(sized);
        }

    void registerLocalTypes(Node* n)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        if (k == (u16)nkVariableDecl)
            sizeArrayFromInitialiser(n);
        if (k == (u16)nkStructDecl)
            {
            _structs.set((Hashable*)n.name(), (Object*)n);
            return;
            }
        if (k == (u16)nkTypedefDecl)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                if (n.kid(i).kind() == (u16)nkStructDecl)
                    _structs.set((Hashable*)n.name(), (Object*)n.kid(i));
            return;
            }
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            registerLocalTypes(n.kid(i));
        }

    void preScanPinned(Node* body)
        {
        _ampTaken = new Array();
        _assignedNames = new Array();
        _vaCursors = new Array();
        _asmNamed = new Array();

        // A struct declared INSIDE the function names a shape the pre-scan has
        // to know about before it can decide which locals are aggregates —
        // and the statement that declares it has not been lowered yet.
        registerLocalTypes(body);

        Array* addressed = new Array();
        collectAddressTaken(body, addressed);
        // Function-local statics live in a module global, not a frame slot, so
        // they must not be pinned even when address-taken (bug 174).
        Array* staticNames = new Array();
        collectStaticLocalNames(body, staticNames);
        // A function with a goto pins ALL its locals (so a jump is a plain
        // branch, no SSA value reconstruction across the edge). Reject the cases
        // the pinned model cannot yet tear down on a jump.
        if (astContainsGoto(body))
            {
            String* why = gotoUnsupportedReason(body);
            if (why != 0)
                {
                String* msg = String.withCString("goto in a function with ");
                msg.append(why);
                msg.appendCString(" is not supported (goto is a C-porting aid)");
                giveUp(msg);
                return;
                }
            collectAllLocalNames(body, addressed);
            }

        // Value-typed aggregates are pinned whether or not anything takes
        // their address. The array ones are recorded separately: a bare name
        // decays to a pointer, where a struct's does not.
        Array* aggNames = new Array();
        Map* aggTypes = new Map();
        collectAggregateLocals(body, aggNames, aggTypes);
        for (u32 i = (u32)0; i < aggNames.count(); i = i + (u32)1)
            {
            String* nm = (String*)aggNames.get(i);
            if (hasName(staticNames, nm))
                continue; // static: global-backed (bug 174)
            addUnique(addressed, nm);
            String* ty = (String*)aggTypes.get((Hashable*)nm);
            if (isArrayLike(ty))
                _arrayElem.set((Hashable*)nm, (Object*)elementOf(ty));
            }
        for (u32 i = (u32)0; i < _vaCursors.count(); i = i + (u32)1)
            addUnique(addressed, (String*)_vaCursors.get(i));
        if (addressed.count() == (u32)0)
            return;

        // Each name's DECLARED type, recovered by walking the body. The
        // aggregate walk already carries an authoritative one, so it wins.
        Map* typesByName = new Map();
        _pinDeclTys = new Map();
        collectVarDeclTypes(body, addressed, typesByName);
        for (u32 i = (u32)0; i < aggNames.count(); i = i + (u32)1)
            {
            String* nm = (String*)aggNames.get(i);
            typesByName.set((Hashable*)nm, aggTypes.get((Hashable*)nm));
            }

        Array* sorted = sortedNames(addressed);
        u32 off = (u32)0;
        for (u32 i = (u32)0; i < sorted.count(); i = i + (u32)1)
            {
            String* name = (String*)sorted.get(i);
            if (hasName(staticNames, name))
                continue; // static: global-backed (bug 174)
            Object* t = typesByName.get((Hashable*)name);
            if (t == 0)
                {
                // Not a var-decl. A PARAMETER reached through `&` pins to its
                // own value — there is no new slot to allocate, and no frame
                // entry: the parameter already has storage.
                // `self` is never one of them. `&self.f` takes the FIELD's
                // address, and the receiver is already a pointer — giving it a
                // slot would make every ivar access read the slot first.
                Object* pv = isName(name, "self") ? (Object*)0
                                                  : _locals.get((Hashable*)name);
                // A scalar/pointer parameter whose address is `&`-taken gets its
                // OWN frame slot, initialised from the incoming param value at
                // entry — exactly as `T j = j0; &j` does. Aliasing AddrOf to the
                // param value itself is wrong once the function is inlined: the
                // callee's `AddrOf param; Store` mutates the caller's argument SSA
                // value, corrupting a shared argument such as a constant that also
                // feeds later calls (bug 202). Asm-named params keep the alias
                // (they need the param's ZP address); aggregates ride their
                // prologue slot. So only `&`-taken, non-asm, non-Agg params.
                if (pv != 0 && pinOf(name) == 0 && hasName(_ampTaken, name) && !hasName(_asmNamed, name) && !isAggIr(((IRValue*)pv).ty()))
                    {
                    IRValue* v = (IRValue*)pv;
                    IRPinned* p = IRPinned.with(new IRValue(v.ty()), v.ty(), off, true);
                    _fn.addPinned(p);
                    _pins.set((Hashable*)name, (Object*)p);
                    // The slot's AST spelling, as the aliasing path below
                    // records it: every read of the name loads THROUGH the
                    // slot, and loadThrough types the Load from this entry.
                    // Without it the load came out `Void` — which the arm64
                    // back end sized as one byte, so an i32 parameter over 255
                    // read back truncated (bug 205).
                    _pinAst.set((Hashable*)name, _localTypes.get((Hashable*)name));
                    _pinnedParamInit.set((Hashable*)name, (Object*)v); // prologue copies it in
                    off = off + irWidth(v.ty());
                    continue;
                    }
                if (pv != 0 && pinOf(name) == 0)
                    {
                    IRValue* v = (IRValue*)pv;
                    _pins.set((Hashable*)name, (Object*)IRPinned.with(v, v.ty(), (u32)0, false));
                    _pinAst.set((Hashable*)name, _localTypes.get((Hashable*)name));
                    }
                continue;
                }
            String* ast = (String*)t;
            // A value-class slot holds the INSTANCE, so it is sized by the
            // class's aggregate — `irType` would give the reference type,
            // which is a pointer and the wrong size entirely.
            Object* vco = _valueClass.get((Hashable*)name);
            String* irTy = vco != 0 ? ((ClassInfo*)vco).agg() : irType(ast);
            if (_failed)
                return;
            // An auto-zeroing local's slot carries its two link words, so the
            // slot's TYPE is the whole [prev, next, payload] — not merely a
            // wider byte offset. The backends size a pinned slot from its
            // type and never read the offset, so reserving space by advancing
            // the offset would let the links land on a neighbour.
            if (isWeakSlot(ast))
                {
                irTy = weakSlotAgg(irTy);
                addUnique(_weakLocals, name);
                }
            // An `&`-taken local, a va cursor, and an array all escape: the
            // pointer reaches a callee, which reads and writes through it. The
            // backend has to give them storage a call cannot reuse.
            // An asm-named local keeps a fixed, directly-addressable slot:
            // the body says `STA name`, and that has to resolve to an address
            // the assembler can write down. So it is pinned but NOT marked
            // escaping — including when it is an array, which would otherwise
            // qualify on shape alone.
            // A stack instance is only ever reached through its self-pointer,
            // which is handed to every method it calls — so it escapes for the
            // same reason an `&`-taken local does.
            bool esc = hasName(_ampTaken, name) || hasName(_vaCursors, name) || _valueClass.get((Hashable*)name) != 0 || (_arrayElem.get((Hashable*)name) != 0 && !hasName(_asmNamed, name));
            // One slot per DECLARATION of the name — a name declared twice in
            // two blocks is two locals, and giving them one slot makes the
            // second's width and contents overwrite the first's.
            Array* decls = (Array*)_pinDeclTys.get((Hashable*)name);

            // An ARRAY or struct keeps the aggregate walk's spelling and one
            // slot; everything else gets one per declared TYPE, value-class
            // instances included — `BumpedPoint a` and `Point a` in two blocks
            // are two locals of two shapes.
            //
            // …unless the name is ALSO declared at another type. `u8 m[32]` in
            // one block and `u32 m` in a sibling collapsed onto the array's one
            // slot, and since _arrayElem is keyed by NAME the scalar's every
            // bare-name read then decayed to the array's ADDRESS: `tbl[m]`
            // lowered as `tbl[&m]`, no diagnostic, SIGBUS at run time. A name
            // declared at one type only still has one entry here, so the
            // aggregate walk keeps speaking for it exactly as before.
            // A value-class instance keeps the opt-out whatever it is declared
            // as: its slot is sized by the class's own aggregate, which the
            // per-declaration loop below does not reproduce.
            bool oneSlot = hasName(aggNames, name) && (vco != (Object*)0 || decls == (Array*)0 || decls.count() <= (u32)1);
            u32 count = (decls == 0 || oneSlot) ? (u32)1 : decls.count();
            if (count == (u32)0)
                count = (u32)1;
            Array* mine = new Array();
            for (u32 d = (u32)0; d < count; d = d + (u32)1)
                {
                // The AGGREGATE walk's spelling is authoritative for the
                // names it covers; everywhere else each declaration brings
                // its own, and the last one does not speak for the first.
                bool aggWins = oneSlot || decls == 0;
                String* dAst = aggWins ? ast : (String*)decls.get(d);
                String* dIr = irTy;
                if (!aggWins || d > (u32)0)
                    {
                    // The value-class agg comes from THIS declaration's type,
                    // not from the name: a name declared as two different
                    // classes is two instances of two sizes.
                    ClassInfo* dci = vco == 0 ? (ClassInfo*)0 : classFor(stripQual(dAst));
                    dIr = dci != 0 ? dci.agg() : irType(dAst);
                    if (_failed)
                        return;
                    if (isWeakSlot(dAst))
                        dIr = weakSlotAgg(dIr);
                    }
                IRPinned* p = IRPinned.with(new IRValue(dIr), dIr, off, esc);
                _fn.addPinned(p);
                mine.add((Object*)p);
                if (d == (u32)0)
                    {
                    _pins.set((Hashable*)name, (Object*)p);
                    _pinAst.set((Hashable*)name, (Object*)dAst);
                    }
                off = off + irWidth(dIr);
                }
            _pinSeq.set((Hashable*)name, (Object*)mine);
            }
        _fn.setPinnedSize(off);
        }

    // Identifiers in one asm line. A comment runs to end of line and its words
    // are prose, not names — `; Clear numCols bytes` must not pin a local.
    void collectAsmIdentifiers(String* line, Array* out)
        {
        if (line == 0)
            return;
        u32 i = (u32)0;
        while (i < line.byteLength())
            {
            u8 c = line.byteAt(i);
            if (c == (u8)';')
                return;
            if (isIdentStart(c))
                {
                u32 start = i;
                while (i < line.byteLength() && isIdentChar(line.byteAt(i)))
                    i = i + (u32)1;
                addUnique(out, line.substringBytes(start, i - start));
                }
            else
                {
                i = i + (u32)1;
                }
            }
        }

    bool isIdentStart(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || c == (u8)'_';
        }

    bool isIdentChar(u8 c)
        {
        return isIdentStart(c) || (c >= (u8)'0' && c <= (u8)'9');
        }

    bool hasName(Array* a, String* name)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(name))
                return true;
        return false;
        }

    // Every name an `&` is applied to, plus the va cursors, collected in one
    // walk. `&a.b.c` pins `a`: the address is INTO a's storage. `&p->x` pins
    // nothing — p is a pointer whose value is used directly.
    //
    // The walk deliberately mirrors the original's, node kind for node kind —
    // including that it does not descend into a TERNARY. A rule the two
    // implementations have to agree on is a rule about which names get slots,
    // and "the original misses this one" is part of the rule.
    void collectAddressTaken(Node* n, Array* out)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        // An inline-asm body that names an xtc local needs that local to HAVE
        // an address — `STA scrMode` has to resolve to something, and an
        // unpinned SSA value is not something. Every identifier in the body is
        // collected; the pin loop keeps whichever are real locals.
        if (k == (u16)nkAsmBlock)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                collectAsmIdentifiers(n.kid(i).name(), out);
                collectAsmIdentifiers(n.kid(i).name(), _asmNamed);
                }
            return;
            }
        if (k == (u16)nkUnary && isName(n.op(), "&") && n.kidCount() > (u32)0 && n.kid((u32)0).bound() == 0)
            {
            // `&obj.method` does NOT take obj's address: the receiver is read
            // BY VALUE into the pair's recv word. Pinning it here would be
            // actively harmful — an address-taken local is excluded from the
            // strong set, so the receiver's scope-exit release would vanish
            // and the object would leak.
            Node* cur = n.kid((u32)0);
            while (cur != 0 && cur.kind() == (u16)nkMember)
                {
                if (cur.hasFlag((u32)NF_ARROW))
                    {
                    cur = (Node*)0;
                    break;
                    }
                cur = cur.kid((u32)0);
                }
            if (cur != 0 && cur.kind() == (u16)nkIdent)
                {
                addUnique(out, cur.name());
                addUnique(_ampTaken, cur.name());
                }
            }
        // A plain `name = …` whose slot is a class pointer. A PARAMETER that
        // is assigned has to become a strong slot (private:docs/bugs/064), and that is
        // decided before the body is lowered — this walk is already the one
        // pre-pass over the body, so it is collected here rather than in a
        // second traversal to drift against.
        if (k == (u16)nkAssign && n.kidCount() > (u32)0 && n.kid((u32)0).kind() == (u16)nkIdent && isClassPointer(n.kid((u32)0).ty()))
            addUnique(_assignedNames, n.kid((u32)0).name());
        if (k == (u16)nkCall && n.sym() != 0 && n.sym().hasPrefix(String.withCString("__intrinsic_va_")) && n.kidCount() > (u32)0 && n.kid((u32)0).kind() == (u16)nkIdent)
            {
            addUnique(_vaCursors, n.kid((u32)0).name());
            }
        if (k == (u16)nkBlock || k == (u16)nkIf || k == (u16)nkWhile || k == (u16)nkForCStyle || k == (u16)nkReturn || k == (u16)nkExprStatement || k == (u16)nkVariableDecl || k == (u16)nkUnary || k == (u16)nkPostfix || k == (u16)nkBinary || k == (u16)nkAssign || k == (u16)nkCall || k == (u16)nkMethodCall || k == (u16)nkSubscript || k == (u16)nkMember || k == (u16)nkCast || k == (u16)nkTernary || k == (u16)nkMarkerInit || k == (u16)nkMarkerCond || k == (u16)nkMarkerStep)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                collectAddressTaken(n.kid(i), out);
            }
        }

    // Value-typed struct and array locals. The traversal is the original's:
    // blocks, both arms of an `if`, a loop body, a `for`'s init clause — and
    // nothing else, because a declaration cannot appear anywhere else.
    // Does this initialiser hand the name a value that needs no frame slot?
    // `new T` gives a heap pointer, and a method called on a value instance
    // returns in registers.
    bool bindsWithoutSlot(Node* ini)
        {
        if (ini.kind() == (u16)nkNew)
            return true;
        if (ini.kind() != (u16)nkMethodCall || ini.kidCount() == (u32)0)
            return false;
        String* rt = ini.kid((u32)0).ty();
        return rt != 0 && !Types.isPointer(rt) && classFor(stripQual(rt)) != 0;
        }

    void collectAggregateLocals(Node* n, Array* names, Map* types)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        if (k == (u16)nkVariableDecl)
            {
            String* ty = n.op();
            if (n.name() == 0 || ty == 0)
                return;
            if ((isArrayLike(ty) || structDeclFor(ty) != 0) && !Types.isPointer(ty))
                {
                addUnique(names, n.name());
                types.set((Hashable*)n.name(), (Object*)ty);
                // A struct that EMBEDS a class reference owns it: the fields
                // are nulled at the declaration so the first assignment's
                // release-of-old reads null rather than frame litter, and
                // released at scope exit because nothing else will.
                // An ARRAY of class pointers owns every element: each slot is
                // nulled at the declaration so the first assignment's
                // release-of-old reads null rather than frame litter, and each
                // is released at scope exit because nothing else will.
                if (isArrayLike(ty) && isClassPointer(elementOf(ty)))
                    _strongArray.set((Hashable*)n.name(), (Object*)ty);
                // …and an array of AUTO-ZEROING slots owns nothing, but every
                // element is on a chain and every entry has to come out.
                if (isArrayLike(ty) && isWeakSlot(elementOf(ty)))
                    _weakArray.set((Hashable*)n.name(), (Object*)ty);
                if (structHasClassField(ty))
                    _strongStruct.set((Hashable*)n.name(), (Object*)ty);
                // …and an ARRAY of such structs owns one set per element.
                else if (isArrayLike(ty) && structHasClassField(elementOf(ty)))
                    _strongStruct.set((Hashable*)n.name(), (Object*)ty);
                return;
                }
            // An AUTO-ZEROING local must be pinned even though a pointer
            // would live happily in an SSA value: the runtime zeroes the
            // slot's MEMORY when the referent dies, and an SSA copy would
            // never see that — the guard would still read the stale pointer.
            // Pinning is what makes the auto-zeroing observable.
            if (isWeakSlot(ty))
                {
                addUnique(names, n.name());
                types.set((Hashable*)n.name(), (Object*)ty);
                return;
                }
            // A sized SCALAR whose byte-list has a runtime entry needs
            // addressable storage too — there is no single Const to bind, so
            // the value is assembled a byte at a time into the slot. An
            // all-constant list stays unpinned and costs no IR at all.
            if (byteListStorable(ty) && n.kidCount() > (u32)0 && n.kid((u32)0).kind() == (u16)nkBlock && !byteListAllConstant(n.kid((u32)0)))
                {
                addUnique(names, n.name());
                types.set((Hashable*)n.name(), (Object*)ty);
                return;
                }
            // A STACK class instance — `Counter c;` with no `new`. The
            // instance memory IS the frame slot, so the slot is sized by the
            // class's own layout and not by a pointer, and the name evaluates
            // to its ADDRESS everywhere.
            // A STACK class instance. `Gadget g(42)` passes constructor
            // arguments and lives in the frame; `Point c = h.clone()` takes a
            // copy OUT of a heap object, which is an indirect byte copy into a
            // slot. `new` makes the name a heap pointer instead, and a value
            // returned by a STACK instance's method comes back in registers
            // and binds directly — neither needs storage of its own.
            if (classFor(ty) != 0 && !Types.isPointer(ty) && (n.kidCount() == (u32)0 || !bindsWithoutSlot(n.kid((u32)0))))
                {
                addUnique(names, n.name());
                types.set((Hashable*)n.name(), (Object*)ty);
                _valueClass.set((Hashable*)n.name(), (Object*)classFor(ty));
                }
            return;
            }
        if (k == (u16)nkBlock || k == (u16)nkIf || k == (u16)nkWhile || k == (u16)nkForCStyle || k == (u16)nkMarkerInit)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                collectAggregateLocals(n.kid(i), names, types);
            }
        }

    void collectVarDeclTypes(Node* n, Array* names, Map* out)
        {
        if (n == 0)
            return;
        u16 k = n.kind();
        if (k == (u16)nkVariableDecl)
            {
            if (n.name() != 0 && n.op() != 0 && hasName(names, n.name()))
                {
                out.set((Hashable*)n.name(), (Object*)n.op());
                // …and EVERY declaration of the name, in order. Two blocks can
                // each declare a `c`, and they are two different locals with
                // two slots — the name alone cannot tell them apart.
                Object* seq = _pinDeclTys.get((Hashable*)n.name());
                if (seq == 0)
                    {
                    seq = (Object*)new Array();
                    _pinDeclTys.set((Hashable*)n.name(), seq);
                    }
                // …but only when the TYPE differs from what the name already
                // has. Two `u16 i` in sibling blocks are one slot — they can
                // never be live at once and the storage is the same shape.
                // A `u8 c` and a `u32 c` are not: one slot cannot be both
                // widths, and the narrower one's neighbour would be
                // overwritten.
                Array* all = (Array*)seq;
                bool seen = false;
                for (u32 q = (u32)0; q < all.count(); q = q + (u32)1)
                    if (((String*)all.get(q)).equals(n.op()))
                        seen = true;
                if (!seen)
                    all.add((Object*)n.op());
                }
            return;
            }
        if (k == (u16)nkBlock || k == (u16)nkIf || k == (u16)nkWhile || k == (u16)nkForCStyle || k == (u16)nkMarkerInit)
            {
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                collectVarDeclTypes(n.kid(i), names, out);
            }
        }

    // ── functions and the module ─────────────────────────────────────────
    IRModule* run(Node* program, String* moduleName)
        {
        _pendingGlobalInits = new Array();
        _m = new IRModule();
        _m.setName(moduleName);

        // Does this program thread? `Thread.xc` declares
        // `pointer _xt_thread_create(pointer, pointer);` at FILE SCOPE, so the
        // answer is a scan of the top-level declarations — no walk into bodies.
        // Deliberately conservative in the same direction as the reference
        // compiler: importing Thread.xc without calling spawn turns it on.
        if (_tssMode >= (i32)0)
            {
            _threadSafeStatics = _tssMode != (i32)0;
            }
        else
            {
            _threadSafeStatics = false;
            for (u32 ti = (u32)0; ti < program.kidCount(); ti = ti + (u32)1)
                {
                Node* td = program.kid(ti);
                if (td.kind() != (u16)nkFunctionDecl)
                    continue;
                if (td.name().equals(String.withCString("_xt_thread_create")))
                    _threadSafeStatics = true;
                }
            }

        // Struct shapes first — a signature or a global can name one, and a
        // layout has to exist before any type that refers to it is spelled.
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            {
            Node* d = program.kid(i);
            if (d.kind() == (u16)nkClassDecl)
                {
                _classDecls.set((Hashable*)d.name(), (Object*)d);
                continue;
                }
            if (d.kind() == (u16)nkProtocolDecl)
                {
                _protocols.set((Hashable*)d.name(), (Object*)d);
                continue;
                }
            // An enum MEMBER is a compile-time constant, not storage: a
            // mention of it resolves to a Const of the enum's own width, and
            // the enum type itself never reaches the IR.
            if (d.kind() == (u16)nkEnumDecl)
                {
                _enums.set((Hashable*)d.name(), (Object*)d);
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    {
                    Node* m = d.kid(j);
                    if (m.kind() != (u16)nkEnumMember)
                        continue;
                    _enumConsts.set((Hashable*)m.name(), (Object*)Number.with((u32)m.num()));
                    }
                continue;
                }
            if (d.kind() == (u16)nkStructDecl)
                {
                _structs.set((Hashable*)d.name(), (Object*)d);
                continue;
                }
            // `typedef struct { … } Name;` — the typedef's name is the one
            // every mention uses, so it maps to the same shape.
            if (d.kind() == (u16)nkTypedefDecl)
                {
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    if (d.kid(j).kind() == (u16)nkStructDecl)
                        _structs.set((Hashable*)d.name(), (Object*)d.kid(j));
                }
            }

        // Each class gets a dense RTTI id, 1..N in NAME order so the numbering
        // is a property of the program; 0 stays the "no class" sentinel.
        Array* cnames = sortedNames(_classDecls.allKeys());
        for (u32 i = (u32)0; i < cnames.count(); i = i + (u32)1)
            _classIds.set((Hashable*)(String*)cnames.get(i), (Object*)Number.with(i + (u32)1));

        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            if (program.kid(i).kind() == (u16)nkUseDecl)
                _usedClasses.add((Object*)program.kid(i).name());

        // Classes before functions: a function may take a class-pointer
        // parameter or call `new T`, and both need the layout to exist.
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            {
            Node* d = program.kid(i);
            if (d.kind() == (u16)nkClassDecl)
                {
                preScanClass(d);
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    {
                    Node* m = d.kid(j);
                    if (m.kind() != (u16)nkMethodDecl || !isName(m.name(), "dealloc"))
                        continue;
                    if (callsSuperDealloc(methodBody(m)))
                        addUnique(_deallocCallsSuper, d.name());
                    }
                }
            if (_failed)
                return (IRModule*)0;
            }

        // Function symbols first, in declaration order, then the globals —
        // which is the order the original registers them, and the order the
        // text prints them in.
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            {
            Node* d = program.kid(i);
            if (d.kind() != (u16)nkFunctionDecl)
                continue;
            // The bounded C-variadic rule (blewit item 2): a BODY-LESS
            // declaration ending in `...` names a C callee — no xtc body
            // exists to walk a pack buffer, so the call is C-ABI. Stamped
            // ONCE here so both consumers (the symbol's cabi attribute and
            // packVarargs' native-promote split) agree. Mirrors the
            // original's XTFnIsCABI.
            if (d.hasFlag((u32)NF_VARARGS))
                {
                bool hasBody = false;
                for (u32 b = (u32)0; b < d.kidCount(); b = b + (u32)1)
                    if (d.kid(b).kind() == (u16)nkBlock)
                        hasBody = true;
                if (!hasBody)
                    d.addFlag((u32)NF_CABI);
                }
            _funcs.set((Hashable*)d.name(), (Object*)d);
            // …and under the MANGLED name, which is what tells two overloads
            // apart. Keyed by name alone, `show(u32)` and `show(u8,u8)` are
            // the same entry and whichever was declared last answers for both.
            if (d.sym() != 0)
                _funcsBySym.set((Hashable*)d.sym(), (Object*)d);
            IRSymbol* fsym = IRSymbol.func(d.sym() == 0 ? d.name() : d.sym(),
                                           signatureOf(d),
                                           d.hasFlag((u32)NF_VARARGS),
                                           d.hasFlag((u32)NF_CABI));
            if (d.hasFlag((u32)NF_THROWS))
                fsym.setThrows();
            if (d.hasFlag((u32)NF_IRQ))
                fsym.setIrq();
            if (d.hasFlag((u32)NF_VBI))
                fsym.setVbi();
            // Only when SET, like the three above: printed on every function it
            // would rewrite every golden IR file to say "false" about a
            // property almost nothing has. private:docs/bugs/047.
            if (d.hasFlag((u32)NF_VAFWD))
                fsym.setAttr(String.withCString("vaforward"), true);
            // §6: `extern` on a DEFINITION exports — the original's
            // `exported` attribute, plus `expname_<spelled>` when overload
            // mangling renamed the symbol (tasks #31/#33).
            //
            // The #package half of §6 used to stay unported, on the reasoning
            // that no differential could reach it — the oracle FE rejects
            // #package on every off-wasm32 target, so no comparison would ever
            // notice. True, and it left the SHIPPED compiler unable to build a
            // working wasm program: every extern landed in `env` while the
            // loader supplies them under `browser`, so the module instantiated
            // against stubs and trapped on the first call. A gap no harness can
            // see is still a gap a user hits on their first program.
            bool defHasBody = false;
            for (u32 b = (u32)0; b < d.kidCount(); b = b + (u32)1)
                if (d.kid(b).kind() == (u16)nkBlock)
                    defHasBody = true;
            // A BODYLESS declaration carries the `#package` in force as
            // `pkg_<ns>`, which is what the wasm back end reads to place the
            // import. The parser stashed it on the node's extra slot.
            // A function reconstructed from a LIBRARY interface carries its
            // package on its own slot — `extra` is the `#package` a SOURCE
            // declaration was written under, and a library's free functions
            // have neither. Without this the app imported `env.makeLoud`,
            // which no host supplies.
            String* fpkg = d.pkg() != 0 && d.pkg().byteLength() > (u32)0
                               ? d.pkg()
                               : d.extra();
            if (!defHasBody && fpkg != 0 && fpkg.byteLength() > (u32)0)
                fsym.setAttr(String.withFormat("pkg_%s", fpkg.cString()), true);
            if (defHasBody && d.hasFlag((u32)NF_EXTERN))
                {
                fsym.setAttr(String.withCString("exported"), true);
                if (d.sym() != 0 && !d.sym().equals(d.name()))
                    fsym.setAttr(String.withFormat("expname_%s",
                                                   d.name().cString()),
                                 true);
                }
            // MERGED duplicate prototypes (sema's C repeated-prototype rule,
            // blewit item 1) still exist as AST nodes — one symbol serves
            // them all, exactly as the original's symbol table has one entry.
            if (!symbolExists(d.sym() == 0 ? d.name() : d.sym()))
                _m.addSym(fsym);
            }
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            {
            Node* d = program.kid(i);
            if (d.kind() != (u16)nkVariableDecl)
                continue;
            // An uninitialised file-scope global is a C TENTATIVE definition:
            // repeats of one name (here, a.xc and b.xc both declaring
            // `u32 gShared;`, merged into one unit by #import) collapse to a
            // single storage slot. The original keeps the FIRST and skips the
            // rest; without this the x86_64 assembler saw two `gShared:` defs
            // and refused the link (c2xc bug 36 — arm64 merged them as common,
            // so only the x86_64 deploy broke).
            if (symbolExists(d.name()))
                continue;
            sizeArrayFromInitialiser(d);
            _globals.set((Hashable*)d.name(), (Object*)d.op());
            // An auto-zeroing GLOBAL carries the same two hidden link words a
            // local's slot does: the runtime walks a chain to zero it, and the
            // chain has to be threaded through storage the referent can find.
            String* gty = isWeakSlot(d.op())
                              ? weakSlotAggOf(d.op())
                              : irType(d.op());
            IRSymbol* g = IRSymbol.dataGlobal(d.name(), gty);
            // §6: `extern` WITH an initialiser = an exported definition —
            // the original stamps `exported` on the global's symbol. The
            // parser already swapped NF_EXTERN for NF_EXPORTED on it.
            if (d.hasFlag((u32)NF_EXPORTED))
                g.setAttr(String.withCString("exported"), true);
            // An initialised global carries its bytes, little-endian, folded
            // at compile time — the backend bakes the payload in, so the
            // initialiser is not code that runs.
            if (d.kidCount() > (u32)0)
                {
                // A FLOAT global's payload is the literal as an IEEE DOUBLE,
                // eight bytes, whether the slot is declared `float` or
                // `double` — the backend narrows it if it has to. Nothing else
                // about the literal survives, so the value has to be encoded
                // here rather than folded through the integer path.
                if (Types.isFloating(d.op()) && d.kid((u32)0).kind() != (u16)nkBlock)
                    {
                    Node* lit = d.kid((u32)0);
                    if (lit.kind() == (u16)nkFloat)
                        g.setBytes(bytesOfData(FloatEncoding.ieeeBytes(lit.name(), true)));
                    else if (!isWeakSlot(d.op()))
                        _pendingGlobalInits.add((Object*)d);
                    }
                else if (isArrayLike(d.op()) || structDeclFor(d.op()) != 0)
                    {
                    // An AGGREGATE global's initialiser is baked into the
                    // image, so its bytes are laid out here rather than
                    // written by code at run time.
                    Array* bytes = aggregateInitBytes(expandRange(d.kid((u32)0), d.op()),
                                                      d.op());
                    if (bytes != 0)
                        g.setBytes(bytes);
                    else if (!isWeakSlot(d.op()))
                        _pendingGlobalInits.add((Object*)d);
                    }
                else if (d.kid((u32)0).kind() == (u16)nkBlock)
                    {
                    // A SCALAR with a byte list is those bytes, low to high,
                    // truncated or zero-padded to the slot: the list is the
                    // storage written out, not a value to fold.
                    Array* bytes = new Array();
                    Node* list = d.kid((u32)0);
                    for (u32 b = (u32)0; b < astWidth(d.op()); b = b + (u32)1)
                        {
                        i32 v = (i32)0;
                        if (b < list.kidCount())
                            {
                            _constOk = true;
                            v = constEval(list.kid(b));
                            if (!_constOk)
                                v = (i32)0;
                            }
                        bytes.add((Object*)Number.with((u32)v & (u32)$FF));
                        }
                    g.setBytes(bytes);
                    }
                else
                    {
                    _constOk = true;
                    i32 v = constEval(d.kid((u32)0));
                    if (_constOk)
                        g.setBytes(leBytes(v, astWidth(d.op())));
                    // Not foldable — a string literal is an ADDRESS, an
                    // expression has no image at all. main's prologue runs
                    // these as ordinary stores (mirror of the original's
                    // pendingGlobalInits; the base32-alphabet report).
                    else if (!isWeakSlot(d.op()))
                        _pendingGlobalInits.add((Object*)d);
                    }
                }
            _m.addSym(g);
            }
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            {
            Node* d = program.kid(i);
            if (d.kind() == (u16)nkFunctionDecl)
                {
                // Load-time constructors ride in the module header as
                // `modinit "<fn>"`, which each back end turns into an entry in
                // the target's constructor list.
                if (d.hasFlag((u32)NF_MODINIT) && d.name() != 0)
                    _m.addModInit(String.withString(d.name()));
                lowerFunction(d);
                }
            else if (d.kind() == (u16)nkClassDecl)
                lowerClass(d);
            if (_failed)
                return (IRModule*)0;
            }
        // A destructor is dispatched INDIRECTLY: its address is written into
        // every object header at `new` time, so there is no IR-level call edge
        // to it at all. Mark it as escaping — its address genuinely is taken,
        // just not by an instruction — or dead-function elimination drops
        // every dealloc and the whole teardown silently becomes a no-op.
        for (u32 i = (u32)0; i < _m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* sym = (IRSymbol*)_m.syms().get(i);
            if (sym.kind() == (u8)SYM_FUNCTION && sym.name().hasSuffix(String.withCString("$dealloc")))
                sym.setEscapes();
            }
        return _m;
        }

    void lowerClass(Node* cls)
        {
        ClassInfo* info = classFor(cls.name());
        if (info == 0)
            return;
        for (u32 i = (u32)0; i < cls.kidCount(); i = i + (u32)1)
            {
            Node* m = cls.kid(i);
            if (m.kind() != (u16)nkMethodDecl || methodBody(m) == 0)
                continue;
            lowerMethod(info, cls, m);
            if (_failed)
                return;
            }
        if (hasName(_synthDealloc, cls.name()))
            emitSynthDeallocBody(info, cls);
        }

    String* signatureOf(Node* d)
        {
        // The RETURN type is resolved BEFORE the parameters, and the order is
        // load-bearing: resolving a type is what REGISTERS its layout, so it
        // decides the layout table's NUMBERING. Params-first put `_Bigint` at
        // index 10 where the original has it at 1, and every `Agg(N)` after it
        // shifted — 720 differing lines in the arm9 libc interface from this one
        // line. The IR was self-consistent either way, which is why it only
        // showed up as a byte-identity failure.
        String* ret = irReturnOf(d);
        String* s = String.withCString("(");
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1)
            {
            Node* p = d.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            if (n > (u32)0)
                s.appendCString(", ");
            s.append(irType(p.op()));
            n = n + (u32)1;
            }
        s.appendCString(") -> ");
        s.append(ret);
        return s;
        }

    // A function that returns SEVERAL values returns ONE aggregate: the
    // caller cannot be handed two results, so the pair is packed and taken
    // apart at the call site. The layout is created once, when the symbol is
    // registered, and remembered — building it a second time for the body
    // would leave an identical spare layout behind and renumber every one
    // after it.
    String* irReturnOf(Node* d)
        {
        if (!isMultiReturn(d.op()))
            return irType(returnOf(d));
        String* key = d.sym() == 0 ? d.name() : d.sym();
        Object* have = _tupleAgg.get((Hashable*)key);
        if (have != 0)
            return (String*)have;
        IRLayout* L = new IRLayout();
        u32 off = (u32)0;
        Array* parts = splitReturns(d.op());
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            {
            String* t = (String*)parts.get(i);
            // Tuple slots follow the same (capped) natural alignment rule as
            // struct fields — the tuple is a real in-memory buffer on the
            // sret path. Mirror of layoutForTupleReturnTypes:.
            u32 fa = fieldAlignFor(t);
            off = (off + fa - (u32)1) & ~(fa - (u32)1);
            L.addField(off, irType(t));
            off = off + astWidth(t);
            }
        L.setSize(off);
        String* agg = String.withCString("Agg(");
        agg.appendFormat("%ld", (i32)_m.addLayout(L));
        agg.appendCString(")");
        _tupleAgg.set((Hashable*)key, (Object*)agg);
        return agg;
        }

    bool isMultiReturn(String* t)
        {
        if (t == 0)
            return false;
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            if (t.byteAt(i) == (u8)',')
                return true;
        return false;
        }

    Array* splitReturns(String* t)
        {
        Array* out = new Array();
        u32 start = (u32)0;
        for (u32 i = (u32)0; i <= t.byteLength(); i = i + (u32)1)
            {
            if (i < t.byteLength() && t.byteAt(i) != (u8)',')
                continue;
            // LENGTH, not the end index. substringBytes(from, len) takes a
            // length; this passed the comma's index, so every part after the
            // first started correctly and ran too long. It clamps at the end
            // of the string, which is why TWO return values worked by luck —
            // the second part over-ran into nothing — and three did not:
            // `u16,u16,bool` split as "u16", "u16,boo", "bool", and the
            // middle one is not a type, so lowering gave up with
            // `unsupported: type u16,boo`. Multiple return values are a
            // documented language feature; the shipped compiler could not
            // lower more than two of them.
            out.add((Object*)t.substringBytes(start, i - start).trimmed());
            start = i + (u32)1;
            }
        return out;
        }

    // A `void main` still hands the process a status, so it returns I32 — but
    // only when it declared nothing of its own. `i16 main(void)` keeps I16.
    String* returnOf(Node* d)
        {
        String* r = firstReturn(d.op());
        if (isName(d.name(), "main") && isName(stripQual(r), "void"))
            return String.withCString("i32");
        return r;
        }

    // A METHOD is a function with a hidden first formal. What else it needs is
    // `self` bound so a bare ivar name resolves, and — when the receiver is
    // known to be heap-allocated — a retain that survives the body, because
    // the caller may drop its only reference mid-call.
    void lowerMethod(ClassInfo* info, Node* cls, Node* m)
        {
        Node* body = methodBody(m);
        beginFunction(methodSymbolName(cls, m), firstReturn(m.op()));
        Object* frozen = _methodRetIr.get((Hashable*)methodSymbolName(cls, m));
        if (frozen != 0)
            _fn.setRet((String*)frozen);
        _fnThrows = m.hasFlag((u32)NF_THROWS);
        _curClass = info;
        _curMethodName = m.name();
        if (!m.hasFlag((u32)NF_STATIC))
            {
            IRValue* selfV = new IRValue(info.selfPtr());
            _fn.addParam(selfV);
            _self = selfV;
            _locals.set((Hashable*)String.withCString("self"), (Object*)selfV);
            _localTypes.set((Hashable*)String.withCString("self"), (Object*)info.name());
            }
        bindParams(m, (Array*)_methodParIr.get((Hashable*)methodSymbolName(cls, m)));
        _mem = new IRValue(String.withCString("Mem"));
        _fn.addParam(_mem);
        preScanPinned(body);
        if (_failed)
            return;
        _blk = new IRBlock(String.withCString("bb_entry"));
        _fn.addBlock(_blk);
        pushArcScope();
        emitPinnedParamCopies();
        // A STATIC method's `self` is the class's own storage block, taken
        // once at entry — which is what lets ivar access reuse the instance
        // FieldAddr machinery unchanged. It is not an object, so it is never
        // retained.
        if (m.hasFlag((u32)NF_STATIC))
            {
            Array* sops = new Array();
            sops.add((Object*)IROperand.sym(staticDataSymbol(info)));
            _self = emit(String.withCString("AddrOf"), info.selfPtr(), sops);
            _staticSelfClass = info.name();
            }
        if (m.heapRecv() && !m.stackRecv() && !m.hasFlag((u32)NF_STATIC) && _self != 0)
            {
            refOp(String.withCString("Retain"), _self);
            _retainedSelf = _self;
            }
        // A subclass `init` that does not call `super.init()` gets one
        // injected, parent-first, so the parent's ivars are valid before any
        // of the subclass's own code runs. Prepended once, here — unlike the
        // dealloc chain, which appends at every return.
        retainAssignedParams(m);
        if (m.autoSuperInit() && _self != 0)
            emitAutoSuperInit(info);
        lowerStmt(body);
        if (_failed)
            return;
        finishFunction();
        }

    // A static class's `init` runs ONCE, on its own storage block, before the
    // first static call reaches it — otherwise the body reads a zeroed block
    // and silently does nothing (Stdio never sets `canPrint`, so `printf`
    // prints nothing at all). The guard is a byte: test it, and on the way
    // through set it and run the init.
    //
    // Not for a class that is also instantiated AND declares static ivars:
    // running an INSTANCE initialiser against the class's static block is the
    // static-class idiom, but for a `new`-able class it is a category error
    // whose writes are visible through the shared static name.
    void emitStaticInitGuard(ClassInfo* ci)
        {
        if (ci.decl() != 0 && ci.decl().usedByNew())
            {
            for (ClassInfo* c = ci; c != 0; c = c.parent())
                if (hasStaticIvar(c))
                    return;
            }
        String* initSym = (String*)0;
        for (ClassInfo* c = ci; c != 0 && initSym == 0; c = c.parent())
            {
            String* cand = String.withString(c.name());
            cand.appendCString("$init");
            if (symbolExists(cand))
                initSym = cand;
            }
        if (initSym == 0)
            return;

        // Single-threaded: flagVal == 0 means "not yet run". Threaded: the flag
        // is tri-state and DONE is 2, so the fast path tests `!= 2` — the same
        // load / compare / branch, one immediate different. 0 = untouched,
        // 1 = an init is in flight, 2 = complete.
        bool safeOnce = _threadSafeStatics;
        i32 doneVal = safeOnce ? (i32)2 : (i32)0;

        String* u8Ptr = ptrTo(String.withCString("U8"));
        Array* fops = new Array();
        fops.add((Object*)IROperand.sym(staticInitFlag(ci)));
        IRValue* flagPtr = emit(String.withCString("AddrOf"), u8Ptr, fops);
        IRValue* flagVal = loadThrough(flagPtr, String.withCString("u8"));
        Array* zops = new Array();
        zops.add((Object*)IROperand.immI(doneVal, String.withCString("U8")));
        IRValue* zero = emit(String.withCString("Const"), String.withCString("U8"), zops);
        IRInsn* cmp = IRInsn.with(String.withCString("ICmp"));
        cmp.setRes(new IRValue(String.withCString("Bool")));
        cmp.setPred(safeOnce ? String.withCString("NE") : String.withCString("EQ"));
        cmp.add(IROperand.useVal(flagVal));
        cmp.add(IROperand.useVal(zero));
        _blk.add(cmp);

        String* prefix = blockPrefix();
        prefix.appendCString("_sinit_");
        prefix.append(ci.name());
        String* rn = String.withString(prefix);
        rn.appendCString("_run");
        String* cn = String.withString(prefix);
        cn.appendCString("_cont");
        IRBlock* runB = addBlock(rn);
        IRBlock* contB = addBlock(cn);
        IRInsn* cb = IRInsn.with(String.withCString("CondBranch"));
        cb.add(IROperand.useVal(cmp.res()));
        cb.add(IROperand.block(runB));
        cb.add(IROperand.block(contB));
        _blk.setTerm(cb);

        _blk = runB;
        // Single-threaded: set the flag BEFORE the body, so a re-entrant static
        // use of the SAME class sees zeroed state instead of recursing.
        // Threaded: _xtc_sinit_enter does the 0->1 claim atomically and answers
        // whether THIS caller must run the body — the winner gets 1, a
        // re-entrant caller on the owning thread gets 0 and sees that same
        // zeroed state, and a DIFFERENT thread blocks until 2 is published.
        if (safeOnce)
            {
            // One call, then the branch to cont — deliberately a SINGLE block.
            // _xtc_sinit_run takes the initialiser and its static block and does
            // the claim, the call and the publish itself. An earlier version
            // split it (enter -> test -> call -> done), and that cost the
            // optimisation: the guard-hoisting pass requires a run block that is
            // one block ending in Branch.
            emitSinitRun(flagPtr, initSym, staticDataSymbol(ci), ci, contB);
            return;
            }
            {
            Array* oops = new Array();
            oops.add((Object*)IROperand.immI((i32)1, String.withCString("U8")));
            storeThrough(flagPtr, emit(String.withCString("Const"), String.withCString("U8"), oops));
            }
        Array* sops = new Array();
        sops.add((Object*)IROperand.sym(staticDataSymbol(ci)));
        IRValue* sdata = emit(String.withCString("AddrOf"), ci.selfPtr(), sops);
        emitMethodCall(initSym, sdata, new Array(), (String*)0, false);
        // Publish completion AFTER the body, so a waiter resumes only once the
        // statics are actually written.
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(contB));
        _blk.setTerm(br);
        _blk = contB;
        }

    bool hasStaticIvar(ClassInfo* c)
        {
        Node* d = c.decl();
        if (d == 0)
            return false;
        for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1)
            {
            Node* iv = d.kid(i);
            if (iv.kind() == (u16)nkVariableDecl && iv.hasFlag((u32)NF_STATIC))
                return true;
            }
        return false;
        }

    // The threaded slow path of the static-init guard, split out because the
    // guard function is already at the arm64 frame budget.
    //
    // `_xtc_sinit_run(&flag, &C$init, &__sdata_C)` — one call that claims,
    // initialises and publishes, so the slow path stays a single basic block.
    void emitSinitRun(IRValue* flagPtr, String* initSym, String* sdataSym,
                      ClassInfo* ci, IRBlock* contB)
        {
        Array* iops = new Array();
        iops.add((Object*)IROperand.sym(initSym));
        IRValue* initPtr = emit(String.withCString("AddrOf"),
                                ptrTo(String.withCString("U8")), iops);
        Array* dops = new Array();
        dops.add((Object*)IROperand.sym(sdataSym));
        IRValue* sdataPtr = emit(String.withCString("AddrOf"), ci.selfPtr(), dops);
        Array* args = new Array();
        args.add((Object*)flagPtr);
        args.add((Object*)initPtr);
        args.add((Object*)sdataPtr);
        emitMethodCall(runtimeHelper(String.withCString("_xtc_sinit_run")),
                       (IRValue*)0, args, (String*)0, false);
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(contB));
        _blk.setTerm(br);
        _blk = contB;
        }

    String* staticInitFlag(ClassInfo* ci)
        {
        String* name = String.withCString("__sinit_");
        name.append(ci.name());
        if (!symbolExists(name))
            _m.addSym(IRSymbol.dataGlobal(name, String.withCString("U8")));
        return name;
        }

    // One storage block per class, created the first time a static method
    // needs it — which is why it appears in the symbol table after the
    // functions rather than with them.
    String* staticDataSymbol(ClassInfo* info)
        {
        Object* have = _sdata.get((Hashable*)info.name());
        if (have != 0)
            return (String*)have;
        String* name = String.withCString("__sdata_");
        name.append(info.name());
        _m.addSym(IRSymbol.dataGlobal(name, info.agg()));
        _sdata.set((Hashable*)info.name(), (Object*)name);
        return name;
        }

    void emitAutoSuperInit(ClassInfo* info)
        {
        for (ClassInfo* p = info.parent(); p != 0; p = p.parent())
            {
            if (zeroArgInit(p) == 0)
                continue;
            String* sym = String.withString(p.name());
            sym.appendCString("$init");
            if (!symbolExists(sym))
                continue;
            emitMethodCall(sym, _self, new Array(), (String*)0, false);
            return;
            }
        }

    void beginFunction(String* name, String* ret)
        {
        _fn = new IRFunc();
        _fn.setName(name);
        clearStaticLocals();
        _fnReturn = ret;
        _fnRetAgg = (String*)0;
        _fn.setRet(irType(_fnReturn));
        _locals = new Map();
        // Per FUNCTION, not per module. `T@ p = new T[N]` records N against the
        // NAME p, and `.length` reads it back as a constant — so an entry that
        // outlives its function answers for an unrelated local with the same
        // name in the next one. String.xc has `u8* buf = new u8[96]`, which is
        // why any user function with a `buf` got `buf.length == 96`: a wrong
        // ANSWER, silently, with no header read emitted at all. The original
        // clears this in _lowerCallable: alongside _locals; this was created
        // once at construction and never again.
        _heapArrayLen = new Map();
        _localTypes = new Map();
        _pins = new Map();
        _pinnedParamInit = new Map();
        _pinAst = new Map();
        _pinDeclTys = new Map();
        _pinSeq = new Map();
        _pinNext = new Map();
        _pinDeclTys = new Map();
        _pinSeq = new Map();
        _pinNext = new Map();
        _arrayElem = new Map();
        _valueClass = new Map();
        _weakLocals = new Array();
        _weakArray = new Map();
        _strongArray = new Map();
        _strongStruct = new Map();
        _arcScopes = new Array();
        _gotoLabelBlocks = new Map();
        _gotoLabelDepths = new Map();
        _deferScopes = new Array();
        _tryHandlers = new Array();
        _fnThrows = false;
        _strongLocals = new Array();
        _curClass = (ClassInfo*)0;
        _curMethodName = (String*)0;
        _staticSelfClass = (String*)0;
        _self = (IRValue*)0;
        _retainedSelf = (IRValue*)0;
        }

    void bindParams(Node* d)
        {
        bindParams(d, (Array*)0);
        }

    // `frozen`, when given, holds the IR types the SYMBOL was built with. A
    // class named in a parameter that was not registered yet collapsed to an
    // opaque pointer there, and the function has to agree with its own
    // signature — resolving again now, with every class registered, would give
    // the two different types.
    void bindParams(Node* d, Array* frozen)
        {
        u32 pi = (u32)0;
        for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1)
            {
            Node* p = d.kid(i);
            if (p.kind() != (u16)nkParam)
                continue;
            String* pty = (frozen != 0 && pi < frozen.count())
                              ? (String*)frozen.get(pi)
                              : irType(p.op());
            pi = pi + (u32)1;
            IRValue* v = new IRValue(pty);
            _fn.addParam(v);
            _locals.set((Hashable*)p.name(), (Object*)v);
            _localTypes.set((Hashable*)p.name(), (Object*)p.op());
            // A value-typed struct PARAMETER is an aggregate, so `p.x` has to
            // resolve through its address like any other. It needs no frame
            // slot — the prologue already spills every parameter — so it pins
            // to its own value and stays OUT of the frame list, where counting
            // it would allocate the storage a second time.
            if (irType(p.op()).hasPrefix(String.withCString("Agg(")))
                {
                _pins.set((Hashable*)p.name(),
                          (Object*)IRPinned.with(v, v.ty(), (u32)0, false));
                _pinAst.set((Hashable*)p.name(), (Object*)p.op());
                }
            }
        }

    // Falling off the end still has to name the memory token, tear the scope
    // down, and — for `main` — produce a status.
    void finishFunction(void)
        {
        if (_blk.term() == 0)
            {
            releaseAlongExit();
            IRInsn* r = IRInsn.with(String.withCString("Return"));
            if (!isName(irType(_fnReturn), "Void"))
                {
                IRValue* z = constOf((i64)0, _fnReturn);
                r.add(IROperand.useVal(z));
                }
            r.add(IROperand.useVal(_mem));
            _blk.setTerm(r);
            }
        popArcScope();
        _m.addFunc(_fn);
        // A trampoline synthesised while this body was being lowered lands
        // after it, which is where the original puts it too.
        for (u32 i = (u32)0; i < _pendingFns.count(); i = i + (u32)1)
            _m.addFunc((IRFunc*)_pendingFns.get(i));
        _pendingFns = new Array();
        }

    void lowerFunction(Node* d)
        {
        Node* body = (Node*)0;
        for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1)
            if (d.kid(i).kind() == (u16)nkBlock)
                body = d.kid(i);
        if (body == 0)
            return; // a prototype has a symbol but no function

        beginFunction(d.sym() == 0 ? d.name() : d.sym(), returnOf(d));
        _fnThrows = d.hasFlag((u32)NF_THROWS);
        if (isMultiReturn(d.op()))
            {
            _fnRetAgg = irReturnOf(d);
            _fn.setRet(_fnRetAgg);
            }
        bindParams(d);
        _mem = new IRValue(String.withCString("Mem"));
        _fn.addParam(_mem);

        // Which locals get frame slots is settled before any block is lowered —
        // it changes how every mention of those names lowers, and the slots'
        // offsets belong to the whole function.
        preScanPinned(body);
        if (_failed)
            return;

        _blk = new IRBlock(String.withCString("bb_entry"));
        _fn.addBlock(_blk);
        pushArcScope();
        emitPinnedParamCopies();
        // Deferred global initialisers: main's prologue is the earliest point
        // every target reaches exactly once, before any user statement can
        // read the global. A class-typed initialiser's +1 is ADOPTED (plain
        // store, no retain) — the ownership a global holds to process exit.
        if (isName(_fn.name(), "main") && _pendingGlobalInits.count() > (u32)0)
            {
            Array* pend = _pendingGlobalInits;
            _pendingGlobalInits = new Array();
            for (u32 gi = (u32)0; gi < pend.count(); gi = gi + (u32)1)
                {
                Node* g = (Node*)pend.get(gi);
                String* aty = stripQual(g.op());
                // An ARRAY initialiser `{ … }` whose elements aren't constant-
                // foldable (symbol addresses): store each element, coercing per
                // element — WIDENS `callback tab[N] = {&a,&b}` to {recv,code}
                // pairs and stores `pointer p[N] = {&a,&b}` addresses. A callback
                // (or `weak:`) element is an auto-zeroing SLOT, so the stride
                // spans the two link words and the value lands at the payload
                // (field 2), the same shape the subscript read uses. Bug 167.
                if (isArrayLike(aty) && g.kid((u32)0).kind() == (u16)nkBlock)
                    {
                    String* elem = elementOf(aty);
                    bool weakElem = isWeakSlot(elem);
                    String* payloadIr = irType(elem);
                    String* elemIr = weakElem ? weakSlotAggOf(elem) : payloadIr;
                    Array* aop = new Array();
                    aop.add((Object*)IROperand.sym(globalSymName(g.name())));
                    IRValue* aslot = emit(String.withCString("AddrOf"),
                                          ptrTo(irType(aty)), aop);
                    Array* bop = new Array();
                    bop.add((Object*)IROperand.useVal(aslot));
                    IRValue* base = emit(String.withCString("Bitcast"),
                                         ptrTo(elemIr), bop);
                    Node* list = g.kid((u32)0);
                    u32 cnt = arrayCount(aty);
                    for (u32 ei = (u32)0; ei < list.kidCount() && ei < cnt; ei = ei + (u32)1)
                        {
                        IRValue* ev = lowerExpr(list.kid(ei));
                        if (_failed)
                            return;
                        if (ev == (IRValue*)0)
                            continue;
                        ev = coerce(ev, list.kid(ei).ty(), elem);
                        if (ev == (IRValue*)0)
                            continue;
                        Array* io = new Array();
                        io.add((Object*)IROperand.immI((i32)ei, String.withCString("U16")));
                        IRValue* idxC = emit(String.withCString("Const"),
                                             String.withCString("U16"), io);
                        Array* eo = new Array();
                        eo.add((Object*)IROperand.useVal(base));
                        eo.add((Object*)IROperand.useVal(idxC));
                        IRValue* ea = emit(String.withCString("ElementAddr"),
                                           ptrTo(elemIr), eo);
                        if (weakElem)
                            ea = fieldAddr(ea, (u32)2, ptrTo(payloadIr));
                        storeThrough(ea, ev);
                        }
                    continue;
                    }
                IRValue* v = lowerExpr(g.kid((u32)0));
                if (_failed)
                    return;
                if (v == (IRValue*)0)
                    continue;
                v = coerce(v, g.kid((u32)0).ty(), stripQual(g.op()));
                if (v == (IRValue*)0)
                    continue;
                String* ity = irType(stripQual(g.op()));
                String* pty = String.withCString("Ptr(");
                pty.append(ity);
                pty.appendCString(", unbanked)");
                Array* ops = new Array();
                ops.add((Object*)IROperand.sym(globalSymName(g.name())));
                IRValue* addr = emit(String.withCString("AddrOf"), pty, ops);
                storeThrough(addr, v);
                }
            }
        retainAssignedParams(d);
        lowerStmt(body);
        if (_failed)
            return;
        finishFunction();
        }
    }
