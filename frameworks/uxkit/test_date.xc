// test_date.xc — UXDate civil-calendar math + UXDateFormatter patterns.
#import <Stdio.xc>
#import "UXDate.xc"

i32 gFails;
void checkStr(u8* what, u8* got, u8* want)
    {
    if (streq(got, want))
        {
        Stdio.printf("  ok   %s = \"%s\"\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }
void check(u8* what, i32 got, i32 want)
    {
    // %d on an i32, not (i16): microseconds do not fit 16 bits and printed as nonsense while the
    // comparison itself was fine — a display that lies about a passing test is worse than useless.
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
bool streq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && b[i] != (u8)0)
        {
        if (a[i] != b[i])
            {
            return false;
            }
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
void eq(u8* what, u8* got, u8* want)
    {
    if (streq(got, want))
        {
        Stdio.printf("  ok   %s = \"%s\"\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

// Split in two: every UXDate* here is a frame temporary, and arm64 gives a function 16KB.
void testArithmetic(void)
    {
    // ---- arithmetic: every unit, and the cases that catch a naive implementation ---------------
    UXDate* base = UXDate.makeMicro((i32)2024, (i32)1, (i32)31, (i32)23, (i32)30, (i32)45, (i32)900000);

    // MONTHS CLAMP.  31 Jan + 1 month is 29 Feb in a leap year (28 otherwise) — never 2 or 3 March.
    UXDate* m1 = base.addingMonths((i32)1);
    check("31 Jan +1mo -> month", m1.month, (i32)2);
    check("31 Jan +1mo -> day (leap)", m1.day, (i32)29);
    check("...time carried", m1.hour, (i32)23);
    check("...micros carried", m1.micro, (i32)900000);
    check("31 Jan 2023 +1mo -> 28 Feb", UXDate.make((i32)2023, (i32)1, (i32)31).addingMonths((i32)1).day, (i32)28);
    check("+12 months == +1 year", base.addingMonths((i32)12).year, base.addingYears((i32)1).year);
    check("31 Jan -1mo -> Dec", base.addingMonths((i32)-1).month, (i32)12);
    check("31 Jan -1mo -> year", base.addingMonths((i32)-1).year, (i32)2023);
    check("29 Feb +1yr clamps to 28", UXDate.make((i32)2024, (i32)2, (i32)29).addingYears((i32)1).day, (i32)28);
    }

void testCarries(void)
    {
    UXDate* base = UXDate.makeMicro((i32)2024, (i32)1, (i32)31, (i32)23, (i32)30, (i32)45, (i32)900000);
    // TIME CARRIES INTO THE DATE.
    UXDate* h1 = base.addingHours((i32)1); // 23:30 -> 00:30 next day
    check("+1h rolls the day", h1.day, (i32)1);
    check("+1h rolls the month", h1.month, (i32)2);
    check("+1h hour", h1.hour, (i32)0);
    check("+90min minute", base.addingMinutes((i32)90).minute, (i32)0);
    check("+90min hour", base.addingMinutes((i32)90).hour, (i32)1);
    check("-24h goes back a day", base.addingHours((i32)-24).day, (i32)30);
    check("+15s seconds", base.addingSeconds((i32)15).second, (i32)0);
    check("+15s minute", base.addingSeconds((i32)15).minute, (i32)31);

    // MICROSECONDS carry into seconds, and negative amounts borrow.
    UXDate* u1 = base.addingMicroseconds((i32)200000); // .900000 + .200000 -> next second .100000
    check("+200000us micro", u1.micro, (i32)100000);
    check("+200000us second", u1.second, (i32)46);
    UXDate* u2 = base.addingMicroseconds((i32)-900001);
    check("-900001us borrows", u2.micro, (i32)999999);
    check("-900001us second", u2.second, (i32)44);

    // Round trips, so the units agree with each other.
    check("+1mo -1mo is the same month", base.addingMonths((i32)1).addingMonths((i32)-1).month, (i32)1);
    check("+7d == +1wk", base.addingDays((i32)7).dayNumber(), base.addingWeeks((i32)1).dayNumber());
    check("+3600s == +1h", base.addingSeconds((i32)3600).dayNumber(), base.addingHours((i32)1).dayNumber());
    check("daysInMonth Feb 2024", UXDate.daysInMonth((i32)2024, (i32)2), (i32)29);
    check("daysInMonth Feb 2100", UXDate.daysInMonth((i32)2100, (i32)2), (i32)28);
    check("daysInMonth Apr", UXDate.daysInMonth((i32)2024, (i32)4), (i32)30);

    // NOTHING MUTATES: base must be untouched after all of that.
    check("base year unchanged", base.year, (i32)2024);
    check("base day unchanged", base.day, (i32)31);
    check("base micro unchanged", base.micro, (i32)900000);

    // currentDate with no driver answers the epoch rather than inventing a time.
    UXDate* nod = UXDate.currentDate();
    check("no driver -> epoch year", nod.year, (i32)1970);
    }

// Zones.  The distinction that matters: setZone RELABELS, inZone CONVERTS.
void testZones(void)
    {
    UXDate* utcNoon = UXDate.makeTime((i32)2026, (i32)7, (i32)28, (i32)12, (i32)0, (i32)0);
    check("default zone is UTC", utcNoon.zoneOffsetMinutes(), (i32)0);

    // A known zone by name, including the half- and quarter-hour ones a "just use hours" API breaks on.
    UXTimeZone* cet = UXTimeZone.named((u8*)"CET");
    check("CET is +60", cet.offsetMinutes, (i32)60);
    check("IST_IN is +330", UXTimeZone.named((u8*)"IST_IN").offsetMinutes, (i32)330);
    check("NPT is +345", UXTimeZone.named((u8*)"NPT").offsetMinutes, (i32)345);
    check("CHAST is +765", UXTimeZone.named((u8*)"CHAST").offsetMinutes, (i32)765);
    check("PST is -480", UXTimeZone.named((u8*)"PST").offsetMinutes, (i32)-480);
    check("an unknown zone is nil, not UTC",
          UXTimeZone.named((u8*)"Nowhere/Nothing") == (UXTimeZone*)0 ? (i32)1 : (i32)0, (i32)1);
    check("the table is enumerable", UXTimeZone.knownCount() > (i32)0 ? (i32)1 : (i32)0, (i32)1);

    // CONVERT: same instant, different clock face.
    UXDate* inCet = utcNoon.inZone(cet);
    check("12:00Z is 13:00 CET", inCet.hour, (i32)13);
    check("...same day", inCet.day, (i32)28);
    check("...and the SAME INSTANT", inCet.isSameInstant(utcNoon) ? (i32)1 : (i32)0, (i32)1);
    check("...carrying its zone", inCet.zoneOffsetMinutes(), (i32)60);

    // Across the date line, and backwards over midnight.
    UXDate* inNz = utcNoon.inZone(UXTimeZone.named((u8*)"NZST"));
    check("12:00Z is next day in NZ", inNz.day, (i32)29);
    check("...at midnight", inNz.hour, (i32)0);
    UXDate* inPst = UXDate.makeTime((i32)2026, (i32)7, (i32)28, (i32)3, (i32)0, (i32)0).inZone(UXTimeZone.named((u8*)"PST"));
    check("03:00Z is the previous day in PST", inPst.day, (i32)27);
    check("...at 19:00", inPst.hour, (i32)19);

    // Half-hour zones must not lose the half.
    UXDate* inIndia = utcNoon.inZone(UXTimeZone.named((u8*)"IST_IN"));
    check("12:00Z is 17:30 in India", inIndia.hour, (i32)17);
    check("...and 30 minutes", inIndia.minute, (i32)30);

    // RELABEL: setZone changes what the clock face MEANS, so the instant moves.
    UXDate* relabelled = UXDate.makeTime((i32)2026, (i32)7, (i32)28, (i32)12, (i32)0, (i32)0);
    relabelled.setZone(cet);
    check("setZone keeps the clock face", relabelled.hour, (i32)12);
    check("...so it is NOT the same instant", relabelled.isSameInstant(utcNoon) ? (i32)1 : (i32)0, (i32)0);
    check("...it is an hour earlier", utcNoon.epochSeconds() - relabelled.epochSeconds(), (i32)3600);

    // A round trip returns the original clock face.
    check("UTC -> CET -> UTC hour", inCet.inZone(UXTimeZone.utc()).hour, (i32)12);
    // Arithmetic stays in the zone it started in.
    check("+1h in CET stays CET", inCet.addingHours((i32)1).zoneOffsetMinutes(), (i32)60);
    check("+1mo in CET stays CET", inCet.addingMonths((i32)1).zoneOffsetMinutes(), (i32)60);
    // Offsets print the way a log wants them.
    checkStr("UTC prints Z", UXTimeZone.utc().offsetString(), (u8*)"Z");
    checkStr("CET prints +01:00", cet.offsetString(), (u8*)"+01:00");
    checkStr("India prints +05:30", UXTimeZone.named((u8*)"IST_IN").offsetString(), (u8*)"+05:30");
    checkStr("PST prints -08:00", UXTimeZone.named((u8*)"PST").offsetString(), (u8*)"-08:00");
    }

void main(void)
    {
    gFails = (i32)0;

    // day-number anchor: 1970-01-01 is day 0
    check("epoch day number", UXDate.make((i32)1970, (i32)1, (i32)1).dayNumber(), (i32)0);
    check("2000-01-01 day number", UXDate.make((i32)2000, (i32)1, (i32)1).dayNumber(), (i32)10957);
    check("day before epoch", UXDate.make((i32)1969, (i32)12, (i32)31).dayNumber(), (i32)-1);

    // round-trip through the day number (no magic constant — compute it, then invert)
    i32 dn = UXDate.make((i32)2025, (i32)7, (i32)25).dayNumber();
    UXDate* d = UXDate.fromDayNumber(dn);
    check("roundtrip year", d.year, (i32)2025);
    check("roundtrip month", d.month, (i32)7);
    check("roundtrip day", d.day, (i32)25);

    // weekday: 2026-07-25 is a Saturday (=6), 1970-01-01 was a Thursday (=4)
    check("epoch weekday Thursday", UXDate.make((i32)1970, (i32)1, (i32)1).weekday(), (i32)4);
    check("2026-07-25 weekday Saturday", UXDate.make((i32)2026, (i32)7, (i32)25).weekday(), (i32)6);

    // leap-year handling: 2024-02-29 exists; adding one day gives March 1
    UXDate* leap = UXDate.make((i32)2024, (i32)2, (i32)29);
    UXDate* next = leap.addingDays((i32)1);
    check("Feb 29 + 1 -> March", next.month, (i32)3);
    check("Feb 29 + 1 -> day 1", next.day, (i32)1);
    check("2024 is leap", UXDate.isLeapYear((i32)2024) ? (i32)1 : (i32)0, (i32)1);
    check("1900 not leap", UXDate.isLeapYear((i32)1900) ? (i32)1 : (i32)0, (i32)0);
    check("2000 is leap", UXDate.isLeapYear((i32)2000) ? (i32)1 : (i32)0, (i32)1);

    // days between
    check("days in Jan 2026", UXDate.make((i32)2026, (i32)1, (i32)1).daysUntil(UXDate.make((i32)2026, (i32)2, (i32)1)), (i32)31);

    // formatting
    UXDate* dt = UXDate.makeTime((i32)2026, (i32)7, (i32)25, (i32)9, (i32)5, (i32)3);
    eq("ISO", UXDateFormatter.withPattern((u8*)"yyyy-MM-dd").format(dt), (u8*)"2026-07-25");
    eq("time HH:mm:ss", UXDateFormatter.withPattern((u8*)"HH:mm:ss").format(dt), (u8*)"09:05:03");
    eq("long", UXDateFormatter.withPattern((u8*)"EEEE d MMMM yyyy").format(dt), (u8*)"Saturday 25 July 2026");
    eq("abbrev", UXDateFormatter.withPattern((u8*)"EEE, MMM d").format(dt), (u8*)"Sat, Jul 25");
    eq("two-digit year", UXDateFormatter.withPattern((u8*)"MM/dd/yy").format(dt), (u8*)"07/25/26");
    eq("single-digit fields", UXDateFormatter.withPattern((u8*)"M/d").format(UXDate.make((i32)2026, (i32)3, (i32)5)), (u8*)"3/5");
    eq("literal text passes through", UXDateFormatter.withPattern((u8*)"yyyy 'at' HH:mm").format(dt), (u8*)"2026 'at' 09:05");

    testArithmetic();
    testZones();
    testCarries();

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXDate — civil day-number math, weekday, leap years, arithmetic, pattern formatting.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
