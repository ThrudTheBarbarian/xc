// XAGasString.h — the operands of a GAS string directive.
//
// `.ascii`, `.asciz` and `.string` take one or more quoted strings separated by
// commas. Inside a string GAS understands \b \f \n \r \t, \\ and \", an octal
// escape of one to three digits (\0, \12, \342) and a hex escape \x followed by
// any number of hex digits, of which the low byte is kept. Any other escaped
// character stands for itself. The text is read as UTF-8 bytes, so a non-ASCII
// character written into the string goes through unchanged.
//
// Every assembler here decodes through this, matching the self-hosted
// GasString.xc. Each used to carry its own decoder that knew only a few
// escapes: \342\200\224 (an em dash, as a compiler writes UTF-8) came out as the
// digits, and \012 as a NUL followed by "12".

#import <Foundation/Foundation.h>

static inline int XAGasHexDigit(uint8_t c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// The bytes of `rest`, the text after the directive, with a NUL after each
// string when `zero` (.asciz, .string). nil when `rest` is not a comma-separated
// list of quoted strings.
static inline NSData *XAGasStringDecode(NSString *rest, BOOL zero)
{
    NSData *src = [rest dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *s = (const uint8_t *)src.bytes;
    NSUInteger n = src.length, i = 0;
    NSMutableData *out = [NSMutableData data];
    while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
    if (i >= n) return nil;
    for (;;) {
        if (i >= n || s[i] != '"') return nil;
        i++;
        BOOL closed = NO;
        while (i < n && !closed) {
            uint8_t c = s[i];
            if (c == '"') { closed = YES; i++; continue; }
            if (c == '\\' && i + 1 < n) {
                i++;
                uint8_t e = s[i];
                uint8_t b;
                if (e >= '0' && e <= '7') {
                    unsigned v = 0, k = 0;
                    while (k < 3 && i < n && s[i] >= '0' && s[i] <= '7') { v = v * 8 + (unsigned)(s[i] - '0'); i++; k++; }
                    b = (uint8_t)(v & 0xFF);
                } else if ((e == 'x' || e == 'X') && i + 1 < n && XAGasHexDigit(s[i + 1]) >= 0) {
                    unsigned v = 0;
                    i++;
                    while (i < n && XAGasHexDigit(s[i]) >= 0) { v = (v << 4) | (unsigned)XAGasHexDigit(s[i]); i++; }
                    b = (uint8_t)(v & 0xFF);
                } else {
                    b = e == 'b' ? 8 : e == 'f' ? 12 : e == 'n' ? 10 : e == 'r' ? 13 : e == 't' ? 9 : e;
                    i++;
                }
                [out appendBytes:&b length:1];
                continue;
            }
            [out appendBytes:&c length:1];
            i++;
        }
        if (!closed) return nil;
        if (zero) { uint8_t z = 0; [out appendBytes:&z length:1]; }
        while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
        if (i >= n) return out;
        if (s[i] != ',') return nil;
        i++;
        while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
    }
}
