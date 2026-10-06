// foundation_characterset_classes.xc — CharacterSet's punctuation, symbols
// and letter-case sets cover printable ASCII between them exactly once with
// the digits, letters and space.
#import "Foundation.xc"

void row(u8* name, CharacterSet* cs)
    {
    Stdio.printf("%s:", name);
    for (u8 c = (u8)33; c < (u8)127; c++)
        {
        if (cs.contains(c))
            Stdio.printf("%c", c);
        }
    Stdio.printf("\n");
    }

i32 main(void)
    {
    row("punct", CharacterSet.punctuation());
    row("symbols", CharacterSet.symbols());
    row("upper", CharacterSet.uppercaseLetters());
    row("lower", CharacterSet.lowercaseLetters());
    // Every printable character falls in exactly one class.
    u8 bad = (u8)0;
    for (u8 c = (u8)32; c < (u8)127; c++)
        {
        u8 n = (u8)0;
        if (CharacterSet.punctuation().contains(c))
            n++;
        if (CharacterSet.symbols().contains(c))
            n++;
        if (CharacterSet.letters().contains(c))
            n++;
        if (CharacterSet.decimalDigits().contains(c))
            n++;
        if (CharacterSet.whitespace().contains(c))
            n++;
        if (n != (u8)1)
            bad++;
        }
    Stdio.printf("unclassified or twice: %d\n", (i32)bad);
    String* s = String.withCString("Hi, you! (ok?)");
    Stdio.printf("[%s]\n", s.trimmed(CharacterSet.punctuation()).cString());
    return (i32)0;
    }
