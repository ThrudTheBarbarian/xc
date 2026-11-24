// giclient.xc — a program with a global instance of its own, using the
// library's (#641): the library's is set up when the library loads, then the
// program's, then main runs. The library's instance is reached through the
// library's functions and, declared `extern`, by name.
#import "Stdio.xc"
#import <gilib>

extern Tally gTally;

class Mark : Object
    {
    i32 v;
    void init(void) { v = 7; Stdio.printf("program instance set up\n"); }
    }

Mark gMark;

i32 main(void)
    {
    Stdio.printf("main\n");
    Tally* t = GiLib.tally();
    Stdio.printf("bump %d %d mark %d\n", GiLib.bump(), t.bump(), gMark.v);
    t = nil;
    Stdio.printf("extern %d same %d\n", gTally.bump(), GiLib.tally() == &gTally);
    Stdio.printf("again %d\n", GiLib.bump());
    return 0;
    }
