// XTIROptOuterUnroll.h — a counted loop around one inner loop that exits on
// data it loads runs K copies of its body per trip (#41).
//
// The rotated shape LoopRotate leaves:
//
//     B:   phi i = [(pre, S), (L, next)] ...  <body, inner loop> ...
//     L:   next = Add i, 1; c = ICmp ULT|SLT|NE next, N; CondBranch c, B, X
//
// with S and N constants, so the trip T = N - S, and K the largest of 4, 3
// and 2 dividing T. Copy j starts from the values copy j-1 sends back; the
// copies run in order, so nothing needs to be independent. Each copy has its
// own inner loop and so its own exit branch, with its own predictor history
// for that position's trip count (clang does the same to sort_small).
//
// The loop has no other exit and no call, its body is small, and its one
// inner loop is innermost with an exit that compares a value it loads. The
// port is selfhost/opt/OptOuterUnroll.xc; the two make the same blocks,
// values and order. Profile-gated (the 64-bit targets), -O2+.
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

@interface XTIROptOuterUnroll : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
