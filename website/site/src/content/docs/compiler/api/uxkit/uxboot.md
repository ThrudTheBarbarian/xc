---
title: UXBoot
description: "Test scaffolding that starts the GEM window server under qemu. Documented so that nobody mistakes it for something an application should call."
---

:::danger[This is not part of the toolkit]
`UXBoot` is **test scaffolding**. No shipped code imports it, and a real
application must never call it.

It is documented so that anyone who finds it in the source knows what it is for
and why using it would be a mistake.
:::

```c
#import "UXBoot.xc"       // tests only; not reachable through #use <UXKit>
```

## The problem it exists for

On the board, `init(1)` runs the boot scripts off the SD card, and one of them
starts `gemd` with `&`.

Under **qemu the SD card is not mounted**. `/bin/sh` is missing, `init` runs no
scripts, and nothing starts the window server. `libGEM` then hard-exits with
*"no window server"*. That is **correct**: there is no single-process mode, and
pretending otherwise would be worse than the error.

A test running under qemu therefore has to start `gemd` itself. That is all this
class does.

## Why an application must never do this

Starting the window server from a client is the *"the desktop is not the
server"* mistake in miniature.

An application is a **client**. It connects to a service that something else is
responsible for running. An application that starts its own server has taken the
role of the system, and when two applications run, the second finds a server it
did not start and does not own.

The file exists in one place, is imported by nothing that ships, and says so in
its first line. The scaffolding is allowed to exist because this containment
stops it from leaking.

## What it does

```c
static bool ensureWindowServer(void)
```

1. Try to connect to the `gem` service. **If it is already up (as on the board),
   return immediately.** The common case costs one connect.
2. Otherwise `sys_spawn("/bin/gemd")`.
3. Wait for it to register, retrying with a sleep, for up to **5 seconds**.

:::note[The sleep is required]
A server has a plane to open, a theme to load and a service to bind. A tight
retry loop on a failing connect does not yield enough time for that to finish,
and gives up before `gemd` is ready. Sleeping between tries makes startup
reliable. Without it, the failure looks like *"the window server does not work"*
when the cause is asking too early.
:::

Returns `false` if the spawn failed or the server never registered, so a test
can report *"no window server"* instead of proceeding into a crash.

## See also

- [`UXGemDriver`](/compiler/api/uxkit/uxgemdriver/): the backend that needs the
  server this starts
- [`UXApplication`](/compiler/api/uxkit/uxapplication/): what a real
  application starts instead
