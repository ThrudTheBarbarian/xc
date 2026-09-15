// UXDate.xc — a civil date/time value + a pattern formatter (NSDate/NSDateFormatter in shape).
//
// UXDate holds broken-down components (year, month, day, hour, minute, second) and converts to and
// from a DAY NUMBER (days since 1970-01-01) using the exact integer civil-calendar algorithm — so
// date arithmetic (addDays) and the weekday are correct across all leap-year rules, on every backend,
// with no floating point.  UXDateFormatter turns a date into a string from a pattern (yyyy-MM-dd,
// "EEE d MMM yyyy", HH:mm:ss, …).
#import "Array.xc"
#import "UXViewDriver.xc"
#import "UXString.xc" // UXStr — offsetString builds "+05:30"      // gDriver.nowUTC — currentDate reads the wall clock through the seam

u8* gUXMonthFull[12];
u8* gUXMonthAbbr[12];
u8* gUXDayFull[7];
u8* gUXDayAbbr[7];
bool gUXDateNamesReady;

void xgDateInitNames(void)
    {
    if (gUXDateNamesReady)
        {
        return;
        }
    gUXMonthFull[0] = (u8*)"January";
    gUXMonthFull[1] = (u8*)"February";
    gUXMonthFull[2] = (u8*)"March";
    gUXMonthFull[3] = (u8*)"April";
    gUXMonthFull[4] = (u8*)"May";
    gUXMonthFull[5] = (u8*)"June";
    gUXMonthFull[6] = (u8*)"July";
    gUXMonthFull[7] = (u8*)"August";
    gUXMonthFull[8] = (u8*)"September";
    gUXMonthFull[9] = (u8*)"October";
    gUXMonthFull[10] = (u8*)"November";
    gUXMonthFull[11] = (u8*)"December";
    gUXMonthAbbr[0] = (u8*)"Jan";
    gUXMonthAbbr[1] = (u8*)"Feb";
    gUXMonthAbbr[2] = (u8*)"Mar";
    gUXMonthAbbr[3] = (u8*)"Apr";
    gUXMonthAbbr[4] = (u8*)"May";
    gUXMonthAbbr[5] = (u8*)"Jun";
    gUXMonthAbbr[6] = (u8*)"Jul";
    gUXMonthAbbr[7] = (u8*)"Aug";
    gUXMonthAbbr[8] = (u8*)"Sep";
    gUXMonthAbbr[9] = (u8*)"Oct";
    gUXMonthAbbr[10] = (u8*)"Nov";
    gUXMonthAbbr[11] = (u8*)"Dec";
    gUXDayFull[0] = (u8*)"Sunday";
    gUXDayFull[1] = (u8*)"Monday";
    gUXDayFull[2] = (u8*)"Tuesday";
    gUXDayFull[3] = (u8*)"Wednesday";
    gUXDayFull[4] = (u8*)"Thursday";
    gUXDayFull[5] = (u8*)"Friday";
    gUXDayFull[6] = (u8*)"Saturday";
    gUXDayAbbr[0] = (u8*)"Sun";
    gUXDayAbbr[1] = (u8*)"Mon";
    gUXDayAbbr[2] = (u8*)"Tue";
    gUXDayAbbr[3] = (u8*)"Wed";
    gUXDayAbbr[4] = (u8*)"Thu";
    gUXDayAbbr[5] = (u8*)"Fri";
    gUXDayAbbr[6] = (u8*)"Sat";
    gUXDateNamesReady = true;
    }

// The known zones: name -> offset, standard and summer listed separately because a fixed-offset zone
// cannot switch by itself.  Not a tz database and not pretending to be one.
#define UX_TZ_COUNT 24
u8* gUXTzName[UX_TZ_COUNT];
i32 gUXTzOff[UX_TZ_COUNT];
bool gUXTzReady;
void xgTzInit(void)
    {
    if (gUXTzReady)
        {
        return;
        }
    gUXTzName[0] = (u8*)"UTC";
    gUXTzOff[0] = (i32)0;
    gUXTzName[1] = (u8*)"GMT";
    gUXTzOff[1] = (i32)0;
    gUXTzName[2] = (u8*)"BST";
    gUXTzOff[2] = (i32)60;
    gUXTzName[3] = (u8*)"IST";
    gUXTzOff[3] = (i32)60; // Irish Standard
    gUXTzName[4] = (u8*)"CET";
    gUXTzOff[4] = (i32)60;
    gUXTzName[5] = (u8*)"CEST";
    gUXTzOff[5] = (i32)120;
    gUXTzName[6] = (u8*)"EET";
    gUXTzOff[6] = (i32)120;
    gUXTzName[7] = (u8*)"EEST";
    gUXTzOff[7] = (i32)180;
    gUXTzName[8] = (u8*)"MSK";
    gUXTzOff[8] = (i32)180;
    gUXTzName[9] = (u8*)"GST";
    gUXTzOff[9] = (i32)240;
    gUXTzName[10] = (u8*)"IST_IN";
    gUXTzOff[10] = (i32)330;
    gUXTzName[11] = (u8*)"NPT";
    gUXTzOff[11] = (i32)345; // +05:30, +05:45
    gUXTzName[12] = (u8*)"ICT";
    gUXTzOff[12] = (i32)420;
    gUXTzName[13] = (u8*)"CST_CN";
    gUXTzOff[13] = (i32)480;
    gUXTzName[14] = (u8*)"JST";
    gUXTzOff[14] = (i32)540;
    gUXTzName[15] = (u8*)"ACST";
    gUXTzOff[15] = (i32)570; // +09:30
    gUXTzName[16] = (u8*)"AEST";
    gUXTzOff[16] = (i32)600;
    gUXTzName[17] = (u8*)"AEDT";
    gUXTzOff[17] = (i32)660;
    gUXTzName[18] = (u8*)"NZST";
    gUXTzOff[18] = (i32)720;
    gUXTzName[19] = (u8*)"CHAST";
    gUXTzOff[19] = (i32)765; // +12:45
    gUXTzName[20] = (u8*)"EST";
    gUXTzOff[20] = (i32)-300;
    gUXTzName[21] = (u8*)"EDT";
    gUXTzOff[21] = (i32)-240;
    gUXTzName[22] = (u8*)"PST";
    gUXTzOff[22] = (i32)-480;
    gUXTzName[23] = (u8*)"PDT";
    gUXTzOff[23] = (i32)-420;
    gUXTzReady = true;
    }

// A time zone, as the only thing a calendar actually needs from one: a NAME and an offset from UTC.
// MINUTES, not hours — India is +05:30, Nepal +05:45, the Chatham Islands +12:45.
//
// This is a fixed-offset zone, deliberately.  A real zone is a function of the instant (a DST rule,
// amended by politics, historically irregular) and answering that properly needs the tz database —
// megabytes of it, revised several times a year.  So: the offset is what you set, the summer-time
// variants are listed separately (BST as well as GMT, EDT as well as EST), and systemZone() asks the
// host what offset is in force NOW, which is the one case where the rules have already been applied
// for us.  Anything more than that wants a real tz implementation, not a bigger table.
class UXTimeZone : Object
    {
    u8* name;
    i32 offsetMinutes; // add to UTC to get local time; negative west of Greenwich
    void init(void)
        {
        name = (u8*)"UTC";
        offsetMinutes = (i32)0;
        }
    static UXTimeZone* make(u8* nm, i32 mins)
        {
        UXTimeZone* z = new UXTimeZone();
        z.name = nm;
        z.offsetMinutes = mins;
        return z;
        }
    static UXTimeZone* utc(void)
        {
        return UXTimeZone.make((u8*)"UTC", (i32)0);
        }
    // Look one up by name; nil if it is not in the table, so a caller can tell "unknown" from UTC.
    // UXStr has no compare; this is the only one needed
    static bool sameName(u8* a, u8* b)
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
    static UXTimeZone* named(u8* nm)
        {
        xgTzInit();
        for (i32 i = (i32)0; i < (i32)UX_TZ_COUNT; i = i + (i32)1)
            {
            if (UXTimeZone.sameName(gUXTzName[i], nm))
                {
                return UXTimeZone.make(gUXTzName[i], gUXTzOff[i]);
                }
            }
        return (UXTimeZone*)0;
        }
    static i32 knownCount(void)
        {
        xgTzInit();
        return (i32)UX_TZ_COUNT;
        }
    static UXTimeZone* knownAt(i32 i)
        {
        xgTzInit();
        if (i < (i32)0 || i >= (i32)UX_TZ_COUNT)
            {
            return (UXTimeZone*)0;
            }
        return UXTimeZone.make(gUXTzName[i], gUXTzOff[i]);
        }
    // What the HOST is on right now — the one case where the real rules (DST included) have already
    // been applied for us, by whoever owns the tz database.  UTC when there is no driver to ask.
    static UXTimeZone* systemZone(void)
        {
        if (gDriver == (UXViewDriver*)0)
            {
            return UXTimeZone.utc();
            }
        return UXTimeZone.make((u8*)"local", gDriver.localOffsetMinutes());
        }
    // "+05:30" / "-08:00" / "Z" — what a formatter prints and a log wants.
    u8* offsetString(void)
        {
        if (offsetMinutes == (i32)0)
            {
            return (u8*)"Z";
            }
        i32 m = offsetMinutes < (i32)0 ? -offsetMinutes : offsetMinutes;
        u8* sign = offsetMinutes < (i32)0 ? (u8*)"-" : (u8*)"+";
        u8* hh = UXStr.fromInt(m / (i32)60);
        if (m / (i32)60 < (i32)10)
            {
            hh = UXStr.append((u8*)"0", hh);
            }
        u8* mm = UXStr.fromInt(m % (i32)60);
        if (m % (i32)60 < (i32)10)
            {
            mm = UXStr.append((u8*)"0", mm);
            }
        return UXStr.append(UXStr.append(UXStr.append(sign, hh), (u8*)":"), mm);
        }
    }

    class UXDate
    {
    i32 year;
    i32 month;
    i32 day; // month 1..12, day 1..31
    i32 hour;
    i32 minute;
    i32 second;
    i32 micro;        // microseconds within the second, 0..999999
    UXTimeZone* zone; // what the components above are EXPRESSED IN; UTC unless set
    void init(void)
        {
        year = (i32)1970;
        month = (i32)1;
        day = (i32)1;
        hour = (i32)0;
        minute = (i32)0;
        second = (i32)0;
        micro = (i32)0;
        zone = UXTimeZone.utc();
        }
    // Writable, as asked — but note what it does NOT do: setting the zone RELABELS this date, it does
    // not convert it (10:00 UTC becomes 10:00 in Tokyo, a different instant).  inZone() converts.
    void setZone(UXTimeZone* z)
        {
        zone = z != (UXTimeZone*)0 ? z : UXTimeZone.utc();
        }
    i32 zoneOffsetMinutes(void)
        {
        return zone != (UXTimeZone*)0 ? zone.offsetMinutes : (i32)0;
        }

    static UXDate* make(i32 y, i32 mo, i32 d)
        {
        UXDate* dt = new UXDate();
        dt.year = y;
        dt.month = mo;
        dt.day = d;
        return dt;
        }
    static UXDate* makeTime(i32 y, i32 mo, i32 d, i32 h, i32 mi, i32 s)
        {
        UXDate* dt = UXDate.make(y, mo, d);
        dt.hour = h;
        dt.minute = mi;
        dt.second = s;
        return dt;
        }
    static UXDate* makeMicro(i32 y, i32 mo, i32 d, i32 h, i32 mi, i32 s, i32 us)
        {
        UXDate* dt = UXDate.makeTime(y, mo, d, h, mi, s);
        dt.micro = us;
        return dt;
        }

    // NOW, from the driver's wall clock.  The model stays pure arithmetic everywhere else; this is
    // the one place it asks the outside world what time it is, and with no driver it answers the
    // epoch rather than pretending.
    // Now, in the host's own zone — the offset the system says is in force, DST already applied.
    static UXDate* currentDateLocal(void)
        {
        return UXDate.currentDate().inZone(UXTimeZone.systemZone());
        }
    static UXDate* currentDate(void)
        {
        if (gDriver == (UXViewDriver*)0)
            {
            return new UXDate();
            }
        i32 now[7];
        for (i32 i = (i32)0; i < (i32)7; i = i + (i32)1)
            {
            now[i] = (i32)0;
            }
        gDriver.nowUTC(&now[(i32)0]);
        // a driver with no clock
        if (now[(i32)0] == (i32)0)
            {
            return new UXDate();
            }
        return UXDate.makeMicro(now[(i32)0], now[(i32)1], now[(i32)2],
                                now[(i32)3], now[(i32)4], now[(i32)5], now[(i32)6]);
        }
    // UTC seconds since 1970 -> civil date.  Floor division, so dates before 1970 land on the right
    // day rather than truncating towards zero into the day after.
    static UXDate* fromEpochSeconds(i32 secs, i32 us)
        {
        i32 days = secs / (i32)86400;
        i32 rem = secs % (i32)86400;
        if (rem < (i32)0)
            {
            rem = rem + (i32)86400;
            days = days - (i32)1;
            }
        UXDate* d = UXDate.fromDayNumber(days);
        d.hour = rem / (i32)3600;
        d.minute = (rem % (i32)3600) / (i32)60;
        d.second = rem % (i32)60;
        d.micro = us;
        return d;
        }
    // The INSTANT this date names, in UTC seconds since 1970.  The components are local to `zone`,
    // so the offset comes back off — two dates an hour apart in different zones can be the same
    // instant, and comparing them any other way is the classic timezone bug.
    i32 epochSeconds(void)
        {
        return self.dayNumber() * (i32)86400 + hour * (i32)3600 + minute * (i32)60 + second - self.zoneOffsetMinutes() * (i32)60;
        }
    // The SAME instant, expressed in another zone: 17:00 UTC is 18:00 CET, not a different time.
    UXDate* inZone(UXTimeZone* tz)
        {
        if (tz == (UXTimeZone*)0)
            {
            return self.inZone(UXTimeZone.utc());
            }
        UXDate* r = UXDate.fromEpochSeconds(self.epochSeconds() + tz.offsetMinutes * (i32)60, micro);
        r.zone = tz;
        return r;
        }
    // Do two dates name the same moment, whatever zones they are written in?
    bool isSameInstant(UXDate* other)
        {
        return self.epochSeconds() == other.epochSeconds();
        }

    // Days since 1970-01-01 (Hinnant's days_from_civil), exact for any proleptic-Gregorian date.
    i32 dayNumber(void)
        {
        i32 y = year;
        i32 m = month;
        if (m <= (i32)2)
            {
            y = y - (i32)1;
            }
        i32 era = (y >= (i32)0 ? y : y - (i32)399) / (i32)400;
        i32 yoe = y - era * (i32)400;
        i32 mp = m + (m > (i32)2 ? (i32)-3 : (i32)9);
        i32 doy = ((i32)153 * mp + (i32)2) / (i32)5 + day - (i32)1;
        i32 doe = yoe * (i32)365 + yoe / (i32)4 - yoe / (i32)100 + doy;
        return era * (i32)146097 + doe - (i32)719468;
        }
    static UXDate* fromDayNumber(i32 z)
        {
        z = z + (i32)719468;
        i32 era = (z >= (i32)0 ? z : z - (i32)146096) / (i32)146097;
        i32 doe = z - era * (i32)146097;
        i32 yoe = (doe - doe / (i32)1460 + doe / (i32)36524 - doe / (i32)146096) / (i32)365;
        i32 y = yoe + era * (i32)400;
        i32 doy = doe - ((i32)365 * yoe + yoe / (i32)4 - yoe / (i32)100);
        i32 mp = ((i32)5 * doy + (i32)2) / (i32)153;
        i32 d = doy - ((i32)153 * mp + (i32)2) / (i32)5 + (i32)1;
        i32 m = mp + (mp < (i32)10 ? (i32)3 : (i32)-9);
        if (m <= (i32)2)
            {
            y = y + (i32)1;
            }
        return UXDate.make(y, m, d);
        }
    // 0 = Sunday .. 6 = Saturday.
    i32 weekday(void)
        {
        i32 z = self.dayNumber();
        return z >= (i32)-4 ? (z + (i32)4) % (i32)7 : (z + (i32)5) % (i32)7 + (i32)6;
        }
    // ---- arithmetic: every one returns a NEW date, none mutates ---------------------------------
    UXDate* addingDays(i32 n)
        {
        UXDate* r = UXDate.fromDayNumber(self.dayNumber() + n);
        r.hour = hour;
        r.minute = minute;
        r.second = second;
        r.micro = micro;
        r.zone = zone;
        return r;
        }
    UXDate* addingWeeks(i32 n)
        {
        return self.addingDays(n * (i32)7);
        }

    // Days in a month, so month arithmetic can CLAMP: 31 Jan + 1 month is 28 Feb (29 in a leap
    // year), not 3 March.  Every calendar does this, and it is the whole reason months cannot just
    // be turned into days.
    static i32 daysInMonth(i32 y, i32 mo)
        {
        if (mo == (i32)2)
            {
            return UXDate.isLeapYear(y) ? (i32)29 : (i32)28;
            }
        if (mo == (i32)4 || mo == (i32)6 || mo == (i32)9 || mo == (i32)11)
            {
            return (i32)30;
            }
        return (i32)31;
        }
    UXDate* addingMonths(i32 n)
        {
        i32 total = (year * (i32)12 + (month - (i32)1)) + n;
        i32 y = total / (i32)12;
        i32 m = total % (i32)12;
        // floor, for negative n
        if (m < (i32)0)
            {
            m = m + (i32)12;
            y = y - (i32)1;
            }
        m = m + (i32)1;
        i32 dim = UXDate.daysInMonth(y, m);
        i32 d = day > dim ? dim : day; // clamp into the shorter month
        UXDate* r = UXDate.makeMicro(y, m, d, hour, minute, second, micro);
        r.zone = zone; // arithmetic stays in the zone it started in
        return r;
        }
    UXDate* addingYears(i32 n)
        {
        return self.addingMonths(n * (i32)12);
        }

    // Time units carry into the date: 23:30 + 90 minutes is tomorrow, 01:00.  Done in seconds
    // through the day number, so the civil-calendar rules stay in one place.
    UXDate* addingSeconds(i32 n)
        {
        i32 secOfDay = hour * (i32)3600 + minute * (i32)60 + second + n;
        i32 dayShift = secOfDay / (i32)86400;
        i32 rem = secOfDay % (i32)86400;
        if (rem < (i32)0)
            {
            rem = rem + (i32)86400;
            dayShift = dayShift - (i32)1;
            }
        UXDate* r = UXDate.fromDayNumber(self.dayNumber() + dayShift);
        r.hour = rem / (i32)3600;
        r.minute = (rem % (i32)3600) / (i32)60;
        r.second = rem % (i32)60;
        r.micro = micro;
        r.zone = zone;
        return r;
        }
    UXDate* addingMinutes(i32 n)
        {
        return self.addingSeconds(n * (i32)60);
        }
    UXDate* addingHours(i32 n)
        {
        return self.addingSeconds(n * (i32)3600);
        }
    // Microseconds carry the same way — and the seconds are added SEPARATELY rather than folding
    // everything into microseconds, which would overflow an i32 after ~35 minutes.
    UXDate* addingMicroseconds(i32 n)
        {
        i32 us = micro + n;
        i32 carry = us / (i32)1000000;
        i32 rem = us % (i32)1000000;
        if (rem < (i32)0)
            {
            rem = rem + (i32)1000000;
            carry = carry - (i32)1;
            }
        UXDate* r = self.addingSeconds(carry);
        r.micro = rem;
        return r;
        }
    // Whole days from self to other (other - self).
    i32 daysUntil(UXDate* other)
        {
        return other.dayNumber() - self.dayNumber();
        }
    static bool isLeapYear(i32 y)
        {
        return (y % (i32)4 == (i32)0 && y % (i32)100 != (i32)0) || y % (i32)400 == (i32)0;
        }
    }

    class UXDateFormatter
    {
    u8* pattern;
    void init(void)
        {
        pattern = (u8*)"yyyy-MM-dd";
        xgDateInitNames();
        }
    void setPattern(u8* p)
        {
        pattern = p;
        }
    static UXDateFormatter* withPattern(u8* p)
        {
        UXDateFormatter* f = new UXDateFormatter();
        f.pattern = p;
        return f;
        }

    static i32 slen(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }
    // append a zero-padded number, return new offset
    i32 putNum(u8* out, i32 o, i32 v, i32 width)
        {
        u8 tmp[16];
        i32 t = (i32)0;
        i32 x = v < (i32)0 ? -v : v;
        if (x == (i32)0)
            {
            tmp[0] = (u8)'0';
            t = (i32)1;
            }
        while (x > (i32)0)
            {
            tmp[t] = (u8)((i32)'0' + x % (i32)10);
            x = x / (i32)10;
            t = t + (i32)1;
            }
        for (i32 z = (i32)0; z < width - t; z = z + (i32)1)
            {
            out[o] = (u8)'0';
            o = o + (i32)1;
            }
        for (i32 i = (i32)0; i < t; i = i + (i32)1)
            {
            out[o] = tmp[t - (i32)1 - i];
            o = o + (i32)1;
            }
        return o;
        }
    i32 putStr(u8* out, i32 o, u8* s)
        {
        i32 i = (i32)0;
        while (s[i] != (u8)0)
            {
            out[o] = s[i];
            o = o + (i32)1;
            i = i + (i32)1;
            }
        return o;
        }

    // count how many of the same char start at pos
    i32 runLength(i32 pos)
        {
        u8 c = pattern[pos];
        i32 n = (i32)0;
        while (pattern[pos + n] == c)
            {
            n = n + (i32)1;
            }
        return n;
        }

    u8* format(UXDate* d)
        {
        xgDateInitNames();
        i32 pn = UXDateFormatter.slen(pattern);
        u8* out = new u8[(u32)(pn * (i32)4 + (i32)32)]; // month/day names expand; generous
        i32 o = (i32)0;
        i32 i = (i32)0;
        while (i < pn)
            {
            u8 c = pattern[i];
            i32 run = self.runLength(i);
            if (c == (u8)'y')
                {
                if (run <= (i32)2)
                    {
                    o = self.putNum(out, o, d.year % (i32)100, (i32)2);
                    }
                else
                    {
                    o = self.putNum(out, o, d.year, (i32)4);
                    }
                }
            else if (c == (u8)'M')
                {
                if (run == (i32)1)
                    {
                    o = self.putNum(out, o, d.month, (i32)1);
                    }
                else if (run == (i32)2)
                    {
                    o = self.putNum(out, o, d.month, (i32)2);
                    }
                else if (run == (i32)3)
                    {
                    o = self.putStr(out, o, gUXMonthAbbr[d.month - (i32)1]);
                    }
                else
                    {
                    o = self.putStr(out, o, gUXMonthFull[d.month - (i32)1]);
                    }
                }
            else if (c == (u8)'d')
                {
                o = self.putNum(out, o, d.day, run == (i32)1 ? (i32)1 : (i32)2);
                }
            else if (c == (u8)'H')
                {
                o = self.putNum(out, o, d.hour, run == (i32)1 ? (i32)1 : (i32)2);
                }
            else if (c == (u8)'m')
                {
                o = self.putNum(out, o, d.minute, run == (i32)1 ? (i32)1 : (i32)2);
                }
            else if (c == (u8)'s')
                {
                o = self.putNum(out, o, d.second, run == (i32)1 ? (i32)1 : (i32)2);
                }
            else if (c == (u8)'E')
                {
                if (run >= (i32)4)
                    {
                    o = self.putStr(out, o, gUXDayFull[d.weekday()]);
                    }
                else
                    {
                    o = self.putStr(out, o, gUXDayAbbr[d.weekday()]);
                    }
                }
            else
                {
                // literal run
                for (i32 k = (i32)0; k < run; k = k + (i32)1)
                    {
                    out[o] = c;
                    o = o + (i32)1;
                    }
                }
            i = i + run;
            }
        out[o] = (u8)0;
        return out;
        }
    }
