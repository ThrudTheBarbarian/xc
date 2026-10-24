# mbedTLS — third-party

The static libraries in `mbedtls-linux/` (x86-64 Linux, musl),
`mbedtls-win64/` (x86-64 Windows, mingw-w64), `mbedtls-android/` (arm64
Android, NDK r27 clang, API level 21, debug sections stripped) and
`mbedtls-ios/` (arm64 iOS 15, the iOS SDK's clang) are prebuilt
**mbedTLS 4.2.0**, built from the unmodified release:

    libmbedtls.a  libmbedcrypto.a  libmbedx509.a  libtfpsacrypto.a

The Windows libraries were configured with CMake's Release build, testing and
programs off, `-D__USE_MINGW_ANSI_STDIO=0` (so they call the Universal C
Runtime's printf, which an xc DLL links against), and `-ffile-prefix-map` so
they name no build directory. The Android and iOS libraries were configured
the same way (CMake Release, no tests or programs, `-ffile-prefix-map`), with
the NDK's `android.toolchain.cmake` for `arm64-v8a` and `CMAKE_SYSTEM_NAME=iOS`
for the device SDK.

The Linux libraries are built with threading on: `MBEDTLS_THREADING_C` and
`MBEDTLS_THREADING_PTHREAD` defined in `tf-psa-crypto/include/psa/crypto_config.h`
(nothing else changed), CMake Release with the musl cross clang
(`/opt/clang/linux/bin/x86_64-linux-musl-clang`, `CMAKE_SYSTEM_NAME=Linux`),
no tests or programs, and `-ffile-prefix-map`. The PSA crypto core's random
generator and key slots are shared by every connection, and without threading
two handshakes at once could both fail (a daemon serving two programs). The
shim is compiled against headers with threading on, so the libraries must
match. The win64, Android and iOS libraries do not have it yet.

- **Licence:** dual **Apache-2.0 OR GPL-2.0-or-later** — the user chooses.
  Full text in `LICENSE-mbedtls.txt`.
- **Upstream:** <https://github.com/Mbed-TLS/mbedtls>
- **Release:** <https://github.com/Mbed-TLS/mbedtls/releases/tag/mbedtls-4.2.0>

The dual licence is convenient here: Apache-2.0 is one-way compatible with
GPLv3, and the GPL-2.0-or-later arm can be taken as GPLv3 directly, so mbedTLS
combines with this repository's GPLv3 either way round.

Redistributing it in binary form requires the licence to travel with it, which
is what this directory now carries. mbedTLS's own terms are unaffected by the
GPLv3 that covers the rest of this repository — see
[LICENSING.md](../../../LICENSING.md).

`tlsshim.c`, `tlsshim.h`, `install.sh` and everything under `xc/` are ours and
are GPLv3; only the `.a` files in `mbedtls-linux/`, `mbedtls-win64/`,
`mbedtls-android/` and `mbedtls-ios/` are mbedTLS.
