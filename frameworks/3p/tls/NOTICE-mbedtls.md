# mbedTLS — third-party

The static libraries in `mbedtls-linux/` are prebuilt **mbedTLS 4.2.0**,
redistributed unmodified:

    libmbedtls.a  libmbedcrypto.a  libmbedx509.a  libtfpsacrypto.a

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
are GPLv3; only the `.a` files in `mbedtls-linux/` are mbedTLS.
