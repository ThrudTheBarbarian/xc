// A variadic method called through the vtable gets its variadic arguments
// where its va_start reads them, whether it reads them itself (sum) or
// forwards them with '...' (say). On arm64 they were left in registers.
#use Stdio
class A
    {
    i32 pad;
    String* say(string fmt, ...)
        {
        String* s = String.withCString((u8*)"A:");
        s.appendFormat(fmt, ...);
        return s;
        }
    u32 sum(u32 n, ...)
        {
        u8 ap;
        va_start(ap);
        u32 t = (u32)0;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            t = t + va_arg_u32(ap);
        return t;
        }
    }
class B : A
    {
    String* say(string fmt, ...)
        {
        String* s = String.withCString((u8*)"B:");
        s.appendFormat(fmt, ...);
        return s;
        }
    u32 sum(u32 n, ...)
        {
        u8 ap;
        va_start(ap);
        u32 t = (u32)1000;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            t = t + va_arg_u32(ap);
        return t;
        }
    }
i32 main(void)
    {
    A* a = new A();
    A* b = new B();
    Stdio.printf("%s\n", a.say("%lu %lu", (u32)11, (u32)22).cString());
    Stdio.printf("%s\n", b.say("%lu %lu", (u32)33, (u32)44).cString());
    Stdio.printf("%lu %lu\n", a.sum((u32)2, (u32)5, (u32)6), b.sum((u32)2, (u32)5, (u32)6));
    return 0;
    }
