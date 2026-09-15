# `selfhost/` — the compiler, written in xtc

This tree holds the compiler written in xtc, plus the tools that prove it
matches the Objective-C compiler it was ported from.

The `xcc` that ships is built from here, which is the point of self-hosting: a
downloaded toolchain compiles xtc programs on its own, with no Objective-C
compiler present. The Objective-C build in `src/` bootstraps this one and is the
reference the differentials compare it against. It ships beside `xcc` as
`xcc-bootstrap` and is never what compiles your code.

## Layout

```
selfhost/
  lexer/       Token.xc  TokenType.xc  Lexer.xc  FloatEncoding.xc  BigNat.xc
  preproc/     MacroDef.xc  Preprocessor.xc
  parser/      Node.xc  Parser.xc  AstDump.xc
  sema/        Analyze.xc  Sema.xc  Mangle.xc  Overload.xc  Iface.xc  Dwarf.xc …
  ir/          Ir.xc  IrParse.xc  Lower.xc
  opt/         Opt.xc
  codegen/     Arm64.xc  Arm9.xc  M68k.xc  X86_64.xc  Xt6502.xc  Layout.xc …
  asm/         Arm64Asm.xc  X86Asm.xc  Arm32.xc  ElfObject.xc  CoffObject.xc …
  link/        Apk.xc  ApkSign.xc  CodeSign.xc  RsaKeygen.xc  Bignum.xc
  driver/      Frontend.xc  Designable.xc  Runtime6502.xc
  tools/       the drivers (xtlex.xc, xtfe.xc, xcc.xc, xtcg*.xc, xtas*.xc,
               xtld*.xc), the *-diff.sh harnesses, and gen-token-types.py,
               which generates lexer/TokenType.xc
```

### Virtual slot numbering

Slots are PROGRAM-WIDE: every class implementing the method behind slot N puts
its implementation at index N. A slot number is an ABI fact and has to match.

The algorithm (`computeOverriddenMethods` + `computeVirtualMethodTables` in
src/xtc/sema/XTSemanticAnalyzer+Analysis.m) is: override ROOTS first, numbered
in sorted label order, then every protocol's methods, protocols in sorted name
order and methods in declaration order.

Three things decide how many slots a class gets, and a port has to model all
three to reach the same numbers:

* A class with no explicit parent still HAS one (Object), and sema
  SYNTHESISES a `description()` on every class that lacks one. Together these
  make `_cls_Object_description` an override root and give it slot 0. Both are
  needed before any number is right.
* Appending the synthesised method to the class node makes the DUMP grow a
  line the comparison then trips on, so synthesis has to be modelled without
  adding a child, or the dumper taught to skip it.
* Signatures are compared as resolved TYPES, not by spelling. `string` and
  `u8@` are one parameter type, as is a typedef against what it stands for. A
  port that compares spellings finds too few override roots.

`parser/AstDump.xc` prints the tree for BOTH the parser and the analyser
harness (one walk, a mode flag), because two walks drift the moment either
format changes. The original makes the same choice for the same reason.

## How a module is proved

Every module has an **oracle** (a flag on the Objective-C `xtc-fe` that dumps
one stage's output in a canonical text form) and a **driver** in xtc that
prints the same form. A harness runs both over every `.xc` file in the tree and
diffs them **byte for byte**.

| Stage | Oracle | Driver | Harness |
|---|---|---|---|
| Lexer | `xtc-fe --dump-tokens` | `tools/xtlex.xc` | `tools/lexer-diff.sh` |
| Preprocessor | `xtc-fe --dump-pp` | `tools/xtpp.xc` | `tools/pp-diff.sh` |
| Parser | `xtc-fe --dump-ast` | `tools/xtast.xc` | `tools/ast-diff.sh` |
| Analyser | `xtc-fe --dump-sema` | `tools/xtsema.xc` | `tools/sema-diff.sh` |

The later stages follow the same pattern: `tools/` holds a driver and a
`*-diff.sh` harness for the IR, the optimiser, each code generator, each
assembler and each linker. `tools/all-diff.sh` runs the set.

A file the oracle cannot process is reported as ORACLE FAILED rather than
counted as agreement, so a file neither side could parse never looks like a file
both sides parsed identically. There is no "close enough": a stage that
disagrees anywhere disagrees.

## Reading the code

Two choices will look odd otherwise.

**The ports are FAITHFUL, not improved.** Every quirk of the original is
reproduced: `#` lexes as an identifier, a lone apostrophe survives, a macro
body's trailing `// comment` is stripped at definition time, an inactive `#if`
branch emits blank lines rather than nothing. A "better" version is a version
that disagrees.

**Where a port cannot be faithful, the source says so.** Integer literals are
u32 because xtc has no 64-bit integer; columns count bytes rather than UTF-16
units; three double constants differ in their last mantissa bit because the
decimal→binary conversion is not correctly rounded. Each of those is a comment
at the site.

## The AST is one class, not forty-seven

`parser/Node.xc` is a single node type carrying a kind and a few general fields,
where `src/xtc/ast/` has ~47 classes. xtc has no generics, so 47 classes would
mean 47 downcasts at every visitor site. The harness compares the tree's SHAPE,
and one dispatch on `kind` is what a later sema pass wants anyway.

## If you change something here

1. `make selfhost`: about a minute, and it names the file and the differing lines.
2. `VERBOSE=1 selfhost/tools/ast-diff.sh` prints the first differing lines per
   file, which is usually enough to name the construct.
3. `selfhost/tools/ast-diff.sh path/to/one.xc` checks a single file.

`lexer/TokenType.xc` is **generated** (`python3 selfhost/tools/gen-token-types.py`)
because the token numbers are a contract with the Objective-C enum. Editing it
by hand lets the two drift silently.

## Compiler bugs the port found

Porting the compiler found eight bugs the corpus fixtures never covered: a loop that would not compile, two assembler holes, a float
codegen bug, two ARC lifetime holes, a cast that would not parse, and a
`static` ivar that was parsed and discarded. All eight are fixed. The two ARC
bugs were fixed by a convention change (every class-pointer return is +1)
rather than a patch.
