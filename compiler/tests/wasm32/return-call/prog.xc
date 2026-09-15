// return-call guard (TODO-wasm.md W5): mutual recursion 1,000,000 deep.
// With -x-wasm32,return-call the calls fuse into `return_call` and the
// depth is O(1); without it both the engine stack and the shadow stack
// blow long before a million frames. run.sh asserts BOTH behaviours,
// plus byte-identity of oracle and selfhost port with the option on.
#use Stdio

u32 odd(u32 n)
    {
    if (n == (u32)0)
        return (u32)0;
    return even(n - (u32)1);
    }
u32 even(u32 n)
    {
    if (n == (u32)0)
        return (u32)1;
    return odd(n - (u32)1);
    }

void main()
    {
    printf("e=%lu o=%lu\n", even((u32)1000000), odd((u32)999999));
    }
