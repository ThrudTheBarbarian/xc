---
title: UXValidationRule
description: "One rule in a UXValidator: a kind, its operands, and the message to show when a value fails it."
slug: versions/0.7/compiler/api/uxkit/uxvalidationrule
banner:
  content: 'This is the documentation for xc 0.7. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

`UXValidationRule` is one entry in a
[`UXValidator`](/versions/0.7/compiler/api/uxkit/uxvalidator/)'s list.

```c
#use <UXKit>            // or #import "UXValidator.xc"
```

## Overview

```c
class UXValidationRule : Object {
    i32      type;        // UXV_REQUIRED / UXV_REGEX / UXV_MINLEN / UXV_MAXLEN / UXV_INTRANGE
    UXRegex* rx;          // UXV_REGEX only
    i32      a;           // length, or range low
    i32      b;           // range high
    u8*      message;     // what to show when this rule fails
}
```

The `require*` methods on the validator build these; you rarely construct one
directly.

## One shape for five rules

`a` and `b` mean different things per type. This avoids five separate classes:

| type | `a` | `b` | `rx` |
| --- | --- | --- | --- |
| `UXV_REQUIRED` | — | — | — |
| `UXV_REGEX` | — | — | the compiled pattern |
| `UXV_MINLEN` | minimum length | — | — |
| `UXV_MAXLEN` | maximum length | — | — |
| `UXV_INTRANGE` | low | high | — |

Both length rules use `a` as their single operand, so `UXV_MINLEN` and
`UXV_MAXLEN` differ only in `type`. A rule table read from a file needs only the
type, two integers and a string.

## The message travels with the rule

```c
u8* message
```

The rule knows what to say when it fails, so the error label and the enabled
state come from one place. See
[the validator](/versions/0.7/compiler/api/uxkit/uxvalidator/#the-message-is-part-of-the-rule).

The string is **kept, not copied**, so it must outlive the rule. A literal is
the usual case; a string built at run time needs
[`UXStr.dup`](/versions/0.7/compiler/api/uxkit/uxstr/#dup).

`message` is read only when the rule fails. A rule with no message validates
correctly but reports nothing useful.

## The regex is pre-compiled

```c
UXRegex* rx
```

[`requireMatch`](/versions/0.7/compiler/api/uxkit/uxvalidator/#requirematch) compiles the
pattern when the rule is added, so validating on every keystroke costs a match
and not a compile.

:::caution[A null `rx` on a `UXV_REGEX` rule always fails]
If the pattern did not compile, `rx` is null and the rule reports failure for
every value, including valid ones.

Passing everything instead would turn a broken pattern into a form with no
validation, which is worse. If a field rejects *everything*, check the pattern
before the input.

If you build a rule with [`addRule`](/versions/0.7/compiler/api/uxkit/uxvalidator/#addrule)
and your own [`UXRegex`](/versions/0.7/compiler/api/uxkit/uxregex/), check
[`isValid`](/versions/0.7/compiler/api/uxkit/uxregex/#isvalid) before passing it.
:::

## Fields

### type

```c
i32 type
```

One of the five constants.

### rx

```c
UXRegex* rx        // UXV_REGEX only; null otherwise
```

### a / b

```c
i32 a; i32 b
```

Operands, per the table above.

### message

```c
u8* message
```

## Conforms to

- Inherits [`Object`](/versions/0.7/compiler/api/object/)

## See also

- [`UXValidator`](/versions/0.7/compiler/api/uxkit/uxvalidator/): the list these live in
- [`UXRegex`](/versions/0.7/compiler/api/uxkit/uxregex/): what a `UXV_REGEX` rule holds
