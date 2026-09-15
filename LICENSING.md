# Licensing

Short version:

- **The compiler is GPLv3.** Improve it, and share the improvements.
- **Programs you compile with it are yours.** No obligation of any kind,
  including for commercial and closed-source work.
- **UXKit is LGPLv3.** Build a closed application on it if you like; if you
  change UXKit itself, share that.

The rest of this file says which terms apply to which files, and why.

## The compiler — GPLv3

`compiler/` (the driver, front end, code generators, assemblers, linkers, the
simulators and the self-hosted sources), `tools/` and `apps/`.

See [COPYING](COPYING).

The copyleft is intentional: a fork that improves the compiler should come back
as an improvement to the compiler.

## What you compile — no obligation

Every program xcc builds contains some of xcc's own code. The standard library
(`Stdio`, `Object`, `Array`, `String` …) is compiled into your binary, and so is
the startup and runtime support. There is no shared runtime to link against
instead.

Under a plain GPL that would be contagious: your program would contain GPL'd
code, so your program would have to be GPL. That is not the intent, and it is
not what happens.

Everything under `compiler/support/` (the standard library in
`support/<arch>/lib/`, and the runtime and startup in `support/<arch>/runtime/`)
is GPLv3 **plus the GCC Runtime Library Exception**, the same additional
permission GCC uses for the same reason.

See [compiler/support/COPYING.RUNTIME](compiler/support/COPYING.RUNTIME).

The effect: **compile whatever you want, license it however you want, sell it
if you want.** The exception is what keeps the compiler's GPL out of your work.

It does not let you take the *library sources* into a proprietary project.
Using them as the compiler links them is free; forking them is GPL.

## UXKit — LGPLv3

`frameworks/uxkit/`, the cross-platform GUI toolkit (GEM, Win32, AppKit, GTK,
Web, iOS, Android).

See [frameworks/uxkit/COPYING.LESSER](frameworks/uxkit/COPYING.LESSER), which
applies alongside [frameworks/uxkit/COPYING](frameworks/uxkit/COPYING).

LGPL rather than GPL because a GUI toolkit that forces every application using
it to be open source is a toolkit nobody adopts. Link UXKit into anything,
including closed commercial software, with no obligation on your application.
Modifications to UXKit itself stay free.

## Third-party code, under its own terms

These components come from other projects and are not affected by the terms
above.

| Component | Licence | Where |
| --- | --- | --- |
| **mbedTLS** 4.2.0 (prebuilt `libmbedtls`, `libmbedcrypto`, `libmbedx509`, `libtfpsacrypto`) | Apache-2.0 **OR** GPL-2.0-or-later (dual) | `frameworks/3p/tls/` |
| **pycparser** 3.0 | BSD-3-Clause | `tools/c2xc/vendor/` |

mbedTLS is redistributed here in binary form, so its licence travels with it in
`frameworks/3p/tls/LICENSE-mbedtls.txt`, with the details in
`NOTICE-mbedtls.md`. The dual licence combines with GPLv3 either way:
Apache-2.0 is one-way compatible with GPLv3, and the GPL-2.0-**or-later** arm
can be taken as GPLv3 directly. Upstream:
<https://github.com/Mbed-TLS/mbedtls>.

pycparser is vendored unmodified with its own `dist-info`, licence included.
Upstream: <https://github.com/eliben/pycparser>.

## Contributing

Contributions are accepted under the licence of the file you are changing:
GPLv3 for the compiler, LGPLv3 for UXKit. No copyright assignment is required.
