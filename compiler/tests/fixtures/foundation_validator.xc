//xtc-na: xt6502 — Validator is not available on xt6502
// foundation_validator.xc — Validator: each rule, rule order, every error,
// character (not byte) lengths, number parsing and a custom check.
#import "Foundation.xc"
#import "Validator.xc"

String* S(u8* c)
    {
    return String.withCString(c);
    }

class Policy : Object
    {
    bool notAdmin(String* s)
        {
        return !s.lowercased().equals(S("admin"));
        }
    }

void check(Validator* v, u8* text)
    {
    String* e = v.firstError(S(text));
    Stdio.printf("[%s] %s%s\n", text, v.validate(S(text)) ? "ok" : "fails: ", e == 0 ? "" : e.cString());
    }

i32 main(void)
    {
    Validator* name = new Validator();
    Policy* pol = new Policy();
    try
        {
        name.requireNonEmpty(S("Enter a name."));
        name.requireMaxLength((u32)5, S("At most 5 characters."));
        name.requireMatch(S("[A-Za-zé' -]+"), S("Letters only."));
        name.requireCustom(&pol.notAdmin, S("That name is taken."));
        }
    catch (RegexError e)
        {
        Stdio.printf("%s\n", e.message().cString());
        }
    check(name, "");
    check(name, "   ");
    check(name, "Ada");
    check(name, "Ad4");
    check(name, "Adelaide");
    check(name, "Renée");
    check(name, "ADMIN");
    Array* all = name.errors(S("Adm1n99"));
    Stdio.printf("all errors for Adm1n99:");
    for (u32 i = (u32)0; i < all.count(); i++)
        Stdio.printf(" (%s)", ((String*)all.get(i)).cString());
    Stdio.printf("\n");

    Validator* age = new Validator();
    age.requireIntegerRange((i64)0, (i64)130, S("An age from 0 to 130."));
    check(age, "42");
    check(age, " 7 ");
    check(age, "131");
    check(age, "-1");
    check(age, "4.5");
    check(age, "forty");
    check(age, "true");

    Validator* price = new Validator();
    price.requireNumberRange(0.0d, 99.99d, S("A price up to 99.99."));
    price.requireMinLength((u32)1, S("Required."));
    check(price, "4.5");
    check(price, "100");
    check(price, "1e1");
    check(price, "");
    Stdio.printf("rules: %u %u %u\n", name.ruleCount(), age.ruleCount(), price.ruleCount());
    try
        {
        name.requireMatch(S("(bad"), S("x"));
        }
    catch (RegexError e)
        {
        Stdio.printf("%s\n", e.message().cString());
        }
    return (i32)0;
    }
