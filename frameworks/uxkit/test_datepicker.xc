// test_datepicker.xc — UXDatePicker year/month/day stepping with correct rollover + clamping.
#import <Stdio.xc>
#import "UXDatePicker.xc"
#import "UXDate.xc"

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

void main(void)
    {
    gFails = (i32)0;
    UXDatePicker* dp = new UXDatePicker();

    // day rollover across a month boundary
    dp.setDate(UXDate.make((i32)2026, (i32)1, (i32)31));
    dp.stepDay((i32)1);
    check("Jan 31 + 1 day -> Feb", dp.month(), (i32)2);
    check("...day 1", dp.day(), (i32)1);
    dp.stepDay((i32)-1);
    check("back to Jan", dp.month(), (i32)1);
    check("...day 31", dp.day(), (i32)31);

    // month step with day clamping: Jan 31 + 1 month -> Feb 28 (2026 not leap)
    dp.setDate(UXDate.make((i32)2026, (i32)1, (i32)31));
    dp.stepMonth((i32)1);
    check("Jan 31 +1 month -> Feb", dp.month(), (i32)2);
    check("...clamped to 28", dp.day(), (i32)28);

    // month step into a leap February keeps 29 available
    dp.setDate(UXDate.make((i32)2024, (i32)1, (i32)31));
    dp.stepMonth((i32)1);
    check("2024 Jan 31 +1 month -> Feb 29 (leap)", dp.day(), (i32)29);

    // month rollover across the year
    dp.setDate(UXDate.make((i32)2026, (i32)11, (i32)15));
    dp.stepMonth((i32)3);
    check("Nov +3 -> Feb", dp.month(), (i32)2);
    check("...year advanced", dp.year(), (i32)2027);
    dp.stepMonth((i32)-4);
    check("Feb -4 -> Oct", dp.month(), (i32)10);
    check("...year back", dp.year(), (i32)2026);

    // year step with Feb-29 clamping
    dp.setDate(UXDate.make((i32)2024, (i32)2, (i32)29));
    dp.stepYear((i32)1);
    check("2024-02-29 +1yr -> 2025", dp.year(), (i32)2025);
    check("...Feb 29 clamps to 28", dp.day(), (i32)28);
    dp.setDate(UXDate.make((i32)2024, (i32)2, (i32)29));
    dp.stepYear((i32)4);
    check("2024-02-29 +4yr -> 2028 (leap)", dp.year(), (i32)2028);
    check("...29 stays", dp.day(), (i32)29);

    // plain year step keeps the day
    dp.setDate(UXDate.make((i32)2026, (i32)6, (i32)15));
    dp.stepYear((i32)-10);
    check("year -10", dp.year(), (i32)2016);
    check("...month unchanged", dp.month(), (i32)6);
    check("...day unchanged", dp.day(), (i32)15);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXDatePicker — day/month/year stepping, rollover, day + leap clamping.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
