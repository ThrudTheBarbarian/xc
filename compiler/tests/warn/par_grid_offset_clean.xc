// A captured offset in a :grid block's index is the loop form's `a[i + off]`:
// accepted, with the run-time check where it is needed, and no par-scatter
// warning (par.md: a grid block has the same limits as the loop form). It was
// "writes 'o' at an index computed from data".
#import "Par.xc"
void main(void)
    {
    u32 w = (u32)64; u32 h = (u32)64; u32 plane = w * h;
    float* o = new float[plane * (u32)3];
    par planes :grid(w, h)
        {
        o[par.y * par.width + par.x] = (float)1.0;
        o[plane + par.y * par.width + par.x] = (float)2.0;
        o[par.y * par.width + par.x + (u32)2 * plane] = (float)3.0;
        }
    }
