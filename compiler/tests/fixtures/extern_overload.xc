//xtc-flags: target=arm64, expect=sema-error
// A DIFFERENT-signature overload of a body-less (external C) function is
// refused with a diagnosis (blewit spike, item 1). Overloading mangles every
// member of the set — including the C symbol — so this used to fail at LINK
// as `undefined symbol: write__i32_p_u64`, baffling and far from the cause.
// A C symbol has exactly one signature; sema now says so at the declaration.
i32 ext_fn(i32 v);

i32 ext_fn(u64 v) { return (i32)v; }

i32 main(void)
{
    return ext_fn((i32)0);
}
