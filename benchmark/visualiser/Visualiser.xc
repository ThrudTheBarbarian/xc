// Visualiser.xc — read a benchmark contribution, draw it, and move it to and
// from the project's corpus.
//
// The screen is three parts.  A filter rail on the left chooses which runs are
// drawn (CPU, GPU, suite, device, optimisation level).  The chart in the middle
// is one horizontal bar per run in the Phoronix manner: a bar for the value, an
// error bar for one standard deviation over the repeats, and the run's own
// parameters under its label.  A table along the bottom spells every filtered
// run out: benchmark, series, level, best time, spread and the exact parameters.
//
//   visualiser                                  open empty; use File ▸ Open
//   visualiser results.json                     open one contribution
//   visualiser --selftest results.json          check the model head-less and quit
//
// Built against the UXKit sources (see the Makefile): the app needs JSON, Http
// and Socket beside the toolkit, and the toolkit's library and those modules
// each declare the Foundation classes, so they are compiled together here.

#import <Stdio.xc>
#import "JSON.xc"
#import "Model.xc"
#import "Chart.xc"
#import "Net.xc"
#import "UXPlatform.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXTableView.xc"
#import "UXScrollView.xc"
#import "UXPopUpButton.xc"
#import "UXMenu.xc"
#import "UXOpenPanel.xc"

// A filter field: a drawn box that shows its value and opens the toolkit's own
// menu of choices on a click.  It is drawn and driven here, so the choices can
// be replaced whenever data is loaded — a native popup builds its menu once, at
// realization, and cannot be refilled afterwards.
class PickView : UXView
    {
    Controller* controller;
    i32         field;      // 0 cpu, 1 gpu, 2 suite, 3 opt, 4 device, 5 view, 6 arch, 7 baseline
    String*     current;    // the chosen value, or null for Any
    String*     anyText;    // what null is called: "Any", or "Fastest" for the baseline
    Array*      values;     // the choices, held so the menu titles stay valid
    i32         winHandle;

    void init(void)
        {
        controller = (Controller*)0;
        field = 0;
        current = (String*)0;
        values = new Array();
        winHandle = 0;
        anyText = String.withCString("Any");
        }

    void setValues(Array* v)
        {
        values = v;
        current = (String*)0;
        self.setNeedsDisplay();
        }

    String* selected(void) { return current; }

    void setCurrent(String* v) { current = v; self.setNeedsDisplay(); }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        UXPainter.fillRoundRectRGB(g, b, 4, 178, 182, 190);
        UXRect inner = UXGeom.make(b.x + 1, b.y + 1,
                                   b.w - 2, b.h - 2);
        UXPainter.fillRoundRectRGB(g, inner, 3, 255, 255, 255);
        String* shown = current == (String*)0 ? anyText : current;
        g.drawTextRGBA(shown.cString(), 8, (b.h - 14) / 2, 30, 30, 34, 255, 12);
        i16 tri[6];
        i32 cx = b.w - 14;
        i32 cy = b.h / 2 - 2;
        tri[0] = cx;        tri[1] = cy;
        tri[2] = cx + 8;  tri[3] = cy;
        tri[4] = cx + 4;  tri[5] = cy + 5;
        g.fillPolygonRGBA(&tri[0], 3, 90, 94, 102, 255);
        }

    void mouseDown(UXEvent* e) { self.openMenu(); }

    void openMenu(void)
        {
        if (winHandle == 0 || controller == (Controller*)0) { return; }
        UXMenu* m = new UXMenu();
        m.addItem(anyText.cString(), &self.onPick);
        for (u32 i = 0; i < values.count(); i++)
            {
            m.addItem(((String*)values.get(i)).cString(), &self.onPick);
            }
        UXRect a = self.absoluteFrame();
        m.popUp(winHandle, a.x, a.y + a.h);
        }

    void onPick(UXMenuItem* sender)
        {
        String* picked = (String*)0;
        if (sender != (UXMenuItem*)0 && sender.title != (u8*)0
            && !String.withCString(sender.title).equalsIgnoringCase(anyText))
            {
            picked = String.withCString(sender.title);
            }
        current = picked;
        self.setNeedsDisplay();
        controller.applyPick(field, picked);
        }
    }

// A pane of the rail: a titled card the controls sit inside, so the rail
// reads as three parts (data, filters, publishing) and not one long column.
class PaneView : UXView
    {
    u8* title;

    void init(void)
        {
        super.init();
        title = (u8*)"";
        }

    static i32 TitleH(void) { return 24; }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        UXPainter.fillRoundRectRGB(g, b, 7, 206, 209, 217);
        UXRect inner = UXGeom.make(b.x + 1, b.y + 1,
                                   b.w - 2, b.h - 2);
        UXPainter.fillRoundRectRGB(g, inner, 6, 248, 249, 251);
        g.drawTextRGBA(title, 10, 6, 90, 94, 104, 255, 11);
        }
    }

class Controller : Object <UXApplicationDelegate, UXTableDataSource>
    {
    DataSet*   data;
    Filter*    filter;
    ChartView* chart;
    UXScrollView* chartScroll;
    UXTableView* table;
    PickView*      cpuPick;
    PickView*      gpuPick;
    PickView*      suitePick;
    PickView*      devicePick;
    PickView*      optPick;
    PickView*      archPick;
    PickView*      viewPick;   // per-benchmark rows, the summary grid or the heat map
    PickView*      basePick;   // the heat map's baseline series
    UXPopUpButton* metricPop;
    UXCheckbox*    firstRun;
    UXCheckbox*    consent;
    UXLabel*       status;
    UXWindow*  win;           // the window, to force a full display after a load
    Array*     visible;       // ChartRow currently shown, for the table
    Contribution* own;        // the last xc-bench contribution opened from disk: what Submit sends
    String*    statusText;    // the status label stores the pointer it is given
    i32        exitCode;
    bool       populating;   // true while the filter popups are refilled
    bool       selfTest;
    String*    selfFile;

    void init(void)
        {
        data = new DataSet();
        filter = new Filter();
        win = (UXWindow*)0;
        visible = new Array();
        own = (Contribution*)0;
        statusText = (String*)0;
        exitCode = 0;
        populating = false;
        selfTest = false;
        selfFile = (String*)0;
        }

    // ---- data -----------------------------------------------------------

    void loadFile(String* path)
        {
        Array* cs = Contribution.loadAll(path);
        if (cs.count() == 0)
            {
            say(String.withFormat((string)"Could not read %s: not a contribution, "
                                  "a run.py results.json or a par results.json",
                                  path.lastPathComponent().cString()));
            return;
            }
        i32 runs = 0;
        for (u32 i = 0; i < cs.count(); i++)
            {
            Contribution* c = (Contribution*)cs.get(i);
            data.add(c);
            runs += c.runs.count();
            if (c.schema != (String*)0 && c.schema.equalsIgnoringCase(BHelp.S((u8*)"xc-bench/1")))
                {
                own = c;
                }
            }
        rebuild(true);
        say(String.withFormat("Opened %s (%d runs)", path.lastPathComponent().cString(), runs));
        }

    // Merge a corpus response: {"contributions":[ {...}, ... ],
    // "published":[ results.json, ... ]}.  The published files are the
    // project's own measurements, so the window has something to show even
    // before anyone has submitted a run.
    void mergeCorpus(String* text)
        {
        if (text == (String*)0)
            {
            say(String.withFormat("Could not read the corpus: %s", Net.lastError().cString()));
            return;
            }
        Array* cs = Contribution.loadText(text, BHelp.S((u8*)"corpus"));
        if (cs.count() == 0)
            {
            say(BHelp.S((u8*)"The corpus had no contributions."));
            return;
            }
        i32 runs = 0;
        for (u32 i = 0; i < cs.count(); i++)
            {
            Contribution* c = (Contribution*)cs.get(i);
            data.add(c);
            runs += c.runs.count();
            }
        rebuild(true);
        say(String.withFormat("Downloaded %d runs in %d result sets.", runs, (i32)cs.count()));
        }

    // ---- the filter -----------------------------------------------------

    void syncFilter(void)
        {
        if (populating) { return; }
        filter.cpu = cpuPick == (PickView*)0 ? (String*)0 : cpuPick.selected();
        filter.gpu = gpuPick == (PickView*)0 ? (String*)0 : gpuPick.selected();
        filter.suite = suitePick == (PickView*)0 ? (String*)0 : suitePick.selected();
        filter.device = devicePick == (PickView*)0 ? (String*)0 : devicePick.selected();
        filter.opt = optPick == (PickView*)0 ? (String*)0 : optPick.selected();
        filter.arch = archPick == (PickView*)0 ? (String*)0 : archPick.selected();
        rebuild(false);
        }

    void onFilter(UXControl* sender) { syncFilter(); }

    void onFirstRun(UXControl* sender)
        {
        if (populating) { return; }
        chart.setUseFirst(firstRun.isChecked());
        rebuild(false);
        }

    void onMetric(UXControl* sender)
        {
        if (populating) { return; }
        chart.setMetric(metricPop.selectedIndex());
        rebuild(false);
        }

    // ---- the table ------------------------------------------------------

    i32 numberOfRows(UXTableView* t) { return visible.count(); }

    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (row < 0 || row >= visible.count()) { return (u8*)""; }
        ChartRow* r = (ChartRow*)visible.get(row);
        if (col == 0) { return r.group.cString(); }
        if (col == 1) { return r.label.cString(); }
        if (col == 2) { return r.bestText == (String*)0 ? (u8*)"" : r.bestText.cString(); }
        if (col == 3) { return r.spreadText == (String*)0 ? (u8*)"" : r.spreadText.cString(); }
        if (col == 4) { return r.machineText == (String*)0 ? (u8*)"" : r.machineText.cString(); }
        return r.params != (String*)0 ? r.params.cString() : (u8*)"";
        }

    // ---- actions --------------------------------------------------------

    void onOpen(UXMenuItem* sender)
        {
        u8* p = UXOpenPanel.run((u8*)"Open a contribution", (u8*)".");
        if (p != (u8*)0) { loadFile(String.withCString(p)); }
        }

    void onDownload(UXMenuItem* sender)
        {
        say(BHelp.S((u8*)"Fetching the corpus..."));
        mergeCorpus(Net.get(Net.corpusUrl()));
        }

    void onSubmit(UXMenuItem* sender)
        {
        if (!consent.isChecked())
            {
            say(BHelp.S((u8*)"Tick \"I agree to publish this run\" before submitting."));
            return;
            }
        // Only a contribution opened from this machine is sent: never one
        // that came down from the corpus, and never a published results file.
        if (own == (Contribution*)0 || own.root == (Map*)0)
            {
            say(BHelp.S((u8*)"Nothing to submit: open your own xc-bench JSON first (diy.py writes it)."));
            return;
            }
        String* body = (String*)0;
        try
            {
            body = JSON.stringify(own.root);
            }
        catch (e)
            {
            say(BHelp.S((u8*)"The contribution could not be serialised."));
            return;
            }
        say(BHelp.S((u8*)"Submitting..."));
        HttpResponse* r = Net.post(Net.submitUrl(), body);
        if (r == (HttpResponse*)0)
            {
            say(String.withFormat("Submit failed: %s", Net.lastError().cString()));
            return;
            }
        // The server answers JSON: {"ok":true,"id":...,"count":N} or
        // {"ok":false,"error":...}.
        Map* reply = (Map*)0;
        try
            {
            reply = (Map* ?)JSON.parse(r.bodyString());
            }
        catch (e)
            {
            reply = (Map*)0;
            }
        if (r.status() == 200 && reply != (Map*)0)
            {
            String* id = BHelp.field(reply, (u8*)"id");
            say(String.withFormat("Submitted as %s; the corpus holds %lld contribution(s).",
                                  id == (String*)0 ? (u8*)"?" : id.cString(),
                                  BHelp.intField(reply, (u8*)"count", 0)));
            return;
            }
        String* why = reply == (Map*)0 ? (String*)0 : BHelp.field(reply, (u8*)"error");
        say(String.withFormat("The server refused the run (%d): %s", (i32)r.status(),
                              why == (String*)0 ? (u8*)"no reason given" : why.cString()));
        }

    // ---- the screen -----------------------------------------------------

    void say(String* s)
        {
        // The label keeps the pointer, so the string is held here.
        statusText = s;
        if (status != (String*)0) { status.setText(statusText.cString()); }
        // Shown now, not at the next event: a download blocks until it is done,
        // so "Fetching..." has to be on screen before it starts.
        if (win != (UXWindow*)0) { win.displayAll(); }
        Stdio.printf("%s\n", s.cString());
        }

    void rebuild(bool reloadLists)
        {
        if (chart == (ChartView*)0) { return; }
        if (reloadLists)
            {
            // New data: start from "Any" everywhere, so the shown filters and
            // the filter actually applied agree.  Refilling the popups fires
            // their callbacks, so they are muted while it happens.
            populating = true;
            filter.cpu = filter.gpu = filter.suite = filter.device = filter.opt = filter.arch = (String*)0;
            chart.baseline = (String*)0;
            fillLists();
            populating = false;
            }
        chart.setFilter(filter);   // rebuilds the chart's rows from the data
        visible.removeAll();
        Array* cr = chart.visibleRows();
        for (u32 i = 0; i < cr.count(); i++)
            {
            visible.add(cr.get(i));
            }
        if (chartScroll != (UXScrollView*)0)
            {
            chart.setFrame(UXGeom.make(0, 0, chartScroll.document().bounds().w, chart.height()));
            chartScroll.setDocumentHeight(chart.height());
            }
        if (table != (UXTableView*)0) { table.reloadData(); }
        if (chart != (ChartView*)0) { chart.setNeedsDisplay(); }
        if (win != (UXWindow*)0) { win.displayAll(); }
        }

    // The first item is "Any"; the rest are the distinct values in the data.
    void fillLists(void)
        {
        cpuPick.setValues(distinct(BHelp.S((u8*)"cpu")));
        gpuPick.setValues(distinct(BHelp.S((u8*)"gpu")));
        suitePick.setValues(distinct(BHelp.S((u8*)"suite")));
        devicePick.setValues(deviceChoices());
        optPick.setValues(distinct(BHelp.S((u8*)"opt")));
        archPick.setValues(distinct(BHelp.S((u8*)"arch")));
        basePick.setValues(distinct(BHelp.S((u8*)"series")));
        }

    // Distinct non-empty values of one field across the whole data set.
    Array* distinct(String* what)
        {
        Array* out = new Array();
        Array* runs = data.runs();
        for (u32 i = 0; i < runs.count(); i++)
            {
            Run* r = (Run*)runs.get(i);
            Contribution* c = ownerOf(r);
            String* v = (String*)0;
            if (what.equalsIgnoringCase(BHelp.S((u8*)"cpu")))       { v = c.machine.cpu; }
            else if (what.equalsIgnoringCase(BHelp.S((u8*)"gpu")))  { v = c.machine.gpu; }
            else if (what.equalsIgnoringCase(BHelp.S((u8*)"suite"))){ v = r.suite; }
            else if (what.equalsIgnoringCase(BHelp.S((u8*)"opt")))  { v = r.opt; }
            else if (what.equalsIgnoringCase(BHelp.S((u8*)"arch"))) { v = r.arch; }
            else if (what.equalsIgnoringCase(BHelp.S((u8*)"series"))) { v = ChartView.seriesName(r); }
            if (v == (String*)0 || v.isEmpty()) { continue; }
            bool seen = false;
            for (u32 j = 0; j < out.count(); j++)
                {
                if (((String*)out.get(j)).equalsIgnoringCase(v)) { seen = true; break; }
                }
            if (!seen) { out.add(v); }
            }
        return out;
        }

    Contribution* ownerOf(Run* want)
        {
        for (u32 i = 0; i < data.contributions.count(); i++)
            {
            Contribution* c = (Contribution*)data.contributions.get(i);
            for (u32 j = 0; j < c.runs.count(); j++)
                {
                if (c.runs.get(j) == (Object*)want) { return c; }
                }
            }
        return data.at(0);
        }

    // The Device filter offers only what the data holds: the friendly name of
    // each device present, plus "CPU only"/"GPU only" when both kinds are
    // present.  A run whose device is absent (Vulkan in a CPU-only file) is
    // therefore not offered, so it can never select nothing.
    static String* friendlyDevice(String* d)
        {
        if (d == (String*)0) { return (String*)0; }
        if (d.equalsIgnoringCase(BHelp.S((u8*)"serial"))) { return BHelp.S((u8*)"one thread"); }
        if (d.equalsIgnoringCase(BHelp.S((u8*)"cpu")))    { return BHelp.S((u8*)"all threads"); }
        if (d.equalsIgnoringCase(BHelp.S((u8*)"gpu")))    { return BHelp.S((u8*)"GPU"); }
        if (d.equalsIgnoringCase(BHelp.S((u8*)"vulkan"))) { return BHelp.S((u8*)"Vulkan"); }
        return d;
        }

    Array* deviceChoices(void)
        {
        Array* out = new Array();
        Array* runs = data.runs();
        bool anyGpu = false;
        bool anyCpu = false;
        for (u32 i = 0; i < runs.count(); i++)
            {
            Run* r = (Run*)runs.get(i);
            if (r.isGpu()) { anyGpu = true; } else { anyCpu = true; }
            String* label = friendlyDevice(r.device);
            if (label == (String*)0 || label.isEmpty()) { continue; }
            bool seen = false;
            for (u32 j = 0; j < out.count(); j++)
                {
                if (((String*)out.get(j)).equalsIgnoringCase(label)) { seen = true; break; }
                }
            if (!seen) { out.add(label); }
            }
        if (anyCpu) { out.add(BHelp.S((u8*)"CPU only")); }
        if (anyGpu) { out.add(BHelp.S((u8*)"GPU only")); }
        return out;
        }

    static Array* viewChoices(void)
        {
        Array* a = new Array();
        a.add(BHelp.S((u8*)"Per benchmark"));
        a.add(BHelp.S((u8*)"Summary"));
        a.add(BHelp.S((u8*)"Heat map"));
        return a;
        }

    // A filter pick, the view pick or the baseline pick.  The view switches
    // the chart between the per-benchmark rows, the summary grid and the heat
    // map; the baseline is what the heat map divides by.
    void applyPick(i32 field, String* value)
        {
        if (field == 5)
            {
            i32 m = 0;
            if (value != (String*)0 && value.equalsIgnoringCase(BHelp.S((u8*)"Summary")))  { m = 1; }
            if (value != (String*)0 && value.equalsIgnoringCase(BHelp.S((u8*)"Heat map"))) { m = 2; }
            chart.setMode(m);
            rebuild(false);
            return;
            }
        if (field == 7)
            {
            chart.setBaseline(value);
            rebuild(false);
            return;
            }
        syncFilter();
        }

    UXMenuBar* buildMenu(void)
        {
        UXMenuBar* bar = new UXMenuBar();
        UXMenu* file = bar.addMenu((u8*)"File");
        file.addItem((u8*)"Open a contribution...", &self.onOpen);
        file.addItem((u8*)"Download contributions", &self.onDownload);
        file.addSeparator();
        file.addItem((u8*)"Submit to the corpus", &self.onSubmit);
        return bar;
        }

    i32 applicationDidStart(UXApplication* app)
        {
        UXView* content = new UXView();
        win = new UXWindow();
        app.addWindow(win);
        win.open((u8*)"xc benchmark visualiser", UXGeom.make(40, 40, 1100, 720), content);
        app.setMenuBar(buildMenu());

        i32 railW = 250;
        i32 bottomH = 170;
        i32 winW = 1100;
        i32 winH = 720;
        i32 chartX = railW + 8;
        i32 chartW = winW - chartX - 8;
        i32 chartH = winH - bottomH - 16;

        // ---- the rail: three panes ----
        // Data at the top (open and download), the filters in the middle, and
        // publishing at the bottom, kept apart from the rest.  What happened is
        // reported in the status line under the table, which has the width.
        UXView* rail = new UXView();
        rail.setAutoresizeMask(UX_ANCHOR_LEFT | UX_ANCHOR_TOP | UX_FLEX_HEIGHT);
        content.addSubview(rail, UXGeom.make(0, 0, railW, winH));
        i32 paneW = railW - 16;
        i32 cw = paneW - 20;   // a control's width inside a pane

        UXView* dataPane = pane(rail, (u8*)"Data", 8, 60, UX_ANCHOR_LEFT | UX_ANCHOR_TOP);
        i32 y = PaneView.TitleH();
        UXButton* open = new UXButton();
        open.setTitle((u8*)"Open JSON...");
        open.setAction(&self.onOpenControl);
        dataPane.addSubview(open, UXGeom.make(10, y, (cw - 6) / 2, 24));
        UXButton* dl = new UXButton();
        dl.setTitle((u8*)"Download");
        dl.setAction(&self.onDownloadControl);
        dataPane.addSubview(dl, UXGeom.make(10 + (cw + 6) / 2, y, (cw - 6) / 2, 24));

        UXView* filters = pane(rail, (u8*)"Filters and view", 76, 466, UX_ANCHOR_LEFT | UX_ANCHOR_TOP);
        y = PaneView.TitleH();
        label(filters, (u8*)"CPU", 10, y); y += 16;
        cpuPick = pick(filters, 10, y, cw, 0); y += 30;
        label(filters, (u8*)"GPU", 10, y); y += 16;
        gpuPick = pick(filters, 10, y, cw, 1); y += 30;
        label(filters, (u8*)"Suite", 10, y); y += 16;
        suitePick = pick(filters, 10, y, cw, 2); y += 30;
        label(filters, (u8*)"Device", 10, y); y += 16;
        devicePick = pick(filters, 10, y, cw, 4); y += 30;
        label(filters, (u8*)"Optimisation", 10, y); y += 16;
        optPick = pick(filters, 10, y, cw, 3); y += 30;
        label(filters, (u8*)"Arch", 10, y); y += 16;
        archPick = pick(filters, 10, y, cw, 6); y += 30;
        label(filters, (u8*)"View", 10, y); y += 16;
        viewPick = pick(filters, 10, y, cw, 5);
        viewPick.setValues(viewChoices());
        viewPick.setCurrent(BHelp.S((u8*)"Per benchmark"));
        y += 30;
        label(filters, (u8*)"Heat map baseline", 10, y); y += 16;
        basePick = pick(filters, 10, y, cw, 7);
        basePick.anyText = BHelp.S((u8*)"Fastest");
        y += 30;
        label(filters, (u8*)"Metric", 10, y); y += 16;
        metricPop = new UXPopUpButton();
        metricPop.addItem((u8*)"Time (ms)", 0);
        metricPop.addItem((u8*)"Speed-up over slowest", 1);
        metricPop.setAction(&self.onMetric);
        filters.addSubview(metricPop, UXGeom.make(10, y, cw, 24)); y += 32;
        firstRun = new UXCheckbox();
        firstRun.setTitle((u8*)"First run (one-off costs)");
        firstRun.setAction(&self.onFirstRun);
        filters.addSubview(firstRun, UXGeom.make(10, y, cw, 20));

        UXView* publish = pane(rail, (u8*)"Publish", winH - 90, 82, UX_ANCHOR_LEFT | UX_ANCHOR_BOTTOM);
        y = PaneView.TitleH();
        consent = new UXCheckbox();
        consent.setTitle((u8*)"I agree to publish this run");
        publish.addSubview(consent, UXGeom.make(10, y, cw, 20)); y += 26;
        UXButton* submit = new UXButton();
        submit.setTitle((u8*)"Submit to the corpus");
        submit.setAction(&self.onSubmitControl);
        publish.addSubview(submit, UXGeom.make(10, y, cw, 24));

        // ---- chart, in a scroll view ----
        chart = new ChartView();
        chart.setData(data);
        chart.setFilter(filter);
        chartScroll = new UXScrollView();
        chartScroll.setAutoresizeMask(UX_ANCHOR_LEFT | UX_ANCHOR_TOP | UX_FLEX_WIDTH | UX_FLEX_HEIGHT);
        content.addSubview(chartScroll, UXGeom.make(chartX, 8, chartW, chartH));
        chartScroll.document().addSubview(chart, UXGeom.make(0, 0, chartW, 400));
        chartScroll.setDocumentHeight(400);

        // ---- parameters table ----
        table = new UXTableView();
        table.setAutoresizeMask(UX_ANCHOR_LEFT | UX_ANCHOR_BOTTOM | UX_FLEX_WIDTH);
        table.addColumn((u8*)"Benchmark", 130);
        table.addColumn((u8*)"Series", 120);
        table.addColumn((u8*)"Best", 90);
        table.addColumn((u8*)"Spread", 90);
        table.addColumn((u8*)"Machine", 180);
        table.addColumn((u8*)"Parameters", 380);
        table.setDataSource(self);
        content.addSubview(table, UXGeom.make(chartX, winH - bottomH, chartW, bottomH - 30));

        // ---- the status line, under the table ----
        status = new UXLabel();
        status.setText((u8*)"Open your results JSON, or Download the published results and everyone's runs.");
        status.setAutoresizeMask(UX_ANCHOR_LEFT | UX_ANCHOR_BOTTOM | UX_FLEX_WIDTH);
        content.addSubview(status, UXGeom.make(chartX + 4, winH - 24, chartW - 8, 18));

        cpuPick.winHandle = win.handle;
        gpuPick.winHandle = win.handle;
        suitePick.winHandle = win.handle;
        devicePick.winHandle = win.handle;
        optPick.winHandle = win.handle;
        archPick.winHandle = win.handle;
        basePick.winHandle = win.handle;
        viewPick.winHandle = win.handle;

        win.tree.finalise();
        win.displayAll();

        if (selfFile != (String*)0)
            {
            loadFile(selfFile);
            }
        if (selfTest)
            {
            runSelfTest();
            app.stop();
            return exitCode;
            }
        return 0;
        }

    void onOpenControl(UXControl* sender) { onOpen((UXMenuItem*)0); }
    void onDownloadControl(UXControl* sender) { onDownload((UXMenuItem*)0); }
    void onSubmitControl(UXControl* sender) { onSubmit((UXMenuItem*)0); }

    // ---- helpers --------------------------------------------------------

    UXView* pane(UXView* parent, u8* title, i32 y, i32 h, i32 mask)
        {
        PaneView* p = new PaneView();
        p.title = title;
        p.setAutoresizeMask(mask);
        parent.addSubview(p, UXGeom.make(8, y, 234, h));
        return p;
        }

    PickView* pick(UXView* parent, i32 x, i32 y, i32 w, i32 field)
        {
        PickView* p = new PickView();
        p.controller = self;
        p.field = field;
        parent.addSubview(p, UXGeom.make(x, y, w, 24));
        return p;
        }

    void label(UXView* parent, u8* text, i32 x, i32 y)
        {
        UXLabel* l = new UXLabel();
        l.setText(text);
        parent.addSubview(l, UXGeom.make(x, y, 200, 16));
        }

    // ---- the head-less check -------------------------------------------

    // The heat map over the langs runs on one architecture at one level: a
    // row per benchmark, a column per series, the fastest of each row 1.00x,
    // the baseline's own column 1.00x, and an unmeasured pair left empty.
    i32 heatSelfTest(void)
        {
        i32 fails = 0;
        Filter* f = new Filter();
        f.suite = BHelp.S((u8*)"langs");
        f.opt = BHelp.S((u8*)"O3");
        f.arch = BHelp.S((u8*)"x86_64");
        ChartView* v = new ChartView();
        v.setData(data);
        v.setFilter(f);
        HeatMap* h = v.heat;
        Stdio.printf("heat map: %d benchmarks x %d series\n", h.benchCount(), h.columnCount());
        if (h.benchCount() < 1 || h.columnCount() < 2)
            { Stdio.printf("FAIL: heat map too small\n"); return 1; }
        i32 missing = 0;
        for (i32 bi = 0; bi < h.benchCount(); bi++)
            {
            double lo = 1.0e30;
            for (i32 ci = 0; ci < h.columnCount(); ci++)
                {
                double r = 0.0;
                bool noisy = false;
                if (h.ratio(bi, ci, &r, &noisy)) { if (r < lo) { lo = r; } }
                else { missing++; }
                }
            if (Math.abs(lo - 1.0) > 1.0e-9)
                { Stdio.printf("FAIL: the fastest of row %d is %.3fx, not 1x\n", bi, lo); fails++; }
            }
        if (missing == 0) { Stdio.printf("FAIL: no unmeasured cell (sample has one)\n"); fails++; }
        v.setBaseline(BHelp.S((u8*)"xc"));
        h = v.heat;
        for (i32 ci = 0; ci < h.columnCount(); ci++)
            {
            String* sn = (String*)h.colSeries.get(ci);
            for (i32 bi = 0; bi < h.benchCount(); bi++)
                {
                double r = 0.0;
                bool noisy = false;
                if (!h.ratio(bi, ci, &r, &noisy)) { continue; }
                if (sn.equalsIgnoringCase(BHelp.S((u8*)"xc")) && Math.abs(r - 1.0) > 1.0e-9)
                    { Stdio.printf("FAIL: xc over xc is %.3fx\n", r); fails++; }
                if (sn.equalsIgnoringCase(BHelp.S((u8*)"C++ (clang)"))
                    && ((String*)h.benches.get(bi)).equalsIgnoringCase(BHelp.S((u8*)"int_accum")))
                    {
                    Stdio.printf("heat map: int_accum clang over xc %.4fx\n", r);
                    if (Math.abs(r - 126100.0 / 117900.0) > 1.0e-6) { Stdio.printf("FAIL: wrong ratio\n"); fails++; }
                    }
                }
            double gm = 0.0;
            // The outlier stays out of the mean: clang's is int_accum's alone.
            if (sn.equalsIgnoringCase(BHelp.S((u8*)"C++ (clang)")) && h.geomean(ci, &gm)
                && Math.abs(gm - 126100.0 / 117900.0) > 1.0e-6)
                { Stdio.printf("FAIL: the geometric mean kept matrix_mul_f32 (%.3fx)\n", gm); fails++; }
            if (h.geomean(ci, &gm)) { Stdio.printf("  %-12s %-10s geomean %.3fx\n", sn.cString(),
                                                   ((String*)h.colSub.get(ci)).cString(), gm); }
            }
        return fails;
        }

    // With XC_BENCH_SERVER set (a local `php -S` over website/site/public),
    // the corpus round trip: a download with nothing local, a submission of
    // the open contribution, a second one refused by the rate limit, and the
    // corpus again with the first in it.
    i32 netSelfTest(void)
        {
        String* server = Platform.env(String.withCString("XC_BENCH_SERVER"));
        if (server == (String*)0 || server.isEmpty())
            {
            Stdio.printf("net:      skipped (set XC_BENCH_SERVER to test the corpus)\n");
            return 0;
            }
        i32 fails = 0;
        String* text = Net.get(Net.corpusUrl());
        if (text == (String*)0)
            {
            Stdio.printf("FAIL: corpus download: %s\n", Net.lastError().cString());
            return 1;
            }
        Array* before = Contribution.loadText(text, BHelp.S((u8*)"corpus"));
        i32 published = 0;
        for (u32 i = 0; i < before.count(); i++)
            {
            String* src = ((Contribution*)before.get(i)).source;
            if (src != (String*)0 && src.equalsIgnoringCase(BHelp.S((u8*)"published"))) { published++; }
            }
        Stdio.printf("net:      corpus has %d contribution(s), %d published\n", (i32)before.count(), published);
        if (published == 0) { Stdio.printf("FAIL: the corpus carries no published results\n"); fails++; }
        if (own == (Contribution*)0) { Stdio.printf("FAIL: nothing of our own to submit\n"); return fails + 1; }
        // The first submission is stored; a second within the minute is
        // refused by the rate limit, with a reason.
        String* body = (String*)0;
        try { body = JSON.stringify(own.root); }
        catch (e) { Stdio.printf("FAIL: the contribution could not be serialised\n"); return fails + 1; }
        for (i32 k = 0; k < 2; k++)
            {
            HttpResponse* r = Net.post(Net.submitUrl(), body);
            if (r == (HttpResponse*)0) { Stdio.printf("FAIL: submit: %s\n", Net.lastError().cString()); return fails + 1; }
            Stdio.printf("net:      submit %d -> %d %s\n", k + 1, (i32)r.status(), r.bodyString().cString());
            u32 want = k == 0 ? 200 : 429;
            if (r.status() != want) { Stdio.printf("FAIL: submit %d answered %d, not %d\n", k + 1, (i32)r.status(), (i32)want); fails++; }
            }
        Array* after = Contribution.loadText(Net.get(Net.corpusUrl()), BHelp.S((u8*)"corpus"));
        Stdio.printf("net:      corpus now has %d contribution(s)\n", (i32)after.count());
        if (after.count() != before.count() + 1) { Stdio.printf("FAIL: the submission is not in the corpus\n"); fails++; }
        return fails;
        }

    void runSelfTest(void)
        {
        i32 fails = 0;
        if (selfFile == (String*)0)
            {
            Stdio.printf("FAIL: --selftest needs a file\n");
            exitCode = 2;
            return;
            }
        Contribution* c = data.at(0);
        if (c == (Contribution*)0) { Stdio.printf("FAIL: could not parse %s\n", selfFile.cString()); exitCode = 1; return; }
        Stdio.printf("machine:  %s\n", c.machine.label().cString());
        Stdio.printf("runs:     %d\n", (i32)c.runs.count());
        // Every run has samples, and the statistics are finite.
        for (u32 i = 0; i < c.runs.count(); i++)
            {
            Run* r = (Run*)c.runs.get(i);
            if (r.samples.count() == 0) { Stdio.printf("FAIL: no samples for %s\n", r.key().cString()); fails++; }
            if (r.meanUs < 0.0) { Stdio.printf("FAIL: negative mean for %s\n", r.key().cString()); fails++; }
            }
        // The CPU-only filter drops the GPU runs.  Only a data set with GPU
        // runs can show this, so the check is skipped when there are none (as
        // in a run.py results.json, which is CPU-only by nature).
        Filter* f = new Filter();
        f.device = BHelp.S((u8*)"CPU only");
        Array* runs = data.runs();
        i32 cpu = 0;
        i32 gpu = 0;
        for (u32 i = 0; i < runs.count(); i++)
            {
            Run* r = (Run*)runs.get(i);
            if (f.matches(c, r)) { cpu++; }
            if (r.isGpu()) { gpu++; }
            }
        Stdio.printf("cpu-only: %d of %d (%d GPU runs)\n", cpu, (i32)runs.count(), gpu);
        if (gpu > 0 && cpu >= runs.count())
            {
            Stdio.printf("FAIL: the CPU-only filter kept the GPU runs\n");
            fails++;
            }
        // The filter popups must carry their values (Any + one each).
        Stdio.printf("filters: cpu %d, suite %d, opt %d, device %d\n",
                     (i32)distinct(BHelp.S((u8*)"cpu")).count(),
                     (i32)distinct(BHelp.S((u8*)"suite")).count(),
                     (i32)distinct(BHelp.S((u8*)"opt")).count(),
                     (i32)deviceChoices().count());
        // Selecting the first CPU value must narrow the set.
        Array* cvals = distinct(BHelp.S((u8*)"cpu"));
        if (cvals.count() > 0)
            {
            Filter* ff = new Filter();
            ff.cpu = (String*)cvals.get(0);
            i32 kept = 0;
            for (u32 i = 0; i < runs.count(); i++)
                {
                Run* r = (Run*)runs.get(i);
                if (ff.matches(ownerOf(r), r)) { kept++; }
                }
            Stdio.printf("cpu filter '%s': %d of %d\n", ff.cpu.cString(), kept, (i32)runs.count());
            // Only a data set with more than one CPU can show the filter narrowing.
            if (cvals.count() > 1 && (kept == 0 || kept == runs.count()))
                { Stdio.printf("FAIL: cpu filter had no effect\n"); fails++; }
            }
        // Round-trip, for a contribution: stringify it and parse it again.  The
        // published files are a different shape and are not re-written.
        if (c.schema != (String*)0 && c.schema.equalsIgnoringCase(BHelp.S((u8*)"xc-bench/1")))
            {
            try
                {
                String* again = JSON.stringify(c.root);
                Contribution* c2 = Contribution.fromText(again, BHelp.S((u8*)"roundtrip"));
                if (c2 == (Contribution*)0 || c2.runs.count() != c.runs.count())
                    {
                    Stdio.printf("FAIL: JSON round-trip lost runs\n");
                    fails++;
                    }
                }
            catch (e) { Stdio.printf("FAIL: round-trip threw\n"); fails++; }
            }
        // The chart builds rows from the load alone, before anything here
        // touches the filter (this is what the window relies on).
        i32 rows = chart.rowCount();
        Stdio.printf("chart:    %d rows\n", rows);
        if (rows <= 0) { Stdio.printf("FAIL: chart drew no rows\n"); fails++; }
        fails += heatSelfTest();
        // The published shapes load as well: run.py's results.json and
        // par/run.py's results.json.
        String* runpy = String.withCString("{\"version\":\"v0.74\",\"platform\":\"arm64\",\"repeats\":5,"
            "\"net\":{\"int_accum\":{\"O3\":{\"xc\":1.2,\"cpp\":1.3,\"cpp_x86_64\":0.9}}}}");
        Array* rl = Contribution.loadText(runpy, BHelp.S((u8*)"test"));
        i32 rlruns = 0;
        for (u32 i = 0; i < rl.count(); i++) { rlruns += ((Contribution*)rl.get(i)).runs.count(); }
        if (rl.count() != 2 || rlruns != 3)
            { Stdio.printf("FAIL: run.py results.json split wrong (%d contribs, %d runs)\n", rl.count(), rlruns); fails++; }
        String* parpy = String.withCString("{\"nbody\":{\"linux\":{\"checksum\":\"42\","
            "\"gpu\":{\"best_us\":1051,\"first_us\":202245},\"cpu\":{\"best_us\":66500,\"first_us\":67000}}}}");
        Array* pl = Contribution.loadText(parpy, BHelp.S((u8*)"test"));
        if (pl.count() != 1 || ((Contribution*)pl.get(0)).runs.count() != 2)
            { Stdio.printf("FAIL: par results.json did not load (got %d)\n", pl.count()); fails++; }
        // Merge a synthetic corpus of one contribution.
        String* corpus = String.withCString("{\"contributions\":[{\"schema\":\"xc-bench/1\",\"machine\":{\"cpu\":\"Test\"},"
                                            "\"runs\":[{\"suite\":\"langs\",\"benchmark\":\"b\",\"target\":\"xc\","
                                            "\"device\":\"cpu\",\"opt\":\"O3\",\"samples_us\":[1,2,3],\"best_us\":1}]}]}");
        u32 before = data.count();
        mergeCorpus(corpus);
        if (data.count() != before + 1) { Stdio.printf("FAIL: corpus merge added %d\n", (i32)(data.count() - before)); fails++; }
        fails += netSelfTest();
        if (fails == 0) { Stdio.printf("PASS\n"); }
        else { Stdio.printf("FAIL: %d check(s)\n", fails); }
        exitCode = fails == 0 ? 0 : 1;
        }
    }

i32 main(i32 argc, u8** argv)
    {
    Controller* c = new Controller();
    UXApplication* app = new UXApplication();
    if (argc > 1 && String.withCString(argv[1]).equalsIgnoringCase(BHelp.S((u8*)"--selftest")))
        {
        c.selfTest = true;
        if (argc > 2) { c.selfFile = String.withCString(argv[2]); }
        app.setHeadless(true);
        }
    else if (argc > 1)
        {
        c.selfFile = String.withCString(argv[1]);
        }
    Net.setProgramPath(String.withCString(argv[0]));
    app.setDelegate(c);
    app.run();
    return c.exitCode;
    }
