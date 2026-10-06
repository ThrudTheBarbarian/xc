---
title: Predicate
description: "Conditions over records, built in code or parsed from text such as \"age > 30 AND name CONTAINS[c] 'sm'\"; evaluated against Maps or any object."
---

`Predicate` is a condition over records, built in code or parsed from text
(`NSPredicate` in shape): what a rule editor, a filter field or a smart folder
needs. **From the release after 0.71.**

```c
#import "Predicate.xc"     // not in the Foundation umbrella: import it by name
```

## Overview

```c
Predicate* p = Predicate.parse(String.withCString("age > 30 AND name CONTAINS[c] 'sm'"));
Map* person = (Map*)JSON.parse(String.withCString("{\"name\":\"Smith\",\"age\":42}"));
p.evaluate(person);                  // true
Array* adults = Predicate.parse(String.withCString("age >= 18")).filter(people);
```

A predicate is a tree of comparisons (*key* *operator* *value*) joined by `AND`,
`OR` and `NOT`. The thing tested is a [`Map`](/compiler/api/map/), such as a
[JSON](/compiler/api/json/) object or a [CSV](/compiler/api/csv/) record, or any
object through a callback that reads a key:

```c
bool ok = p.evaluateWith(&row.valueForKey);   // Object* valueForKey(String* key)
```

A key may be a path: `address.city` reads `address`, then `city` in the `Map`
found there.

### Comparing

Two Numbers compare as numbers. A Number and a String that holds a number also
compare as numbers, so records read from text work; the String must be written
as JSON writes a number (`"42"`, `"-1.5e3"`), so `"02139"` stays text. Two
Strings compare by bytes, or ignoring ASCII case with `[c]`. Otherwise only `=`
and `!=` apply, by `equals`. A missing key reads as null, which equals only
`NULL` and is neither less nor more than anything.

| Operator | |
|---|---|
| `=` `==` `!=` `<>` `<` `>` `<=` `>=` | compare |
| `CONTAINS` `BEGINSWITH` `ENDSWITH` | substring tests on Strings |
| `LIKE` | wildcards: `*` any run, `?` one character |
| `MATCHES` | a [`Regex`](/compiler/api/regex/) that must match the whole value |
| `IN { 'a', 'b', 3 }` | the value is one of these |

Any of them may take `[c]` for case-insensitive (ASCII).

### The text form

Keywords are in any case. `AND`/`&&`, `OR`/`||` and `NOT`/`!` combine, and
parentheses group. Strings are in single or double quotes with `\` escapes;
numbers are integers or decimals; `TRUE`/`YES`, `FALSE`/`NO` and `NULL`/`NIL`
are values. `TRUEPREDICATE` and `FALSEPREDICATE` are the constant predicates.
[`description`](#description) writes a predicate back in this form.

:::note[Availability]
Every target except xt6502.
:::

## Topics

**Parsing** · [parse](#parse) · [description](#description)

**Building** · [compare](#compare) · [and / or / not](#and--or--not) · [andAll / orAll](#andall--orall) · [truePredicate / falsePredicate](#truepredicate--falsepredicate)

**Evaluating** · [evaluate](#evaluate) · [evaluateWith](#evaluatewith) · [filter](#filter) · [valueAtPath](#valueatpath) · [compareValues](#comparevalues)

**Errors** · [PredicateError](#predicateerror)

---

## Parsing

### parse
```c
static Predicate* parse(String* text) throws
```
Reads [the text form](#the-text-form). Throws a
[`PredicateError`](#predicateerror) for text it cannot read, or a `MATCHES`
pattern that is not a valid `Regex`.

### description
```c
String* description(void)
```
The predicate in the text form, which `parse` reads back to the same predicate.

[↑ Topics](#topics)

## Building

### compare
```c
static Predicate* compare(String* key, String* op, Object* value, bool caseInsensitive) throws
```
`key` compared with `value` by `op`, one of the operators in the table (in any
case). `value` is a `String`, `Number` or `Null`, or an `Array` for `IN`.
Throws for an unknown operator or a bad `MATCHES` pattern.

### and / or / not
```c
static Predicate* and(Predicate* a, Predicate* b)
static Predicate* or(Predicate* a, Predicate* b)
static Predicate* not(Predicate* a)
```

### andAll / orAll
```c
static Predicate* andAll(Array* parts)
static Predicate* orAll(Array* parts)
```
Every predicate in `parts` joined. An empty `andAll` is true, an empty `orAll`
false.

### truePredicate / falsePredicate
```c
static Predicate* truePredicate(void)
static Predicate* falsePredicate(void)
```

[↑ Topics](#topics)

## Evaluating

### evaluate
```c
bool evaluate(Object* record)
```
Tests a `Map`, reading keys and paths through nested Maps. Any other object has
no keys: every key reads as null.

### evaluateWith
```c
bool evaluateWith(callback read Object*(String* key))
```
Tests an object through `read`, which returns a key's value (a `String`,
`Number` or `Null`; null for none).

### filter
```c
Array* filter(Array* items)
```
The members of `items` that pass, in order.

### valueAtPath
```c
static Object* valueAtPath(Object* record, String* path)
```
The value at a dotted key path through nested Maps, or null.

### compareValues
```c
static i32 compareValues(Object* a, Object* b, bool fold)
```
How two values order as a predicate compares them: -1, 0 or 1, or 2 when they
have no order. `fold` ignores ASCII case between Strings.
[`SortDescriptor`](/compiler/api/sortdescriptor/) sorts with it.

[↑ Topics](#topics)

## Errors

### PredicateError
```c
class PredicateError <Error>
String* message(void)
```
What [`parse`](#parse) and [`compare`](#compare) throw, as in
`bad predicate at byte 5: expected a value`.

[↑ Topics](#topics)
