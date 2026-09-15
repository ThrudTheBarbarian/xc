// static_init_once.xc — a class's `static init` runs EXACTLY ONCE, lazily, and
// behaves under the two cases that break naive run-once mechanisms.
//
// This is xtc's lazy-singleton idiom: a class with static state and a
// `static void init(void)`. The compiler guards it with a per-class flag
// (`__sinit_<Class>`) tested before first use, so no explicit "have I set up
// yet?" check is needed in user code. It is what a translated compiler will use
// in place of dispatch_once. See private:docs/Design/threading.md Phase 0.5.
//
// Pinned here because all three properties are currently implicit:
//
//   1. EXACTLY ONCE — repeated use does not re-run init.
//   2. RE-ENTRANCY — if init touches its own class, it does NOT re-run and does
//      NOT recurse; the re-entrant read sees ZERO-INITIALISED state, because the
//      guard is set BEFORE the body runs. `A.get()` inside `A.init` therefore
//      returns 0, not the value init is about to assign.
//   3. MUTUAL DEPENDENCY — a class whose init uses another class gets that
//      other class initialised; neither runs twice and neither deadlocks.
//
// NOT thread-safe: the guard is a plain flag, not an atomic CAS. There are no
// threads yet, so this has no runtime consequence today — but it is the one
// change Phase 1 must make when they arrive.

#import "Stdio.xc"

class Counter
{
    static u32 value;
    static u32 initRuns;
    static void init(void)
    {
        initRuns = initRuns + (u32)1;
        // Re-entrant read of our own class: must NOT re-run init, and sees the
        // zero-initialised value rather than recursing.
        value = Counter.peek() + (u32)1;
    }
    static u32 peek(void)     { return value; }
    static u32 bump(void)     { value = value + (u32)1; return value; }
    static u32 runCount(void) { return initRuns; }
}

class Inner
{
    static u32 y;
    static void init(void) { y = (u32)7; }
    static u32 get(void)   { return y; }
}

class Outer
{
    static u32 x;
    static void init(void) { x = Inner.get() + (u32)1; }   // depends on Inner
    static u32 get(void)   { return x; }
}

void main(void)
{
    // 2. re-entrant init saw zero, so value is 1 — and init ran once
    Stdio.printf("after-init value=%d runs=%d\n", Counter.peek(), Counter.runCount());

    // 1. repeated use does not re-run init
    Stdio.printf("bump=%d bump=%d runs=%d\n",
                 Counter.bump(), Counter.bump(), Counter.runCount());

    // 3. mutual dependency resolves, each initialised once
    Stdio.printf("outer=%d inner=%d\n", Outer.get(), Inner.get());
}
