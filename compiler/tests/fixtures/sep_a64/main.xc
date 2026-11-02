// main.xc — the program of tests/driver/arm64-linux-objects.sh, compiled
// against Counter's interface and linked from the two objects.
#import "Stdio.xc"
#import <Counter>

i32 main(void)
    {
    Counter* c = new Counter();
    for (u32 i in 0..10)
        c.add(counterTwice(i));
    String* s = String.withFormat("counter %u", c.value());
    Stdio.printf("%s\n", s.cString());
    return 0;
    }
