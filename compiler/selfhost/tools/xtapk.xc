// xtapk.xc — the ported APK writer, as a standalone tool.
//
//   xtapk manifest <pkg> <lib> <label> <hasCode 0|1> -o out.bin
//   xtapk zip <name>=<file> [...] -o out.apk
//
// It exists so the port's bytes can be compared against the reference's
// directly, before any of it is wired into the driver — the same reason every
// other stage has a differential.
#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "Apk.xc"
#import "ApkSign.xc"

void writeBytes(String* path, Array* bytes)
    {
    Data* d = Data.withCapacity((u32)0);
    for (u32 i = (u32)0; i < bytes.count(); i = i + (u32)1)
        d.appendByte((u8)((Number*)bytes.get(i)).asU32());
    Files.writeData(path, d);
    }

// The debug key, from the raw sidecar both drivers share:
//   "XKEY1" then four little-endian length-prefixed blobs: n, e, d, cert.
Array* readKeyField(Data* d, u32* at)
    {
    u32 p = *at;
    u32 n = (u32)d.byteAt(p) | ((u32)d.byteAt(p + (u32)1) << (u32)8) | ((u32)d.byteAt(p + (u32)2) << (u32)16) | ((u32)d.byteAt(p + (u32)3) << (u32)24);
    p = p + (u32)4;
    Array* out = new Array();
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        out.add((Object*)Number.withU32((u32)d.byteAt(p + i)));
    *at = p + n;
    return out;
    }

void main(void)
    {
    u32 argc = Process.argumentCount();
    if (argc < (u32)2)
        {
        Stdio.printf("usage: xtapk manifest|zip ...\n");
        Process.exit((i32)1);
        return;
        }
    String* mode = Process.argument((u32)1);
    String* out = String.withCString("");
    for (u32 i = (u32)2; i + (u32)1 < argc; i = i + (u32)1)
        if (Process.argument(i).equals(String.withCString("-o")))
            out = Process.argument(i + (u32)1);
    if (out.byteLength() == (u32)0)
        {
        Stdio.printf("xtapk: -o required\n");
        Process.exit((i32)1);
        return;
        }

    if (mode.equals(String.withCString("manifest")))
        {
        if (argc < (u32)6)
            {
            Stdio.printf("xtapk: manifest wants pkg lib label hasCode\n");
            Process.exit((i32)1);
            return;
            }
        bool hasCode = Process.argument((u32)5).equals(String.withCString("1"));
        Array* m = ApkXml.manifest(Process.argument((u32)2), Process.argument((u32)3),
                                   Process.argument((u32)4), (u32)24, (u32)35, hasCode);
        writeBytes(out, m);
        return;
        }
    if (mode.equals(String.withCString("zip")))
        {
        Array* entries = new Array();
        for (u32 i = (u32)2; i < argc; i = i + (u32)1)
            {
            String* a = Process.argument(i);
            if (a.equals(String.withCString("-o")))
                {
                i = i + (u32)1;
                continue;
                }
            u32 eq = a.byteIndexOf(String.withCString("="));
            if (eq == String.notFound())
                continue;
            String* nm = a.substringToByte(eq);
            String* fp = a.substringFromByte(eq + (u32)1);
            Data* d = Files.readData(fp);
            if (d == (Data*)0)
                {
                Stdio.printf("xtapk: cannot read '%s'\n", fp.cString());
                Process.exit((i32)1);
                return;
                }
            Array* bytes = new Array();
            for (u32 b = (u32)0; b < d.length(); b = b + (u32)1)
                bytes.add((Object*)Number.withU32((u32)d.byteAt(b)));
            entries.add((Object*)ApkEntry.with(nm, bytes));
            }
        Array* zip = ApkZip.build(entries, (u32)4096, String.withCString(".so"));
        // Sign it, if the shared debug key is there. An UNSIGNED apk will not
        // install, so a missing key is a loud refusal rather than a file that
        // looks finished.
        // The key path is given, not discovered: the port has no getenv, so
        // there is no HOME to resolve. Wiring this into the driver needs either
        // a runtime getenv or an explicit flag — noted rather than guessed.
        String* kp = String.withCString("");
        for (u32 i = (u32)2; i + (u32)1 < argc; i = i + (u32)1)
            if (Process.argument(i).equals(String.withCString("-key")))
                kp = Process.argument(i + (u32)1);
        if (kp.byteLength() == (u32)0)
            {
            Stdio.printf("xtapk: zip needs -key <android-debug.key.raw>\n");
            Process.exit((i32)1);
            return;
            }
        Data* kd = Files.readData(kp);
        if (kd == (Data*)0 || kd.length() < (u32)5)
            {
            Stdio.printf("xtapk: no signing key at %s\n", kp.cString());
            Process.exit((i32)1);
            return;
            }
        u32 at = (u32)5; // past "XKEY1"
        Array* kn = readKeyField(kd, &at);
        Array* ke = readKeyField(kd, &at);
        Array* kdd = readKeyField(kd, &at);
        Array* kc = readKeyField(kd, &at);
        Array* signed_ = ApkSign.sign(zip, kc, kn, ke, kdd);
        if (signed_.count() == (u32)0)
            {
            Stdio.printf("xtapk: signing failed\n");
            Process.exit((i32)1);
            return;
            }
        writeBytes(out, signed_);
        return;
        }
    Stdio.printf("xtapk: unknown mode '%s'\n", mode.cString());
    Process.exit((i32)1);
    }
