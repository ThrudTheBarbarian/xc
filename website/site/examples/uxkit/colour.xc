// colour.xc — UXColor: integer RGBA, HSB, blending, and readable-text choice.
//
// All integer, no floats, so every backend produces identical pixels.
#import <Stdio.xc>
#import "UXColor.xc"

void show(u8* what, UXColor* c) {
    Stdio.printf("%s rgb(%d,%d,%d) a=%d hex=%x lum=%d %s\n",
                 what, c.r, c.g, c.b, c.a, c.toHex(), c.luminance(),
                 c.isDark() ? (u8*)"dark" : (u8*)"light");
}

void main(void) {
    UXColor* brand = UXColor.fromHex($3050A0);
    show((u8*)"brand    ", brand);

    // Tints and shades are blends toward white and black: 0 = unchanged,
    // 255 = fully the other colour.
    show((u8*)"lighter  ", brand.lightened(64));
    show((u8*)"darker   ", brand.darkened(64));

    // Halfway between two colours.
    show((u8*)"halfway  ", brand.blend(UXColor.red(), 128));

    // Alpha is a copy, not a mutation — the original is untouched.
    UXColor* ghost = brand.withAlpha(96);
    show((u8*)"ghost    ", ghost);
    show((u8*)"brand yet", brand);

    // Round-tripping through HSB.
    i32 h = 0; i32 s = 0; i32 v = 0;
    brand.toHSB(&h, &s, &v);
    Stdio.printf("brand HSB  h=%d s=%d v=%d\n", h, s, v);
    show((u8*)"from HSB ", UXColor.hsb(h, s, v));

    // Picking readable text over a background is what luminance is FOR.
    UXColor* ink = brand.isDark() ? UXColor.white() : UXColor.black();
    Stdio.printf("text over brand should be %s\n",
                 ink.isEqualTo(UXColor.white()) ? (u8*)"white" : (u8*)"black");
}
