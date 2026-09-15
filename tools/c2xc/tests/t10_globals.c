#include <stdio.h>
static int counter = 3;
double table[4] = {1.5, 2.5, 3.5, 4.5};
struct rec
    {
    const char* name;
    int n;
    double v;
    } recs[2] = {{"a", 1, 0.5}, {"b", 2, 1.5}};
const char* greeting = "hi";
int* ptr = &counter;
static int tick(void)
    {
    static int n = 0;
    return ++n;
    }
int main(void)
    {
    tick();
    tick();
    *ptr += tick();
    printf("%d %.1f %s %d %.1f %s\n", counter, table[2], recs[1].name, recs[1].n, recs[0].v, greeting);
    return 0;
    }
