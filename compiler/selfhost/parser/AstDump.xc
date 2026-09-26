// AstDump.xc — the AST dump both self-hosting oracles compare against.
// =================================================================
//
// self-hosting M5/M6. The format is XTASTDumper's, exactly: one node per line,
// two spaces of indent per level, `Kind field=value …` fields in a fixed order.
//
// It lives here rather than in a tool because TWO tools need it. `xtast` prints
// the parser's tree (M5, compared against `xtc-fe --dump-ast`); `xtsema` prints
// the same tree WITH what the analyser stamped on it (M6, compared against
// `xtc-fe --dump-sema`). The original made the same call for the same reason —
// one walk, a mode flag — because two walks drift the moment either format
// changes.
//
// In sema mode each node's first line gains a suffix built from the fields the
// analyser filled in (Node.setTy / setSym / …). The splice is done by index
// rather than by every case knowing about it, so the ~40 emit branches below
// are byte-for-byte the parser dump they always were.

#import "Foundation.xc"
#import "Node.xc"
// Uses FloatEncoding directly. It compiled only because every CONSUMER happened
// to import the lexer first — so this file could not be built on its own, and a
// file that cannot be built is one the self-hosting differential silently skips
// rather than compares (see all-diff.sh).
#import "FloatEncoding.xc"

// The dump, as a class: `emit` and `emitKids` call each other, and a free
// function in xtc must be defined before it is used — methods have no such
// ordering rule.
class AstDump
    {
    u8 _unused;
    void init(void)
        {
        _unused = (u8)0;
        }

    // Sema mode: `emit` splices an annotation onto the end of each node's own
    // first line. Off, this is the M5 parser dump, unchanged.
    static bool _sema;
    // bare name: a static
    static void setSemaMode(bool on)
        {
        _sema = on;
        }
          // ivar is reachable by name
          // inside its own class

    // The suffix for one node — the mirror of semaAnnotation() in
    // src/xtc/ast/XTASTDumper.m, field for field and in the same order.
    static String* annotation(Node* n)
        {
        String* a = String.withCString("");
        if (n.ty() != 0)
            {
            a.appendCString(" ty=");
            a.append(Node.stripElem(n.ty()));
            }
        if (n.sym() != 0)
            {
            // The key depends on the node: a `new` prints the INIT it resolved,
            // everything else prints the symbol it resolved to. Same field
            // underneath, different word — as in the original.
            if (n.kind() == (u16)nkNew)
                a.appendCString(" init=");
            else
                a.appendCString(" sym=");
            a.append(n.sym());
            }
        if (n.cls() != 0)
            {
            a.appendCString(" cls=");
            a.append(n.cls());
            }
        if (n.vslot() >= (i32)0)
            a.appendFormat(" vslot=%ld", (u32)n.vslot());
        if (n.indirect())
            a.appendCString(" indirect=1");
        if (n.boundCall())
            a.appendCString(" bound=1");
        if (n.setter() != 0)
            {
            a.appendCString(" set=");
            a.append(n.setter());
            }
        if (n.setterCls() != 0)
            {
            a.appendCString(" setcls=");
            a.append(n.setterCls());
            }
        if (n.getter() != 0)
            {
            a.appendCString(" get=");
            a.append(n.getter());
            }
        if (n.getterCls() != 0)
            {
            a.appendCString(" getcls=");
            a.append(n.getterCls());
            }
        if (n.bound() != 0)
            {
            a.appendCString(" bound=");
            a.append(n.bound());
            }
        if (n.boundCls() != 0)
            {
            a.appendCString(" boundcls=");
            a.append(n.boundCls());
            }
        if (n.boundSlot() >= (i32)0)
            a.appendFormat(" boundslot=%ld", (u32)n.boundSlot());
        if (n.boundProto() != 0)
            {
            a.appendCString(" boundproto=");
            a.append(n.boundProto());
            }
        if (n.boundPIdx() >= (i32)0)
            a.appendFormat(" boundprotoidx=%ld", (u32)n.boundPIdx());
        if (n.proto() != 0)
            {
            a.appendCString(" proto=");
            a.append(n.proto());
            }
        if (n.protoIdx() >= (i32)0)
            a.appendFormat(" protoidx=%ld", (u32)n.protoIdx());
        // Order matters as much as content: these follow sym= on their node in
        // the original's switch, and a differential dump compares lines.
        if (n.heapRecv())
            a.appendCString(" heaprecv=1");
        if (n.stackRecv())
            a.appendCString(" stackrecv=1");
        if (n.autoSuperInit())
            a.appendCString(" autosuperinit=1");
        if (n.usedByNew())
            a.appendCString(" usedbynew=1");
        // Sorted by SLOT, then name — a map's own order is not a fact about the
        // program, and the original sorts for exactly that reason.
        if (n.slots() != 0 && n.vslots() > (u32)0)
            {
            a.appendFormat(" vslots=%lu", n.vslots());
            Array* keys = n.slots().allKeys();
            if (keys.count() == (u32)0)
                return a; // a table with no entries
            AstDump.sortBySlot(keys, n.slots());
            a.appendCString(" slots=[");
            for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
                {
                if (i > (u32)0)
                    a.appendByte((u8)',');
                String* k = (String*)keys.get(i);
                a.append(k);
                a.appendByte((u8)':');
                a.appendFormat("%lu", ((Number*)n.slots().get((Hashable*)k)).asU32());
                }
            a.appendByte((u8)']');
            if (n.symSlots() != 0 && n.symSlots().count() > (u32)0)
                {
                Array* sk = n.symSlots().allKeys();
                AstDump.sortBySlot(sk, n.symSlots());
                a.appendCString(" syms=[");
                for (u32 i = (u32)0; i < sk.count(); i = i + (u32)1)
                    {
                    if (i > (u32)0)
                        a.appendByte((u8)',');
                    String* k = (String*)sk.get(i);
                    a.append(k);
                    a.appendByte((u8)':');
                    a.appendFormat("%lu", ((Number*)n.symSlots().get((Hashable*)k)).asU32());
                    }
                a.appendByte((u8)']');
                }
            }
        return a;
        }

    // Escape a field value: one node is one line, and a string literal may hold
    // anything. Matches `esc()` in src/xtc/ast/XTASTDumper.m — including the space,
    // which would otherwise split a field.
    static String* escField(String* s)
        {
        if (s == 0)
            return String.withCString("-");
        String* out = String.withCString("");
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)92)
                out.appendCString("\\\\");
            else if (c == (u8)10)
                out.appendCString("\\n");
            else if (c == (u8)9)
                out.appendCString("\\t");
            else if (c == (u8)13)
                out.appendCString("\\r");
            else if (c == (u8)32)
                out.appendCString("\\s");
            else if (c < (u8)32 || c > (u8)126)
                {
                out.appendCString("\\x");
                out.appendByte(AstDump.hexDigit(c >> (u8)4));
                out.appendByte(AstDump.hexDigit(c & (u8)$0F));
                }
            else
                {
                out.appendByte(c);
                }
            }
        return out;
        }

    static u8 hexDigit(u8 nibble)
        {
        if (nibble < (u8)10)
            return (u8)((u8)'0' + nibble);
        return (u8)((u8)'A' + (nibble - (u8)10));
        }

    static void indent(String* out, u32 depth)
        {
        for (u32 i = (u32)0; i < depth; i = i + (u32)1)
            out.appendCString("  ");
        }

    static u32 flag(Node* n, u32 bit)
        {
        return n.hasFlag(bit) ? (u32)1 : (u32)0;
        }

    static String* orDash(String* s)
        {
        return (s == 0) ? String.withCString("-") : s;
        }

    // A TYPE field, printed the way the ObjC dumper prints one. That compiler
    // keeps a collection's element type on the type object and leaves the
    // display name bare, so it writes `Array*`; here the element rides in the
    // spelling, so it has to come off before printing or the two dumps differ
    // on every line that mentions the type.
    static String* tyField(String* s)
        {
        return AstDump.escField(AstDump.orDash(Node.stripElem(s)));
        }

    static void sortBySlot(Array* keys, Map* slots)
        {
        for (u32 i = (u32)1; i < keys.count(); i = i + (u32)1)
            {
            String* key = (String*)keys.get(i);
            u32 kv = ((Number*)slots.get((Hashable*)key)).asU32();
            u32 j = i;
            while (j > (u32)0)
                {
                String* prev = (String*)keys.get(j - (u32)1);
                u32 pv = ((Number*)slots.get((Hashable*)prev)).asU32();
                if (pv < kv)
                    break;
                if (pv == kv && prev.compare(key) <= (i8)0)
                    break;
                keys.set(j, (Object*)prev);
                j = j - (u32)1;
                }
            keys.set(j, (Object*)key);
            }
        }

    static void emit(Node* n, String* out, u32 depth)
        {
        if (n == 0)
            return;
        // Where this node's own first line starts, so the annotation can be
        // spliced onto the end of it once the node (and its children) are out.
        u32 lineStart = out.byteLength();
        u16 k = n.kind();
        if (k <= (u16)nkParam)
            AstDump.emitDecl(n, out, depth);
        else if (k <= (u16)nkCatch)
            AstDump.emitStmt(n, out, depth);
        else
            AstDump.emitExpr(n, out, depth);
        if (!_sema)
            return;
        String* a = AstDump.annotation(n);
        if (a.byteLength() == (u32)0)
            return;
        for (u32 i = lineStart; i < out.byteLength(); i = i + (u32)1)
            {
            if (out.byteAt(i) == (u8)10)
                {
                out.insertAtByte(i, a);
                return;
                }
            }
        }

    static void emitDecl(Node* n, String* out, u32 depth)
        {
        u16 k = n.kind();

        if (k == (u16)nkProgram)
            {
            AstDump.indent(out, depth);
            out.appendCString("Program\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkFunctionDecl)
            {
            AstDump.indent(out, depth);
            out.appendFormat("FunctionDecl name=%s ret=%s varargs=%lu throws=%lu\n",
                             AstDump.escField(n.name()).cString(), AstDump.tyField(n.op()).cString(),
                             AstDump.flag(n, (u32)NF_VARARGS), AstDump.flag(n, (u32)NF_THROWS));
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkMethodDecl)
            {
            AstDump.indent(out, depth);
            out.appendFormat("MethodDecl name=%s ret=%s static=%lu varargs=%lu throws=%lu optional=%lu final=%lu",
                             AstDump.escField(n.name()).cString(), AstDump.tyField(n.op()).cString(),
                             AstDump.flag(n, (u32)NF_STATIC), AstDump.flag(n, (u32)NF_VARARGS),
                             AstDump.flag(n, (u32)NF_THROWS), AstDump.flag(n, (u32)NF_OPTIONAL),
                             AstDump.flag(n, (u32)NF_FINAL));
            // `since` prints only when set, so pre-0.4 dumps byte-match.
            if (n.since() != (String*)0 && n.since().byteLength() > (u32)0)
                out.appendFormat(" since=%s", n.since().cString());
            out.appendCString("\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkParam)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Param name=%s type=%s\n",
                             AstDump.escField(n.name()).cString(), AstDump.tyField(n.op()).cString());
            return;
            }
        if (k == (u16)nkVariableDecl)
            {
            AstDump.indent(out, depth);
            out.appendFormat("VariableDecl name=%s type=%s static=%lu global=%lu extern=%lu volatile=%lu register=%lu\n",
                             AstDump.escField(n.name()).cString(), AstDump.tyField(n.op()).cString(),
                             AstDump.flag(n, (u32)NF_STATIC), AstDump.flag(n, (u32)NF_GLOBAL),
                             AstDump.flag(n, (u32)NF_EXTERN), AstDump.flag(n, (u32)NF_VOLATILE),
                             AstDump.flag(n, (u32)NF_REGISTER));
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkStructDecl)
            {
            AstDump.indent(out, depth);
            // packed only when SET — golden dumps of unpacked structs unchanged.
            if (n.hasFlag((u32)NF_PACKED))
                out.appendFormat("StructDecl name=%s packed=1\n", AstDump.escField(n.name()).cString());
            else
                out.appendFormat("StructDecl name=%s\n", AstDump.escField(n.name()).cString());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkTypedefDecl)
            {
            AstDump.indent(out, depth);
            out.appendFormat("TypedefDecl name=%s type=%s\n",
                             AstDump.escField(n.name()).cString(), AstDump.tyField(n.op()).cString());
            return;
            }
        if (k == (u16)nkEnumDecl)
            {
            AstDump.indent(out, depth);
            out.appendFormat("EnumDecl name=%s\n", AstDump.escField(n.name()).cString());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkEnumMember)
            {
            AstDump.indent(out, depth);
            if (n.op() == 0)
                {
                out.appendFormat("EnumMember name=%s value=-\n", AstDump.escField(n.name()).cString());
                }
            else
                {
                out.appendFormat("EnumMember name=%s value=%s\n",
                                 AstDump.escField(n.name()).cString(),
                                 String.withI64(n.num()).cString());
                }
            return;
            }
        if (k == (u16)nkUseDecl)
            {
            AstDump.indent(out, depth);
            out.appendFormat("UseDecl name=%s\n", AstDump.escField(n.name()).cString());
            return;
            }
        if (k == (u16)nkClassDecl)
            {
            AstDump.indent(out, depth);
            out.appendFormat("ClassDecl name=%s super=%s protocols=%s\n",
                             AstDump.escField(n.name()).cString(), AstDump.tyField(n.op()).cString(),
                             AstDump.escField(AstDump.orDash(n.extra())).cString());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkProtocolDecl)
            {
            AstDump.indent(out, depth);
            out.appendFormat("ProtocolDecl name=%s\n", AstDump.escField(n.name()).cString());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }

        AstDump.indent(out, depth);
        out.appendFormat("Unknown kind=%lu\n", (u32)k);
        }

    static void emitStmt(Node* n, String* out, u32 depth)
        {
        u16 k = n.kind();
        if (k == (u16)nkBlock)
            {
            AstDump.indent(out, depth);
            out.appendCString("Block\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkIf)
            {
            AstDump.indent(out, depth);
            out.appendCString("If\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkWhile)
            {
            AstDump.indent(out, depth);
            out.appendCString("While\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkForIn)
            {
            AstDump.indent(out, depth);
            out.appendCString("ForIn\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkReturn)
            {
            AstDump.indent(out, depth);
            out.appendCString("Return\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkBreak)
            {
            AstDump.indent(out, depth);
            out.appendCString("Break\n");
            return;
            }
        if (k == (u16)nkContinue)
            {
            AstDump.indent(out, depth);
            out.appendCString("Continue\n");
            return;
            }
        if (k == (u16)nkExprStatement)
            {
            AstDump.indent(out, depth);
            out.appendCString("ExprStatement\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkTupleAssign)
            {
            AstDump.indent(out, depth);
            out.appendCString("TupleAssign\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkDefer)
            {
            AstDump.indent(out, depth);
            out.appendCString("Defer\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkThrow)
            {
            AstDump.indent(out, depth);
            out.appendCString("Throw\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }

        if (k == (u16)nkForCStyle)
            {
            // The three clauses are printed under their markers so an omitted one
            // is visibly omitted rather than shifting the others up.
            AstDump.indent(out, depth);
            out.appendCString("ForCStyle\n");
            for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
                {
                Node* kid = n.kid(i);
                u16 kk = kid.kind();
                if (kk == (u16)nkMarkerInit)
                    {
                    AstDump.indent(out, depth + (u32)1);
                    out.appendCString("init\n");
                    AstDump.emitKids(kid, out, depth + (u32)2, (u32)0);
                    }
                else if (kk == (u16)nkMarkerCond)
                    {
                    AstDump.indent(out, depth + (u32)1);
                    out.appendCString("cond\n");
                    AstDump.emitKids(kid, out, depth + (u32)2, (u32)0);
                    }
                else if (kk == (u16)nkMarkerStep)
                    {
                    AstDump.indent(out, depth + (u32)1);
                    out.appendCString("step\n");
                    AstDump.emitKids(kid, out, depth + (u32)2, (u32)0);
                    }
                else
                    {
                    AstDump.emit(kid, out, depth + (u32)1);
                    }
                }
            return;
            }
        if (k == (u16)nkSwitch)
            {
            AstDump.indent(out, depth);
            out.appendCString("Switch\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkCase)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Case default=%lu\n", AstDump.flag(n, (u32)NF_DEFAULT));
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkLabel)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Label range=%lu\n", AstDump.flag(n, (u32)NF_RANGE));
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkAsmBlock)
            {
            AstDump.indent(out, depth);
            out.appendFormat("AsmBlock lines=%lu\n", n.kidCount());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkAsmLine)
            {
            AstDump.indent(out, depth);
            out.appendFormat("AsmLine %s\n", AstDump.escField(n.name()).cString());
            return;
            }
        if (k == (u16)nkDelete)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Delete op=%ld\n", (i32)n.num());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkTry)
            {
            AstDump.indent(out, depth);
            out.appendCString("Try\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkCatch)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Catch type=%s var=%s\n",
                             AstDump.tyField(n.op()).cString(), AstDump.escField(n.name()).cString());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }

        AstDump.indent(out, depth);
        out.appendFormat("Unknown kind=%lu\n", (u32)k);
        }

    static void emitExpr(Node* n, String* out, u32 depth)
        {
        u16 k = n.kind();
        if (k == (u16)nkTernary)
            {
            AstDump.indent(out, depth);
            out.appendCString("Ternary\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkSubscript)
            {
            AstDump.indent(out, depth);
            out.appendCString("Subscript\n");
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }

        if (k == (u16)nkBinary)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Binary op=%s\n", n.op().cString());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkUnary)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Unary op=%s\n", n.op().cString());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkPostfix)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Postfix op=%s\n", n.op().cString());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkAssign)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Assign op=%s\n", n.op().cString());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkCall)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Call name=%s args=%ld\n", AstDump.escField(n.name()).cString(), (i32)n.num());
            // Arguments, then the callee EXPRESSION when there is one. Anything
            // past that is a rewrite sema hung on the node (private:docs/bugs/074), which
            // the original does not print either.
            u32 shownC = (u32)n.num() + (u32)1;
            for (u32 i = (u32)0; i < n.kidCount() && i < shownC; i = i + (u32)1)
                AstDump.emit(n.kid(i), out, depth + (u32)1);
            return;
            }
        if (k == (u16)nkMethodCall)
            {
            AstDump.indent(out, depth);
            out.appendFormat("MethodCall name=%s args=%ld\n", AstDump.escField(n.name()).cString(), (i32)n.num());
            // Receiver + args only. Sema may hang a rewritten call on the node as
            // one extra kid (private:docs/bugs/074); the original keeps the node exactly
            // as written and prints no such thing, so neither does this.
            u32 shown = (u32)n.num() + (u32)1;
            for (u32 i = (u32)0; i < n.kidCount() && i < shown; i = i + (u32)1)
                AstDump.emit(n.kid(i), out, depth + (u32)1);
            return;
            }
        if (k == (u16)nkSlice)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Slice inclusive=%lu\n", AstDump.flag(n, (u32)NF_INCLUSIVE));
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkRange)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Range inclusive=%lu\n", AstDump.flag(n, (u32)NF_INCLUSIVE));
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkMember)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Member name=%s arrow=%lu\n",
                             AstDump.escField(n.name()).cString(), AstDump.flag(n, (u32)NF_ARROW));
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkCast)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Cast type=%s failable=%lu\n",
                             AstDump.tyField(n.name()).cString(), AstDump.flag(n, (u32)NF_FAILABLE));
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkIdent)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Ident %s\n", AstDump.escField(n.name()).cString());
            return;
            }
        if (k == (u16)nkInt)
            {
            // UNSIGNED: an integer literal is never negative here (unary minus is
            // its own node), so a value above 2^31 must print as itself rather
            // than as the i32 it wraps to — `$DEADBEEF` is 3735928559.
            AstDump.indent(out, depth);
            // Printed via String.withI64, not "%ld": appendFormat understands one
            // `l`, so its widest integer is 32 bits, while the oracle prints %lld.
            // A 64-bit literal would have truncated HERE even with a 64-bit token.
            out.appendFormat("Int %s\n", String.withI64(n.num()).cString());
            return;
            }
        if (k == (u16)nkFloat)
            {
            // The encoded bytes, as the original dumps them: the lexer encodes at
            // lex time, so the bytes ARE the literal. `num` carries the `d` suffix.
            AstDump.indent(out, depth);
            String* hex = FloatEncoding.hexForLiteral(n.name(), n.num() != (i64)0);
            out.appendFormat("Float %s\n", hex.cString());
            return;
            }
        if (k == (u16)nkStr)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Str %s\n", AstDump.escField(n.name()).cString());
            return;
            }
        if (k == (u16)nkChar)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Char %ld\n", (i32)n.num());
            return;
            }
        if (k == (u16)nkBool)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Bool %ld\n", (i32)n.num());
            return;
            }
        if (k == (u16)nkNew)
            {
            AstDump.indent(out, depth);
            out.appendFormat("New type=%s args=%ld\n", AstDump.tyField(n.name()).cString(), (i32)n.num());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }
        if (k == (u16)nkSizeof)
            {
            AstDump.indent(out, depth);
            out.appendFormat("Sizeof type=%s\n", AstDump.tyField(n.name()).cString());
            AstDump.emitKids(n, out, depth + (u32)1, (u32)0);
            return;
            }

        AstDump.indent(out, depth);
        out.appendFormat("Unknown kind=%lu\n", (u32)k);
        }

    static void emitKids(Node* n, String* out, u32 depth, u32 unused)
        {
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            AstDump.emit(n.kid(i), out, depth);
        }
    }
