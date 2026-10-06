#import "XTIRParMSL.h"
#import "XTIRModule.h"
#import "XTIRFunction.h"
#import "XTIRBlock.h"
#import "XTIRInsn.h"
#import "XTIROperand.h"
#import "XTIRValue.h"
#import "XTIRType.h"
#import "XTIRLayout.h"

NS_ASSUME_NONNULL_BEGIN

// The GPU kernel printers' shared state and analysis: XTIRParMSL.m prints
// Metal, XTIRParPTX.m (a category) prints PTX from the same analysis.

// Where a pointer value points: the thread's copy of the block object, or a
// device buffer (a captured array).
typedef NS_ENUM(uint8_t, XTParSpace) {
    XTParSpaceNone,
    XTParSpaceThread,
    XTParSpaceDevice,
};

@interface XTIRParMSL ()
@property(nonatomic) XTIRModule* module;
@property(nonatomic) XTIRFunction* fn;
@property(nonatomic) XTIRLayout* objLayout;
@property(nonatomic) NSMutableDictionary<NSNumber*, XTIRInsn*>* def;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* space;     // value -> XTParSpace
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* bufferOf;  // value -> field index
@property(nonatomic) NSMutableIndexSet* bufferFields;
@property(nonatomic) NSMutableIndexSet* reductionFields;
// Globals the kernel uses (each an AddrOf of a data global), in the order
// first seen: each is a device buffer, named in the header line so the
// runtime can ask the block for its address and size (gpuGlobal).
@property(nonatomic) NSMutableArray<NSString*>* globals;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSString*>* globalOf; // value -> global name
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* blockIndex;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* ordinal; // value -> its name's number
@property(nonatomic) BOOL failed;
// Structured control flow (planStructure).
@property(nonatomic) NSArray<NSArray<NSNumber*>*>* succ;
@property(nonatomic) NSArray<NSNumber*>* rpoIndex;
@property(nonatomic) NSArray<NSNumber*>* fwdPreds;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSMutableIndexSet*>* loopOf;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* loopExit;
@property(nonatomic) NSArray<NSNumber*>* ipdom;
// Helpers (functions the kernel calls, transitively): printed once each, in
// the order they finish, so a callee is always defined before its caller.
@property(nonatomic) BOOL helperMode;
// The block's goal is speed: fast maths, and approximate sin, cos, exp, ln
// and pow, are allowed.
@property(nonatomic) BOOL fast;
// The static-init guard of a class the kernel calls (Math, say): its flag,
// its init function and its static data, by the AddrOf value naming each
// (YES for the flag). The host ran every init before the block started, so
// the flag reads as done (2) and the rest prints nothing.
@property(nonatomic, readonly) NSMutableDictionary<NSNumber*, NSNumber*>* sinitOf;
// Why the kernel could not be printed, for the par-gpu warning: the first
// reason met, phrased to follow "because" ("it calls Math.sin, which …").
@property(nonatomic, nullable) NSString* why;
@property(nonatomic) NSMutableArray<NSString*>* helperText;
@property(nonatomic) NSMutableSet<NSString*>* helperNames;
@end

@interface XTIRParMSL (Analysis)
- (nullable XTIRType*)typeOf:(XTIRValueId)v;
- (NSString*)name:(XTIRValueId)v;
- (NSInteger)selfFieldOf:(XTIROperand*)op;
- (BOOL)analyse;
- (void)because:(NSString*)why;
- (NSString*)whyFor:(XTIRInsn*)i ptx:(BOOL)ptx;
- (NSString*)callFailed:(NSString*)callee helper:(nullable XTIRParMSL*)h;
@end

NS_ASSUME_NONNULL_END
