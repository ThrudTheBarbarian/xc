// cyclic_import_b.xc — the other half of the cyclic-#import guard pair
// (task #20). readA is the killer shape: single-block leaf accessors on a
// CycA* parameter, spliced in by the -O2 leaf inliner. When the include
// guard put CycB ahead of CycA in the merged unit, the CycA* here lowered
// as Ptr(Void), and the inlined FieldAddrs folded every offset to 0.
//xtc-flags: skip
#import "cyclic_import_a.xc"

class CycB
{
    u16 _w;

    void init(void)
    {
        _w = (u16)$BEEF;
    }

    u32 mix(void) { return (u32)_w; }

    // Multi-block ON PURPOSE: a single-block readA gets inlined into
    // main, where the receiver is main's own correctly-typed value and
    // the bug vanishes. Kept out of main, readA's CycA* PARAMETER is the
    // FieldAddr base the accessors splice onto — the shape that broke.
    u32 readA(CycA* a)
    {
        u32 acc = (u32)0;
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            acc = acc + (u32)a.tag();
        if (acc > (u32)500)
            acc = acc + a.mag() % (u32)$100;
        return acc;
    }
}
