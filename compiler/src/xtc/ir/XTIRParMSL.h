#import <Foundation/Foundation.h>

@class XTIRModule;
@class XTIRFunction;

NS_ASSUME_NONNULL_BEGIN

// A `par` block's kernel printed as Metal Shading Language (par-blocks.md §6).
//
// The kernel is the block's CPU chunk method, `ParImpl$<n>$run`, which loops
// over [lo, hi). Each GPU thread runs that loop over its own slice: it takes a
// private copy of the block object's bytes (`args`), sets lo/hi from its
// thread index and the span, reads the captured arrays through `device`
// buffers, and writes each reduction's partial to `red_<k>[tid]`, which the
// host folds in thread order. Control flow is printed as a `pc` dispatch loop,
// which is correct for any CFG (MSL has no goto).
//
// The first line is a comment the runtime reads:
//   // xcpar size=<bytes> lo=<off> hi=<off> buf=<off>:<own-ivar>:<elem-bytes>… red=<off>:<bytes>…
// Buffers are bound from index 2 in field order, then the reductions; 0 is the
// object's bytes and 1 the span {base, end, per}.
@interface XTIRParMSL : NSObject

// The kernel's MSL, or nil when this block cannot run on Metal: it uses f64
// (§7), a global, a call other than the maths intrinsics, or IR the printer
// does not know. A nil block runs on the CPU.
+ (nullable NSString*)sourceForKernel:(XTIRFunction*)run module:(XTIRModule*)module;

@end

NS_ASSUME_NONNULL_END
