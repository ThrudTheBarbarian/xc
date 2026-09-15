// test_numberformatter.xc — UXNumberFormatter: grouping, fixed-point, currency, percent.
#import <Stdio.xc>
#import "UXNumberFormatter.xc"

i32 gFails;
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

    UXNumberFormatter* dec = UXNumberFormatter.decimal();
    eq("grouped million", dec.format((i32)1234567), (u8*)"1,234,567");
    eq("grouped thousand", dec.format((i32)1000), (u8*)"1,000");
    eq("under a thousand", dec.format((i32)999), (u8*)"999");
    eq("zero", dec.format((i32)0), (u8*)"0");
    eq("negative grouped", dec.format((i32)-1234567), (u8*)"-1,234,567");

    UXNumberFormatter* plain = new UXNumberFormatter();
    plain.setGrouping(false);
    eq("ungrouped", plain.format((i32)1234567), (u8*)"1234567");

    // fixed-point (value scaled by 10^decimals)
    eq("1299.00 from cents", UXNumberFormatter.decimal().formatFixed((i32)129900, (i32)2), (u8*)"1,299.00");
    eq("0.05 from 5 cents", plain.formatFixed((i32)5, (i32)2), (u8*)"0.05");
    eq("1.00 from 100", plain.formatFixed((i32)100, (i32)2), (u8*)"1.00");
    eq("negative fixed", plain.formatFixed((i32)-12345, (i32)2), (u8*)"-123.45");
    eq("three decimals", plain.formatFixed((i32)1234, (i32)3), (u8*)"1.234");

    // currency + percent presets
    eq("USD currency", UXNumberFormatter.currency((u8*)"$").formatFixed((i32)129900, (i32)2), (u8*)"$1,299.00");
    eq("percent", UXNumberFormatter.percent().format((i32)42), (u8*)"42%");

    // a custom separator (European style)
    UXNumberFormatter* euro = UXNumberFormatter.currency((u8*)"EUR ");
    euro.setGroupSeparator((u8)'.');
    euro.setDecimalSeparator((u8)',');
    eq("euro style", euro.formatFixed((i32)129900, (i32)2), (u8*)"EUR 1.299,00");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXNumberFormatter — grouping, fixed-point, currency, percent, custom separators.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
