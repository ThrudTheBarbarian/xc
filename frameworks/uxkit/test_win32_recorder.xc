// test_win32_recorder.xc — capture the event stream and play it back into a live UI.
//
// test_eventrecorder covers the model against synthetic time.  This drives the REAL kitchen-sink
// Recorder window: events go through UXApplication's tap (which is how a recorder sees anything at
// all), and replay pushes the copies back through the window's own dispatch.  The proof is that the
// widgets reach the same state the second time WITHOUT the user: a row selected, a box toggled.
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

KitchenSink* gKS;
UXWin32Driver* gDrv;

// A click at the centre of a view, pushed through the SAME funnel the run loop uses — so the tap
// sees it exactly as it would see a real one.
void clickView(UXView* v)
    {
    UXRect r = v.absoluteFrame();
    UXEvent* e = new UXEvent();
    e.kind = (u8)UXEventMouseDown;
    e.x = (i16)((i32)r.x + (i32)r.w / (i32)2);
    e.y = (i16)((i32)r.y + (i32)r.h / (i32)2);
    e.handle = gKS.recWin.handle;
    gApp.dispatchEvent(e);
    }
// A click the way the OS delivers one to a NATIVE control: the driver gets a notification, not a
// mouse event.  Sending BN_CLICKED through the real window proc exercises the path a user's click
// takes, which is the one the tap has to cover.
void nativeClick(UXControl* c)
    {
    pointer hwnd = GetDlgItem(gDrv.windowNative(gKS.recWin.handle), (i32)W32_CTRL_ID_BASE + (i32)c.index);
    if (hwnd == (pointer)0)
        {
        Stdio.printf("  FAIL no native control for the checkbox\n");
        gFails = gFails + (i32)1;
        return;
        }
    u32 wp = ((u32)BN_CLICKED << (u32)16) | (u32)((i32)W32_CTRL_ID_BASE + (i32)c.index);
    SendMessageA(gDrv.windowNative(gKS.recWin.handle), (u32)WM_COMMAND, (pointer)wp, hwnd);
    }
void clickAt(i16 x, i16 y)
    {
    UXEvent* e = new UXEvent();
    e.kind = (u8)UXEventMouseDown;
    e.x = x;
    e.y = y;
    e.handle = gKS.recWin.handle;
    gApp.dispatchEvent(e);
    }

void main(void)
    {
    gFails = (i32)0;
    UXWin32Driver* drv = new UXWin32Driver();
    gDrv = drv;
    gDriver = drv;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);

    UXApplication* app = new UXApplication();
    gApp = app;
    gKS = new KitchenSink();
    gKS.app = app;
    gKS.fillData();
    gKS.buildRecord(); // the real window, its real widgets

    // The clock the recorder stamps with must move forward.
    i32 t0 = gDriver.nowMs();
    for (i32 spin = (i32)0; spin < (i32)200000; spin = spin + (i32)1)
        {
        }
    checkTrue("driver clock is monotonic", gDriver.nowMs() >= t0);

    // Nothing is captured until Record is pressed — a tap that records unasked would be a bug.
    nativeClick(gKS.recCheck);
    check("no capture before Record", gKS.recorder.count(), (i32)0);
    bool checkedAfterFirst = gKS.recCheck.isChecked();

    // Record: a row selection, then the toggle — the CHECKBOX through the native notification path
    // (WM_COMMAND/BN_CLICKED), because that is how a real click on a native control arrives and it
    // bypasses the app's dispatch entirely.  Recording only what dispatchEvent sees would miss it.
    gKS.onRecStart((UXControl*)0);
    checkTrue("recording", gKS.recorder.isRecording());
    UXRect tr = gKS.recTable.absoluteFrame();
    clickAt((i16)((i32)tr.x + (i32)40), (i16)((i32)tr.y + (i32)30)); // a row in the table
    nativeClick(gKS.recCheck);
    gKS.onRecStop((UXControl*)0);
    checkTrue("stopped", !gKS.recorder.isRecording());
    check("captured both events", gKS.recorder.count(), (i32)2);
    checkTrue("events carry a timestamp", gKS.recorder.durationMs() >= (i32)0);

    // The state those events produced.
    i32 rowAfterRecord = gKS.recTable.selection();
    bool checkAfterRecord = gKS.recCheck.isChecked();
    checkTrue("the toggle changed while recording", checkAfterRecord != checkedAfterFirst);

    // Undo it by hand, then let REPLAY put it back — without touching the widgets.
    gKS.recTable.setRowSelected(rowAfterRecord, false);
    gKS.recCheck.setChecked(checkedAfterFirst);
    checkTrue("state reset before replay", gKS.recCheck.isChecked() == checkedAfterFirst);

    gKS.onRecReplay((UXControl*)0);
    check("replay reselected the same row", gKS.recTable.selection(), rowAfterRecord);
    checkTrue("replay re-toggled the box", gKS.recCheck.isChecked() == checkAfterRecord);

    // AND ON SCREEN.  The model changing proves nothing on a backend whose widgets are native — the
    // first version of this test asserted only isChecked() and passed while the real app showed
    // nothing at all.  Ask the CONTROL: realizeTree pushes the model into it with BM_SETCHECK.
    gKS.recWin.displayAll();
    pointer cb = GetDlgItem(gDrv.windowNative(gKS.recWin.handle), (i32)W32_CTRL_ID_BASE + (i32)gKS.recCheck.index);
    i32 nativeState = (i32)SendMessageA(cb, (u32)BM_GETCHECK, (pointer)0, (pointer)0);
    check("the NATIVE checkbox followed the replay", nativeState, checkAfterRecord ? (i32)1 : (i32)0);

    // Replay must not record itself: the tap is off, and dispatch goes in below it.
    check("replay did not grow the recording", gKS.recorder.count(), (i32)2);

    // ---- selection through the NATIVE notification path ---------------------------------------
    // A click on a SysListView32 arrives as WM_NOTIFY/LVN_ITEMCHANGED and never reaches the toolkit,
    // so a recording held every button press and no sign a row was ever chosen — "the toggle replays
    // but the others do not".  Drive that notification and check the recording carries the selection
    // and that replay restores it.
    //
    // The CONTROL is asserted too now — this used to be the documented gap.  What made the push work
    // is clearing ROW BY ROW: the documented broadcast (LVM_SETITEMSTATE with wParam -1) does nothing
    // under Wine, exactly as LVM_GETNEXTITEM with -1 does nothing here, so the old rows survived
    // every attempt and the control was left holding the UNION of the old selection and the new.
    // Start from a KNOWN state.  Now that the model's selection really does reach the control, a row
    // left selected by an earlier phase of this test is mirrored into the list and shows up in the
    // counts below — the fixture has to be explicit rather than assumed empty.
    gKS.recTable.deselectAllRows();
    gKS.recWin.displayAll();
    gKS.recorder.clear();
    gKS.onRecStart((UXControl*)0);
    pointer lv = GetDlgItem(gDrv.windowNative(gKS.recWin.handle), (i32)W32_CTRL_ID_BASE + (i32)gKS.recTable.index);
    if (lv == (pointer)0)
        {
        Stdio.printf("  FAIL no native list\n");
        gFails = gFails + (i32)1;
        }
    else
        {
        LVITEM sel;
        sel.mask = (u32)0;
        sel.iItem = (i32)0;
        sel.iSubItem = (i32)0;
        sel.state = (u32)LVIS_SELECTED;
        sel.stateMask = (u32)LVIS_SELECTED;
        sel.pszText = (pointer)0;
        sel.cchTextMax = (i32)0;
        sel.iImage = (i32)0;
        sel.lParam = (pointer)0;
        sel.iIndent = (i32)0;
        SendMessageA(lv, (u32)LVM_SETITEMSTATE, (pointer)2, (pointer)&sel); // the control selects row 2
        check("the model followed the native selection", gKS.recTable.selection(), (i32)2);
        checkTrue("the selection was announced", gKS.recorder.count() > (i32)0);
        // A MULTI-row selection: the announcement carries the whole set, not just the anchor — an
        // anchor alone replayed as one row however many were chosen ("only 1 line selected").
        sel.state = (u32)LVIS_SELECTED;
        SendMessageA(lv, (u32)LVM_SETITEMSTATE, (pointer)4, (pointer)&sel);
        check("two rows selected while recording", gKS.recTable.selectedCount(), (i32)2);
        gKS.onRecStop((UXControl*)0);

        gKS.recTable.deselectAllRows(); // clear it by hand
        check("selection cleared before replay", gKS.recTable.selectedCount(), (i32)0);
        gKS.onRecReplay((UXControl*)0);
        check("replay restored BOTH rows", gKS.recTable.selectedCount(), (i32)2);
        checkTrue("...row 2", gKS.recTable.isRowSelected((i32)2));
        checkTrue("...and row 4", gKS.recTable.isRowSelected((i32)4));

        // ...and the CONTROL followed, which is the half that never worked.  realizeTree does the
        // push, so display it first, then ask the list itself — not the model.
        gKS.recWin.displayAll();
        check("the native list holds two rows", (i32)SendMessageA(lv, (u32)LVM_GETSELECTEDCOUNT, (pointer)0, (pointer)0), (i32)2);
        checkTrue("...row 2 in the control", ((u32)SendMessageA(lv, (u32)LVM_GETITEMSTATE,
                                                                (pointer)2, (pointer)LVIS_SELECTED) &
                                              (u32)LVIS_SELECTED) != (u32)0);
        checkTrue("...row 4 in the control", ((u32)SendMessageA(lv, (u32)LVM_GETITEMSTATE,
                                                                (pointer)4, (pointer)LVIS_SELECTED) &
                                              (u32)LVIS_SELECTED) != (u32)0);
        // The union bug in one assertion: a row that was selected BEFORE the push must be gone.
        gKS.recTable.selectRow((i32)7);
        gKS.recWin.displayAll();
        check("a narrowed selection replaces, not unions", (i32)SendMessageA(lv, (u32)LVM_GETSELECTEDCOUNT, (pointer)0, (pointer)0), (i32)1);
        checkTrue("...and it is row 7", ((u32)SendMessageA(lv, (u32)LVM_GETITEMSTATE,
                                                           (pointer)7, (pointer)LVIS_SELECTED) &
                                         (u32)LVIS_SELECTED) != (u32)0);

        // Typing: keystrokes reach a native EDIT and surface only as EN_CHANGE, so the recording
        // holds the TEXT rather than the keys.
        gKS.recorder.clear();
        gKS.onRecStart((UXControl*)0);
        gKS.recField.setText((u8*)"replay me");
        gKS.recField.fieldDidChange(); // what EN_CHANGE drives
        checkTrue("the text change was announced", gKS.recorder.count() > (i32)0);
        gKS.onRecStop((UXControl*)0);
        gKS.recField.setText((u8*)"");
        check("field cleared before replay", (i32)UXPredicate.slen(gKS.recField.text()), (i32)0);
        gKS.onRecReplay((UXControl*)0);
        checkTrue("replay put the text back",
                  UXPredicate.streq(gKS.recField.text(), (u8*)"replay me"));
        }

    // ---- scroll: recorded as an OUTCOME, because the drag that caused it emits nothing ----------
    // Find the table's own scroll view, scroll it while recording, put it back by hand, and let
    // replay restore the offset.  Without the announcement a recording replays every click
    // faithfully and leaves the view scrolled somewhere else entirely.
    gKS.recorder.clear();
    gKS.onRecStart((UXControl*)0);
    UXScrollView* tsv = gKS.recTable.scroll;
    if (tsv == (UXScrollView*)0)
        {
        Stdio.printf("  FAIL table has no scroll view\n");
        gFails = gFails + (i32)1;
        }
    else
        {
        // Both paths now behave the same way, which is the point: the toolkit scrolls the view, the
        // scroll is announced, and a replay puts it back.  On a native backend that used to be three
        // no-ops — scrollTo returned early because "the container owns the offset", with no way to
        // tell the container anything.  A table's scroll is the native list's own (LVM_SCROLL), a
        // plain scroll view's is an UXScroll32; nativeScrollTo hides which.
        tsv.scrollTo((i16)40);
        i32 want = (i32)tsv.scrollPx();
        checkTrue("scrolled while recording", want > (i32)0);
        checkTrue("the scroll was announced", gKS.recorder.count() > (i32)0);
        gKS.onRecStop((UXControl*)0);
        tsv.scrollTo((i16)0); // put it back by hand
        check("scroll reset before replay", (i32)tsv.scrollPx(), (i32)0);
        gKS.onRecReplay((UXControl*)0);
        check("replay restored the scroll offset", (i32)tsv.scrollPx(), want);
        }

    // A replayed press must not grab the live pointer.  A drag is not in the event stream at all —
    // pressing a scrollbar enters the driver's modal trackDragStep, which follows the pointer until
    // release — so replaying the press alone re-entered that loop and the widget carried on scrolling
    // under the user's hand.  gInputReplay makes the drag poll report "not dragging" at once.
    checkTrue("not replaying once replay returned", !gInputReplay);
    i32 dx = (i32)0;
    i32 dy = (i32)0;
    gInputReplay = true;
    check("drag poll declines during a replay", gDriver.trackDragStep(&dx, &dy), (i32)0);
    gInputReplay = false;

    // Clear empties it.
    gKS.onRecClear((UXControl*)0);
    check("clear empties the recording", gKS.recorder.count(), (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: capture through the tap, replay through dispatch\n");
        }
    else
        {
        Stdio.printf("FAIL: %d checks failed\n", gFails);
        }
    }
