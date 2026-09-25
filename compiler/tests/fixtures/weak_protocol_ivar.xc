// weak_protocol_ivar.xc — a weak ivar whose pointee is a PROTOCOL auto-zeroes
// like one whose pointee is a class, and the ivar after it keeps its value.
//
// The shipped compiler read `weak : Del* del` as a plain strong pointer: no
// link words, a retain on store, and every later ivar 8 bytes earlier than
// the reference placed it. A library and a client built by the two compilers
// then disagreed about the object's layout.
//
//   T1  the weak field holds the delegate while it is alive
//   T2  the ivar declared after it is intact
//   T3  releasing the delegate zeroes the field
//   T4  the ivar after it is still intact

#import "Stdio.xc"
#import "Assert.xc"

protocol Del
{
    u16 tick(void);
}

class Ticker<Del>
{
    u16 tick(void) { return (u16)7; }
}

class Holder
{
    weak : Del* del;
    u16 v;
    void init(void) { v = (u16)5; }
    u16 call(void)
    {
        if (del)
            return del.tick();
        return (u16)0;
    }
}

Holder* gH;
Ticker* gT;

void main(void)
{
    Assert.reset();
    gH = new Holder();
    gT = new Ticker();
    gH.del = gT;
    Assert.isTrue(gH.call() == (u16)7);     // T1
    Assert.isTrue(gH.v == (u16)5);          // T2
    gT = (Ticker*)0;
    Assert.isTrue(gH.call() == (u16)0);     // T3
    Assert.isTrue(gH.v == (u16)5);          // T4
    Assert.summary();
}
