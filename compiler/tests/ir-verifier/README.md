# Layer 2 verifier fixtures

Text fixtures for the IR verifier. Each `.ir` file is part of the specification
the verifier must meet.

## Files

Each fixture targets one mandatory verifier invariant.
Positive: minimal well-formed IR that satisfies the invariant.
Negative: minimal IR that violates it (a header comment explains how).

| #  | Invariant                        | Positive                                | Negative                                |
|----|----------------------------------|-----------------------------------------|-----------------------------------------|
| 1  | Single-def SSA                   | `positive/inv-01-single-def-ssa.ir`     | `negative/inv-01-single-def-ssa.ir`     |
| 2  | Operand types match def types    | `positive/inv-02-operand-types-match.ir`| `negative/inv-02-operand-types-match.ir`|
| 3  | One terminator per block         | `positive/inv-03-one-terminator.ir`     | `negative/inv-03-one-terminator.ir`     |
| 4  | Phi operands match preds         | `positive/inv-04-phi-matches-preds.ir`  | `negative/inv-04-phi-matches-preds.ir`  |
| 5  | Memory token used at most once   | `positive/inv-05-memory-single-use.ir`  | `negative/inv-05-memory-single-use.ir`  |
| 6  | Memory token reaches mem ops     | `positive/inv-06-memory-reaches-mem-ops.ir` | `negative/inv-06-memory-reaches-mem-ops.ir` |
| 7  | AddrOf only on pinnable values   | `positive/inv-07-addrof-pinnable.ir`    | `negative/inv-07-addrof-pinnable.ir`    |
| 8  | Symbol references resolve        | `positive/inv-08-symbol-resolves.ir`    | `negative/inv-08-symbol-resolves.ir`    |
| 9  | CallConv matches callee          | `positive/inv-09-callconv-matches.ir`   | `negative/inv-09-callconv-matches.ir`   |
| 10 | Block reachability               | `positive/inv-10-block-reachability.ir` | `negative/inv-10-block-reachability.ir` |
| 11 | Frame discipline                 | `positive/inv-11-frame-discipline.ir`   | `negative/inv-11-frame-discipline.ir`   |

The two `--paranoid` invariants (memory-chain topological order, statically
balanced retain/release) are not covered here.

## How the verifier consumes these

1. Each fixture is read with the IR text parser.
2. Each positive fixture must parse and verify cleanly.
3. Each negative fixture must parse cleanly and fail verification
   with a diagnostic that names the violated invariant.
4. Round-trip: parse → print → parse must be a fixed point on
   every positive fixture.
