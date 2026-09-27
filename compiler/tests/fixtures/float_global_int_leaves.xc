// Integer leaves in float and double globals are folded into the data image.
//
// `double a[2] = {1, 2};` has integer leaves in a double array. One compiler
// baked them into the image and the other wrote them with code at start-up
// (or refused a struct of them outright), so the two produced different output
// for the same program. Arrays, struct fields, nested aggregates and mixed
// integer / float leaves, including negated, cast, character and computed
// ones, and integers too wide for a float to hold exactly.
#import "Foundation.xc"
#import "Stdio.xc"

struct Pt
{
    double x;
    float y;
    i32 n;
};

double gd[4] = {1, 2, -3, 1000000000};
float gf[4] = {1, -2, 0.5, 16777217};
double gmix[5] = {1, 2.5, -4, (double)7, 3 * 4};
float gfmix[3] = {-1.25, 6, 'A'};
Pt gp = {5, -6, 7};
Pt gps[2] = {{1, 2.5, 3}, {-4, 5, 6}};
double gbig[2] = {9007199254740993, -9223372036854775807};
float gfbig[1] = {2147483647};

String* line;

void add(double v)
{
    line.appendCString(" ");
    line.append(String.withI32((i32)(v * 4.0)));
}

void flush(string tag)
{
    Stdio.printf("%s%s\n", tag, line.cString());
    line = String.withCString("");
}

i32 main(void)
{
    line = String.withCString("");
    for (u32 i = 0; i < 3; i++)
        add(gd[i]);
    flush("gd");
    Stdio.printf("gd3 %s\n", gd[3] == 1000000000.0d ? "ok" : "wrong");
    for (u32 i = 0; i < 4; i++)
        add((double)gf[i]);
    flush("gf");
    for (u32 i = 0; i < 5; i++)
        add(gmix[i]);
    flush("gmix");
    for (u32 i = 0; i < 3; i++)
        add((double)gfmix[i]);
    flush("gfmix");
    add(gp.x);
    add((double)gp.y);
    flush("gp");
    Stdio.printf("gp.n %d\n", gp.n);
    for (u32 i = 0; i < 2; i++)
    {
        add(gps[i].x);
        add((double)gps[i].y);
        flush("gps");
        Stdio.printf("gps.n %d\n", gps[i].n);
    }
    Stdio.printf("gbig0 %s\n", gbig[0] == 9007199254740992.0d ? "ok" : "wrong");
    Stdio.printf("gbig1 %s\n", gbig[1] == -9223372036854775808.0d ? "ok" : "wrong");
    Stdio.printf("gfbig %s\n", (double)gfbig[0] == 2147483648.0d ? "ok" : "wrong");
    return 0;
}
