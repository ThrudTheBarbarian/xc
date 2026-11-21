// ElfDyn.xc — what the x86-64 and AArch64 ELF writers put in an image's dynamic
// sections the same way (#336): the .dynsym order, .dynstr with its strings
// interned, and the SysV .hash table DT_HASH points at. Each writer had its own
// copy; the layout around them, the relocations and the program headers stay
// with the writers.
#import "Foundation.xc"

class ElfDyn
{
    // The SysV ELF hash DT_HASH requires — unchanged since 1995 and specified
    // byte for byte in the gABI, so it is written out rather than looked up.
    static u32 hash(String* name)
    {
        u32 h = (u32)0;
        for (u32 i = (u32)0; i < name.byteLength(); i = i + (u32)1)
        {
            h = (h << (u32)4) + (u32)name.byteAt(i);
            u32 g = h & (u32)$F000_0000;
            if (g != (u32)0)
                h = h ^ (g >> (u32)24);
            h = h & ~g;
        }
        return h;
    }

    // s's offset in blob, appending it (NUL-terminated) the first time.
    static u32 intern(Data* blob, Map* off, String* s)
    {
        Object* have = off.get((Hashable*)s);
        if (have != (Object*)0)
            return ((Number*)have).asU32();
        u32 at = blob.length();
        off.set((Hashable*)s, (Object*)Number.withU32(at));
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            blob.appendByte(s.byteAt(i));
        blob.appendByte((u8)0);
        return at;
    }

    // The offset intern gave s, or 0.
    static u32 lookup(Map* off, String* s)
    {
        Object* have = off.get((Hashable*)s);
        return have != (Object*)0 ? ((Number*)have).asU32() : (u32)0;
    }

    // .dynsym's names in order: the null entry, the exports, the imports, then
    // the imports named only by data words.
    static Array* symbolOrder(Array* exports, Array* imports, Array* wordImports)
    {
        Array* order = new Array();
        order.add((Object*)String.withCString(""));
        for (u32 i = (u32)0; i < exports.count(); i = i + (u32)1)
            order.add(exports.get(i));
        for (u32 i = (u32)0; i < imports.count(); i = i + (u32)1)
            order.add(imports.get(i));
        for (u32 i = (u32)0; i < wordImports.count(); i = i + (u32)1)
            order.add(wordImports.get(i));
        return order;
    }

    // .dynstr: "" at offset 0, then every name of order (after its null entry)
    // interned into off.
    static Data* stringTable(Array* order, Map* off)
    {
        Data* blob = new Data();
        blob.appendByte((u8)0); // index 0 = ""
        for (u32 i = (u32)1; i < order.count(); i = i + (u32)1)
            ElfDyn.intern(blob, off, (String*)order.get(i));
        return blob;
    }

    // About four symbols to a bucket.
    static u32 bucketCount(u32 nsym)
    {
        return nsym < (u32)4 ? (u32)1 : nsym / (u32)4 + (u32)1;
    }

    static u32 hashSize(u32 nsym)
    {
        return ((u32)2 + ElfDyn.bucketCount(nsym) + nsym) * (u32)4;
    }

    // The .hash section for order (whose entry 0 is the null symbol), little
    // endian: nbucket, nchain, the buckets, the chains. Each symbol is pushed
    // onto the front of its bucket's chain.
    static Data* hashTable(Array* order)
    {
        u32 nsym = order.count();
        u32 nbucket = ElfDyn.bucketCount(nsym);
        Array* bucket = new Array();
        Array* chain = new Array();
        for (u32 i = (u32)0; i < nbucket; i = i + (u32)1)
            bucket.add((Object*)Number.withU32((u32)0));
        for (u32 i = (u32)0; i < nsym; i = i + (u32)1)
            chain.add((Object*)Number.withU32((u32)0));
        for (u32 i = (u32)1; i < nsym; i = i + (u32)1)
        {
            u32 b = ElfDyn.hash((String*)order.get(i)) % nbucket;
            chain.set(i, bucket.get(b));
            bucket.set(b, (Object*)Number.withU32(i));
        }
        Data* out = new Data();
        ElfDyn.word(out, nbucket);
        ElfDyn.word(out, nsym);
        for (u32 i = (u32)0; i < nbucket; i = i + (u32)1)
            ElfDyn.word(out, ((Number*)bucket.get(i)).asU32());
        for (u32 i = (u32)0; i < nsym; i = i + (u32)1)
            ElfDyn.word(out, ((Number*)chain.get(i)).asU32());
        return out;
    }

    static void word(Data* out, u32 v)
    {
        out.appendByte((u8)v);
        out.appendByte((u8)(v >> (u32)8));
        out.appendByte((u8)(v >> (u32)16));
        out.appendByte((u8)(v >> (u32)24));
    }
}
