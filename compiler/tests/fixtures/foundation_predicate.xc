//xtc-na: xt6502 — Predicate is not available on xt6502
// foundation_predicate.xc — Predicate: parsing, every operator, [c], key
// paths through nested Maps, numbers held in Strings, NULL, IN, LIKE,
// MATCHES, compound logic, a callback reader, filtering, description round
// trips and parse errors.
#import "Foundation.xc"
#import "JSON.xc"
#import "Predicate.xc"

String* S(u8* c)
    {
    return String.withCString(c);
    }
Map* rec(u8* json)
    {
    try
        {
        return (Map*)JSON.parse(S(json));
        }
    catch (JSONError e)
        {
        Stdio.printf("bad JSON\n");
        }
    return new Map();
    }
void t(u8* text, Map* r)
    {
    try
        {
        Predicate* p = Predicate.parse(S(text));
        Stdio.printf("%d  %s\n", (i32)(p.evaluate(r) ? 1 : 0), text);
        }
    catch (PredicateError e)
        {
        Stdio.printf("!  %s: %s\n", text, e.message().cString());
        }
    }
void d(u8* text)
    {
    try
        {
        Predicate* p = Predicate.parse(S(text));
        String* once = p.description();
        String* twice = Predicate.parse(once).description();
        Stdio.printf("%s -> %s%s\n", text, once.cString(), once.equals(twice) ? "" : " (differs when re-read)");
        }
    catch (PredicateError e)
        {
        Stdio.printf("!  %s\n", e.message().cString());
        }
    }

class Row : Object
    {
    Object* valueForKey(String* key)
        {
        if (key.equals(S("size")))
            return S("42");
        if (key.equals(S("kind")))
            return S("Folder");
        return (Object*)0;
        }
    }

i32 main(void)
    {
    Map* p = rec("{\"name\":\"Smith\",\"age\":42,\"height\":1.8,\"admin\":true,\"nick\":null,\"zip\":\"02139\",\"tags\":[\"a\"],\"address\":{\"city\":\"Leeds\",\"floor\":3}}");
    t("age > 30", p);
    t("age >= 42 AND age <= 42", p);
    t("age < 30 OR name = 'Smith'", p);
    t("NOT (age < 30)", p);
    t("!(age == 42)", p);
    t("age != 42", p);
    t("age <> 41", p);
    t("height > 1.75", p);
    t("height == 1.8", p);
    t("age = 42.0", p);
    t("zip > 2000", p);
    t("zip = '02139'", p);
    t("name CONTAINS 'mit'", p);
    t("name CONTAINS 'MIT'", p);
    t("name CONTAINS[c] 'MIT'", p);
    t("name BEGINSWITH 'Sm' && name ENDSWITH 'th'", p);
    t("name LIKE 'S*h'", p);
    t("name LIKE[c] 's?ith'", p);
    t("name LIKE 'S?'", p);
    t("name MATCHES '[A-Z][a-z]+'", p);
    t("name MATCHES 'mit'", p);
    t("name IN {'Jones', 'Smith'}", p);
    t("age IN {1, 2, 42}", p);
    t("admin == TRUE", p);
    t("admin = YES AND nick = NULL", p);
    t("missing = NULL", p);
    t("missing > 3 OR missing < 3", p);
    t("address.city = 'Leeds' AND address.floor > 2", p);
    t("address.nothing.deeper = NULL", p);
    t("name = 'Smith' AND age > 40 OR age < 0", p);
    t("TRUEPREDICATE", p);
    t("FALSEPREDICATE OR age = 42", p);
    t("age > 3 extra", p);
    t("age >", p);
    t("age ~ 3", p);
    t("name MATCHES '(unclosed'", p);
    t("name = 'open", p);
    t("(age > 3", p);

    Predicate* q = (Predicate*)0;
    try
        {
        q = Predicate.parse(S("size > 40 AND kind = 'folder'"));
        }
    catch (PredicateError e)
        {
        }
    Row* row = new Row();
    Stdio.printf("callback: %d\n", (i32)(q.evaluateWith(&row.valueForKey) ? 1 : 0));
    try
        {
        q = Predicate.parse(S("size > 40 AND kind =[c] 'folder'"));
        }
    catch (PredicateError e)
        {
        }
    Stdio.printf("callback [c]: %d\n", (i32)(q.evaluateWith(&row.valueForKey) ? 1 : 0));

    Array* people = new Array();
    people.add(rec("{\"name\":\"Ann\",\"age\":31}"));
    people.add(rec("{\"name\":\"Bob\",\"age\":17}"));
    people.add(rec("{\"name\":\"Cy\",\"age\":45}"));
    try
        {
        Array* adults = Predicate.parse(S("age >= 18")).filter(people);
        Stdio.printf("adults:");
        for (u32 i = (u32)0; i < adults.count(); i++)
            Stdio.printf(" %@", ((Map*)adults.get(i)).get(S("name")));
        Stdio.printf("\n");
        Predicate* built = Predicate.and(Predicate.compare(S("age"), S(">"), Number.withI32((i32)20), false),
                                         Predicate.not(Predicate.compare(S("name"), S("beginswith"), S("c"), true)));
        Stdio.printf("built: %s ->", built.description().cString());
        Array* some = built.filter(people);
        for (u32 i = (u32)0; i < some.count(); i++)
            Stdio.printf(" %@", ((Map*)some.get(i)).get(S("name")));
        Stdio.printf("\n");
        Predicate.compare(S("age"), S("~"), Number.withI32((i32)1), false);
        }
    catch (PredicateError e)
        {
        Stdio.printf("%s\n", e.message().cString());
        }

    d("a = 1 AND (b = 'x' OR NOT c CONTAINS[c] \"y\")");
    d("x IN {1, 'two', NULL, TRUE} && y <= -2.5");
    d("name = 'it\\'s'");
    return (i32)0;
    }
