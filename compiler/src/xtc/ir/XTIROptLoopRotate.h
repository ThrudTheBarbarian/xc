// XTIROptLoopRotate.h — top-tested → bottom-tested loop rotation.
//
// A loop the front-end emits top-tested:
//
//     PH → H
//     H:    phi …; <guard G>; CondBranch cond, B, E      (cond from G)
//     B:    <body>; Branch H                              (unconditional back-edge)
//     E:    …                                             (escape uses of H's phis)
//
// costs two branch instructions per iteration — the header `cbz`/`b.<c>` exit
// test plus the body's unconditional `b` back to the header. Rotation makes it
// bottom-tested, matching clang:
//
//     PH → H'
//     H':   <guard G[phi→init]>; CondBranch cond, B, E    (peeled first test)
//     B:    phi …; <body>; <guard G[phi→next]>; CondBranch cond', B, E
//     E:    phi(s) merging the H' and B exit edges
//
// so the back-edge is the single conditional branch (`cbnz`). The guard is
// duplicated (peeled copy in H', bottom copy in B); escaping loop-carried values
// get an exit phi in E merging the zero-iteration (H') and looped (B) values.
//
// Profile-gated (arm64 on), -O2+. Runs after the unrollers (which expect the
// canonical top-tested shape).
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

@interface XTIROptLoopRotate : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
