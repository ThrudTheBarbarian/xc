// XTIROptMem2Reg.h — promote pinned-local struct fields out of the frame
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

/// Scalar replacement of aggregates, in the only shape the IR actually
/// produces: a pinned local reached exclusively through
/// `AddrOf` -> `FieldAddr(base, constant)` -> scalar `Load`/`Store`.
///
/// Each field becomes an independent SSA variable — phis at the iterated
/// dominance frontier of the blocks that store it, renamed by a walk of the
/// dominator tree. Loads and stores of a promoted field disappear entirely.
///
/// It runs AFTER `agg-expand`, which is what turns whole-aggregate traffic
/// into the per-field form this recognises; before that pass the locals a
/// by-value struct produces are all rejected on the first test.
@interface XTIROptMem2Reg : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
