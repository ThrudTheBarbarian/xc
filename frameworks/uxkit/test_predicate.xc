// test_predicate.xc — UXPredicate: the AND/OR/CONTAINS rule engine.
#import <Stdio.xc>
#import "UXPredicate.xc"

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

// A record answering UXEvaluable: name / age / city as string values.
class Person : Object<UXEvaluable>
    {
    u8* name;
    u8* ageStr;
    u8* city;
    void init(void)
        {
        name = (u8*)"";
        ageStr = (u8*)"0";
        city = (u8*)"";
        }
    u8* valueForKey(u8* key)
        {
        if (UXPredicate.streq(key, (u8*)"name"))
            {
            return name;
            }
        if (UXPredicate.streq(key, (u8*)"age"))
            {
            return ageStr;
            }
        if (UXPredicate.streq(key, (u8*)"city"))
            {
            return city;
            }
        return (u8*)"";
        }
    } Person* mkP(u8* n, u8* age, u8* c)
    {
    Person* p = new Person();
    p.name = n;
    p.ageStr = age;
    p.city = c;
    return p;
    }

i32 ev(UXPredicate* p, Person* who)
    {
    return p.evaluate(who) ? (i32)1 : (i32)0;
    }

void main(void)
    {
    gFails = (i32)0;
    Person* alice = mkP((u8*)"Alice Smith", (u8*)"34", (u8*)"NYC");
    Person* bob = mkP((u8*)"Bob Jones", (u8*)"28", (u8*)"LA");
    Person* carol = mkP((u8*)"Carol Smythe", (u8*)"41", (u8*)"NYC");

    // simple comparisons
    UXPredicate* over30 = UXPredicate.greaterThan((u8*)"age", (u8*)"30");
    check("Alice age>30", ev(over30, alice), (i32)1);
    check("Bob age>30", ev(over30, bob), (i32)0);
    check("Carol age>30", ev(over30, carol), (i32)1);

    UXPredicate* inNYC = UXPredicate.equals((u8*)"city", (u8*)"NYC");
    check("Alice in NYC", ev(inNYC, alice), (i32)1);
    check("Bob in NYC", ev(inNYC, bob), (i32)0);

    UXPredicate* notLA = UXPredicate.notEquals((u8*)"city", (u8*)"LA");
    check("Alice not LA", ev(notLA, alice), (i32)1);
    check("Bob not LA", ev(notLA, bob), (i32)0);

    // string ops
    UXPredicate* hasSm = UXPredicate.contains_((u8*)"name", (u8*)"Sm");
    check("Alice name has 'Sm'", ev(hasSm, alice), (i32)1);
    check("Carol name has 'Sm'", ev(hasSm, carol), (i32)1);
    check("Bob name has 'Sm'", ev(hasSm, bob), (i32)0);
    check("beginsWith Alice", ev(UXPredicate.beginsWith((u8*)"name", (u8*)"Alice"), alice), (i32)1);
    check("endsWith Smith", ev(UXPredicate.endsWith((u8*)"name", (u8*)"Smith"), alice), (i32)1);
    check("endsWith Smith on Carol (Smythe)", ev(UXPredicate.endsWith((u8*)"name", (u8*)"Smith"), carol), (i32)0);

    // MATCHES via regex: surname Sm(i|y)the?... i.e. starts with a capital and contains Sm
    UXPredicate* rx = UXPredicate.matches((u8*)"name", (u8*)"Sm(i|y)");
    check("Alice matches Sm(i|y)", ev(rx, alice), (i32)1);
    check("Carol matches Sm(i|y)", ev(rx, carol), (i32)1);
    check("Bob matches Sm(i|y)", ev(rx, bob), (i32)0);

    // compound: (age > 30) AND (city == NYC)
    UXPredicate* rule = UXPredicate.and (over30, inNYC);
    check("Alice: >30 AND NYC", ev(rule, alice), (i32)1);
    check("Bob: >30 AND NYC", ev(rule, bob), (i32)0);
    check("Carol: >30 AND NYC", ev(rule, carol), (i32)1);

    // (city == LA) OR (age >= 40)
    UXPredicate* rule2 = UXPredicate.or (UXPredicate.equals((u8*)"city", (u8*)"LA"),
                                         UXPredicate.greaterOrEqual((u8*)"age", (u8*)"40"));
    check("Alice: LA OR >=40", ev(rule2, alice), (i32)0);
    check("Bob: LA OR >=40", ev(rule2, bob), (i32)1);
    check("Carol: LA OR >=40", ev(rule2, carol), (i32)1);

    // NOT (city == NYC)
    UXPredicate* rule3 = UXPredicate.not(inNYC);
    check("Bob: NOT NYC", ev(rule3, bob), (i32)1);
    check("Alice: NOT NYC", ev(rule3, alice), (i32)0);

    // nested: NOT (over30 AND NYC)  -> only Bob
    UXPredicate* rule4 = UXPredicate.not(UXPredicate.and (over30, inNYC));
    check("Bob: NOT(>30 AND NYC)", ev(rule4, bob), (i32)1);
    check("Alice: NOT(>30 AND NYC)", ev(rule4, alice), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXPredicate — comparisons, string ops, MATCHES, AND/OR/NOT, nesting.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
