// Chart.xc — the chart view.  A UXView whose drawRect paints the filtered
// runs as a Phoronix-style horizontal bar chart: one row per run, grouped by
// benchmark, a bar for the measured value, an error bar for one standard
// deviation, and the run's parameters under its label.  The same view draws
// absolute times or the speed-up over the slowest run in each benchmark.
//
// Imported by Visualiser.xc.

#import "Model.xc"

// ---- a formatting helper -------------------------------------------------

class Fmt
    {
    // Microseconds as the reader wants them: milliseconds below a second, and
    // whole seconds above, with a fixed number of decimals.
    static String* us(i64 v)
        {
        if (v >= 1000000)
            {
            return String.withFormat((string)"%.2f s", (double)v / 1000000.0);
            }
        if (v >= 1000)
            {
            return String.withFormat((string)"%.1f ms", (double)v / 1000.0);
            }
        return String.withFormat((string)"%lld us", v);
        }

    static String* ms(double us)
        {
        return String.withFormat((string)"%.1f", us / 1000.0);
        }

    static String* ratio(double v)
        {
        return String.withFormat((string)"%.2fx", v);
        }
    }

// ---- one bar -------------------------------------------------------------

class ChartRow
    {
    String*  group;     // the benchmark, the group heading
    String*  label;     // device / target + opt, plus the machine
    String*  params;    // the exact run parameters, one line
    String*  bestText;  // the value, formatted (kept: the table holds pointers)
    String*  spreadText;// one standard deviation, formatted
    String*  machineText;// the machine this run was measured on
    String*  series;    // the series alone: "xc", "C++ (clang)", "GPU"
    String*  sub;       // what else tells a run apart: "x86-64 O3"
    double   valueUs;   // best, or first when asked
    double   rawUs;     // the same, in microseconds even in relative mode
    double   meanUs;
    double   stddevUs;
    i32      color;     // which series colour
    Contribution* owner;

    void init(void)
        {
        group = label = params = bestText = spreadText = machineText = (String*)0;
        series = sub = (String*)0;
        valueUs = rawUs = meanUs = stddevUs = 0.0;
        color = 0;
        owner = (Contribution*)0;
        }
    }

// ---- the heat map: benchmarks down, series across -----------------------
//
// One row per benchmark and one column per series at one setting ("xc" at
// "x86-64 O3"), so xc, clang, GCC and Swift on one architecture sit side by
// side.  Each cell compares the run with its baseline: the fastest run of
// the row, or the chosen series at the same setting.  A cell says which way
// in words ("1.50x slower", "2.10x faster"), so no bare number can be read
// the wrong way round, and the colour agrees: green is better, red is worse.
// Against a chosen series the scale is green, white at parity, red, on the
// log of the ratio, symmetric and clamped at 4x, so a 2x win and a 2x loss
// are equally strong.  Against the fastest nothing can be better, so the
// scale runs green at the fastest, through yellow, to red at 4x behind it;
// either way the clamp means one outlier (matrix_mul_f32) cannot wash the
// rest out.
// A cell within one standard deviation of its baseline is drawn neutral: the
// difference is noise.  The last row is each column's geometric mean, which
// leaves the outlier out (BHelp.isOutlier) while its own row stays on show.

class HeatMap
    {
    Array*  rows;       // ChartRow, the chart's filtered rows
    String* baseline;   // a series name, or null for the fastest of each row
    Array*  benches;    // String, the row names in order of appearance
    Array*  colSeries;  // String, per column
    Array*  colSub;     // String, per column
    i32     width;

    void init(void)
        {
        rows = new Array();
        baseline = (String*)0;
        benches = new Array();
        colSeries = new Array();
        colSub = new Array();
        width = 800;
        }

    static i32 Left(void)  { return 150; }
    static i32 Top(void)   { return 66; }
    static i32 CellH(void) { return 26; }

    static bool addOnce(Array* a, String* v)
        {
        for (u32 i = 0; i < a.count(); i++)
            {
            if (((String*)a.get(i)).equalsIgnoringCase(v)) { return false; }
            }
        a.add(v);
        return true;
        }

    void build(Array* r, String* base, i32 w)
        {
        rows = r;
        baseline = base;
        width = w;
        benches = new Array();
        colSeries = new Array();
        colSub = new Array();
        // When two machines' runs would fall into one cell (the same series
        // at the same architecture and level), the machine joins the sub-key.
        // Otherwise it is left out: the architecture already tells them apart.
        bool clash = false;
        for (u32 i = 0; i < rows.count() && !clash; i++)
            {
            ChartRow* a = (ChartRow*)rows.get(i);
            for (u32 j = i + 1; j < rows.count(); j++)
                {
                ChartRow* b = (ChartRow*)rows.get(j);
                if (a.owner != b.owner && a.group.equalsIgnoringCase(b.group)
                    && a.series.equalsIgnoringCase(b.series) && a.sub.equalsIgnoringCase(b.sub))
                    {
                    clash = true;
                    break;
                    }
                }
            }
        if (clash)
            {
            for (u32 i = 0; i < rows.count(); i++)
                {
                ChartRow* c = (ChartRow*)rows.get(i);
                if (c.machineText == (String*)0) { continue; }
                c.sub = String.withFormat((string)"%s %s", c.sub.cString(), c.machineText.cString());
                }
            }
        for (u32 i = 0; i < rows.count(); i++)
            {
            ChartRow* c = (ChartRow*)rows.get(i);
            addOnce(benches, c.group);
            String* key = String.withFormat((string)"%s|%s", c.series.cString(), c.sub.cString());
            bool seen = false;
            for (u32 j = 0; j < colSeries.count(); j++)
                {
                String* k = String.withFormat((string)"%s|%s", ((String*)colSeries.get(j)).cString(),
                                              ((String*)colSub.get(j)).cString());
                if (k.equalsIgnoringCase(key)) { seen = true; break; }
                }
            if (!seen)
                {
                // Insert in a fixed order, whatever order the runs came in.
                u32 at = colSeries.count();
                for (u32 j = 0; j < colSeries.count(); j++)
                    {
                    if (before(c.series, c.sub, (String*)colSeries.get(j), (String*)colSub.get(j)))
                        {
                        at = j;
                        break;
                        }
                    }
                colSeries.insert(at, c.series);
                colSub.insert(at, c.sub);
                }
            }
        }

    // Does column (series, sub) come before column (s2, sub2)?  Settings
    // alphabetically; within one, xc first and then the rest alphabetically.
    static bool before(String* series, String* sub, String* s2, String* sub2)
        {
        i8 c = sub.compare(sub2);
        if (c != 0) { return c < 0; }
        String* xc = BHelp.S((u8*)"xc");
        if (s2.equalsIgnoringCase(xc)) { return false; }
        if (series.equalsIgnoringCase(xc)) { return true; }
        return series.lowercased().compare(s2.lowercased()) < 0;
        }

    i32 benchCount(void)  { return benches.count(); }
    i32 columnCount(void) { return colSeries.count(); }

    ChartRow* find(String* bench, String* series, String* sub)
        {
        for (u32 i = 0; i < rows.count(); i++)
            {
            ChartRow* c = (ChartRow*)rows.get(i);
            if (c.group.equalsIgnoringCase(bench) && c.series.equalsIgnoringCase(series)
                && c.sub.equalsIgnoringCase(sub))
                {
                return c;
                }
            }
        return (ChartRow*)0;
        }

    ChartRow* cell(i32 bi, i32 ci)
        {
        return find((String*)benches.get(bi), (String*)colSeries.get(ci),
                    (String*)colSub.get(ci));
        }

    // The fastest run of one benchmark, across every column.
    ChartRow* fastest(i32 bi)
        {
        String* bench = (String*)benches.get(bi);
        ChartRow* best = (ChartRow*)0;
        for (u32 i = 0; i < rows.count(); i++)
            {
            ChartRow* c = (ChartRow*)rows.get(i);
            if (!c.group.equalsIgnoringCase(bench) || c.rawUs <= 0.0) { continue; }
            if (best == (ChartRow*)0 || c.rawUs < best.rawUs) { best = c; }
            }
        return best;
        }

    ChartRow* baseOf(i32 bi, i32 ci)
        {
        if (baseline == (String*)0) { return fastest(bi); }
        return find((String*)benches.get(bi), baseline, (String*)colSub.get(ci));
        }

    // The cell's time over its baseline's; false when either is missing.
    // `noisy` is set when the two are within one combined standard deviation.
    bool ratio(i32 bi, i32 ci, double* out, bool* noisy)
        {
        *out = 0.0;
        *noisy = false;
        ChartRow* c = cell(bi, ci);
        ChartRow* b = baseOf(bi, ci);
        if (c == (ChartRow*)0 || b == (ChartRow*)0 || c.rawUs <= 0.0 || b.rawUs <= 0.0) { return false; }
        *out = c.rawUs / b.rawUs;
        if (c != b && (c.stddevUs > 0.0 || b.stddevUs > 0.0))
            {
            double spread = Math.sqrt(c.stddevUs * c.stddevUs + b.stddevUs * b.stddevUs);
            *noisy = Math.abs(c.meanUs - b.meanUs) <= spread;
            }
        return true;
        }

    // The geometric mean of one column's ratios, without the outlier; false
    // when it has none.
    bool geomean(i32 ci, double* out)
        {
        double logs = 0.0;
        i32 n = 0;
        for (i32 bi = 0; bi < benchCount(); bi++)
            {
            if (BHelp.isOutlier((String*)benches.get(bi))) { continue; }
            double r = 0.0;
            bool noisy = false;
            if (ratio(bi, ci, &r, &noisy)) { logs += Math.ln(r); n++; }
            }
        *out = n == 0 ? 0.0 : Math.exp(logs / (double)n);
        return n > 0;
        }

    i32 height(void)
        {
        if (benchCount() == 0) { return 220; }
        return Top() + (benchCount() + 1) * CellH() + 8 + 70;
        }

    i32 cellW(void)
        {
        i32 n = columnCount();
        if (n == 0) { return 100; }
        i32 w = (width - Left() - 16) / n;
        if (w < 96) { w = 96; }
        if (w > 130) { w = 130; }
        return w;
        }

    // A diverging colour for a time ratio: white at 1x, green as the cell
    // gets faster than its baseline (better), red as it gets slower (worse),
    // full at 4x either way.
    static i32 colorFor(double r)
        {
        double t = Math.ln(r) / (2.0 * Math.LN2());
        if (t > 1.0) { t = 1.0; }
        if (t < -1.0) { t = -1.0; }
        i32 er = 26;  i32 eg = 140; i32 eb = 70;    // faster
        if (t > 0.0) { er = 200; eg = 40; eb = 40; } // slower
        double a = Math.abs(t);
        i32 cr = 255.0 + (double)(er - 255) * a;
        i32 cg = 255.0 + (double)(eg - 255) * a;
        i32 cb = 255.0 + (double)(eb - 255) * a;
        return (cr << 16) | (cg << 8) | cb;
        }

    // A time ratio in words: "1.50x slower", "2.10x faster", or "same"
    // when it rounds to parity.
    // Against the fastest: green at the fastest, yellow at 2x behind, red
    // at 4x and beyond.
    static i32 colorBehind(double r)
        {
        double t = Math.ln(r) / (2.0 * Math.LN2());
        if (t > 1.0) { t = 1.0; }
        if (t < 0.0) { t = 0.0; }
        double a = t < 0.5 ? t * 2.0 : (t - 0.5) * 2.0;
        i32 r0 = 99;  i32 g0 = 190; i32 b0 = 123;   // green
        i32 r1 = 250; i32 g1 = 225; i32 b1 = 120;   // yellow
        if (t >= 0.5)
            {
            r0 = r1; g0 = g1; b0 = b1;
            r1 = 214; g1 = 64; b1 = 52;              // red
            }
        i32 cr = (double)r0 + (double)(r1 - r0) * a;
        i32 cg = (double)g0 + (double)(g1 - g0) * a;
        i32 cb = (double)b0 + (double)(b1 - b0) * a;
        return (cr << 16) | (cg << 8) | cb;
        }

    // The colour of a time ratio under the current baseline.
    i32 shade(double r)
        {
        return baseline == (String*)0 ? colorBehind(r) : colorFor(r);
        }

    static String* ratioText(double r)
        {
        bool slower = r >= 1.0;
        double k = slower ? r : 1.0 / r;
        if (k < 1.005) { return BHelp.S((u8*)"same"); }
        u8* way = slower ? (u8*)"slower" : (u8*)"faster";
        if (k >= 10.0) { return String.withFormat((string)"%.0fx %s", k, way); }
        return String.withFormat((string)"%.2fx %s", k, way);
        }

    // At most `n` characters of `s`, so a header stays inside its column.
    static String* clip(String* s, i32 n)
        {
        if (s.byteLength() <= n) { return s; }
        if (n > 63) { n = 63; }
        u8 buf[64];
        u8* src = s.cString();
        for (i32 i = 0; i < n; i++) { buf[i] = src[i]; }
        buf[n] = 0;
        return String.withCString(&buf[0]);
        }

    // `name` replaces the ratio for the cell the row is measured against
    // ("fastest", "baseline"); null draws the ratio.
    void fillCell(UXGraphics* g, i32 x, i32 y, i32 w, i32 h, double r, bool noisy, bool bold, u8* name)
        {
        // A frame round every cell, so a white 1.00x still reads as a cell;
        // a dark one round the fastest of the row.
        i32 f = bold ? 50 : 222;
        g.fillRectRGB(UXGeom.make(x + 1, y + 1, w - 2, h - 2), f, f, f + 4);
        i32 c = noisy ? 0xEEEEF0 : shade(r);
        g.fillRectRGB(UXGeom.make(x + 3, y + 3, w - 6, h - 6),
                      (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF);
        double t = Math.abs(Math.ln(r) / (2.0 * Math.LN2()));
        bool dark = !noisy && t > (baseline == (String*)0 ? 0.8 : 0.55);
        String* txt = name != (u8*)0 ? String.withCString(name) : ratioText(r);
        i32 tx = x + (w - txt.byteLength() * 6) / 2;
        i32 tc = dark ? 255 : (noisy ? 130 : 30);
        g.drawTextRGBA(txt.cString(), tx, y + 7, tc, tc, tc, 255, bold ? 12 : 11);
        }

    void draw(UXGraphics* g)
        {
        UXRect b = UXGeom.make(0, 0, width, height());
        g.fillRectRGB(b, 255, 255, 255);
        i32 nB = benchCount();
        i32 nC = columnCount();
        if (nB == 0 || nC == 0)
            {
            g.drawTextRGBA((u8*)"No runs match the filters.", 16, 16, 90, 90, 90, 255, 13);
            return;
            }
        i32 cw = cellW();
        i32 ch = CellH();
        String* over = baseline == (String*)0
                     ? BHelp.S((u8*)"the fastest run of each benchmark")
                     : String.withFormat((string)"%s at the same setting", baseline.cString());
        String* title = String.withFormat((string)"each run against %s", over.cString());
        g.drawTextRGBA(title.cString(), 12, 8, 40, 40, 44, 255, 12);

        // Column headers: the series, and under it the setting.
        for (i32 ci = 0; ci < nC; ci++)
            {
            i32 x = Left() + ci * cw;
            i32 chars = cw / 7;
            String* sn = clip((String*)colSeries.get(ci), chars);
            String* sb = clip((String*)colSub.get(ci), chars + 2);
            g.drawTextRGBA(sn.cString(), x + 4, Top() - 34, 24, 24, 28, 255, 12);
            g.drawTextRGBA(sb.cString(), x + 4, Top() - 18, 110, 110, 118, 255, 10);
            }

        // The cells.  The fastest run of each row is drawn in a heavier hand.
        for (i32 bi = 0; bi < nB; bi++)
            {
            i32 y = Top() + bi * ch;
            if ((bi & 1) == 1)
                {
                g.fillRectRGB(UXGeom.make(4, y, Left() - 8, ch), 244, 245, 248);
                }
            g.drawTextRGBA(clip((String*)benches.get(bi), 20).cString(),
                           10, y + 7, 40, 40, 44, 255, 12);
            ChartRow* win = fastest(bi);
            for (i32 ci = 0; ci < nC; ci++)
                {
                i32 x = Left() + ci * cw;
                double r = 0.0;
                bool noisy = false;
                if (ratio(bi, ci, &r, &noisy))
                    {
                    ChartRow* here = cell(bi, ci);
                    u8* name = (u8*)0;
                    if (here == baseOf(bi, ci)) { name = baseline == (String*)0 ? (u8*)"fastest" : (u8*)"baseline"; }
                    fillCell(g, x, y, cw, ch, r, noisy, here == win, name);
                    }
                else
                    {
                    // No run, or no baseline to divide by: an outline, never
                    // white, which would read as parity.
                    UXRect e = UXGeom.make(x + 1, y + 1, cw - 2, ch - 2);
                    g.fillRectRGB(e, 214, 216, 222);
                    UXRect ei = UXGeom.make(x + 2, y + 2, cw - 4, ch - 4);
                    g.fillRectRGB(ei, 255, 255, 255);
                    g.drawTextRGBA((u8*)"-", x + cw / 2 - 3, y + 7, 170, 170, 176, 255, 11);
                    }
                }
            }

        // The geometric mean of each column, under a rule.
        i32 gy = Top() + nB * ch + 8;
        g.fillRectRGB(UXGeom.make(4, gy - 4, Left() + nC * cw - 4, 1), 190, 194, 202);
        bool hasOutlier = false;
        for (i32 bi = 0; bi < nB; bi++)
            {
            if (BHelp.isOutlier((String*)benches.get(bi))) { hasOutlier = true; }
            }
        g.drawTextRGBA((u8*)"geometric mean", 10, gy + 2, 40, 40, 44, 255, 12);
        if (hasOutlier)
            {
            g.drawTextRGBA((u8*)"without matrix_mul_f32", 10, gy + 15, 120, 120, 128, 255, 9);
            }
        for (i32 ci = 0; ci < nC; ci++)
            {
            double m = 0.0;
            if (geomean(ci, &m)) { fillCell(g, Left() + ci * cw, gy, cw, ch, m, false, false, (u8*)0); }
            }

        // The key: the scale from 4x faster to 4x slower.
        i32 ky = gy + ch + 22;
        i32 kx = Left();
        i32 steps = 40;
        for (i32 k = 0; k < steps; k++)
            {
            double t = (double)k / (double)(steps - 1);
            if (baseline != (String*)0) { t = t * 2.0 - 1.0; }
            i32 c = shade(Math.exp(t * 2.0 * Math.LN2()));
            g.fillRectRGB(UXGeom.make(kx + k * 6, ky, 6, 12),
                          (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF);
            }
        bool behind = baseline == (String*)0;
        g.drawTextRGBA(behind ? (u8*)"fastest" : (u8*)"4x faster", kx - (behind ? 46 : 58), ky + 1, 90, 90, 96, 255, 10);
        g.drawTextRGBA(behind ? (u8*)"2x slower" : (u8*)"same", kx + steps * 3 - (behind ? 24 : 12), ky + 15, 90, 90, 96, 255, 10);
        g.drawTextRGBA((u8*)"4x slower", kx + steps * 6 + 4, ky + 1, 90, 90, 96, 255, 10);
        g.drawTextRGBA((u8*)"green = better, red = worse, grey = within one standard deviation, framed = fastest, - = not measured",
                       12, ky + 30, 110, 110, 118, 255, 10);
        }
    }

// ---- the chart -----------------------------------------------------------

class ChartView : UXView
    {
    DataSet* data;
    Filter*  filter;
    i32      metric;    // 0 absolute ms, 1 speed-up over the slowest
    bool     useFirst;  // draw the first-run figure (par) instead of the best
    Array*   rows;      // ChartRow, sorted
    i32      maxRows;   // diagnostics
    i32      mode;      // 0 = per-benchmark rows, 1 = the summary grid, 2 = the heat map
    HeatMap* heat;      // mode 2's matrix, rebuilt with the rows
    String*  baseline;  // the heat map's baseline series, or null for the fastest

    void init(void)
        {
        data = (DataSet*)0;
        filter = (Filter*)0;
        metric = 0;
        useFirst = false;
        rows = new Array();
        maxRows = 0;
        mode = 0;
        heat = new HeatMap();
        baseline = (String*)0;
        }

    void setData(DataSet* d) { data = d; rebuild(); }
    void setMode(i32 m) { mode = m; rebuild(); }
    i32  modeValue(void) { return mode; }
    void setFilter(Filter* f) { filter = f; rebuild(); }
    void setMetric(i32 m) { metric = m; rebuild(); }
    void setUseFirst(bool b) { useFirst = b; rebuild(); }
    void setBaseline(String* s) { baseline = s; rebuild(); }
    i32  rowCount(void) { return rows.count(); }
    Array* visibleRows(void) { return rows; }
    // Layout: a header band per benchmark, then one row per run on a fixed
    // grid, then a gap before the next card.  drawRect and height() share these
    // numbers so the scroll view always fits the chart.
    static i32 Top(void)   { return 56; }
    static i32 HeadH(void) { return 30; }
    static i32 RowH(void)  { return 52; }

    // The first row index of the next group after `i`.
    i32 groupEnd(i32 i)
        {
        i32 n = rows.count();
        i32 j = i + 1;
        while (j < n && ((ChartRow*)rows.get(j)).group.equalsIgnoringCase(((ChartRow*)rows.get(i)).group)) { j++; }
        return j;
        }

    i32 height(void)
        {
        if (mode == 2) { return heat.height(); }
        return mode == 1 ? summaryHeight() : rowsHeight();
        }

    i32 rowsHeight(void)
        {
        i32 n = rows.count();
        if (n == 0) { return 220; }
        i32 h = Top();
        i32 i = 0;
        while (i < n)
            {
            i32 j = groupEnd(i);
            h += HeadH() + (j - i) * RowH() - 8 + 16;
            i = j;
            }
        return h + 40;
        }

    // The colour a device (par) or a target (langs) draws in.
    static void colorOf(Run* r, i32* cr, i32* cg, i32* cb)
        {
        String* k = (r.device != (String*)0) ? r.device : r.target;
        i32 code = 0;
        if (r.suite != (String*)0 && r.suite.equalsIgnoringCase(BHelp.S((u8*)"langs")))
            {
            if (r.target.equalsIgnoringCase(BHelp.S((u8*)"xc")))    { code = 0; }
            else if (r.target.equalsIgnoringCase(BHelp.S((u8*)"objc")))  { code = 1; }
            else if (r.target.equalsIgnoringCase(BHelp.S((u8*)"cpp")))   { code = 2; }
            else if (r.target.equalsIgnoringCase(BHelp.S((u8*)"gcc")))   { code = 3; }
            else                                                     { code = 4; }
            }
        else
            {
            if (k.equalsIgnoringCase(BHelp.S((u8*)"serial")))       { code = 5; }
            else if (k.equalsIgnoringCase(BHelp.S((u8*)"cpu")))      { code = 2; }
            else if (k.equalsIgnoringCase(BHelp.S((u8*)"gpu")))      { code = 3; }
            else if (k.equalsIgnoringCase(BHelp.S((u8*)"vulkan")))   { code = 4; }
            else                                                    { code = 1; }
            }
        i32 c = 0x6B7280;                       // default: grey
        if (code == 0) { c = 0xD4751F; }   // xc / auto
        else if (code == 1) { c = 0xC9A227; } // Objective-C / auto
        else if (code == 2) { c = 0x3B82F6; } // C++ / all threads
        else if (code == 3) { c = 0x16A34A; } // GCC / GPU
        else if (code == 4) { c = 0x9333EA; } // Swift / Vulkan
        *cr = (c >> 16) & 0xFF;
        *cg = (c >> 8) & 0xFF;
        *cb = c & 0xFF;
        }

    // The series name plus the machine it ran on, so two machines' rows are
    // told apart ("Objective-C  arm64" beside "Objective-C  x86-64").
    static String* labelFor(Run* r)
        {
        String* base = seriesName(r);
        String* a = archName(r);
        if (a == (String*)0) { return base; }
        return String.withFormat((string)"%s  %s", base.cString(), a.cString());
        }

    // The architecture as the reader writes it, or null when the run has none.
    static String* archName(Run* r)
        {
        if (r.arch == (String*)0 || r.arch.isEmpty()) { return (String*)0; }
        if (r.arch.equalsIgnoringCase(BHelp.S((u8*)"x86_64")))      { return BHelp.S((u8*)"x86-64"); }
        if (r.arch.equalsIgnoringCase(BHelp.S((u8*)"wasm32")))      { return BHelp.S((u8*)"wasm"); }
        return r.arch;
        }

    // The heat map's sub-key: the architecture and the level, so a column is
    // one series at one setting ("xc" at "x86-64 O3").
    static String* subFor(Run* r)
        {
        String* s = String.withCString("");
        String* a = archName(r);
        if (a != (String*)0) { s.append(a); }
        if (r.opt != (String*)0 && !r.opt.isEmpty())
            {
            if (!s.isEmpty()) { s.appendCString(" "); }
            s.append(r.opt);
            }
        return s;
        }

    // A human name for the series: "xc vs Objective-C" or "the GPU".
    static String* seriesName(Run* r)
        {
        if (r.suite != (String*)0 && r.suite.equalsIgnoringCase(BHelp.S((u8*)"langs")))
            {
            if (r.target.equalsIgnoringCase(BHelp.S((u8*)"objc"))) { return BHelp.S((u8*)"Objective-C"); }
            if (r.target.equalsIgnoringCase(BHelp.S((u8*)"cpp")))  { return BHelp.S((u8*)"C++ (clang)"); }
            if (r.target.equalsIgnoringCase(BHelp.S((u8*)"gcc")))  { return BHelp.S((u8*)"C++ (GCC)"); }
            if (r.target.equalsIgnoringCase(BHelp.S((u8*)"swift"))){ return BHelp.S((u8*)"Swift"); }
            return BHelp.S((u8*)"xc");
            }
        if (r.device == (String*)0) { return BHelp.S((u8*)"auto"); }
        if (r.device.equalsIgnoringCase(BHelp.S((u8*)"serial"))) { return BHelp.S((u8*)"one thread"); }
        if (r.device.equalsIgnoringCase(BHelp.S((u8*)"cpu")))    { return BHelp.S((u8*)"all threads"); }
        if (r.device.equalsIgnoringCase(BHelp.S((u8*)"gpu")))    { return BHelp.S((u8*)"GPU"); }
        if (r.device.equalsIgnoringCase(BHelp.S((u8*)"vulkan"))) { return BHelp.S((u8*)"Vulkan"); }
        return BHelp.S((u8*)"auto");
        }

    // Build the rows the filter lets through, group them by benchmark, and
    // sort each group fastest-first.  Relative mode computes each row's
    // speed-up against the slowest run of its own benchmark.
    void rebuild(void)
        {
        rows.removeAll();
        maxRows = 0;
        if (data == (DataSet*)0 || filter == (Filter*)0)
            {
            return;
            }
        // Pass 1: collect (contribution, run) pairs that pass the filter.
        Array* owners = new Array();
        Array* keep = new Array();
        for (u32 i = 0; i < data.contributions.count(); i++)
            {
            Contribution* c = (Contribution*)data.contributions.get(i);
            for (u32 j = 0; j < c.runs.count(); j++)
                {
                Run* r = (Run*)c.runs.get(j);
                if (filter.matches(c, r))
                    {
                    owners.add(c);
                    keep.add(r);
                    }
                }
            }
        // Pass 2: per benchmark, the slowest value is the relative baseline.
        Array* groups = new Array();   // distinct benchmark names
        for (u32 i = 0; i < keep.count(); i++)
            {
            Run* r = (Run*)keep.get(i);
            bool seen = false;
            for (u32 g = 0; g < groups.count(); g++)
                {
                if (((String*)groups.get(g)).equalsIgnoringCase(r.benchmark)) { seen = true; }
                }
            if (!seen) { groups.add(r.benchmark); }
            }
        for (u32 g = 0; g < groups.count(); g++)
            {
            String* name = (String*)groups.get(g);
            double slowest = 0.0;
            for (u32 i = 0; i < keep.count(); i++)
                {
                Run* r = (Run*)keep.get(i);
                if (!r.benchmark.equalsIgnoringCase(name)) { continue; }
                double v = r.value(useFirst);
                if (v > slowest) { slowest = v; }
                }
            // gather this group's rows, then insertion-sort by value
            Array* group = new Array();
            for (u32 i = 0; i < keep.count(); i++)
                {
                Run* r = (Run*)keep.get(i);
                if (!r.benchmark.equalsIgnoringCase(name)) { continue; }
                Contribution* c = (Contribution*)owners.get(i);
                ChartRow* row = new ChartRow();
                row.group = name;
                row.label = labelFor(r);
                row.series = seriesName(r);
                row.sub = subFor(r);
                row.owner = c;
                row.valueUs = r.value(useFirst);
                row.rawUs = row.valueUs;
                row.meanUs = r.meanUs;
                row.stddevUs = r.stddevUs;
                i32 cr = 0; i32 cg = 0; i32 cb = 0;
                colorOf(r, &cr, &cg, &cb);
                row.color = (cr << 16) | (cg << 8) | cb;
                row.params = paramLine(c, r);
                i32 at = group.count();
                for (i32 k = 0; k < group.count(); k++)
                    {
                    ChartRow* e = (ChartRow*)group.get(k);
                    if (row.valueUs < e.valueUs) { at = k; break; }
                    }
                group.insert(at, row);
                }
            // In relative mode, divide the baseline through so the bar is a
            // speed-up; the slowest of the group is 1.00x.
            for (u32 i = 0; i < group.count(); i++)
                {
                ChartRow* row = (ChartRow*)group.get(i);
                if (metric == 1 && slowest > 0.0)
                    {
                    row.valueUs = row.valueUs > 0.0 ? slowest / row.valueUs : 0.0;
                    }
                // The table holds the pointers this returns, so the text is
                // kept on the row and not made afresh per cell.
                row.bestText = (metric == 1) ? Fmt.ratio(row.valueUs) : Fmt.us(row.valueUs);
                row.spreadText = String.withFormat((string)"+/- %.1f", row.stddevUs);
                row.machineText = row.owner.machine.label();
                rows.add(row);
                }
            if (group.count() > maxRows) { maxRows = group.count(); }
            }
        heat.build(rows, baseline, self.bounds().w);
        }

    // The parameters of one run as a single line: "xc O3 x86_64 · XC_PAR=gpu".
    static String* paramLine(Contribution* c, Run* r)
        {
        String* s = String.withCString("");
        if (r.suite != (String*)0) { s.append(r.suite); s.appendCString(" · "); }
        if (r.target != (String*)0) { s.append(r.target); }
        if (r.opt != (String*)0) { s.appendCString(" "); s.append(r.opt); }
        if (r.arch != (String*)0) { s.appendCString(" "); s.append(r.arch); }
        Array* keys = r.params.allKeys();
        for (u32 i = 0; i < keys.count(); i++)
            {
            String* k = (String*)keys.get(i);
            String* v = BHelp.text(r.params.get(k));
            if (v == (String*)0) { continue; }
            s.appendCString(" · ");
            s.append(k);
            s.appendCString("=");
            s.append(v);
            }
        return s;
        }

    // ---- the summary: a grid of small charts, one per series -------------
    //
    // Each panel is one series (a language, or a device) with every benchmark
    // along the bottom as a vertical bar, so all the tests are visible at once.
    // Names are stacked a character a line under their bar, which reads at this
    // width where a horizontal label would collide with its neighbour.

    static i32 ColW(void)   { return 18; }   // width per benchmark
    static i32 BarW(void)   { return 12; }
    static i32 TitleH(void) { return 20; }
    static i32 PlotH(void)  { return 150; }
    static i32 CharH(void)  { return 8; }

    Array* benchNames(void)
        {
        Array* out = new Array();
        for (u32 i = 0; i < rows.count(); i++)
            {
            String* g = ((ChartRow*)rows.get(i)).group;
            // The outlier is left out of the summary: it would flatten every
            // other bar.
            if (BHelp.isOutlier(g)) { continue; }
            bool seen = false;
            for (u32 j = 0; j < out.count(); j++)
                {
                if (((String*)out.get(j)).equalsIgnoringCase(g)) { seen = true; break; }
                }
            if (!seen) { out.add(g); }
            }
        return out;
        }

    Array* seriesNames(void)
        {
        Array* out = new Array();
        for (u32 i = 0; i < rows.count(); i++)
            {
            String* l = ((ChartRow*)rows.get(i)).label;
            bool seen = false;
            for (u32 j = 0; j < out.count(); j++)
                {
                if (((String*)out.get(j)).equalsIgnoringCase(l)) { seen = true; break; }
                }
            if (!seen) { out.add(l); }
            }
        return out;
        }

    i32 labelChars(void)
        {
        Array* names = benchNames();
        i32 longest = 0;
        for (u32 i = 0; i < names.count(); i++)
            {
            i32 len = ((String*)names.get(i)).byteLength();
            if (len > longest) { longest = len; }
            }
        return longest > 16 ? 16 : longest;
        }

    i32 summaryCols(void)
        {
        i32 nB = benchNames().count();
        if (nB == 0) { return 1; }
        i32 panelW = 16 + nB * ColW();
        i32 cols = (self.bounds().w - 16) / (panelW + 12);
        return cols < 1 ? 1 : cols;
        }

    i32 summaryPanelH(void)
        {
        return TitleH() + PlotH() + labelChars() * CharH() + 18;
        }

    i32 summaryHeight(void)
        {
        i32 nS = seriesNames().count();
        if (nS == 0) { return 220; }
        i32 cols = summaryCols();
        i32 rowsOf = (nS + cols - 1) / cols;
        return 8 + rowsOf * (summaryPanelH() + 12);
        }

    // The row for one series and one benchmark, or null.
    ChartRow* findRow(String* series, String* benchmark)
        {
        for (u32 i = 0; i < rows.count(); i++)
            {
            ChartRow* r = (ChartRow*)rows.get(i);
            if (r.group.equalsIgnoringCase(benchmark) && r.label.equalsIgnoringCase(series))
                {
                return r;
                }
            }
        return (ChartRow*)0;
        }

    void drawSummary(UXGraphics* g)
        {
        UXRect b = self.bounds();
        g.fillRectRGB(b, 255, 255, 255);
        Array* names = benchNames();
        Array* series = seriesNames();
        i32 nB = names.count();
        i32 nS = series.count();
        if (nB == 0 || nS == 0)
            {
            g.drawTextRGBA((u8*)"No runs match the filters.", 16, 16, 90, 90, 90, 255, 13);
            return;
            }
        // One scale for every panel: the largest bar among the tests on show
        // (matrix_mul_f32 excluded), so the panels can be compared directly.
        double peak = 0.0;
        for (u32 i = 0; i < rows.count(); i++)
            {
            ChartRow* r = (ChartRow*)rows.get(i);
            if (BHelp.isOutlier(r.group)) { continue; }
            if (r.valueUs > peak) { peak = r.valueUs; }
            }
        if (peak <= 0.0) { peak = 1.0; }

        i32 lc = labelChars();
        i32 panelW = 16 + nB * ColW();
        i32 panelH = summaryPanelH();
        i32 cols = summaryCols();
        for (i32 s = 0; s < nS; s++)
            {
            String* key = (String*)series.get(s);
            i32 col = s % cols;
            i32 band = s / cols;
            i32 px = 8 + col * (panelW + 12);
            i32 py = 8 + band * (panelH + 12);
            UXRect card = UXGeom.make(px, py, panelW, panelH);
            UXPainter.fillRoundRectRGB(g, card, 7, 197, 202, 214);
            UXRect inner = UXGeom.make(px + 1, py + 1,
                                       panelW - 2, panelH - 2);
            UXPainter.fillRoundRectRGB(g, inner, 6, 252, 253, 255);
            g.drawTextRGBA(key.cString(), px + 10, py + 7, 24, 24, 28, 255, 12);

            i32 x0 = px + 8;
            i32 baseY = py + TitleH() + PlotH();
            g.fillRectRGB(UXGeom.make(x0, baseY, nB * ColW(), 1), 200, 203, 210);
            // The shared scale on every panel: the same gridlines and the same
            // maximum, so a bar here and a bar there are directly comparable.
            for (i32 k = 1; k <= 4; k++)
                {
                i32 gy = baseY - (k * PlotH()) / 4;
                g.fillRectRGB(UXGeom.make(x0, gy, nB * ColW(), 1), 234, 236, 242);
                }
            g.drawTextRGBA(Fmt.us(peak).cString(), px + panelW - 74, py + 7, 120, 120, 128, 255, 10);
            for (i32 bi = 0; bi < nB; bi++)
                {
                String* bn = (String*)names.get(bi);
                ChartRow* row = findRow(key, bn);
                i32 bx = x0 + bi * ColW() + (ColW() - BarW()) / 2;
                if (row != (ChartRow*)0)
                    {
                    i32 cr = (row.color >> 16) & 255;
                    i32 cg = (row.color >> 8) & 255;
                    i32 cb = row.color & 255;
                    i32 hgt = (row.valueUs / peak) * (double)PlotH();
                    if (hgt < 2) { hgt = 2; }
                    g.fillRectRGB(UXGeom.make(bx, baseY - hgt, BarW(), hgt), cr, cg, cb);
                    if (metric == 0 && row.stddevUs > 0.0)
                        {
                        i32 mid = bx + BarW() / 2;
                        i32 eTop = baseY - (i32)(((row.meanUs + row.stddevUs) / peak) * (double)PlotH());
                        i32 eBot = baseY - (i32)(((row.meanUs - row.stddevUs) / peak) * (double)PlotH());
                        g.drawLine(mid, eTop, mid, eBot, 1);
                        }
                    }
                // The name, a character a line, under the bar.
                u8* nm = bn.cString();
                for (i32 k = 0; k < lc && nm[k] != 0; k++)
                    {
                    u8 one[2];
                    one[0] = nm[k];
                    one[1] = 0;
                    g.drawTextRGBA(&one[0], bx + (BarW() / 2) - 3,
                                   baseY + 4 + k * CharH(), 70, 70, 78, 255, 8);
                    }
                }
            }
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        if (mode == 1) { drawSummary(g); return; }
        if (mode == 2) { heat.width = self.bounds().w; heat.draw(g); return; }
        UXRect b = self.bounds();
        g.fillRectRGB(b, 255, 255, 255);
        i32 w = b.w;
        i32 left = 190;
        i32 right = w - 90;
        if (right <= left) { right = left + 40; }
        i32 n = rows.count();

        if (n == 0)
            {
            g.drawTextRGBA((u8*)"No runs match the filters.", 16, 16, 90, 90, 90, 255, 13);
            return;
            }

        // The largest bar, for the absolute scale.  In relative mode the
        // largest value is already a speed-up (1.0 or more).
        double peak = 0.0;
        for (u32 i = 0; i < rows.count(); i++)
            {
            double v = ((ChartRow*)rows.get(i)).valueUs;
            if (v > peak) { peak = v; }
            }
        if (peak <= 0.0) { peak = 1.0; }
        // Round the axis up to a 1/2/5 x 10^k step so the gridlines are round.
        double step = niceStep(peak);
        i32 ticks = (i32)(peak / step) + 1;

        // Pass 1: one card per benchmark, laid out one after the other.  Each
        // card has a header band for the benchmark's name, then its rows.
        i32 y = Top();
        i32 contentBottom = y;
        i32 gi = 0;
        while (gi < n)
            {
            i32 gj = groupEnd(gi);
            i32 cardH = HeadH() + (gj - gi) * RowH() - 8;
            UXRect card = UXGeom.make(4, y, w - 8, cardH);
            UXPainter.fillRoundRectRGB(g, card, 7, 197, 202, 214);
            UXRect inner = UXGeom.make(card.x + 1, card.y + 1,
                                       card.w - 2, card.h - 2);
            UXPainter.fillRoundRectRGB(g, inner, 6, 236, 238, 243);
            contentBottom = y + cardH;
            y += cardH + 16;
            gi = gj;
            }

        // Axis, gridlines and their labels, over the cards.
        for (i32 t = 0; t <= ticks; t++)
            {
            double val = (double)t * step;
            i32 x = left + (i32)((val / (step * (double)ticks)) * (double)(right - left));
            if (x > right) { break; }
            g.fillRectRGB(UXGeom.make(x, Top() - 8, 1, contentBottom - Top() + 8), 208, 211, 219);
            String* lab = (metric == 1)
                        ? Fmt.ratio(val)
                        : String.withFormat((string)"%.1f", val / 1000.0);
            g.drawTextRGBA(lab.cString(), x + 2, Top() - 26, 110, 110, 110, 255, 11);
            }
        String* unit = (metric == 1) ? BHelp.S((u8*)"speed-up (x)") : BHelp.S((u8*)"time (ms)");
        g.drawTextRGBA(unit.cString(), left, 6, 60, 60, 60, 255, 12);

        // Pass 2: the benchmark name in each card's header, then its rows.
        y = Top();
        gi = 0;
        while (gi < n)
            {
            i32 gj = groupEnd(gi);
            g.drawTextRGBA(((ChartRow*)rows.get(gi)).group.cString(), 12, y + 9, 24, 24, 28, 255, 13);
            i32 ry = y + HeadH();
            for (i32 k = gi; k < gj; k++)
                {
                ChartRow* row = (ChartRow*)rows.get(k);
                i32 cr = (row.color >> 16) & 0xFF;
                i32 cg = (row.color >> 8) & 0xFF;
                i32 cb = row.color & 0xFF;
                g.drawTextRGBA(row.label.cString(), 24, ry + 21, 80, 80, 88, 255, 11);
                double frac = row.valueUs / (step * (double)ticks);
                if (frac < 0.0) { frac = 0.0; }
                if (frac > 1.0) { frac = 1.0; }
                i32 bw = frac * (double)(right - left);
                if (bw < 2) { bw = 2; }
                g.fillRectRGB(UXGeom.make(left, ry + 14, bw, 14), cr, cg, cb);
                String* val = (metric == 1) ? Fmt.ratio(row.valueUs) : Fmt.us(row.valueUs);
                g.drawTextRGBA(val.cString(), left + bw + 6, ry + 19, 40, 40, 44, 255, 11);
                if (metric == 0 && row.stddevUs > 0.0)
                    {
                    double lo = row.meanUs - row.stddevUs;
                    double hi = row.meanUs + row.stddevUs;
                    i32 x0 = left + (i32)((lo / (step * (double)ticks)) * (double)(right - left));
                    i32 x1 = left + (i32)((hi / (step * (double)ticks)) * (double)(right - left));
                    i32 ym = ry + 21;
                    g.drawLine(x0, ym - 5, x0, ym + 5, 1);
                    g.drawLine(x1, ym - 5, x1, ym + 5, 1);
                    g.drawLine(x0, ym, x1, ym, 1);
                    }
                ry += RowH();
                }
            i32 cardH = HeadH() + (gj - gi) * RowH() - 8;
            y += cardH + 16;
            gi = gj;
            }
        String* legend = BHelp.S((u8*)"bar = value    error bar = one standard deviation    label = machine");
        g.drawTextRGBA(legend.cString(), 12, y + 4, 110, 110, 118, 255, 11);
        }

    // A round step, so the axis labels read 1, 2, 5, 10, 20, ...
    static double niceStep(double peak)
        {
        double raw = peak / 5.0;
        double mag = 1.0;
        while (mag * 10.0 <= raw) { mag *= 10.0; }
        while (mag > raw && mag > 0.00001) { mag /= 10.0; }
        double n = raw / mag;
        double m = n < 1.5 ? 1.0 : (n < 3.5 ? 2.0 : (n < 7.5 ? 5.0 : 10.0));
        return m * mag;
        }
    }
