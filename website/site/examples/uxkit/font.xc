// font.xc — UXFont is a VALUE: every derivation returns a new descriptor.
//
// The font a chooser edits and text drawing carries. Glyph rendering and the
// list of available families are the backend's business, not this type's.
#import <Stdio.xc>
#import "UXFont.xc"

void show(u8* what, UXFont* f) {
    Stdio.printf("%s %s\n", what, f.description());
}

void main(void) {
    UXFont* base = UXFont.make((u8*)"Helvetica", 12);
    show((u8*)"base       ", base);

    // Each derivation is a NEW font; base is never touched.
    show((u8*)"bolded     ", base.bolded());
    show((u8*)"italic     ", base.italicized());
    show((u8*)"withSize 18", base.withSize(18));
    show((u8*)"scaledBy150", base.scaledBy(150));
    show((u8*)"base again ", base);

    // Derivations chain, which is how a style menu works.
    show((u8*)"chained    ", base.bolded().italicized().withSize(14));

    // Toggling is what a Bold menu item does — it does not know the current state.
    UXFont* b = base.togglingBold();
    show((u8*)"toggled    ", b);
    show((u8*)"toggled x2 ", b.togglingBold());

    // Value equality, not identity: two separately-built fonts are equal.
    UXFont* other = UXFont.make((u8*)"Helvetica", 12);
    Stdio.printf("equal to a fresh copy: %s\n",
                 base.isEqualTo(other) ? (u8*)"yes" : (u8*)"no");
    Stdio.printf("equal after bolding:   %s\n",
                 base.isEqualTo(base.bolded()) ? (u8*)"yes" : (u8*)"no");
}
