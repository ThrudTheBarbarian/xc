// Origins.xc — where each definition in an object came from (#663).
//
// Every `-c` object carries its imports compiled in (the standard library in
// each module), so two objects routinely define the same name, and the link
// keeps the first copy. That is right when both come from the same source
// and wrong when two modules each wrote a definition of their own. The
// bytes cannot tell the two apart (each module compiles a library function
// with its own context), so the object says where each definition came from:
// one line per name, `<symbol>\t<file basename>:<line>`, sorted, written
// beside the object as `<object>.xtc.origins`. A link refuses a name two
// objects define from different origins.
//
// Recorded: free functions and methods that have a body, and initialised
// globals, as the user wrote them — nothing the compiler synthesised. A tentative global (`i32 g;`) is a common, merged by design, and is
// not recorded. The basename, not the path: the same library file reached
// through two support roots is still one origin. The reference writes the
// same table, byte for byte.

#import "Foundation.xc"
#import <Node>
#import "NodeDefs.xc"

class Origins
    {
    static bool hasBody(Node* d)
        {
        for (u32 i = (u32)0; i < d.kidCount(); i = i + (u32)1)
            if (d.kid(i) != (Node*)0 && d.kid(i).kind() == (u16)nkBlock)
                return true;
        return false;
        }

    static void note(Map* m, Array* names, String* sym, Node* at)
        {
        if (sym == (String*)0 || at == (Node*)0 || at.file() == (String*)0)
            return;
        // Only what a user wrote: not a definition the compiler synthesised
        // (a `<class-names>` or `<conformance-helper>` source, a line of 0).
        // The statement's first line, as the reference records a declaration;
        // a node that has none carries its own line.
        u32 ln = at.stmtLine() != (u32)0 ? at.stmtLine() : at.line();
        if (at.file().hasPrefix(String.withCString("<")) || ln == (u32)0)
            return;
        if (m.get((Hashable*)sym) != (Object*)0)
            return;
        String* o = String.withString(at.file().lastPathComponent());
        o.appendByte((u8)':');
        o.append(String.withU32(ln));
        m.set((Hashable*)sym, (Object*)o);
        names.add((Object*)sym);
        }

    static String* table(Node* program)
        {
        Map* m = new Map();
        Array* names = new Array();
        for (u32 i = (u32)0; program != (Node*)0 && i < program.kidCount(); i = i + (u32)1)
            {
            Node* d = program.kid(i);
            if (d == (Node*)0)
                continue;
            if (d.kind() == (u16)nkFunctionDecl && Origins.hasBody(d))
                Origins.note(m, names, d.sym() != (String*)0 ? d.sym() : d.name(), d);
            // A class whose name has a `$` is the compiler's (a block's
            // `Blk$…`, a par block's): it has no source of its own.
            else if (d.kind() == (u16)nkClassDecl && d.name() != (String*)0
                     && d.name().byteIndexOf(String.withCString("$")) == String.notFound())
                {
                for (u32 k = (u32)0; k < d.kidCount(); k = k + (u32)1)
                    {
                    Node* mt = d.kid(k);
                    if (mt == (Node*)0 || mt.kind() != (u16)nkMethodDecl || !Origins.hasBody(mt))
                        continue;
                    String* s = String.withString(d.name());
                    s.appendByte((u8)'$');
                    s.append(mt.sym() != (String*)0 ? mt.sym() : mt.name());
                    Origins.note(m, names, s, mt);
                    }
                }
            else if (d.kind() == (u16)nkVariableDecl && d.kidCount() > (u32)0
                     && !d.hasFlag((u32)NF_EXTERN) && d.name() != (String*)0)
                Origins.note(m, names, d.name(), d);
            }
        names.sort();
        String* out = new String();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* n = (String*)names.get(i);
            out.append(n);
            out.appendByte((u8)'\t');
            out.append((String*)m.get((Hashable*)n));
            out.appendByte((u8)'\n');
            }
        return out;
        }
    }
