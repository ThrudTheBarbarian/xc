// A :grid block writing planes of a planar result at a captured offset
// (`o[plane + par.y * par.width + par.x]`), and one reading plane 0 while it
// writes plane 1, which the run-time check settles. Same answers as the loop
// form, on every device.
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
    {
    u32 w = (u32)64;
    u32 h = (u32)32;
    u32 plane = w * h;
    float* o = new float[plane * (u32)3];
    par planes :grid(w, h)
        {
        u32 p = par.y * par.width + par.x;
        o[p] = (float)p;
        o[plane + p] = (float)1.0;
        o[(u32)2 * plane + p] = (float)2.0;
        }
    par doubled :grid(w, h)
        {
        u32 p = par.y * par.width + par.x;
        o[plane + p] = o[p] * (float)2.0;
        }
    double s0 = 0.0;
    double s1 = 0.0;
    double s2 = 0.0;
    for (u32 i in 0..plane)
        {
        s0 = s0 + (double)o[i];
        s1 = s1 + (double)o[plane + i];
        s2 = s2 + (double)o[(u32)2 * plane + i];
        }
    Stdio.printf("%.1f %.1f %.1f\n", s0, s1, s2);
    return 0;
    }
