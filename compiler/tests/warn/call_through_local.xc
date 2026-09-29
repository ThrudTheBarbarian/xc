// A local that is only called — a function pointer read by `f()` — is used.
#use Stdio

typedef i32 op_t(i32);

i32 twice(i32 v)
    {
    return v + v;
    }

i32 main(void)
    {
    op_t* f = &twice;
    Stdio.printf("%ld\n", f(21));
    return 0;
    }
