// siobj.xc — an object built with -c for simain.xc and siboth.xc (#655). Its
// classes' static init runs before the first use of their statics, from
// whichever module comes first, and once.
class Base40 : Object
    {
    static i32 base;
    static void init(void) { base = 40; }
    static i32 get(void) { return base + 2; }
    }

class Counted : Object
    {
    static i32 base;
    static u32 runs;
    static void init(void) { runs = runs + 1; base = 40; }
    static i32 get(void) { return base + 2; }
    static u32 initRuns(void) { return runs; }
    }

// Set up before main, so the object uses Counted's statics first.
class Early : Object
    {
    i32 v;
    void init(void) { v = Counted.get(); }
    }

Early gEarly;

i32 fromObject(void) { return Base40.get(); }
i32 earlyFromObject(void) { return gEarly.v; }
i32 countedFromObject(void) { return Counted.get(); }
