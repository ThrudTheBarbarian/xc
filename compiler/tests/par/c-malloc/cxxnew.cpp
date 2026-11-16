/* A C++ program whose first allocation is an operator new (a list's node),
   then a lifted loop over three new[] arrays of 64 KB and more, which the
   heap allocates, so the loop runs as a block. */
#include <cstdio>
#include <list>

static void axpy(float* y, const float* x, const int* idx, int n)
    {
    for (int i = 0; i < n; i++)
        y[i] = x[idx[i]] * 2.0f + y[i];
    }

int main()
    {
    std::list<int> l;
    for (int i = 0; i < 100; i++)
        l.push_back(i);
    long ls = 0;
    for (int v : l)
        ls += v;
    int n = 300000;
    float* x = new float[n];
    float* y = new float[n];
    int* idx = new int[n];
    for (int i = 0; i < n; i++)
        {
        x[i] = (float)(i % 1000) * 0.25f;
        y[i] = (float)(i % 7);
        idx[i] = (int)(((long)i * 7919) % n);
        }
    axpy(y, x, idx, n);
    double s = 0;
    for (int i = 0; i < n; i++)
        s += y[i];
    std::printf("%ld %.1f\n", ls, s);
    delete[] x;
    delete[] y;
    delete[] idx;
    return 0;
    }
