// UXData.xc — a growable byte buffer (NSData / NSMutableData in shape).
//
// The binary counterpart to a string: append bytes, read them back, slice a subrange, compare, and
// render as hex.  Capacity doubles on growth so appends amortise to O(1).  This is what binary
// pasteboard payloads, serialized structures, and file contents ride in — the piece that string-only
// classes leave out.
#import "Array.xc"

class UXData
    {
    u8* buf;
    i32 len;
    i32 cap;
    void init(void)
        {
        buf = new u8[(u32)8];
        len = (i32)0;
        cap = (i32)8;
        }

    static UXData* withCapacity(i32 n)
        {
        UXData* d = new UXData();
        if (n < (i32)1)
            {
            n = (i32)1;
            }
        d.buf = new u8[(u32)n];
        d.cap = n;
        d.len = (i32)0;
        return d;
        }
    static UXData* fromBytes(u8* src, i32 n)
        {
        UXData* d = UXData.withCapacity(n < (i32)1 ? (i32)1 : n);
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            d.buf[i] = src[i];
            }
        d.len = n;
        return d;
        }
    // treat a NUL-terminated string as bytes (no terminator copied)
    static UXData* fromString(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return UXData.fromBytes(s, n);
        }

    void ensure(i32 want)
        {
        if (want <= cap)
            {
            return;
            }
        i32 nc = cap;
        while (nc < want)
            {
            nc = nc * (i32)2;
            }
        u8* nb = new u8[(u32)nc];
        for (i32 i = (i32)0; i < len; i = i + (i32)1)
            {
            nb[i] = buf[i];
            }
        buf = nb;
        cap = nc;
        }
    void appendByte(u8 b)
        {
        self.ensure(len + (i32)1);
        buf[len] = b;
        len = len + (i32)1;
        }
    void appendBytes(u8* src, i32 n)
        {
        self.ensure(len + n);
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            buf[len + i] = src[i];
            }
        len = len + n;
        }
    void appendData(UXData* o)
        {
        if (o != (UXData*)0)
            {
            self.appendBytes(o.buf, o.len);
            }
        }

    i32 length(void)
        {
        return len;
        }
    u8 byteAt(i32 i)
        {
        return (i >= (i32)0 && i < len) ? buf[i] : (u8)0;
        }
    u8* bytes(void)
        {
        return buf;
        }

    UXData* subdata(i32 start, i32 n)
        {
        if (start < (i32)0)
            {
            start = (i32)0;
            }
        if (start + n > len)
            {
            n = len - start;
            }
        if (n < (i32)0)
            {
            n = (i32)0;
            }
        UXData* d = UXData.withCapacity(n < (i32)1 ? (i32)1 : n);
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            d.buf[i] = buf[start + i];
            }
        d.len = n;
        return d;
        }
    bool isEqualTo(UXData* o)
        {
        if (o == (UXData*)0 || o.len != len)
            {
            return false;
            }
        for (i32 i = (i32)0; i < len; i = i + (i32)1)
            {
            if (buf[i] != o.buf[i])
                {
                return false;
                }
            }
        return true;
        }

    // lowercase hex, two chars per byte
    u8* toHex(void)
        {
        u8* hexd = (u8*)"0123456789abcdef";
        u8* o = new u8[(u32)(len * (i32)2 + (i32)1)];
        for (i32 i = (i32)0; i < len; i = i + (i32)1)
            {
            o[i * (i32)2] = hexd[(i32)(buf[i] >> (u8)4) & (i32)15];
            o[i * (i32)2 + (i32)1] = hexd[(i32)buf[i] & (i32)15];
            }
        o[len * (i32)2] = (u8)0;
        return o;
        }
    }
