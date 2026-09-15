#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* Predicate: may `name` be called from a :cloaked context? Returns YES iff
|* the helper (and its transitive deps) touches neither the xtc software
|* stack ($82/$83 on xl+xe, $89/$8A on xt) nor any helper that does
|* (_xcall, _heap_*). Unknown names return NO — stage-4c errs on the
|* side of rejecting unannotated references so that new runtime helpers
|* must be explicitly audited before becoming callable from cloaked code.
\****************************************************************************/
BOOL XTRuntimeRoutineIsStackSafe(NSString* name);

NS_ASSUME_NONNULL_END
