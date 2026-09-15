// The case a flat, program-global vtable slot CANNOT express.
//
// blib and clib are built independently, so each numbers its protocol from the same
// base. A class conforming to both was handed the SAME slot twice: one impl silently
// overwrote the other, and every call through the loser ran the wrong method. It could
// not be fixed by renumbering either — each library's vtables are already emitted and
// its own dispatch sites already bake its numbers in.
//
// Protocols therefore leave the flat slot space entirely (phase-618). A method's index
// in its PROTOCOL's own declaration depends on nothing but that declaration, so two
// libraries that have never met derive it identically, and the receiver's itable maps
// protocol id -> table at run time.
#import "Stdio.xc"
#import <blib>
#import <clib>

class Both<BProto, CProto>
    {
    u16 v;
    u16 bee(void)
        {
        return (u16)111;
        }
    u16 see(void)
        {
        return (u16)222;
        }
    }

    i16
    main(void)
    {
    Both* x = new Both(); // conforms to protocols from BOTH
    BProto* b = (BProto*)x;
    CProto* c = (CProto*)x;
    Stdio.printf("both=%d,%d\n", b.bee(), c.see()); // 111,222

    BThing* bt = new BThing();
    BProto* b2 = (BProto*)bt; // each library's own classes
    CThing* ct = new CThing();
    CProto* c2 = (CProto*)ct;                         // still dispatch correctly
    Stdio.printf("libs=%d,%d\n", b2.bee(), c2.see()); // 10,30
    return 0;
    }
