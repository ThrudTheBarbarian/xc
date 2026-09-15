// harness.m — the REFERENCE side of coffobj-diff.
//
// The COFF twin of tests/link-elfobj/oracle-diff/harness.m. Prints one
// canonical line per fact the port's CoffObject.xc must agree on, for every
// member of an archive: blob sizes, each symbol's classification, and the
// relocations.
//
// Symbol NAMES alone would not be enough. COFF keeps AUXILIARY records in the
// symbol table and relocations index it BY SLOT, so a reader that skips them
// renumbers every symbol after the first aux record and still lists the same
// names — which is why the slot INDEX is printed with each one.
#import <Foundation/Foundation.h>
#import "XTPEWriter.h"

int main(int argc, const char** argv)
    {
    @autoreleasepool
        {
        if (argc < 2)
            {
            fprintf(stderr, "usage: oracle-coffobj <archive.a|object.o>\n");
            return 2;
            }
        NSString* path = [NSString stringWithUTF8String:argv[1]];
        NSArray<NSDictionary*>* objs = nil;
        NSArray<NSString*>* names = nil;
        if ([path hasSuffix:@".a"])
            {
            objs = [XTPEWriter objectsInArchive:path];
            NSMutableArray* n = [NSMutableArray array];
            for (NSDictionary* o in objs)
                [n addObject:o[@"member"] ?: @"?"];
            names = n;
            }
        else
            {
            NSDictionary* o = [XTPEWriter objectAtPath:path];
            if (!o)
                {
                fprintf(stderr, "not an object\n");
                return 1;
                }
            objs = @[ o ];
            names = @[ path.lastPathComponent ];
            }
        if (!objs)
            {
            fprintf(stderr, "not readable\n");
            return 1;
            }
        for (NSUInteger i = 0; i < objs.count; i++)
            {
            NSDictionary* o = objs[i];
            NSString* m = names[i];
            printf("%s blobs text=%lu data=%lu\n", m.UTF8String,
                   (unsigned long)[o[@"text"] length], (unsigned long)[o[@"data"] length]);
            NSArray<NSString*>* sn = o[@"symnames"];
            NSArray<NSDictionary*>* sd = o[@"symdefs"];
            for (NSUInteger k = 0; k < sn.count; k++)
                printf("%s sym %lu %s ext=%d where=%d off=%llu\n",
                       m.UTF8String, (unsigned long)k,
                       sn[k].length ? sn[k].UTF8String : "-",
                       [sd[k][@"ext"] boolValue], [sd[k][@"where"] intValue],
                       [sd[k][@"off"] unsignedLongLongValue]);
            NSArray* kinds = @[ @"reloc", @"datareloc" ];
            NSArray* lists = @[ o[@"relocs"], o[@"datarelocs"] ];
            for (NSUInteger q = 0; q < 2; q++)
                for (NSDictionary* r in lists[q])
                    printf("%s %s off=%llu sym=%llu type=%llu addend=%lld\n",
                           m.UTF8String, [kinds[q] UTF8String],
                           [r[@"off"] unsignedLongLongValue], [r[@"sym"] unsignedLongLongValue],
                           [r[@"type"] unsignedLongLongValue], [r[@"addend"] longLongValue]);
            }
        }
    return 0;
    }
