/****************************************************************************\
|* XAM68kAssemblerTests.m
|*
|* The reference 68k assembler's REFUSALS. Nothing else can reach them: the
|* driver only ever feeds it the back end's own output, and as68-diff compares
|* it against the port on that same output — so a hand-written case that must
|* be REJECTED has no harness but this one.
|*
|* Each case is a bug that shipped silently before the check existed:
|*   - a symbol of 80+ bytes was clipped to 79 by `strncpy` on the USE, the
|*     lookup missed, and `symVal` answered 0 — 64 `bra`s to offset 0 in one
|*     function (private:docs/bugs/126);
|*   - an undefined symbol resolved to 0 in pass 2 with nothing said, which is
|*     how m68k assembled `jsr 0` for every file call (127);
|*   - a label defined twice was a dictionary overwrite, so a program with two
|*     `_start`s assembled — and GEMDOS entered the wrong one (128).
\****************************************************************************/
#import <Foundation/Foundation.h>
#import "XAM68kAssembler.h"

static XAM68kAssembler* asm68(void)
    {
    return [[XAM68kAssembler alloc] init];
    }

// Assemble `src`; return the error (nil on success).
static NSString* errorFor(NSString* src, NSData** outImage)
    {
    NSString* err = nil;
    NSData* img = [asm68() assemble:src error:&err];
    if (outImage)
        *outImage = img;
    if (!img && !err)
        return @"(failed with no message)";
    return img ? nil : err;
    }

int runM68kAssemblerTests(void);
int runM68kAssemblerTests(void)
    {
    int failures = 0;
    fprintf(stderr, "XAM68kAssembler refusals:\n");

    // 1. A long label RESOLVES, and to the same place as a short one.
    NSString* longLabel = [@"." stringByPaddingToLength:90 withString:@"L" startingAtIndex:0];
    NSString* withLong = [NSString stringWithFormat:
                                       @"\t.text\n_start:\n\tbra\t%@\n%@:\n\tnop\n\trts\n", longLabel, longLabel];
    NSString* withShort = @"\t.text\n_start:\n\tbra\t.s\n.s:\n\tnop\n\trts\n";
    NSData *a = nil, *b = nil;
    NSString *e1 = errorFor(withLong, &a), *e2 = errorFor(withShort, &b);
    if (e1 || e2 || ![a isEqualToData:b])
        {
        fprintf(stderr, "  FAIL: 90-byte label: %s\n",
                e1 ? e1.UTF8String : e2 ? e2.UTF8String
                                        : "image differs from the short-label image");
        failures++;
        }
    else
        {
        fprintf(stderr, "  PASS: 90-byte label resolves like a short one (%lu bytes)\n",
                (unsigned long)a.length);
        }

    // 2. An over-long symbol is REFUSED, never clipped.
    NSString* huge = [@"." stringByPaddingToLength:300 withString:@"H" startingAtIndex:0];
    NSString* e3 = errorFor([NSString stringWithFormat:@"\t.text\n\tbra\t%@\n%@:\n\trts\n", huge, huge], NULL);
    if (!e3 || [e3 rangeOfString:@"at most"].location == NSNotFound)
        {
        fprintf(stderr, "  FAIL: 300-byte symbol: %s\n", e3 ? e3.UTF8String : "assembled");
        failures++;
        }
    else
        fprintf(stderr, "  PASS: 300-byte symbol refused: %s\n", e3.UTF8String);

    // 3. An undefined symbol is a hard error that NAMES the symbol.
    NSString* e4 = errorFor(@"\t.text\n_start:\n\tjsr\t_xt_nowhere\n\trts\n", NULL);
    if (!e4 || [e4 rangeOfString:@"_xt_nowhere"].location == NSNotFound)
        {
        fprintf(stderr, "  FAIL: undefined symbol: %s\n", e4 ? e4.UTF8String : "assembled (resolved to 0)");
        failures++;
        }
    else
        fprintf(stderr, "  PASS: undefined symbol refused: %s\n", e4.UTF8String);

    // 4. A duplicate label is a hard error.
    NSString* e5 = errorFor(@"\t.text\n_start:\n\tnop\n_start:\n\trts\n", NULL);
    if (!e5 || [e5 rangeOfString:@"duplicate"].location == NSNotFound)
        {
        fprintf(stderr, "  FAIL: duplicate label: %s\n", e5 ? e5.UTF8String : "assembled (later one won)");
        failures++;
        }
    else
        fprintf(stderr, "  PASS: duplicate label refused: %s\n", e5.UTF8String);

    // 5. Forward references still work — pass 1 must not trip the undefined check.
    NSString* e6 = errorFor(@"\t.text\n_start:\n\tbra\t.fwd\n\tnop\n.fwd:\n\trts\n", NULL);
    if (e6)
        {
        fprintf(stderr, "  FAIL: forward reference: %s\n", e6.UTF8String);
        failures++;
        }
    else
        fprintf(stderr, "  PASS: forward reference resolves\n");

    fprintf(stderr, "  [%d failure(s)]\n", failures);
    return failures;
    }
