// UXGroupBox.xc — a titled frame around related controls (promoted out of the
// file panel, where it was born): the ST-dialog way of saying "these belong
// together".  Pure decoration: it draws a rule around its bounds with the
// title breaking the top edge, and the grouped controls sit on top of it as
// siblings on the canvas — the box neither contains nor lays out anything.
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"

class UXGroupBox : UXView
    {
    u8* title;
    void init(void)
        {
        super.init();
        title = (u8*)"";
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    void setTitle(u8* t)
        {
        title = t;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        i16 top = (i16)8;
        // 1px fills, not drawLine: the line stand-in on some graphics draws
        // verticals as degenerate slivers
        g.fillRect(UXGeom.make((i16)0, top, (i16)1, (i16)(b.h - top)), (i32)9);              // left
        g.fillRect(UXGeom.make((i16)(b.w - (i16)1), top, (i16)1, (i16)(b.h - top)), (i32)9); // right
        g.fillRect(UXGeom.make((i16)0, (i16)(b.h - (i16)1), b.w, (i16)1), (i32)9);           // bottom
        g.fillRect(UXGeom.make((i16)0, top, b.w, (i16)1), (i32)9);                           // top
        g.fillRect(UXGeom.make((i16)6, (i16)1, (i16)60, (i16)14), (i32)8);                   // gap for the title
        g.drawText(title, (i16)10, (i16)1, (i32)1, (i32)0);
        }
    }
