// cloaked_varargs.xc — exercises the now-permitted :cloaked + varargs
// combination. Pre-fix sema rejected this categorically with the
// reasoning that "va_args pop from the hidden xtc stack." Post-fix
// the rejection is gone: va_arg_* lowers to direct reads from
// XT_PRINTF_DATA_BUF (a fixed buffer in main RAM, always visible
// regardless of PORTB), va_start is a cursor init, va_end is a
// no-op — nothing in the variadic ABI touches the xtc stack.
//
// The function below sums an arbitrary number of u16s. The cloaked
// bracket at the call site sets PORTB=$32 (banking off, library bank
// at $4000-$7FFF visible in main RAM), JSRs the function, then
// restores PORTB. Inside, va_start seeds the cursor past the 0-byte
// header, four va_arg_u16 calls read the four packed values back, and
// va_end is the no-op tail.
//
// Result: 10 + 20 + 30 + 40 = 100. Print "DONE 100" via Stdio.

#use Stdio

class Test
{
    static u16 sumU16s(u8 count, ...) : cloaked
    {
        u8  ap;
        u16 total = 0;
        u8  i;
        va_start(ap);
        for (i = 0; i < count; i = i + 1) {
            total = total + va_arg_u16(ap);
        }
        va_end(ap);
        return total;
    }
}

void main(void)
{
    u16 t = Test.sumU16s((u8)4, (u16)10, (u16)20, (u16)30, (u16)40);
    Stdio.printf("DONE %u\n", t);
}
