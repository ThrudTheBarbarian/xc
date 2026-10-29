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

// BundleSign.xc — making and checking a signed bundle (bundles-and-plugins.md
// §2, §2a, §4 steps 1-3; review 1-5, 12):
//
//     String* err = BundleSign.make(dir, name, version, platform, codeFile,
//                                   resourcesDir, seed, publisher, domain,
//                                   provides, requires);
//     String* err = BundleSign.verify(dir);          // 0: every check passed
//
// A bundle is `bundle.json` (its manifest), `bundle.sig` (the Ed25519
// signature over the manifest's exact bytes, in hex), `Exec/<os>-<arch>/`
// with the code and `Resources/`. The manifest lists EVERY file with its
// SHA-256 and carries the publisher's public key; verify() refuses a bad
// signature, a manifest the strict parser refuses, a path outside the
// grammar, two paths that are one file on a case-insensitive disk, a link or
// special file, a file the manifest does not list, and a listed file that is
// missing or changed. make() keeps the other platforms' code (and the
// version and publisher, when not given: 0) when the manifest there was
// signed by the same key, so each target is one run.
//
//     Data* seed = BundleSign.publisherKey(path);   // made on first use, 0600
#import "Foundation.xc"
#import "Files.xc"
#import "Directory.xc"
#import "Sha256.xc"
#import "Ed25519.xc"
#import "SecureRandom.xc"
#import "BundleRules.xc"

#if ARCH_arm64 || ARCH_x86_64 || OS_android
i32 chmod(u8* path, u32 mode);
#endif

class BundleSign
    {
    static String* _hex(u8* p, u32 n)
        {
        String* s = new String();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            s.appendFormat("%02x", (u32)p[i]);
        return s;
        }

    // Hex to bytes; 0 when the text is not exactly n bytes of hex.
    static Data* _unhex(String* s, u32 n)
        {
        if (s == (String*)0 || s.byteLength() != n * (u32)2)
            return (Data*)0;
        Data* d = Data.withLength(n);
        u8* o = d.bytes();
        for (u32 i = (u32)0; i < n * (u32)2; i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            u32 v = c >= (u8)'0' && c <= (u8)'9' ? (u32)(c - (u8)'0')
                  : c >= (u8)'a' && c <= (u8)'f' ? (u32)(c - (u8)'a') + (u32)10 : (u32)99;
            if (v == (u32)99)
                return (Data*)0;
            o[i / (u32)2] = (u8)(o[i / (u32)2] * (u8)16 + (u8)v);
            }
        return d;
        }

    static u64 _num(String* s)
        {
        u64 v = (u64)0;
        for (u32 i = (u32)0; i < s.byteLength() && s.byteAt(i) >= (u8)'0' && s.byteAt(i) <= (u8)'9'; i = i + (u32)1)
            v = v * (u64)10 + (u64)(s.byteAt(i) - (u8)'0');
        return v;
        }

    static String* _join(String* a, String* b)
        {
        String* s = String.withString(a);
        s.appendByte((u8)'/');
        s.append(b);
        return s;
        }

    static String* _quoted(String* v)
        {
        String* s = String.withCString("\"");
        for (u32 i = (u32)0; i < v.byteLength(); i = i + (u32)1)
            {
            u8 c = v.byteAt(i);
            if (c == (u8)'"' || c == (u8)'\\')
                s.appendByte((u8)'\\');
            s.appendByte(c);
            }
        s.appendByte((u8)'"');
        return s;
        }

    static void _sort(Array* a)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            for (u32 j = i; j > (u32)0 && ((String*)a.get(j)).compare((String*)a.get(j - (u32)1)) < (i32)0; j = j - (u32)1)
                {
                Object* t = a.get(j);
                a.set(j, a.get(j - (u32)1));
                a.set(j - (u32)1, t);
                }
        }

    // A {"k": "v", ...} object, keys sorted, from a Map of String to String.
    static String* _object(Map* m)
        {
        String* s = String.withCString("{");
        if (m != (Map*)0)
            {
            Array* ks = m.allKeys();
            BundleSign._sort(ks);
            for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
                {
                String* k = (String*)ks.get(i);
                if (i > (u32)0)
                    s.appendCString(", ");
                s.append(BundleSign._quoted(k));
                s.appendCString(": ");
                s.append(BundleSign._quoted((String*)m.get((Hashable*)k)));
                }
            }
        s.appendCString("}");
        return s;
        }

    // Every file under dir/rel (rel "" for the root), as relative paths;
    // false when a link or special file is met (its path in *bad).
    static bool _walk(String* dir, String* rel, Array* out, String** bad)
        {
        String* here = rel.byteLength() == (u32)0 ? dir : BundleSign._join(dir, rel);
        Array* es = Directory.list(here);
        if (es == (Array*)0)
            return true;
        for (u32 i = (u32)0; i < es.count(); i = i + (u32)1)
            {
            DirEntry* e = (DirEntry*)es.get(i);
            String* p = rel.byteLength() == (u32)0 ? String.withString(e.name) : BundleSign._join(rel, e.name);
            if (e.kind == (u8)DIR_DIRECTORY)
                {
                if (!BundleSign._walk(dir, p, out, bad))
                    return false;
                }
            else if (e.kind == (u8)DIR_FILE)
                out.add((Object*)p);
            else
                {
                *bad = p;
                return false;
                }
            }
        return true;
        }

    static String* _sha(String* path)
        {
        Data* d = Files.readData(path);
        if (d == (Data*)0)
            return (String*)0;
        return Sha256.hex(d.bytes(), d.length());
        }

    // The publisher's 32-byte private seed at path, made from the OS random
    // source on first use and kept 0600.
    static Data* publisherKey(String* path)
        {
        Data* d = Files.readData(path);
        if (d != (Data*)0 && d.length() == (u32)32)
            return d;
        d = SecureRandom.bytes((u32)32);
        if (d == (Data*)0)
            return (Data*)0;
        // The file made empty and 0600 FIRST, so the key is never readable by
        // anyone else, not even for the moment between writing and chmod.
        if (!Files.writeData(path, new Data()))
            return (Data*)0;
#if ARCH_arm64 || ARCH_x86_64 || OS_android
        chmod(path.cString(), (u32)384);   // 0600
#endif
        if (!Files.writeData(path, d))
            return (Data*)0;
        return d;
        }

    static bool _copy(String* from, String* to)
        {
        Data* d = Files.readData(from);
        return d != (Data*)0 && Files.writeData(to, d);
        }

    static void _mkdirs(String* path)
        {
        for (u32 i = (u32)1; i <= path.byteLength(); i = i + (u32)1)
            if (i == path.byteLength() || path.byteAt(i) == (u8)'/')
                Files.createDirectory(path.substringBytes((u32)0, i));
        }

    // Lay out and sign the bundle; 0, or what went wrong.
    static String* make(String* dir, String* name, String* version, String* platform, String* codeFile,
                        String* resourcesDir, Data* seed, String* publisher, String* domain, Map* provides, Map* requires)
        {
        return BundleSign.makeWith(dir, name, version, platform, codeFile, resourcesDir, seed, publisher, domain,
                                   provides, requires, (Map*)0, (Map*)0, (Data*)0, (Array*)0);
        }

    // What the old key signs to hand its plugins over to the new one.
    static String* _rotationText(String* newKeyHex)
        {
        String* t = String.withCString("xc-bundle-key-rotation\n");
        t.append(newKeyHex);
        return t;
        }

    // make(), with the developer's properties: readonly (the publisher's,
    // final) and writeable (defaults a user may override); 0 for both keeps
    // what the last run's manifest had. previousSeed: the key this one
    // replaces, which signs the hand-over (a rotation record); 0 keeps the
    // record the last run made with this key, if any. libs: libraries the
    // code needs that the system does not provide, shipped beside it in
    // Exec/<platform>/ (the loader loads them first, from the verified copy).
    static String* makeWith(String* dir, String* name, String* version, String* platform, String* codeFile,
                            String* resourcesDir, Data* seed, String* publisher, String* domain, Map* provides,
                            Map* requires, Map* readonly, Map* writeable, Data* previousSeed, Array* libs)
        {
        Map* rotation = (Map*)0;
        if (!BundleRules.validName(name))
            return String.withFormat("'%s' is not a bundle name: letters, digits, '_' and '-'", name.cString());
        // seed 0: laid out UNSIGNED, for `xcc --sign-bundle` on the machine
        // that holds the key; no loader accepts it until then.
        if (seed != (Data*)0 && seed.length() != (u32)32)
            return String.withCString("the publisher key is not a key");
        String* keyHex = seed == (Data*)0 ? String.withCString("")
                                          : BundleSign._hex(Ed25519.publicKey(seed.bytes()).bytes(), (u32)32);
        // The code file keeps its extension: Exec/<platform>/<name><ext>.
        String* ext = new String();
        u32 dot = codeFile.byteLength();
        while (dot > (u32)0 && codeFile.byteAt(dot - (u32)1) != (u8)'.' && codeFile.byteAt(dot - (u32)1) != (u8)'/')
            dot = dot - (u32)1;
        if (dot > (u32)0 && codeFile.byteAt(dot - (u32)1) == (u8)'.')
            ext = codeFile.substringFromByte(dot - (u32)1);
        // What a previous run left for OTHER platforms, if the same key signed it.
        Map* files = new Map();
        Array* platforms = new Array();
        String* prior = BundleSign.verify(dir);
        // An unsigned layout (from --no-sign) carries over too, when its files
        // are what its manifest says: its key is "", so nothing is trusted from it.
        bool unsignedPrior = prior != (String*)0 && BundleSign.checkFiles(dir) == (String*)0;
        if (prior == (String*)0 || unsignedPrior)
            {
            Data* mb = Files.readData(BundleSign._join(dir, String.withCString("bundle.json")));
            try
                {
                Map* old = (Map*)BundleRules.parseManifest(mb);
                Map* opub = (Map*)old.get((Hashable*)String.withCString("publisher"));
                String* okey = opub == (Map*)0 ? (String*)0 : (String*)opub.get((Hashable*)String.withCString("key"));
                bool handedOver = previousSeed != (Data*)0 && previousSeed.length() == (u32)32 && okey != (String*)0
                                  && okey.equals(BundleSign._hex(Ed25519.publicKey(previousSeed.bytes()).bytes(), (u32)32));
                if (okey != (String*)0 && (keyHex.equals(okey) || handedOver || (unsignedPrior && okey.byteLength() == (u32)0)))
                    {
                    Map* of = (Map*)old.get((Hashable*)String.withCString("files"));
                    String* mine = String.withCString("Exec/");
                    mine.append(platform);
                    mine.appendByte((u8)'/');
                    Array* ks = of.allKeys();
                    for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
                        {
                        String* k = (String*)ks.get(i);
                        if (k.hasPrefix(String.withCString("Exec/")) && !k.hasPrefix(mine))
                            files.set((Hashable*)k, of.get((Hashable*)k));
                        }
                    // What this run does not say, the last one did: the
                    // version and publisher carry over.
                    if (version == (String*)0)
                        version = (String*)old.get((Hashable*)String.withCString("version"));
                    if (publisher == (String*)0)
                        publisher = (String*)opub.get((Hashable*)String.withCString("name"));
                    if (domain == (String*)0)
                        domain = (String*)opub.get((Hashable*)String.withCString("domain"));
                    if (previousSeed == (Data*)0 && opub.get((Hashable*)String.withCString("rotation")) != (Object*)0)
                        {
                        rotation = new Map();
                        rotation.set((Hashable*)String.withCString("previousKey"), opub.get((Hashable*)String.withCString("previousKey")));
                        rotation.set((Hashable*)String.withCString("previousKeyId"), opub.get((Hashable*)String.withCString("previousKeyId")));
                        rotation.set((Hashable*)String.withCString("rotation"), opub.get((Hashable*)String.withCString("rotation")));
                        }
                    Map* oprops = (Map*)old.get((Hashable*)String.withCString("properties"));
                    if (readonly == (Map*)0 && writeable == (Map*)0 && oprops != (Map*)0)
                        {
                        readonly = (Map*)oprops.get((Hashable*)String.withCString("readonly"));
                        writeable = (Map*)oprops.get((Hashable*)String.withCString("writeable"));
                        }
                    Array* op = (Array*)old.get((Hashable*)String.withCString("platforms"));
                    for (u32 i = (u32)0; op != (Array*)0 && i < op.count(); i = i + (u32)1)
                        if (!((String*)op.get(i)).equals(platform))
                            platforms.add(op.get(i));
                    }
                }
            catch (JSONError e)
                {
                }
            }
        if (version == (String*)0)
            version = String.withCString("1.0");
        Map* props = (Map*)0;
        if ((readonly != (Map*)0 && readonly.count() > (u32)0) || (writeable != (Map*)0 && writeable.count() > (u32)0))
            {
            props = new Map();
            if (readonly != (Map*)0 && readonly.count() > (u32)0)
                props.set((Hashable*)String.withCString("readonly"), (Object*)readonly);
            if (writeable != (Map*)0 && writeable.count() > (u32)0)
                props.set((Hashable*)String.withCString("writeable"), (Object*)writeable);
            String* bad = BundleRules.checkProperties((Object*)props);
            if (bad != (String*)0)
                return bad;
            }
        platforms.add((Object*)platform);
        BundleSign._sort(platforms);
        // The code.
        String* execDir = BundleSign._join(BundleSign._join(dir, String.withCString("Exec")), platform);
        BundleSign._mkdirs(execDir);
        String* rel = String.withCString("Exec/");
        rel.append(platform);
        rel.appendByte((u8)'/');
        rel.append(name);
        rel.append(ext);
        if (!BundleSign._copy(codeFile, BundleSign._join(dir, rel)))
            return String.withFormat("cannot copy %s into the bundle", codeFile.cString());
        files.set((Hashable*)rel, (Object*)BundleSign._sha(BundleSign._join(dir, rel)));
        for (u32 i = (u32)0; libs != (Array*)0 && i < libs.count(); i = i + (u32)1)
            {
            String* lib = (String*)libs.get(i);
            u32 sl = lib.byteLength();
            while (sl > (u32)0 && lib.byteAt(sl - (u32)1) != (u8)'/' && lib.byteAt(sl - (u32)1) != (u8)92)
                sl = sl - (u32)1;
            String* lrel = String.withFormat("Exec/%s/%s", platform.cString(), lib.substringFromByte(sl).cString());
            if (!BundleRules.validPath(lrel) || lrel.equals(rel))
                return String.withFormat("'%s' is not a name a bundle may hold beside its code", lrel.cString());
            if (!BundleSign._copy(lib, BundleSign._join(dir, lrel)))
                return String.withFormat("cannot copy %s into the bundle", lib.cString());
            files.set((Hashable*)lrel, (Object*)BundleSign._sha(BundleSign._join(dir, lrel)));
            }
        // The resources (one level: Resources/<file>).
        if (resourcesDir != (String*)0)
            {
            Array* es = Directory.list(resourcesDir);
            if (es == (Array*)0)
                return String.withFormat("cannot read the resources in %s", resourcesDir.cString());
            BundleSign._mkdirs(BundleSign._join(dir, String.withCString("Resources")));
            for (u32 i = (u32)0; i < es.count(); i = i + (u32)1)
                {
                DirEntry* e = (DirEntry*)es.get(i);
                if (e.kind != (u8)DIR_FILE)
                    continue;
                String* r = String.withCString("Resources/");
                r.append(e.name);
                if (!BundleRules.validPath(r))
                    return String.withFormat("'%s' is not a name a bundle may hold", r.cString());
                if (!BundleSign._copy(BundleSign._join(resourcesDir, e.name), BundleSign._join(dir, r)))
                    return String.withFormat("cannot copy %s", r.cString());
                files.set((Hashable*)r, (Object*)BundleSign._sha(BundleSign._join(dir, r)));
                }
            }
        else
            {
            // Resources already in the bundle stay, re-hashed.
            Array* all = new Array();
            String* bad = (String*)0;
            BundleSign._walk(dir, String.withCString(""), all, &bad);
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                String* p = (String*)all.get(i);
                if (p.hasPrefix(String.withCString("Resources/")))
                    files.set((Hashable*)p, (Object*)BundleSign._sha(BundleSign._join(dir, p)));
                }
            }
        return BundleSign._emit(dir, name, version, files, platforms, props, provides, requires, publisher, domain, seed,
                                previousSeed, rotation);
        }

    // The manifest, keys sorted, then its signature (none when seed is 0).
    static String* _emit(String* dir, String* name, String* version, Map* files, Array* platforms, Map* props,
                         Map* provides, Map* requires, String* publisher, String* domain, Data* seed, Data* previousSeed,
                         Map* rotation)
        {
        String* keyHex = seed == (Data*)0 ? String.withCString("")
                                          : BundleSign._hex(Ed25519.publicKey(seed.bytes()).bytes(), (u32)32);
        Map* pm = new Map();
        pm.set((Hashable*)String.withCString("domain"), (Object*)(domain != (String*)0 ? domain : new String()));
        pm.set((Hashable*)String.withCString("key"), (Object*)keyHex);
        pm.set((Hashable*)String.withCString("keyId"),
               (Object*)(seed == (Data*)0 ? String.withCString("")
                                          : Sha256.hex(Ed25519.publicKey(seed.bytes()).bytes(), (u32)32)));
        pm.set((Hashable*)String.withCString("name"), (Object*)(publisher != (String*)0 ? publisher : new String()));
        if (previousSeed != (Data*)0 && seed != (Data*)0)
            {
            if (previousSeed.length() != (u32)32)
                return String.withCString("the previous key is not a key");
            Data* opk = Ed25519.publicKey(previousSeed.bytes());
            if (BundleSign._hex(opk.bytes(), (u32)32).equals(keyHex))
                return String.withCString("the previous key is the same key");
            String* rt = BundleSign._rotationText(keyHex);
            Data* rs = Ed25519.sign(rt.cString(), rt.byteLength(), previousSeed.bytes());
            rotation = new Map();
            rotation.set((Hashable*)String.withCString("previousKey"), (Object*)BundleSign._hex(opk.bytes(), (u32)32));
            rotation.set((Hashable*)String.withCString("previousKeyId"), (Object*)Sha256.hex(opk.bytes(), (u32)32));
            rotation.set((Hashable*)String.withCString("rotation"), (Object*)BundleSign._hex(rs.bytes(), (u32)64));
            }
        if (rotation != (Map*)0)
            {
            Array* rk = rotation.allKeys();
            for (u32 i = (u32)0; i < rk.count(); i = i + (u32)1)
                pm.set((Hashable*)rk.get(i), rotation.get((Hashable*)rk.get(i)));
            }
        String* m = String.withCString("{\n  \"code\": ");
        m.append(BundleSign._quoted(name));
        m.appendCString(",\n  \"files\": ");
        m.append(BundleSign._object(files));
        m.appendCString(",\n  \"name\": ");
        m.append(BundleSign._quoted(name));
        m.appendCString(",\n  \"platforms\": [");
        for (u32 i = (u32)0; i < platforms.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                m.appendCString(", ");
            m.append(BundleSign._quoted((String*)platforms.get(i)));
            }
        m.appendCString("]");
        if (props != (Map*)0)
            {
            m.appendCString(",\n  \"properties\": {");
            bool first = true;
            if (props.get((Hashable*)String.withCString("readonly")) != (Object*)0)
                {
                m.appendCString("\"readonly\": ");
                m.append(BundleSign._object((Map*)props.get((Hashable*)String.withCString("readonly"))));
                first = false;
                }
            if (props.get((Hashable*)String.withCString("writeable")) != (Object*)0)
                {
                if (!first)
                    m.appendCString(", ");
                m.appendCString("\"writeable\": ");
                m.append(BundleSign._object((Map*)props.get((Hashable*)String.withCString("writeable"))));
                }
            m.appendCString("}");
            }
        m.appendCString(",\n  \"provides\": ");
        m.append(BundleSign._object(provides));
        m.appendCString(",\n  \"publisher\": ");
        m.append(BundleSign._object(pm));
        m.appendCString(",\n  \"requires\": ");
        m.append(BundleSign._object(requires));
        m.appendCString(",\n  \"version\": ");
        m.append(BundleSign._quoted(version));
        m.appendCString("\n}\n");
        if (!Files.writeText(BundleSign._join(dir, String.withCString("bundle.json")), m))
            return String.withCString("cannot write bundle.json");
        if (seed == (Data*)0)
            {
            // Unsigned: a stale signature would only mislead.
            Directory.remove(BundleSign._join(dir, String.withCString("bundle.sig")));
            return BundleSign.checkFiles(dir);
            }
        Data* sig = Ed25519.sign(m.cString(), m.byteLength(), seed.bytes());
        String* sh = BundleSign._hex(sig.bytes(), (u32)64);
        sh.appendByte((u8)10);
        if (!Files.writeText(BundleSign._join(dir, String.withCString("bundle.sig")), sh))
            return String.withCString("cannot write bundle.sig");
        return BundleSign.verify(dir);
        }

    // The files against the manifest, signed or not: every listed file there
    // and unchanged, nothing else there, the paths and properties well formed.
    // 0, or what is wrong. What --sign-bundle checks before it signs, so a
    // bundle altered on its way from the build machine is not signed.
    static String* checkFiles(String* dir)
        {
        Data* mb = Files.readData(BundleSign._join(dir, String.withCString("bundle.json")));
        if (mb == (Data*)0)
            return String.withCString("no bundle.json");
        Map* m = (Map*)0;
        try
            {
            m = (Map*)BundleRules.parseManifest(mb);
            }
        catch (JSONError e)
            {
            return String.withFormat("the manifest is refused: %s", e.message().cString());
            }
        Map* files = (Map* ?)m.get((Hashable*)String.withCString("files"));
        if (files == (Map*)0)
            return String.withCString("the manifest lists no files");
        Array* listed = files.allKeys();
        BundleSign._sort(listed);
        for (u32 i = (u32)0; i < listed.count(); i = i + (u32)1)
            if (!BundleRules.validPath((String*)listed.get(i)))
                return String.withFormat("'%s' is not a path a bundle may hold", ((String*)listed.get(i)).cString());
        Array* present = new Array();
        String* bad = (String*)0;
        if (!BundleSign._walk(dir, String.withCString(""), present, &bad))
            return String.withFormat("'%s' is a link or a special file", bad.cString());
        for (u32 i = (u32)0; i < present.count(); i = i + (u32)1)
            {
            String* p = (String*)present.get(i);
            if (p.equals(String.withCString("bundle.json")) || p.equals(String.withCString("bundle.sig")))
                continue;
            if (files.get((Hashable*)p) == (Object*)0)
                return String.withFormat("'%s' is a file the manifest does not list", p.cString());
            }
        for (u32 i = (u32)0; i < listed.count(); i = i + (u32)1)
            {
            String* p = (String*)listed.get(i);
            String* h = BundleSign._sha(BundleSign._join(dir, p));
            if (h == (String*)0)
                return String.withFormat("'%s' is missing", p.cString());
            if (!h.equals((String*)files.get((Hashable*)p)))
                return String.withFormat("'%s' has changed since the manifest was written", p.cString());
            }
        return BundleRules.checkProperties(m.get((Hashable*)String.withCString("properties")));
        }

    // Sign a bundle laid out elsewhere (xcc --bundle --no-sign), or sign one
    // again: its files are checked against its manifest first, then the
    // manifest is written with this publisher's key and signed. publisher and
    // domain: 0 keeps the manifest's. previousSeed hands the bundle over from
    // that key (a rotation record), as makeWith does.
    static String* sign(String* dir, Data* seed, String* publisher, String* domain, Data* previousSeed)
        {
        if (seed == (Data*)0 || seed.length() != (u32)32)
            return String.withCString("no publisher key");
        String* err = BundleSign.checkFiles(dir);
        if (err != (String*)0)
            return err;
        Map* m = (Map*)0;
        try
            {
            m = (Map*)BundleRules.parseManifest(Files.readData(BundleSign._join(dir, String.withCString("bundle.json"))));
            }
        catch (JSONError e)
            {
            return e.message();
            }
        Map* pub = (Map*)m.get((Hashable*)String.withCString("publisher"));
        if (publisher == (String*)0 && pub != (Map*)0)
            publisher = (String*)pub.get((Hashable*)String.withCString("name"));
        if (domain == (String*)0 && pub != (Map*)0)
            domain = (String*)pub.get((Hashable*)String.withCString("domain"));
        // A rotation record carries over only when the key that signed it is
        // the one signing now.
        Map* rotation = (Map*)0;
        String* keyHex = BundleSign._hex(Ed25519.publicKey(seed.bytes()).bytes(), (u32)32);
        if (previousSeed == (Data*)0 && pub != (Map*)0 && pub.get((Hashable*)String.withCString("rotation")) != (Object*)0
            && keyHex.equals((String*)pub.get((Hashable*)String.withCString("key"))))
            {
            rotation = new Map();
            rotation.set((Hashable*)String.withCString("previousKey"), pub.get((Hashable*)String.withCString("previousKey")));
            rotation.set((Hashable*)String.withCString("previousKeyId"), pub.get((Hashable*)String.withCString("previousKeyId")));
            rotation.set((Hashable*)String.withCString("rotation"), pub.get((Hashable*)String.withCString("rotation")));
            }
        Map* props = (Map* ?)m.get((Hashable*)String.withCString("properties"));
        return BundleSign._emit(dir, (String*)m.get((Hashable*)String.withCString("name")),
                                (String*)m.get((Hashable*)String.withCString("version")),
                                (Map*)m.get((Hashable*)String.withCString("files")),
                                (Array*)m.get((Hashable*)String.withCString("platforms")), props,
                                (Map* ?)m.get((Hashable*)String.withCString("provides")),
                                (Map* ?)m.get((Hashable*)String.withCString("requires")), publisher, domain, seed,
                                previousSeed, rotation);
        }

    // Every check §4 steps 1-3 make before anything in the bundle is used:
    // 0 when they all pass, else the first failure.
    static String* verify(String* dir)
        {
        Data* mb = Files.readData(BundleSign._join(dir, String.withCString("bundle.json")));
        if (mb == (Data*)0)
            return String.withCString("no bundle.json");
        String* st = Files.readText(BundleSign._join(dir, String.withCString("bundle.sig")));
        if (st == (String*)0)
            return String.withCString("no bundle.sig: the bundle is not signed (xcc --sign-bundle signs it)");
        String* err = BundleSign.verifyManifest(mb, st);
        if (err != (String*)0)
            return err;
        Map* m = (Map*)0;
        try
            {
            m = (Map*)BundleRules.parseManifest(mb);
            }
        catch (JSONError e)
            {
            return e.message();
            }
        Map* files = (Map*)m.get((Hashable*)String.withCString("files"));
        Array* listed = files.allKeys();
        BundleSign._sort(listed);
        Array* present = new Array();
        String* bad = (String*)0;
        if (!BundleSign._walk(dir, String.withCString(""), present, &bad))
            return String.withFormat("'%s' is a link or a special file", bad.cString());
        BundleSign._sort(present);
        for (u32 i = (u32)0; i < present.count(); i = i + (u32)1)
            {
            String* p = (String*)present.get(i);
            if (p.equals(String.withCString("bundle.json")) || p.equals(String.withCString("bundle.sig")))
                continue;
            if (files.get((Hashable*)p) == (Object*)0)
                return String.withFormat("'%s' is a file the manifest does not list", p.cString());
            }
        for (u32 i = (u32)0; i < listed.count(); i = i + (u32)1)
            {
            String* p = (String*)listed.get(i);
            String* h = BundleSign._sha(BundleSign._join(dir, p));
            if (h == (String*)0)
                return String.withFormat("'%s' is missing", p.cString());
            if (!h.equals((String*)files.get((Hashable*)p)))
                return String.withFormat("'%s' has changed since it was signed", p.cString());
            }
        return (String*)0;
        }

    // A copy that holds only one platform's code (a URL bundle's local copy,
    // bundles-and-plugins.md §2b): the signature and manifest as verify(),
    // nothing in it the manifest does not list, every Resources/ file and
    // every file of Exec/<platform>/ present and unchanged, and any other
    // platform's file absent or unchanged.
    static String* verifyPartial(String* dir, String* platform)
        {
        Data* mb = Files.readData(BundleSign._join(dir, String.withCString("bundle.json")));
        String* st = Files.readText(BundleSign._join(dir, String.withCString("bundle.sig")));
        if (mb == (Data*)0 || st == (String*)0)
            return String.withCString("no bundle.json or bundle.sig");
        String* err = BundleSign.verifyManifest(mb, st);
        if (err != (String*)0)
            return err;
        Map* m = (Map*)0;
        try
            {
            m = (Map*)BundleRules.parseManifest(mb);
            }
        catch (JSONError e)
            {
            return e.message();
            }
        Map* files = (Map*)m.get((Hashable*)String.withCString("files"));
        Array* present = new Array();
        String* bad = (String*)0;
        if (!BundleSign._walk(dir, String.withCString(""), present, &bad))
            return String.withFormat("'%s' is a link or a special file", bad.cString());
        for (u32 i = (u32)0; i < present.count(); i = i + (u32)1)
            {
            String* p = (String*)present.get(i);
            if (p.equals(String.withCString("bundle.json")) || p.equals(String.withCString("bundle.sig")))
                continue;
            if (files.get((Hashable*)p) == (Object*)0)
                return String.withFormat("'%s' is a file the manifest does not list", p.cString());
            }
        String* mine = String.withFormat("Exec/%s/", platform.cString());
        Array* listed = files.allKeys();
        BundleSign._sort(listed);
        for (u32 i = (u32)0; i < listed.count(); i = i + (u32)1)
            {
            String* p = (String*)listed.get(i);
            bool needed = p.hasPrefix(String.withCString("Resources/")) || p.hasPrefix(mine);
            String* h = BundleSign._sha(BundleSign._join(dir, p));
            if (h == (String*)0)
                {
                if (needed)
                    return String.withFormat("'%s' is missing", p.cString());
                continue;
                }
            if (!h.equals((String*)files.get((Hashable*)p)))
                return String.withFormat("'%s' has changed since it was signed", p.cString());
            }
        return (String*)0;
        }

    // The manifest's bytes and bundle.sig's text: the signature, the strict
    // parse, the name and every listed path. What verify() and a web load
    // share; the files themselves are checked by whoever holds them.
    static String* verifyManifest(Data* mb, String* st)
        {
        if (st.byteLength() > (u32)0 && st.byteAt(st.byteLength() - (u32)1) == (u8)10)
            st = st.substringBytes((u32)0, st.byteLength() - (u32)1);
        Data* sig = BundleSign._unhex(st, (u32)64);
        if (sig == (Data*)0)
            return String.withCString("bundle.sig is not a signature");
        Map* m = (Map*)0;
        try
            {
            m = (Map*)BundleRules.parseManifest(mb);
            }
        catch (JSONError e)
            {
            return String.withFormat("the manifest is refused: %s", e.message().cString());
            }
        Map* pub = (Map*)m.get((Hashable*)String.withCString("publisher"));
        Data* key = pub == (Map*)0 ? (Data*)0 : BundleSign._unhex((String*)pub.get((Hashable*)String.withCString("key")), (u32)32);
        if (key == (Data*)0)
            return String.withCString("the manifest has no publisher key");
        if (!Ed25519.verify(mb.bytes(), mb.length(), sig.bytes(), key.bytes()))
            return String.withCString("the signature does not verify");
        // A rotation record: the previous key, its id, and its signature over
        // the hand-over to this key. All three, or none.
        Object* rot = pub.get((Hashable*)String.withCString("rotation"));
        Object* prevK = pub.get((Hashable*)String.withCString("previousKey"));
        Object* prevId = pub.get((Hashable*)String.withCString("previousKeyId"));
        if (rot != (Object*)0 || prevK != (Object*)0 || prevId != (Object*)0)
            {
            String* rs = (String* ?)rot;
            String* pk = (String* ?)prevK;
            String* pid = (String* ?)prevId;
            Data* pkb = pk == (String*)0 ? (Data*)0 : BundleSign._unhex(pk, (u32)32);
            Data* rsb = rs == (String*)0 ? (Data*)0 : BundleSign._unhex(rs, (u32)64);
            if (pkb == (Data*)0 || rsb == (Data*)0 || pid == (String*)0 || !Sha256.hex(pkb.bytes(), (u32)32).equals(pid))
                return String.withCString("the key rotation record is incomplete");
            String* rt = BundleSign._rotationText((String*)pub.get((Hashable*)String.withCString("key")));
            if (!Ed25519.verify(rt.cString(), rt.byteLength(), rsb.bytes(), pkb.bytes()))
                return String.withCString("the key rotation does not verify");
            }
        String* name = (String*)m.get((Hashable*)String.withCString("name"));
        if (!BundleRules.validName(name))
            return String.withCString("the bundle's name is not a valid name");
        Map* files = (Map*)m.get((Hashable*)String.withCString("files"));
        if (files == (Map*)0)
            return String.withCString("the manifest lists no files");
        Array* listed = files.allKeys();
        BundleSign._sort(listed);
        for (u32 i = (u32)0; i < listed.count(); i = i + (u32)1)
            if (!BundleRules.validPath((String*)listed.get(i)))
                return String.withFormat("'%s' is not a path a bundle may hold", ((String*)listed.get(i)).cString());
        String* clash = BundleRules.collision(listed);
        if (clash != (String*)0)
            return String.withFormat("'%s' is the same file as another on a case-insensitive disk", clash.cString());
        return BundleRules.checkProperties(m.get((Hashable*)String.withCString("properties")));
        }
    }
