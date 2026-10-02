---
title: UXFileIO
description: "Read a whole file, or write one atomically: what a document-based app needs to open and save, on every native target."
---

`UXFileIO` reads a whole file into a [`UXData`](/compiler/api/uxkit/uxdata/)
and writes one back:

```c
UXData* bytes = UXFileIO.read(path);          // null if it cannot be read
bool ok = UXFileIO.write(path, bytes);        // false if it did not happen
```

It is libc's stdio underneath, which every native target has: macOS,
Linux, Windows, iOS and Android inside their sandboxes, and GEM through its
own libc. The standard library's `Files.xc` exists only on the host
architectures, so a document app built on it could not save on a device or
on GEM. `UXFileIO` can.

## Saving is atomic

`write` puts the bytes in `path` + `.uxtmp` first. It renames that over the
original only when every byte is written and the file is closed.

A full disk, a missing folder or a failed write therefore leaves the
previous document exactly as it was, instead of truncating it. The temporary
file is removed on failure.

:::note[Windows]
Windows' `rename` will not replace an existing file, so there the original
is removed first. That still happens only after the new bytes are safely on
disk.
:::

## The web

A browser has no file system. On wasm32 both calls fail cleanly, `read`
returning null and `write` returning false, rather than pretending.
Saving on the web means a download, which is a separate, later piece.

## Topics

### read

```c
static UXData* read(u8* path)
```

The whole file, or null if it does not exist or cannot be read. An empty
file reads as an empty `UXData`, not as null.

### write

```c
static bool write(u8* path, UXData* d)
```

Writes `d` to `path`, replacing it only if every byte made it to disk.

## See also

- [`UXSavePanel`](/compiler/api/uxkit/uxsavepanel/) and
  [`UXOpenPanel`](/compiler/api/uxkit/uxopenpanel/), for asking the user
  which file
- [`UXData`](/compiler/api/uxkit/uxdata/)
