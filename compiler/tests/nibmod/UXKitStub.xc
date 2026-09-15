// The framework surface the compiler looks for, as a real library declares it.
typedef void UXAct(Object* sender);

class UXControl : Object
    {
    UXAct ^ action;
    void init(void)
        {
        }
    void setAction(UXAct ^ a)
        {
        action = a;
        }
    void fire(Object* s)
        {
        if (action)
            {
            action(s);
            }
        }
    }

    protocol UXDesignable
    {
    bool setOutlet(u8 * name, Object * value);
    bool wireAction(u8 * name, UXControl * control);
    }

// A per-module factory, as the compiler generates it.
typedef UXDesignable* UXFactory(u8* name);

// The loader. It holds the registered factories and tries them in turn, so a
// designable class can live in ANY module and no module knows another's.
class UXNib : Object
    {
    static UXFactory* f0;
    static UXFactory* f1;
    static u16 nfac;

    static void registerObjectFactory(pointer fn)
        {
        if (nfac == (u16)0)
            {
            f0 = (UXFactory*)fn;
            }
        else
            {
            f1 = (UXFactory*)fn;
            }
        nfac = nfac + (u16)1;
        }

    static u16 factoryCount(void)
        {
        return nfac;
        }

    static UXDesignable* make(u8* name)
        {
        UXDesignable* o = (UXDesignable*)0;
        if (nfac > (u16)0)
            {
            o = f0(name);
            if (o != (UXDesignable*)0)
                return o;
            }
        if (nfac > (u16)1)
            {
            o = f1(name);
            if (o != (UXDesignable*)0)
                return o;
            }
        return (UXDesignable*)0;
        }
    }
