struct SRect
    {
    i16 x;
    i16 y;
    i16 w;
    i16 h;
    }

// A global the library defines and a free function: the app declares both
// itself, writes the global and reads it back after the function adds one
// (#648).
u16 gSCounter;
void sbump(void)
    {
    gSCounter = gSCounter + (u16)1;
    }

class SLib
    {
    // the APP's object
    static u32 lenOf(String* s)
        {
        return s.byteLength();
        }
    static u32 lenOwn(void) // the LIBRARY's own
        {
        String* t = String.withCString("xyz");
        return t.byteLength();
        }
    // an aggregate result: a hidden result pointer on both sides
    static SRect make(i16 x, i16 y, i16 w, i16 h)
        {
        SRect r;
        r.x = x;
        r.y = y;
        r.w = w;
        r.h = h;
        return r;
        }
    }
