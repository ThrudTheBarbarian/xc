// ed25519_rfc8032.xc — Ed25519 (Ed25519.xc) against RFC 8032 §7.1 tests 1-3:
// the public keys and signatures, byte for byte; each verifies; a flipped
// message bit, a flipped signature bit and a non-canonical S (S + L) are
// refused, as is the small-order identity key; and a key from the OS random
// source (SecureRandom.xc) signs and verifies.
//xtc-na: xt6502, m68k, arm9 — no OS random source there (SecureRandom says so)
#import "Stdio.xc"
#import "Ed25519.xc"
#import "SecureRandom.xc"
void hexTo(u8* out, u8* hex)
{
    u32 i = (u32)0;
    while (hex[i * (u32)2] != (u8)0)
    {
        u32 v = (u32)0;
        for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
        {
            u8 c = hex[i * (u32)2 + k];
            v = v * (u32)16 + (c <= (u8)'9' ? (u32)(c - (u8)'0') : (u32)(c - (u8)'a') + (u32)10);
        }
        out[i] = (u8)v;
        i = i + (u32)1;
    }
}
void show(u8* b, u32 n)
{
    for (u32 i = (u32)0; i < n; i = i + (u32)1) Stdio.printf("%02x", (u32)b[i]);
    Stdio.printf("\n");
}
void vec(u8* seedHex, u8* msgHex, u32 mlen)
{
    u8 seed[32];
    u8 msg[64];
    hexTo(&seed[0], seedHex);
    hexTo(&msg[0], msgHex);
    Data* pub = Ed25519.publicKey(&seed[0]);
    Data* sig = Ed25519.sign(&msg[0], mlen, &seed[0]);
    show(pub.bytes(), (u32)32);
    show(sig.bytes(), (u32)64);
    Stdio.printf("verify %d\n", Ed25519.verify(&msg[0], mlen, sig.bytes(), pub.bytes()) ? 1 : 0);
    // a flipped message bit, a flipped signature bit, S + L (non-canonical)
    if (mlen > (u32)0)
    {
        msg[0] = msg[0] ^ (u8)1;
        Stdio.printf("bad msg %d\n", Ed25519.verify(&msg[0], mlen, sig.bytes(), pub.bytes()) ? 1 : 0);
        msg[0] = msg[0] ^ (u8)1;
    }
    u8* s = sig.bytes();
    s[5] = s[5] ^ (u8)4;
    Stdio.printf("bad sig %d\n", Ed25519.verify(&msg[0], mlen, s, pub.bytes()) ? 1 : 0);
    s[5] = s[5] ^ (u8)4;
    u8 L[32];
    hexTo(&L[0], "edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010");
    u32 carry = (u32)0;
    for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
    {
        u32 t = (u32)s[(u32)32 + i] + (u32)L[i] + carry;
        s[(u32)32 + i] = (u8)t;
        carry = t >> (u32)8;
    }
    Stdio.printf("S+L %d\n", Ed25519.verify(&msg[0], mlen, s, pub.bytes()) ? 1 : 0);
}
i32 main(void)
{
    vec("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "", (u32)0);
    vec("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "72", (u32)1);
    vec("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7", "af82", (u32)2);
    // a small-order public key (the identity, y = 1) must be refused
    u8 ident[32];
    for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1) ident[i] = (u8)0;
    ident[0] = (u8)1;
    u8 zsig[64];
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) zsig[i] = (u8)0;
    zsig[0] = (u8)1;
    Stdio.printf("identity key %d\n", Ed25519.verify(&ident[0], (u32)0, &zsig[0], &ident[0]) ? 1 : 0);
    u8 seed[32];
    Stdio.printf("random %d\n", SecureRandom.fill(&seed[0], (u32)32) ? 1 : 0);
    Data* pk = Ed25519.publicKey(&seed[0]);
    Data* sg = Ed25519.sign("hello", (u32)5, &seed[0]);
    Stdio.printf("random roundtrip %d\n", Ed25519.verify("hello", (u32)5, sg.bytes(), pk.bytes()) ? 1 : 0);
    return 0;
}
