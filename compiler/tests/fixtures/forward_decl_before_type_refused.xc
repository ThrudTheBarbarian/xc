//xtc-flags: expect=sema-error
// A function declared ABOVE its parameter's type: at that line `MTerr` is not
// a type yet, so `MTerr*` reads as an opaque `void*`, and the definition below
// the type then looks like a second signature. The diagnosis is the
// declaration order, not "Cannot overload ... an external C function".
// Refused: 'palTerrIndex' is declared at ... taking 'void*' where this takes 'MTerr*'
#import "Stdio.xc"

i32 palTerrIndex(MTerr* t);
typedef struct { i32 idx; } MTerr;
i32 palTerrIndex(MTerr* t) { return t.idx; }

i32 main(void)
{
    MTerr m;
    m.idx = 3;
    Stdio.printf("%d\n", palTerrIndex(&m));
    return 0;
}
