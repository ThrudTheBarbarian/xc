//xtc-na: xt6502 — NumberFormatter is not available on xt6502
// foundation_numberformatter.xc — NumberFormatter: grouping, fraction digits,
// rounding, currency and percent styles, fixed point, separators, and
// parsing the text back.
#import "Foundation.xc"
#import "NumberFormatter.xc"

String* S(u8* c)
    {
    return String.withCString(c);
    }
void show(u8* label, String* s)
    {
    Stdio.printf("%-26s [%@]\n", label, s);
    }
void back(NumberFormatter* f, u8* text)
    {
    Number* n = f.parse(S(text));
    if (n == 0)
        Stdio.printf("parse %-20s -> none\n", text);
    else
        Stdio.printf("parse %-20s -> %@%s\n", text, n, n.isFloat() ? " (double)" : "");
    }

i32 main(void)
    {
    NumberFormatter* d = NumberFormatter.decimal();
    show("decimal 1234567", d.format(Number.withI64((i64)1234567)));
    show("decimal -1234567", d.format(Number.withI64((i64)-1234567)));
    show("decimal 999", d.format(Number.withI64((i64)999)));
    show("decimal i64 min", d.format(Number.withI64((i64)0 - (i64)9223372036854775807 - (i64)1)));
    show("decimal 1234.5678", d.format(Number.withDouble(1234.5678d)));
    show("decimal 2.5", d.format(Number.withDouble(2.5d)));
    show("decimal 3.0", d.format(Number.withDouble(3.0d)));
    show("decimal -0.0001", d.format(Number.withDouble(-0.0001d)));
    show("decimal null", d.format((Number*)0));

    NumberFormatter* c = NumberFormatter.currency(S("$"));
    show("currency 1299.5", c.format(Number.withDouble(1299.5d)));
    show("currency -5", c.format(Number.withI64((i64)-5)));
    show("currency 2.675", c.format(Number.withDouble(2.675d)));
    show("currency fixed 129900/2", c.formatFixed((i64)129900, (u8)2));
    show("currency fixed -7/2", c.formatFixed((i64)-7, (u8)2));

    NumberFormatter* p = NumberFormatter.percent();
    show("percent 0.256", p.format(Number.withDouble(0.256d)));
    show("percent 1", p.format(Number.withI64((i64)1)));

    NumberFormatter* eu = NumberFormatter.decimal();
    eu.groupSeparator = S(".");
    eu.decimalSeparator = S(",");
    eu.minimumFractionDigits = (u8)2;
    show("european 1234567.891", eu.format(Number.withDouble(1234567.891d)));
    NumberFormatter* plain = NumberFormatter.decimal();
    plain.grouping = false;
    show("no grouping", plain.format(Number.withI64((i64)1234567)));

    back(d, "1,234,567");
    back(d, "-1,234.5");
    back(c, "$1,299.50");
    back(c, "-$5.00");
    back(c, "$-5");
    back(p, "25%");
    back(p, "300%");
    back(eu, "1.234,5");
    back(d, "12a");
    back(d, "");
    return (i32)0;
    }
