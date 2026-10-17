---
title: Plugin
description: "Load a signed bundle's code into a running program, natively or on the web: verified before anything in it runs, trusted once by the user, and called through versioned protocols. A complete method reference."
---

`Plugin` loads the code of a [signed bundle](/compiler/api/bundle/#signed-bundles)
into a running program. The program and the plugin talk through
[protocols with static members](/compiler/language/inheritance/#static-members-an-interface-between-programs):
the program **provides** some (the plugin calls them) and the plugin provides
others (the program calls them).

```c
#import "Plugin.xc"
```

## Overview

```c
protocol Fence :version(2.1) { static i32 emit(u8* p, u32 n); }
protocol Spice :version(1.0) { static i32 run(i32 x); }

class Host : Object <Fence>
    {
    static i32 emit(u8* p, u32 n) { ... }
    }

bool ask(String* name, String* publisher, String* domain, String* keyId)
{
    return true;        // ask the user: this is the first time this publisher's plugin is seen
}

void loaded(Plugin* p)
{
    if (p == (Plugin*)0) {
        Stdio.printf("%s\n", Plugin.lastError().cString());
        return;
    }
    Spice.bind(p.table(String.withCString("Spice")));
    Spice.run((i32)7);
}

i32 main(void)
{
    Plugin.provide(String.withCString("Fence"), Fence.versionMajor(), Fence.versionMinor(), Fence.table());
    Plugin.loadAsync(String.withCString("spice"), &ask, &loaded);
    return 0;
}
```

The same lines work on every target. Natively `where` is a directory and
`loaded` runs before `loadAsync` returns; on the web it is a URL, and `loaded`
runs once the bundle has been fetched and checked.

Nothing from the bundle runs until every check has passed:

1. The signature over the manifest verifies, and the manifest parses strictly
   (no key given twice, every path one a bundle may hold).
2. Every file is what the manifest says. Natively the bundle is first copied
   into a private store (`~/.xcc/plugins`, or `$XCC_PLUGIN_STORE`), and only
   the verified copy is used, so nothing can swap a file between the check and
   the load. On the web, the code's bytes are hashed and exactly those bytes are
   compiled.
3. Trust: the first time a publisher's key and a plugin's name are seen
   together, the program's consent callback is asked, and a yes is recorded.
   With no callback, the plugin is refused. A plugin older than one loaded
   before is refused too. The records are kept apart from the program's
   [Settings](/compiler/api/settings/): natively in the store's `trust` file, on
   the web in the page's `localStorage`.
4. The bundle has code for this platform, and every protocol it requires is
   one the program provides, with the same major version and at least the
   minor version it was built against.
5. Natively, the code's own export table, read from the file before it is
   loaded, has every protocol the manifest says it provides and requires.
   Loading a library runs its startup code, so a manifest that does not match
   its code is refused before that.

### Trust

The first load of a publisher's plugin asks the consent callback; the
publisher is then known by its key, not its name. Three things narrow that
first decision:

- **A hash-pinned link** names exact bytes: `spice@sha256:<hash>` (the SHA-256
  of `bundle.json`, which lists every file's hash). Such a load needs no
  question, and loads nothing else.
- **A curated program** accepts only the publishers it was built to trust:
  `xcc --trust key.pub ... -o app app.xc`, with each publisher's public key
  file (`xcc --bundle` writes it beside the private key, as `<key>.pub`). Any
  other publisher's plugin is refused, asked or not.
- **The publisher's domain vouches for its key.** When the manifest names a
  domain and the bundle was fetched from that host, the loader reads
  `/.well-known/xc-bundle-keys` there: `{"keys": [...], "revoked": [...]}`, key
  fingerprints. The consent callback is shown the domain only when it vouches
  for the key (otherwise it gets `""`), and a revoked key is refused. (On the
  web; the file must be readable by the page, so serve it with CORS when the
  page is elsewhere.)

**Keys change.** A publisher moving to a new key builds with `xcc --bundle ...
--bundle-key new --rotate-from old`: the old key signs the hand-over, and a
plugin trusted under the old key carries on under the new one, with no
question and its version floor kept. The old key is then retired: a plugin it
signs later is asked about as a stranger. When the publisher's domain can be
checked, a hand-over counts only if the domain vouches for the new key too, so
a leaked old key cannot hand the plugin to someone else.

A refusal says which check failed:

```
spice 1.0 is older than 1.1, which was loaded before
spice needs Fence 2.1; this program provides 2.0
spice 1.2 has no build for linux-x86_64; it has macos-arm64, wasm32
```

### On the web

A web plugin is a WebAssembly module with **its own memory**: it cannot read or
write the program's. A call between the two goes through the loader, which
copies each buffer into the other module's memory and back, after checking that
it lies inside the caller's own. So a protocol used between web modules passes
numbers, or a pointer to numbers followed by their count:

```c
static u32 sum(u8* p, u32 n);       // a buffer and its length: copied in, and back
static void take(String* s);        // refused when compiled for wasm32
```

A web plugin gets output, maths, time and random numbers from the loader, and
nothing else: no files, no environment, and no way to end the program.

## Topics

- [Loading](#loading): [loadAsync](#loadasync), [load](#load), [lastError](#lasterror)
- [Protocols](#protocols): [provide](#provide), [table](#table)
- [The loaded plugin](#the-loaded-plugin): [name](#name), [directory](#directory), [resource](#resource), [symbol](#symbol)
- [Properties](#properties): [info](#info), [value](#value), [setValue](#setvalue), [resetValue](#resetvalue),
  [infoKeys](#infokeys), [isWriteable](#iswriteable), [isOverridden](#isoverridden),
  [defaultChanged](#defaultchanged), [useSettings](#usesettings), [valueChanged](#valuechanged)

## Loading

### loadAsync

```c
static void loadAsync(String* where, PluginConsent_t* consent, PluginDone_t* done)
```

Loads the bundle at `where`, a directory or (on the web) a URL, and calls
`done` with the plugin, or with 0 when it was refused; then
[`lastError()`](#lasterror) says why. `consent` is asked the first time a
publisher's plugin is seen; 0 refuses any plugin not trusted before.

```c
typedef bool PluginConsent_t(String* name, String* publisher, String* domain, String* keyId);
typedef void PluginDone_t(Plugin* p);
```

The publisher and domain are what the manifest says, so they are a claim; the
key is the identity. A record is kept for the key and the name together, so
another publisher's plugin of the same name is asked about again.

### load

```c
static Plugin* load(String* path, PluginConsent_t* consent)
```

The same, returning the plugin at once. Native targets only; on the web it
refuses, because fetching cannot block there.

### lastError

```c
static String* lastError(void)
```

Why the last load was refused.

## Protocols

### provide

```c
static void provide(String* proto, u32 major, u32 minor, pointer table)
```

Says that this program provides `proto` at `major.minor`, with the table its
companion makes: `Fence.table()`. A plugin that requires `Fence` gets that
table bound into it as it loads.

### table

```c
pointer table(String* proto)
```

What the program hands `proto.bind()` to call a protocol the plugin provides,
or 0 when it provides none by that name.

## The loaded plugin

### name

```c
String* name(void)
```

The bundle's name.

### directory

```c
String* directory(void)
```

Where the plugin's verified files are: natively, its copy in the private store
(its `Resources/` included); on the web, its URL.

### resource

```c
void resource(String* name, block cb void(Data*))
```

A file of the plugin's `Resources/`, checked against the signed manifest:
`cb` gets its bytes, or 0 when it is not there or not what was signed.
Natively `cb` runs at once; on the web, once the file has been fetched.

```c
p.resource(String.withCString("icon.png"), block void(Data* d) { ... });
```

### symbol

```c
pointer symbol(String* nm)
```

A symbol of a native plugin's code, or 0. On the web there are none: call a
protocol the plugin provides instead.

### Offline

On the web, each file of a plugin that loaded is kept: in the browser's Cache
Storage, or `$XCC_PLUGIN_STORE/cache` under Node. When the network does not
answer, the kept copy is used, and it is checked exactly as a fresh download
is, so a copy that has changed is refused. A server that answers with an
error is not "offline": its answer stands. A file is kept only after it has
been checked, so a bad download never replaces a good copy.

## Properties

A bundle can carry the developer's own text values, set when it is built:

```sh
xcc --bundle spice -o spice.dylib spice.xc \
    --property endpoint=https://example.org/api \
    --setting theme=dark
```

A `--property` is the publisher's and cannot be changed. A `--setting` is a
default the user may override. Both are signed with the rest of the manifest.
A user's override is kept in the app's [Settings](/compiler/api/settings/),
outside the bundle, under `bundle.<publisher key id>.<name>.<key>`. So it
survives updates, needs no new consent, and two publishers' plugins of the
same name do not read each other's values. Names are letters, digits, `_` and
`-`; a value is at most 1024 bytes on one line.

The user's value wins across updates. When an update ships a new default,
[`defaultChanged`](#defaultchanged) says so, so a settings page can offer it. A
key that becomes a `--property` takes the publisher's value; the user's is kept
and applies again if the key becomes a `--setting` again.

A writeable value is input like any other: anything that can write the app's
Settings can set it, another plugin included. Validate it, and keep anything
that matters for security (an update address, where data is sent) a
`--property`.

### info

```c
String* info(String* key)
```

The manifest's value, or 0. Never the user's.

### value

```c
String* value(String* key)
```

What the plugin should use: a `--property`'s value; otherwise the user's value
if there is one; otherwise the manifest's default (or 0).

### setValue

```c
bool setValue(String* key, String* v)
```

Keeps a user's value for `key`, and posts [`valueChanged`](#valuechanged). A key
the manifest does not have is allowed, which is how a plugin keeps its own
state. Refused, with a logged reason, for a `--property`, a name outside the
grammar, or a value that is not one line of at most 1024 bytes.

### resetValue

```c
void resetValue(String* key)
```

Drops the user's value, so `value` reads the manifest again, and posts
[`valueChanged`](#valuechanged).

### infoKeys

```c
Array* infoKeys(void)
```

The manifest's keys, both kinds, sorted: for a settings page.

### isWriteable

```c
bool isWriteable(String* key)
```

Whether `setValue` may change `key`: every key but a `--property`.

### isOverridden

```c
bool isOverridden(String* key)
```

Whether `value(key)` is the user's.

### defaultChanged

```c
bool defaultChanged(String* key)
```

Whether the publisher's default has changed since the user's value replaced it.

### useSettings

```c
static void useSettings(Settings* s)
```

Where users' values are kept: the app's Settings. Without it they last for the
run only.

### valueChanged

```c
static String* valueChanged(void)
```

The name of the notification `setValue` and `resetValue` post through
[NotificationCenter](/compiler/api/notificationcenter/), with the plugin as its
sender and `{"key": key}` as its user info.

## See also

- [Bundle](/compiler/api/bundle/): resources, and `xcc --bundle`, which makes
  the signed bundles this loads.
- [Inheritance](/compiler/language/inheritance/): protocols, and their static
  members.
