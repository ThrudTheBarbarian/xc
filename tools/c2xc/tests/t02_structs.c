#include <stdio.h>
#include <string.h>
struct node
    {
    int v;
    struct node* next;
    };
typedef struct
    {
    double re, im;
    } cx;
typedef struct point
    {
    int x, y;
    } point_t;
static cx cmul(cx a, cx b)
    {
    cx r;
    r.re = a.re * b.re - a.im * b.im;
    r.im = a.re * b.im + a.im * b.re;
    return r;
    }
int main(void)
    {
    struct node a, b, *p;
    a.v = 1;
    a.next = &b;
    b.v = 2;
    b.next = NULL;
    for (p = &a; p; p = p->next)
        printf("%d ", p->v);
    cx z = {1.0, 2.0}, w = cmul(z, z);
    printf("%.1f %.1f\n", w.re, w.im);
    point_t pts[3] = {{1, 2}, {3, 4}, {5, 6}};
    point_t q = pts[1];
    q.x = 9;
    printf("%d %d %d\n", pts[1].x, q.x, (int)sizeof(point_t));
    struct point* pp = &pts[2];
    pp->y += 10;
    printf("%d\n", pts[2].y);
    return 0;
    }
