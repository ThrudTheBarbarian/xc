// Two overloads that each convert one argument better than the other: no
// candidate is at least as good on every argument, so the call is still
// ambiguous (#643), and says so rather than "no overload matches".
// xtc: error "is ambiguous among 2 overloads"
#import "Stdio.xc"
void g(u32 a, u64 b) { Stdio.printf("1\n"); }
void g(u64 a, u32 b) { Stdio.printf("2\n"); }
i32 main(void)
{
    u16 x = (u16)1;
    g(x, x);
    return 0;
}
