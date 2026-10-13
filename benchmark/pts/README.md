# Phoronix Test Suite profile

`xc-par-1.0.0/` runs the par suite under the [Phoronix Test Suite](https://www.phoronix-test-suite.com/).
It downloads the published Linux compiler and benchmark sources (pinned by
SHA-256 in `downloads.xml`), builds the four programs at `-O3`, and offers each
on one CPU thread, every CPU thread, the GPU, every GPU, every device, or
`auto`. Each result is the best of the program's eight runs; the first run is
reported beside it.

A run is refused when the checksum is wrong, or when a GPU mode would run on
the CPU (no usable GPU): the program reports that under `XC_PAR_REPORT=1`.

    mkdir -p ~/.phoronix-test-suite/test-profiles/local
    cp -R xc-par-1.0.0 ~/.phoronix-test-suite/test-profiles/local/
    phoronix-test-suite benchmark local/xc-par-1.0.0

Each release needs a new profile version: the archive names, sizes and
checksums in `downloads.xml`, the names in `install.sh`, and `AppVersion`.
