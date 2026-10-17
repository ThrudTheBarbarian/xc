---
title: Bundle
description: "Where a program's own files live: name one directory and resolve resources inside it, so a launcher, an icon and a test harness all find the same files. A complete method reference."
---

`Bundle` names the one directory a program's resources live in — a shader, a
font, a template, a dictionary, a set of fixtures — and resolves a resource name
inside it. "The directory I was started from" is not an answer to that question:
a launcher, a desktop icon and a test harness each start a program somewhere
else.

```c
#import "Bundle.xc"
```

## Overview

[`Bundle.main()`](#main) is the directory of the **running executable**
(`argv[0]`), which is where an installed program's resources sit. When the
layout is different, `$XCC_BUNDLE_ROOT` overrides it, and
[`Bundle.withRoot`](#withroot) names any directory outright — which is what a
test wants.

```c
Bundle* b = Bundle.main();
String* t = b.textForResource(String.withCString("greeting"), String.withCString("txt"));
if (t == 0) { /* there is no such resource */ }
```

[`resourcePath`](#resourcepath) is `<root>/Resources` when such a directory
exists and `<root>` otherwise, so the same source works for an app that has a
`Resources` folder and for one that keeps everything flat.

A missing resource is **`0`, not an empty string**, so "there is no such
resource" and "the resource is empty" stay different answers.

:::note[Availability]
`Bundle` is a `generic/lib/` class and is cross-platform: **arm64**, **arm9**,
**m68k**, **x86_64** and **win64** read resources; **wasm32** reads them through
its loader. On **xt6502** there is no filesystem and no `argv`, so a bundle can
be named — [`root`](#root), [`directoryOf`](#directoryof) and the path builders
all work — but [`textForResource`](#textforresource) and its siblings always
answer `0`.
:::

## Signed bundles

A **plugin** is a bundle another program loads: a library with its resources,
laid out the same way on every platform and signed by its publisher.
`xcc --bundle` builds one:

```sh
xcc --bundle spice -A arm64  -o spice.dylib spice.xc --resources art/
xcc --bundle spice -A x86_64 -o spice.so    spice.xc      # adds linux-x86_64
```

```
spice/
    bundle.json        the manifest: name, version, platforms, every file's SHA-256,
                       the publisher's public key, the protocols it provides and requires
    bundle.sig         the Ed25519 signature over bundle.json
    Exec/macos-arm64/spice.dylib
    Exec/linux-x86_64/spice.so
    Resources/...
```

Each run adds or replaces its target's entry and signs the manifest again.
The publisher key is made on first use in `~/.xcc/bundle-key` (or the file
`--bundle-key` names) and its fingerprint is printed: keep it, because an update
must be signed by the same key. `--bundle-name`, `--bundle-version`,
`--publisher` and `--publisher-domain` fill in the rest of the manifest,
`--property k=v` and `--setting k=v` add the developer's own
[properties](/compiler/api/plugin/#properties), and `--rotate-from <old key>`
hands the bundle over to a [new key](/compiler/api/plugin/#trust); what
the bundle provides and requires comes from the protocols with
[static members](/compiler/language/inheritance/#static-members-an-interface-between-programs)
it declares.

A plugin may load only the system's libraries, or ones shipped inside the
bundle: a library it links that the system does not provide (an xc library
built with `--emit-lib`, say) is refused unless named with `--bundle-lib
<file>`, which puts it beside the code in `Exec/<os>-<arch>/`, listed and
signed like the rest. The loader loads those first, from the verified copy, so
the system never goes looking for them elsewhere.

With `-A wasm32` the entry is `Exec/wasm32/<name>.wasm`, a module with its
own memory that a web page loads. [Plugin](/compiler/api/plugin/) loads a
bundle's code into a running program, on every target.

`BundleSign.verify(dir)` (`#import "BundleSign.xc"`) checks a bundle before
anything in it is used, and says what is wrong: a signature that does not
verify, a manifest with a key given twice, a path outside the bundle, a link,
a file the manifest does not list, or one that has changed since it was
signed.

## Topics

**Construction** · [withRoot](#withroot) · [main](#main) · [mainFrom](#mainfrom) · [directoryOf](#directoryof)

**Paths** · [root](#root) · [resourcePath](#resourcepath) · [pathFor](#pathfor) · [pathForResource](#pathforresource)

**Contents** · [resourceExists](#resourceexists) · [textForResource](#textforresource) · [dataForResource](#dataforresource)

---

## Construction

### withRoot
```c
static Bundle* withRoot(String* root)
```
A bundle whose resources live under `root`. A null or empty `root` becomes `.`,
so the path builders always produce something usable.

### main
```c
static Bundle* main(void)
```
The bundle of the **running program**: `$XCC_BUNDLE_ROOT` when that is set and
non-empty, otherwise the directory part of `argv[0]`, otherwise `.`.

### mainFrom
```c
static Bundle* mainFrom(String* envName)
```
The same, reading `envName` instead of `$XCC_BUNDLE_ROOT` — for a program with
several bundles, or one that already has a variable of its own. A null or empty
`envName` is [`main`](#main).

### directoryOf
```c
static String* directoryOf(String* path)
```
The directory part of `path`: everything before the last `/` or `\`. A path with
no separator yields `.`; a leading separator yields `/`. Public because the same
question comes up outside a bundle.

[↑ Topics](#topics)

## Paths

### root
```c
String* root(void)
```
The directory the bundle was built with.

### resourcePath
```c
String* resourcePath(void)
```
`<root>/Resources` when that directory exists, `<root>` otherwise. Every
resource lookup goes through here, which is what makes the flat and the
`Resources` layouts interchangeable.

### pathFor
```c
String* pathFor(String* relative)
```
A path inside the resources, whether or not the file is there. An empty
`relative` is [`resourcePath`](#resourcepath) itself.

### pathForResource
```c
String* pathForResource(String* name, String* ext)
String* pathForResource(String* name, String* ext, String* subdir)
```
`<resourcePath>/<subdir>/<name>.<ext>`. An empty `ext` drops the dot, so an
extensionless resource is nameable; an empty `subdir` is the resources
themselves. The path is built whether or not the file is there, so a caller can
name where a resource **would** be.

[↑ Topics](#topics)

## Contents

### resourceExists
```c
bool resourceExists(String* name, String* ext)
```
`true` when the resource is there.

### textForResource
```c
String* textForResource(String* name, String* ext)
```
The resource's bytes as a [`String`](/compiler/api/string/), or **`0`** when it
is missing.

### dataForResource
```c
Data* dataForResource(String* name, String* ext)
```
The resource's bytes as [`Data`](/compiler/api/data/), or **`0`** when it is
missing.

[↑ Topics](#topics)

## See also

- [Settings](/compiler/api/settings/): where a program's *values* are kept, as
  opposed to where its *files* live.
- [String](/compiler/api/string/): the type a resource path and a text resource
  come back as.
