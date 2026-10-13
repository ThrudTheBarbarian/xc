**AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 and an RTX 3090, both on PCIe ×8 Gen4, each reached through CUDA and the 3090 also through Vulkan** (ms; best of eight runs). The GPU-heavy `mandelbrot`, `perlin` and `nbody` each finish in well under a millisecond on one card, where `auto` keeps them; the two benchmarks that show the device sets apart are the memory-bound `saxpy` and the compute-bound `md5`. Every row here runs through the multi-device tile queue, so a single card is a little slower than the direct single-shot `GPU` column in the table above (for `md5`, 1.12 ms against 0.9 ms): the queue is what lets two devices share a block.

| device set | `saxpy` (16M) | `md5` (64M) |
|---|---|---|
| CPU, all cores | 3.2 | 333 |
| RTX 5080, CUDA | 14.9 | 1.12 |
| RTX 3090, CUDA | 16.2 | 1.82 |
| RTX 3090, Vulkan | 17.1 | 1.96 |
| 5080 + 3090, both CUDA | 7.8 | 0.90 |
| 5080 CUDA + 3090 Vulkan | 9.6 | 1.02 |
| every device (both GPUs + CPU) | 5.1 | 160 |
| `auto` | 3.5 | 0.88 |
