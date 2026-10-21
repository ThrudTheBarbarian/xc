#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIROptTargetProfile;

// gpu-globals: a numeric global array of 64 KB or more gets pages of its own,
// as a heap array of that size does (rt.c's _xtc_alloc_aligned). It is marked
// `gpupage` (the back end puts it on a 16 KB boundary and pads it to whole
// 16 KB pages), and __xt_gpu_globals, which the par runtime declares and calls
// on its block registry's first use, registers it (_xtc_simd_register), so a
// par block's GPU runtime shares it in place on a unified-memory GPU and keeps
// an unwritten copy resident on a discrete one. Defined only where declared;
// on arm64, x86-64 and win64; at every level. Mirrors the self-hosted
// Opt.gpuGlobals.
@interface XTIROptGpuGlobals : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
