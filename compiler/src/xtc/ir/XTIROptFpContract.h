// XTIROptFpContract.h — float multiply-adds that may fuse under :goal(speed)
#import "XTIROptPass.h"

@class XTIRBlock;
@class XTIRFunction;

NS_ASSUME_NONNULL_BEGIN

// Code under `:goal(speed)` (a `par` block's run function, a loop marked so)
// may fuse a float multiply with the add or subtract that consumes it, rounding
// once (FMA). Owner, 2026-10-26: x86-64 does it only there, so a plain loop's
// answer never depends on the CPU running it. Every scalar FAdd and FSub in a
// speed loop is marked XTIRFpContract (printed `contract`); the back end fuses
// those with a product for an operand where the code has FMA (x86-64's avx2
// and avx512 copies). A speed loop is the cycle through its header: the blocks
// reachable from it that reach it again, inner loops included. -O2+, after
// everything that rebuilds instructions, so the mark is not lost on the way.
// As the port's fp-contract (selfhost/opt/Opt.xc).
@interface XTIROptFpContract : NSObject <XTIROptPass>
@end

// Whether a block named `name` heads a speed loop of fn, or a copy of one.
BOOL XTIRFpcSpeedName(XTIRFunction* fn, NSString* name);
// Every float add and subtract in bb marked to fuse with a product: a speed
// loop's block, or the loop unroller's copy of one, which no header names
// once the loop is gone (#24). As the port's fpcMarkBlock.
void XTIRFpcMarkBlock(XTIRBlock* bb);

NS_ASSUME_NONNULL_END
