// UXDatePicker.xc — a date entry control (NSDatePicker in shape).
//
// Holds an UXDate and steps its year / month / day fields, using UXDate's exact civil-calendar maths so
// day rollover (Jan 31 + 1 day -> Feb 1), month rollover (+ day clamping: Jan 31 + 1 month -> Feb
// 28/29) and leap years are all correct.  The stepping model is pure and testable; drawing the fields
// + wiring steppers ride the UXControl seam.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"
#import "UXDate.xc"

class UXDatePicker : UXControl
    {
    UXDate* dateVal;
    void init(void)
        {
        super.init();
        dateVal = UXDate.make((i32)2000, (i32)1, (i32)1);
        }
    UXKind kind(void)
        {
        return UXKindView;
        }

    void setDate(UXDate* d)
        {
        dateVal = d;
        }
    UXDate* date(void)
        {
        return dateVal;
        }
    i32 year(void)
        {
        return dateVal.year;
        }
    i32 month(void)
        {
        return dateVal.month;
        }
    i32 day(void)
        {
        return dateVal.day;
        }

    static i32 daysInMonth(i32 y, i32 m)
        {
        if (m == (i32)2)
            {
            return UXDate.isLeapYear(y) ? (i32)29 : (i32)28;
            }
        if (m == (i32)4 || m == (i32)6 || m == (i32)9 || m == (i32)11)
            {
            return (i32)30;
            }
        return (i32)31;
        }

    // Day stepping goes through the day-number so it rolls across months/years exactly.
    void stepDay(i32 delta)
        {
        dateVal = dateVal.addingDays(delta);
        }

    void stepMonth(i32 delta)
        {
        i32 m = dateVal.month + delta;
        i32 y = dateVal.year;
        while (m > (i32)12)
            {
            m = m - (i32)12;
            y = y + (i32)1;
            }
        while (m < (i32)1)
            {
            m = m + (i32)12;
            y = y - (i32)1;
            }
        i32 d = dateVal.day;
        i32 dim = UXDatePicker.daysInMonth(y, m);
        // clamp (e.g. Jan 31 -> Feb 28/29)
        if (d > dim)
            {
            d = dim;
            }
        dateVal = UXDate.makeTime(y, m, d, dateVal.hour, dateVal.minute, dateVal.second);
        }
    void stepYear(i32 delta)
        {
        i32 y = dateVal.year + delta;
        i32 m = dateVal.month;
        i32 d = dateVal.day;
        i32 dim = UXDatePicker.daysInMonth(y, m);
        // Feb 29 in a non-leap year -> Feb 28
        if (d > dim)
            {
            d = dim;
            }
        dateVal = UXDate.makeTime(y, m, d, dateVal.hour, dateVal.minute, dateVal.second);
        }

    // yyyy-MM-dd into a caller-lifetime buffer — the field face's text.
    void formatInto(u8* out)
        {
        i32 y = dateVal.year;
        i32 m = dateVal.month;
        i32 d = dateVal.day;
        out[0] = (u8)((u8)48 + (u8)(y / (i32)1000));
        out[1] = (u8)((u8)48 + (u8)((y / (i32)100) % (i32)10));
        out[2] = (u8)((u8)48 + (u8)((y / (i32)10) % (i32)10));
        out[3] = (u8)((u8)48 + (u8)(y % (i32)10));
        out[4] = (u8)45;
        out[5] = (u8)((u8)48 + (u8)(m / (i32)10));
        out[6] = (u8)((u8)48 + (u8)(m % (i32)10));
        out[7] = (u8)45;
        out[8] = (u8)((u8)48 + (u8)(d / (i32)10));
        out[9] = (u8)((u8)48 + (u8)(d % (i32)10));
        out[10] = (u8)0;
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        // a bordered field face with the ISO date — the up/down affordance at
        // the right edge marks it as steppable
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)0);
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, (i16)1), (i32)9);
        g.fillRect(UXGeom.make((i16)0, (i16)(b.h - (i16)1), b.w, (i16)1), (i32)9);
        g.fillRect(UXGeom.make((i16)0, (i16)0, (i16)1, b.h), (i32)9);
        g.fillRect(UXGeom.make((i16)(b.w - (i16)1), (i16)0, (i16)1, b.h), (i32)9);
        u8 txt[12];
        self.formatInto(&txt[(i32)0]);
        g.drawText(&txt[(i32)0], (i16)6, (i16)((b.h - (i16)12) / (i16)2), (i32)1, (i32)0);
        i16 ax = (i16)(b.w - (i16)16);
        g.fillTriangle((i16)(ax + (i16)6), (i16)(b.h / (i16)2 - (i16)7),
                       ax, (i16)(b.h / (i16)2 - (i16)2), (i16)(ax + (i16)12), (i16)(b.h / (i16)2 - (i16)2), (i32)1);
        g.fillTriangle((i16)(ax + (i16)6), (i16)(b.h / (i16)2 + (i16)7),
                       ax, (i16)(b.h / (i16)2 + (i16)2), (i16)(ax + (i16)12), (i16)(b.h / (i16)2 + (i16)2), (i32)1);
        }
    }
