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
+ (nullable NSString*)sourceForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                                   why:(NSString* _Nullable* _Nullable)why;
// As above, given each reduction field's operator by field index (bug 645):
// the kernel then combines its reductions per threadgroup of 256.
+ (nullable NSString*)sourceForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                                redOps:(nullable NSDictionary<NSNumber*, NSString*>*)redOps
                                   why:(NSString* _Nullable* _Nullable)why;

@end

// The same kernel as PTX for NVIDIA GPUs (XTIRParPTX.m); nil keeps the block
// on the CPU.
@interface XTIRParMSL (SPIRV)
// The kernel as a SPIR-V module for Vulkan: the header line (ending
// ` spirv=<words>`), a NUL, padding to a 4-byte boundary, then the words.
+ (nullable NSData*)spirvForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                               why:(NSString* _Nullable* _Nullable)why;
+ (nullable NSData*)spirvForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                            redOps:(nullable NSDictionary<NSNumber*, NSString*>*)redOps
                               why:(NSString* _Nullable* _Nullable)why;
@end

@interface XTIRParMSL (WGSL)
// The kernel in WGSL for WebGPU (wasm32): the header line (ending ` wgsl`,
// then ` fast` for a speed block), then the WGSL text.
+ (nullable NSString*)wgslForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                                why:(NSString* _Nullable* _Nullable)why;
+ (nullable NSString*)wgslForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                             redOps:(nullable NSDictionary<NSNumber*, NSString*>*)redOps
                                why:(NSString* _Nullable* _Nullable)why;
@end

@interface XTIRParMSL (PTX)
+ (nullable NSString*)ptxForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                                why:(NSString* _Nullable* _Nullable)why;
// As above, given each reduction field's operator by field index (bug 645):
// the kernel then combines its reductions per workgroup on the device.
+ (nullable NSString*)ptxForKernel:(XTIRFunction*)run module:(XTIRModule*)module fast:(BOOL)fast
                             redOps:(nullable NSDictionary<NSNumber*, NSString*>*)redOps
                                why:(NSString* _Nullable* _Nullable)why;
@end

NS_ASSUME_NONNULL_END
