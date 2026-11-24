// siboth.xc — links siobj.o (-c, #655): Counted's statics are used in the
// object and here. Its static init runs once, whichever module uses them
// first: both modules test the one guard flag. The object's global instance
// uses them first, before main. Printed with Stdio.print, as simain.xc.
#import "Stdio.xc"

class Counted : Object
    {
    static i32 base;
    static u32 runs;
    static void init(void) { runs = runs + 1; base = 40; }
    static i32 get(void) { return base + 2; }
    static u32 initRuns(void) { return runs; }
    }

i32 countedFromObject(void);
i32 earlyFromObject(void);

i32 main(void)
    {
    Stdio.print("before main ");
    Stdio.print(earlyFromObject());
    Stdio.print(" object ");
    Stdio.print(countedFromObject());
    Stdio.print(" program ");
    Stdio.print(Counted.get());
    Stdio.print(" runs ");
    Stdio.print(Counted.initRuns());
    Stdio.print("\n");
    return 0;
    }
