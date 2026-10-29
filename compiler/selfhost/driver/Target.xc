// Target.xc — the target table: one row per target, found by its -A token.
// =========================================================================
//
// private:docs/Design/targets.md. A target is named by one token, canonical
// `cpu-os[-env|-libc]` (arm64-macos, x86_64-linux, arm64-android, ...), with
// today's short names and the gcc/clang triples as aliases of the same row.
// The reference's XTTarget holds the same rows, field for field.
//
// Step 1: the rows name the target and carry `legacy`, the arch string the
// rest of the driver still tests (d.arch()); the decisions move onto row
// fields one group at a time after this.

#import "Foundation.xc"

class TargetRow
    {
    String* _name;      // canonical token
    Array* _aliases;    // of String*: other spellings -A takes for this row
    String* _cpu;       // arm64, x86_64, armv7, wasm32, m68k, 6502
    u32 _cpuVariant;    // 68000 / 68030 on m68k; 0 elsewhere
    String* _os;        // macos, ios, android, linux, windows, xtos, web, tos, xt
    String* _env;       // simulator, or 0
    String* _libc;      // darwin, bionic, glibc, musl, msvcrt, xtos, none
    String* _legacy;    // the arch string the driver tests today (d.arch())
    String* _backend;   // platform key: front end target, opt profile (arm64, x86_64, win64, arm9, atarist, wasm32, xt6502)
    String* _codegen;   // the code generator, xcc-cg-<codegen> in the reference
    Array* _supportChain; // of String*: support/<dir>/lib before generic, in order; empty for 6502 (its layout names it)
    String* _platformLayer; // the third-party tree's platform layer before the arch's (ios, ios-sim, android), or 0

    void init(void)
        {
        _aliases = new Array();
        _cpuVariant = (u32)0;
        _env = (String*)0;
        }

    String* name(void)     { return _name; }
    Array* aliases(void)   { return _aliases; }
    String* cpu(void)      { return _cpu; }
    u32 cpuVariant(void)   { return _cpuVariant; }
    String* os(void)       { return _os; }
    String* env(void)      { return _env; }
    String* libc(void)     { return _libc; }
    String* legacy(void)   { return _legacy; }
    String* backend(void)  { return _backend; }
    String* codegen(void)  { return _codegen; }
    Array* supportChain(void) { return _supportChain; }
    String* platformLayer(void) { return _platformLayer; }

    // A row: name, cpu, cpu variant, os, env (or ""), libc, legacy arch, then
    // its aliases separated by spaces.
    static TargetRow* make(string name, string cpu, u32 variant, string os, string env,
                           string libc, string legacy, string backend, string codegen, string chain, string layer, string aliases)
        {
        TargetRow* r = new TargetRow();
        r._name = String.withCString(name);
        r._cpu = String.withCString(cpu);
        r._cpuVariant = variant;
        r._os = String.withCString(os);
        String* e = String.withCString(env);
        r._env = e.byteLength() == (u32)0 ? (String*)0 : e;
        r._libc = String.withCString(libc);
        r._legacy = String.withCString(legacy);
        r._backend = String.withCString(backend);
        r._codegen = String.withCString(codegen);
        r._supportChain = TargetRow.words(String.withCString(chain));
        String* ly = String.withCString(layer);
        r._platformLayer = ly.byteLength() == (u32)0 ? (String*)0 : ly;
        r._aliases = TargetRow.words(String.withCString(aliases));
        return r;
        }

    // The space-separated words of s.
    static Array* words(String* s)
        {
        Array* out = new Array();
        u32 start = (u32)0;
        for (u32 i = (u32)0; i <= s.byteLength(); i = i + (u32)1)
            {
            if (i == s.byteLength() || s.byteAt(i) == (u8)' ')
                {
                if (i > start)
                    out.add((Object*)s.substringBytes(start, i - start));
                start = i + (u32)1;
                }
            }
        return out;
        }

    // `--print-target`: the row, one field per line, in the order both
    // compilers print it.
    String* describe(void)
        {
        String* s = new String();
        s.appendFormat("target %s\n", _name.cString());
        s.appendFormat("cpu %s\n", _cpu.cString());
        if (_cpuVariant != (u32)0)
            s.appendFormat("cpu-variant %lu\n", _cpuVariant);
        s.appendFormat("os %s\n", _os.cString());
        if (_env != (String*)0)
            s.appendFormat("env %s\n", _env.cString());
        s.appendFormat("libc %s\n", _libc.cString());
        s.appendFormat("legacy %s\n", _legacy.cString());
        s.appendFormat("backend %s\n", _backend.cString());
        s.appendFormat("codegen %s\n", _codegen.cString());
        if (_platformLayer != (String*)0)
            s.appendFormat("platform-layer %s\n", _platformLayer.cString());
        s.appendCString("support");
        for (u32 i = (u32)0; i < _supportChain.count(); i = i + (u32)1)
            s.appendFormat(" %s", ((String*)_supportChain.get(i)).cString());
        s.appendCString("\n");
        s.appendCString("aliases");
        for (u32 i = (u32)0; i < _aliases.count(); i = i + (u32)1)
            s.appendFormat(" %s", ((String*)_aliases.get(i)).cString());
        s.appendCString("\n");
        return s;
        }
    }

class Targets
    {
    // The rows, in this order in both compilers.
    static Array* rows(void)
        {
        Array* t = new Array();
        t.add((Object*)TargetRow.make("arm64-macos", "arm64", (u32)0, "macos", "", "darwin", "arm64", "arm64", "arm64", "arm64", "",
                                      "arm64 aarch64-apple-darwin arm64-apple-macos arm64-apple-darwin"));
        t.add((Object*)TargetRow.make("arm64-ios", "arm64", (u32)0, "ios", "", "darwin", "ios", "arm64", "arm64", "ios arm64", "ios",
                                      "ios arm64-apple-ios"));
        t.add((Object*)TargetRow.make("arm64-ios-sim", "arm64", (u32)0, "ios", "simulator", "darwin", "ios-sim", "arm64", "arm64", "ios arm64", "ios-sim",
                                      "ios-sim arm64-apple-ios-simulator"));
        t.add((Object*)TargetRow.make("arm64-android", "arm64", (u32)0, "android", "", "bionic", "android", "arm64", "arm64", "arm64", "android",
                                      "android aarch64-linux-android"));
        t.add((Object*)TargetRow.make("x86_64-linux", "x86_64", (u32)0, "linux", "", "glibc", "x86_64", "x86_64", "x86_64", "x86_64", "",
                                      "x86_64 x86-64 amd64 x86_64-linux-gnu x86_64-pc-linux-gnu"));
        t.add((Object*)TargetRow.make("x86_64-windows", "x86_64", (u32)0, "windows", "", "msvcrt", "win64", "win64", "win64", "win64 x86_64", "",
                                      "win64 windows x86_64-w64-mingw32 x86_64-w64-windows-gnu x86_64-pc-windows-gnu"));
        t.add((Object*)TargetRow.make("armv7-xtos", "armv7", (u32)0, "xtos", "", "xtos", "arm9", "arm9", "arm9", "arm9", "",
                                      "arm9 armv7 armv7-a cortex-a9"));
        t.add((Object*)TargetRow.make("wasm32-web", "wasm32", (u32)0, "web", "", "none", "wasm32", "wasm32", "wasm32", "wasm32", "",
                                      "wasm32 wasm wasm32-unknown-unknown"));
        t.add((Object*)TargetRow.make("m68k-tos", "m68k", (u32)68000, "tos", "", "none", "m68k", "atarist", "68k", "atarist", "",
                                      "m68k 68000 atarist m68k-atari-tos"));
        t.add((Object*)TargetRow.make("m68030-tos", "m68k", (u32)68030, "tos", "", "none", "m68k", "atarist", "68k", "atarist", "",
                                      "68030"));
        t.add((Object*)TargetRow.make("6502-xt", "6502", (u32)0, "xt", "", "none", "xt6502", "xt6502", "6502", "", "",
                                      "6502 xt6502 xt"));
        return t;
        }

    // The row a -A token names (its canonical name or an alias), or 0.
    static TargetRow* find(String* token)
        {
        Array* t = rows();
        for (u32 i = (u32)0; i < t.count(); i = i + (u32)1)
            {
            TargetRow* r = (TargetRow*)t.get(i);
            if (r.name().equals(token))
                return r;
            for (u32 j = (u32)0; j < r.aliases().count(); j = j + (u32)1)
                if (((String*)r.aliases().get(j)).equals(token))
                    return r;
            }
        return (TargetRow*)0;
        }
    }
