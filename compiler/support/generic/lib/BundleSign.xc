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

#if ARCH_arm64 || ARCH_x86_64 || PLATFORM_android
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
        if (d == (Data*)0 || !Files.writeData(path, d))
            return (Data*)0;
#if ARCH_arm64 || ARCH_x86_64 || PLATFORM_android
        chmod(path.cString(), (u32)384);   // 0600
#endif
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
        if (!BundleRules.validName(name))
            return String.withFormat("'%s' is not a bundle name: letters, digits, '_' and '-'", name.cString());
        if (seed == (Data*)0 || seed.length() != (u32)32)
            return String.withCString("no publisher key");
        Data* pub = Ed25519.publicKey(seed.bytes());
        String* keyHex = BundleSign._hex(pub.bytes(), (u32)32);
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
        if (prior == (String*)0)
            {
            Data* mb = Files.readData(BundleSign._join(dir, String.withCString("bundle.json")));
            try
                {
                Map* old = (Map*)BundleRules.parseManifest(mb);
                Map* opub = (Map*)old.get((Hashable*)String.withCString("publisher"));
                if (opub != (Map*)0 && keyHex.equals((String*)opub.get((Hashable*)String.withCString("key"))))
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
        // The manifest, keys sorted, then its signature.
        Map* pm = new Map();
        pm.set((Hashable*)String.withCString("domain"), (Object*)(domain != (String*)0 ? domain : new String()));
        pm.set((Hashable*)String.withCString("key"), (Object*)keyHex);
        pm.set((Hashable*)String.withCString("keyId"), (Object*)Sha256.hex(pub.bytes(), (u32)32));
        pm.set((Hashable*)String.withCString("name"), (Object*)(publisher != (String*)0 ? publisher : new String()));
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
        m.appendCString("],\n  \"provides\": ");
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
        Data* sig = Ed25519.sign(m.cString(), m.byteLength(), seed.bytes());
        String* sh = BundleSign._hex(sig.bytes(), (u32)64);
        sh.appendByte((u8)10);
        if (!Files.writeText(BundleSign._join(dir, String.withCString("bundle.sig")), sh))
            return String.withCString("cannot write bundle.sig");
        return BundleSign.verify(dir);
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
            return String.withCString("no bundle.sig");
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
    }
