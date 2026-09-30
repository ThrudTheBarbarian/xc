//xtc-na: xt6502 — i64 formatting needs ENABLE_64BIT there, and its formatter ignores a precision
// format_wrapper.xc — a variadic that hands its format and `...` on to a
// format function is itself one: its callers' arguments are promoted and a
// literal format's lengths fitted, exactly as for String.withFormat.
#import "Foundation.xc"
#import "Stdio.xc"

class Out
{
    String* _s;
    void init(void) { _s = String.withCString(""); }
    void say(string fmt, ...) { _s.appendFormat(fmt, ...); }
    String* text(void) { return _s; }
}

String* early(void)
{
    u8 b = (u8)200;
    return fmt("early %d %c", b, (u8)65);
}

String* fmt(string f, ...)
{
    return String.withFormat(f, ...);
}

i32 main(void)
{
    u8 b = (u8)7;
    i16 h = (i16)-300;
    float f = 2.5;
    i64 big = (i64)-5000000000;
    Out* o = new Out();
    o.say("%d %d %f %d|", b, h, f, big);
    o.say("%x %lld", (u16)255, (u32)9);
    Stdio.printf("%@\n", o.text());
    Stdio.printf("%@\n", fmt("%u %.2f %s", b, f, "ok"));
    Stdio.printf("%@\n", early());
    return 0;
}
