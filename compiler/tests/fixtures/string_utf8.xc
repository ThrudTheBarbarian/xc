//xtc-flags: target=arm64
// string_utf8.xc — the String UTF-8 layer (private:docs/Design/string-utf8.md).
//
// Byte semantics stay byte semantics (length() counts bytes); the code-point
// layer is additive. Every rejection class the strict decoder claims is
// exercised — overlong, surrogate, beyond U+10FFFF, truncation, bare
// continuation — plus the maximal-subpart repair and the encoding edges
// (Latin-1, ASCII, UTF-16 both orders). Hosted targets only: xt6502 keeps
// its own byte-oriented String.
#import "Stdio.xc"
#import "String.xc"
#import "Data.xc"

void main(void)
{
    // T1: bytes vs code points on "aé€😀" (1+2+3+4 bytes).
    String* s = String.withCString("aé€😀");
    Stdio.printf("T1 %lu %lu %d\n", s.byteLength(), s.charCount(),
                 s.isValidUtf8() ? (i16)1 : (i16)0);

    // T2: forward walk — each code point in hex.
    u32 i = (u32)0;
    Stdio.printf("T2");
    while (i < s.byteLength()) {
        Stdio.printf(" %lx", s.charAtByte(i));
        i = s.nextCharByte(i);
    }
    Stdio.printf("\n");

    // T3: backward walk from the end.
    Stdio.printf("T3");
    i = s.byteLength();
    while (i > (u32)0) {
        i = s.prevCharByte(i);
        Stdio.printf(" %lx", s.charAtByte(i));
    }
    Stdio.printf("\n");

    // T4: byteIndexOfChar / isCharBoundary. 😀 starts at byte 6; byte 2 continues é.
    Stdio.printf("T4 %lu %lu %d %d\n", s.byteIndexOfChar((u32)3), s.byteIndexOfChar((u32)9),
                 s.isCharBoundary((u32)6) ? (i16)1 : (i16)0,
                 s.isCharBoundary((u32)2) ? (i16)1 : (i16)0);

    // T5: rebuild from code points; must equal the literal byte-for-byte.
    String* r = String.withCString("");
    r.appendChar((u32)0x61);
    r.appendChar((u32)0xE9);
    r.appendChar((u32)0x20AC);
    r.appendChar((u32)0x1F600);
    Stdio.printf("T5 %d\n", r.equals(s) ? (i16)1 : (i16)0);

    // T6: the encoder never manufactures invalid UTF-8 — a surrogate and an
    // out-of-range value both encode U+FFFD.
    String* w = String.withChar((u32)0xD800);
    String* v = String.withChar((u32)0x110000);
    Stdio.printf("T6 %lx %lx\n", w.charAtByte((u32)0), v.charAtByte((u32)0));

    // T7: every strict-decoder rejection, one buffer each.
    u8 overlong[2];  overlong[0] = (u8)$C0; overlong[1] = (u8)$AF;   // overlong '/'
    u8 surr[3];      surr[0] = (u8)$ED; surr[1] = (u8)$A0; surr[2] = (u8)$80; // U+D800
    u8 range[4];     range[0] = (u8)$F5; range[1] = (u8)$80; range[2] = (u8)$80; range[3] = (u8)$80;
    u8 trunc[2];     trunc[0] = (u8)$E2; trunc[1] = (u8)$82;         // € missing a byte
    u8 bare[1];      bare[0] = (u8)$80;                              // continuation alone
    String* b1 = String.withBytes(&overlong[0], (u32)2);
    String* b2 = String.withBytes(&surr[0], (u32)3);
    String* b3 = String.withBytes(&range[0], (u32)4);
    String* b4 = String.withBytes(&trunc[0], (u32)2);
    String* b5 = String.withBytes(&bare[0], (u32)1);
    Stdio.printf("T7 %d%d%d%d%d\n",
                 b1.isValidUtf8() ? (i16)1 : (i16)0, b2.isValidUtf8() ? (i16)1 : (i16)0,
                 b3.isValidUtf8() ? (i16)1 : (i16)0, b4.isValidUtf8() ? (i16)1 : (i16)0,
                 b5.isValidUtf8() ? (i16)1 : (i16)0);

    // T8: maximal-subpart repair — a truncated 3-byte lead plus 'A' becomes
    // exactly ONE U+FFFD then 'A'; valid input comes back identical.
    u8 mang[3]; mang[0] = (u8)$E2; mang[1] = (u8)$82; mang[2] = (u8)'A';
    String* m = String.withBytes(&mang[0], (u32)3);
    String* fixed = m.sanitizedUtf8();
    Stdio.printf("T8 %lu %lx %lx %d\n", fixed.charCount(),
                 fixed.charAtByte((u32)0), fixed.charAtByte(fixed.byteIndexOfChar((u32)1)),
                 s.sanitizedUtf8().equals(s) ? (i16)1 : (i16)0);

    // T9: Latin-1 in — "caf\xE9" decodes to café; ASCII in — a high byte
    // repairs to U+FFFD.
    u8 lat[4]; lat[0] = (u8)'c'; lat[1] = (u8)'a'; lat[2] = (u8)'f'; lat[3] = (u8)$E9;
    String* cafe = String.withEncodedBytes(&lat[0], (u32)4, ENC_LATIN1);
    String* asc  = String.withEncodedBytes(&lat[0], (u32)4, ENC_ASCII);
    Stdio.printf("T9 %d %lx %lx\n", cafe.equals(String.withCString("café")) ? (i16)1 : (i16)0,
                 cafe.charAtByte((u32)3), asc.charAtByte((u32)3));

    // T10: UTF-16LE in, surrogate pair included: "€😀" is AC 20 3D D8 00 DE.
    u8 u16le[6];
    u16le[0] = (u8)$AC; u16le[1] = (u8)$20;
    u16le[2] = (u8)$3D; u16le[3] = (u8)$D8;
    u16le[4] = (u8)$00; u16le[5] = (u8)$DE;
    String* d = String.withEncodedBytes(&u16le[0], (u32)6, ENC_UTF16LE);
    Stdio.printf("T10 %lu %lx %lx\n", d.charCount(), d.charAtByte((u32)0),
                 d.charAtByte(d.byteIndexOfChar((u32)1)));

    // T11: UTF-16BE of the same text; unpaired high surrogate and an odd
    // trailing byte each repair to one U+FFFD.
    u8 u16be[6];
    u16be[0] = (u8)$20; u16be[1] = (u8)$AC;
    u16be[2] = (u8)$D8; u16be[3] = (u8)$3D;
    u16be[4] = (u8)$DE; u16be[5] = (u8)$00;
    String* e = String.withEncodedBytes(&u16be[0], (u32)6, ENC_UTF16BE);
    u8 unpaired[3]; unpaired[0] = (u8)$3D; unpaired[1] = (u8)$D8; unpaired[2] = (u8)$41;
    String* f = String.withEncodedBytes(&unpaired[0], (u32)3, ENC_UTF16LE);
    Stdio.printf("T11 %d %lu %lx\n", e.equals(d) ? (i16)1 : (i16)0,
                 f.charCount(), f.charAtByte((u32)0));

    // T12: exports — on Data, per the house rule (Data imports String; the
    // reverse import is a cycle). UTF-8 out is a byte copy; UTF-16LE out
    // round-trips the surrogate pair; Latin-1 substitutes '?' for what it
    // cannot say.
    Data* du8 = Data.withStringEncoded(s, ENC_UTF8);
    Data* dle = Data.withStringEncoded(s, ENC_UTF16LE);
    Data* dl1 = Data.withStringEncoded(s, ENC_LATIN1);
    Stdio.printf("T12 %lu %lu %lu %x %x %x %x\n",
                 du8.length(), dle.length(), dl1.length(),
                 (i16)dle.byteAt((u32)6), (i16)dle.byteAt((u32)7),
                 (i16)dl1.byteAt((u32)2), (i16)dl1.byteAt((u32)3));
}
