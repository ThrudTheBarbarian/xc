// perlin — benchmark/par/perlin.xc written by hand in bare CUDA.
// Same data, same arithmetic, same eight runs, same checksum. GPU only. The
// permutation table moves to __constant__ memory by hand, which the xc version
// never has to think about.
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "../../../src/include/bench_time.h"

#define SIZE (2048 * 2048)
#define THREADS 256

__constant__ unsigned int c_perm[512];

static void check(cudaError_t e, const char *what)
{
    if (e != cudaSuccess) { fprintf(stderr, "%s: %s\n", what, cudaGetErrorString(e)); exit(1); }
}

__device__ __forceinline__ float fade(float t) { return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f); }
__device__ __forceinline__ float lerp(float t, float a, float b) { return a + t * (b - a); }
__device__ __forceinline__ float grad(unsigned int h, float x, float y)
{
    unsigned int g = h & 7u;
    float u = g < 4u ? x : y;
    float v = g < 4u ? y : x;
    float a = (g & 1u) ? -u : u;
    float b = (g & 2u) ? -2.0f * v : 2.0f * v;
    return a + b;
}

__global__ void perlin_k(unsigned int n, unsigned char *img, unsigned int *acc)
{
    unsigned int local = 0;
    for (unsigned int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; i += gridDim.x * blockDim.x)
    {
        float x = (float)(i % 2048u) / 256.0f;
        float y = (float)(i / 2048u) / 256.0f;
        float sum = 0.0f, amp = 1.0f, norm = 0.0f;
        for (unsigned int o = 0; o < 4; o++)
        {
            unsigned int xi = (unsigned int)x, yi = (unsigned int)y;
            float xf = x - (float)xi, yf = y - (float)yi;
            unsigned int X = xi & 255u, Y = yi & 255u;
            unsigned int aa = c_perm[c_perm[X] + Y];
            unsigned int ab = c_perm[c_perm[X] + Y + 1u];
            unsigned int ba = c_perm[c_perm[X + 1u] + Y];
            unsigned int bb = c_perm[c_perm[X + 1u] + Y + 1u];
            float u = fade(xf), v = fade(yf);
            float n = lerp(v, lerp(u, grad(aa, xf, yf), grad(ba, xf - 1.0f, yf)),
                           lerp(u, grad(ab, xf, yf - 1.0f), grad(bb, xf - 1.0f, yf - 1.0f)));
            sum = sum + n * amp;
            norm = norm + amp;
            amp = amp * 0.5f;
            x = x * 2.0f;
            y = y * 2.0f;
        }
        float s = (sum / norm) * 0.5f + 0.5f;
        if (s < 0.0f) s = 0.0f;
        if (s > 1.0f) s = 1.0f;
        unsigned int p = (unsigned int)(s * 255.0f);
        img[i] = (unsigned char)p;
        local += p;
    }
    if (local) atomicAdd(acc, local);
}

int main(void)
{
    static uint32_t perm[512];
    static unsigned char img[SIZE];
    unsigned char *d_img = 0;
    unsigned int *d_acc = 0;
    unsigned int total = 0;
    int64_t best = 0, first = 0;

    uint32_t seed = 12345;
    for (uint32_t i = 0; i < 256; i++) perm[i] = i;
    for (uint32_t i = 0; i < 256; i++)
    {
        seed = seed * 1103515245u + 12345u;
        uint32_t j = i + (seed >> 16) % (256u - i);
        uint32_t t = perm[i]; perm[i] = perm[j]; perm[j] = t;
    }
    for (uint32_t i = 0; i < 256; i++) perm[i + 256] = perm[i];

    unsigned int blocks = (SIZE + THREADS - 1) / THREADS;
    for (unsigned int rep = 0; rep < 8; rep++)
    {
        int64_t t0 = bench_now_us();
        if (rep == 0)
        {
            cudaFree(0);
            check(cudaMalloc(&d_img, SIZE * sizeof(unsigned char)), "malloc img");
            check(cudaMalloc(&d_acc, sizeof(unsigned int)), "malloc acc");
            check(cudaMemcpyToSymbol(c_perm, perm, sizeof(perm)), "perm");
        }
        check(cudaMemset(d_acc, 0, sizeof(unsigned int)), "memset");
        perlin_k<<<blocks, THREADS>>>(SIZE, d_img, d_acc);
        check(cudaMemcpy(&total, d_acc, sizeof(unsigned int), cudaMemcpyDeviceToHost), "copy acc");
        check(cudaMemcpy(img, d_img, SIZE * sizeof(unsigned char), cudaMemcpyDeviceToHost), "out img");
        check(cudaDeviceSynchronize(), "sync");
        int64_t t1 = bench_now_us();
        if (rep == 0) first = t1 - t0;
        if (rep == 0 || t1 - t0 < best) best = t1 - t0;
    }
    printf("%u %lld %lld\n", (total * 10u + (SIZE / 2)) / SIZE,
           (long long)best, (long long)first);
    cudaFree(d_img); cudaFree(d_acc);
    return 0;
}
