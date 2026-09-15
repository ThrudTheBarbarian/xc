// strings.xc — the 0.4 String: bytes and characters, named apart.
#import "Stdio.xc"
#import "Foundation.xc"

i32 main(void)
{
    // "héllo⚡" — 6 characters, 9 bytes: é is 2 bytes, ⚡ is 3.
    String* s = String.withCString("h");
    s.appendChar((u32)$E9);          // é   U+00E9, encoded as 2 bytes
    s.appendCString("llo");
    s.appendChar((u32)$26A1);        // ⚡  U+26A1, encoded as 3 bytes

    Stdio.printf("bytes %d, chars %d\n",
                 (i16)s.byteLength(), (i16)s.charCount());

    // Byte in the name = byte semantics; Char = code points.
    Stdio.printf("byteAt(1) %lx, charAt(1) U+%lx\n",
                 (u32)s.byteAt((u32)1), s.charAt((u32)1));

    Stdio.printf("slice chars '%s'\n",
                 s.substringChars((u32)1, (u32)2).cString());

    // Walking characters by byte index — no O(n^2) charAt loop.
    u32 i = (u32)0;
    while (i < s.byteLength()) {
        Stdio.printf("U+%lx ", s.charAtByte(i));
        i = s.nextCharByte(i);
    }
    Stdio.printf("\n");

    // Malformed bytes read as U+FFFD; sanitizedUtf8 repairs a copy.
    String* bad = String.withCString("a");
    bad.appendByte((u8)$C3);         // a lead byte with no continuation
    bad.appendCString("z");
    Stdio.printf("valid %d, chars %d, repaired chars %d\n",
                 (i16)(bad.isValidUtf8() ? 1 : 0),
                 (i16)bad.charCount(),
                 (i16)bad.sanitizedUtf8().charCount());

    // Other encodings transcode at the edge; inside it is always UTF-8.
    u8 latin[3];
    latin[0] = (u8)'c'; latin[1] = (u8)$E9; latin[2] = (u8)'!';   // "cé!" in Latin-1
    String* dec = String.withEncodedBytes(&latin[0], (u32)3, ENC_LATIN1);
    Stdio.printf("latin-1 in: '%s' (%d bytes)\n",
                 dec.cString(), (i16)dec.byteLength());

    Data* enc = Data.withStringEncoded(dec, ENC_ASCII);           // é -> '?'
    Stdio.printf("ascii out: %s\n", enc.hexString().cString());
    return 0;
}
