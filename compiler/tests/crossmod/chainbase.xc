// chainbase.xc — the first library of chain.sh: a class with two roots, and a
// function that calls them through a base pointer.
#import "Stdio.xc"

class Base
    {
    i32 k;
    static u32 freed;
    void init(void) { k = (i32)0; }
    void dealloc(void) { freed = freed + (u32)1; }
    u32 f(void) { return (u32)1; }
    u32 g(void) { return (u32)2; }
    static u32 deallocs(void) { return freed; }
    }

class ChainA
    {
    static u32 viaBase(Base* b) { return b.f() * (u32)100 + b.g(); }
    }

// The class a designable class's load-time constructor calls (chainuse.xc).
// It calls through Base's vtable, whose words this library fills in when it
// is relocated, so on wasm32 this library must be relocated before a library
// whose startup code calls it.
class UXNib
    {
    static Base@ probe;
    static u32 boot;
    static void registerObjectFactory(pointer fn)
        {
        probe = new Base();
        boot = ChainA.viaBase(probe);
        }
    static u32 booted(void) { return boot; }
    }
