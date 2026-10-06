//xtc-na: xt6502 — SortDescriptor is not available on xt6502
// foundation_sortdescriptor.xc — SortDescriptor: one and two keys, both
// directions, case folding, numbers held in Strings, missing values,
// stability, key paths, reversing, and a reader callback.
#import "Foundation.xc"
#import "JSON.xc"
#import "SortDescriptor.xc"

String* S(u8* c)
    {
    return String.withCString(c);
    }
void show(u8* what, Array* rows)
    {
    Stdio.printf("%s:", what);
    for (u32 i = (u32)0; i < rows.count(); i++)
        Stdio.printf(" %@", ((Map*)rows.get(i)).get(S("id")));
    Stdio.printf("\n");
    }

class Box : Object
    {
    i32 w;
    String* label;
    }
Object* boxValue(Object* item, String* key)
    {
    Box* b = (Box*)item;
    if (key.equals(S("w")))
        return Number.withI32(b.w);
    return b.label;
    }

i32 main(void)
    {
    Array* rows = new Array();
    try
        {
        rows = (Array*)JSON.parse(S("[{\"id\":\"a\",\"name\":\"bob\",\"age\":30,\"size\":\"10\",\"loc\":{\"city\":\"York\"}},{\"id\":\"b\",\"name\":\"Ann\",\"age\":25,\"size\":\"9\",\"loc\":{\"city\":\"Bath\"}},{\"id\":\"c\",\"name\":\"cy\",\"age\":30,\"size\":\"100\"},{\"id\":\"d\",\"name\":\"Ann\",\"age\":40,\"size\":\"9\",\"loc\":{\"city\":\"Ayr\"}},{\"id\":\"e\",\"name\":\"bob\",\"age\":null,\"size\":\"x\"}]"));
        }
    catch (JSONError e)
        {
        Stdio.printf("bad JSON\n");
        }
    show("as given", rows);
    show("name", SortDescriptor.sorted(rows, SortDescriptor.list1(SortDescriptor.withKey(S("name"), true))));
    SortDescriptor* folded = SortDescriptor.withKey(S("name"), true);
    folded.caseInsensitive = true;
    show("name [c]", SortDescriptor.sorted(rows, SortDescriptor.list1(folded)));
    show("age", SortDescriptor.sorted(rows, SortDescriptor.list1(SortDescriptor.withKey(S("age"), true))));
    show("age desc", SortDescriptor.sorted(rows, SortDescriptor.list1(SortDescriptor.withKey(S("age"), false))));
    show("age desc, name", SortDescriptor.sorted(rows, SortDescriptor.list2(SortDescriptor.withKey(S("age"), false), folded)));
    show("size as text", SortDescriptor.sorted(rows, SortDescriptor.list1(SortDescriptor.withKey(S("size"), true))));
    show("loc.city", SortDescriptor.sorted(rows, SortDescriptor.list1(SortDescriptor.withKey(S("loc.city"), true))));
    show("loc.city reversed", SortDescriptor.sorted(rows, SortDescriptor.list1(SortDescriptor.withKey(S("loc.city"), true).reversed())));
    show("no descriptors", SortDescriptor.sorted(rows, new Array()));

    Array* boxes = new Array();
    for (i32 i = (i32)0; i < (i32)4; i++)
        {
        Box* b = new Box();
        b.w = ((i32)3 * i) % (i32)4;
        b.label = Number.withI32(i).description();
        boxes.add(b);
        }
    Array* bw = SortDescriptor.sortedWith(boxes, SortDescriptor.list1(SortDescriptor.withKey(S("w"), true)), &boxValue);
    Stdio.printf("boxes by w:");
    for (u32 i = (u32)0; i < bw.count(); i++)
        Stdio.printf(" %d", ((Box*)bw.get(i)).w);
    Stdio.printf("\n");
    return (i32)0;
    }
