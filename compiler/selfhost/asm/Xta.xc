// Xta.xc — the banked-6502 assembler, in xtc.
// =================================================================
//
// self-hosting M24, a port of `XAAssembler`. Two passes over the source, with
// size-changing rewrites in between: pass 1 assigns label addresses, the
// long-branch and cross-bank rewriters may change instruction lengths, and the
// whole thing re-runs until the line list stops moving. Then pass 2 resolves
// every expression and emits bytes into origin-tagged segments, which the XEX
// writer turns into a loadable Atari binary.
//
// Two things here have no equivalent in the other assemblers.
//
// The 6502's conditional branches reach +/-127 bytes and nothing further, so an
// out-of-range branch is REWRITTEN as its inverse over a JMP. That changes the
// instruction's length, which moves every label after it — hence the iteration
// to a fixpoint rather than a single sizing pass.
//
// And code lives in declared REGIONS with hardware in the gaps between them. An
// instruction that would cross a region boundary is bridged: a JMP into the next
// region, or just a `.org` when the preceding instruction was an unconditional
// transfer and nothing falls through.

#import "Foundation.xc"
#import "Files.xc"
#import "Xa6502.xc"

#define LT_EMPTY 0
#define LT_LABEL 1
#define LT_INSTRUCTION 2
#define LT_ASSIGNMENT 3
#define LT_ORG 4
#define LT_BYTE 5
#define LT_WORD 6
#define LT_LONG 7
#define LT_STRING 8
#define LT_SPACE 9
#define LT_CODE_REGIONS 10
#define LT_BANK 11
#define LT_SPILL_POINT 12

class XaLine
    {
    u32 _type;
    String* _label;
    bool _labelIsLocal;
    String* _mnemonic;
    String* _operand;
    u32 _mode;
    u32 _byteSize;
    u32 _address;
    Array* _dataValues; // String@ per element
    String* _assignName;
    String* _assignValue;
    String* _rawText;
    u32 _sourceLine;
    bool _isLongbrInverse;

    void init(void)
        {
        _type = (u32)LT_EMPTY;
        _labelIsLocal = false;
        _mode = (u32)AM_IMPLIED;
        _byteSize = (u32)0;
        _address = (u32)0;
        _sourceLine = (u32)0;
        _isLongbrInverse = false;
        }

    u32 type(void)
        {
        return _type;
        }
    String* label(void)
        {
        return _label;
        }
    bool labelIsLocal(void)
        {
        return _labelIsLocal;
        }
    String* mnemonic(void)
        {
        return _mnemonic;
        }
    String* operand(void)
        {
        return _operand;
        }
    u32 mode(void)
        {
        return _mode;
        }
    u32 byteSize(void)
        {
        return _byteSize;
        }
    u32 address(void)
        {
        return _address;
        }
    Array* dataValues(void)
        {
        return _dataValues;
        }
    String* assignName(void)
        {
        return _assignName;
        }
    String* assignValue(void)
        {
        return _assignValue;
        }
    String* rawText(void)
        {
        return _rawText;
        }
    u32 sourceLine(void)
        {
        return _sourceLine;
        }
    bool isLongbrInverse(void)
        {
        return _isLongbrInverse;
        }

    void setType(u32 v)
        {
        _type = v;
        }
    void setLabel(String* v)
        {
        _label = v;
        }
    void setLabelIsLocal(bool v)
        {
        _labelIsLocal = v;
        }
    void setMnemonic(String* v)
        {
        _mnemonic = v;
        }
    void setOperand(String* v)
        {
        _operand = v;
        }
    void setMode(u32 v)
        {
        _mode = v;
        }
    void setByteSize(u32 v)
        {
        _byteSize = v;
        }
    void setAddress(u32 v)
        {
        _address = v;
        }
    void setDataValues(Array* v)
        {
        _dataValues = v;
        }
    void setAssign(String* n, String* v)
        {
        _assignName = n;
        _assignValue = v;
        }
    void setRawText(String* v)
        {
        _rawText = v;
        }
    void setSourceLine(u32 v)
        {
        _sourceLine = v;
        }
    void setLongbrInverse(bool v)
        {
        _isLongbrInverse = v;
        }
    }

    // A contiguous block of assembled bytes at a load origin.
    class XaSegment
    {
    u32 _origin;
    Array* _data; // Number@ per byte
    // A `.bank <id>` segment carries an EXPLICIT bank number, allocated so it
    // cannot clash with the encounter-order user banks. -1 means "use the
    // running counter" — a plain `.org` into the window.
    i32 _bankNumber;

    void init(void)
        {
        _origin = (u32)0;
        _data = new Array();
        _bankNumber = (i32)-1;
        }

    i32 bankNumber(void)
        {
        return _bankNumber;
        }
    void setBankNumber(i32 v)
        {
        _bankNumber = v;
        }

    static XaSegment* at(u32 origin)
        {
        XaSegment* s = new XaSegment();
        s._origin = origin;
        return s;
        }

    u32 origin(void)
        {
        return _origin;
        }
    Array* data(void)
        {
        return _data;
        }
    void setOrigin(u32 v)
        {
        _origin = v;
        }
    }

    class Xta
    {
    Xa6502* _cpu;
    Map* _symbols;  // name -> value
    Array* _lines;  // XaLine@
    Array* _errors; // String@
    Array* _warnings;
    u32 _pc;
    String* _lastGlobalLabel;
    Array* _codeRegions; // pairs of Number@: lo, hi
    u32 _currentRegionIndex;
    bool _pcInsideMainRegion;
    bool _finalRegionOverflowReported;
    u32 _codeBankReg;
    u32 _dataBankReg;
    Array* _segments; // XaSegment@
    Map* _bankIds;    // `.bank` identifier -> its physical bank number
    Map* _labelBank;  // label -> the bank it is defined in
    u32 _bankWindowSegSeen;
    u32 _curDirectiveBank;

    void init(void)
        {
        _cpu = new Xa6502();
        _symbols = new Map();
        _lines = new Array();
        _errors = new Array();
        _warnings = new Array();
        _codeBankReg = (u32)0;
        _dataBankReg = (u32)0;
        }

    void setBankRegs(u32 code, u32 data)
        {
        _codeBankReg = code;
        _dataBankReg = data;
        }

    Array* errors(void)
        {
        return _errors;
        }
    Array* warnings(void)
        {
        return _warnings;
        }
    Array* segments(void)
        {
        return _segments;
        }
    Map* symbols(void)
        {
        return _symbols;
        }

    void err(String* m)
        {
        _errors.add((Object*)m);
        }
    void warn(String* m)
        {
        _warnings.add((Object*)m);
        }

    // ── Expression evaluation ────────────────────────────────────────────
    //
    // `<` and `>` take the low and high byte. Everything else is the usual
    // precedence-free right-split: the LAST top-level `+`/`-` splits first, so
    // evaluation is left-associative, and `*`/`/` bind tighter only because
    // they are looked for second.
    i32 evaluate(String* expr)
        {
        if (expr == (String*)0)
            return (i32)0;
        String* e = expr.trimmed();
        if (e.byteLength() == (u32)0)
            return (i32)0;

        if (e.hasPrefix(String.withCString("<")))
            return evaluate(e.substringFromByte((u32)1)) & (i32)$FF;
        if (e.hasPrefix(String.withCString(">")))
            return (evaluate(e.substringFromByte((u32)1)) >> (i32)8) & (i32)$FF;

        i32 parenDepth = (i32)0;
        i32 lastAddSub = (i32)-1;
        i32 lastMulDiv = (i32)-1;
        u32 i = e.byteLength();
        while (i > (u32)0)
            {
            i = i - (u32)1;
            u8 ch = e.byteAt(i);
            if (ch == (u8)')')
                parenDepth = parenDepth + (i32)1;
            else if (ch == (u8)'(')
                parenDepth = parenDepth - (i32)1;
            else if (parenDepth == (i32)0)
                {
                if ((ch == (u8)'+' || ch == (u8)'-') && i > (u32)0)
                    {
                    lastAddSub = (i32)i;
                    break;
                    }
                if ((ch == (u8)'*' || ch == (u8)'/') && i > (u32)0 && lastMulDiv < (i32)0)
                    lastMulDiv = (i32)i;
                }
            }
        if (lastAddSub > (i32)0)
            {
            i32 left = evaluate(e.substringBytes((u32)0, (u32)lastAddSub));
            u8 op = e.byteAt((u32)lastAddSub);
            i32 right = evaluate(e.substringFromByte((u32)lastAddSub + (u32)1));
            return op == (u8)'+' ? left + right : left - right;
            }
        if (lastMulDiv > (i32)0)
            {
            i32 left = evaluate(e.substringBytes((u32)0, (u32)lastMulDiv));
            u8 op = e.byteAt((u32)lastMulDiv);
            i32 right = evaluate(e.substringFromByte((u32)lastMulDiv + (u32)1));
            if (op == (u8)'*')
                return left * right;
            return right != (i32)0 ? left / right : (i32)0;
            }
        if (e.hasPrefix(String.withCString("(")) && e.hasSuffix(String.withCString(")")))
            return evaluate(e.substringBytes((u32)1, e.byteLength() - (u32)2));

        if (e.hasPrefix(String.withCString("$")))
            return (i32)parseRadix(e.substringFromByte((u32)1), (u32)16);
        if (e.hasPrefix(String.withCString("%")))
            return (i32)parseRadix(e.substringFromByte((u32)1), (u32)2);

        // A DEFINED symbol always wins over the Z80-style hex suffix, so a
        // pathological label like `0abch` — digit-first, all hex, trailing h,
        // and indistinguishable from a literal by any heuristic — resolves to
        // the label when one exists.
        Object* sym = _symbols.get((Hashable*)e);
        if (sym != (Object*)0)
            return (i32)((Number*)sym).asU32();

        if (isZ80Hex(e))
            return (i32)parseRadix(e.substringBytes((u32)0, e.byteLength() - (u32)1), (u32)16);

        // A decimal literal needs EVERY character to be a digit. Checking only
        // the first made `12h_skip` evaluate to 12, because the C parse stops
        // at the `h`.
        if (allDigits(e))
            return (i32)parseRadix(e, (u32)10);

        String* m = String.withCString("undefined symbol '");
        m.append(e);
        m.appendCString("', using 0");
        warn(m);
        return (i32)0;
        }

    // Pass 1's zero-page test: -1 would be a real value, so an unresolvable
    // expression answers $100 — "assume not zero page".
    i32 tryEvaluate(String* expr)
        {
        if (expr == (String*)0)
            return (i32)-1;
        String* e = expr.trimmed();
        if (e.hasPrefix(String.withCString("$")))
            return (i32)parseRadix(e.substringFromByte((u32)1), (u32)16);
        if (e.hasPrefix(String.withCString("%")))
            return (i32)parseRadix(e.substringFromByte((u32)1), (u32)2);
        if (allDigits(e))
            return (i32)parseRadix(e, (u32)10);
        Object* sym = _symbols.get((Hashable*)e);
        if (sym != (Object*)0)
            return (i32)((Number*)sym).asU32();
        return (i32)$100;
        }

    static bool allDigits(String* e)
        {
        if (e.byteLength() == (u32)0)
            return false;
        u8 f = e.byteAt((u32)0);
        if (f < (u8)'0' || f > (u8)'9')
            return false;
        for (u32 i = (u32)0; i < e.byteLength(); i = i + (u32)1)
            {
            u8 c = e.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return false;
            }
        return true;
        }

    static bool isZ80Hex(String* e)
        {
        if (e.byteLength() < (u32)2)
            return false;
        u8 last = e.byteAt(e.byteLength() - (u32)1);
        if (last != (u8)'h' && last != (u8)'H')
            return false;
        u8 first = e.byteAt((u32)0);
        if (first < (u8)'0' || first > (u8)'9')
            return false;
        for (u32 i = (u32)0; i + (u32)1 < e.byteLength(); i = i + (u32)1)
            {
            u8 c = e.byteAt(i);
            bool hex = (c >= (u8)'0' && c <= (u8)'9') || (c >= (u8)'a' && c <= (u8)'f') || (c >= (u8)'A' && c <= (u8)'F');
            if (!hex)
                return false;
            }
        return true;
        }

    // Parses as far as the digits go and stops, exactly as the C library does.
    static u32 parseRadix(String* s, u32 base)
        {
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            u32 d;
            if (c >= (u8)'0' && c <= (u8)'9')
                d = (u32)(c - (u8)'0');
            else if (c >= (u8)'a' && c <= (u8)'f')
                d = (u32)(c - (u8)'a') + (u32)10;
            else if (c >= (u8)'A' && c <= (u8)'F')
                d = (u32)(c - (u8)'A') + (u32)10;
            else
                break;
            if (d >= base)
                break;
            v = v * base + d;
            }
        return v;
        }

    static bool isValidIdentifier(String* s)
        {
        if (s.byteLength() == (u32)0)
            return false;
        u8 f = s.byteAt((u32)0);
        if (f == (u8)'>')
            return s.byteLength() > (u32)1;
        return (f >= (u8)'a' && f <= (u8)'z') || (f >= (u8)'A' && f <= (u8)'Z') || f == (u8)'_' || f == (u8)'.';
        }

    // ── Line handling ────────────────────────────────────────────────────
    //
    // A `;` outside a string starts a comment.
    static String* stripComment(String* line)
        {
        bool inString = false;
        for (u32 i = (u32)0; i < line.byteLength(); i = i + (u32)1)
            {
            u8 ch = line.byteAt(i);
            if (ch == (u8)'"')
                inString = !inString;
            if (ch == (u8)';' && !inString)
                return line.substringBytes((u32)0, i);
            }
        return line;
        }

    // The compound separator is " : " — a label's colon has no spaces around
    // it, so `_fn_main:` survives intact while `TXA : PHA` splits in two.
    static Array* splitCompoundLine(String* line)
        {
        Array* out = new Array();
        if (line.byteIndexOf(String.withCString(" : ")) == (u32)$FFFF_FFFF)
            {
            out.add((Object*)line);
            return out;
            }
        u32 start = (u32)0;
        u32 i = (u32)0;
        while (i + (u32)2 < line.byteLength())
            {
            if (line.byteAt(i) == (u8)' ' && line.byteAt(i + (u32)1) == (u8)':' && line.byteAt(i + (u32)2) == (u8)' ')
                {
                String* t = line.substringBytes(start, i - start).trimmed();
                if (t.byteLength() > (u32)0)
                    out.add((Object*)t);
                i = i + (u32)3;
                start = i;
                continue;
                }
            i = i + (u32)1;
            }
        String* t = line.substringFromByte(start).trimmed();
        if (t.byteLength() > (u32)0)
            out.add((Object*)t);
        if (out.count() == (u32)0)
            out.add((Object*)line);
        return out;
        }

    static Array* parseDataList(String* str)
        {
        Array* out = new Array();
        Array* parts = str.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            {
            String* t = ((String*)parts.get(i)).trimmed();
            if (t.byteLength() > (u32)0)
                out.add((Object*)t);
            }
        return out;
        }

    XaLine* parseLine(String* rawLine, u32 lineNum)
        {
        XaLine* pl = new XaLine();
        pl.setSourceLine(lineNum);
        pl.setRawText(rawLine);
        String* line = stripComment(rawLine);
        String* trimmed = line.trimmed();
        if (trimmed.byteLength() == (u32)0)
            return pl;

        String* afterLabel = trimmed;
        u32 colon = trimmed.byteIndexOf(String.withCString(":"));
        if (colon != (u32)$FFFF_FFFF)
            {
            String* before = trimmed.substringBytes((u32)0, colon).trimmed();
            if (before.byteLength() > (u32)0 && isValidIdentifier(before))
                {
                if (before.hasPrefix(String.withCString(">")))
                    {
                    pl.setLabel(before.substringFromByte((u32)1));
                    pl.setLabelIsLocal(true);
                    }
                else if (before.hasPrefix(String.withCString(".")))
                    {
                    pl.setLabel(before); // the dot stays — scoped later
                    pl.setLabelIsLocal(true);
                    }
                else
                    {
                    pl.setLabel(before);
                    pl.setLabelIsLocal(false);
                    }
                afterLabel = trimmed.substringFromByte(colon + (u32)1).trimmed();
                }
            }
        if (afterLabel.byteLength() == (u32)0)
            {
            if (pl.label() != (String*)0)
                pl.setType((u32)LT_LABEL);
            return pl;
            }

        u32 eq = afterLabel.byteIndexOf(String.withCString("="));
        if (eq != (u32)$FFFF_FFFF && eq > (u32)0)
            {
            String* lhs = afterLabel.substringBytes((u32)0, eq).trimmed();
            String* rhs = afterLabel.substringFromByte(eq + (u32)1).trimmed();
            if (isValidIdentifier(lhs) && rhs.byteLength() > (u32)0 && !_cpu.isValidMnemonic(lhs))
                {
                pl.setType((u32)LT_ASSIGNMENT);
                pl.setAssign(lhs, rhs);
                return pl;
                }
            }

        if (parseDirective(pl, afterLabel))
            return pl;

        Array* parts = splitWhitespace(afterLabel);
        if (parts.count() == (u32)0)
            return pl;
        parseInstruction(pl, joinWith(parts, String.withCString(" ")));
        return pl;
        }

    bool parseDirective(XaLine* pl, String* afterLabel)
        {
        String* lc = afterLabel.lowercased();
        if (lc.hasPrefix(String.withCString(".org ")))
            {
            pl.setType((u32)LT_ORG);
            pl.setOperand(afterLabel.substringFromByte((u32)4).trimmed());
            return true;
            }
        if (lc.hasPrefix(String.withCString(".bank ")))
            {
            pl.setType((u32)LT_BANK);
            pl.setOperand(afterLabel.substringFromByte((u32)6).trimmed());
            pl.setByteSize((u32)0);
            return true;
            }
        if (lc.hasPrefix(String.withCString(".code_regions ")))
            {
            pl.setType((u32)LT_CODE_REGIONS);
            pl.setOperand(afterLabel.substringFromByte((u32)14).trimmed());
            return true;
            }
        if (lc.hasPrefix(String.withCString(".spill_point")))
            {
            pl.setType((u32)LT_SPILL_POINT);
            pl.setByteSize((u32)0);
            return true;
            }
        if (lc.hasPrefix(String.withCString(".byte ")))
            {
            pl.setType((u32)LT_BYTE);
            pl.setDataValues(parseDataList(afterLabel.substringFromByte((u32)5)));
            pl.setByteSize(pl.dataValues().count());
            return true;
            }
        if (lc.hasPrefix(String.withCString(".word ")))
            {
            pl.setType((u32)LT_WORD);
            pl.setDataValues(parseDataList(afterLabel.substringFromByte((u32)5)));
            pl.setByteSize(pl.dataValues().count() * (u32)2);
            return true;
            }
        if (lc.hasPrefix(String.withCString(".long ")))
            {
            pl.setType((u32)LT_LONG);
            pl.setDataValues(parseDataList(afterLabel.substringFromByte((u32)5)));
            pl.setByteSize(pl.dataValues().count() * (u32)4);
            return true;
            }
        if (lc.hasPrefix(String.withCString(".string ")))
            {
            pl.setType((u32)LT_STRING);
            String* v = afterLabel.substringFromByte((u32)7).trimmed();
            if (v.hasPrefix(String.withCString("\"")) && v.hasSuffix(String.withCString("\"")))
                v = v.substringBytes((u32)1, v.byteLength() - (u32)2);
            pl.setOperand(v);
            pl.setByteSize(v.byteLength() + (u32)1); // the NUL terminator
            return true;
            }
        if (lc.hasPrefix(String.withCString(".space ")))
            {
            pl.setType((u32)LT_SPACE);
            pl.setOperand(afterLabel.substringFromByte((u32)6).trimmed());
            pl.setByteSize((u32)evaluate(pl.operand()));
            return true;
            }
        return false;
        }

    void parseInstruction(XaLine* pl, String* str)
        {
        Array* parts = splitWhitespace(str);
        if (parts.count() == (u32)0)
            return;
        String* mnemonic = ((String*)parts.get((u32)0)).uppercased();
        // Not an instruction: a macro invocation, already handled upstream.
        if (!_cpu.isValidMnemonic(mnemonic))
            return;

        pl.setType((u32)LT_INSTRUCTION);
        pl.setMnemonic(mnemonic);

        if (parts.count() == (u32)1)
            {
            // A bare shift or rotate means "operate on A"; everything else
            // with no operand is implied.
            if (mnemonic.equals(String.withCString("ASL")) || mnemonic.equals(String.withCString("LSR")) || mnemonic.equals(String.withCString("ROL")) || mnemonic.equals(String.withCString("ROR")))
                pl.setMode((u32)AM_ACCUMULATOR);
            else
                pl.setMode((u32)AM_IMPLIED);
            pl.setByteSize((u32)1);
            return;
            }
        Array* rest = new Array();
        for (u32 i = (u32)1; i < parts.count(); i = i + (u32)1)
            rest.add(parts.get(i));
        String* operand = joinWith(rest, String.withCString(" ")).trimmed();
        pl.setOperand(operand);
        pl.setMode(detectAddressingMode(operand, Xa6502.isBranchMnemonic(mnemonic)));
        pl.setByteSize(Xa6502.byteSizeForMode(pl.mode()));

        if (operand.uppercased().equals(String.withCString("A")))
            {
            pl.setMode((u32)AM_ACCUMULATOR);
            pl.setByteSize((u32)1);
            pl.setOperand((String*)0);
            return;
            }

        // Promote a zero-page form the mnemonic does not have to its absolute
        // one HERE, at parse time. Pass 2 has the same fallback, but it runs
        // after pass 1 has already stamped label addresses with the short
        // size — so every label past the instruction ends up a byte low and
        // the branch offsets miss. The classic case is `LDA $95,Y`: the
        // operand fits a byte so ZP,Y is detected, but only LDX and STX have
        // that mode.
        if (pl.mode() == (u32)AM_ZEROPAGE && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ZEROPAGE) < (i32)0 && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ABSOLUTE) >= (i32)0)
            {
            pl.setMode((u32)AM_ABSOLUTE);
            pl.setByteSize((u32)3);
            }
        else if (pl.mode() == (u32)AM_ZEROPAGEX && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ZEROPAGEX) < (i32)0 && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ABSOLUTEX) >= (i32)0)
            {
            pl.setMode((u32)AM_ABSOLUTEX);
            pl.setByteSize((u32)3);
            }
        else if (pl.mode() == (u32)AM_ZEROPAGEY && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ZEROPAGEY) < (i32)0 && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ABSOLUTEY) >= (i32)0)
            {
            pl.setMode((u32)AM_ABSOLUTEY);
            pl.setByteSize((u32)3);
            }
        }

    // The xt additions are checked BEFORE the generic `),Y` and `,X` forms,
    // which would otherwise capture them.
    u32 detectAddressingMode(String* operand, bool isBranch)
        {
        if (isBranch)
            return (u32)AM_RELATIVE;
        String* op = stripSpacesAroundCommas(operand.trimmed());
        String* up = op.uppercased();

        if (op.hasPrefix(String.withCString("(")) && up.hasSuffix(String.withCString(",SP),Y")))
            return (u32)AM_SPINDIRECTINDEXEDY;
        if (up.hasSuffix(String.withCString(",SP,X")))
            return (u32)AM_SPINDEXEDX;
        if (up.hasSuffix(String.withCString(",SP")))
            return (u32)AM_SPRELATIVE;
        if (up.hasPrefix(String.withCString("SP,")))
            return (u32)AM_STACKADJUST;

        if (op.hasPrefix(String.withCString("#")))
            return (u32)AM_IMMEDIATE;
        if (op.hasPrefix(String.withCString("(")) && up.hasSuffix(String.withCString("),Y")))
            return (u32)AM_INDIRECTINDEXEDY;
        if (op.hasPrefix(String.withCString("(")) && up.hasSuffix(String.withCString(",X)")))
            return (u32)AM_INDEXEDINDIRECTX;
        if (op.hasPrefix(String.withCString("(")) && op.hasSuffix(String.withCString(")")))
            return (u32)AM_INDIRECT;
        if (up.hasSuffix(String.withCString(",X")))
            {
            i32 v = tryEvaluate(op.substringBytes((u32)0, op.byteLength() - (u32)2));
            return (v >= (i32)0 && v <= (i32)$FF) ? (u32)AM_ZEROPAGEX : (u32)AM_ABSOLUTEX;
            }
        if (up.hasSuffix(String.withCString(",Y")))
            {
            i32 v = tryEvaluate(op.substringBytes((u32)0, op.byteLength() - (u32)2));
            return (v >= (i32)0 && v <= (i32)$FF) ? (u32)AM_ZEROPAGEY : (u32)AM_ABSOLUTEY;
            }
        i32 v = tryEvaluate(op);
        return (v >= (i32)0 && v <= (i32)$FF) ? (u32)AM_ZEROPAGE : (u32)AM_ABSOLUTE;
        }

    static String* stripSpacesAroundCommas(String* s)
        {
        String* o = new String();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)' ')
                {
                // Drop a space that sits either side of a comma.
                bool nextComma = i + (u32)1 < s.byteLength() && s.byteAt(i + (u32)1) == (u8)',';
                bool prevComma = o.byteLength() > (u32)0 && o.byteAt(o.byteLength() - (u32)1) == (u8)',';
                if (nextComma || prevComma)
                    continue;
                }
            o.appendByte(c);
            }
        return o;
        }

    static Array* splitWhitespace(String* s)
        {
        Array* out = new Array();
        String* cur = new String();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)' ' || c == (u8)'\t')
                {
                if (cur.byteLength() > (u32)0)
                    {
                    out.add((Object*)cur);
                    cur = new String();
                    }
                continue;
                }
            cur.appendByte(c);
            }
        if (cur.byteLength() > (u32)0)
            out.add((Object*)cur);
        return out;
        }

    static String* joinWith(Array* a, String* sep)
        {
        String* o = new String();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                o.append(sep);
            o.append((String*)a.get(i));
            }
        return o;
        }

    // ── Operand extraction ───────────────────────────────────────────────
    //
    // The signed-offset modes prefix a `0`: the expression evaluator only
    // splits on an operator at index > 0, so `+5` has to become `0+5` for the
    // leading sign to parse as a binary operator rather than a stray token.
    String* extractExpression(String* operand, u32 mode)
        {
        if (operand == (String*)0)
            return String.withCString("0");
        String* op = operand.trimmed();
        if (mode == (u32)AM_IMMEDIATE)
            return op.substringFromByte((u32)1);
        if (mode == (u32)AM_INDEXEDINDIRECTX)
            return op.substringBytes((u32)1, op.byteLength() - (u32)4).trimmed();
        if (mode == (u32)AM_INDIRECTINDEXEDY)
            {
            u32 paren = op.byteIndexOf(String.withCString(")"));
            return op.substringBytes((u32)1, paren - (u32)1).trimmed();
            }
        if (mode == (u32)AM_INDIRECT)
            return op.substringBytes((u32)1, op.byteLength() - (u32)2).trimmed();
        if (mode == (u32)AM_ZEROPAGEX || mode == (u32)AM_ABSOLUTEX || mode == (u32)AM_ZEROPAGEY || mode == (u32)AM_ABSOLUTEY)
            return op.substringBytes((u32)0, op.byteLength() - (u32)2).trimmed();
        if (mode == (u32)AM_SPRELATIVE || mode == (u32)AM_SPINDEXEDX)
            {
            u32 sp = lastIndexOfSP(op);
            String* inner = sp == (u32)$FFFF_FFFF ? op : op.substringBytes((u32)0, sp);
            return zeroPrefixed(inner.trimmed());
            }
        if (mode == (u32)AM_STACKADJUST)
            {
            String* after = op.substringFromByte((u32)3).trimmed();
            if (after.hasPrefix(String.withCString("#")))
                after = after.substringFromByte((u32)1);
            return zeroPrefixed(after);
            }
        if (mode == (u32)AM_SPINDIRECTINDEXEDY)
            {
            u32 sp = lastIndexOfSP(op);
            String* inner = (sp == (u32)$FFFF_FFFF || op.byteLength() < (u32)1)
                                ? op
                                : op.substringBytes((u32)1, sp - (u32)1);
            return zeroPrefixed(inner.trimmed());
            }
        return op;
        }

    static String* zeroPrefixed(String* s)
        {
        String* o = String.withCString("0");
        o.append(s);
        return o;
        }

    // The rightmost `,SP`, case-insensitively.
    static u32 lastIndexOfSP(String* op)
        {
        u32 found = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i + (u32)2 < op.byteLength() + (u32)1; i = i + (u32)1)
            {
            if (i + (u32)2 >= op.byteLength() + (u32)1)
                break;
            if (op.byteAt(i) != (u8)',')
                continue;
            u8 a = op.byteAt(i + (u32)1);
            u8 b = op.byteAt(i + (u32)2);
            if ((a == (u8)'S' || a == (u8)'s') && (b == (u8)'P' || b == (u8)'p'))
                found = i;
            }
        return found;
        }

    // Scope a dot-prefixed local label reference to the enclosing global.
    String* scopeLocalLabelsInOperand(String* operand)
        {
        if (_lastGlobalLabel == (String*)0 || operand == (String*)0)
            return operand;
        if (operand.byteIndexOf(String.withCString(".")) == (u32)$FFFF_FFFF)
            return operand;
        String* out = new String();
        u32 i = (u32)0;
        while (i < operand.byteLength())
            {
            u8 c = operand.byteAt(i);
            // A dot starts a local reference only when what follows is an
            // identifier character and what precedes is not — `$12.5` and a
            // dotted symbol already scoped both stay alone.
            bool prevIdent = i > (u32)0 && isIdentChar(operand.byteAt(i - (u32)1));
            bool nextIdent = i + (u32)1 < operand.byteLength() && isIdentChar(operand.byteAt(i + (u32)1));
            if (c == (u8)'.' && !prevIdent && nextIdent)
                {
                out.append(_lastGlobalLabel);
                out.appendByte(c);
                i = i + (u32)1;
                continue;
                }
            out.appendByte(c);
            i = i + (u32)1;
            }
        return out;
        }

    static bool isIdentChar(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_';
        }

    // ── Pass 1 ───────────────────────────────────────────────────────────
    //
    // Sub-phase 1a parses and scope-resolves every line without touching the
    // PC, so 1b can walk a flat list and assign addresses.
    void pass1(Array* sourceLines)
        {
        _lines = new Array();
        _pc = (u32)0;
        _lastGlobalLabel = (String*)0;
        _codeRegions = (Array*)0;
        _currentRegionIndex = (u32)0;
        _pcInsideMainRegion = false;
        _finalRegionOverflowReported = false;
        _bankIds = new Map();
        _labelBank = new Map();
        _bankWindowSegSeen = (u32)0;
        _curDirectiveBank = (u32)0;

        for (u32 i = (u32)0; i < sourceLines.count(); i = i + (u32)1)
            {
            String* rawLine = (String*)sourceLines.get(i);
            String* line = stripComment(rawLine);
            Array* compounds = splitCompoundLine(line);
            bool lineIsLongbrInverse =
                rawLine.byteIndexOf(String.withCString("; longbr")) != (u32)$FFFF_FFFF;
            for (u32 k = (u32)0; k < compounds.count(); k = k + (u32)1)
                {
                XaLine* pl = parseLine((String*)compounds.get(k), i + (u32)1);
                if (lineIsLongbrInverse)
                    pl.setLongbrInverse(true);
                // A dotted local becomes `<lastGlobal>.<name>`. The long-branch
                // rewriter's own `_xlb_N` skip labels must NOT become the new
                // enclosing global, or every dotted label after one gets scoped
                // to the skip label instead of the routine.
                if (pl.label() != (String*)0)
                    {
                    if (pl.label().hasPrefix(String.withCString(".")) && _lastGlobalLabel != (String*)0)
                        {
                        String* scoped = new String();
                        scoped.append(_lastGlobalLabel);
                        scoped.append(pl.label());
                        pl.setLabel(scoped);
                        }
                    else if (!pl.labelIsLocal() && !pl.label().hasPrefix(String.withCString("_xlb_")))
                        {
                        _lastGlobalLabel = pl.label();
                        }
                    }
                if (pl.operand() != (String*)0)
                    pl.setOperand(scopeLocalLabelsInOperand(pl.operand()));
                _lines.add((Object*)pl);
                }
            }
        assignAddresses();
        }

    void assignAddresses(void)
        {
        for (u32 idx = (u32)0; idx < _lines.count(); idx = idx + (u32)1)
            {
            XaLine* pl = (XaLine*)_lines.get(idx);
            idx = maybeAutoSpill(idx);
            pl = (XaLine*)_lines.get(idx);
            if (pl.label() != (String*)0)
                {
                _symbols.set((Hashable*)pl.label(), (Object*)Number.withU32(_pc));
                // Tag a label defined inside a `.bank` region with that bank,
                // so an external JSR/JMP to it can be routed through the
                // trampoline rather than jumping into an unmapped page.
                if (_curDirectiveBank != (u32)0)
                    _labelBank.set((Hashable*)pl.label(),
                                   (Object*)Number.withU32(_curDirectiveBank));
                }
            u32 t = pl.type();
            if (t == (u32)LT_ORG)
                {
                _pc = (u32)evaluate(pl.operand()) & (u32)$FFFF;
                syncCurrentRegionToPC();
                // A plain `.org` into the bank window is a codegen user bank.
                // Count it, so a later `.bank` identifier is allocated a number
                // that cannot clash — but do not tag its labels, because the
                // code generator stages those cross-bank calls itself.
                if (_bankWindowEnd != (u32)0 && _pc >= _bankWindowStart && _pc <= _bankWindowEnd)
                    _bankWindowSegSeen = _bankWindowSegSeen + (u32)1;
                _curDirectiveBank = (u32)0;
                continue;
                }
            if (t == (u32)LT_BANK)
                {
                String* id = pl.operand() == (String*)0 ? String.withCString("") : pl.operand();
                Object* assigned = _bankIds.get((Hashable*)id);
                if (assigned == (Object*)0)
                    {
                    _bankWindowSegSeen = _bankWindowSegSeen + (u32)1;
                    assigned = (Object*)Number.withU32(_bankWindowSegSeen);
                    _bankIds.set((Hashable*)id, assigned);
                    }
                // Publish `__bank_<id>` so the harness's unbanked thunks can
                // stage the bank number without knowing the allocation.
                String* symName = String.withCString("__bank_");
                symName.append(id);
                _symbols.set((Hashable*)symName, assigned);
                _curDirectiveBank = ((Number*)assigned).asU32();
                _pc = _bankWindowStart;
                syncCurrentRegionToPC();
                continue;
                }
            if (t == (u32)LT_CODE_REGIONS)
                {
                _codeRegions = parseRegionList(pl.operand());
                syncCurrentRegionToPC();
                continue;
                }
            if (t == (u32)LT_ASSIGNMENT)
                {
                _symbols.set((Hashable*)pl.assignName(),
                             (Object*)Number.withU32((u32)evaluate(pl.assignValue())));
                // An alias for a banked label inherits its bank, so a call
                // through the alias still routes through the trampoline.
                String* rhs = pl.assignValue().trimmed();
                Object* rhsBank = _labelBank.get((Hashable*)rhs);
                if (rhsBank != (Object*)0)
                    _labelBank.set((Hashable*)pl.assignName(), rhsBank);
                continue;
                }
            if (t == (u32)LT_SPACE)
                pl.setByteSize((u32)evaluate(pl.operand()));
            pl.setAddress(_pc);
            _pc = (_pc + pl.byteSize()) & (u32)$FFFF;
            }
        }

    // Code lives in declared REGIONS with hardware in the gaps. An instruction
    // that would cross a boundary is bridged into the next region — with a JMP
    // when something falls through into it, or just a `.org` when the previous
    // instruction was an unconditional transfer and nothing does.
    //
    // The runway is ten bytes rather than three: it leaves room for both a JMP
    // bridge AND a short-branch-plus-JMP pattern, so the long-branch rewriter's
    // inverse branch, its JMP and its skip label stay on the same side of the
    // gap.
    u32 maybeAutoSpill(u32 idx)
        {
        if (_codeRegions == (Array*)0 || !_pcInsideMainRegion)
            return idx;
        XaLine* pl = (XaLine*)_lines.get(idx);
        if (!emitsBytes(pl) || pl.byteSize() == (u32)0)
            return idx;
        u32 nRegions = _codeRegions.count() / (u32)2;
        if (_currentRegionIndex + (u32)1 >= nRegions)
            return idx;
        u32 regionEnd = ((Number*)_codeRegions.get(_currentRegionIndex * (u32)2 + (u32)1)).asU32();
        u32 tail = _pc + pl.byteSize();
        u32 limit = regionEnd + (u32)1;
        if (limit < (u32)10 || tail <= limit - (u32)10)
            return idx;

        bool lineIsSpace = pl.type() == (u32)LT_SPACE;
        bool prevIsTransfer = false;
        bool prevIsLongbrInverse = false;
        if (idx > (u32)0)
            {
            XaLine* prev = (XaLine*)_lines.get(idx - (u32)1);
            if (prev.type() == (u32)LT_INSTRUCTION && (prev.mnemonic().equals(String.withCString("JMP")) || prev.mnemonic().equals(String.withCString("RTS")) || prev.mnemonic().equals(String.withCString("RTI"))))
                prevIsTransfer = true;
            if (prev.isLongbrInverse())
                prevIsLongbrInverse = true;
            }
        u32 nextStart = ((Number*)_codeRegions.get((_currentRegionIndex + (u32)1) * (u32)2)).asU32();
        String* target = String.withCString("$");
        target.append(hex4(nextStart));

        if (prevIsTransfer || lineIsSpace)
            {
            // Nothing falls through — a `.space` is never executed and a
            // transfer already left — so the bridge is just a `.org`.
            // Return idx pointing AT the inserted line, so the caller
            // processes it — the whole point is that the `.org` moves the PC.
            _lines.insert(idx, (Object*)makeOrg(target, pl.sourceLine()));
            return idx;
            }
        if (!prevIsLongbrInverse)
            {
            XaLine* jmp = new XaLine();
            jmp.setType((u32)LT_INSTRUCTION);
            jmp.setMnemonic(String.withCString("JMP"));
            jmp.setOperand(target);
            jmp.setMode((u32)AM_ABSOLUTE);
            jmp.setByteSize((u32)3);
            jmp.setSourceLine(pl.sourceLine());
            _lines.insert(idx, (Object*)jmp);
            _lines.insert(idx + (u32)1, (Object*)makeOrg(target, pl.sourceLine()));
            return idx;
            }
        return idx;
        }

    static XaLine* makeOrg(String* target, u32 srcLine)
        {
        XaLine* org = new XaLine();
        org.setType((u32)LT_ORG);
        org.setOperand(target);
        org.setSourceLine(srcLine);
        return org;
        }

    static bool emitsBytes(XaLine* pl)
        {
        u32 t = pl.type();
        return t == (u32)LT_INSTRUCTION || t == (u32)LT_BYTE || t == (u32)LT_WORD || t == (u32)LT_LONG || t == (u32)LT_STRING || t == (u32)LT_SPACE;
        }

    static String* hex4(u32 v)
        {
        String* o = new String();
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            {
            u32 nib = (v >> ((u32)4 * ((u32)3 - i))) & (u32)$F;
            o.appendByte(nib < (u32)10 ? (u8)((u32)'0' + nib) : (u8)((u32)'A' + nib - (u32)10));
            }
        return o;
        }

    void syncCurrentRegionToPC(void)
        {
        if (_codeRegions == (Array*)0)
            {
            _pcInsideMainRegion = false;
            return;
            }
        _pcInsideMainRegion = false;
        for (u32 i = (u32)0; i + (u32)1 < _codeRegions.count(); i = i + (u32)2)
            {
            u32 lo = ((Number*)_codeRegions.get(i)).asU32();
            u32 hi = ((Number*)_codeRegions.get(i + (u32)1)).asU32();
            if (_pc >= lo && _pc <= hi)
                {
                _currentRegionIndex = i / (u32)2;
                _pcInsideMainRegion = true;
                return;
                }
            }
        }

    // `$2400-$3FFF, $D800-$FFF9` — a flat list of lo/hi pairs.
    Array* parseRegionList(String* operand)
        {
        Array* out = new Array();
        Array* parts = operand.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            {
            String* p = ((String*)parts.get(i)).trimmed();
            u32 dash = findRangeDash(p);
            if (dash == (u32)$FFFF_FFFF)
                continue;
            out.add((Object*)Number.withU32((u32)evaluate(p.substringBytes((u32)0, dash))));
            out.add((Object*)Number.withU32((u32)evaluate(p.substringFromByte(dash + (u32)1))));
            }
        return out.count() > (u32)0 ? out : (Array*)0;
        }

    // The separator dash, not a minus inside an expression: it is the one that
    // follows a value and precedes a `$` or a digit.
    static u32 findRangeDash(String* p)
        {
        for (u32 i = (u32)1; i + (u32)1 < p.byteLength(); i = i + (u32)1)
            if (p.byteAt(i) == (u8)'-')
                return i;
        return (u32)$FFFF_FFFF;
        }

    // ── Pass 2 ───────────────────────────────────────────────────────────
    //
    // Resolve every expression and emit bytes into origin-tagged segments.
    // A small forward `.org` pads with zeros and keeps the current segment
    // going — the banked target packs several functions onto one page and each
    // would otherwise become its own load segment, so calls would land on the
    // wrong page. A large jump starts a NEW segment, because padding across a
    // zone change would collapse two regions into one load.
    void pass2(void)
        {
        _segments = new Array();
        XaSegment* cur = (XaSegment*)0;
        _pc = (u32)0;
        for (u32 i = (u32)0; i < _lines.count(); i = i + (u32)1)
            {
            XaLine* pl = (XaLine*)_lines.get(i);
            u32 t = pl.type();
            if (t == (u32)LT_ORG)
                {
                u32 newPc = (u32)evaluate(pl.operand()) & (u32)$FFFF;
                bool forward = cur != (XaSegment*)0 && newPc >= _pc;
                bool sameSlot = cur != (XaSegment*)0 && newPc == _pc && cur.data().count() == (u32)0;
                // A spill-rewritten `.org` moves from one declared region into
                // the next. The addresses can be a handful of bytes apart, so
                // the padding rule below would otherwise zero-fill across the
                // gap and keep both regions in ONE load block — which the
                // hardware will not honour past the first region's end.
                bool crossesRegion = forward && regionIndexOf(newPc) > regionIndexOf(_pc) && regionIndexOf(_pc) >= (i32)0;
                if (forward && !sameSlot && !crossesRegion && newPc - _pc < (u32)$100)
                    {
                    while (_pc < newPc)
                        {
                        cur.data().add((Object*)Number.withU32((u32)0));
                        _pc = _pc + (u32)1;
                        }
                    continue;
                    }
                cur = XaSegment.at(newPc);
                _segments.add((Object*)cur);
                _pc = newPc;
                continue;
                }
            if (t == (u32)LT_BANK)
                {
                // Open a named banked region: a fresh segment at the bank
                // window, carrying the identifier's pre-allocated physical bank
                // number so the writer's preload stub matches what the
                // cross-bank staging expects.
                _pc = _bankWindowStart;
                cur = XaSegment.at(_pc);
                String* id = pl.operand() == (String*)0 ? String.withCString("") : pl.operand();
                Object* bn = _bankIds.get((Hashable*)id);
                cur.setBankNumber(bn == (Object*)0 ? (i32)-1 : (i32)((Number*)bn).asU32());
                _segments.add((Object*)cur);
                continue;
                }
            if (t == (u32)LT_CODE_REGIONS || t == (u32)LT_LABEL || t == (u32)LT_EMPTY || t == (u32)LT_ASSIGNMENT || t == (u32)LT_SPILL_POINT)
                continue;
            if (cur == (XaSegment*)0)
                {
                cur = XaSegment.at(_pc);
                _segments.add((Object*)cur);
                }
            if (t == (u32)LT_INSTRUCTION)
                {
                emitInstruction(pl, cur);
                _pc = _pc + pl.byteSize();
                continue;
                }
            if (t == (u32)LT_BYTE)
                {
                Array* vs = pl.dataValues();
                for (u32 k = (u32)0; k < vs.count(); k = k + (u32)1)
                    cur.data().add((Object*)Number.withU32((u32)evaluate((String*)vs.get(k)) & (u32)$FF));
                _pc = _pc + vs.count();
                continue;
                }
            if (t == (u32)LT_WORD)
                {
                Array* vs = pl.dataValues();
                for (u32 k = (u32)0; k < vs.count(); k = k + (u32)1)
                    {
                    u32 v = (u32)evaluate((String*)vs.get(k));
                    cur.data().add((Object*)Number.withU32(v & (u32)$FF));
                    cur.data().add((Object*)Number.withU32((v >> (u32)8) & (u32)$FF));
                    }
                _pc = _pc + vs.count() * (u32)2;
                continue;
                }
            if (t == (u32)LT_LONG)
                {
                Array* vs = pl.dataValues();
                for (u32 k = (u32)0; k < vs.count(); k = k + (u32)1)
                    {
                    u32 v = (u32)evaluate((String*)vs.get(k));
                    for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
                        cur.data().add((Object*)Number.withU32((v >> ((u32)8 * b)) & (u32)$FF));
                    }
                _pc = _pc + vs.count() * (u32)4;
                continue;
                }
            if (t == (u32)LT_STRING)
                {
                String* v = pl.operand();
                for (u32 k = (u32)0; k < v.byteLength(); k = k + (u32)1)
                    cur.data().add((Object*)Number.withU32((u32)v.byteAt(k)));
                cur.data().add((Object*)Number.withU32((u32)0));
                _pc = _pc + v.byteLength() + (u32)1;
                continue;
                }
            if (t == (u32)LT_SPACE)
                {
                for (u32 k = (u32)0; k < pl.byteSize(); k = k + (u32)1)
                    cur.data().add((Object*)Number.withU32((u32)0));
                _pc = _pc + pl.byteSize();
                continue;
                }
            }
        }

    i32 regionIndexOf(u32 addr)
        {
        if (_codeRegions == (Array*)0)
            return (i32)-1;
        for (u32 i = (u32)0; i + (u32)1 < _codeRegions.count(); i = i + (u32)2)
            {
            u32 lo = ((Number*)_codeRegions.get(i)).asU32();
            u32 hi = ((Number*)_codeRegions.get(i + (u32)1)).asU32();
            if (addr >= lo && addr <= hi)
                return (i32)(i / (u32)2);
            }
        return (i32)-1;
        }

    void emitInstruction(XaLine* pl, XaSegment* seg)
        {
        i32 opcode = _cpu.opcodeFor(pl.mnemonic(), pl.mode());
        // The same zero-page-to-absolute promotion the parser does, kept here
        // as a backstop for a mode the parser could not resolve.
        if (opcode < (i32)0 && pl.mode() == (u32)AM_ZEROPAGE)
            {
            pl.setMode((u32)AM_ABSOLUTE);
            pl.setByteSize((u32)3);
            opcode = _cpu.opcodeFor(pl.mnemonic(), pl.mode());
            }
        if (opcode < (i32)0 && pl.mode() == (u32)AM_ZEROPAGEX)
            {
            pl.setMode((u32)AM_ABSOLUTEX);
            pl.setByteSize((u32)3);
            opcode = _cpu.opcodeFor(pl.mnemonic(), pl.mode());
            }
        if (opcode < (i32)0 && pl.mode() == (u32)AM_ZEROPAGEY)
            {
            pl.setMode((u32)AM_ABSOLUTEY);
            pl.setByteSize((u32)3);
            opcode = _cpu.opcodeFor(pl.mnemonic(), pl.mode());
            }
        if (opcode < (i32)0)
            {
            String* m = String.withCString("invalid addressing mode for ");
            m.append(pl.mnemonic());
            err(m);
            return;
            }
        seg.data().add((Object*)Number.withU32((u32)opcode));
        if (pl.byteSize() == (u32)1)
            return;

        String* exprStr = extractExpression(pl.operand(), pl.mode());
        i32 value = evaluate(exprStr);

        if (pl.mode() == (u32)AM_RELATIVE)
            {
            // The 6502's PC addition wraps at 16 bits, so the offset is masked
            // and sign-extended — a branch at $FFFE to $0003 is +3, not
            // -65533, and must not be flagged out of range.
            i32 offset = value - (i32)(_pc + (u32)2);
            i32 wrapped = offset & (i32)$FFFF;
            if (wrapped >= (i32)$8000)
                wrapped = wrapped - (i32)$10000;
            if (wrapped < (i32)-128 || wrapped > (i32)127)
                {
                String* m = String.withCString("branch out of range: ");
                m.append(pl.mnemonic());
                m.appendCString(" ");
                if (pl.operand() != (String*)0)
                    m.append(pl.operand());
                err(m);
                }
            seg.data().add((Object*)Number.withU32((u32)offset & (u32)$FF));
            return;
            }
        if (pl.mode() == (u32)AM_SPRELATIVE || pl.mode() == (u32)AM_STACKADJUST || pl.mode() == (u32)AM_SPINDIRECTINDEXEDY || pl.mode() == (u32)AM_SPINDEXEDX)
            {
            // A signed 8-bit immediate. Out of range is a hard error: silent
            // truncation would mis-target every stack access after it.
            if (value < (i32)-128 || value > (i32)127)
                {
                String* m = String.withCString("signed-8-bit stack offset out of range in ");
                m.append(pl.mnemonic());
                err(m);
                }
            seg.data().add((Object*)Number.withU32((u32)value & (u32)$FF));
            return;
            }
        if (pl.byteSize() == (u32)2)
            {
            if (pl.mode() == (u32)AM_IMMEDIATE && (pl.mnemonic().equals(String.withCString("PSH")) || pl.mnemonic().equals(String.withCString("PLL"))) && (value < (i32)0 || value > (i32)255))
                {
                // PSH/PLL take an UNSIGNED byte; truncating would mis-size the
                // prologue's frame allocation.
                String* m = String.withCString("PSH/PLL immediate out of range (0..255)");
                err(m);
                }
            seg.data().add((Object*)Number.withU32((u32)value & (u32)$FF));
            return;
            }
        if (pl.byteSize() == (u32)3)
            {
            seg.data().add((Object*)Number.withU32((u32)value & (u32)$FF));
            seg.data().add((Object*)Number.withU32(((u32)value >> (u32)8) & (u32)$FF));
            }
        }

    // ── The long-branch rewriter ─────────────────────────────────────────
    //
    // A conditional branch that cannot reach its target becomes its INVERSE
    // over a JMP: `BEQ far` turns into `BNE skip / JMP far / skip:`. That is
    // three bytes longer, which moves every label after it — so the caller
    // re-runs pass 1 and this runs again, until nothing changes.
    //
    // BRA is unconditional, so an out-of-range one becomes a plain JMP with no
    // inverse-branch dance at all.
    u32 _longBranchCounter;

    u32 rewriteLongBranches(Array* sourceLines)
        {
        Array* pcMap = new Array();
        u32 pc = (u32)0;
        for (u32 i = (u32)0; i < _lines.count(); i = i + (u32)1)
            {
            XaLine* pl = (XaLine*)_lines.get(i);
            pcMap.add((Object*)Number.withU32(pc));
            if (pl.type() == (u32)LT_ORG)
                pc = (u32)evaluate(pl.operand()) & (u32)$FFFF;
            // A `.bank` region loads at the bank window, so the PC has to jump
            // there — otherwise every branch inside the banked runtime is
            // measured against the main region's cursor, comes out tens of
            // kilobytes away, and gets rewritten as an inverse-plus-JMP that
            // was never needed.
            else if (pl.type() == (u32)LT_BANK)
                pc = _bankWindowStart;
            else
                pc = (pc + pl.byteSize()) & (u32)$FFFF;
            }

        // One replacement per SOURCE line, applied back to front so the
        // earlier indices stay valid.
        Array* repIdx = new Array();
        Array* repText = new Array(); // Array@ of String@ per entry
        for (u32 i = (u32)0; i < _lines.count(); i = i + (u32)1)
            {
            XaLine* pl = (XaLine*)_lines.get(i);
            if (pl.type() != (u32)LT_INSTRUCTION)
                continue;
            if (!Xa6502.isBranchMnemonic(pl.mnemonic()))
                continue;
            String* targetExpr = pl.operand();
            if (targetExpr == (String*)0)
                continue;
            i32 target = evaluate(targetExpr);
            u32 branchPC = ((Number*)pcMap.get(i)).asU32();
            i32 offset = target - (i32)(branchPC + (u32)2);
            i32 wrapped = offset & (i32)$FFFF;
            if (wrapped >= (i32)$8000)
                wrapped = wrapped - (i32)$10000;
            if (wrapped >= (i32)-128 && wrapped <= (i32)127)
                continue;

            u32 srcLine = pl.sourceLine() - (u32)1;
            if (srcLine >= sourceLines.count())
                continue;
            if (containsIndex(repIdx, srcLine))
                continue;

            Array* lines = new Array();
            if (pl.mnemonic().equals(String.withCString("BRA")))
                {
                String* j = String.withCString("    JMP ");
                j.append(targetExpr);
                lines.add((Object*)j);
                }
            else
                {
                String* inverse = inverseBranch(pl.mnemonic());
                if (inverse == (String*)0)
                    continue;
                String* skip = String.withCString("_xlb_");
                skip.appendFormat("%lu", _longBranchCounter);
                _longBranchCounter = _longBranchCounter + (u32)1;
                String* a = String.withCString("    ");
                a.append(inverse);
                a.appendCString(" ");
                a.append(skip);
                a.appendCString(" ; longbr");
                String* b = String.withCString("    JMP ");
                b.append(targetExpr);
                String* c = new String();
                c.append(skip);
                c.appendCString(":");
                lines.add((Object*)a);
                lines.add((Object*)b);
                lines.add((Object*)c);
                }
            repIdx.add((Object*)Number.withU32(srcLine));
            repText.add((Object*)lines);
            }
        if (repIdx.count() == (u32)0)
            return (u32)0;

        // Back to front, so an insertion never shifts an index still to come.
        sortByIndexDescending(repIdx, repText);
        for (u32 r = (u32)0; r < repIdx.count(); r = r + (u32)1)
            {
            u32 at = ((Number*)repIdx.get(r)).asU32();
            Array* lines = (Array*)repText.get(r);
            sourceLines.set(at, lines.get((u32)0));
            for (u32 j = (u32)1; j < lines.count(); j = j + (u32)1)
                sourceLines.insert(at + j, lines.get(j));
            }
        return repIdx.count();
        }

    static bool containsIndex(Array* a, u32 v)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((Number*)a.get(i)).asU32() == v)
                return true;
        return false;
        }

    static void sortByIndexDescending(Array* idx, Array* txt)
        {
        for (u32 i = (u32)1; i < idx.count(); i = i + (u32)1)
            {
            Object* vi = idx.get(i);
            Object* vt = txt.get(i);
            u32 j = i;
            while (j > (u32)0 && ((Number*)idx.get(j - (u32)1)).asU32() < ((Number*)vi).asU32())
                {
                idx.set(j, idx.get(j - (u32)1));
                txt.set(j, txt.get(j - (u32)1));
                j = j - (u32)1;
                }
            idx.set(j, vi);
            txt.set(j, vt);
            }
        }

    static String* inverseBranch(String* m)
        {
        if (m.equals(String.withCString("BCC")))
            return String.withCString("BCS");
        if (m.equals(String.withCString("BCS")))
            return String.withCString("BCC");
        if (m.equals(String.withCString("BEQ")))
            return String.withCString("BNE");
        if (m.equals(String.withCString("BNE")))
            return String.withCString("BEQ");
        if (m.equals(String.withCString("BMI")))
            return String.withCString("BPL");
        if (m.equals(String.withCString("BPL")))
            return String.withCString("BMI");
        if (m.equals(String.withCString("BVC")))
            return String.withCString("BVS");
        if (m.equals(String.withCString("BVS")))
            return String.withCString("BVC");
        return (String*)0;
        }

    // ── Cross-bank call rewriting ────────────────────────────────────────
    //
    // A `JSR`/`JMP` to a bare label defined inside a `.bank` region, made from
    // a DIFFERENT bank, is retargeted onto that entry's unbanked thunk:
    // `JSR fpAdd` becomes `JSR _fpAdd`. The thunk does the trampoline staging —
    // select the bank, call, restore — so the call site stays a single 3-byte
    // instruction. That size preservation is the whole point: inlining the
    // staging at every call site would push the banked user functions past
    // their 16 KB budget.
    //
    // Only the matching statement on a line is rewritten. One source line can
    // hold several colon-separated statements — inline asm emits things like
    // `LDA #<s : STA $B5 : ... : JSR asc2fp` — and replacing the whole line
    // would drop the pointer staging in front of the call, leaving the callee
    // to run on a garbage operand.
    u32 rewriteCrossBankCalls(Array* sourceLines)
        {
        if (_bankIds == (Map*)0 || _bankIds.allKeys().count() == (u32)0)
            return (u32)0;
        if (_labelBank.allKeys().count() == (u32)0)
            return (u32)0;

        Array* lineIdx = new Array();   // Number@
        Array* lineCalls = new Array(); // Array@ of String@ pairs: mnemonic, operand
        u32 curBank = (u32)0;
        for (u32 i = (u32)0; i < _lines.count(); i = i + (u32)1)
            {
            XaLine* pl = (XaLine*)_lines.get(i);
            // Only a `.bank` region sets a non-zero bank; a plain `.org` — a
            // user bank or main — resets to zero, which still differs from any
            // runtime bank, so its calls do get rewritten.
            if (pl.type() == (u32)LT_BANK)
                {
                String* id = pl.operand() == (String*)0 ? String.withCString("") : pl.operand();
                Object* b = _bankIds.get((Hashable*)id);
                curBank = b == (Object*)0 ? (u32)0 : ((Number*)b).asU32();
                continue;
                }
            if (pl.type() == (u32)LT_ORG)
                {
                curBank = (u32)0;
                continue;
                }
            if (pl.type() != (u32)LT_INSTRUCTION)
                continue;
            if (!pl.mnemonic().equals(String.withCString("JSR")) && !pl.mnemonic().equals(String.withCString("JMP")))
                continue;
            if (pl.operand() == (String*)0)
                continue;
            String* op = pl.operand().trimmed();
            Object* targetBank = _labelBank.get((Hashable*)op);
            if (targetBank == (Object*)0)
                continue; // not a banked label
            if (((Number*)targetBank).asU32() == curBank)
                continue; // intra-bank
            u32 srcLine = pl.sourceLine() - (u32)1;
            if (srcLine >= sourceLines.count())
                continue;
            i32 at = indexOfNumber(lineIdx, srcLine);
            if (at < (i32)0)
                {
                lineIdx.add((Object*)Number.withU32(srcLine));
                lineCalls.add((Object*)new Array());
                at = (i32)(lineIdx.count() - (u32)1);
                }
            Array* calls = (Array*)lineCalls.get((u32)at);
            calls.add((Object*)pl.mnemonic());
            calls.add((Object*)op);
            }
        if (lineIdx.count() == (u32)0)
            return (u32)0;

        u32 rewritten = (u32)0;
        for (u32 r = (u32)0; r < lineIdx.count(); r = r + (u32)1)
            {
            u32 at = ((Number*)lineIdx.get(r)).asU32();
            Array* calls = (Array*)lineCalls.get(r);
            String* line = (String*)sourceLines.get(at);
            Array* stmts = line.splitOnByte((u8)':');
            String* out = new String();
            for (u32 si = (u32)0; si < stmts.count(); si = si + (u32)1)
                {
                if (si > (u32)0)
                    out.appendCString(":");
                String* stmt = (String*)stmts.get(si);
                String* t = stmt.trimmed();
                String* replacement = (String*)0;
                for (u32 c = (u32)0; c + (u32)1 < calls.count(); c = c + (u32)2)
                    {
                    String* mn = (String*)calls.get(c);
                    String* op = (String*)calls.get(c + (u32)1);
                    String* prefix = new String();
                    prefix.append(mn);
                    prefix.appendCString(" ");
                    if (!t.hasPrefix(prefix))
                        continue;
                    // The operand is the first token after the mnemonic; stop
                    // at whitespace or a `;`, so a trailing comment cannot
                    // defeat the match. An unmatched cross-bank call would
                    // stay a direct jump into an unmapped bank.
                    String* rest = t.substringFromByte(prefix.byteLength()).trimmed();
                    String* tok = firstToken(rest);
                    if (!tok.equals(op))
                        continue;
                    replacement = String.withCString(" ");
                    replacement.append(mn);
                    replacement.appendCString(" _");
                    replacement.append(op);
                    break;
                    }
                if (replacement != (String*)0)
                    {
                    out.append(replacement);
                    rewritten = rewritten + (u32)1;
                    }
                else
                    out.append(stmt);
                }
            sourceLines.set(at, (Object*)out);
            }
        return rewritten;
        }

    static i32 indexOfNumber(Array* a, u32 v)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((Number*)a.get(i)).asU32() == v)
                return (i32)i;
        return (i32)-1;
        }

    static String* firstToken(String* s)
        {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)' ' || c == (u8)'\t' || c == (u8)';')
                return s.substringBytes((u32)0, i);
            }
        return s;
        }

    // ── The whole assembly ───────────────────────────────────────────────
    //
    // Pass 1, then the size-changing rewrite, then pass 1 again — until the
    // line list stops moving. Only then does pass 2 emit bytes.
    void assemble(Array* sourceLines)
        {
        for (u32 iter = (u32)0; iter < (u32)8; iter = iter + (u32)1)
            {
            _symbols = new Map();
            // The bank-select registers are named symbols so both the generated
            // code and the hand-written runtime can say `__bank_code_reg`
            // rather than a hard-coded address. They come ONLY from the layout;
            // there is deliberately no default, so a banked program that
            // references one the layout never declared fails with an undefined
            // symbol rather than silently aliasing the historical ZP pair.
            if (_codeBankReg != (u32)0)
                _symbols.set((Hashable*)String.withCString("__bank_code_reg"),
                             (Object*)Number.withU32(_codeBankReg));
            if (_dataBankReg != (u32)0)
                _symbols.set((Hashable*)String.withCString("__bank_data_reg"),
                             (Object*)Number.withU32(_dataBankReg));
            _errors = new Array();
            _warnings = new Array();
            pass1(sourceLines);
            if (_errors.count() > (u32)0)
                return;
            // Cross-bank staging runs to completion first and is idempotent —
            // it leaves no `JSR <banked-label>` behind — so it settles in one
            // pass before the long branches are measured. Only ONE rewriter
            // may edit the line list per iteration: both index off the same
            // pass-1 snapshot, so running two would invalidate the second's
            // indices.
            if (rewriteCrossBankCalls(sourceLines) > (u32)0)
                continue;
            if (rewriteLongBranches(sourceLines) == (u32)0)
                break;
            }
        if (_errors.count() > (u32)0)
            return;
        pass2();
        }

    // ── XEX output ───────────────────────────────────────────────────────
    //
    // An Atari executable is `$FFFF` then a run of (start, end, bytes) blocks,
    // and finally a RUNAD block writing the entry address to $02E0 — which the
    // loader treats as "jump here when everything is in".
    Array* writeXex(u32 entry)
        {
        Array* xex = new Array();
        xex.add((Object*)Number.withU32((u32)$FF));
        xex.add((Object*)Number.withU32((u32)$FF));
        for (u32 i = (u32)0; i < _segments.count(); i = i + (u32)1)
            {
            XaSegment* seg = (XaSegment*)_segments.get(i);
            if (seg.data().count() == (u32)0)
                continue;
            u32 start = seg.origin();
            u32 end = (start + seg.data().count() - (u32)1) & (u32)$FFFF;
            xex.add((Object*)Number.withU32(start & (u32)$FF));
            xex.add((Object*)Number.withU32((start >> (u32)8) & (u32)$FF));
            xex.add((Object*)Number.withU32(end & (u32)$FF));
            xex.add((Object*)Number.withU32((end >> (u32)8) & (u32)$FF));
            for (u32 k = (u32)0; k < seg.data().count(); k = k + (u32)1)
                xex.add(seg.data().get(k));
            }
        xex.add((Object*)Number.withU32((u32)$E0));
        xex.add((Object*)Number.withU32((u32)$02));
        xex.add((Object*)Number.withU32((u32)$E1));
        xex.add((Object*)Number.withU32((u32)$02));
        xex.add((Object*)Number.withU32(entry & (u32)$FF));
        xex.add((Object*)Number.withU32((entry >> (u32)8) & (u32)$FF));
        return xex;
        }

    // ── Preprocessing ────────────────────────────────────────────────────
    //
    // Two sub-passes: collect macro definitions and splice in `.include`d
    // files, then expand macro invocations. A macro body runs to the next
    // `.macro` or the next line that starts in column zero.
    Array* _macroNames;   // String@
    Array* _macroParams;  // Array@ of String@
    Array* _macroBodies;  // Array@ of String@
    Array* _includePaths; // String@

    void setIncludePaths(Array* paths)
        {
        _includePaths = paths;
        }

    Array* preprocess(String* source, String* filename)
        {
        if (_macroNames == (Array*)0)
            {
            _macroNames = new Array();
            _macroParams = new Array();
            _macroBodies = new Array();
            }
        Array* rawLines = source.splitOnByte((u8)'\n');
        Array* result = new Array();
        bool inMacro = false;
        i32 curMacro = (i32)-1;

        for (u32 i = (u32)0; i < rawLines.count(); i = i + (u32)1)
            {
            String* rawLine = (String*)rawLines.get(i);
            String* trimmed = stripComment(rawLine).trimmed();
            if (inMacro)
                {
                bool startsAnother = trimmed.lowercased().hasPrefix(String.withCString(".macro "));
                bool column0 = trimmed.byteLength() > (u32)0 && !rawLine.hasPrefix(String.withCString(" ")) && !rawLine.hasPrefix(String.withCString("\t"));
                if (startsAnother || column0)
                    inMacro = false;
                else
                    {
                    ((Array*)_macroBodies.get((u32)curMacro)).add((Object*)rawLine);
                    continue;
                    }
                }
            if (trimmed.lowercased().hasPrefix(String.withCString(".macro ")))
                {
                String* rest = trimmed.substringFromByte((u32)7).trimmed();
                Array* parts = splitWhitespace(rest);
                if (parts.count() > (u32)0)
                    {
                    _macroNames.add(parts.get((u32)0));
                    Array* params = new Array();
                    if (parts.count() > (u32)1)
                        {
                        String* paramStr =
                            rest.substringFromByte(((String*)parts.get((u32)0)).byteLength()).trimmed();
                        Array* ps = paramStr.splitOnByte((u8)',');
                        for (u32 k = (u32)0; k < ps.count(); k = k + (u32)1)
                            {
                            String* t = ((String*)ps.get(k)).trimmed();
                            if (t.byteLength() > (u32)0)
                                params.add((Object*)t);
                            }
                        }
                    _macroParams.add((Object*)params);
                    _macroBodies.add((Object*)new Array());
                    curMacro = (i32)(_macroNames.count() - (u32)1);
                    inMacro = true;
                    }
                continue;
                }
            if (trimmed.lowercased().hasPrefix(String.withCString(".include ")))
                {
                String* inc = trimmed.substringFromByte((u32)9).trimmed();
                if ((inc.hasPrefix(String.withCString("\"")) && inc.hasSuffix(String.withCString("\""))) || (inc.hasPrefix(String.withCString("<")) && inc.hasSuffix(String.withCString(">"))))
                    inc = inc.substringBytes((u32)1, inc.byteLength() - (u32)2);
                String* content = readInclude(inc, filename);
                if (content != (String*)0)
                    {
                    Array* incLines = preprocess(content, inc);
                    for (u32 k = (u32)0; k < incLines.count(); k = k + (u32)1)
                        result.add(incLines.get(k));
                    }
                continue;
                }
            result.add((Object*)rawLine);
            }
        return expandMacros(result);
        }

    Array* expandMacros(Array* result)
        {
        Array* expanded = new Array();
        for (u32 i = (u32)0; i < result.count(); i = i + (u32)1)
            {
            String* rawLine = (String*)result.get(i);
            String* trimmed = stripComment(rawLine).trimmed();
            String* afterLabel = trimmed;
            bool hadLabel = false;
            u32 colon = trimmed.byteIndexOf(String.withCString(":"));
            if (colon != (u32)$FFFF_FFFF && colon < (u32)20)
                {
                String* before = trimmed.substringBytes((u32)0, colon).trimmed();
                if (isValidIdentifier(before))
                    {
                    afterLabel = trimmed.substringFromByte(colon + (u32)1).trimmed();
                    hadLabel = true;
                    }
                }
            Array* words = splitWhitespace(afterLabel);
            i32 mi = (i32)-1;
            if (words.count() > (u32)0)
                mi = macroIndex((String*)words.get((u32)0));
            if (mi >= (i32)0)
                {
                if (hadLabel)
                    expanded.add((Object*)trimmed.substringBytes((u32)0, colon + (u32)1));
                String* name = (String*)words.get((u32)0);
                String* args = afterLabel.byteLength() > name.byteLength()
                                   ? afterLabel.substringFromByte(name.byteLength()).trimmed()
                                   : String.withCString("");
                Array* body = expandMacro((u32)mi, args);
                for (u32 k = (u32)0; k < body.count(); k = k + (u32)1)
                    expanded.add(body.get(k));
                continue;
                }
            expanded.add((Object*)rawLine);
            }
        return expanded;
        }

    i32 macroIndex(String* name)
        {
        if (_macroNames == (Array*)0 || name.byteLength() == (u32)0)
            return (i32)-1;
        for (u32 i = (u32)0; i < _macroNames.count(); i = i + (u32)1)
            if (((String*)_macroNames.get(i)).equals(name))
                return (i32)i;
        return (i32)-1;
        }

    Array* expandMacro(u32 mi, String* argsStr)
        {
        Array* argValues = new Array();
        if (argsStr.byteLength() > (u32)0)
            {
            Array* as = argsStr.splitOnByte((u8)',');
            for (u32 i = (u32)0; i < as.count(); i = i + (u32)1)
                argValues.add((Object*)((String*)as.get(i)).trimmed());
            }
        Array* params = (Array*)_macroParams.get(mi);
        Array* body = (Array*)_macroBodies.get(mi);
        Array* out = new Array();
        for (u32 i = (u32)0; i < body.count(); i = i + (u32)1)
            {
            String* line = (String*)body.get(i);
            for (u32 k = (u32)0; k < params.count() && k < argValues.count(); k = k + (u32)1)
                line = replaceAll(line, (String*)params.get(k), (String*)argValues.get(k));
            out.add((Object*)line);
            }
        return out;
        }

    static String* replaceAll(String* s, String* from, String* to)
        {
        if (from.byteLength() == (u32)0)
            return s;
        String* out = new String();
        u32 i = (u32)0;
        while (i < s.byteLength())
            {
            if (i + from.byteLength() <= s.byteLength() && s.substringBytes(i, from.byteLength()).equals(from))
                {
                out.append(to);
                i = i + from.byteLength();
                continue;
                }
            out.appendByte(s.byteAt(i));
            i = i + (u32)1;
            }
        return out;
        }

    String* readInclude(String* filename, String* currentFile)
        {
        Array* paths = new Array();
        paths.add((Object*)dirOf(currentFile));
        if (_includePaths != (Array*)0)
            for (u32 i = (u32)0; i < _includePaths.count(); i = i + (u32)1)
                paths.add(_includePaths.get(i));
        for (u32 i = (u32)0; i < paths.count(); i = i + (u32)1)
            {
            String* dir = (String*)paths.get(i);
            String* full = new String();
            if (dir.byteLength() > (u32)0)
                {
                full.append(dir);
                full.appendCString("/");
                }
            full.append(filename);
            String* content = Files.readText(full);
            if (content != (String*)0)
                return content;
            }
        String* m = String.withCString("cannot find include file '");
        m.append(filename);
        m.appendCString("'");
        err(m);
        return (String*)0;
        }

    static String* dirOf(String* path)
        {
        u32 last = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i < path.byteLength(); i = i + (u32)1)
            if (path.byteAt(i) == (u8)'/')
                last = i;
        return last == (u32)$FFFF_FFFF ? String.withCString("") : path.substringBytes((u32)0, last);
        }

    // ── Banked XEX output ────────────────────────────────────────────────
    //
    // A banked segment cannot simply be loaded: the $6000-$9FFF window shows
    // whichever bank the selector register names, so the loader has to SELECT
    // the bank before the bytes stream in. The trick is INITAD — the Atari
    // loader jumps to whatever address sits at $02E2 after each segment — so
    // each banked segment is preceded by a tiny stub in the cassette buffer
    // that writes the bank register, an INITAD pointing at it, and a re-load of
    // the same bytes to fire it. Then the payload lands in the right page.
    //
    // The stub is idempotent, so re-loading it to trigger the fire is harmless.
    u32 _bankWindowStart;
    u32 _bankWindowEnd;
    u32 _dataWindowStart;
    u32 _dataWindowEnd;
    bool _hasSplitBanking;

    void setBankWindow(u32 lo, u32 hi)
        {
        _bankWindowStart = lo;
        _bankWindowEnd = hi;
        }
    // Recording the data window does NOT by itself mean split banking: the xt
    // layout has two windows but ONE joint selector pair (low byte to the code
    // register, high byte to the data one). Split mode — two independent 8-bit
    // selectors — is a separate decision the layout makes.
    void setDataWindow(u32 lo, u32 hi)
        {
        _dataWindowStart = lo;
        _dataWindowEnd = hi;
        }
    void setSplitBanking(bool v)
        {
        _hasSplitBanking = v;
        }

    // `LDA #v / STA <reg>` — zero page when the register fits, absolute
    // otherwise, because a layout may put the selector outside ZP (xt does:
    // $D5C0 and $D5C1).
    static void emitBankRegStore(Array* out, u32 addr)
        {
        if (addr <= (u32)$FF)
            {
            out.add((Object*)Number.withU32((u32)$85));
            out.add((Object*)Number.withU32(addr));
            return;
            }
        out.add((Object*)Number.withU32((u32)$8D));
        out.add((Object*)Number.withU32(addr & (u32)$FF));
        out.add((Object*)Number.withU32((addr >> (u32)8) & (u32)$FF));
        }

    static void addBlock(Array* xex, u32 start, u32 end)
        {
        xex.add((Object*)Number.withU32(start & (u32)$FF));
        xex.add((Object*)Number.withU32((start >> (u32)8) & (u32)$FF));
        xex.add((Object*)Number.withU32(end & (u32)$FF));
        xex.add((Object*)Number.withU32((end >> (u32)8) & (u32)$FF));
        }

    static void addAll(Array* dst, Array* src)
        {
        for (u32 i = (u32)0; i < src.count(); i = i + (u32)1)
            dst.add(src.get(i));
        }

    // INITAD ($02E2) pointing at the cassette buffer.
    static void addInitad(Array* xex)
        {
        xex.add((Object*)Number.withU32((u32)$E2));
        xex.add((Object*)Number.withU32((u32)$02));
        xex.add((Object*)Number.withU32((u32)$E3));
        xex.add((Object*)Number.withU32((u32)$02));
        xex.add((Object*)Number.withU32((u32)$FD));
        xex.add((Object*)Number.withU32((u32)$03));
        }

    Array* writeBankedXex(u32 entry)
        {
        Array* xex = new Array();
        xex.add((Object*)Number.withU32((u32)$FF));
        xex.add((Object*)Number.withU32((u32)$FF));

        u32 bwStart = _bankWindowStart != (u32)0 ? _bankWindowStart : (u32)$4000;
        u32 bwEnd = _bankWindowEnd != (u32)0 ? _bankWindowEnd : (u32)$7FFF;
        Array* mainSegs = new Array();
        Array* bankedSegs = new Array();
        for (u32 i = (u32)0; i < _segments.count(); i = i + (u32)1)
            {
            XaSegment* seg = (XaSegment*)_segments.get(i);
            if (seg.origin() >= bwStart && seg.origin() <= bwEnd)
                bankedSegs.add((Object*)seg);
            else
                mainSegs.add((Object*)seg);
            }

        u32 stubAddr = (u32)$03FD;
        u32 codeBankPage = (u32)1;
        u32 dataBankPage = (u32)1;
        u32 bankPage = (u32)1;
        i32 hiState = (i32)-1;

        for (u32 i = (u32)0; i < bankedSegs.count(); i = i + (u32)1)
            {
            XaSegment* bseg = (XaSegment*)bankedSegs.get(i);
            bool isDataSeg = _hasSplitBanking && bseg.origin() >= _dataWindowStart && bseg.origin() <= _dataWindowEnd;
            // An EMPTY banked segment is a placeholder bank-page anchor: at
            // -O3 the optimiser can inline away every function on a page and
            // leave the `.org` behind. It emits no bytes, but it still BURNS a
            // page number, so later classes stay on the bank their call sites
            // were compiled against.
            if (bseg.data().count() == (u32)0)
                {
                if (_hasSplitBanking)
                    {
                    if (isDataSeg)
                        dataBankPage = dataBankPage + (u32)1;
                    else
                        codeBankPage = codeBankPage + (u32)1;
                    }
                else
                    bankPage = bankPage + (u32)1;
                continue;
                }
            // An explicit `.bank` number overrides the running counter; the
            // counter still advances, so a later auto-numbered segment stays
            // correctly numbered.
            u32 effBankPage = bseg.bankNumber() >= (i32)0 ? (u32)bseg.bankNumber() : bankPage;
            u32 thisPage = _hasSplitBanking ? (isDataSeg ? dataBankPage : codeBankPage)
                                            : effBankPage;

            Array* stub = new Array();
            if (_hasSplitBanking)
                {
                // Split windows: write only the selector for this segment's
                // half. Code and data are fully independent under split mode,
                // so a code-side stub must not disturb the data bank.
                u32 reg = isDataSeg ? _dataBankReg : _codeBankReg;
                stub.add((Object*)Number.withU32((u32)$A9));
                stub.add((Object*)Number.withU32(thisPage & (u32)$FF));
                emitBankRegStore(stub, reg);
                stub.add((Object*)Number.withU32((u32)$60));
                }
            else
                {
                // Joint selector: low byte to the code register, high byte to
                // the data one. An 8-bit page never sets the high byte, so
                // that write stays dormant — and tracking it across segments
                // lets the stub drop to five bytes after the first.
                u32 lo = effBankPage & (u32)$FF;
                u32 hi = (effBankPage >> (u32)8) & (u32)$FF;
                stub.add((Object*)Number.withU32((u32)$A9));
                stub.add((Object*)Number.withU32(lo));
                emitBankRegStore(stub, _codeBankReg);
                if ((i32)hi != hiState)
                    {
                    stub.add((Object*)Number.withU32((u32)$A9));
                    stub.add((Object*)Number.withU32(hi));
                    emitBankRegStore(stub, _dataBankReg);
                    hiState = (i32)hi;
                    }
                stub.add((Object*)Number.withU32((u32)$60));
                }
            u32 stubEnd = stubAddr + stub.count() - (u32)1;
            addBlock(xex, stubAddr, stubEnd);
            addAll(xex, stub);
            addInitad(xex);
            addBlock(xex, stubAddr, stubEnd); // re-load to fire INITAD
            addAll(xex, stub);

            u32 loadStart = bseg.origin();
            u32 loadEnd = (loadStart + bseg.data().count() - (u32)1) & (u32)$FFFF;
            addBlock(xex, loadStart, loadEnd);
            addAll(xex, bseg.data());

            // Reset the selector before whatever loads next, so a later
            // banked segment's stub does not run against a stale bank.
            Array* reset = new Array();
            if (_hasSplitBanking)
                {
                u32 reg = isDataSeg ? _dataBankReg : _codeBankReg;
                reset.add((Object*)Number.withU32((u32)$A9));
                reset.add((Object*)Number.withU32((u32)0));
                emitBankRegStore(reset, reg);
                reset.add((Object*)Number.withU32((u32)$60));
                }
            else
                {
                reset.add((Object*)Number.withU32((u32)$A9));
                reset.add((Object*)Number.withU32((u32)0));
                emitBankRegStore(reset, _codeBankReg);
                if (hiState != (i32)0)
                    {
                    emitBankRegStore(reset, _dataBankReg);
                    hiState = (i32)0;
                    }
                reset.add((Object*)Number.withU32((u32)$60));
                }
            u32 rsEnd = stubAddr + reset.count() - (u32)1;
            addBlock(xex, stubAddr, rsEnd);
            addAll(xex, reset);
            addInitad(xex);
            addBlock(xex, stubAddr, rsEnd);
            addAll(xex, reset);

            if (_hasSplitBanking)
                {
                if (isDataSeg)
                    dataBankPage = dataBankPage + (u32)1;
                else
                    codeBankPage = codeBankPage + (u32)1;
                }
            else
                bankPage = bankPage + (u32)1;
            }

        for (u32 i = (u32)0; i < mainSegs.count(); i = i + (u32)1)
            {
            XaSegment* seg = (XaSegment*)mainSegs.get(i);
            if (seg.data().count() == (u32)0)
                continue;
            u32 start = seg.origin();
            u32 end = (start + seg.data().count() - (u32)1) & (u32)$FFFF;
            addBlock(xex, start, end);
            addAll(xex, seg.data());
            }

        xex.add((Object*)Number.withU32((u32)$E0));
        xex.add((Object*)Number.withU32((u32)$02));
        xex.add((Object*)Number.withU32((u32)$E1));
        xex.add((Object*)Number.withU32((u32)$02));
        xex.add((Object*)Number.withU32(entry & (u32)$FF));
        xex.add((Object*)Number.withU32((entry >> (u32)8) & (u32)$FF));
        return xex;
        }
    }
