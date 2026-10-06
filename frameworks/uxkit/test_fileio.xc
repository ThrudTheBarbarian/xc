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
bool same(Data* a, Data* b)
    {
    if (a == (Data*)0 || b == (Data*)0 || a.length() != b.length())
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
    Data* one = Data.withCapacity((u32)((i32)10000));
    for (i32 i = (i32)0; i < (i32)10000; i = i + (i32)1)
        {
        one.appendByte((u8)((i * (i32)7 + (i32)3) & (i32)$FF));
        }
    // (wasm32 too: under node the web shim's files are real files; a page keeps them in a store)
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
    Data* two = UXStr.toData((u8*)"shorter");
    ck((u8*)"a second save replaces it", UXFileIO.write(path, two));
    ck((u8*)"...entirely: the old tail is gone", same(UXFileIO.read(path), two));
    Data* tn = UXStr.toData(path);
    tn.appendBytes((u8*)".uxtmp", (i32)6);
    tn.appendByte((u8)0);
    ck((u8*)"...and leaves no temporary behind", UXFileIO.read(tn.bytes()) == (Data*)0);
    Data* empty = Data.withCapacity((u32)((i32)1));
    ck((u8*)"an empty file saves", UXFileIO.write(path, empty));
    Data* back = UXFileIO.read(path);
    ck((u8*)"...and reads back empty, not missing", back != (Data*)0 && back.length() == (i32)0);
    ck((u8*)"a missing file reads as null", UXFileIO.read((u8*)"no_such_dir_uxfileio/none.bin") == (Data*)0);
    ck((u8*)"saving into a missing folder fails", !UXFileIO.write((u8*)"no_such_dir_uxfileio/x.bin", one));
#if ARCH_wasm32
#else
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
