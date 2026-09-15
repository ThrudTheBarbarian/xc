// test_characterset.xc — UXCharacterSet membership + standard sets + inversion.
#import <Stdio.xc>
#import "UXCharacterSet.xc"

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
i32 has(UXCharacterSet* s, u8 c)
    {
    return s.contains((i32)c) ? (i32)1 : (i32)0;
    }

void main(void)
    {
    gFails = (i32)0;

    UXCharacterSet* digits = UXCharacterSet.decimalDigits();
    check("'5' is a digit", has(digits, (u8)'5'), (i32)1);
    check("'0' is a digit", has(digits, (u8)'0'), (i32)1);
    check("'a' is not a digit", has(digits, (u8)'a'), (i32)0);

    UXCharacterSet* letters = UXCharacterSet.letters();
    check("'a' is a letter", has(letters, (u8)'a'), (i32)1);
    check("'Z' is a letter", has(letters, (u8)'Z'), (i32)1);
    check("'5' is not a letter", has(letters, (u8)'5'), (i32)0);

    UXCharacterSet* alnum = UXCharacterSet.alphanumerics();
    check("'a' alnum", has(alnum, (u8)'a'), (i32)1);
    check("'9' alnum", has(alnum, (u8)'9'), (i32)1);
    check("'-' not alnum", has(alnum, (u8)'-'), (i32)0);

    UXCharacterSet* ws = UXCharacterSet.whitespaceAndNewlines();
    check("space is ws", has(ws, (u8)' '), (i32)1);
    check("tab is ws", has(ws, (u8)9), (i32)1);
    check("newline is ws", has(ws, (u8)10), (i32)1);
    check("'x' not ws", has(ws, (u8)'x'), (i32)0);

    // inversion: non-digits
    UXCharacterSet* nonDigits = digits.inverted();
    check("'a' is a non-digit", has(nonDigits, (u8)'a'), (i32)1);
    check("'5' is not a non-digit", has(nonDigits, (u8)'5'), (i32)0);

    // custom set + union
    UXCharacterSet* vowels = new UXCharacterSet();
    vowels.addString((u8*)"aeiou");
    check("'e' is a vowel", has(vowels, (u8)'e'), (i32)1);
    check("'b' is not a vowel", has(vowels, (u8)'b'), (i32)0);
    UXCharacterSet* vowelsOrDigits = vowels.unionWith(digits);
    check("union has vowel", has(vowelsOrDigits, (u8)'a'), (i32)1);
    check("union has digit", has(vowelsOrDigits, (u8)'7'), (i32)1);
    check("union excludes consonant", has(vowelsOrDigits, (u8)'b'), (i32)0);

    // a tiny use: count word characters in a string via alphanumerics
    u8* text = (u8*)"ab 12! z";
    i32 wc = (i32)0;
    for (i32 i = (i32)0; text[i] != (u8)0; i = i + (i32)1)
        {
        if (alnum.contains((i32)text[i]))
            {
            wc = wc + (i32)1;
            }
        }
    check("counted 5 word chars in 'ab 12! z'", wc, (i32)5);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXCharacterSet — standard sets, membership, inversion, union.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
