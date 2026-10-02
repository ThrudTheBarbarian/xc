// test_web_sound.xc — sound on the web: the client's sounds rendered by UXSound and handed to the
// page.  Under the node rig the recorded hand-over is checked (length, rate, loudness); in real
// headless Chrome (run_web_sound.sh) the page counts the AudioBuffer sources that started, and with
// the browser's default autoplay policy -- no click yet -- play() must say it did not play.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXSound.xc"

extern i32 ux_test_audio(i32 k, i32 what);
extern void ux_test_sound_done(i32 played);
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
    gDriver = new UXWebDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXSound* wire = new UXSound();
    wire.note((i32)UXSND_SINE, 880.0, 0.10, 0.07, 0.0, 0.0);
    wire.note((i32)UXSND_SINE, 1170.0, 0.14, 0.06, 0.0, 0.09);
    UXSound* fight = new UXSound();
    fight.boom(0.16, 0.0);
    i32 played = (i32)0;
    if (wire.play()) { played = played + (i32)1; }
    if (fight.play()) { played = played + (i32)1; }
    i32 n = ux_test_audio((i32)-1, (i32)0);
    if (n >= (i32)0)
        {
        // the node rig: what was handed over
        ck(played == (i32)2 && n == (i32)2, "both sounds were handed to the page", n);
        ck(ux_test_audio((i32)0, (i32)0) == wire.frameCount() && ux_test_audio((i32)0, (i32)1) == (i32)UXSND_RATE,
           "wire: its frames at 44.1 kHz", ux_test_audio((i32)0, (i32)0));
        ck(ux_test_audio((i32)1, (i32)2) > (i32)300, "fight: the boom is audible", ux_test_audio((i32)1, (i32)2));
        Stdio.printf(gFails == 0 ? "PASS: sound on the web (node rig) -- the samples reach the page\n" : "FAIL: %d\n", gFails);
        }
    ux_test_sound_done(played);
    }
