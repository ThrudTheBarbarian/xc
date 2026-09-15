// test_sortdescriptor.xc — UXSortDescriptor sorting UXEvaluable records by a key.
#import <Stdio.xc>
#import "UXSortDescriptor.xc"
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

class Person : Object<UXEvaluable>
    {
    u8* name;
    u8* ageStr;
    void init(void)
        {
        name = (u8*)"";
        ageStr = (u8*)"0";
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
        return (u8*)"";
        }
    } Person* mk(u8* n, u8* a)
    {
    Person* p = new Person();
    p.name = n;
    p.ageStr = a;
    return p;
    }
u8* nameAt(Array<Person>* a, i32 i)
    { return ((Person* ?)a.get((u16)i)).name;
    }

void main(void)
    {
    gFails = (i32)0;
    Array* people = new Array();
    people.add(mk((u8*)"Carol", (u8*)"41"));
    people.add(mk((u8*)"Alice", (u8*)"34"));
    people.add(mk((u8*)"Bob", (u8*)"28"));

    // sort by name ascending
    UXSortDescriptor.make((u8*)"name", true).sort(people);
    eq("name asc [0]", nameAt(people, (i32)0), (u8*)"Alice");
    eq("name asc [1]", nameAt(people, (i32)1), (u8*)"Bob");
    eq("name asc [2]", nameAt(people, (i32)2), (u8*)"Carol");

    // sort by name descending
    UXSortDescriptor.make((u8*)"name", false).sort(people);
    eq("name desc [0]", nameAt(people, (i32)0), (u8*)"Carol");
    eq("name desc [2]", nameAt(people, (i32)2), (u8*)"Alice");

    // sort by age numerically ascending (string sort would misorder "28","34","41" — here they're fine,
    // but test numeric with values that string-sort wrong)
    Array* nums = new Array();
    nums.add(mk((u8*)"nine", (u8*)"9"));
    nums.add(mk((u8*)"ten", (u8*)"10"));
    nums.add(mk((u8*)"two", (u8*)"2"));
    UXSortDescriptor.numericKey((u8*)"age", true).sort(nums);
    eq("numeric asc [0] = 2", nameAt(nums, (i32)0), (u8*)"two");
    eq("numeric asc [1] = 9", nameAt(nums, (i32)1), (u8*)"nine");
    eq("numeric asc [2] = 10", nameAt(nums, (i32)2), (u8*)"ten");

    // string sort of the same would put "10" before "2" (lexicographic) — prove numeric differs
    UXSortDescriptor.make((u8*)"age", true).sort(nums);            // string sort by age
    eq("string asc [0] = '10'", nameAt(nums, (i32)0), (u8*)"ten"); // "10" < "2" lexically
    eq("string asc [1] = '2'", nameAt(nums, (i32)1), (u8*)"two");
    eq("string asc [2] = '9'", nameAt(nums, (i32)2), (u8*)"nine");

    // numeric descending
    UXSortDescriptor.numericKey((u8*)"age", false).sort(nums);
    eq("numeric desc [0] = 10", nameAt(nums, (i32)0), (u8*)"ten");
    eq("numeric desc [2] = 2", nameAt(nums, (i32)2), (u8*)"two");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXSortDescriptor — string + numeric sort, ascending/descending, over UXEvaluable.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
