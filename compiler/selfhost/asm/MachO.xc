// MachO.xc — serialise a laid-out arm64 image into a Mach-O executable.
// =================================================================
//
// self-hosting M19, a port of `XTMachOWriter`. It takes what the assembler
// produced — text bytes, data bytes, symbol offsets, fixups — and writes a
// complete, ad-hoc-signed MH_EXECUTE with no external toolchain: no clang, no
// system `as`, no `codesign`.
//
// One representation choice runs through the whole file. Every virtual address
// here is VMBASE + a file offset, and VMBASE (0x1_0000_0000) is page-aligned —
// so the port keeps addresses as 32-bit FILE OFFSETS and adds the base only
// when it writes one out. Page deltas subtract, so the base cancels and never
// has to exist as a 64-bit quantity at all. That is what lets a language with
// no 64-bit integer write a 64-bit object format without arithmetic gymnastics.

#import "Foundation.xc"
#import "MachOObject.xc"
#import "Arm64Asm.xc"

#define MACHO_PAGE $4000
#define STUB_SZ 12
#define GOT_SZ 8

class Sha256
    {
    u32 _s[8];
    u32 _len; // bytes hashed so far; a Mach-O here is far under 4 GB
    u32 _buf[64];
    u32 _n;

    void init(void)
        {
        _s[0] = (u32)$6a09e667;
        _s[1] = (u32)$bb67ae85;
        _s[2] = (u32)$3c6ef372;
        _s[3] = (u32)$a54ff53a;
        _s[4] = (u32)$510e527f;
        _s[5] = (u32)$9b05688c;
        _s[6] = (u32)$1f83d9ab;
        _s[7] = (u32)$5be0cd19;
        _len = (u32)0;
        _n = (u32)0;
        }

    static u32 ror32(u32 x, u32 r)
        {
        return (x >> r) | (x << ((u32)32 - r));
        }

    static u32 k(u32 i)
        {
        // The round constants: the fractional parts of the cube roots of the
        // first 64 primes. Spelled out rather than computed — a table this
        // size is clearer than the derivation and cannot drift.
        u32 t[64];
        t[0] = (u32)$428a2f98;
        t[1] = (u32)$71374491;
        t[2] = (u32)$b5c0fbcf;
        t[3] = (u32)$e9b5dba5;
        t[4] = (u32)$3956c25b;
        t[5] = (u32)$59f111f1;
        t[6] = (u32)$923f82a4;
        t[7] = (u32)$ab1c5ed5;
        t[8] = (u32)$d807aa98;
        t[9] = (u32)$12835b01;
        t[10] = (u32)$243185be;
        t[11] = (u32)$550c7dc3;
        t[12] = (u32)$72be5d74;
        t[13] = (u32)$80deb1fe;
        t[14] = (u32)$9bdc06a7;
        t[15] = (u32)$c19bf174;
        t[16] = (u32)$e49b69c1;
        t[17] = (u32)$efbe4786;
        t[18] = (u32)$0fc19dc6;
        t[19] = (u32)$240ca1cc;
        t[20] = (u32)$2de92c6f;
        t[21] = (u32)$4a7484aa;
        t[22] = (u32)$5cb0a9dc;
        t[23] = (u32)$76f988da;
        t[24] = (u32)$983e5152;
        t[25] = (u32)$a831c66d;
        t[26] = (u32)$b00327c8;
        t[27] = (u32)$bf597fc7;
        t[28] = (u32)$c6e00bf3;
        t[29] = (u32)$d5a79147;
        t[30] = (u32)$06ca6351;
        t[31] = (u32)$14292967;
        t[32] = (u32)$27b70a85;
        t[33] = (u32)$2e1b2138;
        t[34] = (u32)$4d2c6dfc;
        t[35] = (u32)$53380d13;
        t[36] = (u32)$650a7354;
        t[37] = (u32)$766a0abb;
        t[38] = (u32)$81c2c92e;
        t[39] = (u32)$92722c85;
        t[40] = (u32)$a2bfe8a1;
        t[41] = (u32)$a81a664b;
        t[42] = (u32)$c24b8b70;
        t[43] = (u32)$c76c51a3;
        t[44] = (u32)$d192e819;
        t[45] = (u32)$d6990624;
        t[46] = (u32)$f40e3585;
        t[47] = (u32)$106aa070;
        t[48] = (u32)$19a4c116;
        t[49] = (u32)$1e376c08;
        t[50] = (u32)$2748774c;
        t[51] = (u32)$34b0bcb5;
        t[52] = (u32)$391c0cb3;
        t[53] = (u32)$4ed8aa4a;
        t[54] = (u32)$5b9cca4f;
        t[55] = (u32)$682e6ff3;
        t[56] = (u32)$748f82ee;
        t[57] = (u32)$78a5636f;
        t[58] = (u32)$84c87814;
        t[59] = (u32)$8cc70208;
        t[60] = (u32)$90befffa;
        t[61] = (u32)$a4506ceb;
        t[62] = (u32)$bef9a3f7;
        t[63] = (u32)$c67178f2;
        return t[i];
        }

    void block(void)
        {
        u32 w[64];
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            w[i] = (_buf[i * (u32)4] << (u32)24) | (_buf[i * (u32)4 + (u32)1] << (u32)16) | (_buf[i * (u32)4 + (u32)2] << (u32)8) | _buf[i * (u32)4 + (u32)3];
        for (u32 i = (u32)16; i < (u32)64; i = i + (u32)1)
            {
            u32 a = w[i - (u32)15];
            u32 b = w[i - (u32)2];
            u32 s0 = ror32(a, (u32)7) ^ ror32(a, (u32)18) ^ (a >> (u32)3);
            u32 s1 = ror32(b, (u32)17) ^ ror32(b, (u32)19) ^ (b >> (u32)10);
            w[i] = w[i - (u32)16] + s0 + w[i - (u32)7] + s1;
            }
        u32 a = _s[0];
        u32 b = _s[1];
        u32 c = _s[2];
        u32 d = _s[3];
        u32 e = _s[4];
        u32 f = _s[5];
        u32 g = _s[6];
        u32 h = _s[7];
        for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1)
            {
            u32 S1 = ror32(e, (u32)6) ^ ror32(e, (u32)11) ^ ror32(e, (u32)25);
            u32 ch = (e & f) ^ (~e & g);
            u32 t1 = h + S1 + ch + k(i) + w[i];
            u32 S0 = ror32(a, (u32)2) ^ ror32(a, (u32)13) ^ ror32(a, (u32)22);
            u32 maj = (a & b) ^ (a & c) ^ (b & c);
            u32 t2 = S0 + maj;
            h = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = b;
            b = a;
            a = t1 + t2;
            }
        _s[0] = _s[0] + a;
        _s[1] = _s[1] + b;
        _s[2] = _s[2] + c;
        _s[3] = _s[3] + d;
        _s[4] = _s[4] + e;
        _s[5] = _s[5] + f;
        _s[6] = _s[6] + g;
        _s[7] = _s[7] + h;
        }

    void update(Array* bytes, u32 from, u32 len)
        {
        _len = _len + len;
        for (u32 i = (u32)0; i < len; i = i + (u32)1)
            {
            _buf[_n] = ((Number*)bytes.get(from + i)).asU32() & (u32)$FF;
            _n = _n + (u32)1;
            if (_n == (u32)64)
                {
                block();
                _n = (u32)0;
                }
            }
        }

    // The length is appended as a 64-bit BIT count. Only the low 35 bits can be
    // non-zero for anything this writes, but the field is still eight bytes.
    void finalise(Array* out)
        {
        u32 bitsLo = _len << (u32)3;
        u32 bitsHi = _len >> (u32)29;
        _buf[_n] = (u32)$80;
        _n = _n + (u32)1;
        if (_n == (u32)64)
            {
            block();
            _n = (u32)0;
            }
        while (_n != (u32)56)
            {
            _buf[_n] = (u32)0;
            _n = _n + (u32)1;
            if (_n == (u32)64)
                {
                block();
                _n = (u32)0;
                }
            }
        _buf[56] = (u32)0;
        _buf[57] = (u32)0;
        _buf[58] = (u32)0;
        _buf[59] = (u32)0;
        _buf[56] = (bitsHi >> (u32)24) & (u32)$FF;
        _buf[57] = (bitsHi >> (u32)16) & (u32)$FF;
        _buf[58] = (bitsHi >> (u32)8) & (u32)$FF;
        _buf[59] = bitsHi & (u32)$FF;
        _buf[60] = (bitsLo >> (u32)24) & (u32)$FF;
        _buf[61] = (bitsLo >> (u32)16) & (u32)$FF;
        _buf[62] = (bitsLo >> (u32)8) & (u32)$FF;
        _buf[63] = bitsLo & (u32)$FF;
        block();
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
                out.add((Object*)Number.withU32((_s[i] >> ((u32)8 * ((u32)3 - b))) & (u32)$FF));
        }
    }

    // ── The dyld EXPORT TRIE ─────────────────────────────────────────────────
    //
    // A dylib publishes its symbols here, not in the symbol table: dyld resolves a
    // client's import by WALKING this, and a name absent from it does not exist as
    // far as the loader is concerned however many nlist entries name it.
    //
    // The shape is a radix tree over the names. Each node carries an optional
    // terminal payload (flags + the symbol's image-relative address) and a list of
    // (edge-string, child-offset) pairs. Offsets are ULEB, so a node's SIZE depends
    // on its children's offsets and their offsets depend on the sizes ahead of
    // them — which is why the layout below is solved rather than computed once.
    class ExportTrieNode
    {
    bool _terminal;
    u32 _addr;
    Array* _edges; // String@
    Array* _kids;  // ExportTrieNode@
    u32 _offset;
    u32 _size;

    void init(void)
        {
        _terminal = false;
        _addr = (u32)0;
        _edges = new Array();
        _kids = new Array();
        _offset = (u32)0;
        _size = (u32)0;
        }
    bool terminal(void)
        {
        return _terminal;
        }
    u32 addr(void)
        {
        return _addr;
        }
    Array* edges(void)
        {
        return _edges;
        }
    Array* kids(void)
        {
        return _kids;
        }
    u32 offset(void)
        {
        return _offset;
        }
    void setTerminal(u32 a)
        {
        _terminal = true;
        _addr = a;
        }
    void setOffset(u32 o)
        {
        _offset = o;
        }
    void setSize(u32 z)
        {
        _size = z;
        }
    }

    class ExportTrie
    {
    // One node and everything below it. `idxs` are indices into `names`;
    // `depth` is how many bytes of those names the walk has already spent.
    static ExportTrieNode* build(Array* names, Array* addrs, Array* idxs, u32 depth)
        {
        ExportTrieNode* node = new ExportTrieNode();
        Array* rest = new Array();
        for (u32 i = (u32)0; i < idxs.count(); i = i + (u32)1)
            {
            u32 ix = ((Number*)idxs.get(i)).asU32();
            String* nm = (String*)names.get(ix);
            if (nm.byteLength() == depth) // this name ENDS here
                node.setTerminal(((Number*)addrs.get(ix)).asU32());
            else
                rest.add((Object*)Number.withU32(ix));
            }
        // Partitioned by the next byte in FIRST-SEEN order, so the output is a
        // function of the input and not of how a map happened to hash.
        Array* order = new Array();  // Number@ (the byte)
        Array* groups = new Array(); // Array@ of Number@
        for (u32 i = (u32)0; i < rest.count(); i = i + (u32)1)
            {
            u32 ix = ((Number*)rest.get(i)).asU32();
            u32 c = (u32)((String*)names.get(ix)).byteAt(depth);
            i32 at = (i32)-1;
            for (u32 k = (u32)0; k < order.count(); k = k + (u32)1)
                if (((Number*)order.get(k)).asU32() == c)
                    at = (i32)k;
            if (at < (i32)0)
                {
                order.add((Object*)Number.withU32(c));
                groups.add((Object*)new Array());
                at = (i32)(order.count() - (u32)1);
                }
            ((Array*)groups.get((u32)at)).add((Object*)Number.withU32(ix));
            }
        for (u32 k = (u32)0; k < order.count(); k = k + (u32)1)
            {
            Array* g = (Array*)groups.get(k);
            // The group's longest common prefix past `depth` becomes ONE edge,
            // so a chain of single-child nodes never appears.
            String* first = (String*)names.get(((Number*)g.get((u32)0)).asU32());
            u32 lcp = depth + (u32)1;
            while (lcp < first.byteLength())
                {
                bool all = true;
                for (u32 i = (u32)0; i < g.count(); i = i + (u32)1)
                    {
                    String* c = (String*)names.get(((Number*)g.get(i)).asU32());
                    if (c.byteLength() <= lcp || c.byteAt(lcp) != first.byteAt(lcp))
                        all = false;
                    }
                if (!all)
                    break;
                lcp = lcp + (u32)1;
                }
            node.edges().add((Object*)first.substringBytes(depth, lcp - depth));
            node.kids().add((Object*)ExportTrie.build(names, addrs, g, lcp));
            }
        return node;
        }

    static void flatten(ExportTrieNode* n, Array* out)
        {
        out.add((Object*)n);
        for (u32 i = (u32)0; i < n.kids().count(); i = i + (u32)1)
            ExportTrie.flatten((ExportTrieNode*)n.kids().get(i), out);
        }

    static u32 nodeSize(ExportTrieNode* n)
        {
        u32 sz = (u32)0;
        if (n.terminal())
            {
            u32 term = (u32)1 + MachO.ulebLen(n.addr()); // flags + address
            sz = sz + MachO.ulebLen(term) + term;
            }
        else
            {
            sz = sz + (u32)1; // terminalSize = 0
            }
        sz = sz + (u32)1; // childCount
        for (u32 i = (u32)0; i < n.kids().count(); i = i + (u32)1)
            {
            sz = sz + ((String*)n.edges().get(i)).byteLength() + (u32)1;
            sz = sz + MachO.ulebLen(((ExportTrieNode*)n.kids().get(i)).offset());
            }
        return sz;
        }

    // The trie's bytes, or an empty array when nothing is exported.
    static Array* build(Array* names, Array* addrs)
        {
        Array* out = new Array();
        if (names.count() == (u32)0)
            return out;
        Array* all = new Array();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            all.add((Object*)Number.withU32(i));
        ExportTrieNode* root = ExportTrie.build(names, addrs, all, (u32)0);
        Array* nodes = new Array();
        ExportTrie.flatten(root, nodes);

        // Sizes only ever GROW as offsets grow, so iterating to a fixed point
        // converges. Capped and then checked: a trie that silently did not
        // settle is a truncated export list, which reads as "the library does
        // not have that symbol" — the failure mode of private:docs/bugs/042.
        bool settled = false;
        for (u32 iter = (u32)0; iter < (u32)16 && !settled; iter = iter + (u32)1)
            {
            u32 off = (u32)0;
            for (u32 i = (u32)0; i < nodes.count(); i = i + (u32)1)
                {
                ExportTrieNode* nd = (ExportTrieNode*)nodes.get(i);
                nd.setOffset(off);
                off = off + ExportTrie.nodeSize(nd);
                }
            settled = true;
            u32 chk = (u32)0;
            for (u32 i = (u32)0; i < nodes.count(); i = i + (u32)1)
                {
                ExportTrieNode* nd = (ExportTrieNode*)nodes.get(i);
                if (nd.offset() != chk)
                    {
                    settled = false;
                    i = nodes.count();
                    }
                else
                    chk = chk + ExportTrie.nodeSize(nd);
                }
            }

        for (u32 i = (u32)0; i < nodes.count(); i = i + (u32)1)
            {
            ExportTrieNode* nd = (ExportTrieNode*)nodes.get(i);
            if (nd.terminal())
                {
                u32 term = (u32)1 + MachO.ulebLen(nd.addr());
                ExportTrie.putULEB(out, term);
                out.add((Object*)Number.withU32((u32)0)); // flags = REGULAR
                ExportTrie.putULEB(out, nd.addr());
                }
            else
                {
                out.add((Object*)Number.withU32((u32)0)); // terminalSize = 0
                }
            out.add((Object*)Number.withU32(nd.kids().count()));
            for (u32 k = (u32)0; k < nd.kids().count(); k = k + (u32)1)
                {
                String* e = (String*)nd.edges().get(k);
                for (u32 b = (u32)0; b < e.byteLength(); b = b + (u32)1)
                    out.add((Object*)Number.withU32((u32)e.byteAt(b)));
                out.add((Object*)Number.withU32((u32)0)); // NUL
                ExportTrie.putULEB(out, ((ExportTrieNode*)nd.kids().get(k)).offset());
                }
            }
        return out;
        }

    static void putULEB(Array* out, u32 v)
        {
        while (true)
            {
            u32 b = v & (u32)$7F;
            v = v >> (u32)7;
            if (v != (u32)0)
                b = b | (u32)$80;
            out.add((Object*)Number.withU32(b));
            if (v == (u32)0)
                return;
            }
        }
    }

    // A shared library this image LINKS AGAINST: its install path, and the names
    // it exports. Both halves are needed — the path becomes an LC_LOAD_DYLIB, and
    // the export set decides which of this image's imports bind to it rather than
    // to libSystem. Binding a library's symbol at libSystem's ordinal is a file
    // that links and then will not load, naming libSystem for a symbol libSystem
    // never had.
    class MachODep
    {
    String* _path;
    Array* _syms; // String@
    void init(void)
        {
        _path = (String*)0;
        _syms = new Array();
        }
    static MachODep* with(String* path, Array* syms)
        {
        MachODep* d = new MachODep();
        d._path = path;
        d._syms = syms == (Array*)0 ? new Array() : syms;
        return d;
        }
    String* path(void)
        {
        return _path;
        }
    Array* syms(void)
        {
        return _syms;
        }
    }

    // Everything the layout pass decided, in one place. It exists so the emitters
    // take ONE argument instead of forty: a long parameter list is not just hard to
    // read, it also spills a frame far past what a single stack slot can address.
    class MachOLayout
    {
    u32 textOffset;
    u32 stubsOffset;
    u32 stubsSize;
    u32 textSegEnd;
    u32 dataSegFileOff;
    u32 dataProgOffset;
    u32 gotOffset;
    u32 gotSize;
    u32 dataSegEnd;
    u32 gotOffInSeg;
    u32 linkeditOff;
    u32 linkeditFilesz;
    u32 linkeditVmsz;
    u32 rebaseOff;
    u32 rebaseLen;
    u32 bindOff;
    u32 bindLen;
    u32 symoff;
    u32 nsyms;
    u32 stroff;
    u32 strsizeRaw;
    u32 indOff;
    u32 ndef;
    u32 nimp;
    u32 sigOffset;
    u32 sigSize;
    u32 entryOffset;
    u32 ncmds;
    u32 sizeofcmds;
    u32 nDataSects;
    u32 szPagezero;
    u32 szTextSeg;
    u32 szDataSeg;
    u32 szLink;
    u32 szDyldInfo;
    u32 szDyld;
    u32 szMain;
    u32 szDylib;
    u32 szSym;
    u32 szDysym;
    u32 szBuild;
    u32 szUUID;
    u32 szCodeSig;
    u32 szRpath;
    u32 szDeps;
    u32 textLen;
    u32 dataLen;
    bool hasData;
    bool hasImp;
    bool hasDataSeg;
    bool hasRebase;
    bool hasDyldInfo;
    // Bug 066: the __mod_init_func tail of __data, and the part that is not it.
    bool hasModInit;
    bool hasDataSect;
    u32 miLen;
    u32 dOnly;

    void init(void)
        {
        }
    }

    class MachO
    {
    Array* _out; // Number@ per byte
    // LC_BUILD_VERSION stamp — mirrors XTMachOWriter's sPlatform* statics:
    // macos (1, 11.0) by default; setApplePlatform("ios"/"ios-sim") switches
    // to 2/7 with minos 15.0. One image per process, exactly as in the ref.
    u32 _platformId;
    u32 _platformVer;
    // The segment and section names are fixed, so they are built once. Doing
    // it at the call sites instead put a String temporary in every emitter's
    // frame, which is how a load-command writer ended up wanting ten kilobytes
    // of stack.
    Array* _names; // String@, indexed by the NM_* constants below
    // What differs between an EXECUTABLE and a DYLIB, held rather than
    // branched on at forty sites. An executable has a __PAGEZERO, so __DATA is
    // segment 2 and its addresses carry VMBASE; a dylib has neither, so __DATA
    // is segment 1 and its addresses ARE its file offsets. And a dylib binds
    // FLAT: its imports may come from another xtc library whose LC_LOAD_DYLIB
    // lives on the client, so naming libSystem's ordinal sends dyld to the one
    // place the symbol is not.
    u32 _dataSegIdx;
    u32 _baseHi;
    bool _flatBind;
    Array* _deps; // MachODep@ — the dylibs this image loads

    void init(void)
        {
        _objcSects = (Array*)0;
        _out = new Array();
        _dataSegIdx = (u32)2;
        _baseHi = (u32)1;
        _flatBind = false;
        _deps = new Array();
        _platformId = (u32)1;
        _platformVer = (u32)11 << (u32)16;
        _names = new Array();
        _names.add((Object*)String.withCString("__PAGEZERO"));                 // 0
        _names.add((Object*)String.withCString("__TEXT"));                     // 1
        _names.add((Object*)String.withCString("__text"));                     // 2
        _names.add((Object*)String.withCString("__stubs"));                    // 3
        _names.add((Object*)String.withCString("__DATA"));                     // 4
        _names.add((Object*)String.withCString("__data"));                     // 5
        _names.add((Object*)String.withCString("__got"));                      // 6
        _names.add((Object*)String.withCString("__LINKEDIT"));                 // 7
        _names.add((Object*)String.withCString("/usr/lib/dyld"));              // 8
        _names.add((Object*)String.withCString("/usr/lib/libSystem.B.dylib")); // 9
        _names.add((Object*)String.withCString("xtc"));                        // 10
        _names.add((Object*)String.withCString("@loader_path"));               // 11
        _names.add((Object*)String.withCString("__mod_init_func"));            // 12 (bug 066)
        _names.add((Object*)String.withCString("__XTC"));                      // 13
        _names.add((Object*)String.withCString("__iface"));                    // 14
        }

    // The dylibs an EXECUTABLE links against. Set before executable(); empty
    // (the default) leaves the output exactly as it was, which is what lets
    // ld64-diff keep gating the ordinary path.
    void setDeps(Array* deps)
        {
        _deps = deps == (Array*)0 ? new Array() : deps;
        }

    // libSystem is ordinal 1 and each dep follows: 2, 3, … A symbol none of
    // them exports stays with libSystem, which is where the C runtime calls
    // live.
    u32 ordinalFor(String* sym)
        {
        for (u32 i = (u32)0; i < _deps.count(); i = i + (u32)1)
            if (inArray(((MachODep*)_deps.get(i)).syms(), sym))
                return (u32)2 + i;
        return (u32)1;
        }

    void setApplePlatform(String* p)
        {
        if (p.equals(String.withCString("ios")))
            {
            _platformId = (u32)2;
            _platformVer = (u32)15 << (u32)16;
            }
        else if (p.equals(String.withCString("ios-sim")))
            {
            _platformId = (u32)7;
            _platformVer = (u32)15 << (u32)16;
            }
        else
            {
            _platformId = (u32)1;
            _platformVer = (u32)11 << (u32)16;
            }
        }

    void putName(u32 idx, u32 width)
        {
        putFixed((String*)_names.get(idx), width);
        }
    String* name(u32 idx)
        {
        return (String*)_names.get(idx);
        }

    Array* bytes(void)
        {
        return _out;
        }

    // ── Byte emission ────────────────────────────────────────────────────
    void put8(u32 v)
        {
        _out.add((Object*)Number.withU32(v & (u32)$FF));
        }

    void put32(u32 v)
        {
        put8(v);
        put8(v >> (u32)8);
        put8(v >> (u32)16);
        put8(v >> (u32)24);
        }

    // A 64-bit little-endian field written as two halves.
    void put64(u32 lo, u32 hi)
        {
        put32(lo);
        put32(hi);
        }

    // A virtual address: VMBASE + the file offset. VMBASE is 0x1_0000_0000, so
    // an executable's high half is exactly 1 and the low half is the offset
    // unchanged. A DYLIB is based at 0 — the loader picks where it goes — so
    // its high half is 0 and the address IS the offset.
    void putAddr(u32 off)
        {
        put64(off, _baseHi);
        }

    void put32be(u32 v)
        {
        put8(v >> (u32)24);
        put8(v >> (u32)16);
        put8(v >> (u32)8);
        put8(v);
        }

    void put64be(u32 lo, u32 hi)
        {
        put32be(hi);
        put32be(lo);
        }

    void putFixed(String* s, u32 n)
        {
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            put8(i < s.byteLength() ? (u32)s.byteAt(i) : (u32)0);
        }

    void putULEB(u32 v)
        {
        while (true)
            {
            u32 b = v & (u32)$7F;
            v = v >> (u32)7;
            if (v != (u32)0)
                b = b | (u32)$80;
            put8(b);
            if (v == (u32)0)
                return;
            }
        }

    static u32 ulebLen(u32 v)
        {
        u32 n = (u32)1;
        while (v >= (u32)$80)
            {
            v = v >> (u32)7;
            n = n + (u32)1;
            }
        return n;
        }

    static u32 roundUp(u32 v, u32 a)
        {
        return (v + a - (u32)1) & ~(a - (u32)1);
        }

    void padTo(u32 off)
        {
        while (_out.count() < off)
            put8((u32)0);
        }

    // ── MH_OBJECT: the object `-c` writes ────────────────────────────────
    //
    // Separate compilation, arm64. One UNNAMED segment holding both sections —
    // the MH_OBJECT convention — plus a symbol table, a dysymtab that says
    // where the undefined run starts, and LC_BUILD_VERSION (without it `ld`
    // warns "no platform load command found, assuming: macOS"; it is assuming
    // correctly, but a real object says so).
    Array* objectFromText(Array* text, Array* data, Map* symbols, Array* dataSyms,
                          Array* fixups, Array* exports, Map* commons)
        {
        if (data == (Array*)0)
            data = new Array();
        if (commons == (Map*)0)
            commons = new Map();
        // [locals][externs][undefs], as LC_DYSYMTAB requires. `exports` (the
        // assembler's .globl set) decides which defined symbol is external;
        // null keeps everything external. A local is private to its object,
        // so two objects' `_str_N` literals no longer collide (bug 136).
        // Mirrors XTMachOWriter.objectFromText.

        // Sorted within each group so the file is reproducible: two builds of
        // one input must not differ because a map enumerated differently.
        Array* defText = new Array();
        Array* defData = new Array();
        Array* locText = new Array();
        Array* locData = new Array();
        Array* names = symbols.allKeys();
        MachO.sortNames(names);
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* n = (String*)names.get(i);
            if (n.hasPrefix(String.withCString("L")))
                continue; // assembler-local
            bool ext = exports == (Array*)0 || MachO.hasName(exports, n);
            if (MachO.hasName(dataSyms, n))
                {
                if (ext)
                    defData.add((Object*)n);
                else
                    locData.add((Object*)n);
                }
            else
                {
                if (ext)
                    defText.add((Object*)n);
                else
                    locText.add((Object*)n);
                }
            }
        u32 nLocals = locText.count() + locData.count();
        Array* undef = new Array();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            if (f.symbol() == (String*)0)
                continue;
            if (symbols.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            if (!MachO.hasName(undef, f.symbol()))
                undef.add((Object*)f.symbol());
            }
        // COMMON (`.comm`) symbols are external undefined-with-size — they sit
        // with the undefined externals whether or not this object references
        // them, so the linker sees the size and gives one shared slot (bug 169).
        Array* cks = commons.allKeys();
        for (u32 i = (u32)0; i < cks.count(); i = i + (u32)1)
            if (!MachO.hasName(undef, (String*)cks.get(i)))
                undef.add(cks.get(i));
        MachO.sortNames(undef);

        Array* order = new Array();
        for (u32 i = (u32)0; i < locText.count(); i = i + (u32)1)
            order.add(locText.get(i));
        for (u32 i = (u32)0; i < locData.count(); i = i + (u32)1)
            order.add(locData.get(i));
        for (u32 i = (u32)0; i < defText.count(); i = i + (u32)1)
            order.add(defText.get(i));
        for (u32 i = (u32)0; i < defData.count(); i = i + (u32)1)
            order.add(defData.get(i));
        for (u32 i = (u32)0; i < undef.count(); i = i + (u32)1)
            order.add(undef.get(i));
        Map* symIndex = new Map();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            symIndex.set((Hashable*)(String*)order.get(i), (Object*)Number.withU32(i));

        // Relocations, split by the section the fixup lives in. A Pointer64
        // fixup patches a `.quad sym` inside __data; every other kind patches
        // an instruction in __text.
        Array* textRel = new Array();
        Array* dataRel = new Array();
        u32 nTextRel = (u32)0;
        u32 nDataRel = (u32)0;
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            if (f.symbol() == (String*)0)
                continue;
            Object* si = symIndex.get((Hashable*)f.symbol());
            if (si == (Object*)0)
                continue; // nothing names it
            u32 kind = f.kind();
            u32 rt = (u32)0;
            u32 pcrel = (u32)0;
            u32 len = (u32)2;
            if (kind == (u32)FIXUP_BRANCH26)
                {
                rt = (u32)2;
                pcrel = (u32)1;
                }
            else if (kind == (u32)FIXUP_PAGE21)
                {
                rt = (u32)3;
                pcrel = (u32)1;
                }
            else if (kind == (u32)FIXUP_PAGEOFF12)
                {
                rt = (u32)4;
                pcrel = (u32)0;
                }
            else if (kind == (u32)FIXUP_GOTPAGE21)
                {
                rt = (u32)5;
                pcrel = (u32)1;
                }
            else if (kind == (u32)FIXUP_GOTPAGEOFF12)
                {
                rt = (u32)6;
                pcrel = (u32)0;
                }
            else if (kind == (u32)FIXUP_POINTER64)
                {
                rt = (u32)0;
                pcrel = (u32)0;
                len = (u32)3;
                }
            else
                continue;
            bool inData = kind == (u32)FIXUP_POINTER64;
            Array* into = inData ? dataRel : textRel;
            // An ARM64_RELOC_ADDEND must PRECEDE the pair it applies to, and
            // its "symbolnum" field carries the addend VALUE, not an index.
            if (f.addend() != (i32)0 && !inData)
                {
                MachO.put32In(into, f.offset());
                MachO.put32In(into, ((u32)10 << (u32)28) | ((u32)1 << (u32)27) | ((u32)2 << (u32)25) | ((u32)f.addend() & (u32)$FFFFFF));
                nTextRel = nTextRel + (u32)1;
                }
            MachO.put32In(into, f.offset());
            MachO.put32In(into, (rt << (u32)28) | ((u32)1 << (u32)27) | (len << (u32)25) | (pcrel << (u32)24) | (((Number*)si).asU32() & (u32)$FFFFFF));
            if (inData)
                nDataRel = nDataRel + (u32)1;
            else
                nTextRel = nTextRel + (u32)1;
            }

        u32 hdrSize = (u32)32;
        u32 segCmd = (u32)72 + (u32)80 * (u32)2;
        u32 symCmd = (u32)24;
        u32 dysymCmd = (u32)80;
        u32 buildCmd = (u32)24;
        u32 sizeofcmds = segCmd + symCmd + dysymCmd + buildCmd;
        u32 textOff = MachO.roundUp(hdrSize + sizeofcmds, (u32)16);
        u32 dataOff = MachO.roundUp(textOff + text.count(), (u32)16);
        u32 textRelOff = dataOff + data.count();
        u32 dataRelOff = textRelOff + textRel.count();
        u32 symOff = MachO.roundUp(dataRelOff + dataRel.count(), (u32)8);
        u32 strOff = symOff + order.count() * (u32)16;

        Array* strtab = new Array();
        strtab.add((Object*)Number.withU32((u32)0)); // index 0 is the empty string
        Array* strx = new Array();
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            strx.add((Object*)Number.withU32(strtab.count()));
            String* n = (String*)order.get(i);
            for (u32 k = (u32)0; k < n.byteLength(); k = k + (u32)1)
                strtab.add((Object*)Number.withU32((u32)n.byteAt(k)));
            strtab.add((Object*)Number.withU32((u32)0));
            }
        while ((strtab.count() & (u32)7) != (u32)0)
            strtab.add((Object*)Number.withU32((u32)0));

        _out = new Array();
        put32(MachO.MH_MAGIC_64());
        put32(MachO.CPU_TYPE_ARM64());
        put32((u32)0);
        put32((u32)1); // MH_OBJECT
        put32((u32)4); // ncmds
        put32(sizeofcmds);
        put32((u32)0);
        put32((u32)0);

        put32((u32)$19);
        put32(segCmd); // LC_SEGMENT_64
        putFixed(String.withCString(""), (u32)16);
        put64((u32)0, (u32)0);
        put64(text.count() + data.count(), (u32)0);
        put64(textOff, (u32)0);
        put64(text.count() + data.count(), (u32)0);
        put32((u32)7);
        put32((u32)7);
        put32((u32)2);
        put32((u32)0);

        putFixed(String.withCString("__text"), (u32)16);
        putFixed(String.withCString("__TEXT"), (u32)16);
        put64((u32)0, (u32)0);
        put64(text.count(), (u32)0);
        put32(textOff);
        put32((u32)2); // align 4
        put32(nTextRel != (u32)0 ? textRelOff : (u32)0);
        put32(nTextRel);
        put32((u32)$80000400); // PURE|SOME_INSTRUCTIONS
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);

        putFixed(String.withCString("__data"), (u32)16);
        putFixed(String.withCString("__DATA"), (u32)16);
        put64(text.count(), (u32)0);
        put64(data.count(), (u32)0);
        put32(data.count() != (u32)0 ? dataOff : (u32)0);
        put32((u32)3); // align 8
        put32(nDataRel != (u32)0 ? dataRelOff : (u32)0);
        put32(nDataRel);
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);

        put32((u32)2);
        put32(symCmd); // LC_SYMTAB
        put32(symOff);
        put32(order.count());
        put32(strOff);
        put32(strtab.count());

        put32((u32)$32);
        put32(buildCmd); // LC_BUILD_VERSION
        // Objects keep their historical macOS 14.0 stamp; an iOS platform set
        // by the caller overrides it, so the default output is unchanged.
        if (_platformId == (u32)1)
            {
            put32((u32)1);
            put32((u32)$000E0000);
            put32((u32)$000E0000);
            }
        else
            {
            put32(_platformId);
            put32(_platformVer);
            put32(_platformVer);
            }
        put32((u32)0); // ntools

        put32((u32)$B);
        put32(dysymCmd); // LC_DYSYMTAB
        put32((u32)0);
        put32(nLocals); // ilocalsym, nlocalsym
        put32(nLocals);
        put32(defText.count() + defData.count());
        put32(nLocals + defText.count() + defData.count());
        put32(undef.count());
        for (u32 i = (u32)0; i < (u32)12; i = i + (u32)1)
            put32((u32)0);

        padTo(textOff);
        for (u32 i = (u32)0; i < text.count(); i = i + (u32)1)
            put8(((Number*)text.get(i)).asU32());
        padTo(dataOff);
        for (u32 i = (u32)0; i < data.count(); i = i + (u32)1)
            put8(((Number*)data.get(i)).asU32());
        for (u32 i = (u32)0; i < textRel.count(); i = i + (u32)1)
            put8(((Number*)textRel.get(i)).asU32());
        for (u32 i = (u32)0; i < dataRel.count(); i = i + (u32)1)
            put8(((Number*)dataRel.get(i)).asU32());
        padTo(symOff);
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            String* n = (String*)order.get(i);
            Object* at = symbols.get((Hashable*)n);
            bool isUndef = at == (Object*)0;
            bool inData = MachO.hasName(dataSyms, n);
            bool isExt = exports == (Array*)0 || MachO.hasName(exports, n);
            Array* common = (Array*)commons.get((Hashable*)n); // [size, log2align] or 0
            put32(((Number*)strx.get(i)).asU32());
            put8(isUndef ? (u32)$01 : (isExt ? (u32)$0F : (u32)$0E)); // N_UNDF|N_EXT : N_SECT[|N_EXT]
            put8(isUndef ? (u32)0 : (inData ? (u32)2 : (u32)1));      // section, 1-based
            // A COMMON carries its alignment in n_desc (GET_COMM_ALIGN: log2
            // align in bits 8-11) and its SIZE in n_value; a plain undef zeroes.
            u32 desc = (common != (Array*)0) ? ((((Number*)common.get((u32)1)).asU32() & (u32)$0F) << (u32)8) : (u32)0;
            put8(desc & (u32)$FF);
            put8((desc >> (u32)8) & (u32)$FF); // n_desc
            u32 value = (u32)0;
            if (common != (Array*)0)
                {
                value = ((Number*)common.get((u32)0)).asU32();
                }
            else if (!isUndef)
                {
                value = ((Number*)at).asU32();
                // A __data symbol's value is an offset into the SEGMENT, and
                // __data follows __text in it.
                if (inData)
                    value = value + text.count();
                }
            put64(value, (u32)0);
            }
        for (u32 i = (u32)0; i < strtab.count(); i = i + (u32)1)
            put8(((Number*)strtab.get(i)).asU32());
        return _out;
        }

    static void put32In(Array* b, u32 v)
        {
        b.add((Object*)Number.withU32(v & (u32)$FF));
        b.add((Object*)Number.withU32((v >> (u32)8) & (u32)$FF));
        b.add((Object*)Number.withU32((v >> (u32)16) & (u32)$FF));
        b.add((Object*)Number.withU32((v >> (u32)24) & (u32)$FF));
        }

    static bool hasName(Array* a, String* n)
        {
        for (u32 i = (u32)0; a != (Array*)0 && i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(n))
                return true;
        return false;
        }

    // Insertion sort on the byte order of the name — what `compare:` gives,
    // and what makes the file reproducible.
    static void sortNames(Array* a)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            {
            Object* cur = a.get(i);
            u32 j = i;
            while (j > (u32)0 && ((String*)a.get(j - (u32)1)).compare((String*)cur) > (i32)0)
                {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
                }
            a.set(j, cur);
            }
        }

    // ── Mach-O constants ─────────────────────────────────────────────────
    //
    // Spelled here so the writer needs no system header — the whole point of
    // the exercise is that nothing outside this tree is consulted.
    static u32 MH_MAGIC_64(void)
        {
        return (u32)$FEEDFACF;
        }
    static u32 CPU_TYPE_ARM64(void)
        {
        return (u32)$0100000C;
        }
    static u32 VM_READ(void)
        {
        return (u32)1;
        }
    static u32 VM_WRITE(void)
        {
        return (u32)2;
        }
    static u32 VM_EXEC(void)
        {
        return (u32)4;
        }

    // ── The executable ───────────────────────────────────────────────────
    //
    // `text`, `data`, `symbols`, `dataSyms` and `fixups` are exactly what the
    // assembler produced. A Branch26 fixup whose target is not a defined
    // symbol becomes a libSystem import: a __stubs entry jumping through a
    // __got slot, bound at load by the LC_DYLD_INFO bind stream.
    Array* _imports;   // String@
    Map* _importIndex; // name -> index
    Array* _dataBinds; // Arm64Fixup@ — undefined-symbol __data slots (finding #7)
    // Bug 069 / 138: the ObjC metadata sections carved out of the data blob
    // by the linker's repartition (MachOObjcRange@, FINAL blob coordinates).
    // Each gets its own section header inside __DATA, name and flags carried
    // from the input object, so the runtime finds its metadata by section
    // identity. Empty for a link with no ObjC content — nothing changes.
    Array* _objcSects;

    void executable(Array* text, u32 entryOffset, Map* symbols,
                    Array* data, Array* dataSyms, Array* fixups)
        {
        executable(text, entryOffset, symbols, data, dataSyms, fixups, (u32)0, (Array*)0);
        }
    void executable(Array* text, u32 entryOffset, Map* symbols,
                    Array* data, Array* dataSyms, Array* fixups, u32 modInitLength)
        {
        executable(text, entryOffset, symbols, data, dataSyms, fixups, modInitLength, (Array*)0);
        }
    u32 objcSectCount(void)
        {
        return _objcSects == (Array*)0 ? (u32)0 : _objcSects.count();
        }
    // The ObjC sections sit between the ordinary data and the mod-init tail,
    // so __data ends where the first of them begins.
    u32 dataOnlyBefore(u32 dOnly)
        {
        for (u32 i = (u32)0; _objcSects != (Array*)0 && i < _objcSects.count(); i = i + (u32)1)
            {
            MachOObjcRange* r = (MachOObjcRange*)_objcSects.get(i);
            if (r.off() < dOnly)
                dOnly = r.off();
            }
        return dOnly;
        }
    // One section header per ObjC section, emitted inside __DATA's span
    // (the blob lives there; the runtime keys on the section NAME).
    // `base` is the address of blob offset 0 for this image kind.
    void putObjcSects(u64 base, u32 dataProgOffset, bool addr)
        {
        for (u32 i = (u32)0; _objcSects != (Array*)0 && i < _objcSects.count(); i = i + (u32)1)
            {
            MachOObjcRange* r = (MachOObjcRange*)_objcSects.get(i);
            putFixed(r.name(), (u32)16);
            putName((u32)4, (u32)16); // name, __DATA
            if (addr)
                putAddr(dataProgOffset + r.off());
            else
                put64(dataProgOffset + r.off(), (u32)0);
            put64(r.size(), (u32)0);
            put32(dataProgOffset + r.off());
            put32((u32)3);
            put32((u32)0);
            put32((u32)0);
            put32(r.flags());
            put32((u32)0);
            put32((u32)0);
            put32((u32)0);
            }
        }

    // `modInitLength` is how many bytes at the END of `data` are the
    // __mod_init_func pointer array (bug 066). They get their own
    // S_MOD_INIT_FUNC_POINTERS section: the bytes and addresses do not move,
    // but without that section type dyld treats them as inert data and no
    // load-time constructor ever runs.
    void executable(Array* text, u32 entryOffset, Map* symbols,
                    Array* data, Array* dataSyms, Array* fixups, u32 modInitLength,
                    Array* objcSects)
        {
        _objcSects = objcSects;
        bool hasData = data.count() > (u32)0;
        u32 miLen = modInitLength <= data.count() ? modInitLength : (u32)0;
        u32 dOnly = dataOnlyBefore(data.count() - miLen);
        bool hasModInit = miLen > (u32)0;
        bool hasDataSect = dOnly > (u32)0;

        // 1. Imports — the calls this image cannot resolve itself.
        _imports = new Array();
        _importIndex = new Map();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            // A pointer slot in __data holding an UNDEFINED symbol's address
            // needs an import too — it binds in place (finding #7; the slot
            // used to link as null with no diagnostic).
            bool wants = f.kind() == (u32)FIXUP_BRANCH26 || f.kind() == (u32)FIXUP_GOTPAGE21 || f.kind() == (u32)FIXUP_GOTPAGEOFF12 || f.kind() == (u32)FIXUP_POINTER64;
            if (!wants)
                continue;
            if (symbols.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            if (_importIndex.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            _importIndex.set((Hashable*)f.symbol(), (Object*)Number.withU32(_imports.count()));
            _imports.add((Object*)f.symbol());
            }
        u32 nimp = _imports.count();
        bool hasImp = nimp > (u32)0;
        bool hasDataSeg = hasData || hasImp;

        // 2. Layout. The vmaddr of everything is VMBASE + its file offset, so
        //    a single set of offsets describes both.
        u32 textOffset = (u32)MACHO_PAGE; // header slack for the signature
        u32 stubsOffset = roundUp(textOffset + text.count(), (u32)4);
        u32 stubsSize = nimp * (u32)STUB_SZ;
        u32 textSegEnd = roundUp(stubsOffset + stubsSize, (u32)MACHO_PAGE);
        u32 dataSegFileOff = textSegEnd;
        u32 dataProgOffset = dataSegFileOff;
        u32 gotOffset = roundUp(dataProgOffset + (hasData ? data.count() : (u32)0), (u32)8);
        u32 gotSize = nimp * (u32)GOT_SZ;
        u32 dataSegEnd = hasDataSeg ? roundUp(gotOffset + gotSize, (u32)MACHO_PAGE) : textSegEnd;
        u32 gotOffInSeg = gotOffset - dataSegFileOff;
        u32 linkeditOff = dataSegEnd;

        // 3. Patch the fixups. Both the target and the reference site carry the
        //    same VMBASE, so page deltas cancel it and this is all 32-bit.
        Array* txt = copyBytes(text);
        Array* dat = copyBytes(data);
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            bool defined = symbols.get((Hashable*)f.symbol()) != (Object*)0;
            u32 site = textOffset + f.offset();
            if (f.kind() == (u32)FIXUP_BRANCH26 && !defined)
                {
                u32 idx = ((Number*)_importIndex.get((Hashable*)f.symbol())).asU32();
                u32 stub = stubsOffset + idx * (u32)STUB_SZ;
                i32 rel = ((i32)stub - (i32)site) >> (i32)2;
                wrw(txt, f.offset(), (rdw(txt, f.offset()) & (u32)$FC000000) | ((u32)rel & (u32)$03FFFFFF));
                }
            else if (f.kind() == (u32)FIXUP_BRANCH26)
                {
                u32 s = symOffset(symbols, dataSyms, f.symbol(), textOffset, dataProgOffset);
                i32 rel = (((i32)s + f.addend()) - (i32)site) >> (i32)2;
                wrw(txt, f.offset(), (rdw(txt, f.offset()) & (u32)$FC000000) | ((u32)rel & (u32)$03FFFFFF));
                }
            else if (f.kind() == (u32)FIXUP_PAGE21 && defined)
                {
                u32 s = symOffset(symbols, dataSyms, f.symbol(), textOffset, dataProgOffset) + (u32)f.addend();
                patchAdrp(txt, f.offset(), s, site);
                }
            else if (f.kind() == (u32)FIXUP_PAGEOFF12 && defined)
                {
                u32 s = symOffset(symbols, dataSyms, f.symbol(), textOffset, dataProgOffset) + (u32)f.addend();
                u32 imm12 = (s & (u32)$FFF) >> f.scale();
                wrw(txt, f.offset(), (rdw(txt, f.offset()) & ~((u32)$FFF << (u32)10)) | (imm12 << (u32)10));
                }
            else if (f.kind() == (u32)FIXUP_GOTPAGE21 && !defined)
                {
                u32 slot = gotOffset + ((Number*)_importIndex.get((Hashable*)f.symbol())).asU32() * (u32)GOT_SZ;
                patchAdrp(txt, f.offset(), slot, site);
                }
            else if (f.kind() == (u32)FIXUP_GOTPAGEOFF12 && !defined)
                {
                u32 slot = gotOffset + ((Number*)_importIndex.get((Hashable*)f.symbol())).asU32() * (u32)GOT_SZ;
                wrw(txt, f.offset(), (rdw(txt, f.offset()) & ~((u32)$FFF << (u32)10)) | (((slot & (u32)$FFF) >> (u32)3) << (u32)10));
                }
            }

        // 3b. `.quad <symbol>` slots in __data hold an UNSLID address; dyld
        //     adds the slide, which is what the rebase stream asks it to do.
        //     An UNDEFINED symbol's slot stays zero and gets a dyld BIND
        //     instead (finding #7) — dyld writes the address at load.
        Array* rebaseOffs = new Array();
        _dataBinds = new Array();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            if (f.kind() != (u32)FIXUP_POINTER64)
                continue;
            if (symbols.get((Hashable*)f.symbol()) == (Object*)0)
                {
                if (_importIndex.get((Hashable*)f.symbol()) != (Object*)0)
                    _dataBinds.add((Object*)f);
                continue;
                }
            u32 s = symOffset(symbols, dataSyms, f.symbol(), textOffset, dataProgOffset) + (u32)f.addend();
            for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
                dat.set(f.offset() + b, (Object*)Number.withU32((s >> ((u32)8 * b)) & (u32)$FF));
            dat.set(f.offset() + (u32)4, (Object*)Number.withU32((u32)1)); // VMBASE high half
            for (u32 b = (u32)5; b < (u32)8; b = b + (u32)1)
                dat.set(f.offset() + b, (Object*)Number.withU32((u32)0));
            rebaseOffs.add((Object*)Number.withU32(f.offset()));
            }
        bool hasRebase = rebaseOffs.count() > (u32)0;
        sortNumbers(rebaseOffs);
        sortBindsByOffset(_dataBinds);

        MachOLayout* L = new MachOLayout();
        L.textOffset = textOffset;
        L.stubsOffset = stubsOffset;
        L.stubsSize = stubsSize;
        L.textSegEnd = textSegEnd;
        L.dataSegFileOff = dataSegFileOff;
        L.dataProgOffset = dataProgOffset;
        L.gotOffset = gotOffset;
        L.gotSize = gotSize;
        L.dataSegEnd = dataSegEnd;
        L.gotOffInSeg = gotOffInSeg;
        L.linkeditOff = linkeditOff;
        L.entryOffset = entryOffset;
        L.hasData = hasData;
        L.hasImp = hasImp;
        L.hasModInit = hasModInit;
        L.hasDataSect = hasDataSect;
        L.miLen = miLen;
        L.dOnly = dOnly;
        L.hasDataSeg = hasDataSeg;
        L.hasRebase = hasRebase;
        buildImage(txt, dat, symbols, dataSyms, rebaseOffs, L);
        }

    // ── The DYLIB ────────────────────────────────────────────────────────
    //
    // The same image as an executable with four differences that matter, and
    // one that is the whole point:
    //   * based at 0, not VMBASE, and with no __PAGEZERO — so __DATA is
    //     segment 1 and every address IS its file offset;
    //   * MH_DYLIB with LC_ID_DYLIB in place of LC_MAIN — no entry point;
    //   * FLAT binds, because an import may come from another xtc library
    //     whose LC_LOAD_DYLIB lives on the client, not here;
    //   * an optional read-only `__XTC,__iface` section carrying the module
    //     interface, so `#import <X>` reads the types out of the binary
    //     rather than a side file that can go missing.
    // …and the point: an EXPORT TRIE. dyld resolves a client's import by
    // walking it, so a name missing from it does not exist however many nlist
    // entries mention it.
    void dylib(Array* text, String* installName, Array* exports, Array* iface,
               Map* symbols, Array* data, Array* dataSyms, Array* fixups,
               u32 modInitLength)
        {
        dylib(text, installName, exports, iface, symbols, data, dataSyms, fixups,
              modInitLength, (Array*)0);
        }
    void dylib(Array* text, String* installName, Array* exports, Array* iface,
               Map* symbols, Array* data, Array* dataSyms, Array* fixups,
               u32 modInitLength, Array* objcSects)
        {
        _objcSects = objcSects;
        _dataSegIdx = (u32)1; // no __PAGEZERO: __TEXT=0, __DATA=1
        _baseHi = (u32)0;     // based at 0; the loader slides it
        _flatBind = true;

        bool hasData = data.count() > (u32)0;
        u32 miLen = modInitLength <= data.count() ? modInitLength : (u32)0;
        u32 dOnly = dataOnlyBefore(data.count() - miLen);
        bool hasModInit = miLen > (u32)0;
        bool hasDataSect = dOnly > (u32)0;
        bool hasIface = iface != (Array*)0 && iface.count() > (u32)0;

        // 1. Imports — identical rule to the executable's.
        _imports = new Array();
        _importIndex = new Map();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            bool wants = f.kind() == (u32)FIXUP_BRANCH26 || f.kind() == (u32)FIXUP_GOTPAGE21 || f.kind() == (u32)FIXUP_GOTPAGEOFF12 || f.kind() == (u32)FIXUP_POINTER64;
            if (!wants)
                continue;
            if (symbols.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            if (_importIndex.get((Hashable*)f.symbol()) != (Object*)0)
                continue;
            _importIndex.set((Hashable*)f.symbol(), (Object*)Number.withU32(_imports.count()));
            _imports.add((Object*)f.symbol());
            }
        u32 nimp = _imports.count();
        bool hasImp = nimp > (u32)0;
        bool hasDataSeg = hasData || hasImp;

        // 2. Layout — base 0, so vmaddr == file offset throughout.
        u32 textOffset = (u32)MACHO_PAGE;
        u32 stubsOffset = roundUp(textOffset + text.count(), (u32)4);
        u32 stubsSize = nimp * (u32)STUB_SZ;
        u32 textSegEnd = roundUp(stubsOffset + stubsSize, (u32)MACHO_PAGE);
        u32 dataSegFileOff = textSegEnd;
        u32 dataProgOffset = dataSegFileOff;
        u32 gotOffset = roundUp(dataProgOffset + (hasData ? data.count() : (u32)0), (u32)8);
        u32 gotSize = nimp * (u32)GOT_SZ;
        u32 dataSegEnd = hasDataSeg ? roundUp(gotOffset + gotSize, (u32)MACHO_PAGE) : textSegEnd;
        u32 gotOffInSeg = gotOffset - dataSegFileOff;
        u32 xtcSegFileOff = dataSegEnd;
        u32 xtcSegEnd = hasIface ? roundUp(xtcSegFileOff + iface.count(), (u32)MACHO_PAGE)
                                 : dataSegEnd;
        u32 linkeditOff = xtcSegEnd;

        // 3. Patch the fixups — the same maths as the executable, base 0.
        Array* txt = copyBytes(text);
        Array* dat = copyBytes(data);
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            bool defined = symbols.get((Hashable*)f.symbol()) != (Object*)0;
            u32 site = textOffset + f.offset();
            if (f.kind() == (u32)FIXUP_BRANCH26 && !defined)
                {
                u32 idx = ((Number*)_importIndex.get((Hashable*)f.symbol())).asU32();
                u32 stub = stubsOffset + idx * (u32)STUB_SZ;
                i32 rel = ((i32)stub - (i32)site) >> (i32)2;
                wrw(txt, f.offset(), (rdw(txt, f.offset()) & (u32)$FC000000) | ((u32)rel & (u32)$03FFFFFF));
                }
            else if (f.kind() == (u32)FIXUP_BRANCH26)
                {
                u32 s = symOffset(symbols, dataSyms, f.symbol(), textOffset, dataProgOffset);
                i32 rel = (((i32)s + f.addend()) - (i32)site) >> (i32)2;
                wrw(txt, f.offset(), (rdw(txt, f.offset()) & (u32)$FC000000) | ((u32)rel & (u32)$03FFFFFF));
                }
            else if (f.kind() == (u32)FIXUP_PAGE21 && defined)
                {
                u32 s = symOffset(symbols, dataSyms, f.symbol(), textOffset, dataProgOffset) + (u32)f.addend();
                patchAdrp(txt, f.offset(), s, site);
                }
            else if (f.kind() == (u32)FIXUP_PAGEOFF12 && defined)
                {
                u32 s = symOffset(symbols, dataSyms, f.symbol(), textOffset, dataProgOffset) + (u32)f.addend();
                u32 imm12 = (s & (u32)$FFF) >> f.scale();
                wrw(txt, f.offset(), (rdw(txt, f.offset()) & ~((u32)$FFF << (u32)10)) | (imm12 << (u32)10));
                }
            else if (f.kind() == (u32)FIXUP_GOTPAGE21 && !defined)
                {
                u32 slot = gotOffset + ((Number*)_importIndex.get((Hashable*)f.symbol())).asU32() * (u32)GOT_SZ;
                patchAdrp(txt, f.offset(), slot, site);
                }
            else if (f.kind() == (u32)FIXUP_GOTPAGEOFF12 && !defined)
                {
                u32 slot = gotOffset + ((Number*)_importIndex.get((Hashable*)f.symbol())).asU32() * (u32)GOT_SZ;
                wrw(txt, f.offset(), (rdw(txt, f.offset()) & ~((u32)$FFF << (u32)10)) | (((slot & (u32)$FFF) >> (u32)3) << (u32)10));
                }
            }

        // 3b. `.quad <symbol>` slots: a DEFINED symbol's address is written and
        //     rebased; an undefined one stays zero and gets a bind.
        Array* rebaseOffs = new Array();
        _dataBinds = new Array();
        for (u32 i = (u32)0; i < fixups.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)fixups.get(i);
            if (f.kind() != (u32)FIXUP_POINTER64)
                continue;
            if (symbols.get((Hashable*)f.symbol()) == (Object*)0)
                {
                if (_importIndex.get((Hashable*)f.symbol()) != (Object*)0)
                    _dataBinds.add((Object*)f);
                continue;
                }
            u32 s = symOffset(symbols, dataSyms, f.symbol(), textOffset, dataProgOffset);
            for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
                dat.set(f.offset() + b, (Object*)Number.withU32(b < (u32)4
                                                                    ? ((s >> ((u32)8 * b)) & (u32)$FF)
                                                                    : (u32)0));
            rebaseOffs.add((Object*)Number.withU32(f.offset()));
            }
        bool hasRebase = rebaseOffs.count() > (u32)0;
        sortNumbers(rebaseOffs);
        sortBindsByOffset(_dataBinds);

        // 4. __LINKEDIT: rebase | bind | export trie | nlist | indirect | strtab
        Array* rebase = buildRebase(rebaseOffs, hasRebase);
        Array* bind = buildBind(gotOffInSeg, hasImp);

        Array* defNames = sortedByOffsetThenName(symbols);
        Array* locals = new Array();
        Array* externs = new Array();
        for (u32 i = (u32)0; i < defNames.count(); i = i + (u32)1)
            {
            String* nm = (String*)defNames.get(i);
            if (inArray(exports, nm))
                externs.add((Object*)nm);
            else
                locals.add((Object*)nm);
            }
        Array* strtab = new Array();
        Array* nlist = new Array();
        Array* indirect = new Array();
        dylibSymbolTables(symbols, dataSyms, locals, externs, exports,
                          strtab, nlist, indirect, textOffset, dataProgOffset, hasImp);

        Array* expNames = new Array();
        Array* expAddrs = new Array();
        for (u32 i = (u32)0; i < externs.count(); i = i + (u32)1)
            {
            String* nm = (String*)externs.get(i);
            expNames.add((Object*)nm);
            expAddrs.add((Object*)Number.withU32(
                symOffset(symbols, dataSyms, nm, textOffset, dataProgOffset)));
            }
        Array* trie = ExportTrie.build(expNames, expAddrs);
        bool hasExport = trie.count() > (u32)0;
        // 8-aligned so the symbol table that follows it is aligned.
        while ((trie.count() & (u32)7) != (u32)0)
            trie.add((Object*)Number.withU32((u32)0));

        u32 nloc = locals.count();
        u32 nexp = externs.count();
        u32 nsyms = defNames.count() + nimp;

        u32 rebaseOff = linkeditOff;
        u32 bindOff = rebaseOff + rebase.count();
        u32 exportOff = bindOff + bind.count();
        u32 symoff = exportOff + trie.count();
        u32 indOff = symoff + nlist.count();
        u32 stroff = indOff + indirect.count();
        // LC_SYMTAB states the PADDED size — the padding is part of the table
        // as far as the loader is concerned, and stating the unpadded length
        // leaves the last few names outside what dyld will read.
        u32 strsize = roundUp(strtab.count(), (u32)8);
        while (strtab.count() < strsize)
            strtab.add((Object*)Number.withU32((u32)0));

        String* sigIdent = installName.lastPathComponent();
        if (sigIdent == (String*)0 || sigIdent.byteLength() == (u32)0)
            sigIdent = String.withCString("xtclib");
        u32 sigOffset = roundUp(stroff + strsize, (u32)16);
        u32 nCodeSlots = (sigOffset + (u32)4095) / (u32)4096;
        u32 sigSize = (u32)12 + (u32)8 + (u32)88 + sigIdent.byteLength() + (u32)1 + nCodeSlots * (u32)32;
        // The signature must be the file's LAST bytes (iOS/codesign reject
        // trailing bytes; macOS load tolerates them — bug 148). Exact
        // filesize, page-rounded vmsize (in-memory only).
        u32 linkeditFilesz = (sigOffset + sigSize) - linkeditOff;
        u32 linkeditVmsz = roundUp(linkeditFilesz, (u32)MACHO_PAGE);

        // 5. Command sizes.
        u32 nDataSects = (hasDataSect ? (u32)1 : (u32)0) + (hasModInit ? (u32)1 : (u32)0) + (hasImp ? (u32)1 : (u32)0) + objcSectCount(); // bug 069
        u32 szTextSeg = (u32)72 + (u32)80 * ((u32)1 + (hasImp ? (u32)1 : (u32)0));
        u32 szDataSeg = (u32)72 + (u32)80 * nDataSects;
        u32 szXtcSeg = (u32)72 + (u32)80;
        u32 szLink = (u32)72;
        u32 szDyldInfo = (u32)48;
        u32 szDyld = roundUp((u32)12 + name((u32)8).byteLength() + (u32)1, (u32)8);
        u32 szId = roundUp((u32)24 + installName.byteLength() + (u32)1, (u32)8);
        u32 szDylib = roundUp((u32)24 + name((u32)9).byteLength() + (u32)1, (u32)8);
        u32 szSym = (u32)24;
        u32 szDysym = (u32)80;
        u32 szBuild = (u32)24;
        u32 szUUID = (u32)24;
        u32 szCodeSig = (u32)16;
        bool hasDyldInfo = hasImp || hasRebase || hasExport;
        u32 ncmds = (u32)1 + (hasDataSeg ? (u32)1 : (u32)0) + (hasIface ? (u32)1 : (u32)0) + (u32)1 + (hasDyldInfo ? (u32)1 : (u32)0) + (u32)1 + (u32)1 + (u32)1 + (u32)1 + (u32)1 + (u32)1 + (u32)1 + (u32)1;
        u32 sizeofcmds = szTextSeg + (hasDataSeg ? szDataSeg : (u32)0) + (hasIface ? szXtcSeg : (u32)0) + szLink + (hasDyldInfo ? szDyldInfo : (u32)0) + szDyld + szId + szDylib + szSym + szDysym + szBuild + szUUID + szCodeSig;

        // 6. Header and commands. A segment_command_64 is cmd, cmdsize,
        //    segname[16], vmaddr, vmsize, fileoff, filesize, maxprot,
        //    initprot, nsects, flags; a section_64 is sectname[16],
        //    segname[16], addr, size, offset, align, reloff, nreloc, flags,
        //    reserved1..3. Written out longhand, in that order, because a
        //    field written in the wrong place produces a file that loads
        //    until something reads the field that moved.
        put32(MachO.MH_MAGIC_64());
        put32(MachO.CPU_TYPE_ARM64());
        put32((u32)0);
        put32((u32)6); // MH_DYLIB
        put32(ncmds);
        put32(sizeofcmds);
        put32((u32)4 | (u32)$80); // MH_DYLDLINK | MH_TWOLEVEL
        put32((u32)0);

        // __TEXT (+ __text [+ __stubs])
        put32((u32)$19);
        put32(szTextSeg);
        putName((u32)1, (u32)16);
        put64((u32)0, (u32)0);
        put64(textSegEnd, (u32)0); // vmaddr, vmsize
        put64((u32)0, (u32)0);
        put64(textSegEnd, (u32)0); // fileoff, filesize
        put32(MachO.VM_READ() | MachO.VM_EXEC());
        put32(MachO.VM_READ() | MachO.VM_EXEC());
        put32(hasImp ? (u32)2 : (u32)1);
        put32((u32)0);
        putName((u32)2, (u32)16);
        putName((u32)1, (u32)16); // __text, __TEXT
        put64(textOffset, (u32)0);
        put64(txt.count(), (u32)0);
        put32(textOffset);
        put32((u32)2);
        put32((u32)0);
        put32((u32)0);
        put32((u32)$80000400); // PURE|SOME_INSTR
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);
        if (hasImp)
            {
            putName((u32)3, (u32)16);
            putName((u32)1, (u32)16); // __stubs, __TEXT
            put64(stubsOffset, (u32)0);
            put64(stubsSize, (u32)0);
            put32(stubsOffset);
            put32((u32)2);
            put32((u32)0);
            put32((u32)0);
            put32((u32)$80000400);
            put32((u32)0);
            put32((u32)0);
            put32((u32)0);
            }
        // __DATA (+ __data [+ __mod_init_func] [+ __got])
        if (hasDataSeg)
            {
            u32 segSz = dataSegEnd - dataSegFileOff;
            put32((u32)$19);
            put32(szDataSeg);
            putName((u32)4, (u32)16);
            put64(dataSegFileOff, (u32)0);
            put64(segSz, (u32)0);
            put64(dataSegFileOff, (u32)0);
            put64(segSz, (u32)0);
            put32(MachO.VM_READ() | MachO.VM_WRITE());
            put32(MachO.VM_READ() | MachO.VM_WRITE());
            put32(nDataSects);
            put32((u32)0);
            if (hasDataSect)
                {
                putName((u32)5, (u32)16);
                putName((u32)4, (u32)16); // __data, __DATA
                put64(dataProgOffset, (u32)0);
                put64(dOnly, (u32)0);
                put32(dataProgOffset);
                put32((u32)3);
                put32((u32)0);
                put32((u32)0);
                put32((u32)0); // S_REGULAR
                put32((u32)0);
                put32((u32)0);
                put32((u32)0);
                }
            putObjcSects((u64)0, dataProgOffset, false); // bug 069
            // Bug 066: a LIBRARY's load-time constructors. Nothing can call a
            // library's copy of the runner, so this section is the only way
            // they run at all.
            if (hasModInit)
                {
                putName((u32)12, (u32)16);
                putName((u32)4, (u32)16);
                put64(dataProgOffset + dOnly, (u32)0);
                put64(miLen, (u32)0);
                put32(dataProgOffset + dOnly);
                put32((u32)3);
                put32((u32)0);
                put32((u32)0);
                put32((u32)9); // S_MOD_INIT_FUNC_POINTERS
                put32((u32)0);
                put32((u32)0);
                put32((u32)0);
                }
            if (hasImp)
                {
                putName((u32)6, (u32)16);
                putName((u32)4, (u32)16); // __got, __DATA
                put64(gotOffset, (u32)0);
                put64(gotSize, (u32)0);
                put32(gotOffset);
                put32((u32)3);
                put32((u32)0);
                put32((u32)0);
                put32((u32)6); // S_NON_LAZY_SYMBOL_POINTERS
                put32((u32)0);
                put32((u32)0);
                put32((u32)0);
                }
            }
        // __XTC,__iface — the module interface, read-only.
        if (hasIface)
            {
            u32 segSz = xtcSegEnd - xtcSegFileOff;
            put32((u32)$19);
            put32(szXtcSeg);
            putName((u32)13, (u32)16);
            put64(xtcSegFileOff, (u32)0);
            put64(segSz, (u32)0);
            put64(xtcSegFileOff, (u32)0);
            put64(segSz, (u32)0);
            put32(MachO.VM_READ());
            put32(MachO.VM_READ());
            put32((u32)1);
            put32((u32)0);
            putName((u32)14, (u32)16);
            putName((u32)13, (u32)16);
            put64(xtcSegFileOff, (u32)0);
            put64(iface.count(), (u32)0);
            put32(xtcSegFileOff);
            put32((u32)0);
            put32((u32)0);
            put32((u32)0);
            put32((u32)0); // S_REGULAR
            put32((u32)0);
            put32((u32)0);
            put32((u32)0);
            }
        // __LINKEDIT
        put32((u32)$19);
        put32(szLink);
        putName((u32)7, (u32)16);
        put64(linkeditOff, (u32)0);
        put64(linkeditVmsz, (u32)0);
        put64(linkeditOff, (u32)0);
        put64(linkeditFilesz, (u32)0);
        put32(MachO.VM_READ());
        put32(MachO.VM_READ());
        put32((u32)0);
        put32((u32)0);
        if (hasDyldInfo)
            {
            put32((u32)$80000022);
            put32(szDyldInfo); // LC_DYLD_INFO_ONLY
            put32(hasRebase ? rebaseOff : (u32)0);
            put32(rebase.count());
            put32(hasImp ? bindOff : (u32)0);
            put32(bind.count());
            put32((u32)0);
            put32((u32)0); // weak bind
            put32((u32)0);
            put32((u32)0); // lazy bind
            put32(hasExport ? exportOff : (u32)0);
            put32(trie.count());
            }
        put32((u32)$0E);
        put32(szDyld);
        put32((u32)12); // LC_LOAD_DYLINKER
        putFixed(name((u32)8), szDyld - (u32)12);
        put32((u32)$0D);
        put32(szId);
        put32((u32)24); // LC_ID_DYLIB
        put32((u32)1);
        put32((u32)$10000);
        put32((u32)$10000);
        putFixed(installName, szId - (u32)24);
        put32((u32)$0C);
        put32(szDylib);
        put32((u32)24); // LC_LOAD_DYLIB
        put32((u32)2);
        put32((u32)$510000);
        put32((u32)$10000);
        putFixed(name((u32)9), szDylib - (u32)24);
        put32((u32)2);
        put32(szSym); // LC_SYMTAB
        put32(symoff);
        put32(nsyms);
        put32(stroff);
        put32(strsize);
        put32((u32)$0B);
        put32(szDysym); // LC_DYSYMTAB
        put32((u32)0);
        put32(nloc);
        put32(nloc);
        put32(nexp);
        put32(nloc + nexp);
        put32(nimp);
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);
        put32(hasImp ? indOff : (u32)0);
        put32(nimp);
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);
        put32((u32)$32);
        put32(szBuild); // LC_BUILD_VERSION
        put32(_platformId);
        put32(_platformVer);
        put32(_platformVer);
        put32((u32)0);
        put32((u32)$1B);
        put32(szUUID); // LC_UUID
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            put8((u32)0);
        put32((u32)$1D);
        put32(szCodeSig); // LC_CODE_SIGNATURE
        put32(sigOffset);
        put32(sigSize);

        // 7. The body.
        padTo(textOffset);
        appendAll(txt);
        padTo(stubsOffset);
        for (u32 i = (u32)0; i < nimp; i = i + (u32)1)
            emitStub(stubsOffset + i * (u32)STUB_SZ, gotOffset + i * (u32)GOT_SZ);
        if (hasData)
            {
            padTo(dataProgOffset);
            appendAll(dat);
            }
        if (hasImp)
            {
            padTo(gotOffset);
            for (u32 i = (u32)0; i < gotSize; i = i + (u32)1)
                put8((u32)0);
            }
        if (hasIface)
            {
            padTo(xtcSegFileOff);
            appendAll(iface);
            }
        padTo(linkeditOff);
        appendAll(rebase);
        appendAll(bind);
        appendAll(trie);
        appendAll(nlist);
        appendAll(indirect);
        appendAll(strtab);
        padTo(sigOffset);
        appendAll(adhocSignature(sigOffset, sigIdent, textSegEnd));
        padTo(linkeditOff + linkeditFilesz);
        }

    // A dylib's symbol table: [locals][exported externs][undefined imports].
    // Three things differ from the executable's — an exported name carries
    // N_EXT, an address is base-0, and an import's library ordinal is
    // DYNAMIC_LOOKUP (0xFE) rather than libSystem's 1, which is the nlist half
    // of the flat binding the bind stream asks for.
    void dylibSymbolTables(Map* symbols, Array* dataSyms, Array* locals,
                           Array* externs, Array* exports, Array* strtab,
                           Array* nlist, Array* indirect,
                           u32 textOffset, u32 dataProgOffset, bool hasImp)
        {
        strtab.add((Object*)Number.withU32((u32)0));
        u32 dataSect = (u32)1 + (hasImp ? (u32)1 : (u32)0) + (u32)1;
        for (u32 pass = (u32)0; pass < (u32)2; pass = pass + (u32)1)
            {
            Array* list = pass == (u32)0 ? locals : externs;
            for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
                {
                String* nm = (String*)list.get(i);
                u32 strx = strtab.count();
                strInto(strtab, nm);
                u32Into(nlist, strx);
                nlist.add((Object*)Number.withU32(
                    (u32)$0E | (inArray(exports, nm) ? (u32)$01 : (u32)0))); // N_SECT [| N_EXT]
                nlist.add((Object*)Number.withU32(inArray(dataSyms, nm) ? dataSect : (u32)1));
                nlist.add((Object*)Number.withU32((u32)0));
                nlist.add((Object*)Number.withU32((u32)0));
                u32Into(nlist, symOffset(symbols, dataSyms, nm, textOffset, dataProgOffset));
                u32Into(nlist, (u32)0); // base 0
                }
            }
        for (u32 i = (u32)0; i < _imports.count(); i = i + (u32)1)
            {
            u32 strx = strtab.count();
            strInto(strtab, (String*)_imports.get(i));
            u32Into(nlist, strx);
            nlist.add((Object*)Number.withU32((u32)$01)); // N_UNDF | N_EXT
            nlist.add((Object*)Number.withU32((u32)0));
            nlist.add((Object*)Number.withU32((u32)0));
            nlist.add((Object*)Number.withU32((u32)$FE)); // DYNAMIC_LOOKUP
            u32Into(nlist, (u32)0);
            u32Into(nlist, (u32)0);
            }
        u32 ndef = locals.count() + externs.count();
        for (u32 i = (u32)0; i < _imports.count(); i = i + (u32)1)
            u32Into(indirect, ndef + i);
        }

    static Array* copyBytes(Array* a)
        {
        Array* o = new Array();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            o.add(a.get(i));
        return o;
        }

    static u32 rdw(Array* b, u32 o)
        {
        return ((Number*)b.get(o)).asU32() | (((Number*)b.get(o + (u32)1)).asU32() << (u32)8) | (((Number*)b.get(o + (u32)2)).asU32() << (u32)16) | (((Number*)b.get(o + (u32)3)).asU32() << (u32)24);
        }

    static void wrw(Array* b, u32 o, u32 w)
        {
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            b.set(o + i, (Object*)Number.withU32((w >> ((u32)8 * i)) & (u32)$FF));
        }

    // The page-relative displacement an adrp encodes. VMBASE is page-aligned,
    // so masking file offsets gives the same answer as masking addresses.
    static void patchAdrp(Array* txt, u32 off, u32 target, u32 site)
        {
        i32 d = (i32)(target & ~(u32)$FFF) - (i32)(site & ~(u32)$FFF);
        i32 imm = d >> (i32)12;
        u32 w = rdw(txt, off) & ~(((u32)3 << (u32)29) | ((u32)$7FFFF << (u32)5));
        wrw(txt, off, w | (((u32)imm & (u32)3) << (u32)29) | ((((u32)imm >> (u32)2) & (u32)$7FFFF) << (u32)5));
        }

    static u32 symOffset(Map* symbols, Array* dataSyms, String* nm,
                         u32 textOffset, u32 dataProgOffset)
        {
        Object* o = symbols.get((Hashable*)nm);
        u32 off = o == (Object*)0 ? (u32)0 : ((Number*)o).asU32();
        return inArray(dataSyms, nm) ? dataProgOffset + off : textOffset + off;
        }

    static bool inArray(Array* a, String* nm)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(nm))
                return true;
        return false;
        }

    static void sortNumbers(Array* a)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            {
            Object* v = a.get(i);
            u32 j = i;
            while (j > (u32)0 && ((Number*)a.get(j - (u32)1)).asU32() > ((Number*)v).asU32())
                {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
                }
            a.set(j, v);
            }
        }

    // ── The image ────────────────────────────────────────────────────────
    void buildImage(Array* txt, Array* dat, Map* symbols, Array* dataSyms,
                    Array* rebaseOffs, MachOLayout* L)
        {
        u32 nimp = _imports.count();

        Array* rebase = buildRebase(rebaseOffs, L.hasRebase);
        Array* bind = buildBind(L.gotOffInSeg, L.hasImp);
        Array* defNames = sortedByOffsetThenName(symbols);
        Array* strtab = new Array();
        Array* nlist = new Array();
        Array* indirect = new Array();
        buildSymbolTables(symbols, dataSyms, defNames, strtab, nlist, indirect,
                          L.textOffset, L.dataProgOffset, L.hasImp);
        u32 ndef = defNames.count();
        u32 nsyms = ndef + nimp;

        L.rebaseOff = L.linkeditOff;
        L.rebaseLen = rebase.count();
        L.bindOff = L.rebaseOff + L.rebaseLen;
        L.bindLen = bind.count();
        L.symoff = L.bindOff + L.bindLen;
        L.nsyms = ndef + nimp;
        L.indOff = L.symoff + nlist.count();
        L.stroff = L.indOff + indirect.count();
        L.strsizeRaw = roundUp(strtab.count(), (u32)8); // the PADDED size is what LC_SYMTAB states
        L.ndef = ndef;
        L.nimp = nimp;
        L.textLen = txt.count();
        L.dataLen = dat.count();
        while (strtab.count() < L.strsizeRaw)
            strtab.add((Object*)Number.withU32((u32)0));

        // The signature sits at the end of __LINKEDIT and everything before it
        // is hashed, so its size has to be known BEFORE it is built.
        String* sigIdent = name((u32)10);
        L.sigOffset = roundUp(L.stroff + L.strsizeRaw, (u32)16);
        u32 nCodeSlots = (L.sigOffset + (u32)4095) / (u32)4096;
        L.sigSize = (u32)12 + (u32)8 + (u32)88 + sigIdent.byteLength() + (u32)1 + nCodeSlots * (u32)32;
        L.linkeditFilesz = (L.sigOffset + L.sigSize) - L.linkeditOff; // exact — sig is last (148)
        L.linkeditVmsz = roundUp(L.linkeditFilesz, (u32)MACHO_PAGE);

        computeCommandSizes(L);
        emitHeaderAndCommands(L);

        padTo(L.textOffset);
        appendAll(txt);
        padTo(L.stubsOffset);
        for (u32 i = (u32)0; i < nimp; i = i + (u32)1)
            emitStub(L.stubsOffset + i * (u32)STUB_SZ, L.gotOffset + i * (u32)GOT_SZ);
        if (L.hasData)
            {
            padTo(L.dataProgOffset);
            appendAll(dat);
            }
        if (L.hasImp)
            {
            padTo(L.gotOffset);
            for (u32 i = (u32)0; i < L.gotSize; i = i + (u32)1)
                put8((u32)0);
            }
        padTo(L.linkeditOff);
        appendAll(rebase);
        appendAll(bind);
        appendAll(nlist);
        appendAll(indirect);
        appendAll(strtab);

        // The ad-hoc signature hashes [0, sigOffset) a page at a time.
        padTo(L.sigOffset);
        appendAll(adhocSignature(L.sigOffset, sigIdent, L.textSegEnd));
        padTo(L.linkeditOff + L.linkeditFilesz);
        }

    // The load-command sizes, which the header must state before any of them
    // is written.
    void computeCommandSizes(MachOLayout* L)
        {
        u32 dyldLen = (u32)14;                                                                                                                // "/usr/lib/dyld"
        u32 libSysLen = (u32)26;                                                                                                              // "/usr/lib/libSystem.B.dylib"
        L.nDataSects = (L.hasDataSect ? (u32)1 : (u32)0) + (L.hasModInit ? (u32)1 : (u32)0) + (L.hasImp ? (u32)1 : (u32)0) + objcSectCount(); // bug 069
        L.szPagezero = (u32)72;
        L.szTextSeg = (u32)72 + (u32)80 * ((u32)1 + (L.hasImp ? (u32)1 : (u32)0));
        L.szDataSeg = (u32)72 + (u32)80 * L.nDataSects;
        L.szLink = (u32)72;
        L.szDyldInfo = (u32)48;
        L.szDyld = roundUp((u32)12 + dyldLen, (u32)8);
        L.szMain = (u32)24;
        L.szDylib = roundUp((u32)24 + libSysLen, (u32)8);
        L.szSym = (u32)24;
        L.szDysym = (u32)80;
        L.szBuild = (u32)24;
        L.szUUID = (u32)24;
        L.szCodeSig = (u32)16;
        // `@loader_path` is always searched, so a program finds a shared library
        // sitting beside it without the caller having to say so.
        L.szRpath = roundUp((u32)12 + (u32)13, (u32)8); // "@loader_path" + NUL
        // One LC_LOAD_DYLIB per linked library, after libSystem's — the order
        // IS the ordinal numbering the bind stream refers to.
        L.szDeps = (u32)0;
        for (u32 i = (u32)0; i < _deps.count(); i = i + (u32)1)
            L.szDeps = L.szDeps + roundUp((u32)24 + ((MachODep*)_deps.get(i)).path().byteLength() + (u32)1, (u32)8);
        L.hasDyldInfo = L.hasImp || L.hasRebase;
        L.ncmds = (u32)10 + (L.hasDataSeg ? (u32)1 : (u32)0) + (L.hasDyldInfo ? (u32)1 : (u32)0) + (u32)1 + (u32)1 // +LC_RPATH
                  + _deps.count();
        L.sizeofcmds = L.szPagezero + L.szTextSeg + (L.hasDataSeg ? L.szDataSeg : (u32)0) + L.szLink + (L.hasDyldInfo ? L.szDyldInfo : (u32)0) + L.szDeps + L.szDyld + L.szMain + L.szDylib + L.szSym + L.szDysym + L.szBuild + L.szUUID + L.szCodeSig + L.szRpath;
        }

    void emitHeaderAndCommands(MachOLayout* L)
        {
        // Header.
        put32(MH_MAGIC_64());
        put32(CPU_TYPE_ARM64());
        put32((u32)0);
        put32((u32)2); // MH_EXECUTE
        put32(L.ncmds);
        put32(L.sizeofcmds);
        put32((u32)$1 | (u32)$4 | (u32)$80 | (u32)$200000); // NOUNDEFS|DYLDLINK|TWOLEVEL|PIE
        put32((u32)0);

        // __PAGEZERO — the whole low 4 GB, unmapped.
        put32((u32)$19);
        put32(L.szPagezero);
        putName((u32)0, (u32)16);
        put64((u32)0, (u32)0);
        put64((u32)0, (u32)1);
        put64((u32)0, (u32)0);
        put64((u32)0, (u32)0);
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);

        // __TEXT, holding __text and (when there are imports) __stubs.
        put32((u32)$19);
        put32(L.szTextSeg);
        putName((u32)1, (u32)16);
        putAddr((u32)0);
        put64(L.textSegEnd, (u32)0);
        put64((u32)0, (u32)0);
        put64(L.textSegEnd, (u32)0);
        put32(VM_READ() | VM_EXEC());
        put32(VM_READ() | VM_EXEC());
        put32(L.hasImp ? (u32)2 : (u32)1);
        put32((u32)0);
        putName((u32)2, (u32)16);
        putName((u32)1, (u32)16);
        putAddr(L.textOffset);
        put64(L.textLen, (u32)0);
        put32(L.textOffset);
        put32((u32)2);
        put32((u32)0);
        put32((u32)0);
        put32((u32)$80000000 | (u32)$400);
        put32((u32)0);
        put32((u32)0);
        put32((u32)0);
        if (L.hasImp)
            {
            putName((u32)3, (u32)16);
            putName((u32)1, (u32)16);
            putAddr(L.stubsOffset);
            put64(L.stubsSize, (u32)0);
            put32(L.stubsOffset);
            put32((u32)2);
            put32((u32)0);
            put32((u32)0);
            put32((u32)$80000000 | (u32)$400);
            put32((u32)0);
            put32((u32)0);
            put32((u32)0);
            }

        emitDataAndLinkedit(L);
        emitLinkCommands(L);
        }

    void emitDataAndLinkedit(MachOLayout* L)
        {
        // __DATA, holding __data and __got.
        if (L.hasDataSeg)
            {
            u32 segSz = L.dataSegEnd - L.dataSegFileOff;
            put32((u32)$19);
            put32(L.szDataSeg);
            putName((u32)4, (u32)16);
            putAddr(L.dataSegFileOff);
            put64(segSz, (u32)0);
            put64(L.dataSegFileOff, (u32)0);
            put64(segSz, (u32)0);
            put32(VM_READ() | VM_WRITE());
            put32(VM_READ() | VM_WRITE());
            put32(L.nDataSects);
            put32((u32)0);
            if (L.hasDataSect)
                {
                putName((u32)5, (u32)16);
                putName((u32)4, (u32)16);
                putAddr(L.dataProgOffset);
                put64(L.dOnly, (u32)0);
                put32(L.dataProgOffset);
                put32((u32)3);
                put32((u32)0);
                put32((u32)0);
                put32((u32)0);
                put32((u32)0);
                put32((u32)0);
                put32((u32)0);
                }
            putObjcSects((u64)0, L.dataProgOffset, true); // bug 069
            // Bug 066: the load-time constructors. Same segment, same bytes,
            // straight after __data — only the section TYPE differs, and that is
            // what makes dyld call them rather than ignore them.
            if (L.hasModInit)
                {
                putName((u32)12, (u32)16);
                putName((u32)4, (u32)16);
                putAddr(L.dataProgOffset + L.dOnly);
                put64(L.miLen, (u32)0);
                put32(L.dataProgOffset + L.dOnly);
                put32((u32)3);
                put32((u32)0);
                put32((u32)0);
                put32((u32)9); // S_MOD_INIT_FUNC_POINTERS
                put32((u32)0);
                put32((u32)0);
                put32((u32)0);
                }
            if (L.hasImp)
                {
                putName((u32)6, (u32)16);
                putName((u32)4, (u32)16);
                putAddr(L.gotOffset);
                put64(L.gotSize, (u32)0);
                put32(L.gotOffset);
                put32((u32)3);
                put32((u32)0);
                put32((u32)0);
                put32((u32)6); // NON_LAZY_SYMBOL_POINTERS
                put32((u32)0);
                put32((u32)0);
                put32((u32)0);
                }
            }

        // __LINKEDIT.
        put32((u32)$19);
        put32(L.szLink);
        putName((u32)7, (u32)16);
        putAddr(L.linkeditOff);
        put64(L.linkeditVmsz, (u32)0);
        put64(L.linkeditOff, (u32)0);
        put64(L.linkeditFilesz, (u32)0);
        put32(VM_READ());
        put32(VM_READ());
        put32((u32)0);
        put32((u32)0);
        }

    void emitLinkCommands(MachOLayout* L)
        {
        if (L.hasDyldInfo)
            {
            put32((u32)$22 | (u32)$80000000);
            put32(L.szDyldInfo);
            put32(L.hasRebase ? L.rebaseOff : (u32)0);
            put32(L.rebaseLen);
            put32(L.hasImp ? L.bindOff : (u32)0);
            put32(L.bindLen);
            put32((u32)0);
            put32((u32)0); // weak bind
            put32((u32)0);
            put32((u32)0); // lazy bind
            put32((u32)0);
            put32((u32)0); // export
            }
        put32((u32)$0E);
        put32(L.szDyld);
        put32((u32)12);
        putName((u32)8, L.szDyld - (u32)12);
        // Entry is LC_MAIN. LC_UNIXTHREAD is not an option: modern dyld rejects
        // a dynamically-linked main executable without LC_MAIN, and owning the
        // entry would mean a fully static binary with no libSystem — which is
        // exactly what this deliberately depends on.
        put32((u32)$28 | (u32)$80000000);
        put32(L.szMain);
        put64(L.textOffset + L.entryOffset, (u32)0);
        put64((u32)0, (u32)0);
        put32((u32)$0C);
        put32(L.szDylib);
        put32((u32)24);
        put32((u32)2);
        put32((u32)$510000);
        put32((u32)$10000);
        putName((u32)9, L.szDylib - (u32)24);
        // …then one per linked library, in the order that IS their ordinal
        // numbering (libSystem is 1, these are 2, 3, …). `@rpath/` because the
        // image already carries an LC_RPATH of `@loader_path`, so a library
        // sitting beside the program is found without the caller saying so.
        for (u32 i = (u32)0; i < _deps.count(); i = i + (u32)1)
            {
            String* dp = ((MachODep*)_deps.get(i)).path();
            u32 sz = roundUp((u32)24 + dp.byteLength() + (u32)1, (u32)8);
            put32((u32)$0C);
            put32(sz);
            put32((u32)24);
            put32((u32)2);
            put32((u32)$10000);
            put32((u32)$10000);
            putFixed(dp, sz - (u32)24);
            }
        put32((u32)$1C | (u32)$80000000);
        put32(L.szRpath);
        put32((u32)12);
        putName((u32)11, L.szRpath - (u32)12);
        put32((u32)$02);
        put32(L.szSym);
        put32(L.symoff);
        put32(L.nsyms);
        put32(L.stroff);
        put32(L.strsizeRaw);
        put32((u32)$0B);
        put32(L.szDysym);
        put32((u32)0);
        put32(L.ndef); // ilocalsym, nlocalsym
        put32(L.ndef);
        put32((u32)0); // iextdefsym, nextdefsym
        put32(L.ndef);
        put32(L.nimp); // iundefsym, nundefsym
        put32((u32)0);
        put32((u32)0); // toc
        put32((u32)0);
        put32((u32)0); // modtab
        put32((u32)0);
        put32((u32)0); // extrefsym
        put32(L.hasImp ? L.indOff : (u32)0);
        put32(L.nimp); // indirect symbols
        put32((u32)0);
        put32((u32)0); // extrel
        put32((u32)0);
        put32((u32)0); // locrel
        put32((u32)$32);
        put32(L.szBuild);
        put32(_platformId);
        put32(_platformVer);
        put32(_platformVer);
        put32((u32)0);
        put32((u32)$1B);
        put32(L.szUUID);
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            put8((u32)0);
        put32((u32)$1D);
        put32(L.szCodeSig);
        put32(L.sigOffset);
        put32(L.sigSize);
        }

    // The rebase stream: each `.quad <symbol>` slot in __data is a pointer dyld
    // slides for the PIE. __data is the first section of __DATA, so its section
    // offset IS its segment offset.
    Array* buildRebase(Array* rebaseOffs, bool hasRebase)
        {
        Array* rebase = new Array();
        if (!hasRebase)
            return rebase;
        rebase.add((Object*)Number.withU32((u32)$10 | (u32)1)); // SET_TYPE pointer
        for (u32 i = (u32)0; i < rebaseOffs.count(); i = i + (u32)1)
            {
            rebase.add((Object*)Number.withU32((u32)$20 | _dataSegIdx)); // SET_SEG_OFF
            ulebInto(rebase, ((Number*)rebaseOffs.get(i)).asU32());
            rebase.add((Object*)Number.withU32((u32)$50 | (u32)1)); // DO_IMM_TIMES 1
            }
        rebase.add((Object*)Number.withU32((u32)0)); // DONE
        while ((rebase.count() & (u32)7) != (u32)0)
            rebase.add((Object*)Number.withU32((u32)0));
        return rebase;
        }

    // The bind stream: one GOT slot per import, all from libSystem (ordinal
    // 1) — then the __data pointer-slot binds (finding #7), each bound in
    // place at its own segment offset, addend via SET_ADDEND when non-zero.
    Array* buildBind(u32 gotOffInSeg, bool hasImp)
        {
        Array* bind = new Array();
        if (!hasImp)
            return bind;
        // A dylib sets FLAT lookup once, up front; an executable names
        // libSystem's ordinal per symbol.
        // SET_DYLIB_SPECIAL_IMM with the ordinal in a 4-bit SIGNED field:
        // FLAT_LOOKUP is -2, which is 0x0E, not 0x0F (that is -1, and means
        // nothing). One byte, and the only one in a 278 KB image that was
        // wrong — plus the 32 signature bytes that hash the page it sits in.
        if (_flatBind)
            bind.add((Object*)Number.withU32((u32)$30 | (u32)$0E));
        u32 curOrd = (u32)0; // force an initial SET
        for (u32 i = (u32)0; i < _imports.count(); i = i + (u32)1)
            {
            u32 ord = ordinalFor((String*)_imports.get(i));
            if (!_flatBind && ord != curOrd)
                {
                bind.add((Object*)Number.withU32((u32)$10 | ord));
                curOrd = ord;
                }
            bind.add((Object*)Number.withU32((u32)$40)); // SET_SYMBOL_FLAGS
            strInto(bind, (String*)_imports.get(i));
            bind.add((Object*)Number.withU32((u32)$50 | (u32)1));      // SET_TYPE pointer
            bind.add((Object*)Number.withU32((u32)$70 | _dataSegIdx)); // SET_SEG_OFF
            ulebInto(bind, gotOffInSeg + i * (u32)GOT_SZ);
            bind.add((Object*)Number.withU32((u32)$90)); // DO_BIND
            }
        for (u32 k = (u32)0; k < _dataBinds.count(); k = k + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)_dataBinds.get(k);
            if (!_flatBind)
                {
                u32 ord = ordinalFor(f.symbol());
                bind.add((Object*)Number.withU32((u32)$10 | ord));
                curOrd = ord;
                }
            bind.add((Object*)Number.withU32((u32)$40)); // SET_SYMBOL_FLAGS
            strInto(bind, f.symbol());
            bind.add((Object*)Number.withU32((u32)$50 | (u32)1)); // SET_TYPE pointer
            if (f.addend() != (i32)0)
                {
                bind.add((Object*)Number.withU32((u32)$60)); // SET_ADDEND_SLEB
                slebInto(bind, f.addend());
                }
            bind.add((Object*)Number.withU32((u32)$70 | _dataSegIdx)); // SET_SEG_OFF
            ulebInto(bind, f.offset());
            bind.add((Object*)Number.withU32((u32)$90)); // DO_BIND
            if (f.addend() != (i32)0)
                {
                bind.add((Object*)Number.withU32((u32)$60)); // addend is sticky: reset
                slebInto(bind, (i32)0);
                }
            }
        bind.add((Object*)Number.withU32((u32)0)); // DONE
        while ((bind.count() & (u32)7) != (u32)0)
            bind.add((Object*)Number.withU32((u32)0));
        return bind;
        }

    // Signed LEB128 (the bind stream's addend form).
    static void slebInto(Array* out, i32 v)
        {
        bool more = true;
        while (more)
            {
            u32 b = (u32)v & (u32)$7F;
            v = v >> (i32)7;
            if ((v == (i32)0 && (b & (u32)$40) == (u32)0) || (v == (i32)-1 && (b & (u32)$40) != (u32)0))
                more = false;
            else
                b = b | (u32)$80;
            out.add((Object*)Number.withU32(b));
            }
        }

    static void sortBindsByOffset(Array* binds)
        {
        for (u32 i = (u32)1; i < binds.count(); i = i + (u32)1)
            {
            Arm64Fixup* f = (Arm64Fixup*)binds.get(i);
            u32 j = i;
            while (j > (u32)0 && ((Arm64Fixup*)binds.get(j - (u32)1)).offset() > f.offset())
                {
                binds.set(j, binds.get(j - (u32)1));
                j = j - (u32)1;
                }
            binds.set(j, (Object*)f);
            }
        }

    // Defined symbols first, then the undefined imports. Defined names go in
    // OFFSET order with ties broken on the NAME — two labels can share an
    // offset (a text label at 0 and a data label at 0 always do), and leaving
    // that tie to the table's own order would make the output depend on how the
    // map happened to hash.
    void buildSymbolTables(Map* symbols, Array* dataSyms, Array* defNames,
                           Array* strtab, Array* nlist, Array* indirect,
                           u32 textOffset, u32 dataProgOffset, bool hasImp)
        {
        strtab.add((Object*)Number.withU32((u32)0));
        u32 dataSect = (u32)1 + (hasImp ? (u32)1 : (u32)0) + (u32)1;
        for (u32 i = (u32)0; i < defNames.count(); i = i + (u32)1)
            {
            String* nm = (String*)defNames.get(i);
            u32 strx = strtab.count();
            strInto(strtab, nm);
            u32Into(nlist, strx);
            nlist.add((Object*)Number.withU32((u32)$0E)); // N_SECT
            nlist.add((Object*)Number.withU32(inArray(dataSyms, nm) ? dataSect : (u32)1));
            nlist.add((Object*)Number.withU32((u32)0));
            nlist.add((Object*)Number.withU32((u32)0));
            u32Into(nlist, symOffset(symbols, dataSyms, nm, textOffset, dataProgOffset));
            u32Into(nlist, (u32)1); // VMBASE high half
            }
        for (u32 i = (u32)0; i < _imports.count(); i = i + (u32)1)
            {
            u32 strx = strtab.count();
            strInto(strtab, (String*)_imports.get(i));
            u32Into(nlist, strx);
            nlist.add((Object*)Number.withU32((u32)$01)); // N_UNDF | N_EXT
            nlist.add((Object*)Number.withU32((u32)0));
            nlist.add((Object*)Number.withU32((u32)0));
            // n_desc's high byte: the library ordinal — the one the bind
            // stream names for this symbol (ordinalFor), not always libSystem's
            // 1. The two disagreed for a GOT-reached import from libobjc; the
            // reference stamps the exporting dylib's ordinal here as well.
            nlist.add((Object*)Number.withU32(ordinalFor((String*)_imports.get(i))));
            u32Into(nlist, (u32)0);
            u32Into(nlist, (u32)0);
            }
        for (u32 i = (u32)0; i < _imports.count(); i = i + (u32)1)
            u32Into(indirect, defNames.count() + i);
        }

    // adrp x16, slotpage ; ldr x16, [x16, #slotoff] ; br x16
    void emitStub(u32 stubOff, u32 slotOff)
        {
        i32 pd = (i32)(slotOff & ~(u32)$FFF) - (i32)(stubOff & ~(u32)$FFF);
        i32 imm = pd >> (i32)12;
        u32 immlo = (u32)imm & (u32)3;
        u32 immhi = ((u32)imm >> (u32)2) & (u32)$7FFFF;
        put32((u32)$90000010 | (immlo << (u32)29) | (immhi << (u32)5));
        put32((u32)$F9400210 | (((slotOff & (u32)$FFF) / (u32)8) << (u32)10));
        put32((u32)$D61F0200);
        }

    // The code-signing blobs are BIG-endian, unlike everything else in the file.
    Array* adhocSignature(u32 codeLimit, String* ident, u32 execSegLimit)
        {
        u32 CS_PAGE = (u32)4096;
        u32 idLen = ident.byteLength();
        u32 nCodeSlots = (codeLimit + CS_PAGE - (u32)1) / CS_PAGE;
        u32 hdr = (u32)88;
        u32 identOffset = hdr;
        u32 hashOffset = identOffset + idLen + (u32)1;
        u32 cdLength = hashOffset + nCodeSlots * (u32)32;

        Array* cd = new Array();
        be32Into(cd, (u32)$fade0c02); // CSMAGIC_CODEDIRECTORY
        be32Into(cd, cdLength);
        be32Into(cd, (u32)$20400);
        be32Into(cd, (u32)$2); // flags: adhoc
        be32Into(cd, hashOffset);
        be32Into(cd, identOffset);
        be32Into(cd, (u32)0);
        be32Into(cd, nCodeSlots);
        be32Into(cd, codeLimit);
        cd.add((Object*)Number.withU32((u32)32)); // hashSize
        cd.add((Object*)Number.withU32((u32)2));  // hashType = SHA-256
        cd.add((Object*)Number.withU32((u32)0));  // platform
        cd.add((Object*)Number.withU32((u32)12)); // pageSize = log2(4096)
        be32Into(cd, (u32)0);                     // spare2
        be32Into(cd, (u32)0);                     // scatterOffset
        be32Into(cd, (u32)0);                     // teamOffset
        be32Into(cd, (u32)0);                     // spare3
        be64Into(cd, (u32)0, (u32)0);             // codeLimit64
        be64Into(cd, (u32)0, (u32)0);             // execSegBase
        be64Into(cd, execSegLimit, (u32)0);
        be64Into(cd, (u32)1, (u32)0); // execSegFlags = MAIN_BINARY
        strInto(cd, ident);
        for (u32 i = (u32)0; i < nCodeSlots; i = i + (u32)1)
            {
            u32 off = i * CS_PAGE;
            u32 len = codeLimit - off;
            if (len > CS_PAGE)
                len = CS_PAGE;
            Sha256* h = new Sha256();
            h.update(_out, off, len);
            h.finalise(cd);
            }
        Array* sb = new Array(); // SuperBlob { CodeDirectory }
        be32Into(sb, (u32)$fade0cc0);
        be32Into(sb, (u32)12 + (u32)8 + cdLength);
        be32Into(sb, (u32)1);
        be32Into(sb, (u32)0);  // slot type = CodeDirectory
        be32Into(sb, (u32)20); // offset
        for (u32 i = (u32)0; i < cd.count(); i = i + (u32)1)
            sb.add(cd.get(i));
        return sb;
        }

    void appendAll(Array* a)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            _out.add(a.get(i));
        }

    static void ulebInto(Array* a, u32 v)
        {
        while (true)
            {
            u32 b = v & (u32)$7F;
            v = v >> (u32)7;
            if (v != (u32)0)
                b = b | (u32)$80;
            a.add((Object*)Number.withU32(b));
            if (v == (u32)0)
                return;
            }
        }

    static void strInto(Array* a, String* s)
        {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            a.add((Object*)Number.withU32((u32)s.byteAt(i)));
        a.add((Object*)Number.withU32((u32)0));
        }

    static void u32Into(Array* a, u32 v)
        {
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            a.add((Object*)Number.withU32((v >> ((u32)8 * i)) & (u32)$FF));
        }

    static void be32Into(Array* a, u32 v)
        {
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            a.add((Object*)Number.withU32((v >> ((u32)8 * ((u32)3 - i))) & (u32)$FF));
        }

    static void be64Into(Array* a, u32 lo, u32 hi)
        {
        be32Into(a, hi);
        be32Into(a, lo);
        }

    static Array* sortedByOffsetThenName(Map* symbols)
        {
        Array* keys = symbols.allKeys();
        for (u32 i = (u32)1; i < keys.count(); i = i + (u32)1)
            {
            Object* v = keys.get(i);
            u32 vo = ((Number*)symbols.get((Hashable*)(String*)v)).asU32();
            u32 j = i;
            while (j > (u32)0)
                {
                String* p = (String*)keys.get(j - (u32)1);
                u32 po = ((Number*)symbols.get((Hashable*)p)).asU32();
                bool after = po > vo || (po == vo && p.compare((String*)v) > (i32)0);
                if (!after)
                    break;
                keys.set(j, keys.get(j - (u32)1));
                j = j - (u32)1;
                }
            keys.set(j, v);
            }
        return keys;
        }
    }
