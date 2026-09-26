// chainbase.xc — the first library of chain.sh: a class with two roots, and a
// function that calls them through a base pointer.
#import "Stdio.xc"

class Base
    {
    i32 k;
    void init(void) { k = (i32)0; }
    u32 f(void) { return (u32)1; }
    u32 g(void) { return (u32)2; }
    }

class ChainA
    {
    static u32 viaBase(Base* b) { return b.f() * (u32)100 + b.g(); }
    }
