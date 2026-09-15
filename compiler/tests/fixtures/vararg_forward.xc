// vararg_forward.xc — `f(fmt, ...)` forwards the enclosing variadic's tail.
//
//
// This is not a copy. On every target but arm9 a variadic's arguments are
// packed by the CALLER into a shared buffer, so a function that takes `...` and
// never repacks leaves them there and whatever it calls reads the ORIGINAL
// caller's. Forwarding is the ABSENCE of a repack — which is why it already
// worked before it could be spelled, invisibly, and why the spelling matters:
// `Stdio.printf(fmt)` silently receiving three arguments nobody wrote is not
// something a reader can be expected to know. private:docs/bugs/047.
//
// arm9 is the exception and the interesting one: its varargs travel in
// REGISTERS, so a forwarder cannot decline to repack — it relays its own homed
// tail into the callee's slots. Its tail also starts 8-ALIGNED, which plain
// AAPCS does not require: without that, a forwarder whose named-arg count has
// different parity from the callee's (`withFormat(fmt,…)` = 1 word,
// `appendFormat(self,fmt,…)` = 2) reads every `double` one word out — `%d` and
// `%s` came through and `%f` printed 0.
#import "Foundation.xc"
#import "Stdio.xc"

void logIt(string fmt, ...)
{
    Stdio.print("[log] ");
    Stdio.printf(fmt, ...);
}

// Two levels: a forwarder into a forwarder into the real consumer.
void logTwice(string fmt, ...)
{
    logIt(fmt, ...);
    logIt(fmt, ...);
}

i32 main(void)
{
    logIt("a=%d b=%d s=%s\n", (u16)222, (u16)333, "hi");
    logTwice("x=%d\n", (u16)7);
    // The same call written without forwarding still packs its own arguments,
    // so the two forms coexist in one function.
    Stdio.printf("direct a=%d\n", (u16)44);
    return 0;
}
