// itlib.xc — a library whose interface carries a struct, an enum and a typedef.
// See iface-types.sh.
#import "Stdio.xc"

struct TRect { i16 x; i16 y; i32 w; i32 h; }
enum TColor = {kRed = 3, kGreen = 7, kBlue = 11};
typedef i32 TCount;

class TBox : Object
    {
    TRect r;
    void init(i16 x, i16 y) { r.x = x; r.y = y; r.w = (i32)100; r.h = (i32)50; }
    TRect frame(void) { return r; }
    i32 area(TRect q) { return q.w * q.h; }
    TCount colourSum(void) { return (TCount)(kRed + kGreen + kBlue); }
    static TRect make(i16 x, i16 y) { TRect m; m.x = x; m.y = y; m.w = (i32)2; m.h = (i32)3; return m; }
    }
