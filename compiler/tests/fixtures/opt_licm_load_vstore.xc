// opt_licm_load_vstore.xc — LICM keeps an element load in an outer loop whose inner loop the
// vectoriser turned into vector stores (#433). Hoisted, a[k] was read once.
#import "Stdio.xc"

i32 run(i32* a, i32 k, i32 reps)
    {
    i32 s = 0;
    for (i32 r = 0; r < reps; r = r + 1)
        {
        s = s + a[k];
        for (i32 i = 0; i < 16; i = i + 1)
            {
            a[i] = a[i] + 1;
            }
        }
    return s;
    }

void main(void)
    {
    i32* a = new i32[16];
    for (i32 i = 0; i < 16; i = i + 1)
        a[i] = 0;
    Stdio.printf("%d\n", run(a, 0, 5));
    }
