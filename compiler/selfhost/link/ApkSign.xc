// ApkSign.xc — APK Signature Scheme v2, in xtc. Mirrors src/xtc/sign/XTApkSign.m.
// =================================================================
//
// v1 (JAR signing) will not do: Android 11 and later REFUSE a package whose
// targetSdk is 30+ when it carries only a v1 signature, and ours targets 35.
//
// The shape: digest the file in three regions — everything before the central
// directory, the central directory, and the end-of-central-directory record —
// as 1 MB chunks, digest the digests, sign that, and insert an "APK Signing
// Block" between the entries and the central directory. The EOCD's
// central-directory offset then has to move by the block's size, which is the
// one field that is patched rather than rebuilt.
//
// The EOCD is digested UNMODIFIED, before that patch: the block lands exactly
// where the central directory started, so a verifier recomputes the digest with
// the ORIGINAL offset. Getting that backwards produces a package that verifies
// nowhere and says nothing about why.

#import "Foundation.xc"
#import "MachO.xc" // Sha256
#import "Bignum.xc"
#import "Apk.xc" // apkW8/16/32, apkAppend
#import "RsaKeygen.xc"

u32 apkR32(Array* d, u32 at)
    {
    return ((Number*)d.get(at)).asU32() | (((Number*)d.get(at + (u32)1)).asU32() << (u32)8) | (((Number*)d.get(at + (u32)2)).asU32() << (u32)16) | (((Number*)d.get(at + (u32)3)).asU32() << (u32)24);
    }
void apkW64(Array* d, u64 v)
    {
    for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
        apkW8(d, (u32)((v >> ((u64)8 * (u64)i)) & (u64)$FF));
    }
Array* apkLenPrefixed(Array* d)
    {
    Array* o = new Array();
    apkW32(o, d.count());
    apkAppend(o, d);
    return o;
    }
Array* apkSha256(Array* d, u32 from, u32 len)
    {
    Sha256* h = new Sha256();
    h.update(d, from, len);
    Array* out = new Array();
    h.finalise(out);
    return out;
    }

class ApkSign
    {
    // 1 MB, the scheme's fixed chunk size.
    static u32 chunkSize(void)
        {
        return (u32)1048576;
        }
    static u32 chunkCount(u32 len)
        {
        return (len + ApkSign.chunkSize() - (u32)1) / ApkSign.chunkSize();
        }

    // Each chunk is digested with a 0xa5 tag and its length in front.
    static void appendChunkDigests(Array* out, Array* src, u32 base, u32 len)
        {
        u32 n = ApkSign.chunkCount(len);
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            u32 off = i * ApkSign.chunkSize();
            u32 sz = ApkSign.chunkSize();
            if (len - off < sz)
                sz = len - off;
            Array* pre = new Array();
            apkW8(pre, (u32)$A5);
            apkW32(pre, sz);
            for (u32 k = (u32)0; k < sz; k = k + (u32)1)
                pre.add(src.get(base + off + k));
            apkAppend(out, apkSha256(pre, (u32)0, pre.count()));
            }
        }

    // PKCS#1 v1.5 over a SHA-256 DigestInfo. The DigestInfo for SHA-256 is a
    // FIXED 19-byte DER prefix, so no DER writer is needed to sign — the only
    // varying part is the digest itself.
    static Array* rsaSignSha256(Array* digest, Bignum* n, Bignum* d, u32 modLen)
        {
        Array* t = new Array();
        u32 pre[19];
        pre[0] = (u32)$30;
        pre[1] = (u32)$31;
        pre[2] = (u32)$30;
        pre[3] = (u32)$0d;
        pre[4] = (u32)$06;
        pre[5] = (u32)$09;
        pre[6] = (u32)$60;
        pre[7] = (u32)$86;
        pre[8] = (u32)$48;
        pre[9] = (u32)$01;
        pre[10] = (u32)$65;
        pre[11] = (u32)$03;
        pre[12] = (u32)$04;
        pre[13] = (u32)$02;
        pre[14] = (u32)$01;
        pre[15] = (u32)$05;
        pre[16] = (u32)$00;
        pre[17] = (u32)$04;
        pre[18] = (u32)$20;
        for (u32 i = (u32)0; i < (u32)19; i = i + (u32)1)
            t.add((Object*)Number.withU32(pre[i]));
        apkAppend(t, digest);

        // EM = 0x00 01 FF..FF 00 T
        Array* em = new Array();
        em.add((Object*)Number.withU32((u32)0));
        em.add((Object*)Number.withU32((u32)1));
        u32 padLen = modLen - t.count() - (u32)3;
        for (u32 i = (u32)0; i < padLen; i = i + (u32)1)
            em.add((Object*)Number.withU32((u32)$FF));
        em.add((Object*)Number.withU32((u32)0));
        apkAppend(em, t);

        Bignum* m = Bignum.fromBytes(em);
        Bignum* s = Bignum.modexp(m, d, n);
        return s.toBytes(modLen);
        }

    // Returns the signed APK bytes, or an empty array on failure.
    static Array* sign(Array* apk, Array* certDer, Array* nBytes, Array* eBytes, Array* dBytes)
        {
        u32 len = apk.count();
        // Find the end-of-central-directory record, scanning back from the end.
        i64 eocd = (i64)-1;
        u32 i = len >= (u32)22 ? len - (u32)22 : (u32)0;
        while (true)
            {
            if (apkR32(apk, i) == (u32)$06054B50)
                {
                eocd = (i64)i;
                break;
                }
            if (i == (u32)0)
                break;
            i = i - (u32)1;
            }
        if (eocd < (i64)0)
            return new Array();
        u32 eo = (u32)eocd;
        u32 cdSize = apkR32(apk, eo + (u32)12);
        u32 cdOff = apkR32(apk, eo + (u32)16);
        if (cdOff + cdSize > len)
            return new Array();

        Array* chunks = new Array();
        ApkSign.appendChunkDigests(chunks, apk, (u32)0, cdOff);
        ApkSign.appendChunkDigests(chunks, apk, cdOff, cdSize);
        ApkSign.appendChunkDigests(chunks, apk, eo, len - eo);
        u32 total = ApkSign.chunkCount(cdOff) + ApkSign.chunkCount(cdSize) + ApkSign.chunkCount(len - eo);

        Array* top = new Array();
        apkW8(top, (u32)$5A);
        apkW32(top, total);
        apkAppend(top, chunks);
        Array* apkDigest = apkSha256(top, (u32)0, top.count());

        u32 SIG = (u32)$0103; // RSA PKCS#1 v1.5 with SHA-256
        Array* one = new Array();
        apkW32(one, SIG);
        apkAppend(one, apkLenPrefixed(apkDigest));
        Array* digests = apkLenPrefixed(one);

        Array* certs = apkLenPrefixed(certDer);
        Array* signedData = new Array();
        apkAppend(signedData, apkLenPrefixed(digests));
        apkAppend(signedData, apkLenPrefixed(certs));
        apkAppend(signedData, apkLenPrefixed(new Array())); // additional attrs

        Array* sdDigest = apkSha256(signedData, (u32)0, signedData.count());
        Bignum* n = Bignum.fromBytes(nBytes);
        Bignum* d = Bignum.fromBytes(dBytes);
        Array* sig = ApkSign.rsaSignSha256(sdDigest, n, d, nBytes.count());

        Array* sone = new Array();
        apkW32(sone, SIG);
        apkAppend(sone, apkLenPrefixed(sig));
        Array* signatures = apkLenPrefixed(sone);

        // The public key, as a DER SubjectPublicKeyInfo. Built here rather than
        // through a DER writer: the only variable-length pieces are n and e.
        Array* spki = ApkSign.spki(nBytes, eBytes);

        Array* signer = new Array();
        apkAppend(signer, apkLenPrefixed(signedData));
        apkAppend(signer, apkLenPrefixed(signatures));
        apkAppend(signer, apkLenPrefixed(spki));
        Array* signers = apkLenPrefixed(signer);
        Array* v2Value = apkLenPrefixed(signers);

        Array* pairs = new Array();
        apkW64(pairs, (u64)((u32)4 + v2Value.count()));
        apkW32(pairs, (u32)$7109871A); // the v2 block id
        apkAppend(pairs, v2Value);

        Array* block = new Array();
        u64 blockSize = (u64)(pairs.count() + (u32)8 + (u32)16);
        apkW64(block, blockSize);
        apkAppend(block, pairs);
        apkW64(block, blockSize);
        String* magic = String.withCString("APK Sig Block 42");
        for (u32 k = (u32)0; k < (u32)16; k = k + (u32)1)
            apkW8(block, (u32)magic.byteAt(k));

        Array* out = new Array();
        for (u32 k = (u32)0; k < cdOff; k = k + (u32)1)
            out.add(apk.get(k));
        apkAppend(out, block);
        for (u32 k = (u32)0; k < cdSize; k = k + (u32)1)
            out.add(apk.get(cdOff + k));
        // The EOCD, with ONLY its central-directory offset moved on by the
        // block's size. It was digested above in its original form.
        u32 newCdOff = cdOff + block.count();
        for (u32 k = (u32)0; k < len - eo; k = k + (u32)1)
            {
            if (k >= (u32)16 && k < (u32)20)
                out.add((Object*)Number.withU32((newCdOff >> ((k - (u32)16) * (u32)8)) & (u32)$FF));
            else
                out.add(apk.get(eo + k));
            }
        return out;
        }

    // ── the self-signed certificate ──────────────────────────────────────
    //
    // An APK signature carries a certificate, and a compiler that can generate
    // a key but not a certificate still cannot sign — so this is here for the
    // same reason keygen is: for a user, the bootstrap compiler does not exist.
    //
    // X.509 v3, self-issued: subject == issuer, serial 1, valid 2001-2099. The
    // identity is the DN alone, which is what `adb install -r` compares.
    static Array* derBytes(Array* v, u32 tag)
        {
        return ApkSign.derTagged(tag, v);
        }
    static Array* derStr(String* s, u32 tag)
        {
        Array* b = new Array();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            b.add((Object*)Number.withU32((u32)s.byteAt(i)));
        return ApkSign.derTagged(tag, b);
        }
    static Array* derOid(Array* body)
        {
        return ApkSign.derTagged((u32)$06, body);
        }
    static Array* oidRsaEncryption(void)
        {
        Array* o = new Array();
        u32 v[9];
        v[0] = (u32)$2A;
        v[1] = (u32)$86;
        v[2] = (u32)$48;
        v[3] = (u32)$86;
        v[4] = (u32)$F7;
        v[5] = (u32)$0D;
        v[6] = (u32)$01;
        v[7] = (u32)$01;
        v[8] = (u32)$01;
        for (u32 i = (u32)0; i < (u32)9; i = i + (u32)1)
            o.add((Object*)Number.withU32(v[i]));
        return ApkSign.derOid(o);
        }
    static Array* oidSha256Rsa(void)
        {
        Array* o = new Array();
        u32 v[9];
        v[0] = (u32)$2A;
        v[1] = (u32)$86;
        v[2] = (u32)$48;
        v[3] = (u32)$86;
        v[4] = (u32)$F7;
        v[5] = (u32)$0D;
        v[6] = (u32)$01;
        v[7] = (u32)$01;
        v[8] = (u32)$0B;
        for (u32 i = (u32)0; i < (u32)9; i = i + (u32)1)
            o.add((Object*)Number.withU32(v[i]));
        return ApkSign.derOid(o);
        }
    static Array* oidCommonName(void)
        {
        Array* o = new Array();
        o.add((Object*)Number.withU32((u32)$55));
        o.add((Object*)Number.withU32((u32)$04));
        o.add((Object*)Number.withU32((u32)$03));
        return ApkSign.derOid(o);
        }

    static Array* selfSignedCert(Array* nBytes, Array* eBytes, Array* dBytes, String* cn)
        {
        Array* sigAlgoInner = new Array();
        apkAppend(sigAlgoInner, ApkSign.oidSha256Rsa());
        apkAppend(sigAlgoInner, ApkSign.derTagged((u32)$05, new Array())); // NULL
        Array* sigAlgo = ApkSign.derTagged((u32)$30, sigAlgoInner);

        // Name ::= SEQUENCE { SET { SEQUENCE { OID commonName, UTF8String } } }
        Array* rdnInner = new Array();
        apkAppend(rdnInner, ApkSign.oidCommonName());
        apkAppend(rdnInner, ApkSign.derStr(cn, (u32)$0C)); // UTF8String
        Array* rdnSeq = ApkSign.derTagged((u32)$30, rdnInner);
        Array* rdnSet = ApkSign.derTagged((u32)$31, rdnSeq);
        Array* name = ApkSign.derTagged((u32)$30, rdnSet);

        Array* validInner = new Array();
        apkAppend(validInner, ApkSign.derStr(String.withCString("200101000000Z"), (u32)$17));
        apkAppend(validInner, ApkSign.derStr(String.withCString("20990101000000Z"), (u32)$18));
        Array* validity = ApkSign.derTagged((u32)$30, validInner);

        Array* verInner = new Array();
        Array* two = new Array();
        two.add((Object*)Number.withU32((u32)2));
        apkAppend(verInner, ApkSign.derTagged((u32)$02, two));
        Array* version = ApkSign.derTagged((u32)$A0, verInner); // [0] EXPLICIT

        Array* serial = new Array();
        serial.add((Object*)Number.withU32((u32)1));

        Array* tbsInner = new Array();
        apkAppend(tbsInner, version);
        apkAppend(tbsInner, ApkSign.derTagged((u32)$02, serial));
        apkAppend(tbsInner, sigAlgo);
        apkAppend(tbsInner, name); // issuer
        apkAppend(tbsInner, validity);
        apkAppend(tbsInner, name); // subject == issuer
        apkAppend(tbsInner, ApkSign.spki(nBytes, eBytes));
        Array* tbs = ApkSign.derTagged((u32)$30, tbsInner);

        Array* digest = apkSha256(tbs, (u32)0, tbs.count());
        Bignum* n = Bignum.fromBytes(nBytes);
        Bignum* d = Bignum.fromBytes(dBytes);
        Array* sig = ApkSign.rsaSignSha256(digest, n, d, nBytes.count());

        Array* bits = new Array();
        bits.add((Object*)Number.withU32((u32)0));
        apkAppend(bits, sig);
        Array* sigBits = ApkSign.derTagged((u32)$03, bits);

        Array* all = new Array();
        apkAppend(all, tbs);
        apkAppend(all, sigAlgo);
        apkAppend(all, sigBits);
        return ApkSign.derTagged((u32)$30, all);
        }

    // DER: SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { SEQUENCE { n, e } } }
    static Array* derLen(u32 n)
        {
        Array* o = new Array();
        if (n < (u32)128)
            {
            o.add((Object*)Number.withU32(n));
            return o;
            }
        if (n < (u32)256)
            {
            o.add((Object*)Number.withU32((u32)$81));
            o.add((Object*)Number.withU32(n));
            return o;
            }
        if (n < (u32)65536)
            {
            o.add((Object*)Number.withU32((u32)$82));
            o.add((Object*)Number.withU32((n >> (u32)8) & (u32)$FF));
            o.add((Object*)Number.withU32(n & (u32)$FF));
            return o;
            }
        o.add((Object*)Number.withU32((u32)$83));
        o.add((Object*)Number.withU32((n >> (u32)16) & (u32)$FF));
        o.add((Object*)Number.withU32((n >> (u32)8) & (u32)$FF));
        o.add((Object*)Number.withU32(n & (u32)$FF));
        return o;
        }
    static Array* derTagged(u32 tag, Array* body)
        {
        Array* o = new Array();
        o.add((Object*)Number.withU32(tag));
        apkAppend(o, ApkSign.derLen(body.count()));
        apkAppend(o, body);
        return o;
        }
    // An INTEGER is signed, so a high top bit needs a leading zero or the value
    // reads as negative.
    static Array* derInteger(Array* v)
        {
        Array* b = new Array();
        u32 s = (u32)0;
        while (s + (u32)1 < v.count() && ((Number*)v.get(s)).asU32() == (u32)0)
            s = s + (u32)1;
        if ((((Number*)v.get(s)).asU32() & (u32)$80) != (u32)0)
            b.add((Object*)Number.withU32((u32)0));
        for (u32 k = s; k < v.count(); k = k + (u32)1)
            b.add(v.get(k));
        return ApkSign.derTagged((u32)$02, b);
        }
    static Array* spki(Array* nBytes, Array* eBytes)
        {
        Array* rsaPub = new Array();
        apkAppend(rsaPub, ApkSign.derInteger(nBytes));
        apkAppend(rsaPub, ApkSign.derInteger(eBytes));
        Array* pubSeq = ApkSign.derTagged((u32)$30, rsaPub);

        Array* algo = new Array();
        apkAppend(algo, ApkSign.oidRsaEncryption());
        apkAppend(algo, ApkSign.derTagged((u32)$05, new Array())); // NULL
        Array* algoSeq = ApkSign.derTagged((u32)$30, algo);

        Array* bits = new Array();
        bits.add((Object*)Number.withU32((u32)0)); // unused bits
        apkAppend(bits, pubSeq);
        Array* bitStr = ApkSign.derTagged((u32)$03, bits);

        Array* all = new Array();
        apkAppend(all, algoSeq);
        apkAppend(all, bitStr);
        return ApkSign.derTagged((u32)$30, all);
        }
    }
