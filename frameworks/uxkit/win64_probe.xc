// win64_probe.xc — proves the neutral view/widget layer compiles for win64.
//
// Not a runnable program (there is no win64 UXViewDriver yet, so gDriver is null and the
// ops would fault) — it is a COMPILE gate: it imports the whole widget stack and instantiates
// each class, so if anyone reintroduces a GEM type / <GEM> import / GEM constant into the
// neutral layer, `xtc -A win64` stops building this and `make win64-lib` goes red.
//
//   make win64-lib      (xtc -A win64; skips if the win64 toolchain is absent)
//
// What it proves portable today: UXView, UXControl (UXButton/UXTextField), UXTableView,
// UXOutlineView, UXViewTree, UXWindow, UXResponder, UXGeometry, UXGraphics (protocol),
// UXEvent, UXMenu, and now UXApplication — the ENTIRE neutral toolkit including the run
// loop + event decode, driven entirely through UXViewDriver.  Nothing above the driver
// names a GEM type any more; the backend is injected (setDriver / the gDriver global).
#import "UXControl.xc"
#import "UXTableView.xc"
#import "UXOutlineView.xc"
#import "UXWindow.xc"
#import "UXApplication.xc"
#import "UXMenu.xc"
#import "UXAlert.xc"

class ProbeView : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(self.bounds(), (i32)1);
        }
    }

    void
    main(void)
    {
    ProbeView* v = new ProbeView();
    UXButton* b = new UXButton();
    b.setTitle("ok");
    UXLabel* lbl = new UXLabel();
    lbl.setText("Name:");
    UXCheckbox* cb = new UXCheckbox();
    cb.setTitle("on");
    cb.setChecked(true);
    UXTextField* f = new UXTextField();
    f.setText("x");
    UXTableView* t = new UXTableView();
    t.addColumn("A", (i16)80);
    UXOutlineView* o = new UXOutlineView();
    UXWindow* w = new UXWindow();
    w.setDefaultButton(b);
    UXApplication* a = new UXApplication();
    a.stop(); // the run loop compiles for win64 too
    UXMenuBar* mb = new UXMenuBar();
    mb.addMenu("File");
    UXAlert* al = new UXAlert();
    al.addLine("hi");
    al.addButton("OK");
    v.setNeedsDisplay(); // exercises the neutral geometry/damage path
    }
