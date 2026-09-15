# xc

The xc compiler, its GUI framework and the tools and applications built with
them.

| Path | Contents |
|---|---|
| `compiler/` | The `xcc` toolchain: front end, IR, back ends, assemblers, linkers, simulators and standard library. |
| `frameworks/uxkit/` | UXKit, the cross-platform GUI framework. |
| `frameworks/3p/` | Bundled third-party libraries, such as `tls` (Mbed TLS and its shim). |
| `apps/rocks/` | Rocks, a GEM resource and UI editor. |
| `website/site/` | The documentation site for <https://compile-xc.org>. |
| `website/downloads/` | Release archives served by the site. These are not tracked. |
| `tools/release/` | Packaging and deployment scripts. |
| `tools/c2xc/` | A converter from C to xc. |

## Building

Build and install the compiler first (see [compiler/USAGE.md](compiler/USAGE.md)).
Applications and frameworks build against the installed `xcc` toolchain, the
same way an external project does, and never against paths inside
`compiler/`.

Settings that depend on your machines, such as the Linux test host or the
location of the GEM desktop sources, live in `build.env` at the repository
root. Copy `build.env.template` to `build.env` and fill in the values you need.
`build.env` is ignored by git. A variable left empty turns off the step that
needs it.

## Licensing

See [LICENSING.md](LICENSING.md).

## Checkin history

My apologies but I wasn't great at keeping private details out of the ~3000 or so checkins made to get this far, and the thought of going back and changing everything didn't really appeal. So, clean start, and I'll be more diligent from now on...

