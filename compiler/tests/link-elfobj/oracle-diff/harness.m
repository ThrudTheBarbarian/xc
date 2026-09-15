// harness.m — the REFERENCE side of elfobj-diff.
//
// Prints one canonical line per fact the port's ElfObject.xc must agree on,
// for every member of an archive: the three blob sizes and alignments, each
// symbol's classification, and the relocations. The port prints the same lines
// from the same input, and the harness compares them.
//
// Symbol NAMES alone were not enough: the reader can classify a symbol into the
// wrong blob and still list it, which is exactly the bug that made every
// function in a -ffunction-sections member come back undefined.
#import <Foundation/Foundation.h>
#import "XTElfWriter.h"

int main(int argc, const char** argv)
    {
    @autoreleasepool
        {
        if (argc < 2)
            {
            fprintf(stderr, "usage: oracle-elfobj <archive.a|object.o>\n");
            return 2;
            }
        NSString* path = [NSString stringWithUTF8String:argv[1]];
        NSArray<NSDictionary*>* objs = nil;
        NSArray<NSString*>* names = nil;
        if ([path hasSuffix:@".a"])
            {
            objs = [XTElfWriter objectsInArchive:path];
            NSMutableArray* n = [NSMutableArray array];
            for (NSDictionary* o in objs)
                [n addObject:o[@"member"] ?: @"?"];
            names = n;
            }
        else
            {
            NSDictionary* o = [XTElfWriter objectAtPath:path];
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
            printf("%s blobs text=%lu data=%lu tls=%lu dataalign=%llu tlsalign=%llu\n",
                   m.UTF8String,
                   (unsigned long)[o[@"text"] length], (unsigned long)[o[@"data"] length],
                   (unsigned long)[o[@"tls"] length],
                   [o[@"dataalign"] unsignedLongLongValue],
                   [o[@"tlsalign"] unsignedLongLongValue]);
            NSArray<NSString*>* sn = o[@"symnames"];
            NSArray<NSDictionary*>* sd = o[@"symdefs"];
            for (NSUInteger k = 0; k < sn.count; k++)
                printf("%s sym %lu %s ext=%d weak=%d where=%d off=%llu\n",
                       m.UTF8String, (unsigned long)k,
                       sn[k].length ? sn[k].UTF8String : "-",
                       [sd[k][@"ext"] boolValue], [sd[k][@"weak"] boolValue],
                       [sd[k][@"where"] intValue],
                       [sd[k][@"off"] unsignedLongLongValue]);
            NSArray* kinds = @[ @"reloc", @"datareloc", @"tlsreloc" ];
            NSArray* lists = @[ o[@"relocs"], o[@"datarelocs"], o[@"tlsrelocs"] ];
            for (NSUInteger q = 0; q < 3; q++)
                for (NSDictionary* r in lists[q])
                    printf("%s %s off=%llu sym=%llu type=%llu addend=%lld\n",
                           m.UTF8String, [kinds[q] UTF8String],
                           [r[@"off"] unsignedLongLongValue], [r[@"sym"] unsignedLongLongValue],
                           [r[@"type"] unsignedLongLongValue], [r[@"addend"] longLongValue]);
            }
        }
    return 0;
    }
