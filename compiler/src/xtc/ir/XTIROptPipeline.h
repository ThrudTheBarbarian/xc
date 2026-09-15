#import <Foundation/Foundation.h>
#import "XTIRModule.h"
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIROptTargetProfile;

// Pass pipeline: runs a fixed sequence of XTIROptPass instances over an
// XTIRModule, in registration order, gated by the requested -O level.
//
// Standard usage:
//
//   XTIROptPipeline *pipe =
//       [XTIROptPipeline standardPipelineAtLevel:opts.optimisationLevel];
//   pipe.traceToStderr = !opts.quiet;
//   if (![pipe runOnModule:mod errors:&errs]) { ... }
//
// `standardPipelineAtLevel:` constructs the canonical set of passes that
// the driver and corpus harness both use. Individual passes can also be
// registered ad hoc via `addPass:` for testing.
@interface XTIROptPipeline : NSObject

/// Show "xcc: pass X: <before> → <after> ..." on stderr after each pass.
/// Off by default (so passing modes that produce no measurable delta
/// don't litter the log).
@property(nonatomic) BOOL traceToStderr;

/// Build the canonical pipeline for the given -O level. Currently:
///   -O0 : empty (no passes)
///   -O1 : dead-function-elim
///   -O2 : ... (TBD)
///   -O3 : ... (TBD)
+ (instancetype)standardPipelineAtLevel:(NSInteger)level;

/// As above, but with an explicit target profile that target-tunable passes
/// (e.g. loop-unroll) consult for their caps / capabilities. The no-profile
/// form above uses the conservative profile.
+ (instancetype)standardPipelineAtLevel:(NSInteger)level
                                profile:(XTIROptTargetProfile*)profile;

/// Register an extra pass at the end of the pipeline. Passes whose
/// minOptLevel exceeds the pipeline's level are kept but skipped at run.
- (void)addPass:(id<XTIROptPass>)pass;

/// Run all passes in order. Returns NO on the first pass that fails and
/// populates `outErrors` (the populated array is the pass's `errors`,
/// nothing further is appended).
- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors;

@end

NS_ASSUME_NONNULL_END
