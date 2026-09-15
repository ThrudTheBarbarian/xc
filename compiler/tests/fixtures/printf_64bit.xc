// printf_64bit.xc — `%lld` / `%llu`, and the auto-widening that makes `%d`
// work on a 64-bit argument.
//
// Before this, `%lld` parsed as `%l` followed by a stray `d`: printf emitted
// the literal character, consumed NO argument, and every following argument
// shifted by one. So the trailing `%d` below is the real assertion — it proves
// the 64-bit conversion consumed exactly one slot.
//
// Making it work needed three things that had to agree: the `va_arg_i64` /
// `va_arg_u64` intrinsics (the 8-byte vararg slot already existed for
// `%lf`), the Stdio format arm that calls them, and — the one that was easy to
// miss — the sema switch mapping the intrinsic's type KIND back to a type. The
// name table alone left `va_arg_i64` typed u8, so `%lld` printed 0 while
// consuming the right number of bytes.
#import "Stdio.xc"

i32 main(void)
{
    i64 big = (i64)1099511627776;        // 2^40 — invisible to a 32-bit slot
    i64 neg = (i64)0 - (i64)1099511627776;
    u64 max = (u64)18446744073709551615; // every bit set

    Stdio.printf("lld %lld then %d\n", big, (i16)7);
    Stdio.printf("neg %lld then %d\n", neg, (i16)7);
    Stdio.printf("llu %llu then %d\n", max, (i16)7);

    // Type-directed widening: a 64-bit argument upgrades `%d` to `%lld` and
    // `%ld` to `%lld`, exactly as a 32-bit argument already upgraded `%d` to
    // `%ld`. All three spellings must print the same number.
    Stdio.printf("auto %d %ld %lld\n", big, big, big);

    // The narrower widths must be untouched by any of this.
    Stdio.printf("narrow %d %ld %u\n", (i16)-5, (i32)-100000, (u16)40000);
    return 0;
}
