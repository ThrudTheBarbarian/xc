//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
// gfx_clear.xc — Gfx.clear() through a Gfx@ pointer.
//
// The Gfx factory (gfxCreate) returns Gfx@. Before this fix
// `g.clear()` on the upcast pointer failed sema with "No method
// 'clear' on class 'Gfx'" — clear() lived only on each subclass.
// Now Gfx.clear() walks the receiver's `clearBytes` bytes from
// `sbase`, so virtual dispatch through Gfx@ lands on the
// inherited body and the subclass's clearBytes / sbase ivars
// drive the loop.

#import "Stdio.xc"
#import "Assert.xc"
#import "GfxFactory.xc"

void main(void)
{
    Assert.reset();

    // ── GR.8 (320×192 1bpp) — clearBytes = 7680 ──────────
    {
        u8* buf = new u8[7680];
        Gfx8* g8 = new Gfx8(buf);
        Gfx* g = (Gfx*)g8;        // upcast to base

        // Pre-fill with $AA so we can see the clear actually
        // overwrites every byte.
        u16 i = (u16)0;
        while (i < (u16)7680) { buf[i] = $AA; i = i + (u16)1; }

        g.setFillColor(0);
        g.clear();                 // virtual dispatch through Gfx@
        Assert.isEqual((u16)buf[0],    (u16)0);          // T1
        Assert.isEqual((u16)buf[3840], (u16)0);          // T2 — middle
        Assert.isEqual((u16)buf[7679], (u16)0);          // T3 — last byte

        g.setFillColor(1);
        g.clear();
        Assert.isEqual((u16)buf[0],    (u16)$FF);        // T4
        Assert.isEqual((u16)buf[7679], (u16)$FF);        // T5
    }

    // ── GR.7 (160×96 4-colour) — clearBytes = 3840 ──────
    {
        u8* buf = new u8[3840];
        Gfx7* g7 = new Gfx7(buf);
        Gfx* g = (Gfx*)g7;

        u16 i = (u16)0;
        while (i < (u16)3840) { buf[i] = $55; i = i + (u16)1; }

        g.setFillColor(0);
        g.clear();
        Assert.isEqual((u16)buf[0],    (u16)0);          // T6
        Assert.isEqual((u16)buf[3839], (u16)0);          // T7

        g.setFillColor(1);
        g.clear();
        // 1bpp interpretation: any non-zero fillColor → $FF.
        // GR.7 is 2bpp, so $FF = colour 3 in every pixel slot.
        Assert.isEqual((u16)buf[0],    (u16)$FF);        // T8
        Assert.isEqual((u16)buf[3839], (u16)$FF);        // T9
    }

    Stdio.printf("DONE 9\n");
    return;
}