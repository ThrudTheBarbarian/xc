// XTIROptBlockLayout.h — lay the hot path out so it falls through
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"
#import "XTIROptTargetProfile.h"

NS_ASSUME_NONNULL_BEGIN

/// Orders a function's blocks so that the successor a conditional branch is
/// EXPECTED to take is the one laid out next.
///
/// This costs no instructions to decide and removes taken branches, which on a
/// tight loop is the whole cost. sort_small's inner loop is three blocks laid
/// out in declaration order, and every edge between them is a taken branch:
///
///     header:  cmp w10, #0 ; b.hi rhs    ; b exit      <- taken
///     body:    ... ; b header                          <- taken
///     exit:    ...
///     rhs:     ... ; b.hi body ; b exit                <- taken
///
/// Three taken branches per iteration against clang's one. At roughly one
/// taken branch per cycle that is the entire 3x gap, and the arithmetic in
/// between is free.
///
/// The back end's fallthrough peephole already drops a `b` to the next block
/// and INVERTS a conditional whose taken target is next, so ordering the
/// blocks is the whole transform — nothing else has to change.
@interface XTIROptBlockLayout : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
