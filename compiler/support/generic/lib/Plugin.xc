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
#import "Foundation.xc"
#import "Files.xc"
#import "PlatformCore.xc"
#import "BundleSign.xc"

typedef bool PluginConsent_t(String* name, String* publisher, String* domain, String* keyId);
typedef void PluginBind_t(pointer table);

#if ARCH_win64
pointer LoadLibraryExA(u8* path, pointer file, u32 flags);
pointer GetProcAddress(pointer module, u8* name);
#elif ARCH_arm64 || ARCH_x86_64 || PLATFORM_android
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

class Plugin : Object
    {
    String* _name;
    String* _dir;
    pointer _handle;

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
#if ARCH_win64
        return String.withCString("windows-x86_64");
#elif PLATFORM_android
        return String.withCString("android-arm64");
#elif ARCH_x86_64
        return String.withCString("linux-x86_64");
#elif ARCH_wasm32
        return String.withCString("wasm32");
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

    static String* _trusted(String* keyId, String* name)
        {
        String* t = Files.readText(Plugin._trustFile());
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
        String* t = Files.readText(Plugin._trustFile());
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
        Files.writeText(Plugin._trustFile(), out);
        }

    static Plugin* load(String* path, PluginConsent_t* consent)
        {
        _error = (String*)0;
        String* err = BundleSign.verify(path);
        if (err != (String*)0)
            return Plugin._fail(String.withFormat("%s: %s", path.cString(), err.cString()));
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
        // Trust.
        String* highest = Plugin._trusted(keyId, name);
        if (highest != (String*)0)
            {
            if (Plugin._cmpVersion(version, highest) < (i32)0)
                return Plugin._fail(String.withFormat("%s %s is older than %s, which was loaded before", name.cString(),
                                                      version.cString(), highest.cString()));
            }
        else
            {
            if (consent == (PluginConsent_t*)0)
                return Plugin._fail(String.withFormat("%s is not trusted yet, and nothing was asked (no consent callback)",
                                                      name.cString()));
            if (!consent(name, (String*)pub.get((Hashable*)String.withCString("name")),
                         (String*)pub.get((Hashable*)String.withCString("domain")), keyId))
                return Plugin._fail(String.withFormat("%s was not trusted", name.cString()));
            }
        // The platform's code.
        String* plat = Plugin._platform();
        String* prefix = String.withFormat("Exec/%s/%s.", plat.cString(), name.cString());
        String* code = (String*)0;
        for (u32 i = (u32)0; i < paths.count(); i = i + (u32)1)
            if (((String*)paths.get(i)).hasPrefix(prefix))
                code = (String*)paths.get(i);
        if (code == (String*)0)
            {
            Array* ps = (Array*)m.get((Hashable*)String.withCString("platforms"));
            String* has = new String();
            for (u32 i = (u32)0; ps != (Array*)0 && i < ps.count(); i = i + (u32)1)
                {
                if (i > (u32)0) has.appendCString(", ");
                has.append((String*)ps.get(i));
                }
            return Plugin._fail(String.withFormat("%s %s has no build for %s; it has %s", name.cString(), version.cString(),
                                                  plat.cString(), has.cString()));
            }
        // What it requires, against what this program provides.
        Map* req = (Map*)m.get((Hashable*)String.withCString("requires"));
        Array* rk = req == (Map*)0 ? new Array() : req.allKeys();
        for (u32 i = (u32)0; i < rk.count(); i = i + (u32)1)
            {
            String* proto = (String*)rk.get(i);
            String* rv = (String*)req.get((Hashable*)proto);
            PluginProvided* pp = _provided == (Map*)0 ? (PluginProvided*)0 : (PluginProvided*)_provided.get((Hashable*)proto);
            if (pp == (PluginProvided*)0)
                return Plugin._fail(String.withFormat("%s needs %s %s, which this program does not provide", name.cString(),
                                                      proto.cString(), rv.cString()));
            u32 dot = rv.indexOfByte((u8)'.');
            u32 maj = (u32)BundleSign._num(dot == String.notFound() ? rv : rv.substringBytes((u32)0, dot));
            u32 min = dot == String.notFound() ? (u32)0 : (u32)BundleSign._num(rv.substringFromByte(dot + (u32)1));
            if (maj != pp.major || min > pp.minor)
                return Plugin._fail(String.withFormat("%s needs %s %s; this program provides %u.%u", name.cString(),
                                                      proto.cString(), rv.cString(), pp.major, pp.minor));
            }
        // The code, from the copy.
        String* lib = BundleSign._join(dir, code);
        Plugin* p = new Plugin();
        p._name = name;
        p._dir = dir;
#if ARCH_win64
        // LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32
        p._handle = LoadLibraryExA(lib.cString(), (pointer)0, (u32)0x00000900);
        if (p._handle == (pointer)0)
            return Plugin._fail(String.withFormat("%s: the system would not load %s", name.cString(), code.cString()));
#elif ARCH_arm64 || ARCH_x86_64 || PLATFORM_android
        p._handle = dlopen(lib.cString(), (i32)2);
        if (p._handle == (pointer)0)
            {
            u8* why = dlerror();
            return Plugin._fail(String.withFormat("%s: %s", name.cString(), why != (u8*)0 ? why : "the system would not load it"));
            }
#else
        return Plugin._fail(String.withCString("plugins are not loaded on this target yet"));
#endif
        if (highest == (String*)0 || Plugin._cmpVersion(version, highest) > (i32)0)
            Plugin._record(keyId, name, version);
        // Each required protocol's table, bound into it.
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
        }

    // A symbol of the plugin's code, or 0.
    pointer symbol(String* nm)
        {
#if ARCH_win64
        return GetProcAddress(_handle, nm.cString());
#elif ARCH_arm64 || ARCH_x86_64 || PLATFORM_android
        return dlsym(_handle, nm.cString());
#else
        return (pointer)0;
#endif
        }
    }
