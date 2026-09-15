---
title: UXValidator
description: "A list of rules a field value must pass, each with the message to show when it fails: the check behind live validation and a form's Submit gate."
---

`UXValidator` is an ordered list of rules. [`validate`](#validate) says whether a
value passes them all; [`firstError`](#firsterror) returns the message of the
first rule that fails.

```c
#use <UXKit>            // or #import "UXValidator.xc"
```

## Overview

```c
UXValidator* name = new UXValidator();
name.requireNonEmpty((u8*)"a name is required");
name.requireMinLength(2, (u8*)"at least 2 characters");
name.requireMaxLength(8, (u8*)"at most 8 characters");

name.validate((u8*)"Alice");        // true
name.firstError((u8*)"J");          // "at least 2 characters"
name.firstError((u8*)"Alice");      // 0 — nothing wrong
```

It contains no window code, so a form's Submit gate can be tested without
typing. A text field consults the same object on every keystroke, and a dialog
consults it before closing.

## The message is part of the rule

Each rule knows what to say when it fails, so the error label has one source:

```c
u8* err = v.firstError(field.stringValue());
errorLabel.setText(err == (u8*)0 ? (u8*)"" : err);
submit.setEnabled(err == (u8*)0);
```

The enabled state and the message come from one call, so they cannot disagree.
A form cannot show no error while refusing to submit.

## Order is message priority

Rules are checked in the order they were added, and `firstError` stops at the
first failure. The order you add them is the order the user is told about them:

```
''    -> "age is required"
'17'  -> "must be 18 to 120"
'42'  -> ok
```

Put the coarsest rule first. Empty text also fails a range check, but *"age is
required"* is more useful to read than *"must be 18 to 120"*.

## A regex rule matches the whole value

```c
code.requireMatch((u8*)"^[A-Z][A-Z]-\\d\\d$", (u8*)"format is XX-99");

code.validate((u8*)"GB-42");            // true
code.validate((u8*)"see GB-42 here");   // false
```

The rule uses [`UXRegex.matches`](/compiler/api/uxkit/uxregex/#matches), so the
pattern must describe the **entire** field, as a field format should. A pattern
written to be found inside a value will reject everything.

The `^` and `$` above are therefore redundant, but they show a reader that the
whole value is intended.

:::note[The pattern is compiled once, when the rule is added]
`requireMatch` compiles immediately, so validating on every keystroke costs a
match and not a compile.

An invalid pattern makes a rule that **always fails**: the compiled regex is
null and the rule reports that as a failure. Check your patterns the first time
you run the form; there is no separate error for a broken rule.
:::

## The integer range is lenient about what a number is

:::caution[Non-numeric text reads as `0`]
```c
score.requireIntRange(0, 100, (u8*)"0 to 100");
score.validate((u8*)"55");        // true
score.validate((u8*)"banana");    // ALSO true
```

The value is read with a lenient parser that takes leading digits and stops.
Text with no digits reads as `0`, and passes whenever `0` is inside the range.

Pair the range with a format rule when it matters:

```c
score.requireMatch((u8*)"^\\d+$", (u8*)"digits only");
score.requireIntRange(0, 100, (u8*)"0 to 100");
```

This also gives a better message: *"digits only"* is what the user needs to see
for `banana`.
:::

## An empty validator passes everything

```c
new UXValidator().validate(anything);    // true
```

With no rules, nothing can fail. This is the right default for an optional
field, and a form can hold one validator per field without special-casing
fields that have no rules.

## Topics

[requireNonEmpty](#requirenonempty) · [requireMatch](#requirematch) · [requireMinLength](#requireminlength) · [requireMaxLength](#requiremaxlength) · [requireIntRange](#requireintrange) · [validate](#validate) · [firstError](#firsterror) · [ruleCount](#rulecount) · [addRule](#addrule)

### requireNonEmpty

```c
void requireNonEmpty(u8* msg)
```

At least one byte. A value of spaces is **not** empty; trim it with
[`UXText.trimWhitespace`](/compiler/api/uxkit/uxtext/#trimwhitespace) first if
you want to treat it as empty.

### requireMatch

```c
void requireMatch(u8* pattern, u8* msg)
```

A whole-value [regex](/compiler/api/uxkit/uxregex/) match.

### requireMinLength

```c
void requireMinLength(i32 n, u8* msg)
```

### requireMaxLength

```c
void requireMaxLength(i32 n, u8* msg)
```

Length is in **bytes**, so a non-ASCII UTF-8 character counts as more than one.
This suits a field with a hard storage limit; for "at most 20 letters" it is
approximate.

### requireIntRange

```c
void requireIntRange(i32 lo, i32 hi, u8* msg)
```

Inclusive at both ends. See the [caution](#the-integer-range-is-lenient-about-what-a-number-is).

### validate

```c
bool validate(u8* value)
```

True if all rules pass. Stops at the first failure.

### firstError

```c
u8* firstError(u8* value)
```

The message of the first failing rule, or **null** if all pass. It returns null
and not `""`, so "no error" is distinguishable from an empty message.

### ruleCount

```c
i32 ruleCount(void)
```

### addRule

```c
void addRule(i32 type, UXRegex* rx, i32 a, i32 b, u8* msg)
```

The general form the `require*` methods use, with `UXV_REQUIRED`, `UXV_REGEX`,
`UXV_MINLEN`, `UXV_MAXLEN` or `UXV_INTRANGE`. Use it to add a rule with an
already-compiled regex, or to build rules from a table.

Messages are **kept, not copied**. Pass literals, or strings that outlive the
validator.

## Example

```
  '': a name is required
  'J': at least 2 characters
  'Jonathan Smith': at most 8 characters
  'Alice': ok
  'GB-42': ok
  'gb-42': format is XX-99
  'see GB-42 here': format is XX-99
  '': age is required
  '17': must be 18 to 120
  '42': ok
  '55': ok
  'banana': ok
  empty validator rules=0 passes=1
```

`banana` passing the 0–100 range shows the lenient parse. The program is
`website/site/examples/uxkit/rules.xc`. The `doc-examples` gate compiles it,
and the block above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXValidationRule`](/compiler/api/uxkit/uxvalidationrule/): one rule
- [`UXRegex`](/compiler/api/uxkit/uxregex/): what `requireMatch` compiles
- [`UXTextField`](/compiler/api/uxkit/uxtextfield/): the control this usually
  guards
