#include <stdio.h>
enum colour
    {
    RED,
    GREEN = 5,
    BLUE
    };
    typedef union {
    int i;
    float f;
    unsigned char b[4];
    } word;
struct flags
    {
    unsigned a : 3;
    unsigned b : 5;
    int c;
    };
int main(void)
    {
    enum colour c = BLUE;
    word w;
    struct flags f;
    w.i = 0x01020304;
    f.a = 5;
    f.b = 17;
    f.c = -1;
    printf("%d %d %d %d %d\n", c, GREEN + 1, w.b[0] + w.b[3], f.a + f.b, f.c);
    w.f = 1.0f;
    printf("%d\n", w.i == 0x3f800000);
    return c;
    }
