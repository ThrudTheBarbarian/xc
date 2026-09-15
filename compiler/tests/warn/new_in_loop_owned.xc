// No expectation: this file must produce NO warning.
//
// `new` inside a loop, in the three shapes the retired "will leak" warning
// (private:docs/bugs/086) used to fire on. None leaks under ARC — measured with a
// dealloc counter: a discarded `new` is released, a loop-local is released
// each iteration, a stored one is owned by the array and freed when it lets
// go. The analyser must say nothing about any of them.
#import "Stdio.xc"
class Thing
    {
    i32 v;
    void init(void)
        {
        v = (i32)0;
        }
    void poke(void)
        {
        v = v + (i32)1;
        }
    } i32 main(void)
    {
    Array* keep = new Array();
    for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
        {
        new Thing();            // discarded — released at once
        Thing* t = new Thing(); // loop-local — released each pass
        t.poke();
        Thing* kept = new Thing(); // stored — the array owns it
        keep.add((Object*)kept);
        }
    Stdio.printf("%lu\n", keep.count());
    return (i32)0;
    }
