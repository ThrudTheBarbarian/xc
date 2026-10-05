#import <Foundation/Foundation.h>

@class XTIRModule;
@class XTClassDeclNode;
@class XTDiagnosticEngine;

NS_ASSUME_NONNULL_BEGIN

// The `par` subset check (par-blocks.md §2). Every `par` block's kernel — the
// `run` method of the class the parser made for it, `ParImpl$<n>` — and every
// function it calls, transitively, must be something a GPU can run: no heap
// allocation or ARC'd values, no dynamic calls, no recursion, no varargs, I/O
// or other code outside the program, no inline assembly, and no writes to
// globals other than elements of a global array (a buffer). The rule holds on
// every target, the CPU included, so a block that builds today builds for a
// GPU later. One error per block, at the block, naming the construct.
@interface XTIRParCheck : NSObject

// NO when a block broke a rule; each such block has an error in `diag`.
+ (BOOL)checkModule:(XTIRModule*)module
         classDecls:(NSDictionary<NSString*, XTClassDeclNode*>*)classDecls
        diagnostics:(XTDiagnosticEngine*)diag;

@end

NS_ASSUME_NONNULL_END
