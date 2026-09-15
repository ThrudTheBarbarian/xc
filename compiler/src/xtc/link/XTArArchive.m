#import "XTArArchive.h"

@implementation XTArArchive

// An `ar` archive: `!<arch>\n` then 60-byte headers, each followed by its
// member, padded to an even length. Long names live in the `//` member and a
// header names them as `/<offset>`; the `/` member is the symbol index, which
// this does not need.
//
// COFF archives spell the long-name member `//` too, but ALSO use a second
// convention Microsoft's linker emits — a name ending in `/` is simply the name
// with the slash stripped. Handling both here is why this is one function.
+ (nullable NSArray<NSDictionary*>*)membersOfArchiveData:(NSData*)d
    {
    if (d.length < 8 || memcmp(d.bytes, "!<arch>\n", 8) != 0)
        return nil;
    const uint8_t* b = d.bytes;
    NSMutableArray<NSDictionary*>* out = [NSMutableArray array];
    NSData* longNames = nil;
    uint64_t p = 8;
    while (p + 60 <= d.length)
        {
        char namef[17];
        memcpy(namef, b + p, 16);
        namef[16] = 0;
        char sizef[11];
        memcpy(sizef, b + p + 48, 10);
        sizef[10] = 0;
        uint64_t msize = (uint64_t)atoll(sizef);
        uint64_t body = p + 60;
        if (body + msize > d.length)
            break;
        NSString* nm = [[NSString stringWithUTF8String:namef]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([nm isEqualToString:@"//"])
            {
            longNames = [d subdataWithRange:NSMakeRange((NSUInteger)body, (NSUInteger)msize)];
            }
        else if ([nm hasPrefix:@"/"] && nm.length > 1 && longNames)
            {
            NSUInteger at = (NSUInteger)atoll(nm.UTF8String + 1);
            const char* ln = (const char*)longNames.bytes;
            if (at < longNames.length)
                {
                NSUInteger e = at;
                while (e < longNames.length && ln[e] != '/' && ln[e] != '\n')
                    e++;
                nm = [[NSString alloc] initWithBytes:ln + at
                                              length:e - at
                                            encoding:NSUTF8StringEncoding];
                }
            }
        else if (nm.length > 1 && [nm hasSuffix:@"/"])
            {
            nm = [nm substringToIndex:nm.length - 1]; // the COFF short-name form
            }
        // BSD (Mach-O) puts a long name in the first `extra` bytes of the
        // member body, so it comes off the front of the DATA, not just the name.
        uint64_t extra = 0;
        if ([nm hasPrefix:@"#1/"])
            {
            extra = (uint64_t)[[nm substringFromIndex:3] intValue];
            if (extra > msize)
                break;
            nm = [[[NSString alloc] initWithBytes:b + body
                                           length:(NSUInteger)extra
                                         encoding:NSUTF8StringEncoding]
                stringByTrimmingCharactersInSet:[NSCharacterSet controlCharacterSet]];
            }
        if (![nm isEqualToString:@"/"] && ![nm isEqualToString:@"//"] && ![nm hasPrefix:@"__.SYMDEF"] && msize > extra)
            {
            [out addObject:@{@"name" : nm ?: @"",
                             @"data" : [d subdataWithRange:
                                              NSMakeRange((NSUInteger)(body + extra),
                                                          (NSUInteger)(msize - extra))]}];
            }
        p = body + msize + (msize & 1);
        }
    return out;
    }

+ (nullable NSArray<NSDictionary*>*)membersOfArchive:(NSString*)path
    {
    NSData* d = [NSData dataWithContentsOfFile:path];
    if (!d)
        return nil;
    return [self membersOfArchiveData:d];
    }

@end
