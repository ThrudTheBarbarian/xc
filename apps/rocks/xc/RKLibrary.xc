// RKLibrary.xc — the object library: what can be added to a form, searchable by name.
//
// Interface Builder's library.  Picking a control arms the canvas: the next press there places
// it, inside whatever box it lands in.  Picking Object adds one of the document's objects (IB's
// Object, given a class in the Identity inspector), which has no place on the canvas.
#import "Array.xc"
#import "UXTableView.xc"
#import "UXRscModel.xc"

#define RKLIB_OBJECT -1 // the `type` of the Object entry: not a control

class RKLibraryItem : Object
    {
    u8* name;
    u8* blurb; // one line: what it is for
    i32 type;  // a UXR_T_* type, or RKLIB_OBJECT
    i32 w;
    i32 h;
    u8* text;  // the new control's text, or 0
    u8* cls;   // a UXKit class for a control GEM has no type for (a G_USERDEF of it), or 0
    u8* attrs; // its starting attributes, "key=value;key=value", or 0

    static RKLibraryItem* make(u8* name, i32 type, i32 w, i32 h, u8* text, u8* blurb)
        {
        RKLibraryItem* it = new RKLibraryItem();
        it.name = name;
        it.type = type;
        it.w = w;
        it.h = h;
        it.text = text;
        it.blurb = blurb;
        it.cls = (u8*)0;
        it.attrs = (u8*)0;
        return it;
        }
    static RKLibraryItem* uxkit(u8* name, u8* cls, i32 w, i32 h, u8* attrs, u8* blurb)
        {
        RKLibraryItem* it = RKLibraryItem.make(name, (i32)UXR_T_USERDEF, w, h, (u8*)0, blurb);
        it.cls = cls;
        it.attrs = attrs;
        return it;
        }
    }

class RKLibrary : Object<UXTableDataSource>
    {
    Array<RKLibraryItem>* all;
    Array<RKLibraryItem>* shown; // after the search filter
    u8* filter;

    void init(void)
        {
        all = new Array();
        shown = new Array();
        filter = (u8*)"";
        all.add(RKLibraryItem.make((u8*)"Button", (i32)UXR_T_BUTTON, (i32)80, (i32)24, (u8*)"Button", (u8*)"Fires an action when clicked"));
        all.add(RKLibraryItem.make((u8*)"Label", (i32)UXR_T_STRING, (i32)120, (i32)20, (u8*)"Label", (u8*)"A line of text"));
        all.add(RKLibraryItem.make((u8*)"Text Field", (i32)UXR_T_FIELD, (i32)160, (i32)24, (u8*)"", (u8*)"A line of text to edit"));
        all.add(RKLibraryItem.make((u8*)"Checkbox", (i32)UXR_T_CHECKBOX, (i32)120, (i32)20, (u8*)"Checkbox", (u8*)"On or off"));
        all.add(RKLibraryItem.make((u8*)"Radio Button", (i32)UXR_T_RADIO, (i32)120, (i32)20, (u8*)"Radio", (u8*)"One of a group"));
        all.add(RKLibraryItem.make((u8*)"Pop-up Button", (i32)UXR_T_POPUP, (i32)120, (i32)24, (u8*)"Item", (u8*)"One of a list"));
        all.add(RKLibraryItem.uxkit((u8*)"Slider", (u8*)"UXSlider", (i32)160, (i32)24, (u8*)"min=0;max=100;value=50", (u8*)"A value along a range"));
        all.add(RKLibraryItem.uxkit((u8*)"Stepper", (u8*)"UXStepper", (i32)100, (i32)24, (u8*)"min=0;max=10;step=1;value=0", (u8*)"A value, a step at a time"));
        all.add(RKLibraryItem.uxkit((u8*)"Progress Bar", (u8*)"UXProgressBar", (i32)160, (i32)16, (u8*)"total=100;completed=40", (u8*)"How far something has got"));
        all.add(RKLibraryItem.uxkit((u8*)"Segmented Control", (u8*)"UXSegmentedControl", (i32)200, (i32)24, (u8*)"segments=One|Two|Three;selected=0", (u8*)"One of a few, side by side"));
        all.add(RKLibraryItem.uxkit((u8*)"Combo Box", (u8*)"UXComboBox", (i32)160, (i32)24, (u8*)"items=Red|Green|Blue;text=Red", (u8*)"A line of text, or one of a list"));
        all.add(RKLibraryItem.uxkit((u8*)"Text View", (u8*)"UXTextView", (i32)240, (i32)120, (u8*)"text=", (u8*)"Several lines of text to edit"));
        all.add(RKLibraryItem.uxkit((u8*)"Date Picker", (u8*)"UXDatePicker", (i32)140, (i32)24, (u8*)"date=", (u8*)"A day of the year"));
        all.add(RKLibraryItem.uxkit((u8*)"Breadcrumb", (u8*)"UXBreadcrumb", (i32)240, (i32)24, (u8*)"segments=Home|Documents|Work", (u8*)"Where you are, one level a step"));
        all.add(RKLibraryItem.uxkit((u8*)"Table View", (u8*)"UXTableView", (i32)240, (i32)120, (u8*)"columns=Name:120|Size:60", (u8*)"Rows and columns of data"));
        all.add(RKLibraryItem.uxkit((u8*)"Outline View", (u8*)"UXOutlineView", (i32)240, (i32)120, (u8*)"columns=Name:160", (u8*)"A tree, one row a level"));
        all.add(RKLibraryItem.uxkit((u8*)"Collection View", (u8*)"UXCollectionView", (i32)240, (i32)160, (u8*)"items=One|Two|Three|Four;itemSize=56;spacing=12", (u8*)"A grid of items"));
        all.add(RKLibraryItem.uxkit((u8*)"Scroll View", (u8*)"UXScrollView", (i32)200, (i32)140, (u8*)"lineHeight=16", (u8*)"A viewport that scrolls its content"));
        all.add(RKLibraryItem.uxkit((u8*)"Split View", (u8*)"UXSplitView", (i32)240, (i32)160, (u8*)"vertical=0;divider=100", (u8*)"Two panes with a draggable divider"));
        all.add(RKLibraryItem.uxkit((u8*)"Tab View", (u8*)"UXTabView", (i32)240, (i32)160, (u8*)"tabs=One|Two|Three", (u8*)"A strip of tabs, each with its own content"));
        all.add(RKLibraryItem.uxkit((u8*)"Navigation View", (u8*)"UXNavigationView", (i32)520, (i32)320, (u8*)"panes=2", (u8*)"A sequence of panes, shown side by side"));
        all.add(RKLibraryItem.make((u8*)"Group Box", (i32)UXR_T_BOX, (i32)200, (i32)120, (u8*)0, (u8*)"Groups controls under a frame"));
        all.add(RKLibraryItem.make((u8*)"View", (i32)UXR_T_IBOX, (i32)200, (i32)120, (u8*)0, (u8*)"Groups controls, unseen"));
        all.add(RKLibraryItem.make((u8*)"Custom View", (i32)UXR_T_USERDEF, (i32)200, (i32)120, (u8*)0, (u8*)"A view of a class you name"));
        all.add(RKLibraryItem.make((u8*)"Object", (i32)RKLIB_OBJECT, (i32)0, (i32)0, (u8*)0, (u8*)"An object of a class you name: a controller"));
        self.refilter();
        }

    // Show only the items whose name contains `s`, ignoring case.
    void setFilter(u8* s)
        {
        filter = s != (u8*)0 ? s : (u8*)"";
        self.refilter();
        }
    void refilter(void)
        {
        shown = new Array();
        for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
            {
            RKLibraryItem* it = (RKLibraryItem* ?)all.get(i);
            if (RKLibrary.contains(it.name, filter))
                {
                shown.add(it);
                }
            }
        }
    i32 count(void)
        {
        return (i32)shown.count();
        }
    RKLibraryItem* itemAt(i32 row)
        {
        if (row < (i32)0 || row >= (i32)shown.count())
            {
            return (RKLibraryItem*)0;
            }
        return (RKLibraryItem* ?)shown.get((u32)row);
        }
    RKLibraryItem* named(u8* name)
        {
        for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
            {
            RKLibraryItem* it = (RKLibraryItem* ?)all.get(i);
            if (RKLibrary.contains(it.name, name) && UXRscTree.len(it.name) == UXRscTree.len(name))
                {
                return it;
                }
            }
        return (RKLibraryItem*)0;
        }

    // ---- UXTableDataSource -------------------------------------------------------------------
    i32 numberOfRows(UXTableView* t)
        {
        return (i32)shown.count();
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        RKLibraryItem* it = self.itemAt(row);
        if (it == (RKLibraryItem*)0)
            {
            return (u8*)"";
            }
        return col == (i32)0 ? it.name : it.blurb;
        }

    static u8 lower(u8 c)
        {
        return c >= (u8)'A' && c <= (u8)'Z' ? (u8)(c + (u8)32) : c;
        }
    static bool contains(u8* hay, u8* needle)
        {
        if (needle[0] == (u8)0)
            {
            return true;
            }
        for (i32 i = (i32)0; hay[i] != (u8)0; i = i + (i32)1)
            {
            i32 j = (i32)0;
            while (needle[j] != (u8)0 && hay[i + j] != (u8)0 && RKLibrary.lower(hay[i + j]) == RKLibrary.lower(needle[j]))
                {
                j = j + (i32)1;
                }
            if (needle[j] == (u8)0)
                {
                return true;
                }
            }
        return false;
        }
    }
