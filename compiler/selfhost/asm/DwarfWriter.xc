// DwarfWriter.xc — DWARF 4 debug information for an executable xcc linked.
// =================================================================
//
// The port of XTDwarfWriter. What -g produces: a line table (.debug_line) and
// a compile unit with one subprogram per function (.debug_info, .debug_abbrev,
// .debug_str), plus call frames (.debug_frame), so a debugger can break on
// file:line, step by line and name every frame.
//
// Format-independent: the assembler records the `.file`/`.loc` rows and each
// frame setup into the PENDING writer, and whichever executable writer places
// the text (Mach-O, ELF, PE) asks it for the sections at the address the text
// was given. Every section is an Array of Number@ bytes, as the writers' own
// images are.

#import "Foundation.xc"

#ifndef XCC_VERSION
#define XCC_VERSION "unversioned"
#endif

// The assemblers read `.file <n> "<path>"` and `.loc <n> <line> [<col>]` the
// way the original's NSScanner does: blanks skipped, an optional sign, then at
// least one digit.
class DwarfScan
{
    String* _s;
    u32 _i;
    i32 _value;

    static DwarfScan* over(String* s, u32 from)
    {
        DwarfScan* d = new DwarfScan();
        d._s = s;
        d._i = from;
        return d;
    }

    i32 value(void) { return _value; }

    bool scanInt(void)
    {
        u32 n = _s.byteLength();
        u32 i = _i;
        while (i < n && (_s.byteAt(i) == (u8)' ' || _s.byteAt(i) == (u8)9 || _s.byteAt(i) == (u8)10
                         || _s.byteAt(i) == (u8)13))
            i = i + (u32)1;
        bool neg = false;
        if (i < n && (_s.byteAt(i) == (u8)'-' || _s.byteAt(i) == (u8)'+')) {
            neg = _s.byteAt(i) == (u8)'-';
            i = i + (u32)1;
        }
        if (i >= n || _s.byteAt(i) < (u8)'0' || _s.byteAt(i) > (u8)'9') return false;
        i32 v = (i32)0;
        while (i < n && _s.byteAt(i) >= (u8)'0' && _s.byteAt(i) <= (u8)'9') {
            v = v * (i32)10 + (i32)(_s.byteAt(i) - (u8)'0');
            i = i + (u32)1;
        }
        _i = i;
        _value = neg ? -v : v;
        return true;
    }

    // The text between the first and the last `"` of `s`, or 0 when there is
    // no such pair.
    static String* quotedPath(String* s)
    {
        u32 n = s.byteLength();
        u32 q1 = (u32)$FFFF_FFFF;
        u32 q2 = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i < n; i = i + (u32)1) {
            if (s.byteAt(i) == (u8)34) {
                if (q1 == (u32)$FFFF_FFFF) q1 = i;
                q2 = i;
            }
        }
        if (q1 == (u32)$FFFF_FFFF || q2 <= q1) return (String*)0;
        return s.substringBytes(q1 + (u32)1, q2 - q1 - (u32)1);
    }
}

// A variable of a function: `name` lives at `reg` + `off` (DWARF register
// number) for the whole function containing text offset `at`; `type` is its IR
// type as the IR text spells it.
class DwarfVar
{
    u32 _at;
    String* _name;
    u32 _reg;
    i64 _off;
    String* _type;
    bool _param;

    static DwarfVar* make(u32 at, String* name, u32 reg, i64 off, String* type, bool param)
    {
        DwarfVar* v = new DwarfVar();
        v._at = at;
        v._name = name;
        v._reg = reg;
        v._off = off;
        v._type = type;
        v._param = param;
        return v;
    }
    u32 at(void)        { return _at; }
    String* name(void)  { return _name; }
    u32 reg(void)       { return _reg; }
    i64 off(void)       { return _off; }
    String* type(void)  { return _type; }
    bool param(void)    { return _param; }
}

class DwarfWriter
{
    static DwarfWriter* _pending;

    Array* _files;      // String@ by `.file` number, 0 where none was given
    Array* _rowOff;     // Number@ u32, one per `.loc`, in offset order
    Array* _rowFile;
    Array* _rowLine;
    Array* _rowCol;
    Array* _frameSetups; // Number@ u32 text offsets
    Array* _frameSizes;  // Number@ u32, parallel: the call frame's distance above fp
    Array* _variables;   // DwarfVar@, in assembly order
    Map* _typeDie;       // IR type spelling -> Number@ its DIE's unit offset (0 = none)
    Array* _secs;        // the five sections, in the writers' order

    void init(void)
    {
        _files = new Array();
        _rowOff = new Array();
        _rowFile = new Array();
        _rowLine = new Array();
        _rowCol = new Array();
        _frameSetups = new Array();
        _frameSizes = new Array();
        _variables = new Array();
        _secs = new Array();
    }

    // The debug information of the program being assembled, if it has any:
    // the assembler records it here and the writer that places the text reads
    // (and clears) it.
    static DwarfWriter* pending(void) { return _pending; }
    static void setPending(DwarfWriter* w) { _pending = w; }

    // One `.file`/`.loc` directive, its operands in `ops` from byte `from`,
    // recorded against text offset `offset` (a `.loc` only counts in text).
    // `dwarf` is the writer so far, or 0; the result is the writer after this
    // line — a new one once a directive with a file number is seen.
    static DwarfWriter* directive(DwarfWriter* dwarf, String* ops, u32 from, bool isFile,
                                  bool inText, u32 offset)
    {
        DwarfScan* sc = DwarfScan.over(ops, from);
        if (!sc.scanInt()) return dwarf;
        u32 fileNo = (u32)sc.value();
        DwarfWriter* w = dwarf;
        if (w == (DwarfWriter*)0) w = new DwarfWriter();
        if (isFile) {
            String* p = DwarfScan.quotedPath(ops);
            if (p != (String*)0) w.setFile(fileNo, p);
        } else if (inText && sc.scanInt()) {
            u32 lineNo = (u32)sc.value();
            u32 colNo = (u32)0;
            if (sc.scanInt()) colNo = (u32)sc.value();
            w.addRow(offset, fileNo, lineNo, colNo);
        }
        return w;
    }

    void setFile(u32 number, String* path)
    {
        while (_files.count() <= number)
            _files.add((Object*)0);
        _files.set(number, (Object*)path);
    }

    String* fileAt(u32 number)
    {
        if (number >= _files.count()) return (String*)0;
        return (String*)_files.get(number);
    }

    // One row per `.loc`: the text offset it applies from and its file/line/col.
    // Two locations at one address (a statement that emitted no code): the
    // later one is the one that address belongs to.
    void addRow(u32 offset, u32 file, u32 line, u32 column)
    {
        u32 n = _rowOff.count();
        if (n > (u32)0 && ((Number*)_rowOff.get(n - (u32)1)).asU32() == offset) {
            _rowFile.set(n - (u32)1, (Object*)Number.withU32(file));
            _rowLine.set(n - (u32)1, (Object*)Number.withU32(line));
            _rowCol.set(n - (u32)1, (Object*)Number.withU32(column));
            return;
        }
        _rowOff.add((Object*)Number.withU32(offset));
        _rowFile.add((Object*)Number.withU32(file));
        _rowLine.add((Object*)Number.withU32(line));
        _rowCol.add((Object*)Number.withU32(column));
    }

    // A frame record set up at `offset` (the instruction after which the frame
    // pointer holds the address of the saved {fp, lr} pair): from there the
    // call frame is fp + 16.
    // The call frame is fp + `frameSize` from there, the {fp, return
    // address} pair at its bottom (16 on x86-64; on arm64 the frame size above
    // x29).
    void addFrameSetup(u32 offset, u32 frameSize)
    {
        _frameSetups.add((Object*)Number.withU32(offset));
        _frameSizes.add((Object*)Number.withU32(frameSize));
    }

    void addVariable(String* name, u32 at, u32 reg, i64 off, String* type, bool param)
    {
        _variables.add((Object*)DwarfVar.make(at, name, reg, off, type, param));
    }

    // `.xc_var "<name>" <reg> <offset> "<type>"` (or `.xc_param`), its text
    // in `ops`: a variable of the function being assembled, recorded against
    // text offset `at`. `dwarf` is the writer so far, or 0.
    static DwarfWriter* variableDirective(DwarfWriter* dwarf, String* ops, bool param, u32 at)
    {
        Array* q = ops.splitOnByte((u8)34);
        if (q.count() < (u32)5) return dwarf;
        DwarfScan* sc = DwarfScan.over((String*)q.get((u32)2), (u32)0);
        if (!sc.scanInt()) return dwarf;
        u32 reg = (u32)sc.value();
        if (!sc.scanInt()) return dwarf;
        i64 off = (i64)sc.value();
        DwarfWriter* w = dwarf;
        if (w == (DwarfWriter*)0) w = new DwarfWriter();
        w.addVariable((String*)q.get((u32)1), at, reg & (u32)$FF, off, (String*)q.get((u32)3), param);
        return w;
    }

    // True once any row was recorded: a build without -g has none and gets no
    // debug sections.
    bool hasRows(void) { return _rowOff.count() > (u32)0; }

    // The writers' function list: every symbol of `symbols` (name -> text
    // offset) that is not a data symbol and not a `.`-local label, with
    // `prefix` required and stripped when it is non-empty (Mach-O's `_`), and
    // only offsets below `textLimit` when that is not $FFFFFFFF (ELF). In
    // DESCENDING name order, so that once build() sorts them by address (a
    // stable sort) two names at one address keep the order the original's
    // comparator gives them: the last takes the range, the name sorting first.
    static void functionsOf(Map* symbols, Array* dataSyms, String* prefix, u32 textLimit,
                            Array* names, Array* offs)
    {
        Map* dset = new Map();
        for (u32 i = (u32)0; i < dataSyms.count(); i = i + (u32)1)
            dset.set((Hashable*)dataSyms.get(i), (Object*)Number.withU32((u32)1));
        Array* keys = symbols.allKeys();
        keys.sort();
        for (u32 ri = keys.count(); ri > (u32)0; ri = ri - (u32)1) {
            String* nm = (String*)keys.get(ri - (u32)1);
            if (prefix.byteLength() > (u32)0) {
                if (!nm.hasPrefix(prefix)) continue;
            } else if (nm.hasPrefix(String.withCString("."))) continue;
            if (dset.get((Hashable*)nm) != (Object*)0) continue;
            Object* off = symbols.get((Hashable*)nm);
            if (textLimit != (u32)$FFFF_FFFF && ((Number*)off).asU32() >= textLimit) continue;
            names.add((Object*)(prefix.byteLength() > (u32)0 ? nm.substringFromByte(prefix.byteLength()) : nm));
            offs.add(off);
        }
    }

    // The section names, in the order every writer places them.
    static Array* order(void)
    {
        Array* a = new Array();
        a.add((Object*)String.withCString("debug_line"));
        a.add((Object*)String.withCString("debug_info"));
        a.add((Object*)String.withCString("debug_abbrev"));
        a.add((Object*)String.withCString("debug_str"));
        a.add((Object*)String.withCString("debug_frame"));
        return a;
    }

    // Section `i` of order(), after build().
    Array* section(u32 i) { return (Array*)_secs.get(i); }

    // ── byte helpers ──────────────────────────────────────────────────
    static void putU8(Array* d, u32 v) { d.add((Object*)Number.withU32(v & (u32)$FF)); }
    static void putU16(Array* d, u32 v)
    {
        DwarfWriter.putU8(d, v);
        DwarfWriter.putU8(d, v >> (u32)8);
    }
    static void putU32(Array* d, u32 v)
    {
        DwarfWriter.putU8(d, v);
        DwarfWriter.putU8(d, v >> (u32)8);
        DwarfWriter.putU8(d, v >> (u32)16);
        DwarfWriter.putU8(d, v >> (u32)24);
    }
    static void putU64(Array* d, u64 v)
    {
        DwarfWriter.putU32(d, (u32)(v & (u64)$FFFF_FFFF));
        DwarfWriter.putU32(d, (u32)(v >> (u64)32));
    }
    static void putULEB(Array* d, u64 v0)
    {
        u64 v = v0;
        bool more = true;
        while (more) {
            u32 b = (u32)(v & (u64)$7F);
            v = v >> (u64)7;
            if (v != (u64)0) b = b | (u32)$80;
            else more = false;
            DwarfWriter.putU8(d, b);
        }
    }
    static void putSLEB(Array* d, i64 v0)
    {
        i64 v = v0;
        bool more = true;
        while (more) {
            u32 b = (u32)(v & (i64)$7F);
            v = v >> (i64)7;   // arithmetic: v is signed
            if ((v == (i64)0 && (b & (u32)$40) == (u32)0) || (v == (i64)-1 && (b & (u32)$40) != (u32)0))
                more = false;
            else
                b = b | (u32)$80;
            DwarfWriter.putU8(d, b);
        }
    }
    static void putCString(Array* d, String* s)
    {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            DwarfWriter.putU8(d, (u32)s.byteAt(i));
        DwarfWriter.putU8(d, (u32)0);
    }
    static void patchU32(Array* d, u32 at, u32 v)
    {
        d.set(at, (Object*)Number.withU32(v & (u32)$FF));
        d.set(at + (u32)1, (Object*)Number.withU32((v >> (u32)8) & (u32)$FF));
        d.set(at + (u32)2, (Object*)Number.withU32((v >> (u32)16) & (u32)$FF));
        d.set(at + (u32)3, (Object*)Number.withU32((v >> (u32)24) & (u32)$FF));
    }

    // ── .debug_str ────────────────────────────────────────────────────
    Array* _str;
    Map*   _strOffsets;  // String -> Number@ offset

    u32 strp(String* s)
    {
        Object* have = _strOffsets.get((Hashable*)s);
        if (have != (Object*)0) return ((Number*)have).asU32();
        u32 at = _str.count();
        DwarfWriter.putCString(_str, s);
        _strOffsets.set((Hashable*)s, (Object*)Number.withU32(at));
        return at;
    }

    // Function names and their text offsets, sorted by offset (stable, so a
    // tie keeps the order given). Each runs to the next one, or to the end of
    // the text.
    static void sortByOffset(Array* names, Array* offs)
    {
        u32 n = offs.count();
        if (n < (u32)2) return;
        // A bottom-up merge sort of the pairs: stable, and n log n where the
        // runtime alone has thousands of functions.
        Array* srcN = new Array();
        Array* srcO = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1) {
            srcN.add(names.get(i));
            srcO.add(offs.get(i));
        }
        Array* dstN = new Array();
        Array* dstO = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1) {
            dstN.add((Object*)0);
            dstO.add((Object*)0);
        }
        u32 width = (u32)1;
        while (width < n) {
            u32 lo = (u32)0;
            while (lo < n) {
                u32 mid = lo + width < n ? lo + width : n;
                u32 hi = lo + width + width < n ? lo + width + width : n;
                u32 a = lo;
                u32 b = mid;
                u32 k = lo;
                while (k < hi) {
                    bool takeA = a < mid
                        && (b >= hi || ((Number*)srcO.get(a)).asU32() <= ((Number*)srcO.get(b)).asU32());
                    if (takeA) {
                        dstN.set(k, srcN.get(a));
                        dstO.set(k, srcO.get(a));
                        a = a + (u32)1;
                    } else {
                        dstN.set(k, srcN.get(b));
                        dstO.set(k, srcO.get(b));
                        b = b + (u32)1;
                    }
                    k = k + (u32)1;
                }
                lo = hi;
            }
            for (u32 i = (u32)0; i < n; i = i + (u32)1) {
                srcN.set(i, dstN.get(i));
                srcO.set(i, dstO.get(i));
            }
            width = width + width;
        }
        for (u32 i = (u32)0; i < n; i = i + (u32)1) {
            names.set(i, srcN.get(i));
            offs.set(i, srcO.get(i));
        }
    }

    // The sections, for text placed at `textAddress` with `textSize` bytes.
    // `names`/`offs` are the functions (name, text offset), in any order —
    // sorted here. `minInsnLength` is 4 on arm64 and 1 on x86-64.
    // `frameRegister` is the DWARF number of the frame pointer (29 on arm64, 6
    // on x86-64).
    void build(u64 textAddress, u32 textSize, Array* names, Array* offs,
               u32 minInsnLength, u32 frameRegister)
    {
        _str = new Array();
        _strOffsets = new Map();
        _secs = new Array();
        DwarfWriter.sortByOffset(names, offs);
        Array* line = buildLine(textAddress, textSize, minInsnLength);
        Array* abbrev = buildAbbrev();
        Array* info = buildInfo(textAddress, textSize, names, offs, frameRegister);
        Array* frame = buildFrame(textAddress, textSize, names, offs, minInsnLength);
        _secs.add((Object*)line);
        _secs.add((Object*)info);
        _secs.add((Object*)abbrev);
        _secs.add((Object*)_str);
        _secs.add((Object*)frame);
    }

    // ---- .debug_line ----
    Array* buildLine(u64 textAddress, u32 textSize, u32 minInsnLength)
    {
        // File numbers as `.file` gave them; the line table numbers files from 1.
        u32 maxFile = (u32)0;
        for (u32 f = (u32)0; f < _files.count(); f = f + (u32)1)
            if (_files.get(f) != (Object*)0 && f > maxFile) maxFile = f;

        Array* line = new Array();
        DwarfWriter.putU32(line, (u32)0); // unit_length, patched
        DwarfWriter.putU16(line, (u32)4);
        u32 headerLengthAt = line.count();
        DwarfWriter.putU32(line, (u32)0); // header_length, patched
        u32 headerStart = line.count();
        DwarfWriter.putU8(line, minInsnLength);
        DwarfWriter.putU8(line, (u32)1);    // maximum_operations_per_instruction
        DwarfWriter.putU8(line, (u32)1);    // default_is_stmt
        DwarfWriter.putU8(line, (u32)$FB);  // line_base, -5
        DwarfWriter.putU8(line, (u32)14);   // line_range
        DwarfWriter.putU8(line, (u32)13);   // opcode_base
        // standard_opcode_lengths
        DwarfWriter.putU8(line, (u32)0); DwarfWriter.putU8(line, (u32)1); DwarfWriter.putU8(line, (u32)1);
        DwarfWriter.putU8(line, (u32)1); DwarfWriter.putU8(line, (u32)1); DwarfWriter.putU8(line, (u32)0);
        DwarfWriter.putU8(line, (u32)0); DwarfWriter.putU8(line, (u32)0); DwarfWriter.putU8(line, (u32)1);
        DwarfWriter.putU8(line, (u32)0); DwarfWriter.putU8(line, (u32)0); DwarfWriter.putU8(line, (u32)1);
        DwarfWriter.putU8(line, (u32)0); // no include directories: file names are full paths
        for (u32 f = (u32)1; f <= maxFile; f = f + (u32)1) {
            String* p = fileAt(f);
            DwarfWriter.putCString(line, p == (String*)0 ? String.withCString("<unknown>") : p);
            DwarfWriter.putULEB(line, (u64)0);
            DwarfWriter.putULEB(line, (u64)0);
            DwarfWriter.putULEB(line, (u64)0);
        }
        DwarfWriter.putU8(line, (u32)0);
        DwarfWriter.patchU32(line, headerLengthAt, line.count() - headerStart);

        DwarfWriter.putU8(line, (u32)0);
        DwarfWriter.putULEB(line, (u64)9);
        DwarfWriter.putU8(line, (u32)2); // DW_LNE_set_address
        DwarfWriter.putU64(line, textAddress);
        u32 addr = (u32)0;
        i64 curLine = (i64)1;
        u32 curFile = (u32)1;
        u32 curCol = (u32)0;
        for (u32 i = (u32)0; i < _rowOff.count(); i = i + (u32)1) {
            u32 off = ((Number*)_rowOff.get(i)).asU32();
            u32 file = ((Number*)_rowFile.get(i)).asU32();
            u32 ln = ((Number*)_rowLine.get(i)).asU32();
            u32 col = ((Number*)_rowCol.get(i)).asU32();
            if (off > addr) {
                DwarfWriter.putU8(line, (u32)2); // DW_LNS_advance_pc
                DwarfWriter.putULEB(line, (u64)((off - addr) / minInsnLength));
                addr = off;
            }
            if (file != curFile) {
                DwarfWriter.putU8(line, (u32)4); // DW_LNS_set_file
                DwarfWriter.putULEB(line, (u64)file);
                curFile = file;
            }
            if ((i64)ln != curLine) {
                DwarfWriter.putU8(line, (u32)3); // DW_LNS_advance_line
                DwarfWriter.putSLEB(line, (i64)ln - curLine);
                curLine = (i64)ln;
            }
            if (col != curCol) {
                DwarfWriter.putU8(line, (u32)5); // DW_LNS_set_column
                DwarfWriter.putULEB(line, (u64)col);
                curCol = col;
            }
            DwarfWriter.putU8(line, (u32)1); // DW_LNS_copy
        }
        if (textSize > addr) {
            DwarfWriter.putU8(line, (u32)2);
            DwarfWriter.putULEB(line, (u64)((textSize - addr) / minInsnLength));
        }
        DwarfWriter.putU8(line, (u32)0);
        DwarfWriter.putULEB(line, (u64)1);
        DwarfWriter.putU8(line, (u32)1); // DW_LNE_end_sequence
        DwarfWriter.patchU32(line, (u32)0, line.count() - (u32)4);
        return line;
    }

    // ---- .debug_abbrev ----
    static Array* buildAbbrev(void)
    {
        Array* a = new Array();
        DwarfWriter.putULEB(a, (u64)1);
        DwarfWriter.putULEB(a, (u64)$11); // DW_TAG_compile_unit
        DwarfWriter.putU8(a, (u32)1);     // has children
        DwarfWriter.putULEB(a, (u64)$25); DwarfWriter.putULEB(a, (u64)$0E); // producer, strp
        DwarfWriter.putULEB(a, (u64)$13); DwarfWriter.putULEB(a, (u64)$05); // language, data2
        DwarfWriter.putULEB(a, (u64)$03); DwarfWriter.putULEB(a, (u64)$0E); // name, strp
        DwarfWriter.putULEB(a, (u64)$1B); DwarfWriter.putULEB(a, (u64)$0E); // comp_dir, strp
        DwarfWriter.putULEB(a, (u64)$11); DwarfWriter.putULEB(a, (u64)$01); // low_pc, addr
        DwarfWriter.putULEB(a, (u64)$12); DwarfWriter.putULEB(a, (u64)$07); // high_pc, data8
        DwarfWriter.putULEB(a, (u64)$10); DwarfWriter.putULEB(a, (u64)$17); // stmt_list, sec_offset
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putULEB(a, (u64)2);
        DwarfWriter.putULEB(a, (u64)$2E); // DW_TAG_subprogram
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putULEB(a, (u64)$03); DwarfWriter.putULEB(a, (u64)$0E); // name, strp
        DwarfWriter.putULEB(a, (u64)$11); DwarfWriter.putULEB(a, (u64)$01); // low_pc, addr
        DwarfWriter.putULEB(a, (u64)$12); DwarfWriter.putULEB(a, (u64)$07); // high_pc, data8
        DwarfWriter.putULEB(a, (u64)$3F); DwarfWriter.putULEB(a, (u64)$19); // external, flag_present
        DwarfWriter.putULEB(a, (u64)$40); DwarfWriter.putULEB(a, (u64)$18); // frame_base, exprloc
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putU8(a, (u32)0);
        // 3: a subprogram with variables (the same attributes, and children).
        DwarfWriter.putULEB(a, (u64)3);
        DwarfWriter.putULEB(a, (u64)$2E);
        DwarfWriter.putU8(a, (u32)1);
        DwarfWriter.putULEB(a, (u64)$03); DwarfWriter.putULEB(a, (u64)$0E);
        DwarfWriter.putULEB(a, (u64)$11); DwarfWriter.putULEB(a, (u64)$01);
        DwarfWriter.putULEB(a, (u64)$12); DwarfWriter.putULEB(a, (u64)$07);
        DwarfWriter.putULEB(a, (u64)$3F); DwarfWriter.putULEB(a, (u64)$19);
        DwarfWriter.putULEB(a, (u64)$40); DwarfWriter.putULEB(a, (u64)$18);
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putU8(a, (u32)0);
        // 4: a variable: name, type, location.
        DwarfWriter.putULEB(a, (u64)4);
        DwarfWriter.putULEB(a, (u64)$34); // DW_TAG_variable
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putULEB(a, (u64)$03); DwarfWriter.putULEB(a, (u64)$0E); // name, strp
        DwarfWriter.putULEB(a, (u64)$49); DwarfWriter.putULEB(a, (u64)$13); // type, ref4
        DwarfWriter.putULEB(a, (u64)$02); DwarfWriter.putULEB(a, (u64)$18); // location, exprloc
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putU8(a, (u32)0);
        // 5: a base type: name, encoding, size.
        DwarfWriter.putULEB(a, (u64)5);
        DwarfWriter.putULEB(a, (u64)$24); // DW_TAG_base_type
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putULEB(a, (u64)$03); DwarfWriter.putULEB(a, (u64)$0E); // name, strp
        DwarfWriter.putULEB(a, (u64)$3E); DwarfWriter.putULEB(a, (u64)$0B); // encoding, data1
        DwarfWriter.putULEB(a, (u64)$0B); DwarfWriter.putULEB(a, (u64)$0B); // byte_size, data1
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putU8(a, (u32)0);
        // 6: a pointer to a type; 7: a pointer to nothing in particular.
        DwarfWriter.putULEB(a, (u64)6);
        DwarfWriter.putULEB(a, (u64)$0F); // DW_TAG_pointer_type
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putULEB(a, (u64)$49); DwarfWriter.putULEB(a, (u64)$13); // type, ref4
        DwarfWriter.putULEB(a, (u64)$0B); DwarfWriter.putULEB(a, (u64)$0B); // byte_size, data1
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putULEB(a, (u64)7);
        DwarfWriter.putULEB(a, (u64)$0F);
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putULEB(a, (u64)$0B); DwarfWriter.putULEB(a, (u64)$0B);
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putU8(a, (u32)0);
        // 8: a parameter, with the variable's attributes.
        DwarfWriter.putULEB(a, (u64)8);
        DwarfWriter.putULEB(a, (u64)$05); // DW_TAG_formal_parameter
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putULEB(a, (u64)$03); DwarfWriter.putULEB(a, (u64)$0E);
        DwarfWriter.putULEB(a, (u64)$49); DwarfWriter.putULEB(a, (u64)$13);
        DwarfWriter.putULEB(a, (u64)$02); DwarfWriter.putULEB(a, (u64)$18);
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putU8(a, (u32)0);
        DwarfWriter.putU8(a, (u32)0);
        return a;
    }

    // ---- .debug_info ----
    Array* buildInfo(u64 textAddress, u32 textSize, Array* names, Array* offs, u32 frameRegister)
    {
        String* mainFile = fileAt((u32)1);
        if (mainFile == (String*)0) mainFile = String.withCString("<unknown>");
        Array* info = new Array();
        DwarfWriter.putU32(info, (u32)0); // unit_length, patched
        DwarfWriter.putU16(info, (u32)4);
        DwarfWriter.putU32(info, (u32)0); // abbrev offset
        DwarfWriter.putU8(info, (u32)8);  // address size
        DwarfWriter.putULEB(info, (u64)1);
        DwarfWriter.putU32(info, strp(String.withCString("xcc " XCC_VERSION)));
        DwarfWriter.putU16(info, (u32)$0C); // DW_LANG_C99
        DwarfWriter.putU32(info, strp(mainFile.lastPathComponent()));
        DwarfWriter.putU32(info, strp(mainFile.deletingLastPathComponent()));
        DwarfWriter.putU64(info, textAddress);
        DwarfWriter.putU64(info, (u64)textSize);
        DwarfWriter.putU32(info, (u32)0); // stmt_list: the one line program, at 0

        // The variables' types, each once, as the IR spells them.
        _typeDie = new Map();
        for (u32 i = (u32)0; i < _variables.count(); i = i + (u32)1)
            typeRef(info, ((DwarfVar*)_variables.get(i)).type());

        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1) {
            u32 start = ((Number*)offs.get(i)).asU32();
            u32 end = (i + (u32)1 < names.count()) ? ((Number*)offs.get(i + (u32)1)).asU32() : textSize;
            if (end <= start) continue;
            // This function's variables with a type: parameters first, each
            // group in assembly order (a stable sort on the parameter flag).
            Array* vars = new Array();
            for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1)
                for (u32 k = (u32)0; k < _variables.count(); k = k + (u32)1) {
                    DwarfVar* v = (DwarfVar*)_variables.get(k);
                    if (v.param() != (pass == (u32)0)) continue;
                    if (v.at() < start || v.at() >= end) continue;
                    if (((Number*)_typeDie.get((Hashable*)v.type())).asU32() == (u32)0) continue;
                    vars.add((Object*)v);
                }
            DwarfWriter.putULEB(info, vars.count() > (u32)0 ? (u64)3 : (u64)2);
            DwarfWriter.putU32(info, strp((String*)names.get(i)));
            DwarfWriter.putU64(info, textAddress + (u64)start);
            DwarfWriter.putU64(info, (u64)(end - start));
            DwarfWriter.putULEB(info, (u64)1);
            DwarfWriter.putU8(info, (u32)$50 + frameRegister); // DW_OP_reg0 + n
            if (vars.count() > (u32)0) {
                for (u32 k = (u32)0; k < vars.count(); k = k + (u32)1) {
                    DwarfVar* v = (DwarfVar*)vars.get(k);
                    DwarfWriter.putULEB(info, v.param() ? (u64)8 : (u64)4);
                    DwarfWriter.putU32(info, strp(v.name()));
                    DwarfWriter.putU32(info, ((Number*)_typeDie.get((Hashable*)v.type())).asU32());
                    Array* loc = new Array();
                    DwarfWriter.putU8(loc, (u32)$70 + v.reg()); // DW_OP_breg0 + n
                    DwarfWriter.putSLEB(loc, v.off());
                    DwarfWriter.putULEB(info, (u64)loc.count());
                    for (u32 b = (u32)0; b < loc.count(); b = b + (u32)1)
                        info.add(loc.get(b));
                }
                DwarfWriter.putU8(info, (u32)0); // end of the subprogram's children
            }
        }
        DwarfWriter.putU8(info, (u32)0); // end of the compile unit's children
        DwarfWriter.patchU32(info, (u32)0, info.count() - (u32)4);
        return info;
    }

    // The DIE of IR type `t`, written into `info` the first time it is asked
    // for: scalars become base types, Ptr(T, ...) a pointer to T's DIE
    // (Ptr(Void) a bare pointer). A type with no DWARF form here (an
    // aggregate) has none: 0. Offsets are from the start of the unit.
    u32 typeRef(Array* info, String* t)
    {
        Object* have = _typeDie.get((Hashable*)t);
        if (have != (Object*)0) return ((Number*)have).asU32();
        u32 at = (u32)0;
        String* bn = (String*)0;
        u32 enc = (u32)0;
        u32 size = (u32)0;
        if (t.equals(String.withCString("I8")))       { bn = String.withCString("i8");     enc = (u32)6; size = (u32)1; }
        else if (t.equals(String.withCString("U8")))  { bn = String.withCString("u8");     enc = (u32)8; size = (u32)1; }
        else if (t.equals(String.withCString("I16"))) { bn = String.withCString("i16");    enc = (u32)5; size = (u32)2; }
        else if (t.equals(String.withCString("U16"))) { bn = String.withCString("u16");    enc = (u32)7; size = (u32)2; }
        else if (t.equals(String.withCString("I32"))) { bn = String.withCString("i32");    enc = (u32)5; size = (u32)4; }
        else if (t.equals(String.withCString("U32"))) { bn = String.withCString("u32");    enc = (u32)7; size = (u32)4; }
        else if (t.equals(String.withCString("I64"))) { bn = String.withCString("i64");    enc = (u32)5; size = (u32)8; }
        else if (t.equals(String.withCString("U64"))) { bn = String.withCString("u64");    enc = (u32)7; size = (u32)8; }
        else if (t.equals(String.withCString("F32"))) { bn = String.withCString("float");  enc = (u32)4; size = (u32)4; }
        else if (t.equals(String.withCString("F64"))) { bn = String.withCString("double"); enc = (u32)4; size = (u32)8; }
        else if (t.equals(String.withCString("Bool")) || t.equals(String.withCString("I1")))
                                                      { bn = String.withCString("bool");   enc = (u32)2; size = (u32)1; }
        if (bn != (String*)0) {
            at = info.count();
            DwarfWriter.putULEB(info, (u64)5);
            DwarfWriter.putU32(info, strp(bn));
            DwarfWriter.putU8(info, enc);
            DwarfWriter.putU8(info, size);
        } else if (t.hasPrefix(String.withCString("Ptr(")) && t.hasSuffix(String.withCString(")"))) {
            // The pointee is everything up to the top-level comma.
            String* inner = t.substringBytes((u32)4, t.byteLength() - (u32)5);
            i32 depth = (i32)0;
            u32 cut = inner.byteLength();
            for (u32 i = (u32)0; i < inner.byteLength(); i = i + (u32)1) {
                u8 c = inner.byteAt(i);
                if (c == (u8)'(') depth = depth + (i32)1;
                else if (c == (u8)')') depth = depth - (i32)1;
                else if (c == (u8)',' && depth == (i32)0) { cut = i; break; }
            }
            String* pointee = inner.substringBytes((u32)0, cut);
            u32 to = pointee.equals(String.withCString("Void")) ? (u32)0 : typeRef(info, pointee);
            at = info.count();
            if (to != (u32)0) {
                DwarfWriter.putULEB(info, (u64)6);
                DwarfWriter.putU32(info, to);
            } else
                DwarfWriter.putULEB(info, (u64)7);
            DwarfWriter.putU8(info, (u32)8);
        }
        _typeDie.set((Hashable*)t, (Object*)Number.withU32(at));
        return at;
    }

    // ---- .debug_frame ----
    // One CIE: on entry the call frame is the stack pointer and the return
    // address is in the link register. Then one FDE per function, which moves
    // the frame to fp + 16 once the frame record is set up (where fp and lr
    // are saved at -16 and -8).
    Array* buildFrame(u64 textAddress, u32 textSize, Array* names, Array* offs, u32 minInsnLength)
    {
        bool a64 = minInsnLength == (u32)4;
        Array* frame = new Array();
        u32 spReg = a64 ? (u32)31 : (u32)7;  // arm64 sp / x86-64 rsp
        u32 raReg = a64 ? (u32)30 : (u32)16; // arm64 lr / x86-64 return address column
        u32 fpReg = a64 ? (u32)29 : (u32)6;
        DwarfWriter.putU32(frame, (u32)0);          // length, patched
        DwarfWriter.putU32(frame, (u32)$FFFF_FFFF); // CIE id
        DwarfWriter.putU8(frame, (u32)1);           // version
        DwarfWriter.putU8(frame, (u32)0);           // augmentation ""
        DwarfWriter.putULEB(frame, (u64)minInsnLength); // code alignment
        DwarfWriter.putSLEB(frame, (i64)-8);            // data alignment
        DwarfWriter.putU8(frame, raReg);
        DwarfWriter.putU8(frame, (u32)$0C); // DW_CFA_def_cfa
        DwarfWriter.putULEB(frame, (u64)spReg);
        DwarfWriter.putULEB(frame, a64 ? (u64)0 : (u64)8);
        if (!a64) {
            DwarfWriter.putU8(frame, (u32)$80 | raReg); // DW_CFA_offset: return address at cfa-8
            DwarfWriter.putULEB(frame, (u64)1);
        }
        while (frame.count() % (u32)8 != (u32)0)
            DwarfWriter.putU8(frame, (u32)0); // DW_CFA_nop
        DwarfWriter.patchU32(frame, (u32)0, frame.count() - (u32)4);

        // The frame setups in offset order.
        Array* setups = new Array();
        Array* sizes = new Array();
        for (u32 i = (u32)0; i < _frameSetups.count(); i = i + (u32)1) {
            setups.add(_frameSetups.get(i));
            sizes.add(_frameSizes.get(i));
        }
        DwarfWriter.sortByOffset(sizes, setups);

        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1) {
            u32 start = ((Number*)offs.get(i)).asU32();
            u32 end = (i + (u32)1 < names.count()) ? ((Number*)offs.get(i + (u32)1)).asU32() : textSize;
            if (end <= start) continue;
            u32 fdeAt = frame.count();
            DwarfWriter.putU32(frame, (u32)0); // length, patched
            DwarfWriter.putU32(frame, (u32)0); // CIE at offset 0
            DwarfWriter.putU64(frame, textAddress + (u64)start);
            DwarfWriter.putU64(frame, (u64)(end - start));
            for (u32 k = (u32)0; k < setups.count(); k = k + (u32)1) {
                u32 at = ((Number*)setups.get(k)).asU32();
                u32 size = ((Number*)sizes.get(k)).asU32();
                if (at < start || at >= end) continue;
                u32 delta = (at - start) / minInsnLength;
                DwarfWriter.putU8(frame, (u32)$02); // DW_CFA_advance_loc1 (a prologue is short)
                DwarfWriter.putU8(frame, delta > (u32)255 ? (u32)255 : delta);
                DwarfWriter.putU8(frame, (u32)$0C); // DW_CFA_def_cfa fp, size
                DwarfWriter.putULEB(frame, (u64)fpReg);
                DwarfWriter.putULEB(frame, (u64)size);
                DwarfWriter.putU8(frame, (u32)$80 | fpReg); // fp at cfa-size
                DwarfWriter.putULEB(frame, (u64)(size / (u32)8));
                DwarfWriter.putU8(frame, (u32)$80 | raReg); // return address just above it
                DwarfWriter.putULEB(frame, (u64)(size / (u32)8 - (u32)1));
                break;
            }
            while ((frame.count() - fdeAt) % (u32)8 != (u32)0)
                DwarfWriter.putU8(frame, (u32)0);
            DwarfWriter.patchU32(frame, fdeAt, frame.count() - fdeAt - (u32)4);
        }
        return frame;
    }

    // The total size of the five sections.
    u32 totalSize(void)
    {
        u32 t = (u32)0;
        for (u32 i = (u32)0; i < _secs.count(); i = i + (u32)1)
            t = t + section(i).count();
        return t;
    }
}
