// test_validator.xc — UXValidator field rules.
#import <Stdio.xc>
#import "UXValidator.xc"

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
bool streq(u8* a, u8* b)
    {
    if (a == (u8*)0 || b == (u8*)0)
        {
        return a == b;
        }
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
i32 ok(UXValidator* v, u8* val)
    {
    return v.validate(val) ? (i32)1 : (i32)0;
    }

void main(void)
    {
    gFails = (i32)0;

    // a required, min-length username
    UXValidator* user = new UXValidator();
    user.requireNonEmpty((u8*)"Username is required");
    user.requireMinLength((i32)3, (u8*)"At least 3 characters");
    check("empty fails", ok(user, (u8*)""), (i32)0);
    check("empty error message", streq(user.firstError((u8*)""), (u8*)"Username is required") ? (i32)1 : (i32)0, (i32)1);
    check("too short fails", ok(user, (u8*)"ab"), (i32)0);
    check("short error is the length one", streq(user.firstError((u8*)"ab"), (u8*)"At least 3 characters") ? (i32)1 : (i32)0, (i32)1);
    check("valid passes", ok(user, (u8*)"alice"), (i32)1);
    check("valid has no error", user.firstError((u8*)"alice") == (u8*)0 ? (i32)1 : (i32)0, (i32)1);

    // an email-ish regex field
    UXValidator* email = new UXValidator();
    email.requireMatch((u8*)"[a-z]+@[a-z]+\\.[a-z]+", (u8*)"Not a valid email");
    check("good email passes", ok(email, (u8*)"bob@example.com"), (i32)1);
    check("bad email fails", ok(email, (u8*)"nope"), (i32)0);
    check("partial email fails (anchored full match)", ok(email, (u8*)"bob@ex"), (i32)0);

    // an integer in a range
    UXValidator* age = new UXValidator();
    age.requireIntRange((i32)0, (i32)120, (u8*)"Age must be 0-120");
    check("in range passes", ok(age, (u8*)"42"), (i32)1);
    check("over range fails", ok(age, (u8*)"200"), (i32)0);
    check("negative fails", ok(age, (u8*)"-5"), (i32)0);

    // max length
    UXValidator* code = new UXValidator();
    code.requireMaxLength((i32)4, (u8*)"Too long");
    check("within max passes", ok(code, (u8*)"AB12"), (i32)1);
    check("over max fails", ok(code, (u8*)"AB123"), (i32)0);

    // rule ordering: first failing rule's message wins
    UXValidator* multi = new UXValidator();
    multi.requireNonEmpty((u8*)"required");
    multi.requireMinLength((i32)5, (u8*)"min5");
    multi.requireMatch((u8*)"[0-9]+", (u8*)"digits only");
    check("empty -> required first", streq(multi.firstError((u8*)""), (u8*)"required") ? (i32)1 : (i32)0, (i32)1);
    check("short digits -> min5", streq(multi.firstError((u8*)"12"), (u8*)"min5") ? (i32)1 : (i32)0, (i32)1);
    check("long letters -> digits only", streq(multi.firstError((u8*)"abcdef"), (u8*)"digits only") ? (i32)1 : (i32)0, (i32)1);
    check("all good passes", ok(multi, (u8*)"12345"), (i32)1);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXValidator — required, regex, length, int-range, ordered first-error.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
