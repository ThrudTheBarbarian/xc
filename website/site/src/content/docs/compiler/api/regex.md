---
title: Regex
description: "Regular expressions over UTF-8 text: capture groups, lazy and counted quantifiers, word boundaries, find-all, replace with $1 templates, split."
---

`Regex` compiles a regular expression once and uses it to test, find, replace
and split text. **From 0.72.**

```c
#import "Regex.xc"         // not in the Foundation umbrella: import it by name
```

## Overview

```c
try
    {
    Regex* re = Regex.compile(String.withCString("(\\w+)@(\\w+)\\.com"));
    RegexMatch* m = re.firstMatch(String.withCString("mail ada@example.com now"));
    m.group((u32)1);                     // "ada"
    re.replace(String.withCString("ada@example.com"), String.withCString("$2: $1"));
                                         // "example: ada"
    }
catch (RegexError e)
    {
    Stdio.printf("%s\n", e.message().cString());   // bad pattern at byte 3: missing ')'
    }
```

### The syntax

| | |
|---|---|
| `a` `é` | a character; UTF-8 in the pattern is one character |
| `.` | any character but `\n` (any at all with [`dotAll`](#options)) |
| `[abc]` `[^a-z]` | a class, with ranges; `\d` `\w` `\s` and escapes work inside |
| `\d` `\w` `\s` | a digit, a word character `[A-Za-z0-9_]`, white space |
| `\D` `\W` `\S` | their complements |
| `\b` `\B` | a word boundary, and not one |
| `^` `$` | the start and end (of each line with [`multiline`](#options)) |
| `\t` `\n` `\r` `\xHH` `\.` `\\` … | escapes |
| `( )` | a capture group; `(?: )` groups without capturing |
| `a\|b` | either |
| `*` `+` `?` | 0 or more, 1 or more, 0 or 1 |
| `{n}` `{n,}` `{n,m}` | counted (up to 1000) |
| `*?` `+?` `??` `{n,m}?` | the lazy forms: as few as will do |

**Characters.** A character is a whole UTF-8 sequence where the text has one:
`.` and a class consume all of `é`, and `[^a]` matches it. A class is held as a
set of code points (an [`IndexSet`](/compiler/api/indexset/)). Case-insensitive
matching folds ASCII letters only. There are no backreferences or lookaround.
Positions and [`Range`](/compiler/api/range/)s are byte offsets into the text.

**The engine** is a backtracking virtual machine over a compiled program, with an
explicit stack, so a long text cannot exhaust the native stack, and a guard that
stops a loop whose body matched nothing from going round again. Like other
backtracking engines it can take exponential time on patterns such as `(a*)*b`
against a long run of `a`s; each search gives up after 2<sup>24</sup> steps and
reports no match.

:::note[Availability]
Every target except xt6502.
:::

## Topics

**Compiling** · [compile](#compile) · [compileWith](#compilewith) · [options](#options) · [pattern](#pattern) · [groupCount](#groupcount) · [escape](#escape)

**Matching** · [test](#test) · [matches](#matches) · [firstMatch](#firstmatch) · [firstMatchFrom](#firstmatchfrom) · [allMatches](#allmatches)

**Changing text** · [replace](#replace) · [replaceFirst](#replacefirst) · [split](#split)

**Results and errors** · [RegexMatch](#regexmatch) · [RegexError](#regexerror)

---

## Compiling

### compile
```c
static Regex* compile(String* pattern) throws
```
Throws a [`RegexError`](#regexerror) for a pattern it cannot read.

### compileWith
```c
static Regex* compileWith(String* pattern, u8 options) throws
```
With any of the [options](#options) or'd together.

### options
```c
static u8 caseInsensitive(void)
static u8 multiline(void)       // ^ and $ at every line
static u8 dotAll(void)          // . matches \n too
```

### pattern
```c
String* pattern(void)
```

### groupCount
```c
u32 groupCount(void)
```
The number of capture groups.

### escape
```c
static String* escape(String* literal)
```
`literal` with every character the syntax treats specially escaped, so it
matches itself: `1+1=2?` becomes `1\+1=2\?`.

[↑ Topics](#topics)

## Matching

### test
```c
bool test(String* text)
```
Whether the pattern matches somewhere in `text`.

### matches
```c
bool matches(String* text)
```
Whether the pattern matches the whole of `text`: some way of matching it starts
at the first byte and ends at the last, even where the first match found would
stop short (`a|ab` matches `ab`).

### firstMatch
```c
RegexMatch* firstMatch(String* text)
```
The leftmost match, or null.

### firstMatchFrom
```c
RegexMatch* firstMatchFrom(String* text, i32 from)
```
The first match starting at or after byte `from`.

### allMatches
```c
Array* allMatches(String* text)
```
Every match, left to right, not overlapping. After an empty match the search
goes on one character later.

[↑ Topics](#topics)

## Changing text

### replace
```c
String* replace(String* text, String* template)
```
`text` with every match replaced by `template`, in which `$0` to `$9` are the
groups (empty for a group that took no part) and `$$` is a `$`.

### replaceFirst
```c
String* replaceFirst(String* text, String* template)
```

### split
```c
Array* split(String* text)
```
The pieces of `text` between matches: `\s*,\s*` splits `a , b,c` into `a`, `b`,
`c`. Empty matches at the very start or end do not split.

[↑ Topics](#topics)

## Results and errors

### RegexMatch
```c
Range* range(void)                // the whole match
u32 groupCount(void)
Range* rangeOfGroup(u32 n)        // Range(-1, 0) when the group took no part
String* group(u32 n)              // null when it took no part; 0 is the whole match
```

### RegexError
```c
class RegexError <Error>
String* message(void)
```
What [`compile`](#compile) throws, with the byte offset, as in
`bad pattern at byte 3: missing ')'`.

[↑ Topics](#topics)
