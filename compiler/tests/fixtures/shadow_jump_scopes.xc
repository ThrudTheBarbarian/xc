// A jump out of scopes where an inner local shadows an outer one of the
// same name. The lowering's bindings are by name, so `continue`, `break` and
// `return` used to carry the INNER value as the outer variable's: the loop
// header phi took an integer for a Data*, and the release at the end of the
// iteration then released the integer (EXC_BAD_ACCESS).

#import <Data.xc>
use Stdio;

u32 gDeallocs;

class Tracked
{
    u32 tag;
    void dealloc(void) { gDeallocs = gDeallocs + (u32)1; }
}

// continue from inside the inner shadow
i64 viaContinue(void)
{
    i64 total = (i64)0;
    for (u32 r = (u32)0; r < (u32)3; r = r + (u32)1)
        {
        Data* need = new Data();
        need.appendByte((u8)7);
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            {
            i64 need = (i64)5000000;
            if (i < (u32)3)
                continue;
            total = total + need;
            }
        total = total + (i64)need.length();
        }
    return total;
}

// break from inside the inner shadow
u32 viaBreak(void)
{
    Data* need = new Data();
    need.appendByte((u8)1);
    need.appendByte((u8)2);
    for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
        {
        u32 need = (u32)99;
        if (need > (u32)0)
            break;
        }
    return need.length();
}

// continue leaving TWO scopes, each with a `t`: the outer object must be
// released, the inner integer must not be
void viaTwoFrames(void)
{
    for (u32 i = (u32)0; i < (u32)3; i = i + (u32)1)
        {
        Tracked* t = new Tracked();
        t.tag = i;
            {
            u32 t = (u32)5;
            if (t == (u32)5)
                continue;
            }
        }
}

// return from inside the shadow: the outer object goes, the inner value is returned
u32 viaReturn(void)
{
    Tracked* t = new Tracked();
    t.tag = (u32)1;
        {
        u32 t = (u32)42;
        return t;
        }
}

// the C-style increment runs against the loop's own counter, not a shadow
u32 viaIncrement(void)
{
    u32 n = (u32)0;
    for (u32 i = (u32)0; i < (u32)3; i = i + (u32)1)
        {
        n = n + (u32)1;
            {
            u32 i = (u32)100;
            if (i == (u32)100)
                continue;
            }
        }
    return n;
}

void main(void)
{
    printf("continue %ld\n", viaContinue());
    printf("break %u\n", viaBreak());
    gDeallocs = (u32)0;
    viaTwoFrames();
    printf("two frames deallocs %u\n", gDeallocs);
    gDeallocs = (u32)0;
    u32 r = viaReturn();
    printf("return %u deallocs %u\n", r, gDeallocs);
    printf("increment %u\n", viaIncrement());
}
