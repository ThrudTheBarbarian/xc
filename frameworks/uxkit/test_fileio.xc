// test_fileio.xc — UXFileIO: a whole file written and read back, replaced atomically, and the
// failures failing cleanly.  On the web (no file system) both calls must fail, not pretend.
#import <Stdio.xc>
#import "UXFileIO.xc"

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
bool same(UXData* a, UXData* b)
    {
    if (a == (UXData*)0 || b == (UXData*)0 || a.length() != b.length())
        {
        return false;
        }
    for (i32 i = (i32)0; i < a.length(); i = i + (i32)1)
        {
        if (a.byteAt(i) != b.byteAt(i))
            {
            return false;
            }
        }
    return true;
    }

void main(void)
    {
    gFails = (i32)0;
    // 10000 bytes: more than one 4096-byte read, with every byte value in it (NULs included)
    UXData* one = UXData.withCapacity((i32)10000);
    for (i32 i = (i32)0; i < (i32)10000; i = i + (i32)1)
        {
        one.appendByte((u8)((i * (i32)7 + (i32)3) & (i32)$FF));
        }
#if ARCH_wasm32
    ck((u8*)"the web has no file system: write fails", !UXFileIO.write((u8*)"x.bin", one));
    ck((u8*)"...and so does read", UXFileIO.read((u8*)"x.bin") == (UXData*)0);
#else
    // The first writable place: the working directory, else a device's scratch area.
    u8* path = (u8*)"uxfileio_test.bin";
    if (!UXFileIO.write(path, one))
        {
        path = (u8*)"/data/local/tmp/uxfileio_test.bin";
        if (!UXFileIO.write(path, one))
            {
            path = (u8*)"/tmp/uxfileio_test.bin";
            ck((u8*)"a whole file is written", UXFileIO.write(path, one));
            }
        }
    Stdio.printf("  (at %s)\n", path);
    ck((u8*)"...and read back, byte for byte", same(UXFileIO.read(path), one));
    UXData* two = UXData.fromString((u8*)"shorter");
    ck((u8*)"a second save replaces it", UXFileIO.write(path, two));
    ck((u8*)"...entirely: the old tail is gone", same(UXFileIO.read(path), two));
    UXData* tn = UXData.fromString(path);
    tn.appendBytes((u8*)".uxtmp", (i32)6);
    tn.appendByte((u8)0);
    ck((u8*)"...and leaves no temporary behind", UXFileIO.read(tn.bytes()) == (UXData*)0);
    UXData* empty = UXData.withCapacity((i32)1);
    ck((u8*)"an empty file saves", UXFileIO.write(path, empty));
    UXData* back = UXFileIO.read(path);
    ck((u8*)"...and reads back empty, not missing", back != (UXData*)0 && back.length() == (i32)0);
    ck((u8*)"a missing file reads as null", UXFileIO.read((u8*)"no_such_dir_uxfileio/none.bin") == (UXData*)0);
    ck((u8*)"saving into a missing folder fails", !UXFileIO.write((u8*)"no_such_dir_uxfileio/x.bin", one));
    remove(path);
#endif
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXFileIO -- whole-file read and atomic write\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
