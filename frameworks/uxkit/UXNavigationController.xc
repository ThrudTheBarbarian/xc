// UXNavigationController.xc — the navigation stack (UINavigationController in
// shape): forms pushed forward and popped back, exactly one visible.
//
// This is the COMPACT-space realization of UXNB v2 §5's MASTER-DETAIL — the
// mobile-aware layer's first citizen — and it keeps the UXTabView discipline:
// the STACK is a pure model (push / pop / depth / top, unit-testable with no
// window), and applyNav() maps it onto a live tree by hiding everything but
// the top form's content.  The drawn bar (back chevron + titles) is the
// neutral fallback; on iOS the driver seam later swaps the whole thing for a
// real UINavigationController with the real edge-swipe, and back-swipe never
// surfaces as an app event — it is a pop, reported through the same delegate.
//
// Lifecycle notifications use §5's names: formWillShow fires for a form about
// to become the visible top (on its push, and again when a pop re-reveals
// it); formDidHide fires for a form leaving the top (covered by a push, or
// popped off).  The delegate is weak, as delegates are.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXMetrics.xc"

class UXNavItem : Object
    {
    u8* title;
    UXView* content;
    void init(void)
        {
        title = (u8*)"";
        content = (UXView*)0;
        }
    }

    protocol UXNavigationDelegate
    {
    optional void formWillShow(UXNavigationController * n, UXView * content, i32 depth);
    optional void formDidHide(UXNavigationController * n, UXView * content, i32 depth);
    }

// The optional methods' types, takeable as `callback`s.
class UXNavigationController : UXView
    {
    Array<UXNavItem>* stack;
    weak : UXNavigationDelegate* delegate;

    void init(void)
        {
        super.init();
        stack = new Array();
        delegate = (UXNavigationDelegate*)0;
        }
    void setDelegate(UXNavigationDelegate* d)
        {
        delegate = d;
        }

    // ---- the model (no window needed) ---------------------------------------
    i32 depth(void)
        {
        return (i32)stack.count();
        }
    UXNavItem* itemAt(i32 i)
        { return (UXNavItem* ?)stack.get((u16)i);
        }
    u8* titleAt(i32 i)
        {
        return self.itemAt(i).title;
        }
    UXView* contentAt(i32 i)
        {
        return self.itemAt(i).content;
        }
    u8* topTitle(void)
        {
        return self.depth() > (i32)0 ? self.titleAt(self.depth() - (i32)1) : (u8*)"";
        }
    UXView* topContent(void)
        {
        return self.depth() > (i32)0 ? self.contentAt(self.depth() - (i32)1) : (UXView*)0;
        }
    // What the back affordance reads: the title UNDER the top — where back goes.
    u8* backTitle(void)
        {
        return self.depth() > (i32)1 ? self.titleAt(self.depth() - (i32)2) : (u8*)"";
        }
    bool canGoBack(void)
        {
        return self.depth() > (i32)1;
        }
    bool isFormVisible(i32 i)
        {
        return i == self.depth() - (i32)1;
        }

    // ---- the bar ------------------------------------------------------------
    i16 barHeight(void)
        {
        i32 ff = gDriver != (UXViewDriver*)0 ? gDriver.formFactorClass() : (i32)UX_FORM_DESKTOP;
        return (i16)UXMetrics.navBarHeightFor(ff);
        }
    UXRect contentFrame(void)
        {
        UXRect b = self.bounds();
        i16 bh = self.barHeight();
        return UXGeom.make((i16)0, bh, b.w, (i16)((i32)b.h - (i32)bh));
        }

    // ---- forward and back ---------------------------------------------------
    void push(u8* title, UXView* content)
        {
        i32 d = self.depth();
        // the covered form
        if (d > (i32)0)
            {
            self.notifyHide(self.contentAt(d - (i32)1), d);
            }
        UXNavItem* it = new UXNavItem();
        it.title = title;
        it.content = content;
        stack.add(it);
        self.notifyShow(content, d + (i32)1);
        if (owner != (UXViewTree*)0 && content != (UXView*)0 && content.owner == (UXViewTree*)0)
            {
            self.addSubview(content, self.contentFrame());
            }
        self.applyNav();
        }

    void pop(void)
        {
        i32 d = self.depth();
        // the root never pops
        if (d <= (i32)1)
            {
            return;
            }
        UXNavItem* top = self.itemAt(d - (i32)1);
        self.notifyHide(top.content, d);
        stack.removeAt((u16)(d - (i32)1));              // the view stays attached, hidden — repushable
        self.notifyShow(self.topContent(), d - (i32)1); // the re-revealed form
        self.applyNav();
        }

    void popToRoot(void)
        {
        while (self.depth() > (i32)1)
            {
            self.pop();
            }
        }

    // ---- the model applied to the tree --------------------------------------
    // Only the top form's content is shown; safe once the contents have owners.
    void applyNav(void)
        {
        for (i32 i = (i32)0; i < self.depth(); i = i + (i32)1)
            {
            UXView* c = self.contentAt(i);
            if (c != (UXView*)0 && c.owner != (UXViewTree*)0)
                {
                c.setHidden(!self.isFormVisible(i));
                }
            }
        self.setNeedsDisplay(); // the bar's titles changed
        }

    void notifyShow(UXView* c, i32 d)
        {
        if (delegate != (UXNavigationDelegate*)0)
            {
            callback f void(UXNavigationController * n, UXView * content, i32 depth) = &delegate.formWillShow;
            if (f)
                {
                f(self, c, d);
                }
            }
        }
    void notifyHide(UXView* c, i32 d)
        {
        if (delegate != (UXNavigationDelegate*)0)
            {
            callback f void(UXNavigationController * n, UXView * content, i32 depth) = &delegate.formDidHide;
            if (f)
                {
                f(self, c, d);
                }
            }
        }

    // ---- the drawn bar (the neutral fallback realization) -------------------
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        i16 bh = self.barHeight();
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, bh), (i32)8);                 // the bar ground
        g.fillRect(UXGeom.make((i16)0, (i16)(bh - (i16)1), b.w, (i16)1), (i32)9); // hairline
        i16 ty = (i16)(((i32)bh - (i32)12) / (i32)2);
        if (self.canGoBack())
            {
            // chevron ‹ + where back goes
            i16 cy = (i16)((i32)bh / (i32)2);
            g.fillTriangle((i16)10, cy, (i16)17, (i16)(cy - (i16)6), (i16)17, (i16)(cy + (i16)6), (i32)1);
            g.drawText(self.backTitle(), (i16)22, ty, (i32)1, (i32)0);
            }
        // the current title, centred by estimate (the drawn bar has no measurer)
        u8* t = self.topTitle();
        i32 n = (i32)0;
        while (t[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        i16 tx = (i16)(((i32)b.w - n * (i32)7) / (i32)2);
        if (tx < (i16)90)
            {
            tx = (i16)90;
            }
        g.drawText(t, tx, ty, (i32)1, (i32)0);
        }

    // A tap in the bar's back zone pops; everything else falls through to the
    // visible content by ordinary tree hit-testing.
    void mouseDown(UXEvent* e)
        {
        if ((i32)e.y < (i32)self.barHeight() && self.canGoBack() && (i32)e.x < (i32)90)
            {
            self.pop();
            return;
            }
        }
    }
