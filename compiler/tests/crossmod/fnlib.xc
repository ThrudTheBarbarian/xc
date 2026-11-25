// fnlib.xc — a library declared with the f32 and f64 type names. See
// float-names.sh.
#import "Stdio.xc"

typedef f64 FWide;

f32 narrow(f64 x)
{
    return x * 2;
}

class FScale : Object
    {
    f32 factor;
    void init(float k) { factor = k; }
    f64 apply(f32 v) { return v * factor; }
    static FWide sum(f64 a, double b) { return a + b; }
    }
