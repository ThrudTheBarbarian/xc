// saxpy — benchmark/par/saxpy.xc written by hand in bare CUDA.
// Same data, same arithmetic, same eight runs, same checksum. GPU only. The
// xc version keeps this block on the CPU by itself, because the copies cost
// more than the work; this hand-written kernel cannot, and is slower than the
// CPU for exactly that reason.
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "../../../src/include/bench_time.h"

#define SIZE (16 * 1024 * 1024)
#define THREADS 256

static void check(cudaError_t e, const char *what)
{
    if (e != cudaSuccess) { fprintf(stderr, "%s: %s\n", what, cudaGetErrorString(e)); exit(1); }
}

__global__ void saxpy_k(unsigned int n, const unsigned int *xs, unsigned int *ys, unsigned int *acc)
{
    unsigned int local = 0;
    for (unsigned int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; i += gridDim.x * blockDim.x)
    {
        unsigned int v = 3u * xs[i] + ys[i];
        ys[i] = v;
        local += v;
    }
    if (local) atomicAdd(acc, local);
}

int main(void)
{
    static uint32_t xs[SIZE], ys[SIZE];
    unsigned int *d_xs = 0, *d_ys = 0, *d_acc = 0;
    unsigned int total = 0;
    int64_t best = 0, first = 0;

    for (uint32_t i = 0; i < SIZE; i++)
    {
        xs[i] = i * 2654435761u;
        ys[i] = i;
    }
    unsigned int blocks = (SIZE + THREADS - 1) / THREADS;
    for (unsigned int rep = 0; rep < 8; rep++)
    {
        int64_t t0 = bench_now_us();
        if (rep == 0)
        {
            cudaFree(0);
            check(cudaMalloc(&d_xs, SIZE * sizeof(unsigned int)), "malloc xs");
            check(cudaMalloc(&d_ys, SIZE * sizeof(unsigned int)), "malloc ys");
            check(cudaMalloc(&d_acc, sizeof(unsigned int)), "malloc acc");
        }
        check(cudaMemcpy(d_xs, xs, SIZE * sizeof(unsigned int), cudaMemcpyHostToDevice), "in xs");
        check(cudaMemcpy(d_ys, ys, SIZE * sizeof(unsigned int), cudaMemcpyHostToDevice), "in ys");
        check(cudaMemset(d_acc, 0, sizeof(unsigned int)), "memset");
        saxpy_k<<<blocks, THREADS>>>(SIZE, d_xs, d_ys, d_acc);
        check(cudaMemcpy(&total, d_acc, sizeof(unsigned int), cudaMemcpyDeviceToHost), "copy acc");
        check(cudaMemcpy(ys, d_ys, SIZE * sizeof(unsigned int), cudaMemcpyDeviceToHost), "out ys");
        check(cudaDeviceSynchronize(), "sync");
        int64_t t1 = bench_now_us();
        if (rep == 0) first = t1 - t0;
        if (rep == 0 || t1 - t0 < best) best = t1 - t0;
    }
    printf("%u %lld %lld\n", total, (long long)best, (long long)first);
    cudaFree(d_xs); cudaFree(d_ys); cudaFree(d_acc);
    return 0;
}
