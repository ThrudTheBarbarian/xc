// sha1_base64.xc — Sha1 against the FIPS 180-4 vectors (the empty message,
// "abc", the 56-byte two-block message, a million a's), and Base64 both
// ways including RFC 6455's handshake example, which uses both:
// base64(sha1(key + GUID)) is the Sec-WebSocket-Accept value.
#import "Stdio.xc"
#import "Sha1.xc"
#import "Base64.xc"
void show(u8* label, u8* p, u32 n)
    {
    Stdio.printf("%s %s\n", label, Sha1.hex(p, n).cString());
    }
i32 main(void)
    {
    show("empty ", (u8*)"", (u32)0);
    show("abc   ", (u8*)"abc", (u32)3);
    show("two   ", (u8*)"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", (u32)56);
    u8* million = new u8[1000000];
    for (u32 i = (u32)0; i < (u32)1000000; i++)
        million[i] = (u8)'a';
    show("1e6 a ", million, (u32)1000000);
    delete million;
    // Base64: every tail length, and a round trip through decode
    u8 bytes[6] = {(u8)0xde, (u8)0xad, (u8)0xbe, (u8)0xef, (u8)0x01, (u8)0x02};
    for (u32 n = (u32)0; n <= (u32)6; n++)
        {
        String* e = Base64.encode(bytes, n);
        Data* d = Base64.decode(e);
        bool same = d != 0 && d.length() == n;
        for (u32 i = (u32)0; same && i < n; i++)
            same = d.bytes()[i] == bytes[i];
        Stdio.printf("%u '%s' round trip %d\n", n, e.cString(), (i32)(same ? 1 : 0));
        }
    Stdio.printf("bad: %d %d %d\n", (i32)(Base64.decode(String.withCString("abc")) == 0 ? 1 : 0),
                 (i32)(Base64.decode(String.withCString("ab=c")) == 0 ? 1 : 0),
                 (i32)(Base64.decode(String.withCString("a b=")) == 0 ? 1 : 0));
    // RFC 6455 §1.3: the key, the GUID, and the expected accept value
    String* k = String.withCString("dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    Data* h = Sha1.of(k.cString(), k.byteLength());
    Stdio.printf("accept %s\n", Base64.encodeData(h).cString());
    return (i32)0;
    }
