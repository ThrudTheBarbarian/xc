/* The allocating half of a program of two C files (twoloop.c runs the loop). */
#include <stdlib.h>
float* make(int n, int k)
    {
    float* p = malloc(sizeof(float) * n);
    for (int i = 0; i < n; i++)
        p[i] = (float)((i * k) % 1000) * 0.25f;
    return p;
    }
