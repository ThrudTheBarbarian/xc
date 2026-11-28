// TensorPar.xc — what the kernels of tensor expressions run on.
//
// The compiler turns each tensor expression (`a * b + c`, `t[.., ..] = x`,
// `t += u`) into one kernel: a function that works out the broadcast shape,
// and a block of the kind a CPU `par` block becomes, which computes every
// element of the result from the operands in one pass. This file holds what
// those kernels share: the shape checks and the run over the CPU's threads.
// The compiler imports it, with Par.xc, into a unit that has a tensor
// expression.

#if ARCH_m68k
// The par runtime is not built for the Atari, which has no threads: a kernel's
// block is run on the calling thread, and this is all of ParChunk it uses.
class ParChunk : Object
{
    i64 lo;
    i64 hi;

    void run(void)
    {
    }
    ParChunk* copyChunk(void)
    {
        return (ParChunk*)0;
    }
    u8* gpuSource(void)
    {
        return "";
    }
    u8* parName(void)
    {
        return "par";
    }
}
#else
#import "Par.xc"
#endif

// A result dimension `k` of size `n` meets an operand's dimension of size `d`:
// the size they broadcast to. Each must be the other or 1.
u64 _xt_tensor_bdim(u64 n, u64 d, u64 k)
{
    if (d == n || d == 1)
        return n;
    if (n == 1)
        return d;
    _xt_tensor_put("\n=== xcc: tensor shapes that do not broadcast ===\n  dimension ");
    _xt_tensor_putNum(k);
    _xt_tensor_put(" of the result: sizes ");
    _xt_tensor_putNum(n);
    _xt_tensor_put(" and ");
    _xt_tensor_putNum(d);
    _xt_tensor_put("; each must be the same, or 1\n");
    _xt_tensor_stop();
    return n;
}

// An operand's dimension of size `d` written into dimension `k` of a
// destination, of size `n`: it must be n, or 1 and repeat.
void _xt_tensor_bset(u64 n, u64 d, u64 k)
{
    if (d == n || d == 1)
        return;
    _xt_tensor_put("\n=== xcc: a tensor that does not fit its destination ===\n  dimension ");
    _xt_tensor_putNum(k);
    _xt_tensor_put(": size ");
    _xt_tensor_putNum(d);
    _xt_tensor_put(" into size ");
    _xt_tensor_putNum(n);
    _xt_tensor_put("; it must be the same, or 1\n");
    _xt_tensor_stop();
}

// Run a kernel's block over its `items` work items (rows, or elements when
// every operand is contiguous), `total` elements in all. A small kernel, one
// that must run in order, and one started while another block runs (a tensor
// expression inside a par block) run on the calling thread; the others on
// the CPU's threads, as a CPU par block does.
void _xt_tensor_run(ParChunk* c, i64 items, u64 total, bool serial)
{
#if ARCH_6502 || ARCH_m68k || ARCH_wasm32
    c.lo = 0;
    c.hi = items;
    c.run();
#else
    if (serial || total < 32768)
        {
        c.lo = 0;
        c.hi = items;
        c.run();
        return;
        }
    Par.runCpuShared(c, 0, items);
#endif
}
