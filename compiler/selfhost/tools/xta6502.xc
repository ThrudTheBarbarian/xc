// xta6502.xc — xcc-as, the 6502 assembler: Atari XEX, banked XEX, C64 PRG.
// =================================================================
//
//   xcc-as [options] <input.asm ...>
//
// The options are the ones printed by -h. Banking comes from a layout (-L), the
// same .lnk the compiler reads, so the windows and bank registers live in one
// place. The harnesses also drive the older spellings, which set the banking
// directly:
//
//   -e <entry-symbol>  -code-window LO-HI  -data-window LO-HI
//   -code-reg R  -data-reg R  -split-bank

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "PlatformCore.xc"
#import "Xta.xc"
#import "XtaHost.xc"

#ifndef XCC_VERSION
#define XCC_VERSION "unversioned"
#endif

void say(string s)
    {
    Stdio.error(String.withCString(s));
    }

void sayLine(String* s)
    {
    String* m = String.withString(s);
    m.appendCString("\n");
    Stdio.error(m);
    }

void usage(void)
    {
    say("xcc-as — 6502 assembler\n"
        "Usage: xcc-as [options] <input.asm ...>\n"
        "Options:\n"
        "  -D name[=value]  Define a symbol\n"
        "  -f <which>       Output format: xex (default), prg\n"
        "  -I path          Add include search path\n"
        "  -o path          Output file (default: input stem + .xex)\n"
        "  -l path          Output listing file\n"
        "  -b               Enable banked output mode (for xtc bank-switched targets)\n"
        "  --split-bank     xt Option B: segments at $6000-$7FFF get $83-only preloads,\n"
        "                   segments at $4000-$5FFF get $82-only preloads. Requires -b.\n"
        "  --data-window START:END  Data-window bounds for --split-bank (hex, e.g. $6000:$7FFF).\n"
        "  -L <layout.lnk>  Read banking windows + bank registers from a layout file\n"
        "                   (the same .lnk the xtc driver uses). Enables banked output\n"
        "                   when the layout declares a [banking] section.\n"
        "  -s path          Load platform symbol file (.sym)\n"
        "  -v, --version    Print version\n"
        "  -V               Verbose (show all warnings)\n"
        "  -h               Show this help\n"
        "\n"
        "The output format is auto-detected from the -o extension (.prg = PRG,\n"
        "anything else = XEX), or set explicitly with -f.\n");
    }

// `$6000-$9FFF` — a hex range, for the legacy window flags.
void parseRange(String* s, u32* lo, u32* hi)
    {
    u32 dash = s.byteIndexOf(String.withCString("-"));
    if (dash == (u32)$FFFF_FFFF)
        return;
    *lo = parseHex(s.substringBytes((u32)0, dash));
    *hi = parseHex(s.substringFromByte(dash + (u32)1));
    }

u32 parseHex(String* s0)
    {
    String* s = s0.trimmed();
    if (s.hasPrefix(String.withCString("$")))
        s = s.substringFromByte((u32)1);
    u32 v = (u32)0;
    for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
        {
        i32 d = XaText.hexDigit(s.byteAt(i));
        if (d < (i32)0)
            break;
        v = v * (u32)16 + (u32)d;
        }
    return v;
    }

// $XCC_HOME / $XTC_HOME as written, less quotes and backslashes.
String* envPath(string name)
    {
    String* raw = Platform.env(String.withCString(name));
    if (raw == (String*)0 || raw.byteLength() == (u32)0)
        return (String*)0;
    String* s = XaText.tws(raw);
    if (s.byteLength() >= (u32)2 && s.hasPrefix(String.withCString("\"")) && s.hasSuffix(String.withCString("\"")))
        s = s.substringBytes((u32)1, s.byteLength() - (u32)2);
    String* o = new String();
    for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
        o.appendByte(s.byteAt(i) == (u8)'\\' ? (u8)'/' : s.byteAt(i));
    return o.byteLength() > (u32)0 ? o : (String*)0;
    }

// The support tree under a home: lib/xc (an install), xc (Windows), support
// (the source tree).
String* supportUnder(String* home)
    {
    if (home == (String*)0 || home.byteLength() == (u32)0)
        return (String*)0;
    Array* rels = new Array();
    rels.add((Object*)String.withCString("lib/xc"));
    rels.add((Object*)String.withCString("xc"));
    rels.add((Object*)String.withCString("support"));
    for (u32 i = (u32)0; i < rels.count(); i = i + (u32)1)
        {
        String* p = XaPath.appending(home, (String*)rels.get(i));
        if (XaDir.isDirectory(p))
            return p;
        }
    return (String*)0;
    }

// The support tree the compiler would find: $XCC_HOME, $XTC_HOME, beside this
// binary and one level up, the current directory, then the install roots.
String* supportRoot(void)
    {
    Array* cands = new Array();
    String* e1 = envPath("XCC_HOME");
    if (e1 != (String*)0)
        cands.add((Object*)e1);
    String* e2 = envPath("XTC_HOME");
    if (e2 != (String*)0)
        cands.add((Object*)e2);
    String* bin = XaPath.deletingLastComponent(Process.argument((u32)0));
    if (bin.byteLength() > (u32)0)
        {
        cands.add((Object*)bin);
        cands.add((Object*)XaPath.appending(bin, String.withCString("..")));
        }
    cands.add((Object*)String.withCString("."));
    String* home = Platform.home();
    if (home != (String*)0 && home.byteLength() > (u32)0)
        {
        cands.add((Object*)XaPath.appending(home, String.withCString("xcc")));
        cands.add((Object*)XaPath.appending(home, String.withCString("xtc")));
        }
    String* opt = String.withCString("/opt/xcc/");
    opt.appendCString(XCC_VERSION);
    cands.add((Object*)opt);
    cands.add((Object*)String.withCString("/opt/xcc"));
    cands.add((Object*)String.withCString("/usr/local/xcc"));
    cands.add((Object*)String.withCString("/usr/local/xtc"));
    cands.add((Object*)String.withCString("/opt/xtc"));
    for (u32 i = (u32)0; i < cands.count(); i = i + (u32)1)
        {
        String* r = supportUnder((String*)cands.get(i));
        if (r != (String*)0)
            return r;
        }
    return (String*)0;
    }

// Every `.sym` under <root>/atari/symbols and <root>/generic/symbols, each
// directory in name order.
Array* platformSymbolFiles(String* root)
    {
    Array* out = new Array();
    Array* dirs = new Array();
    dirs.add((Object*)XaPath.appending(XaPath.appending(root, String.withCString("atari")), String.withCString("symbols")));
    dirs.add((Object*)XaPath.appending(XaPath.appending(root, String.withCString("generic")), String.withCString("symbols")));
    for (u32 d = (u32)0; d < dirs.count(); d = d + (u32)1)
        {
        String* dir = (String*)dirs.get(d);
        Array* names = XaDir.list(dir);
        if (names == (Array*)0)
            continue;
        XaDir.sort(names);
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* name = (String*)names.get(i);
            if (XaPath.extension(name).equals(String.withCString("sym")))
                out.add((Object*)XaPath.appending(dir, name));
            }
        }
    return out;
    }

// START:END, each half hex with or without a leading $ or 0x.
bool parseDataWindow(String* v, u32* lo, u32* hi)
    {
    Array* parts = v.splitOnByte((u8)':');
    if (parts.count() != (u32)2)
        {
        say("xcc-as: --data-window expects START:END\n");
        return false;
        }
    for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
        {
        String* s = (String*)parts.get(k);
        if (s.hasPrefix(String.withCString("$")))
            s = s.substringFromByte((u32)1);
        else if (s.hasPrefix(String.withCString("0x")) || s.hasPrefix(String.withCString("0X")))
            s = s.substringFromByte((u32)2);
        u32 u = (u32)0;
        u32 end = (u32)0;
        if (!XaText.scanHex(s, &u, &end) || !XaText.restIsWs(s, end))
            {
            String* m = String.withCString("xcc-as: --data-window bad hex '");
            m.append(s);
            m.appendCString("'\n");
            Stdio.error(m);
            return false;
            }
        if (k == (u32)0)
            *lo = u & (u32)$FFFF;
        else
            *hi = u & (u32)$FFFF;
        }
    return true;
    }

Data* toData(Array* img)
    {
    Data* d = Data.withCapacity(img.count());
    for (u32 k = (u32)0; k < img.count(); k = k + (u32)1)
        d.appendByte((u8)((Number*)img.get(k)).asU32());
    return d;
    }

void main(void)
    {
    Array* inputFiles = new Array();
    Array* includePaths = new Array();
    Array* defNames = new Array();
    Array* defValues = new Array();
    String* outputPath = (String*)0;
    String* listingPath = (String*)0;
    String* formatStr = (String*)0;
    String* symbolsFile = (String*)0;
    String* layoutPath = (String*)0;
    bool banked = false;
    bool verbose = false;
    bool splitBanking = false;
    u32 dataWindowStart = (u32)0;
    u32 dataWindowEnd = (u32)0;
    // The older spellings.
    String* entrySym = (String*)0;
    bool legacySplit = false;
    u32 codeLo = (u32)0;
    u32 codeHi = (u32)0;
    u32 dataLo = (u32)0;
    u32 dataHi = (u32)0;
    u32 codeReg = (u32)0;
    u32 dataReg = (u32)0;

    u32 argc = Process.argumentCount();
    u32 i = (u32)1;
    while (i < argc)
        {
        String* arg = Process.argument(i);
        bool more = i + (u32)1 < argc;
        if (arg.equals(String.withCString("-h")))
            {
            usage();
            Process.exit((i32)0);
            return;
            }
        if (arg.equals(String.withCString("-v")) || arg.equals(String.withCString("--version")))
            {
            Stdio.printf("xcc-as %s\n", XCC_VERSION);
            Process.exit((i32)0);
            return;
            }
        if (arg.equals(String.withCString("-V")))
            verbose = true;
        else if (arg.equals(String.withCString("-b")))
            banked = true;
        else if (arg.equals(String.withCString("--split-bank")))
            splitBanking = true;
        else if (arg.equals(String.withCString("--data-window")) && more)
            {
            i = i + (u32)1;
            if (!parseDataWindow(Process.argument(i), &dataWindowStart, &dataWindowEnd))
                {
                Process.exit((i32)1);
                return;
                }
            }
        else if (arg.equals(String.withCString("-L")) && more)
            {
            i = i + (u32)1;
            layoutPath = Process.argument(i);
            }
        else if (arg.equals(String.withCString("-f")) && more)
            {
            i = i + (u32)1;
            formatStr = Process.argument(i).lowercased();
            }
        else if (arg.equals(String.withCString("-s")) && more)
            {
            i = i + (u32)1;
            symbolsFile = Process.argument(i);
            }
        else if (arg.equals(String.withCString("-o")) && more)
            {
            i = i + (u32)1;
            outputPath = Process.argument(i);
            }
        else if (arg.equals(String.withCString("-l")) && more)
            {
            i = i + (u32)1;
            listingPath = Process.argument(i);
            }
        else if (arg.equals(String.withCString("-I")) && more)
            {
            i = i + (u32)1;
            includePaths.add((Object*)Process.argument(i));
            }
        else if (arg.hasPrefix(String.withCString("-D")))
            {
            String* def = String.withCString("");
            if (arg.byteLength() > (u32)2)
                def = arg.substringFromByte((u32)2);
            else if (more)
                {
                i = i + (u32)1;
                def = Process.argument(i);
                }
            u32 eq = def.indexOfByte((u8)'=');
            if (eq != (u32)$FFFF_FFFF)
                {
                defNames.add((Object*)def.substringBytes((u32)0, eq));
                defValues.add((Object*)def.substringFromByte(eq + (u32)1));
                }
            else
                {
                defNames.add((Object*)def);
                defValues.add((Object*)String.withCString("1"));
                }
            }
        else if (arg.equals(String.withCString("-e")) && more)
            {
            i = i + (u32)1;
            entrySym = Process.argument(i);
            }
        else if (arg.equals(String.withCString("-split-bank")))
            legacySplit = true;
        else if (arg.equals(String.withCString("-code-window")) && more)
            {
            i = i + (u32)1;
            parseRange(Process.argument(i), &codeLo, &codeHi);
            }
        else if (arg.equals(String.withCString("-data-window")) && more)
            {
            i = i + (u32)1;
            parseRange(Process.argument(i), &dataLo, &dataHi);
            }
        else if (arg.equals(String.withCString("-code-reg")) && more)
            {
            i = i + (u32)1;
            codeReg = parseHex(Process.argument(i));
            }
        else if (arg.equals(String.withCString("-data-reg")) && more)
            {
            i = i + (u32)1;
            dataReg = parseHex(Process.argument(i));
            }
        else if (arg.hasPrefix(String.withCString("-")))
            {
            String* m = String.withCString("xcc-as: unknown option '");
            m.append(arg);
            m.appendCString("'\n");
            Stdio.error(m);
            Process.exit((i32)1);
            return;
            }
        else
            inputFiles.add((Object*)arg);
        i = i + (u32)1;
        }

    if (inputFiles.count() == (u32)0)
        {
        say("xcc-as: no input files\n");
        usage();
        Process.exit((i32)1);
        return;
        }
    String* firstInput = (String*)inputFiles.get((u32)0);

    if (outputPath == (String*)0)
        {
        bool prg = formatStr != (String*)0 && formatStr.equals(String.withCString("prg"));
        outputPath = XaPath.appendingExtension(XaPath.deletingExtension(firstInput),
                                               String.withCString(prg ? "prg" : "xex"));
        }

    // Every input, each followed by a newline, is one source.
    String* source = new String();
    for (u32 k = (u32)0; k < inputFiles.count(); k = k + (u32)1)
        {
        String* path = (String*)inputFiles.get(k);
        String* text = Files.readText(path);
        String* why = XaPath.readFailure(path, text);
        if (why != (String*)0)
            {
            String* m = String.withCString("xcc-as: cannot read '");
            m.append(path);
            m.appendCString("': ");
            m.append(why);
            sayLine(m);
            Process.exit((i32)1);
            return;
            }
        source.append(text);
        source.appendCString("\n");
        }

    Xta* a = new Xta();
    a.setVerbose(verbose);
    a.setIncludePaths(includePaths);
    a.setFilename(firstInput);
    if (symbolsFile != (String*)0)
        a.setSymbolsFile(symbolsFile);
    else
        {
        // The platform's `.sym` files, found under the support tree the
        // compiler uses.
        String* root = supportRoot();
        if (root != (String*)0)
            {
            Array* files = platformSymbolFiles(root);
            if (files.count() > (u32)0)
                a.setSymbolsFiles(files);
            }
        }

    // The older spellings set the banking directly.
    a.setBankRegs(codeReg, dataReg);
    if (codeHi != (u32)0)
        a.setBankWindow(codeLo, codeHi);
    if (dataHi != (u32)0)
        a.setDataWindow(dataLo, dataHi);
    if (legacySplit)
        a.setSplitBanking(true);

    if (splitBanking)
        {
        a.setSplitBanking(true);
        a.setDataWindow(dataWindowStart, dataWindowEnd);
        }

    // A layout with a [banking] section configures the assembler as the
    // compiler does from the same file, and implies banked output.
    if (layoutPath != (String*)0)
        {
        XaLayout* m = XaLayout.read(layoutPath);
        if (m.error() != (String*)0)
            {
            String* msg = String.withCString("xcc-as: cannot read layout '");
            msg.append(layoutPath);
            msg.appendCString("': ");
            msg.append(m.error());
            sayLine(msg);
            Process.exit((i32)1);
            return;
            }
        if (m.hasBanking())
            {
            banked = true;
            a.setBankWindow(m.bankWindowStart(), m.bankWindowEnd());
            Array* mr = m.mainRanges();
            if (mr != (Array*)0 && mr.count() >= (u32)2)
                a.setMainRegion(((Number*)mr.get((u32)0)).asU32(),
                                ((Number*)mr.get(mr.count() - (u32)1)).asU32());
            u32 cr = m.codeBankReg() != (u32)0 ? m.codeBankReg() : codeReg;
            u32 dr = m.dataBankReg() != (u32)0 ? m.dataBankReg() : dataReg;
            a.setBankRegs(cr, dr);
            if (m.hasSplitBanking())
                {
                a.setSplitBanking(true);
                a.setDataWindow(m.dataWindowStart(), m.dataWindowEnd());
                }
            if (m.hasRegionC())
                a.setRegionC(m.regCWindowStart(), m.regCWindowEnd(), m.regCBankRegLo(), m.regCBankRegHi());
            }
        }

    for (u32 k = (u32)0; k < defNames.count(); k = k + (u32)1)
        a.defineSymbol((String*)defNames.get(k), (String*)defValues.get(k));

    Array* lines = a.preprocess(source, firstInput);
    bool ok = a.assemble(lines);
    for (u32 k = (u32)0; k < a.warnings().count(); k = k + (u32)1)
        {
        String* m = String.withCString("xcc-as: warning: ");
        m.append((String*)a.warnings().get(k));
        sayLine(m);
        }
    if (!ok)
        {
        for (u32 k = (u32)0; k < a.errors().count(); k = k + (u32)1)
            {
            String* m = String.withCString("xcc-as: error: ");
            m.append((String*)a.errors().get(k));
            sayLine(m);
            }
        Process.exit((i32)1);
        return;
        }

    Array* segs = a.segments();
    u32 entry = segs.count() > (u32)0 ? ((XaSegment*)segs.get((u32)0)).origin() : (u32)$3400;
    if (entrySym != (String*)0)
        {
        Object* e = a.symbols().get((Hashable*)entrySym);
        if (e != (Object*)0)
            entry = (u32)((Number*)e).asI64() & (u32)$FFFF;
        }

    bool usePRG = (formatStr != (String*)0 && formatStr.equals(String.withCString("prg")))
                  || (formatStr == (String*)0 && XaPath.extension(outputPath).lowercased().equals(String.withCString("prg")));
    Array* img = (Array*)0;
    if (usePRG)
        img = a.writePrg();
    else if (banked)
        img = a.writeBankedXex(entry);
    else
        img = a.writeXex(entry);
    if (img == (Array*)0 || outputPath == (String*)0 || !Files.writeData(outputPath, toData(img)))
        {
        String* m = String.withCString("xcc-as: error: cannot write '");
        m.append(outputPath == (String*)0 ? String.withCString("(null)") : outputPath);
        m.appendCString("'");
        sayLine(m);
        Process.exit((i32)1);
        return;
        }

    if (listingPath != (String*)0)
        Files.writeText(listingPath, a.listing());

    u32 total = (u32)0;
    for (u32 k = (u32)0; k < segs.count(); k = k + (u32)1)
        total = total + ((XaSegment*)segs.get(k)).data().count();
    String* m = String.withCString("xcc-as: assembled '");
    m.append(firstInput);
    m.appendCString("' -> '");
    m.append(outputPath);
    m.appendCString("' (");
    m.append(String.withU32(total));
    m.appendCString(" bytes, ");
    m.append(String.withU32(segs.count()));
    m.appendCString(segs.count() == (u32)1 ? " segment)" : " segments)");
    sayLine(m);
    }
