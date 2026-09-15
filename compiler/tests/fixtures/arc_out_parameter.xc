// arc_out_parameter.xc — a store through `T@@` must RETAIN (bug 034).
//
// `@out = local` writes a value the callee OWNS into the caller's slot. If the
// store does not retain, the callee's epilogue releases it and the caller is
// left holding a freed block.
//
// The churn loop is the whole test. Without it the freed block still contains
// the right bytes and a broken compiler prints `HELLO` — correct output from
// dangling memory. Reallocating over it is what makes the bug visible, so do
// not "simplify" this fixture by deleting the loop.
#import "Stdio.xc"
#import "String.xc"

class Out
{
    static void fill(String** out)
    {
        String* local = String.withCString("HELLO");
        *out = local;                      // owned by fill, adopted by the slot
    }

    // Writing twice through the same pointer must release the first value
    // rather than leak it — the slot owns what it holds.
    static void refill(String** out)
    {
        *out = String.withCString("FIRST");
        *out = String.withCString("SECOND");
    }
}

i32 main(void)
{
    String* got = (String*)0;
    Out.fill(&got);
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) {
        String* junk = String.withCString("XXXXXXXXXXXXXXXX");
        junk.appendCString("YYYY");
    }
    Stdio.printf("got=%s len=%d\n", got.cString(), (i16)got.byteLength());

    String* two = (String*)0;
    Out.refill(&two);
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) {
        String* junk = String.withCString("ZZZZZZZZZZZZZZZZ");
        junk.appendCString("WWWW");
    }
    Stdio.printf("two=%s len=%d\n", two.cString(), (i16)two.byteLength());
    return 0;
}
