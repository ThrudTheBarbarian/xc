---
title: Http
description: "An HTTP/1.1 client over the host's sockets: a blocking GET, the same request on its own thread, and the native transport behind url.fetch. https through the optional TLS library. A complete method reference."
---

`Http` fetches a URL over HTTP/1.1. It can block until the answer arrives, or
run the request on its own thread and call you back, and it can be the
transport behind [`url.fetch`](#install).

```c
#import "Http.xc"
```

## Overview

[`Http.get`](#get) blocks the calling thread and returns an
[`HttpResponse`](#httpresponse):

```c
HttpResponse* r = Http.get(Url.withCString("http://example.com/"));
if (r.status() == (u32)200)
    Stdio.printf("%s\n", r.bodyString().cString());
else if (r.status() == (u32)0)
    Stdio.printf("no response: %s\n", r.error().cString());
```

[`Http.fetch`](#fetch) runs the same request on a new thread and calls a block
with the status and the body when it finishes:

```c
Http.fetch(url, block void(u32 status, String* body) {
    // runs on the request's thread, not the caller's
    });
```

[`Http.install`](#install) makes `Http` the transport behind `url.fetch(…)`,
so code written against `Url` works unchanged:

```c
Http.install();
url.fetch(block void(u32 status, String* body) { … });
```

A status of **0** means there was no HTTP response at all — the host did not
resolve, the connection was refused, or nothing arrived for 30 seconds.
[`error`](#error) says which. Any HTTP status, 404 and 500 included, is a
response.

Each request uses its own connection and asks the server to close it.
Redirects (301, 302, 303, 307 and 308) are followed, up to five. A chunked or
`Content-Length` body is decoded.

:::caution[Threads]
The block passed to [`fetch`](#fetch), and to `url.fetch` after
[`install`](#install), runs on the request's own thread. Anything it shares
with the rest of the program needs a `Mutex`, and a UI toolkit's objects
should only be touched from the toolkit's own thread. Or call
[`deliverOn`](#deliveron) with a [`RunLoop`](/compiler/api/runloop/), and the
completions run on that loop's thread instead. Importing `Http.xc` turns on
thread-safe reference counting, as any use of `Thread` does.
:::

:::note[Availability]
`Http` needs sockets and threads: **arm64** (macOS, iOS, Android),
**x86_64** (Linux) and **win64**. Importing it on **xt6502**, **m68k**,
**arm9** or **wasm32** is a compile-time error. On **wasm32**, `url.fetch`
already goes through the browser.
:::

## https

`Http` does no cryptography itself. `HttpTls.xc` connects it to the optional
TLS library, which verifies every server certificate against a CA bundle:

```c
#import "HttpTls.xc"

if (!HttpTls.install())
    Stdio.printf("no CA bundle found; https is off\n");
```

[`HttpTls.install`](#httptlsinstall) looks for a bundle where macOS and the
common Linux distributions keep one (`/etc/ssl/cert.pem`,
`/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`,
`/etc/ssl/ca-bundle.pem`). Android and Windows keep their certificates
elsewhere, so there, pass a PEM bundle to
[`installWithBundle`](#httptlsinstallwithbundle). There is no mode that skips
the check. Without a TLS layer, an https URL fails with status 0 and an error
saying so.

## Http

### get

```c
static HttpResponse* get(Url* url)
```

Sends a GET for `url`, following redirects, and returns the response. Blocks
until the response has arrived or the request has failed.

### fetch

```c
static void fetch(Url* url, block cb void(u32, String*))
```

Runs [`get`](#get) on a new thread and calls `cb` on that thread with the
status and the body. On a failure the status is 0 and the body is `0`.

### install

```c
static void install(void)
```

Sets the platform delegate to one whose fetch runs [`fetch`](#fetch), so
`url.fetch(…)` uses this transport. It replaces any delegate already set.

### deliverOn

```c
static void deliverOn(RunLoop* loop)
```

Posts every completion (from [`fetch`](#fetch), and from `url.fetch` after
[`install`](#install)) to `loop`, so it runs on that loop's thread. `0` goes
back to running completions on the request's own thread. Set it before
starting requests.

### setSecureLayer

```c
static void setSecureLayer(HttpSecureLayer* layer)
```

Registers the layer https requests go through. `HttpTls.install` calls this;
a program with its own TLS stack can adopt `HttpSecureLayer` and
`HttpSecureConnection` and register that instead.

## HttpResponse

### status

```c
u32 status(void)
```

The HTTP status code, or 0 when there was no response.

### error

```c
String* error(void)
```

Why there was no response, or `0` when there was one.

### url

```c
Url* url(void)
```

The URL that answered, after any redirects.

### body

```c
Data* body(void)
```

The body's bytes, empty when there were none.

### bodyString

```c
String* bodyString(void)
```

The body as a string.

### header

```c
String* header(String* name)
```

A response header by name, in any case, or `0` when the server did not send
it. A header sent more than once reads as its values joined by `", "`.

### headers

```c
Map* headers(void)
```

Every response header, keyed by its lower-case name.

## HttpTls

### HttpTls.install

```c
static bool install(void)
```

Registers https with `Http`, verifying certificates against the first CA
bundle found in the usual places. `false` when there is none, and https stays
off.

### HttpTls.installWithBundle

```c
static bool installWithBundle(String* path)
```

Registers https with `Http`, verifying certificates against the PEM bundle at
`path`. `false` when the bundle cannot be loaded.
