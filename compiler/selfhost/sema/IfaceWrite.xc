// IfaceWrite.xc — the module INTERFACE, as JSON.
// =================================================================
//
// The writer half of the `.xtc.iface` contract (task #52). `Iface.xc` next door
// READS this format — it is what `#import <Lib>` type-checks a client against —
// and until now only the reference compiler could produce one, which is why
// `--emit-lib` needed the bootstrap.
//
// The shape is fixed by the reader, not invented here: classes carry
// name/parent/protocols/ivars/methods, a method carries
// name/symbol/static/optional/varargs/params/returns, and a param carries
// name/type. Keys the reader does not consume (enums, structs, globals,
// typedefs) are still written, because a client importing this library may
// need the TYPES even when this compiler's reader ignores them, and a file
// that is a subset of the reference's is a file the reference cannot read
// back.
//
// What is deliberately NOT exported:
//   * a declaration that ARRIVED through an import — it belongs to the library
//     that owns it. Re-exporting it collides with that library's record in any
//     client importing both, and after a category merge would leak this
//     module's chain methods into the class where a client would read them as
//     plain methods and direct-call past every override (§4.3b).
//   * a `static` ivar — it occupies no instance slot, so emitting it would
//     insert a phantom field into every importer's layout and shift every ivar
//     after it.
#import "Foundation.xc"
#import "Node.xc"
#import "Vtable.xc"
#import "Iface.xc"

class IfaceWrite
{
    // The class node of that name, or null. Object lives in the prelude and is
    // not among the classes an interface KEEPS, but it is in the program, and
    // it owns the slot every `description` override answers at.
    static Node* classNamed(Node* program, String* name)
    {
        if (program == (Node*)0 || name == (String*)0) return (Node*)0;
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1) {
            Node* d = program.kid(i);
            if (d == (Node*)0 || d.kind() != (u16)nkClassDecl) continue;
            if (d.name() != (String*)0 && d.name().equals(name)) return d;
        }
        return (Node*)0;
    }

    // The slot `m` answers at on class `c`: the HIGHEST ancestor declaring a
    // matching signature that has a slot. The walk stops where the chain does —
    // an ancestor that does not declare the method cannot own its slot.
    static Object* answeringSlot(Node* program, Vtable* vt, Node* c, Node* m)
    {
        if (vt == (Vtable*)0) return (Object*)0;
        Object* best = (Object*)0;
        Node* a = c;
        Node* am = m;
        u32 guard = (u32)0;
        while (a != (Node*)0 && guard < (u32)64) {
            Object* s = vt.slotForLabel(Vtable.label(a.name(), am));
            if (s != (Object*)0) best = s;
            Node* p = IfaceWrite.classNamed(program, Vtable.parentName(a));
            if (p == (Node*)0) break;
            Node* pm = Vtable.matching(p, am);
            if (pm == (Node*)0) break;
            a = p; am = pm;
            guard = guard + (u32)1;
        }
        // TOPMOST match, not the nearest. Returning the FIRST hit instead was
        // tried and MEASURED: ifacewrite-diff went 3 failures -> 15, breaking
        // the whole `class_inherit_*` family. The reference's rule is neither
        // "nearest root" nor "topmost class with a method of that name" — see
        // private:docs/bugs/065 for the three cases this still gets wrong and the
        // `XTC_DUMP_VSLOTS` evidence. Do not change this without re-running
        // the harness; the plausible simplification is the wrong one.
        return best;
    }

    static Node* protocolNamed(Node* program, String* name)
    {
        if (program == (Node*)0 || name == (String*)0) return (Node*)0;
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1) {
            Node* d = program.kid(i);
            if (d == (Node*)0 || d.kind() != (u16)nkProtocolDecl) continue;
            if (d.name() != (String*)0 && d.name().equals(name)) return d;
        }
        return (Node*)0;
    }

    // The slot a protocol requirement occupies, for a method that answers one.
    // The conformance list is inherited, so this walks the class chain too.
    static Object* protocolSlot(Node* program, Vtable* vt, Node* c, Node* m)
    {
        if (vt == (Vtable*)0 || m.name() == (String*)0) return (Object*)0;
        Object* best = (Object*)0;
        u32 guard = (u32)0;
        for (Node* a = c; a != (Node*)0 && guard < (u32)64; guard = guard + (u32)1) {
            String* protos = a.extra();
            if (protos != (String*)0) {
                Array* list = protos.splitOnByte((u8)',');
                for (u32 i = (u32)0; i < list.count(); i = i + (u32)1) {
                    String* pn = ((String*)list.get(i)).trimmed();
                    Map* ms = vt.protoSlotsFor(pn);
                    if (ms == (Map*)0) continue;
                    Object* s = ms.get((Hashable*)m.name());
                    if (s == (Object*)0) continue;
                    // The requirement's SIGNATURE has to match. The slot map is
                    // keyed by name, so `Data.compare(Data*)` — an overload
                    // that answers nothing — otherwise claimed Comparable's
                    // `compare(Object*)` slot alongside the form that really
                    // answers it, and two methods published one slot.
                    Node* pd = IfaceWrite.protocolNamed(program, pn);
                    if (pd != (Node*)0 && Vtable.matching(pd, m) == (Node*)0) continue;
                    // The LAST conforming protocol wins, not the first.
                    //
                    // The reference writes the protocol slot into the label map
                    // once per conforming (protocol, method) as it walks the
                    // class's list (XTSemanticAnalyzer+Analysis.m:1814), so a
                    // later entry overwrites an earlier one. The class-impl
                    // loop runs AFTER and overwrites again with the class-root
                    // slot — which is why a method that overrides one
                    // (`Data.hash` over `Object.hash`) publishes the class slot
                    // 2 and not Hashable's 8, and why this function is only
                    // reached when there is no class root to answer with.
                    //
                    // What survives, then, is the LAST protocol's slot.
                    // `Sprite <Drawable, Named>` — both declaring `draw()`,
                    // neither overriding anything — publishes Named's 16.
                    // Returning the first match gave Drawable's 7 (bug 117).
                    best = s;
                }
            }
            // LAST within THIS class's list, but stop at the first class that
            // yields one. The reference's loop is over a single class's
            // `protocolNames`; carrying `best` on up the ancestor chain instead
            // picks a grandparent's protocol over the nearest, which measured
            // 772/1 -> 594/179.
            if (best != (Object*)0) return best;
            a = IfaceWrite.classNamed(program, Vtable.parentName(a));
        }
        return best;
    }

    // Does this class declare more than one instance method of that name?
    static bool declaresTwice(Node* c, String* name)
    {
        if (name == (String*)0) return false;
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1) {
            Node* m = c.kid(i);
            if (m == (Node*)0 || m.kind() != (u16)nkMethodDecl) continue;
            if (m.hasFlag((u32)NF_STATIC)) continue;
            if (m.name() != (String*)0 && m.name().equals(name)) n = n + (u32)1;
        }
        return n > (u32)1;
    }

    // A function DEFINITION has a block among its kids; a prototype does not.
    static bool hasBody(Node* d)
    {
        for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1)
            if (d.kid(i) != (Node*)0 && d.kid(i).kind() == (u16)nkBlock) return true;
        return false;
    }

    // ── JSON primitives ──────────────────────────────────────────────────
    static String* esc(String* s)
    {
        String* o = new String();
        if (s == 0) return o;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1) {
            u8 c = s.byteAt(i);
            if (c == (u8)'"' || c == (u8)'\\') { o.appendByte((u8)'\\'); o.appendByte(c); }
            else if (c == (u8)'\n') o.appendCString("\\n");
            else if (c == (u8)'\t') o.appendCString("\\t");
            else if (c < (u8)32)    o.appendCString(" ");
            else o.appendByte(c);
        }
        return o;
    }

    // Every name here comes off an AST node, and a node CAN carry a null name
    // (an anonymous struct, a synthesised decl). Reading through one is a
    // segfault, so nothing below dereferences a name directly.
    static String* nm(String* s)
    { return s == (String*)0 ? String.withCString("") : s; }

    static void kv(String* out, string k, String* v, bool comma)
    {
        out.appendFormat("\"%s\": \"%s\"", k, IfaceWrite.esc(v).cString());
        if (comma) out.appendCString(", ");
    }

    static void kb(String* out, string k, bool v, bool comma)
    {
        out.appendFormat("\"%s\": %s", k, v ? "true" : "false");
        if (comma) out.appendCString(", ");
    }

    // A type as the reader spells it. The port keeps a collection's element
    // type on the node's own type string, which is already the display form.
    static String* ty(Node* n)
    {
        String* t = n == (Node*)0 ? (String*)0 : n.op();
        if (t == (String*)0) return String.withCString("void");
        return IfaceWrite.erased(t);
    }

    // A typed collection is ERASED: `Array<String>*` is an `Array*` at run
    // time and in every symbol, and the reference publishes the erased
    // spelling. The port published the generic one, so a client read a type
    // name that names nothing — no class `Array<String>` exists to import,
    // and two libraries spelling the same erased type differently do not
    // agree about a parameter they both take.
    //
    // Nesting-aware, because the argument can itself be generic
    // (`Array<Array<String>>*`), and it must not disturb a spelling with no
    // `<` at all — a function-pointer type like `i8(Object*,Object*)` passes
    // through untouched.
    static String* erased(String* t)
    {
        if (t.indexOfByte((u8)'<') == String.notFound()) return t;
        String* out = new String();
        u32 depth = (u32)0;
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1) {
            u8 c = t.byteAt(i);
            if (c == (u8)'<') { depth = depth + (u32)1; continue; }
            if (c == (u8)'>') { if (depth > (u32)0) depth = depth - (u32)1; continue; }
            if (depth == (u32)0) out.appendByte(c);
        }
        return out;
    }

    // ── one method ───────────────────────────────────────────────────────
    // `clsName` is null for a PROTOCOL method: a protocol has no code, so
    // there is no symbol to link against and the reference writes "".
    static void method(String* out, Node* m, String* clsName)
    {
        out.appendCString("{");
        IfaceWrite.kv(out, "name", IfaceWrite.nm(m.name()), true);
        String* sym = new String();
        if (clsName != (String*)0) {
            // Class$method — the same mangling the back ends emit, because a
            // client links against the NAME, not the declaration. `sym()` is
            // the OVERLOAD-mangled form (`isEqual__u16_u16`) and the plain
            // name is only right when there is one form: publishing
            // `Assert$isEqual` for all four overloads names a symbol that does
            // not exist, so a client either fails to link or is silently given
            // whichever body the linker picked.
            sym.append(IfaceWrite.nm(clsName));
            sym.appendCString("$");
            sym.append(IfaceWrite.nm(m.sym() != (String*)0 ? m.sym() : m.name()));
        }
        IfaceWrite.kv(out, "symbol", sym, true);
        IfaceWrite.kb(out, "static", m.hasFlag((u32)NF_STATIC), true);
        IfaceWrite.kb(out, "optional", m.hasFlag((u32)NF_OPTIONAL), true);
        IfaceWrite.kb(out, "varargs", m.hasFlag((u32)NF_VARARGS), true);
        IfaceWrite.params(out, m);
        IfaceWrite.returnsList(out, m);
    }

    // The `returns` ARRAY. A multi-return function's type spelling is one
    // comma-joined string ("i16,i16"), and this used to emit it as a single
    // element — so a client reading the interface saw one return of a type
    // that does not exist. The reference writes one element per value.
    //
    // Depth-aware: a function-POINTER return spells its own parameters with
    // commas (`i32(Object*,Object*)`), and those must not split.
    static void returnsList(String* out, Node* d)
    {
        out.appendCString(", \"returns\": [");
        String* t = IfaceWrite.esc(IfaceWrite.ty(d));
        u32 depth = (u32)0;
        u32 start = (u32)0;
        bool first = true;
        for (u32 i = (u32)0; i <= t.byteLength(); i = i + (u32)1) {
            bool end = (i == t.byteLength());
            u8 c = end ? (u8)',' : t.byteAt(i);
            if (!end && (c == (u8)'(' || c == (u8)'[')) depth = depth + (u32)1;
            else if (!end && (c == (u8)')' || c == (u8)']') && depth > (u32)0) depth = depth - (u32)1;
            if (c != (u8)',' || depth != (u32)0) continue;
            if (!first) out.appendCString(", ");
            first = false;
            out.appendFormat("\"%s\"", t.substringBytes(start, i - start).cString());
            start = i + (u32)1;
        }
        out.appendCString("]}");
    }

    // The `params` array of a method or function. One writer, because the two
    // shapes must not drift: a client matches a call against these.
    static void params(String* out, Node* d)
    {
        out.appendCString("\"params\": [");
        bool first = true;
        for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1) {
            Node* p = d.kid(i);
            if (p == (Node*)0 || p.kind() != (u16)nkParam) continue;
            if (!first) out.appendCString(", ");
            first = false;
            out.appendCString("{");
            IfaceWrite.kv(out, "name", IfaceWrite.nm(p.name()), true);
            IfaceWrite.kv(out, "type", IfaceWrite.ty(p), false);
            out.appendCString("}");
        }
        out.appendCString("]");
    }

    // ── one class (or protocol — same shape, the reader reads both) ──────
    static void classDecl(String* out, Node* c, bool wantIvars)
    {
        out.appendCString("{");
        IfaceWrite.kv(out, "name", IfaceWrite.nm(c.name()), true);
        if (wantIvars) {
            // The parent is on the node's `op`, and a ROOT spells it "-".
            // Written as "" rather than "-" because the reader turns an empty
            // parent back into "-", and a literal "-" would come back as a
            // class named "-".
            String* parent = c.op();
            if (parent == (String*)0 || parent.equals(String.withCString("-")))
                parent = String.withCString("");
            IfaceWrite.kv(out, "parent", parent, true);

            // Protocols ride on `extra` as a comma-separated list, "-" when
            // there are none — the shape Iface.xc's reader produces, so the
            // writer has to undo exactly that encoding and no other.
            out.appendCString("\"protocols\": [");
            String* ex = c.extra();
            if (ex != (String*)0 && !ex.equals(String.withCString("-"))
                                 && ex.byteLength() > (u32)0) {
                bool pf = true;
                String* cur = new String();
                for (u32 i = (u32)0; i <= ex.byteLength(); i = i + (u32)1) {
                    bool end = (i == ex.byteLength());
                    u8 ch = end ? (u8)',' : ex.byteAt(i);
                    if (ch != (u8)',') { cur.appendByte(ch); continue; }
                    if (cur.byteLength() > (u32)0) {
                        if (!pf) out.appendCString(", ");
                        pf = false;
                        out.appendFormat("\"%s\"", IfaceWrite.esc(cur).cString());
                    }
                    cur = new String();
                }
            }
            out.appendCString("], \"ivars\": [");
            bool vf = true;
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1) {
                Node* v = c.kid(i);
                if (v == (Node*)0 || v.kind() != (u16)nkVariableDecl) continue;
                // A STATIC ivar occupies no instance slot. Emitting it would
                // insert a phantom field into every importer's layout and
                // shift every ivar after it.
                if (v.hasFlag((u32)NF_STATIC)) continue;
                if (!vf) out.appendCString(", ");
                vf = false;
                out.appendCString("{");
                IfaceWrite.kv(out, "name", IfaceWrite.nm(v.name()), true);
                IfaceWrite.kv(out, "type", IfaceWrite.ty(v), false);
                out.appendCString("}");
            }
            out.appendCString("], ");
        }
        out.appendCString("\"methods\": [");
        bool mf = true;
        for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1) {
            Node* m = c.kid(i);
            if (m == (Node*)0 || m.kind() != (u16)nkMethodDecl) continue;
            if (!mf) out.appendCString(", ");
            mf = false;
            IfaceWrite.method(out, m, wantIvars ? c.name() : (String*)0);
        }
        out.appendCString("]");
        // The XG-NIB DESIGNABLE surface: `outlet` ivars and `:action` methods,
        // which Rocks reflects on to offer connections and validate wires. The
        // port published neither, so a designable class imported from a library
        // came back looking like an ordinary one and its outlets could not be
        // wired at all. Emitted only when there IS one, exactly as the
        // reference gates it — an empty `outlets`/`actions` pair on every
        // class would change every interface in the tree for nothing.
        if (wantIvars) {
            bool anyOutlet = false;
            bool anyAction = false;
            for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1) {
                Node* k = c.kid(i);
                if (k == (Node*)0) continue;
                if (k.kind() == (u16)nkVariableDecl && k.hasFlag((u32)NF_OUTLET)) anyOutlet = true;
                if (k.kind() == (u16)nkMethodDecl   && k.hasFlag((u32)NF_ACTION)) anyAction = true;
            }
            if (anyOutlet || anyAction) {
                out.appendCString(", \"designable\": true, \"outlets\": [");
                bool of = true;
                for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1) {
                    Node* v = c.kid(i);
                    if (v == (Node*)0 || v.kind() != (u16)nkVariableDecl) continue;
                    if (!v.hasFlag((u32)NF_OUTLET)) continue;
                    if (!of) out.appendCString(", ");
                    of = false;
                    out.appendCString("{");
                    IfaceWrite.kv(out, "name", IfaceWrite.nm(v.name()), true);
                    IfaceWrite.kv(out, "type", IfaceWrite.ty(v), false);
                    out.appendCString("}");
                }
                out.appendCString("], \"actions\": [");
                bool af = true;
                for (u32 i = (u32)0; i < c.kidCount(); i = i + (u32)1) {
                    Node* m = c.kid(i);
                    if (m == (Node*)0 || m.kind() != (u16)nkMethodDecl) continue;
                    if (!m.hasFlag((u32)NF_ACTION)) continue;
                    if (!af) out.appendCString(", ");
                    af = false;
                    // The SENDER is the action's first parameter's type; a
                    // parameterless action reports the base class, as the
                    // reference's `firstObject` fallback does.
                    String* sender = String.withCString("Object*");
                    for (u32 j = (u32)0; j < m.kidCount(); j = j + (u32)1) {
                        Node* pp = m.kid(j);
                        if (pp == (Node*)0 || pp.kind() != (u16)nkParam) continue;
                        sender = IfaceWrite.ty(pp);
                        break;
                    }
                    out.appendCString("{");
                    IfaceWrite.kv(out, "name", IfaceWrite.nm(m.name()), true);
                    IfaceWrite.kv(out, "sender", sender, false);
                    out.appendCString("}");
                }
                out.appendCString("]");
            }
        }
        out.appendCString("}");
    }

    // Every `_cls_<Class>_<method>` slot this module OWNS. A client dispatches
    // through these numbers, so they are part of the contract: recomputing
    // them on the far side would number a different set of classes and land
    // somewhere else in the table. Slots ADOPTED from a library we imported
    // are not ours to re-export — they already travel in that library's own
    // interface, and a second copy is a second thing to disagree.
    // Is `label` a `_cls_<C>_…` for one of the classes we exported? The slots
    // travel with the class they belong to, so a label for a class this
    // interface does not describe is somebody else's contract.
    static bool ownsLabel(String* label, Array* kept)
    {
        if (!label.hasPrefix(String.withCString("_cls_"))) return false;
        String* rest = label.substringFromByte((u32)5);
        for (u32 i = (u32)0; i < kept.count(); i = i + (u32)1) {
            String* cn = String.withString((String*)kept.get(i));
            cn.appendByte((u8)'_');
            if (rest.hasPrefix(cn)) return true;
        }
        return false;
    }

    static void slotObj(String* out, Map* m, Array* kept)
    {
        out.appendCString("{");
        if (m != (Map*)0) {
            Array* ks = m.allKeys();
            bool first = true;
            for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1) {
                String* k = (String*)ks.get(i);
                if (kept != (Array*)0 && !IfaceWrite.ownsLabel(k, kept)) continue;
                Object* v = m.get((Hashable*)k);
                if (v == (Object*)0) continue;
                if (!first) out.appendCString(", ");
                first = false;
                out.appendFormat("\"%s\": %ld", IfaceWrite.esc(k).cString(),
                                 (i32)((Number*)v).asU32());
            }
        }
        out.appendCString("}");
    }

    static void slotMap(String* out, string key, Map* m, Array* kept)
    {
        out.appendFormat("\"%s\": ", key);
        IfaceWrite.slotObj(out, m, kept);
    }

    // ── the module ───────────────────────────────────────────────────────
    // Did this declaration arrive with the PRELUDE? Keyed by file, the same
    // way the preprocessor recorded it, so a later explicit `#import
    // "Stdio.xc"` — a once-only no-op — does not make Stdio ours to export.
    static bool ambient(Node* d, Set* prelude)
    {
        if (prelude == (Set*)0 || d == (Node*)0) return false;
        String* f = d.file();
        // No position at all means the COMPILER made it — a `Blk$…` callback
        // shim, a runtime helper declaration. A module's public surface is
        // what somebody wrote, so a decl with no file is not exported.
        if (f == (String*)0 || f.byteLength() == (u32)0) return true;
        // …and so is anything the compiler INJECTED: the conformance helper is
        // parsed from a source string, so it has a position, but it belongs to
        // every unit rather than to this one.
        if (d.hasFlag((u32)NF_SYNTH)) return true;
        // …and so is a COMPILER-GENERATED class: `BlkImpl$N`, the `Blk$…`
        // shapes. `$` is the hex-literal prefix, so it cannot appear in a name
        // anybody wrote — an exact test, not a heuristic. They were already
        // being dropped here, but only because the node happened to carry no
        // position, while the reference published them. Stated outright on
        // both sides now: relying on a missing position for a decision this
        // load-bearing is how the two drifted apart in the first place.
        String* dn = d.name();
        if (dn != (String*)0 && dn.indexOfByte((u8)'$') != String.notFound())
            return true;
        return prelude.contains((Hashable*)f);
    }

    static String* json(Node* program, Vtable* vt, Set* prelude, Array* cImports)
    {
        String* out = new String();
        out.appendCString("{\n");
        out.appendCString("\"ifaceVersion\": 1, \"version\": 1,\n");

        // The names actually exported, collected as they are written: the slot
        // maps below are pruned to them, so the two can never disagree about
        // which classes this interface describes.
        Array* keptDecls  = new Array();     // the class NODES, for their slots
        Array* keptProtos = new Array();

        out.appendCString("\"classes\": [");
        bool first = true;
        for (u32 i = (u32)0; program != (Node*)0 && i < program.kidCount(); i = i + (u32)1) {
            Node* d = program.kid(i);
            if (d == (Node*)0 || d.kind() != (u16)nkClassDecl) continue;
            // Arrived through an IMPORT: it belongs to the library that owns
            // it. Re-exporting collides with that library's own record in any
            // client importing both.
            if (d.hasFlag((u32)NF_EXTERNAL)) continue;
            if (IfaceWrite.ambient(d, prelude)) continue;
            if (!first) out.appendCString(",\n  ");
            first = false;
            keptDecls.add((Object*)d);
            IfaceWrite.classDecl(out, d, true);
        }
        out.appendCString("],\n");

        out.appendCString("\"protocols\": [");
        first = true;
        for (u32 i = (u32)0; program != (Node*)0 && i < program.kidCount(); i = i + (u32)1) {
            Node* d = program.kid(i);
            if (d == (Node*)0 || d.kind() != (u16)nkProtocolDecl) continue;
            if (d.hasFlag((u32)NF_EXTERNAL)) continue;
            if (IfaceWrite.ambient(d, prelude)) continue;
            if (!first) out.appendCString(",\n  ");
            first = false;
            keptProtos.add((Object*)IfaceWrite.nm(d.name()));
            IfaceWrite.classDecl(out, d, false);
        }
        out.appendCString("],\n");

        out.appendCString("\"functions\": [");
        first = true;
        for (u32 i = (u32)0; program != (Node*)0 && i < program.kidCount(); i = i + (u32)1) {
            Node* d = program.kid(i);
            if (d == (Node*)0 || d.kind() != (u16)nkFunctionDecl) continue;
            if (d.hasFlag((u32)NF_EXTERNAL)) continue;
            if (IfaceWrite.ambient(d, prelude)) continue;
            // NOT gated on `NF_EXTERN`. `extern` on a DEFINITION is §6's
            // target-neutral face — `extern u32 twice(u32 v) { … }` keeps its
            // mangled symbol and carries `exported` — and dropping every
            // extern-flagged node took those out of the interface with the
            // prototypes. The body test below is the one that separates them,
            // and it is sufficient: a prototype has no block whether or not it
            // is spelled `extern`.
            // Only DEFINED functions. A body-less declaration in a library's
            // own source is a prototype for something it IMPORTED — `printf`
            // and `abs` arrive that way through `#import <c>` — and publishing
            // one makes this library claim to export libc. A client importing
            // both then has two declarations of `printf` from two libraries.
            // A C import is not spelled `extern` either — it simply has no
            // block — so the body test is what catches both shapes.
            if (!IfaceWrite.hasBody(d)) continue;
            // Compiler-generated helpers (`_xtc_obj_conforms`, the XG-NIB
            // synthesis functions) are injected into EVERY module — per-module
            // implementation, not API. Exporting one makes a client see a
            // second declaration of the copy it already has.
            if (d.name() != (String*)0
                && d.name().hasPrefix(String.withCString("_xtc_"))) continue;
            if (!first) out.appendCString(", ");
            first = false;
            out.appendCString("{");
            IfaceWrite.kv(out, "name", IfaceWrite.nm(d.name()), true);
            // The OVERLOAD-MANGLED symbol, exactly as `method()` above does it.
            // A free function's overloads were all published under the bare
            // name — three `show`s, one `symbol: "show"` — so a client either
            // failed to link or was silently handed whichever body the linker
            // picked. This is the SAME defect that was already fixed for
            // methods; it was fixed in one of the two places that spell the
            // rule, which is how a contract in two places drifts.
            IfaceWrite.kv(out, "symbol",
                          IfaceWrite.nm(d.sym() != (String*)0 ? d.sym() : d.name()), true);
            IfaceWrite.kb(out, "varargs", d.hasFlag((u32)NF_VARARGS), true);
            IfaceWrite.params(out, d);
            IfaceWrite.returnsList(out, d);
        }
        out.appendCString("],\n");

        // The RESOLVED slot of every method of every exported class — where the
        // method actually dispatches, which is what a client needs. Not the
        // root labels: `Greeter.description` overrides `Object.description`,
        // so it answers at Object's slot, and publishing Greeter's own root
        // number would send a client's call somewhere else in the table.
        // Where each method a kept class declares actually DISPATCHES, keyed
        // the way the reference keys it: `_cls_<Class>_<mangled>`.
        //
        // Both halves were wrong before. The KEY was the plain method name, so
        // two overloads of one name collapsed onto a single entry. And the
        // VALUE came from the class's own slot table, which numbers a method
        // where it was DECLARED — but an override answers at the slot it
        // overrides, so `Data.description` is Object's slot, not a number in
        // Data's own range. A client adopts these numbers as authoritative (it
        // cannot re-derive them and agree by luck), so either mistake is a call
        // landing on the wrong method, not a formatting difference.
        //
        // `ifaceSlots` is sema's snapshot of exactly that — where a method
        // dispatches ON THE CLASS, taken before the protocol loop rewrites a
        // requirement's entry to the PROTOCOL's slot, which is a different
        // number in a table a class-typed call never indexes. A method with no
        // entry there overrides nothing, so its own root number is the answer,
        // and that one distinguishes overloads.
        out.appendCString("\"methodSlots\": {");
        bool sf = true;
        for (u32 i = (u32)0; i < keptDecls.count(); i = i + (u32)1) {
            Node* c = (Node*)keptDecls.get(i);
            Map* resolved = c.ifaceSlots();
            for (u32 k = (u32)0; k < c.kidCount(); k = k + (u32)1) {
                Node* m = c.kid(k);
                if (m == (Node*)0 || m.kind() != (u16)nkMethodDecl) continue;
                if (m.hasFlag((u32)NF_STATIC)) continue;     // no vtable slot
                // …nor a method SEMA SYNTHESISED. A subclass that declares no
                // `init` gets one whose body is nothing but the super chain
                // (`class_inherited_init.xc`), and it is an implementation
                // detail of this build, not part of the class's published
                // surface — the reference's slot map, which sema fills from
                // DECLARED methods, has no label for it. Publishing one told a
                // client the subclass had its own init to dispatch to.
                if (m.hasFlag((u32)NF_SYNTH)) continue;
                // `ifaceSlots` first: it is sema's answer to "where does this
                // method dispatch on THIS class", computed under whichever mode
                // the build is in. In a library build every instance method is
                // its own root and it says so; the label map holds the
                // inheritance-resolved number instead, which is a different
                // question and the wrong one to publish.
                //
                // The label map is the fallback for a method sema's snapshot
                // did not reach.
                // Resolve the method to the slot it ANSWERS at: walk to the
                // highest ancestor that declares a matching signature and take
                // that label's number. `Data.description` and
                // `ArArchive.description` both come out as Object's slot,
                // which is why the reference publishes 176 for both — in a
                // library build Object's own methods are numbered last, so the
                // shared slot is a high number rather than a low one.
                //
                // A non-overriding overload has no such ancestor and keeps its
                // own root: `Data.equals(Data*)` is 88 while
                // `Data.equals(Object*)` is Object's 177. That distinction is
                // the whole reason this walks signatures rather than names —
                // sema's per-class snapshot is keyed by the plain NAME and
                // gives both forms one answer.
                // SEMA'S OWN ANSWER FIRST. `ifaceSlots` is the snapshot of
                // "where does this method dispatch ON THIS CLASS", taken in
                // Sema before the protocol loop rewrites entries — which is
                // exactly the question a client asks. Re-deriving it with an
                // ancestor walk is what bug 117 was: the walk returns the
                // TOPMOST match, and the right answer is sometimes the class's
                // own root (`Vehicle.description` at 7, not Object's 4) and
                // sometimes an ancestor's (`Animal.description` at Object's 3),
                // with nothing in the class shape to tell them apart. Sema
                // already knows; asking it is not a heuristic.
                //
                // Only when the name is UNAMBIGUOUS, because that map is keyed
                // by the plain name and cannot separate overloads: it would
                // hand `Data.equals(Data*)` the slot belonging to
                // `equals(Object*)`. Overloads keep the walk.
                Object* sl = (Object*)0;
                if (resolved != (Map*)0 && m.name() != (String*)0) {
                    u32 sameName = (u32)0;
                    for (u32 q = (u32)0; q < c.kidCount(); q = q + (u32)1) {
                        Node* o = c.kid(q);
                        if (o == (Node*)0 || o.kind() != (u16)nkMethodDecl) continue;
                        if (o.name() != (String*)0 && o.name().equals(m.name()))
                            sameName = sameName + (u32)1;
                    }
                    if (sameName == (u32)1)
                        sl = resolved.get((Hashable*)m.name());
                }
                if (sl == (Object*)0)
                    sl = IfaceWrite.answeringSlot(program, vt, c, m);
                // …and a method can answer a PROTOCOL requirement instead of
                // an ancestor's method. `Object` declares only hash, equals and
                // description — `compare` and `copy` come from Comparable and
                // Copying — so no class walk can find their slot, and both went
                // missing from every interface the shipped compiler wrote.
                if (sl == (Object*)0)
                    sl = IfaceWrite.protocolSlot(program, vt, c, m);
                // PROTOCOL LAST, not first. Asking it first was measured:
                // ifacewrite-diff 772/1 -> 593/180. Most methods that CAN
                // answer a protocol requirement are still published at their
                // class slot; only `class_protocol`'s Sprite.draw wants the
                // protocol number, and one file does not outrank 179.
                // NO fall back to the plain-name map here. It is keyed by name,
                // so it hands `Data.equals(Data*)` the slot belonging to
                // `equals(Object*)` — publishing a slot for an overload that
                // participates in no dispatch at all. Absent is the answer.
                if (sl == (Object*)0) continue;
                String* lab = Vtable.label(IfaceWrite.nm(c.name()), m);
                if (!sf) out.appendCString(", ");
                sf = false;
                out.appendFormat("\"%s\": %ld", IfaceWrite.esc(lab).cString(),
                                 (i32)((Number*)sl).asU32());
            }
        }
        out.appendCString("}");
        out.appendCString(",\n");
        out.appendCString("\"protocolSlots\": {");
        if (vt != (Vtable*)0 && vt.protoSlots() != (Map*)0) {
            Array* ps = vt.protoSlots().allKeys();
            bool pf = true;
            for (u32 i = (u32)0; i < ps.count(); i = i + (u32)1) {
                String* pn = (String*)ps.get(i);
                // Only a protocol THIS interface declares. A protocol we merely
                // conform to belongs to whoever declared it, and its numbering
                // travels in that module's interface.
                bool mine = false;
                for (u32 j = (u32)0; j < keptProtos.count(); j = j + (u32)1)
                    if (((String*)keptProtos.get(j)).equals(pn)) mine = true;
                if (!mine) continue;
                Map* inner = (Map*)vt.protoSlots().get((Hashable*)pn);
                if (inner == (Map*)0) continue;
                if (!pf) out.appendCString(", ");
                pf = false;
                out.appendFormat("\"%s\": ", IfaceWrite.esc(pn).cString());
                IfaceWrite.slotObj(out, inner, (Array*)0);
            }
        }
        out.appendCString("},\n");

        // …and the slots this module assigned to classes it does NOT export:
        // the AMBIENT ones (String, Object, Array — the prelude). They are not
        // this library's declarations to publish, and 115 is right to keep them
        // out of `classes`. But the library still ASSUMED a vtable layout for
        // them, and under shared-everything wasm the object a client hands in
        // carries the CLIENT's table — so the library indexed slot 110 of a
        // 16-slot table (bug 091).
        //
        // A separate key on purpose: an ABI assumption, not an export. Merging
        // it into methodSlots would tell a client this library declares String.
        out.appendCString("\"ambientSlots\": {");
        {
            bool af = true;
            // `ownsLabel` takes class NAMES; keptDecls holds the class NODES.
            Array* keptNames = new Array();
            for (u32 i = (u32)0; i < keptDecls.count(); i = i + (u32)1)
                keptNames.add((Object*)IfaceWrite.nm(((Node*)keptDecls.get(i)).name()));
            // The SAME per-method resolution the kept-class loop above uses,
            // over the classes this module does NOT export. Deriving it from
            // `vt.slotByLabel()` instead was tried and produced a strict SUBSET
            // — 3 entries where the reference had 17 — because that map holds
            // ROOTS and the reference's holds roots AND the impl labels that
            // answer at them (`_cls_Array_copy` at Object's slot). Two writers
            // reading two different sources cannot agree by luck.
            for (u32 i = (u32)0; program != (Node*)0 && i < program.kidCount(); i = i + (u32)1) {
                Node* c = program.kid(i);
                if (c == (Node*)0 || c.kind() != (u16)nkClassDecl) continue;
                String* cn = IfaceWrite.nm(c.name());
                bool kept = false;
                for (u32 k = (u32)0; k < keptNames.count(); k = k + (u32)1)
                    if (((String*)keptNames.get(k)).equals(cn)) kept = true;
                if (kept) continue;                       // an export, above
                // …nor a COMPILER-GENERATED class. `BlkImpl$N` is a per-unit
                // ordinal, so its slot number means nothing to a client — the
                // same reason its declaration is not published. `$` is the
                // hex-literal prefix, so the test is exact.
                if (cn.indexOfByte((u8)'$') != String.notFound()) continue;
                for (u32 k = (u32)0; k < c.kidCount(); k = k + (u32)1) {
                    Node* m = c.kid(k);
                    if (m == (Node*)0 || m.kind() != (u16)nkMethodDecl) continue;
                    if (m.hasFlag((u32)NF_STATIC)) continue;
                    if (m.hasFlag((u32)NF_SYNTH)) continue;
                    Object* sl = IfaceWrite.answeringSlot(program, vt, c, m);
                    if (sl == (Object*)0)
                        sl = IfaceWrite.protocolSlot(program, vt, c, m);
                    if (sl == (Object*)0) continue;
                    String* lab = Vtable.label(cn, m);
                    if (!af) out.appendCString(", ");
                    af = false;
                    out.appendFormat("\"%s\": %ld", IfaceWrite.esc(lab).cString(),
                                     (i32)((Number*)sl).asU32());
                }
            }
        }
        out.appendCString("},\n");

        // Written empty rather than omitted: the reference emits these keys, and
        // a reader that expects them must not have to special-case our output.
        // Enums, structs, globals and typedefs. All four were hardcoded EMPTY,
        // so a client that imported a library could not name a single type it
        // declared: a `Rect` parameter in a published signature had its type
        // nowhere, and the client could not so much as declare one. The class
        // list alone is not an interface.
        out.appendCString("\"enums\": [");
        bool ef = true;
        for (u32 i = (u32)0; program != (Node*)0 && i < program.kidCount(); i = i + (u32)1) {
            Node* d = program.kid(i);
            if (d == (Node*)0 || d.kind() != (u16)nkEnumDecl) continue;
            if (d.hasFlag((u32)NF_EXTERNAL)) continue;
            if (IfaceWrite.ambient(d, prelude)) continue;
            // `$imported_constants` is the synthesised bucket holding the enum
            // constants THIS module imported from ITS libraries — a private
            // artefact of how it was built, not API. Publishing it made every
            // client fail outright: it synthesises a bucket of the same name
            // and sema rejects the duplicate enum.
            if (d.name() != (String*)0
                && d.name().equals(String.withCString("$imported_constants"))) continue;
            if (!ef) out.appendCString(", ");
            ef = false;
            out.appendCString("{");
            IfaceWrite.kv(out, "name", IfaceWrite.nm(d.name()), true);
            out.appendCString("\"members\": [");
            bool mf = true;
            for (u32 k = (u32)0; k < d.kidCount(); k = k + (u32)1) {
                Node* mem = d.kid(k);
                if (mem == (Node*)0 || mem.kind() != (u16)nkEnumMember) continue;
                if (!mf) out.appendCString(", ");
                mf = false;
                out.appendCString("{");
                IfaceWrite.kv(out, "name", IfaceWrite.nm(mem.name()), true);
                out.appendFormat("\"value\": %ld", (i32)mem.num());
                out.appendCString("}");
            }
            out.appendCString("]}");
        }
        out.appendCString("], \"structs\": [");
        bool stf = true;
        for (u32 i = (u32)0; program != (Node*)0 && i < program.kidCount(); i = i + (u32)1) {
            Node* d = program.kid(i);
            if (d == (Node*)0 || d.kind() != (u16)nkStructDecl) continue;
            if (d.hasFlag((u32)NF_EXTERNAL)) continue;
            if (IfaceWrite.ambient(d, prelude)) continue;
            if (d.name() == (String*)0 || d.name().byteLength() == (u32)0) continue;  // anonymous
            if (!stf) out.appendCString(", ");
            stf = false;
            out.appendCString("{");
            IfaceWrite.kv(out, "name", IfaceWrite.nm(d.name()), true);
            out.appendCString("\"fields\": [");
            bool ff = true;
            for (u32 k = (u32)0; k < d.kidCount(); k = k + (u32)1) {
                Node* f = d.kid(k);
                if (f == (Node*)0 || f.kind() != (u16)nkVariableDecl) continue;
                if (!ff) out.appendCString(", ");
                ff = false;
                out.appendCString("{");
                IfaceWrite.kv(out, "name", IfaceWrite.nm(f.name()), true);
                IfaceWrite.kv(out, "type", IfaceWrite.ty(f), false);
                out.appendCString("}");
            }
            out.appendCString("], ");
            IfaceWrite.kb(out, "packed", d.hasFlag((u32)NF_PACKED), false);
            out.appendCString("}");
        }
        out.appendCString("], \"globals\": [");
        bool gf = true;
        for (u32 i = (u32)0; program != (Node*)0 && i < program.kidCount(); i = i + (u32)1) {
            Node* d = program.kid(i);
            if (d == (Node*)0 || d.kind() != (u16)nkVariableDecl) continue;
            if (d.hasFlag((u32)NF_EXTERNAL)) continue;
            if (IfaceWrite.ambient(d, prelude)) continue;
            if (d.name() == (String*)0 || d.name().byteLength() == (u32)0) continue;
            if (!gf) out.appendCString(", ");
            gf = false;
            out.appendCString("{");
            IfaceWrite.kv(out, "name", IfaceWrite.nm(d.name()), true);
            IfaceWrite.kv(out, "type", IfaceWrite.ty(d), false);
            out.appendCString("}");
        }
        out.appendCString("],\n");
        // A type ALIAS. `typedef struct {…} Foo;` is already covered by the
        // struct export, which names the type; this carries the plain
        // `typedef <type> <alias>;` form so a client can spell the alias too.
        out.appendCString("\"typedefs\": [");
        bool tf = true;
        for (u32 i = (u32)0; program != (Node*)0 && i < program.kidCount(); i = i + (u32)1) {
            Node* d = program.kid(i);
            if (d == (Node*)0 || d.kind() != (u16)nkTypedefDecl) continue;
            if (d.hasFlag((u32)NF_EXTERNAL)) continue;
            if (IfaceWrite.ambient(d, prelude)) continue;
            if (d.name() == (String*)0 || d.name().byteLength() == (u32)0) continue;
            if (d.op() == (String*)0 || d.op().byteLength() == (u32)0) continue;
            if (!tf) out.appendCString(", ");
            tf = false;
            out.appendCString("{");
            IfaceWrite.kv(out, "name", IfaceWrite.nm(d.name()), true);
            IfaceWrite.kv(out, "target", IfaceWrite.esc(d.op()), false);
            out.appendCString("}");
        }
        // The C libraries this module's `#import <X>` named. A client
        // re-imports each through its own DWARF reader rather than trusting
        // a copy of their types here.
        out.appendCString("], \"cImports\": [");
        for (u32 i = (u32)0; cImports != (Array*)0 && i < cImports.count(); i = i + (u32)1) {
            if (i > (u32)0) out.appendCString(", ");
            out.appendFormat("\"%s\"", IfaceWrite.esc((String*)cImports.get(i)).cString());
        }
        out.appendCString("]\n");
        out.appendCString("}\n");
        return JsonVal.canonical(out);
    }
}
