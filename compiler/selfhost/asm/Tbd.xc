// Tbd.xc — an Apple SDK text stub (`.tbd`, TAPI v4) read for what the
// linker needs: the library's install-name and the symbols it exports for
// the platform being linked. The mirror of XTMachOWriter's inspectTbd:
// (bug 138 / uxkit 028: the shipped driver bound every framework import to
// dylib ordinal 1 because it knew no framework's exports).
//
// The format is regular YAML: `install-name:`, then `exports:`/`reexports:`
// entries each pairing a `targets: [ … ]` list with `symbols: [ … ]`,
// `objc-classes: [ … ]`, `objc-eh-types: [ … ]` lists (any may wrap across
// lines). The most recent `targets:` decides whether the lists that follow
// apply to OUR target triple; reading the wrong ones yields NO symbols, not
// wrong ones, and an empty export set is silent — the import still resolves,
// to ordinal 1, and dyld refuses at launch (028).
//
// `reexported-libraries:` names what this dylib provides THROUGH another
// (Foundation → CoreFoundation, libobjc): those exports are unioned in, so a
// symbol reached through the re-export binds to this ordinal, as dyld
// resolves it. The re-exported stub sits at `<sdk-root><install-name>.tbd`.
//
// Cached per path AND platform: Foundation.tbd is 6.8 MB and a link reads
// each stub once (uxkit 027 was reading them per root, per line).

#import "Foundation.xc"
#import "Files.xc"

class TbdInfo
    {
    String* _install;
    Array* _symbols; // String@
    void init(void)
        {
        _symbols = new Array();
        }
    String* install(void)
        {
        return _install;
        }
    Array* symbols(void)
        {
        return _symbols;
        }
    }

    class Tbd
    {
    static Map* _cache;       // "path|platform" -> TbdInfo (empty install = unreadable)
    static String* _platform; // "macos" | "ios" | "ios-sim"

    void init(void)
        {
        }

    static void setPlatform(String* p)
        {
        _platform = p;
        }

    // The target triples this platform's exports are listed under.
    static Array* targets(void)
        {
        Array* t = new Array();
        String* p = _platform;
        if (p != (String*)0 && p.equals(String.withCString("ios")))
            {
            t.add((Object*)String.withCString("arm64-ios"));
            t.add((Object*)String.withCString("arm64e-ios"));
            }
        else if (p != (String*)0 && p.equals(String.withCString("ios-sim")))
            {
            t.add((Object*)String.withCString("arm64-ios-simulator"));
            t.add((Object*)String.withCString("arm64e-ios-simulator"));
            }
        else
            {
            t.add((Object*)String.withCString("arm64-macos"));
            t.add((Object*)String.withCString("arm64e-macos"));
            }
        return t;
        }

    // `sdkRoot` is where re-exported stubs are found (`<sdkRoot><install>.tbd`).
    static TbdInfo* inspect(String* path, String* sdkRoot)
        {
        if (_cache == (Map*)0)
            _cache = new Map();
        String* key = String.withString(path);
        key.appendCString("|");
        key.append(_platform == (String*)0 ? String.withCString("macos") : _platform);
        Object* hit = _cache.get((Hashable*)key);
        if (hit != (Object*)0)
            {
            TbdInfo* h = (TbdInfo*)hit;
            return h.install() == (String*)0 ? (TbdInfo*)0 : h;
            }
        TbdInfo* r = Tbd.inspectUncached(path, sdkRoot, (u32)0);
        _cache.set((Hashable*)key, (Object*)(r == (TbdInfo*)0 ? new TbdInfo() : r));
        return r;
        }

    static bool startsWith(String* t, string p)
        {
        return t.hasPrefix(String.withCString(p));
        }

    // Strip spaces and quotes from a list item.
    static String* unquote(String* s)
        {
        u32 a = (u32)0;
        u32 b = s.byteLength();
        while (a < b && (s.byteAt(a) == (u8)' ' || s.byteAt(a) == (u8)'\'' || s.byteAt(a) == (u8)'"' || s.byteAt(a) == (u8)9))
            a = a + (u32)1;
        while (b > a && (s.byteAt(b - (u32)1) == (u8)' ' || s.byteAt(b - (u32)1) == (u8)'\'' || s.byteAt(b - (u32)1) == (u8)'"' || s.byteAt(b - (u32)1) == (u8)9 || s.byteAt(b - (u32)1) == (u8)13))
            b = b - (u32)1;
        return s.substringBytes(a, b - a);
        }

    static TbdInfo* inspectUncached(String* path, String* sdkRoot, u32 depth)
        {
        String* txt = Files.readText(path);
        if (txt == (String*)0 || !txt.contains(String.withCString("tapi-tbd")))
            return (TbdInfo*)0;
        Array* lines = txt.splitOnByte((u8)10);
        Array* want = Tbd.targets();
        TbdInfo* info = new TbdInfo();
        Map* seen = new Map();
        Array* reexports = new Array();
        bool cur = false;
        bool inReexports = false;
        String* lb = String.withCString("[");
        String* rb = String.withCString("]");
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* t = ((String*)lines.get(i)).trimmed();
            if (info._install == (String*)0 && Tbd.startsWith(t, "install-name:"))
                {
                info._install = Tbd.unquote(t.substringFromByte((u32)13));
                continue;
                }
            if (Tbd.startsWith(t, "reexported-libraries:"))
                {
                inReexports = true;
                continue;
                }
            if (Tbd.startsWith(t, "exports:") || Tbd.startsWith(t, "symbols:") || Tbd.startsWith(t, "objc-classes:"))
                inReexports = false;
            u32 kind = (u32)0; // 1 targets, 2 symbols, 3 objc-classes, 4 objc-eh-types, 5 libraries
            u32 klen = (u32)0;
            if (Tbd.startsWith(t, "- targets:"))
                {
                kind = (u32)1;
                klen = (u32)10;
                }
            else if (Tbd.startsWith(t, "targets:"))
                {
                kind = (u32)1;
                klen = (u32)8;
                }
            else if (Tbd.startsWith(t, "symbols:"))
                {
                kind = (u32)2;
                klen = (u32)8;
                }
            else if (Tbd.startsWith(t, "- symbols:"))
                {
                kind = (u32)2;
                klen = (u32)10;
                }
            else if (Tbd.startsWith(t, "objc-classes:"))
                {
                kind = (u32)3;
                klen = (u32)13;
                }
            else if (Tbd.startsWith(t, "- objc-classes:"))
                {
                kind = (u32)3;
                klen = (u32)15;
                }
            else if (Tbd.startsWith(t, "objc-eh-types:"))
                {
                kind = (u32)4;
                klen = (u32)14;
                }
            else if (Tbd.startsWith(t, "- objc-eh-types:"))
                {
                kind = (u32)4;
                klen = (u32)16;
                }
            else if (inReexports && Tbd.startsWith(t, "libraries:"))
                {
                kind = (u32)5;
                klen = (u32)10;
                }
            else if (inReexports && Tbd.startsWith(t, "- libraries:"))
                {
                kind = (u32)5;
                klen = (u32)12;
                }
            if (kind == (u32)0)
                continue;
            // Accumulate the bracketed list, which may wrap over several
            // lines. The termination test looks at the line just appended,
            // never at the whole buffer (that was uxkit 027's minutes).
            String* buf = String.withString(t.substringFromByte(klen));
            bool closed = buf.contains(rb);
            while (!closed && i + (u32)1 < lines.count())
                {
                i = i + (u32)1;
                String* ln = (String*)lines.get(i);
                buf.appendCString(" ");
                buf.append(ln);
                closed = ln.contains(rb);
                }
            u32 l = buf.byteIndexOf(lb);
            if (l == String.notFound())
                continue;
            u32 r = String.notFound();
            for (u32 q = buf.byteLength(); q > l; q = q - (u32)1)
                if (buf.byteAt(q - (u32)1) == (u8)']')
                    {
                    r = q - (u32)1;
                    break;
                    }
            if (r == String.notFound() || r <= l)
                continue;
            Array* items = buf.substringBytes(l + (u32)1, r - l - (u32)1).splitOnByte((u8)',');
            if (kind == (u32)1)
                {
                cur = false;
                for (u32 k = (u32)0; k < items.count() && !cur; k = k + (u32)1)
                    {
                    String* s = ((String*)items.get(k)).trimmed();
                    for (u32 w = (u32)0; w < want.count(); w = w + (u32)1)
                        if (s.equals((String*)want.get(w)))
                            {
                            cur = true;
                            break;
                            }
                    }
                continue;
                }
            if (!cur)
                continue;
            for (u32 k = (u32)0; k < items.count(); k = k + (u32)1)
                {
                String* s = Tbd.unquote((String*)items.get(k));
                if (s.byteLength() == (u32)0)
                    continue;
                if (kind == (u32)5)
                    {
                    reexports.add((Object*)s);
                    continue;
                    }
                if (kind == (u32)3)
                    {
                    Tbd.addSym(info, seen, String.withCString("_OBJC_CLASS_$_").appending(s));
                    Tbd.addSym(info, seen, String.withCString("_OBJC_METACLASS_$_").appending(s));
                    }
                else if (kind == (u32)4)
                    {
                    Tbd.addSym(info, seen, String.withCString("_OBJC_EHTYPE_$_").appending(s));
                    }
                else
                    {
                    Tbd.addSym(info, seen, s);
                    }
                }
            }
        if (info._install == (String*)0)
            return (TbdInfo*)0;
        // What this dylib RE-EXPORTS, unioned in: the stub for a re-exported
        // library sits at `<sdk-root><install-name>.tbd`.
        if (depth < (u32)4 && reexports.count() > (u32)0 && sdkRoot != (String*)0)
            {
            for (u32 k = (u32)0; k < reexports.count(); k = k + (u32)1)
                {
                String* sub = String.withString(sdkRoot);
                sub.append((String*)reexports.get(k));
                sub.appendCString(".tbd");
                if (!Files.exists(sub))
                    continue;
                TbdInfo* r = Tbd.inspectUncached(sub, sdkRoot, depth + (u32)1);
                if (r == (TbdInfo*)0)
                    continue;
                for (u32 q = (u32)0; q < r.symbols().count(); q = q + (u32)1)
                    Tbd.addSym(info, seen, (String*)r.symbols().get(q));
                }
            }
        return info;
        }

    static void addSym(TbdInfo* info, Map* seen, String* s)
        {
        if (seen.get((Hashable*)s) != (Object*)0)
            return;
        seen.set((Hashable*)s, (Object*)Number.withU32((u32)1));
        info._symbols.add((Object*)s);
        }
    }
