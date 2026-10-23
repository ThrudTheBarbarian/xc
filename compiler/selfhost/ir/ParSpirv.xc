// ParSpirv.xc — the SPIR-V module builder for the `par` kernel printer.
// =================================================================
//
// The port of XTIRParSPIRV.m's XTSpvModule, XTSpvRecipe and XTSpvFunc: one
// module's sections in the order the format requires, ids, and caches so each
// type and constant is declared once. Everything is appended in the order the
// printer asks, so both compilers produce the same words. The printer itself
// is in Lower.xc (it needs the lowering's IR and the Metal port's analysis).
#import "Foundation.xc"

// SPIR-V opcodes and enumerants used by the printer.
#import "ParSpirvDefs.xc"


// GLSL.std.450

// One instruction into a section: its word count and opcode, then the words.
void spvOp(Array* sec, u32 op, Array* words)
    {
    sec.add((Object*)Number.withU32(((words.count() + (u32)1) << (u32)16) | op));
    for (u32 i = (u32)0; i < words.count(); i = i + (u32)1)
        sec.add(words.get(i));
    }

// Words, from up to six values; `n` of them.
Array* spvW(u32 n, u32 a, u32 b, u32 c, u32 d, u32 e, u32 f)
    {
    Array* w = new Array();
    if (n > (u32)0) w.add((Object*)Number.withU32(a));
    if (n > (u32)1) w.add((Object*)Number.withU32(b));
    if (n > (u32)2) w.add((Object*)Number.withU32(c));
    if (n > (u32)3) w.add((Object*)Number.withU32(d));
    if (n > (u32)4) w.add((Object*)Number.withU32(e));
    if (n > (u32)5) w.add((Object*)Number.withU32(f));
    return w;
    }

// A string operand: UTF-8, NUL-terminated, padded to a word.
Array* spvString(String* s)
    {
    Array* b = new Array();
    for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
        b.add((Object*)Number.withU32((u32)s.byteAt(i)));
    u32 pad = (u32)4 - s.byteLength() % (u32)4;
    for (u32 i = (u32)0; i < pad; i = i + (u32)1)
        b.add((Object*)Number.withU32((u32)0));
    Array* w = new Array();
    for (u32 i = (u32)0; i < b.count(); i = i + (u32)4)
        w.add((Object*)Number.withU32(((Number*)b.get(i)).asU32() | ((Number*)b.get(i + (u32)1)).asU32() << (u32)8 |
                                      ((Number*)b.get(i + (u32)2)).asU32() << (u32)16 |
                                      ((Number*)b.get(i + (u32)3)).asU32() << (u32)24));
    return w;
    }

class SpvMod
    {
    u32 bound;
    Array* head;       // ext imports, memory model, entry, modes
    Array* decos;
    Array* globals;    // types, constants, module variables
    Array* funcs;
    Map* cache;
    bool usesInt64;
    bool usesFloat64;
    u32 glsl;          // the GLSL.std.450 import, 0 until used

    void init(void)
        {
        bound = (u32)1;
        head = new Array();
        decos = new Array();
        globals = new Array();
        funcs = new Array();
        cache = new Map();
        usesInt64 = false;
        usesFloat64 = false;
        glsl = (u32)0;
        }

    u32 newId(void)
        {
        u32 i = bound;
        bound = bound + (u32)1;
        return i;
        }

    // A cached global declaration: `key` names it.
    u32 cached(String* key, u32 op, Array* words, bool resultFirst)
        {
        Number* have = (Number*)cache.get((Hashable*)key);
        if (have != (Number*)0)
            return have.asU32();
        u32 i = newId();
        Array* w = new Array();
        if (resultFirst)
            w.add((Object*)Number.withU32(i));
        for (u32 k = (u32)0; k < words.count(); k = k + (u32)1)
            w.add(words.get(k));
        spvOp(globals, op, w);
        cache.set((Hashable*)key, (Object*)Number.withU32(i));
        return i;
        }

    u32 typeVoid(void)
        {
        return cached(String.withCString("void"), (u32)SPV_TYPEVOID, new Array(), true);
        }

    u32 typeBool(void)
        {
        return cached(String.withCString("bool"), (u32)SPV_TYPEBOOL, new Array(), true);
        }

    u32 typeInt(u32 w)
        {
        if (w == (u32)64)
            usesInt64 = true;
        String* k = String.withCString("i");
        k.append(String.withU32(w));
        return cached(k, (u32)SPV_TYPEINT, spvW((u32)2, w, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0), true);
        }

    // The signed type of the same width. The module holds one integer type a
    // width and carries the signedness on the OPERATION (OpSDiv against
    // OpUDiv): the NVIDIA Vulkan driver reads the operand type's signedness as
    // the operation's for these, so a signed divide carries this type and the
    // bits cross by OpBitcast (bug 649; the reference explains).
    u32 typeIntSigned(u32 w)
        {
        if (w == (u32)64)
            usesInt64 = true;
        String* k = String.withCString("s");
        k.append(String.withU32(w));
        return cached(k, (u32)SPV_TYPEINT, spvW((u32)2, w, (u32)1, (u32)0, (u32)0, (u32)0, (u32)0), true);
        }

    u32 typeFloat(u32 w)
        {
        if (w == (u32)64)
            usesFloat64 = true;
        String* k = String.withCString("f");
        k.append(String.withU32(w));
        return cached(k, (u32)SPV_TYPEFLOAT, spvW((u32)1, w, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0), true);
        }

    u32 ptrType(u32 sc, u32 t)
        {
        String* k = String.withCString("p");
        k.append(String.withU32(sc));
        k.appendCString("_");
        k.append(String.withU32(t));
        return cached(k, (u32)SPV_TYPEPOINTER, spvW((u32)2, sc, t, (u32)0, (u32)0, (u32)0, (u32)0), true);
        }

    u32 constant(u32 type, u64 bits, bool wide)
        {
        String* k = String.withCString("c");
        k.append(String.withU32(type));
        k.appendCString("_");
        k.append(String.withU64(bits));
        Number* have = (Number*)cache.get((Hashable*)k);
        if (have != (Number*)0)
            return have.asU32();
        u32 i = newId();
        if (wide)
            spvOp(globals, (u32)SPV_CONSTANT, spvW((u32)4, type, i, (u32)bits, (u32)(bits >> (u64)32), (u32)0, (u32)0));
        else
            spvOp(globals, (u32)SPV_CONSTANT, spvW((u32)3, type, i, (u32)bits, (u32)0, (u32)0, (u32)0));
        cache.set((Hashable*)k, (Object*)Number.withU32(i));
        return i;
        }

    u32 constBool(bool v)
        {
        u32 b = typeBool();
        String* k = String.withCString(v ? "true" : "false");
        Number* have = (Number*)cache.get((Hashable*)k);
        if (have != (Number*)0)
            return have.asU32();
        u32 i = newId();
        spvOp(globals, v ? (u32)SPV_CONSTANTTRUE : (u32)SPV_CONSTANTFALSE, spvW((u32)2, b, i, (u32)0, (u32)0, (u32)0, (u32)0));
        cache.set((Hashable*)k, (Object*)Number.withU32(i));
        return i;
        }

    u32 u32c(u32 v)
        {
        return constant(typeInt((u32)32), (u64)v, false);
        }

    u32 glslImport(void)
        {
        if (glsl == (u32)0)
            {
            glsl = newId();
            Array* w = new Array();
            w.add((Object*)Number.withU32(glsl));
            Array* s = spvString(String.withCString("GLSL.std.450"));
            for (u32 i = (u32)0; i < s.count(); i = i + (u32)1)
                w.add(s.get(i));
            // Imports go first in the head section.
            Array* sec = new Array();
            spvOp(sec, (u32)SPV_EXTINSTIMPORT, w);
            for (u32 i = (u32)0; i < head.count(); i = i + (u32)1)
                sec.add(head.get(i));
            head = sec;
            }
        return glsl;
        }

    // The module as little-endian bytes.
    Array* bytes(void)
        {
        Array* all = new Array();
        all.add((Object*)Number.withU32((u32)0x07230203));
        all.add((Object*)Number.withU32((u32)0x00010600));
        all.add((Object*)Number.withU32((u32)0));
        all.add((Object*)Number.withU32(bound));
        all.add((Object*)Number.withU32((u32)0));
        spvOp(all, (u32)SPV_CAPABILITY, spvW((u32)1, (u32)SPV_CAP_SHADER, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0));
        if (usesInt64)
            spvOp(all, (u32)SPV_CAPABILITY, spvW((u32)1, (u32)SPV_CAP_INT64, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0));
        if (usesFloat64)
            spvOp(all, (u32)SPV_CAPABILITY, spvW((u32)1, (u32)SPV_CAP_FLOAT64, (u32)0, (u32)0, (u32)0, (u32)0, (u32)0));
        Array* secs[5];
        secs[0] = head;
        secs[1] = decos;
        secs[2] = globals;
        secs[3] = funcs;
        for (u32 s = (u32)0; s < (u32)4; s = s + (u32)1)
            for (u32 i = (u32)0; i < secs[s].count(); i = i + (u32)1)
                all.add(secs[s].get(i));
        Array* out = new Array();
        for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
            {
            u32 v = ((Number*)all.get(i)).asU32();
            out.add((Object*)Number.withU8((u8)(v & (u32)0xFF)));
            out.add((Object*)Number.withU8((u8)((v >> (u32)8) & (u32)0xFF)));
            out.add((Object*)Number.withU8((u8)((v >> (u32)16) & (u32)0xFF)));
            out.add((Object*)Number.withU8((u8)((v >> (u32)24) & (u32)0xFF)));
            }
        return out;
        }
    }

// Where a pointer value points, as an access chain: a base variable and the
// indexes into it (constant member numbers, then at most one dynamic index,
// held in a variable).
class SpvRecipe
    {
    u32 base;
    u32 storage;
    Array* members;    // constant ids (Number)
    u32 indexVar;      // a Function variable holding the element index, or 0
    u32 indexType;
    String* pointee;   // the IR type pointed at
    bool words;        // a narrow element of a buffer of 32-bit words
    u32 wordShift;     // a narrow captured value: its bit offset in its word, + 1 (0: none)

    SpvRecipe* copy(void)
        {
        SpvRecipe* r = new SpvRecipe();
        r.base = base;
        r.storage = storage;
        r.members = members;
        r.indexVar = indexVar;
        r.indexType = indexType;
        r.pointee = pointee;
        r.words = words;
        r.wordShift = wordShift;
        return r;
        }
    }

// One function being printed (the kernel or a helper).
class SpvFn
    {
    Array* vars;       // its Function variables, first in the entry block
    Array* code;
    Map* varOf;        // value key -> variable (Number)
    Map* recipeOf;     // pointer value key -> SpvRecipe
    Map* used;         // value key -> 1: values some instruction reads
    Map* blockNum;     // block name -> its number (Number)
    u32 pcVar;
    u32 retVar;
    u32 loopContinue;
    // The structured walk (Lower.xc spvS…): a dry run only checks the shape;
    // the current block is open; each loop header's continue target and
    // merge; where the kernel's return goes.
    bool dry;
    bool open;
    Map* loopCont;     // header index -> Number
    Map* loopMerge;
    u32 exitLabel;

    void init(void)
        {
        vars = new Array();
        code = new Array();
        varOf = new Map();
        recipeOf = new Map();
        used = new Map();
        blockNum = new Map();
        pcVar = (u32)0;
        retVar = (u32)0;
        loopContinue = (u32)0;
        dry = false;
        open = false;
        loopCont = new Map();
        loopMerge = new Map();
        exitLabel = (u32)0;
        }
    }
