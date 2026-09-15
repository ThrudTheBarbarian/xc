# AArch64 assembler oracle-diff

Full-corpus byte-parity check for `XAArm64Assembler`, the AArch64 encoder in the
self-hosted native toolchain. It assembles a list of AArch64 instructions with
`clang -c` and byte-diffs each against the in-house encoder, so parity with clang
is checked against ground truth rather than a hand-written table.

Needs `clang` + `otool` at runtime, so it is **not** wired into `make test`
(the self-contained golden subset in `../XAArm64AssemblerTests.m` is). Run it
explicitly:

```sh
make oracle-arm64
./bin/osx/oracle-arm64 tests/asm-arm64/oracle-diff/insns-sample.txt
```

`insns-sample.txt` is a small representative sample. To diff against **every**
instruction the backend emits across the whole fixture corpus:

```sh
./tests/asm-arm64/oracle-diff/gen-corpus-insns.sh > /tmp/all.txt
./bin/osx/oracle-arm64 /tmp/all.txt
```

The integer/scalar subset is 100% byte-identical to clang across the corpus
(20,156 instructions, 0 mismatches). The remaining mismatches are scalar-FP and
NEON (`s`/`d`/`v` registers, including NEON vectoriser output), which this
harness's encoder does not yet cover.
