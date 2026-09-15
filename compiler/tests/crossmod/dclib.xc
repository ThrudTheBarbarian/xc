// dclib.xc — #9 conformance-downcast library side. Holds objects as Object@ and
// asks "does this conform to Pingable?" — the nib-loader shape. It never sees the
// client's classes; the check reads the object's vtable itable at runtime.
protocol Pingable
    {
    i32 ping(i32 x);
    }
bool isPingable(Object* o)
    { return (Pingable* ?)o != (Pingable*)0;
    }
i32 tryPing(Object* o, i32 x)
    {
    Pingable* p = (Pingable* ?)o;
    if (p != (Pingable*)0)
        {
        return p.ping(x);
        }
    return (i32)-1;
    }
