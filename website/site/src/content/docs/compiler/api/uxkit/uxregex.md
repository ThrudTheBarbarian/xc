---
title: UXRegex
description: "A small regular-expression engine: pattern to bytecode to a backtracking VM. A matcher, not a parser: no captures, and the supported syntax is listed."
---

`UXRegex` compiles a pattern and matches strings against it.

```c
#use <UXKit>            // or #import "UXRegex.xc"
```

## Overview

```c
UXRegex* re = UXRegex.compile((u8*)"^\\d+-[a-z]+$");
re.matches((u8*)"42-hello");     // true  — the WHOLE string
re.test((u8*)"x 42 y");          // does it occur ANYWHERE?
re.search((u8*)"x 42 y");        // 2, the offset — or -1
re.matchLength();                // how long the match at that offset was
```

The pipeline is pattern → AST (recursive descent) → a small bytecode → a
backtracking VM. The bytecode is the classic six-instruction set: `CHAR`, `ANY`,
`CLASS`, `split`, `jmp`, `match`, plus the two anchors.

Alternation and every quantifier compile to a `split`, which the VM tries one way
and, on failure, backtracks to the other.

## matches versus test

This is the distinction most often got wrong:

```c
re = UXRegex.compile((u8*)"\\d+");
re.matches((u8*)"42");        // true
re.matches((u8*)"x 42 y");    // FALSE — matches() is anchored to both ends
re.test((u8*)"x 42 y");       // true  — test() searches
```

[`matches`](#matches) asks *"is the whole string this pattern"*, which is what a
form field wants. [`test`](#test) and [`search`](#search) ask *"does this occur
anywhere"*, which is what a filter wants.

A field validator therefore needs no `^…$`, though writing them documents intent
at no cost. A search box must **not** use `matches`.

## What is supported

| | |
| --- | --- |
| literals | `abc` |
| any character | `.` |
| classes | `[abc]`, `[^a-z]`, with ranges |
| predefined classes | `\d` `\w` `\s` and `\D` `\W` `\S` |
| escapes | `\.` `\*` `\\` and the rest |
| anchors | `^` `$` |
| groups | `( )` |
| alternation | `|` |
| quantifiers | `*` `+` `?` — **greedy** |

That is the complete list. It covers what a field format, a filename filter or a
log scan needs.

## What is not — and how it fails

:::danger[`{n,m}` is not a quantifier: the braces are literal]
```c
UXRegex.compile((u8*)"^\\d{2}$").matches((u8*)"42");    // FALSE
UXRegex.compile((u8*)"^\\d\\d$").matches((u8*)"42");    // true
```

`{2}` is not rejected. `{`, `2` and `}` are matched as ordinary characters, so
the pattern is **valid** and never matches what you meant.

[`isValid`](#isvalid) reports such a pattern as valid, so nothing warns you.
Repeat the atom, or use `+` with a length rule from
[`UXValidator`](/compiler/api/uxkit/uxvalidator/).
:::

Also absent:

- **No captures or backreferences.** This is a matcher, not a parser; there is
  no group `1`. To pull fields out of a string, match to confirm the shape and
  then use [`UXText.split`](/compiler/api/uxkit/uxtext/#split) to take it apart.
- **No non-greedy `*?`.** `<.*>` on `<a> and <b>` matches the whole string, not
  `<a>`. Use a negated class, `<[^>]*>`, which is also faster.
- **No lookaround, no word boundary `\b`, no case-insensitive flag.** For
  case-insensitivity, fold with
  [`UXText.toLower`](/compiler/api/uxkit/uxtext/#tolower--toupper) first and
  match a lowercase pattern.

## Invalid patterns are reported

```c
UXRegex* re = UXRegex.compile((u8*)"[a-");
re.isValid();      // false
```

An unterminated class, a stray `)` or a quantifier with nothing to repeat sets
the flag. **Always check `isValid`** on a pattern that came from a user or a
file. An invalid regex still answers `matches`, and the answer is meaningless.

## Backtracking has a worst case

The VM tries one branch and backs up on failure. This is simple and correct, and
it is exponential on patterns where many branches match the same text.
`(a|a)*b` against a long run of `a`s is the classic example.

Patterns written by you against strings of field length are not a problem.
Patterns from **untrusted input** are, and this engine has no step limit to stop
one. Treat a user-supplied pattern as a user-supplied loop.

## Topics

[compile](#compile) · [isValid](#isvalid) · [matches](#matches) · [test](#test) · [search](#search) · [matchLength](#matchlength)

### compile

```c
static UXRegex* compile(u8* pattern)
```

Compile once, match many times. The compiled form makes repeated matching cheap,
so hoist this out of a loop.

Never returns null; check [`isValid`](#isvalid).

### isValid

```c
bool isValid(void)
```

Whether the pattern parsed. See [above](#invalid-patterns-are-reported).

### matches

```c
bool matches(u8* s)
```

Whether the **whole string** is the pattern.

### test

```c
bool test(u8* s)
```

Whether the pattern occurs **anywhere**. [`search`](#search) `>= 0`.

### search

```c
i32 search(u8* s)
```

The offset of the leftmost match, or `-1`. Leftmost, then greedy: it tries each
starting position in turn and takes the first that matches.

### matchLength

```c
i32 matchLength(void)
```

How long the last successful match was. Read it **after** `search` or
`matches`. It is state on the regex, not a property of the string, so a second
search overwrites it.

## Example

```
  /\d+/ on '42': matches=1 test=1 at=0 len=2
  /\d+/ on 'x 42 y': matches=0 test=1 at=2 len=4
  /^\d+-[a-z]+$/ on '42-hello': matches=1 test=1 at=0 len=8
  /^\d+-[a-z]+$/ on '42-Hello': matches=0 test=0 at=-1 len=0
  /[A-Za-z_][A-Za-z0-9_]*/ on '9lives': matches=0 test=1 at=1 len=6
  /^[^0-9]+$/ on 'letters': matches=1 test=1 at=0 len=7
  /^(cat|dog)s?$/ on 'dogs': matches=1 test=1 at=0 len=4
  /<.*>/ on '<a> and <b>': matches=1 test=1 at=0 len=11
  [a- : INVALID PATTERN
  /^\d{2}$/ on '42': matches=0 test=0 at=-1 len=0
  /^\d\d$/ on '42': matches=1 test=1 at=0 len=2
```

The identifier pattern on `9lives` shows the leftmost-match rule: it cannot start
at `9`, so it starts at `l` and takes the rest. The `<.*>` line shows greediness,
and the last pair shows `{2}` failing silently.

The program is `website/site/examples/uxkit/rules.xc`. The `doc-examples` gate
compiles it, and the block above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXValidator`](/compiler/api/uxkit/uxvalidator/): rules built on this, with
  messages
- [`UXText`](/compiler/api/uxkit/uxtext/): `contains`, `hasPrefix` and `split`,
  which are usually enough and always cheaper
- [`UXPredicate`](/compiler/api/uxkit/uxpredicate/): filtering objects rather
  than matching strings
