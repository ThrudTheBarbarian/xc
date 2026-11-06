---
title: Environment & settings
description: Every XC_ environment variable, the settings store each program keeps (macOS defaults, the Windows registry, ~/.config), and how to read, set and clear what par keeps there.
---

A compiled xc program can be steered from outside without being rebuilt, in
two ways:

- **Environment variables**, for one run: `XC_PAR=cpu ./game`.
- **The program's settings store**, which lasts: a choice you write there
  holds for every later run, and `par` keeps what it measures there too.

xcc itself reads a few variables while it compiles; they are listed
[at the end](#while-compiling).

## Where a program's settings live

Each program has its own store, named after its executable (`game` for
`./game`, `game` for `game.exe`), and it belongs to the current user. It is
the platform's own store where there is one, else a text file. The examples
below set `par`, the key that chooses where every `par` block runs.

### macOS

The user's preferences, domain `game`: the store `defaults` reads and
`NSUserDefaults` is built on.

```bash
defaults read game                 # every setting
defaults write game par cpu        # set one
defaults read game par             # read one
defaults delete game par           # remove one
```

A value written as a number or a boolean (`defaults write game n -int 3`)
reads back in decimal or as `true`/`false`; the program writes strings.

### Windows

The registry key `HKEY_CURRENT_USER\Software\game`, one string value
(`REG_SZ`) per setting. It is per user, under `HKEY_CURRENT_USER` rather than
`HKEY_LOCAL_MACHINE`, so one user's settings do not change another's and no
administrator rights are needed.

```bat
reg query HKCU\Software\game
reg add HKCU\Software\game /v par /t REG_SZ /d cpu /f
reg query HKCU\Software\game /v par
reg delete HKCU\Software\game /v par /f
```

`regedit` shows the same key. A `DWORD` value reads back in decimal.

### Linux, Android and the Raspberry Pi

The text file `$XDG_CONFIG_HOME/game.conf`, or `~/.config/game.conf` when
`XDG_CONFIG_HOME` is not set. It is one `key = value` per line; `#` starts a
comment, blank lines are ignored and both sides are trimmed, so it is meant
to be edited by hand:

```ini
# ~/.config/game.conf
par = auto
par.physics = gpu
par.blur = 200000
```

```bash
cat ~/.config/game.conf                        # every setting
echo 'par = cpu' >> ~/.config/game.conf        # set one
sed -i '/^par *=/d' ~/.config/game.conf        # remove one
```

The file is created the first time the program saves a setting. A program
writes it back in full, keys in the order they were set, and comments and
blank lines are not kept: `par`'s `auto` saves the file whenever it learns
something, so keep notes elsewhere.

### In a browser

A program compiled for the web (wasm32) keeps its settings in the page's
`localStorage`, under the item `game`, as a JSON object of strings. In the
browser's console:

```js
JSON.parse(localStorage.getItem("game"))                  // every setting
const s = JSON.parse(localStorage.getItem("game") || "{}");
s.par = "cpu"; localStorage.setItem("game", JSON.stringify(s));   // set one
```

### Any platform: one directory for everything

Set `XCC_SETTINGS_DIR` and every store becomes the text file
`$XCC_SETTINGS_DIR/<program>.conf`, on macOS and Windows as well, in the
format above. That is the easy way to try settings out, or to keep them with
a project:

```bash
mkdir -p settings
XCC_SETTINGS_DIR=$PWD/settings ./game
cat settings/game.conf
```

A program's own values use the same store, through
[Settings](/compiler/api/settings/) (`Settings.standard("game")`), which
describes the format in full.

## What `par` keeps in the store

[Parallel blocks](/compiler/language/par/) read your choices from the store
and keep what `auto` measures there. A block's name is the one in
`par name { … }`, or `file:line` for an unnamed block (`saxpy.xc:12`, or
`perlin.c:41` for a loop lifted from C). `XC_PAR_REPORT=1` prints every
block's name as it runs.

### Your choices

The program reads these and never writes them:

| Key | Value | Effect |
|---|---|---|
| `par.<block>` | `cpu`, `gpu`, `gpus`, `all`, `auto` | that block runs there (`gpus`: every GPU, tiled; `all`: every GPU and the CPU) |
| `par.<block>` | a number, e.g. `200000` | that block runs on the GPU from that many items up, on the CPU below |
| `par` | the same values | every block without its own key |

For example, on a Mac, to keep `physics` on the GPU and let everything else
choose:

```bash
defaults write game par.physics gpu
defaults write game par auto
```

### What `auto` keeps

`auto` writes these itself. The keys carry the compiler version, so a new
release measures afresh, and records from other versions are removed the
first time a program from the new one runs:

| Key | What it holds |
|---|---|
| `par.learned.v<version>.<hw>.<block>.<code>` | the largest size the CPU won at and the smallest the GPU won at (`-1`: not yet); on a machine with several kinds of GPU, the interface it chose |
| `par.measuring.v<version>.…` | a measurement still in progress, so it can finish over several runs |
| `par.probe.v<version>.…` | what an [`XC_PAR_PROBE`](#par-at-run-time) run found for each worker |

`<hw>` is a hash of the machine's GPUs and CPU, so a new GPU is measured
afresh and the old one's records wait in case it comes back; `<code>` is a
hash of the block's GPU version, so a block you change is measured afresh
too. [How auto learns](/compiler/language/par/#how-auto-learns-across-runs-of-different-sizes)
explains the two numbers.

To make a program measure everything again, run it once with
`XC_PAR_FORGET=1`, which removes its `par.learned` and `par.measuring`
records (your own `par` keys and the probe records stay). Or delete the
keys by hand, with the commands above.

### Remote GPUs

A program that uses other machines' GPUs through [xcd](/compiler/language/par/#across-machines-xcd)
keeps the certificate it first sees from each daemon in a separate store
named `par` (on a Mac, `defaults read par`; elsewhere `par.conf` or
`HKCU\Software\par`), as `tls.pin.<host>:<port>`. A daemon whose
certificate changes is refused; delete its key to accept the new one.

### Which choice wins

For each block, the first of these that applies decides:

1. `XC_PAR` in the environment, for every block in that run.
2. Your settings: `par.<block>`, then `par`.
3. The program's own [`Par.device(…)`](/compiler/language/par/) for the block, or for every block.
4. The block's `:device(…)` default in the source.
5. `auto`, using what it has learned, and measuring when it has to.

A `par.<block> = auto` of yours therefore overrides the program's
`Par.device` and the block's default.

## Environment variables a program reads

All of these are read when the program runs, so no rebuild is needed. An
empty value is the same as an unset one.

### par at run time

| Variable | Values | Default | Effect |
|---|---|---|---|
| `XC_PAR` | `cpu`, `gpu`, `gpus`, `all`, `auto` | unset: your settings, then the program's choices, then `auto` | every `par` block runs there. `cpu` also stops looking for remote daemons |
| `XC_PAR_THREADS` | a number above 0 | the machine's CPU count | how many threads a block on the CPU uses |
| `XC_PAR_REPORT` | `1`, or `2` | off | prints where each block ran, how long it took, why it stayed on the CPU, and what `auto` measured and learned. `2` adds each tile's worker and time |
| `XC_PAR_FORGET` | `1` | off | removes the program's `par.learned` and `par.measuring` records when it starts, so `auto` measures again |
| `XC_PAR_GPU` | `cuda`, `vulkan` | CUDA where there is a CUDA card, else Vulkan | which GPU interface is used where both exist (Windows, Linux on x86-64) |
| `XC_PAR_VULKAN_DEVICE` | a number, `0` up | a discrete GPU, else an integrated one, else the first | which Vulkan device, by its index in the driver's list |
| `XC_PAR_CUDA_DEVICES` | numbers, e.g. `0,1` | every CUDA card | which CUDA cards take tiles, by ordinal |
| `XC_PAR_WORKERS` | a list of `cpu`, `cuda`, `metal`, `vulkan`, `remote` | every GPU and the CPU | the devices that share a block's tiles; every block then runs on that set |
| `XC_PAR_TILES` | `0` | on | `0` runs each block in one piece instead of tiles, for comparison |
| `XC_PAR_TILE_MB` | a number, `1`–`1024` | `8` | how many megabytes a tile moves each way |
| `XC_PAR_PROBE` | `1` | off | a block's first run measures every worker at each tile size and keeps the result in the store as a starting point for `auto` |
| `XC_PAR_TRACE` | `1`, a file path, or `host:port` | off | records each run's tiles: `1` writes `par-trace.xcpt` here, a path writes there, `host:port` streams to xcmon |
| `XC_PAR_PIN` | `0` | on | Linux: `0` leaves the CPU threads unpinned instead of pinning each to its own core |

### Remote GPUs (xcd)

| Variable | Values | Default | Effect |
|---|---|---|---|
| `XC_PAR_REMOTE` | `host[:port],…`, `mdns`, or `none` | none, unless `XC_PAR_POOL` is set | the xcd daemons the program may send tiles to; `mdns` finds them on the local network |
| `XC_PAR_POOL` | a pool name | unset | finds the daemons of that pool by mDNS; setting it alone turns discovery on |
| `XC_PAR_SECRET` | the pool's secret | none | proves to the daemons that the program belongs to the pool |
| `XC_PAR_VERIFY` | `0`, `all` | checks a sample | how many of a remote daemon's tiles are checked on the CPU (exact integer blocks only); a mismatch drops the daemon |
| `XC_TLS_LIB` | a file path | beside the program, then the toolchain, then the system | the TLS library for connections to daemons |

### Other

| Variable | Values | Default | Effect |
|---|---|---|---|
| `XC_SIMD` | `base`, `avx2`, `avx512` | the best the CPU supports | x86-64 only: which version of each [`-msimd=auto`](/compiler/usage/cli/) function runs; asking for more than the CPU has falls back, with a note on stderr |
| `XCC_SETTINGS_DIR` | a directory | unset | every settings store becomes `<dir>/<name>.conf` ([above](#where-a-programs-settings-live)) |
| `XDG_CONFIG_HOME` | a directory | `~/.config` | where the text stores are kept on Linux and Android |
| `XCC_BUNDLE_ROOT` | a directory | the program's own directory | the root [Bundle](/compiler/api/bundle/) resources are found from |
| `XCC_PLUGIN_STORE` | a directory | `~/.xcc/plugins` | where [plugins](/compiler/api/plugin/) are kept |
| `XCD_HOME` | a directory | `~/.xcc/xcd` | xcd: where the daemon keeps its certificate |

In a browser (wasm32), a program reads these from `globalThis.xccEnv`, an
object of strings the page sets before it starts the program.

## While compiling

xcc reads these when it builds a program:

| Variable | Effect |
|---|---|
| `XCC_HOME` | the toolchain's root, searched first (also `XTC_HOME`) |
| `XCC_3P` | the root of the third-party libraries `#import <…>` finds, searched first |
| `XCC_DEBUG_DIR` | directories (`:`-separated) searched for C libraries' separate debug files; default `/usr/lib/debug` |
| `XTC_LDFLAGS` | extra arguments for the link, separated by spaces |
| `SDKROOT` | the Apple SDK, tried first |
| `XCC_SIGN_PASSPHRASE` | the passphrase of the key `--sign` uses |
| `XC_PAR_REMOTE` | set (and not `none`) when building: the program carries every GPU form of its blocks, so a remote daemon can run any of them (as `-fpar-kernels=all`) |
| `XC_C_TRACE` | [C programs](/compiler/usage/c-programs/): lists the functions left to clang, and why |
