// test_web_settings.xc — UXKit's settings PERSIST on the web (the web-settings gate).
//
// Two loads of one page in one browser profile: the first writes, the second must read back
// everything the first wrote (localStorage), the way test_gtk/win32/gem/mac_settings do with two
// runs of a binary.  The pass is told by a marker the first load leaves; the second cleans up.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXKeyValueStore.xc"

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    UXWebDriver* d = new UXWebDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    d.boot(&sw, &sh);
    UXKeyValueStore* ks = UXKeyValueStore.forDomain((u8*)"xg.test.web");
    if (!ks.hasKey((u8*)"pass"))
        {
        ks.setInt((u8*)"fontSize", (i32)14);
        ks.setString((u8*)"lastFile", (u8*)"notes.txt");
        ks.setString((u8*)"greeting", (u8*)"héllo"); // UTF-8 bytes must survive
        ks.setBool((u8*)"wrap", true);
        ks.setString((u8*)"gone", (u8*)"x");
        ks.removeKey((u8*)"gone");
        ks.setInt((u8*)"pass", (i32)1);
        Stdio.printf("PASS1: written\n");
        return;
        }
    ck((u8*)"an int survives the reload", ks.intFor((u8*)"fontSize") == (i32)14);
    ck((u8*)"a string survives", UXKeyValueStore.streq(ks.stringFor((u8*)"lastFile"), (u8*)"notes.txt"));
    ck((u8*)"UTF-8 survives byte for byte", UXKeyValueStore.streq(ks.stringFor((u8*)"greeting"), (u8*)"héllo"));
    ck((u8*)"a bool survives", ks.boolFor((u8*)"wrap"));
    ck((u8*)"a removed key stays removed", !ks.hasKey((u8*)"gone"));
    ks.removeKey((u8*)"fontSize");
    ks.removeKey((u8*)"lastFile");
    ks.removeKey((u8*)"greeting");
    ks.removeKey((u8*)"wrap");
    ks.removeKey((u8*)"pass");
    Stdio.printf(gFails == (i32)0 ? "PASS: web settings persist across a reload (localStorage)\n" : "FAIL: %d\n", gFails);
    }
