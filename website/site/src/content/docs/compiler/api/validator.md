---
title: Validator
description: "Rules a field's text must pass, each with the message to show when it fails: length, pattern, number range or a custom check."
---

`Validator` is a list of rules a field's text must pass, each with the message
to show when it fails: the check behind a text field's live validation and a
form's Submit button. **From 0.72.**

```c
#import "Validator.xc"     // not in the Foundation umbrella: import it by name
```

## Overview

```c
Validator* v = new Validator();
v.requireNonEmpty(String.withCString("Enter a name."));
v.requireMaxLength((u32)40, String.withCString("At most 40 characters."));
v.requireMatch(String.withCString("[A-Za-z' -]+"), String.withCString("Letters only."));
v.firstError(String.withCString(""));       // "Enter a name."
v.validate(String.withCString("Ada"));       // true
```

Rules are checked in the order they were added. Lengths count characters (UTF-8
sequences), not bytes. A pattern must match the whole text (see
[`Regex`](/compiler/api/regex/)). The integer and number rules read the text,
trimmed of white space, as [JSON](/compiler/api/json/) writes a number.

:::note[Availability]
Every target except xt6502.
:::

## Topics

**Rules** · [requireNonEmpty](#requirenonempty) · [requireMatch](#requirematch) · [requireRegex](#requireregex) · [requireMinLength / requireMaxLength](#requireminlength--requiremaxlength) · [requireIntegerRange](#requireintegerrange) · [requireNumberRange](#requirenumberrange) · [requireCustom](#requirecustom) · [ruleCount](#rulecount) · [removeAllRules](#removeallrules)

**Checking** · [validate](#validate) · [firstError](#firsterror) · [errors](#errors)

---

## Rules

### requireNonEmpty
```c
void requireNonEmpty(String* message)
```
Something other than white space.

### requireMatch
```c
void requireMatch(String* pattern, String* message) throws
```
The whole text matches `pattern`. Throws a `RegexError` for a bad pattern.

### requireRegex
```c
void requireRegex(Regex* re, String* message)
```
The same with a `Regex` already compiled, with options say.

### requireMinLength / requireMaxLength
```c
void requireMinLength(u32 n, String* message)
void requireMaxLength(u32 n, String* message)
```
In characters.

### requireIntegerRange
```c
void requireIntegerRange(i64 lo, i64 hi, String* message)
```
A whole number from `lo` to `hi`.

### requireNumberRange
```c
void requireNumberRange(double lo, double hi, String* message)
```
Any number, whole or decimal, from `lo` to `hi`.

### requireCustom
```c
void requireCustom(callback check bool(String* text), String* message)
```
`check`, a bound method or a function, returns true for good text.

### ruleCount
```c
u32 ruleCount(void)
```

### removeAllRules
```c
void removeAllRules(void)
```

[↑ Topics](#topics)

## Checking

A null text is checked as `""`.

### validate
```c
bool validate(String* text)
```
Whether `text` passes every rule.

### firstError
```c
String* firstError(String* text)
```
The message of the first rule `text` fails, or null: what a field shows under
itself.

### errors
```c
Array* errors(String* text)
```
The messages of every rule `text` fails, in order.

[↑ Topics](#topics)
