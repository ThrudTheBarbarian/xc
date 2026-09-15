// collection_unbox_contexts.xc — reading a PRIMITIVE element out of a typed
// collection must give the element type in EVERY context, not just the four
// that happened to have an unbox site. Guard for private:docs/bugs/046: declaration,
// assignment, call argument, arithmetic, comparison, vararg and ternary all
// have to agree, or the three that were missing silently yield the box —
// a pointer-shaped integer, and in the comparison's case a plausible `false`.
//
// Split into per-context functions rather than one main: xt6502 has a
// 119-byte SP frame budget and the seven contexts together overflow it.
#import "Foundation.xc"
#import "Stdio.xc"

i32 twice(i32 v) { return v + v; }

Array<i32>* ints(void)
{
    Array<i32>* a = new Array();
    a.add((i32)70);
    a.add((i32)5);
    return a;
}

void assignmentContexts(void)
{
    Array<i32>* a = ints();
    u16 i = (u16)0;
    i32 d = a.get(i);              // declaration — worked before 046
    i32 e;
    e = a.get(i);                  // assignment  — worked before 046
    Stdio.printf("decl=%ld asgn=%ld arg=%ld\n", d, e, twice(a.get(i)));
}

void expressionContexts(void)
{
    Array<i32>* a = ints();
    u16 i = (u16)0;
    // Arithmetic. Before 046 this added to the Number POINTER.
    i32 sum = a.get(i) + a.get((u16)1);
    // Comparison. Before 046 this compared a pointer against 70 and said no,
    // which is the dangerous one — a wrong ANSWER, not an obviously wrong
    // number.
    u16 eq = a.get(i) == (i32)70 ? (u16)1 : (u16)0;
    Stdio.printf("arith=%ld cmp=%d\n", sum, eq);
}

void varargAndTernary(void)
{
    Array<i32>* a = ints();
    u16 i = (u16)0;
    bool pick = true;
    bool nope = false;
    // Vararg slot: no parameter type to key an unbox off, so the element type
    // has to decide on its own.
    Stdio.printf("vararg=%ld\n", a.get(i));
    // Ternary arms, both orders.
    Stdio.printf("tern=%ld tern2=%ld\n",
                 pick ? a.get(i) : (i32)0,
                 nope ? (i32)0 : a.get(i));
}

void widthsAgree(void)
{
    // A narrower element must come back at ITS width, not the box's — and the
    // CAST is its own context: `(u16)b.get(0)` converts the VALUE, which means
    // unboxing before the conversion rather than narrowing a pointer.
    Array<u8>* b = new Array();
    b.add((u8)222);
    u16 v = (u16)b.get((u16)0);
    Stdio.printf("u8elem=%d sum=%d\n", v, (u16)(v + (u16)1));
}

i32 main(void)
{
    assignmentContexts();
    expressionContexts();
    varargAndTernary();
    widthsAgree();
    return 0;
}
