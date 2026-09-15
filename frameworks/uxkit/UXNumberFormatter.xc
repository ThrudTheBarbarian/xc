// UXNumberFormatter.xc — format integers with grouping + fixed-point decimals (NSNumberFormatter).
//
// The "formattable column" a list view wants: turn 1234567 into "1,234,567", or the cents value
// 129900 into "$1,299.00", or 42 into "42%".  Integer-only (no float): a fixed-point value is passed
// as a scaled integer plus a decimal count, so it is exact on every backend.  Builds into a heap
// buffer and returns a u8*.
#import "Array.xc"

class UXNumberFormatter
    {
    u8* prefix;
    u8* suffix;
    u8 groupSep; // 0 = no grouping
    u8 decSep;
    void init(void)
        {
        prefix = (u8*)"";
        suffix = (u8*)"";
        groupSep = (u8)',';
        decSep = (u8)'.';
        }

    void setPrefix(u8* p)
        {
        prefix = p;
        }
    void setSuffix(u8* s)
        {
        suffix = s;
        }
    void setGrouping(bool on)
        {
        groupSep = on ? (u8)',' : (u8)0;
        }
    void setGroupSeparator(u8 c)
        {
        groupSep = c;
        }
    void setDecimalSeparator(u8 c)
        {
        decSep = c;
        }

    static i32 pow10(i32 n)
        {
        i32 v = (i32)1;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            v = v * (i32)10;
            }
        return v;
        }
    static i32 slen(u8* s)
        {
        if (s == (u8*)0)
            {
            return (i32)0;
            }
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }

    // digits of a non-negative int into out[], most-significant first; returns the count.
    i32 digitsOf(i32 v, u8* out)
        {
        if (v == (i32)0)
            {
            out[0] = (u8)'0';
            return (i32)1;
            }
        u8 tmp[16];
        i32 t = (i32)0;
        while (v > (i32)0)
            {
            tmp[t] = (u8)((i32)'0' + v % (i32)10);
            v = v / (i32)10;
            t = t + (i32)1;
            }
        for (i32 i = (i32)0; i < t; i = i + (i32)1)
            {
            out[i] = tmp[t - (i32)1 - i];
            }
        return t;
        }

    // Format `value` interpreted as scaled by 10^decimals (decimals=0 -> a plain integer).
    u8* formatFixed(i32 value, i32 decimals)
        {
        bool neg = value < (i32)0;
        i32 v = neg ? -value : value;
        i32 scale = UXNumberFormatter.pow10(decimals);
        i32 intPart = decimals > (i32)0 ? v / scale : v;
        i32 fracPart = decimals > (i32)0 ? v % scale : (i32)0;

        u8 digs[16];
        i32 nd = self.digitsOf(intPart, &digs[0]);

        // worst case: prefix + sign + digits + (nd/3) separators + 1 decSep + decimals + suffix + NUL
        i32 cap = UXNumberFormatter.slen(prefix) + UXNumberFormatter.slen(suffix) + nd + nd / (i32)3 + decimals + (i32)8;
        u8* out = new u8[(u32)cap];
        i32 o = (i32)0;

        i32 pl = UXNumberFormatter.slen(prefix);
        for (i32 i = (i32)0; i < pl; i = i + (i32)1)
            {
            out[o] = prefix[i];
            o = o + (i32)1;
            }
        if (neg)
            {
            out[o] = (u8)'-';
            o = o + (i32)1;
            }

        // grouped integer part: a separator falls before a digit when the remaining count %3 == 0
        for (i32 i = (i32)0; i < nd; i = i + (i32)1)
            {
            if (groupSep != (u8)0 && i > (i32)0 && (nd - i) % (i32)3 == (i32)0)
                {
                out[o] = groupSep;
                o = o + (i32)1;
                }
            out[o] = digs[i];
            o = o + (i32)1;
            }
        if (decimals > (i32)0)
            {
            out[o] = decSep;
            o = o + (i32)1;
            // fractional digits, zero-padded to `decimals`
            u8 fd[16];
            i32 fn = self.digitsOf(fracPart, &fd[0]);
            for (i32 z = (i32)0; z < decimals - fn; z = z + (i32)1)
                {
                out[o] = (u8)'0';
                o = o + (i32)1;
                }
            for (i32 i = (i32)0; i < fn; i = i + (i32)1)
                {
                out[o] = fd[i];
                o = o + (i32)1;
                }
            }
        i32 sl = UXNumberFormatter.slen(suffix);
        for (i32 i = (i32)0; i < sl; i = i + (i32)1)
            {
            out[o] = suffix[i];
            o = o + (i32)1;
            }
        out[o] = (u8)0;
        return out;
        }
    u8* format(i32 value)
        {
        return self.formatFixed(value, (i32)0);
        }

    // Convenience presets.
    static UXNumberFormatter* decimal(void)
        {
        UXNumberFormatter* f = new UXNumberFormatter();
        f.setGrouping(true);
        return f;
        }
    static UXNumberFormatter* currency(u8* symbol)
        {
        UXNumberFormatter* f = new UXNumberFormatter();
        f.setGrouping(true);
        f.setPrefix(symbol);
        return f;
        }
    static UXNumberFormatter* percent(void)
        {
        UXNumberFormatter* f = new UXNumberFormatter();
        f.setSuffix((u8*)"%");
        return f;
        }
    }
