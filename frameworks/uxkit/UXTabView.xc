// UXTabView.xc — a tabbed panel (NSTabView in shape).
//
// A set of tabs, each a label + a content view; selecting a tab shows its content and hides the
// others.  The tab strip is naturally an UXSegmentedControl (the picker) sitting above the content
// area.  The tab MODEL — which tab is selected, its label and content — is pure and unit-testable;
// applying the visibility (setHidden on the content views) needs a live window, so it runs in
// layoutTabs() when the view tree exists.
#import "UXView.xc"
#import "UXControl.xc"
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
    void init(void)
        {
        super.init();
        tabs = new Array();
        selected = (i32)0;
        }

    void addTab(u8* label, UXView* content)
        {
        UXTab* t = new UXTab();
        t.label = label;
        t.content = content;
        tabs.add(t);
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
    }
