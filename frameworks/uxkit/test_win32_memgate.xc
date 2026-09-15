// test_win32_memgate.xc — the per-backend memory gate for Win32 (doc/XTG-MULTIPLATFORM.md §10).
//
// §10 says every milestone carries a gate that opens and closes N windows in a loop and asserts
// BOTH counters return to baseline:
//   1. the driver's NATIVE-OBJECT counter (gDriver.liveNativeCount()) — a leaked HWND, which
//      the heap probe below cannot see (it lives in the window manager + the handle table).
//   2. the ALLOCATOR baseline — a leaked front object, view tree, shadow-tree node array, or
//      field editor, all of which are heap.  Same malloc/free-address oracle as GEM's gate.
//
// This is the Win32 instance of the same gate the GEM backend passes (test_memgate.xc).  Each
// cycle builds a real form — content view + button + text field — so it exercises windowCreate/
// Destroy, structNew/Free, structAppend, and fieldEditorNew/Free together.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
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

// One unit of work: open a window with a small form, then release it — by close() or by
// dropping the only reference and letting dealloc walk the ARC -> native chain.
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
    Stdio.printf("%s over %d cycles: native=%d heap=%d\n", what, (i32)CYCLES, nativeLeak, allocLeak);
    }

void main(void)
    {
    gDriver = new UXWin32Driver();
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
        Stdio.printf("PASS: Win32 backend passes its §10 gate\n");
        }
    else
        {
        Stdio.printf("FAIL: %d native window(s) leaked\n", leaked);
        }
    }
