// test_win32_sound.xc — sound on Win32: the client's sounds, rendered by UXSound and played through
// one waveOut stream each.  Checked: each starts, two overlap (both streams playing), and both
// finish and are closed.  Under Wine, whose waveOut reaches the Mac's CoreAudio.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXSound.xc"

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
    gDriver = new UXWin32Driver();
    UXSound* update = new UXSound();
    update.note((i32)UXSND_SINE, 180.0, 0.5, 0.09, 120.0, 0.0);
    update.note((i32)UXSND_SINE, 270.0, 0.45, 0.05, 0.0, 0.06);
    UXSound* fight = new UXSound();
    fight.boom(0.16, 0.0);
    ck(update.play(), "update() plays", (i32)0);
    ck(fight.play(), "fight() plays over it", (i32)0);
    Sleep((u32)100);
    ck(w32_sound_prune() == (i32)2, "both streams are playing at once", w32_sound_prune());
    Sleep((u32)1200);
    ck(w32_sound_prune() == (i32)0, "and both have finished and been closed", w32_sound_prune());
    Stdio.printf(gFails == 0 ? "PASS: sound on Win32 -- UXSound through waveOut, overlapping\n" : "FAIL: %d\n", gFails);
    }
