# Cross-architecture performance harness

`make perf` compiles every kernel in `kernels/*.xc` through all five backends and
records a per-backend metric plus a cross-backend checksum, comparing against
`baseline.json`.

## What it measures

| backend | headline metric | runs on this host? | checksum |
|---------|-----------------|--------------------|----------|
| m68k    | **dynamic** instruction count (`xst --cycles`) | yes | yes |
| xt6502  | **dynamic** instruction count (`xts --cycles`) | yes | yes |
| arm64   | **static** insns in the kernel's own functions | yes (native) | yes |
| x86_64  | **static** insns in the kernel's own functions | no (Linux ELF) | no |
| arm9    | **static** insns in the kernel's own functions | no (qemu-system) | no |

- **Dynamic instruction count** comes from the `xst` / `xts` simulators and is
  exact and deterministic: the real per-run cost, and the number to watch for
  these two simulated targets.
- **Static instruction count** is the number of instructions emitted for the
  *user's own* functions (the constant library runtime is excluded by scoping to
  the `.globl`-declared kernel symbols). It's a code-density regression signal
  for the targets that don't execute on the macOS/arm64 host. It is comparable
  for one backend over time, **not** between different ISAs.

Kernels are integer-only and print a checksum with `%ld`, so every backend that
runs must agree. A divergence is a **miscompile**, not a perf delta, and fails
the run, so the harness doubles as a differential correctness check.

## Usage

```
make perf                          # measure + compare to baseline
make perf PERF_ARGS=--update       # rewrite baseline.json with current numbers
python3 tests/perf/run_perf.py --kernel reduce
python3 tests/perf/run_perf.py --threshold 3
```

Exit code: `0` ok, `1` a metric regressed past the threshold (default 2%),
`2` a checksum diverged across backends.

## Wall-clock vs a reference compiler (`--bench`)

```
make perf PERF_ARGS=--bench        # xtc vs clang (arm64) / gcc (x86_64)
```

Times the array kernels against a real optimising compiler at a large workload:

- **arm64** runs locally: xtc vs `clang -O3`, both native.
- **x86_64** runs on a Linux host over ssh: `XTC_PERF_REMOTE` from `build.env`,
  falling back to `XTC_LINUX_HOST`. It times xtc's ELF vs `gcc -O3`. The ELF and
  the C source are copied over, gcc-compiled there, and both timed with GNU
  `/usr/bin/time`.

The kernels are built `-DBENCH`: `main(argc,…)` seeds the array from `argc`
(runtime-opaque, so the reference compiler can't constant-fold the loads away)
and uses a `u32` accumulator so REPS can be large. Each target verifies the xtc
and reference checksums agree; a divergence is a **miscompile vs a real
compiler** and fails the bench.

Reference numbers (Jul 2026, macOS/arm64 host): xtc is ~3× clang/gcc on `reduce`
but ~25× (arm64) / diverges (x86_64) on `map` and ~37–47× on `dot`. clang/gcc
vectorise the map/dot patterns that xtc's backends lower to scalar code.

### Known finding

`--bench` currently exits 2: **x86_64 miscompiles `map`** (the store-loop +
read-loop pattern). This is independent of the bench: the default `map` kernel
gives 6041600 on x86_64 vs the correct 12275200 (agreed by arm64/m68k/xt6502).
`reduce` and `dot` are correct on x86_64.

## Adding a kernel

Drop a `<name>.xc` in `kernels/`. Keep it integer-only, give it a fixed workload
(so the instruction count is stable), and print a single `%ld` checksum as the
last line of output. Then `make perf PERF_ARGS=--update` to record its baseline.

## Known limitations (v1)

- **arm64 / x86_64** have no dynamic count here: arm64 is sub-millisecond at
  these workloads (wall-clock is noise) and x86_64 is a Linux ELF with no
  `qemu-user` on the macOS host. Their headline is the static count; `--bench`
  covers wall-clock against a reference compiler.
- **arm9** runs only under the `qemu-system-arm` loader (the corpus drives it),
  and its checksum and a dynamic count are not wired through that shell
  protocol. It reports the static count only.
