---
title: UXURL
description: "A URL split into scheme, host, port, path, query and fragment, and rebuilt, with no network access."
---

`UXURL` parses `scheme://host:port/path?query#fragment` into six fields and
builds it back again. It has the shape of `NSURL`/`NSURLComponents`.

It works on strings only: nothing here resolves, connects or looks anything up.
It is the **model half** of networking (a connection would take one of these),
and it also backs `public.file-url` pasteboard payloads and the file panel.

```c
#use <UXKit>            // or #import "UXURL.xc"
```

## Overview

```c
UXURL* u = UXURL.parse((u8*)"https://example.org:8443/docs/uxkit?tab=api#paths");

u.scheme;               // "https"
u.host;                 // "example.org"
u.port;                 // 8443
u.path;                 // "/docs/uxkit"
u.query;                // "tab=api"      — no leading '?'
u.fragment;             // "paths"        — no leading '#'
u.lastPathComponent();  // "uxkit"
u.toString();           // the whole thing again
```

The delimiters are **not** stored: `query` is `"tab=api"`, not `"?tab=api"`.
[`toString`](#tostring) restores them when the part is non-empty, so a URL with
no fragment has no trailing `#`.

## Every field has an empty default, never null

```c
scheme = ""; host = ""; path = ""; query = ""; fragment = ""; port = -1;
```

A parsed URL is always safe to print and compare, whatever the input. There is
no "is this part present" call because there is no null to guard against. An
absent part is empty; test with `slen(...) > 0` when you need to.

`port` is the exception, because `0` is a valid number:

:::note[`port` is -1 when unspecified, not 0]
`-1` means *"use the scheme's default"*: 443 for https, 21 for ftp. A URL with
no port rebuilds without a colon. Storing `0` would either print `:0` or need a
second flag to mark it as absent.
:::

## "://" is what makes a scheme

The parser looks for the literal `://`. Without it there is **no scheme and no
host**, and the whole string is the path:

```c
UXURL* bare = UXURL.parse((u8*)"notes/today.md");
bare.scheme;      // ""
bare.host;        // ""
bare.path;        // "notes/today.md"
```

A bare filename or relative path therefore survives `parse` unchanged and is not
misread as a host. The cost of this rule is that `mailto:user@example.org` has a
scheme by RFC but not by this parser, and comes out as a path. Schemes without
an authority are not handled.

## file: URLs are the bridge to UXPath

```c
UXURL* f = UXURL.fileURL((u8*)"/usr/local/share/fonts/system.fnt");
f.toString();       // "file:///usr/local/share/fonts/system.fnt"
f.isFileURL();      // true
UXPath* p = UXPath.parse(f.path);
```

The three slashes are `file://`, an empty host, and a path that starts with `/`.
This is the correct form, and the rebuild produces it without a special case.

A dropped file arrives this way. The pasteboard carries `public.file-url`; you
parse it, take `.path`, and continue with
[`UXPath`](/compiler/api/uxkit/uxpath/).

:::caution[No percent-encoding, in either direction]
`parse` does not decode `%20` and `toString` does not encode anything. A path
with a space round-trips as a space.

For local files and pasteboard payloads this is correct: the path you get is the
path you open, with no decode step to forget. If you build a URL for a network
stack, encode it yourself first.
:::

## Fields

### scheme

```c
u8* scheme      // "" when the string had no "://"
```

### host

```c
u8* host        // "" for file: URLs and for scheme-less strings
```

### port

```c
i32 port        // -1 = unspecified
```

### path

```c
u8* path
```

Everything after the authority, up to `?` or `#`. Keeps its leading `/`.

### query

```c
u8* query       // no leading '?'
```

Held whole and not split into pairs. The structure of a query string is up to
the application.

### fragment

```c
u8* fragment    // no leading '#'
```

## Topics

[parse](#parse) · [fileURL](#fileurl) · [isFileURL](#isfileurl) · [lastPathComponent](#lastpathcomponent) · [toString](#tostring)

### parse

```c
static UXURL* parse(u8* s)
```

Splits a string into the six fields. Copies the bytes, so the input can be
freed. Never fails: a string that is not a URL becomes a URL that is all path.

### fileURL

```c
static UXURL* fileURL(u8* path)
```

A `file:` URL for a local path.

:::note
Unlike [`parse`](#parse), this **keeps the pointer** you give it and does not
copy. Pass a string that outlives the URL, such as a literal or something you
allocated, not a stack buffer.
:::

### isFileURL

```c
bool isFileURL(void)
```

Whether the scheme is `file`, compared by content.

### lastPathComponent

```c
u8* lastPathComponent(void)
```

The filename: everything after the last `/` in [`path`](#path). `""` for a URL
whose path ends in a separator.

### toString

```c
u8* toString(void)
```

Rebuilds the string, restoring `://`, `:port`, `?` and `#` for the parts that
are present. `parse` → `toString` round-trips.

## Example

```
url scheme=https host=example.org port=8443
    path=/docs/uxkit query=tab=api fragment=paths
    last=uxkit rebuilt=https://example.org:8443/docs/uxkit?tab=api#paths
no port: port=-1 rebuilt=http://example.com/index.html
bare: scheme='' host='' path=notes/today.md
file url: file:///usr/local/share/fonts/system.fnt isFile=1 name=system.fnt
back to path: '/usr/local/share/fonts/system.fnt'  count=5 abs=1
```

The program is `website/site/examples/uxkit/paths.xc`. The `doc-examples` gate
compiles it, and the block above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXPath`](/compiler/api/uxkit/uxpath/): the same job for filesystem paths
- [`UXPasteboard`](/compiler/api/uxkit/uxpasteboard/): where `public.file-url`
  payloads arrive
- [`UXFilePanel`](/compiler/api/uxkit/uxfilepanel/): choosing a file
