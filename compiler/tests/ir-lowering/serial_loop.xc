// serial_loop.xc — a loop marked `: serial` is named in its function's
// `serial: [...]` line, so no pass after lowering makes it parallel (#727).
u32 a[64];
i32 main(void)
{
    u32 s = 0;
    for (u32 i = 0; i < 64; i++) : serial
        a[i] = i * 3;
    for (u32 i = 0; i < 64; i++)
        s = s + a[i];
    return (i32)(s & 255);
}
