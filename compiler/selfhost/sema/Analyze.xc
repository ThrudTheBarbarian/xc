// Analyze.xc — the static analyser, `-Wanalyze`.
// =================================================================
//
// Tier 1 of private:docs/Design/static-analysis.md: per-function checks that need no
// lattice and no worklist, reported at the source position of the thing they
// are about.
//
// It runs on the **AST**, not the IR, and that is a deliberate departure from
// the design's §3. The port's IR carries no source positions — an IRInsn has
// no dbgLoc — so a diagnostic derived from it could name the function and
// nothing finer, which is precisely the complaint that motivated the phi check
// in private:docs/bugs/092. The AST has file:line:col on every statement, so that is
// where the checks live until the IR grows positions.
//
// Three rules from the design are hard, because breaking them turns a warning
// into a divergence the other harnesses would report as a real failure:
//
//   * diagnostics go to STDERR, never stdout (the `-S` path writes stdout);
//   * a warning never changes the emitted code;
//   * a warning never changes the exit status.
//
// Gated by `warn-diff`, which asserts both what must warn and — just as
// importantly — what must stay silent.
#import "Foundation.xc"
#import "Stdio.xc"
#import "Node.xc"

class Analyze
    {
    Array* _out; // String@ — the diagnostics, in source order

    void init(void)
        {
        _out = new Array();
        }

    Array* diagnostics(void)
        {
        return _out;
        }

    void warnAt(Node* n, string msg)
        {
        String* s = new String();
        if (n != (Node*)0 && n.line() != (u32)0)
            {
            s.append(n.file() != (String*)0 ? n.file() : String.withCString("?"));
            s.appendByte((u8)':');
            s.append(String.withU32(n.line()));
            s.appendByte((u8)':');
            s.append(String.withU32(n.col()));
            s.appendCString(": ");
            }
        s.appendCString("warning: ");
        s.appendCString(msg);
        _out.add((Object*)s);
        }

    // ── entry ────────────────────────────────────────────────────────────
    void run(Node* program)
        {
        if (program == (Node*)0)
            return;
        for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
            {
            Node* d = program.kid(i);
            u16 k = d.kind();
            // A declaration reconstructed from a library interface has no body
            // to analyse and is not this module's code to complain about.
            if (d.hasFlag((u32)NF_EXTERNAL))
                continue;
            if (k == (u16)nkFunctionDecl || k == (u16)nkMethodDecl)
                checkBody(d);
            else if (k == (u16)nkClassDecl)
                for (u32 j = (u32)0; j < d.kidCount(); j = j + (u32)1)
                    if (d.kid(j).kind() == (u16)nkMethodDecl)
                        checkBody(d.kid(j));
            }
        }

    void checkBody(Node* fn)
        {
        for (u32 i = (u32)0; i < fn.kidCount(); i = i + (u32)1)
            if (fn.kid(i).kind() == (u16)nkBlock)
                walkBlock(fn.kid(i));
        }

    // ── unreachable code ─────────────────────────────────────────────────
    //
    // A statement after `return`, `break`, `continue` or `throw` in the SAME
    // block. Syntactic and exact: nothing can branch into the middle of a
    // block, so what follows a terminator in it cannot run.
    //
    // Only the FIRST one is reported. Everything after it is unreachable for
    // the same reason, and a warning per statement buries the cause in its own
    // consequences.
    void walkBlock(Node* b)
        {
        bool dead = false;
        for (u32 i = (u32)0; i < b.kidCount(); i = i + (u32)1)
            {
            Node* st = b.kid(i);
            if (dead)
                {
                warnAt(st, "this code cannot be reached — the statement above "
                           "always leaves the block");
                dead = false; // report once per block
                }
            if (terminates(st))
                dead = true;
            u16 k = st.kind();
            if ((k == (u16)nkIf || k == (u16)nkWhile) && st.kidCount() > (u32)0)
                checkCondition(st.kid((u32)0), st);
            walkInto(st);
            }
        deadStores(b);
        unusedLocals(b);
        }

    bool terminates(Node* st)
        {
        u16 k = st.kind();
        return k == (u16)nkReturn || k == (u16)nkBreak || k == (u16)nkContinue || k == (u16)nkThrow;
        }

    // Every nested block, wherever it hangs.
    void walkInto(Node* st)
        {
        for (u32 i = (u32)0; i < st.kidCount(); i = i + (u32)1)
            {
            Node* k = st.kid(i);
            if (k.kind() == (u16)nkBlock)
                walkBlock(k);
            else
                walkInto(k);
            }
        }

    // ── dead stores ──────────────────────────────────────────────────────
    //
    // `x = a;` followed by `x = b;` with nothing between that could read x.
    // Straight-line only, and it gives up at anything it cannot see through —
    // a call, a nested block, a loop, an `asm` — because a dead store reported
    // wrongly is worse than one missed: it sends the reader looking for a bug
    // that is not there.
    void deadStores(Node* b)
        {
        for (u32 i = (u32)0; i + (u32)1 < b.kidCount(); i = i + (u32)1)
            {
            String* name = storedName(b.kid(i));
            if (name == (String*)0)
                continue;
            for (u32 j = i + (u32)1; j < b.kidCount(); j = j + (u32)1)
                {
                Node* nxt = b.kid(j);
                if (namesLocal(nxt, name) && storedName(nxt) == (String*)0)
                    break;
                String* again = storedName(nxt);
                if (again != (String*)0 && again.equals(name))
                    {
                    // The second store's RHS may read the first — `x = x + 1`
                    // is not a dead store, it is an update.
                    if (readsInRhs(nxt, name))
                        break;
                    warnAt(b.kid(i), "this value is never read — it is "
                                     "overwritten before anything uses it");
                    j = b.kidCount();
                    continue;
                    }
                if (opaque(nxt))
                    break;
                }
            }
        }

    // The name a statement STORES to, when it is a simple `<ident> = …` or a
    // declaration with an initialiser; null for anything else.
    String* storedName(Node* st)
        {
        if (st.kind() == (u16)nkVariableDecl)
            return st.kidCount() > (u32)0 ? st.name() : (String*)0;
        if (st.kind() != (u16)nkExprStatement || st.kidCount() == (u32)0)
            return (String*)0;
        Node* e = st.kid((u32)0);
        if (e.kind() != (u16)nkAssign || e.kidCount() < (u32)2)
            return (String*)0;
        Node* lhs = e.kid((u32)0);
        // Only a bare local. A field, a subscript or a deref may alias
        // something this walk cannot see.
        if (lhs.kind() != (u16)nkIdent)
            return (String*)0;
        // A compound assignment (`+=`) READS before it writes.
        if (e.op() != (String*)0 && !e.op().equals(String.withCString("=")))
            return (String*)0;
        return lhs.name();
        }

    bool readsInRhs(Node* st, String* name)
        {
        if (st.kind() == (u16)nkVariableDecl)
            return st.kidCount() > (u32)0 && namesLocal(st.kid((u32)0), name);
        if (st.kidCount() == (u32)0)
            return false;
        Node* e = st.kid((u32)0);
        return e.kidCount() > (u32)1 && namesLocal(e.kid((u32)1), name);
        }

    // Anything that could read or write the local out of sight.
    bool opaque(Node* st)
        {
        u16 k = st.kind();
        return k == (u16)nkBlock || k == (u16)nkIf || k == (u16)nkWhile || k == (u16)nkForCStyle || k == (u16)nkForIn || k == (u16)nkSwitch || k == (u16)nkAsmBlock || k == (u16)nkTry || k == (u16)nkDefer || k == (u16)nkLabel || k == (u16)nkTupleAssign;
        }

    // ── unused local ─────────────────────────────────────────────────────
    //
    // Declared, then never named again anywhere in the enclosing block or
    // below it. Scoped to the block the declaration is in, which is where the
    // language scopes it too.
    //
    // A leading underscore suppresses it: `_unused` is how every language with
    // this warning lets an author say "yes, deliberately", and without an
    // escape hatch the check makes correct code noisy — a tuple unpack that
    // needs only one half, a parameter kept for a signature.
    void unusedLocals(Node* b)
        {
        for (u32 i = (u32)0; i < b.kidCount(); i = i + (u32)1)
            {
            Node* st = b.kid(i);
            if (st.kind() != (u16)nkVariableDecl)
                continue;
            String* nm = st.name();
            if (nm == (String*)0 || nm.byteLength() == (u32)0)
                continue;
            if (nm.byteAt((u32)0) == (u8)'_')
                continue;
            // A static or global local outlives the block and may be read from
            // anywhere; only an ordinary one can be judged here.
            if (st.hasFlag((u32)NF_STATIC) || st.hasFlag((u32)NF_GLOBAL))
                continue;
            bool used = false;
            for (u32 j = i + (u32)1; j < b.kidCount(); j = j + (u32)1)
                if (namesLocal(b.kid(j), nm))
                    used = true;
            // Its own initialiser does not count as a use, but a later
            // declaration shadowing the name would confuse the answer — give
            // up rather than guess.
            for (u32 j = i + (u32)1; j < b.kidCount(); j = j + (u32)1)
                {
                Node* o = b.kid(j);
                if (o.kind() == (u16)nkVariableDecl && o.name() != (String*)0 && o.name().equals(nm))
                    used = true;
                }
            if (!used)
                warnAt(st, "this local is never used — prefix it with '_' if "
                           "that is deliberate");
            }
        }

    // ── always-true / always-false conditions ────────────────────────────
    //
    // A condition that is a bare integer literal, or a comparison of two of
    // them. Not a general const-folder: sema already folds those, and what is
    // left here is what a READER would also see as constant — `if (1)`,
    // `while (0)`, `if (2 > 3)`. A condition folded from named constants is
    // deliberately NOT reported: `if (DEBUG)` is how a build switch is
    // spelled, and warning on it would be noise on correct code.
    // A cast of a literal is still a literal to a reader: `if ((i32)1)` says
    // exactly what `if (1)` says. Sema keeps the cast node, so the check has
    // to see through it or it never fires on real source, which is written
    // with the casts this language requires.
    Node* throughCasts(Node* n)
        {
        Node* c = n;
        u32 guard = (u32)0;
        while (c != (Node*)0 && c.kind() == (u16)nkCast && c.kidCount() > (u32)0 && guard < (u32)8)
            {
            c = c.kid((u32)0);
            guard = guard + (u32)1;
            }
        return c;
        }

    void checkCondition(Node* condIn, Node* at)
        {
        Node* cond = throughCasts(condIn);
        if (cond == (Node*)0)
            return;
        if (cond.kind() == (u16)nkInt)
            {
            warnAt(at, cond.num() != (i64)0
                           ? "this condition is always true"
                           : "this condition is always false");
            return;
            }
        if (cond.kind() != (u16)nkBinary || cond.kidCount() < (u32)2)
            return;
        Node* l = throughCasts(cond.kid((u32)0));
        Node* r = throughCasts(cond.kid((u32)1));
        if (l == (Node*)0 || r == (Node*)0)
            return;
        if (l.kind() != (u16)nkInt || r.kind() != (u16)nkInt)
            return;
        String* op = cond.op();
        if (op == (String*)0)
            return;
        i64 a = l.num();
        i64 b = r.num();
        bool known = true;
        bool val = false;
        if (op.equals(String.withCString("<")))
            val = a < b;
        else if (op.equals(String.withCString(">")))
            val = a > b;
        else if (op.equals(String.withCString("<=")))
            val = a <= b;
        else if (op.equals(String.withCString(">=")))
            val = a >= b;
        else if (op.equals(String.withCString("==")))
            val = a == b;
        else if (op.equals(String.withCString("!=")))
            val = a != b;
        else
            known = false;
        if (!known)
            return;
        warnAt(at, val ? "this condition is always true"
                       : "this condition is always false");
        }

    bool namesLocal(Node* n, String* name)
        {
        if (n == (Node*)0)
            return false;
        if (n.kind() == (u16)nkIdent && n.name() != (String*)0 && n.name().equals(name))
            return true;
        for (u32 i = (u32)0; i < n.kidCount(); i = i + (u32)1)
            if (namesLocal(n.kid(i), name))
                return true;
        return false;
        }
    }
