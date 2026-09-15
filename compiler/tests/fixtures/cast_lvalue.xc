// cast_lvalue.xc — a cast expression as an assignment target.
//
//     ((S@)p).a = 7;      →  error: Expected 'identifier' but found ')'
//     ( (S@)p ).a = 7;    →  fine
//
// `((` is a single token: it is this language's alternative BLOCK opener. So a statement
// beginning `((S@)p)...` was read as "open a block" and died on the cast's closing paren.
// A space made it work, which is a miserable thing to have to know.
//
// One token of lookahead settles it. A block that begins with a declaration reads
// `(( i16 x = 1; ))` — a type followed by an IDENTIFIER. A cast reads `((S@)p)` — a type
// followed by `@` or `)`. The two cannot be confused, so `((` opens a block unless what
// follows is a cast.
//
// Both forms are exercised below, in the same function.

#import "Stdio.xc"

struct S { i16 a; i16 b; }

i16 main(void)
{
    S s;  s.a = (i16)1;  s.b = (i16)2;
    pointer p = (pointer)&s;

    ((S*)p).a = (i16)7;                    // cast as an LVALUE, at statement start
    ((S*)p).b = ((S*)p).a + (i16)3;        // and on the RHS of one
    Stdio.printf("cast=%d %d\n", s.a, s.b);              // 7 10

    { i16 x = (i16)5;                     // a genuine (( )) block still parses
       Stdio.printf("block=%d\n", x); }
    return 0;
}
