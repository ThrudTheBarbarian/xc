// banked_call.xc — bank-switched function calls. On xt6502 the call to
// helper() may go through the cross-bank trampoline; print the result so
// the call's return value is actually proven (not just "doesn't crash").
#import "Stdio.xc"

u8 helper(u8 x)
{
    return x + 1;
}

void main(void)
{
    u8 result = helper($59);   // $59 + 1 = $5A (90)
    Stdio.printf("%d\n", (u16)result);
    return;
}
