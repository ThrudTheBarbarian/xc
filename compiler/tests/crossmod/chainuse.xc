// chainuse.xc — the third library of chain.sh. It uses chainbase's library
// only inside its bodies, so its interface names nothing from it. It has
// startup code: UsePanel's `outlet` gives it a load-time constructor, which
// calls chainbase's UXNib.registerObjectFactory.
#import "Stdio.xc"
#import <ChainBase>

protocol UXDesignable
    {
    bool setOutlet(u8* name, Object* value);
    bool wireAction(u8* name, Object* control);
    }

class UsePanel
    {
    outlet Object* part;
    void init(void) { }
    }

class ChainU
    {
    static u32 booted(void) { return UXNib.booted(); }
    // An array of the first library's class, made and freed here. Each
    // element is freed through the first library's Base$dealloc.
    static u32 many(u32 n)
        {
        u32 was = Base.deallocs();
        { Base* arr = new Base[n]; }
        return Base.deallocs() - was;
        }
    }
