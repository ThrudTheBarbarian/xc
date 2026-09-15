#import "Stdio.xc"
#import <proofshim>

// hand-declared C prototype (mirrors proofshim.c) — the export side rides on
// xtc's standard convention already being the platform C ABI for pointer args.
void run_callback_n(pointer cb, pointer ctx, i32 n);

class Counter
    {
    i32 count;
    void seed(i32 v)
        {
        count = v;
        }
    void bump(void)
        {
        count = count + 1;
        }
    i32 value(void)
        {
        return count;
        }
    }

    // The C-ABI free-function callback the "toolkit" invokes. No implicit self;
    // the receiver arrives in the context word and is recovered by a cast.
    void on_event(pointer ctx)
    {
    Counter* c = (Counter*)ctx;
    c.bump();
    }

void main(void)
    {
    Counter* c = new Counter();
    c.seed(100);                              // pre-set field proves identity
    run_callback_n(&on_event, (pointer)c, 5); // foreign C calls back 5x
    Stdio.printf("count=%d\n", c.value());    // expect 105
    }
