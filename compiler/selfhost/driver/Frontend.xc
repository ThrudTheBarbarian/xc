// Frontend.xc — preprocess, lex, parse, analyse, lower. SHARED.
// =================================================================
//
// This was the body of xtfe's main(), and it moved here the moment a second
// tool needed it: `xcc`, the driver written in xtc, runs exactly this and then
// keeps going into the optimiser and a back end.
//
// Two copies of a pipeline whose stages must agree about pointer width, vtable
// shape and which targets carry an itable is precisely the drift this project
// keeps finding, so there is ONE copy and both tools call it. The CLI stays
// with each tool — xtfe takes the front end's own small flag set, xcc takes the
// driver's — because that is the part that genuinely differs.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "TokenType.xc"
#import "Token.xc"
#import "Lexer.xc"
#import "FloatEncoding.xc"
#import "MacroDef.xc"
#import "Preprocessor.xc"
#import "Node.xc"
#import "Parser.xc"
#import "AstDump.xc"
#import "Mangle.xc"
#import "Iface.xc"
#import "IfaceWrite.xc"
#import "Dwarf.xc" // …and a C library's own DWARF, when it has no iface
#import "Analyze.xc"
#import "Sema.xc"
#import "Vtable.xc"
#import "Ir.xc"
#import "Lower.xc"
#import "Designable.xc"

// has to be built TWICE (once to find `%@`, once for real) and the two must be
// built identically or the gate is decided against a different program.
class FeOptions
    {
    String* _input;
    String* _output;
    String* _target;      // arm64 / arm9 / atarist / x86_64 / win64 / xt6502
    String* _libPlatform; // ios / ios-sim: the platform LAYER searched before the arch tree (iOS.md stage 4)
    String* _home;        // -H, or 0 for the search list
    Array* _incs;
    Array* _defs;
    Array* _libs; // -L dirs: `.xtc.iface` side files resolve here
    bool _verbose;
    bool _boundsCheck; // -fbounds-check
    i32 _threadSafeArc; // -f[no-]thread-safe-arc: 1 on, 0 off, -1 decide per module
    bool _emitIface;   // compute the module interface (--emit-lib, -c, --emit-iface)
    // …and, SEPARATELY, whether this is a LIBRARY build. The two used to be one
    // flag, so `--emit-iface` — which only asks what the source declares —
    // silently switched the slot numbering into library mode and reported a
    // numbering no build of this module would ever use. The reference keeps
    // them apart: `--emit-lib` and `-c` are library builds, `--emit-iface` is
    // a question.
    bool _libraryBuild;
    bool _analyze;      // -Wanalyze: run the static analyser
    String* _ifaceJson; // …and where it lands
    Array* _neededLibs; // the library FILES `#import <X>` resolved to, for the
                        //   driver: a wasm app's loader has to name the
                        //   modules it will fetch, and only the preprocessor
                        //   knows which ones the source asked for
    String* _migrate;   // --migrate=<base>:<to> — compile as if the library
                        //   were still <base>, so a call whose MEANING changed
                        //   between the two fails loudly instead of quietly
                        //   resolving to the new one. 0 when not asked for.
    String* _ppOut;     // -E <path>: where the preprocessed source goes, or 0

    void init(void)
        {
        _ppOut = (String*)0;
        _emitIface = false;
        _libraryBuild = false;
        _analyze = false;
        _ifaceJson = (String*)0;
        _neededLibs = new Array();
        _target = String.withCString("xt6502");
        _libPlatform = (String*)0;
        _incs = new Array();
        _defs = new Array();
        _libs = new Array();
        _verbose = false;
        _migrate = (String*)0;
        _boundsCheck = false;
        _threadSafeArc = (i32)-1;
        }

    String* input(void)
        {
        return _input;
        }
    String* output(void)
        {
        return _output;
        }
    String* target(void)
        {
        return _target;
        }
    String* home(void)
        {
        return _home;
        }
    Array* incs(void)
        {
        return _incs;
        }
    Array* defs(void)
        {
        return _defs;
        }
    Array* libs(void)
        {
        return _libs;
        }
    bool verbose(void)
        {
        return _verbose;
        }
    String* migrate(void)
        {
        return _migrate;
        }
    bool boundsCheck(void)
        {
        return _boundsCheck;
        }
    i32 threadSafeArc(void)
        {
        return _threadSafeArc;
        }
    bool analyze(void)
        {
        return _analyze;
        }
    void setAnalyze(bool b)
        {
        _analyze = b;
        }

    // `-Wno-<category>` suppressions, by the reference's category names. The
    // port accepted no -W flag at all and REJECTED `-Wno-anything` outright as
    // an unrecognised option — so a user following the documented advice got a
    // hard build failure from the shipped compiler while the reference quietly
    // did as asked (bug 211).
    Array* _wno;
    void suppressWarning(String* cat)
        {
        if (_wno == (Array*)0)
            _wno = new Array();
        _wno.add((Object*)String.withString(cat));
        }
    bool warningSuppressed(String* cat)
        {
        if (_wno == (Array*)0 || cat == (String*)0)
            return false;
        for (u32 i = (u32)0; i < _wno.count(); i = i + (u32)1)
            if (((String*)_wno.get(i)).equals(cat))
                return true;
        return false;
        }
    bool emitIface(void)
        {
        return _emitIface;
        }
    void setEmitIface(bool b)
        {
        _emitIface = b;
        }
    bool libraryBuild(void)
        {
        return _libraryBuild;
        }
    void setLibraryBuild(bool b)
        {
        _libraryBuild = b;
        }
    String* ifaceJson(void)
        {
        return _ifaceJson;
        }
    void setIfaceJson(String* j)
        {
        _ifaceJson = j;
        }
    Array* neededLibs(void)
        {
        return _neededLibs;
        }
    void setNeededLibs(Array* a)
        {
        _neededLibs = a;
        }

    void setInput(String* s)
        {
        _input = s;
        }
    void setOutput(String* s)
        {
        _output = s;
        }
    void setTarget(String* s)
        {
        _target = s;
        }
    String* libPlatform(void)
        {
        return _libPlatform;
        }
    void setLibPlatform(String* s)
        {
        _libPlatform = s;
        }
    void setHome(String* s)
        {
        _home = s;
        }
    void setVerbose(bool v)
        {
        _verbose = v;
        }
    void setMigrate(String* m)
        {
        _migrate = m;
        }
    void setBoundsCheck(bool b)
        {
        _boundsCheck = b;
        }
    String* preprocessedPath(void)
        {
        return _ppOut;
        }
    void setPreprocessedPath(String* p)
        {
        _ppOut = p;
        }
    void setThreadSafeArc(i32 mode)
        {
        _threadSafeArc = mode;
        }
    }

    class Frontend
    {
    void init(void)
        {
        }

    // Source in, IR module out. 0 on a failure that has already been reported.
    static IRModule* lower(FeOptions* o)
        {
        resolveIncludePaths(o);
        if (o.verbose())
            {
            Stdio.printf("xc-fe: platform: %s\n", platformOf(o).cString());
            Stdio.printf("xc-fe: include search paths:\n");
            for (u32 i = (u32)0; i < o.incs().count(); i = i + (u32)1)
                Stdio.printf("xc-fe:   %s\n", ((String*)o.incs().get(i)).cString());
            }

        // The `%@` gate, decided by a THROWAWAY expansion of the whole source: the
        // library pulls in the Object root for `%@` → description() dispatch only
        // when the program actually uses one, and the use can be inside an
        // imported file.
        Preprocessor* scan = buildPP(o);
        scan.define(String.withCString("HAS_ATFMT"), String.withCString("0"));
        String* probe = scan.preprocessFile(o.input());
        bool hasAt = probe != 0 && probe.byteIndexOf(String.withCString("%@")) != String.notFound();

        Preprocessor* pp = buildPP(o);
        pp.define(String.withCString("HAS_ATFMT"),
                  String.withCString(hasAt ? "1" : "0"));

        String* source = pp.preprocessFile(o.input());
        // PREPROCESSOR errors are errors. They were collected and thrown away
        // here — the same shape as bug 077 one stage later — so a missing
        // `#import` produced no message, exit 0 and a binary built without the
        // declarations it asked for. The first symptom was a parse error
        // pointing at a line that used the missing type, forty lines away.
        if (pp.errors().count() > (u32)0)
            {
            for (u32 e = (u32)0; e < pp.errors().count(); e = e + (u32)1)
                Frontend.printDiagnostic((String*)pp.errors().get(e));
            Process.exit((i32)1);
            return (IRModule*)0;
            }
        if (source == 0)
            {
            Stdio.printf("xc-fe: error: cannot read '%s'\n", o.input().cString());
            Process.exit((i32)1);
            return (IRModule*)0;
            }
        // -E <path>: the text the lexer is about to see, platform prelude and
        // every import expanded. Written here, after the preprocessor has
        // reported its errors and before anything else runs, so a failure
        // further on still leaves it behind to look at.
        if (o.preprocessedPath() != (String*)0 && !Files.writeText(o.preprocessedPath(), source))
            {
            Stdio.printf("xcc: error: cannot write -E output to '%s'\n",
                         o.preprocessedPath().cString());
            Process.exit((i32)1);
            return (IRModule*)0;
            }

        Lexer* lex = Lexer.with(source, o.input());
        Array* tokens = lex.tokenise();
        // A LEXICAL error stops the compile, and says so. The lexer kept only a
        // count and nothing ever read it, so `"\x80"` — which the reference
        // rejects outright — was detected here and silently discarded, taking
        // the byte with it (bug 212). Reported before the parse, because a
        // parser fed a token stream the lexer already disowned produces noise,
        // not information.
        if (lex.diagnostics().count() > (u32)0)
            {
            for (u32 e = (u32)0; e < lex.diagnostics().count(); e = e + (u32)1)
                Frontend.printDiagnostic((String*)lex.diagnostics().get(e));
            Process.exit((i32)1);
            return (IRModule*)0;
            }
        Parser* parser = Parser.with(tokens);

        // Stage 3 of separate compilation: `#import <Mod>` resolved to a bare
        // `.xtc.iface` reconstructs the module's declarations (marked external)
        // and PREPENDS them, as the reference driver does; its slot numbering is
        // ADOPTED rather than re-derived. A binary library is a loud refusal —
        // the port has no Mach-O/ELF section readers, and compiling without the
        // imports would fail far from the cause.
        //
        // Read BEFORE the parse, and the imported names registered with the
        // parser (task #36) — the original's "an imported library's types are
        // registered before the parse begins". The parser's decl heuristics gate
        // on KNOWN type names now; without this an imported class in a
        // declaration reads as an expression.
        Array* adoptedSlots = new Array();   // of IfaceImport@, for sema
        Array* importedIfaces = new Array(); // of IfaceImport@, prepended below
        // The C libraries `#import <X>` named — every import that carries no
        // xtc interface. A library build records them in its own interface
        // (`cImports`), so a client re-reads those types from the C library
        // rather than from a copy (the reference's `cImportNames`).
        Array* cImports = new Array();
        // How many of the imports are XTC libraries (they carry an interface).
        // A C library read from DWARF does not count: nothing in it dispatches.
        u32 xtcImports = (u32)0;
            {
            Array* metas = pp.metadataImports();
            // Handed to the DRIVER: a wasm app's loader lists the modules it
            // will fetch, and `#import <X>` is the only place that is known.
            o.setNeededLibs(metas);
            for (u32 i = (u32)0; i < metas.count(); i = i + (u32)1)
                {
                String* mp = (String*)metas.get(i);
                    // `.wasm` is read directly — its interface lives in the module,
                    // in an `xtc.iface` custom section. Mach-O and ELF libraries
                    // still need their section readers, and until those exist the
                    // refusal is loud rather than a build without the imports.
                    // A win64 SYSTEM import library (mingw's libuser32.a,
                    // libcomdlg32.a …) carries no interface to read and is not
                    // meant to: every win64 program already has these, and what
                    // they declare comes from the ambient Platform.xc and the
                    // program's own prototypes. `#use <comdlg32>` only has to
                    // RESOLVE. Skipping it here is the same contract the bundled
                    // stubs had — they are three lines of comment each, existing
                    // solely so the name resolves — except that the real sysroot
                    // needs no file per library and cannot drift from what mingw
                    // actually exports.
                    //
                    // Scoped to the sysroot directory, not to `.a` generally: a
                    // stray archive somewhere else is still a loud refusal, because
                    // silently importing nothing from a library the user named is
                    // the failure this whole path exists to avoid.
                    {
                    String* sysDir = win64SysLibDir();
                    if (sysDir != (String*)0 && mp.hasPrefix(sysDir))
                        continue;
                    }
                if (!mp.hasSuffix(String.withCString(".xtc.iface")) && !mp.hasSuffix(String.withCString(".wasm")) && !mp.hasSuffix(String.withCString(".dylib")) && !mp.hasSuffix(String.withCString(".so")))
                    {
                    Stdio.printf("xc-fe: error: '%s' is a binary library; the ported "
                                 "front end reads .wasm modules, .dylib and .so "
                                 "libraries, and bare .xtc.iface files\n",
                                 mp.cString());
                    Process.exit((i32)1);
                    return (IRModule*)0;
                    }
                IfaceImport* im = IfaceImport.read(mp);
                if (im == 0)
                    cImports.add((Object*)cLibraryName(mp));
                else
                    xtcImports = xtcImports + (u32)1;
                // No `.xtc.iface`? Then this is a library THIS compiler did not
                // build, and a C library describes itself in DWARF. That is
                // where its types come from — verbatim, which is the only way
                // they can be right: UXKit's binding header notes that a
                // hand-guessed `sizeof(theme)` would have smashed the heap,
                // because it is 19502 bytes (uxkit bug 034-D).
                if (im == 0)
                    {
                    Dwarf* dw = new Dwarf();
                    if (dw.read(mp, ptrWidthFor(o)))
                        {
                        im = new IfaceImport();
                        for (u32 k = (u32)0; k < dw.decls().count(); k = k + (u32)1)
                            im.decls().add(dw.decls().get(k));
                        }
                    }
                if (im == 0)
                    {
                    // A FOREIGN library — one this compiler did not build —
                    // carries no `.xtc.iface`, and that is not an error: its
                    // declarations come from a source header the program
                    // imports, and the binary is only a link dependency. The
                    // loader tree's `libGEM.so` is a C library exactly like
                    // this, and refusing it made the arm9 umbrella build
                    // impossible while the reference built it without comment
                    // (uxkit bug 034-D).
                    //
                    // Said out loud, on stderr, because the other reading —
                    // an xtc library whose interface did not survive — looks
                    // identical here and fails much later, at the first call.
                    String* w = String.withCString("xc-fe: note: '");
                    w.append(mp);
                    w.appendCString("' carries no interface section; its "
                                    "declarations must come from an imported "
                                    "header. Linking against it anyway.\n");
                    Stdio.error(w);
                    continue;
                    }
                // A wasm LIBRARY's symbols resolve as imports in that
                // library's own package — `libX.wasm` is package "X" — so the
                // loader can wire each call to that module's exports. Stamped
                // on every reconstructed declaration; it rides into the IR as
                // the `pkg_<X>` attribute the wasm back end reads. Without it
                // the app imported `env.__addr_Greeter$vtbl`, which no host
                // supplies, and would not instantiate.
                String* pkgStem = (String*)0;
                if (mp.hasSuffix(String.withCString(".wasm")))
                    {
                    String* fn = mp.lastPathComponent();
                    if (fn.hasPrefix(String.withCString("lib")))
                        pkgStem = fn.substringBytes((u32)3,
                                                    fn.byteLength() - (u32)3 - (u32)5);
                    }
                for (u32 j = (u32)0; j < im.decls().count(); j = j + (u32)1)
                    {
                    Node* d = (Node*)im.decls().get(j);
                    if (pkgStem != (String*)0)
                        d.setPkg(pkgStem);
                    u16 k = d.kind();
                    if (k == (u16)nkClassDecl || k == (u16)nkProtocolDecl || k == (u16)nkEnumDecl || k == (u16)nkTypedefDecl)
                        parser.addTypeName(d.name());
                    if (k == (u16)nkStructDecl)
                        {
                        parser.addTypeName(d.name());
                        parser.addStructName(d.name());
                        }
                    }
                importedIfaces.add((Object*)im);
                adoptedSlots.add((Object*)im);
                }
            }

        Node* program = parser.parse();
        // A PARSE ERROR MUST FAIL THE BUILD. The parser collected these all
        // along and nothing ever read them, so the shipped compiler took
        // `i32 x = ;`, said nothing, exited 0 and wrote a runnable binary —
        // while the reference refused it. Diagnostics the user never sees are
        // worse than no diagnostics: the build looks clean.
        // Parser WARNINGS, before the errors: each is "<category>\t<text>",
        // and a category named by `-Wno-<category>` is dropped here. Printed
        // even when the parse then fails, because a warning about the thing
        // that confused the parser is exactly what the reader needs.
        for (u32 w = (u32)0; w < parser.warnings().count(); w = w + (u32)1)
            {
            String* raw = (String*)parser.warnings().get(w);
            u32 tab = (u32)0;
            while (tab < raw.byteLength() && raw.byteAt(tab) != (u8)9)
                tab = tab + (u32)1;
            String* cat = raw.substringBytes((u32)0, tab);
            if (o.warningSuppressed(cat))
                continue;
            String* line = raw.substringBytes(tab + (u32)1,
                                              raw.byteLength() - tab - (u32)1);
            line.appendByte((u8)'\n');
            Stdio.error(line);
            }
        if (parser.errors().count() > (u32)0)
            {
            // Each message carries its own `file:line:col: error:` now (#78);
            // printDiagnostic adds the source line and the caret under it.
            for (u32 e = (u32)0; e < parser.errors().count(); e = e + (u32)1)
                Frontend.printDiagnostic((String*)parser.errors().get(e));
            Process.exit((i32)3);
            return (IRModule*)0;
            }
            {
            u32 at = (u32)0;
            for (u32 i = (u32)0; i < importedIfaces.count(); i = i + (u32)1)
                {
                IfaceImport* im = (IfaceImport*)importedIfaces.get(i);
                for (u32 j = (u32)0; j < im.decls().count(); j = j + (u32)1)
                    {
                    program.insertKid(at, (Node*)im.decls().get(j));
                    at = at + (u32)1;
                    }
                }
            }

        // #9 conformance downcast: on a backend that carries the conformance
        // itable, the `(P@ ?)obj` cast lowers to a call to a runtime helper that
        // walks obj → vtable → itable looking for the protocol's id. The driver
        // injects it as SOURCE — pure xtc, so the pointer-array stride is right on
        // every backend — before sema, so it is analysed like anything else.
        // Dead-function elimination drops it when no downcast uses it.
        // uxkit/026: a class with an `outlet` field or an `:action` method
        // auto-conforms to the binding protocol and has its setOutlet /
        // wireAction bodies written for it. BEFORE sema, so the synthesised
        // methods are what conformance checking sees.
        synthesizeDesignable(program);
        if (carriesItable(o))
            injectConformanceHelper(program);
        // The C interface the driver reads out of libc's DWARF. The port has no
        // DWARF reader, so the same declarations come from a bundled stub — and
        // everything in it is marked C-ABI here, because that is a property of
        // where it came from and not something the source can say.
        injectCInterface(program, o, tokens, pp.preludeFiles());

        Sema* sema = Sema.make();
        // §4.2 chain slots exist only where the vtable carries the chain word.
        sema.setChainCapable(carriesItable(o));
        // The target's pointer width, for the ptrdiff type of `p - q`. The same
        // pointerWidthOf() the lowering is handed below, so the two halves
        // cannot disagree about the address space they are compiling for.
        sema.setPointerWidth(pointerWidthOf(o));
        sema.setCountWidth(countWidthOf(o));
        // A LIBRARY build numbers every instance method a slot, because the
        // overrides live in a client that does not exist yet. The interface
        // this build emits publishes that numbering, so the decision has to be
        // made BEFORE the slots are assigned, not when they are written out.
        sema.vtable().setLibraryBuild(o.libraryBuild());
        sema.setMigrateBase(migrateBaseOf(o.migrate()));
        // Adopt each imported module's vtable numbering — its vtables are emitted,
        // so its slots are authoritative and local numbering continues above them.
        // Protocol numbering is NOT adopted in itable mode (every live multi-module
        // target): dispatch never goes through it, and adopting it is what created
        // the two-library collision the itable exists to end.
        // arm9 is the one target that dispatches a protocol through the ITABLE,
        // so its numbering is never read across a module boundary and adopting
        // it is what would make two independent libraries collide. Everywhere
        // else a `Proto*` receiver is called at a VTABLE slot, and that number
        // belongs to the library that emitted the tables — a client that
        // renumbered dispatched into a slot nothing filled, which is a null
        // function at run time rather than an error at build time.
        // arm9 AND x86_64 (bug 201): both link as several independently compiled
        // modules, where a program-global protocol slot number is unachievable —
        // dispatch goes through the itable and protocol numbering is not adopted.
        // Bug 266: the same holds for EVERY module that meets another one — see
        // itableDispatchOf.
        bool itableProtos = itableDispatchOf(o, xtcImports > (u32)0);
        // AMBIENT slots: the numbers a library assumed for the prelude classes.
        // Under shared-everything wasm the app and the library each emit their
        // own `String$vtbl`, and an object created by one is dispatched on by
        // the other — so the two layouts have to agree, and the library's is
        // the one already fixed (bug 091). Every other target has the same
        // problem one step removed: a client class that derives from Object
        // is laid out by the client, and a library's `a.equals(b)` on an
        // `Object*` reads the library's slot for Object.equals out of it (bug
        // 266). A library numbers the prelude per class, from each class's
        // ancestry alone, so two libraries agree and a client program adopts
        // the numbers. A library build numbers them the same way itself and
        // does not need to.
        bool adoptAmbient = platformOf(o).equals(String.withCString("wasm32")) || (itableProtos && !o.libraryBuild());
        Map* ambientSeen = new Map();
        for (u32 i = (u32)0; i < adoptedSlots.count(); i = i + (u32)1)
            {
            IfaceImport* im = (IfaceImport*)adoptedSlots.get(i);
            Array* labels = im.methodSlots().allKeys();
            for (u32 j = (u32)0; j < labels.count(); j = j + (u32)1)
                {
                String* l = (String*)labels.get(j);
                sema.vtable().adopt(l,
                                    ((Number*)im.methodSlots().get((Hashable*)l)).asU32());
                }
            if (adoptAmbient)
                {
                Array* al = im.ambientSlots().allKeys();
                for (u32 j = (u32)0; j < al.count(); j = j + (u32)1)
                    {
                    String* l = (String*)al.get(j);
                    u32 slot = ((Number*)im.ambientSlots().get((Hashable*)l)).asU32();
                    // Two libraries that assumed DIFFERENT layouts for the same
                    // ambient class cannot both be satisfied, and picking one
                    // silently is the runtime trap 091 already is — one of them
                    // would dispatch into a slot the object does not have. Say
                    // so at build time instead.
                    Object* prev = ambientSeen.get((Hashable*)l);
                    if (prev != (Object*)0 && ((Number*)prev).asU32() != slot)
                        {
                        Stdio.printf("xc-fe: error: imported libraries disagree "
                                     "about the vtable slot of '%s' (%lu vs %lu); "
                                     "they were built against different ambient "
                                     "layouts and cannot be linked together\n",
                                     l.cString(),
                                     (u32)((Number*)prev).asU32(), (u32)slot);
                        Process.exit((i32)1);
                        return (IRModule*)0;
                        }
                    ambientSeen.set((Hashable*)l, (Object*)Number.withU32(slot));
                    sema.vtable().adopt(l, slot);
                    }
                }
            if (itableProtos)
                continue;
            Array* pns = im.protoSlots().allKeys();
            for (u32 j = (u32)0; j < pns.count(); j = j + (u32)1)
                {
                String* pn = (String*)pns.get(j);
                Map* inner = (Map*)im.protoSlots().get((Hashable*)pn);
                if (inner == (Map*)0)
                    continue;
                Array* mns = inner.allKeys();
                for (u32 k = (u32)0; k < mns.count(); k = k + (u32)1)
                    {
                    String* mn = (String*)mns.get(k);
                    sema.vtable().adoptProtoSlot(pn, mn,
                                                 ((Number*)inner.get((Hashable*)mn)).asU32());
                    }
                }
            }
        sema.analyse(program);
        // Same for SEMANTIC errors, and for the same reason.
        if (sema.errors().count() > (u32)0)
            {
            // The message carries its own `file:line:col: error:` when the node
            // it came from had a position, and a bare `error:` when it did not.
            for (u32 e = (u32)0; e < sema.errors().count(); e = e + (u32)1)
                Frontend.printDiagnostic((String*)sema.errors().get(e));
            Process.exit((i32)3);
            return (IRModule*)0;
            }

        // -Wanalyze: the static analyser, after sema so it sees resolved types
        // and before lowering so it sees the code as WRITTEN — the optimiser
        // deletes a dead store itself, which would hide exactly what the check
        // is for. A warning changes neither the emitted code nor the exit
        // status (private:docs/Design/static-analysis.md §1).
        //
        // On STDERR, through Stdio.error — because `--dump-ast` and friends
        // write their artefact to stdout and the differentials compare it byte
        // for byte, so a warning landing in the middle of one would read as a
        // divergence in whichever file happened to warn.
        if (o.analyze())
            {
            Analyze* an = new Analyze();
            an.run(program);
            for (u32 i = (u32)0; i < an.diagnostics().count(); i = i + (u32)1)
                {
                String* line = String.withString((String*)an.diagnostics().get(i));
                line.appendByte((u8)'\n');
                Stdio.error(line);
                }
            }

        // The module INTERFACE, taken AFTER sema so the declarations carry the
        // types sema resolved. A library build embeds this; an executable
        // never asks for it, so it costs nothing to compute here and hand back.
        // The prelude's files are the AMBIENT surface: every unit already has
        // them, so this module does not export them as its own.
        if (o.emitIface())
            o.setIfaceJson(IfaceWrite.json(program, sema.vtable(), pp.preludeFiles(), cImports));

        Lower* lower = Lower.make();
        lower.setPointerWidth(pointerWidthOf(o));
        lower.setCountWidth(countWidthOf(o));
        lower.setAlignCaps(fieldAlignCapOf(o), tailAlignCapOf(o));
        // A vtable's shape is the target's, not the language's: the backends that
        // link separate shared objects carry a parent link and a conformance
        // itable ahead of the methods, and the ones that do not keep the
        // parent-free vtable and decide conformance at compile time.
        lower.setVtableAncestry(carriesItable(o));
        lower.setVtableItable(carriesItable(o));
        // Where a program-global protocol slot cannot be handed out, dispatch
        // goes through the itable (bugs 201, 266).
        lower.setItableDispatch(itableProtos);
        lower.setNativeVarargs(platformOf(o).equals(String.withCString("arm9")) || platformOf(o).equals(String.withCString("arm64")));                         // bug 179
        // The race-free static-init once (threading.md §9.5). -1 = decide per
        // module; -f[no-]thread-safe-arc forces it, because atomic ARC and this
        // once ride the same switch and a program that asks for one gets both.
        lower.setThreadSafeStatics(o.threadSafeArc());
        lower.setBoundsCheck(o.boundsCheck());
        lower.setVtable(sema.vtable());
        IRModule* mod = lower.run(program, moduleNameOf(o.input()));
        if (mod == 0 || lower.failed())
            {
            Stdio.printf("xc-fe: %s: unsupported: %s\n", o.input().cString(),
                         lower.why() == 0 ? "?" : lower.why().cString());
            Process.exit((i32)3);
            return (IRModule*)0;
            }

        return mod;
        }

    // Print one diagnostic the way the reference's XTDiagnosticEngine does,
    // on STDERR: `file:line:col: error: message`, then the source line, then
    // a caret under the column — with the same three ANSI colours (bold
    // location, red level, green caret) and the same tab-to-four-spaces rule,
    // so the two compilers' output is the same bytes. A message with no
    // position (`error: …`) prints as it is.
    // The decimal value of a run of digits; anything else stops it. Line and
    // column numbers only — no sign, no overflow to speak of.
    static u32 digitsOf(String* s)
        {
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u32 ch = s.charAtByte(i);
            if (ch < (u32)48 || ch > (u32)57)
                return v;
            v = v * (u32)10 + (ch - (u32)48);
            }
        return v;
        }

    // Stdio.error writes exactly what it is given; a diagnostic is a line.
    static String* withNewline(String* s)
        {
        String* out = String.withString(s);
        out.appendByte((u8)10);
        return out;
        }

    static void printDiagnostic(String* msg)
        {
        String* bold = String.withCString("\x1b[1m");
        String* red = String.withCString("\x1b[1;31m");
        String* green = String.withCString("\x1b[1;32m");
        String* reset = String.withCString("\x1b[0m");
        u32 ep = msg.byteIndexOf(String.withCString(": error: "));
        if (ep == String.notFound() || ep == (u32)0)
            {
            Stdio.error(Frontend.withNewline(msg));
            return;
            }
        String* loc = msg.substringBytes((u32)0, ep); // file:line:col
        String* text = msg.substringFromByte(ep + (u32)9);
        // Split the location from the right: col, then line, then the path
        // (which may itself contain ':' on Windows).
        u32 c2 = loc.lastIndexOfByte((u8)':');
        if (c2 == String.notFound())
            {
            Stdio.error(Frontend.withNewline(msg));
            return;
            }
        String* head = loc.substringBytes((u32)0, c2);
        u32 c1 = head.lastIndexOfByte((u8)':');
        if (c1 == String.notFound())
            {
            Stdio.error(Frontend.withNewline(msg));
            return;
            }
        String* path = head.substringBytes((u32)0, c1);
        u32 line = Frontend.digitsOf(head.substringFromByte(c1 + (u32)1));
        u32 col = Frontend.digitsOf(loc.substringFromByte(c2 + (u32)1));
        String* out = String.withCString("");
        out.append(bold);
        out.append(loc);
        out.appendByte((u8)':');
        out.append(reset);
        out.appendByte((u8)' ');
        out.append(red);
        out.appendCString("error:");
        out.append(reset);
        out.appendByte((u8)' ');
        out.append(text);
        Stdio.error(Frontend.withNewline(out));
        String* src = Files.readText(path);
        if (src == (String*)0 || line == (u32)0)
            return;
        Array* lines = src.splitOnByte((u8)'\n');
        if (line > lines.count())
            return;
        String* srcLine = (String*)lines.get(line - (u32)1);
        // Tabs become four spaces on the shown line, and the caret column
        // advances four for each tab before it.
        String* shown = String.withCString(" ");
        u32 adjusted = (u32)0;
        for (u32 i = (u32)0; i < srcLine.byteLength(); i = i + (u32)1)
            {
            u32 ch = srcLine.charAtByte(i);
            if (ch == (u32)9)
                {
                shown.appendCString("    ");
                if (i + (u32)1 < col)
                    adjusted = adjusted + (u32)4;
                }
            else
                {
                shown.appendByte((u8)ch);
                if (i + (u32)1 < col)
                    adjusted = adjusted + (u32)1;
                }
            }
        Stdio.error(Frontend.withNewline(shown));
        String* caret = String.withCString("");
        caret.append(green);
        caret.appendByte((u8)' ');
        for (u32 i = (u32)0; i < adjusted; i = i + (u32)1)
            caret.appendByte((u8)' ');
        caret.appendByte((u8)'^');
        caret.append(reset);
        Stdio.error(Frontend.withNewline(caret));
        return;
        }

    }

    // `--migrate=0.3:0.4` names the version to compile AS — the base — and the one
    // being moved to. Only the base gates visibility; the second half records the
    // intent.
    String* migrateBaseOf(String* spec)
    {
    if (spec == 0)
        return (String*)0;
    for (u32 i = (u32)0; i < spec.byteLength(); i = i + (u32)1)
        if (spec.byteAt(i) == (u8)':')
            return spec.substringBytes((u32)0, i);
    return spec;
    }

// The TARGET's pointer width. The DWARF reader needs it because a struct's
// pad arithmetic depends on it: the back end re-sizes pointers, so a
// pointer-followed-by-member layout only reproduces the C offsets when the
// pads are computed at the width the pointer will actually occupy.
u32 ptrWidthFor(FeOptions* o)
    {
    String* t = o.target();
    if (t.equals(String.withCString("xt6502")) || t.equals(String.withCString("6502")))
        return (u32)2;
    if (t.equals(String.withCString("arm64")) || t.equals(String.withCString("x86_64")) || t.equals(String.withCString("win64")))
        return (u32)8;
    return (u32)4; // arm9, atarist, wasm32
    }

String* platformOf(FeOptions* o)
    {
    String* t = o.target();
    if (t.equals(String.withCString("arm64")))
        return String.withCString("arm64");
    // iOS resolves libraries from the ARM64 support tree: stage 0 ships no
    // support/ios layer (docs/mobile/iOS.md says one arrives with stage 4), so
    // this is the deliberate answer rather than a target falling through.
    if (t.equals(String.withCString("ios")))
        return String.withCString("arm64");
    if (t.equals(String.withCString("ios-sim")))
        return String.withCString("arm64");
    if (t.equals(String.withCString("arm9")))
        return String.withCString("arm9");
    if (t.equals(String.withCString("atarist")))
        return String.withCString("atarist");
    if (t.equals(String.withCString("x86_64")))
        return String.withCString("x86_64");
    if (t.equals(String.withCString("win64")))
        return String.withCString("win64");
    if (t.equals(String.withCString("wasm32")))
        return String.withCString("wasm32");
    if (t.equals(String.withCString("xt6502")))
        return String.withCString("xt6502");
    if (t.equals(String.withCString("6502")))
        return String.withCString("xt6502");
    // An unlisted target STOPS. It used to fall through to xt6502 — a REAL
    // platform — so wasm32, which was missing here, silently compiled against
    // the 6502 library: it built, it ran, and it printed nothing. A default
    // that is a valid answer can never announce itself, and the failure it
    // produces looks like a miscompile rather than a missing case.
    Stdio.printf("xc-fe: error: no library platform is mapped for target '%s'\n",
                 t.cString());
    Stdio.printf("       (every target this driver drives must be named in "
                 "platformOf; falling back to another platform's library would "
                 "build something that runs and does nothing)\n");
    Process.exit((i32)2);
    return (String*)0;
    }

// `#import <c>` is automatic on a target with a real libc: the driver finds
// libc.so and reads the declarations out of its DWARF. This is the port's
// substitute — `support/<plat>/selfhost-iface/c.xc`, parsed like any source
// and then marked as what it is.
//
// `ambient` is the set of files whose declarations are not this module's to
// export. The stub joins it: in the reference these declarations come out of
// DWARF with no source position, and a library's interface does not publish
// them (`struct stat` and `timespec` were exported by every arm9 library that
// named `stat`).
void injectCInterface(Node* program, FeOptions* o, Array* tokens, Set* ambient)
    {
    String* root = supportRoot(o);
    if (root == 0)
        return;
    String* path = String.withCString("");
    path.append(root);
    path.appendCString("/");
    path.append(platformOf(o));
    path.appendCString("/selfhost-iface/c.xc");
    if (!Files.exists(path))
        return;
    String* src = Files.readText(path);
    if (src == 0)
        return;
    if (ambient != 0)
        ambient.add((Hashable*)String.withString(path));
    Lexer* lex = Lexer.with(src, path);
    Parser* parser = Parser.with(lex.tokenise());
    Node* iface = parser.parse();
    if (iface == 0)
        return;

    // Three rules, all the driver's. A libc name the source never mentions is
    // not declared at all (so the module's symbol list stays the used set); a
    // name the program already declares SHADOWS the libc one, because libc is
    // the lowest-precedence layer; and what survives goes in FRONT of the
    // program, as the driver's `[protos addObjectsFromArray:ast.declarations]`
    // does.
    Array* picked = Array.withCapacity((u32)8);
    for (u32 i = (u32)0; i < iface.kidCount(); i = i + (u32)1)
        {
        Node* d = iface.kid(i);
        if (d.kind() != (u16)nkFunctionDecl)
            continue;
        if (!mentions(tokens, d.name()))
            continue;
        if (declaresFunction(program, d.name()))
            continue;
        d.addFlag((u32)NF_CABI);
        picked.add((Object*)d);
        }
    // A libc function that takes `tms@` needs `struct tms` as well — and the
    // struct's own fields may name more. Only the ones REACHED this way go in:
    // the original registers every imported type but emits a layout for none
    // the module does not use, so injecting them all would print layouts the
    // oracle has not got.
    Array* needed = Array.withCapacity((u32)8);
    for (u32 i = (u32)0; i < picked.count(); i = i + (u32)1)
        {
        Node* d = (Node*)picked.get(i);
        noteStructRef(iface, needed, d.op());
        for (u32 k = (u32)0; k < d.kidCount(); k = k + (u32)1)
            if (d.kid(k).kind() == (u16)nkParam)
                noteStructRef(iface, needed, d.kid(k).op());
        }
    // The worklist grows as fields are walked, so this is a closure, not a scan.
    for (u32 i = (u32)0; i < needed.count(); i = i + (u32)1)
        {
        Node* st = (Node*)needed.get(i);
        for (u32 k = (u32)0; k < st.kidCount(); k = k + (u32)1)
            noteStructRef(iface, needed, st.kid(k).op());
        }
    needed.addAll(picked);
    program.kids().insertAll((u32)0, needed);
    }

// `…/libGEM.so` -> `GEM`: the file name without its last extension and
// without a `lib` prefix — the reference's cLibraryNameFromPath.
String* cLibraryName(String* path)
    {
    String* base = path.lastPathComponent();
    u32 dot = String.notFound();
    for (u32 i = (u32)0; i < base.byteLength(); i = i + (u32)1)
        if (base.byteAt(i) == (u8)'.')
            dot = i;
    if (dot != String.notFound() && dot > (u32)0)
        base = base.substringBytes((u32)0, dot);
    if (base.hasPrefix(String.withCString("lib")))
        base = base.substringFromByte((u32)3);
    return base;
    }

// If `spelling` names a struct the stub declares, add that declaration to
// `outNeeded` (once). Pointer and array suffixes are not part of the name.
void noteStructRef(Node* iface, Array* outNeeded, String* spelling)
    {
    if (spelling == 0)
        return;
    String* base = String.withCString("");
    for (u32 i = (u32)0; i < spelling.byteLength(); i = i + (u32)1)
        {
        u8 c = spelling.byteAt(i);
        if (c == (u8)'*' || c == (u8)'[')
            break;
        base.appendByte(c);
        }
    if (base.byteLength() == (u32)0)
        return;
    for (u32 i = (u32)0; i < outNeeded.count(); i = i + (u32)1)
        if (((Node*)outNeeded.get(i)).name().equals(base))
            return;
    for (u32 i = (u32)0; i < iface.kidCount(); i = i + (u32)1)
        {
        Node* d = iface.kid(i);
        if (d.kind() != (u16)nkStructDecl && d.kind() != (u16)nkTypedefDecl)
            continue;
        if (!d.name().equals(base))
            continue;
        outNeeded.add((Object*)d);
        return;
        }
    }

// Does any identifier token in the unit spell this name? The driver's test is
// exactly this — a token scan, not a resolved call — so an unused libc symbol
// never reaches the IR.
bool mentions(Array* tokens, String* name)
    {
    for (u32 i = (u32)0; i < tokens.count(); i = i + (u32)1)
        {
        Token* t = (Token*)tokens.get(i);
        if (t.type() != (u16)tokIdentifier)
            continue;
        if (t.value() != 0 && t.value().equals(name))
            return true;
        }
    return false;
    }

bool declaresFunction(Node* program, String* name)
    {
    for (u32 i = (u32)0; i < program.kidCount(); i = i + (u32)1)
        {
        Node* d = program.kid(i);
        if (d.kind() != (u16)nkFunctionDecl)
            continue;
        // The accessor is read ONCE: calling it twice in one `&&` on a
        // downcast result miscompiles on arm64 (private:docs/bugs/025).
        String* dn = d.name();
        if (dn != 0 && dn.equals(name))
            return true;
        }
    return false;
    }

// The conformance itable is emitted by the native backends; the 6502 does not
// carry one, so the helper would be dead weight there and is not injected.
//
// wasm32 DOES carry one. It was missing from this list while the reference's
// matching gate (XTCompilerDriver.m, `useWasm32Backend`) had it, so the shipped
// compiler emitted no `$itab`/`$itbl` data at all for wasm — 20 metadata
// segments against the reference's 68 — and a program that stored a callback
// trapped inside _xtc_weak_register on memory that was never laid out (bug
// 083). The two gates are the same list written twice; keep them the same
// length.
bool carriesItable(FeOptions* o)
    {
    String* p = platformOf(o);
    return p.equals(String.withCString("arm64")) || p.equals(String.withCString("x86_64")) || p.equals(String.withCString("win64")) || p.equals(String.withCString("arm9")) || p.equals(String.withCString("wasm32"));
    }

// Does a call through a protocol go through the itable rather than a vtable
// slot? A slot number is only good inside the program that numbered it. arm9
// always links as several modules. On arm64 (and iOS and Android, which use its
// back end), x86_64 and wasm32 the same is true of a library build, a `-c`
// object, and a program that imports an xtc library: each numbers the
// protocols it sees itself, and nothing can make the numbers agree for a
// protocol the library does not declare. A library's `h.hash()` on a client's
// `Hashable*` read the library's slot 92 out of a 19-entry client vtable (bug
// 266). The itable is keyed by the protocol's name-derived id and the method's
// declaration index, which every module derives alike, so no numbering has to
// cross the interface. win64 links no libraries yet, so it keeps the slot.
bool itableDispatchOf(FeOptions* o, bool importsLibrary)
    {
    String* p = platformOf(o);
    if (p.equals(String.withCString("arm9")))
        return true;
    if (p.equals(String.withCString("arm64")) || p.equals(String.withCString("x86_64")) || p.equals(String.withCString("wasm32")))
        return o.libraryBuild() || importsLibrary;
    return false;
    }

// The helper takes the object's ALREADY-VALIDATED vtable pointer: the caller
// reads obj[0] and passes null when it is a non-vtable class's small class-id
// or the object itself is null. Given a real vtable it reads the itable at
// slot 1 and scans the (protoId, &table) pairs for `pid`.
void injectConformanceHelper(Node* program)
    {
    String* src = String.withCString("");
    src.appendCString("bool _xtc_obj_conforms(pointer vtbl, u32 pid) {\n");
    src.appendCString("  if (vtbl == (pointer)0) { return false; }\n");
    src.appendCString("  pointer* vp = (pointer@)vtbl;\n");
    src.appendCString("  pointer itab = vp[1];\n");
    src.appendCString("  if (itab == (pointer)0) { return false; }\n");
    src.appendCString("  pointer* ip = (pointer@)itab;\n");
    src.appendCString("  i32 k = (i32)0;\n");
    src.appendCString("  while (ip[k + k] != (pointer)0) {\n");
    src.appendCString("    if ((u32)ip[k + k] == pid) { return true; }\n");
    src.appendCString("    k = k + (i32)1;\n");
    src.appendCString("  }\n");
    src.appendCString("  return false;\n");
    src.appendCString("}\n");
    Lexer* lex = Lexer.with(src, String.withCString("<conformance-helper>"));
    Parser* parser = Parser.with(lex.tokenise());
    Node* synth = parser.parse();
    if (synth == 0)
        return;
    for (u32 i = (u32)0; i < synth.kidCount(); i = i + (u32)1)
        {
        // Marked SYNTH so it stays out of the module's INTERFACE: the helper is
        // the compiler's, injected into every itable-carrying unit, and a
        // library that published it would hand a client a second definition of
        // something the client already has.
        synth.kid(i).addFlag((u32)NF_SYNTH);
        program.add(synth.kid(i));
        }
    }

// Is there a `Platform.xc` on the search path? That is what gates the implicit
// prelude — a bare tree, or a target without one, must not fail every compile
// on a missing include.
bool hasPlatformPrelude(FeOptions* o)
    {
    for (u32 i = (u32)0; i < o.incs().count(); i = i + (u32)1)
        {
        String* p = String.withCString(((String*)o.incs().get(i)).cString());
        p.appendCString("/Platform.xc");
        if (Files.exists(p))
            return true;
        }
    return false;
    }

// The target's NATIVE pointer width, which is what `sizeof` reports and what
// every struct offset is summed from. It has to agree with the backend's own
// or the opt passes fold an address the backend then disagrees with.
// Bytes of element COUNT in the allocation header — what `.length` and
// `for (v in heapPtr)` read back. NOT the pointer width: arm9 and atarist
// share a 4-byte pointer but hold 4- and 2-byte counts. Hard-wired to 2 once,
// which truncated every array over 65535 elements AND, because for-in takes
// the same call, silently shortened iteration (bug 234).
u32 countWidthOf(FeOptions* o)
    {
    String* p = platformOf(o);
    // Capped at 4 even where the header holds 8 (arm64): it keeps `.length`
    // the same type on every 32/64-bit target and keeps u64 out of the index
    // arithmetic the for-in and slice paths share.
    if (p.equals(String.withCString("arm64")) || p.equals(String.withCString("x86_64"))
        || p.equals(String.withCString("win64")) || p.equals(String.withCString("arm9"))
        || p.equals(String.withCString("wasm32")))
        return (u32)4;
    // atarist: the m68k header really is [count:2][elemSize:2]. xt6502 writes
    // no count at all and its `.length` soft-fails at compile time.
    return (u32)2;
    }

u32 pointerWidthOf(FeOptions* o)
    {
    String* p = platformOf(o);
    if (p.equals(String.withCString("arm64")) || p.equals(String.withCString("x86_64")) || p.equals(String.withCString("win64")))
        return (u32)8;
    if (p.equals(String.withCString("arm9")) || p.equals(String.withCString("atarist")) || p.equals(String.withCString("wasm32")))
        return (u32)4;
    // xt6502: [addr-lo, addr-hi, bank]. Named rather than defaulted — wasm32
    // was absent from this chain and inherited the 6502's THREE-byte pointer,
    // so the shipped compiler laid out wasm structs with 3-byte pointer fields
    // while the back end loaded 4 (bug 083). That is the type-width invariant
    // in private:docs/Design/type-width-invariant.md, and it does not surface as a
    // layout error — it surfaces as a wrong address.
    if (p.equals(String.withCString("xt6502")))
        return (u32)3;
    Stdio.printf("xc-fe: error: no pointer width is mapped for platform '%s'\n", p.cString());
    Process.exit((i32)2);
    return (u32)0;
    }

// Struct FIELD alignment cap (blewit #5): fields align to min(natural, cap),
// and the offsets land in the IR layout, which every backend reads verbatim.
// 8 = full C natural alignment on the register targets; 2 = the m68k C ABI;
// 1 = the xt6502's tightly packed layout, unchanged. The mirror of the
// original driver's setFieldAlignmentCap: site.
u32 fieldAlignCapOf(FeOptions* o)
    {
    String* p = platformOf(o);
    if (p.equals(String.withCString("arm64")) || p.equals(String.withCString("x86_64")) || p.equals(String.withCString("win64")) || p.equals(String.withCString("arm9")) || p.equals(String.withCString("wasm32")))
        return (u32)8;
    if (p.equals(String.withCString("atarist")))
        return (u32)2;
    if (p.equals(String.withCString("xt6502")))
        return (u32)1;
    Stdio.printf("xc-fe: error: no field-alignment cap is mapped for platform '%s'\n", p.cString());
    Process.exit((i32)2);
    return (u32)0;
    }

// The TAIL cap — what sizeof rounds up to: 2 on m68k (its C ABI), 8 everywhere
// else, including xt6502, which keeps the bug-015 pow2 rounding even though
// its fields pack.
u32 tailAlignCapOf(FeOptions* o)
    {
    if (platformOf(o).equals(String.withCString("atarist")))
        return (u32)2;
    return (u32)8;
    }

// -I paths first, then the platform's lib, then the generic one — a platform
// file of the same name has to win, which is the whole point of the order.
void resolveIncludePaths(FeOptions* o)
    {
    String* support = supportRoot(o);
    if (support == 0)
        return;
    String* plat = platformOf(o);
    // iOS: its own layer FIRST (support/ios/lib — the Platform.xc prelude and
    // whatever is iOS-shaped), then the arm64 tree it shares the ISA and
    // runtime with — the same platform-then-arch order win64/x86_64 use.
    if (o.libPlatform() != (String*)0 && o.libPlatform().hasPrefix(String.withCString("ios")))
        addLibDir(o, support, String.withCString("ios"));
    if (plat.equals(String.withCString("win64")))
        {
        addLibDir(o, support, String.withCString("win64"));
        // win64 shares the x86-64 native library tree — same ISA, same
        // libc-backed shape — with its own dir first for the overrides.
        addLibDir(o, support, String.withCString("x86_64"));
        }
    else
        {
        addLibDir(o, support, plat);
        }
    addLibDir(o, support, String.withCString("generic"));
    // `#import <kernel32>` and friends. With a mingw sysroot present the
    // reference reads the real import libraries; without one — which is this
    // compiler's normal state, since the whole point is not to need a foreign
    // toolchain — the hand-written interfaces under win64/selfhost-iface are
    // what `Platform.xc` resolves against. Listed LAST so a real sysroot,
    // when there is one, still wins.
    if (plat.equals(String.withCString("win64")))
        {
        // The mingw sysroot's IMPORT LIBRARIES — libuser32.a, libcomdlg32.a,
        // libole32.a … — are what `#use <user32>` resolves to when a win64
        // toolchain is installed, and they are also what makes the link pull
        // in the real Windows API.
        //
        // This is a LIBRARY path, not an include path. The port had neither
        // half: no sysroot directory, and a resolver that only knew
        // .dylib/.so/.wasm, so `libcomdlg32.a` could not have been matched even
        // if the directory had been listed. Adding only the path was tried
        // first and made things WORSE — the three bundled stubs stopped
        // shadowing and nothing replaced them (bug 120).
        //
        // Stubs are searched only when there is NO sysroot, exactly as the
        // reference gates it. They are INCLUDE paths, and the source probe runs
        // before the library probe, so keeping both would let a stub shadow the
        // real import library: the program would compile and then fail to link
        // on an undefined symbol.
        String* mingw = win64SysLibDir();
        if (mingw != (String*)0)
            {
            o.libs().add((Object*)mingw);
            }
        else
            {
            String* sh = String.withCString(support.cString());
            sh.appendCString("/win64/selfhost-iface");
            if (Files.exists(sh))
                o.incs().add((Object*)sh);
            }
        }
    }

void addLibDir(FeOptions* o, String* support, String* plat)
    {
    String* d = String.withCString(support.cString());
    d.appendCString("/");
    d.append(plat);
    d.appendCString("/lib");
    if (Files.exists(d))
        o.incs().add((Object*)d);
    }

// The support tree under `base`, in the three spellings an install and a
// source checkout use: `lib/xc` (an install), `xc` (Windows), `support` (the
// checkout). 0 when none of them is there.
String* probeRoot(String* base)
    {
    if (base == 0)
        return (String*)0;
    Array* spellings = new Array();
    spellings.add((Object*)String.withCString("/lib/xc"));
    spellings.add((Object*)String.withCString("/xc"));
    spellings.add((Object*)String.withCString("/support"));
    for (u32 i = (u32)0; i < spellings.count(); i = i + (u32)1)
        {
        String* c = String.withString(base);
        c.append((String*)spellings.get(i));
        if (Files.exists(c))
            return c;
        }
    return (String*)0;
    }

// A path from the environment or the command line, cleaned the way a Windows
// shell leaves it: surrounding whitespace, a pair of enclosing double quotes
// (`SET XCC_HOME="C:\xcc"` keeps them), and backslash separators. 0 when
// nothing is left.
String* sanitiseEnvPath(String* raw)
    {
    if (raw == 0)
        return (String*)0;
    String* s = raw.trimmed();
    if (s.byteLength() >= (u32)2 && s.byteAt((u32)0) == (u8)'"'
        && s.byteAt(s.byteLength() - (u32)1) == (u8)'"')
        s = s.substringBytes((u32)1, s.byteLength() - (u32)2);
    String* out = new String();
    for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
        out.appendByte(s.byteAt(i) == (u8)'\\' ? (u8)'/' : s.byteAt(i));
    if (out.byteLength() == (u32)0)
        return (String*)0;
    return out;
    }

// `a/b/xcc` -> `a/b`, and "" for a bare name.
String* dirOf(String* path)
    {
    if (path == 0)
        return (String*)0;
    u32 cut = (u32)0;
    bool sawSlash = false;
    for (u32 i = (u32)0; i < path.byteLength(); i = i + (u32)1)
        if (path.byteAt(i) == (u8)'/')
            {
            cut = i;
            sawSlash = true;
            }
    if (!sawSlash)
        return (String*)0;
    return path.substringBytes((u32)0, cut);
    }

// Where the library lives.
//
// The BINARY-RELATIVE step is the one that matters, and it was missing: an
// installed compiler has to find its own libraries with no flag and no
// environment, and this searched only `./support` and two pre-0.4 paths that no
// install has used since 0.3. So `/opt/xcc/0.5/bin/xcc hello.xc` failed on
// every target while the same binary worked from the build tree with `-H`.
//
// `-H` names a ROOT, not a support directory: it is probed for the same three
// spellings, so `-H /opt/xcc/0.5` and `-H .` both work. Appending `/support`
// unconditionally is why `-H /opt/xcc/0.5/lib/xc` also failed.
//
// The versioned fallback comes from the VERSION file through -DXCC_VERSION, as
// xcc.xc's --version line does. It was a literal "/opt/xcc/0.6", so a 0.61
// compiler run outside an install read 0.6's libraries.
#ifndef XCC_VERSION
#define XCC_VERSION "unversioned"
#endif
String* supportRoot(FeOptions* o)
    {
    if (o.home() != 0)
        {
        String* r = probeRoot(o.home());
        if (r != 0)
            return r;
        // An explicit -H that names the support directory ITSELF still works.
        if (Files.exists(o.home()))
            return o.home();
        return (String*)0;
        }
    Array* bases = new Array();
    // $XCC_HOME, then the older $XTC_HOME: an explicit choice of root, so
    // they come before anything the compiler would find for itself.
    String* xccHome = sanitiseEnvPath(Platform.env(String.withCString("XCC_HOME")));
    if (xccHome != 0)
        bases.add((Object*)xccHome);
    String* xtcHome = sanitiseEnvPath(Platform.env(String.withCString("XTC_HOME")));
    if (xtcHome != 0)
        bases.add((Object*)xtcHome);
    // Beside the binary, then one level up — `<bin>/../lib/xc` is the install.
    String* self = Process.argument((u32)0);
    String* bin = dirOf(self);
    if (bin != 0)
        {
        bases.add((Object*)bin);
        String* up = dirOf(bin);
        if (up != 0)
            bases.add((Object*)up);
        }
    bases.add((Object*)String.withCString("."));
    // A per-user tree, after the working directory and before the system ones.
    String* userHome = Platform.home();
    if (userHome != 0 && userHome.byteLength() > (u32)0)
        {
        bases.add((Object*)String.withString(userHome).appending(String.withCString("/xcc")));
        bases.add((Object*)String.withString(userHome).appending(String.withCString("/xtc")));
        }
    bases.add((Object*)String.withCString("/opt/xcc/" XCC_VERSION));
    bases.add((Object*)String.withCString("/opt/xcc"));
    bases.add((Object*)String.withCString("/usr/local/xcc"));
    bases.add((Object*)String.withCString("/usr/local/xtc"));
    bases.add((Object*)String.withCString("/opt/xtc"));
    for (u32 i = (u32)0; i < bases.count(); i = i + (u32)1)
        {
        String* r = probeRoot((String*)bases.get(i));
        if (r != 0)
            return r;
        }
    return (String*)0;
    }

// The mingw sysroot's import-library directory, or 0 when no win64 toolchain
// is installed. ONE definition: it decides both where `#use <user32>` looks and
// which resolved files are ambient system libraries, and those two answers have
// to agree or a library resolves and is then refused.
String* win64SysLibDir(void)
    {
    String* tcRoot = Platform.env(String.withCString("XTC_WIN64_TOOLCHAIN"));
    if (tcRoot == (String*)0 || tcRoot.byteLength() == (u32)0)
        tcRoot = String.withCString("/opt/clang/win64");
    String* d = String.withString(tcRoot);
    d.appendCString("/x86_64-w64-mingw32/lib");
    return Files.exists(d) ? d : (String*)0;
    }

Preprocessor* buildPP(FeOptions* o)
    {
    Preprocessor* pp = new Preprocessor();
    predefine(pp, o);
    // `#package` is wasm32-only and the preprocessor has to be able to say so.
    pp.setArch(platformOf(o));
    for (u32 i = (u32)0; i < o.incs().count(); i = i + (u32)1)
        pp.addIncludePath((String*)o.incs().get(i));
    for (u32 i = (u32)0; i < o.libs().count(); i = i + (u32)1)
        pp.addLibraryPath((String*)o.libs().get(i));
    // The target's implicit platform header, when it has one. win64's declares
    // the Win32 entry points a program reaches the native API through; a target
    // without one simply skips it rather than failing every compile.
    if (hasPlatformPrelude(o))
        pp.setPrelude(String.withCString("Platform.xc"));
    // A -D on the command line comes LAST, so it wins over the target's own.
    for (u32 i = (u32)0; i < o.defs().count(); i = i + (u32)1)
        defineArg(pp, (String*)o.defs().get(i));
    return pp;
    }

// The driver's predefines, per target. These are not conveniences — inline asm
// in the runtime library reads them, and the preprocessor cannot ask a memory
// model a question, so the driver answers it here in macros.
void predefine(Preprocessor* pp, FeOptions* o)
    {
    String* plat = platformOf(o);
    bool xt = plat.equals(String.withCString("xt6502"));

    // The printf scratch buffers come from the layout's `buffers` map. xt
    // declares none, so all three are zero there; every other target keeps the
    // DEFAULT model's — the driver loads no memory model for a native backend
    // and the default one is still the flat 6502's, which is where these
    // addresses come from. They mean nothing on arm64, but the macros are
    // expanded into inline asm the library still carries, so agreeing matters
    // more than making sense.
    if (xt)
        {
        pp.define(String.withCString("XT_STDIO_FMT_BUF"), String.withCString("$0000"));
        pp.define(String.withCString("XT_PRINTF_BUF"), String.withCString("$0000"));
        pp.define(String.withCString("XT_PRINTF_DATA_BUF"), String.withCString("$0002"));
        }
    else
        {
        pp.define(String.withCString("XT_STDIO_FMT_BUF"), String.withCString("$04C0"));
        pp.define(String.withCString("XT_PRINTF_BUF"), String.withCString("$0480"));
        pp.define(String.withCString("XT_PRINTF_DATA_BUF"), String.withCString("$0482"));
        }

    // The platform LAYER's defines, beside the ISA's: ARCH_arm64 says what
    // the code is, PLATFORM_ios says where it runs (and _sim which flavour).
    if (o.libPlatform() != (String*)0 && o.libPlatform().hasPrefix(String.withCString("ios")))
        {
        pp.define(String.withCString("PLATFORM_ios"), String.withCString("1"));
        if (o.libPlatform().equals(String.withCString("ios-sim")))
            pp.define(String.withCString("PLATFORM_ios_sim"), String.withCString("1"));
        }
    pp.define(String.withCString("BANK_DATA"), String.withCString("0"));
    pp.define(String.withCString("BANK_CODE"), String.withCString("1"));
    pp.define(String.withCString("BANK_C"), String.withCString("2"));

    if (plat.equals(String.withCString("atarist")))
        pp.define(String.withCString("ARCH_m68k"), String.withCString("1"));
    else if (plat.equals(String.withCString("win64")))
        {
        // Windows is x86-64 — the ISA guard AND the OS guard both apply.
        pp.define(String.withCString("ARCH_x86_64"), String.withCString("1"));
        pp.define(String.withCString("ARCH_win64"), String.withCString("1"));
        }
    else if (plat.equals(String.withCString("x86_64")))
        pp.define(String.withCString("ARCH_x86_64"), String.withCString("1"));
    else if (plat.equals(String.withCString("arm9")))
        pp.define(String.withCString("ARCH_arm9"), String.withCString("1"));
    else if (plat.equals(String.withCString("arm64")))
        pp.define(String.withCString("ARCH_arm64"), String.withCString("1"));
    else if (plat.equals(String.withCString("wasm32")))
        pp.define(String.withCString("ARCH_wasm32"), String.withCString("1"));
    else if (plat.equals(String.withCString("xt6502")))
        pp.define(String.withCString("ARCH_6502"), String.withCString("1"));
    else
        {
        // NOT a silent default. wasm32 was missing from this chain and fell
        // through to ARCH_6502 — so the shipped compiler built wasm against the
        // 6502 branches of every shared library. Object.hash took the `#if
        // ARCH_6502` arm and returned a u8 folded from a u16 pointer, which is
        // how a stored callback ended up trapping inside _xtc_weak_register
        // (bug 083).
        //
        // platformOf() a hundred lines below carries the same lesson, learned
        // the same way and written down at the time: "A default that is a valid
        // answer can never announce itself." This chain kept its silent default
        // anyway. It does not have one now.
        Stdio.printf("xc-fe: error: no ARCH_ macro is mapped for platform '%s'\n",
                     plat.cString());
        Stdio.printf("       (a shared library dispatches on ARCH_<arch>; falling\n"
                     "        back to another target's branch compiles something\n"
                     "        that builds, runs, and is wrong)\n");
        Process.exit((i32)2);
        }

    // A literal in the driver too — the heap pointer's width in the SOURCE's
    // eyes, not the target's.
    pp.define(String.withCString("XTC_POINTER_WIDTH"), String.withCString("4"));

    // The xtc SOFTWARE stack exists only where the hardware one is too shallow
    // for the runtime's recursion frames. xt has a 4 KB hidden hardware stack
    // and drops XTC_SP entirely; defining it there would alias the backend's
    // own spill pointer.
    if (!xt)
        {
        pp.define(String.withCString("XTC_SP_LO"), String.withCString("$82"));
        pp.define(String.withCString("XTC_SP_HI"), String.withCString("$83"));
        }
    pp.define(String.withCString("XTC_HP_LO"), String.withCString(xt ? "$8E" : "$86"));
    pp.define(String.withCString("XTC_HP_HI"), String.withCString(xt ? "$8F" : "$87"));
    if (xt)
        pp.define(String.withCString("XTC_TARGET_BANKED"), String.withCString("1"));
    else
        pp.define(String.withCString("XTC_TARGET_STANDARD"), String.withCString("1"));
    pp.define(String.withCString("XTC_TARGET_SHADOW"), String.withCString("0"));
    pp.define(String.withCString("XTC_HAS_CLOAKED"), String.withCString("0"));
    pp.define(String.withCString("XTC_LIB_HWSTACK"), String.withCString(xt ? "1" : "0"));
    }

void defineArg(Preprocessor* pp, String* arg)
    {
    u32 eq = arg.indexOfByte((u8)'=');
    if (eq == String.notFound())
        {
        pp.define(arg, String.withCString("1"));
        return;
        }
    pp.define(arg.substringBytes((u32)0, eq), arg.substringFromByte(eq + (u32)1));
    }

// The module name is the file's basename with its extension removed.
String* moduleNameOf(String* path)
    {
    u32 slash = String.notFound();
    for (u32 i = (u32)0; i < path.byteLength(); i = i + (u32)1)
        if (path.byteAt(i) == (u8)'/')
            slash = i;
    String* base = (slash == String.notFound()) ? path : path.substringFromByte(slash + (u32)1);
    u32 dot = String.notFound();
    for (u32 i = (u32)0; i < base.byteLength(); i = i + (u32)1)
        if (base.byteAt(i) == (u8)'.')
            dot = i;
    if (dot == String.notFound())
        return base;
    return base.substringBytes((u32)0, dot);
    }
