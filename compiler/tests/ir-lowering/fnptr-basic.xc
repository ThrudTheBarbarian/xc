// fnptr-basic — minimal function-pointer round-trip, executed.
// `&addOne` takes the function's address (AddrOf of the function
// symbol); `fp(x)` dispatches indirectly through it (CallIndirect →
// the backend's indirect-jump trampoline). callit() returns 6.
typedef u8 op_t(u8);

u8 addOne(u8 x)
    {
    return x + (u8)1;
    }

u8 callit(void)
    {
    op_t* fp = &addOne;
    return fp((u8)5);
    }
