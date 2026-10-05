// Apk.xc — the APK writer, in xtc. Mirrors src/xtc/link/XTApkWriter.m.
// =================================================================
//
// An APK is a ZIP with a binary-XML manifest. Neither needs the Android SDK:
// aapt2, zipalign and android.jar were replaced on the Objective-C side by
// XTApkWriter, and this is the same writer in the language the compiler is
// written in — THE RULE, applied to packaging rather than to codegen.
//
// Two pieces here, both pure byte layout:
//
//   * `ApkZip`  — stored (uncompressed) entries with CRC-32 and alignment
//                 padding written INTO the local header's extra field, which
//                 is what zipalign does after the fact.
//   * `ApkXml`  — the binary XML the framework parses: a UTF-16 string pool, a
//                 positional resource map, and the element tree.
//
// The resource map is the part that looks arbitrary and is not: attribute names
// must occupy the LOWEST string-pool indices, in the same order as the
// resource-id array, because the framework matches them by POSITION, not name.
// Interning them first is what makes that true.

#import "Foundation.xc"

// ── little-endian writers ────────────────────────────────────────────────
void apkW8(Array* d, u32 v)
    {
    d.add((Object*)Number.withU32(v & (u32)$FF));
    }
void apkW16(Array* d, u32 v)
    {
    apkW8(d, v);
    apkW8(d, v >> (u32)8);
    }
void apkW32(Array* d, u32 v)
    {
    apkW8(d, v);
    apkW8(d, v >> (u32)8);
    apkW8(d, v >> (u32)16);
    apkW8(d, v >> (u32)24);
    }
void apkAppend(Array* d, Array* src)
    {
    for (u32 i = (u32)0; i < src.count(); i = i + (u32)1)
        d.add(src.get(i));
    }

// ── CRC-32 (the ZIP polynomial, reflected) ───────────────────────────────
class Crc32
    {
    static u32 of(Array* bytes)
        {
        u32 crc = (u32)$FFFFFFFF;
        for (u32 i = (u32)0; i < bytes.count(); i = i + (u32)1)
            {
            crc = crc ^ (((Number*)bytes.get(i)).asU32() & (u32)$FF);
            for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
                {
                u32 mask = (u32)0 - (crc & (u32)1);
                crc = (crc >> (u32)1) ^ ((u32)$EDB88320 & mask);
                }
            }
        return crc ^ (u32)$FFFFFFFF;
        }
    }

    // ── the string pool ──────────────────────────────────────────────────────
    class ApkPool
    {
    Array* _strings; // String@
    Map* _index;     // String -> Number(index)

    void init(void)
        {
        _strings = new Array();
        _index = new Map();
        }

    Array* strings(void)
        {
        return _strings;
        }

    u32 intern(String* s)
        {
        Object* have = _index.get((Hashable*)s);
        if (have != (Object*)0)
            return ((Number*)have).asU32();
        u32 idx = _strings.count();
        _strings.add((Object*)s);
        _index.set((Hashable*)String.withString(s), (Object*)Number.withU32(idx));
        return idx;
        }

    // UTF-16 pool. Every string is length-prefixed and NUL-terminated in
    // 16-bit units, and the whole body is padded to 4.
    Array* chunk(void)
        {
        Array* offsets = new Array();
        Array* body = new Array();
        for (u32 i = (u32)0; i < _strings.count(); i = i + (u32)1)
            {
            String* s = (String*)_strings.get(i);
            apkW32(offsets, body.count());
            u32 n = s.byteLength(); // ASCII throughout, so units == bytes
            apkW16(body, n);
            for (u32 c = (u32)0; c < n; c = c + (u32)1)
                apkW16(body, (u32)s.byteAt(c));
            apkW16(body, (u32)0);
            }
        while (body.count() % (u32)4 != (u32)0)
            apkW8(body, (u32)0);
        u32 headerSize = (u32)28;
        u32 stringsStart = headerSize + offsets.count();
        Array* out = new Array();
        apkW16(out, (u32)$0001); // RES_STRING_POOL
        apkW16(out, headerSize);
        apkW32(out, headerSize + offsets.count() + body.count());
        apkW32(out, _strings.count());
        apkW32(out, (u32)0); // styleCount
        apkW32(out, (u32)0); // flags: UTF-16, unsorted
        apkW32(out, stringsStart);
        apkW32(out, (u32)0); // stylesStart
        apkAppend(out, offsets);
        apkAppend(out, body);
        return out;
        }
    }

    // ── the binary XML manifest ──────────────────────────────────────────────
    class ApkXml
    {
    // The framework matches an attribute to its resource id BY POSITION in the
    // resource map, so these two lists are one table in two halves and must
    // stay in step — and they must be the FIRST things interned, so their pool
    // indices are 0..n-1.
    static Array* attrNames(void)
        {
        Array* a = new Array();
        a.add((Object*)String.withCString("label"));
        a.add((Object*)String.withCString("name"));
        a.add((Object*)String.withCString("hasCode"));
        a.add((Object*)String.withCString("exported"));
        a.add((Object*)String.withCString("value"));
        a.add((Object*)String.withCString("minSdkVersion"));
        a.add((Object*)String.withCString("targetSdkVersion"));
        a.add((Object*)String.withCString("extractNativeLibs"));
        return a;
        }
    static Array* attrIds(void)
        {
        Array* a = new Array();
        a.add((Object*)Number.withU32((u32)$01010001)); // label
        a.add((Object*)Number.withU32((u32)$01010003)); // name
        a.add((Object*)Number.withU32((u32)$0101000C)); // hasCode
        a.add((Object*)Number.withU32((u32)$01010010)); // exported
        a.add((Object*)Number.withU32((u32)$01010024)); // value
        a.add((Object*)Number.withU32((u32)$0101020C)); // minSdkVersion
        a.add((Object*)Number.withU32((u32)$01010270)); // targetSdkVersion
        a.add((Object*)Number.withU32((u32)$010104EA)); // extractNativeLibs
        return a;
        }

    // The <application> attributes --manifest-attr may set: name, framework
    // resource id (from the SDK's android.jar), and whether the value is a
    // boolean (otherwise a string). Each takes a plain value; theme and icon,
    // which name resources, are not here. As the reference's settableAttrs.
    static Array* settableNames(void)
        {
        Array* a = new Array();
        a.add((Object*)String.withCString("label"));
        a.add((Object*)String.withCString("debuggable"));
        a.add((Object*)String.withCString("allowBackup"));
        a.add((Object*)String.withCString("hardwareAccelerated"));
        a.add((Object*)String.withCString("largeHeap"));
        a.add((Object*)String.withCString("usesCleartextTraffic"));
        a.add((Object*)String.withCString("resizeableActivity"));
        a.add((Object*)String.withCString("requestLegacyExternalStorage"));
        a.add((Object*)String.withCString("enableOnBackInvokedCallback"));
        return a;
        }
    static Array* settableIds(void)
        {
        Array* a = new Array();
        a.add((Object*)Number.withU32((u32)$01010001)); // label
        a.add((Object*)Number.withU32((u32)$0101000F)); // debuggable
        a.add((Object*)Number.withU32((u32)$01010280)); // allowBackup
        a.add((Object*)Number.withU32((u32)$010102D3)); // hardwareAccelerated
        a.add((Object*)Number.withU32((u32)$0101035A)); // largeHeap
        a.add((Object*)Number.withU32((u32)$010104EC)); // usesCleartextTraffic
        a.add((Object*)Number.withU32((u32)$010104F6)); // resizeableActivity
        a.add((Object*)Number.withU32((u32)$01010603)); // requestLegacyExternalStorage
        a.add((Object*)Number.withU32((u32)$0101066C)); // enableOnBackInvokedCallback
        return a;
        }
    static i32 settableIndex(String* name)
        {
        Array* n = settableNames();
        for (u32 i = (u32)0; i < n.count(); i = i + (u32)1)
            if (((String*)n.get(i)).equals(name))
                return (i32)i;
        return (i32)-1;
        }

    // `--manifest-attr name=value`: 0 when the writer can set it on
    // <application>, else the error to report.
    static String* manifestAttrError(String* spec)
        {
        u32 eq = spec.byteIndexOf(String.withCString("="));
        if (eq == (u32)$FFFFFFFF || eq == (u32)0)
            {
            String* m = String.withCString("--manifest-attr wants name=value, not '");
            m.append(spec);
            m.appendCString("'");
            return m;
            }
        String* k = spec.substringBytes((u32)0, eq);
        String* v = spec.substringFromByte(eq + (u32)1);
        i32 at = settableIndex(k);
        if (at < (i32)0)
            {
            String* m = String.withCString("--manifest-attr: <application> has no attribute '");
            m.append(k);
            m.appendCString("' it can set; it takes ");
            Array* n = settableNames();
            for (u32 i = (u32)0; i < n.count(); i = i + (u32)1)
                {
                if (i > (u32)0) m.appendCString(", ");
                m.append((String*)n.get(i));
                }
            return m;
            }
        if (at > (i32)0 && !v.equals(String.withCString("true")) && !v.equals(String.withCString("false")))
            {
            String* m = String.withCString("--manifest-attr: ");
            m.append(k);
            m.appendCString(" takes true or false, not '");
            m.append(v);
            m.appendCString("'");
            return m;
            }
        return (String*)0;
        }

    static void attr(Array* d, u32 ns, u32 name, u32 raw, u32 ty, u32 data)
        {
        apkW32(d, ns);
        apkW32(d, name);
        apkW32(d, raw);
        apkW16(d, (u32)8);
        apkW8(d, (u32)0);
        apkW8(d, ty);
        apkW32(d, data);
        }

    static Array* apkRow(u32 id, u32 name, u32 raw, u32 ty, u32 data)
        {
        Array* r = new Array();
        r.add((Object*)Number.withU32(id));
        r.add((Object*)Number.withU32(name));
        r.add((Object*)Number.withU32(raw));
        r.add((Object*)Number.withU32(ty));
        r.add((Object*)Number.withU32(data));
        return r;
        }

    static void startElem(Array* out, u32 nsIdx, u32 nameIdx, Array* attrs, u32 n)
        {
        apkW16(out, (u32)$0102); // RES_XML_START_ELEM
        apkW16(out, (u32)16);
        apkW32(out, (u32)36 + attrs.count());
        apkW32(out, (u32)0);         // lineNumber
        apkW32(out, (u32)$FFFFFFFF); // comment
        apkW32(out, nsIdx);
        apkW32(out, nameIdx);
        apkW16(out, (u32)20); // attributeStart
        apkW16(out, (u32)20); // attributeSize
        apkW16(out, n);
        apkW16(out, (u32)0);
        apkW16(out, (u32)0);
        apkW16(out, (u32)0);
        apkAppend(out, attrs);
        }

    static void endElem(Array* out, u32 nsIdx, u32 nameIdx)
        {
        apkW16(out, (u32)$0103); // RES_XML_END_ELEM
        apkW16(out, (u32)16);
        apkW32(out, (u32)24);
        apkW32(out, (u32)0);
        apkW32(out, (u32)$FFFFFFFF);
        apkW32(out, nsIdx);
        apkW32(out, nameIdx);
        }

    // `hasCode` must be true whenever a classes.dex rides: ART SKIPS the dex
    // entirely when the manifest says false, which is indistinguishable from a
    // dex that failed to load (uxkit/031).
    static Array* manifest(String* pkg, String* libName, String* label,
                           u32 minSdk, u32 targetSdk, bool hasCode, Array* extras)
        {
        // --manifest-attr name=value, checked by manifestAttrError (a later
        // one wins). `label` replaces the default label, on the activity too,
        // which is the name the launcher shows; every other one joins
        // <application>.
        Map* set = new Map();
        Array* order = new Array();
        for (u32 i = (u32)0; i < extras.count(); i = i + (u32)1)
            {
            String* e = (String*)extras.get(i);
            u32 eq = e.byteIndexOf(String.withCString("="));
            String* k = e.substringBytes((u32)0, eq);
            if (set.get((Hashable*)k) == (Object*)0) order.add((Object*)k);
            set.set((Hashable*)k, (Object*)e.substringFromByte(eq + (u32)1));
            }
        if (set.get((Hashable*)String.withCString("label")) != (Object*)0)
            label = (String*)set.get((Hashable*)String.withCString("label"));
        // The attribute table: the eight this manifest always uses, and the
        // extras, in ascending resource-id order (the resource map is
        // positional).
        Array* tNames = attrNames();
        Array* tIds = attrIds();
        Array* appExtras = new Array(); // indices into the settable table
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            String* k = (String*)order.get(i);
            if (k.equals(String.withCString("label"))) continue;
            i32 at = settableIndex(k);
            tNames.add((Object*)k);
            tIds.add(settableIds().get((u32)at));
            appExtras.add((Object*)Number.withU32((u32)at));
            }
        for (u32 i = (u32)1; i < tIds.count(); i = i + (u32)1)
            for (u32 j = i; j > (u32)0 && ((Number*)tIds.get(j - (u32)1)).asU32() > ((Number*)tIds.get(j)).asU32(); j = j - (u32)1)
                {
                Object* x = tIds.get(j); tIds.set(j, tIds.get(j - (u32)1)); tIds.set(j - (u32)1, x);
                Object* y = tNames.get(j); tNames.set(j, tNames.get(j - (u32)1)); tNames.set(j - (u32)1, y);
                }
        ApkPool* p = new ApkPool();
        for (u32 i = (u32)0; i < tNames.count(); i = i + (u32)1)
            p.intern((String*)tNames.get(i)); // indices 0..n-1, in order

        String* NS = String.withCString("http://schemas.android.com/apk/res/android");
        u32 sManifest = p.intern(String.withCString("manifest"));
        u32 sUsesSdk = p.intern(String.withCString("uses-sdk"));
        u32 sApp = p.intern(String.withCString("application"));
        u32 sActivity = p.intern(String.withCString("activity"));
        u32 sMeta = p.intern(String.withCString("meta-data"));
        u32 sFilter = p.intern(String.withCString("intent-filter"));
        u32 sAction = p.intern(String.withCString("action"));
        u32 sCategory = p.intern(String.withCString("category"));
        u32 sAndroid = p.intern(String.withCString("android"));
        u32 sNsUri = p.intern(NS);
        u32 sPackage = p.intern(String.withCString("package"));
        u32 sPkg = p.intern(pkg);
        u32 sLabel = p.intern(label);
        u32 sLib = p.intern(libName);
        u32 sNative = p.intern(String.withCString("android.app.NativeActivity"));
        u32 sLibName = p.intern(String.withCString("android.app.lib_name"));
        u32 sMain = p.intern(String.withCString("android.intent.action.MAIN"));
        u32 sLauncher = p.intern(String.withCString("android.intent.category.LAUNCHER"));

        u32 NONE = (u32)$FFFFFFFF;
        u32 T_STR = (u32)$03;
        u32 T_DEC = (u32)$10;
        u32 T_BOOL = (u32)$12;
        u32 aLabel = p.intern(String.withCString("label"));
        u32 aName = p.intern(String.withCString("name"));
        u32 aHasCode = p.intern(String.withCString("hasCode"));
        u32 aExported = p.intern(String.withCString("exported"));
        u32 aValue = p.intern(String.withCString("value"));
        u32 aMinSdk = p.intern(String.withCString("minSdkVersion"));
        u32 aTgtSdk = p.intern(String.withCString("targetSdkVersion"));
        u32 aExtract = p.intern(String.withCString("extractNativeLibs"));

        Array* body = new Array();
        // namespace open
        apkW16(body, (u32)$0100);
        apkW16(body, (u32)16);
        apkW32(body, (u32)24);
        apkW32(body, (u32)0);
        apkW32(body, NONE);
        apkW32(body, sAndroid);
        apkW32(body, sNsUri);

        Array* a = new Array();
        attr(a, NONE, sPackage, sPkg, T_STR, sPkg);
        startElem(body, NONE, sManifest, a, (u32)1);

        a = new Array();
        attr(a, sNsUri, aMinSdk, NONE, T_DEC, minSdk);
        attr(a, sNsUri, aTgtSdk, NONE, T_DEC, targetSdk);
        startElem(body, NONE, sUsesSdk, a, (u32)2);
        endElem(body, NONE, sUsesSdk);

        // Every attribute in ascending resource-id order: label, hasCode,
        // extractNativeLibs and the extras. Each row: id, name, raw, type, data.
        Array* rows = new Array();
        rows.add((Object*)apkRow((u32)$01010001, aLabel, sLabel, T_STR, sLabel));
        rows.add((Object*)apkRow((u32)$0101000C, aHasCode, NONE, T_BOOL, hasCode ? (u32)$FFFFFFFF : (u32)0));
        rows.add((Object*)apkRow((u32)$010104EA, aExtract, NONE, T_BOOL, (u32)$FFFFFFFF));
        for (u32 i = (u32)0; i < appExtras.count(); i = i + (u32)1)
            {
            u32 at = ((Number*)appExtras.get(i)).asU32();
            String* k = (String*)settableNames().get(at);
            u32 id = ((Number*)settableIds().get(at)).asU32();
            String* v = (String*)set.get((Hashable*)k);
            u32 nameIdx = p.intern(k);
            if (at > (u32)0)
                rows.add((Object*)apkRow(id, nameIdx, NONE, T_BOOL, v.equals(String.withCString("true")) ? (u32)$FFFFFFFF : (u32)0));
            else
                {
                u32 sv = p.intern(v);
                rows.add((Object*)apkRow(id, nameIdx, sv, T_STR, sv));
                }
            }
        for (u32 i = (u32)1; i < rows.count(); i = i + (u32)1)
            for (u32 j = i; j > (u32)0 && ((Number*)((Array*)rows.get(j - (u32)1)).get((u32)0)).asU32() > ((Number*)((Array*)rows.get(j)).get((u32)0)).asU32(); j = j - (u32)1)
                {
                Object* x = rows.get(j); rows.set(j, rows.get(j - (u32)1)); rows.set(j - (u32)1, x);
                }
        a = new Array();
        for (u32 i = (u32)0; i < rows.count(); i = i + (u32)1)
            {
            Array* r = (Array*)rows.get(i);
            attr(a, sNsUri, ((Number*)r.get((u32)1)).asU32(), ((Number*)r.get((u32)2)).asU32(),
                 ((Number*)r.get((u32)3)).asU32(), ((Number*)r.get((u32)4)).asU32());
            }
        startElem(body, NONE, sApp, a, rows.count());

        a = new Array();
        attr(a, sNsUri, aLabel, sLabel, T_STR, sLabel);
        attr(a, sNsUri, aName, sNative, T_STR, sNative);
        attr(a, sNsUri, aExported, NONE, T_BOOL, (u32)$FFFFFFFF);
        startElem(body, NONE, sActivity, a, (u32)3);

        a = new Array();
        attr(a, sNsUri, aName, sLibName, T_STR, sLibName);
        attr(a, sNsUri, aValue, sLib, T_STR, sLib);
        startElem(body, NONE, sMeta, a, (u32)2);
        endElem(body, NONE, sMeta);

        startElem(body, NONE, sFilter, new Array(), (u32)0);
        a = new Array();
        attr(a, sNsUri, aName, sMain, T_STR, sMain);
        startElem(body, NONE, sAction, a, (u32)1);
        endElem(body, NONE, sAction);
        a = new Array();
        attr(a, sNsUri, aName, sLauncher, T_STR, sLauncher);
        startElem(body, NONE, sCategory, a, (u32)1);
        endElem(body, NONE, sCategory);
        endElem(body, NONE, sFilter);

        endElem(body, NONE, sActivity);
        endElem(body, NONE, sApp);
        endElem(body, NONE, sManifest);
        // namespace close
        apkW16(body, (u32)$0101);
        apkW16(body, (u32)16);
        apkW32(body, (u32)24);
        apkW32(body, (u32)0);
        apkW32(body, NONE);
        apkW32(body, sAndroid);
        apkW32(body, sNsUri);

        Array* pool = p.chunk();
        Array* ids = tIds;
        Array* map = new Array();
        apkW16(map, (u32)$0180); // RES_XML_RESOURCE_MAP
        apkW16(map, (u32)8);
        apkW32(map, (u32)8 + (u32)4 * ids.count());
        for (u32 i = (u32)0; i < ids.count(); i = i + (u32)1)
            apkW32(map, ((Number*)ids.get(i)).asU32());

        Array* out = new Array();
        apkW16(out, (u32)$0003); // RES_XML
        apkW16(out, (u32)8);
        apkW32(out, (u32)8 + pool.count() + map.count() + body.count());
        apkAppend(out, pool);
        apkAppend(out, map);
        apkAppend(out, body);
        return out;
        }
    }

    // ── the ZIP ──────────────────────────────────────────────────────────────
    class ApkEntry
    {
    String* name;
    Array* data; // Number@ bytes
    static ApkEntry* with(String* n, Array* d)
        {
        ApkEntry* e = new ApkEntry();
        e.name = n;
        e.data = d;
        return e;
        }
    void init(void)
        {
        }
    }

    class ApkZip
    {
    // Every entry is STORED. Alignment padding goes in the local header's
    // EXTRA field so the file never has to be rewritten — which is all
    // zipalign does, after the fact.
    //
    // A library the loader mmaps needs the full page alignment; everything else
    // still gets 4, which is what `zipalign -c -p 4` checks. Aligning only the
    // .so left the manifest and the dex at odd offsets, and every package this
    // writer produced failed that check.
    static Array* build(Array* entries, u32 alignment, String* alignSuffix)
        {
        Array* out = new Array();
        Array* central = new Array();
        u32 count = (u32)0;

        for (u32 i = (u32)0; i < entries.count(); i = i + (u32)1)
            {
            ApkEntry* e = (ApkEntry*)entries.get(i);
            u32 crc = Crc32.of(e.data);
            u32 localOff = out.count();
            u32 nameLen = e.name.byteLength();

            u32 want = (u32)4;
            if (alignSuffix != (String*)0 && alignment > (u32)1 && e.name.hasSuffix(alignSuffix))
                want = alignment;
            u32 extraLen = (u32)0;
            if (want > (u32)1)
                {
                u32 dataAt = localOff + (u32)30 + nameLen;
                extraLen = (want - (dataAt % want)) % want;
                }

            apkW32(out, (u32)$04034B50); // local file header
            apkW16(out, (u32)20);        // version needed
            apkW16(out, (u32)0);         // flags
            apkW16(out, (u32)0);         // method 0 = stored
            // Fixed mtime/mdate, so two builds of one input give one file.
            apkW16(out, (u32)0);
            apkW16(out, (u32)0);
            apkW32(out, crc);
            apkW32(out, e.data.count());
            apkW32(out, e.data.count());
            apkW16(out, nameLen);
            apkW16(out, extraLen);
            for (u32 c = (u32)0; c < nameLen; c = c + (u32)1)
                apkW8(out, (u32)e.name.byteAt(c));
            for (u32 c = (u32)0; c < extraLen; c = c + (u32)1)
                apkW8(out, (u32)0);
            apkAppend(out, e.data);

            apkW32(central, (u32)$02014B50); // central directory entry
            apkW16(central, (u32)20);
            apkW16(central, (u32)20);
            apkW16(central, (u32)0);
            apkW16(central, (u32)0);
            apkW16(central, (u32)0);
            apkW16(central, (u32)0);
            apkW32(central, crc);
            apkW32(central, e.data.count());
            apkW32(central, e.data.count());
            apkW16(central, nameLen);
            apkW16(central, (u32)0); // extra (central copy)
            apkW16(central, (u32)0); // comment
            apkW16(central, (u32)0); // disk
            apkW16(central, (u32)0); // internal attrs
            apkW32(central, (u32)0); // external attrs
            apkW32(central, localOff);
            for (u32 c = (u32)0; c < nameLen; c = c + (u32)1)
                apkW8(central, (u32)e.name.byteAt(c));
            count = count + (u32)1;
            }

        u32 centralOff = out.count();
        apkAppend(out, central);
        apkW32(out, (u32)$06054B50); // end of central directory
        apkW16(out, (u32)0);
        apkW16(out, (u32)0);
        apkW16(out, count);
        apkW16(out, count);
        apkW32(out, central.count());
        apkW32(out, centralOff);
        apkW16(out, (u32)0); // comment length
        return out;
        }
    }
