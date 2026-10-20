// XTIROptVecCombine.h — the vectoriser's output, two shapes made one op
#import "XTIROptPass.h"
#import "XTIROptTargetProfile.h"

NS_ASSUME_NONNULL_BEGIN

// Two shapes of the vectoriser's output made one op where the back end has it
// (vectorizesBitSelect: arm64):
//   VOr(VShl(x, c), VLShr(x, w - c))          → VRotl x, c
//   VOr(VAnd(m, a), VAnd(VNot(m), b))         → VBsl m, a, b
//   VXor(b, VAnd(m, VXor(a, b)))              → VBsl m, a, b
// (the last is the xor form of the same select, md5_mask's F and G) with
// either operand of an Or, Xor or And in either place (MD5's F is the
// second as written, its G with the Not on the other side; every round's
// rotate the first). Each inner node must have this one use and be in the
// same block. The nodes a match consumed go with it (dead-code keeps vector
// ops). Then, in a big block, the integer constants' splats become loads from
// a read-only table (see poolBlock). -O2+, straight after the vectoriser. As the port's vec-combine
// (selfhost/opt/Opt.xc).
@interface XTIROptVecCombine : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
/// The late instance (vec-pool): only the constant tables, after the last LICM.
@property(nonatomic) BOOL pool;
/// The combine on one function (the vectoriser runs it before its unroller).
- (void)runOnFunction:(XTIRFunction*)fn;
@end

NS_ASSUME_NONNULL_END
