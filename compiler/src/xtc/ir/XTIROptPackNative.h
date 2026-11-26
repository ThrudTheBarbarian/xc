#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIROptTargetProfile;

// The 16-bit floats' conversions in the target's own instructions, where it
// has them (float sizes, step F5a).
//
// The lowering emits every f16 and bf16 conversion as a call of FloatPack.xc
// (`_xt_fpk_unpack`, `_xt_fpk_pack_f32`, ...), and every operation as a
// conversion to f32, the f32 operation and a rounding back. This pass, the
// last of the pipeline at every level, rewrites the calls the profile says the
// back end can do itself, each into IR whose result is the call's bit for
// bit:
//
//   * bf16 (pack e8m7), profile packBF16Inline: to f32 is the pattern shifted
//     into the top half of an f32; from f32 is round to nearest even on the
//     bits, `(x + 0x7FFF + ((x >> 16) & 1)) >> 16`, with a NaN made quiet
//     (`(x >> 16) | 0x40`), which is what FloatPack's rounding gives.
//   * f16 (pack e5m10), profile packF16Hardware: `FpExt %h:U16` to F32 and
//     `FpTrunc` to U16 (from F32, and from F64 where packF16FromF64), which
//     the back end lowers to its half-precision conversions (arm64 `fcvt`,
//     x86-64 F16C). An integer goes through the f32 it converts to exactly or
//     past f16's range. A hardware widening quiets a signalling NaN, where
//     FloatPack keeps it; where a use could tell, the f32's quiet bit is
//     cleared again for exactly those patterns.
//   * f16 arithmetic, profile packF16Arith (arm64 FEAT_FP16): an f32 +, -, *,
//     / or sqrt of two converted halves, rounded back to f16, is the same
//     operation in half precision (`FAdd %a:U16, %b:U16`), and a comparison of
//     two converted halves compares the halves (`FCmp` on U16).
//
// Other packs, the kinds' routines and the integer conversions from a pack
// keep their calls.
@interface XTIROptPackNative : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
