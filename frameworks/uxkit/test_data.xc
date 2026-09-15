// test_data.xc — UXData growable byte buffer: append, grow, subdata, equality, hex.
#import <Stdio.xc>
#import "UXData.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }
bool streq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && b[i] != (u8)0)
        {
        if (a[i] != b[i])
            {
            return false;
            }
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
void eq(u8* what, u8* got, u8* want)
    {
    if (streq(got, want))
        {
        Stdio.printf("  ok   %s = \"%s\"\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;

    UXData* d = new UXData();
    check("empty length", d.length(), (i32)0);
    d.appendByte((u8)$41);
    d.appendByte((u8)$42);
    d.appendByte((u8)$43); // ABC
    check("length after 3 appends", d.length(), (i32)3);
    check("byteAt(0)", (i32)d.byteAt((i32)0), (i32)$41);
    check("byteAt(2)", (i32)d.byteAt((i32)2), (i32)$43);
    eq("hex of ABC", d.toHex(), (u8*)"414243");

    // grow past initial capacity (8)
    for (i32 i = (i32)0; i < (i32)20; i = i + (i32)1)
        {
        d.appendByte((u8)i);
        }
    check("length after growth", d.length(), (i32)23);
    check("byte survived growth (idx 3 = 0)", (i32)d.byteAt((i32)3), (i32)0);
    check("byte survived growth (idx 22 = 19)", (i32)d.byteAt((i32)22), (i32)19);
    check("byte 0 preserved ($41)", (i32)d.byteAt((i32)0), (i32)$41);

    // from bytes / string
    UXData* s = UXData.fromString((u8*)"hello");
    check("string data length", s.length(), (i32)5);
    eq("hello hex", s.toHex(), (u8*)"68656c6c6f");

    // appendData
    UXData* a = UXData.fromString((u8*)"foo");
    UXData* b = UXData.fromString((u8*)"bar");
    a.appendData(b);
    check("concatenated length", a.length(), (i32)6);
    eq("foobar hex", a.toHex(), (u8*)"666f6f626172");

    // subdata
    UXData* sub = a.subdata((i32)3, (i32)3); // "bar"
    check("subdata length", sub.length(), (i32)3);
    eq("subdata hex (bar)", sub.toHex(), (u8*)"626172");
    // clamped subdata
    UXData* clamped = a.subdata((i32)4, (i32)100);
    check("clamped subdata length", clamped.length(), (i32)2);

    // equality
    check("equal data", UXData.fromString((u8*)"xyz").isEqualTo(UXData.fromString((u8*)"xyz")) ? (i32)1 : (i32)0, (i32)1);
    check("unequal length", UXData.fromString((u8*)"xy").isEqualTo(UXData.fromString((u8*)"xyz")) ? (i32)1 : (i32)0, (i32)0);
    check("unequal content", UXData.fromString((u8*)"xyz").isEqualTo(UXData.fromString((u8*)"xyw")) ? (i32)1 : (i32)0, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXData — append, capacity growth, from-string, appendData, subdata, equality, hex.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
