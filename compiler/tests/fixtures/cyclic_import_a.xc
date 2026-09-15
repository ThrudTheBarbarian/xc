// cyclic_import_a.xc — half of the cyclic-#import guard pair (task #20).
// See cyclic_import_layout.xc for the story. Compiles ALONE too (the
// differentials sweep it), which exercises the cycle from the other side:
// here CycA is the guard-blocked one and lands AFTER its user CycB.
//xtc-flags: skip
#import "cyclic_import_b.xc"

class CycA
{
    u8  _tag;
    u32 _mag;

    void init(void)
    {
        _tag = (u8)$DE;
        _mag = (u32)$C0FFEE;
    }

    u8  tag(void) { return _tag; }
    u32 mag(void) { return _mag; }

    // A calls through B too, so the import cycle is a CALL cycle as well.
    u32 viaB(CycB* b) { return b.mix() + (u32)1; }
}
