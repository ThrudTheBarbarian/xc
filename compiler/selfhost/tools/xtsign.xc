// xtsign — identity code signing for Mach-O, the self-hosted xcc-sign
// (docs/mobile/signing.md). The Mac-free half: given an identity bundle
// (`xcc-sign --export-identity` / `--fetch-identity` output) it replaces a
// binary's ad-hoc signature with the developer signature — DER, CMS, RSA and
// the Mach-O splice all in xtc. Exporting from a keychain and fetching from
// App Store Connect stay with the reference tool: both are host APIs.
//
//   xtsign --identity <identity.pem> [--passphrase <p>] [--entitlements <ent.plist>]
//          [--identifier <id>] <macho> [<out>]

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "PlatformCore.xc"
#import "CodeSign.xc"

void usage(void)
    {
    Stdio.error(String.withCString(
        "usage: xtsign --identity <identity.pem> [--passphrase <p>] [--entitlements <ent.plist>]\n"
        "              [--identifier <id>] <macho> [<out>]\n"
        "       xtsign --seal-resources <app.dir> --resource <rel>...   (write _CodeSignature/CodeResources)\n"
        "              sign flags: [--info-plist <p>] [--code-resources <p>] for CD bundle slots 1/3\n"
        "       (--export-identity / --fetch-identity: use xcc-sign — they need the host's keychain / TLS)\n"));
    }

void main(void)
    {
    String* identityPath = (String*)0;
    String* entPath = (String*)0;
    String* identifier = (String*)0;
    String* inPath = (String*)0;
    String* outPath = (String*)0;
    String* passphrase = (String*)0;
    String* sealBundle = (String*)0;
    Array* sealResources = new Array();
    String* infoPlistPath = (String*)0;
    String* codeResourcesPath = (String*)0;
    u32 argc = Process.argumentCount();
    for (u32 i = (u32)1; i < argc; i = i + (u32)1)
        {
        String* a = Process.argument(i);
        if (a.equals(String.withCString("--seal-resources")) && i + (u32)1 < argc)
            {
            sealBundle = Process.argument(i + (u32)1);
            i = i + (u32)1;
            }
        else if (a.equals(String.withCString("--resource")) && i + (u32)1 < argc)
            {
            sealResources.add((Object*)Process.argument(i + (u32)1));
            i = i + (u32)1;
            }
        else if (a.equals(String.withCString("--info-plist")) && i + (u32)1 < argc)
            {
            infoPlistPath = Process.argument(i + (u32)1);
            i = i + (u32)1;
            }
        else if (a.equals(String.withCString("--code-resources")) && i + (u32)1 < argc)
            {
            codeResourcesPath = Process.argument(i + (u32)1);
            i = i + (u32)1;
            }
        else if (a.equals(String.withCString("--identity")) && i + (u32)1 < argc)
            {
            identityPath = Process.argument(i + (u32)1);
            i = i + (u32)1;
            }
        else if (a.equals(String.withCString("--entitlements")) && i + (u32)1 < argc)
            {
            entPath = Process.argument(i + (u32)1);
            i = i + (u32)1;
            }
        else if (a.equals(String.withCString("--identifier")) && i + (u32)1 < argc)
            {
            identifier = Process.argument(i + (u32)1);
            i = i + (u32)1;
            }
        else if (a.equals(String.withCString("--passphrase")) && i + (u32)1 < argc)
            {
            passphrase = Process.argument(i + (u32)1);
            i = i + (u32)1;
            }
        else if (a.equals(String.withCString("--export-identity")) || a.equals(String.withCString("--fetch-identity")))
            {
            Stdio.error(String.withCString("xtsign: that needs the host's keychain or App Store Connect — use xcc-sign for it\n"));
            Process.exit((i32)2);
            return;
            }
        else if (a.hasPrefix(String.withCString("-")))
            {
            usage();
            Process.exit((i32)2);
            return;
            }
        else if (inPath == (String*)0)
            inPath = a;
        else if (outPath == (String*)0)
            outPath = a;
        }
    // ── Seal an app bundle's resources into _CodeSignature/CodeResources. ──
    if (sealBundle != (String*)0)
        {
        if (sealResources.count() == (u32)0)
            {
            Stdio.error(String.withCString("xtsign: --seal-resources needs at least one --resource <rel>\n"));
            Process.exit((i32)2);
            return;
            }
        Array* contents = new Array();
        for (u32 i = (u32)0; i < sealResources.count(); i = i + (u32)1)
            {
            String* rel = (String*)sealResources.get(i);
            String* p = String.withString(sealBundle);
            p.appendCString("/");
            p.append(rel);
            Data* d = Files.readData(p);
            if (d == (Data*)0)
                {
                Stdio.printf("xtsign: cannot read resource '%s'\n", p.cString());
                Process.exit((i32)1);
                return;
                }
            contents.add((Object*)Bytes.fromData(d));
            }
        String* cr = CodeRes.build(sealResources, contents);
        String* csDir = String.withString(sealBundle);
        csDir.appendCString("/_CodeSignature");
        Files.createDirectory(csDir);
        String* crPath = String.withString(csDir);
        crPath.appendCString("/CodeResources");
        if (!Files.writeText(crPath, cr))
            {
            Stdio.printf("xtsign: cannot write '%s'\n", crPath.cString());
            Process.exit((i32)1);
            return;
            }
        Process.exit((i32)0);
        return;
        }
    if (passphrase == (String*)0)
        {
        String* env = Platform.env(String.withCString("XCC_SIGN_PASSPHRASE"));
        if (env != 0 && env.byteLength() > (u32)0)
            passphrase = env;
        }
    if (identityPath == (String*)0 || inPath == (String*)0)
        {
        usage();
        Process.exit((i32)2);
        return;
        }
    if (outPath == (String*)0)
        outPath = inPath;
    if (identifier == (String*)0)
        identifier = inPath.lastPathComponent();
    String* pem = Files.readText(identityPath);
    if (pem == (String*)0)
        {
        Stdio.printf("xtsign: cannot read identity '%s'\n", identityPath.cString());
        Process.exit((i32)1);
        return;
        }
    Identity* id = Identity.fromPEM(pem, passphrase);
    if (id.why() != (String*)0)
        {
        Stdio.printf("xtsign: %s\n", id.why().cString());
        Process.exit((i32)1);
        return;
        }
    Data* md = Files.readData(inPath);
    if (md == (Data*)0)
        {
        Stdio.printf("xtsign: cannot read '%s'\n", inPath.cString());
        Process.exit((i32)1);
        return;
        }
    Array* ent = id.entitlements();
    if (entPath != (String*)0)
        {
        Data* ed = Files.readData(entPath);
        if (ed == (Data*)0)
            {
            Stdio.printf("xtsign: cannot read entitlements '%s'\n", entPath.cString());
            Process.exit((i32)1);
            return;
            }
        ent = Bytes.fromData(ed);
        }
    // Bundle-mode inputs (docs/ios/bundle-signing.md, Part B): hash the
    // Info.plist and CodeResources into CD special slots 1 and 3.
    Array* infoPlist = (Array*)0;
    Array* codeResources = (Array*)0;
    if (infoPlistPath != (String*)0)
        {
        Data* ipd = Files.readData(infoPlistPath);
        if (ipd == (Data*)0)
            {
            Stdio.printf("xtsign: cannot read info-plist '%s'\n", infoPlistPath.cString());
            Process.exit((i32)1);
            return;
            }
        infoPlist = Bytes.fromData(ipd);
        }
    if (codeResourcesPath != (String*)0)
        {
        Data* crd = Files.readData(codeResourcesPath);
        if (crd == (Data*)0)
            {
            Stdio.printf("xtsign: cannot read code-resources '%s'\n", codeResourcesPath.cString());
            Process.exit((i32)1);
            return;
            }
        codeResources = Bytes.fromData(crd);
        }
    CodeSign* cs = new CodeSign();
    Array* signedImg = cs.resign(Bytes.fromData(md), identifier, id, ent, infoPlist, codeResources, String.withCString("20260101000000Z"));
    if (signedImg == (Array*)0)
        {
        Stdio.printf("xtsign: signing failed: %s\n", cs.why().cString());
        Process.exit((i32)1);
        return;
        }
    if (!Files.writeData(outPath, Bytes.toData(signedImg)))
        {
        Stdio.printf("xtsign: cannot write '%s'\n", outPath.cString());
        Process.exit((i32)1);
        return;
        }
    Files.setExecutable(outPath);
    }
