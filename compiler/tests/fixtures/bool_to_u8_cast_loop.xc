// `(u8)flag` of a bool is its byte, 0 or 1, in a loop as anywhere: the two
// compilers write the same code for it (#775; the reference added a uxtb on
// arm64). The output was always right; the assembly comparison is what this
// fixture is for.
#import "Stdio.xc"
class K
{
    u8* rb_; u64 ro_; bool* tb_; bool flat_; i64 lo; i64 hi;
    void run(void)
    {
        u8* p = rb_ + ro_;
        bool* tb = tb_;
        for (i64 i = lo; i < hi; i++)
            p[i] = ((u8)(tb[i]));
    }
}
i32 main(void)
{
    K* k = new K(); u8 a[8]; bool b[8]; b[3] = true;
    k.rb_ = &a[0]; k.tb_ = &b[0]; k.lo = 0; k.hi = 8; k.run();
    Stdio.printf("%d\n", a[3]);
    return 0;
}
