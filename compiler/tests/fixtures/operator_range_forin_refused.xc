//xtc-flags: expect=sema-error
// A range index through an operator is a call's result, not a slice to
// iterate.
// Refused: 'for ... in' cannot iterate a range index made by an operator; assign it to a variable first
#import <Stdio.xc>

class S
    {
    i32 items[4];
    i32* part(i32 lo, i32 hi) :operator(self[lo..hi]) { return &items[lo]; }
    }

i32 main(void)
    {
    S* s = new S();
    for (i32 x in s[1..3])
        Stdio.printf("%d\n", x);
    return 0;
    }
