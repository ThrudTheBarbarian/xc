// mkident — a SELF-SIGNED test identity for sign-diff: an RSA-2048 key and a
// certificate over it, written as the PEM bundle both xcc-sign and xtsign
// read (CERTIFICATE + RSA PRIVATE KEY, unencrypted). Structure and hashes
// are what codesign validates; only trust needs Apple's chain
// (docs/mobile/signing.md, "the de-risker").
//
//   mkident <out.pem> [<common-name>]

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "CodeSign.xc"
#import "RsaKeygen.xc"

String* pemBlock(String* label, Array* der)
    {
    String* b64 = String.withCString("");
    String* alpha = String.withCString("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
    u32 col = (u32)0;
    for (u32 i = (u32)0; i < der.count(); i = i + (u32)3)
        {
        u32 b0 = Bytes.at(der, i);
        u32 b1 = i + (u32)1 < der.count() ? Bytes.at(der, i + (u32)1) : (u32)0;
        u32 b2 = i + (u32)2 < der.count() ? Bytes.at(der, i + (u32)2) : (u32)0;
        u32 v = (b0 << (u32)16) | (b1 << (u32)8) | b2;
        b64.appendByte(alpha.byteAt((v >> (u32)18) & (u32)63));
        b64.appendByte(alpha.byteAt((v >> (u32)12) & (u32)63));
        b64.appendByte(i + (u32)1 < der.count() ? alpha.byteAt((v >> (u32)6) & (u32)63) : (u8)'=');
        b64.appendByte(i + (u32)2 < der.count() ? alpha.byteAt(v & (u32)63) : (u8)'=');
        col = col + (u32)4;
        if (col >= (u32)64)
            {
            b64.appendCString("\n");
            col = (u32)0;
            }
        }
    String* s = String.withCString("-----BEGIN ");
    s.append(label);
    s.appendCString("-----\n");
    s.append(b64);
    if (col != (u32)0)
        s.appendCString("\n");
    s.appendCString("-----END ");
    s.append(label);
    s.appendCString("-----\n");
    return s;
    }

void main(void)
    {
    if (Process.argumentCount() < (u32)2)
        {
        Stdio.printf("usage: mkident <out.pem> [<common-name>]\n");
        Process.exit((i32)2);
        return;
        }
    String* out = Process.argument((u32)1);
    String* cn = Process.argumentCount() > (u32)2 ? Process.argument((u32)2) : String.withCString("xtsign self-signed");
    Array* key = Rsa.generate((u32)2048);
    if (key.count() < (u32)3)
        {
        Stdio.printf("mkident: key generation failed\n");
        Process.exit((i32)1);
        return;
        }
    Array* n = (Array*)key.get((u32)0);
    Array* e = (Array*)key.get((u32)1);
    Array* d = (Array*)key.get((u32)2);
    Array* cert = ApkSign.selfSignedCert(n, e, d, cn);
    // RSAPrivateKey ::= SEQUENCE { version 0, n, e, d } — the fields both
    // readers consume (the CRT parameters are not needed to sign).
    Array* fields = new Array();
    fields.add((Object*)Der.integerU32((u32)0));
    fields.add((Object*)Der.integer(n));
    fields.add((Object*)Der.integer(e));
    fields.add((Object*)Der.integer(d));
    Array* keyDer = Der.sequence(fields);
    String* pem = pemBlock(String.withCString("CERTIFICATE"), cert);
    pem.append(pemBlock(String.withCString("RSA PRIVATE KEY"), keyDer));
    if (!Files.writeText(out, pem))
        {
        Stdio.printf("mkident: cannot write '%s'\n", out.cString());
        Process.exit((i32)1);
        return;
        }
    }
