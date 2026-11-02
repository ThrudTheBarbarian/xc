// Lower.xc — the analysed AST becomes IR: the module, and the files below.
// =========================================================================
//
// The lowering is one class, Lower, in layers (2026-11-02: one file of
// 25,800 lines was the split build's longest object):
//
//   LowerBase.xc          class Lower: every field, and the AST lowered to
//                         IR (one file: its parts call each other)
//   LowerParCommon.xc     what the GPU kernel printers share
//   LowerPar{Metal,Lanes,Ptx,Spirv,Wgsl}.xc
//                         a `par` kernel for each GPU
//   LowerPar.xc           `par` blocks: the check, and their kernels filled in
//   Lower.xc              this file: run, the functions it lowers, and the
//                         kernel hook; importing Lower still sees all of it
//
// A file imports only what it calls, and the imports have no cycles (the
// split build refuses one). Every field is declared in LowerBase.xc.


#import "Foundation.xc"
#import <Node>
#import "NodeDefs.xc"
#import <Types>
#import <Vtable>
#import <Ir>
#import "IrDefs.xc"
#import <FloatEncoding>
#import <ParSpirv>
#import "ParSpirvDefs.xc"
#import <ParWgsl>
#import <Overload>
#import "Process.xc"
#import <OptBase>
#import <Opt>
#import "OptDefs.xc"
#import <IrParse>
#import <LowerBase>
#import <LowerParCommon>
#import <LowerParPtx>
#import <LowerParMetal>
#import <LowerParLanes>
#import <LowerParSpirv>
#import <LowerParWgsl>
#import <LowerPar>

    class Lower (Module)
    {

    static Lower* make(void)
        {
        return new Lower();
        }

    // ── the module: run, and the functions it lowers ─────────────────────

    final IRModule* run(Node* program, String* moduleName)
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
        // The classes whose `_xtc_cname_<C>` the driver generated; each goes
        // in its class's itable, where Object.className() looks for it.
        _cnameClasses = new Map();
        for (u32 ci = (u32)0; ci < program.kidCount(); ci = ci + (u32)1)
            {
            Node* cd = program.kid(ci);
            if (cd.kind() != (u16)nkFunctionDecl || cd.name() == (String*)0)
                continue;
            if (!cd.name().hasPrefix(String.withCString("_xtc_cname_")))
                continue;
            bool defined = false;
            for (u32 b = (u32)0; b < cd.kidCount(); b = b + (u32)1)
                if (cd.kid(b) != (Node*)0 && cd.kid(b).kind() == (u16)nkBlock)
                    defined = true;
            if (!defined)
                continue;
            String* cn = cd.name().substringFromByte((u32)11);
            _cnameClasses.set((Hashable*)cn, (Object*)cn);
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
        Array* cnames = self.sortedNames(_classDecls.allKeys());
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
                self.preScanClass(d);
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    {
                    Node* m = d.kid(j);
                    if (m.kind() != (u16)nkMethodDecl || !self.isName(m.name(), "dealloc"))
                        continue;
                    if (callsSuperDealloc(self.methodBody(m)))
                        self.addUnique(_deallocCallsSuper, d.name());
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
            Array* fg = (Array*)_funcGroups.get((Hashable*)d.name());
            if (fg == (Array*)0)
                {
                fg = new Array();
                _funcGroups.set((Hashable*)d.name(), (Object*)fg);
                }
            fg.add((Object*)d);
            // …and under the MANGLED name, which is what tells two overloads
            // apart. Keyed by name alone, `show(u32)` and `show(u8,u8)` are
            // the same entry and whichever was declared last answers for both.
            if (d.sym() != 0)
                _funcsBySym.set((Hashable*)d.sym(), (Object*)d);
            IRSymbol* fsym = IRSymbol.func(d.sym() == 0 ? d.name() : d.sym(),
                                           self.signatureOf(d),
                                           d.hasFlag((u32)NF_VARARGS),
                                           d.hasFlag((u32)NF_CABI));
            if (d.hasFlag((u32)NF_THROWS))
                fsym.setThrows();
            if (d.hasFlag((u32)NF_IRQ))
                fsym.setIrq();
            if (d.hasFlag((u32)NF_VBI))
                fsym.setVbi();
            // `:banked` / `:main` reach the symbol the way they do on a
            // method: the xt6502 placement reads `banked` (never kept in main
            // RAM, even under -Fmb) and `main` (never banked). `main` only
            // when set, like irq/vbi. private:docs/bugs/267.
            if (d.hasFlag((u32)NF_BANKED))
                fsym.setAttr(String.withCString("banked"), true);
            if (d.hasFlag((u32)NF_MAINRAM))
                fsym.setAttr(String.withCString("main"), true);
            // `:xtcStack` / `:hwStack`: the xt6502 back end's calling
            // convention for this function, overriding --xtc-stack. Only when
            // set, like the flags above.
            if (d.hasFlag((u32)NF_XTCSTACK))
                fsym.setAttr(String.withCString("xtcstack"), true);
            else if (d.hasFlag((u32)NF_HWSTACK))
                fsym.setAttr(String.withCString("hwstack"), true);
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
            if (!self.symbolExists(d.sym() == 0 ? d.name() : d.sym()))
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
            self.sizeArrayFromInitialiser(d);
            _globals.set((Hashable*)d.name(), (Object*)d.op());
            // An auto-zeroing GLOBAL carries the same two hidden link words a
            // local's slot does: the runtime walks a chain to zero it, and the
            // chain has to be threaded through storage the referent can find.
            String* gty = self.isWeakSlot(d.op())
                              ? self.weakSlotAggOf(d.op())
                              : self.irType(d.op());
            IRSymbol* g = IRSymbol.dataGlobal(d.name(), gty);
            // §6: `extern` WITH an initialiser = an exported definition —
            // the original stamps `exported` on the global's symbol. The
            // parser already swapped NF_EXTERN for NF_EXPORTED on it.
            if (d.hasFlag((u32)NF_EXPORTED))
                g.setAttr(String.withCString("exported"), true);
            // A bodyless `extern` global is defined in another module (a C
            // library or a framework's `kSecClass`): a reference through the
            // GOT, no storage here. Without this it was emitted as a common
            // symbol, so the program read its own zeroed copy.
            if (d.hasFlag((u32)NF_EXTERN))
                g.setAttr(String.withCString("extern"), true);
            // An initialised global carries its bytes, little-endian, folded
            // at compile time — the backend bakes the payload in, so the
            // initialiser is not code that runs.
            if (d.kidCount() > (u32)0)
                {
                Array* bytes = self.foldInitialiser(d.kid((u32)0), d.op());
                if (bytes != 0)
                    g.setBytes(bytes);
                // Not foldable — a string literal is an ADDRESS, an
                // expression has no image at all. main's prologue runs
                // these as ordinary stores (mirror of the original's
                // pendingGlobalInits; the base32-alphabet report).
                else if (!self.isWeakSlot(d.op()))
                    _pendingGlobalInits.add((Object*)d);
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
                self.lowerFunction(d);
                }
            else if (d.kind() == (u16)nkClassDecl)
                self.lowerClass(d);
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
        // Bound-method trampolines last, by name: each was added where it was
        // first needed, which depends on the lowering order. As the reference.
        self.trampolinesLast();
        // `par` blocks must stay within the GPU subset on every target
        // (par-blocks.md §2).
        self.parCheck();
        if (_failed)
            return (IRModule*)0;
        self.parFillSources();
        // Instructions an optimisation pass makes later carry no location of
        // their own; they must not take the last statement's.
        IRDbg.clearCurrent();
        return _m;
        }
    }

// The lowering's printers, for the blocks the IR outliner makes in the
// optimiser (it holds the lowering, so the lowering outlives the front end).
class LowerKernelHook : ParKernelHook
    {
    Lower* _l;
    static LowerKernelHook* with(Lower* l)
        {
        LowerKernelHook* h = new LowerKernelHook();
        h._l = l;
        return h;
        }
    void print(IRModule* m, Array* blocks)
        {
        _l.parFillOutlined(m, blocks);
        }
    }
