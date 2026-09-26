//xtc-na: xt6502 — prints through the C printf (a bodiless `...` prototype), and xt6502 has no C library to call
// variadic_forwarding.xc — bug 179. A `...`-forwarding variadic function must
// re-pass its incoming pack to the callee. On arm64 (native AAPCS va_list, no
// shared buffer) the forwarder relays its incoming tail into the callee's
// outgoing slots. Covers direct, single-forward, and double-forward, with a
// mix of i32 / double / string (each an 8-byte va_list slot).
i32 printf(u8* f, ...);

void take(u8* tag, ...)
{
    u8 ap; va_start(ap);
    i32 a = va_arg(ap, i32);
    double d = va_arg(ap, double);
    u8* s = va_arg(ap, u8*);
    va_end(ap);
    printf("%s %d %.1f %s\n", tag, a, d, s);
}

void fwd(u8* tag, ...)  { take(tag, ...); }        // single forward
void fwd2(u8* tag, ...) { u8 buf[8]; fwd(tag, ...); }  // double forward

i32 main(void)
{
    take(&("direct")[0], (i32)1, 2.5d, &("a")[0]);
    fwd(&("fwd")[0], (i32)3, 4.5d, &("b")[0]);
    fwd2(&("fwd2")[0], (i32)5, 6.5d, &("c")[0]);
    return (i32)0;
}
