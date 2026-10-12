// Model.xc — the contribution model for the benchmark visualiser.
//
// A "contribution" is one machine's run of the benchmark suites, in the JSON
// shape benchmark/diy.py writes (schema "xc-bench/1").  A DataSet is the
// local contribution merged with any user contributions downloaded from the
// server.  Nothing here touches the toolkit: parsing, statistics and the
// filter are plain xc, so the model can be exercised head-less.
//
// Imported by Visualiser.xc.

#import <Stdio.xc>
#import "JSON.xc"
#import "Files.xc"
#import "Math.xc"

// ---- small helpers -------------------------------------------------------

class BHelp
    {
    // A String from a C literal, so a key can be read without a temporary.
    static String* S(u8* s)
        {
        return String.withCString(s);
        }

    // The text view of any JSON scalar: a String as itself, a Number and a
    // bool through description, anything else null.
    static String* text(Object* v)
        {
        if (v == (Object*)0)
            {
            return (String*)0;
            }
        String* s = (String* ?)v;
        if (s != (String*)0)
            {
            return s;
            }
        Number* n = (Number* ?)v;
        if (n != (Number*)0)
            {
            return n.description();
            }
        return (String*)0;
        }

    static String* field(Map* m, u8* key)
        {
        if (m == (Map*)0)
            {
            return (String*)0;
            }
        return text(m.get(S(key)));
        }

    static i64 intField(Map* m, u8* key, i64 dflt)
        {
        if (m == (Map*)0)
            {
            return dflt;
            }
        Number* n = (Number* ?)m.get(S(key));
        return n == (Number*)0 ? dflt : n.asI64();
        }

    // Does `hay` contain `needle`, ignoring case?  An empty needle matches.
    static bool contains(String* hay, String* needle)
        {
        if (needle == (String*)0 || needle.isEmpty())
            {
            return true;
            }
        if (hay == (String*)0)
            {
            return false;
            }
        return hay.lowercased().contains(needle.lowercased());
        }

    // The Device filter's menu shows friendly names; a run stores the raw one.
    static String* deviceCode(String* d)
        {
        if (d.equalsIgnoringCase(S((u8*)"one thread")))  { return S((u8*)"serial"); }
        if (d.equalsIgnoringCase(S((u8*)"all threads"))) { return S((u8*)"cpu"); }
        if (d.equalsIgnoringCase(S((u8*)"GPU")))         { return S((u8*)"gpu"); }
        if (d.equalsIgnoringCase(S((u8*)"Vulkan")))      { return S((u8*)"vulkan"); }
        return d;   // "auto", or an already-raw device string
        }

    // matrix_mul_f32 is an outlier in every comparison: xcc replaces its loop
    // nest with a matrix kernel of its own, so it is tens to hundreds of times
    // faster on one side.  The summary's scale and the heat map's geometric
    // mean leave it out, so it cannot swamp every other test.
    static bool isOutlier(String* benchmark)
        {
        return benchmark != (String*)0 && benchmark.equalsIgnoringCase(S((u8*)"matrix_mul_f32"));
        }

    static String* join(u8* a, String* b)
        {
        return (a == (u8*)0) ? b : String.withFormat((string)a, b.cString());
        }
    }

// ---- a machine -----------------------------------------------------------

class Machine
    {
    String* os;
    String* arch;
    String* cpu;
    String* gpu;
    String* gpuDriver;
    i64     memoryMb;

    void init(void)
        {
        os = arch = cpu = gpu = gpuDriver = (String*)0;
        memoryMb = 0;
        }

    String* label(void)
        {
        String* core = (cpu != (String*)0) ? String.withString(cpu) : String.withCString("unknown CPU");
        if (gpu != (String*)0 && !gpu.isEmpty())
            {
            core.appendCString(" + ");
            core.append(gpu);
            }
        return core;
        }

    String* summary(void)
        {
        String* s = String.withCString("");
        if (os != (String*)0)      { s.appendCString("OS ");     s.append(os);     }
        if (arch != (String*)0)    { s.appendCString("  arch "); s.append(arch);   }
        if (memoryMb > 0)     { s.appendCString("  ");      s.append(String.withI64(memoryMb / 1024)); s.appendCString(" GB"); }
        if (gpuDriver != (String*)0 && !gpuDriver.isEmpty()) { s.appendCString("  driver "); s.append(gpuDriver); }
        return s;
        }
    }

// ---- one timed data point ------------------------------------------------

class Run
    {
    String* suite;      // "langs" or "par"
    String* benchmark;  // int_accum, nbody, ...
    String* target;     // xc, objc, cpp, gcc, swift
    String* device;     // cpu (langs); serial, cpu, gpu, vulkan, auto (par)
    String* opt;        // O0 .. O3
    String* arch;       // arm64, x86_64, win64, wasm32, arm64+browser
    Map*    params;     // the exact environment the run used
    Array*  samples;    // Number, microseconds, one per repeat
    i64     bestUs;
    i64     firstUs;    // par only: the first run, which carries one-off costs
    double  meanUs;
    double  stddevUs;
    String* checksum;

    void init(void)
        {
        suite = benchmark = target = device = opt = arch = checksum = (String*)0;
        params = new Map();
        samples = new Array();
        bestUs = firstUs = 0;
        meanUs = stddevUs = 0.0;
        }

    void compute(void)
        {
        i32 n = samples.count();
        if (n == 0)
            {
            meanUs = stddevUs = 0.0;
            return;
            }
        i64 sum = 0;
        for (i32 i = 0; i < n; i++)
            {
            sum += ((Number*)samples.get(i)).asI64();
            }
        meanUs = (double)sum / (double)n;
        double var = 0.0;
        for (i32 i = 0; i < n; i++)
            {
            double d = (double)((Number*)samples.get(i)).asI64() - meanUs;
            var += d * d;
            }
        stddevUs = n > 1 ? Math.sqrt(var / (double)n) : 0.0;
        }

    bool isGpu(void)
        {
        return device != (String*)0 && (device.contains(BHelp.S((u8*)"gpu"))
                                     || device.contains(BHelp.S((u8*)"vulkan")));
        }

    String* key(void)
        {
        return String.withFormat((string)"%s/%s/%s/%s", benchmark.cString(),
                                 target.cString(), device.cString(), opt.cString());
        }

    // The measured value in microseconds that the chart draws: the best run,
    // unless firstUs is asked for (the one-off-cost run).
    double value(bool useFirst)
        {
        if (useFirst && firstUs > 0)
            {
            return (double)firstUs;
            }
        return bestUs > 0 ? (double)bestUs : meanUs;
        }
    }

// ---- a contribution: one machine's JSON ---------------------------------

class Contribution
    {
    String* schema;
    String* id;
    String* collected;
    String* source;     // where it was read from, on screen
    Map*    root;       // the original JSON object, kept for re-submission
    Machine* machine;
    Map*    toolchains;
    i32     repeats;
    Array*  runs;       // Run

    void init(void)
        {
        schema = id = collected = source = (String*)0;
        root = (Map*)0;
        machine = new Machine();
        toolchains = new Map();
        repeats = 0;
        runs = new Array();
        }

    static Contribution* fromRoot(Map* o, String* source)
        {
        Contribution* c = new Contribution();
        c.root = o;
        c.source = source;
        c.schema = BHelp.field(o, (u8*)"schema");
        c.id = BHelp.field(o, (u8*)"id");
        c.collected = BHelp.field(o, (u8*)"collected");
        c.repeats = BHelp.intField(o, (u8*)"repeats", 0);
        Map* mach = (Map* ?)o.get(BHelp.S((u8*)"machine"));
        if (mach != (Map*)0)
            {
            c.machine.os = BHelp.field(mach, (u8*)"os");
            c.machine.arch = BHelp.field(mach, (u8*)"arch");
            c.machine.cpu = BHelp.field(mach, (u8*)"cpu");
            c.machine.gpu = BHelp.field(mach, (u8*)"gpu");
            c.machine.gpuDriver = BHelp.field(mach, (u8*)"gpu_driver");
            c.machine.memoryMb = BHelp.intField(mach, (u8*)"memory_mb", 0);
            }
        Map* tc = (Map* ?)o.get(BHelp.S((u8*)"toolchains"));
        if (tc != (Map*)0)
            {
            c.toolchains = tc;
            }
        Array* runs = (Array* ?)o.get(BHelp.S((u8*)"runs"));
        if (runs == (Array*)0)
            {
            return c;
            }
        for (u32 i = 0; i < runs.count(); i++)
            {
            Map* ro = (Map* ?)runs.get(i);
            if (ro == (Map*)0)
                {
                continue;
                }
            Run* r = new Run();
            r.suite = BHelp.field(ro, (u8*)"suite");
            r.benchmark = BHelp.field(ro, (u8*)"benchmark");
            r.target = BHelp.field(ro, (u8*)"target");
            r.device = BHelp.field(ro, (u8*)"device");
            r.opt = BHelp.field(ro, (u8*)"opt");
            r.arch = BHelp.field(ro, (u8*)"arch");
            r.checksum = BHelp.field(ro, (u8*)"checksum");
            r.bestUs = BHelp.intField(ro, (u8*)"best_us", 0);
            r.firstUs = BHelp.intField(ro, (u8*)"first_us", 0);
            Map* pm = (Map* ?)ro.get(BHelp.S((u8*)"params"));
            if (pm != (Map*)0)
                {
                r.params = pm;
                }
            Array* sm = (Array* ?)ro.get(BHelp.S((u8*)"samples_us"));
            if (sm != (Array*)0)
                {
                r.samples = sm;
                }
            r.compute();
            c.runs.add(r);
            }
        return c;
        }

    static Contribution* fromFile(String* path)
        {
        String* txt = Files.readText(path);
        if (txt == (String*)0)
            {
            return (Contribution*)0;
            }
        return fromText(txt, path);
        }

    static Contribution* fromText(String* txt, String* source)
        {
        try
            {
            Map* o = (Map* ?)JSON.parse(txt);
            if (o == (Map*)0)
                {
                return (Contribution*)0;
                }
            return fromRoot(o, source);
            }
        catch (JSONError e)
            {
            return (Contribution*)0;
            }
        }
// ---- reading the project's own results.json files -------------------------
//
// diy.py writes the contribution shape ("xc-bench/1"), which carries the
// machine and every repeat's time.  The published files are a different shape
// and carry less: run.py writes {version, platform, repeats, raw, net} with one
// best time per benchmark, level and language, and par/run.py writes
// {benchmark: {machine: {checksum, mode: {best_us, first_us}}}}.  These are read
// here too, so the results already on the site open without re-measuring.  A
// file with one time per point has no spread to draw, so its bars carry no
// error bar.

    static Map* paramsLang(String* lang, String* opt, String* arch)
        {
        Map* p = new Map();
        p.set(BHelp.S((u8*)"lang"), lang);
        p.set(BHelp.S((u8*)"opt"), opt);
        p.set(BHelp.S((u8*)"arch"), arch);
        return p;
        }

    static Map* paramsPar(String* mode)
        {
        Map* p = new Map();
        if (mode.equalsIgnoringCase(BHelp.S((u8*)"serial")))
            {
            p.set(BHelp.S((u8*)"XC_PAR"), BHelp.S((u8*)"cpu"));
            p.set(BHelp.S((u8*)"XC_PAR_THREADS"), BHelp.S((u8*)"1"));
            }
        else if (mode.equalsIgnoringCase(BHelp.S((u8*)"cpu")))
            {
            p.set(BHelp.S((u8*)"XC_PAR"), BHelp.S((u8*)"cpu"));
            }
        else if (mode.equalsIgnoringCase(BHelp.S((u8*)"gpu")))
            {
            p.set(BHelp.S((u8*)"XC_PAR"), BHelp.S((u8*)"gpu"));
            }
        else if (mode.equalsIgnoringCase(BHelp.S((u8*)"vulkan")))
            {
            p.set(BHelp.S((u8*)"XC_PAR"), BHelp.S((u8*)"gpu"));
            p.set(BHelp.S((u8*)"XC_PAR_GPU"), BHelp.S((u8*)"vulkan"));
            }
        p.set(BHelp.S((u8*)"opt"), BHelp.S((u8*)"O3"));
        return p;
        }

    static String* parMachineName(String* key)
        {
        if (key.equalsIgnoringCase(BHelp.S((u8*)"mac")))     { return BHelp.S((u8*)"macOS (arm64)"); }
        if (key.equalsIgnoringCase(BHelp.S((u8*)"linux")))   { return BHelp.S((u8*)"Linux (x86-64)"); }
        if (key.equalsIgnoringCase(BHelp.S((u8*)"windows"))) { return BHelp.S((u8*)"Windows (x86-64)"); }
        if (key.equalsIgnoringCase(BHelp.S((u8*)"browser"))) { return BHelp.S((u8*)"Chrome (wasm32)"); }
        return key;
        }

    // run.py's results.json: {version, platform, repeats, raw, net}.  The file
    // holds two machines in one: the host (`platform`) and the x86-64 host (the
    // `_x86_64` legs).  Their times are not comparable, so one contribution is
    // made per architecture.
    static String* langArch(String* lang, String* platform)
        {
        return lang.hasSuffix(BHelp.S((u8*)"_x86_64")) ? BHelp.S((u8*)"x86_64") : platform;
        }

    static String* langTarget(String* lang)
        {
        return lang.hasSuffix(BHelp.S((u8*)"_x86_64"))
             ? lang.substringToByte(lang.byteLength() - 7) : lang;
        }

    static Array* fromRunJSON(Map* o, String* source)
        {
        Array* out = new Array();
        Map* data = (Map* ?)o.get(BHelp.S((u8*)"net"));
        if (data == (Map*)0) { data = (Map* ?)o.get(BHelp.S((u8*)"raw")); }
        if (data == (Map*)0) { return out; }
        String* platform = BHelp.field(o, (u8*)"platform");
        if (platform == (String*)0) { platform = BHelp.S((u8*)"unknown"); }
        String* version = BHelp.field(o, (u8*)"version");
        i32 repeats = BHelp.intField(o, (u8*)"repeats", 0);
        Array* benches = data.allKeys();
        // The architectures present, in the order they first appear.
        Array* arches = new Array();
        for (u32 i = 0; i < benches.count(); i++)
            {
            Map* byOpt = (Map* ?)data.get((String*)benches.get(i));
            if (byOpt == (Map*)0) { continue; }
            Array* opts = byOpt.allKeys();
            for (u32 j = 0; j < opts.count(); j++)
                {
                Map* byLang = (Map* ?)byOpt.get((String*)opts.get(j));
                if (byLang == (Map*)0) { continue; }
                Array* langs = byLang.allKeys();
                for (u32 k = 0; k < langs.count(); k++)
                    {
                    String* a = langArch((String*)langs.get(k), platform);
                    bool seen = false;
                    for (u32 s = 0; s < arches.count(); s++)
                        {
                        if (((String*)arches.get(s)).equalsIgnoringCase(a)) { seen = true; break; }
                        }
                    if (!seen) { arches.add(a); }
                    }
                }
            }
        for (u32 ai = 0; ai < arches.count(); ai++)
            {
            String* a = (String*)arches.get(ai);
            Contribution* c = new Contribution();
            c.root = o;
            c.source = source;
            c.schema = BHelp.S((u8*)"run.py");
            c.id = version == (String*)0 ? a
                 : String.withFormat((string)"%s %s", version.cString(), a.cString());
            c.repeats = repeats;
            c.machine.os = version;
            c.machine.arch = a;
            c.machine.cpu = a;
            for (u32 i = 0; i < benches.count(); i++)
                {
                String* b = (String*)benches.get(i);
                if (b.equalsIgnoringCase(BHelp.S((u8*)"baseline"))) { continue; }
                Map* byOpt = (Map* ?)data.get(b);
                if (byOpt == (Map*)0) { continue; }
                Array* opts = byOpt.allKeys();
                for (u32 j = 0; j < opts.count(); j++)
                    {
                    String* opt = (String*)opts.get(j);
                    Map* byLang = (Map* ?)byOpt.get(opt);
                    if (byLang == (Map*)0) { continue; }
                    Array* langs = byLang.allKeys();
                    for (u32 k = 0; k < langs.count(); k++)
                        {
                        String* lang = (String*)langs.get(k);
                        if (!langArch(lang, platform).equalsIgnoringCase(a)) { continue; }
                        Number* secs = (Number* ?)byLang.get(lang);
                        if (secs == (Number*)0) { continue; }
                        i64 us = secs.asDouble() * 1000000.0 + 0.5;
                        Run* r = new Run();
                        r.suite = BHelp.S((u8*)"langs");
                        r.benchmark = b;
                        r.target = langTarget(lang);
                        r.device = BHelp.S((u8*)"cpu");
                        r.opt = opt;
                        r.arch = a;
                        r.params = paramsLang(r.target, opt, a);
                        r.samples.add(Number.withI64(us));
                        r.bestUs = us;
                        r.checksum = BHelp.S((u8*)"");
                        r.compute();
                        c.runs.add(r);
                        }
                    }
                }
            if (c.runs.count() > 0) { out.add(c); }
            }
        return out;
        }

    static bool looksPar(Map* o)
        {
        Array* benchKeys = o.allKeys();
        for (u32 i = 0; i < benchKeys.count(); i++)
            {
            Map* bm = (Map* ?)o.get((String*)benchKeys.get(i));
            if (bm == (Map*)0) { continue; }
            Array* mk = bm.allKeys();
            for (u32 j = 0; j < mk.count(); j++)
                {
                Map* mm = (Map* ?)bm.get((String*)mk.get(j));
                if (mm != (Map*)0 && mm.get(BHelp.S((u8*)"checksum")) != (Object*)0) { return true; }
                }
            }
        return false;
        }

    // par/run.py's results.json: {benchmark: {machine: {checksum, mode: {...}}}}.
    // One contribution per machine.
    static Array* fromParJSON(Map* o, String* source)
        {
        Array* out = new Array();
        Array* benchKeys = o.allKeys();
        Array* machines = new Array();
        for (u32 i = 0; i < benchKeys.count(); i++)
            {
            Map* bm = (Map* ?)o.get((String*)benchKeys.get(i));
            if (bm == (Map*)0) { continue; }
            Array* mk = bm.allKeys();
            for (u32 j = 0; j < mk.count(); j++)
                {
                String* m = (String*)mk.get(j);
                bool seen = false;
                for (u32 s = 0; s < machines.count(); s++)
                    {
                    if (((String*)machines.get(s)).equalsIgnoringCase(m)) { seen = true; break; }
                    }
                if (!seen) { machines.add(m); }
                }
            }
        for (u32 mi = 0; mi < machines.count(); mi++)
            {
            String* m = (String*)machines.get(mi);
            Contribution* c = new Contribution();
            c.root = o;
            c.source = source;
            c.schema = BHelp.S((u8*)"par.py");
            c.id = m;
            c.machine.cpu = parMachineName(m);
            c.machine.os = c.machine.cpu;
            c.machine.arch = m;
            for (u32 i = 0; i < benchKeys.count(); i++)
                {
                String* b = (String*)benchKeys.get(i);
                Map* bm = (Map* ?)o.get(b);
                Map* mm = bm == (Map*)0 ? (Map*)0 : (Map* ?)bm.get(m);
                if (mm == (Map*)0) { continue; }
                String* checksum = BHelp.field(mm, (u8*)"checksum");
                Array* modes = mm.allKeys();
                for (u32 j = 0; j < modes.count(); j++)
                    {
                    String* mode = (String*)modes.get(j);
                    if (mode.equalsIgnoringCase(BHelp.S((u8*)"checksum"))) { continue; }
                    Map* md = (Map* ?)mm.get(mode);
                    if (md == (Map*)0) { continue; }
                    i64 best = BHelp.intField(md, (u8*)"best_us", 0);
                    i64 first = BHelp.intField(md, (u8*)"first_us", 0);
                    Run* r = new Run();
                    r.suite = BHelp.S((u8*)"par");
                    r.benchmark = b;
                    r.target = BHelp.S((u8*)"xc");
                    r.device = mode;
                    r.opt = BHelp.S((u8*)"O3");
                    r.arch = m;
                    r.params = paramsPar(mode);
                    r.samples.add(Number.withI64(best));
                    r.bestUs = best;
                    r.firstUs = first;
                    r.checksum = checksum == (String*)0 ? BHelp.S((u8*)"") : checksum;
                    r.compute();
                    c.runs.add(r);
                    }
                }
            if (c.runs.count() > 0) { out.add(c); }
            }
        return out;
        }

    // Read any of the shapes the project writes: one contribution, run.py's
    // results.json, par/run.py's results.json, or a corpus object.
    static Array* loadText(String* txt, String* source)
        {
        if (txt == (String*)0) { return new Array(); }
        Object* parsed = (Object*)0;
        try
            {
            parsed = JSON.parse(txt);
            }
        catch (JSONError e)
            {
            return new Array();
            }
        return loadObject(parsed, source);
        }

    // The same, from parsed JSON.  A corpus object is the server's reply:
    // the submitted contributions, and under "published" the project's own
    // results files, in run.py's and par/run.py's shapes.
    static Array* loadObject(Object* parsed, String* source)
        {
        Array* out = new Array();
        Array* arr = (Array* ?)parsed;
        if (arr != (Array*)0)
            {
            for (u32 i = 0; i < arr.count(); i++)
                {
                Map* e = (Map* ?)arr.get(i);
                if (e != (Map*)0) { out.add(fromRoot(e, source)); }
                }
            return out;
            }
        Map* o = (Map* ?)parsed;
        if (o == (Map*)0) { return out; }
        Array* clist = (Array* ?)o.get(BHelp.S((u8*)"contributions"));
        if (clist != (Array*)0)
            {
            for (u32 i = 0; i < clist.count(); i++)
                {
                Map* e = (Map* ?)clist.get(i);
                if (e != (Map*)0) { out.add(fromRoot(e, source)); }
                }
            Array* plist = (Array* ?)o.get(BHelp.S((u8*)"published"));
            if (plist != (Array*)0)
                {
                for (u32 i = 0; i < plist.count(); i++)
                    {
                    Array* more = loadObject(plist.get(i), BHelp.S((u8*)"published"));
                    for (u32 j = 0; j < more.count(); j++) { out.add(more.get(j)); }
                    }
                }
            return out;
            }
        String* schema = BHelp.field(o, (u8*)"schema");
        if (schema != (String*)0 && schema.equalsIgnoringCase(BHelp.S((u8*)"xc-bench/1")))
            {
            out.add(fromRoot(o, source));
            return out;
            }
        if ((Map* ?)o.get(BHelp.S((u8*)"net")) != (Map*)0
            || (Map* ?)o.get(BHelp.S((u8*)"raw")) != (Map*)0)
            {
            Array* rs = fromRunJSON(o, source);
            for (u32 i = 0; i < rs.count(); i++) { out.add(rs.get(i)); }
            return out;
            }
        if (looksPar(o)) { return fromParJSON(o, source); }
        return out;
        }

    // The same, from a file.
    static Array* loadAll(String* path)
        {
        return loadText(Files.readText(path), path);
        }

    }

// ---- the whole data set --------------------------------------------------

class DataSet
    {
    Array* contributions;   // Contribution

    void init(void) { contributions = new Array(); }

    void add(Contribution* c) { contributions.add(c); }

    u32 count(void) { return contributions.count(); }

    Contribution* at(u32 i) { return (Contribution*)contributions.get(i); }

    // Every run of every contribution, in order.
    Array* runs(void)
        {
        Array* out = new Array();
        for (u32 i = 0; i < contributions.count(); i++)
            {
            Contribution* c = (Contribution*)contributions.get(i);
            for (u32 j = 0; j < c.runs.count(); j++)
                {
                out.add(c.runs.get(j));
                }
            }
        return out;
        }
    }

// ---- the filter ----------------------------------------------------------

class Filter
    {
    String* cpu;     // substring, case-insensitive; empty = any
    String* gpu;     // substring, case-insensitive; empty = any
    String* suite;   // "" = any
    String* device;  // "" = any; also the literal "CPU only" / "GPU only"
    String* opt;     // "" = any
    String* arch;    // "" = any

    void init(void) { cpu = gpu = suite = device = opt = arch = (String*)0; }

    bool matches(Contribution* c, Run* r)
        {
        if (cpu != (String*)0 && !BHelp.contains(c.machine.cpu, cpu))
            {
            return false;
            }
        if (gpu != (String*)0 && !gpu.isEmpty())
            {
            if (!BHelp.contains(c.machine.gpu, gpu))
                {
                return false;
                }
            }
        if (suite != (String*)0 && !suite.isEmpty() && r.suite != (String*)0
            && !r.suite.equalsIgnoringCase(suite))
            {
            return false;
            }
        if (opt != (String*)0 && !opt.isEmpty() && r.opt != (String*)0
            && !r.opt.equalsIgnoringCase(opt))
            {
            return false;
            }
        if (arch != (String*)0 && !arch.isEmpty() && r.arch != (String*)0
            && !r.arch.equalsIgnoringCase(arch))
            {
            return false;
            }
        if (device != (String*)0 && !device.isEmpty())
            {
            if (device.equalsIgnoringCase(BHelp.S((u8*)"GPU only")))
                {
                if (!r.isGpu()) { return false; }
                }
            else if (device.equalsIgnoringCase(BHelp.S((u8*)"CPU only")))
                {
                if (r.isGpu()) { return false; }
                }
            else if (r.device == (String*)0 || !r.device.equalsIgnoringCase(BHelp.deviceCode(device)))
                {
                return false;
                }
            }
        return true;
        }
    }
