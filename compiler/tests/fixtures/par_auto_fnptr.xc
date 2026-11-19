//xtc-flags: target=arm64 --par-style=auto
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_auto_fnptr.xc — with --par-style=auto, a loop that calls a function
// pointer it was given (a parameter or a local) builds and gives the loop's
// answer (#437). The block captures the pointer like any other name its body
// reads; the call with the loop counter and the call with a literal each
// failed to build, with the call's name undeclared in the block.
#import "Stdio.xc"
typedef i32 f_t(i32);
i32 id(i32 x) { return x; }
i32 twice(i32 x) { return x + x; }
i32 run(f_t* cb)
    {
    i32 acc = 0;
    for (i32 i = 0; i < 3; i = i + 1)
        {
        acc = acc + cb(i);
        }
    return acc;
    }
i32 runLiteral(f_t* cb, i32 n)
    {
    i32 acc = 0;
    for (i32 i = 0; i < n; i = i + 1)
        {
        acc = acc + cb(5);
        }
    return acc;
    }
i64 runLocal(i32 n)
    {
    f_t* f = &twice;
    i64 acc = 0;
    for (i32 i = 0; i < n; i = i + 1)
        acc += f(i);
    return acc;
    }
i32 main(void)
    {
    Stdio.printf("%d\n", run(&id));
    Stdio.printf("%d %lld\n", runLiteral(&id, 100000), runLocal(200000));
    return 0;
    }
