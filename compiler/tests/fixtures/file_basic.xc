// file_basic.xc — Stream FILE* / fputc / fputs / fread / fwrite /
// fseek / fclose / feof coverage. The keyboard-side tests use
// MemoryStream — an in-memory FILE subclass declared inline here
// so the fixture exercises the polymorphic dispatch path without
// blocking on real keyboard input.
//
//   T1  stdout singleton — same FILE@ across calls.
//   T2  fputs through stdout writes the requested bytes.
//   T3  fputc through stdout returns the byte cast to i16.
//   T4  fseek on stdout returns EOF (unseekable).
//   T5  feof on stdout is false.
//   T6  Custom MemoryStream subclass — read/write round-trip
//       through fputc / fgetc / fwrite / fread.
//   T7  MemoryStream EOF: fgetc past the end returns EOF and
//       feof() flips to true.

#import "FILE.xc"
#import "Assert.xc"

// ─── In-memory FILE subclass for the read-side tests ───────────
// Holds a 64-byte buffer, walks `_pos` forward on each operation.
// EOF is simply pos >= len. The buffer is small enough that all
// indexing fits in u8 — works around a codegen quirk where u16-
// indexed ivar-array stores from inside a class method body don't
// take effect (separately logged).
class MemoryStream : FILE
{
    u8 _buf[64];
    u8 _len;        // bytes currently in the stream (≤ 64)

    void init(void)
    {
        super.init();
        _len = (u8)0;
    }

    i16 write(u8* src, u16 count)
    {
        u8 pos8 = (u8)_pos;
        u8 cnt8 = (u8)count;
        u8 remain = (u8)64 - pos8;
        if (cnt8 > remain) cnt8 = remain;
        u8 i = (u8)0;
        while (i < cnt8) {
            _buf[pos8 + i] = src[i];
            i = i + (u8)1;
        }
        _pos = _pos + (u16)cnt8;
        if ((u8)_pos > _len) _len = (u8)_pos;
        return (i16)((u16)cnt8);
    }

    i16 read(u8* dst, u16 count)
    {
        u8 pos8 = (u8)_pos;
        if (pos8 >= _len) {
            _flags = _flags | (u8)F_EOF;
            return (i16)0;
        }
        u8 cnt8 = (u8)count;
        u8 avail = _len - pos8;
        if (cnt8 > avail) cnt8 = avail;
        u8 i = (u8)0;
        while (i < cnt8) {
            dst[i] = _buf[pos8 + i];
            i = i + (u8)1;
        }
        _pos = _pos + (u16)cnt8;
        if ((u8)_pos >= _len) _flags = _flags | (u8)F_EOF;
        return (i16)((u16)cnt8);
    }

    i16 seek(i16 offset, u8 whence)
    {
        i16 newPos;
        if (whence == (u8)SEEK_SET) {
            newPos = offset;
        } else if (whence == (u8)SEEK_CUR) {
            newPos = (i16)_pos + offset;
        } else {
            newPos = (i16)((u16)_len) + offset;
        }
        if (newPos < (i16)0) return EOF;
        if ((u16)newPos > (u16)_len) return EOF;
        _pos = (u16)newPos;
        _flags = _flags & (u8)$FE;
        return (i16)_pos;
    }

    // Single-byte fast paths. FILE.writeChar / readChar default to
    // EOF (see FILE.xc for the address-of-local hazard rationale);
    // every concrete subclass provides its own.
    i16 writeChar(u8 c)
    {
        u8 pos8 = (u8)_pos;
        if (pos8 >= (u8)64) return EOF;
        _buf[pos8] = c;
        _pos = _pos + (u16)1;
        if ((u8)_pos > _len) _len = (u8)_pos;
        return (i16)((u16)c);
    }

    i16 readChar(void)
    {
        u8 pos8 = (u8)_pos;
        if (pos8 >= _len) {
            _flags = _flags | (u8)F_EOF;
            return EOF;
        }
        u8 c = _buf[pos8];
        _pos = _pos + (u16)1;
        if ((u8)_pos >= _len) _flags = _flags | (u8)F_EOF;
        return (i16)((u16)c);
    }
}

void main(void)
{
    Assert.reset();

    // ── T1: stdout singleton stability ─────────────────────────
    FILE* a = Stream.stdout();
    FILE* b = Stream.stdout();
    Assert.isTrue(a == b);                             // T1

    // ── T2: fputs through stdout writes the bytes ──────────────
    // We can't directly probe screen RAM portably, but if the
    // call returns success (>=0) the path executed without
    // hanging or trapping.
    i16 r2 = Stream.fputs("[T2]\n", a);
    Assert.isTrue(r2 >= (i16)0);                       // T2

    // ── T3: fputc returns the written byte cast to i16 ─────────
    i16 r3 = Stream.fputc((u8)$58, a);                  // 'X'
    Assert.isEqual(r3, (i16)$58);                      // T3
    Stream.fputc((u8)$0A, a);                           // newline

    // ── T4: fseek on an unseekable stream returns EOF ──────────
    i16 r4 = Stream.fseek(a, (i16)0, (u8)SEEK_SET);
    Assert.isEqual(r4, EOF);                           // T4

    // ── T5: feof on stdout is false (writes don't EOF) ─────────
    Assert.isFalse(Stream.feof(a));                     // T5

    // ── T6: MemoryStream round-trip via FILE@ ──────────────────
    FILE* ms = (FILE*)new MemoryStream();
    Stream.fputc((u8)$48, ms);                          // 'H'
    Stream.fputc((u8)$69, ms);                          // 'i'
    u8 wbuf[3];
    wbuf[0] = (u8)$21;                                 // '!'
    wbuf[1] = (u8)$0A;                                 // \n
    wbuf[2] = (u8)$00;
    Stream.fwrite(&wbuf[0], (u16)3, ms);

    // Rewind and read everything back
    Stream.fseek(ms, (i16)0, (u8)SEEK_SET);
    u8 rbuf[8];
    i16 nread = Stream.fread(&rbuf[0], (u16)8, ms);
    Assert.isEqual(nread, (i16)5);                     // T6a — wrote 5 bytes
    Assert.isEqual((u16)rbuf[0], (u16)$48);            // T6b — 'H'
    Assert.isEqual((u16)rbuf[1], (u16)$69);            // T6c — 'i'
    Assert.isEqual((u16)rbuf[2], (u16)$21);            // T6d — '!'
    Assert.isEqual((u16)rbuf[3], (u16)$0A);            // T6e — '\n'
    Assert.isEqual((u16)rbuf[4], (u16)$00);            // T6f — null

    // ── T7: feof flips on read past end ────────────────────────
    Assert.isTrue(Stream.feof(ms));                     // T7a — at end now
    i16 c = Stream.fgetc(ms);
    Assert.isEqual(c, EOF);                            // T7b — past end → EOF
    Assert.isTrue(Stream.feof(ms));                     // T7c — still EOF

    Stream.fclose(ms);
    Assert.summary();
    return;
}
