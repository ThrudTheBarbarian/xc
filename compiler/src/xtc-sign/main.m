//
//  xcc-sign — re-sign a Mach-O with a developer identity.
//
//  The last stage of the signing pipeline (docs/mobile/signing.md). Default
//  builds are ad-hoc signed by the Mach-O writer; this replaces that with a
//  developer signature, from a PEM identity bundle, on any host — no keychain,
//  no network, no Apple APIs.
//
//  Usage:
//    xcc-sign --identity <identity.pem> [--entitlements <ent.plist>]
//             [--identifier <id>] <macho> [<out>]
//
//  With no <out> the file is signed in place. --identifier defaults to the
//  binary's base name. Entitlements come from --entitlements, else from the
//  identity bundle if it carries them.
//
//  Route 2's Mac-side identity export (`--export-identity`) is a separate,
//  macOS-only stage; it is stubbed here so the flag is recognised.
//

#import <Foundation/Foundation.h>
#import "XTIdentity.h"
#import "XTCodeSign.h"
#import "XTCodeResources.h"
#import "XTIdentityExport.h"
#import "XTPkcs8.h"
#if XT_HAVE_TLS
#import "XTAscApi.h"
#endif

static void usage(void)
    {
    fprintf(stderr,
            "usage: xcc-sign --identity <identity.pem> [--entitlements <ent.plist>]\n"
            "                [--identifier <id>] [--info-plist <p>] [--code-resources <p>] <macho> [<out>]\n"
            "       xcc-sign --seal-resources <app.dir> --resource <rel>...\n"
            "       xcc-sign --export-identity <name> -o <identity.pem>\n"
            "                [--keychain <path>] [--profile <mobileprovision>]  (macOS)\n"
            "       xcc-sign --fetch-identity -o <identity.pem> --passphrase <p>\n"
            "                --asc-issuer <id> --asc-key-id <kid> --asc-key <AuthKey.p8>\n"
            "                [--profile-name <substr>]   (Route 1: App Store Connect)\n");
    }

#if XT_HAVE_TLS
// Route 1: generate a keypair + CSR, create an Apple Development certificate
// via the App Store Connect API, fetch the WWDR intermediate and (optionally) a
// provisioning profile, and write an encrypted PEM identity. Returns 0/1.
static int fetchIdentity(NSString* issuer, NSString* keyId, NSString* p8,
                         NSString* profileName, NSString* passphrase, NSString* out)
    {
    NSString* err = nil;
    XTAscApi* api = [[XTAscApi alloc] initWithIssuerId:issuer keyId:keyId p8Path:p8 error:&err];
    if (!api)
        {
        fprintf(stderr, "xcc-sign: %s\n", err.UTF8String);
        return 1;
        }

    NSData* keyDer = nil;
    NSString* csr = [api generateKeypairAndCSRWithCommonName:@"xcc Route 1"
                                                 keyPkcs1Der:&keyDer
                                                       error:&err];
    if (!csr)
        {
        fprintf(stderr, "xcc-sign: CSR: %s\n", err.UTF8String);
        return 1;
        }
    fprintf(stderr, "xcc-sign: creating an Apple Development certificate...\n");
    NSData* cert = [api createDevelopmentCertificate:csr error:&err];
    if (!cert)
        {
        fprintf(stderr, "xcc-sign: create cert: %s\n", err.UTF8String);
        if ([err containsString:@"already have"])
            fprintf(stderr, "xcc-sign: the account is at its Development-certificate limit; "
                            "revoke an unused one (developer.apple.com or the API) and retry.\n");
        return 1;
        }

    NSData* wwdr = [XTAscApi fetchAppleCA:@"AppleWWDRCAG3" error:&err];
    if (!wwdr)
        {
        fprintf(stderr, "xcc-sign: fetch WWDR: %s\n", err.UTF8String);
        return 1;
        }

    NSData* ent = nil;
    NSData* profile = [api fetchProfileMatching:profileName error:&err];
    if (profile)
        {
        ent = [XTAscApi entitlementsFromProfile:profile];
        fprintf(stderr, "xcc-sign: fetched provisioning profile (%lu bytes)%s\n",
                (unsigned long)profile.length, ent ? ", entitlements embedded" : "");
        }

    NSData* encKey = [XTPkcs8 encryptPrivateKey:keyDer passphrase:passphrase error:&err];
    if (!encKey)
        {
        fprintf(stderr, "xcc-sign: key encrypt: %s\n", err.UTF8String);
        return 1;
        }

    NSData* pem = [XTIdentity pemBundleWithLeaf:cert
                                          chain:@[ wwdr ]
                                       keyBlock:encKey
                                       keyLabel:@"ENCRYPTED PRIVATE KEY"
                                entitlementsXml:ent];
    if (![pem writeToFile:out atomically:YES])
        {
        fprintf(stderr, "xcc-sign: cannot write '%s'\n", out.UTF8String);
        return 1;
        }
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0600}
                                     ofItemAtPath:out
                                            error:NULL];
    fprintf(stderr, "xcc-sign: fetched identity -> '%s' (encrypted; sign with --passphrase)\n", out.UTF8String);
    return 0;
    }
#endif

int main(int argc, const char* argv[])
    {
    @autoreleasepool
        {
        NSString *identityPath = nil, *entPath = nil, *identifier = nil;
        NSString *inPath = nil, *outPath = nil;
        NSString *exportName = nil, *keychainPath = nil, *profilePath = nil, *oPath = nil;
        NSString* passphrase = nil;
        NSString *ascIssuer = nil, *ascKeyId = nil, *ascKey = nil, *profileName = nil;
        NSString* revokeId = nil;
        NSString* sealBundle = nil;
        NSString *infoPlistPath = nil, *codeResourcesPath = nil;
        NSMutableArray<NSString*>* sealResources = [NSMutableArray array];
        BOOL fetch = NO, listCerts = NO;
        for (int i = 1; i < argc; i++)
            {
            NSString* a = @(argv[i]);
            if ([a isEqualToString:@"--identity"] && i + 1 < argc)
                identityPath = @(argv[++i]);
            else if ([a isEqualToString:@"--entitlements"] && i + 1 < argc)
                entPath = @(argv[++i]);
            else if ([a isEqualToString:@"--identifier"] && i + 1 < argc)
                identifier = @(argv[++i]);
            else if ([a isEqualToString:@"--export-identity"] && i + 1 < argc)
                exportName = @(argv[++i]);
            else if ([a isEqualToString:@"--keychain"] && i + 1 < argc)
                keychainPath = @(argv[++i]);
            else if ([a isEqualToString:@"--profile"] && i + 1 < argc)
                profilePath = @(argv[++i]);
            else if ([a isEqualToString:@"--passphrase"] && i + 1 < argc)
                passphrase = @(argv[++i]);
            else if ([a isEqualToString:@"--fetch-identity"])
                fetch = YES;
            else if ([a isEqualToString:@"--list-certs"])
                listCerts = YES;
            else if ([a isEqualToString:@"--revoke-cert"] && i + 1 < argc)
                revokeId = @(argv[++i]);
            else if ([a isEqualToString:@"--asc-issuer"] && i + 1 < argc)
                ascIssuer = @(argv[++i]);
            else if ([a isEqualToString:@"--asc-key-id"] && i + 1 < argc)
                ascKeyId = @(argv[++i]);
            else if ([a isEqualToString:@"--asc-key"] && i + 1 < argc)
                ascKey = @(argv[++i]);
            else if ([a isEqualToString:@"--profile-name"] && i + 1 < argc)
                profileName = @(argv[++i]);
            else if ([a isEqualToString:@"-o"] && i + 1 < argc)
                oPath = @(argv[++i]);
            else if ([a isEqualToString:@"--seal-resources"] && i + 1 < argc)
                sealBundle = @(argv[++i]);
            else if ([a isEqualToString:@"--resource"] && i + 1 < argc)
                [sealResources addObject:@(argv[++i])];
            else if ([a isEqualToString:@"--info-plist"] && i + 1 < argc)
                infoPlistPath = @(argv[++i]);
            else if ([a isEqualToString:@"--code-resources"] && i + 1 < argc)
                codeResourcesPath = @(argv[++i]);
            else if ([a hasPrefix:@"-"])
                {
                fprintf(stderr, "xcc-sign: unknown option %s\n", argv[i]);
                usage();
                return 2;
                }
            else if (!inPath)
                inPath = a;
            else if (!outPath)
                outPath = a;
            }

        // The passphrase (for the encrypted key) may also come from the
        // environment, so it need not appear in the process table / shell history.
        if (!passphrase)
            {
            const char* env = getenv("XCC_SIGN_PASSPHRASE");
            if (env)
                passphrase = @(env);
            }

        // ── Seal an app bundle's resources into _CodeSignature/CodeResources. ──
        // The resource half of Mac-free bundle signing (docs/ios/bundle-signing.md).
        if (sealBundle)
            {
            if (sealResources.count == 0)
                {
                fprintf(stderr, "xcc-sign: --seal-resources needs at least one --resource <rel>\n");
                return 2;
                }
            NSString* err = nil;
            NSData* cr = [XTCodeResources codeResourcesForBundle:sealBundle
                                                       resources:sealResources
                                                           error:&err];
            if (!cr)
                {
                fprintf(stderr, "xcc-sign: %s\n", err.UTF8String);
                return 1;
                }
            NSString* csDir = [sealBundle stringByAppendingPathComponent:@"_CodeSignature"];
            [[NSFileManager defaultManager] createDirectoryAtPath:csDir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];
            NSString* crPath = [csDir stringByAppendingPathComponent:@"CodeResources"];
            if (![cr writeToFile:crPath atomically:YES])
                {
                fprintf(stderr, "xcc-sign: cannot write '%s'\n", crPath.UTF8String);
                return 1;
                }
            return 0;
            }

        // ── Route 1 admin: list / revoke certificates. ──
        if (listCerts || revokeId)
            {
#if XT_HAVE_TLS
            if (!ascIssuer || !ascKeyId || !ascKey)
                {
                fprintf(stderr, "xcc-sign: --list-certs/--revoke-cert need --asc-issuer, --asc-key-id, --asc-key\n");
                return 2;
                }
            NSString* e = nil;
            XTAscApi* api = [[XTAscApi alloc] initWithIssuerId:ascIssuer keyId:ascKeyId p8Path:ascKey error:&e];
            if (!api)
                {
                fprintf(stderr, "xcc-sign: %s\n", e.UTF8String);
                return 1;
                }
            if (revokeId)
                {
                if (![api revokeCertificate:revokeId error:&e])
                    {
                    fprintf(stderr, "xcc-sign: %s\n", e.UTF8String);
                    return 1;
                    }
                fprintf(stderr, "xcc-sign: revoked certificate %s\n", revokeId.UTF8String);
                return 0;
                }
            NSData* d = [api listCertificates:&e];
            if (!d)
                {
                fprintf(stderr, "xcc-sign: %s\n", e.UTF8String);
                return 1;
                }
            NSDictionary* j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
            for (NSDictionary* ct in j[@"data"])
                fprintf(stdout, "%s  %-28s  %s\n",
                        [ct[@"id"] UTF8String], [ct[@"attributes"][@"certificateType"] UTF8String],
                        [ct[@"attributes"][@"displayName"] UTF8String]);
            return 0;
#else
            fprintf(stderr, "xcc-sign: --list-certs/--revoke-cert need a TLS build\n");
            return 2;
#endif
            }

        // ── Route 1: fetch an identity from App Store Connect. ──
        if (fetch)
            {
#if XT_HAVE_TLS
            if (!oPath || !ascIssuer || !ascKeyId || !ascKey)
                {
                fprintf(stderr, "xcc-sign: --fetch-identity needs -o, --asc-issuer, --asc-key-id, --asc-key\n");
                return 2;
                }
            if (!passphrase)
                {
                fprintf(stderr, "xcc-sign: --fetch-identity needs --passphrase "
                                "(or $XCC_SIGN_PASSPHRASE) to protect the fetched key\n");
                return 2;
                }
            return fetchIdentity(ascIssuer, ascKeyId, ascKey, profileName, passphrase, oPath);
#else
            fprintf(stderr, "xcc-sign: --fetch-identity needs a TLS build "
                            "(rebuild with Mbed TLS; see MBEDTLS_PREFIX)\n");
            return 2;
#endif
            }

        // ── Route 2: export a keychain identity into a PEM bundle (macOS). ──
        if (exportName)
            {
            if (!oPath)
                {
                fprintf(stderr, "xcc-sign: --export-identity needs -o <identity.pem>\n");
                return 2;
                }
            if (!passphrase)
                {
                fprintf(stderr, "xcc-sign: --export-identity needs --passphrase "
                                "(or $XCC_SIGN_PASSPHRASE) to protect the key\n");
                return 2;
                }
            NSString* err = nil;
            if (![XTIdentityExport exportIdentityMatching:exportName
                                               passphrase:passphrase
                                             keychainPath:keychainPath
                                              profilePath:profilePath
                                                   toPath:oPath
                                                    error:&err])
                {
                fprintf(stderr, "xcc-sign: %s\n", err.UTF8String);
                return 1;
                }
            fprintf(stderr, "xcc-sign: exported identity -> '%s'\n", oPath.UTF8String);
            return 0;
            }
        if (!identityPath || !inPath)
            {
            usage();
            return 2;
            }
        if (!outPath)
            outPath = inPath;
        if (!identifier)
            identifier = inPath.lastPathComponent;

        NSData* pem = [NSData dataWithContentsOfFile:identityPath];
        if (!pem)
            {
            fprintf(stderr, "xcc-sign: cannot read identity '%s'\n", identityPath.UTF8String);
            return 1;
            }
        NSString* err = nil;
        XTIdentity* identity = [XTIdentity identityFromPEM:pem passphrase:passphrase error:&err];
        if (!identity)
            {
            fprintf(stderr, "xcc-sign: %s\n", err.UTF8String);
            return 1;
            }

        NSData* macho = [NSData dataWithContentsOfFile:inPath];
        if (!macho)
            {
            fprintf(stderr, "xcc-sign: cannot read '%s'\n", inPath.UTF8String);
            return 1;
            }

        NSData* ent = identity.entitlementsXml;
        if (entPath)
            {
            ent = [NSData dataWithContentsOfFile:entPath];
            if (!ent)
                {
                fprintf(stderr, "xcc-sign: cannot read entitlements '%s'\n", entPath.UTF8String);
                return 1;
                }
            }

        // Bundle-mode inputs: hashing the Info.plist and CodeResources into CD
        // special slots 1 and 3 (docs/ios/bundle-signing.md, Part B).
        NSData *infoPlist = nil, *codeResources = nil;
        if (infoPlistPath)
            {
            infoPlist = [NSData dataWithContentsOfFile:infoPlistPath];
            if (!infoPlist)
                {
                fprintf(stderr, "xcc-sign: cannot read info-plist '%s'\n", infoPlistPath.UTF8String);
                return 1;
                }
            }
        if (codeResourcesPath)
            {
            codeResources = [NSData dataWithContentsOfFile:codeResourcesPath];
            if (!codeResources)
                {
                fprintf(stderr, "xcc-sign: cannot read code-resources '%s'\n", codeResourcesPath.UTF8String);
                return 1;
                }
            }

        // A fixed signing time keeps a re-sign reproducible; the CMS carries it.
        NSData* signed_ = [XTCodeSign resign:macho
                                  identifier:identifier
                                 leafCertDer:identity.leafCertDer
                                    chainDer:identity.chainDer
                                     modulus:identity.modulus
                             privateExponent:identity.privateExponent
                             entitlementsXml:ent
                                   infoPlist:infoPlist
                               codeResources:codeResources
                                 signingTime:@"20260101000000Z"
                                       error:&err];
        if (!signed_)
            {
            fprintf(stderr, "xcc-sign: signing failed: %s\n", err.UTF8String);
            return 1;
            }

        if (![signed_ writeToFile:outPath atomically:YES])
            {
            fprintf(stderr, "xcc-sign: cannot write '%s'\n", outPath.UTF8String);
            return 1;
            }
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0755}
                                         ofItemAtPath:outPath
                                                error:NULL];
        return 0;
        }
    }
