//xtc-flags: expect=sema-error
// `m +%101` is Money's `+%` with 101, and also `m + %101`, a pointer step by
// the binary literal 5. Both readings type-check, so neither is chosen.
// Refused: '+%' reads two ways here and both type-check: as the operator of 'Money' and as the built-in operators it is spelt with; write those operators apart, or call the method by name
#import <Stdio.xc>

class Money
    {
    i32 c;
    Money* addPct(i32 p) :operator(self +% p) { return self; }
    }

i32 main(void)
    {
    Money* m = new Money();
    Money* n = m +%101;
    return n.c;
    }
