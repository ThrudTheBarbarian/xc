// Batch oracle-diff harness for XAX86_64Assembler — the x86-64 analogue of
// tests/asm-arm64/oracle-diff. Reads Intel-syntax instructions (one per line)
// from argv[1], encodes each with our assembler, and byte-compares against
// clang's encoding of the same batch.
//
// x86-64 is VARIABLE length, so we can't chunk the oracle's bytes by a fixed
// width like the AArch64 harness does. Instead we assemble the whole batch with
// clang, disassemble with objdump, and use its per-instruction offsets to slice
// the reference bytes exactly.
#import <Foundation/Foundation.h>
#import "XAX86_64Assembler.h"

// clang-assemble the batch, then objdump it; returns an array of NSData, one per
// input line, or nil on failure.
static NSArray<NSData*>* clangEncode(NSArray<NSString*>* lines)
    {
    NSMutableString* s = [@".intel_syntax noprefix\n.text\n" mutableCopy];
    for (NSString* l in lines)
        {
        [s appendString:l];
        [s appendString:@"\n"];
        }
        // The input is a list of distinct instruction FORMS lifted out of real
        // corpus assembly, so its branch targets and [rip+sym] operands have no
        // definitions here — clang rejects the batch outright ("Undefined temporary
        // symbol .Lf_main_bb_10"). Define every identifier that isn't a register, a
        // mnemonic or a size keyword, at the end where it cannot change any encoding
        // above it: rel32 and disp32 are fixed-width whatever the distance.
        {
        NSRegularExpression* ident =
            [NSRegularExpression regularExpressionWithPattern:@"[A-Za-z_.$][A-Za-z_0-9.$]*"
                                                      options:0
                                                        error:NULL];
        NSMutableSet<NSString*>* seen = [NSMutableSet set];
        for (NSString* l in lines)
            {
            // Skip the mnemonic — only operands can name a symbol.
            NSRange sp = [l rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
            if (sp.location == NSNotFound)
                continue;
            NSString* ops = [l substringFromIndex:sp.location];
            for (NSTextCheckingResult* m in [ident matchesInString:ops
                                                           options:0
                                                             range:NSMakeRange(0, ops.length)])
                {
                NSString* t = [ops substringWithRange:m.range];
                // Registers and `byte/word/dword/qword/xmmword ptr` are not symbols.
                if ([t hasPrefix:@"r"] || [t hasPrefix:@"e"] || [t hasPrefix:@"xmm"] ||
                    t.length <= 3 || [t isEqualToString:@"ptr"] ||
                    [t hasSuffix:@"word"] || [t isEqualToString:@"byte"])
                    continue;
                [seen addObject:t];
                }
            }
        // Push the definitions well out of rel8 reach so clang is forced to the
        // same rel32 forms we emit; otherwise it shortens every nearby branch to
        // two bytes and the comparison is measuring the test setup, not us.
        if (seen.count)
            [s appendString:@".zero 256\n"];
        for (NSString* t in [seen.allObjects sortedArrayUsingSelector:@selector(compare:)])
            [s appendFormat:@"%@:\n", t];
        }
    [s writeToFile:@"/tmp/x86batch.s" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSTask* t = [NSTask new];
    t.launchPath = @"/usr/bin/clang";
    t.arguments = @[ @"-c", @"-target", @"x86_64-unknown-linux-gnu",
                     @"-o", @"/tmp/x86batch.o", @"/tmp/x86batch.s" ];
    NSPipe* ep = [NSPipe pipe];
    t.standardError = ep;
    [t launch];
    [t waitUntilExit];
    if (t.terminationStatus != 0)
        {
        NSData* d = [ep.fileHandleForReading readDataToEndOfFile];
        fprintf(stderr, "clang failed: %s\n",
                [[NSString alloc] initWithData:d
                                      encoding:NSUTF8StringEncoding]
                    .UTF8String);
        return nil;
        }
    NSTask* o = [NSTask new];
    o.launchPath = @"/usr/bin/objdump";
    o.arguments = @[ @"-d", @"--no-show-raw-insn", @"/tmp/x86batch.o" ];
    // (we want raw insn bytes, so re-run without the suppressing flag)
    o.arguments = @[ @"-d", @"/tmp/x86batch.o" ];
    NSPipe* op = [NSPipe pipe];
    o.standardOutput = op;
    [o launch];
    NSData* od = [op.fileHandleForReading readDataToEndOfFile];
    [o waitUntilExit];
    NSString* txt = [[NSString alloc] initWithData:od encoding:NSUTF8StringEncoding];
    // objdump lines look like:  "       0: 48 89 c3   \tmovq %rax, %rbx"
    NSMutableArray<NSData*>* out = [NSMutableArray array];
    for (NSString* ln in [txt componentsSeparatedByString:@"\n"])
        {
        NSRange colon = [ln rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString* head = [ln substringToIndex:colon.location];
        if ([head stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length == 0)
            continue;
        unsigned dummy;
        if (![[NSScanner scannerWithString:head] scanHexInt:&dummy])
            continue;
        NSString* rest = [ln substringFromIndex:colon.location + 1];
        NSRange tab = [rest rangeOfString:@"\t"];
        NSString* hex = tab.location == NSNotFound ? rest : [rest substringToIndex:tab.location];
        NSMutableData* bytes = [NSMutableData data];
        for (NSString* tk in [hex componentsSeparatedByCharactersInSet:
                                      [NSCharacterSet whitespaceCharacterSet]])
            {
            if (tk.length != 2)
                continue;
            unsigned v;
            if (![[NSScanner scannerWithString:tk] scanHexInt:&v])
                continue;
            uint8_t b = (uint8_t)v;
            [bytes appendBytes:&b length:1];
            }
        if (bytes.length)
            [out addObject:bytes];
        }
    return out;
    }

static NSString* hexOf(NSData* d)
    {
    NSMutableString* s = [NSMutableString string];
    const uint8_t* b = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++)
        [s appendFormat:@"%02x ", b[i]];
    return s;
    }

int main(int argc, char** argv)
    {
    @autoreleasepool
        {
        if (argc < 2)
            {
            fprintf(stderr, "usage: harness [-c] insns.txt\n");
            return 2;
            }
        // -c: COVERAGE mode. Skip clang entirely and just report which forms our
        // encoder cannot encode yet. Used to drive the encoder against the real
        // corpus instruction stream, which clang can't assemble out of context
        // (undefined symbols, labels) but which we still want coverage numbers for.
        if (strcmp(argv[1], "-c") == 0)
            {
            if (argc < 3)
                {
                fprintf(stderr, "usage: harness -c insns.txt\n");
                return 2;
                }
            NSString* ct = [NSString stringWithContentsOfFile:@(argv[2])
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
            NSMutableDictionary<NSString*, NSNumber*>* missing = [NSMutableDictionary dictionary];
            NSUInteger enc = 0, tot = 0;
            for (NSString* l in [ct componentsSeparatedByString:@"\n"])
                {
                NSString* ln = [l stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceCharacterSet]];
                if (!ln.length || [ln hasPrefix:@"."] || [ln hasSuffix:@":"])
                    continue;
                tot++;
                XAX86_64Assembler* as = [[XAX86_64Assembler alloc] init];
                if ([as encodeOne:ln error:NULL])
                    {
                    enc++;
                    continue;
                    }
                NSRange sp = [ln rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
                NSString* mn = sp.location == NSNotFound ? ln : [ln substringToIndex:sp.location];
                missing[mn] = @(missing[mn].integerValue + 1);
                }
            printf("encodable: %lu / %lu (%.1f%%)\n", (unsigned long)enc, (unsigned long)tot,
                   tot ? 100.0 * enc / tot : 0.0);
            NSArray* keys = [missing keysSortedByValueUsingComparator:^(NSNumber* x, NSNumber* y) {
              return [y compare:x];
            }];
            printf("unhandled mnemonics (by frequency):\n  ");
            for (NSString* k in keys)
                printf("%s(%s) ", k.UTF8String, missing[k].stringValue.UTF8String);
            printf("\n");
            return 0;
            }
        NSString* txt = [NSString stringWithContentsOfFile:@(argv[1])
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if (!txt)
            {
            fprintf(stderr, "cannot read %s\n", argv[1]);
            return 2;
            }
        NSMutableArray<NSString*>* lines = [NSMutableArray array];
        for (NSString* l in [txt componentsSeparatedByString:@"\n"])
            {
            NSString* s = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (s.length)
                [lines addObject:s];
            }
        NSArray<NSData*>* ref = clangEncode(lines);
        if (!ref)
            return 1;
        if (ref.count != lines.count)
            {
            fprintf(stderr, "note: clang produced %lu insns for %lu lines "
                            "(a line may have assembled to multiple instructions)\n",
                    (unsigned long)ref.count, (unsigned long)lines.count);
            }
        NSUInteger ok = 0, bad = 0, n = MIN(ref.count, lines.count);
        for (NSUInteger i = 0; i < n; i++)
            {
            NSError* e = nil;
            XAX86_64Assembler* as = [[XAX86_64Assembler alloc] init];
            NSData* mine = [as encodeOne:lines[i] error:&e];
            if (!mine)
                {
                printf("  ERR  %-42s %s\n", lines[i].UTF8String,
                       e ? e.localizedDescription.UTF8String : "(unencodable)");
                bad++;
                continue;
                }
            if ([mine isEqualToData:ref[i]])
                {
                ok++;
                continue;
                }
            // Any field we record a fixup for — a branch rel32, a [rip+sym] disp32 —
            // is deliberately left zero here and filled at link time from the fixup.
            // Those four bytes are not ours to get right, so blank them in BOTH sides
            // before comparing; everything else, including the length, still has to
            // match clang exactly.
            if (as.fixups.count && mine.length == ref[i].length)
                {
                NSMutableData *a = [mine mutableCopy], *b = [ref[i] mutableCopy];
                for (XAX86_64Fixup* f in as.fixups)
                    {
                    if (f.offset + 4 > a.length)
                        continue;
                    memset((uint8_t*)a.mutableBytes + f.offset, 0, 4);
                    memset((uint8_t*)b.mutableBytes + f.offset, 0, 4);
                    }
                if ([a isEqualToData:b])
                    {
                    ok++;
                    continue;
                    }
                }
            printf("  DIFF %-42s ours[%s] clang[%s]\n", lines[i].UTF8String,
                   hexOf(mine).UTF8String, hexOf(ref[i]).UTF8String);
            bad++;
            }
        printf("\n%lu ok, %lu bad, of %lu\n", (unsigned long)ok, (unsigned long)bad, (unsigned long)n);
        return bad ? 1 : 0;
        }
    }
