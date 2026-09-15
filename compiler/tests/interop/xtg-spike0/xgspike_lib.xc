// A library whose functions call back into an app-provided override, exactly
// the reverse-map -> override path the Xtg model rests on (libtable essence).

// (1) virtual method the LIBRARY itself invokes; the app subclasses + overrides.
class LibView
    {
    u16 tag;
    // virtual (default)
    u16 drawRect(void)
        {
        return (u16)0;
        }
    // library reaches the override
    u16 render(void)
        {
        return self.drawRect();
        }
    }

    // (2) optional protocol method as a nullable bound-method pointer, fired by the
    //     library, and required to weak-zero when the target object dies.
    typedef u16 hook_t(void);
class LibControl
    {
    weak : hook_t ^ onValidate;
    void setValidate(hook_t ^ h)
        {
        onValidate = h;
        }
    u16 validate(void)
        {
        if (onValidate)
            {
            return onValidate();
            }
        return (u16)999;
        }
    }

    // (3) a struct passed BY VALUE across the .so boundary, both directions.
    struct XGRect
    {
    u16 x;
    u16 y;
    u16 w;
    u16 h;
    } class LibGeom
    {
    u16 area(XGRect r)
        {
        return r.w * r.h;
        }
    XGRect unit(void)
        {
        XGRect b;
        b.x = (u16)1;
        b.y = (u16)2;
        b.w = (u16)3;
        b.h = (u16)4;
        return b;
        }
    }
