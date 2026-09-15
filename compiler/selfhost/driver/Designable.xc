// Designable.xc — uxkit/026, XG-NIB §4: the designable surface.
//
// Split out of Frontend.xc because TWO tools need it: the ported front end
// (xtfe / xcc) and the IR-lowering harness (xtir), whose oracle is `xcc-fe` —
// and xcc-fe synthesises. A copy in only one of them makes the differential
// compare a program the oracle built against a different program.
//
// Mirrored from the reference driver's `synthesizeDesignable:`.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Process.xc"
#import "Node.xc"
#import "Lexer.xc"
#import "Parser.xc"

// uxkit/026, XG-NIB §4 — the designable surface, mirrored from the reference
// driver's `synthesizeDesignable:`.
//
// A class with an `outlet` field or an `:action` method auto-conforms to the
// binding protocol, and its setOutlet / wireAction bodies are written HERE
// rather than by hand: a nib holds a member NAME, the language has no
// selectors, so the only way a name becomes a member access is a switch the
// compiler generates over the annotated members.
//
// Generated as SOURCE and parsed, exactly as the conformance helper above is —
// which is what keeps the pointer widths, the ARC and the vtable numbering the
// same as for anything the user wrote.

// The type spelling a cast target needs: the placement qualifiers ride as a
// prefix on the spelling (`weak:Label@`) and a cast may not carry them.
String* stripTypeQualifiers(String* disp)
    {
    String* out = String.withString(disp);
    bool changed = true;
    while (changed)
        {
        changed = false;
        u32 c = out.byteIndexOf(String.withCString(":"));
        if (c != String.notFound())
            {
            out = out.substringFromByte(c + (u32)1);
            changed = true;
            }
        }
    return out;
    }

// Does this class declare any designable member?
bool classIsDesignable(Node* c)
    {
    for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1)
        {
        Node* m = c.kid(i);
        if (m.kind() == (u16)nkVariableDecl && m.hasFlag((u32)NF_OUTLET))
            return true;
        if (m.kind() == (u16)nkMethodDecl && m.hasFlag((u32)NF_ACTION))
            return true;
        }
    return false;
    }

bool nameIsOneOf(String* n, String* a, String* b)
    {
    return n != 0 && (n.equals(a) || n.equals(b));
    }

void synthesizeDesignable(Node* program)
    {
    // 1. Local designable classes only — an imported class already carries its
    //    synthesised bodies in the library, and re-synthesising across a module
    //    boundary would give it a second, differently-numbered set.
    Array* designable = new Array();
    for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
        {
        Node* d = program.kid(i);
        if (d.kind() != (u16)nkClassDecl)
            continue;
        if (d.hasFlag((u32)NF_EXTERNAL))
            continue;
        if (classIsDesignable(d))
            designable.add((Object*)d);
        }
    if (designable.count() == (u32)0)
        return;

    // 2. The binding protocol must be in scope: a class cannot conform to a
    //    protocol it cannot see. The NAMES are discovered rather than fixed —
    //    the framework was XG and is now UXKit, and a compiler that knows only
    //    one spelling silently stops synthesising when the other is imported.
    String* protoName = (String*)0;
    String* nibClass = (String*)0;
    String* controlType = (String*)0;
    for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
        {
        Node* d = program.kid(i);
        String* n = d.name();
        if (d.kind() == (u16)nkProtocolDecl)
            {
            if (protoName == 0 && nameIsOneOf(n, String.withCString("UXDesignable"),
                                              String.withCString("UIDesignable")))
                protoName = n;
            }
        else if (d.kind() == (u16)nkClassDecl)
            {
            if (nibClass == 0 && nameIsOneOf(n, String.withCString("UXNib"),
                                             String.withCString("XGNib")))
                nibClass = n;
            if (controlType == 0 && nameIsOneOf(n, String.withCString("UXControl"),
                                                String.withCString("XGControl")))
                controlType = n;
            }
        }
    if (protoName == 0)
        {
        Stdio.printf("xc-fe: error: a class with an `outlet` field or `:action` method "
                     "must import the UI framework — it auto-conforms to the "
                     "UXDesignable protocol declared there\n");
        Process.exit((i32)1);
        return;
        }
    // wireAction's parameter type. Falling back to Object keeps a class with
    // outlets but no actions compiling in a tree that has the protocol but no
    // control class.
    if (controlType == 0)
        controlType = String.withCString("Object");

    // 3. Every `:action` must be wireable: void return, exactly one
    //    object-pointer parameter (the sender). A malformed one cannot be
    //    called from a control, so it is rejected at its declaration rather
    //    than misfiring at load.
    bool bad = false;
    for (u32 i = (u32)0; i < designable.count(); i = i + (u32)1)
        {
        Node* c = (Node*)designable.get(i);
        for (u32 j = (u32)0; j < c.kidCount(); j = j + (u32)1)
            {
            Node* m = c.kid(j);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (!m.hasFlag((u32)NF_ACTION))
                continue;
            bool voidRet = m.op() == 0 || m.op().equals(String.withCString("void"));
            u32 nparams = (u32)0;
            bool objParam = false;
            for (u32 k = (u32)0; k < m.kidCount(); k = k + (u32)1)
                {
                Node* p = m.kid(k);
                if (p.kind() != (u16)nkParam)
                    continue;
                nparams = nparams + (u32)1;
                if (p.op() != 0 && p.op().byteIndexOf(String.withCString("*")) != String.notFound())
                    objParam = true;
                }
            if (!voidRet || nparams != (u32)1 || !objParam)
                {
                Stdio.printf("xc-fe: error: `:action` method '%s' must return void and "
                             "take exactly one object-pointer parameter (the sender)\n",
                             m.name() == 0 ? "?" : m.name().cString());
                bad = true;
                }
            }
        }
    if (bad)
        {
        Process.exit((i32)1);
        return;
        }

    // 4. The synthesis source. `_xtc_streq` because `u8@ ==` is a POINTER
    //    compare and a nib matches by bytes; `_xtc_nibNew` so the loader can
    //    make this module's classes by name; one throwaway `__xtc_synth_<C>`
    //    per designable class carrying the two bodies.
    String* src = String.withCString("");
    src.appendCString("bool _xtc_streq(u8* a, u8* b) {\n");
    src.appendCString("  i32 i = (i32)0;\n");
    src.appendCString("  while (a[i] != (u8)0 && a[i] == b[i]) { i = i + (i32)1; }\n");
    src.appendCString("  return a[i] == b[i];\n");
    src.appendCString("}\n");
    src.appendCString(protoName.cString());
    src.appendCString("* _xtc_nibNew(u8* name) {\n");
    for (u32 i = (u32)0; i < designable.count(); i = i + (u32)1)
        {
        String* cn = ((Node*)designable.get(i)).name();
        src.appendCString("  if (_xtc_streq(name, (u8*)\"");
        src.append(cn);
        src.appendCString("\")) return (");
        src.append(protoName);
        src.appendCString("*)new ");
        src.append(cn);
        src.appendCString("();\n");
        }
    src.appendCString("  return (");
    src.append(protoName);
    src.appendCString("*)0;\n}\n");
    // A load-time constructor hands the factory to the loader, so nibs resolve
    // this module's classes with no per-app code. Only when the nib class is in
    // scope — otherwise the factory is generated but unwired, which is what a
    // self-contained test calling _xtc_nibNew directly wants.
    if (nibClass != 0)
        {
        src.appendCString("void _xtc_nib_register(void) {\n  ");
        src.append(nibClass);
        src.appendCString(".registerObjectFactory((pointer)&_xtc_nibNew);\n}\n");
        }
    for (u32 i = (u32)0; i < designable.count(); i = i + (u32)1)
        {
        Node* c = (Node*)designable.get(i);
        src.appendCString("class __xtc_synth_");
        src.append(c.name());
        src.appendCString(" {\n");
        src.appendCString("  bool setOutlet(u8* name, Object* value) {\n");
        for (u32 j = (u32)0; j < c.kidCount(); j = j + (u32)1)
            {
            Node* v = c.kid(j);
            if (v.kind() != (u16)nkVariableDecl)
                continue;
            if (!v.hasFlag((u32)NF_OUTLET))
                continue;
            String* ty = stripTypeQualifiers(v.op() == 0 ? String.withCString("Object*")
                                                         : v.op());
            src.appendCString("    if (_xtc_streq(name, (u8*)\"");
            src.append(v.name());
            src.appendCString("\")) { ");
            src.append(v.name());
            src.appendCString(" = (");
            src.append(ty);
            src.appendCString(" ?)value; return ");
            src.append(v.name());
            src.appendCString(" != (");
            src.append(ty);
            src.appendCString(")0 || value == (Object*)0; }\n");
            }
        src.appendCString("    return false;\n  }\n");
        src.appendCString("  bool wireAction(u8* name, ");
        src.append(controlType);
        src.appendCString("* control) {\n");
        for (u32 j = (u32)0; j < c.kidCount(); j = j + (u32)1)
            {
            Node* m = c.kid(j);
            if (m.kind() != (u16)nkMethodDecl)
                continue;
            if (!m.hasFlag((u32)NF_ACTION))
                continue;
            src.appendCString("    if (_xtc_streq(name, (u8*)\"");
            src.append(m.name());
            src.appendCString("\")) { control.setAction(&self.");
            src.append(m.name());
            src.appendCString("); return true; }\n");
            }
        src.appendCString("    return false;\n  }\n");
        src.appendCString("}\n");
        }

    // 5. Parse it. The fresh parser has to be told the names this source
    //    mentions but does not declare — the outlet types, the protocol, the
    //    control, the designable classes — or its declaration heuristics read
    //    a cast to one of them as an expression.
    Lexer* lex = Lexer.with(src, String.withCString("<nib-synth>"));
    Parser* parser = Parser.with(lex.tokenise());
    parser.addTypeName(protoName);
    parser.addTypeName(controlType);
    if (nibClass != 0)
        parser.addTypeName(nibClass);
    for (u32 i = (u32)0; i < designable.count(); i = i + (u32)1)
        {
        Node* c = (Node*)designable.get(i);
        parser.addTypeName(c.name());
        for (u32 j = (u32)0; j < c.kidCount(); j = j + (u32)1)
            {
            Node* v = c.kid(j);
            if (v.kind() != (u16)nkVariableDecl || !v.hasFlag((u32)NF_OUTLET))
                continue;
            String* ty = stripTypeQualifiers(v.op() == 0 ? String.withCString("Object*")
                                                         : v.op());
            u32 star = ty.byteIndexOf(String.withCString("*"));
            parser.addTypeName(star == String.notFound() ? ty : ty.substringToByte(star));
            }
        }
    Node* synth = parser.parse();
    if (synth == 0)
        return;

    // 6. Transplant. The free functions join the program; each __xtc_synth_<C>
    //    hands its methods to the real C and adds the conformance — the
    //    throwaway class itself is dropped, so nothing names it afterwards.
    for (u32 i = (u32)0; i < synth.kidCount(); i = i + (u32)1)
        {
        Node* d = synth.kid(i);
        if (d.kind() == (u16)nkFunctionDecl)
            {
            // The registrar is a LOAD-TIME constructor: nothing calls it, its
            // pointer goes into the target's constructor list, and that is the
            // whole point — a nib resolves this module's classes with no line
            // of per-app code.
            if (d.name() != 0 && d.name().equals(String.withCString("_xtc_nib_register")))
                d.addFlag((u32)NF_MODINIT);
            program.add(d);
            continue;
            }
        if (d.kind() != (u16)nkClassDecl)
            continue;
        String* real = d.name().substringFromByte((u32)12); // past "__xtc_synth_"
        for (u32 k = (u32)0; k < designable.count(); k = k + (u32)1)
            {
            Node* rc = (Node*)designable.get(k);
            if (!rc.name().equals(real))
                continue;
            for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                if (d.kid(j).kind() == (u16)nkMethodDecl)
                    rc.add(d.kid(j));
            String* protos = rc.extra();
            if (protos == 0 || protos.equals(String.withCString("-")))
                {
                rc.setExtra(String.withString(protoName));
                }
            else if (protos.byteIndexOf(protoName) == String.notFound())
                {
                String* joined = String.withString(protos);
                joined.appendByte((u8)',');
                joined.append(protoName);
                rc.setExtra(joined);
                }
            break;
            }
        }
    }
