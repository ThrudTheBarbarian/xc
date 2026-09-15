// The race-free static-init once (private:docs/Design/threading.md §9.5), in the shape
// the differential can actually reach.
//
// The once is gated on "does this program declare the thread-spawn primitive",
// and that is a FILE-SCOPE prototype — so the gate flips without importing
// Thread.xc, which matters here: this harness targets -m xt, where Thread.xc is
// a hard #error. Declaring the prototype is the whole trigger.
//
// What this pins is that both lowerings agree on the THREADED shape: the fast
// path testing the flag against 2 rather than 0, and the whole body collapsing
// into ONE `_xtc_sinit_run(&flag, &C$init, &__sdata_C)` call, which claims,
// runs and publishes. (An earlier design split that into _xtc_sinit_enter, a
// _do block and _xtc_sinit_done; the runtimes still carry those symbols, but
// no lowering emits them — do not go looking for them in the .expected.ir.)
// Without a case like this the differential only ever saw the single-threaded
// guard, and the two compilers could diverge on exactly the new code.
pointer _xt_thread_create(pointer code, pointer recv);

class Once
    {
    static u8 value;
    static void init(void)
        {
        value = (u8)7;
        }
    static u8 get(void)
        {
        return value;
        }
    }

    u8
    useOnce(void)
    {
    return Once.get();
    }
