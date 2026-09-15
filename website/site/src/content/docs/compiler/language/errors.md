---
title: Errors — throws, try & catch
description: "Checked error propagation: the throws effect, throw, typed and untyped catch arms, the Error protocol, and how errors interact with defer and ARC."
---

xcc's error model is **checked propagation**, without stack unwinding. A function that can fail says so on its signature. `throw` runs the scope teardown and returns. A call to such a function tests an error channel and either branches to a `catch` or propagates. The cost is a test-and-branch per throwing call, paid only where failure is possible.

This model is portable. Table-driven unwinding needs per-backend CFI tables, personality routines and an unwinder, which a banked 6502 with a 4 KB hardware stack cannot carry. Checked propagation uses only what the IR already has (calls, compares, branches, returns), so every backend supports it, xt6502 included.

## The shape of it

```c
#import <Error.xc>

class ParseError <Error>
{
    String* msg;
    void init(String* m)  { msg = m; }
    String* message(void) { return msg; }
}

i32 parseDigit(u8 ch) throws
{
    if (ch < '0' || ch > '9')
        throw new ParseError(String.withCString("not a digit"));
    return (i32)(ch - '0');
}

void main(void)
{
    try {
        i32 n = parseDigit('7');
        Stdio.printf("n=%d\n", n);
    }
    catch (ParseError e) { Stdio.printf("parse: %s\n", e.message().cString()); }
    catch (e)            { Stdio.printf("other error\n"); }
}
```

## The `Error` protocol

An error is an ordinary heap object. It conforms to `Error`, which has one requirement:

```c
protocol Error
{
    String* message(void);
}
```

With that requirement, a handler can always describe what it caught without knowing the concrete type. Errors are classes, so they use the existing protocols, ARC and RTTI downcast machinery.

`Error.xc` lives in `support/generic/lib/`. It is **not** part of the `Foundation.xc` umbrella, so import it explicitly.

Errors follow ARC like any other object. A caught error is a strong local, released at the end of its `catch` scope.

## `throws` — the effect on the signature

`throws` goes between the parameter list and the body, after any function annotations:

```c
i32 parse(String* s) throws { … }
void reload(void) :main throws { … }
```

A `throws` function has one hidden trailing out-parameter. `throw` stores the error through it and returns, and the caller tests it after the call. The return value on the throwing path is indeterminate; the generated check ensures you never read it.

### Calling a `throws` function is checked

A call to a `throws` function must be **either** inside a `try` **or** inside a function that is itself `throws`. Anything else is a sema error that names the callee and both fixes:

```
'readCount' is declared 'throws' — wrap the call in try { } catch (e) { },
or declare the caller 'throws' to propagate
```

This keeps the test-and-branch off every non-throwing call, and the compiler shows you where failure can reach.

Propagation needs no syntax. A `throws` function that calls another `throws` function without a `try` forwards the error to its own caller:

```c
i32 middle(u32 n) throws { i32 v = inner(n); return v + (i32)1; }
```

`throws` works the same on class methods (instance and static) and on free
functions. Declaring, throwing, catching and the checked effect behave
identically for all of them.

```c
u16 a = p.parse(c);      // throws method, unguarded → rejected
u16 b = parseFree(c);    // throws function, unguarded → rejected
```

## `throw`

```c
throw new IOError(String.withCString("cannot open"));
```

`throw` evaluates its operand, stores it into the error channel, then runs every enclosing scope's [`defer`](/compiler/language/statements/#defer) bodies and ARC teardown on the way out, as an early `return` does. A propagating throw is an ordinary exit path, so scope cleanup has no special case.

The operand should conform to `Error`. The compiler does not enforce this and **accepts any class pointer**, so a handler that calls `message()` on an object without that method fails at the handler, not at the `throw`. Conform to `Error` anyway, because every untyped `catch` is written against it.

## `try` / `catch`

```c
try   { … }
catch (IOError e) { … }        // typed arm
catch (ParseError e) { … }     // another typed arm
catch (e) { … }                // untyped catch-all
```

A `try` block must be followed by at least one `catch`. Arms are tested **in source order**:

- A **typed** arm runs only when the in-flight error is an instance of that class. The test is the same RTTI conformance check that [`(T* ?)obj`](/compiler/language/inheritance/#downcasts--runtime-checked) uses, so it also works across a `.so` boundary. Inside the arm, the binder is already narrowed to that class, and `e.message()` resolves directly against it.
- An **untyped** arm catches everything. Its binder is `Object*`, the most general reference, so reaching a specific class's members needs a cast.
- If **no** arm matches, the error keeps propagating, out to an enclosing `try` or out of the function if it is `throws`.

The class name in a typed arm has **no** pointer sigil: write `catch (IOError e)`, not `catch (IOError* e)`.

### Unreachable arms are a warning

An arm shadowed by an earlier, broader one can never run, and the compiler warns:

```
this 'catch' can never run — an earlier arm already catches everything
```

This is a warning, not an error. Silence it with `-Wno-unreachable-catch` if you want to keep the dead arm (for example, a signature you intend to fill in).

## A worked example

Using the `ParseError` class from the top of the page:

```c
i32 inner(u32 n) throws
{
    defer { Stdio.printf("  inner-defer\n"); }
    if (n == (u32)1) throw new ParseError(String.withCString("deep"));
    return (i32)7;
}

// No try here: the error propagates out to our caller.
i32 middle(u32 n) throws { i32 v = inner(n); return v + (i32)1; }

void main(void)
{
    try { i32 a = middle((u32)0); Stdio.printf("ok a=%d\n", a); }
    catch (e) { Stdio.printf("UNEXPECTED\n"); }

    try { i32 b = middle((u32)1); Stdio.printf("UNEXPECTED b=%d\n", b); }
    catch (e) { Stdio.printf("caught: %s\n", ((ParseError*)e).message().cString()); }
}
```

```
  inner-defer
ok a=8
  inner-defer
caught: deep
```

The defer fires on both paths, once on the ordinary return and once on the throw. `middle` forwards the error with no handling code.

## What there is no such thing as

- **No `finally`.** [`defer`](/compiler/language/statements/#defer) replaces it, and attaches cleanup to the thing being cleaned up instead of to a block at the bottom of the function.
- **No throwing from a `defer` body.** A defer running during propagation would have nowhere to send a second error, so this is forbidden.
- **No unchecked errors.** You cannot call a `throws` function and ignore the possibility of failure. The cost is `throws` annotations up the call chain; in return the compiler knows where failure flows.

## What's next

- [Statements & control flow → `defer`](/compiler/language/statements/#defer): the cleanup mechanism errors rely on.
- [Inheritance & protocols](/compiler/language/inheritance/): protocols and the failable downcast that typed arms use.
- [Heap, ARC & weak refs](/compiler/language/memory/): how a caught error's lifetime is managed.

## Worked example

`throws` as a checked effect, `defer` on the unwind path, and typed `catch` arms:

```c
// errors.xc — throws / try / catch / defer, worked end to end.
//
// A function that can fail says so with `throws`. Callers must either handle
// it in a `try` block or be declared `throws` themselves, so a failure path
// cannot be ignored by accident.
#import "Foundation.xc"
#import "Error.xc"      // not part of the Foundation umbrella
#import "Stdio.xc"

// Anything thrown must conform to `Error`, which requires message().
class ParseError <Error>
{
    String* _what;
    void init(void) { _what = 0; }
    static ParseError* with(String* what)
    {
        ParseError* e = new ParseError();
        e._what = what;
        return e;
    }
    String* message(void) { return _what; }
}

// `throws` is part of the signature: the caller can see it can fail.
u16 parseDigit(u8 c) throws
{
    if (c < (u8)'0' || c > (u8)'9')
        throw ParseError.with(String.withCString("not a digit"));
    return (u16)(c - (u8)'0');
}

// A `defer` block runs when the enclosing scope exits — on the normal path
// AND when an error unwinds through it. That is what makes it useful for
// releasing things.
u16 sumDigits(string s) throws
{
    defer { Stdio.print("  (defer: sumDigits scope exited)\n"); }
    u16 total = (u16)0;
    for (u16 i = (u16)0; s[i] != (u8)0; i = i + (u16)1)
        total = total + parseDigit(s[i]);       // may throw; propagates
    return total;
}

i32 main(void)
{
    // 1. The happy path. `try` guards the block; `catch (T e)` binds the
    //    error as a T. Name the class: an untyped `catch (e)` binds `e` as
    //    Object*, which has no message() — so it is only useful for "handle
    //    anything and carry on", not for inspecting what went wrong.
    try {
        u16 n = sumDigits("12345");
        Stdio.printf("sum of 12345 = %d\n", n);
    } catch (ParseError e) {
        Stdio.printf("unexpected: %s\n", e.message().cString());
    }

    // 2. The failing path — the throw unwinds out of the loop, out of
    //    sumDigits (running its defer), and lands in catch.
    try {
        u16 n = sumDigits("12x45");
        Stdio.printf("sum of 12x45 = %d\n", n);
    } catch (ParseError e) {
        Stdio.printf("caught: %s\n", e.message().cString());
    }

    // 3. The same, catching a throw that happens directly in the block.
    try {
        u16 d = parseDigit((u8)'!');
        Stdio.printf("digit %d\n", d);
    } catch (ParseError e) {
        Stdio.printf("caught a ParseError: %s\n", e.message().cString());
    }
    return 0;
}
```

```
  (defer: sumDigits scope exited)
sum of 12345 = 15
  (defer: sumDigits scope exited)
caught: not a digit
caught a ParseError: not a digit
```

On the happy path, `sumDigits`'s `defer` runs *before* the `printf` in the `try` block, because the defer fires when `sumDigits` returns. It also runs on the failing path, as the throw unwinds through it.
