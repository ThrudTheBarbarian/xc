// test_mac_sound.xc — sound on AppKit: the client's sounds, rendered by UXSound and played through
// NSSound.  Checked: each one starts, two overlap (both playing at once), and they finish.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXSound.xc"

extern i32 ux_ak_audio_playing(void);
extern void ux_ak_run_for(i32 ms);
i32 gFails = 0;
void ck(bool ok, u8* what, i32 v)
    {
    Stdio.printf("  %s %s (%d)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, v);
    if (!ok)
        {
        gFails = gFails + 1;
        }
    }
void main(void)
    {
    gDriver = new UXAppKitDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXSound* update = new UXSound();
    update.note((i32)UXSND_SINE, 180.0, 0.5, 0.09, 120.0, 0.0);
    update.note((i32)UXSND_SINE, 270.0, 0.45, 0.05, 0.0, 0.06);
    UXSound* fight = new UXSound();
    fight.boom(0.16, 0.0);
    ck(update.play(), "update() plays", (i32)0);
    ck(fight.play(), "fight() plays over it", (i32)0);
    ux_ak_run_for((i32)100);
    ck(ux_ak_audio_playing() == (i32)2, "both are playing at once", ux_ak_audio_playing());
    ux_ak_run_for((i32)900);
    ck(ux_ak_audio_playing() == (i32)0, "and both have finished a second later", ux_ak_audio_playing());
    Stdio.printf(gFails == 0 ? "PASS: sound on AppKit -- UXSound through NSSound, overlapping\n" : "FAIL: %d\n", gFails);
    }
