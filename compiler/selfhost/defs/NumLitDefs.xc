// NumLitDefs.xc — the prefix and sign options of NumLit.scan (asm/NumLit.xc).
#define NUM_DOLLAR  1   // `$1F` is hex (Motorola, ARM)
#define NUM_PERCENT 2   // `%101` is binary (Motorola)
#define NUM_OCTAL   4   // a leading `0` is octal (C's strtoll)
#define NUM_NOPLUS  8   // no `+` sign
