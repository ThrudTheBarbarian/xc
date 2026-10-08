//xtc-flags: expect=sema-error
// nil_not_compared.xc — `nil` takes part in `==` and `!=` against a pointer,
// and in nothing else.
//
// `nil + 1` and `nil < p` are "nil is a pointer: it is only compared, with ==
// or !="; `n == nil` with a u32 `n` is "nil is a pointer: it cannot be
// compared with a 'u32'". The literal 0 would be accepted in all three.

#import "Stdio.xc"

void main(void)
{
    u32 n = (u32)1;
    u32* p = &n;
    u32 m = nil + (u32)1;       // error: arithmetic on nil
    bool lt = nil < p;          // error: an ordering against nil
    bool eq = n == nil;         // error: a u32 compared with nil
    Stdio.printf("%u %d %d\n", m, (i32)lt, (i32)eq);
}
