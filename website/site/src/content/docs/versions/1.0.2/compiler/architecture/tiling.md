---
title: Tiles, devices and the network
description: Transparent, scalable network tiling. The xcc runtime cuts a par block into tiles and schedules them by earliest estimated finish across every CPU core, GPUs from different vendors at once (CUDA, Vulkan, Metal), and remote GPUs served by the xcd daemon over TLS, with deterministic results.
slug: versions/1.0.2/compiler/architecture/tiling
banner:
  content: 'This is the documentation for xc 1.0.2. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

One `par` block can run on many devices at once. The runtime cuts it into **tiles** and
hands them to every device that can take one: the CPU's cores, each local GPU whatever its
vendor, and GPUs on other machines. A remote GPU is one more worker in the same queue, so
the program does not change when the network does: **transparent, scalable network
tiling**.

<svg class="xc-diagram" viewBox="0 0 860 330" style="max-width:860px" role="img" aria-label="Tiling: one par block cut into tiles, scheduled by earliest estimated finish across CUDA, Vulkan and Metal GPUs, the CPU pool, and remote GPUs served by xcd over TLS">
<rect class="key" x="10" y="120" width="140" height="80" rx="6"/>
<text x="80" y="147.5" text-anchor="middle" class="head">One par block</text>
<text x="80" y="164.5" text-anchor="middle" class="muted">n items, with each</text>
<text x="80" y="181.5" text-anchor="middle" class="muted">array's footprint</text>
<rect class="box" x="190" y="120" width="160" height="80" rx="6"/>
<text x="270" y="139.0" text-anchor="middle" class="head">Tile queue</text>
<text x="270" y="156.0" text-anchor="middle" class="muted">earliest estimated</text>
<text x="270" y="173.0" text-anchor="middle" class="muted">finish; lost tiles</text>
<text x="270" y="190.0" text-anchor="middle" class="muted">re-issued first</text>
<path class="line" d="M150 160 L190 160"/>
<polygon class="arrow" points="190,160 183,156 183,164"/>
<rect class="box" x="420" y="10" width="170" height="50" rx="6"/>
<text x="505" y="31.0" text-anchor="middle" class="head">CUDA GPU</text>
<text x="505" y="48.0" text-anchor="middle" class="muted">3 tiles in flight</text>
<path class="line" d="M350 160 L385 160 L385 35 L420 35"/>
<polygon class="arrow" points="420,35 413,31 413,39"/>
<rect class="box" x="420" y="72" width="170" height="50" rx="6"/>
<text x="505" y="93.0" text-anchor="middle" class="head">Vulkan GPU</text>
<text x="505" y="110.0" text-anchor="middle" class="muted">any vendor, 3 in flight</text>
<path class="line" d="M350 160 L385 160 L385 97 L420 97"/>
<polygon class="arrow" points="420,97 413,93 413,101"/>
<rect class="box" x="420" y="134" width="170" height="50" rx="6"/>
<text x="505" y="155.0" text-anchor="middle" class="head">Metal GPU</text>
<text x="505" y="172.0" text-anchor="middle" class="muted">3 tiles in flight</text>
<path class="line" d="M350 160 L385 160 L385 159 L420 159"/>
<polygon class="arrow" points="420,159 413,155 413,163"/>
<rect class="box" x="420" y="196" width="170" height="50" rx="6"/>
<text x="505" y="217.0" text-anchor="middle" class="head">CPU pool</text>
<text x="505" y="234.0" text-anchor="middle" class="muted">every core, SIMD</text>
<path class="line" d="M350 160 L385 160 L385 221 L420 221"/>
<polygon class="arrow" points="420,221 413,217 413,225"/>
<rect class="key" x="420" y="258" width="170" height="50" rx="6"/>
<text x="505" y="279.0" text-anchor="middle" class="head">Remote GPU</text>
<text x="505" y="296.0" text-anchor="middle" class="muted">xcd over TLS, cached data</text>
<path class="line" d="M350 160 L385 160 L385 283 L420 283"/>
<polygon class="arrow" points="420,283 413,279 413,287"/>
<rect class="box" x="660" y="120" width="190" height="80" rx="6"/>
<text x="755" y="147.5" text-anchor="middle" class="head">Results merged</text>
<text x="755" y="164.5" text-anchor="middle" class="muted">in tile order: the same</text>
<text x="755" y="181.5" text-anchor="middle" class="muted">answer on any devices</text>
<path class="line" d="M590 35 L625 35 L625 160 L660 160"/>
<polygon class="arrow" points="660,160 653,156 653,164"/>
<path class="line" d="M590 97 L625 97 L625 160 L660 160"/>
<polygon class="arrow" points="660,160 653,156 653,164"/>
<path class="line" d="M590 159 L625 159 L625 160 L660 160"/>
<polygon class="arrow" points="660,160 653,156 653,164"/>
<path class="line" d="M590 221 L625 221 L625 160 L660 160"/>
<polygon class="arrow" points="660,160 653,156 653,164"/>
<path class="line" d="M590 283 L625 283 L625 160 L660 160"/>
<polygon class="arrow" points="660,160 653,156 653,164"/>
</svg>

## Tiles

The compiler writes each array's **footprint** per item into the block, so the runtime knows
which slice of each array a tile reads and writes, and moves only that slice to a GPU across
a bus or a network.

The tile size follows the devices: large enough that a GPU's per-tile cost is a small share
of the run, small enough that every worker gets several tiles, and, for a remote GPU, large
enough that the link's latency stays a small fraction of a tile.

## Workers and scheduling

| Worker | Tiles in flight |
|---|---|
| each CUDA card | 3 |
| a Vulkan GPU, any vendor | 3 |
| the Metal GPU | 3 |
| a remote GPU | the depth its daemon offers |
| the CPU pool, every core | one tile at a time, split across the cores |

Each tile goes to the worker with the **earliest estimated finish**, from the rate it has
shown so far; a tile may wait for a faster worker rather than go to a slower free one. Rates
start from the run-time measurement. CUDA cards, a Vulkan GPU from another vendor, Metal, the
CPU and remote daemons all serve one queue in the same run, so an NVIDIA card through CUDA
and another through Vulkan work on the same block together.

**Results are deterministic.** Reductions from each tile are folded in tile order, whichever
device ran it, so the answer does not depend on which devices took part. A lost tile is
re-issued to another worker before any new tile.

## `xcd`: GPUs over the network

`xcd` is a daemon that serves a machine's GPUs to programs elsewhere on the network.

- **Discovery:** named by address, or found on the local network by **mDNS**
  (`_xcd._tcp`), within a named pool and the same compiler version.
- **Security:** every connection is **TLS**; the program pins the daemon's certificate on
  first use and refuses a changed one, and a shared secret admits a program.
- **Compatibility:** program and daemon agree the protocol, the compiler version, and the
  data layout (byte order and pointer width) before any work moves.
- **Caching:** kernels are sent once per connection; arrays and footprint slices are named
  by hash, and the daemon keeps them, so a second pass over the same data sends almost
  nothing. Slices it wrote stay cached under their new hash.
- **Fitting:** each tile is checked against the card's free memory, and a daemon whose card
  is full is given no more tiles.
- **Checking:** for integer kernels, the first tile from each daemon and every sixteenth
  after it are re-run on the local CPU and compared; a daemon that disagrees is dropped and
  the local result kept.
- **Liveness:** a heartbeat every second; a daemon that stops answering is dropped and its
  tiles go to other workers.

The run-time measurement includes remote GPUs as a candidate of their own, so a program
uses the network only where it is faster. See
[Performance: networked](/compiler/benchmarks/network/) for figures, including a Raspberry
Pi 5 using a remote RTX 5080.
