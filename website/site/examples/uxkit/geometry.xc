// geometry.xc — UXRect and the UXGeom operations, with no window at all.
//
// The geometry is pure value types and static functions, so it runs headless.
//
// Columns are padded by hand: printf field widths (%-22s) are unimplemented in
// the runtime today and silently corrupt the arguments after them.
#import <Stdio.xc>
#import "UXGeometry.xc"

void show(u8* what, UXRect r) {
    Stdio.printf("%s: %d,%d %dx%d\n", what, r.x, r.y, r.w, r.h);
}

void main(void) {
    UXRect panel  = UXGeom.make(10, 10, 100, 60);
    UXRect button = UXGeom.make(80, 40, 60, 40);

    show((u8*)"panel             ", panel);
    show((u8*)"button            ", button);

    // Do they overlap, and where?
    Stdio.printf("intersects            %s\n",
                 UXGeom.intersects(panel, button) ? (u8*)"yes" : (u8*)"no");
    show((u8*)"intersection      ", UXGeom.intersection(panel, button));

    // The smallest rect covering both — what a damage region accumulates.
    show((u8*)"unite             ", UXGeom.unite(panel, button));

    // An EMPTY rect is the identity for unite, so damage can start at zero
    // and just union into it without a "first time" special case.
    UXRect damage = UXGeom.zero();
    damage = UXGeom.unite(damage, panel);
    damage = UXGeom.unite(damage, button);
    show((u8*)"damage accumulated", damage);

    // Hit testing is half-open: the right and bottom edges are NOT inside.
    Stdio.printf("contains(10,10)       %s\n", UXGeom.contains(panel, 10, 10) ? (u8*)"yes" : (u8*)"no");
    Stdio.printf("contains(110,70)      %s\n", UXGeom.contains(panel, 110, 70) ? (u8*)"yes" : (u8*)"no");
    Stdio.printf("contains(109,69)      %s\n", UXGeom.contains(panel, 109, 69) ? (u8*)"yes" : (u8*)"no");

    // Integer length, no floats anywhere in the toolkit's geometry.
    Stdio.printf("length(3,4)           %d\n", UXGeom.length(3, 4));
    Stdio.printf("isqrt(50)             %d\n", UXGeom.isqrt(50));
}
