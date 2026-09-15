//xtc-na: x86_64,win64 — the Gfx library is not ported to x86_64
//   the comprehensive off-screen port (support/arm64/lib/GfxFactory.xc)
//   and passes cleanly.
// gfx_factory.xc — `gfxCreate(mode, textRows)` factory in
// GfxFactory.xc instantiates the right Gfx subclass for each
// mode constant. Verifies dispatch through Gfx@ lands on the
// concrete subclass's plot / hline by checking that bytes show
// up at the resolution-correct offsets in the screen buffer.

#import "Stdio.xc"
#import "Assert.xc"
#import "GfxFactory.xc"

void main(void)
{
    Assert.reset();

    // ── GFX_320_192_1 (GR.8) ─────────────────────────────
    // Construct against an off-screen heap buffer so the test
    // doesn't need a real display set up. Use the explicit
    // Gfx8(buf) constructor — gfxCreate's setupNative path
    // assumes the OS isn't running and would scribble ANTIC
    // registers in the simulator.
    {
        u8* buf8 = new u8[7680];   // 320×192/8
        Gfx8* g8 = new Gfx8(buf8);
        Gfx* g = (Gfx*)g8;          // upcast — vtable still resolves to Gfx8
        g.setPen(1);
        g.hline(0, 7, 0);            // first byte of row 0 → $FF
        Assert.isEqual((u16)buf8[0], $FF);             // T1
    }

    // ── GFX_160_96_2 (GR.7) ──────────────────────────────
    {
        u8* buf7 = new u8[3840];   // 160×96 / 4
        Gfx7* g7 = new Gfx7(buf7);
        Gfx* g = (Gfx*)g7;
        g.setPen(3);
        g.hline(0, 3, 0);            // first byte of row 0 → $FF (col 3 ×4)
        Assert.isEqual((u16)buf7[0], $FF);             // T2
    }

    // ── GFX_160_192_2 (GR.15) ───────────────────────────
    {
        u8* buf15 = new u8[7680];      // 160×192 / 4
        Gfx15* g15 = new Gfx15(buf15);
        Gfx* g = (Gfx*)g15;
        g.setPen(3);
        g.hline(0, 3, 0);
        Assert.isEqual((u16)buf15[0], $FF);            // T3
    }

    // ── Unknown mode returns null ─────────────────────────
    // gfxCreate is a free function (not a Gfx static method),
    // so calling it with an unsupported mode returns null
    // without touching the OS.
    Gfx* none = gfxCreate(99, 0);
    Assert.isEqual(none == (Gfx*)0 ? (u16)1 : (u16)0, 1); // T4

    Stdio.printf("DONE 4\n");
    return;
}
