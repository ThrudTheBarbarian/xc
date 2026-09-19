// XTIROptAggExpand.h — turn whole-aggregate traffic into per-field traffic
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

/// Rewrites the two shapes that keep a small by-value struct in memory:
///
///   * `v:Agg = Load src; Store dst, v` — a struct copy — becomes one
///     Load/Store pair per field;
///   * `v:Agg = Load p; a = AddrOf v; FieldAddr a, #k` — the SNAPSHOT an
///     inlined by-value parameter leaves behind — becomes `FieldAddr p, #k`,
///     reading the field where it already lives instead of through a copy.
///
/// Neither is faster by itself. What they buy is that the fields become
/// ordinary scalar memory operations, which store-to-load forwarding can see
/// through and which scalar replacement can promote out of memory entirely.
@interface XTIROptAggExpand : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
