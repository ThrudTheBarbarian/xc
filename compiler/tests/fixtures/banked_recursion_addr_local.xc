// banked_recursion_addr_local.xc — #444: a function whose only calls are
// :banked or :cloaked calls still calls out. The xt6502 back end's leaf test
// and its call save sets counted Call, CallIndirect and VTblDispatch only, so
// a recursive :banked method (each call a CallBanked) was taken for a leaf:
// its address-taken local, a run-time-indexed array, got a static slot, and
// the recursion overwrote it (fib printed 88 for 364). The plain method was
// right all along; it is here as the control.

#import "Stdio.xc"

u16 cfib(u16 n, u16 k) :cloaked
{
    u16 buf[2];
    buf[k & (u16)1] = n;
    buf[(k + (u16)1) & (u16)1] = n + (u16)100;
    if (n < (u16)2) return n;
    u16 a = cfib(n - (u16)1, k + (u16)1);
    u16 b = cfib(n - (u16)2, k);
    return a + b + buf[k & (u16)1];
}

class Walker
{
    u16 depth;

    u16 fib(u16 n, u16 k) :banked
    {
        u16 buf[2];
        buf[k & (u16)1] = n;
        buf[(k + (u16)1) & (u16)1] = n + (u16)100;
        if (n < (u16)2) return n;
        u16 a = self.fib(n - (u16)1, k + (u16)1);
        u16 b = self.fib(n - (u16)2, k);
        return a + b + buf[k & (u16)1];
    }

    u16 cloakedFib(u16 n, u16 k) :cloaked
    {
        u16 buf[2];
        buf[k & (u16)1] = n;
        buf[(k + (u16)1) & (u16)1] = n + (u16)100;
        if (n < (u16)2) return n;
        u16 a = self.cloakedFib(n - (u16)1, k + (u16)1);
        u16 b = self.cloakedFib(n - (u16)2, k);
        return a + b + buf[k & (u16)1];
    }

    u16 plain(u16 n, u16 k)
    {
        u16 buf[2];
        buf[k & (u16)1] = n;
        buf[(k + (u16)1) & (u16)1] = n + (u16)100;
        if (n < (u16)2) return n;
        u16 a = self.plain(n - (u16)1, k + (u16)1);
        u16 b = self.plain(n - (u16)2, k);
        return a + b + buf[k & (u16)1];
    }
}

i32 main(void)
{
    Walker* w = new Walker();
    Stdio.printf("banked %u\n", (u32)w.fib((u16)10, (u16)0));
    Stdio.printf("cloaked method %u\n", (u32)w.cloakedFib((u16)10, (u16)0));
    Stdio.printf("cloaked %u\n", (u32)cfib((u16)10, (u16)0));
    Stdio.printf("plain %u\n", (u32)w.plain((u16)10, (u16)0));
    return 0;
}
