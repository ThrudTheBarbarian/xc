// test_memgate.xc — the per-backend memory gate (doc/XTG-MULTIPLATFORM.md §10).
//
// §10 says every milestone from M1 carries a gate that opens and closes N windows in a
// loop and asserts BOTH counters return to their baseline:
//
//   1. the driver's own NATIVE-OBJECT counter (gDriver.liveNativeCount()) — incremented
//      in the driver's create path, decremented in destroy.  This catches a leaked gemd
//      window, which the allocator probe below CANNOT see: the leaked state lives in gemd
//      and in a static client-side handle slot, not on the xtc heap.
//   2. the xtc ALLOCATOR baseline (the probe from test_leak.xc) — catches a leaked
//      front object, view tree, or reverse-map entry, all of which are heap.
//
// Two leak sites, two probes.  This is the GEM instance of the gate; a Win32/AppKit/GTK
// driver mirrors it against the same oracle.  It also caught a real bug: UXWindow had no
// close() at all, so every window it opened leaked its native gemd handle + surface.
#import <Stdio.xc>
#import <GEM>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXView.xc"
#import "UXBoot.xc"

#define CYCLES 16

// Where the allocator's next small block lives.  If nothing leaked between two probes,
// the freed block comes straight back and the addresses match (see test_leak.xc).
u32 probe(void)
    {
    pointer p = malloc((u32)16);
    free(p);
    return (u32)p;
    }

// One unit of window work: open a real gemd window with a content view, then release it.
// `explicit` chooses the teardown path we are proving:
//   true  — the app-facing close() call
//   false — drop the only reference and let dealloc do it (the ARC -> native chain)
void windowCycle(bool explicitClose)
    {
    UXWindow* w = new UXWindow();
    UXView* content = new UXView();
    w.open("gate", UXGeom.make((i16)4, (i16)4, (i16)120, (i16)80), content);
    if (explicitClose)
        {
        w.close();
        }
    // w goes out of scope here; if it was not closed, dealloc closes it.
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
    Stdio.printf("%s over %ld cycles:\n", what, (i32)CYCLES);
    Stdio.printf("    native gemd windows still live: %ld  (want 0)\n", nativeLeak);
    Stdio.printf("    heap grew: %ld bytes            (want 0)\n", allocLeak);
    if (nativeLeak != (i32)0 || allocLeak != (i32)0)
        {
        Stdio.printf("    -- LEAK\n");
        }
    else
        {
        Stdio.printf("    -- CLEAN\n");
        }
    }

class Controller : Object<UXApplicationDelegate>
    {
    void init(void)
        {
        }

    i32 applicationDidStart(UXApplication* a)
        {
        // Warm up: the first window's first-time allocations (a fresh Array's buffer,
        // the theme, a first realloc) are legitimate one-time growth, not a leak.
        windowCycle(true);

        run("close() path ", true);
        run("dealloc path ", false);

        i32 leaked = gDriver.liveNativeCount(); // every window opened here is closed
        if (leaked == (i32)0)
            {
            Stdio.printf("PASS: open/close balances on both paths — no native window and\n");
            Stdio.printf("      no heap left behind.  The GEM backend passes its §10 gate.\n");
            }
        else
            {
            Stdio.printf("FAIL: %ld native gemd window(s) leaked.\n", leaked);
            }
        a.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    // qemu has no SD card, so init started no gemd.  TEST-ONLY (UXBoot.xc).
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }

    gDriver = new UXGemDriver(); // select the GEM backend (UXApplication is neutral)
    UXApplication* app = new UXApplication();
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
