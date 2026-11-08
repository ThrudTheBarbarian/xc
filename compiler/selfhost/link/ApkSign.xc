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
#import <MachO> // Sha256
#import "MachODefs.xc"
#import <Bignum>
#import <Apk> // apkW8/16/32, apkAppend
#import <RsaKeygen>

u32 apkR32(Data* d, u32 at)
    {
    return (u32)d.byteAt(at) | ((u32)d.byteAt(at + (u32)1) << (u32)8) | ((u32)d.byteAt(at + (u32)2) << (u32)16) | ((u32)d.byteAt(at + (u32)3) << (u32)24);
    }
void apkW64(Data* d, u64 v)
    {
    for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
        apkW8(d, (u32)((v >> ((u64)8 * (u64)i)) & (u64)$FF));
    }
Data* apkLenPrefixed(Data* d)
    {
    Data* o = new Data();
    apkW32(o, d.length());
    apkAppend(o, d);
    return o;
    }
Data* apkSha256(Data* d, u32 from, u32 len)
    {
    MachOSha256* h = new MachOSha256();
    h.updateData(d, from, len);
    Data* out = new Data();
    h.finaliseInto(out);
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
    static void appendChunkDigests(Data* out, Data* src, u32 base, u32 len)
        {
        u32 n = ApkSign.chunkCount(len);
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            u32 off = i * ApkSign.chunkSize();
            u32 sz = ApkSign.chunkSize();
            if (len - off < sz)
                sz = len - off;
            Data* pre = new Data();
            apkW8(pre, (u32)$A5);
            apkW32(pre, sz);
            for (u32 k = (u32)0; k < sz; k = k + (u32)1)
                pre.appendByte(src.byteAt(base + off + k));
            apkAppend(out, apkSha256(pre, (u32)0, pre.length()));
            }
        }

    // PKCS#1 v1.5 over a SHA-256 DigestInfo. The DigestInfo for SHA-256 is a
    // FIXED 19-byte DER prefix, so no DER writer is needed to sign — the only
    // varying part is the digest itself.
    static Data* rsaSignSha256(Data* digest, Bignum* n, Bignum* d, u32 modLen)
        {
        Data* t = new Data();
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
            t.appendByte((u8)(pre[i]));
        apkAppend(t, digest);

        // EM = 0x00 01 FF..FF 00 T
        Data* em = new Data();
        em.appendByte((u8)0);
        em.appendByte((u8)1);
        u32 padLen = modLen - t.length() - (u32)3;
        for (u32 i = (u32)0; i < padLen; i = i + (u32)1)
            em.appendByte((u8)$FF);
        em.appendByte((u8)0);
        apkAppend(em, t);

        Bignum* m = Bignum.fromBytes(em);
        Bignum* s = Bignum.modexp(m, d, n);
        return s.toBytes(modLen);
        }

    // Returns the signed APK bytes, or an empty array on failure.
    static Data* sign(Data* apk, Data* certDer, Data* nBytes, Data* eBytes, Data* dBytes)
        {
        u32 len = apk.length();
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
            return new Data();
        u32 eo = (u32)eocd;
        u32 cdSize = apkR32(apk, eo + (u32)12);
        u32 cdOff = apkR32(apk, eo + (u32)16);
        if (cdOff + cdSize > len)
            return new Data();

        Data* chunks = new Data();
        ApkSign.appendChunkDigests(chunks, apk, (u32)0, cdOff);
        ApkSign.appendChunkDigests(chunks, apk, cdOff, cdSize);
        ApkSign.appendChunkDigests(chunks, apk, eo, len - eo);
        u32 total = ApkSign.chunkCount(cdOff) + ApkSign.chunkCount(cdSize) + ApkSign.chunkCount(len - eo);

        Data* top = new Data();
        apkW8(top, (u32)$5A);
        apkW32(top, total);
        apkAppend(top, chunks);
        Data* apkDigest = apkSha256(top, (u32)0, top.length());

        u32 SIG = (u32)$0103; // RSA PKCS#1 v1.5 with SHA-256
        Data* one = new Data();
        apkW32(one, SIG);
        apkAppend(one, apkLenPrefixed(apkDigest));
        Data* digests = apkLenPrefixed(one);

        Data* certs = apkLenPrefixed(certDer);
        Data* signedData = new Data();
        apkAppend(signedData, apkLenPrefixed(digests));
        apkAppend(signedData, apkLenPrefixed(certs));
        apkAppend(signedData, apkLenPrefixed(new Data())); // additional attrs

        Data* sdDigest = apkSha256(signedData, (u32)0, signedData.length());
        Bignum* n = Bignum.fromBytes(nBytes);
        Bignum* d = Bignum.fromBytes(dBytes);
        Data* sig = ApkSign.rsaSignSha256(sdDigest, n, d, nBytes.length());

        Data* sone = new Data();
        apkW32(sone, SIG);
        apkAppend(sone, apkLenPrefixed(sig));
        Data* signatures = apkLenPrefixed(sone);

        // The public key, as a DER SubjectPublicKeyInfo. Built here rather than
        // through a DER writer: the only variable-length pieces are n and e.
        Data* spki = ApkSign.spki(nBytes, eBytes);

        Data* signer = new Data();
        apkAppend(signer, apkLenPrefixed(signedData));
        apkAppend(signer, apkLenPrefixed(signatures));
        apkAppend(signer, apkLenPrefixed(spki));
        Data* signers = apkLenPrefixed(signer);
        Data* v2Value = apkLenPrefixed(signers);

        Data* pairs = new Data();
        apkW64(pairs, (u64)((u32)4 + v2Value.length()));
        apkW32(pairs, (u32)$7109871A); // the v2 block id
        apkAppend(pairs, v2Value);

        Data* block = new Data();
        u64 blockSize = (u64)(pairs.length() + (u32)8 + (u32)16);
        apkW64(block, blockSize);
        apkAppend(block, pairs);
        apkW64(block, blockSize);
        String* magic = String.withCString("APK Sig Block 42");
        for (u32 k = (u32)0; k < (u32)16; k = k + (u32)1)
            apkW8(block, (u32)magic.byteAt(k));

        Data* out = new Data();
        out.appendBytes(apk.bytes(), cdOff);
        apkAppend(out, block);
        out.appendBytes(apk.bytes() + cdOff, cdSize);
        // The EOCD, with ONLY its central-directory offset moved on by the
        // block's size. It was digested above in its original form.
        u32 newCdOff = cdOff + block.length();
        for (u32 k = (u32)0; k < len - eo; k = k + (u32)1)
            {
            if (k >= (u32)16 && k < (u32)20)
                out.appendByte((u8)((newCdOff >> ((k - (u32)16) * (u32)8)) & (u32)$FF));
            else
                out.appendByte(apk.byteAt(eo + k));
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
    static Data* derBytes(Data* v, u32 tag)
        {
        return ApkSign.derTagged(tag, v);
        }
    static Data* derStr(String* s, u32 tag)
        {
        Data* b = new Data();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            b.appendByte(s.byteAt(i));
        return ApkSign.derTagged(tag, b);
        }
    static Data* derOid(Data* body)
        {
        return ApkSign.derTagged((u32)$06, body);
        }
    static Data* oidRsaEncryption(void)
        {
        Data* o = new Data();
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
            o.appendByte((u8)(v[i]));
        return ApkSign.derOid(o);
        }
    static Data* oidSha256Rsa(void)
        {
        Data* o = new Data();
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
            o.appendByte((u8)(v[i]));
        return ApkSign.derOid(o);
        }
    static Data* oidCommonName(void)
        {
        Data* o = new Data();
        o.appendByte((u8)$55);
        o.appendByte((u8)$04);
        o.appendByte((u8)$03);
        return ApkSign.derOid(o);
        }

    static Data* selfSignedCert(Data* nBytes, Data* eBytes, Data* dBytes, String* cn)
        {
        Data* sigAlgoInner = new Data();
        apkAppend(sigAlgoInner, ApkSign.oidSha256Rsa());
        apkAppend(sigAlgoInner, ApkSign.derTagged((u32)$05, new Data())); // NULL
        Data* sigAlgo = ApkSign.derTagged((u32)$30, sigAlgoInner);

        // Name ::= SEQUENCE { SET { SEQUENCE { OID commonName, UTF8String } } }
        Data* rdnInner = new Data();
        apkAppend(rdnInner, ApkSign.oidCommonName());
        apkAppend(rdnInner, ApkSign.derStr(cn, (u32)$0C)); // UTF8String
        Data* rdnSeq = ApkSign.derTagged((u32)$30, rdnInner);
        Data* rdnSet = ApkSign.derTagged((u32)$31, rdnSeq);
        Data* name = ApkSign.derTagged((u32)$30, rdnSet);

        Data* validInner = new Data();
        apkAppend(validInner, ApkSign.derStr(String.withCString("200101000000Z"), (u32)$17));
        apkAppend(validInner, ApkSign.derStr(String.withCString("20990101000000Z"), (u32)$18));
        Data* validity = ApkSign.derTagged((u32)$30, validInner);

        Data* verInner = new Data();
        Data* two = new Data();
        two.appendByte((u8)2);
        apkAppend(verInner, ApkSign.derTagged((u32)$02, two));
        Data* version = ApkSign.derTagged((u32)$A0, verInner); // [0] EXPLICIT

        Data* serial = new Data();
        serial.appendByte((u8)1);

        Data* tbsInner = new Data();
        apkAppend(tbsInner, version);
        apkAppend(tbsInner, ApkSign.derTagged((u32)$02, serial));
        apkAppend(tbsInner, sigAlgo);
        apkAppend(tbsInner, name); // issuer
        apkAppend(tbsInner, validity);
        apkAppend(tbsInner, name); // subject == issuer
        apkAppend(tbsInner, ApkSign.spki(nBytes, eBytes));
        Data* tbs = ApkSign.derTagged((u32)$30, tbsInner);

        Data* digest = apkSha256(tbs, (u32)0, tbs.length());
        Bignum* n = Bignum.fromBytes(nBytes);
        Bignum* d = Bignum.fromBytes(dBytes);
        Data* sig = ApkSign.rsaSignSha256(digest, n, d, nBytes.length());

        Data* bits = new Data();
        bits.appendByte((u8)0);
        apkAppend(bits, sig);
        Data* sigBits = ApkSign.derTagged((u32)$03, bits);

        Data* all = new Data();
        apkAppend(all, tbs);
        apkAppend(all, sigAlgo);
        apkAppend(all, sigBits);
        return ApkSign.derTagged((u32)$30, all);
        }

    // DER: SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { SEQUENCE { n, e } } }
    static Data* derLen(u32 n)
        {
        Data* o = new Data();
        if (n < (u32)128)
            {
            o.appendByte((u8)(n));
            return o;
            }
        if (n < (u32)256)
            {
            o.appendByte((u8)$81);
            o.appendByte((u8)(n));
            return o;
            }
        if (n < (u32)65536)
            {
            o.appendByte((u8)$82);
            o.appendByte((u8)((n >> (u32)8) & (u32)$FF));
            o.appendByte((u8)(n & (u32)$FF));
            return o;
            }
        o.appendByte((u8)$83);
        o.appendByte((u8)((n >> (u32)16) & (u32)$FF));
        o.appendByte((u8)((n >> (u32)8) & (u32)$FF));
        o.appendByte((u8)(n & (u32)$FF));
        return o;
        }
    static Data* derTagged(u32 tag, Data* body)
        {
        Data* o = new Data();
        o.appendByte((u8)(tag));
        apkAppend(o, ApkSign.derLen(body.length()));
        apkAppend(o, body);
        return o;
        }
    // An INTEGER is signed, so a high top bit needs a leading zero or the value
    // reads as negative.
    static Data* derInteger(Data* v)
        {
        Data* b = new Data();
        u32 s = (u32)0;
        while (s + (u32)1 < v.length() && (u32)v.byteAt(s) == (u32)0)
            s = s + (u32)1;
        if (((u32)v.byteAt(s) & (u32)$80) != (u32)0)
            b.appendByte((u8)0);
        for (u32 k = s; k < v.length(); k = k + (u32)1)
            b.appendByte(v.byteAt(k));
        return ApkSign.derTagged((u32)$02, b);
        }
    static Data* spki(Data* nBytes, Data* eBytes)
        {
        Data* rsaPub = new Data();
        apkAppend(rsaPub, ApkSign.derInteger(nBytes));
        apkAppend(rsaPub, ApkSign.derInteger(eBytes));
        Data* pubSeq = ApkSign.derTagged((u32)$30, rsaPub);

        Data* algo = new Data();
        apkAppend(algo, ApkSign.oidRsaEncryption());
        apkAppend(algo, ApkSign.derTagged((u32)$05, new Data())); // NULL
        Data* algoSeq = ApkSign.derTagged((u32)$30, algo);

        Data* bits = new Data();
        bits.appendByte((u8)0); // unused bits
        apkAppend(bits, pubSeq);
        Data* bitStr = ApkSign.derTagged((u32)$03, bits);

        Data* all = new Data();
        apkAppend(all, algoSeq);
        apkAppend(all, bitStr);
        return ApkSign.derTagged((u32)$30, all);
        }
    }
