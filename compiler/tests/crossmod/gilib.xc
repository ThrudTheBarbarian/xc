// gilib.xc — a library with a global instance (#641), set up by the
// library's load-time constructor before the program's main.
#import "Stdio.xc"

class Tally : Object
    {
    i32 n;
    void init(void) { n = 40; Stdio.printf("library instance set up\n"); }
    i32 bump(void) { n = n + 1; return n; }
    }

Tally gTally;

class GiLib
    {
    static i32 bump(void) { return gTally.bump(); }
    static Tally* tally(void) { return &gTally; }
    }
