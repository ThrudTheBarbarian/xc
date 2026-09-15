// spike.xc — the xtc half of the run-loop spike (Option B + A).  main() is one
// call deep: register the callbacks, enter the shell — which is what
// UXApplication.run()'s iOS inside will be.  Everything below runs ON the
// main thread, driven by UIKit: started from didFinishLaunching, ticked by
// the display link, dispatched a LOGICAL ID by a real target-action.
#import <Stdio.xc>

extern void ux_ios_shell_run(void);
extern void ux_ios_set_start(pointer fn);
extern void ux_ios_set_tick(pointer fn);
extern void ux_ios_set_action(pointer fn);
extern void ux_ios_set_label(u8* s);
extern void ux_ios_quit(i32 rc);

i32 gTaps;
i32 gTicks;

void onStart(void)
    {
    Stdio.printf("spike: applicationDidStart moment, from didFinishLaunching\n");
    }
// the sec-3.2 heartbeat
void onTick(void)
    {
    gTicks = gTicks + (i32)1;
    }
void onAction(i32 logicalId)
    {
    // L2 = the Play button
    if (logicalId != (i32)2)
        {
        return;
        }
    gTaps = gTaps + (i32)1;
    Stdio.printf("spike: action L2 -> onPlay, tap %d (ticks so far %d)\n", (i16)gTaps, (i16)gTicks);
    if (gTaps == (i32)1)
        {
        ux_ios_set_label((u8*)"tap 1");
        }
    else if (gTaps == (i32)2)
        {
        ux_ios_set_label((u8*)"tap 2");
        }
    else
        {
        ux_ios_set_label((u8*)"tap 3");
        if (gTicks > (i32)0)
            {
            Stdio.printf("PASS: UIKit-owned loop, delegate start, logical-id actions, display-link heartbeat\n");
            ux_ios_quit((i32)0);
            }
        else
            {
            Stdio.printf("FAIL: no heartbeat ticks\n");
            ux_ios_quit((i32)1);
            }
        }
    }

void main(void)
    {
    gTaps = (i32)0;
    gTicks = (i32)0;
    ux_ios_set_start((pointer)&onStart);
    ux_ios_set_tick((pointer)&onTick);
    ux_ios_set_action((pointer)&onAction);
    ux_ios_shell_run(); // UIApplicationMain — never returns
    }
