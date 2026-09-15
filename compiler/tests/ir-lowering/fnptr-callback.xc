// fnptr-callback — function pointer passed as a parameter (the classic
// callback shape), executed end-to-end. applyU8 receives `&addOne` as a
// `op_t@` argument and dispatches through it. callcb() → addOne(100) =
// 101. A single call chain (no value held across a call) so it isn't
// perturbed by the separate ZP caller-save gap (see KNOWN-ISSUES).
typedef u8 op_t(u8);

u8 addOne(u8 x)
    {
    return x + (u8)1;
    }

u8 applyU8(op_t* fn, u8 x)
    {
    return fn(x);
    }

u8 callcb(void)
    {
    return applyU8(&addOne, (u8)100);
    }
