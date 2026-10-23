---
title: Contributing
description: How a change gets into xc - the contributor licence agreement, where changes go, building and testing with an installed release, and review.
---

Thank you for helping. This file says how a change gets from your fork into
`main`: what to agree to first, where changes go, how to test them, and what
happens after you open a pull request.

## Before you start

- **Look for an issue first.** Work that is already under way has an issue
  with the `in progress` label. Issues marked `help wanted` are open to
  anyone. If you want to work on something that has no issue, open one and
  say what you plan to do, so nobody else starts the same thing.
- **Talk before large changes.** A new language feature, a new target, or a
  change to how the compiler is organised needs agreeing in an issue before
  the code is written. Small fixes can go straight to a pull request.

## The contributor licence agreement

Before your first pull request can be merged, you sign the
[contributor licence agreement](/contributor-licence/) once. The CLA Assistant bot asks you
on that pull request, and signing takes a minute.

You keep the copyright in what you write. The agreement gives Cognostem Ltd,
which runs the project, a licence to use your contribution, including the
right to publish it under other terms. That covers two things:

- **Changing a licence**, for example if the runtime exception or UXKit's
  licence ever has to change. Without the agreement, every contributor would
  have to be traced and asked first, which in practice means it could never
  happen.
- **Commercial licences.** A company that wants to distribute xc on terms
  other than its open-source licence can buy a commercial licence instead.

What the agreement promises in return: everything you contribute stays
available to everyone under its open-source licence, permanently. A
commercial licence is offered alongside the open-source one, never instead of
it. Only Cognostem can grant other terms; anyone else gets your work under
the open-source licence.

## Licences

Your contribution is published under the licence of the tree it goes into
(see [LICENSING.md](https://github.com/ThrudTheBarbarian/xc/blob/main/LICENSING.md)):

| Tree | Licence |
|---|---|
| `compiler/`, `tools/`, `apps/` | GPLv3 or later |
| `compiler/support/` (standard library, runtime) | GPLv3 or later, with the GCC Runtime Library Exception |
| `frameworks/uxkit/` | LGPLv3 or later |

A new file starts with the same header as the files beside it.

## Where changes go

The repository is one tree for several projects, and a pull request changes
**one** of them:

| Tree | What it is |
|---|---|
| `compiler/` | the `xcc` toolchain: front end, IR, back ends, assemblers, linkers, simulators, standard library and tests |
| `frameworks/` | UXKit and the bundled third-party libraries |
| `apps/` | programs built on the frameworks |
| `website/` | compile-xc.org |
| `tools/` | packaging, deployment and other tools |
| `benchmark/` | the benchmark programs and runners |

Compiler changes go in `compiler/selfhost/`, the compiler written in xc, which
is the compiler that ships. The tests and gates read only `compiler/`.

An application or framework builds against an installed `xcc`, as an outside
project would, and never against paths inside `compiler/`. If something only
builds in a full checkout, that is a bug.

## Building and testing

1. Install the current release from
   [compile-xc.org/compiler/downloads](https://compile-xc.org/compiler/downloads/).
2. Build the compiler from your checkout with it:

   ```bash
   cd compiler
   make contrib XCC=/opt/xcc/<version>/bin/xcc
   ```

   This builds the compiler in your checkout three times: with the installed
   `xcc` (stage 1), with stage 1 (stage 2) and with stage 2 (stage 3), and
   checks that stages 2 and 3 are the same, byte for byte. That is the sign
   the tree builds itself. `build/contrib/xcc-stage2` is your compiler, with
   your change in it. On Linux the same command builds an x86-64 compiler.

3. Run the tests with it:

   ```bash
   XC=build/contrib/xcc-stage2 bash selfhost/tools/installed-sweep.sh
   ```

   This compiles and runs each program in `tests/fixtures/` and compares
   what it prints with the `.expected.out` file beside it. Add a pattern to
   run only the fixtures whose names match it.

Every fix comes with a test that fails without it, and every feature with
tests that show it working, in `compiler/tests/` beside the existing ones.

The full gates (every target, the self-compile, the corpus sweeps on Linux,
macOS and Windows) run on the maintainers' machines. You don't need to run
them. A maintainer runs them on your pull request before it is merged.

## Style

Write code that reads like the code around it.

- **Whitesmiths braces:** the brace on its own line, indented to the level of
  the body it encloses.

  ```c
  for (u32 i in 0..n)
      {
      total = total + a[i];
      }
  ```

- Match the surrounding comment density and naming.
- No casts that change nothing: `(i32)12` is just `12`.
- The language is **xc** and the compiler is **xcc**, in code comments,
  messages and documentation.
- Documentation and messages are in British English, plainly written.

## Commits

- One topic per pull request. Several commits are fine if each one builds.
- Message: `area: what changed, in plain words`. For example:
  `par: a captured offset is settled at run time`.
- Rebase on `main` rather than merging `main` into your branch.

## Using AI tools

You may use AI assistants. You are responsible for every line you submit: you
must understand it, have tested it, and have the right to contribute it under
the CLA. If a large part of a change was generated, say so in the pull request.

## After you open a pull request

1. **The CLA check.** The bot confirms you have signed the agreement. There
   is no public build check yet, so say in the pull request what you ran.
2. **Review.** A maintainer reviews the change
   for correctness, tests, style, and the rules in this file. You
   will get comments to answer on the pull request.
3. **Verification.** Before merging, a maintainer runs the full gates and
   carries the change through the project's internal verification. That can
   turn up problems the public tests miss. If it does, we raise them on your
   pull request and work through them with you. It isn't a judgement on the
   change.
4. **Merge.** A maintainer merges the pull request, keeping your authorship
   on the commits.

Maintainers may push small follow-up commits to your branch, and say so when
they do.

## Security

Please don't report security problems in public issues. See
[SECURITY.md](https://github.com/ThrudTheBarbarian/xc/blob/main/SECURITY.md).

## Conduct

Everyone taking part agrees to the [code of conduct](https://github.com/ThrudTheBarbarian/xc/blob/main/CODE_OF_CONDUCT.md).
