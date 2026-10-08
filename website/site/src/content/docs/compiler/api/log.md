---
title: Log
description: "Logging on every target: levels with a minimum, named subsystem channels, monitors that see every message, and a replaceable Logger."
---

`Log` is the logging facade: a program writes `Log.info("connected %d", n)` on
every target, and where the text goes is the platform's business: the browser
console on wasm32, the system log on iOS, logcat on Android, the screen on the
6502 and standard output elsewhere (the table under [Where it
goes](#where-it-goes)).

```c
#import "Log.xc"
```

## Overview

```c
Log.info("listening on %d", port);
Log.warning(String.withCString("disk nearly full"));

LogChannel* net = Log.forSubsystem(String.withCString("net"));
net.setMinLevel(Log.levelWarning());
net.error("timeout after %d s", (i32)30);       // "net: timeout after 30 s"

Log.addMonitor(&self.onLog);   // void onLog(String* subsystem, u8 level, String* msg)
```

**Levels** are debug, info, warning and error, in that order. Messages below the
[global minimum](#setminlevel--minlevel) (info at first) are dropped, so a
`Log.debug` costs one comparison until it is wanted. **From 0.72**, as are subsystems and monitors.

**Subsystems.** [`Log.forSubsystem`](#forsubsystem) gives the
[`LogChannel`](#logchannel) for a name, one per name, with its own minimum
level; its messages reach the Logger as `name: message`.

**Monitors** are called with the subsystem (`""` for the plain facade), the
level and the message of everything that passes the level filters, whatever the
Logger does with it: to count errors, show the last warning in a status bar, or
watch for a pattern with a [`Regex`](/compiler/api/regex/). A monitor does not
keep its receiver alive; one whose receiver has gone is dropped.

**The Logger** receives each message once it has passed the filters. The default
prints `error:` and `warning:` prefixes (in red and yellow on a terminal); an app
may install its own with [`setLogger`](#setlogger).

:::note[Availability]
Every target. The 6502 prints through its screen.
:::

## Topics

**Writing** · [error / warning / info / debug](#error--warning--info--debug)

**Levels** · [levelDebug … levelError](#leveldebug--levelerror) · [setMinLevel / minLevel](#setminlevel--minlevel)

**Subsystems** · [forSubsystem](#forsubsystem) · [LogChannel](#logchannel)

**Monitors** · [addMonitor / removeMonitor](#addmonitor--removemonitor)

**Where it goes** · [Logger](#logger) · [setLogger / logger](#setlogger)

---

## Writing

### error / warning / info / debug
```c
static void error(String* msg)
static void error(string fmt, ...)
static void warning(String* msg)
static void warning(string fmt, ...)
static void info(String* msg)
static void info(string fmt, ...)
static void debug(String* msg)
static void debug(string fmt, ...)
```
The format forms take [`printf`](/compiler/api/stdio/) formats. `debug`'s format
form does not even format the text while debug messages are dropped.

[↑ Topics](#topics)

## Levels

### levelDebug … levelError
```c
static u8 levelDebug(void)      // 0
static u8 levelInfo(void)       // 1
static u8 levelWarning(void)    // 2
static u8 levelError(void)      // 3
```

### setMinLevel / minLevel
```c
static void setMinLevel(u8 level)
static u8 minLevel(void)
```
Messages below `level` are dropped, from every channel. Info at first.

[↑ Topics](#topics)

## Subsystems

### forSubsystem
```c
static LogChannel* forSubsystem(String* name)
```
The channel named `name`, made on first use with a minimum of debug, so only
the global minimum filters it until it sets its own.

### LogChannel
```c
String* name;
u8 minLevel;
void setMinLevel(u8 level)
void log(u8 level, String* msg)
void error(String* msg)      void error(string fmt, ...)
void warning(String* msg)    void warning(string fmt, ...)
void info(String* msg)       void info(string fmt, ...)
void debug(String* msg)      void debug(string fmt, ...)
```
A message passes when it is at or above both the channel's minimum and the
global one.

[↑ Topics](#topics)

## Monitors

### addMonitor / removeMonitor
```c
static void addMonitor(callback cb void(String* subsystem, u8 level, String* msg))
static void removeMonitor(callback cb void(String* subsystem, u8 level, String* msg))
```
`cb` is usually a bound method, `&watcher.onLog`.

[↑ Topics](#topics)

## Where it goes

The Logger made on first use is the platform's, and it writes to the place
that platform's developers look at:

| Platform | Destination | To see it |
|---|---|---|
| macOS, Linux, Windows, arm9, m68k | standard output, through [`Stdio`](/compiler/api/stdio/); `error:` and `warning:` are prefixed, in red and yellow on a terminal | the terminal, or redirect `stdout` |
| iOS, iOS simulator | the system log, through `syslog`: errors at `LOG_ERR`, warnings at `LOG_WARNING`, the rest at `LOG_NOTICE` | Console.app, `log stream`, or `xcrun simctl spawn booted log stream` for the simulator |
| Android | standard output, which the app's glue copies line by line to logcat under the tag `xcapp` at priority `INFO` | `adb logcat -s xcapp` |
| a browser (wasm32) | the browser console: `console.error` for errors, `console.warn` for warnings, `console.log` for the rest | the page's developer console |
| xt6502 | the text screen, through `Stdio` | the screen |

`debug` messages go where `info` messages go on every platform. A program that
wants something else, a file say, installs its own Logger with
[`setLogger`](#setlogger); monitors see every message whatever the Logger does
with it.

### Logger
```c
protocol Logger
    {
    void error(String* msg);
    void warning(String* msg);
    void info(String* msg);
    optional void debug(String* msg);   // without it, debug messages go to info
    }
```

### setLogger
```c
static void setLogger(Logger* l)
static Logger* logger(void)
```
Installs the app's own Logger, or reads the one in use (made on first use).
A null Logger discards messages; monitors still see them.

[↑ Topics](#topics)
