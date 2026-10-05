// XTIROptSimdClone.m — runtime SIMD dispatch: the per-level clones. See the header.
#import "XTIROptSimdClone.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRType.h"
#import "XTIRValue.h"
#import "XTIRPrinter.h"
#import "XTIRParser.h"

@implementation XTIROptSimdClone

- (NSString*)passName
    {
    return self.prune ? @"simd-prune" : @"simd-clone";
    }
- (NSInteger)minOptLevel
    {
    return 2;
    }

// A function worth cloning has a loop, and in this IR every loop header holds
// a phi (the induction variable at least).
static BOOL hasPhi(XTIRFunction* fn)
    {
    for (XTIRBlock* b in fn.blocks)
        if (b.phiNodes.count)
            return YES;
    return NO;
    }

// Does the clone use vectors of its own level's width (32 bytes for avx2, 64
// for avx512)? One that does not gained nothing over the base, and goes.
static BOOL hasWideVector(XTIRFunction* fn, uint32_t bytes)
    {
    for (NSNumber* k in fn.values)
        {
        XTIRValue* v = fn.values[k];
        if (v.type.kind == XTIRTypeKindVec && v.type.byteWidth == bytes)
            return YES;
        }
    return NO;
    }

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors
    {
    (void)outErrors;
    if (!self.profile.simdDispatch || !self.profile.vectorizesLoops)
        return YES;
    if (self.prune)
        {
        NSMutableDictionary<NSString*, XTIRFunction*>* byName = [NSMutableDictionary dictionary];
        for (XTIRFunction* fn in mod.functions)
            byName[fn.name] = fn;
        NSMutableArray<XTIRFunction*>* drop = [NSMutableArray array];
        for (XTIRFunction* fn in mod.functions)
            {
            if (!fn.simdLevel)
                continue;
            XTIRFunction* base = byName[fn.simdBaseName];
            if (base && hasWideVector(fn, (uint32_t)fn.simdLaneBytes))
                base.simdDispatch = YES;
            else
                [drop addObject:fn];
            }
        [mod.functions removeObjectsInArray:drop];
        return YES;
        }
    // CLONE. The copy comes from a printed and re-parsed module: the printer
    // and parser are the IR's own round trip (the front end hands the code
    // generator its module that way), so the clone is exact, and its symbol,
    // constant and layout ids match this module's because both list the same
    // tables in the same order.
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    for (XTIRFunction* fn in mod.functions)
        if (!fn.simdLevel && hasPhi(fn))
            [names addObject:fn.name];
    if (!names.count)
        return YES;
    NSString* printed = [XTIRPrinter stringFromModule:mod];
    // One copy per level, each from its own parse: the avx2 clones join the
    // module before the avx512 copy is taken, so it is taken from the text.
    NSMutableArray<XTIRModule*>* copies = [NSMutableArray array];
    for (int k = 0; k < 2; k++)
        {
        XTIRModule* copy = [XTIRParser moduleFromString:printed sharingLayoutsOf:mod error:NULL];
        // The copy must print back exactly as the original did: a round
        // trip that loses anything (a construct the parser does not read)
        // would make the clone a different program. Then nothing is cloned,
        // and every function keeps its one base version — slower, never wrong.
        if (!copy || ![[XTIRPrinter stringFromModule:copy] isEqualToString:printed])
            return YES;
        [copies addObject:copy];
        }
    NSArray* levels = @[@"avx2", @"avx512"];
    NSArray* widths = @[@32, @64];
    for (NSUInteger k = 0; k < levels.count; k++)
        {
        NSMutableDictionary<NSString*, XTIRFunction*>* byName = [NSMutableDictionary dictionary];
        for (XTIRFunction* fn in copies[k].functions)
            byName[fn.name] = fn;
        for (NSString* n in names)
            {
            XTIRFunction* c = byName[n];
            if (!c)
                continue;
            [c renameTo:[NSString stringWithFormat:@"%@$%@", n, levels[k]]];
            c.simdLaneBytes = [widths[k] unsignedIntValue];
            c.simdLevel = levels[k];
            c.simdBaseName = n;
            [mod addFunction:c];
            }
        }
    return YES;
    }

@end
