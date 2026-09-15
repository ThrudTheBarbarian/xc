// test_win32_date.xc — UXDate.currentDate against a real driver clock.
//
// test_date covers the arithmetic, which is pure integer maths and needs no backend.  This covers
// the one place UXDate reaches outside itself: the driver's wall clock (nowUTC), delivered as UTC
// civil components.  Win32 under Wine because it runs headlessly; the seam is the same on all three.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXDate.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }
void checkRange(u8* what, i32 got, i32 lo, i32 hi)
    {
    if (got >= lo && got <= hi)
        {
        Stdio.printf("  ok   %s = %d\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d..%d)\n", what, got, lo, hi);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    UXWin32Driver* drv = new UXWin32Driver();
    gDriver = drv;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);

    UXDate* now = UXDate.currentDate();
    // Not asserting an exact date — asserting it is a real one.  A driver that answered nothing, or
    // wrote its components in the wrong order, fails every one of these.
    checkRange("year is plausible", now.year, (i32)2024, (i32)2100);
    checkRange("month in range", now.month, (i32)1, (i32)12);
    checkRange("day in range", now.day, (i32)1, (i32)31);
    checkRange("hour in range", now.hour, (i32)0, (i32)23);
    checkRange("minute in range", now.minute, (i32)0, (i32)59);
    checkRange("second in range", now.second, (i32)0, (i32)59);
    checkRange("microsecond in range", now.micro, (i32)0, (i32)999999);
    check("day fits the month", now.day <= UXDate.daysInMonth(now.year, now.month) ? (i32)1 : (i32)0, (i32)1);

    // The clock MOVES, and forwards: two reads a moment apart must not go backwards.
    i32 first = now.epochSeconds();
    for (i32 spin = (i32)0; spin < (i32)2000000; spin = spin + (i32)1)
        {
        }
    UXDate* later = UXDate.currentDate();
    check("time does not run backwards", later.epochSeconds() >= first ? (i32)1 : (i32)0, (i32)1);

    // And the arithmetic composes with a real date: a year on is the same day-of-month (or clamped).
    UXDate* nextYear = now.addingYears((i32)1);
    check("+1 year moves the year", nextYear.year, now.year + (i32)1);
    check("+1 year keeps the month", nextYear.month, now.month);

    // The SYSTEM's zone: the one honest answer about DST, because the host applied the rules.
    UXTimeZone* sys = UXTimeZone.systemZone();
    checkRange("system offset is a real one", sys.offsetMinutes, (i32)-720, (i32)840);
    check("system offset lands on a quarter hour", sys.offsetMinutes % (i32)15, (i32)0);

    UXDate* local = UXDate.currentDateLocal();
    check("local time is the same instant as UTC",
          local.isSameInstant(UXDate.currentDate()) ? (i32)1 : (i32)0, (i32)1);
    check("local carries the system offset", local.zoneOffsetMinutes(), sys.offsetMinutes);
    checkRange("local hour is still an hour", local.hour, (i32)0, (i32)23);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: currentDate reads the driver clock\n");
        }
    else
        {
        Stdio.printf("FAIL: %d checks failed\n", gFails);
        }
    }
