// UXTabView.xc — a tabbed panel (NSTabView in shape).
//
// A set of tabs, each a label + a content view; selecting a tab shows its content and hides the
// others.  The tab strip is naturally an UXSegmentedControl (the picker) sitting above the content
// area.  The tab MODEL — which tab is selected, its label and content — is pure and unit-testable;
// applying the visibility (setHidden on the content views) needs a live window, so it runs in
// layoutTabs() when the view tree exists.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXSegmentedControl.xc"
#import "UXGeometry.xc"

class UXTab : Object
    {
    u8* label;
    UXView* content;
    void init(void)
        {
        label = (u8*)"";
        content = (UXView*)0;
        }
    }

    class UXTabView : UXView
    {
    Array<UXTab>* tabs;
    i32 selected;
    UXSegmentedControl* strip; // the picker across the top
    i16 stripH;                // its height; the content sits below it
    void init(void)
        {
        super.init();
        tabs = new Array();
        selected = (i32)0;
        strip = (UXSegmentedControl*)0;
        stripH = (i16)20;
        }

    void addTab(u8* label, UXView* content)
        {
        UXTab* t = new UXTab();
        t.label = label;
        t.content = content;
        tabs.add(t);
        if (owner != (UXViewTree*)0) // already in a tree: bring the content in now
            {
            if (strip != (UXSegmentedControl*)0)
                {
                strip.addSegment(label, self.count() - (i32)1);
                strip.applyNativeSelection(selected);
                }
            self.mount(t);
            self.relayout();
            }
        }
    i32 count(void)
        {
        return (i32)tabs.count();
        }
    UXTab* tabAt(i32 i)
        { return (UXTab* ?)tabs.get((u16)i);
        }
    u8* labelAt(i32 i)
        {
        return self.tabAt(i).label;
        }
    UXView* contentAt(i32 i)
        {
        return self.tabAt(i).content;
        }

    void selectTab(i32 i)
        {
        if (i >= (i32)0 && i < self.count())
            {
            selected = i;
            }
        }
    i32 selectedIndex(void)
        {
        return selected;
        }
    u8* selectedLabel(void)
        {
        return self.count() > (i32)0 ? self.labelAt(selected) : (u8*)"";
        }
    UXView* selectedContent(void)
        {
        return self.count() > (i32)0 ? self.contentAt(selected) : (UXView*)0;
        }
    bool isTabVisible(i32 i)
        {
        return i == selected;
        }

    // Apply the model to the view tree: only the selected tab's content is shown.  Safe to call only
    // once the content views have been added to a window (setHidden needs an owner).
    void layoutTabs(void)
        {
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            UXView* c = self.contentAt(i);
            if (c != (UXView*)0)
                {
                c.setHidden(i != selected);
                }
            }
        }

    // ---- the view ---------------------------------------------------------
    // The tab view draws nothing of its own: it is a segmented strip across the top and the tab
    // contents stacked below it, only the selected one showing.  The parts are built on attach.
    UXKind kind(void)
        {
        return UXKindView;
        }
    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        strip = new UXSegmentedControl();
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            strip.addSegment(self.labelAt(i), i);
            }
        strip.setAction(&self.onStrip);
        self.addSubview(strip, UXGeom.make((i16)0, (i16)0, frame.w, stripH));
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            self.mount(self.tabAt(i));
            }
        strip.applyNativeSelection(selected);
        self.relayout();
        }
    // Bring one tab's content into the tree, if it is not in it already.
    void mount(UXTab* t)
        {
        if (t != (UXTab*)0 && t.content != (UXView*)0 && t.content.superview != self)
            {
            UXRect b = self.bounds();
            self.addSubview(t.content, UXGeom.make((i16)0, stripH, b.w, (i16)(b.h - stripH)));
            }
        }
    // The strip was clicked: show that tab.
    void onStrip(UXControl* s)
        {
        if (strip != (UXSegmentedControl*)0)
            {
            self.selectTab(strip.selectedSegment());
            self.layoutTabs();
            self.setNeedsDisplay();
            }
        }
    // Place the strip and the contents for the current size.
    void relayout(void)
        {
        UXRect b = self.bounds();
        if (strip != (UXSegmentedControl*)0)
            {
            strip.setFrame(UXGeom.make((i16)0, (i16)0, b.w, stripH));
            }
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            UXView* c = self.contentAt(i);
            if (c != (UXView*)0)
                {
                c.setFrame(UXGeom.make((i16)0, stripH, b.w, (i16)(b.h - stripH)));
                }
            }
        self.layoutTabs();
        }
    void resizeSubviews(i32 oldW, i32 oldH, i32 newW, i32 newH)
        {
        super.resizeSubviews(oldW, oldH, newW, newH);
        self.relayout();
        }
    }
