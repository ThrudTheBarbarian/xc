// test_posted.xc — work posted to the UI thread from a worker (UXViewDriver.setPostedHook).
//
// A worker thread posts N progress updates to RunLoop.main() while the UI loop is idle: it waits
// first, so the loop is asleep in the platform's wait, and pauses between bursts, so it falls
// asleep again.  The UI thread must see all N, in order, on its own thread.  One update goes
// through OperationQueue.main() and one through a RunLoop timer, the two other ways work reaches
// RunLoop.main().  Nothing sends the loop any input, so only the driver's wake can run the blocks;
// UX_AUTOQUIT ends a run whose blocks never arrive.
//
// One source for every threaded backend; the build picks the driver:
//   -A arm64 (AppKit), -A arm64 -D UX_POSTED_GTK (GTK), -A x86_64 (GTK), -A win64 (Win32),
//   -A ios-sim (iOS), -A android (Android).  On the last two the platform owns the loop and run()
//   never returns, so the last block reports, and a watchdog fails a run that never gets there.
//   Build+run: sh run_posted.sh
#import <Stdio.xc>
#import "Thread.xc"
#import "RunLoop.xc"
#import "OperationQueue.xc"
#if PLATFORM_ios
#import "UXIosDriver.xc"
extern void ux_ios_test_watchdog(i32 ms, i32 rc); // a wedge fails, never hangs
#elif PLATFORM_android
#import "UXAndroidDriver.xc"
extern void ux_and_test_watchdog(i32 ms, i32 rc);
#elif ARCH_win64
#import "UXWin32Driver.xc"
#elif ARCH_x86_64 || UX_POSTED_GTK
#import "UXGtkDriver.xc"
#else
#import "UXAppKitDriver.xc"
#endif
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"

#define POSTED_N 300
#define POSTED_BURST 50

UXApplication* gPostedApp;
u32 gUiThread;
i32 gNext;        // the next sequence number the UI thread expects
i32 gOutOfOrder;
i32 gOffThread;
bool gQueueRan;
bool gTimerRan;

void postedReport(void)
    {
    Stdio.printf("posted: %d of %d ran, %d out of order, %d off the UI thread, queue %d, timer %d\n", gNext,
                 (i32)POSTED_N, gOutOfOrder, gOffThread, (i32)gQueueRan, (i32)gTimerRan);
    bool ok = gNext == (i32)POSTED_N && gOutOfOrder == (i32)0 && gOffThread == (i32)0 && gQueueRan && gTimerRan;
    if (ok)
        {
        Stdio.printf("PASS: a worker's posts run on the idle UI thread, in order\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }

void postedCheck(i32 seq)
    {
    if (Thread.currentId() != gUiThread)
        {
        gOffThread = gOffThread + (i32)1;
        }
    if (seq != gNext)
        {
        gOutOfOrder = gOutOfOrder + (i32)1;
        }
    gNext = seq + (i32)1;
    if (gNext == (i32)POSTED_N)
        {
#if PLATFORM_ios || PLATFORM_android
        postedReport();
#endif
        gPostedApp.stop();
        }
    }

void postedWorker(void)
    {
    Thread.sleepMs((u32)300); // the UI loop is asleep by now
    OperationQueue.main().addBlock(block void(void) { gQueueRan = Thread.currentId() == gUiThread; });
    for (i32 i = (i32)0; i < (i32)POSTED_N; i = i + (i32)1)
        {
        i32 seq = i;
        RunLoop.main().post(block void(void) { postedCheck(seq); });
        if (i % (i32)POSTED_BURST == (i32)POSTED_BURST - (i32)1)
            {
            Thread.sleepMs((u32)40); // idle again between bursts
            }
        }
    }

class PostedDelegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        gUiThread = Thread.currentId(); // on Android, main() runs on another thread
        UXWindow* win = new UXWindow();
        win.open((u8*)"Posted", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)120), new UXView());
        app.addWindow(win);
        RunLoop.main().after((u32)100, block void(void) { gTimerRan = Thread.currentId() == gUiThread; });
#if PLATFORM_ios
        ux_ios_test_watchdog((i32)15000, (i32)2);
#elif PLATFORM_android
        ux_and_test_watchdog((i32)15000, (i32)2);
#endif
        Thread* t = Thread.spawn(&postedWorker);
        t.detach();
        return (i32)0;
        }
    }

void main(void)
    {
#if PLATFORM_ios
    gDriver = new UXIosDriver();
#elif PLATFORM_android
    gDriver = new UXAndroidDriver();
#elif ARCH_win64
    gDriver = new UXWin32Driver();
#elif ARCH_x86_64 || UX_POSTED_GTK
    gDriver = new UXGtkDriver();
#else
    gDriver = new UXAppKitDriver();
#endif
    gPostedApp = new UXApplication();
    gPostedApp.setDelegate(new PostedDelegate());
    gPostedApp.run();
    postedReport();
    }
