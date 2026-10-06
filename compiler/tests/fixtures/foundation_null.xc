// foundation_null.xc — Null: one shared instance, told apart from a null
// reference, holding a place in a collection.
#import "Foundation.xc"

i32 gFails;
void check(u8* what, bool ok)
    {
    if (ok)
        Stdio.printf("  ok   %s\n", what);
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

i32 main(void)
    {
    gFails = (i32)0;
    check("shared", Null.null() == Null.null());
    check("isNull", Null.isNull(Null.null()));
    check("null reference is not Null", !Null.isNull((Object*)0));
    check("plain object is not Null", !Null.isNull(new Object()));
    check("isNothing reference", Null.isNothing((Object*)0));
    check("isNothing Null", Null.isNothing(Null.null()));
    check("isNothing object", !Null.isNothing(new Object()));
    Array* row = new Array();
    row.add(Number.withI32((i32)1));
    row.add(Null.null());
    row.add(Number.withI32((i32)3));
    check("keeps its place", row.count() == (u32)3 && Null.isNull(row.get((u32)1)));
    Stdio.printf("%@\n", Null.null());
    if (gFails == (i32)0)
        Stdio.printf("PASS\n");
    return gFails;
    }
