// Batch oracle-diff harness: reads instructions (one per line) from argv[1],
// encodes each with XAArm64Assembler, and compares to clang's encoding of the
// same batch (assembled once). Non-branch, external-symbol-only lines.
#import "XAArm64Assembler.h"

static NSData* clangEncode(NSArray<NSString*>* lines)
    {
    NSMutableString* s = [@".text\n" mutableCopy];
    for (NSString* l in lines)
        {
        [s appendString:l];
        [s appendString:@"\n"];
        }
    [s writeToFile:@"/tmp/batch.s" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSTask* t = [NSTask new];
    t.launchPath = @"/usr/bin/clang";
    t.arguments = @[ @"-c", @"-target", @"arm64-apple-macos11", @"-o", @"/tmp/batch.o", @"/tmp/batch.s" ];
    NSPipe* ep = [NSPipe pipe];
    t.standardError = ep;
    [t launch];
    [t waitUntilExit];
    if (t.terminationStatus != 0)
        {
        NSData* d = [ep.fileHandleForReading readDataToEndOfFile];
        fprintf(stderr, "clang failed: %s\n", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String);
        return nil;
        }
    // otool -s __TEXT __text /tmp/batch.o  -> hex bytes
    NSTask* o = [NSTask new];
    o.launchPath = @"/usr/bin/otool";
    o.arguments = @[ @"-s", @"__TEXT", @"__text", @"/tmp/batch.o" ];
    NSPipe* op = [NSPipe pipe];
    o.standardOutput = op;
    [o launch];
    NSData* od = [op.fileHandleForReading readDataToEndOfFile];
    [o waitUntilExit];
    NSString* txt = [[NSString alloc] initWithData:od encoding:NSUTF8StringEncoding];
    NSMutableData* out = [NSMutableData data];
    // otool prints: "<16-hex addr> <8-hex word> <8-hex word> ...", words in
    // logical (big-endian text) form == the numeric instruction value.
    for (NSString* ln in [txt componentsSeparatedByString:@"\n"])
        {
        for (NSString* tk in [ln componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]])
            {
            if (tk.length != 8)
                continue; // skip 16-char address + noise
            unsigned v;
            if (![[NSScanner scannerWithString:tk] scanHexInt:&v])
                continue;
            uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
            [out appendBytes:b length:4]; // store little-endian for the reader below
            }
        }
    return out;
    }

int main(int argc, char** argv)
    {
    @autoreleasepool
        {
        if (argc < 2)
            {
            fprintf(stderr, "usage: harness insns.txt\n");
            return 2;
            }
        NSString* file = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:NULL];
        NSMutableArray<NSString*>* lines = [NSMutableArray array];
        for (NSString* l in [file componentsSeparatedByString:@"\n"])
            {
            NSString* t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length)
                [lines addObject:t];
            }
        NSData* ref = clangEncode(lines);
        if (!ref)
            return 1;
        if (ref.length != lines.count * 4)
            {
            fprintf(stderr, "WARN ref bytes %lu != %lu insns*4\n", (unsigned long)ref.length, (unsigned long)lines.count * 4);
            }
        const uint8_t* rb = ref.bytes;
        XAArm64Assembler* as = [XAArm64Assembler new];
        int ok = 0, bad = 0;
        for (NSUInteger i = 0; i < lines.count; i++)
            {
            NSError* e = nil;
            uint32_t w = [as encodeLine:lines[i] pc:i * 4 resolve:nil error:&e];
            uint32_t r = (i * 4 + 3 < ref.length) ? (rb[i * 4] | (rb[i * 4 + 1] << 8) | (rb[i * 4 + 2] << 16) | ((uint32_t)rb[i * 4 + 3] << 24)) : 0xDEADBEEF;
            if (e)
                {
                printf("  ERR  %-40s %s\n", lines[i].UTF8String, e.localizedDescription.UTF8String);
                bad++;
                continue;
                }
            if (w == r)
                ok++;
            else
                {
                printf("  MISS %-40s ours=%08x clang=%08x\n", lines[i].UTF8String, w, r);
                bad++;
                }
            }
        printf("\n%d ok, %d bad, of %lu\n", ok, bad, (unsigned long)lines.count);
        return bad ? 1 : 0;
        }
    }
