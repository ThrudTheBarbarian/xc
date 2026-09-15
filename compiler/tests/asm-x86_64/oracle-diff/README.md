# x86-64 assembler oracle-diff

Byte-parity check for `XAX86_64Assembler`, the encoder for the self-hosted
**Linux** last stage (a Mac producing a Linux ELF with no Linux tooling). It
assembles Intel-syntax instructions with `clang -target x86_64-unknown-linux-gnu`
and byte-diffs each against the in-house encoder, so parity with clang is checked
against ground truth rather than a hand table.

x86-64 is **variable length**, so unlike the AArch64 harness the oracle's output
cannot be sliced at a fixed width. The harness disassembles the batch with
`objdump -d` and uses its per-instruction offsets to cut the reference bytes.

Needs `clang` + `objdump`, so it is not wired into `make test`. Run it with:

```sh
make oracle-x86_64
./bin/osx/oracle-x86_64 tests/asm-x86_64/oracle-diff/insns-sample.txt
```

To diff against every instruction the backend emits across the corpus,
generate the list the same way the arm64 side does (compile each fixture with
`-A x86_64 -S`, then collect the mnemonics/operands).

Status: the hot integer core (mov/lea/push/pop/ret/ALU/movzx/movsx/unary/test,
reg-reg, reg-imm and `[base+disp]` memory forms) is byte-identical to clang.
