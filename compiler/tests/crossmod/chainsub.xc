// chainsub.xc — the second library of chain.sh: it imports chainbase's
// library and subclasses Base, overriding f and adding a root h of its own.
#import "Stdio.xc"
#import <ChainBase>

class Sub : Base
    {
    u32 f(void) { return (u32)5; }
    u32 h(void) { return (u32)7; }
    }

class ChainB
    {
    static Sub@ make(void) { return new Sub(); }
    static u32 viaSub(Sub* s) { return s.h() + s.g() * (u32)10; }
    }
