// shell.m — the iOS half of the run-loop spike, aimed at the SETTLED model
// (Option B + A, 2026-08-26): UIKit owns the main thread's loop, full stop.
//
//   B — the abstract hijack: xtc's main() calls ux_ios_shell_run() at once,
//       which IS UIApplicationMain and never returns.  The neutral
//       applicationDidStart fires FROM didFinishLaunching, via a registered
//       xtc callback — run() stays one call in app code; its inside is this.
//   A — the subservient pump: a CADisplayLink ticks a registered xtc callback
//       every frame — the §3.2 invalidation-consolidation heartbeat, NOT an
//       input path.
//   Input: a real UIButton target-action carries a LOGICAL ID (UXNB v2's
//       currency) straight into an xtc dispatch callback, on the main thread,
//       no queue and no blocking anywhere.  "Our controller catches
//       member=onPlay without ever knowing a touch was involved."
//
// Headless: the main loop self-injects three taps; a 15s watchdog turns a
// wedge into rc 2.  PASS is printed by the xtc side once all three arrive
// and the display link has demonstrably ticked.
#import <UIKit/UIKit.h>

typedef void (*ux_fn0)(void);
typedef void (*ux_fn1)(int);
static ux_fn0 gStart, gTick;
static ux_fn1 gAction;
void ux_ios_set_start(void* fn)
    {
    gStart = (ux_fn0)fn;
    }
void ux_ios_set_tick(void* fn)
    {
    gTick = (ux_fn0)fn;
    }
void ux_ios_set_action(void* fn)
    {
    gAction = (ux_fn1)fn;
    }

static UILabel* gLabel;
// main-thread already (B): direct
void ux_ios_set_label(const char* s)
    {
    gLabel.text = [NSString stringWithUTF8String:s];
    }
void ux_ios_quit(int rc)
    {
    dispatch_async(dispatch_get_main_queue(), ^{
      exit(rc);
    });
    }

@interface SpikeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@property(nonatomic, strong) CADisplayLink* link;
@end
@implementation SpikeDelegate
- (void)frame:(CADisplayLink*)l
    {
    if (gTick)
        gTick();
    }
// logical id L2, not a coordinate
- (void)tapped:(UIButton*)b
    {
    if (gAction)
        gAction(2);
    }
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opts
    {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController* vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;
    gLabel = [[UILabel alloc] initWithFrame:CGRectMake(40, 120, 300, 40)];
    gLabel.text = @"waiting";
    UIButton* btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(40, 180, 300, 44);
    [btn setTitle:@"Play" forState:UIControlStateNormal];
    [btn addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:gLabel];
    [vc.view addSubview:btn];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    if (gStart)
        gStart(); // the neutral applicationDidStart moment

    for (int i = 1; i <= 3; i++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * 300 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(),
                       ^{
                         [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                       });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
                     exit(2);
                   });
    return YES;
    }
@end

// called from xtc main(); never returns
void ux_ios_shell_run(void)
    {
    char* argv[] = {(char*)"spike", NULL};
    @autoreleasepool
        {
        UIApplicationMain(1, argv, nil, @"SpikeDelegate");
        }
    }

// The console primitive the xtc Stdio machinery bottoms out in — supplied by
// the platform rt in a real build; one line here keeps the spike self-contained.
// _putc comes from the rt objects when clang-linking (the in-house xcc link needs it here instead)
