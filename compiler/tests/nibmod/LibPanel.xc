#import "UXKitStub.xc"

// A designable class defined in the LIBRARY.
class LibLabel : Object
    {
    u16 tag;
    void init(void)
        {
        tag = (u16)0;
        }
    }

    u16 libFired;

// The iface exports classes, not module-level globals, so the app reads the
// library's counter through the library.
class LibProbe : Object
    {
    static u16 fired(void)
        {
        return libFired;
        }
    static void reset(void)
        {
        libFired = (u16)0;
        }
    }

    class LibPanel : Object
    {
    outlet LibLabel* caption;
    void init(void)
        {
        }
    void onLibTap(Object* sender) : action
        {
        libFired = libFired + (u16)1;
        }
    }
