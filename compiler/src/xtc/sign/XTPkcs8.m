//
//  XTPkcs8.m — see XTPkcs8.h.
//

#import "XTPkcs8.h"
#import "XTDer.h"
#import "XTDerReader.h"
#import "XTCrypto.h"

// ─────────────────────────────────────────────────────────────────────────
//  HMAC + PBKDF2 (over XTCrypto's SHA-1 / SHA-256)
// ─────────────────────────────────────────────────────────────────────────
typedef NSData *(^HashFn)(NSData *);

static NSData *hmac(HashFn h, NSUInteger blockSize, NSData *key, NSData *msg) {
    NSMutableData *k = [key mutableCopy];
    if (k.length > blockSize) k = [[h(k) mutableCopy] mutableCopy];
    if (k.length < blockSize) [k increaseLengthBy:blockSize - k.length];
    NSMutableData *ipad = [NSMutableData dataWithLength:blockSize];
    NSMutableData *opad = [NSMutableData dataWithLength:blockSize];
    const uint8_t *kp = k.bytes; uint8_t *ip = ipad.mutableBytes, *op = opad.mutableBytes;
    for (NSUInteger i = 0; i < blockSize; i++) { ip[i] = kp[i] ^ 0x36; op[i] = kp[i] ^ 0x5c; }
    NSMutableData *inner = [ipad mutableCopy]; [inner appendData:msg];
    NSMutableData *outer = [opad mutableCopy]; [outer appendData:h(inner)];
    return h(outer);
}

static NSData *pbkdf2(HashFn h, NSUInteger hLen, NSUInteger blockSize,
                      NSData *pw, NSData *salt, uint32_t iters, NSUInteger dkLen) {
    NSMutableData *dk = [NSMutableData data];
    uint32_t block = 1;
    while (dk.length < dkLen) {
        NSMutableData *t = [salt mutableCopy];
        uint8_t be[4] = {(uint8_t)(block>>24),(uint8_t)(block>>16),(uint8_t)(block>>8),(uint8_t)block};
        [t appendBytes:be length:4];
        NSData *u = hmac(h, blockSize, pw, t);
        NSMutableData *acc = [u mutableCopy];
        uint8_t *ap = acc.mutableBytes;
        for (uint32_t i = 1; i < iters; i++) {
            u = hmac(h, blockSize, pw, u);
            const uint8_t *up = u.bytes;
            for (NSUInteger j = 0; j < hLen; j++) ap[j] ^= up[j];
        }
        [dk appendData:acc];
        block++;
    }
    return [dk subdataWithRange:NSMakeRange(0, dkLen)];
}

// ─────────────────────────────────────────────────────────────────────────
//  DES / 3DES-CBC (decrypt)
// ─────────────────────────────────────────────────────────────────────────
static const uint8_t IP[64]={58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7};
static const uint8_t FP[64]={40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25};
static const uint8_t E[48]={32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1};
static const uint8_t P[32]={16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25};
static const uint8_t PC1[56]={57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4};
static const uint8_t PC2[48]={14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32};
static const uint8_t SHIFTS[16]={1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1};
static const uint8_t SBOX[8][64]={
{14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13},
{15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9},
{10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12},
{7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14},
{2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3},
{12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13},
{4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12},
{13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11}};

static uint64_t permute(uint64_t in, const uint8_t *tbl, int n, int inBits) {
    uint64_t out = 0;
    for (int i = 0; i < n; i++) {
        int bit = (in >> (inBits - tbl[i])) & 1;
        out = (out << 1) | bit;
    }
    return out;
}

static void des_keys(const uint8_t k[8], uint64_t round[16]) {
    uint64_t key = 0; for (int i = 0; i < 8; i++) key = (key << 8) | k[i];
    uint64_t cd = permute(key, PC1, 56, 64);
    uint32_t c = (uint32_t)(cd >> 28) & 0xFFFFFFF, d = (uint32_t)cd & 0xFFFFFFF;
    for (int i = 0; i < 16; i++) {
        int s = SHIFTS[i];
        c = ((c << s) | (c >> (28 - s))) & 0xFFFFFFF;
        d = ((d << s) | (d >> (28 - s))) & 0xFFFFFFF;
        uint64_t cdc = ((uint64_t)c << 28) | d;
        round[i] = permute(cdc, PC2, 48, 56);
    }
}

static uint64_t des_crypt(uint64_t block, const uint64_t round[16], BOOL decrypt) {
    uint64_t ip = permute(block, IP, 64, 64);
    uint32_t l = (uint32_t)(ip >> 32), r = (uint32_t)ip;
    for (int i = 0; i < 16; i++) {
        uint64_t rk = round[decrypt ? 15 - i : i];
        uint64_t er = permute(r, E, 48, 32) ^ rk;
        uint32_t out = 0;
        for (int b = 0; b < 8; b++) {
            uint8_t six = (er >> (42 - 6*b)) & 0x3F;
            uint8_t rowv = ((six & 0x20) >> 4) | (six & 1);
            uint8_t col = (six >> 1) & 0xF;
            out = (out << 4) | SBOX[b][rowv*16 + col];
        }
        uint32_t f = (uint32_t)permute(out, P, 32, 32);
        uint32_t nl = r; r = l ^ f; l = nl;
    }
    uint64_t pre = ((uint64_t)r << 32) | l;   // note swap
    return permute(pre, FP, 64, 64);
}

static NSData *des3_cbc_encrypt(NSData *key24, NSData *iv8, NSData *pt) {
    if (key24.length != 24 || iv8.length != 8 || (pt.length % 8)) return nil;
    const uint8_t *k = key24.bytes;
    uint64_t rk1[16], rk2[16], rk3[16];
    des_keys(k, rk1); des_keys(k+8, rk2); des_keys(k+16, rk3);
    const uint8_t *ivp = iv8.bytes;
    uint64_t prev = 0; for (int i=0;i<8;i++) prev=(prev<<8)|ivp[i];
    NSMutableData *out = [NSMutableData dataWithLength:pt.length];
    const uint8_t *pp = pt.bytes; uint8_t *op = out.mutableBytes;
    for (NSUInteger off = 0; off < pt.length; off += 8) {
        uint64_t pblk = 0; for (int i=0;i<8;i++) pblk=(pblk<<8)|pp[off+i];
        uint64_t x = pblk ^ prev;                 // CBC
        uint64_t c = des_crypt(x, rk1, NO);        // EDE encrypt: E(k1) D(k2) E(k3)
        c = des_crypt(c, rk2, YES);
        c = des_crypt(c, rk3, NO);
        prev = c;
        for (int i=0;i<8;i++) op[off+i] = (uint8_t)(c >> (56 - 8*i));
    }
    return out;
}

static NSData *des3_cbc_decrypt(NSData *key24, NSData *iv8, NSData *ct) {
    if (key24.length != 24 || iv8.length != 8 || (ct.length % 8)) return nil;
    const uint8_t *k = key24.bytes;
    uint64_t rk1[16], rk2[16], rk3[16];
    des_keys(k, rk1); des_keys(k+8, rk2); des_keys(k+16, rk3);
    const uint8_t *ivp = iv8.bytes;
    uint64_t prev = 0; for (int i=0;i<8;i++) prev=(prev<<8)|ivp[i];
    NSMutableData *out = [NSMutableData dataWithLength:ct.length];
    const uint8_t *cp = ct.bytes; uint8_t *op = out.mutableBytes;
    for (NSUInteger off = 0; off < ct.length; off += 8) {
        uint64_t cblk = 0; for (int i=0;i<8;i++) cblk=(cblk<<8)|cp[off+i];
        uint64_t p = des_crypt(cblk, rk3, YES);   // EDE decrypt: D(k3) E(k2) D(k1)
        p = des_crypt(p, rk2, NO);
        p = des_crypt(p, rk1, YES);
        uint64_t pt = p ^ prev; prev = cblk;
        for (int i=0;i<8;i++) op[off+i] = (uint8_t)(pt >> (56 - 8*i));
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────────────
//  PBES2 EncryptedPrivateKeyInfo
// ─────────────────────────────────────────────────────────────────────────
@implementation XTPkcs8

+ (nullable NSData *)decryptEncryptedPrivateKeyInfo:(NSData *)der
                                         passphrase:(NSString *)passphrase
                                              error:(NSString *_Nullable*_Nullable)error {
    #define FAIL(m) do { if (error) *error = m; return nil; } while (0)
    // EncryptedPrivateKeyInfo ::= SEQ { encryptionAlgorithm AlgId, encryptedData OCTET }
    XTDerReader *top = [[XTDerReader alloc] initWithData:der];
    uint8_t t;
    XTDerReader *epki = [top readConstructed:&t]; if (!epki) FAIL(@"not EncryptedPrivateKeyInfo");
    XTDerReader *alg = [epki readConstructed:&t]; if (!alg) FAIL(@"no encryptionAlgorithm");
    NSData *algOid = [alg readTLV:&t];            if (!algOid || t != 0x06) FAIL(@"no alg OID");
    // PBES2 OID = 1.2.840.113549.1.5.13
    static const uint8_t pbes2[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x05,0x0d};
    if (algOid.length != sizeof pbes2 || memcmp(algOid.bytes, pbes2, sizeof pbes2))
        FAIL(@"only PBES2 is supported");
    XTDerReader *params = [alg readConstructed:&t];  // SEQ { keyDeriv, encScheme }
    XTDerReader *kdf = [params readConstructed:&t];    // SEQ { PBKDF2 oid, SEQ{salt,iters,[prf]} }
    NSData *kdfOid = [kdf readTLV:&t];
    static const uint8_t pbkdf2Oid[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x05,0x0c};
    if (kdfOid.length != sizeof pbkdf2Oid || memcmp(kdfOid.bytes, pbkdf2Oid, sizeof pbkdf2Oid))
        FAIL(@"only PBKDF2 key derivation is supported");
    XTDerReader *kdfp = [kdf readConstructed:&t];
    NSData *salt = [kdfp readTLV:&t]; if (t != 0x04) FAIL(@"bad PBKDF2 salt");
    NSData *iterData = [kdfp readTLV:&t]; if (t != 0x02) FAIL(@"bad PBKDF2 iterations");
    uint32_t iters = 0; const uint8_t *ip = iterData.bytes;
    for (NSUInteger i = 0; i < iterData.length; i++) iters = (iters << 8) | ip[i];
    // Optional PRF AlgorithmIdentifier — default HMAC-SHA1.
    BOOL prfSha256 = NO;
    uint8_t peek;
    if ([kdfp peekNextTag:&peek] && peek == 0x30) {
        XTDerReader *prf = [kdfp readConstructed:&t];
        NSData *prfOid = [prf readTLV:&t];
        static const uint8_t hmacSha256[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x02,0x09};
        if (prfOid.length == sizeof hmacSha256 && !memcmp(prfOid.bytes, hmacSha256, sizeof hmacSha256))
            prfSha256 = YES;
    }
    // encryptionScheme SEQ { cipherOid, IV OCTET }
    XTDerReader *enc = [params readConstructed:&t];
    NSData *cipherOid = [enc readTLV:&t];
    NSData *iv = [enc readTLV:&t]; if (t != 0x04) FAIL(@"bad cipher IV");
    static const uint8_t des3[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x03,0x07};   // des-ede3-cbc
    BOOL is3des = (cipherOid.length == sizeof des3 && !memcmp(cipherOid.bytes, des3, sizeof des3));
    if (!is3des) FAIL(@"only des-ede3-cbc is supported (extend for AES if needed)");

    // encryptedData OCTET STRING
    NSData *ct = [epki readTLV:&t]; if (!ct || t != 0x04) FAIL(@"no encryptedData");

    HashFn sha1 = ^(NSData *d){ return [XTCrypto sha1:d]; };
    HashFn sha256 = ^(NSData *d){ return [XTCrypto sha256:d]; };
    NSData *pw = [passphrase dataUsingEncoding:NSUTF8StringEncoding];
    NSData *dk = prfSha256
        ? pbkdf2(sha256, 32, 64, pw, salt, iters, 24)
        : pbkdf2(sha1, 20, 64, pw, salt, iters, 24);
    NSData *plain = des3_cbc_decrypt(dk, iv, ct);
    if (!plain || plain.length == 0) FAIL(@"decryption failed");
    // Strip PKCS#7 padding.
    const uint8_t *pp = plain.bytes; uint8_t pad = pp[plain.length - 1];
    if (pad == 0 || pad > 8 || pad > plain.length) FAIL(@"bad passphrase (padding)");
    for (NSUInteger i = plain.length - pad; i < plain.length; i++)
        if (pp[i] != pad) FAIL(@"bad passphrase (padding)");
    return [plain subdataWithRange:NSMakeRange(0, plain.length - pad)];
    #undef FAIL
}

+ (nullable NSData *)encryptPrivateKey:(NSData *)keyDer
                            passphrase:(NSString *)passphrase
                                 error:(NSString *_Nullable*_Nullable)error {
    #define FAILE(m) do { if (error) *error = m; return nil; } while (0)
    // Random salt (8) + IV (8) from the OS.
    uint8_t rnd[16];
    FILE *f = fopen("/dev/urandom", "rb");
    if (!f || fread(rnd, 1, 16, f) != 16) { if (f) fclose(f); FAILE(@"no OS randomness (/dev/urandom)"); }
    fclose(f);
    NSData *salt = [NSData dataWithBytes:rnd length:8];
    NSData *iv   = [NSData dataWithBytes:rnd+8 length:8];
    uint32_t iters = 2048;

    NSData *pw = [passphrase dataUsingEncoding:NSUTF8StringEncoding];
    HashFn sha1 = ^(NSData *d){ return [XTCrypto sha1:d]; };
    NSData *dk = pbkdf2(sha1, 20, 64, pw, salt, iters, 24);
    // PKCS#7 pad to 8.
    NSMutableData *padded = [keyDer mutableCopy];
    uint8_t pad = 8 - (keyDer.length % 8); if (pad == 0) pad = 8;
    for (int i = 0; i < pad; i++) [padded appendBytes:&pad length:1];
    NSData *ct = des3_cbc_encrypt(dk, iv, padded);
    if (!ct) FAILE(@"3DES encrypt failed");

    // EncryptedPrivateKeyInfo DER (PBES2 { PBKDF2(salt,iters), des-ede3-cbc(IV) }).
    NSData *kdf = [XTDer sequence:@[
        [XTDer oid:@"1.2.840.113549.1.5.12"],   // PBKDF2
        [XTDer sequence:@[[XTDer octetString:salt], [XTDer integerFromU64:iters]]]]];
    NSData *enc = [XTDer sequence:@[
        [XTDer oid:@"1.2.840.113549.3.7"],       // des-ede3-cbc
        [XTDer octetString:iv]]];
    NSData *algid = [XTDer sequence:@[
        [XTDer oid:@"1.2.840.113549.1.5.13"],    // PBES2
        [XTDer sequence:@[kdf, enc]]]];
    return [XTDer sequence:@[algid, [XTDer octetString:ct]]];
    #undef FAILE
}

@end
