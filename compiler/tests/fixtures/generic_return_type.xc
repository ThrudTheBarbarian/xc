//xtc-flags: target=arm64
// `Array<T>*` as a RETURN type (XG bug 023).
//
// It parsed as a field, a parameter and a local, but a method or function
// RETURNING one was a parse error — the function-vs-variable lookahead
// consumed a type name and its pointer sigils but stopped at `<`, so
// `Array<String>* give(void)` was judged "not a function declaration" and the
// field-decl path then choked on the parameter list. The diagnostic pointed at
// `(void)`, which is what made it read as an argument-list problem.
//
// The cases below are every position that shares that lookahead: a method, a
// free function, a protocol signature, a NESTED argument list closing with
// `>>` (one shift token, two levels), and a for-in whose loop variable is a
// typed collection. The printf lines prove the element type PROPAGATES through
// the returned value — `.length()` / `.cString()` on the element with no cast
// is exactly what an untyped `Array*` return could not offer.
#import "Foundation.xc"
#import "Stdio.xc"

protocol RowSource
{
    Array<String>* rows(void);
}

class Grid : Object <RowSource>
{
    Array<Array<String>>* cells;

    void init(void)
    {
        cells = new Array();
        Array<String>* row = new Array();
        row.add(String.withCString("hello"));
        cells.add(row);
    }

    // The original repro: a generic METHOD return type.
    Array<String>* give(void)
    {
        return cells.get((u32)0);
    }

    // Nested arguments in return position: `>>` closes two levels at once.
    Array<Array<String>>* grid(void)
    {
        return cells;
    }

    // Declared through the protocol above — that signature parses too.
    Array<String>* rows(void)
    {
        return cells.get((u32)0);
    }
}

// A FREE function returning one, through the same lookahead at top level.
Array<String>* firstRow(Grid* g)
{
    return g.give();
}

i32 main(void)
{
    Grid* g = new Grid();

    // The element type survives the return: String methods, no cast.
    String* s = g.give().get((u32)0);
    Stdio.printf("method len=%d\n", (u16)s.byteLength());
    Stdio.printf("free   %s\n", firstRow(g).get((u32)0).cString());
    Stdio.printf("proto  %s\n", g.rows().get((u32)0).cString());

    // And a for-in whose loop VARIABLE is a typed collection, over the
    // nested CALL result directly — the for-in detector shares the fixed
    // lookahead, and a call as the subject is also the private:docs/bugs/057 guard:
    // the +1 subject temp is adopted as a hidden strong local and released
    // exactly once (the original used to leak it, the port released it
    // every iteration).
    for (Array<String>* row in g.grid())
    {
        Stdio.printf("for-in %s\n", row.get((u32)0).cString());
    }
    return 0;
}
