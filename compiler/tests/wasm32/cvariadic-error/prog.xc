// A C-variadic import on wasm32 must be a HARD ERROR (task #34): the import
// type was derived from the first call site, so a second arity emitted
// invalid wasm (fallthru stack imbalance, caught only at instantiation) —
// and no C library exists on wasm32 to satisfy the import anyway.
i32 printf(string fmt, ...);

i32 main(void)
    {
    i32 i;
    printf("first\n");
    for (i = 0; i < 200; i = i + 1)
        {
        printf("line %d\n", i);
        }
    printf("last\n");
    return 0;
    }
