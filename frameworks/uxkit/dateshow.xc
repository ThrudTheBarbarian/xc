// dateshow.xc — UXDate timezones, printed against the real wall clock.
//
// A hand-run demo rather than a test: it prints, it does not assert.  Built for WIN64, not
// arm64, because it takes the clock through UXWin32Driver — the seam under UXDate.currentDate —
// so it needs that backend's libraries:
//     xcc -A win64 -I . -o /tmp/dateshow.exe dateshow.xc && wine /tmp/dateshow.exe
// Covers the half-hour and quarter-hour zones (IST +05:30, Chatham +12:45) that catch an
// implementation assuming whole-hour offsets.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXDate.xc"

void show(u8* label, UXDate* d)
    {
    UXDateFormatter* f = UXDateFormatter.withPattern((u8*)"EEE d MMM yyyy HH:mm:ss");
    Stdio.printf("%s | %s %s\n", label, f.format(d), d.zone.offsetString());
    }
void main(void)
    {
    UXWin32Driver* drv = new UXWin32Driver();
    gDriver = drv;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);

    UXDate* utc = UXDate.currentDate();
    show((u8*)"now (UTC)", utc);
    show((u8*)"now (system zone)", UXDate.currentDateLocal());
    show((u8*)"...in Tokyo", utc.inZone(UXTimeZone.named((u8*)"JST")));
    show((u8*)"...in India", utc.inZone(UXTimeZone.named((u8*)"IST_IN")));
    show((u8*)"...in Los Angeles", utc.inZone(UXTimeZone.named((u8*)"PDT")));
    show((u8*)"...in Chatham Is.", utc.inZone(UXTimeZone.named((u8*)"CHAST")));

    Stdio.printf("\n");
    UXDate* jan31 = UXDate.makeTime((i32)2024, (i32)1, (i32)31, (i32)9, (i32)0, (i32)0);
    show((u8*)"31 Jan 2024 09:00", jan31);
    show((u8*)"  + 1 month", jan31.addingMonths((i32)1));
    show((u8*)"  + 1 year", jan31.addingYears((i32)1));
    show((u8*)"  + 100 days", jan31.addingDays((i32)100));
    UXDate* late = UXDate.makeTime((i32)2026, (i32)12, (i32)31, (i32)23, (i32)30, (i32)0);
    show((u8*)"31 Dec 2026 23:30", late);
    show((u8*)"  + 90 minutes", late.addingMinutes((i32)90));
    }
