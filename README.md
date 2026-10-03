# xc

The xc compiler, its GUI framework and the tools and applications built with
them.

| Path | Contents |
|---|---|
| `compiler/` | The `xcc` toolchain: front end, IR, back ends, assemblers, linkers, simulators and standard library. |
| `frameworks/uxkit/` | UXKit, the cross-platform GUI framework. |
| `frameworks/3p/` | Bundled third-party libraries, such as `tls` (Mbed TLS and its shim). |
| `apps/rocks/` | Rocks, a GEM resource and UI editor. |
| `benchmark/` | Benchmark and report generation for the compiler. |
| `website/site/` | The documentation site for <https://compile-xc.org>. |
| `website/downloads/` | Release archives served by the site. These are not tracked. |
| `tools/release/` | Packaging and deployment scripts. |
| `tools/c2xc/` | A converter from C to xc. |

## How the repository is divided

It is one repository, but it is worked on as several separate streams, and each
stream stays inside its own tree.

| Stream | Trees |
|---|---|
| Compiler | `compiler/` — the `xcc` toolchain: front end, IR, back ends, assemblers, linkers, simulators, standard library, tests and the differential gates. |
| Frameworks | `frameworks/uxkit/`, `frameworks/3p/` — the GUI framework and bundled third-party libraries. |
| Applications | `apps/` — programs built on the frameworks. |
| Website | `website/` — the site and the release archives it serves. |
| Tools | `tools/` — packaging, deployment and the C-to-xc converter. |
| Benchmarks | `benchmark/` — the benchmark runs and their reports. |

Two rules keep the streams' work apart:

* A change is made in one tree. Compiler work stays in `compiler/` and
  framework work stays in `frameworks/`; the compiler's tests and gates read
  only the compiler's own tree and never `frameworks/`.
* An application or framework builds against the installed `xcc` toolchain, as
  an external project would, and never against paths inside `compiler/`.
  Something that only builds in a full checkout is a bug, because it cannot
  build for anyone else.

One rule keeps the streams' commits apart, because they share one `main`:

* Push `main` only when every commit it would send is your own stream's.
  Check `git log origin/main..main` (what the push sends, not
  `main..origin/main`). A commit from another stream that is still local may
  not have passed its gates yet, so ask its owner before it goes out. The
  frameworks and applications streams push only with
  `private/frameworks/uxkit/tools/safe_push.sh`, which lists those commits and
  refuses if any of them touches a tree outside `frameworks/`, `apps/rocks/`
  and the UXKit pages of the website.

`private/` is not part of the repository. It is ignored by git and holds the
working rules, the notes on open and fixed bugs, and other material that is
never published. Nothing under it is ever committed.

## Building

Build and install the compiler first (see [compiler/USAGE.md](compiler/USAGE.md)),
then build whichever other tree you are working in against it.

Settings that depend on your machines, such as the Linux test host or the
location of the GEM desktop sources, live in `build.env` at the repository
root. Copy `build.env.template` to `build.env` and fill in the values you need.
`build.env` is ignored by git. A variable left empty turns off the step that
needs it.

## Licensing

See [LICENSING.md](LICENSING.md).

## Checkin history

My apologies but I wasn't great at keeping private details out of the ~3000 or so checkins made to get this far, and the thought of going back and changing everything didn't really appeal. So, clean start, and I'll be more diligent from now on...

