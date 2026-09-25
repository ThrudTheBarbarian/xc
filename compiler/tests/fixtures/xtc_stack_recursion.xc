//xtc-flags: --xtc-stack
// xtc_stack_recursion.xc — recursion under --xtc-stack on xt6502, where every
// function keeps its return address and saved registers in a software-stack
// frame. Each call below leaves a frame on the software stack while it
// recurses, so a return address restored from the wrong frame, or a frame
// popped twice, shows up as a wrong result or a crash. On the other targets
// the flag changes nothing and the program is a plain recursion test.
#import "Stdio.xc"

i32 fib(i32 n)
{
    if (n < 2)
        return n;
    return fib(n - 1) + fib(n - 2);
}

u16 ack(u16 m, u16 n)
{
    if (m == 0)
        return n + 1;
    if (n == 0)
        return ack(m - 1, 1);
    return ack(m - 1, ack(m, n - 1));
}

// A local whose address is taken lives in the software-stack frame in a
// function that calls; it must survive the recursive call below it.
i32 sumDown(i32 n)
{
    i32 cell[2];
    cell[0] = n;
    cell[1] = n * 3;
    if (n == 0)
        return 0;
    i32 rest = sumDown(n - 1);
    return cell[0] + cell[1] + rest;
}

// Four parameters and a result that is not a scalar byte: the arguments are
// read from the hardware stack past the frame's locals.
i32 mix(i32 a, u8 b, u16 c, i32 d)
{
    if (a <= 0)
        return (i32)b + (i32)c + d;
    return mix(a - 1, b + 1, c + 2, d + a);
}

// :hwStack opts one function out of --xtc-stack; calls in both directions
// between the two conventions must still balance.
i32 hwLeaf(i32 v) :hwStack
{
    return v + 100;
}

i32 hwCaller(i32 v) :hwStack
{
    if (v == 0)
        return hwLeaf(0);
    return fib(v) + hwCaller(v - 1);
}

class Counter
{
    i32 total;

    void init(void)
    {
        total = 0;
    }

    i32 addUpTo(i32 n)
    {
        if (n == 0)
            return total;
        total = total + n;
        return addUpTo(n - 1);
    }
}

i32 main(void)
{
    Stdio.printf("fib(15) = %d\n", fib(15));
    Stdio.printf("ack(2,3) = %d\n", (i32)ack(2, 3));
    Stdio.printf("sumDown(10) = %d\n", sumDown(10));
    Stdio.printf("mix(6,1,2,3) = %d\n", mix(6, 1, 2, 3));
    Stdio.printf("hwCaller(5) = %d\n", hwCaller(5));
    Counter* c = new Counter();
    Stdio.printf("addUpTo(12) = %d\n", c.addUpTo(12));
    return 0;
}
