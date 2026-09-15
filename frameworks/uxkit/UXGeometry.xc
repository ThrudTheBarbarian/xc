// UXGeometry.xc — value types.  Structs, not classes: copied, not retained.
//
// GEM's convention throughout: top-left origin, y grows DOWN, i16 pixels.  We do
// not "improve" on that — the AES stores exactly these in OBJECT.ob_x/y/w/h, and
// an impedance mismatch here would cost a conversion at every single call.

struct UXPoint
    {
    i16 x;
    i16 y;
    } struct UXSize
    {
    i16 w;
    i16 h;
    } struct UXRect
    {
    i16 x;
    i16 y;
    i16 w;
    i16 h;
    }

    class UXGeom
    {
    static UXRect make(i16 x, i16 y, i16 w, i16 h)
        {
        UXRect r;
        r.x = x;
        r.y = y;
        r.w = w;
        r.h = h;
        return r;
        }

    static UXRect zero(void)
        {
        return UXGeom.make((i16)0, (i16)0, (i16)0, (i16)0);
        }

    static bool isEmpty(UXRect r)
        {
        return r.w <= (i16)0 || r.h <= (i16)0;
        }

    static bool contains(UXRect r, i16 px, i16 py)
        {
        return px >= r.x && py >= r.y && px < r.x + r.w && py < r.y + r.h;
        }

    // The smallest rect containing both.  An empty operand is ignored — otherwise a
    // zero rect at the origin would drag every union back to (0,0).
    static UXRect unite(UXRect a, UXRect b)
        {
        if (UXGeom.isEmpty(a))
            {
            return b;
            }
        if (UXGeom.isEmpty(b))
            {
            return a;
            }
        i16 x0 = a.x < b.x ? a.x : b.x;
        i16 y0 = a.y < b.y ? a.y : b.y;
        i16 x1 = (a.x + a.w) > (b.x + b.w) ? (i16)(a.x + a.w) : (i16)(b.x + b.w);
        i16 y1 = (a.y + a.h) > (b.y + b.h) ? (i16)(a.y + a.h) : (i16)(b.y + b.h);
        return UXGeom.make(x0, y0, (i16)(x1 - x0), (i16)(y1 - y0));
        }

    static bool intersects(UXRect a, UXRect b)
        {
        if (a.x + a.w <= b.x || b.x + b.w <= a.x)
            {
            return false;
            }
        if (a.y + a.h <= b.y || b.y + b.h <= a.y)
            {
            return false;
            }
        return true;
        }

    static UXRect intersection(UXRect a, UXRect b)
        {
        i16 x0 = a.x > b.x ? a.x : b.x;
        i16 y0 = a.y > b.y ? a.y : b.y;
        i16 x1 = (a.x + a.w) < (b.x + b.w) ? (i16)(a.x + a.w) : (i16)(b.x + b.w);
        i16 y1 = (a.y + a.h) < (b.y + b.h) ? (i16)(a.y + a.h) : (i16)(b.y + b.h);
        if (x1 <= x0 || y1 <= y0)
            {
            return UXGeom.zero();
            }
        return UXGeom.make(x0, y0, (i16)(x1 - x0), (i16)(y1 - y0));
        }

    // The smallest rect covering both.  An empty rect is the identity, so damage
    // regions can start empty and just union into.
    static UXRect union2(UXRect a, UXRect b)
        {
        if (UXGeom.isEmpty(a))
            {
            return b;
            }
        if (UXGeom.isEmpty(b))
            {
            return a;
            }
        i16 x0 = a.x < b.x ? a.x : b.x;
        i16 y0 = a.y < b.y ? a.y : b.y;
        i16 x1 = (a.x + a.w) > (b.x + b.w) ? (i16)(a.x + a.w) : (i16)(b.x + b.w);
        i16 y1 = (a.y + a.h) > (b.y + b.h) ? (i16)(a.y + a.h) : (i16)(b.y + b.h);
        return UXGeom.make(x0, y0, (i16)(x1 - x0), (i16)(y1 - y0));
        }

    // Integer square root (floor), by Newton from a power-of-two seed.  Needed wherever a LENGTH is
    // wanted rather than a squared length — normalising a stroke direction so a cap or an arrowhead
    // can be placed at a known distance along it.  No floats: the toolkit's geometry is integer
    // throughout so every backend flattens and caps a curve to identical pixels.
    static i32 isqrt(i32 v)
        {
        if (v <= (i32)0)
            {
            return (i32)0;
            }
        i32 x = v;
        i32 y = (i32)1;
        // converges from above
        while (x > y)
            {
            x = (x + y) / (i32)2;
            y = v / x;
            }
        return x;
        }
    // Length of (dx,dy), rounded down.  The one place the toolkit needs a real distance.
    static i32 length(i32 dx, i32 dy)
        {
        return UXGeom.isqrt(dx * dx + dy * dy);
        }
    }
