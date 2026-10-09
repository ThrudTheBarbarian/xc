// mandelbrot — benchmark/par/mandelbrot.xc written by hand in bare CUDA.
// Same data, same arithmetic, same eight runs, same checksum. GPU only: this
// runs on no CPU, and on no GPU but an NVIDIA one through CUDA — not Metal,
// not Vulkan, not WebGPU.
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "../../../src/include/bench_time.h"

#define SIZE (2048 * 2048)
#define THREADS 256

static void check(cudaError_t e, const char *what)
{
    if (e != cudaSuccess) { fprintf(stderr, "%s: %s\n", what, cudaGetErrorString(e)); exit(1); }
}

__global__ void mandel(unsigned int n, unsigned int *acc)
{
    unsigned int local = 0;
    for (unsigned int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; i += gridDim.x * blockDim.x)
    {
        float cx = (float)(i % 2048u) * (3.0f / 2048.0f) - 2.0f;
        float cy = (float)(i / 2048u) * (3.0f / 2048.0f) - 1.5f;
        float x = 0.0f, y = 0.0f;
        unsigned int k = 0;
        while (k < 256u && x * x + y * y < 4.0f)
        {
            float xt = x * x - y * y + cx;
            y = 2.0f * x * y + cy;
            x = xt;
            k++;
        }
        local += k;
    }
    if (local) atomicAdd(acc, local);
}

int main(void)
{
    unsigned int *d_acc = 0;
    unsigned int total = 0;
    int64_t best = 0, first = 0;
    unsigned int blocks = (SIZE + THREADS - 1) / THREADS;
    for (unsigned int rep = 0; rep < 8; rep++)
    {
        int64_t t0 = bench_now_us();
        if (rep == 0) { cudaFree(0); check(cudaMalloc(&d_acc, sizeof(unsigned int)), "malloc"); }
        check(cudaMemset(d_acc, 0, sizeof(unsigned int)), "memset");
        mandel<<<blocks, THREADS>>>(SIZE, d_acc);
        check(cudaMemcpy(&total, d_acc, sizeof(unsigned int), cudaMemcpyDeviceToHost), "copy");
        check(cudaDeviceSynchronize(), "sync");
        int64_t t1 = bench_now_us();
        if (rep == 0) first = t1 - t0;
        if (rep == 0 || t1 - t0 < best) best = t1 - t0;
    }
    printf("%u %lld %lld\n", (total + 500000u) / 1000000u,
           (long long)best, (long long)first);
    cudaFree(d_acc);
    return 0;
}
