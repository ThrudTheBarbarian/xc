/****************************************************************************\
|* XTMachOToElfArm64.m — see the header for why this is not in main.m.
\****************************************************************************/

#import "XTMachOToElfArm64.h"
#import "XTRegexCompat.h"

NSString* XTMachOToElfArm64Ex(NSString* asm_, BOOL shared)
    {
    if (!asm_)
        return @"";
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    NSRegularExpression* (^rx)(NSString*) = ^(NSString* p) {
      return [NSRegularExpression regularExpressionWithPattern:p options:0 error:NULL];
    };
    NSRegularExpression* strip = rx(@"(^|[\\s,\\[])_([A-Za-z_$.])");
    NSRegularExpression* gotoff = rx(@"([A-Za-z_$.][A-Za-z0-9_$.]*)@GOTPAGEOFF");
    NSRegularExpression* gotpg = rx(@"([A-Za-z_$.][A-Za-z0-9_$.]*)@GOTPAGE");
    NSRegularExpression* pgoff = rx(@"([A-Za-z_$.][A-Za-z0-9_$.]*)@PAGEOFF");
    NSRegularExpression* pg = rx(@"([A-Za-z_$.][A-Za-z0-9_$.]*)@PAGE");
    // `.comm name, size[, align]`. The third operand is LOG2 in Mach-O and
    // BYTES in ELF — the same directive means different numbers on the two
    // sides, so it has to be converted, not copied (uxkit/029 started emitting
    // it, and `.comm g, 8, 3` is "alignment must be a power of 2" to the ELF
    // assembler).
    NSRegularExpression* commRx = rx(@"^\\.comm\\s+([A-Za-z0-9_$.]+)\\s*,\\s*(\\d+)\\s*(?:,\\s*(\\d+))?");
    NSRegularExpression* globlRx = rx(@"^\\.globl\\s+([A-Za-z0-9_$.]+)");
    NSString* section = @"    .text";
    NSString* (^sub)(NSRegularExpression*, NSString*, NSString*) =
        ^(NSRegularExpression* re, NSString* tmpl, NSString* s) {
          // Through XTRegexReplace, not the framework call directly: GNUstep
          // returns nil for a blank line and assembly is full of them. See
          // XTRegexCompat.h.
          return XTRegexReplace(re, s, tmpl);
        };
    for (NSString* lineIn in [asm_ componentsSeparatedByString:@"\n"])
        {
        NSString* l = lineIn;
        // Sections (Mach-O → ELF). A prefix match keeps the trailing attributes off.
        if ([l containsString:@".section"])
            {
            if ([l containsString:@"__TEXT,__cstring"])
                l = @"    .section .rodata";
            else if ([l containsString:@"__TEXT,__const"])
                l = @"    .section .rodata";
            else if ([l containsString:@"__DATA,__const"])
                l = @"    .section .rodata";
            else if ([l containsString:@"__DATA,__data"])
                l = @"    .data";
            else if ([l containsString:@"__mod_init_func"])
                l = @"    .section .init_array,\"aw\",%init_array";
            else if ([l containsString:@"__TEXT,__text"])
                l = @"    .text";
            }
        l = sub(strip, @"$1$2", l); // one leading underscore off every symbol
        l = sub(gotoff, @":got_lo12:$1", l);
        l = sub(gotpg, @":got:$1", l);
        l = sub(pgoff, @":lo12:$1", l);
        l = sub(pg, @"$1", l);
        // `.comm`'s third operand is LOG2 on Mach-O and BYTES on ELF, so it is
        // CONVERTED on the way across, never copied. Applies to the non-shared
        // rewrite too — this is the clang/NDK executable path, where a copied
        // `.comm gStash, 8, 3` is rejected outright ("alignment must be a power
        // of 2"). The shared path below drops the directive entirely for a
        // concrete .bss object, so it converts to `.p2align` instead.
        if (!shared)
            {
            NSString* t = [l stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
            NSTextCheckingResult* cm = [commRx firstMatchInString:t
                                                          options:0
                                                            range:NSMakeRange(0, t.length)];
            if (cm && [cm rangeAtIndex:3].location != NSNotFound)
                {
                NSString* n = [t substringWithRange:[cm rangeAtIndex:1]];
                NSString* sz = [t substringWithRange:[cm rangeAtIndex:2]];
                NSUInteger log2 = (NSUInteger)
                    [[t substringWithRange:[cm rangeAtIndex:3]] integerValue];
                [out addObject:[NSString stringWithFormat:@"    .comm %@,%@,%lu",
                                                          n, sz, (unsigned long)(1UL << log2)]];
                continue;
                }
            }
        if (shared)
            {
            NSString* t = [l stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
            // Track the section we are in so a .comm can restore it.
            if ([t hasPrefix:@".text"])
                section = @"    .text";
            else if ([t hasPrefix:@".data"])
                section = @"    .data";
            else if ([t hasPrefix:@".section"])
                section = l;
            NSTextCheckingResult* cm = [commRx firstMatchInString:t
                                                          options:0
                                                            range:NSMakeRange(0, t.length)];
            if (cm)
                {
                NSString* n = [t substringWithRange:[cm rangeAtIndex:1]];
                NSString* sz = [t substringWithRange:[cm rangeAtIndex:2]];
                // The emitted alignment, as LOG2 (Mach-O's spelling). Absent on
                // asm that predates uxkit/029; 3 keeps the old behaviour, which
                // is also the safe answer for anything that may hold a pointer.
                NSUInteger log2 = 3;
                if ([cm rangeAtIndex:3].location != NSNotFound)
                    log2 = (NSUInteger)[[t substringWithRange:[cm rangeAtIndex:3]] integerValue];
                [out addObjectsFromArray:@[
                    [NSString stringWithFormat:@"    .globl %@", n],
                    [NSString stringWithFormat:@"    .hidden %@", n],
                    @"    .bss",
                    [NSString stringWithFormat:@"    .p2align %lu", (unsigned long)log2],
                    [NSString stringWithFormat:@"%@:", n],
                    [NSString stringWithFormat:@"    .zero %@", sz],
                    section
                ]];
                continue;
                }
            [out addObject:l];
            NSTextCheckingResult* gm = [globlRx firstMatchInString:t
                                                           options:0
                                                             range:NSMakeRange(0, t.length)];
            if (gm)
                [out addObject:[NSString stringWithFormat:@"    .hidden %@",
                                                          [t substringWithRange:[gm rangeAtIndex:1]]]];
            continue;
            }
        [out addObject:l];
        }
    return [out componentsJoinedByString:@"\n"];
    }

NSString* XTMachOToElfArm64(NSString* asm_)
    {
    return XTMachOToElfArm64Ex(asm_, NO);
    }
