---
title: UXLog
description: "A logger per subsystem with a minimum level, plus monitors that fire a callback when a logged message matches a pattern."
---

`UXLog` is a small logging facility: a **subsystem** name, a minimum level, and
messages below that level dropped. `os_log`/`syslog` in shape.

```c
#use <UXKit>            // or #import "UXLog.xc"
```

## Overview

```c
UXLog* net = UXLog.forSubsystem((u8*)"net");
net.setMinLevel(UX_LOG_INFO);

net.debug((u8*)"opening socket");        // dropped — below the level
net.info((u8*)"connected to host");      // [INFO] net: connected to host
net.warn((u8*)"read timeout after 30s");
net.error((u8*)"giving up");
```

Output goes to stdout by default. A syslog sink is a per-backend addition.

## One logger per name

```c
UXLog.forSubsystem((u8*)"net") == UXLog.forSubsystem((u8*)"net");   // true
```

`forSubsystem` returns the **same** logger for a name, from a process-wide
registry, as `os_log`'s subsystem registry does.

A level set in one place applies everywhere that subsystem logs, and a module
deep in a call stack does not need to be handed a logger. Raising the verbosity
of one subsystem takes one line, anywhere.

[`shared`](#shared) is the unnamed logger for code that has no subsystem of its
own.

## Monitors are the interesting part

```c
net.addMonitor(UXRegex.compile((u8*)"timeout"), &self.onTimeout);
```

Register a [`UXRegex`](/compiler/api/uxkit/uxregex/) and a callback, and the
callback fires whenever a logged message matches. The matching uses the
toolkit's own regex engine.

With monitors, the program can react to its log as it is written. A test
asserts that a particular message was produced; a diagnostic panel lights up
when an error pattern appears; a retry counter increments without the
networking code knowing anything is counting.

```
[WARN] net: read timeout after 30s
    MONITOR saw: read timeout after 30s
```

:::note[A monitor sees what the level lets through]
Monitors fire from inside `log`, **after** the level check. A message dropped
for being below `minLevel` is not offered to monitors either.

A monitor watching for a debug-level pattern therefore needs the level lowered
to see it. One switch controls both, which is usually what you want. If a
monitor never fires, check the level before the pattern.
:::

The callback is a [callback](/compiler/language/bound-methods/), so a monitor
**cannot keep its observer alive**. When the observer is freed, its monitor
stops firing. This is the same lifetime model as
[`UXNotificationCenter`](/compiler/api/uxkit/uxnotificationcenter/).

## Matching is `test`, not `matches`

Monitors search the message rather than requiring the pattern to match all of
it. A pattern of `"timeout"` fires on `"read timeout after 30s"`.

This suits a log watch. [`UXValidator`](/compiler/api/uxkit/uxvalidator/)'s
regex rule works the other way: its pattern must describe the entire field.
Both use the same engine.

## Topics

[forSubsystem](#forsubsystem) · [shared](#shared) · [setMinLevel](#setminlevel) · [setStdout](#setstdout) · [debug / info / warn / error](#debug--info--warn--error) · [log](#log) · [addMonitor](#addmonitor) · [removeMonitor](#removemonitor) · [monitorCount](#monitorcount) · [levelName](#levelname)

### forSubsystem

```c
static UXLog* forSubsystem(u8* name)
```

The logger for a name, made on first use and shared after that. The name is
kept, not copied.

### shared

```c
static UXLog* shared(void)
```

The default logger.

### setMinLevel

```c
void setMinLevel(i32 lvl)
```

`UX_LOG_DEBUG`, `UX_LOG_INFO`, `UX_LOG_WARN`, `UX_LOG_ERROR`. Messages below it
are dropped, and monitors do not see them.

### setStdout

```c
void setStdout(bool on)
```

Turn the stdout sink off. A logger with stdout off and a monitor attached is a
**silent watcher**. This is useful in a test, where the monitor makes the
assertion and the output would be noise.

### debug / info / warn / error

```c
void debug(u8* msg)
void info(u8* msg)
void warn(u8* msg)
void error(u8* msg)
```

### log

```c
void log(i32 lvl, u8* msg)
```

The general form. It takes a finished message with no format string, so build
the message with [`UXStr`](/compiler/api/uxkit/uxstr/) first.

:::caution[The message is built whether or not it is logged]
Because the level check is inside `log`, a call like

```c
net.debug(UXStr.append((u8*)"read ", UXStr.fromInt(n)));
```

allocates and concatenates **even when debug is off**. In a hot loop, test the
level yourself before building the string.
:::

### addMonitor

```c
void addMonitor(UXRegex* pattern, callback cb void(u8* msg))
```

### removeMonitor

```c
void removeMonitor(callback cb void(u8* msg))
```

Matched on the callback, so the same callback cannot be registered twice with
different patterns and removed individually.

### monitorCount

```c
i32 monitorCount(void)
```

### levelName

```c
u8* levelName(i32 lvl)
```

`"DEBUG"`, `"INFO"`, `"WARN"`, `"ERROR"`: what the stdout sink prints in
brackets.

## Example

```
[INFO] net: connected to host
[WARN] net: read timeout after 30s
    MONITOR saw: read timeout after 30s
[ERROR] net: giving up
  monitor fired 1 time(s), monitors=1
  same logger: 1
```

The `debug` call, below the level, produced nothing. The program is
`website/site/examples/uxkit/toolbox.xc`. The `doc-examples` gate compiles it,
and the listing above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXLogMonitor`](/compiler/api/uxkit/uxlogmonitor/): one watch
- [`UXRegex`](/compiler/api/uxkit/uxregex/): the patterns
- [`UXNotificationCenter`](/compiler/api/uxkit/uxnotificationcenter/): the same
  weak-observer lifetime model, for announcements rather than logs
