// variadic_calls_printf.xc — bug 175. A DEFINED variadic that consumes its own
// pack with va_arg and then calls printf (a bodiless C-variadic prototype) must
// compile. The reentrance guard wrongly counted a bodiless prototype as a
// pack-buffer clobberer, rejecting the ubiquitous `void log(fmt, ...) { …;
// printf(fmt, a, b); }` even though the va_list is fully consumed into locals
// before printf runs and printf reads the C ABI, not the shared buffer.
i32 printf(u8* f, ...);

void logmsg(u8* tag, ...)
{
    u8 ap; va_start(ap);
    i32 a = va_arg(ap, i32);
    i32 b = va_arg(ap, i32);
    va_end(ap);
    printf("%s %d %d\n", tag, a, b);
}

i32 main(void)
{
    logmsg(&("one")[0], 1, 2);
    logmsg(&("two")[0], 30, 40);
    return (i32)0;
}
