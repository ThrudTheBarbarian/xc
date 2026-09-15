// test_keyvaluestore.xc — UXKeyValueStore: typed values + registration fallbacks.
#import <Stdio.xc>
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
        Stdio.printf("  ok   %s = \"%s\"\n", what, got == (u8*)0 ? (u8*)"(null)" : got);
        }
    else
        {
        Stdio.printf("  FAIL %s mismatch\n", what);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    UXKeyValueStore* d = new UXKeyValueStore();

    // typed set/get
    d.setInt((u8*)"fontSize", (i32)14);
    d.setBool((u8*)"showToolbar", true);
    d.setString((u8*)"theme", (u8*)"dark");
    check("int value", d.intFor((u8*)"fontSize"), (i32)14);
    check("bool value", d.boolFor((u8*)"showToolbar") ? (i32)1 : (i32)0, (i32)1);
    eq("string value", d.stringFor((u8*)"theme"), (u8*)"dark");
    check("hasKey set", d.hasKey((u8*)"theme") ? (i32)1 : (i32)0, (i32)1);
    check("hasKey unset", d.hasKey((u8*)"nope") ? (i32)1 : (i32)0, (i32)0);

    // unset reads default zero/null/false
    check("unset int is 0", d.intFor((u8*)"missing"), (i32)0);
    check("unset bool is false", d.boolFor((u8*)"missing") ? (i32)1 : (i32)0, (i32)0);
    check("unset string is null", d.stringFor((u8*)"missing") == (u8*)0 ? (i32)1 : (i32)0, (i32)1);

    // registration domain: fallback used only when not explicitly set
    d.registerInt((u8*)"maxItems", (i32)100);
    d.registerString((u8*)"lang", (u8*)"en");
    check("registered fallback int", d.intFor((u8*)"maxItems"), (i32)100);
    eq("registered fallback string", d.stringFor((u8*)"lang"), (u8*)"en");
    check("but hasKey is false for a fallback-only key", d.hasKey((u8*)"maxItems") ? (i32)1 : (i32)0, (i32)0);
    d.setInt((u8*)"maxItems", (i32)5); // explicit overrides fallback
    check("explicit overrides fallback", d.intFor((u8*)"maxItems"), (i32)5);

    // change a value's type in place
    d.setString((u8*)"fontSize", (u8*)"big");
    eq("value retyped to string", d.stringFor((u8*)"fontSize"), (u8*)"big");

    // remove
    d.removeKey((u8*)"theme");
    check("removed key gone", d.hasKey((u8*)"theme") ? (i32)1 : (i32)0, (i32)0);
    check("removed string is null", d.stringFor((u8*)"theme") == (u8*)0 ? (i32)1 : (i32)0, (i32)1);

    // shared standard store
    UXKeyValueStore.standard().setInt((u8*)"launches", (i32)3);
    check("standard store shared", UXKeyValueStore.standard().intFor((u8*)"launches"), (i32)3);

    // domains.  There is no driver here, so nothing persists — but the DOMAIN RULES are the same
    // with or without one: a domain has its own values, and inherits the shared domain's where it
    // has none.  (The persistent half is test_gem_settings / test_win32_settings / test_mac_settings.)
    UXKeyValueStore* ks = UXKeyValueStore.forDomain((u8*)"app.ks");
    UXKeyValueStore* paint = UXKeyValueStore.forDomain((u8*)"app.paint");
    check("forDomain is stable", UXKeyValueStore.forDomain((u8*)"app.ks") == ks ? (i32)1 : (i32)0, (i32)1);
    check("a domain is not the standard store", ks == UXKeyValueStore.standard() ? (i32)1 : (i32)0, (i32)0);
    check("an empty domain IS the standard store",
          UXKeyValueStore.forDomain((u8*)"") == UXKeyValueStore.standard() ? (i32)1 : (i32)0, (i32)1);
    UXKeyValueStore.standard().setInt((u8*)"fontSize", (i32)10);
    ks.setInt((u8*)"fontSize", (i32)14);
    check("a domain keeps its own value", ks.intFor((u8*)"fontSize"), (i32)14);
    check("...without disturbing the shared one", UXKeyValueStore.standard().intFor((u8*)"fontSize"), (i32)10);
    check("...or another domain's", paint.intFor((u8*)"fontSize"), (i32)10); // inherited, not 14
    paint.setInt((u8*)"fontSize", (i32)18);
    check("two domains, two values", ks.intFor((u8*)"fontSize") + paint.intFor((u8*)"fontSize"), (i32)32);
    check("a domain's own value is explicit", ks.hasKey((u8*)"fontSize") ? (i32)1 : (i32)0, (i32)1);
    check("an inherited one is not",
          UXKeyValueStore.forDomain((u8*)"app.other").hasKey((u8*)"fontSize") ? (i32)1 : (i32)0, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXKeyValueStore — typed values, defaults zero/null, registration fallbacks, remove, shared, domains.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
