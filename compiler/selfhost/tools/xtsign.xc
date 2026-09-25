// xtsign — xcc-sign, the developer code signer (docs/mobile/signing.md).
//
// Replaces a Mach-O's ad-hoc signature with a developer one from a PEM
// identity bundle — DER, CMS, RSA and the Mach-O splice all in xtc, on any
// host. It also makes those bundles:
//
//   --export-identity   from the macOS keychain (Security framework; built
//                       with -DXT_HAVE_KEYCHAIN=1)
//   --fetch-identity    from App Store Connect over HTTPS (the 3p tls module;
//                       built with -DXT_HAVE_TLS=1), with --list-certs and
//                       --revoke-cert to manage the account's certificates
//
// A build without one of those says so when the flag is used.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "PlatformCore.xc"
#import "CodeSign.xc"
#if XT_HAVE_KEYCHAIN
#import "Keychain.xc"
#endif
#if XT_HAVE_TLS
#import "Asc.xc"
#endif

void usage(void)
    {
    Stdio.error(String.withCString(
        "usage: xcc-sign --identity <identity.pem> [--entitlements <ent.plist>]\n"
        "                [--identifier <id>] [--info-plist <p>] [--code-resources <p>] <macho> [<out>]\n"
        "       xcc-sign --seal-resources <app.dir> --resource <rel>...\n"
        "       xcc-sign --export-identity <name> -o <identity.pem>\n"
        "                [--keychain <path>] [--profile <mobileprovision>]  (macOS)\n"
        "       xcc-sign --fetch-identity -o <identity.pem> --passphrase <p>\n"
        "                --asc-issuer <id> --asc-key-id <kid> --asc-key <AuthKey.p8>\n"
        "                [--profile-name <substr>]   (Route 1: App Store Connect)\n"));
    }

// `xcc-sign: <a><b><c>` on stderr.
void say(string a, String* b, string c)
    {
    String* m = String.withCString("xcc-sign: ");
    m.appendCString(a);
    if (b != (String*)0)
        m.append(b);
    m.appendCString(c);
    m.appendCString("\n");
    Stdio.error(m);
    }

// dir/name with runs of '/' collapsed and no trailing one: the path the
// reference prints, since it joins with stringByAppendingPathComponent.
String* joinPath(String* dir, String* name)
    {
    String* raw = String.withString(dir);
    raw.appendCString("/");
    raw.append(name);
    String* out = String.withCString("");
    for (u32 i = (u32)0; i < raw.byteLength(); i = i + (u32)1)
        {
        u8 c = raw.byteAt(i);
        if (c == (u8)'/' && out.byteLength() > (u32)0 && out.byteAt(out.byteLength() - (u32)1) == (u8)'/')
            continue;
        out.appendByte(c);
        }
    while (out.byteLength() > (u32)1 && out.byteAt(out.byteLength() - (u32)1) == (u8)'/')
        out = out.substringBytes((u32)0, out.byteLength() - (u32)1);
    return out;
    }

void main(void)
    {
    String* identityPath = (String*)0;
    String* entPath = (String*)0;
    String* identifier = (String*)0;
    String* inPath = (String*)0;
    String* outPath = (String*)0;
    String* exportName = (String*)0;
    String* keychainPath = (String*)0;
    String* profilePath = (String*)0;
    String* oPath = (String*)0;
    String* passphrase = (String*)0;
    String* ascIssuer = (String*)0;
    String* ascKeyId = (String*)0;
    String* ascKey = (String*)0;
    String* profileName = (String*)0;
    String* revokeId = (String*)0;
    String* sealBundle = (String*)0;
    String* infoPlistPath = (String*)0;
    String* codeResourcesPath = (String*)0;
    Array* sealResources = new Array();
    bool fetch = false;
    bool listCerts = false;
    u32 argc = Process.argumentCount();
    for (u32 i = (u32)1; i < argc; i = i + (u32)1)
        {
        String* a = Process.argument(i);
        bool more = i + (u32)1 < argc;
        String* v = more ? Process.argument(i + (u32)1) : (String*)0;
        if (more && a.equals(String.withCString("--identity")))
            identityPath = v;
        else if (more && a.equals(String.withCString("--entitlements")))
            entPath = v;
        else if (more && a.equals(String.withCString("--identifier")))
            identifier = v;
        else if (more && a.equals(String.withCString("--export-identity")))
            exportName = v;
        else if (more && a.equals(String.withCString("--keychain")))
            keychainPath = v;
        else if (more && a.equals(String.withCString("--profile")))
            profilePath = v;
        else if (more && a.equals(String.withCString("--passphrase")))
            passphrase = v;
        else if (a.equals(String.withCString("--fetch-identity")))
            {
            fetch = true;
            continue;
            }
        else if (a.equals(String.withCString("--list-certs")))
            {
            listCerts = true;
            continue;
            }
        else if (more && a.equals(String.withCString("--revoke-cert")))
            revokeId = v;
        else if (more && a.equals(String.withCString("--asc-issuer")))
            ascIssuer = v;
        else if (more && a.equals(String.withCString("--asc-key-id")))
            ascKeyId = v;
        else if (more && a.equals(String.withCString("--asc-key")))
            ascKey = v;
        else if (more && a.equals(String.withCString("--profile-name")))
            profileName = v;
        else if (more && a.equals(String.withCString("-o")))
            oPath = v;
        else if (more && a.equals(String.withCString("--seal-resources")))
            sealBundle = v;
        else if (more && a.equals(String.withCString("--resource")))
            sealResources.add((Object*)v);
        else if (more && a.equals(String.withCString("--info-plist")))
            infoPlistPath = v;
        else if (more && a.equals(String.withCString("--code-resources")))
            codeResourcesPath = v;
        else if (a.hasPrefix(String.withCString("-")))
            {
            say("unknown option ", a, "");
            usage();
            Process.exit((i32)2);
            return;
            }
        else
            {
            if (inPath == (String*)0)
                inPath = a;
            else if (outPath == (String*)0)
                outPath = a;
            continue;
            }
        i = i + (u32)1; // the option's value
        }

    // The passphrase may also come from the environment, so it need not appear
    // in the process table or the shell history.
    // (The runtime reports an unset variable as empty, so empty means unset.)
    if (passphrase == (String*)0)
        {
        String* env = Platform.env(String.withCString("XCC_SIGN_PASSPHRASE"));
        if (env != (String*)0 && env.byteLength() > (u32)0)
            passphrase = env;
        }

    // ── Seal an app bundle's resources into _CodeSignature/CodeResources. ──
    if (sealBundle != (String*)0)
        {
        if (sealResources.count() == (u32)0)
            {
            say("--seal-resources needs at least one --resource <rel>", (String*)0, "");
            Process.exit((i32)2);
            return;
            }
        Array* contents = new Array();
        for (u32 i = (u32)0; i < sealResources.count(); i = i + (u32)1)
            {
            String* p = joinPath(sealBundle, (String*)sealResources.get(i));
            Data* d = Files.readData(p);
            if (d == (Data*)0)
                {
                say("cannot read resource '", p, "'");
                Process.exit((i32)1);
                return;
                }
            contents.add((Object*)Bytes.fromData(d));
            }
        String* cr = CodeRes.build(sealResources, contents);
        String* csDir = joinPath(sealBundle, String.withCString("_CodeSignature"));
        Files.createDirectory(csDir);
        String* crPath = joinPath(csDir, String.withCString("CodeResources"));
        if (!Files.writeText(crPath, cr))
            {
            say("cannot write '", crPath, "'");
            Process.exit((i32)1);
            return;
            }
        Process.exit((i32)0);
        return;
        }

    // ── Route 1 admin: list / revoke certificates. ──
    if (listCerts || revokeId != (String*)0)
        {
#if XT_HAVE_TLS
        if (ascIssuer == (String*)0 || ascKeyId == (String*)0 || ascKey == (String*)0)
            {
            say("--list-certs/--revoke-cert need --asc-issuer, --asc-key-id, --asc-key", (String*)0, "");
            Process.exit((i32)2);
            return;
            }
        Process.exit(AscTool.admin(ascIssuer, ascKeyId, ascKey, listCerts, revokeId));
        return;
#else
        say("--list-certs/--revoke-cert need a TLS build", (String*)0, "");
        Process.exit((i32)2);
        return;
#endif
        }

    // ── Route 1: fetch an identity from App Store Connect. ──
    if (fetch)
        {
#if XT_HAVE_TLS
        if (oPath == (String*)0 || ascIssuer == (String*)0 || ascKeyId == (String*)0 || ascKey == (String*)0)
            {
            say("--fetch-identity needs -o, --asc-issuer, --asc-key-id, --asc-key", (String*)0, "");
            Process.exit((i32)2);
            return;
            }
        if (passphrase == (String*)0)
            {
            say("--fetch-identity needs --passphrase (or $XCC_SIGN_PASSPHRASE) to protect the fetched key", (String*)0, "");
            Process.exit((i32)2);
            return;
            }
        Process.exit(AscTool.fetchIdentity(ascIssuer, ascKeyId, ascKey, profileName, passphrase, oPath));
        return;
#else
        say("--fetch-identity needs a TLS build (rebuild with Mbed TLS; see MBEDTLS_PREFIX)", (String*)0, "");
        Process.exit((i32)2);
        return;
#endif
        }

    // ── Route 2: export a keychain identity into a PEM bundle (macOS). ──
    if (exportName != (String*)0)
        {
        if (oPath == (String*)0)
            {
            say("--export-identity needs -o <identity.pem>", (String*)0, "");
            Process.exit((i32)2);
            return;
            }
        if (passphrase == (String*)0)
            {
            say("--export-identity needs --passphrase (or $XCC_SIGN_PASSPHRASE) to protect the key", (String*)0, "");
            Process.exit((i32)2);
            return;
            }
#if XT_HAVE_KEYCHAIN
        Keychain* kc = new Keychain();
        if (!kc.export(exportName, passphrase, keychainPath, profilePath, oPath))
            {
            say("", kc.why(), "");
            Process.exit((i32)1);
            return;
            }
        say("exported identity -> '", oPath, "'");
        Process.exit((i32)0);
        return;
#else
        say("--export-identity is macOS-only (it reads the Security-framework keychain)", (String*)0, "");
        Process.exit((i32)1);
        return;
#endif
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
        say("cannot read identity '", identityPath, "'");
        Process.exit((i32)1);
        return;
        }
    Identity* id = Identity.fromPEM(pem, passphrase);
    if (id.why() != (String*)0)
        {
        say("", id.why(), "");
        Process.exit((i32)1);
        return;
        }
    Data* md = Files.readData(inPath);
    if (md == (Data*)0)
        {
        say("cannot read '", inPath, "'");
        Process.exit((i32)1);
        return;
        }
    Array* ent = id.entitlements();
    if (entPath != (String*)0)
        {
        Data* ed = Files.readData(entPath);
        if (ed == (Data*)0)
            {
            say("cannot read entitlements '", entPath, "'");
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
            say("cannot read info-plist '", infoPlistPath, "'");
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
            say("cannot read code-resources '", codeResourcesPath, "'");
            Process.exit((i32)1);
            return;
            }
        codeResources = Bytes.fromData(crd);
        }
    // A fixed signing time keeps a re-sign reproducible; the CMS carries it.
    CodeSign* cs = new CodeSign();
    Array* signedImg = cs.resign(Bytes.fromData(md), identifier, id, ent, infoPlist, codeResources, String.withCString("20260101000000Z"));
    if (signedImg == (Array*)0)
        {
        say("signing failed: ", cs.why(), "");
        Process.exit((i32)1);
        return;
        }
    if (!Files.writeData(outPath, Bytes.toData(signedImg)))
        {
        say("cannot write '", outPath, "'");
        Process.exit((i32)1);
        return;
        }
    Files.setExecutable(outPath);
    }
