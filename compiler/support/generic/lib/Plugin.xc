// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// Plugin.xc — loading a signed bundle's code into this program
// (bundles-and-plugins.md §4), natively:
//
//     bool ask(String* name, String* publisher, String* domain, String* keyId) { ... }
//     Plugin.provide(String.withCString("Fence"), Fence.versionMajor(), Fence.versionMinor(), Fence.table());
//     Plugin* p = Plugin.load(String.withCString("spice"), &ask);
//     if (p == (Plugin*)0) Stdio.printf("%s\n", Plugin.lastError().cString());
//     pointer f = p.symbol(String.withCString("SpiceTool$run"));
//
// In this order, nothing from the bundle running until every check passed:
// verify the bundle where it is (BundleSign); copy only its listed files into
// a private store and verify that copy, so nothing can be swapped between
// the check and the load; trust — the record for (publisher key, name), at a
// version no lower than the highest loaded before, else the app's consent
// callback (none: refused), recorded on yes; the platform's entry; each
// protocol the plugin requires, against what this program provides
// (same major, minor at least the plugin's); then the code, from the copy
// (Windows: system32 and the copy's own directory only), and each required
// protocol's table bound into it. Not yet: reading the code's export table
// before loading it (§4 step 5).
//
// On the web (wasm32) loading is asynchronous, so Plugin.loadAsync(where,
// consent, done) is the one call for every target (natively it calls done at
// once): the manifest and signature are fetched from <where>/ and checked
// here, then the code, whose hash must match; the loader instantiates exactly
// those bytes as a module with its own memory and wires its protocol imports
// to this program's exports, copying buffers between the two memories. The
// trust records are the loader's (localStorage, or $XCC_PLUGIN_STORE/trust
// under Node). p.table(proto) is what the host hands proto.bind() to call a
// protocol the plugin provides, on every target.
#import "Foundation.xc"
#import "Files.xc"
#import "PlatformCore.xc"
#import "BundleSign.xc"

typedef bool PluginConsent_t(String* name, String* publisher, String* domain, String* keyId);
typedef void PluginBind_t(pointer table);
typedef pointer PluginTable_t(void);

#import "Sha256.xc"
#import "Exports.xc"
#if !ARCH_wasm32
#import "Http.xc"
#endif
#import "Settings.xc"
#import "NotificationCenter.xc"
#import "Log.xc"
#if ARCH_wasm32
#import "Url.xc"
// The loader's side (loader.js, the xcplugin package). Every bodyless
// declaration after this line in this file is one of its functions, which is
// why the native ones below are #if'd away here.
#package xcplugin
void _xt_plugin_instantiate(u32 token, u8* p, u32 n);
u32 _xt_plugin_trust_len(void);
void _xt_plugin_trust_copy(u8* dst);
void _xt_plugin_trust_set(u8* p, u32 n);
void _xt_plugin_cache_put(u8* u, u32 un, u8* p, u32 n);
void _xt_plugin_cache_get(u32 token, u8* u, u32 un);
#endif

#if OS_windows
pointer LoadLibraryExA(u8* path, pointer file, u32 flags);
pointer GetProcAddress(pointer module, u8* name);
#elif ARCH_arm64 || ARCH_x86_64
pointer dlopen(u8* path, i32 mode);
pointer dlsym(pointer handle, u8* name);
u8* dlerror(void);
#endif

class PluginProvided : Object
    {
    u32 major;
    u32 minor;
    pointer table;
    }

typedef void PluginDone_t(Plugin* p);

// One web fetch of a bundle's file: from the network, and kept as the
// offline copy; from that copy when the network does not answer. Whatever
// comes back is checked by the caller, so a changed copy is refused.
class PluginFetch : Object
    {
    String* url;
    block cb void(u32, String*);

    void fire(u32 status, String* body)
        {
        cb(status, body);
        }
    }

// A web load in flight, between its fetches.
class PluginPending : Object
    {
    String* base;
    PluginConsent_t* consent;
    PluginDone_t* done;
    Data* manifest;
    Map* m;
    String* name;
    String* version;
    String* keyId;
    String* highest;
    String* code;
    String* sig;
    String* codeBytes;
    String* pin;
    String* rotated;
    String* domain;
    bool reached;
    bool vouched;
    bool revoked;
    }

class Plugin : Object
    {
    String* _name;
    String* _dir;
    pointer _handle;
    u32 _web;
    Map* _files;
    Map* _readonly;
    Map* _writeable;
    String* _keyId;
    static Settings* _settings;
    static Map* _pending;
    static Map* _fetches;
    static u32 _nextToken;

    static String* _error;
    static Map* _provided;

    static String* lastError(void) { return _error; }
    String* name(void) { return _name; }
    // Where the verified private copy is (its Resources/ too).
    String* directory(void) { return _dir; }

    // What this program provides to plugins: a protocol's version and table.
    static void provide(String* proto, u32 major, u32 minor, pointer table)
        {
        if (_provided == (Map*)0)
            _provided = new Map();
        PluginProvided* pp = new PluginProvided();
        pp.major = major;
        pp.minor = minor;
        pp.table = table;
        _provided.set((Hashable*)proto, (Object*)pp);
        }

    static Plugin* _fail(String* why)
        {
        _error = why;
        return (Plugin*)0;
        }

    static String* _platform(void)
        {
#if OS_windows
        return String.withCString("windows-x86_64");
#elif OS_android
        return String.withCString("android-arm64");
#elif OS_linux && ARCH_arm64
        return String.withCString("linux-arm64");   // as the driver names the bundle's directory
#elif OS_linux
        return String.withCString("linux-x86_64");
#elif ARCH_wasm32
        return String.withCString("wasm32");
#elif OS_ios
        return String.withCString("ios-arm64");    // as the driver names the bundle's directory
#else
        return String.withCString("macos-arm64");
#endif
        }

    // The private store: $XCC_PLUGIN_STORE, else ~/.xcc/plugins.
    static String* _store(void)
        {
        String* s = Platform.env(String.withCString("XCC_PLUGIN_STORE"));
        if (s.byteLength() > (u32)0)
            return s;
        String* h = Platform.home();
        h.appendCString("/.xcc");
        Files.createDirectory(h);
        h.appendCString("/plugins");
        return h;
        }

    // "1.10" against "1.9", part by part.
    static i32 _cmpVersion(String* a, String* b)
        {
        u32 i = (u32)0;
        u32 j = (u32)0;
        while (i < a.byteLength() || j < b.byteLength())
            {
            u64 x = (u64)0;
            u64 y = (u64)0;
            while (i < a.byteLength() && a.byteAt(i) != (u8)'.') { x = x * (u64)10 + (u64)(a.byteAt(i) - (u8)'0'); i = i + (u32)1; }
            while (j < b.byteLength() && b.byteAt(j) != (u8)'.') { y = y * (u64)10 + (u64)(b.byteAt(j) - (u8)'0'); j = j + (u32)1; }
            if (x != y)
                return x < y ? (i32)-1 : (i32)1;
            i = i + (u32)1;
            j = j + (u32)1;
            }
        return (i32)0;
        }

    // The trust records, "<keyId> <name> <highest version>" a line, in the
    // store's own file (not Settings, which a plugin could write).
    static String* _trustFile(void)
        {
        return BundleSign._join(Plugin._store(), String.withCString("trust"));
        }

    static String* _trustText(void)
        {
#if ARCH_wasm32
        u32 n = _xt_plugin_trust_len();
        if (n == (u32)0)
            return (String*)0;
        u8* b = new u8[n];
        _xt_plugin_trust_copy(b);
        String* t = String.withBytes(b, n);
        delete b;
        return t;
#else
        return Files.readText(Plugin._trustFile());
#endif
        }

    static void _trustWrite(String* t)
        {
#if ARCH_wasm32
        _xt_plugin_trust_set(t.cString(), t.byteLength());
#else
        Files.writeText(Plugin._trustFile(), t);
#endif
        }

    static String* _trusted(String* keyId, String* name)
        {
        String* t = Plugin._trustText();
        if (t == (String*)0)
            return (String*)0;
        String* want = String.withString(keyId);
        want.appendByte((u8)' ');
        want.append(name);
        want.appendByte((u8)' ');
        u32 at = (u32)0;
        while (at < t.byteLength())
            {
            u32 e = at;
            while (e < t.byteLength() && t.byteAt(e) != (u8)10)
                e = e + (u32)1;
            String* line = t.substringBytes(at, e - at);
            if (line.hasPrefix(want))
                return line.substringFromByte(want.byteLength());
            at = e + (u32)1;
            }
        return (String*)0;
        }

    static void _record(String* keyId, String* name, String* version)
        {
        String* t = Plugin._trustText();
        String* out = new String();
        String* want = String.withString(keyId);
        want.appendByte((u8)' ');
        want.append(name);
        want.appendByte((u8)' ');
        u32 at = (u32)0;
        while (t != (String*)0 && at < t.byteLength())
            {
            u32 e = at;
            while (e < t.byteLength() && t.byteAt(e) != (u8)10)
                e = e + (u32)1;
            String* line = t.substringBytes(at, e - at);
            if (!line.hasPrefix(want) && line.byteLength() > (u32)0)
                {
                out.append(line);
                out.appendByte((u8)10);
                }
            at = e + (u32)1;
            }
        out.append(want);
        out.append(version);
        out.appendByte((u8)10);
        Plugin._trustWrite(out);
        }

    // Retire the record for (key, name): a rotation moved the plugin on.
    static void _forget(String* keyId, String* name)
        {
        String* t = Plugin._trustText();
        if (t == (String*)0)
            return;
        String* want = String.withString(keyId);
        want.appendByte((u8)' ');
        want.append(name);
        want.appendByte((u8)' ');
        String* out = new String();
        u32 at = (u32)0;
        while (at < t.byteLength())
            {
            u32 e = at;
            while (e < t.byteLength() && t.byteAt(e) != (u8)10)
                e = e + (u32)1;
            String* line = t.substringBytes(at, e - at);
            if (!line.hasPrefix(want) && line.byteLength() > (u32)0)
                {
                out.append(line);
                out.appendByte((u8)10);
                }
            at = e + (u32)1;
            }
        Plugin._trustWrite(out);
        }

    // The trust decision for (key, name) at version: 0 to go on, else why not.
    // *highest is the version recorded before (0: none).
    // A hash-pinned link, `<where>@sha256:<64 hex>`: the hash of the exact
    // bundle.json bytes, which list every file's hash, so it names the whole
    // bundle. Returns the hash (0: not pinned) and leaves the rest in *rest.
    static String* _pinOf(String* where, String** rest)
        {
        *rest = where;
        String* tag = String.withCString("@sha256:");
        u32 n = where.byteLength();
        if (n < (u32)72 || !where.substringBytes(n - (u32)72, (u32)8).equals(tag))
            return (String*)0;
        String* h = where.substringFromByte(n - (u32)64);
        for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1)
            {
            u8 c = h.byteAt(i);
            if (!((c >= (u8)'0' && c <= (u8)'9') || (c >= (u8)'a' && c <= (u8)'f')))
                return (String*)0;
            }
        *rest = where.substringBytes((u32)0, n - (u32)72);
        return h;
        }

    static String* _decide(Map* m, PluginConsent_t* consent, String** highest)
        {
        String* r = (String*)0;
        return Plugin._decidePinned(m, consent, highest, false, &r, String.withCString(""));
        }

    // The publishers a curated program accepts (xcc --trust key.pub ...), as
    // their key fingerprints separated by spaces; 0 accepts any publisher.
    static String* curated(void)
        {
#ifdef XC_PLUGIN_TRUST
        return String.withCString(XC_PLUGIN_TRUST);
#else
        return (String*)0;
#endif
        }

    static bool _listed(String* list, String* id)
        {
        u32 at = (u32)0;
        while (at < list.byteLength())
            {
            u32 e = at;
            while (e < list.byteLength() && list.byteAt(e) != (u8)' ')
                e = e + (u32)1;
            if (list.substringBytes(at, e - at).equals(id))
                return true;
            at = e + (u32)1;
            }
        return false;
        }

    // pinned: the link named these exact bytes, so nobody is asked.
    // *rotatedFrom: the previous key's id when the trust came through its
    // record (a verified rotation), so the caller retires that record.
    // verified: the publisher's domain when it vouched for the key, else "";
    // that, not the manifest's claim, is what consent is shown.
    static String* _decidePinned(Map* m, PluginConsent_t* consent, String** highest, bool pinned, String** rotatedFrom,
                                 String* verified)
        {
        *rotatedFrom = (String*)0;
        String* name = (String*)m.get((Hashable*)String.withCString("name"));
        String* version = (String*)m.get((Hashable*)String.withCString("version"));
        Map* pub = (Map*)m.get((Hashable*)String.withCString("publisher"));
        String* keyId = (String*)pub.get((Hashable*)String.withCString("keyId"));
        String* only = Plugin.curated();
        if (only != (String*)0 && !Plugin._listed(only, keyId))
            return String.withFormat("%s is from a publisher this program was not built to trust (key %s)", name.cString(),
                                     keyId.substringBytes((u32)0, (u32)16).cString());
        String* h = Plugin._trusted(keyId, name);
        String* prevId = (String*)pub.get((Hashable*)String.withCString("previousKeyId"));
        if (h == (String*)0 && prevId != (String*)0)
            {
            // The manifest's rotation record verified with the bundle
            // (BundleSign.verifyManifest): the old key handed this plugin over.
            h = Plugin._trusted(prevId, name);
            if (h != (String*)0)
                *rotatedFrom = prevId;
            }
        *highest = h;
        if (h != (String*)0)
            {
            if (Plugin._cmpVersion(version, h) < (i32)0)
                return String.withFormat("%s %s is older than %s, which was loaded before", name.cString(),
                                         version.cString(), h.cString());
            return (String*)0;
            }
        if (pinned)
            return (String*)0;
        if (consent == (PluginConsent_t*)0)
            return String.withFormat("%s is not trusted yet, and nothing was asked (no consent callback)", name.cString());
        if (!consent(name, (String*)pub.get((Hashable*)String.withCString("name")), verified, keyId))
            return String.withFormat("%s was not trusted", name.cString());
        return (String*)0;
        }

    // The platform's code file in the manifest, or why there is none.
    static String* _codeFor(Map* m, String** why)
        {
        String* name = (String*)m.get((Hashable*)String.withCString("name"));
        String* version = (String*)m.get((Hashable*)String.withCString("version"));
        Map* files = (Map*)m.get((Hashable*)String.withCString("files"));
        Array* paths = files.allKeys();
        String* plat = Plugin._platform();
        String* prefix = String.withFormat("Exec/%s/%s.", plat.cString(), name.cString());
        String* code = (String*)0;
        for (u32 i = (u32)0; i < paths.count(); i = i + (u32)1)
            if (((String*)paths.get(i)).hasPrefix(prefix))
                code = (String*)paths.get(i);
        if (code != (String*)0)
            return code;
        Array* ps = (Array*)m.get((Hashable*)String.withCString("platforms"));
        String* has = new String();
        for (u32 i = (u32)0; ps != (Array*)0 && i < ps.count(); i = i + (u32)1)
            {
            if (i > (u32)0) has.appendCString(", ");
            has.append((String*)ps.get(i));
            }
        *why = String.withFormat("%s %s has no build for %s; it has %s", name.cString(), version.cString(),
                                 plat.cString(), has.cString());
        return (String*)0;
        }

    // Each protocol the plugin requires, against what this program provides
    // (same major, minor at least): 0, or why not.
    static String* _checkRequires(Map* m)
        {
        String* name = (String*)m.get((Hashable*)String.withCString("name"));
        Map* req = (Map*)m.get((Hashable*)String.withCString("requires"));
        Array* rk = req == (Map*)0 ? new Array() : req.allKeys();
        for (u32 i = (u32)0; i < rk.count(); i = i + (u32)1)
            {
            String* proto = (String*)rk.get(i);
            String* rv = (String*)req.get((Hashable*)proto);
            PluginProvided* pp = _provided == (Map*)0 ? (PluginProvided*)0 : (PluginProvided*)_provided.get((Hashable*)proto);
            if (pp == (PluginProvided*)0)
                return String.withFormat("%s needs %s %s, which this program does not provide", name.cString(),
                                         proto.cString(), rv.cString());
            u32 dot = rv.indexOfByte((u8)'.');
            u32 maj = (u32)BundleSign._num(dot == String.notFound() ? rv : rv.substringBytes((u32)0, dot));
            u32 min = dot == String.notFound() ? (u32)0 : (u32)BundleSign._num(rv.substringFromByte(dot + (u32)1));
            if (maj != pp.major || min > pp.minor)
                return String.withFormat("%s needs %s %s; this program provides %u.%u", name.cString(),
                                         proto.cString(), rv.cString(), pp.major, pp.minor);
            }
        return (String*)0;
        }

    static Plugin* load(String* path, PluginConsent_t* consent)
        {
        _error = (String*)0;
#if ARCH_wasm32
        return Plugin._fail(String.withFormat("%s: on the web a plugin is loaded with Plugin.loadAsync", path.cString()));
#else
        String* pin = Plugin._pinOf(path, &path);
        if (path.hasPrefix(String.withCString("http://")) || path.hasPrefix(String.withCString("https://")))
            return Plugin._loadUrl(path, pin, consent);
        String* err = BundleSign.verify(path);
        if (err != (String*)0)
            return Plugin._fail(String.withFormat("%s: %s", path.cString(), err.cString()));
        if (pin != (String*)0)
            {
            Data* mb = Files.readData(BundleSign._join(path, String.withCString("bundle.json")));
            if (!Sha256.hex(mb.bytes(), mb.length()).equals(pin))
                return Plugin._fail(String.withFormat("%s: not the bundle the link names (its sha256 differs)", path.cString()));
            }
        Map* m = (Map*)0;
        try
            {
            m = (Map*)BundleRules.parseManifest(Files.readData(BundleSign._join(path, String.withCString("bundle.json"))));
            }
        catch (JSONError e)
            {
            return Plugin._fail(e.message());
            }
        String* name = (String*)m.get((Hashable*)String.withCString("name"));
        String* version = (String*)m.get((Hashable*)String.withCString("version"));
        Map* pub = (Map*)m.get((Hashable*)String.withCString("publisher"));
        String* keyId = (String*)pub.get((Hashable*)String.withCString("keyId"));
        Map* files = (Map*)m.get((Hashable*)String.withCString("files"));
        // The private copy, verified again: only it is used from here on.
        String* root = Plugin._store();
        Files.createDirectory(root);
        String* dir = BundleSign._join(root, String.withFormat("%s-%s-%s", keyId.substringBytes((u32)0, (u32)16).cString(),
                                                              name.cString(), version.cString()));
        Array* paths = files.allKeys();
        paths.add((Object*)String.withCString("bundle.json"));
        paths.add((Object*)String.withCString("bundle.sig"));
        for (u32 i = (u32)0; i < paths.count(); i = i + (u32)1)
            {
            String* p = (String*)paths.get(i);
            String* to = BundleSign._join(dir, p);
            u32 slash = to.byteLength();
            while (slash > (u32)0 && to.byteAt(slash - (u32)1) != (u8)'/')
                slash = slash - (u32)1;
            BundleSign._mkdirs(to.substringBytes((u32)0, slash - (u32)1));
            if (!BundleSign._copy(BundleSign._join(path, p), to))
                return Plugin._fail(String.withFormat("cannot copy %s into the private store", p.cString()));
            }
        err = BundleSign.verify(dir);
        if (err != (String*)0)
            return Plugin._fail(String.withFormat("the private copy of %s: %s", name.cString(), err.cString()));
        return Plugin._loadCopy(m, dir, consent, pin != (String*)0, String.withCString(""), false, false, false);
#endif
        }

    // Caps on what a URL bundle may make this program download (review 16).
    static u32 _maxFile(void) { return (u32)268435456; }        // 256 MiB a file
    static u64 _maxTotal(void) { return (u64)1073741824; }      // 1 GiB a bundle

    // A bundle at a URL (bundles-and-plugins.md §2b): its manifest and
    // signature fetched and checked, the publisher's domain asked about the
    // key when it is the host the bundle comes from, then this platform's
    // code and the resources fetched into a side directory of the private
    // store, each checked against the manifest, the copy verified and only
    // then put in place. When nothing answers, the copy an earlier load made
    // is used, verified again; a server that answers with an error is not
    // "offline". https needs Http's TLS layer (HttpTls.xc).
    static Plugin* _loadUrl(String* url, String* pin, PluginConsent_t* consent)
        {
#if ARCH_wasm32
        return (Plugin*)0;
#else
        String* base = String.withString(url);
        while (base.byteLength() > (u32)1 && base.byteAt(base.byteLength() - (u32)1) == (u8)'/')
            base = base.substringBytes((u32)0, base.byteLength() - (u32)1);
        String* root = Plugin._store();
        Files.createDirectory(root);
        String* urls = BundleSign._join(root, String.withCString("urls"));
        Files.createDirectory(urls);
        String* mapFile = BundleSign._join(urls, Sha256.hex(base.cString(), base.byteLength()));
        String* plat = Plugin._platform();
        HttpResponse* mr = Http.get(Url.withString(String.withFormat("%s/bundle.json", base.cString())));
        if (mr.status() == (u32)0)
            {
            // Nothing answered: the copy, if an earlier load made one.
            String* dn = Files.readText(mapFile);
            if (dn == (String*)0)
                return Plugin._fail(String.withFormat("%s cannot be reached (%s), and there is no copy of it here",
                                                      base.cString(), mr.error() != (String*)0 ? mr.error().cString() : "no answer"));
            String* dir = BundleSign._join(root, dn);
            String* err = BundleSign.verifyPartial(dir, plat);
            if (err != (String*)0)
                return Plugin._fail(String.withFormat("the copy of %s: %s", base.cString(), err.cString()));
            Data* cmb = Files.readData(BundleSign._join(dir, String.withCString("bundle.json")));
            if (pin != (String*)0 && !Sha256.hex(cmb.bytes(), cmb.length()).equals(pin))
                return Plugin._fail(String.withFormat("%s: not the bundle the link names (its sha256 differs)", base.cString()));
            Map* cm = (Map*)0;
            try
                {
                cm = (Map*)BundleRules.parseManifest(cmb);
                }
            catch (JSONError e)
                {
                return Plugin._fail(e.message());
                }
            return Plugin._loadCopy(cm, dir, consent, pin != (String*)0, String.withCString(""), true, false, false);
            }
        if (mr.status() != (u32)200)
            return Plugin._fail(String.withFormat("%s/bundle.json: HTTP %u", base.cString(), mr.status()));
        HttpResponse* sr = Http.get(Url.withString(String.withFormat("%s/bundle.sig", base.cString())));
        if (sr.status() != (u32)200)
            return Plugin._fail(String.withFormat("%s/bundle.sig: HTTP %u", base.cString(), sr.status()));
        Data* mb = mr.body();
        if (pin != (String*)0 && !Sha256.hex(mb.bytes(), mb.length()).equals(pin))
            return Plugin._fail(String.withFormat("%s: not the bundle the link names (its sha256 differs)", base.cString()));
        String* err = BundleSign.verifyManifest(mb, sr.bodyString());
        if (err != (String*)0)
            return Plugin._fail(String.withFormat("%s: %s", base.cString(), err.cString()));
        Map* m = (Map*)0;
        try
            {
            m = (Map*)BundleRules.parseManifest(mb);
            }
        catch (JSONError e)
            {
            return Plugin._fail(e.message());
            }
        String* name = (String*)m.get((Hashable*)String.withCString("name"));
        String* version = (String*)m.get((Hashable*)String.withCString("version"));
        Map* pub = (Map*)m.get((Hashable*)String.withCString("publisher"));
        String* keyId = (String*)pub.get((Hashable*)String.withCString("keyId"));
        String* domain = (String*)pub.get((Hashable*)String.withCString("domain"));
        // The publisher's domain vouches for its key (§2a, defence 3) only
        // when it is the host the bundle comes from.
        bool reached = false;
        bool vouched = false;
        String* origin = Plugin._origin(base);
        if (domain != (String*)0 && domain.byteLength() > (u32)0 && origin != (String*)0
            && Plugin._hostOf(origin).lowercased().equals(domain.lowercased()))
            {
            HttpResponse* vr = Http.get(Url.withString(String.withFormat("%s/.well-known/xc-bundle-keys", origin.cString())));
            if (vr.status() == (u32)200)
                {
                Map* v = (Map*)0;
                try
                    {
                    v = (Map* ?)JSON.parseStrict(vr.body(), (u32)65536, (u32)4, (u32)256);
                    }
                catch (JSONError e)
                    {
                    v = (Map*)0;
                    }
                if (v != (Map*)0)
                    {
                    reached = true;
                    vouched = Plugin._inList(v, "keys", keyId);
                    if (Plugin._inList(v, "revoked", keyId))
                        return Plugin._fail(String.withFormat("%s: %s has revoked the key it was signed with (%s)", name.cString(),
                                                              domain.cString(), keyId.substringBytes((u32)0, (u32)16).cString()));
                    }
                }
            }
        // This platform's code and the resources, into a side directory.
        String* dn = String.withFormat("%s-%s-%s", keyId.substringBytes((u32)0, (u32)16).cString(), name.cString(),
                                       version.cString());
        String* dir = BundleSign._join(root, dn);
        String* part = String.withString(dir);
        part.appendCString(".part");
        Directory.remove(part);
        Files.createDirectory(part);
        if (!Files.writeData(BundleSign._join(part, String.withCString("bundle.json")), mb)
            || !Files.writeText(BundleSign._join(part, String.withCString("bundle.sig")), sr.bodyString()))
            return Plugin._fail(String.withFormat("cannot write the copy of %s", name.cString()));
        Map* files = (Map*)m.get((Hashable*)String.withCString("files"));
        Array* listed = files.allKeys();
        BundleSign._sort(listed);
        String* mine = String.withFormat("Exec/%s/", plat.cString());
        u64 total = (u64)0;
        for (u32 i = (u32)0; i < listed.count(); i = i + (u32)1)
            {
            String* f = (String*)listed.get(i);
            if (!f.hasPrefix(String.withCString("Resources/")) && !f.hasPrefix(mine))
                continue;
            HttpResponse* fr = Http.get(Url.withString(String.withFormat("%s/%s", base.cString(), f.cString())));
            if (fr.status() != (u32)200)
                return Plugin._fail(String.withFormat("%s/%s: HTTP %u", base.cString(), f.cString(), fr.status()));
            Data* b = fr.body();
            total = total + (u64)b.length();
            if (b.length() > Plugin._maxFile() || total > Plugin._maxTotal())
                return Plugin._fail(String.withFormat("%s: %s is larger than a plugin may make this program download",
                                                      name.cString(), f.cString()));
            if (!Sha256.hex(b.bytes(), b.length()).equals((String*)files.get((Hashable*)f)))
                return Plugin._fail(String.withFormat("%s: '%s' has changed since it was signed", base.cString(), f.cString()));
            String* to = BundleSign._join(part, f);
            u32 slash = to.byteLength();
            while (slash > (u32)0 && to.byteAt(slash - (u32)1) != (u8)'/')
                slash = slash - (u32)1;
            BundleSign._mkdirs(to.substringBytes((u32)0, slash - (u32)1));
            if (!Files.writeData(to, b))
                return Plugin._fail(String.withFormat("cannot write %s into the copy of %s", f.cString(), name.cString()));
            }
        err = BundleSign.verifyPartial(part, plat);
        if (err != (String*)0)
            return Plugin._fail(String.withFormat("the copy of %s: %s", base.cString(), err.cString()));
        Directory.remove(dir);
        if (!Directory.move(part, dir))
            return Plugin._fail(String.withFormat("cannot put the copy of %s in place", name.cString()));
        Files.writeText(mapFile, dn);
        return Plugin._loadCopy(m, dir, consent, pin != (String*)0, vouched ? domain : String.withCString(""), true,
                                reached, vouched);
#endif
        }

    // Everything after the bundle is in the private store and verified there
    // (from a directory, or fetched from a URL): trust, the platform's code,
    // what it requires, its export table, its shipped libraries, then the
    // load and the tables bound into it. verified: the domain that vouched
    // for the key ("" if none); domainChecked: whether the domain could be
    // asked at all (a URL bundle), so a rotation needs its word.
    static Plugin* _loadCopy(Map* m, String* dir, PluginConsent_t* consent, bool pinned, String* verified,
                             bool domainChecked, bool reached, bool vouched)
        {
#if ARCH_wasm32
        return (Plugin*)0;
#else
        String* name = (String*)m.get((Hashable*)String.withCString("name"));
        String* version = (String*)m.get((Hashable*)String.withCString("version"));
        Map* pub = (Map*)m.get((Hashable*)String.withCString("publisher"));
        String* keyId = (String*)pub.get((Hashable*)String.withCString("keyId"));
        String* domain = (String*)pub.get((Hashable*)String.withCString("domain"));
        Map* files = (Map*)m.get((Hashable*)String.withCString("files"));
        String* rotated = (String*)0;
        String* err = (String*)0;
        String* highest = (String*)0;
        err = Plugin._decidePinned(m, consent, &highest, pinned, &rotated, verified);
        if (err == (String*)0 && rotated != (String*)0 && domainChecked && domain != (String*)0
            && domain.byteLength() > (u32)0 && !vouched)
            err = String.withFormat("%s: a new key (%s) for it counts only once %s vouches for it%s", name.cString(),
                                    keyId.substringBytes((u32)0, (u32)16).cString(), domain.cString(),
                                    reached ? "" : ", and it could not be reached");
        if (err != (String*)0)
            return Plugin._fail(err);
        String* code = Plugin._codeFor(m, &err);
        if (code == (String*)0)
            return Plugin._fail(err);
        err = Plugin._checkRequires(m);
        if (err != (String*)0)
            return Plugin._fail(err);
        // The code, from the copy.
        String* lib = BundleSign._join(dir, code);
        err = Plugin._checkExports(m, Files.readData(lib));
        if (err != (String*)0)
            return Plugin._fail(err);
        // The libraries shipped beside the code, from the copy and in order,
        // so the system finds them loaded rather than looking elsewhere.
        Array* fk = files.allKeys();
        BundleSign._sort(fk);
        String* execDir = String.withFormat("Exec/%s/", Plugin._platform().cString());
        for (u32 i = (u32)0; i < fk.count(); i = i + (u32)1)
            {
            String* f = (String*)fk.get(i);
            if (!f.hasPrefix(execDir) || f.equals(code))
                continue;
            String* full = BundleSign._join(dir, f);
#if OS_windows
            if (LoadLibraryExA(full.cString(), (pointer)0, (u32)0x00000900) == (pointer)0)
                return Plugin._fail(String.withFormat("%s: the system would not load %s", name.cString(), f.cString()));
#elif ARCH_arm64 || ARCH_x86_64
            if (dlopen(full.cString(), (i32)2) == (pointer)0)
                {
                u8* why = dlerror();
                return Plugin._fail(String.withFormat("%s: %s: %s", name.cString(), f.cString(),
                                                      why != (u8*)0 ? why : "the system would not load it"));
                }
#endif
            }
        Plugin* p = new Plugin();
        p._name = name;
        p._dir = dir;
        p._adopt(m);
#if OS_windows
        // LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32
        p._handle = LoadLibraryExA(lib.cString(), (pointer)0, (u32)0x00000900);
        if (p._handle == (pointer)0)
            return Plugin._fail(String.withFormat("%s: the system would not load %s", name.cString(), code.cString()));
#elif ARCH_arm64 || ARCH_x86_64
        p._handle = dlopen(lib.cString(), (i32)2);
        if (p._handle == (pointer)0)
            {
            u8* why = dlerror();
            return Plugin._fail(String.withFormat("%s: %s", name.cString(), why != (u8*)0 ? why : "the system would not load it"));
            }
#else
        return Plugin._fail(String.withCString("plugins are not loaded on this target yet"));
#endif
        if (highest == (String*)0 || Plugin._cmpVersion(version, highest) > (i32)0 || rotated != (String*)0)
            Plugin._record(keyId, name, Plugin._cmpVersion(version, highest == (String*)0 ? version : highest) >= (i32)0
                                        ? version : highest);
        if (rotated != (String*)0)
            Plugin._forget(rotated, name);
        // Each required protocol's table, bound into it.
        Map* req = (Map*)m.get((Hashable*)String.withCString("requires"));
        Array* rk = req == (Map*)0 ? new Array() : req.allKeys();
        for (u32 i = (u32)0; i < rk.count(); i = i + (u32)1)
            {
            String* proto = (String*)rk.get(i);
            String* sym = String.withFormat("_XtP_%s$bind", proto.cString());
            PluginBind_t* bind = (PluginBind_t*)p.symbol(sym);
            if (bind == (PluginBind_t*)0)
                return Plugin._fail(String.withFormat("%s declares it requires %s but has no %s", name.cString(),
                                                      proto.cString(), sym.cString()));
            bind(((PluginProvided*)_provided.get((Hashable*)proto)).table);
            }
        return p;
#endif
        }

    // What the manifest says the code provides and requires, against the
    // code's own export table, read before it is loaded (loading runs its
    // constructors): 0, or the first thing missing.
    static String* _checkExports(Map* m, Data* code)
        {
        String* name = (String*)m.get((Hashable*)String.withCString("name"));
        Array* ex = Exports.of(code);
        if (ex == (Array*)0)
            return String.withFormat("%s: its code is not a library this platform loads", name.cString());
        Map* have = new Map();
        for (u32 i = (u32)0; i < ex.count(); i = i + (u32)1)
            have.set((Hashable*)ex.get(i), (Object*)ex.get(i));
        for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1)
            {
            Map* ps = (Map*)m.get((Hashable*)String.withCString(pass == (u32)0 ? "provides" : "requires"));
            Array* ks = ps == (Map*)0 ? new Array() : ps.allKeys();
            BundleSign._sort(ks);
            for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
                {
                String* sym = String.withFormat("_XtP_%s$%s", ((String*)ks.get(i)).cString(), pass == (u32)0 ? "table" : "bind");
                if (have.get((Hashable*)sym) == (Object*)0)
                    return String.withFormat("%s says it %s %s, but its code has no %s", name.cString(),
                                             pass == (u32)0 ? "provides" : "requires", ((String*)ks.get(i)).cString(),
                                             sym.cString());
                }
            }
        return (String*)0;
        }

    // The one call on every target: natively it loads at once and calls
    // done; on the web it fetches, checks and instantiates, then calls done.
    // done gets 0 on failure, and Plugin.lastError() says why.
    static void loadAsync(String* where, PluginConsent_t* consent, PluginDone_t* done)
        {
#if ARCH_wasm32
        _error = (String*)0;
        PluginPending* pp = new PluginPending();
        String* rest = (String*)0;
        pp.pin = Plugin._pinOf(where, &rest);
        pp.base = String.withString(rest);
        while (pp.base.byteLength() > (u32)1 && pp.base.byteAt(pp.base.byteLength() - (u32)1) == (u8)'/')
            pp.base = pp.base.substringBytes((u32)0, pp.base.byteLength() - (u32)1);
        pp.consent = consent;
        pp.done = done;
        Plugin._fetch(String.withFormat("%s/bundle.json", pp.base.cString()),
                      block void(u32 status, String* body) { Plugin._gotManifest(pp, status, body); });
#else
        done(Plugin.load(where, consent));
#endif
        }

    static void _fetch(String* url, block cb void(u32, String*))
        {
#if ARCH_wasm32
        PluginFetch* f = new PluginFetch();
        f.url = url;
        f.cb = cb;
        Url* u = Url.withString(url);
        u.fetch(block void(u32 status, String* body) { Plugin._fetched(f, status, body); });
#endif
        }

    static void _fetched(PluginFetch* f, u32 status, String* body)
        {
#if ARCH_wasm32
        // A server that answered (200, 404, 500, ...) is not "offline": the
        // copy stands in only when nothing answered. It is written only once
        // what it holds has been checked (_keep), so a bad answer never
        // replaces a good copy.
        if (status != (u32)0)
            {
            f.fire(status, body);
            return;
            }
        if (_fetches == (Map*)0)
            _fetches = new Map();
        _nextToken = _nextToken + (u32)1;
        _fetches.set((Hashable*)Number.with(_nextToken), (Object*)f);
        _xt_plugin_cache_get(_nextToken, f.url.cString(), f.url.byteLength());
#endif
        }

    static void _keep(String* url, String* body)
        {
#if ARCH_wasm32
        _xt_plugin_cache_put(url.cString(), url.byteLength(), body.cString(), body.byteLength());
#endif
        }

    // The offline copy's answer: its bytes, or none (p == 0).
    static void _cached(u32 token, u8* p, u32 n)
        {
        if (_fetches == (Map*)0)
            return;
        PluginFetch* f = (PluginFetch*)_fetches.get((Hashable*)Number.with(token));
        if (f == (PluginFetch*)0)
            return;
        _fetches.remove((Hashable*)Number.with(token));
        if (p == (u8*)0)
            {
            f.fire((u32)0, (String*)0);
            return;
            }
        f.fire((u32)200, String.withBytes(p, n));
        }

    // A file of the plugin's Resources/ (`icon.png`, `art/x.png`), checked
    // against the manifest: its bytes, or 0 when it is not there or not what
    // was signed. Natively from the verified copy, at once; on the web
    // fetched (or from the offline copy), then cb.
    void resource(String* name, block cb void(Data*))
        {
        String* path = String.withFormat("Resources/%s", name.cString());
        if (!BundleRules.validPath(path))
            {
            cb((Data*)0);
            return;
            }
#if ARCH_wasm32
        String* want = _files == (Map*)0 ? (String*)0 : (String*)_files.get((Hashable*)path);
        if (want == (String*)0)
            {
            cb((Data*)0);
            return;
            }
        String* url = String.withFormat("%s/%s", _dir.cString(), path.cString());
        Plugin._fetch(url, block void(u32 status, String* body) { Plugin._gotResource(url, want, cb, status, body); });
#else
        String* want = _files == (Map*)0 ? (String*)0 : (String*)_files.get((Hashable*)path);
        Data* d = want == (String*)0 ? (Data*)0 : Files.readData(BundleSign._join(_dir, path));
        if (d != (Data*)0 && !Sha256.hex(d.bytes(), d.length()).equals(want))
            d = (Data*)0;
        cb(d);
#endif
        }

    static void _gotResource(String* url, String* want, block cb void(Data*), u32 status, String* body)
        {
#if ARCH_wasm32
        if (status != (u32)200 || body == (String*)0 || !Sha256.hex(body.cString(), body.byteLength()).equals(want))
            {
            cb((Data*)0);
            return;
            }
        Plugin._keep(url, body);
        cb(Data.withBytes(body.cString(), body.byteLength()));
#endif
        }

    static void _webFail(PluginPending* pp, String* why)
        {
        _error = why;
        PluginDone_t* d = pp.done;
        d((Plugin*)0);
        }

    static void _gotManifest(PluginPending* pp, u32 status, String* body)
        {
#if ARCH_wasm32
        if (status != (u32)200 || body == (String*)0)
            {
            Plugin._webFail(pp, String.withFormat("%s/bundle.json: HTTP %u", pp.base.cString(), status));
            return;
            }
        pp.manifest = Data.withBytes(body.cString(), body.byteLength());
        Plugin._fetch(String.withFormat("%s/bundle.sig", pp.base.cString()),
                      block void(u32 status, String* body) { Plugin._gotSig(pp, status, body); });
#endif
        }

    static void _gotSig(PluginPending* pp, u32 status, String* body)
        {
#if ARCH_wasm32
        if (status != (u32)200 || body == (String*)0)
            {
            Plugin._webFail(pp, String.withFormat("%s/bundle.sig: HTTP %u", pp.base.cString(), status));
            return;
            }
        pp.sig = body;
        if (pp.pin != (String*)0 && !Sha256.hex(pp.manifest.bytes(), pp.manifest.length()).equals(pp.pin))
            {
            Plugin._webFail(pp, String.withFormat("%s: not the bundle the link names (its sha256 differs)", pp.base.cString()));
            return;
            }
        String* err = BundleSign.verifyManifest(pp.manifest, body);
        if (err != (String*)0)
            {
            Plugin._webFail(pp, String.withFormat("%s: %s", pp.base.cString(), err.cString()));
            return;
            }
        try
            {
            pp.m = (Map*)BundleRules.parseManifest(pp.manifest);
            }
        catch (JSONError e)
            {
            Plugin._webFail(pp, e.message());
            return;
            }
        pp.name = (String*)pp.m.get((Hashable*)String.withCString("name"));
        pp.version = (String*)pp.m.get((Hashable*)String.withCString("version"));
        Map* pub = (Map*)pp.m.get((Hashable*)String.withCString("publisher"));
        pp.keyId = (String*)pub.get((Hashable*)String.withCString("keyId"));
        pp.domain = (String*)pub.get((Hashable*)String.withCString("domain"));
        // The publisher's domain vouches for its key (§2a, defence 3) only
        // when it is the host the bundle came from; its list is at that
        // origin's /.well-known/xc-bundle-keys.
        String* origin = Plugin._origin(pp.base);
        if (pp.domain != (String*)0 && pp.domain.byteLength() > (u32)0 && origin != (String*)0
            && Plugin._hostOf(origin).lowercased().equals(pp.domain.lowercased()))
            {
            Url* u = Url.withString(String.withFormat("%s/.well-known/xc-bundle-keys", origin.cString()));
            u.fetch(block void(u32 status, String* body) { Plugin._gotVouch(pp, status, body); });
            return;
            }
        Plugin._decideWeb(pp);
#endif
        }

    // "scheme://authority" of a URL, or 0.
    static String* _origin(String* url)
        {
        u32 c = url.indexOfByte((u8)':');
        if (c == String.notFound() || c + (u32)3 > url.byteLength() || url.byteAt(c + (u32)1) != (u8)'/'
            || url.byteAt(c + (u32)2) != (u8)'/')
            return (String*)0;
        u32 e = c + (u32)3;
        while (e < url.byteLength() && url.byteAt(e) != (u8)'/' && url.byteAt(e) != (u8)'?' && url.byteAt(e) != (u8)'#')
            e = e + (u32)1;
        return url.substringBytes((u32)0, e);
        }

    // The host of an origin: no scheme, user or port.
    static String* _hostOf(String* origin)
        {
        u32 s = origin.indexOfByte((u8)':') + (u32)3;
        String* a = origin.substringFromByte(s);
        u32 at = a.indexOfByte((u8)'@');
        if (at != String.notFound())
            a = a.substringFromByte(at + (u32)1);
        u32 colon = a.indexOfByte((u8)':');
        if (colon != String.notFound() && a.byteAt((u32)0) != (u8)'[')
            a = a.substringBytes((u32)0, colon);
        return a;
        }

    static bool _inList(Map* m, u8* key, String* id)
        {
        Array* a = m == (Map*)0 ? (Array*)0 : (Array* ?)m.get((Hashable*)String.withCString(key));
        for (u32 i = (u32)0; a != (Array*)0 && i < a.count(); i = i + (u32)1)
            {
            String* s = (String* ?)a.get(i);
            if (s != (String*)0 && s.lowercased().equals(id))
                return true;
            }
        return false;
        }

    static void _gotVouch(PluginPending* pp, u32 status, String* body)
        {
#if ARCH_wasm32
        if (status == (u32)200 && body != (String*)0)
            {
            Map* v = (Map*)0;
            try
                {
                v = (Map* ?)JSON.parseStrict(Data.withBytes(body.cString(), body.byteLength()), (u32)65536, (u32)4, (u32)256);
                }
            catch (JSONError e)
                {
                v = (Map*)0;
                }
            if (v != (Map*)0)
                {
                pp.reached = true;
                pp.vouched = Plugin._inList(v, "keys", pp.keyId);
                pp.revoked = Plugin._inList(v, "revoked", pp.keyId);
                }
            }
        Plugin._decideWeb(pp);
#endif
        }

    static void _decideWeb(PluginPending* pp)
        {
#if ARCH_wasm32
        if (pp.revoked)
            {
            Plugin._webFail(pp, String.withFormat("%s: %s has revoked the key it was signed with (%s)", pp.name.cString(),
                                                  pp.domain.cString(), pp.keyId.substringBytes((u32)0, (u32)16).cString()));
            return;
            }
        String* err = (String*)0;
        String* h = (String*)0;
        String* rot = (String*)0;
        err = Plugin._decidePinned(pp.m, pp.consent, &h, pp.pin != (String*)0, &rot,
                                   pp.vouched ? pp.domain : String.withCString(""));
        pp.highest = h;
        pp.rotated = rot;
        // A rotation counts only if the domain vouches for the new key, so a
        // leaked old key cannot hand the plugin to someone else.
        if (err == (String*)0 && rot != (String*)0 && pp.domain != (String*)0 && pp.domain.byteLength() > (u32)0
            && !pp.vouched)
            err = String.withFormat("%s: a new key (%s) for it counts only once %s vouches for it%s", pp.name.cString(),
                                    pp.keyId.substringBytes((u32)0, (u32)16).cString(), pp.domain.cString(),
                                    pp.reached ? "" : ", and it could not be reached");
        if (err == (String*)0)
            pp.code = Plugin._codeFor(pp.m, &err);
        if (err == (String*)0)
            err = Plugin._checkRequires(pp.m);
        if (err != (String*)0)
            {
            Plugin._webFail(pp, err);
            return;
            }
        Plugin._fetch(String.withFormat("%s/%s", pp.base.cString(), pp.code.cString()),
                      block void(u32 status, String* body) { Plugin._gotCode(pp, status, body); });
#endif
        }

    static void _gotCode(PluginPending* pp, u32 status, String* body)
        {
#if ARCH_wasm32
        if (status != (u32)200 || body == (String*)0)
            {
            Plugin._webFail(pp, String.withFormat("%s/%s: HTTP %u", pp.base.cString(), pp.code.cString(), status));
            return;
            }
        Map* files = (Map*)pp.m.get((Hashable*)String.withCString("files"));
        String* h = Sha256.hex(body.cString(), body.byteLength());
        if (!h.equals((String*)files.get((Hashable*)pp.code)))
            {
            Plugin._webFail(pp, String.withFormat("%s: '%s' has changed since it was signed", pp.base.cString(), pp.code.cString()));
            return;
            }
        if (_pending == (Map*)0)
            _pending = new Map();
        _nextToken = _nextToken + (u32)1;
        _pending.set((Hashable*)Number.with(_nextToken), (Object*)pp);
        pp.codeBytes = body;
        // Exactly these bytes, the ones just hashed, are what the loader compiles.
        _xt_plugin_instantiate(_nextToken, body.cString(), body.byteLength());
#endif
        }

    // The loader's answer: a handle, or 0 and why not.
    static void _ready(u32 token, u32 handle, u8* why, u32 n)
        {
        if (_pending == (Map*)0)
            return;
        PluginPending* pp = (PluginPending*)_pending.get((Hashable*)Number.with(token));
        if (pp == (PluginPending*)0)
            return;
        _pending.remove((Hashable*)Number.with(token));
        if (handle == (u32)0)
            {
            Plugin._webFail(pp, String.withFormat("%s: %s", pp.name.cString(), String.withBytes(why, n).cString()));
            return;
            }
        if (pp.highest == (String*)0 || Plugin._cmpVersion(pp.version, pp.highest) > (i32)0 || pp.rotated != (String*)0)
            Plugin._record(pp.keyId, pp.name,
                           Plugin._cmpVersion(pp.version, pp.highest == (String*)0 ? pp.version : pp.highest) >= (i32)0
                           ? pp.version : pp.highest);
        if (pp.rotated != (String*)0)
            Plugin._forget(pp.rotated, pp.name);
        Plugin._keep(String.withFormat("%s/bundle.json", pp.base.cString()),
                     String.withBytes(pp.manifest.bytes(), pp.manifest.length()));
        Plugin._keep(String.withFormat("%s/bundle.sig", pp.base.cString()), pp.sig);
        Plugin._keep(String.withFormat("%s/%s", pp.base.cString(), pp.code.cString()), pp.codeBytes);
        pp.codeBytes = (String*)0;
        Plugin* p = new Plugin();
        p._name = pp.name;
        p._dir = pp.base;
        p._web = handle;
        p._adopt(pp.m);
        PluginDone_t* d = pp.done;
        d(p);
        }

    // What proto.bind() takes to call a protocol this plugin provides; 0 when
    // it provides none by that name.
    pointer table(String* proto)
        {
#if ARCH_wasm32
        return (pointer)_web;
#else
        PluginTable_t* t = (PluginTable_t*)self.symbol(String.withFormat("_XtP_%s$table", proto.cString()));
        if (t == (PluginTable_t*)0)
            return (pointer)0;
        return t();
#endif
        }

    void _adopt(Map* m)
        {
        _files = (Map*)m.get((Hashable*)String.withCString("files"));
        _keyId = (String*)((Map*)m.get((Hashable*)String.withCString("publisher"))).get((Hashable*)String.withCString("keyId"));
        Map* props = (Map*)m.get((Hashable*)String.withCString("properties"));
        _readonly = props == (Map*)0 ? (Map*)0 : (Map*)props.get((Hashable*)String.withCString("readonly"));
        _writeable = props == (Map*)0 ? (Map*)0 : (Map*)props.get((Hashable*)String.withCString("writeable"));
        }

    // ── Developer properties (bundles-and-plugins.md, "Developer key/value
    // pairs"): the manifest's, signed with it, and a user's overrides of the
    // writeable ones, kept in the app's Settings under
    // bundle.<publisher keyId>.<name>.<key>, beside the default each replaced.

    // Where overrides are kept: the app's Settings. Without this they last
    // for the run only.
    static void useSettings(Settings* s)
        {
        _settings = s;
        }

    static Settings* _overrides(void)
        {
        if (_settings == (Settings*)0)
            _settings = Settings.memory();
        return _settings;
        }

    // The notification setValue and resetValue post, with the plugin as the
    // sender and {"key": key} as its userInfo.
    static String* valueChanged(void)
        {
        return String.withCString("PluginValueChanged");
        }

    String* _skey(String* key)
        {
        return String.withFormat("bundle.%s.%s.%s", _keyId.cString(), _name.cString(), key.cString());
        }

    String* _defaultKey(String* key)
        {
        String* k = self._skey(key);
        k.appendCString(".default");
        return k;
        }

    bool _isReadonly(String* key)
        {
        return _readonly != (Map*)0 && _readonly.get((Hashable*)key) != (Object*)0;
        }

    // The manifest's value for key, or 0; never a user's override.
    String* info(String* key)
        {
        if (self._isReadonly(key))
            return (String*)_readonly.get((Hashable*)key);
        return _writeable == (Map*)0 ? (String*)0 : (String*)_writeable.get((Hashable*)key);
        }

    // The manifest's keys, both sections, sorted: for a settings UI.
    Array* infoKeys(void)
        {
        Array* r = new Array();
        if (_readonly != (Map*)0)
            r.addAll(_readonly.allKeys());
        if (_writeable != (Map*)0)
            r.addAll(_writeable.allKeys());
        BundleSign._sort(r);
        return r;
        }

    // Whether setValue may change key: every key but a readonly one.
    bool isWriteable(String* key)
        {
        return !self._isReadonly(key);
        }

    // What the plugin should use: a readonly key's manifest value; else the
    // user's override if there is one; else the manifest's default (or 0).
    String* value(String* key)
        {
        if (self._isReadonly(key) || !BundleRules.validName(key))
            return self.info(key);
        Settings* s = Plugin._overrides();
        if (s.has(self._skey(key)))
            return s.get(self._skey(key));
        return self.info(key);
        }

    // A user's value for key (one the manifest does not have is allowed:
    // state the plugin keeps). Refused, with a logged reason, for a readonly
    // key, a key outside the name grammar, or a value that is not one line
    // of at most 1024 bytes.
    bool setValue(String* key, String* v)
        {
        if (!BundleRules.validName(key))
            {
            Log.warning(String.withFormat("%s: '%s' is not a property name", _name.cString(), key.cString()));
            return false;
            }
        if (self._isReadonly(key))
            {
            Log.warning(String.withFormat("%s: '%s' is the publisher's and cannot be changed", _name.cString(), key.cString()));
            return false;
            }
        if (!BundleRules.validValue(v))
            {
            Log.warning(String.withFormat("%s: a value for '%s' is text of at most 1024 bytes on one line", _name.cString(),
                                          key.cString()));
            return false;
            }
        Settings* s = Plugin._overrides();
        s.set(self._skey(key), v);
        String* d = self.info(key);
        if (d != (String*)0)
            s.set(self._defaultKey(key), d);
        else
            s.remove(self._defaultKey(key));
        s.save();
        self._posted(key);
        return true;
        }

    // Drop the user's value: value(key) reads the manifest again.
    void resetValue(String* key)
        {
        if (!BundleRules.validName(key))
            return;
        Settings* s = Plugin._overrides();
        s.remove(self._skey(key));
        s.remove(self._defaultKey(key));
        s.save();
        self._posted(key);
        }

    // Whether a user's value is what value(key) gives.
    bool isOverridden(String* key)
        {
        return BundleRules.validName(key) && !self._isReadonly(key) && Plugin._overrides().has(self._skey(key));
        }

    // Whether the publisher's default has changed since the user's value
    // replaced it ("the publisher now suggests ...").
    bool defaultChanged(String* key)
        {
        if (!self.isOverridden(key))
            return false;
        Settings* s = Plugin._overrides();
        String* now = self.info(key);
        if (!s.has(self._defaultKey(key)))
            return now != (String*)0;
        return now == (String*)0 || !now.equals(s.get(self._defaultKey(key)));
        }

    void _posted(String* key)
        {
        Map* info = new Map();
        info.set((Hashable*)String.withCString("key"), (Object*)key);
        NotificationCenter.shared().post(Plugin.valueChanged(), (Object*)self, info);
        }

    // A symbol of the plugin's code, or 0.
    pointer symbol(String* nm)
        {
#if OS_windows
        return GetProcAddress(_handle, nm.cString());
#elif ARCH_arm64 || ARCH_x86_64
        return dlsym(_handle, nm.cString());
#else
        return (pointer)0;
#endif
        }
    }

#if ARCH_wasm32
// The loader's way back in.
extern void _xt_plugin_ready(u32 token, u32 handle, u8* why, u32 n)
    {
    Plugin._ready(token, handle, why, n);
    if (why != (u8*)0)
        delete why;
    }

extern void _xt_plugin_cached(u32 token, u8* p, u32 n)
    {
    Plugin._cached(token, p, n);
    if (p != (u8*)0)
        delete p;
    }

#endif
