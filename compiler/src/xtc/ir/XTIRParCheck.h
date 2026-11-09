#import <Foundation/Foundation.h>

@class XTIRModule;
@class XTClassDeclNode;
@class XTDiagnosticEngine;
@class XTIRType;
@class XTIRFunction;

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

// Whether blocks also get their GPU source (§6), set by the driver: Metal for
// an Apple arm64 target, PTX for win64. Elsewhere each block's gpuSource() is "".
+ (void)setEmitsMetal:(BOOL)on;
+ (void)setEmitsPTX:(BOOL)on;
+ (void)setEmitsSPIRV:(BOOL)on;
+ (void)setEmitsWGSL:(BOOL)on;

// NO when a block broke a rule; each such block has an error in `diag`.
+ (BOOL)checkModule:(XTIRModule*)module
         classDecls:(NSDictionary<NSString*, XTClassDeclNode*>*)classDecls
        diagnostics:(XTDiagnosticEngine*)diag;

@end

// The word a kernel holds an array of structs of type t in: the struct's one
// number type when its fields are all that type, packed; else an unsigned
// word as wide as its widest field, up to 32 bits. nil when a field is not a
// number or t is not a struct.
XTIRType* _Nullable XTParWordOf(XTIRType* _Nullable t);

// A kernel copy's arrays of structs (a global's, or a captured pointer's) as
// arrays of those words, its fields read and written in words. The reason an
// array was left as it was, when one is worth a warning, else nil.
NSString* _Nullable XTParWordStructs(XTIRFunction* f);

NS_ASSUME_NONNULL_END
