// Ir.xc — the IR the front end hands to a back end, and the text it prints as.
// =========================================================================
//
// self-hosting M6b. The port of XTIRModule / XTIRFunction / XTIRBlock /
// XTIRInsn / XTIROperand and of XTIRPrinter, which between them define the
// text that crosses the front-end / back-end process boundary. The ORACLE for
// this module is `xtc-fe` itself: its ordinary output IS this text, so a
// ported lowering can be diffed against the original byte for byte.
//
// Two shortcuts, both the same one the parser and analyser ports took:
//
//   * A TYPE is its spelling. `U16`, `Ptr(U8, unbanked)`, `Agg(0)`, `Mem` —
//     the printer only ever renders a type, and the lowering only ever needs
//     to compare and construct them, so a String carries the whole job and
//     there is no type table to keep in step.
//   * An OPERAND holds the value it uses, not its id. The original prints
//     through a per-function renumbering map (creation order is not print
//     order); holding the object means the printer can stamp a print-id on
//     each value and read it back through the operand with no map at all.
//
// Print-ids are assigned in the original's canonical order — parameters,
// pinned locals, then block by block: phis, instructions, terminator — which
// is what makes the two texts comparable at all.

#import "Foundation.xc"

class IRValue
    {
    u32 _pid;    // the number the printer gives it, `%3`
    String* _ty; // its type spelling
    // The order this value was CREATED in. The original allocates a value id at
    // creation and a back end lays out frame slots in id order, so a pass that
    // rewrites a function shifts every slot after the values it made. The port
    // stamps print-ids only at print time, which is dense and renumbered — so
    // the creation order has to be recorded separately for a back end to
    // reproduce the same frame.
    u32 _seq;
    static u32 _nextSeq;

    void init(void)
        {
        _pid = (u32)0;
        _ty = String.withCString("Void");
        stamp();
        }
    void init(String* t)
        {
        _pid = (u32)0;
        _ty = t;
        stamp();
        }
    void stamp(void)
        {
        _nextSeq = _nextSeq + (u32)1;
        _seq = _nextSeq;
        }
    u32 seq(void)
        {
        return _seq;
        }
    u32 pid(void)
        {
        return _pid;
        }
    void setPid(u32 v)
        {
        _pid = v;
        }
    String* ty(void)
        {
        return _ty;
        }
    void setTy(String* t)
        {
        _ty = t;
        }
    }

// Kinds an operand can take. The original's XTIROperandKind, in its order.
#define OPK_USE $00
#define OPK_IMMI $01
#define OPK_IMMF $02
#define OPK_SYM $03
#define OPK_BLOCK $04
#define OPK_CPOOL $05

    class IROperand
    {
    u8 _kind;
    IRValue* _val;  // OPK_USE
    i64 _imm;       // OPK_IMMI
    bool _uimm;     // …and whether its bits read as an UNSIGNED quantity
    String* _fpHex; // OPK_IMMF — the double's 64 raw bits, as 16 hex digits
    String* _ty;    // OPK_IMMI / OPK_IMMF
    String* _name;  // OPK_SYM
    IRBlock* _blk;  // OPK_BLOCK
    u32 _cid;       // OPK_CPOOL

    void init(void)
        {
        _kind = (u8)OPK_USE;
        _imm = (i64)0;
        _uimm = false;
        _cid = (u32)0;
        }

    static IROperand* useVal(IRValue* v)
        {
        IROperand* o = new IROperand();
        o._kind = (u8)OPK_USE;
        o._val = v;
        return o;
        }

    static IROperand* immI(i64 v, String* t)
        {
        IROperand* o = new IROperand();
        o._kind = (u8)OPK_IMMI;
        o._imm = v;
        o._ty = t;
        return o;
        }

    // The same immediate, read as an unsigned quantity. A byte-list assembles
    // BYTES into a value — `{$00, $00, $00, $80}` is 2147483648, not −1 — so
    // the pattern's top bit is a magnitude, not a sign, whatever the target's
    // own signedness says. The original carries a 64-bit value and never has
    // to make the distinction; a 32-bit one does.
    static IROperand* immU(u32 v, String* t)
        {
        IROperand* o = new IROperand();
        o._kind = (u8)OPK_IMMI;
        o._imm = (i64)v;
        o._uimm = true;
        o._ty = t;
        return o;
        }

    // The same, at full width — for a literal whose bits fill an i64 and so
    // arrives here negative without meaning to be.
    static IROperand* immU64(u64 v, String* t)
        {
        IROperand* o = new IROperand();
        o._kind = (u8)OPK_IMMI;
        o._imm = (i64)v;
        o._uimm = true;
        o._ty = t;
        return o;
        }

    // A float immediate is spelled by its BITS, not by its value — the text
    // has to round-trip exactly, and a decimal rendering does not. The caller
    // hands over the 64 bits already spelled, because appendFormat has no
    // zero-padded hex and a `%lx` would drop the leading zeroes that make the
    // field 16 digits wide.
    static IROperand* immF(String* hex64, String* t)
        {
        IROperand* o = new IROperand();
        o._kind = (u8)OPK_IMMF;
        o._fpHex = hex64;
        o._ty = t;
        return o;
        }

    static IROperand* sym(String* n)
        {
        IROperand* o = new IROperand();
        o._kind = (u8)OPK_SYM;
        o._name = n;
        return o;
        }

    static IROperand* block(IRBlock* b)
        {
        IROperand* o = new IROperand();
        o._kind = (u8)OPK_BLOCK;
        o._blk = b;
        return o;
        }

    // A reference into the module's constant pool — how an inline-asm body
    // reaches the IR without the IR having to understand a word of it.
    static IROperand* cpool(u32 id)
        {
        IROperand* o = new IROperand();
        o._kind = (u8)OPK_CPOOL;
        o._cid = id;
        return o;
        }

    u8 kind(void)
        {
        return _kind;
        }
    IRValue* val(void)
        {
        return _val;
        }
    IRBlock* blk(void)
        {
        return _blk;
        }
    // What a BACK END reads off an operand the printer only ever renders: the
    // immediate itself, the type it was spelled with, the symbol it names, and
    // the constant-pool slot it points at.
    i64 imm(void)
        {
        return _imm;
        }
    // Whether those bits read as an UNSIGNED quantity — the printer spells
    // `%lu` when they do, so a pass that rebuilds an immediate has to carry
    // this or a large U32 comes back out as a negative number.
    bool uimm(void)
        {
        return _uimm;
        }
    String* fpHex(void)
        {
        return _fpHex;
        }
    String* ty(void)
        {
        return _ty;
        }
    String* name(void)
        {
        return _name;
        }
    u32 cid(void)
        {
        return _cid;
        }

    String* text(void)
        {
        if (_kind == (u8)OPK_USE)
            {
            String* s = String.withCString("%");
            s.appendFormat("%ld", (i32)(_val == 0 ? (u32)0 : _val.pid()));
            return s;
            }
        if (_kind == (u8)OPK_IMMI)
            {
            String* s = String.withCString("#");
            // withI64/withU64, not "%ld": appendFormat understands one `l`, so
            // its widest integer is 32 bits, while the oracle prints %lld. A
            // 64-bit Const would have truncated here even with a wide payload.
            if (_uimm)
                s.appendFormat("%s:%s", String.withU64((u64)_imm).cString(), _ty.cString());
            else
                s.appendFormat("%s:%s", String.withI64(_imm).cString(), _ty.cString());
            return s;
            }
        if (_kind == (u8)OPK_IMMF)
            {
            String* s = String.withCString("#fp");
            s.append(_fpHex);
            s.appendCString(":");
            s.append(_ty);
            return s;
            }
        if (_kind == (u8)OPK_SYM)
            {
            String* s = String.withCString("@");
            s.append(_name);
            return s;
            }
        if (_kind == (u8)OPK_BLOCK)
            return _blk == 0 ? String.withCString("bb_?") : _blk.name();
        String* s = String.withCString("#cpool:");
        s.appendFormat("%ld", (i32)_cid);
        return s;
        }
    }

    class IRInsn
    {
    String* _op; // the mnemonic, exactly as the printer spells it
    IRValue* _res;
    IRValue* _memRes;
    Array* _ops;
    String* _pred; // ICmp / FCmp only
    String* _cc;   // call opcodes only

    void init(void)
        {
        _ops = new Array();
        _op = String.withCString("?");
        }

    static IRInsn* with(String* mnemonic)
        {
        IRInsn* i = new IRInsn();
        i._op = mnemonic;
        return i;
        }

    String* op(void)
        {
        return _op;
        }
    IRValue* res(void)
        {
        return _res;
        }
    void setRes(IRValue* v)
        {
        _res = v;
        }
    IRValue* memRes(void)
        {
        return _memRes;
        }
    void setMemRes(IRValue* v)
        {
        _memRes = v;
        }
    Array* ops(void)
        {
        return _ops;
        }
    void add(IROperand* o)
        {
        _ops.add((Object*)o);
        }
    String* pred(void)
        {
        return _pred;
        }
    void setPred(String* p)
        {
        _pred = p;
        }
    String* cc(void)
        {
        return _cc;
        }
    void setCc(String* c)
        {
        _cc = c;
        }

    bool isCall(void)
        {
        return _op.equals(String.withCString("Call")) || _op.equals(String.withCString("CallCloaked")) || _op.equals(String.withCString("CallBanked")) || _op.equals(String.withCString("CallIndirect")) || _op.equals(String.withCString("CallBankedIndirect"));
        }

    String* text(void)
        {
        String* line = String.withCString("");
        // LHS: the result, the memory result, or both.
        if (_res != 0)
            {
            line.appendFormat("%%%ld:%s", (i32)_res.pid(), _res.ty().cString());
            if (_memRes != 0)
                line.appendFormat(", %%%ld", (i32)_memRes.pid());
            line.appendCString(" = ");
            }
        else if (_memRes != 0)
            {
            line.appendFormat("%%%ld = ", (i32)_memRes.pid());
            }
        line.append(_op);

        if (_op.equals(String.withCString("Phi")))
            {
            line.appendCString(" [");
            u32 pairs = (u32)0;
            for (u32 i = (u32)0; i + (u32)1 < _ops.count(); i = i + (u32)2)
                {
                if (pairs > (u32)0)
                    line.appendCString(", ");
                line.appendCString("(");
                line.append(((IROperand*)_ops.get(i)).text());
                line.appendCString(", ");
                line.append(((IROperand*)_ops.get(i + (u32)1)).text());
                line.appendCString(")");
                pairs = pairs + (u32)1;
                }
            line.appendCString("]");
            return line;
            }
        if (isCall())
            {
            // <callee>, [args], CallConv::Kind, %mem
            u32 n = _ops.count();
            if (n < (u32)2)
                return line;
            line.appendCString(" ");
            line.append(((IROperand*)_ops.get((u32)0)).text());
            line.appendCString(", [");
            for (u32 i = (u32)1; i + (u32)1 < n; i = i + (u32)1)
                {
                if (i > (u32)1)
                    line.appendCString(", ");
                line.append(((IROperand*)_ops.get(i)).text());
                }
            line.appendCString("], ");
            line.append(_cc == 0 ? String.withCString("CallConv::Standard") : _cc);
            line.appendCString(", ");
            line.append(((IROperand*)_ops.get(n - (u32)1)).text());
            return line;
            }
        if (_pred != 0)
            {
            line.appendCString(" ");
            line.append(_pred);
            for (u32 i = (u32)0; i < _ops.count(); i = i + (u32)1)
                {
                line.appendCString(", ");
                line.append(((IROperand*)_ops.get(i)).text());
                }
            return line;
            }
        for (u32 i = (u32)0; i < _ops.count(); i = i + (u32)1)
            {
            line.appendCString(i == (u32)0 ? " " : ", ");
            line.append(((IROperand*)_ops.get(i)).text());
            }
        return line;
        }
    }

    class IRBlock
    {
    String* _name;
    Array* _phis;
    Array* _insns;
    IRInsn* _term;

    void init(void)
        {
        _phis = new Array();
        _insns = new Array();
        }
    void init(String* n)
        {
        _phis = new Array();
        _insns = new Array();
        _name = n;
        }

    String* name(void)
        {
        return _name;
        }
    Array* phis(void)
        {
        return _phis;
        }
    Array* insns(void)
        {
        return _insns;
        }
    IRInsn* term(void)
        {
        return _term;
        }
    void setTerm(IRInsn* t)
        {
        _term = t;
        }
    void addPhi(IRInsn* p)
        {
        _phis.add((Object*)p);
        }
    void add(IRInsn* i)
        {
        _insns.add((Object*)i);
        }
    // An OPT pass rebuilds a block's instruction list — vaarg-expand replaces
    // one abstract op with the seven it lowers to.
    void setInsns(Array* a)
        {
        _insns = a;
        }
    // …and a pass that SPLITS a block hands the tail its phi list too.
    void setPhis(Array* a)
        {
        _phis = a;
        }
    }

    // A local pinned to a frame slot — the ones whose address escapes, and the
    // ones a backend cannot keep in SSA.
    class IRPinned
    {
    IRValue* _val;
    String* _ty;
    u32 _off;
    bool _esc;

    void init(void)
        {
        _off = (u32)0;
        _esc = false;
        }
    static IRPinned* with(IRValue* v, String* t, u32 off, bool esc)
        {
        IRPinned* p = new IRPinned();
        p._val = v;
        p._ty = t;
        p._off = off;
        p._esc = esc;
        return p;
        }
    IRValue* val(void)
        {
        return _val;
        }
    String* ty(void)
        {
        return _ty;
        }
    u32 off(void)
        {
        return _off;
        }
    bool esc(void)
        {
        return _esc;
        }
    }

    class IRFunc
    {
    String* _name;
    Array* _params; // IRValue@, the trailing Mem included
    Array* _blocks;
    String* _ret; // the RETURN type spelling, `Void` for none
    Array* _pinned;
    u32 _pinnedSize;
    // Loop-header block NAMES that `for (...) : unroll` asked to unroll. The IR
    // carries no per-loop metadata otherwise, and this is deliberately the
    // smallest thing that changes that: names, printed as one conditional
    // `unroll: [...]` line beside `frame:`. A marker opcode would have touched
    // the opcode table, printer, parser, verifier and every back end, to carry
    // one bit.
    Array* _unrollHeaders; // of String@
    // Value id -> IRValue@, sparse, indexed by the id itself. The PRINTER never
    // needs this (an operand holds its value), but a BACK END does: a frame slot
    // is assigned to every value in id order, pinned locals included, and those
    // are never an instruction result.
    Array* _byId;

    void init(void)
        {
        _params = new Array();
        _blocks = new Array();
        _pinned = new Array();
        _unrollHeaders = new Array();
        _byId = new Array();
        _ret = String.withCString("Void");
        _pinnedSize = (u32)0;
        }

    String* name(void)
        {
        return _name;
        }
    void setName(String* n)
        {
        _name = n;
        }
    Array* params(void)
        {
        return _params;
        }
    void addParam(IRValue* v)
        {
        _params.add((Object*)v);
        }
    Array* blocks(void)
        {
        return _blocks;
        }
    void addBlock(IRBlock* b)
        {
        _blocks.add((Object*)b);
        }
    // if-conversion REMOVES a block, so the list is rewritten wholesale.
    void setBlocks(Array* bs)
        {
        _blocks = bs;
        }
    String* ret(void)
        {
        return _ret;
        }
    void setRet(String* t)
        {
        _ret = t;
        }
    Array* pinned(void)
        {
        return _pinned;
        }
    // Lexicographic, by String.compare — the same shape as Lower.xc's
    // sortedNames, because the reference sorts its header set with `compare:`
    // and the IR text has to match byte for byte.
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

    Array* unrollHeaders(void)
        {
        return _unrollHeaders;
        }
    void addUnrollHeader(String* n)
        {
        _unrollHeaders.add((Object*)String.withString(n));
        }
    void addPinned(IRPinned* p)
        {
        _pinned.add((Object*)p);
        }
    u32 pinnedSize(void)
        {
        return _pinnedSize;
        }
    void setPinnedSize(u32 s)
        {
        _pinnedSize = s;
        }
    Array* byId(void)
        {
        return _byId;
        }
    void noteValue(u32 id, IRValue* v)
        {
        while (_byId.count() <= id)
            _byId.add((Object*)0);
        _byId.set(id, (Object*)v);
        }
    IRValue* valueWithId(u32 id)
        {
        if (id >= _byId.count())
            return (IRValue*)0;
        return (IRValue*)_byId.get(id);
        }

    // Give every value a LOWERING PASS created an id, continuing after the
    // parsed ones, in creation order.
    //
    // The original allocates a value id at construction, so a pass's new values
    // get ids after every parsed one; a back end then keys frame slots AND
    // register homing off those ids. The port stamps print-ids only at print
    // time, which is dense and renumbered — so without this a pass-created
    // value carries id 0, they all collide there, and anything keyed by id
    // silently treats them as one value. (VaArgExpand alone makes over a
    // hundred of them in Stdio.printf.)
    void numberFreshValues(void)
        {
        Array* fresh = new Array();
        for (u32 i = (u32)0; i < _params.count(); i = i + (u32)1)
            noteFresh(fresh, (IRValue*)_params.get(i));
        for (u32 b = (u32)0; b < _blocks.count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)_blocks.get(b);
            freshIn(fresh, bb.phis());
            freshIn(fresh, bb.insns());
            if (bb.term() != 0)
                freshOne(fresh, bb.term());
            }
        sortBySeq(fresh);
        for (u32 i = (u32)0; i < fresh.count(); i = i + (u32)1)
            {
            IRValue* v = (IRValue*)fresh.get(i);
            u32 id = _byId.count();
            v.setPid(id);
            noteValue(id, v);
            }
        }

    void freshIn(Array* fresh, Array* list)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            freshOne(fresh, (IRInsn*)list.get(i));
        }

    void freshOne(Array* fresh, IRInsn* n)
        {
        noteFresh(fresh, n.res());
        noteFresh(fresh, n.memRes());
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() == (u8)OPK_USE)
                noteFresh(fresh, o.val());
            }
        }

    void noteFresh(Array* fresh, IRValue* v)
        {
        if (v == 0)
            return;
        // A value the parser registered already owns its id.
        if (v.pid() < _byId.count() && (IRValue*)_byId.get(v.pid()) == v)
            return;
        for (u32 i = (u32)0; i < fresh.count(); i = i + (u32)1)
            if ((IRValue*)fresh.get(i) == v)
                return;
        fresh.add((Object*)v);
        }

    static void sortBySeq(Array* a)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            {
            Object* cur = a.get(i);
            u32 ck = ((IRValue*)cur).seq();
            u32 j = i;
            while (j > (u32)0 && ((IRValue*)a.get(j - (u32)1)).seq() > ck)
                {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
                }
            a.set(j, cur);
            }
        }

    // The print-ids, in the original's canonical order. Everything the
    // printer emits reads them back off the values themselves.
    void number(void)
        {
        u32 next = (u32)0;
        for (u32 i = (u32)0; i < _params.count(); i = i + (u32)1)
            {
            ((IRValue*)_params.get(i)).setPid(next);
            next = next + (u32)1;
            }
        for (u32 i = (u32)0; i < _pinned.count(); i = i + (u32)1)
            {
            ((IRPinned*)_pinned.get(i)).val().setPid(next);
            next = next + (u32)1;
            }
        for (u32 b = (u32)0; b < _blocks.count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)_blocks.get(b);
            for (u32 i = (u32)0; i < blk.phis().count(); i = i + (u32)1)
                next = numberInsn((IRInsn*)blk.phis().get(i), next);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                next = numberInsn((IRInsn*)blk.insns().get(i), next);
            if (blk.term() != 0)
                next = numberInsn(blk.term(), next);
            }
        }

    u32 numberInsn(IRInsn* i, u32 next)
        {
        if (i.res() != 0)
            {
            i.res().setPid(next);
            next = next + (u32)1;
            }
        if (i.memRes() != 0)
            {
            i.memRes().setPid(next);
            next = next + (u32)1;
            }
        return next;
        }

    // Every value this function defines, in the order `number` walks — the
    // print order. A back end lays out frame slots in THIS order, not by id:
    // an id is creation order (a parsed value's print-id, then whatever
    // `numberFreshValues` appended), and a pass that moves an instruction
    // leaves its value's id where it was. The reference lays out the same
    // way (XTIRFunction.valuesInPrintOrder), which is what makes the two
    // frames identical after -O3 (bug 090).
    Array* valuesInPrintOrder(void)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < _params.count(); i = i + (u32)1)
            out.add(_params.get(i));
        for (u32 i = (u32)0; i < _pinned.count(); i = i + (u32)1)
            out.add((Object*)((IRPinned*)_pinned.get(i)).val());
        for (u32 b = (u32)0; b < _blocks.count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)_blocks.get(b);
            for (u32 i = (u32)0; i < blk.phis().count(); i = i + (u32)1)
                addResults((IRInsn*)blk.phis().get(i), out);
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                addResults((IRInsn*)blk.insns().get(i), out);
            if (blk.term() != 0)
                addResults(blk.term(), out);
            }
        return out;
        }

    void addResults(IRInsn* i, Array* out)
        {
        if (i.res() != 0)
            out.add((Object*)i.res());
        if (i.memRes() != 0)
            out.add((Object*)i.memRes());
        return;
        }

    // Which blocks branch here. Read off the terminators, exactly as the
    // original does — a block is its own predecessor's business, not a
    // fact the block stores.
    String* predsOf(IRBlock* target)
        {
        String* out = String.withCString("");
        u32 n = (u32)0;
        for (u32 b = (u32)0; b < _blocks.count(); b = b + (u32)1)
            {
            IRBlock* src = (IRBlock*)_blocks.get(b);
            if (src == target)
                continue;
            IRInsn* t = src.term();
            if (t == 0)
                continue;
            for (u32 i = (u32)0; i < t.ops().count(); i = i + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(i);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() != target)
                    continue;
                if (n > (u32)0)
                    out.appendCString(", ");
                out.append(src.name());
                n = n + (u32)1;
                break;
                }
            }
        if (n == (u32)0)
            return String.withCString("-");
        return out;
        }

    String* text(void)
        {
        number();
        String* out = String.withCString("  function ");
        out.append(_name);
        out.appendCString("(");
        for (u32 i = (u32)0; i < _params.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                out.appendCString(", ");
            IRValue* v = (IRValue*)_params.get(i);
            out.appendFormat("%%%ld: %s", (i32)v.pid(), v.ty().cString());
            }
        out.appendCString(") -> ");
        if (_ret.equals(String.withCString("Void")))
            out.appendCString("Mem");
        else
            out.appendFormat("(%s, Mem)", _ret.cString());
        out.appendCString(" {\n");

        if (_pinned.count() > (u32)0 || _pinnedSize > (u32)0)
            {
            out.appendCString("    frame: { pinned: [");
            for (u32 i = (u32)0; i < _pinned.count(); i = i + (u32)1)
                {
                if (i > (u32)0)
                    out.appendCString(", ");
                IRPinned* p = (IRPinned*)_pinned.get(i);
                out.appendFormat("(%%%ld:%s @%ld%s)", (i32)p.val().pid(),
                                 p.ty().cString(), (i32)p.off(),
                                 p.esc() ? " esc" : "");
                }
            out.appendFormat("], size: %ld }\n", (i32)_pinnedSize);
            }

        // `unroll: [bb_x, ...]` — the loop headers `: unroll` asked for, AFTER
        // the frame line, which is where the reference prints it. ONLY when
        // non-empty, exactly as `frame:` above is emitted only when there are
        // pinned locals: a line on every function would move the expected IR
        // text of every fixture in the tree, and ir-diff / irwide-diff /
        // opt-diff all compare that text. Sorted, because an array has
        // insertion order and the IR text is a byte-for-byte contract.
        if (_unrollHeaders.count() > (u32)0)
            {
            Array* sorted = sortedNames(_unrollHeaders);
            out.appendCString("    unroll: [");
            for (u32 i = (u32)0; i < sorted.count(); i = i + (u32)1)
                {
                if (i > (u32)0)
                    out.appendCString(", ");
                out.append((String*)sorted.get(i));
                }
            out.appendCString("]\n");
            }

        for (u32 b = (u32)0; b < _blocks.count(); b = b + (u32)1)
            {
            IRBlock* blk = (IRBlock*)_blocks.get(b);
            out.appendFormat("    %s:\n", blk.name().cString());
            out.appendFormat("      preds: %s\n", predsOf(blk).cString());
            for (u32 i = (u32)0; i < blk.phis().count(); i = i + (u32)1)
                out.appendFormat("      %s\n", ((IRInsn*)blk.phis().get(i)).text().cString());
            for (u32 i = (u32)0; i < blk.insns().count(); i = i + (u32)1)
                out.appendFormat("      %s\n", ((IRInsn*)blk.insns().get(i)).text().cString());
            if (blk.term() != 0)
                out.appendFormat("      %s\n", blk.term().text().cString());
            }
        out.appendCString("  }\n");
        return out;
        }
    }

#define SYM_FUNCTION $00
#define SYM_DATAGLOBAL $01
#define SYM_STRINGLIT $02
#define SYM_VTABLE $03
#define SYM_RUNTIME $04

    class IRSymbol
    {
    String* _name;
    u8 _kind;
    String* _sig;  // functions: `(U16) -> U16`
    String* _ty;   // dataglobals: the type spelling
    Array* _bytes; // stringlits / initialised dataglobals: Number@ per byte
    Array* _slots; // vtables: String@ per slot
    bool _banked;
    bool _cabi;
    bool _cloaked;
    bool _variadic;
    bool _throws;
    bool _irq;
    bool _vbi;
    bool _vaforward; // contains `f(a, ...)` — see setAttr/vaforward
    bool _extern;    // defined in ANOTHER module — reached via the GOT
    bool _escapes;
    bool _volatile;
    bool _taskLocal;

    void init(void)
        {
        _kind = (u8)SYM_FUNCTION;
        _banked = false;
        _cabi = false;
        _cloaked = false;
        _variadic = false;
        _vaforward = false;
        _throws = false;
        _irq = false;
        _vbi = false;
        _extern = false;
        _escapes = false;
        _volatile = false;
        _taskLocal = false;
        }

    static IRSymbol* func(String* n, String* sig, bool variadic, bool cabi)
        {
        IRSymbol* s = new IRSymbol();
        s._kind = (u8)SYM_FUNCTION;
        s._name = n;
        s._sig = sig;
        s._variadic = variadic;
        s._cabi = cabi;
        return s;
        }

    static IRSymbol* dataGlobal(String* n, String* ty)
        {
        IRSymbol* s = new IRSymbol();
        s._kind = (u8)SYM_DATAGLOBAL;
        s._name = n;
        s._ty = ty;
        s._escapes = true;
        return s;
        }

    static IRSymbol* stringLit(String* n, Array* bytes)
        {
        IRSymbol* s = new IRSymbol();
        s._kind = (u8)SYM_STRINGLIT;
        s._name = n;
        s._bytes = bytes;
        return s;
        }

    // A METHOD is a function with a different attribute set: it can be
    // `static`, and it is never a C-ABI import, so `cabi` gives way to
    // `static`. The keys print sorted, and the two words sort to the same
    // place, which is why nothing else about the line changes.
    bool _isMethod;
    bool _static;
    static IRSymbol* method(String* n, String* sig, bool variadic, bool isStatic)
        {
        IRSymbol* s = new IRSymbol();
        s._kind = (u8)SYM_FUNCTION;
        s._name = n;
        s._sig = sig;
        s._variadic = variadic;
        s._isMethod = true;
        s._static = isStatic;
        return s;
        }

    void setPlacement(bool banked, bool cloaked)
        {
        _banked = banked;
        _cloaked = cloaked;
        }
    // A dataglobal's declared type spelling — read back so a later access can
    // reuse it rather than rebuilding an identical one.
    String* dataType(void)
        {
        return _ty;
        }
    // A SYNTHESISED function carries neither the method attribute set nor the
    // free-function one — only placement, like a data symbol.
    bool _plain;
    void setThrows(void)
        {
        _throws = true;
        }
    void setIrq(void)
        {
        _irq = true;
        }
    void setVbi(void)
        {
        _vbi = true;
        }
    bool isThrowing(void)
        {
        return _throws;
        }

    void setPlain(void)
        {
        _plain = true;
        }
    bool banked(void)
        {
        return _banked;
        }
    bool cloaked(void)
        {
        return _cloaked;
        }

    // A RUNTIME helper — the allocator and friends. It has no signature the
    // front end can state, so it declares none and the backend knows.
    static IRSymbol* runtime(String* n)
        {
        IRSymbol* s = new IRSymbol();
        s._kind = (u8)SYM_RUNTIME;
        s._name = n;
        return s;
        }

    static IRSymbol* vtable(String* n, Array* slots)
        {
        IRSymbol* s = new IRSymbol();
        s._kind = (u8)SYM_VTABLE;
        s._name = n;
        s._slots = slots;
        return s;
        }

    String* name(void)
        {
        return _name;
        }
    u8 kind(void)
        {
        return _kind;
        }
    bool escapes(void)
        {
        return _escapes;
        }
    // Whether this symbol lives in another module. A back end has to know: its
    // address is not fixed at static-link time, so `&sym` goes through the GOT.
    bool isExtern(void)
        {
        return _extern;
        }
    bool isFunc(void)
        {
        return _kind == (u8)SYM_FUNCTION;
        }
    // A dataglobal's declared type, which is what a back end sizes its
    // reservation from.
    String* globalTy(void)
        {
        return _ty;
        }
    bool variadic(void)
        {
        return _variadic;
        }
    String* signature(void)
        {
        return _sig;
        }
    bool cabi(void)
        {
        return _cabi;
        }
    // Interrupt shapes a BACK END has to know: an `:irq` handler gets a naked
    // prologue and an `:vbi` one saves the registers by hand.
    bool irq(void)
        {
        return _irq;
        }
    bool vbi(void)
        {
        return _vbi;
        }
    void setEscapes(void)
        {
        _escapes = true;
        }

    // Set one attribute by the NAME the text spells it with. The reader has
    // the keys and not the constructor arguments — it is recovering a symbol
    // from what was printed, and what was printed is a key/value list.
    void setAttr(String* key, bool v)
        {
        if (key.equals(String.withCString("banked")))
            {
            _banked = v;
            return;
            }
        if (key.equals(String.withCString("cabi")))
            {
            _cabi = v;
            return;
            }
        if (key.equals(String.withCString("cloaked")))
            {
            _cloaked = v;
            return;
            }
        if (key.equals(String.withCString("extern")))
            {
            _extern = v;
            return;
            }
        if (key.equals(String.withCString("static")))
            {
            _static = v;
            return;
            }
        if (key.equals(String.withCString("variadic")))
            {
            _variadic = v;
            return;
            }
        if (key.equals(String.withCString("throws")))
            {
            _throws = v;
            return;
            }
        if (key.equals(String.withCString("irq")))
            {
            _irq = v;
            return;
            }
        if (key.equals(String.withCString("vbi")))
            {
            _vbi = v;
            return;
            }
        if (key.equals(String.withCString("vaforward")))
            {
            _vaforward = v;
            return;
            }
        // Any OTHER key rides generically — the original keeps every key in an
        // NSDictionary, and a back end reads e.g. `exported` and `pkg_<name>`
        // off it (the wasm32 export/import plumbing). Kept but never printed:
        // the printer's fixed key set is unchanged.
        if (_extraKeys == 0)
            {
            _extraKeys = new Array();
            _extraVals = new Array();
            }
        _extraKeys.add((Object*)key);
        _extraVals.add((Object*)Number.with(v ? (u32)1 : (u32)0));
        }

    // Generic attributes the fixed fields have no slot for.
    Array* _extraKeys; // String@
    Array* _extraVals; // Number@ 0/1

    // The value of a generically-carried attribute, false when absent.
    bool attr(String* key)
        {
        if (_extraKeys == 0)
            return false;
        for (u32 i = (u32)0; i < _extraKeys.count(); i = i + (u32)1)
            if (((String*)_extraKeys.get(i)).equals(key))
                return ((Number*)_extraVals.get(i)).asU32() != (u32)0;
        return false;
        }

    // Every generically-carried key, for a prefix scan (pkg_<name>).
    Array* extraAttrKeys(void)
        {
        return _extraKeys == 0 ? new Array() : _extraKeys;
        }

    bool extraAttrVal(u32 i)
        {
        if (_extraVals == 0 || i >= _extraVals.count())
            return false;
        return ((Number*)_extraVals.get(i)).asU32() != (u32)0;
        }

    // The TRUE generic attribute keys, sorted — the original prints its whole
    // attribute dictionary alphabetically, so generic keys (exported,
    // expname_<n>, pkg_<n>) must land at their sorted positions among the
    // fixed ones (task #33).
    Array* extrasSorted(void)
        {
        Array* out = new Array();
        if (_extraKeys == 0)
            return out;
        for (u32 i = (u32)0; i < _extraKeys.count(); i = i + (u32)1)
            {
            if (!extraAttrVal(i))
                continue;
            out.add(_extraKeys.get(i));
            }
        for (u32 i = (u32)1; i < out.count(); i = i + (u32)1)
            for (u32 j = i; j > (u32)0 && ((String*)out.get(j - (u32)1)).compare((String*)out.get(j)) > (i8)0;
                 j = j - (u32)1)
                out.swapAt(j - (u32)1, j);
        return out;
        }

    // Print (as "key: true, ") every extra from `xi` that sorts before
    // `limit`; returns the new cursor. The trailing-comma style used BEFORE
    // the always-printed `variadic` key.
    u32 extrasBefore(String* out, Array* ex, u32 xi, string limit)
        {
        while (xi < ex.count() && ((String*)ex.get(xi)).compare(String.withCString(limit)) < (i8)0)
            {
            out.appendFormat("%s: true, ", ((String*)ex.get(xi)).cString());
            xi = xi + (u32)1;
            }
        return xi;
        }

    // The leading-comma style used AFTER `variadic`.
    u32 extrasAfterBefore(String* out, Array* ex, u32 xi, string limit)
        {
        while (xi < ex.count() && ((String*)ex.get(xi)).compare(String.withCString(limit)) < (i8)0)
            {
            out.appendFormat(", %s: true", ((String*)ex.get(xi)).cString());
            xi = xi + (u32)1;
            }
        return xi;
        }

    // The function contains `f(a, ...)` — the vararg forwarding form. Only arm9
    // acts on it: its varargs travel in registers, so a forwarder has to relay
    // its own incoming tail into the callee's slots. private:docs/bugs/047.
    bool vaforward(void)
        {
        return _vaforward;
        }

    void setFlag(String* key, bool v)
        {
        if (key.equals(String.withCString("escapes")))
            {
            _escapes = v;
            return;
            }
        if (key.equals(String.withCString("volatile")))
            {
            _volatile = v;
            return;
            }
        if (key.equals(String.withCString("taskLocal")))
            {
            _taskLocal = v;
            return;
            }
        }

    // Which of the three function shapes this is — the attribute KEYS say, and
    // the shape decides which keys print.
    void setMethodShape(void)
        {
        _isMethod = true;
        _plain = false;
        }

    // Two UPPERCASE hex digits. appendFormat's `%x` is lowercase and takes no
    // width, and the IR text wants `#$0A`, so the digits are spelled here.
    static String* hex2(u32 v)
        {
        string digits = "0123456789ABCDEF";
        String* out = String.withCString("");
        out.appendByte(digits[(v >> 4) & (u32)$F]);
        out.appendByte(digits[v & (u32)$F]);
        return out;
        }
    void setBytes(Array* b)
        {
        _bytes = b;
        }
    // What a BACK END reads back off a symbol: the payload bytes and the vtable
    // slots. The printer walks them itself; a code generator needs them too.
    Array* bytes(void)
        {
        return _bytes;
        }
    Array* slots(void)
        {
        return _slots;
        }

    String* byteList(void)
        {
        String* out = String.withCString("");
        if (_bytes == 0 || _bytes.count() == (u32)0)
            return out;
        out.appendCString(" [");
        for (u32 i = (u32)0; i < _bytes.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                out.appendCString(", ");
            out.appendCString("#$");
            out.append(IRSymbol.hex2(((Number*)_bytes.get(i)).asU32()));
            }
        out.appendCString("]");
        return out;
        }

    String* flagsLine(void)
        {
        String* out = String.withCString("");
        u32 n = (u32)0;
        if (_escapes)
            {
            out.appendCString("escapes: true");
            n = n + (u32)1;
            }
        if (_volatile)
            {
            if (n > (u32)0)
                out.appendCString(", ");
            out.appendCString("volatile: true");
            n = n + (u32)1;
            }
        if (_taskLocal)
            {
            if (n > (u32)0)
                out.appendCString(", ");
            out.appendCString("taskLocal: true");
            n = n + (u32)1;
            }
        if (n == (u32)0)
            return String.withCString("");
        String* line = String.withCString("\n    flags: { ");
        line.append(out);
        line.appendCString(" }");
        return line;
        }

    String* text(void)
        {
        String* out = String.withCString("  symbol ");
        out.append(_name);
        if (_kind == (u8)SYM_RUNTIME)
            {
            out.appendCString(": runtime () -> Void");
            out.appendFormat("\n    attributes: { banked: %s, cloaked: %s, variadic: %s }\n",
                             _banked ? "true" : "false", _cloaked ? "true" : "false",
                             _variadic ? "true" : "false");
            return out;
            }
        if (_kind == (u8)SYM_FUNCTION)
            {
            out.appendFormat(": function %s", _sig.cString());
            // The attribute keys print in SORTED order, which for these four
            // is the order they are written here.
            // Every branch merges the GENERIC keys at their sorted positions.
            // Two of them used to print a fixed set instead, so an imported
            // class's methods lost their `pkg_<Lib>` crossing the IR text and
            // the app imported `env.<Class>$init` — a symbol no host supplies,
            // failing at instantiation rather than at the compiler.
            if (_plain)
                {
                Array* ex = extrasSorted();
                u32 xi = (u32)0;
                out.appendCString("\n    attributes: { ");
                xi = extrasBefore(out, ex, xi, "banked");
                out.appendFormat("banked: %s", _banked ? "true" : "false");
                xi = extrasAfterBefore(out, ex, xi, "cloaked");
                out.appendFormat(", cloaked: %s", _cloaked ? "true" : "false");
                while (xi < ex.count())
                    {
                    out.appendFormat(", %s: true", ((String*)ex.get(xi)).cString());
                    xi = xi + (u32)1;
                    }
                out.appendCString(" }");
                }
            else if (_isMethod)
                {
                Array* ex = extrasSorted();
                u32 xi = (u32)0;
                out.appendCString("\n    attributes: { ");
                xi = extrasBefore(out, ex, xi, "banked");
                out.appendFormat("banked: %s, ", _banked ? "true" : "false");
                xi = extrasBefore(out, ex, xi, "cloaked");
                out.appendFormat("cloaked: %s, ", _cloaked ? "true" : "false");
                xi = extrasBefore(out, ex, xi, "static");
                out.appendFormat("static: %s, ", _static ? "true" : "false");
                xi = extrasBefore(out, ex, xi, "throws");
                if (_throws)
                    out.appendCString("throws: true, ");
                xi = extrasBefore(out, ex, xi, "vaforward");
                if (_vaforward)
                    out.appendCString("vaforward: true, ");
                xi = extrasBefore(out, ex, xi, "variadic");
                out.appendFormat("variadic: %s", _variadic ? "true" : "false");
                while (xi < ex.count())
                    {
                    out.appendFormat(", %s: true", ((String*)ex.get(xi)).cString());
                    xi = xi + (u32)1;
                    }
                out.appendCString(" }");
                }
            else
                {
                out.appendFormat("\n    attributes: { banked: %s, cabi: %s, cloaked: %s, ",
                                 _banked ? "true" : "false", _cabi ? "true" : "false",
                                 _cloaked ? "true" : "false");
                // The keys print in SORTED order, which is where irq and vbi
                // land relative to throws and variadic — and where the
                // generic keys (expname_<n> then exported, both < "irq")
                // merge in (task #33).
                Array* ex = extrasSorted();
                u32 xi = (u32)0;
                xi = extrasBefore(out, ex, xi, "irq");
                if (_irq)
                    out.appendCString("irq: true, ");
                xi = extrasBefore(out, ex, xi, "throws");
                if (_throws)
                    out.appendCString("throws: true, ");
                // Sorted: vaforward falls between throws and variadic ('f' < 'r').
                xi = extrasBefore(out, ex, xi, "vaforward");
                if (_vaforward)
                    out.appendCString("vaforward: true, ");
                xi = extrasBefore(out, ex, xi, "variadic");
                out.appendFormat("variadic: %s", _variadic ? "true" : "false");
                xi = extrasAfterBefore(out, ex, xi, "vbi");
                if (_vbi)
                    out.appendCString(", vbi: true");
                while (xi < ex.count())
                    {
                    out.appendFormat(", %s: true", ((String*)ex.get(xi)).cString());
                    xi = xi + (u32)1;
                    }
                out.appendCString(" }");
                }
            out.append(flagsLine());
            out.appendCString("\n");
            return out;
            }
        if (_kind == (u8)SYM_DATAGLOBAL)
            {
            out.appendFormat(": dataglobal %s", _ty.cString());
            if (_bytes != 0 && _bytes.count() > (u32)0)
                {
                out.appendCString(" init");
                out.append(byteList());
                }
            out.appendFormat("\n    attributes: { banked: %s, cloaked: %s",
                             _banked ? "true" : "false", _cloaked ? "true" : "false");
            // Sorted merge: any generic key < "extern" first (none today),
            // then extern, then the rest — an extern-DEF global carries
            // `exported`, which sorts after `extern` (task #33).
            Array* gex = extrasSorted();
            u32 gxi = extrasAfterBefore(out, gex, (u32)0, "extern");
            if (_extern)
                out.appendCString(", extern: true");
            while (gxi < gex.count())
                {
                out.appendFormat(", %s: true", ((String*)gex.get(gxi)).cString());
                gxi = gxi + (u32)1;
                }
            out.appendCString(" }");
            out.append(flagsLine());
            out.appendCString("\n");
            return out;
            }
        if (_kind == (u8)SYM_STRINGLIT)
            {
            out.appendCString(": stringlit");
            out.append(byteList());
            out.appendFormat("\n    attributes: { banked: %s, cloaked: %s }\n",
                             _banked ? "true" : "false", _cloaked ? "true" : "false");
            return out;
            }
        out.appendCString(": vtable");
        if (_slots != 0 && _slots.count() > (u32)0)
            {
            out.appendCString(" [");
            for (u32 i = (u32)0; i < _slots.count(); i = i + (u32)1)
                {
                if (i > (u32)0)
                    out.appendCString(", ");
                String* e = (String*)_slots.get(i);
                out.append(e.byteLength() == (u32)0 ? String.withCString("_") : e);
                }
            out.appendCString("]");
            }
        // Alphabetical, generic keys included. They used to be DROPPED here —
        // this branch printed a fixed set — so an imported class's vtable lost
        // its `pkg_<Lib>` on the way through the IR text, and the app that
        // referenced it imported `env.__addr_<C>$vtbl`, which no host supplies.
        // The failure was at instantiation, on a symbol nothing named wrongly.
        Array* ex = extrasSorted();
        u32 xi = (u32)0;
        out.appendCString("\n    attributes: { ");
        xi = extrasBefore(out, ex, xi, "banked");
        out.appendFormat("banked: %s", _banked ? "true" : "false");
        xi = extrasAfterBefore(out, ex, xi, "cloaked");
        out.appendFormat(", cloaked: %s", _cloaked ? "true" : "false");
        xi = extrasAfterBefore(out, ex, xi, "extern");
        // An EXTERNAL class's vtable (§4.2's iface import): emitted where the
        // class was compiled; this module only references it.
        if (_extern)
            out.appendCString(", extern: true");
        while (xi < ex.count())
            {
            out.appendFormat(", %s: true", ((String*)ex.get(xi)).cString());
            xi = xi + (u32)1;
            }
        out.appendCString(" }\n");
        return out;
        }
    }

    // An aggregate's layout, referred to from a type as `Agg(N)`.
    class IRLayout
    {
    u32 _size;
    u32 _align;
    Array* _offs;  // Number@ byte offsets
    Array* _types; // String@ field type spellings

    void init(void)
        {
        _size = (u32)0;
        _align = (u32)1;
        _offs = new Array();
        _types = new Array();
        }

    static IRLayout* with(u32 size, u32 align)
        {
        IRLayout* l = new IRLayout();
        l._size = size;
        l._align = align;
        return l;
        }

    void addField(u32 off, String* ty)
        {
        _offs.add((Object*)Number.with(off));
        _types.add((Object*)ty);
        }

    u32 size(void)
        {
        return _size;
        }
    u32 fieldCount(void)
        {
        return _offs.count();
        }
    String* typeAt(u32 i)
        {
        return i < _types.count() ? (String*)_types.get(i) : (String*)0;
        }
    u32 offsetAt(u32 i)
        {
        return i < _offs.count() ? ((Number*)_offs.get(i)).asU32() : (u32)0;
        }
    void setSize(u32 v)
        {
        _size = v;
        }
    // A layout laid down while a CYCLE was open holds a placeholder in place of
    // the index the enclosing layout has not been given yet; the lowering
    // patches it once that index exists.
    void setTypeAt(u32 i, String* ty)
        {
        if (i < _types.count())
            _types.set(i, (Object*)ty);
        }

    String* text(u32 index)
        {
        String* out = String.withCString("  layout ");
        out.appendFormat("%ld: size=%ld align=%ld", (i32)index, (i32)_size, (i32)_align);
        if (_offs.count() > (u32)0)
            {
            out.appendCString(" fields=[");
            for (u32 i = (u32)0; i < _offs.count(); i = i + (u32)1)
                {
                if (i > (u32)0)
                    out.appendCString(", ");
                out.appendFormat("(%ld:%s)", (i32)((Number*)_offs.get(i)).asU32(),
                                 ((String*)_types.get(i)).cString());
                }
            out.appendCString("]");
            }
        out.appendCString("\n");
        return out;
        }
    }

    class IRModule
    {
    String* _name;
    Array* _layouts;
    Array* _syms;
    Array* _funcs;
    Array* _modinits;
    Array* _consts; // each an Array@ of Number@ bytes

    void init(void)
        {
        _layouts = new Array();
        _syms = new Array();
        _funcs = new Array();
        _modinits = new Array();
        _consts = new Array();
        }

    void setName(String* n)
        {
        _name = n;
        }
    Array* syms(void)
        {
        return _syms;
        }
    Array* funcs(void)
        {
        return _funcs;
        }
    Array* layouts(void)
        {
        return _layouts;
        }
    Array* modinits(void)
        {
        return _modinits;
        }
    Array* consts(void)
        {
        return _consts;
        }
    String* name(void)
        {
        return _name;
        }
    void addSym(IRSymbol* s)
        {
        _syms.add((Object*)s);
        }
    void addFunc(IRFunc* f)
        {
        _funcs.add((Object*)f);
        }
    // An OPT pass rewrites the function list wholesale — dead-function
    // elimination keeps the survivors and drops the rest.
    void setFuncs(Array* fs)
        {
        _funcs = fs;
        }
    u32 addLayout(IRLayout* l)
        {
        _layouts.add((Object*)l);
        return _layouts.count() - (u32)1;
        }
    u32 addConst(Array* bytes)
        {
        _consts.add((Object*)bytes);
        return _consts.count() - (u32)1;
        }
    void addModInit(String* n)
        {
        _modinits.add((Object*)n);
        }

    String* text(void)
        {
        String* out = String.withCString("module \"");
        out.append(_name);
        out.appendCString("\" {\n");
        for (u32 i = (u32)0; i < _layouts.count(); i = i + (u32)1)
            out.append(((IRLayout*)_layouts.get(i)).text(i));
        for (u32 i = (u32)0; i < _consts.count(); i = i + (u32)1)
            {
            out.appendFormat("  constant %ld: string bytes=[", (i32)i);
            Array* b = (Array*)_consts.get(i);
            for (u32 j = (u32)0; j < b.count(); j = j + (u32)1)
                {
                if (j > (u32)0)
                    out.appendCString(", ");
                out.appendCString("#$");
                out.append(IRSymbol.hex2(((Number*)b.get(j)).asU32()));
                }
            out.appendCString("]\n");
            }
        for (u32 i = (u32)0; i < _modinits.count(); i = i + (u32)1)
            out.appendFormat("  modinit \"%s\"\n", ((String*)_modinits.get(i)).cString());
        for (u32 i = (u32)0; i < _syms.count(); i = i + (u32)1)
            out.append(((IRSymbol*)_syms.get(i)).text());
        for (u32 i = (u32)0; i < _funcs.count(); i = i + (u32)1)
            out.append(((IRFunc*)_funcs.get(i)).text());
        out.appendCString("}\n");
        return out;
        }
    }
