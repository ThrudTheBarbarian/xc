// test_gtk_sound.xc — sound on GTK (Linux): UXSound through PulseAudio's simple API, loaded at run
// time.  With a sound server: two sounds start, overlap and finish.  With none (a headless host):
// play() answers false and nothing crashes -- the honest answer, not a silent pretence.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXSound.xc"

extern i32 ux_gtk_audio_playing(void);
i32 usleep(u32 us);
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
    gDriver = new UXGtkDriver();
    UXSound* update = new UXSound();
    update.note((i32)UXSND_SINE, 180.0, 0.5, 0.09, 120.0, 0.0);
    UXSound* fight = new UXSound();
    fight.boom(0.16, 0.0);
    bool a = update.play();
    bool b = fight.play();
    if (!a && !b)
        {
        ck(ux_gtk_audio_playing() == (i32)0, "no sound server: play() says false, nothing is left playing", (i32)0);
        Stdio.printf(gFails == 0 ? "PASS: sound on GTK -- no sound server here, and play() says so\n" : "FAIL: %d\n", gFails);
        return;
        }
    ck(a && b, "both sounds started", (a ? (i32)1 : (i32)0) + (b ? (i32)1 : (i32)0));
    usleep((u32)100000);
    ck(ux_gtk_audio_playing() == (i32)2, "both are playing at once", ux_gtk_audio_playing());
    usleep((u32)1500000);
    ck(ux_gtk_audio_playing() == (i32)0, "and both have finished", ux_gtk_audio_playing());
    Stdio.printf(gFails == 0 ? "PASS: sound on GTK -- UXSound through PulseAudio, overlapping\n" : "FAIL: %d\n", gFails);
    }
