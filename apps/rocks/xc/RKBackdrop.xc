// RKBackdrop.xc — what the canvas is drawn on: a blue grid, and the form as a panel of its real
// size on it, labelled with the layout it is ("phone portrait · 360 × 640").
//
// Without it the form has no edge: a phone layout looks as wide as the window, and nothing says a
// control has been put where no phone will show it.
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"

// Where the form's panel sits on the canvas: room for its label above, a margin to its left.
#define RK_FORM_X 40
#define RK_FORM_Y 48

class RKBackdrop : UXView
    {
    i32 formW;
    i32 formH;
    u8* label;

    void init(void)
        {
        super.init();
        formW = (i32)0;
        formH = (i32)0;
        label = (u8*)"";
        }
    void showForm(i32 w, i32 h, u8* l)
        {
        formW = w;
        formH = h;
        label = l;
        self.setNeedsDisplay();
        }
    // Whether a point in the form's coordinates is on its panel.
    bool onPanel(i32 x, i32 y)
        {
        return x >= (i32)0 && y >= (i32)0 && x < formW && y < formH;
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRectRGB(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)226, (i32)234, (i32)246);
        for (i32 x = (i32)0; x < (i32)b.w; x = x + (i32)20)
            {
            i32 major = (x % (i32)100) == (i32)0 ? (i32)18 : (i32)0;
            g.fillRectRGB(UXGeom.make((i16)x, (i16)0, (i16)1, b.h), (i32)206 - major, (i32)220 - major, (i32)240 - major);
            }
        for (i32 y = (i32)0; y < (i32)b.h; y = y + (i32)20)
            {
            i32 major = (y % (i32)100) == (i32)0 ? (i32)18 : (i32)0;
            g.fillRectRGB(UXGeom.make((i16)0, (i16)y, b.w, (i16)1), (i32)206 - major, (i32)220 - major, (i32)240 - major);
            }
        if (formW <= (i32)0 || formH <= (i32)0)
            {
            return;
            }
        i16 x = (i16)RK_FORM_X;
        i16 y = (i16)RK_FORM_Y;
        // a soft shadow, the panel, its edge
        g.fillRectRGBA(UXGeom.make((i16)((i32)x + (i32)4), (i16)((i32)y + (i32)4), (i16)formW, (i16)formH), (i32)40, (i32)60, (i32)100, (i32)50);
        g.fillRectRGB(UXGeom.make(x, y, (i16)formW, (i16)formH), (i32)246, (i32)246, (i32)246);
        g.fillRectRGB(UXGeom.make(x, y, (i16)formW, (i16)1), (i32)150, (i32)160, (i32)180);
        g.fillRectRGB(UXGeom.make(x, (i16)((i32)y + formH - (i32)1), (i16)formW, (i16)1), (i32)150, (i32)160, (i32)180);
        g.fillRectRGB(UXGeom.make(x, y, (i16)1, (i16)formH), (i32)150, (i32)160, (i32)180);
        g.fillRectRGB(UXGeom.make((i16)((i32)x + formW - (i32)1), y, (i16)1, (i16)formH), (i32)150, (i32)160, (i32)180);
        g.drawTextRGBA(label, x, (i16)((i32)y - (i32)22), (i32)40, (i32)60, (i32)100, (i32)255, (i32)13);
        }
    }
