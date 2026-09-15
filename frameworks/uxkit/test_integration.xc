// test_integration.xc — the overnight classes composing on a realistic task.
//
// Load a JSON "database" of people, index it for search, filter it with a predicate, and format the
// results — proving UXJSON + UXSearchIndex + UXPredicate + UXNumberFormatter + UXKeyValueStore work
// together, not just in isolation.
#import <Stdio.xc>
#import "UXJSON.xc"
#import "UXSearchIndex.xc"
#import "UXPredicate.xc"
#import "UXNumberFormatter.xc"
#import "UXKeyValueStore.xc"

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

// Adapt a JSON object record to UXEvaluable so a predicate can filter it.
class Record : Object<UXEvaluable>
    {
    UXJSONValue* obj;
    void init(void)
        {
        obj = (UXJSONValue*)0;
        }
    u8* valueForKey(u8* key)
        {
        UXJSONValue* v = obj.get(key);
        if (v == (UXJSONValue*)0)
            {
            return (u8*)"";
            }
        if (v.valueType() == (i32)JV_STR)
            {
            return v.asString();
            }
        if (v.valueType() == (i32)JV_NUM)
            {
            return UXNumberFormatter.decimal().format(v.asInt());
            }
        return (u8*)"";
        }
    } Record* wrap(UXJSONValue* o)
    {
    Record* r = new Record();
    r.obj = o;
    return r;
    }

void main(void)
    {
    gFails = (i32)0;

    // 1. a JSON database
    u8* db = (u8*)"{\"people\":[{\"name\":\"Alice Smith\",\"city\":\"NYC\",\"age\":34,\"salary\":120000},{\"name\":\"Bob Jones\",\"city\":\"LA\",\"age\":28,\"salary\":95000},{\"name\":\"Carol Smythe\",\"city\":\"NYC\",\"age\":41,\"salary\":150000}]}";
    UXJSONValue* root = UXJSON.parse(db);
    check("parsed the database", root != (UXJSONValue*)0 ? (i32)1 : (i32)0, (i32)1);
    UXJSONValue* people = root.get((u8*)"people");
    check("three people", people.count(), (i32)3);

    // 2. index them for full-text search (by name + city)
    UXSearchIndex* index = new UXSearchIndex();
    for (i32 i = (i32)0; i < people.count(); i = i + (i32)1)
        {
        UXJSONValue* p = people.at(i);
        u8* blob = UXNumberFormatter.decimal().format(i); // just to have text; index real fields:
        index.addDocument(i, p.get((u8*)"name").asString());
        index.addDocument(i, p.get((u8*)"city").asString());
        }
    // search "Smith" -> only Alice (doc 0); "NYC" -> Alice + Carol (docs 0,2)
    check("search Smith finds 1", (i32)index.search((u8*)"Smith").count(), (i32)1);
    check("search NYC finds 2", (i32)index.search((u8*)"NYC").count(), (i32)2);

    // 3. filter with a predicate: age > 30 AND city == NYC  -> Alice + Carol
    UXPredicate* rule = UXPredicate.and (UXPredicate.greaterThan((u8*)"age", (u8*)"30"),
                                         UXPredicate.equals((u8*)"city", (u8*)"NYC"));
    i32 matched = (i32)0;
    for (i32 i = (i32)0; i < people.count(); i = i + (i32)1)
        {
        if (rule.evaluate(wrap(people.at(i))))
            {
            matched = matched + (i32)1;
            }
        }
    check("predicate matched 2 (Alice + Carol)", matched, (i32)2);

    // 4. format a salary with the currency formatter
    UXJSONValue* carol = people.at((i32)2);
    eq("formatted salary", UXNumberFormatter.currency((u8*)"$").format(carol.get((u8*)"salary").asInt()), (u8*)"$150,000");

    // 5. remember the last query in the settings store, and round-trip the DB through serialize
    UXKeyValueStore* prefs = new UXKeyValueStore();
    prefs.setString((u8*)"lastQuery", (u8*)"NYC");
    prefs.setInt((u8*)"resultCount", (i32)2);
    eq("stored query", prefs.stringFor((u8*)"lastQuery"), (u8*)"NYC");
    check("stored count", prefs.intFor((u8*)"resultCount"), (i32)2);
    UXJSONValue* again = UXJSON.parse(UXJSON.serialize(root));
    check("db survives JSON round-trip", again.get((u8*)"people").count(), (i32)3);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: integration — JSON + SearchIndex + Predicate + NumberFormatter + KeyValueStore compose.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
