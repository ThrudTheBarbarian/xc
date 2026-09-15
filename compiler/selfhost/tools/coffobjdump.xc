// coffobjdump.xc — the PORT side of coffobj-diff.
//
// Prints exactly what tests/link-coffobj/oracle-diff/harness.m prints, from the
// same input, so the two COFF object readers can be compared byte for byte.
#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"
#import "Process.xc"
#import "ArArchive.xc"
#import "CoffObject.xc"

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

void dumpOne(String* member, CoffObject* o)
    {
    Stdio.printf("%s blobs text=%lu data=%lu\n",
                 member.cString(), o.text().length(), o.data().length());
    Array* sd = o.symdefs();
    for (u32 k = (u32)0; k < sd.count(); k = k + (u32)1)
        {
        ElfSymDef* s = (ElfSymDef*)sd.get(k);
        string nm = s.name().byteLength() == (u32)0 ? "-" : s.name().cString();
        Stdio.printf("%s sym %lu %s ext=%ld where=%ld off=%lu\n",
                     member.cString(), k, nm,
                     s.ext() ? (i32)1 : (i32)0, (i32)s.where(), s.off());
        }
    dumpRelocs(member, String.withCString("reloc"), o.relocs());
    dumpRelocs(member, String.withCString("datareloc"), o.dataRelocs());
    }

void main(void)
    {
    if (Process.argumentCount() < (u32)2)
        {
        Stdio.printf("usage: coffobjdump <archive.a|object.o>\n");
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
            CoffObject* o = CoffObject.parse(m.data());
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
    CoffObject* o = CoffObject.parse(d);
    if (!o.ok())
        {
        Stdio.printf("not an object\n");
        Process.exit((i32)1);
        return;
        }
    dumpOne(path.lastPathComponent(), o);
    }
