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
#define SPV_EXTINSTIMPORT 11
#define SPV_EXTINST 12
#define SPV_MEMORYMODEL 14
#define SPV_ENTRYPOINT 15
#define SPV_EXECUTIONMODE 16
#define SPV_CAPABILITY 17
#define SPV_TYPEVOID 19
#define SPV_TYPEBOOL 20
#define SPV_TYPEINT 21
#define SPV_TYPEFLOAT 22
#define SPV_TYPEVECTOR 23
#define SPV_TYPERUNTIMEARRAY 29
#define SPV_TYPESTRUCT 30
#define SPV_TYPEPOINTER 32
#define SPV_TYPEFUNCTION 33
#define SPV_CONSTANTTRUE 41
#define SPV_CONSTANTFALSE 42
#define SPV_CONSTANT 43
#define SPV_FUNCTION 54
#define SPV_FUNCTIONPARAMETER 55
#define SPV_FUNCTIONEND 56
#define SPV_FUNCTIONCALL 57
#define SPV_VARIABLE 59
#define SPV_LOAD 61
#define SPV_STORE 62
#define SPV_ACCESSCHAIN 65
#define SPV_DECORATE 71
#define SPV_MEMBERDECORATE 72
#define SPV_COMPOSITEEXTRACT 81
#define SPV_CONVERTFTOU 109
#define SPV_CONVERTFTOS 110
#define SPV_CONVERTSTOF 111
#define SPV_CONVERTUTOF 112
#define SPV_UCONVERT 113
#define SPV_SCONVERT 114
#define SPV_FCONVERT 115
#define SPV_BITCAST 124
#define SPV_SNEGATE 126
#define SPV_FNEGATE 127
#define SPV_IADD 128
#define SPV_FADD 129
#define SPV_ISUB 130
#define SPV_FSUB 131
#define SPV_IMUL 132
#define SPV_FMUL 133
#define SPV_UDIV 134
#define SPV_SDIV 135
#define SPV_FDIV 136
#define SPV_UMOD 137
#define SPV_SREM 138
#define SPV_LOGICALEQUAL 164
#define SPV_LOGICALNOTEQUAL 165
#define SPV_LOGICALOR 166
#define SPV_LOGICALAND 167
#define SPV_LOGICALNOT 168
#define SPV_SELECT 169
#define SPV_IEQUAL 170
#define SPV_INOTEQUAL 171
#define SPV_UGREATERTHAN 172
#define SPV_SGREATERTHAN 173
#define SPV_UGREATERTHANEQUAL 174
#define SPV_SGREATERTHANEQUAL 175
#define SPV_ULESSTHAN 176
#define SPV_SLESSTHAN 177
#define SPV_ULESSTHANEQUAL 178
#define SPV_SLESSTHANEQUAL 179
#define SPV_FORDEQUAL 180
#define SPV_FUNORDNOTEQUAL 183
#define SPV_FORDLESSTHAN 184
#define SPV_FORDGREATERTHAN 186
#define SPV_FORDLESSTHANEQUAL 188
#define SPV_FORDGREATERTHANEQUAL 190
#define SPV_SHIFTRIGHTLOGICAL 194
#define SPV_SHIFTRIGHTARITHMETIC 195
#define SPV_SHIFTLEFTLOGICAL 196
#define SPV_BITWISEOR 197
#define SPV_BITWISEXOR 198
#define SPV_BITWISEAND 199
#define SPV_NOT 200
#define SPV_ATOMICAND 240
#define SPV_ATOMICOR 241
#define SPV_LOOPMERGE 246
#define SPV_SELECTIONMERGE 247
#define SPV_LABEL 248
#define SPV_BRANCH 249
#define SPV_BRANCHCONDITIONAL 250
#define SPV_SWITCH 251
#define SPV_RETURN 253
#define SPV_RETURNVALUE 254
#define SPV_UNREACHABLE 255

#define SPV_ST_INPUT 1
#define SPV_ST_PUSHCONSTANT 9
#define SPV_ST_STORAGEBUFFER 12
#define SPV_ST_FUNCTION 7
#define SPV_DEC_BLOCK 2
#define SPV_DEC_ARRAYSTRIDE 6
#define SPV_DEC_NONWRITABLE 24
#define SPV_DEC_BUILTIN 11
#define SPV_DEC_BINDING 33
#define SPV_DEC_DESCRIPTORSET 34
#define SPV_DEC_OFFSET 35
#define SPV_BUILTIN_GLOBALINVOCATIONID 28
#define SPV_BUILTIN_WORKGROUPID 26
#define SPV_BUILTIN_LOCALINVOCATIONID 27
#define SPV_ST_WORKGROUP 4
#define SPV_TYPEARRAY 28
#define SPV_CONTROLBARRIER 224
#define SPV_CAP_SHADER 1
#define SPV_CAP_FLOAT64 10
#define SPV_CAP_INT64 11

// GLSL.std.450
#define GLSL_FABS 4
#define GLSL_SABS 5
#define GLSL_FLOOR 8
#define GLSL_SIN 13
#define GLSL_COS 14
#define GLSL_POW 26
#define GLSL_EXP 27
#define GLSL_LOG 28
#define GLSL_SQRT 31
#define GLSL_FMIN 37
#define GLSL_UMIN 38
#define GLSL_SMIN 39
#define GLSL_FMAX 40
#define GLSL_UMAX 41
#define GLSL_SMAX 42
#define GLSL_FMA 50

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
