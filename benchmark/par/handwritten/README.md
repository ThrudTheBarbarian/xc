# The `par` benchmarks, written by hand

`../mandelbrot.xc`, `nbody.xc`, `perlin.xc` and `saxpy.xc` each run their work
in one `par` block, on the CPU's threads or the GPU. These are the same four
programs written the way you would without `par`:

- `omp/` — C++ with OpenMP. The `par` block becomes one `#pragma`; the
  reduction becomes a reduction clause. **CPU only**: there is no GPU version
  of this on any GPU.
- `cuda/` — bare CUDA. A hand-written kernel, device buffers, `cudaMalloc` and
  `cudaMemcpy`, and an atomic reduction. **GPU only**: it runs on no CPU, and on
  no GPU but an NVIDIA one — not Metal, not Vulkan, not WebGPU.

Both are held to xc's benchmark exactly: the same data, the same arithmetic,
eight runs, the best kept and the first shown, timed with the same monotonic
clock the xc half uses (`clock_gettime(CLOCK_MONOTONIC)`, or
`QueryPerformanceCounter` on Windows). `omp/` uses
`schedule(static)`, the same contiguous one-chunk-per-thread split as a `par`
block, and every build gets `-O3 -march=native`, as the language benchmarks give
clang and GCC.

## They agree to the digit

Every one of the four hand-written C++ programs prints the same checksum as the
released 0.74 `xcc`:

| benchmark | checksum |
|---|---|
| `mandelbrot` | `199` |
| `nbody` | `42` |
| `perlin` | `243` |
| `saxpy` | `3011510272` |

So a timing between them is a timing between programs that compute the same
thing, which is the only kind worth taking.

## Building and running

```bash
# xc — one source, CPU threads and GPU, one binary
xcc -O3 -o mandelbrot mandelbrot.xc
XC_PAR=cpu ./mandelbrot      # every CPU thread
XC_PAR=gpu ./mandelbrot      # the GPU
XC_PAR=auto ./mandelbrot     # the default: measures and picks

# OpenMP — CPU threads only
g++ -O3 -march=native -fopenmp -o mandelbrot_omp omp/mandelbrot.cpp -lm
OMP_NUM_THREADS=$(nproc) ./mandelbrot_omp

# CUDA — GPU only, and only an NVIDIA one
nvcc -O3 -arch=native -o mandelbrot_cuda cuda/mandelbrot.cu   # or -arch=sm_86
./mandelbrot_cuda
```

On macOS, Apple's clang has no OpenMP; install it (`brew install libomp`) and
build with `-Xpreprocessor -fopenmp -lomp`, or use the Linux host. CUDA needs
`nvcc` and an NVIDIA GPU; the Mac cannot build it at all.

The first-run column of each program carries the same one-off costs as the xc
version: for `omp/`, starting the thread pool; for `cuda/`, creating the driver
context, JIT-compiling the PTX and allocating the device buffers. In the CUDA
program those happen inside the first timed run, so the two "first" figures
compare like with like.

## Ease of writing

Lines of code, comments and blanks stripped:

| benchmark | xc `par` | OpenMP | CUDA |
|---|---|---|---|
| `mandelbrot` | 42 | 37 | 54 |
| `nbody` | 53 | 46 | 73 |
| `perlin` | 90 | 77 | 100 |
| `saxpy` | 38 | 32 | 59 |
| **total** | **223** | **192** | **286** |

The xc column is *one* source per benchmark that runs on every core and, where
there is one, on the GPU. The OpenMP column is a little shorter and reaches no
GPU at all. The CUDA column is longer *and* starts from nothing: it cannot run
on the CPU, and it runs on no GPU but an NVIDIA one — the Metal, Vulkan and
WebGPU paths each want their own program again.

`perlin` is the clearest case. The permutation table is a global array in xc;
the block reads it and the compiler moves it to wherever the kernel needs it.
In CUDA it is a `__constant__` buffer and a `cudaMemcpyToSymbol` you write
yourself, and four `__device__` helpers you mark by hand.

## Honesty about the comparison

- The CUDA launch configuration is the plain one — one thread per work item, or
  a grid-stride loop — with no shared-memory tiling, no `__restrict__` and no
  async copies. It is deliberately untuned. With 0.74 these plain kernels were
  faster than `xcc`'s on three of the four programs, by 1.5x to 6.8x. From
  0.75, best of five on the test GPU (CUDA, microseconds, hand / xc):
  `mandelbrot` 211 / 301, `perlin` 675 / 750, `nbody` 1051 / 569, `saxpy`
  25014 / 25029. `nbody` is faster in xc because `:goal(speed)` issues
  approximate float maths; `saxpy` is level; `mandelbrot` and `perlin` remain
  slower, and the difference is in the kernel itself (the escape loop's test is
  not yet rotated on the GPU). So the argument here is still EASE first — 223
  lines of xc, one source, CPU and four GPU APIs — with performance now close
  on three of the four.
- From 0.75 the xc GPU path copies to the device only the arrays the block
  reads, and back only the ones it writes; a small table it only reads stays on
  the device while it is unchanged. These programs copy the same data: each
  uploads what its kernel reads and copies back what it writes. If xc stops
  copying something because the program never uses it, the matching program
  here stops too, so the two keep doing the same work.
- `perlin` and `mandelbrot` are arithmetic-bound and are the clean comparison.
  `saxpy` is the anti-benchmark: it is in the set to show that more hands on the
  GPU is not always faster, and that `auto` knows it.
