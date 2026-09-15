// test_android_settings.xc — UXKit's settings in SharedPreferences.
//
// The same script as the gem/win32/mac/gtk settings gates, against the Android backend: two LAUNCHES
// of one activity, the second of which must read back everything the first wrote.  The store is a
// real SharedPreferences file per domain — the platform's own store, visible to any inspector.
// Pass selection self-sequences through the store itself (a meta marker), because an activity has
// no environment to read; `pm clear` before the run makes the pair hermetic.
//
// No boot() and no window: the settings seam is callable from xt_main's own thread.
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
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
void checkTrue(u8* what, bool cond)
    {
    if (cond)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
void checkStr(u8* what, u8* got, u8* want)
    {
    if (got != (u8*)0 && UXKeyValueStore.streq(got, want))
        {
        Stdio.printf("  ok   %s = \"%s\"\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got == (u8*)0 ? (u8*)"(null)" : got, want);
        gFails = gFails + (i32)1;
        }
    }

void writePass(void)
    {
    UXKeyValueStore* shared = UXKeyValueStore.standard();
    UXKeyValueStore* ks = UXKeyValueStore.forDomain((u8*)"xg.test.ks");
    UXKeyValueStore* paint = UXKeyValueStore.forDomain((u8*)"xg.test.paint");

    shared.setInt((u8*)"fontSize", (i32)10);
    shared.setString((u8*)"theme", (u8*)"light");
    ks.setInt((u8*)"fontSize", (i32)14);
    ks.setString((u8*)"lastFile", (u8*)"notes.txt");
    ks.setBool((u8*)"wrap", true);
    ks.setBool((u8*)"ruler", false);
    paint.setInt((u8*)"fontSize", (i32)18);
    ks.setString((u8*)"doomed", (u8*)"x");
    ks.removeKey((u8*)"doomed");
    Stdio.printf("  wrote settings to SharedPreferences\n");
    }

void readPass(void)
    {
    UXKeyValueStore* shared = UXKeyValueStore.standard();
    UXKeyValueStore* ks = UXKeyValueStore.forDomain((u8*)"xg.test.ks");
    UXKeyValueStore* paint = UXKeyValueStore.forDomain((u8*)"xg.test.paint");
    UXKeyValueStore* other = UXKeyValueStore.forDomain((u8*)"xg.test.other");

    check("shared fontSize survived", shared.intFor((u8*)"fontSize"), (i32)10);
    checkStr("shared theme survived", shared.stringFor((u8*)"theme"), (u8*)"light");
    check("ks fontSize survived", ks.intFor((u8*)"fontSize"), (i32)14);
    check("paint fontSize survived", paint.intFor((u8*)"fontSize"), (i32)18);
    checkStr("ks string survived", ks.stringFor((u8*)"lastFile"), (u8*)"notes.txt");
    checkTrue("ks bool true survived", ks.boolFor((u8*)"wrap"));
    checkTrue("ks bool false survived", !ks.boolFor((u8*)"ruler"));

    check("unset domain inherits the shared value", other.intFor((u8*)"fontSize"), (i32)10);
    // ...but inheriting is not OWNING: the value was cached in the shared store, not this domain's,
    // so a later write to the shared domain still reaches it.
    checkTrue("an inherited value is not the domain's own", !other.hasKey((u8*)"fontSize"));
    checkTrue("...and the shared store does own it", UXKeyValueStore.standard().hasKey((u8*)"fontSize"));
    checkTrue("ks does not see the shared value", ks.intFor((u8*)"fontSize") != (i32)10);
    checkTrue("absent key has no value", !ks.hasKey((u8*)"nosuch"));
    check("absent key reads 0", ks.intFor((u8*)"nosuch"), (i32)0);
    ks.registerInt((u8*)"nosuch", (i32)7);
    check("registered fallback answers", ks.intFor((u8*)"nosuch"), (i32)7);
    checkTrue("...but is still not an explicit value", !ks.hasKey((u8*)"nosuch"));
    checkTrue("removed key is gone", !ks.hasKey((u8*)"doomed"));
    checkTrue("persisted key is explicit", ks.hasKey((u8*)"lastFile"));

    ks.setInt((u8*)"fontSize", (i32)22);
    ks.invalidate();
    check("rewrite reaches the store", ks.intFor((u8*)"fontSize"), (i32)22);
    ks.setInt((u8*)"fontSize", (i32)14);
    }

void main(void)
    {
    gFails = (i32)0;
    UXAndroidDriver* drv = new UXAndroidDriver();
    gDriver = drv; // no boot(): settings need no UI

    u8 probe[64];
    checkTrue("the store accepted a write", gDriver.settingSet((u8*)"xg.test", (u8*)"probe", (u8*)"ok"));
    checkTrue("...and gave it back",
              gDriver.settingGet((u8*)"xg.test", (u8*)"probe", &probe[(i32)0], (i32)64));
    checkStr("...unchanged", &probe[(i32)0], (u8*)"ok");
    checkTrue("an empty value is not the same as no value",
              gDriver.settingSet((u8*)"xg.test", (u8*)"empty", (u8*)"") &&
                  gDriver.settingGet((u8*)"xg.test", (u8*)"empty", &probe[(i32)0], (i32)64));
    checkTrue("no such key reports false",
              !gDriver.settingGet((u8*)"xg.test", (u8*)"neverset", &probe[(i32)0], (i32)64));

    // pass selection: the store itself remembers that the first launch ran
    u8 mark[8];
    if (!gDriver.settingGet((u8*)"xg.test.meta", (u8*)"ran", &mark[(i32)0], (i32)8))
        {
        gDriver.settingSet((u8*)"xg.test.meta", (u8*)"ran", (u8*)"1");
        writePass();
        Stdio.printf("WROTE: first launch complete\n");
        return;
        }
    readPass();

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: settings persist in SharedPreferences\n");
        }
    else
        {
        Stdio.printf("FAIL: %d checks failed\n", gFails);
        }
    }
