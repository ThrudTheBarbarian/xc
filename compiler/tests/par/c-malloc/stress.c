/* Threads that allocate, grow and free blocks large and small at once, each
   checking its own blocks' contents, while the main thread runs a lifted
   gather over two large blocks again and again (each run asks the runtime's
   registry about them, as the other threads change it). `stress <threads>` */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#define SLOTS 64
#define ROUNDS 3000

static void gather(float* y, const float* x, const int* idx, int n)
    {
    for (int i = 0; i < n; i++)
        y[i] = x[idx[i]] * 0.5f + 1.0f;
    }

static unsigned next(unsigned* s)
    {
    *s = *s * 1103515245u + 12345u;
    return *s >> 8;
    }

static void* churn(void* arg)
    {
    unsigned seed = (unsigned)(unsigned long)arg * 7919u + 1u;
    unsigned char* p[SLOTS];
    size_t len[SLOTS];
    unsigned char tag[SLOTS];
    long bad = 0;
    memset(p, 0, sizeof p);
    for (int r = 0; r < ROUNDS; r++)
        {
        int k = (int)(next(&seed) % SLOTS);
        if (p[k])
            {
            /* every byte checked at both ends and the middle */
            if (p[k][0] != tag[k] || p[k][len[k] - 1] != tag[k] || p[k][len[k] / 2] != tag[k])
                bad++;
            unsigned op = next(&seed) % 3;
            if (op == 0)
                {
                free(p[k]);
                p[k] = 0;
                continue;
                }
            if (op == 1)
                {
                size_t n = (next(&seed) % 2) ? 64 + next(&seed) % 4000 : 65536 + next(&seed) % 400000;
                unsigned char* q = realloc(p[k], n);
                if (!q)
                    continue;
                size_t keep = n < len[k] ? n : len[k];
                if (q[0] != tag[k] || q[keep - 1] != tag[k])
                    bad++;
                memset(q, tag[k], n);
                p[k] = q;
                len[k] = n;
                continue;
                }
            }
        else
            {
            size_t n = (next(&seed) % 2) ? 16 + next(&seed) % 8000 : 65536 + next(&seed) % 600000;
            tag[k] = (unsigned char)(next(&seed) | 1);
            p[k] = (next(&seed) % 2) ? malloc(n) : calloc(n, 1);
            if (!p[k])
                continue;
            memset(p[k], tag[k], n);
            len[k] = n;
            }
        }
    for (int k = 0; k < SLOTS; k++)
        free(p[k]);
    return (void*)bad;
    }

int main(int argc, char** argv)
    {
    int nt = argc > 1 ? atoi(argv[1]) : 8;
    pthread_t t[64];
    if (nt > 64)
        nt = 64;
    for (int i = 0; i < nt; i++)
        pthread_create(&t[i], 0, churn, (void*)(unsigned long)i);
    int n = 100000;
    int* idx = malloc(sizeof(int) * n);
    float* x = malloc(sizeof(float) * n);
    float* y = malloc(sizeof(float) * n);
    for (int i = 0; i < n; i++)
        {
        x[i] = (float)(i % 1000) * 0.5f;
        idx[i] = (i * 7919) % n;
        }
    double s = 0;
    for (int r = 0; r < 200; r++)
        {
        gather(y, x, idx, n);
        s += y[r * 37];
        }
    long bad = 0;
    for (int i = 0; i < nt; i++)
        {
        void* b;
        pthread_join(t[i], &b);
        bad += (long)b;
        }
    printf("%.1f %ld\n", s, bad);
    free(idx);
    free(x);
    free(y);
    return 0;
    }
