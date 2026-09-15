// test_statemachine.xc — UXStateMachine transitions, guards, and wizard Back.
#import <Stdio.xc>
#import "UXStateMachine.xc"

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
i32 isIn(UXStateMachine* m, u8* s)
    {
    return m.isIn(s) ? (i32)1 : (i32)0;
    }

void main(void)
    {
    gFails = (i32)0;

    // a traffic light: red -go-> green -caution-> yellow -stop-> red
    UXStateMachine* light = new UXStateMachine();
    light.addTransition((u8*)"red", (u8*)"go", (u8*)"green");
    light.addTransition((u8*)"green", (u8*)"caution", (u8*)"yellow");
    light.addTransition((u8*)"yellow", (u8*)"stop", (u8*)"red");
    light.setInitial((u8*)"red");

    check("starts red", isIn(light, (u8*)"red"), (i32)1);
    check("can go from red", light.canFire((u8*)"go") ? (i32)1 : (i32)0, (i32)1);
    check("cannot stop from red", light.canFire((u8*)"stop") ? (i32)1 : (i32)0, (i32)0);

    check("go succeeds", light.fire((u8*)"go") ? (i32)1 : (i32)0, (i32)1);
    check("now green", isIn(light, (u8*)"green"), (i32)1);
    check("invalid event ignored", light.fire((u8*)"go") ? (i32)1 : (i32)0, (i32)0); // no 'go' from green
    check("still green after invalid", isIn(light, (u8*)"green"), (i32)1);
    light.fire((u8*)"caution");
    check("now yellow", isIn(light, (u8*)"yellow"), (i32)1);
    light.fire((u8*)"stop");
    check("back to red", isIn(light, (u8*)"red"), (i32)1);

    // a wizard with Back
    UXStateMachine* wiz = new UXStateMachine();
    wiz.addTransition((u8*)"welcome", (u8*)"next", (u8*)"details");
    wiz.addTransition((u8*)"details", (u8*)"next", (u8*)"confirm");
    wiz.addTransition((u8*)"confirm", (u8*)"next", (u8*)"done");
    wiz.setInitial((u8*)"welcome");

    check("no history at start", wiz.depth(), (i32)0);
    check("cannot go back at start", wiz.back() ? (i32)1 : (i32)0, (i32)0);
    wiz.fire((u8*)"next");
    wiz.fire((u8*)"next");
    check("at confirm", isIn(wiz, (u8*)"confirm"), (i32)1);
    check("history depth 2", wiz.depth(), (i32)2);

    check("back to details", wiz.back() ? (i32)1 : (i32)0, (i32)1);
    check("now details", isIn(wiz, (u8*)"details"), (i32)1);
    check("history depth 1", wiz.depth(), (i32)1);
    wiz.back();
    check("back to welcome", isIn(wiz, (u8*)"welcome"), (i32)1);
    check("no more history", wiz.depth(), (i32)0);

    // forward again after backing up
    wiz.fire((u8*)"next");
    check("forward again -> details", isIn(wiz, (u8*)"details"), (i32)1);
    wiz.fire((u8*)"next");
    wiz.fire((u8*)"next");
    check("reach done", isIn(wiz, (u8*)"done"), (i32)1);
    check("no transition from done", wiz.canFire((u8*)"next") ? (i32)1 : (i32)0, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXStateMachine — transitions, invalid-event no-op, wizard Back/forward.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
