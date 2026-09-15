// cross_module_callee.xc — module compiled with `xtc -a` to emit
// intermediate `.asm` plus an inline xtc-manifest block. Paired with
// cross_module_caller.xc, which forward-declares these functions and
// links the `.asm` in via `xtc caller.xc callee.asm -o out.xex`. The
// manifest block lets the caller's sema see imported frame_size /
// is_recursive / address_taken attributes instead of treating the
// labels as undecorated externs.
//
// Three shapes covered:
//   plainAddFive  — leaf, static-frame eligible.
//   tailChain     — non-recursive DAG caller of plainAddFive.
//   recurSum      — direct self-recursion, must land in the manifest
//                   with is_recursive = true so the caller doesn't
//                   optimistically treat it as eligible.
// No `main()`: the caller owns program entry. Skipped as a standalone
// corpus sweep — it has no entry point and is exercised only as the
// `//xtc-link:` companion of cross_module_caller.
//xtc-flags: skip

u8 plainAddFive(u8 x)
{
    return x + 5;
}

u8 tailChain(u8 x)
{
    return plainAddFive(x) + 1;
}

u16 recurSum(u8 n)
{
    if (n == 0) { return (u16)0; }
    return (u16)n + recurSum(n - 1);
}
