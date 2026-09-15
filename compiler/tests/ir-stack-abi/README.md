# Stack-ABI reference fixtures

Tiny well-formed IR modules that illustrate the 6502 stack-frame limit. Each
sets a specific `pinnedLocalSize` + parameter signature that hits one side of
the boundary. The function body is always a trivial `Return`; only the frame
declaration matters.

The default verifier accepts all four, because each declared size matches the
pinned-local byte sum. The contract itself (`N + K ≤ 119`) is a 6502-backend
obligation, not a verifier invariant. An optional `--paranoid` verifier
invariant would catch `large-frame-overflow.ir`.

| Fixture | N (locals) | K (params) | N + K | Status |
|---------|----------:|----------:|------:|--------|
| `small-frame.ir`           |   8 | 2 |  10 | well within |
| `large-frame-ok.ir`        | 100 | 2 | 102 | comfortable |
| `large-frame-edge.ir`      | 117 | 1 | 118 | largest single-PSH frame |
| `large-frame-overflow.ir`  | 118 | 2 | 120 | **not encodable** on 6502 |

These are reference examples, not verifier fixtures (see `../ir-verifier`), and
they are not wired into the test runner. Round-trip parsing has been checked
by hand against `XTIRParser` / `XTIRPrinter`.
