// c2xc_rt.xc — the run-time a converted program needs beyond libc's natives:
// a formatter for the v*printf family. C hands a va_list on to vsnprintf;
// xc can only forward its whole tail, and only to an xc variadic, so a
// function that formats its arguments calls c2xc_snprintf(buf, n, fmt, ...)
// and this walks the pack. Supports the C conversions converted programs
// use: %d %i %u %ld %lu %lld %llu %x %X %o %c %s %f %e %g %p %% with -, 0,
// +, space, width, .precision and * for either. A 64-bit argument is read
// as two u32 halves, since va_arg has no i64 form.
#import "Foundation.xc"
i32 fputs(u8* s, pointer f);
extern pointer __stdoutp;

u64 c2xc_strlen(u8* s)
    {
    u64 n = 0;
    while (s[n] != 0)
        n++;
    return n;
    }

void c2xc_put(u8* buf, u64 cap, u64* at, u8 c)
    {
    if (*at + 1 < cap)
        buf[*at] = c;
    *at = *at + 1;
    }
void c2xc_pad(u8* buf, u64 cap, u64* at, i64 n, u8 c)
    {
    while (n > 0)
        {
        c2xc_put(buf, cap, at, c);
        n--;
        }
    }
void c2xc_emit(u8* buf, u64 cap, u64* at, u8* s, i64 len, i64 width, bool left, u8 padc, u8 sign)
    {
    i64 total = len + (sign != 0 ? 1 : 0);
    if (!left && padc == ' ')
        c2xc_pad(buf, cap, at, width - total, ' ');
    if (sign != 0)
        c2xc_put(buf, cap, at, sign);
    if (!left && padc == '0')
        c2xc_pad(buf, cap, at, width - total, '0');
    for (i64 i = 0; i < len; i++)
        c2xc_put(buf, cap, at, s[i]);
    if (left)
        c2xc_pad(buf, cap, at, width - total, ' ');
    }
// an unsigned value in a base into d (backwards then reversed), returns the length
i64 c2xc_utoa(u64 v, u32 base, bool upper, u8* d)
    {
    u8 tmp[32];
    i64 n = 0;
    if (v == 0)
        {
        tmp[0] = '0';
        n = 1;
        }
    while (v != 0)
        {
        u64 q = v % (u64)base;
        tmp[n] = (u8)(q < 10 ? '0' + q : (upper ? 'A' : 'a') + q - 10);
        n++;
        v = v / (u64)base;
        }
    for (i64 i = 0; i < n; i++)
        d[i] = tmp[n - 1 - i];
    return n;
    }
i32 c2xc_snprintf(u8* buf, u64 cap, u8* fmt, ...)
    {
    u8 ap;
    va_start(ap);
    u64 at = 0;
    u64 i = 0;
    while (fmt[i] != 0)
        {
        u8 c = fmt[i];
        if (c != '%')
            {
            c2xc_put(buf, cap, &at, c);
            i++;
            continue;
            }
        i++;
        bool left = false;
        bool plus = false;
        bool space = false;
        bool alt = false;
        u8 padc = ' ';
        while (true)
            {
            u8 f = fmt[i];
            if (f == '-')
                left = true;
            else if (f == '+')
                plus = true;
            else if (f == ' ')
                space = true;
            else if (f == '0')
                padc = '0';
            else if (f == '#')
                alt = true;
            else
                break;
            i++;
            }
        i64 width = 0;
        bool haveW = false;
        if (fmt[i] == '*')
            {
            width = (i64)va_arg(ap, i32);
            haveW = true;
            if (width < 0)
                {
                left = true;
                width = -width;
                }
            i++;
            }
        while (fmt[i] >= '0' && fmt[i] <= '9')
            {
            width = width * 10 + (i64)(fmt[i] - '0');
            haveW = true;
            i++;
            }
        i64 prec = -1;
        if (fmt[i] == '.')
            {
            i++;
            prec = 0;
            if (fmt[i] == '*')
                {
                prec = (i64)va_arg(ap, i32);
                i++;
                }
            else
                while (fmt[i] >= '0' && fmt[i] <= '9')
                    {
                    prec = prec * 10 + (i64)(fmt[i] - '0');
                    i++;
                    }
            }
        u32 longs = 0;
        while (fmt[i] == 'l' || fmt[i] == 'h' || fmt[i] == 'z' || fmt[i] == 'j' || fmt[i] == 't')
            {
            if (fmt[i] == 'l' || fmt[i] == 'z' || fmt[i] == 'j' || fmt[i] == 't')
                longs++;
            i++;
            }
        u8 conv = fmt[i];
        if (conv == 0)
            break;
        i++;
        u8 d[400];
        i64 n = 0;
        u8 sign = 0;
        if (conv == 'd' || conv == 'i')
            {
            i64 v;
            if (longs > 0)
                {
                u32 lo = va_arg(ap, u32);
                u32 hi = va_arg(ap, u32);
                v = (i64)(((u64)hi << 32) | (u64)lo);
                }
            else
                v = (i64)va_arg(ap, i32);
            if (v < 0)
                {
                sign = '-';
                v = -v;
                }
            else if (plus)
                sign = '+';
            else if (space)
                sign = ' ';
            n = c2xc_utoa((u64)v, 10, false, &d[0]);
            if (prec >= 0)
                {
                padc = ' ';
                while (n < prec)
                    {
                    for (i64 k = n; k > 0; k--)
                        d[k] = d[k - 1];
                    d[0] = '0';
                    n++;
                    }
                }
            c2xc_emit(buf, cap, &at, &d[0], n, width, left, padc, sign);
            continue;
            }
        if (conv == 'u' || conv == 'x' || conv == 'X' || conv == 'o' || conv == 'p')
            {
            u64 v;
            if (longs > 0 || conv == 'p')
                {
                u32 lo = va_arg(ap, u32);
                u32 hi = va_arg(ap, u32);
                v = ((u64)hi << 32) | (u64)lo;
                }
            else
                v = (u64)va_arg(ap, u32);
            u32 base = (conv == 'u') ? 10 : (conv == 'o' ? 8 : 16);
            n = c2xc_utoa(v, base, conv == 'X', &d[0]);
            if (prec >= 0)
                {
                padc = ' ';
                while (n < prec)
                    {
                    for (i64 k = n; k > 0; k--)
                        d[k] = d[k - 1];
                    d[0] = '0';
                    n++;
                    }
                }
            if ((alt && v != 0 && (conv == 'x' || conv == 'X')) || conv == 'p')
                {
                for (i64 k = n; k > 0; k--)
                    d[k + 1] = d[k - 1];
                d[0] = '0';
                d[1] = (conv == 'X') ? 'X' : 'x';
                n = n + 2;
                }
            c2xc_emit(buf, cap, &at, &d[0], n, width, left, padc, 0);
            continue;
            }
        if (conv == 'c')
            {
            d[0] = (u8)va_arg(ap, i32);
            c2xc_emit(buf, cap, &at, &d[0], 1, width, left, ' ', 0);
            continue;
            }
        if (conv == 's')
            {
            u8* s = va_arg(ap, string);
            if (s == 0)
                s = "(null)";
            i64 len = (i64)c2xc_strlen(s);
            if (prec >= 0 && prec < len)
                len = prec;
            c2xc_emit(buf, cap, &at, s, len, width, left, ' ', 0);
            continue;
            }
        if (conv == 'f' || conv == 'F' || conv == 'e' || conv == 'E' || conv == 'g' || conv == 'G')
            {
            double v = va_arg(ap, double);
            if (v < 0.0)
                {
                sign = '-';
                v = -v;
                }
            else if (plus)
                sign = '+';
            else if (space)
                sign = ' ';
            n = (i64)c2xc_fmt_double(&d[0], v, (i32)(prec < 0 ? 6 : prec), conv);
            c2xc_emit(buf, cap, &at, &d[0], n, width, left, padc, sign);
            continue;
            }
        if (conv == '%')
            {
            c2xc_put(buf, cap, &at, '%');
            continue;
            }
        // unknown: write it through
        c2xc_put(buf, cap, &at, '%');
        c2xc_put(buf, cap, &at, conv);
        }
    va_end(ap);
    if (cap > 0)
        buf[at < cap ? at : cap - 1] = 0;
    return (i32)at;
    }
double floor(double x);
double fmod(double x, double y);
// the decimal digits of a non-negative integral double (exact below 2^53)
i32 c2xc_dtoa_int(double x, u8* d)
    {
    u8 t[40];
    i32 n = 0;
    if (x < 1.0)
        {
        d[0] = '0';
        return 1;
        }
    while (x >= 1.0 && n < 40)
        {
        t[n] = (u8)('0' + (i32)fmod(x, 10.0));
        n++;
        x = floor(x / 10.0);
        }
    for (i32 k = 0; k < n; k++)
        d[k] = t[n - 1 - k];
    return n;
    }
// %f %e %g on a non-negative double, C's rounding to prec digits
i32 c2xc_fmt_double(u8* d, double v, i32 prec, u8 conv)
    {
    i32 n = 0;
    bool isE = (conv == 'e' || conv == 'E');
    if (conv == 'g' || conv == 'G')
        {
        // C: %e if exponent < -4 or >= precision, else %f, then trailing zeros trimmed
        i32 p = prec == 0 ? 1 : prec;
        i32 ex = 0;
        double t = v;
        if (t != 0.0)
            {
            while (t >= 10.0)
                {
                t = t / 10.0;
                ex++;
                }
            while (t < 1.0)
                {
                t = t * 10.0;
                ex--;
                }
            }
        if (ex < -4 || ex >= p)
            {
            n = c2xc_fmt_double(d, v, p - 1, conv == 'g' ? 'e' : 'E');
            }
        else
            {
            n = c2xc_fmt_double(d, v, p - 1 - ex, 'f');
            }
        // trim trailing zeros in the mantissa
        i32 e = n;
        i32 epos = -1;
        for (i32 k = 0; k < n; k++)
            if (d[k] == 'e' || d[k] == 'E')
                {
                epos = k;
                break;
                }
        i32 end = epos < 0 ? n : epos;
        bool dot = false;
        for (i32 k = 0; k < end; k++)
            if (d[k] == '.')
                dot = true;
        if (dot)
            {
            i32 k = end;
            while (k > 0 && d[k - 1] == '0')
                k--;
            if (k > 0 && d[k - 1] == '.')
                k--;
            if (epos >= 0)
                {
                for (i32 j = 0; j < n - epos; j++)
                    d[k + j] = d[epos + j];
                n = k + (n - epos);
                }
            else
                n = k;
            }
        return n;
        }
    i32 ex = 0;
    if (isE)
        {
        if (v != 0.0)
            {
            while (v >= 10.0)
                {
                v = v / 10.0;
                ex++;
                }
            while (v < 1.0)
                {
                v = v * 10.0;
                ex--;
                }
            }
        }
    // round to prec digits
    double scale = 1.0;
    for (i32 k = 0; k < prec; k++)
        scale = scale * 10.0;
    double r = v * scale + 0.5;
    if (isE && r >= 10.0 * scale)
        {
        r = r / 10.0;
        ex++;
        }
    // digits are taken with double arithmetic: (u64)r is truncated to 32
    // bits by xcc 0.5, which printed large amounts as $0.00
    double ipd = floor(r);
    double whole = floor(ipd / scale);
    double frac = ipd - whole * scale;
    n = c2xc_dtoa_int(whole, d);
    if (prec > 0)
        {
        d[n] = '.';
        n++;
        u8 fd[32];
        i32 fn = c2xc_dtoa_int(frac, &fd[0]);
        for (i32 k = fn; k < prec; k++)
            {
            d[n] = '0';
            n++;
            }
        for (i32 k = 0; k < fn; k++)
            {
            d[n] = fd[k];
            n++;
            }
        }
    if (isE)
        {
        d[n] = (conv == 'E') ? 'E' : 'e';
        n++;
        d[n] = ex < 0 ? '-' : '+';
        n++;
        if (ex < 0)
            ex = -ex;
        if (ex < 10)
            {
            d[n] = '0';
            n++;
            }
        n = n + (i32)c2xc_utoa((u64)ex, 10, false, &d[n]);
        }
    return n;
    }
i32 c2xc_sprintf(u8* buf, u8* fmt, ...)
    {
    return c2xc_snprintf(buf, 1 << 30, fmt, ...);
    }
i32 c2xc_fprintf(pointer f, u8* fmt, ...)
    {
    u8 b[4096];
    i32 n = c2xc_snprintf(&b[0], 4096, fmt, ...);
    fputs(&b[0], f);
    return n;
    }
i32 c2xc_printf(u8* fmt, ...)
    {
    u8 b[4096];
    i32 n = c2xc_snprintf(&b[0], 4096, fmt, ...);
    fputs(&b[0], __stdoutp);
    return n;
    }
// assert(x): C's macro, as a call, so a unit can keep it as an expression
void abort(void);
void c2xc_assert(bool ok)
    {
    if (!ok)
        abort();
    }

// ── libc's variables, as things a unit can reach ─────────────────────────
// xcc 0.5 makes an extern variable a private zeroed copy (private:xcc-bugs/25), so
// stdin/stdout/stderr and getopt's optarg/optind are reached by ADDRESS
// through dlsym (a function, which binds), and errno through __error().
pointer dlsym(pointer handle, u8* name);
pointer dlopen(u8* path, i32 mode);
i32* __error(void);
pointer c2xc_stdin;
pointer c2xc_stdout;
pointer c2xc_stderr;
u8** c2xc_optargp;
i32* c2xc_optindp;
void c2xc_rt_init(void)
    {
    pointer dflt = dlopen((u8*)0, 2); // the main program and its libraries (RTLD_NOW); RTLD_DEFAULT's -2 does not survive the cast
    c2xc_stdin = *(pointer*)dlsym(dflt, &("__stdinp")[0]);
    c2xc_stdout = *(pointer*)dlsym(dflt, &("__stdoutp")[0]);
    c2xc_stderr = *(pointer*)dlsym(dflt, &("__stderrp")[0]);
    c2xc_optargp = (u8**)dlsym(dflt, &("optarg")[0]);
    c2xc_optindp = (i32*)dlsym(dflt, &("optind")[0]);
    }
