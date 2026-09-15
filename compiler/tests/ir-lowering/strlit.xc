// strlit — string-literal lowering. "Hi" becomes a deduplicated
// StringLit symbol (bytes 'H','i',0); `s` holds its address; s[0]
// reads the first byte. Returns 'H' = 72. Validates string-literal
// data emission + AddrOf(symbol) + indexed Load on BOTH backends —
// no printf needed.
u8 firstchar(void)
    {
    string s = "Hi";
    return s[0];
    }
