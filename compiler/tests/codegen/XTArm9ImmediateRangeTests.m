// XTArm9ImmediateRangeTests.m — no arm9 memory operand may carry an offset the
// A32 encoding cannot hold.
//
// THE INVARIANT
// -------------
// A32's `ldr`/`str` reach ±4095 from the base register. Anything the backend
// wants to address further away must fold the excess into the base FIRST. The
// two places that can genuinely go past 4095 are:
//
//   - a vtable slot load. xtc dispatches by method NAME, so a slot index is a
//     translation-unit-wide method-name id, and EVERY class's vtable is as wide
//     as the number of distinct method names in the unit — however few methods
//     the class itself has. 1377 slots (5508 bytes) is an ordinary size for a
//     GUI library.
//   - a block copy of an aggregate bigger than 4 KB.
//
// WHY THIS TEST EXISTS
// --------------------
// Because the failure is a CLIFF, not a slope, and it lands in the assembler
// rather than anywhere near the cause. One method name past 1024 and every
// dispatch to a high slot fails with `Error: bad immediate value for offset
// (4748)` — 392 of them in the build that reported it (XG bug 021), naming a
// temporary .s file and no source line. Nothing below the cliff misbehaves, so
// no ordinary fixture catches the regression: the corpus's vtables are tiny.
//
// The first diagnosis of that report blamed "a far global in a large data
// section", because vtables live in the data section and the two grow together.
// They are not the same variable. If this test fails, the cap on method names
// per translation unit is back — do not go looking at global addressing.

#import <Foundation/Foundation.h>
#import "XTArm9Backend.h"

@interface XTArm9Backend (FarOffsetProbe)
+ (void)emitFarLoad:(NSString*)reg base:(NSString*)base off:(NSUInteger)off
                out:(NSMutableString*)out;
+ (NSUInteger)rebase:(NSString*)addr off:(NSUInteger)off bias:(NSUInteger)bias
                 out:(NSMutableString*)out;
@end

static int gFailures;

static void expectAsm(const char* what, NSString* got, NSString* want)
    {
    if ([got isEqualToString:want])
        {
        fprintf(stderr, "  PASS: %s\n", what);
        }
    else
        {
        gFailures++;
        fprintf(stderr, "  FAIL: %s\n    got  %s\n    want %s\n", what,
                [[got stringByReplacingOccurrencesOfString:@"\n" withString:@" | "] UTF8String],
                [[want stringByReplacingOccurrencesOfString:@"\n" withString:@" | "] UTF8String]);
        }
    }

// Every offset an emitted `[reg, #imm]` carries must be within range. Scanning
// the text is the honest check: it is what the assembler sees.
static void expectAllOffsetsEncodable(const char* what, NSString* asmText)
    {
    __block int bad = 0;
    NSRegularExpression* re =
        [NSRegularExpression regularExpressionWithPattern:@"\\[[^]]*#(\\d+)\\]"
                                                  options:0
                                                    error:NULL];
    [re enumerateMatchesInString:asmText
                         options:0
                           range:NSMakeRange(0, asmText.length)
                      usingBlock:^(NSTextCheckingResult* m, NSMatchingFlags f, BOOL* stop) {
                        (void)f;
                        (void)stop;
                        NSInteger off = [[asmText substringWithRange:[m rangeAtIndex:1]] integerValue];
                        if (off > 4095)
                            bad++;
                      }];
    if (bad == 0)
        {
        fprintf(stderr, "  PASS: %s\n", what);
        }
    else
        {
        gFailures++;
        fprintf(stderr, "  FAIL: %s — %d offset(s) past 4095\n", what, bad);
        }
    }

int runArm9ImmediateRangeTests(void)
    {
    gFailures = 0;

    // In range: unchanged, a bare load. (A regression that always added would
    // cost two instructions on every dispatch in every program.)
    NSMutableString* o = [NSMutableString string];
    [XTArm9Backend emitFarLoad:@"r12" base:@"r12" off:652 out:o];
    expectAsm("slot 163 (652 bytes) stays a single ldr", o, @"\tldr\tr12, [r12, #652]\n");

    // The reported case: slot 1187 of a 1377-slot vtable.
    o = [NSMutableString string];
    [XTArm9Backend emitFarLoad:@"r12" base:@"r12" off:4748 out:o];
    expectAsm("slot 1187 (4748 bytes) folds 4096 into the base", o,
              @"\tadd\tr12, r12, #4096\n\tldr\tr12, [r12, #652]\n");

    // Exactly on the boundary, both sides.
    o = [NSMutableString string];
    [XTArm9Backend emitFarLoad:@"r12" base:@"r12" off:4095 out:o];
    expectAsm("4095 is the last single-instruction offset", o,
              @"\tldr\tr12, [r12, #4095]\n");
    o = [NSMutableString string];
    [XTArm9Backend emitFarLoad:@"r12" base:@"r12" off:4096 out:o];
    expectAsm("4096 is the first that must fold", o,
              @"\tadd\tr12, r12, #4096\n\tldr\tr12, [r12, #0]\n");

    // Far enough that the fold itself needs more than one add: every `add`
    // immediate must stay an encodable rotated constant, so the high bits come
    // off in multiples of 4096, at most 0xFF000 at a time.
    o = [NSMutableString string];
    [XTArm9Backend emitFarLoad:@"r12" base:@"r12" off:0x123456 out:o];
    expectAllOffsetsEncodable("a 1.2 MB offset still emits only encodable loads", o);
    expectAsm("a 1.2 MB offset peels 0xFF000 at a time", o,
              @"\tadd\tr12, r12, #1044480\n\tadd\tr12, r12, #147456\n"
              @"\tldr\tr12, [r12, #1110]\n");

    // The block-copy rebase: walking a 5 KB struct must never emit an offset
    // past the encodable window.
    o = [NSMutableString string];
    NSUInteger bias = 0;
    for (NSUInteger i = 0; i + 4 <= 5120; i += 4)
        {
        bias = [XTArm9Backend rebase:@"r1" off:i bias:bias out:o];
        [o appendFormat:@"\tldr\tr2, [r1, #%lu]\n", (unsigned long)(i - bias)];
        }
    expectAllOffsetsEncodable("a 5 KB block copy keeps its base in range", o);

    return gFailures;
    }
