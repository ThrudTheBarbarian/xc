**Mixing graphics APIs on one machine.** The `all GPUs` column above runs both NVIDIA cards through CUDA. The scheduler does not require one API, though: a block can run the RTX 5080 through CUDA beside the RTX 3090 through Vulkan, through the same tile queue. On the Windows host (ms, best of eight runs):

| both cards share a block | `saxpy` (16M) | `md5` (64M) |
|---|---|---|
| through CUDA (the `all GPUs` column) | 7.8 | 0.90 |
| 5080 through CUDA, 3090 through Vulkan | 9.6 | 1.02 |

The mixed pair is a little slower here only because the 3090 is slower through Vulkan than through CUDA; the point is that it runs at all. Two cards from different vendors — an NVIDIA through CUDA and an AMD through Vulkan — could share a block the same way.
