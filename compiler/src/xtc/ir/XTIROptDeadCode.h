#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// Dead-code elimination: remove pure (side-effect-free, non-memory,
// non-terminator) instructions whose result is never used. Iterates to a
// fixpoint, so a chain of now-dead producers is fully stripped — e.g. an
// inlined nullary static call leaves its receiver `AddrOf` with no consumer
// (the backend would otherwise emit a dead `adrp/add` per call site).
// Conservative: only an explicit allowlist of pure opcodes is removed;
// loads/stores/calls/ARC/weak/memcpy/asm/phi and terminators are left alone.
// -O2+.
@interface XTIROptDeadCode : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
