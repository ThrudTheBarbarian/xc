// test_win32_rules.xc — the rule editor over UXPredicate, driven headlessly.
//
// The engine itself is covered by test_predicate; this is the BOARD: rule rows -> a predicate tree
// -> the filtered row set the table publishes.  It drives the real KSRulesBoard from the kitchen
// sink (same code the three backends run), so the popup tags really are the UXP_* opcodes and the
// key popup really does map "Name" -> the "name" key path.  Win32/Wine because that is the backend
// that runs a whole UI headlessly; nothing here is Win32-specific.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "ks_app.xc"

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

// The dataset (KitchenSink.fillData) is:
//   README.md 2 KB Markdown | main.xc 14 KB Source | UXWindow.xc 9 KB Source | logo.png 48 KB Image
//   notes.txt 1 KB Text     | build.sh 512 B Script | data.json 22 KB JSON   | Makefile 3 KB Makefile
KSRulesBoard* gBoard;

// Set a rule row the way the UI would: pick a key, pick an operator, type a value.
void rule(i32 i, i32 keyTag, i32 opTag, u8* value)
    {
    ksrKey[i].selectByTag(keyTag);
    ksrOp[i].selectByTag(opTag);
    ksrVal[i].setText(value);
    }
i32 matched(void)
    {
    gBoard.applyRules();
    return ksMatchN;
    }
// The name in a given result slot — proves the table publishes the RIGHT rows, not just a count.
u8* hit(i32 i)
    {
    return i < ksMatchN ? ksName[ksMatch[i]] : (u8*)"(none)";
    }

void main(void)
    {
    gFails = (i32)0;
    UXWin32Driver* drv = new UXWin32Driver(); // kept typed: windowNative is Win32-only
    gDriver = drv;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);

    KitchenSink* ks = new KitchenSink();
    ks.fillData(); // the eight records the rules run over

    UXWindow* win = new UXWindow();
    UXView* canvas = new UXView();
    win.open((u8*)"Rules", UXGeom.make((i16)40, (i16)40, (i16)490, (i16)424), canvas);
    gBoard = new KSRulesBoard();
    canvas.addSubview(gBoard, UXGeom.make((i16)0, (i16)0, (i16)490, (i16)424));
    gBoard.setup(canvas);
    win.tree.finalise();
    win.displayAll(); // realize the native controls (the real ListView)

    // The board opens seeded with "Kind is Source" (row 1 has no value, so it is inactive).
    check("seeded: kind is Source", ksMatchN, (i32)2);
    check("  first hit is main.xc", UXPredicate.streq(hit((i32)0), (u8*)"main.xc") ? (i32)1 : (i32)0, (i32)1);

    // AND: both rules must hold.
    // "UX", not "UXKit": the dataset has no file whose NAME contains "UXKit"
    // (UXWindow.xc is UXWindow), so the rule matched nothing and the hit check
    // below was asserting against "(none)".  "UX" is the substring that picks
    // UXWindow.xc out of the two Source files, which is what this row is for.
    rule((i32)1, (i32)0, (i32)UXP_CONTAINS, (u8*)"UX");
    check("All: Source AND name contains UX", matched(), (i32)1);
    check("  it is UXWindow.xc", UXPredicate.streq(hit((i32)0), (u8*)"UXWindow.xc") ? (i32)1 : (i32)0, (i32)1);

    // OR: either rule.
    gBoard.modePop.selectByTag((i32)KR_ANY);
    rule((i32)1, (i32)2, (i32)UXP_EQ, (u8*)"Image");
    check("Any: kind Source OR kind Image", matched(), (i32)3);

    // NOT(OR(...)): the complement of the same two rules.
    gBoard.modePop.selectByTag((i32)KR_NONE);
    check("None: neither Source nor Image", matched(), (i32)5);

    // An empty value is an inactive row; with no active rule nothing is filtered at all.
    gBoard.modePop.selectByTag((i32)KR_ALL);
    rule((i32)0, (i32)0, (i32)UXP_CONTAINS, (u8*)"");
    rule((i32)1, (i32)0, (i32)UXP_CONTAINS, (u8*)"");
    check("no active rules -> everything", matched(), (i32)8);

    // Numeric comparison: the engine parses the LEADING integer of each side, so "512 B" reads as
    // 512 — units are not modelled, which is exactly why "greater than 20" also takes build.sh.
    rule((i32)0, (i32)1, (i32)UXP_GT, (u8*)"20");
    check("size greater than 20", matched(), (i32)3);
    rule((i32)0, (i32)1, (i32)UXP_LT, (u8*)"3");
    check("size less than 3", matched(), (i32)2);

    // String operators, including MATCHES (an UXRegex search, not an anchored match).
    rule((i32)0, (i32)0, (i32)UXP_ENDSWITH, (u8*)".xc");
    check("name ends with .xc", matched(), (i32)2);
    rule((i32)0, (i32)0, (i32)UXP_BEGINSWITH, (u8*)"ma");
    check("name begins with ma", matched(), (i32)1);
    // MATCHES searches, it does not anchor: this takes notes.tXT as well as the two .xc and the .json.
    // The alternation must therefore list xc — without it only notes.txt and
    // data.json match, which is the 2 this asked 4 of.
    rule((i32)0, (i32)0, (i32)UXP_MATCHES, (u8*)"(xc|xt|json)");
    check("name matches (xc|xt|json)", matched(), (i32)4);
    rule((i32)0, (i32)2, (i32)UXP_NE, (u8*)"Source");
    check("kind is not Source", matched(), (i32)6);

    // The row-editing rules: a delete shifts the rows below it up, and one row always survives.
    gBoard.nRows = (i32)2;
    rule((i32)0, (i32)2, (i32)UXP_EQ, (u8*)"Image");
    rule((i32)1, (i32)0, (i32)UXP_ENDSWITH, (u8*)".xc");
    gBoard.modePop.selectByTag((i32)KR_ANY);
    check("two rules, Any", matched(), (i32)3);
    gBoard.removeRow((i32)0); // row 1 shifts up into row 0
    check("after delete: only .xc survives", ksMatchN, (i32)2);
    check("  row count fell to 1", gBoard.nRows, (i32)1);
    gBoard.removeRow((i32)0); // the last row is not removable
    check("  last row is kept", gBoard.nRows, (i32)1);

    // ...and the NATIVE list must follow.  reloadData only moves the toolkit's shadow rows; the
    // SysListView32 is filled once at creation, so without a refill it showed the original eight
    // rows however the rules changed.  Ask the control itself how many rows it holds.
    pointer lv = GetDlgItem(drv.windowNative(win.handle), (i32)W32_CTRL_ID_BASE + (i32)gBoard.result.index);
    if (lv == (pointer)0)
        {
        Stdio.printf("  FAIL no native ListView\n");
        gFails = gFails + (i32)1;
        }
    else
        {
        // Each step must differ from the one before, or a STALE list passes by coincidence: the
        // control was filled with the seeded rule's two rows, so any check expecting 2 proves nothing.
        // 8 -> 2 -> 3 changes the count every time.
        gBoard.modePop.selectByTag((i32)KR_ALL);
        rule((i32)0, (i32)0, (i32)UXP_CONTAINS, (u8*)""); // no active rule -> all eight
        rule((i32)1, (i32)0, (i32)UXP_CONTAINS, (u8*)"");
        i32 want = matched();
        win.display(); // realizeTree runs here: the refill happens
        check("native list rows (no rules -> 8)", (i32)SendMessageA(lv, (u32)LVM_GETITEMCOUNT, (pointer)0, (pointer)0), want);
        rule((i32)0, (i32)2, (i32)UXP_EQ, (u8*)"Source");
        want = matched();
        win.display();
        check("native list rows (kind is Source -> 2)", (i32)SendMessageA(lv, (u32)LVM_GETITEMCOUNT, (pointer)0, (pointer)0), want);
        rule((i32)0, (i32)1, (i32)UXP_GT, (u8*)"20");
        want = matched();
        win.display();
        check("native list rows (size > 20 -> 3)", (i32)SendMessageA(lv, (u32)LVM_GETITEMCOUNT, (pointer)0, (pointer)0), want);
        }

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: rule rows -> predicate tree -> filtered rows\n");
        }
    else
        {
        Stdio.printf("FAIL: %d checks failed\n", gFails);
        }
    }
