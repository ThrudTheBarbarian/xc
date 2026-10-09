// nbody — benchmark/par/nbody.xc written by hand in bare CUDA.
// Same data, same arithmetic, same eight runs, same checksum. GPU only.
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <cuda_runtime.h>
#include "../../../src/include/bench_time.h"

#define N 8192
#define THREADS 256

static void check(cudaError_t e, const char *what)
{
    if (e != cudaSuccess) { fprintf(stderr, "%s: %s\n", what, cudaGetErrorString(e)); exit(1); }
}

__global__ void forces(const float *px, const float *py, const float *mass,
                       float *fx, unsigned int n, unsigned int *acc)
{
    unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float ax = 0.0f;
    for (unsigned int j = 0; j < n; j++)
    {
        float dx = px[j] - px[i];
        float dy = py[j] - py[i];
        float d2 = dx * dx + dy * dy + 0.0001f;
        ax = ax + mass[j] * dx / (d2 * sqrtf(d2));
    }
    fx[i] = ax;
    if (ax > 0.0f) atomicAdd(acc, 1u);
}

int main(void)
{
    static float px[N], py[N], mass[N], fx[N];
    float *d_px = 0, *d_py = 0, *d_mass = 0, *d_fx = 0;
    unsigned int *d_acc = 0;
    unsigned int right = 0;
    int64_t best = 0, first = 0;

    uint32_t seed = 7;
    for (uint32_t i = 0; i < N; i++)
    {
        seed = seed * 1664525u + 1013904223u;
        px[i] = (float)(seed >> 8) / 16777216.0f;
        seed = seed * 1664525u + 1013904223u;
        py[i] = (float)(seed >> 8) / 16777216.0f;
        mass[i] = 1.0f + (float)(i % 7);
    }
    unsigned int blocks = (N + THREADS - 1) / THREADS;
    for (unsigned int rep = 0; rep < 8; rep++)
    {
        int64_t t0 = bench_now_us();
        if (rep == 0)
        {
            cudaFree(0);
            check(cudaMalloc(&d_px, N * sizeof(float)), "malloc px");
            check(cudaMalloc(&d_py, N * sizeof(float)), "malloc py");
            check(cudaMalloc(&d_mass, N * sizeof(float)), "malloc mass");
            check(cudaMalloc(&d_fx, N * sizeof(float)), "malloc fx");
            check(cudaMalloc(&d_acc, sizeof(unsigned int)), "malloc acc");
            check(cudaMemcpy(d_px, px, N * sizeof(float), cudaMemcpyHostToDevice), "in px");
            check(cudaMemcpy(d_py, py, N * sizeof(float), cudaMemcpyHostToDevice), "in py");
            check(cudaMemcpy(d_mass, mass, N * sizeof(float), cudaMemcpyHostToDevice), "in mass");
        }
        check(cudaMemset(d_acc, 0, sizeof(unsigned int)), "memset");
        forces<<<blocks, THREADS>>>(d_px, d_py, d_mass, d_fx, N, d_acc);
        check(cudaMemcpy(&right, d_acc, sizeof(unsigned int), cudaMemcpyDeviceToHost), "copy acc");
        check(cudaMemcpy(fx, d_fx, N * sizeof(float), cudaMemcpyDeviceToHost), "copy fx");
        check(cudaDeviceSynchronize(), "sync");
        int64_t t1 = bench_now_us();
        if (rep == 0) first = t1 - t0;
        if (rep == 0 || t1 - t0 < best) best = t1 - t0;
    }
    printf("%u %lld %lld\n", (right + 50u) / 100u, (long long)best, (long long)first);
    cudaFree(d_px); cudaFree(d_py); cudaFree(d_mass); cudaFree(d_fx); cudaFree(d_acc);
    return 0;
}
