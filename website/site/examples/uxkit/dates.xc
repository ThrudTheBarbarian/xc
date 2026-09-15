// dates.xc — UXDate, UXTimeZone, UXDateFormatter and UXNumberFormatter.
//
// Every value here is fixed rather than read from the clock, so the output is
// the same on every run and on every backend — which is also the point of the
// integer civil-calendar algorithm underneath: no floating point anywhere.
#import <Stdio.xc>
#import "UXDate.xc"
#import "UXNumberFormatter.xc"

void show(u8* label, u8* pattern, UXDate* d) {
    UXDateFormatter* f = UXDateFormatter.withPattern(pattern);
    Stdio.printf("%s %s\n", label, f.format(d));
}

void main(void) {
    // ---- components in, string out ---------------------------------------
    UXDate* d = UXDate.makeTime((i32)2026, (i32)9, (i32)14,
                                (i32)16, (i32)45, (i32)7);

    show((u8*)"iso:      ", (u8*)"yyyy-MM-dd", d);
    show((u8*)"time:     ", (u8*)"HH:mm:ss", d);
    show((u8*)"long:     ", (u8*)"EEEE d MMMM yyyy", d);
    show((u8*)"short:    ", (u8*)"EEE d MMM yy", d);
    show((u8*)"single:   ", (u8*)"d/M/yyyy H:m", d);

    // A run of the same letter is one field, and its LENGTH picks the form.
    show((u8*)"M widths: ", (u8*)"M MM MMM MMMM", d);
    show((u8*)"E widths: ", (u8*)"E EEEE", d);

    // ---- date arithmetic --------------------------------------------------
    Stdio.printf("weekday index: %d\n", d.weekday());
    show((u8*)"+1 day:   ", (u8*)"EEE yyyy-MM-dd", d.addingDays((i32)1));
    show((u8*)"+3 weeks: ", (u8*)"EEE yyyy-MM-dd", d.addingWeeks((i32)3));
    show((u8*)"+5 months:", (u8*)"yyyy-MM-dd", d.addingMonths((i32)5));

    // Month arithmetic clamps rather than overflowing into the next month.
    UXDate* jan31 = UXDate.make((i32)2026, (i32)1, (i32)31);
    show((u8*)"31 Jan +1m:", (u8*)"yyyy-MM-dd", jan31.addingMonths((i32)1));

    // Leap years are exact, across all three rules.
    Stdio.printf("leap: 2024=%d 2025=%d 1900=%d 2000=%d\n",
                 UXDate.isLeapYear((i32)2024) ? 1 : 0,
                 UXDate.isLeapYear((i32)2025) ? 1 : 0,
                 UXDate.isLeapYear((i32)1900) ? 1 : 0,
                 UXDate.isLeapYear((i32)2000) ? 1 : 0);
    show((u8*)"29 Feb 24:", (u8*)"EEEE d MMMM yyyy",
         UXDate.make((i32)2024, (i32)2, (i32)28).addingDays((i32)1));
    show((u8*)"28 Feb 25:", (u8*)"EEEE d MMMM yyyy",
         UXDate.make((i32)2025, (i32)2, (i32)28).addingDays((i32)1));

    // Differences are in days, and work across a year boundary.
    Stdio.printf("days 2026-01-01 -> 2026-09-14: %d\n",
                 UXDate.make((i32)2026, (i32)1, (i32)1).daysUntil(d));

    // ---- time zones -------------------------------------------------------
    UXTimeZone* utc  = UXTimeZone.utc();
    UXTimeZone* ist  = UXTimeZone.make((u8*)"IST", (i32)330);    // +05:30
    UXTimeZone* pst  = UXTimeZone.make((u8*)"PST", -(i32)480);   // -08:00

    Stdio.printf("offsets: %s %s %s\n",
                 utc.offsetString(), ist.offsetString(), pst.offsetString());

    // A date's components are EXPRESSED IN its zone; inZone() re-expresses the
    // same instant, so the wall-clock reading changes and the instant does not.
    UXDate* here  = UXDate.makeTime((i32)2026, (i32)9, (i32)14, (i32)16, (i32)45, (i32)0);
    UXDate* there = here.inZone(pst);
    show((u8*)"utc:      ", (u8*)"yyyy-MM-dd HH:mm", here);
    show((u8*)"in PST:   ", (u8*)"yyyy-MM-dd HH:mm", there);
    Stdio.printf("same instant: %d\n", here.isSameInstant(there) ? 1 : 0);

    // An unknown zone name is null, so it can be told apart from UTC.
    Stdio.printf("named(UTC)=%d named(Mars)=%d known zones=%d\n",
                 UXTimeZone.named((u8*)"UTC") == (UXTimeZone*)0 ? 0 : 1,
                 UXTimeZone.named((u8*)"Mars") == (UXTimeZone*)0 ? 0 : 1,
                 UXTimeZone.knownCount());

    // ---- numbers ----------------------------------------------------------
    // Grouping is ON by default, so turning it OFF is the deliberate act.
    UXNumberFormatter* plain = new UXNumberFormatter();
    plain.setGrouping(false);
    UXNumberFormatter* dec   = UXNumberFormatter.decimal();
    UXNumberFormatter* money = UXNumberFormatter.currency((u8*)"$");

    Stdio.printf("ungrouped: %s   default: %s\n",
                 plain.format((i32)1234567), dec.format((i32)1234567));

    // Fixed point is a SCALED INTEGER plus a decimal count: pass cents, not
    // dollars, and the result is exact with no float in sight.
    Stdio.printf("money: %s   negative: %s\n",
                 money.formatFixed((i32)129900, (i32)2),
                 money.formatFixed(-(i32)129900, (i32)2));

    // Grouping and separators are settable, which is as far as locale goes.
    UXNumberFormatter* euro = UXNumberFormatter.currency((u8*)"EUR ");
    euro.setGroupSeparator((u8)'.');
    euro.setDecimalSeparator((u8)',');
    Stdio.printf("euro:  %s\n", euro.formatFixed((i32)129900, (i32)2));

    UXNumberFormatter* pc = new UXNumberFormatter();
    pc.setSuffix((u8*)"%");
    Stdio.printf("pct:   %s   one dp: %s\n",
                 pc.format((i32)42), pc.formatFixed((i32)425, (i32)1));

    // Small values still pad to the requested decimals.
    Stdio.printf("edges: %s %s %s\n",
                 dec.format((i32)0), dec.format((i32)999),
                 plain.formatFixed((i32)5, (i32)2));
}
