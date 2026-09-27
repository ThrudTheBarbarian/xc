// dplib.xc — declares the binding protocol and the nib class.
protocol UXDesignable
    {
    bool setOutlet(u8* name, Object* value);
    bool wireAction(u8* name, Object* control);
    }

class UXNib
    {
    static u32 registered;
    static void registerObjectFactory(pointer fn)
        {
        registered = registered + (u32)1;
        }
    }
