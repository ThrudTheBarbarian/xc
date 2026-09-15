#import <Foundation/Foundation.h>
#import "XTIRModule.h"

NS_ASSUME_NONNULL_BEGIN

// Protocol for IR-level optimisation passes.
//
// A pass transforms an XTIRModule in place. Passes are stateless across
// invocations: the pipeline creates one instance per pass, runs it
// against the module, then discards it. Internal scratch state lives on
// the instance, not in globals, so pipelines can run in parallel.
//
// Required:
//   passName     — short kebab-case identifier ("dead-function-elim").
//                  Used in -fdump-passes diagnostics.
//   minOptLevel  — the lowest -O level at which this pass should run.
//                  Pipeline skips the pass when -O < minOptLevel.
//   runOnModule: — apply the transform. Return YES on success; NO with
//                  a populated `outErrors` array on failure (pipeline
//                  aborts).
@protocol XTIROptPass <NSObject>
@property(nonatomic, readonly, copy) NSString* passName;
@property(nonatomic, readonly) NSInteger minOptLevel;

- (BOOL)runOnModule:(XTIRModule*)mod
             errors:(NSMutableArray<NSString*>* _Nullable* _Nullable)outErrors;
@end

NS_ASSUME_NONNULL_END
