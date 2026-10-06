---
title: Url
description: "A URL as a value: its scheme, host, port, path and query; file URLs made from paths and read back; and a fetch that works on every target."
---

`Url` is a URL as a value (`NSURL` in shape).

```c
#import "Url.xc"
```

## Overview

```c
Url* u = Url.withCString("https://example.com:8080/dir/page.html?x=1");
u.host();                 // "example.com"
u.port();                 // 8080
u.path();                 // "/dir/page.html"
u.lastPathComponent();    // "page.html"

Url* f = Url.fileURL(String.withCString("/Users/ada/My Docs/notes.txt"));
f.toString();             // "file:///Users/ada/My%20Docs/notes.txt"
f.filePath();             // "/Users/ada/My Docs/notes.txt"
```

The accessors scan the text; nothing is parsed ahead of time.

**File URLs** (from 0.72): [`fileURL`](#fileurl) escapes
every byte of a path that is not a letter, digit or one of `- . _ ~ /`, and a
Windows path (`C:\Work\notes.md`) becomes `file:///C:/Work/notes.md`.
[`filePath`](#filepath) undoes both.

**Fetching**: `url.fetch(block void(u32 status, String* body) { … })` is the same
line of source on every target. The transport is the platform's: the browser on
wasm32, an app's own delegate elsewhere. With none, the block is called at once
with status 0 after a logged warning, so the code still runs everywhere.

## Topics

**Creating** · [withString / withCString](#withstring--withcstring) · [fileURL](#fileurl) · [toString](#tostring)

**Parts** · [scheme](#scheme) · [host](#host) · [port](#port) · [path](#path) · [query](#query) · [lastPathComponent](#lastpathcomponent) · [pathExtension](#pathextension)

**File URLs** · [isFileURL](#isfileurl) · [filePath](#filepath) · [percentDecode](#percentdecode)

**Fetching** · [fetch](#fetch)

---

## Creating

### withString / withCString
```c
static Url* withString(String* s)
static Url* withCString(u8* s)
```
The text as it is: nothing is checked or escaped.

### fileURL
```c
static Url* fileURL(String* path)
```
The file URL for `path`. A relative path is taken as it stands; Url does not
know the working directory. **From 0.72.**

### toString
```c
String* toString(void)
```

[↑ Topics](#topics)

## Parts

### scheme
```c
String* scheme(void)
```
The text before `://`, or `""`.

### host
```c
String* host(void)
```

### port
```c
u32 port(void)
```
0 when the URL names none.

### path
```c
String* path(void)
```
`/` when the URL has none. Still percent-escaped.

### query
```c
String* query(void)
```
The text after `?`, or `""`.

### lastPathComponent
```c
String* lastPathComponent(void)
```
The last component of the decoded path; `""` for `/`. **From 0.72.**

### pathExtension
```c
String* pathExtension(void)
```
**From 0.72.**

[↑ Topics](#topics)

## File URLs

### isFileURL
```c
bool isFileURL(void)
```
Whether the scheme is `file`, in any case. **From 0.72.**

### filePath
```c
String* filePath(void)
```
A file URL's path with its escapes decoded (and `/C:/x` as `C:/x`), or null for
any other URL. **From 0.72.**

### percentDecode
```c
static String* percentDecode(String* s)
```
`s` with each `%XX` replaced by its byte; a `%` not followed by two hex digits
is kept as it is. **From 0.72.**

[↑ Topics](#topics)

## Fetching

### fetch
```c
void fetch(block cb void(u32, String*))
```
Calls `cb` with the HTTP status and body when the fetch completes. Status 0 means
no transport, or a failure below HTTP; the body is null then.

[↑ Topics](#topics)
