// par :grid(w, h[, d]): the work items are a grid's points, par.x/.y/.z the
// point and par.width/.height/.depth the grid's size. The body is any code:
// `return` ends a work item, a loop or switch of its own may `break`, and the
// usual flat index y*width + x (z*height + y)*width + x needs no warning.
#import "Stdio.xc"
#import "Par.xc"

#define W 37
#define H 23
#define D 5

u32 img[W * H];
u32 vol[W * H * D];
u32 kind[W * H];

i32 main(void)
    {
    u32 w = (u32)W;
    u32 sum = (u32)0;
    u32 deepest = (u32)0;
    par fill :grid(w, H) :reduce(+ sum) :reduce(max deepest)
        {
        u32 at = par.y * par.width + par.x;
        if (par.x == (u32)0)
            {
            img[at] = (u32)7;
            return;
            }
        img[at] = par.x * (u32)100 + par.y;
        sum = sum + (u32)1;
        if (par.depth > deepest)
            deepest = par.depth;
        }
    par cube :grid(W, H, D)
        {
        u32 v = (u32)0;
        for (u32 k in 0..100)
            {
            if (k == par.z)
                break;
            v = v + k;
            }
        vol[(par.z * par.height + par.y) * par.width + par.x] = v + par.depth;
        }
    par classify :grid(W, H)
        {
        u32 c = (u32)0;
        switch (par.x % (u32)3)
            {
            case 0:
                c = (u32)10;
                break;
            case 1:
                c = (u32)20;
                break;
            default:
                c = (u32)30;
            }
        kind[par.x + par.y * par.width] = c + par.y % (u32)2;
        }
    u32 a = (u32)0;
    for (u32 i in 0..W * H)
        a = a + img[i];
    u32 b = (u32)0;
    for (u32 i in 0..W * H * D)
        b = b + vol[i];
    u32 k = (u32)0;
    for (u32 i in 0..W * H)
        k = k + kind[i];
    Stdio.printf("fill: %u items, depth %u, total %u, img[3][5] = %u\n", sum, deepest, a, img[3 * W + 5]);
    Stdio.printf("cube: total %u, vol[4][2][1] = %u\n", b, vol[(4 * H + 2) * W + 1]);
    Stdio.printf("classify: total %u, kind[1][4] = %u\n", k, kind[1 * W + 4]);
    return (i32)0;
    }
