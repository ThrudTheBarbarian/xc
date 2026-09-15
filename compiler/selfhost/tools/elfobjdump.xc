// elfobjdump.xc — the PORT side of elfobj-diff.
//
// Prints exactly the lines tests/link-elfobj/oracle-diff/harness.m prints, from
// the same input, so the two ELF object readers can be compared byte for byte.
// Blob sizes and symbol CLASSIFICATION are in the output, not just names: a
// reader can list a symbol and still file it under the wrong blob, which is the
// failure mode that makes a -ffunction-sections member define nothing.
#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "ArArchive.xc"
#import "ElfObject.xc"

void dumpOne(String* member, ElfObject* o)
    {
    Stdio.printf("%s blobs text=%lu data=%lu tls=%lu dataalign=%lu tlsalign=%lu\n",
                 member.cString(), o.text().length(), o.data().length(),
                 o.tls().length(), o.dataAlign(), o.tlsAlign());
    Array* sd = o.symdefs();
    for (u32 k = (u32)0; k < sd.count(); k = k + (u32)1)
        {
        ElfSymDef* s = (ElfSymDef*)sd.get(k);
        string nm = s.name().byteLength() == (u32)0 ? "-" : s.name().cString();
        Stdio.printf("%s sym %lu %s ext=%ld weak=%ld where=%ld off=%lu\n",
                     member.cString(), k, nm,
                     s.ext() ? (i32)1 : (i32)0, s.weak() ? (i32)1 : (i32)0,
                     (i32)s.where(), s.off());
        }
    dumpRelocs(member, String.withCString("reloc"), o.relocs());
    dumpRelocs(member, String.withCString("datareloc"), o.dataRelocs());
    dumpRelocs(member, String.withCString("tlsreloc"), o.tlsRelocs());
    }

void dumpRelocs(String* member, String* kind, Array* rs)
    {
    for (u32 i = (u32)0; i < rs.count(); i = i + (u32)1)
        {
        ElfReloc* r = (ElfReloc*)rs.get(i);
        Stdio.printf("%s %s off=%lu sym=%lu type=%lu addend=%lld\n",
                     member.cString(), kind.cString(),
                     r.off(), r.sym(), r.type(), r.addend());
        }
    }

void main(void)
    {
    if (Process.argumentCount() < (u32)2)
        {
        Stdio.printf("usage: elfobjdump <archive.a|object.o>\n");
        Process.exit((i32)2);
        return;
        }
    String* path = Process.argument((u32)1);
    if (path.hasSuffix(String.withCString(".a")))
        {
        Array* ms = ArArchive.membersOfFile(path);
        if (ms == (Array*)0)
            {
            Stdio.printf("not readable\n");
            Process.exit((i32)1);
            return;
            }
        for (u32 i = (u32)0; i < ms.count(); i = i + (u32)1)
            {
            ArMember* m = (ArMember*)ms.get(i);
            ElfObject* o = ElfObject.parse(m.data());
            if (!o.ok())
                continue;
            dumpOne(m.name(), o);
            }
        return;
        }
    Data* d = Files.readData(path);
    if (d == (Data*)0)
        {
        Stdio.printf("not readable\n");
        Process.exit((i32)1);
        return;
        }
    ElfObject* o = ElfObject.parse(d);
    if (!o.ok())
        {
        Stdio.printf("not an object\n");
        Process.exit((i32)1);
        return;
        }
    dumpOne(path.lastPathComponent(), o);
    }
