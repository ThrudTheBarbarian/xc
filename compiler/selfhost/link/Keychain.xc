// Keychain.xc — export a code-signing identity from the macOS keychain into
// the PEM bundle the signer reads (docs/mobile/signing.md, Route 2).
//
// The one part of signing that needs the host: the keychain is reached through
// the Security framework, so this file links only into a macOS build
// (`-framework Security -framework CoreFoundation`). The key never leaves the
// keychain in the clear — SecItemExport wraps it as a PBES2
// EncryptedPrivateKeyInfo under the passphrase, and that blob is stored as is.
//
// Selecting: every identity in the keychain (or in the file keychain named by
// --keychain), the first whose certificate common name contains the given
// text. Its issuer chain is whatever a trust evaluation over the leaf finds.

#import "Foundation.xc"
#import "Files.xc"
#import "CodeSign.xc"
#import "Plist.xc"

// ── CoreFoundation / Security ───────────────────────────────────────────────
extern pointer kCFTypeDictionaryKeyCallBacks;
extern pointer kCFTypeDictionaryValueCallBacks;
extern pointer kCFTypeArrayCallBacks;
extern pointer kCFBooleanTrue;
extern pointer kSecClass;
extern pointer kSecClassIdentity;
extern pointer kSecReturnRef;
extern pointer kSecMatchLimit;
extern pointer kSecMatchLimitAll;
extern pointer kSecMatchSearchList;

pointer CFDictionaryCreateMutable(pointer alloc, i64 capacity, pointer keyCallBacks, pointer valueCallBacks);
void CFDictionarySetValue(pointer dict, pointer key, pointer value);
pointer CFArrayCreate(pointer alloc, pointer* values, i64 count, pointer callBacks);
i64 CFArrayGetCount(pointer array);
pointer CFArrayGetValueAtIndex(pointer array, i64 index);
pointer CFStringCreateWithCString(pointer alloc, u8* s, u32 encoding);
bool CFStringGetCString(pointer s, u8* buf, i64 size, u32 encoding);
i64 CFStringGetLength(pointer s);
i64 CFDataGetLength(pointer d);
u8* CFDataGetBytePtr(pointer d);
void CFRelease(pointer cf);

i32 SecItemCopyMatching(pointer query, pointer* result);
i32 SecKeychainOpen(u8* path, pointer* keychain);
i32 SecIdentityCopyCertificate(pointer identity, pointer* cert);
i32 SecIdentityCopyPrivateKey(pointer identity, pointer* key);
i32 SecCertificateCopyCommonName(pointer cert, pointer* name);
pointer SecCertificateCopyData(pointer cert);
pointer SecPolicyCreateBasicX509(void);
i32 SecTrustCreateWithCertificates(pointer certs, pointer policy, pointer* trust);
bool SecTrustEvaluateWithError(pointer trust, pointer* error);
pointer SecTrustCopyCertificateChain(pointer trust);
i32 SecItemExport(pointer item, u32 format, u32 flags, pointer keyParams, pointer* exported);
i32 chmod(u8* path, u32 mode);

// SecItemImportExportKeyParameters, version 0.
struct SecExportParams
    {
    u32 version;
    u32 flags;
    pointer passphrase;
    pointer alertTitle;
    pointer alertPrompt;
    pointer accessRef;
    pointer keyUsage;
    pointer keyAttributes;
    }

#define kCFStringEncodingUTF8 $08000100
#define kSecFormatWrappedPKCS8 5

class Keychain
    {
    String* _why;
    void init(void)
        {
        }
    String* why(void)
        {
        return _why;
        }
    bool fail(String* m)
        {
        _why = m;
        return false;
        }

    static Array* bytesOfCFData(pointer d)
        {
        Array* out = new Array();
        if (d == (pointer)0)
            return out;
        i64 n = CFDataGetLength(d);
        u8* p = CFDataGetBytePtr(d);
        for (i64 i = (i64)0; i < n; i = i + (i64)1)
            Bytes.add(out, (u32)p[i]);
        return out;
        }
    static String* stringOfCF(pointer s)
        {
        if (s == (pointer)0)
            return (String*)0;
        u32 cap = (u32)CFStringGetLength(s) * (u32)4 + (u32)1;
        u8* buf = new u8[cap];
        String* out = (String*)0;
        if (CFStringGetCString(s, buf, (i64)cap, (u32)kCFStringEncodingUTF8))
            out = String.withCString(buf);
        delete buf;
        return out;
        }

    // Best-effort issuer chain: the certificates a trust evaluation places
    // above the leaf. A self-signed leaf has none.
    static Array* chainAbove(pointer leaf)
        {
        Array* chain = new Array();
        pointer policy = SecPolicyCreateBasicX509();
        pointer trust = (pointer)0;
        if (SecTrustCreateWithCertificates(leaf, policy, &trust) == (i32)0 && trust != (pointer)0)
            {
            SecTrustEvaluateWithError(trust, (pointer*)0);
            pointer certs = SecTrustCopyCertificateChain(trust);
            if (certs != (pointer)0)
                {
                i64 n = CFArrayGetCount(certs);
                for (i64 i = (i64)1; i < n; i = i + (i64)1)
                    {
                    pointer d = SecCertificateCopyData(CFArrayGetValueAtIndex(certs, i));
                    if (d != (pointer)0)
                        {
                        chain.add((Object*)Keychain.bytesOfCFData(d));
                        CFRelease(d);
                        }
                    }
                CFRelease(certs);
                }
            }
        if (trust != (pointer)0)
            CFRelease(trust);
        if (policy != (pointer)0)
            CFRelease(policy);
        return chain;
        }

    bool export(String* nameSubstring, String* passphrase, String* keychainPath, String* profilePath, String* outPath)
        {
        pointer q = CFDictionaryCreateMutable((pointer)0, (i64)0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(q, kSecClass, kSecClassIdentity);
        CFDictionarySetValue(q, kSecReturnRef, kCFBooleanTrue);
        CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitAll);
        if (keychainPath != (String*)0)
            {
            // The deprecated SecKeychainOpen is the only way to name a file
            // keychain; the data-protection keychain has no path.
            pointer kc = (pointer)0;
            if (SecKeychainOpen(keychainPath.cString(), &kc) == (i32)0 && kc != (pointer)0)
                {
                pointer list = CFArrayCreate((pointer)0, &kc, (i64)1, &kCFTypeArrayCallBacks);
                CFDictionarySetValue(q, kSecMatchSearchList, list);
                }
            }
        pointer result = (pointer)0;
        i32 st = SecItemCopyMatching(q, &result);
        if (st != (i32)0 || result == (pointer)0)
            return fail(String.withCString("no code-signing identities found in the keychain"));

        pointer match = (pointer)0;
        pointer matchCert = (pointer)0;
        i64 n = CFArrayGetCount(result);
        for (i64 i = (i64)0; i < n; i = i + (i64)1)
            {
            pointer ident = CFArrayGetValueAtIndex(result, i);
            pointer cert = (pointer)0;
            if (SecIdentityCopyCertificate(ident, &cert) != (i32)0 || cert == (pointer)0)
                continue;
            pointer cn = (pointer)0;
            SecCertificateCopyCommonName(cert, &cn);
            String* name = Keychain.stringOfCF(cn);
            if (cn != (pointer)0)
                CFRelease(cn);
            if (name != (String*)0 && nameSubstring.byteLength() > (u32)0 && name.contains(nameSubstring))
                {
                match = ident;
                matchCert = cert;
                break;
                }
            CFRelease(cert);
            }
        if (match == (pointer)0)
            {
            String* m = String.withCString("no identity matching '");
            m.append(nameSubstring);
            m.appendCString("'");
            return fail(m);
            }

        pointer leafData = SecCertificateCopyData(matchCert);
        Array* leafDer = Keychain.bytesOfCFData(leafData);
        if (leafData != (pointer)0)
            CFRelease(leafData);
        Array* chain = Keychain.chainAbove(matchCert);

        pointer priv = (pointer)0;
        if (SecIdentityCopyPrivateKey(match, &priv) != (i32)0 || priv == (pointer)0)
            {
            CFRelease(matchCert);
            return fail(String.withCString("the identity's private key is not accessible (not exportable?)"));
            }
        // macOS does not hand out a bare private key: SecItemExport wraps it
        // under the passphrase, and the signer unwraps it with the same one.
        // The first export prompts once for keychain permission.
        SecExportParams params;
        params.version = (u32)0;
        params.flags = (u32)0;
        params.passphrase = CFStringCreateWithCString((pointer)0, passphrase.cString(), (u32)kCFStringEncodingUTF8);
        params.alertTitle = (pointer)0;
        params.alertPrompt = (pointer)0;
        params.accessRef = (pointer)0;
        params.keyUsage = (pointer)0;
        params.keyAttributes = (pointer)0;
        pointer wrapped = (pointer)0;
        i32 est = SecItemExport(priv, (u32)kSecFormatWrappedPKCS8, (u32)0, (pointer)&params, &wrapped);
        CFRelease(priv);
        CFRelease(matchCert);
        if (est != (i32)0 || wrapped == (pointer)0)
            {
            String* m = String.withCString("could not export the private key (OSStatus ");
            m.append(String.withI32(est));
            m.appendCString(")");
            return fail(m);
            }
        Array* keyDer = Keychain.bytesOfCFData(wrapped);
        CFRelease(wrapped);

        Array* ent = (Array*)0;
        if (profilePath != (String*)0)
            {
            Data* raw = Files.readData(profilePath);
            if (raw != (Data*)0)
                ent = Profile.entitlements(Bytes.fromData(raw));
            }
        String* pem = Identity.pemBundle(leafDer, chain, keyDer, String.withCString("ENCRYPTED PRIVATE KEY"), ent);
        if (!Files.writeText(outPath, pem))
            return fail(String.withCString("could not write the PEM bundle"));
        // The bundle holds a private key: owner-only.
        chmod(outPath.cString(), (u32)$180);
        return true;
        }
    }
