// test_appkit_memgate.xc — the per-backend memory gate for AppKit (doc/XTG-MULTIPLATFORM.md §10).
//
// The AppKit instance of the same gate the GEM (test_memgate.xc) and Win32 (test_win32_memgate.xc)
// backends pass: open and close N windows in a loop and assert the driver's NATIVE-OBJECT counter
// (gDriver.liveNativeCount()) returns to baseline — no leaked NSWindow/NSView.  The shim releases
// each window explicitly (releasedWhenClosed:NO + [release] on close) and drains autoreleased
// temporaries per call, so the counter is deterministic.
//
// NOTE on the heap probe: unlike GEM/Win32, the malloc/free-address oracle is NOT a valid leak
// detector here — Cocoa churns its OWN allocator caches (window-server buffers, fonts) on every
// create/destroy, so the delta swings both ways (a real leak is monotonic + scales with cycles;
// this is not).  The xtc-side allocations (front objects, view tree, shadow-tree node array, field
// editor) run the SAME code the Win32 gate proves heap-clean.  So we PRINT the heap delta for
// visibility but GATE on the native counter.  Each cycle builds a real form — content view + button
// + text field — exercising windowCreate/Destroy, structNew/Free, structAppend, fieldEditorNew/Free.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"

#define CYCLES 16

u32 probe(void)
    {
    pointer p = malloc((u32)16);
    free(p);
    return (u32)p;
    }

void windowCycle(bool explicitClose)
    {
    UXWindow* w = new UXWindow();
    UXView* content = new UXView();
    UXButton* b = new UXButton();
    b.setTitle((u8*)"ok");
    UXTextField* f = new UXTextField();
    w.open((u8*)"gate", UXGeom.make((i16)4, (i16)4, (i16)160, (i16)90), content);
    content.addSubview(b, UXGeom.make((i16)8, (i16)8, (i16)56, (i16)18));
    content.addSubview(f, UXGeom.make((i16)8, (i16)34, (i16)120, (i16)20));
    if (explicitClose)
        {
        w.close();
        }
    }

void run(u8* what, bool explicitClose)
    {
    i32 nativeBefore = gDriver.liveNativeCount();
    u32 allocBefore = probe();
    for (i32 i = (i32)0; i < (i32)CYCLES; i++)
        {
        windowCycle(explicitClose);
        }
    u32 allocAfter = probe();
    i32 nativeAfter = gDriver.liveNativeCount();

    i32 nativeLeak = nativeAfter - nativeBefore;
    i32 allocLeak = (i32)(allocAfter - allocBefore);
    Stdio.printf("%s over %d cycles: native=%d  heap~%d (Cocoa cache churn; not asserted)\n",
                 what, (i32)CYCLES, nativeLeak, allocLeak);
    }

void main(void)
    {
    gDriver = new UXAppKitDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("boot failed\n");
        return;
        }

    windowCycle(true); // warm-up: first-time allocations are not a leak
    run((u8*)"close  ", true);
    run((u8*)"dealloc", false);

    i32 leaked = gDriver.liveNativeCount();
    if (leaked == (i32)0)
        {
        Stdio.printf("PASS: AppKit backend passes its §10 gate\n");
        }
    else
        {
        Stdio.printf("FAIL: %d native window(s) leaked\n", leaked);
        }
    }
